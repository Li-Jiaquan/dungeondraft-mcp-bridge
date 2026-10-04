"""Extended native Dungeondraft tools; all coordinates are world pixels (256/tile)."""
from __future__ import annotations
import os
import json
import random
import time
import tempfile
import shutil
import math
from pathlib import Path
from typing import Any
from PIL import Image

from .bridge_client import BridgeError
from .vtt import build_universal_vtt


def register(mcp, bridge):
    @mcp.tool()
    def ui_tree(target: str = 'Editor', search: str = '', limit: int = 500) -> dict:
        """Inspect native application controls for features without a public drawing API.

        Use Tool:TerrainBrush, Tool:Generator, Window:New, Window:ChangeMapSize,
        Window:MakePrefab, Window:PackageAssets etc. Returns live control handles,
        button text, option lists, values and visibility. Handles expire on map/mod reload.
        """
        if not 1 <= limit <= 1500: raise ValueError('limit must be 1..1500')
        return bridge.request('ui_tree', target=target, search=search, limit=limit)

    @mcp.tool()
    def ui_action(target: str, action: str, value: Any = None) -> dict:
        """Operate a control discovered with ui_tree. Actions: press, check, value, text,
        submit, select (option index), color (#rrggbb), show, hide.

        Discover first. Setting values emits native change signals so the application's
        own tools update. Pressing destructive buttons has the same effect as the UI.
        Save your map before resizing, regeneration or deleting floors. Native dialogs
        may still need desktop interaction. No bridge undo is promised.
        """
        return bridge.request('ui_action', target=target, action=action, value=value)

    @mcp.tool()
    def get_capabilities() -> dict:
        """Discover the installed bridge, native API targets and elevation limits."""
        return bridge.request('capabilities')

    @mcp.tool()
    def native_targets() -> dict:
        """List live native tools, windows and map components (including version-specific tools)."""
        return bridge.request('native_targets')

    @mcp.tool()
    def native_describe(target: str, search: str = '') -> dict:
        """Inspect public methods/signatures/properties BEFORE using the native API.

        Targets: World, Editor, Exporter, Level.Terrain, Level.WaterMesh,
        Tool:ObjectTool, Tool:Generator, Window:PackageAssets, Element:123,
        or a $target handle returned by another call. Exact names vary by build.
        Godot types: 1 bool, 2 int, 3 float, 4 string, 5 Vector2, 14 Color,
        17 Object, 18 Dictionary, 19 Array, 24 PoolVector2Array.
        """
        return bridge.request('native_describe', target=target, search=search)

    @mcp.tool()
    def native_get(target: str, properties: list[str]) -> dict:
        """Read advertised native properties. Values retain tagged Godot types."""
        return bridge.request('native_get', target=target, properties=properties)

    @mcp.tool()
    def native_set(target: str, property: str, value: Any) -> dict:
        """Set a native property AFTER checking native_describe and the API documentation.

        Prefer a documented setter method where available; some properties are read-only.
        Tagged values: {$type:Vector2,value:[x,y]}, {$type:Color,value:'#rrggbb'},
        {$target:'Element:123'}, {$type:Texture,category:'Terrain',asset:'res://...'}.
        This low-level operation is not recorded in the bridge undo stack.
        """
        return bridge.request('native_set', target=target, property=property, value=value)

    @mcp.tool()
    def native_call(target: str, method: str, args: list[Any] | None = None) -> dict:
        """Call a discovered public Dungeondraft operation with validated argument types.

        Inspect native_describe first; supply every advertised argument including C#
        defaults. Typed values: {$type:Vector2,value:[x,y]}, {$type:Rect2,value:[x,y,w,h]},
        {$type:Color,value:'#rrggbb'}, {$type:Vector2Array,value:[[x,y],...]},
        {$type:StringArray,value:['a','b']}, {$target:'Level'},
        {$type:Texture,category:'Objects',asset:'res://...'}, {$type:Image,path:'C:/...png'}.
        Native calls are not automatically undoable. Save a copy before complex edits.
        Returns resource handles usable as later targets/arguments. Never call internal
        lifecycle methods (PostInit, Start, Resize) unless documented as user operations.
        """
        return bridge.request('native_call', target=target, method=method, args=args or [])

    @mcp.tool()
    def import_image(path: str, x: float | None = None, y: float | None = None,
                     scale: float = 1, rotation: float = 0, layer: int = 100,
                     shadow: bool = False, spatial_check: bool = True,
                     allow_overlap: bool = False, region: str = '') -> dict:
        """Embed a local PNG into the map as an editable prop, including generated images.

        Preserves transparency. File is embedded so a saved map does not depend on the
        original path. 256 image pixels equal one tile at scale=1. Whole-map images
        remain one prop, without automatic conversion to walls/terrain.
        Spatial checks default on. Use spatial_check=False deliberately for a
        whole-map background or decorative overlay; ordinary props should be checked.
        """
        p = Path(path).expanduser().resolve(strict=True)
        if p.suffix.lower() != '.png' or scale <= 0:
            raise ValueError('A PNG file and positive scale are required')
        with Image.open(p) as img:
            if img.format != 'PNG' or max(img.size)>16384: raise ValueError('PNG dimensions must be at most 16384 pixels')
            img.load()
        params = dict(path=p.as_posix(), scale=scale, rotation=rotation, layer=layer, shadow=shadow)
        params.update(spatial_check=spatial_check,allow_overlap=allow_overlap,region=region)
        if (x is None) != (y is None): raise ValueError('Supply both x and y')
        if x is not None: params.update(x=x, y=y)
        # Native EmbedObject caches by filename. A unique temporary path prevents
        # importing stale pixels after the user edits a PNG at the same path.
        with tempfile.NamedTemporaryFile(prefix='dd-mcp-',suffix='.png',delete=False) as tmp:
            temporary = Path(tmp.name)
        try:
            shutil.copyfile(p,temporary)
            params['path'] = temporary.as_posix()
            result = bridge.request('import_image', **params)
            result['source'] = p.as_posix()
            return result
        finally:
            temporary.unlink(missing_ok=True)

    @mcp.tool()
    def save_map(path: str = '', update_current: bool = True) -> dict:
        """Save ALL live levels, terrain, water, lights and embedded images to .dungeondraft_map.

        Empty path saves to the current file. Existing destinations receive a
        .mcp-backup before replacement. update_current=False saves a separate copy.
        """
        if path:
            p = Path(path).expanduser().resolve()
            p.parent.mkdir(parents=True, exist_ok=True)
            path = p.as_posix()
        params = {'update_current': update_current}
        if path: params['path'] = path
        if not path:
            path = bridge.request('native_get',target='Editor',properties=['CurrentMapFile'])['CurrentMapFile']
            if not path: raise ValueError('The current map has no filename; supply path')
        p = Path(path)
        previous = p.stat().st_mtime_ns if p.exists() else None
        result = bridge.request('save_document', **params)
        deadline = time.monotonic()+120
        last = None
        stable = 0
        while time.monotonic()<deadline:
            state = (p.stat().st_mtime_ns,p.stat().st_size) if p.exists() else None
            stable = stable+1 if state and state[0]!=previous and state[1]>0 and state==last else 0
            if stable>=3:
                result.update(completed=True,bytes=state[1])
                return result
            last=state
            time.sleep(.3)
        raise BridgeError(f'Native save did not finish at {p}; check the application warning dialog')

    @mcp.tool()
    def open_map(path: str) -> dict:
        """Begin opening an existing map, replacing the current document.

        Save the current map first. Native loading is asynchronous: wait for
        the expected objects/floors to load and confirm the current floor ID
        before following this call with edits, floor switches or exports.
        """
        p = Path(path).expanduser().resolve(strict=True)
        return bridge.request('open_document', path=p.as_posix())

    @mcp.tool()
    def export_to_file(path: str, format: str = 'png', ppi: int = 128, quality: int = 95,
                       grid: bool = False) -> dict:
        """Export to PNG, JPEG, WEBP or Universal VTT, and wait for completion.
        grid controls the visible/exported grid; False produces a clean map render.
        """
        modes = {'png': 0, 'jpeg': 1, 'jpg': 1, 'webp': 2, 'uvtt': 3, 'dd2vtt': 3}
        if format.lower() not in modes: raise ValueError('Unsupported export format')
        if not 8 <= ppi <= 1024 or not 1 <= quality <= 100: raise ValueError('Invalid resolution or quality')
        p = Path(path).expanduser().resolve()
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.exists(): raise ValueError('Choose a new export filename to avoid stale results')
        if modes[format.lower()] == 3:
            # Some Dungeondraft 1.2 builds render the UVTT sidecar PNG but never
            # write the JSON file. Build UVTT 0.3 from a native map snapshot.
            with tempfile.TemporaryDirectory(prefix='dd-mcp-uvtt-') as directory:
                temporary = Path(directory)
                render = temporary / 'render.png'
                snapshot = temporary / 'snapshot.dungeondraft_map'
                bridge.request('export_document', path=render.as_posix(), mode=0,
                               ppi=ppi, quality=quality, grid=grid)
                deadline = time.monotonic() + 120
                previous = -1
                stable = 0
                while time.monotonic() < deadline:
                    size = render.stat().st_size if render.exists() else 0
                    stable = stable + 1 if size > 0 and size == previous else 0
                    if stable >= 3: break
                    previous = size
                    time.sleep(.3)
                else:
                    raise BridgeError('PNG render for Universal VTT timed out')
                current = bridge.request('list_levels')['current_id']
                bridge.request('save_document', path=snapshot.as_posix(), update_current=False)
                document = json.loads(snapshot.read_text(encoding='utf-8'))
                payload = build_universal_vtt(document, current, render.read_bytes(), ppi)
                writing = p.with_suffix(p.suffix + '.writing')
                try:
                    writing.write_text(json.dumps(payload, separators=(',', ':')), encoding='utf-8')
                    writing.replace(p)
                finally:
                    writing.unlink(missing_ok=True)
            return {'path': p.as_posix(), 'mode': 3, 'ppi': ppi, 'grid': grid,
                    'completed': True, 'bytes': p.stat().st_size,
                    'line_of_sight': len(payload['line_of_sight']),
                    'portals': len(payload['portals']), 'lights': len(payload['lights']),
                    'los_coverage': 'walls and portals; cave and object silhouettes omitted'}
        result = bridge.request('export_document', path=p.as_posix(), mode=modes[format.lower()], ppi=ppi, quality=quality,grid=grid)
        deadline = time.monotonic() + 120
        last = -1
        stable = 0
        while time.monotonic() < deadline:
            size = p.stat().st_size if p.exists() else 0
            stable = stable + 1 if size > 0 and size == last else 0
            if stable >= 3:
                result.update(completed=True, bytes=size)
                return result
            last = size
            time.sleep(.3)
        raise BridgeError(f'Export timed out; pending output retained at {p}')

    @mcp.tool()
    def configure_terrain(expanded: bool | None = None, smooth: bool | None = None,
                          enabled: bool | None = None) -> dict:
        """Inspect/configure terrain visibility, smooth blending, and 4 versus 8 texture slots."""
        return bridge.request('configure_terrain', **{k:v for k,v in locals().items() if v is not None and k != 'bridge'})

    @mcp.tool()
    def configure_environment(ambient: str | None = None, lighting: bool | None = None,
                              grid: bool | None = None, grid_color: str | None = None,
                              grid_style: int | None = None, camera_filter: int | None = None,
                              building_wear: int | None = None) -> dict:
        """Set ambient light, baked lighting, grid color/style, camera filter and building wear.

        Colors use #rrggbb/#rrggbbaa. Camera filter: 0 off, 1 sepia, 2 vignette.
        Omit all arguments to inspect the current lighting environment.
        """
        if camera_filter is not None and camera_filter not in (0,1,2): raise ValueError('Invalid camera filter')
        params = {k:v for k,v in locals().items() if v is not None and k not in ('bridge','params')}
        return bridge.request('configure_environment', **params)

    @mcp.tool()
    def modify_light(id: int, color: str | None = None, energy: float | None = None,
                     range: float | None = None, shadows: bool | None = None,
                     enabled: bool | None = None, rotation: float | None = None,
                     asset: str | None = None) -> dict:
        """Edit a light's color, brightness, texture scale, shadows or enabled state.

        range is a dimensionless texture scale (usually 1-3), NOT a radius in
        world pixels. Its visible extent depends on the chosen Lights texture.
        """
        if energy is not None and energy < 0 or range is not None and range <= 0: raise ValueError('Invalid brightness or radius')
        return bridge.request('modify_light', **{k:v for k,v in locals().items() if v is not None and k != 'bridge'})

    @mcp.tool()
    def list_layers() -> dict:
        """List draw layers and locked built-in layers on the current floor."""
        return bridge.request('list_layers')

    @mcp.tool()
    def set_layer(index: int, label: str) -> dict:
        """Create a drawing layer. Larger index draws above lower indexes; -4096..4096.
        Existing indexes are rejected; inspect list_layers first.
        """
        return bridge.request('set_layer', index=index, label=label)

    @mcp.tool()
    def set_element_layer(id: int, layer: int) -> dict:
        """Move an existing object/path/light to an available drawing layer."""
        return bridge.request('set_element_layer', id=id, layer=layer)

    @mcp.tool()
    def configure_object(id: int, mirror: bool | None = None, block_light: bool | None = None,
                         layer: int | None = None, asset: str | None = None,
                         spatial_check: bool = True, allow_overlap: bool = False) -> dict:
        """Set object mirroring, lighting occlusion, draw layer and texture."""
        return bridge.request('configure_object', **{k:v for k,v in locals().items() if v is not None and k != 'bridge'})

    @mcp.tool()
    def draw_water(points: list[list[float]] | None = None, rect: list[float] | None = None,
                   erase: bool = False, spatial_check: bool = True) -> dict:
        """Draw/erase a lake or river polygon/rectangle with native shore borders."""
        _shape(points, rect)
        return bridge.request('draw_water', **{k:v for k,v in locals().items() if v is not None and k != 'bridge'})

    @mcp.tool()
    def configure_water(deep_color: str | None = None, shallow_color: str | None = None,
                        blend_distance: float | None = None, border: bool | None = None) -> dict:
        """Set future water brush colors/blend distance, and level-wide shoreline visibility.
        Existing water polygons retain their individual colors.
        """
        if blend_distance is not None and blend_distance <= 0: raise ValueError('Positive blend distance required')
        return bridge.request('configure_water', **{k:v for k,v in locals().items() if v is not None and k != 'bridge'})

    @mcp.tool()
    def draw_material(asset: str, points: list[list[float]] | None = None,
                      rect: list[float] | None = None, layer: int = 100,
                      smooth: bool = True, erase: bool = False, spatial_check: bool = True) -> dict:
        """Draw/erase a native material polygon, with its styled border, on a drawing layer."""
        _shape(points, rect)
        return bridge.request('draw_material', **{k:v for k,v in locals().items() if v is not None and k != 'bridge'})

    @mcp.tool()
    def modify_text(id: int, text: str | None = None, font: str | None = None,
                    size: int | None = None, color: str | None = None) -> dict:
        """Change an existing label's text, font, size or color."""
        return bridge.request('modify_text', **{k:v for k,v in locals().items() if v is not None and k != 'bridge'})

    @mcp.tool()
    def modify_wall(id: int, asset: str | None = None, color: str | None = None,
                    shadow: bool | None = None, points: list[list[float]] | None = None,
                    loop: bool | None = None, type: int | None = None, joint: int | None = None,
                    spatial_check: bool = True) -> dict:
        """Change an existing wall's texture, tint, shadow or geometry."""
        return bridge.request('modify_wall', **{k:v for k,v in locals().items() if v is not None and k != 'bridge'})

    @mcp.tool()
    def set_trace_image(path: str = '', scale: float = 1, opacity: float = .5,
                        center: bool = True, visible: bool = True) -> dict:
        """Set a reference image for tracing; empty path clears it. Use import_image for exported art."""
        if path: path = Path(path).expanduser().resolve(strict=True).as_posix()
        if scale <= 0 or not 0 <= opacity <= 1: raise ValueError('Invalid scale or opacity')
        return bridge.request('set_trace_image', path=path, scale=scale, opacity=opacity, center=center, visible=visible)

    @mcp.tool()
    def rename_level(index: int, label: str) -> dict:
        """Rename a floor by its list_levels index."""
        return bridge.request('rename_level', index=index, label=label)

    @mcp.tool()
    def clone_level(index: int, label: str = 'Copy') -> dict:
        """Duplicate a complete floor, including its drawings and lighting."""
        return bridge.request('clone_level', index=index, label=label)

    @mcp.tool()
    def reorder_levels(ids: list[int]) -> dict:
        """Change vertical floor order; include every level id exactly once."""
        return bridge.request('reorder_levels', ids=ids)

    @mcp.tool()
    def compare_levels(index: int = -1, reference_opacity: float = .35,
                       current_opacity: float = 1) -> dict:
        """Overlay another floor for alignment. index=-1 disables comparison."""
        if not 0 <= reference_opacity <= 1 or not 0 <= current_opacity <= 1: raise ValueError('Invalid opacity')
        return bridge.request('compare_levels', index=index, reference_opacity=reference_opacity, current_opacity=current_opacity)

    @mcp.tool()
    def batch_commands(commands: list[dict[str, Any]], stop_on_error: bool = True) -> dict:
        """Run ordered bridge commands; report partial completion. This is NOT an atomic transaction.

        Each entry has cmd plus its parameters. Nested batches are not allowed.
        Use separate undo/save checkpoints when an all-or-nothing edit is needed.
        """
        if not 1 <= len(commands) <= 200: raise ValueError('Batch size must be 1..200')
        results = []
        for index, entry in enumerate(commands):
            params = dict(entry)
            cmd = params.pop('cmd', '')
            if not cmd or cmd == 'batch_commands': raise ValueError('Invalid batch command')
            try: results.append({'index':index, 'ok':True, 'result':bridge.request(cmd, **params)})
            except BridgeError as error:
                results.append({'index':index, 'ok':False, 'error':str(error)})
                if stop_on_error: break
        return {'results':results, 'completed':len(results), 'requested':len(commands), 'atomic':False}

    @mcp.tool()
    def draw_elevation(points: list[list[float]], cliff_asset: str,
                       terrain_asset: str = '', slot: int = 1,
                       layer: int = 100, width: float = 1, spatial_check: bool = True) -> dict:
        """Draw a raised plateau: a terrain-filled polygon plus a CLOSED cliff path.

        cliff_asset must be a loaded Paths asset chosen with list_assets; width controls
        the drawn cliff width. This is a 2D visual height effect, not a 3D heightmap.
        """
        _shape(points, None)
        if width <= 0 or not 0 <= slot <= 7: raise ValueError('Positive cliff width and slot 0..7 required')
        if str(layer) not in bridge.request('list_layers')['layers']: raise ValueError('Unknown drawing layer')
        terrain = bridge.request('configure_terrain')
        if terrain_asset and slot >= 4 and not terrain['expanded']: raise ValueError('Enable expanded terrain slots first')
        # Validate assets BEFORE painting so a missing cliff does not leave partial terrain.
        assets = bridge.request('list_assets', category='Paths', search=cliff_asset, limit=1)['assets']
        if cliff_asset not in assets: raise ValueError('cliff_asset must be an available Paths asset')
        route = points if points[0] == points[-1] else [*points, points[0]]
        # A cliff's width can reach a protected region even when its fill does not.
        # Preflight both pieces before any terrain is changed; each edit also
        # rechecks immediately before committing. This is not an atomic transaction.
        if spatial_check:
            bridge.preflight('draw_path', points=route, asset=cliff_asset, width=width, smoothness=0)
            if terrain_asset:
                bridge.preflight('fill_region', points=points, slot=slot, asset=terrain_asset)
        result = {}
        if terrain_asset:
            available = bridge.request('list_assets', category='Terrain', search=terrain_asset, limit=1)['assets']
            if terrain_asset not in available: raise ValueError('Terrain asset unavailable')
            result['terrain'] = bridge.request('fill_region', points=points, slot=slot, asset=terrain_asset, spatial_check=spatial_check)
        result['cliff'] = bridge.request('draw_path', points=route, asset=cliff_asset, layer=layer, width=width, smoothness=0, spatial_check=spatial_check)
        result['native_3d_heightmap'] = False
        return result

    @mcp.tool()
    def scatter_objects(asset: str, rect: list[float], count: int = 20,
                         seed: int = 0, min_scale: float = .8, max_scale: float = 1.2,
                         layer: int = 100, allow_overlap: bool = False,
                         spatial_check: bool = True, region: str = '') -> dict:
        """Place deterministic random props in a rectangular region (vegetation/debris).

        Blocked candidates are resampled up to count*20 attempts. Returns every created
        id and skipped count, including partial failure. allow_overlap permits canopies.
        Individual placements are undoable. No furniture is forced into occupied space.
        """
        _shape(None, rect)
        if not 1 <= count <= 200 or not 0 < min_scale <= max_scale: raise ValueError('Invalid scatter settings')
        rng = random.Random(seed)
        ids=[]
        layers = bridge.request('list_layers')['layers']
        if str(layer) not in layers: raise ValueError('Unknown layer')
        if asset not in bridge.request('list_assets', category='Objects', search=asset, limit=1)['assets']:
            raise ValueError('Object asset unavailable')
        error = None
        skipped=0
        attempts=0
        for _ in range(count*20):
            if len(ids)>=count: break
            attempts+=1
            try:
                made = bridge.request('place_object', asset=asset, x=rect[0]+rng.random()*rect[2],
                                      y=rect[1]+rng.random()*rect[3], rotation=rng.uniform(0,360),
                                      scale=rng.uniform(min_scale,max_scale),spatial_check=spatial_check,
                                      allow_overlap=allow_overlap,region=region)
                ids.append(made['id'])
                bridge.request('set_element_layer', id=made['id'], layer=layer)
            except BridgeError as exc:
                if exc.details is not None:
                    skipped+=1
                    continue
                error = str(exc)
                break
        if len(ids)<count and error is None: error='Insufficient clear space within the attempt budget'
        return {'ids':ids,'seed':seed,'completed':len(ids),'requested':count,'error':error,
                'attempts':attempts,'skipped_collisions':skipped}


def _shape(points, rect):
    if (points is None) == (rect is None): raise ValueError('Supply exactly one of points or rect')
    if rect is not None and (len(rect) != 4 or rect[2] <= 0 or rect[3] <= 0): raise ValueError('Invalid rectangle')
    if points is not None and (len(points) < 3 or any(len(p)!=2 for p in points)): raise ValueError('At least three [x,y] points required')
    coordinates = rect if rect is not None else [v for point in points for v in point]
    if any(not math.isfinite(float(v)) for v in coordinates): raise ValueError('Coordinates must be finite')
