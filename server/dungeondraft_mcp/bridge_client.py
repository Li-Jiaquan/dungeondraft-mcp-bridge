"""Thin TCP client for the Dungeondraft MCP bridge mod.

Each request opens a short-lived connection, sends one newline-delimited JSON
object, and reads one newline-delimited JSON object back. See PROTOCOL.md.
"""

from __future__ import annotations

import json
import socket
import threading


class BridgeError(Exception):
    """Raised when the bridge is unreachable or returns an error response."""

    def __init__(self, message, details=None):
        super().__init__(message)
        self.details = details


class BridgeClient:
    def __init__(self, host: str = "127.0.0.1", port: int = 8787, timeout: float = 30.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._request_lock = threading.RLock()

    def request(self, cmd: str, **params) -> dict:
        from .spatial import needs_check
        with self._request_lock:
            if not needs_check(cmd, params):
                return self._request(cmd, **params)
            if not params.get('spatial_check', True):
                result = self._request(cmd, **params)
                result['spatial_validation'] = {'checked': False, 'reason': 'explicit_override'}
                return result
            scene, report = self.preflight(cmd, **params)
            # UI edits or another bridge client between snapshot and mutation make
            # this stamp stale. The mod refuses the edit rather than using old bounds.
            result = self._request(cmd, **params, _spatial_stamp=scene['stamp'])
            result['spatial_validation'] = {'checked': True, 'footprint': report['footprint']}
            return result

    def preflight(self, cmd: str, **params):
        """Check without editing; composite tools can validate all parts first."""
        from .spatial import check_mutation
        with self._request_lock:
            query = {}
            if 'id' in params:
                query['target_id'] = params['id']
            if params.get('asset') and cmd in {'place_object', 'configure_object', 'draw_wall', 'modify_wall', 'draw_path'}:
                query.update(asset=params['asset'], asset_category='Paths' if cmd=='draw_path' else 'Walls' if 'wall' in cmd else 'Objects')
            if cmd == 'build_room' and params.get('wall_asset'):
                query = {'asset': params['wall_asset'], 'asset_category': 'Walls'}
            if cmd == 'import_image':
                query = {'image_path': params['path']}
            scene = self._request('spatial_snapshot', **query)
            report = check_mutation(scene, cmd, params)
            if not report['safe']:
                raise BridgeError('Spatial validation rejected the edit: ' +
                                  json.dumps(report, ensure_ascii=False), details=report)
            return scene, report

    def _request(self, cmd: str, **params) -> dict:
        payload = {"cmd": cmd, **params}
        data = (json.dumps(payload) + "\n").encode("utf-8")

        try:
            with socket.create_connection((self.host, self.port), timeout=self.timeout) as sock:
                sock.settimeout(self.timeout)
                sock.sendall(data)
                buf = b""
                while b"\n" not in buf:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
        except (ConnectionRefusedError, OSError) as exc:
            raise BridgeError(
                f"Could not reach the Dungeondraft MCP bridge on {self.host}:{self.port}. "
                "Is Dungeondraft running with the MCP Bridge mod enabled and a map open? "
                f"({exc})"
            ) from exc

        line, _, _ = buf.partition(b"\n")
        if not line.strip():
            raise BridgeError("empty response from bridge")

        resp = json.loads(line.decode("utf-8"))
        if not resp.get("ok"):
            raise BridgeError(resp.get("error", "unknown bridge error"))
        return resp.get("result", {})
