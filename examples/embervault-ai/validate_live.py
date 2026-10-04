"""Validate this sample in the open editor; only session regions are restored.
Run from the repository with its Python environment:
    python examples/embervault-ai/validate_live.py
"""
import json
from pathlib import Path
from dungeondraft_mcp.bridge_client import BridgeClient
from dungeondraft_mcp import spatial

base = Path(__file__).resolve().parent
layout = json.loads((base/'layout.json').read_text(encoding='utf-8'))
objects, floors, lights = layout['objects'], layout['floors'], layout['lights']
b = BridgeClient(timeout=60)
def bounds(poly):
 return min(p[0] for p in poly),min(p[1] for p in poly),max(p[0] for p in poly),max(p[1] for p in poly)
def scene(): return b.request('spatial_snapshot')
def save(name,data): (base/name).write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')

from collections import deque

def checks(s):
 roles={o['id']:o for o in objects};obs={o['id']:o for o in s['objects']}
 assert set(roles)==set(obs),(set(obs)-set(roles),set(roles)-set(obs))
 filtered=dict(s);filtered['objects']=[dict(o) for o in s['objects'] if roles[o['id']]['role'] not in ['ceiling','floor','tabletop','column_detail']]
 for o in filtered['objects']:
  o['region']='' if roles[o['id']]['role']=='pillar' else roles[o['id']]['room']
 audit=spatial.audit_scene(filtered,4000,door_clearance=80)
 accepted=[f for f in audit['findings'] if f['code']=='wall_intersection' and roles.get(f.get('id'),{}).get('role')=='pillar']
 unexpected=[f for f in audit['findings'] if f not in accepted]
 assert not unexpected,unexpected
 support={str(o['id']):spatial.contains_polygon(obs[o['support']]['polygon'],obs[o['id']]['polygon']) for o in objects if o['role'] in ['tabletop','column_detail']}
 assert all(support.values()),support
 regions={r['name']:r for r in s['regions']}
 containment={str(o['id']):spatial.contains_polygon(regions[o['room']]['points'],obs[o['id']]['polygon']) for o in objects if o['role'] not in ['ceiling','pillar','column_detail']}
 assert all(containment.values()),{k:v for k,v in containment.items() if not v}
 return {'pass':True,'unexpected_findings':unexpected,'intentional_column_wall_contacts':len(accepted),'floor_level_objects_checked':len(filtered['objects']),'tabletop_support':support,'room_containment':containment}

