"""Conservative 2D layout checks against a snapshot of the live current floor.

Footprints are rotated alpha-trimmed rectangles, not a physics simulation. All
distances use world pixels. The bridge verifies the snapshot stamp at commit.
"""
from __future__ import annotations

import math
from collections import Counter

EPS = 1e-6
OBJECT_COMMANDS = {'place_object', 'import_image', 'move_element', 'modify_object',
                   'duplicate_object', 'configure_object'}
WALL_COMMANDS = {'draw_wall', 'build_room', 'modify_wall'}
AREA_COMMANDS = {'fill_terrain', 'fill_region', 'paint_terrain', 'paint_path',
                 'dig_cave', 'clear_caves', 'draw_water', 'draw_material', 'draw_path', 'set_terrain_slot'}
GUARDED_COMMANDS = OBJECT_COMMANDS | WALL_COMMANDS | AREA_COMMANDS


def number(value, name='coordinate'):
    if isinstance(value, bool):
        raise ValueError(f'{name} must be a finite number')
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f'{name} must be finite')
    return result


def points(raw, minimum=3):
    if not isinstance(raw, (list, tuple)) or len(raw) < minimum:
        raise ValueError(f'at least {minimum} points required')
    out = []
    for p in raw:
        if len(p) != 2:
            raise ValueError('points must be [x,y] pairs')
        out.append((number(p[0]), number(p[1])))
    return out


def edges(poly, closed=True):
    return list(zip(poly, poly[1:] + (poly[:1] if closed else [])))


def cross(a, b, c):
    return (b[0]-a[0])*(c[1]-a[1]) - (b[1]-a[1])*(c[0]-a[0])


def point_segment(p, a, b):
    dx, dy = b[0]-a[0], b[1]-a[1]
    length = dx*dx + dy*dy
    t = max(0, min(1, ((p[0]-a[0])*dx+(p[1]-a[1])*dy)/length)) if length else 0
    return math.hypot(p[0]-a[0]-t*dx, p[1]-a[1]-t*dy)


def segments_touch(a, b, c, d):
    if ((cross(a,b,c) > EPS and cross(a,b,d) < -EPS) or
        (cross(a,b,d) > EPS and cross(a,b,c) < -EPS)) and (
        (cross(c,d,a) > EPS and cross(c,d,b) < -EPS) or
        (cross(c,d,b) > EPS and cross(c,d,a) < -EPS)):
        return True
    return min(point_segment(a,c,d), point_segment(b,c,d),
               point_segment(c,a,b), point_segment(d,a,b)) <= EPS


def segment_distance(a, b, c, d):
    if segments_touch(a,b,c,d):
        return 0.0
    return min(point_segment(a,c,d), point_segment(b,c,d),
               point_segment(c,a,b), point_segment(d,a,b))


def inside(p, poly):
    if any(point_segment(p,a,b) <= EPS for a,b in edges(poly)):
        return True
    hit = False
    for a,b in edges(poly):
        if (a[1] > p[1]) != (b[1] > p[1]):
            if p[0] < (b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0]:
                hit = not hit
    return hit


def bounds(poly):
    return [min(p[0] for p in poly), min(p[1] for p in poly),
            max(p[0] for p in poly), max(p[1] for p in poly)]


def polygon_distance(a, b):
    if inside(a[0], b) or inside(b[0], a):
        return 0.0
    return min(segment_distance(x,y,u,v) for x,y in edges(a) for u,v in edges(b))


def near(a, b, margin=0):
    ba,bb=bounds(a),bounds(b)
    if ba[0] > bb[2]+margin+EPS or bb[0] > ba[2]+margin+EPS or ba[1] > bb[3]+margin+EPS or bb[1] > ba[3]+margin+EPS:
        return False
    return polygon_distance(a,b) <= margin+EPS


def polygon_segment(poly, a, b):
    if inside(a,poly) or inside(b,poly):
        return 0.0
    return min(segment_distance(x,y,a,b) for x,y in edges(poly))


