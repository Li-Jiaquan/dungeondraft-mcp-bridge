import json
import unittest
from unittest.mock import MagicMock, patch
from dungeondraft_mcp.bridge_client import BridgeClient


class WireColorsTests(unittest.TestCase):
    def test_rgba_channels_survive_godot3_wire_format(self):
        socket = MagicMock()
        socket.recv.return_value = b'{"ok":true,"result":{"color":"#80102030"}}\n'
        connection = MagicMock()
        connection.__enter__.return_value = socket
        with patch('dungeondraft_mcp.bridge_client.socket.create_connection', return_value=connection):
            result = BridgeClient().request('configure_environment', ambient='#10203080',
                                            grid_color='#abcdef', path='#11223344')
            native = BridgeClient().request('native_call', target='fixture', method='Save')
        self.assertEqual(result['color'], '#10203080')
        self.assertEqual(native['color'], '#80102030')
        payload = json.loads(socket.sendall.call_args_list[0].args[0])
        self.assertEqual(payload['ambient'], [16/255, 32/255, 48/255, 128/255])
        self.assertEqual(payload['grid_color'], '#abcdef')
        self.assertEqual(payload['path'], '#11223344')
