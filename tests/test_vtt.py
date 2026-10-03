import base64
import unittest

from dungeondraft_mcp.vtt import build_universal_vtt


class UniversalVTTTests(unittest.TestCase):
    def test_door_cuts_line_of_sight_and_preserves_light(self):
        document = {'world': {
            'width': 4, 'height': 2,
            'levels': {'0': {
                'environment': {'baked_lighting': True, 'ambient_light': 'ff556677'},
                'walls': [{
                    'points': 'PoolVector2Array( 0, 256, 1024, 256 )',
                    'loop': False,
                    'portals': [{
                        'position': 'Vector2( 512, 256 )', 'radius': 128,
                        'point_index': 0, 'rotation': 0, 'closed': True,
                    }],
                }],
                'portals': [],
                'lights': [{
                    'position': 'Vector2( 256, 256 )', 'range': 3,
                    'intensity': .7, 'color': 'ffffaa55', 'shadows': True,
                }],
            }},
        }}
        image = b'png bytes'
        result = build_universal_vtt(document, 0, image, 40)
        self.assertEqual(result['format'], .3)
        self.assertEqual(result['resolution']['pixels_per_grid'], 40)
        self.assertEqual(result['line_of_sight'], [
            [{'x': 0, 'y': 1}, {'x': 1.5, 'y': 1}],
            [{'x': 2.5, 'y': 1}, {'x': 4, 'y': 1}],
        ])
        self.assertEqual(result['portals'][0]['bounds'],
                         [{'x': 1.5, 'y': 1}, {'x': 2.5, 'y': 1}])
        self.assertEqual(result['lights'][0]['position'], {'x': 1, 'y': 1})
        self.assertEqual(base64.b64decode(result['image']), image)


if __name__ == '__main__':
    unittest.main()
