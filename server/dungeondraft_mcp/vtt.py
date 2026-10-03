"""Build a portable Universal VTT file when Dungeondraft's threaded export stalls.

The native map serializer is still the source of geometry. Coordinates in its
world data are pixels at 256 pixels per grid square; UVTT uses grid squares.
"""

from __future__ import annotations

import base64
import math
import re
from collections.abc import Iterable


_NUMBER = re.compile(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?")
_GRID = 256.0


def _numbers(value: str) -> list[float]:
    if "(" in value:
        value = value.split("(", 1)[1].rsplit(")", 1)[0]
    return [float(item) for item in _NUMBER.findall(value)]


def _point(value: str | Iterable[float]) -> tuple[float, float]:
    if isinstance(value, str):
        numbers = _numbers(value)
    else:
        numbers = [float(item) for item in value]
    if len(numbers) != 2:
        raise ValueError(f"Expected one 2D point, received {value!r}")
    return numbers[0], numbers[1]


def _points(value: str | Iterable[Iterable[float]]) -> list[tuple[float, float]]:
    if isinstance(value, str):
        numbers = _numbers(value)
        if len(numbers) % 2:
            raise ValueError("Wall point array has an odd number of coordinates")
        return list(zip(numbers[::2], numbers[1::2]))
    return [_point(item) for item in value]


def _uv(point: tuple[float, float]) -> dict[str, float]:
    return {"x": round(point[0] / _GRID, 6), "y": round(point[1] / _GRID, 6)}


def _lerp(a: tuple[float, float], b: tuple[float, float], t: float) -> tuple[float, float]:
    return a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t


def _portal_bounds(
    portal: dict, a: tuple[float, float] | None = None,
    b: tuple[float, float] | None = None,
) -> tuple[tuple[float, float], tuple[float, float]]:
    center = _point(portal["position"])
    radius = max(0.0, float(portal.get("radius", 128)))
    if a is not None and b is not None:
        direction = b[0] - a[0], b[1] - a[1]
    elif "direction" in portal:
        direction = _point(portal["direction"])
    else:
        rotation = float(portal.get("rotation", 0))
        direction = math.cos(rotation), math.sin(rotation)
    length = math.hypot(*direction)
    if length < 1e-8:
        direction = (1.0, 0.0)
        length = 1.0
    offset = direction[0] * radius / length, direction[1] * radius / length
    return (center[0] - offset[0], center[1] - offset[1]), (center[0] + offset[0], center[1] + offset[1])


def _visible_spans(a: tuple[float, float], b: tuple[float, float], portals: list[dict]):
    length_squared = (b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2
    if length_squared < 1e-8:
        return []
    cuts = []
    for portal in portals:
        start, end = _portal_bounds(portal, a, b)
        project = lambda point: ((point[0] - a[0]) * (b[0] - a[0]) + (point[1] - a[1]) * (b[1] - a[1])) / length_squared
        lo, hi = sorted((project(start), project(end)))
        lo, hi = max(0.0, lo), min(1.0, hi)
        if hi > lo:
            cuts.append((lo, hi))
    position = 0.0
    spans = []
    for lo, hi in sorted(cuts):
        if lo > position + 1e-6:
            spans.append((_lerp(a, b, position), _lerp(a, b, lo)))
        position = max(position, hi)
    if position < 1.0 - 1e-6:
        spans.append((_lerp(a, b, position), b))
    return spans


def build_universal_vtt(map_data: dict, level_id: int, image: bytes, ppi: int) -> dict:
    """Convert one saved floor and its rendered PNG into UVTT 0.3 data."""
    world = map_data["world"]
    level = world["levels"][str(level_id)]
    los: list[list[dict[str, float]]] = []
    portals: list[dict] = []
    for wall in level.get("walls", []):
        points = _points(wall["points"])
        if len(points) < 2:
            continue
        pairs = list(zip(points, points[1:]))
        if wall.get("loop"):
            pairs.append((points[-1], points[0]))
        attached = wall.get("portals", [])
        for index, (a, b) in enumerate(pairs):
            on_segment = [portal for portal in attached if int(portal.get("point_index", -1)) == index]
            for start, end in _visible_spans(a, b, on_segment):
                los.append([_uv(start), _uv(end)])
            for portal in on_segment:
                start, end = _portal_bounds(portal, a, b)
                portals.append({
                    "position": _uv(_point(portal["position"])),
                    "bounds": [_uv(start), _uv(end)],
                    "rotation": float(portal.get("rotation", 0)),
                    "closed": bool(portal.get("closed", False)),
                    "freestanding": False,
                })
    for portal in level.get("portals", []):
        start, end = _portal_bounds(portal)
        portals.append({
            "position": _uv(_point(portal["position"])),
            "bounds": [_uv(start), _uv(end)],
            "rotation": float(portal.get("rotation", 0)),
            "closed": bool(portal.get("closed", False)),
            "freestanding": True,
        })
    lights = []
    for light in level.get("lights", []):
        lights.append({
            "position": _uv(_point(light["position"])),
            "range": float(light.get("range", 0)),
            "intensity": float(light.get("intensity", 1)),
            "color": light.get("color", "ffffffff"),
            "shadows": bool(light.get("shadows", True)),
        })
    return {
        "format": 0.3,
        "resolution": {
            "map_origin": {"x": 0, "y": 0},
            "map_size": {"x": int(world["width"]), "y": int(world["height"])},
            "pixels_per_grid": ppi,
        },
        "line_of_sight": los,
        "objects_line_of_sight": [],
        "portals": portals,
        "environment": level["environment"],
        "lights": lights,
        "image": base64.b64encode(image).decode("ascii"),
    }
