"""Opt-in integration regression; saves and restores the open Dungeondraft map.

Run with an installed bridge and Dungeondraft open:
    python tests/live_wall_portals.py --run-live
"""
import argparse
from contextlib import nullcontext
import json
import sys
import tempfile
import time
from pathlib import Path
from dungeondraft_mcp.bridge_client import BridgeClient, BridgeError
from dungeondraft_mcp.extended import register
from dungeondraft_mcp.spatial import point_segment, edges


class Registry:
    def __init__(self): self.tools = {}
    def tool(self):
        def decorate(fn): self.tools[fn.__name__] = fn; return fn
        return decorate


def run():
    bridge = BridgeClient(timeout=60)
    registry = Registry()
    register(registry, bridge)
    def call(cmd, **params):
        result = registry.tools[cmd](**params) if cmd in registry.tools else bridge.request(cmd, **params)
        print(cmd,file=sys.stderr,flush=True)
        return result
    def wait_scene(predicate):
        # Map loading/reloaded mod owners can abandon a just-accepted socket.
        # Retry read-only polls, never replay a timed-out mutation.
        reader=BridgeClient(timeout=3)
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            try:
                state=reader.request('spatial_snapshot')
                if predicate(state): return state
            except BridgeError:
                pass
            time.sleep(.25)
        raise AssertionError('Map failed to become ready; keep Dungeondraft visible')
    # Keep the recovery map: after restoration it is the editor's open file.
    with nullcontext(tempfile.mkdtemp(prefix='dd-wall-regression-')) as directory:
        root = Path(directory)
        previous = call('get_status')
        call('save_map', path=str(root/'before.dungeondraft_map'), update_current=True)
        regions = call('spatial_snapshot')['regions']
        try:
            assert min(previous['map_size_woxels'])>=1024,'Use a map at least four tiles across'
            # Load an isolated native copy rather than opening the New dialog:
            # modal save prompts can suspend bridge processing on some builds.
            data=json.loads((Path(__file__).parent/'fixtures'/'empty-wall-map.dungeondraft_map').read_text(encoding='utf-8'))
            initial=root/'empty-fixture.dungeondraft_map'
            initial.write_text(json.dumps(data),encoding='utf-8')
            old_instance=call('spatial_snapshot')['floor_instance']
            call('open_map',path=str(initial))
            wait_scene(lambda state:state['floor_instance']!=old_instance and not state['objects'] and not state['walls'])
            wall = call('draw_wall', asset='res://textures/walls/stone.png', points=[[128,128],[896,128],[896,896]])['id']
            door = call('add_portal', asset='res://textures/portals/door_03.png', x=512,y=128,radius=64,closed=False,flip=True,fallback_free=False)['id']
            window = call('add_portal', asset='res://textures/portals/window_03.png', x=896,y=512,radius=48,closed=True,flip=False,fallback_free=False)['id']
            before = call('spatial_snapshot')
            call('modify_wall', id=wall, points=[[128,160],[896,192],[896,896]])
            after = call('spatial_snapshot')
            assert {p['id'] for p in after['portals']} == {door,window}, {'before':before['portals'],'after':after['portals']}
            masonry = next(w for w in after['walls'] if w['id']==wall)
            for portal in after['portals']:
                assert min(point_segment(portal['position'],a,b) for a,b in edges(masonry['points'],masonry['loop'])) < .01, portal
                i=call('native_get',target=f"Element:{portal['id']}",properties=['WallPointIndex'])['WallPointIndex']
                a,c=masonry['points'][i],masonry['points'][i+1]
                edge=[c[k]-a[k] for k in [0,1]]
                assert abs(edge[0]*portal['tangent'][1]-edge[1]*portal['tangent'][0])<.01,portal
                old = next(p for p in before['portals'] if p['id']==portal['id'])
                assert (portal['closed'],portal['radius'],portal['asset']) == (old['closed'],old['radius'],old['asset'])
            assert call('native_call',target=f'Element:{door}',method='get_Flip',args=[])['value']
            edited_rotation = call('native_get',target=f'Element:{door}',properties=['rotation'])['rotation']
            original_color = call('native_call',target=f'Element:{wall}',method='get_Color',args=[])['value']
            try:
                call('modify_wall',id=wall,points=[[128,160],[640,160],[896,160],[896,896]],color='#ff0000')
            except BridgeError as error:
                assert 'same vertex count' in str(error),error
            else: raise AssertionError('Topology change should be refused while portals are mounted')
            assert call('native_call',target=f'Element:{wall}',method='get_Color',args=[])['value'] == original_color
            assert call('spatial_snapshot')['stamp'] == after['stamp']
            try:
                call('modify_wall',id=wall,points=[[128,160],[192,160],[192,896]],color='#ff0000')
            except BridgeError as error:
                assert 'too short' in str(error),error
            else:raise AssertionError('A shortened segment must fit its portal')
            assert call('spatial_snapshot')['stamp']==after['stamp']
            assert call('native_call',target=f'Element:{wall}',method='get_Color',args=[])['value']==original_color
            empty = call('draw_wall',asset='res://textures/walls/stone.png',points=[[128,768],[384,768]])['id']
            call('modify_wall',id=empty,points=[[128,768],[256,800],[384,768]])
            fixture = root/'fixture.dungeondraft_map'
            call('save_map',path=str(fixture),update_current=False)
            fixture_instance = call('spatial_snapshot')['floor_instance']
            call('open_map',path=str(fixture))
            reopened=wait_scene(lambda state:state['floor_instance']!=fixture_instance and {p['id'] for p in state['portals']}=={door,window})
            # Native files encode the visible flip in direction/rotation rather
            # than serializing the editor's transient Flip flag.
            assert abs(call('native_get',target=f'Element:{door}',properties=['rotation'])['rotation']-edited_rotation)<1e-5
            for portal in reopened['portals']:
                old = next(p for p in after['portals'] if p['id']==portal['id'])
                assert (portal['closed'],portal['radius'],portal['asset'],portal['position']) == (old['closed'],old['radius'],old['asset'],old['position'])
            return {'pass':True,'door_and_window_preserved':True,'positions_on_edited_wall':True,'orientation_follows_rotated_segment':True,'flip_radius_asset_and_closed_state_preserved':True,'topology_rejected_without_partial_color_edit':True,'short_segment_rejected_without_partial_edit':True,'portal_free_topology_change':True,'save_reopen':True}
        finally:
            instance=call('spatial_snapshot')['floor_instance']
            call('open_map',path=str(root/'before.dungeondraft_map'))
            wait_scene(lambda state:state['floor_instance']!=instance and state['dimensions']==previous['map_size_woxels'] and len(state['objects'])==previous['counts']['objects'])
            for region in regions:call('set_spatial_region',**region)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-live',action='store_true',help='Allow creating a temporary fixture in the open application')
    args=parser.parse_args()
    if not args.run_live:parser.error('This opt-in test requires --run-live')
    print(json.dumps(run(),indent=2))
