"""Geometric regression cases and fail-before-mutation contract checks."""
import copy
import unittest

from dungeondraft_mcp.bridge_client import BridgeClient, BridgeError
from dungeondraft_mcp.spatial import (check_mutation, audit_scene, rect_polygon,
                                      transform, contains_polygon, simple_polygon)


def prop(ident, x, y, width=100, height=100, rotation=0):
    local=rect_polygon([-width/2,-height/2,width,height])
    return {'id':ident,'asset':'fixture.png','position':[x,y],'scale':[1,1],
            'rotation':rotation,'local_polygon':local,
            'polygon':transform(local,[x,y],[1,1],rotation)}


def scene():
    return {'stamp':'fixture-revision','floor_id':1,'dimensions':[2000,2000],
            'objects':[],'walls':[],'portals':[],'regions':[],
            'asset':{'local_polygon':rect_polygon([-100,-50,200,100])}}


class FakeBridge(BridgeClient):
    def __init__(self, snapshot):
        super().__init__()
        self.scene=snapshot
        self.calls=[]
    def _request(self,cmd,**params):
        self.calls.append((cmd,params))
        if cmd=='spatial_snapshot': return copy.deepcopy(self.scene)
        return {'id':12}


class SpatialTests(unittest.TestCase):
    def codes(self,s,cmd='place_object',**params):
        return {e['code'] for e in check_mutation(s,cmd,params)['errors']}

    def test_large_table_crosses_wall_even_when_center_is_inside(self):
        s=scene(); s['walls']=[{'id':1,'points':[[600,0],[600,2000]],'loop':False,'half_width':16}]
        self.assertIn('wall_intersection',self.codes(s,x=520,y=500))
        self.assertEqual(self.codes(s,x=450,y=500),set())

    def test_rotation_changes_footprint(self):
        s=scene(); s['walls']=[{'id':1,'points':[[600,0],[600,2000]],'loop':False,'half_width':16}]
        self.assertIn('wall_intersection',self.codes(s,x=520,y=500,rotation=0))
        self.assertNotIn('wall_intersection',self.codes(s,x=520,y=500,rotation=90))

    def test_diagonal_wall_and_thickness(self):
        s=scene(); s['walls']=[{'id':1,'points':[[0,0],[1000,1000]],'loop':False,'half_width':20}]
        self.assertIn('wall_intersection',self.codes(s,x=500,y=600,scale=.5))
        self.assertEqual(self.codes(s,x=200,y=900),set())

    def test_move_ignores_source_but_duplicate_checks_source(self):
        s=scene(); s.pop('asset'); s['objects']=[prop(9,500,500)]
        self.assertTrue(check_mutation(s,'move_element',{'id':9,'x':500,'y':500})['safe'])
        self.assertIn('object_overlap',self.codes(s,'duplicate_object',id=9,dx=20,dy=0))

    def test_door_approach_clearance_and_windows(self):
        s=scene(); s['portals']=[{'id':3,'position':[500,500],'tangent':[1,0],'radius':100}]
        self.assertIn('door_clearance',self.codes(s,x=500,y=620))
        s['portals'][0]['window']=True
        self.assertEqual(self.codes(s,x=500,y=620),set())

    def test_overlap_override_still_blocks_walls(self):
        s=scene(); s['objects']=[prop(4,500,500)]
        self.assertIn('object_overlap',self.codes(s,x=500,y=500))
        self.assertEqual(self.codes(s,x=500,y=500,allow_overlap=True),set())
        s['walls']=[{'id':2,'points':[[500,0],[500,2000]],'loop':False,'half_width':16}]
        self.assertIn('wall_intersection',self.codes(s,x=500,y=500,allow_overlap=True))

    def test_reserved_corridor_and_room(self):
        s=scene(); s['regions']=[{'name':'aisle','kind':'clearance','points':rect_polygon([600,0,100,2000])},
                               {'name':'room','kind':'room','points':rect_polygon([0,0,600,1000])}]
        self.assertIn('reserved_clearance',self.codes(s,x=650,y=500))
        self.assertIn('outside_room',self.codes(s,x=560,y=500,region='room'))

    def test_concave_room_does_not_accept_an_edge_across_notch(self):
        outer=[(0,0),(10,0),(10,10),(6,10),(6,4),(4,4),(4,10),(0,10)]
        self.assertFalse(contains_polygon(outer,[(2,6),(8,6),(8,8),(2,8)]))

    def test_protected_polygon_blocks_brush_edge_not_just_center(self):
        s=scene(); s['regions']=[{'name':'building','kind':'protected','points':rect_polygon([500,500,200,200])}]
        self.assertIn('protected_region',self.codes(s,'paint_terrain',x=450,y=600,radius=60))
        self.assertEqual(self.codes(s,'paint_terrain',x=400,y=600,radius=50),set())
        for cmd in ('fill_terrain','clear_caves'):
            self.assertIn('protected_region',self.codes(s,cmd))
        self.assertIn('protected_region',self.codes(s,'dig_cave',points=[[300,600],[900,600]],radius=20))
        self.assertIn('protected_region',self.codes(s,'draw_water',rect=[450,550,100,100]))
        self.assertIn('protected_region',self.codes(s,'draw_material',points=[[550,550],[650,550],[650,650],[550,650]]))

    def test_cliff_path_width_and_smoothing(self):
        s=scene(); s['regions']=[{'name':'building','kind':'protected','points':rect_polygon([500,500,200,200])}]
        s['asset']['half_width']=40
        self.assertIn('protected_region',self.codes(s,'draw_path',points=[[480,400],[480,800]],width=1))
        self.assertIn('unmodeled_path_smoothing',self.codes(s,'draw_path',points=[[100,100],[200,200]],smoothness=1))

    def test_wall_draw_and_rectangular_room_check_existing_furniture(self):
        s=scene(); s['objects']=[prop(8,500,500)]
        self.assertIn('wall_intersection',self.codes(s,'draw_wall',points=[[500,0],[500,1000]]))
        self.assertIn('wall_intersection',self.codes(s,'build_room',rect=[500,0,500,1000]))

    def test_nonfinite_and_invalid_scale(self):
        for params in ({'x':float('nan'),'y':500},{'x':500,'y':500,'scale':-1},
                       {'x':500,'y':500,'rotation':float('inf')}):
            with self.assertRaises(ValueError): check_mutation(scene(),'place_object',params)
        with self.assertRaises(ValueError): simple_polygon([[0,0],[10,10],[0,10],[10,0]])

    def test_entire_footprint_must_fit_map(self):
        self.assertIn('outside_map',self.codes(scene(),x=50,y=500))

    def test_unknown_existing_footprint_fails_closed(self):
        s=scene(); s['unsupported_objects']=[6]
        self.assertIn('unknown_footprint',self.codes(s,x=500,y=500))
        self.assertFalse(audit_scene(s)['safe'])

    def test_cross_floor_object_cannot_bypass_check(self):
        s=scene(); s['target_kind']='object'
        with self.assertRaises(ValueError): check_mutation(s,'move_element',{'id':90,'x':500,'y':500})

    def test_modified_wall_uses_its_native_transform(self):
        s=scene(); s.pop('asset'); s['objects']=[prop(8,500,500)]
        s['walls']=[{'id':9,'points':[[600,0],[600,1000]],'local_points':[[0,0],[0,1000]],
                     'position':[600,0],'scale':[1,1],'rotation':0,'half_width':10,'loop':False}]
        self.assertIn('wall_intersection',self.codes(s,'modify_wall',id=9,points=[[-100,0],[-100,1000]]))

    def test_protected_brush_includes_native_raster_padding(self):
        s=scene(); s['regions']=[{'name':'protected','kind':'protected','points':rect_polygon([500,500,200,200])}]
        s['terrain_raster_padding']=16
        self.assertIn('protected_region',self.codes(s,'paint_terrain',x=400,y=600,radius=90))
        s['cave_cell_size']=64
        self.assertIn('protected_region',self.codes(s,'dig_cave',x=400,y=600,radius=1))

    def test_terrain_slot_change_is_global_even_when_brush_is_distant(self):
        s=scene(); s['regions']=[{'name':'protected','kind':'protected','points':rect_polygon([500,500,200,200])}]
        self.assertIn('protected_terrain_slot',self.codes(s,'paint_terrain',x=100,y=100,radius=10,asset='new.png'))
        self.assertIn('protected_region',self.codes(s,'set_terrain_slot',asset='new.png'))
        self.assertIn('protected_cave_style',self.codes(s,'dig_cave',x=100,y=100,radius=10,ground_color='#777777'))

    def test_blocked_edit_never_reaches_mutation(self):
        s=scene(); s['objects']=[prop(1,500,500)]
        b=FakeBridge(s)
        with self.assertRaises(BridgeError) as exc:
            b.request('place_object',asset='fixture.png',x=500,y=500)
        self.assertEqual([c for c,p in b.calls],['spatial_snapshot'])
        self.assertFalse(exc.exception.details['safe'])

    def test_success_carries_snapshot_stamp_to_commit(self):
        b=FakeBridge(scene())
        result=b.request('place_object',asset='fixture.png',x=500,y=500)
        self.assertEqual(b.calls[-1][1]['_spatial_stamp'],'fixture-revision')
        self.assertTrue(result['spatial_validation']['checked'])

    def test_explicit_override_and_color_only_edit(self):
        b=FakeBridge(scene())
        self.assertFalse(b.request('place_object',asset='fixture.png',x=0,y=0,spatial_check=False)['spatial_validation']['checked'])
        b.request('modify_object',id=5,color='#ffffff')
        self.assertNotIn('spatial_snapshot',[c for c,p in b.calls])

    def test_audit_counts_even_when_report_is_truncated(self):
        s=scene(); s['objects']=[prop(1,500,500),prop(2,500,500),prop(3,500,500)]
        s['walls']=[{'id':9,'points':[[500,0],[500,2000]],'loop':False,'half_width':10}]
        report=audit_scene(s,limit=1)
        self.assertEqual(report['counts']['wall_intersection'],3)
        self.assertEqual(report['counts']['object_overlap'],3)
        self.assertTrue(report['truncated'])
        self.assertFalse(report['safe'])


if __name__=='__main__': unittest.main()