def contains_polygon(outer, inner):
    if not all(inside(p,outer) for p in inner):
        return False
    # Corner checks alone miss a table crossing a concave room's notch. Split
    # each edge at every room-boundary crossing and test each resulting span.
    for a,b in edges(inner):
        ts = [0.0, 1.0]
        dx,dy = b[0]-a[0], b[1]-a[1]
        for c,d in edges(outer):
            ex,ey = d[0]-c[0], d[1]-c[1]
            den = dx*ey-dy*ex
            if abs(den) <= EPS:
                continue
            t = ((c[0]-a[0])*ey-(c[1]-a[1])*ex)/den
            u = ((c[0]-a[0])*dy-(c[1]-a[1])*dx)/den
            if -EPS <= t <= 1+EPS and -EPS <= u <= 1+EPS:
                ts.append(max(0,min(1,t)))
        ts = sorted(set(ts))
        if any(not inside((a[0]+dx*(s+t)/2, a[1]+dy*(s+t)/2),outer)
               for s,t in zip(ts,ts[1:])):
            return False
    return True


def simple_polygon(raw):
    poly = points(raw)
    if poly[0] == poly[-1]:
        poly.pop()
    if len(poly) < 3 or abs(sum(a[0]*b[1]-b[0]*a[1] for a,b in edges(poly))) <= EPS:
        raise ValueError('polygon must have nonzero area')
    es = edges(poly)
    for i,(a,b) in enumerate(es):
        if math.dist(a,b) <= EPS:
            raise ValueError('polygon has a zero-length edge')
        for j,(c,d) in enumerate(es):
            if j <= i+1 or (i == 0 and j == len(es)-1):
                continue
            if segments_touch(a,b,c,d):
                raise ValueError('polygon must not intersect itself')
    return poly


def rect_polygon(raw):
    if len(raw) != 4:
        raise ValueError('rectangle must be [x,y,width,height]')
    x,y,w,h = [number(v) for v in raw]
    if w <= 0 or h <= 0:
        raise ValueError('rectangle dimensions must be positive')
    return [(x,y),(x+w,y),(x+w,y+h),(x,y+h)]


def transform(poly, position, scale, rotation, parent=None):
    rad = math.radians(number(rotation, 'rotation'))
    c,s = math.cos(rad), math.sin(rad)
    px,py = position
    sx,sy = scale
    matrix = parent or [1,0,0,1,0,0]
    out=[]
    for x,y in poly:
        u,v = px+c*x*sx-s*y*sy, py+s*x*sx+c*y*sy
        out.append((matrix[0]*u+matrix[2]*v+matrix[4],
                    matrix[1]*u+matrix[3]*v+matrix[5]))
    return out


def needs_check(cmd, params):
    if cmd not in GUARDED_COMMANDS:
        return False
    if cmd == 'modify_object':
        return bool({'scale','rotation'} & params.keys())
    if cmd == 'configure_object':
        return bool({'mirror','asset'} & params.keys())
    if cmd == 'modify_wall':
        return bool({'points','asset'} & params.keys())
    return True


def finding(code, message, **data):
    return {'code':code, 'message':message, **data}


def nonnegative(params, key, default):
    v = number(params.get(key,default),key)
    if v < 0:
        raise ValueError(f'{key} must be nonnegative')
    return v


def object_candidate(scene, cmd, params):
    src = next((o for o in scene['objects'] if o['id'] == params.get('id')),None)
    if cmd not in {'place_object','import_image'} and src is None:
        if cmd in {'move_element','modify_object'}:
            if scene.get('target_kind') in {'object','wall'}:
                raise ValueError('target is not on the current floor; select its floor first')
            return None  # lights/text etc remain movable
        raise ValueError('id is not an object on the current floor')
    local = scene.get('asset',{}).get('local_polygon')
    if local is None:
        if src is None:
            raise ValueError('could not determine asset footprint; placement refused')
        local = src['local_polygon']
    position = list(src['position']) if src else [v/2 for v in scene['dimensions']]
    if ('x' in params) != ('y' in params):
        raise ValueError('supply both x and y')
    if 'x' in params:
        position = [number(params['x']),number(params['y'])]
    if cmd == 'duplicate_object':
        position = [position[0]+number(params.get('dx',64)),position[1]+number(params.get('dy',0))]
    scale = list(src['scale']) if src else [1,1]
    if 'scale' in params:
        v = number(params['scale'],'scale')
        if v <= 0:
            raise ValueError('scale must be positive')
        scale=[v,v]
    rotation = params.get('rotation', src['rotation'] if src else 0)
    if 'mirror' in params:
        # Native Mirror operates on the sprite, not on the prop transform.
        old_mirror = bool(src.get('mirror',False)) if src else False
        if bool(params['mirror']) != old_mirror:
            local=[[-p[0],p[1]] for p in local]
    if scene.get('asset') and src and src.get('mirror',False):
        local=[[-p[0],p[1]] for p in local]
    if scene.get('asset',{}).get('empty',False):
        raise ValueError('image is entirely transparent; footprint is empty')
    parent = src.get('parent_transform') if src else scene.get('object_parent_transform')
    poly = transform(points(local),position,scale,rotation,parent)
    return {'id':src['id'] if src and cmd != 'duplicate_object' else None,
            'source_id':src['id'] if src else None, 'polygon':poly,
            'region':src.get('region','') if src else '',
            'asset':params.get('asset',src.get('asset','') if src else 'embedded image')}