def navigation(s, actor_tiles=0.4):
 radius=actor_tiles*128;step=32
 solid=[o for o in s['objects'] if next(r['role'] for r in objects if r['id']==o['id']) not in ['ceiling','floor','tabletop','column_detail']]
 obstacles=[(o['polygon'],bounds(o['polygon'])) for o in solid]
 floor_polys=[(f['points'],bounds(f['points'])) for f in floors[1:]]
 wall_lines=[]
 for w in s['walls']:
  gaps=[d for d in s['portals'] if d['wall_id']==w['id'] and not d['window'] and not d['closed']]
  wall_lines.append((w,bounds(w['points']),gaps))
 def in_floor(p):return any(l<=p[0]<=r and t<=p[1]<=bb and spatial.inside(p,poly) for poly,(l,t,r,bb) in floor_polys)
 def free(p):
  if not in_floor(p):return False
  for w,(l,t,r,bb),gaps in wall_lines:
   margin=w['half_width']+radius
   if not l-margin<=p[0]<=r+margin or not t-margin<=p[1]<=bb+margin:continue
   if min(spatial.point_segment(p,a,c) for a,c in spatial.edges(w['points'],w['loop']))>margin:continue
   if any(abs(sum((p[i]-d['position'][i])*d['tangent'][i] for i in [0,1]))<d['radius']-radius and abs(sum((p[i]-d['position'][i])*d['normal'][i] for i in [0,1]))<margin+step for d in gaps):continue
   return False
  for poly,(l,t,r,bb) in obstacles:
   if not l-radius<=p[0]<=r+radius or not t-radius<=p[1]<=bb+radius:continue
   if spatial.inside(p,poly) or min(spatial.point_segment(p,a,c) for a,c in spatial.edges(poly))<=radius:return False
  return True
 walk={(i,j) for i in range(1,176) for j in range(1,320) if free((i*step,j*step))}
 def node(p):return tuple(round(v*256/step) for v in p)
 start=node((11,38.9));assert start in walk,'Entrance blocked'
 visited={start};q=deque([start])
 while q:
  i,j=q.popleft()
  for v in [(i+1,j),(i-1,j),(i,j+1),(i,j-1)]:
   if v in walk and v not in visited:visited.add(v);q.append(v)
 targets={'lower-vault':(11,33),'southwest-stair-landing':(7.375,35.25),'southeast-stair-landing':(14.625,35.25),'hall-south':(11,25),'hall-middle':(11,18),'hall-north':(11,10),'upper-store':(11,6),'northwest-stair-landing':(6.75,4.75),'northeast-stair-landing':(15.25,4.75),'private-workshop-door':(15.125,12.375),'left-work-bay':(6.875,14.25),'right-dining-bay':(15.8,20.5),'sleeping-bay':(16.6,26.4)}
 result={k:{'tile':p,'reachable':node(p) in visited} for k,p in targets.items()}
 print('NAV',result,flush=True)
 for k,v in result.items():
  if not v['reachable']:
   p=tuple(a*step for a in node(v['tile']));n=node(v['tile'])
   print('DIAG',k,'node_is_free',n in walk,'nearby_reachable',[(a*step/256,c*step/256) for a,c in visited if abs(a-n[0])<=4 and abs(c-n[1])<=4][:8], 'blocking_objects',[(o['id'],next(z['asset'] for z in objects if z['id']==o['id'])) for o in solid if spatial.inside(p,o['polygon']) or min(spatial.point_segment(p,a,c) for a,c in spatial.edges(o['polygon']))<=radius],flush=True)
 assert all(v['reachable'] for v in result.values()),result
 return {'pass':True,'actor_diameter_tiles':actor_tiles,'grid_step_tiles':step/256,'targets':result,'reachable_nodes':len(visited),'method':'4-neighbor flood fill, full rotated furniture envelopes, masonry columns and native wall widths; open door intervals. Outside native floor polygons is forbidden.'}
if __name__=='__main__':
 status = b.request('get_status')
 assert status['map_size_woxels']==[5632,10240] and status['level_count']==1,'Open the Embervault sample first'
 before = scene()
 assert {o['id'] for o in before['objects']}=={o['id'] for o in objects},'Unexpected map objects; refusing to alter session regions'
 # Reopening clears session-only spatial zones. Restore them from the sidecar.
 for region in layout['regions']: b.request('set_spatial_region',**region)
 s = scene()
 for expected in objects:
  actual = next(o for o in s['objects'] if o['id']==expected['id'])
  assert all(abs(actual['position'][i]-expected['tile'][i]*256)<.02 for i in [0,1]),expected
  assert all(abs(v-expected['scale'])<1e-5 for v in actual['scale']),expected
  assert abs((actual['rotation']-expected['rotation']+180)%360-180)<.001,expected
  assert actual['layer']==(400 if expected['role']=='pillar' else 300 if expected['role']=='ceiling' else 200),expected
 assert len(s['portals'])==2 and len(s['walls'])==14 and status['counts']['lights']==16
 for light in lights:
  actual = b.request('native_get',target=f"Element:{light['id']}",properties=['enabled','shadow_enabled','energy','color','position','texture_scale'])
  assert actual['enabled'] and actual['shadow_enabled'] and abs(actual['energy']-light['energy'])<1e-5
  assert all(abs(actual['position']['value'][i]-light['tile'][i]*256)<.02 for i in [0,1])
  rgba=[int(light['color'][i:i+2],16)/255 for i in (1,3,5)]+[1]
  assert all(abs(a-c)<1e-5 for a,c in zip(actual['color']['value'],rgba))
  assert abs(actual['texture_scale']-light['range'])<1e-5
 result={'layout':checks(s),'navigation_small_actor':navigation(s,.4),'navigation_combat_token':navigation(s,1),'lights':{'pass':True,'enabled_shadow_casting_sources':16}}
 save('live-checks.json',result)
 print('PASS: geometry, 13 destinations at both actor widths, 16 enabled lights; live-checks.json written.')
