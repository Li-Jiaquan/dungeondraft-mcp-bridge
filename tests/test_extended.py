"""Offline checks for operations that must fail safely before modifying a map."""
import tempfile
import unittest
from pathlib import Path
from PIL import Image
from dungeondraft_mcp.extended import register
from dungeondraft_mcp.bridge_client import BridgeError


class Registry:
    def __init__(self): self.tools = {}
    def tool(self):
        def decorate(fn):
            self.tools[fn.__name__] = fn
            return fn
        return decorate


class Bridge:
    def __init__(self):
        self.calls = []
        self.imports = []
    def request(self, cmd, **params):
        self.calls.append((cmd, params))
        if cmd == 'import_image':
            path = Path(params['path'])
            with Image.open(path) as im: pixel = im.convert('RGBA').getpixel((0, 0))
            self.imports.append((path, pixel))
            return {'id': 1, 'embedded': True}
        if cmd == 'list_layers': return {'layers': {'100': 'Objects'}}
        if cmd == 'configure_terrain': return {'expanded': True}
        if cmd == 'list_assets': return {'assets': ['tree.png'] if params['category']=='Objects' else []}
        if cmd == 'place_object': return {'id': sum(c=='place_object' for c,p in self.calls)}
        if cmd == 'fail': raise BridgeError('fixture failure')
        return {}


class ExtendedTests(unittest.TestCase):
    def setUp(self):
        self.registry, self.bridge = Registry(), Bridge()
        register(self.registry, self.bridge)
        self.tools = self.registry.tools

    def test_invalid_png_never_reaches_application(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d)/'broken.png'
            path.write_bytes(b'not a PNG')
            with self.assertRaises(OSError): self.tools['import_image'](str(path))
        self.assertEqual(self.bridge.calls, [])

    def test_reimport_uses_fresh_pixels_and_cleans_temporary_files(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d)/'art.png'
            for color in [(255, 0, 0, 0), (0, 0, 255, 255)]:
                Image.new('RGBA', (2, 2), color).save(path)
                self.tools['import_image'](str(path))
        self.assertNotEqual(self.bridge.imports[0][0], self.bridge.imports[1][0])
        self.assertEqual([p for f,p in self.bridge.imports], [(255,0,0,0),(0,0,255,255)])
        self.assertTrue(all(not f.exists() for f,p in self.bridge.imports))

    def test_missing_cliff_cannot_leave_partial_terrain(self):
        with self.assertRaises(ValueError):
            self.tools['draw_elevation']([[0,0],[256,0],[0,256]], 'missing.png', 'terrain.png')
        self.assertFalse(any(cmd in ('fill_region','draw_path') for cmd,p in self.bridge.calls))

    def test_nonfinite_polygon_is_rejected_before_native_call(self):
        with self.assertRaises(ValueError):
            self.tools['draw_water'](points=[[0,0],[256,0],[0,float('nan')]])
        self.assertEqual(self.bridge.calls, [])

    def test_seeded_scatter_is_repeatable(self):
        self.tools['scatter_objects']('tree.png', [0,0,512,512], count=3, seed=7)
        first = [p for c,p in self.bridge.calls if c=='place_object']
        self.bridge.calls.clear()
        self.tools['scatter_objects']('tree.png', [0,0,512,512], count=3, seed=7)
        self.assertEqual(first, [p for c,p in self.bridge.calls if c=='place_object'])

    def test_batch_reports_partial_failure_and_stops(self):
        result = self.tools['batch_commands']([{'cmd':'get_status'},{'cmd':'fail'},{'cmd':'place_object'}])
        self.assertEqual(result['completed'], 2)
        self.assertFalse(result['atomic'])
        self.assertFalse(result['results'][1]['ok'])
        self.assertEqual([c for c,p in self.bridge.calls], ['get_status','fail'])


if __name__ == '__main__': unittest.main()