def check_polygon(scene, candidate, params, ignore_id=None):
    poly=candidate['polygon']
    out=[]
    w,h=scene['dimensions']
    if any(x < -EPS or y < -EPS or x > w+EPS or y > h+EPS for x,y in poly):
        out.append(finding('outside_map','Object footprint extends beyond the map'))
    wall_margin=nonnegative(params,'wall_clearance',0)
    door_depth=nonnegative(params,'door_clearance',128)
    for wall in scene['walls']:
        route=points(wall['points'],2)
        radius=wall['half_width']+wall_margin
        if any(polygon_segment(poly,a,b) <= radius+EPS for a,b in edges(route,wall['loop'])):
            out.append(finding('wall_intersection','Footprint intersects the wall envelope',wall_id=wall['id']))
    if door_depth:
        for door in scene['portals']:
            if door.get('window',False):
                continue
            x,y=door['position']; tx,ty=door['tangent']; radius=door['radius']
            nx,ny=-ty,tx
            zone=[(x+tx*a+nx*b,y+ty*a+ny*b) for a,b in
                  [(-radius,-door_depth),(radius,-door_depth),(radius,door_depth),(-radius,door_depth)]]
            if near(poly,zone):
                out.append(finding('door_clearance','Footprint obstructs a doorway approach',portal_id=door['id']))
    if not params.get('allow_overlap',False):
        margin=nonnegative(params,'object_clearance',0)
        for obj in scene['objects']:
            if obj['id'] == ignore_id:
                continue
            if near(poly,points(obj['polygon']),margin):
                out.append(finding('object_overlap','Footprints overlap or have insufficient clearance',object_id=obj['id']))
    wanted=params.get('region','') or candidate.get('region','')
    regions=scene.get('regions',[])
    if wanted:
        region=next((r for r in regions if r['name']==wanted and r['kind']=='room'),None)
        if region is None:
            raise ValueError('region must name a registered room on this floor')
        if not contains_polygon(points(region['points']),poly):
            out.append(finding('outside_room','Entire footprint must fit within the room',region=wanted))
    for region in regions:
        if region['kind']=='clearance' and near(poly,points(region['points'])):
            out.append(finding('reserved_clearance','Footprint occupies reserved walking space',region=region['name']))
    return out


def check_mutation(scene, cmd, params):
    errors=[]; candidate=None
    moving_wall=cmd in {'move_element','modify_object'} and any(w['id']==params.get('id') for w in scene['walls'])
    if cmd in OBJECT_COMMANDS and not moving_wall:
        candidate=object_candidate(scene,cmd,params)
        if candidate:
            errors=check_polygon(scene,candidate,params,ignore_id=candidate['id'])
            if scene.get('unsupported_objects') and not params.get('allow_overlap',False):
                errors.append(finding('unknown_footprint','Existing object footprints could not be read',ids=scene['unsupported_objects']))
    elif cmd in WALL_COMMANDS or moving_wall:
        src=next((w for w in scene['walls'] if w['id']==params.get('id')),None)
        route=rect_polygon(params['rect']) if 'rect' in params else points(params.get('points',src['points'] if src else []),2)
        if cmd=='modify_wall' and src:
            route=transform(points(params.get('points',src['local_points']),2),src['position'],src['scale'],src['rotation'],src.get('parent_transform'))
        if moving_wall:
            scale=src.get('scale',[1,1])
            if 'scale' in params:
                v=number(params['scale'],'scale')
                if v<=0: raise ValueError('scale must be positive')
                scale=[v,v]
            position=[number(params.get('x',src['position'][0])),number(params.get('y',src['position'][1]))]
            route=transform(points(src['local_points'],2),position,scale,params.get('rotation',src['rotation']),src.get('parent_transform'))
        loop=params.get('loop',src['loop'] if src else cmd=='build_room')
        radius=scene.get('asset',{}).get('half_width',src['half_width'] if src else scene.get('default_wall_half_width',32))
        if src and scene.get('asset'):
            radius*=max(abs(v) for v in src['scale'])
        if moving_wall and 'scale' in params:
            radius=radius*params['scale']/max(abs(v) for v in src['scale'])
        for obj in scene['objects']:
            poly=points(obj['polygon'])
            if any(polygon_segment(poly,a,b) <= radius+EPS for a,b in edges(route,loop)):
                errors.append(finding('wall_intersection','Proposed wall intersects an existing object',object_id=obj['id']))
    elif cmd in AREA_COMMANDS:
        protected=[r for r in scene.get('regions',[]) if r['kind']=='protected']
        if protected:
            if cmd=='dig_cave' and any(params.get(k) for k in ('ground_color','wall_color','texture')):
                errors.extend(finding('protected_cave_style','Changing cave styling affects the entire cave layer',region=r['name']) for r in protected)
            # Setting a terrain slot's texture changes every existing pixel that
            # uses that slot, even when the new stroke is far from a building.
            if params.get('asset') and cmd in {'fill_region','paint_terrain','paint_path'}:
                errors.extend(finding('protected_terrain_slot','Changing a terrain slot texture can affect the protected region',region=r['name']) for r in protected)
            if cmd=='draw_path' and params.get('smoothness',0):
                return {'safe':False,'errors':[finding('unmodeled_path_smoothing','Smoothed path envelope is not modeled near protected regions; use an unsmoothed route or an explicit override')],
                        'footprint':None,'stamp':scene['stamp'],'floor_id':scene['floor_id']}
            if cmd in {'fill_terrain','clear_caves','set_terrain_slot'}:
                errors=[finding('protected_region','Whole-floor edit affects a protected region',region=r['name']) for r in protected]
            elif cmd in {'paint_terrain','paint_path','dig_cave','draw_path'}:
                radius=(scene.get('asset',{}).get('half_width',32)*nonnegative(params,'width',1) if cmd=='draw_path'
                        else nonnegative(params,'radius',64 if cmd=='paint_terrain' else 96 if cmd=='paint_path' else 256))
                if cmd in {'paint_terrain','paint_path'}:
                    radius+=scene.get('terrain_raster_padding',0)
                elif cmd=='dig_cave':
                    # Rounded cell centers/radii and filled cells reach beyond
                    # the ideal circle; keep the protection conservative.
                    radius+=2*scene.get('cave_cell_size',0)
                route=points(params.get('points',[[params.get('x',scene['dimensions'][0]/2),params.get('y',scene['dimensions'][1]/2)]]),1)
                for r in protected:
                    poly=points(r['points'])
                    distance=(min(point_segment(route[0],a,b) for a,b in edges(poly)) if len(route)==1
                              else min(polygon_segment(poly,a,b) for a,b in edges(route,False)))
                    if inside(route[0],poly) or distance <= radius+EPS:
                        errors.append(finding('protected_region','Brush footprint reaches a protected region',region=r['name']))
            else:
                poly=rect_polygon(params['rect']) if 'rect' in params else simple_polygon(params['points'])
                errors.extend(finding('protected_region','Edit shape intersects a protected region',region=r['name'])
                              for r in protected if near(poly,points(r['points']),scene.get('terrain_raster_padding',0) if cmd=='fill_region' else 0))
    return {'safe':not errors, 'errors':errors, 'footprint':candidate['polygon'] if candidate else None,
            'stamp':scene['stamp'], 'floor_id':scene['floor_id'],
            'model':'alpha-trimmed rotated rectangles; conservative wall/door envelopes'}


def audit_scene(scene, limit=200, include_object_overlaps=True, door_clearance=128):
    findings=[]; total=0; counts=Counter()
    for ident in scene.get('unsupported_objects',[]):
        total+=1; counts['unknown_footprint']+=1
        if len(findings)<limit:
            findings.append(finding('unknown_footprint','Cannot read this object footprint',id=ident,severity='error'))
    for obj in scene['objects']:
        params={'allow_overlap':True,'door_clearance':door_clearance}
        found=check_polygon(scene,obj,params,ignore_id=obj['id'])
        for f in found:
            total+=1; counts[f['code']]+=1
            if len(findings)<limit:
                findings.append({**f,'id':obj['id'],'asset':obj['asset'],'footprint':obj['polygon'],'severity':'error'})
    if include_object_overlaps:
        for i,a in enumerate(scene['objects']):
            for b in scene['objects'][i+1:]:
                if near(points(a['polygon']),points(b['polygon'])):
                    total+=1; counts['object_overlap']+=1
                    if len(findings)<limit:
                        findings.append(finding('object_overlap','Review overlap: it may be intentional decoration or canopy',
                                                ids=[a['id'],b['id']],severity='warning'))
    return {'safe':not any(k!='object_overlap' and v for k,v in counts.items()),
            'objects_checked':len(scene['objects']),'walls_checked':len(scene['walls']),
            'floor_id':scene['floor_id'],'regions':scene.get('regions',[]),
            'total_findings':total,'counts':dict(counts),'findings':findings,'truncated':total>len(findings),
            'model':'Conservative 2D envelopes. Visual review is still required.'}


def register(mcp, bridge):
    @mcp.tool()
    def get_asset_footprint(asset: str) -> dict:
        """Read an Objects asset's visible bounds BEFORE deciding furniture scale.

        Returns unscaled dimensions and centered alpha-trimmed local footprint.
        256 world pixels = one tile. Transparent padding is excluded.
        """
        return bridge.request('spatial_snapshot',asset=asset,asset_category='Objects')['asset']

    @mcp.tool()
    def check_object_placement(asset: str, x: float, y: float, scale: float = 1,
                               rotation: float = 0, allow_overlap: bool = False,
                               wall_clearance: float = 0, door_clearance: float = 128,
                               object_clearance: float = 0, region: str = '') -> dict:
        """Preview a placement WITHOUT editing. Checks rotated asset extent, walls,
        doorway approaches, existing objects, map bounds and named room/clearance zones.
        allow_overlap permits decoration/canopies but still checks walls and doors.
        A successful preview is not a reservation; mutations always check again.
        """
        params={k:v for k,v in locals().items() if k!='bridge'}
        scene=bridge.request('spatial_snapshot',asset=asset,asset_category='Objects')
        return check_mutation(scene,'place_object',params)

    @mcp.tool()
    def validate_layout(limit: int = 200, include_object_overlaps: bool = True,
                         door_clearance: float = 128) -> dict:
        """Audit the CURRENT floor for objects crossing walls, blocking doors, leaving
        the map or entering reserved corridors. Object overlaps are review warnings:
        tabletop decor and tree canopies may intentionally overlap. Returns element IDs
        and footprints to inspect/move. Counts cover the whole floor even if truncated.
        This does not judge art, furniture semantics, true 3D height, or cave/water shapes.
        """
        if not 1 <= limit <= 2000:
            raise ValueError('limit must be 1..2000')
        nonnegative({'door_clearance':door_clearance},'door_clearance',128)
        return audit_scene(bridge.request('spatial_snapshot'),limit,include_object_overlaps,door_clearance)

    @mcp.tool()
    def set_spatial_region(name: str, points: list[list[float]], kind: str = 'clearance') -> dict:
        """Register a simple world-pixel polygon on the CURRENT floor.

        kind=clearance: reserve a corridor/door approach, forbid objects.
        kind=room: place_object(region=name) must fit its entire footprint inside.
        kind=protected: forbid terrain/cave/water/material edits touching the polygon.
        Reusing a name replaces it. Regions last for this open map session (including
        MCP reconnects), not a saved-map reopen; reapply after open_document.
        """
        if not name.strip() or len(name)>100 or kind not in {'clearance','room','protected'}:
            raise ValueError('nonempty name (max 100 chars) and a valid kind required')
        poly=simple_polygon(points)
        return bridge.request('set_spatial_region',name=name,points=poly,kind=kind)

    @mcp.tool()
    def remove_spatial_region(name: str) -> dict:
        """Remove a room, corridor or terrain-protection zone from the current floor."""
        return bridge.request('remove_spatial_region',name=name)
