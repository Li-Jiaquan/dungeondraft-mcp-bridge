# dungeondraft-mcp

English · [简体中文](README.zh-CN.md)

This project extends [Brandon Florian's dungeondraft-mcp](https://github.com/brann-dev/dungeondraft-mcp). Its MIT license and original copyright notice remain in [LICENSE](LICENSE).

An MCP server that lets an LLM (Claude Code, Claude Desktop, etc.) drive a
**running Dungeondraft instance** — place objects, draw walls, inspect the map —
through Dungeondraft's GDScript modding API.

Dungeondraft has no built-in server to talk to, so this project is **two halves**
that meet over a localhost socket:

```
Claude / MCP client
      │  MCP (stdio)
      ▼
server/   ── Python MCP server  (this repo)
      │  newline-delimited JSON over TCP  (127.0.0.1:8787)
      ▼
mod/      ── Dungeondraft mod  (GDScript, runs inside DD)
      │  modding API calls
      ▼
   the open map  (Objects, Walls, Levels, …)
```

The mod opens a TCP server inside Dungeondraft and polls it every frame from the
`update(delta)` hook; the Python side exposes each capability as an MCP tool and
forwards calls as JSON. See [PROTOCOL.md](PROTOCOL.md) for the wire format.

> **Status: working.** Confirmed end-to-end against Dungeondraft on **Godot
> 3.4.2** — raw TCP from the modding sandbox works. Version 0.3 exposes 76 tools
> across query / create / modify / terrain / levels / selection / capture /
> camera / undo (see below).

## Version 0.3: spatial validation

Furniture edits now check the **whole rotated footprint** before changing the map.
The checks cover walls (including their thickness), doorway approaches, other
objects, map boundaries, named rooms and reserved corridors. Drawing a wall
through existing furniture is also refused. Placement, PNG import, movement,
rotation, scale, duplication and texture/mirror changes use the same guard.

Five tools help plan and review a layout:

| Tool | Purpose |
| --- | --- |
| `get_asset_footprint` | Read actual asset dimensions and visible bounds before choosing scale. |
| `check_object_placement` | Preview a placement without editing. |
| `validate_layout` | Audit the current floor and return conflicting element IDs. |
| `set_spatial_region` | Register a `room`, `clearance` corridor, or `protected` terrain zone. |
| `remove_spatial_region` | Remove a registered zone. |

Use world pixels (256 per tile). Define room polygons **inside** the walls and
pass `region="tavern"` when placing its furniture; the entire footprint must fit.
Reserve circulation with `kind="clearance"`. Mark finished buildings or banks
with `kind="protected"` before painting terrain, caves, water, materials or
paths. Brush radius, cliff width and raster rounding count toward protection.
Whole-floor fills and terrain slot texture replacements are refused while a
protected zone exists because they can change previously painted areas too.

```python
set_spatial_region(name="tavern", kind="room",
                   points=[[1000,1000],[2500,1000],[2500,2000],[1000,2000]])
get_asset_footprint(asset="<Objects asset from list_assets>")
check_object_placement(asset="<Objects asset>", x=1700, y=1500,
                       scale=0.5, region="tavern")
place_object(asset="<Objects asset>", x=1700, y=1500,
             scale=0.5, region="tavern")
validate_layout()
```

`allow_overlap=True` permits intentional object stacking (tabletop decoration,
tree canopies), while still checking walls, doors and zones. `spatial_check=False`
is an explicit override for exceptional art placements such as a wall ornament
or a whole-map image; it must not be an automatic retry after a rejection.
Scatter resamples blocked positions instead of forcing them into occupied space.
Composite plateau tools preflight the cliff and fill before painting; these and
batches remain non-atomic if another operation or native failure interrupts them.

Checks use alpha-trimmed, rotated rectangles; unreadable alpha falls back to the
full texture bounds. Irregular silhouettes and U-shaped furniture can therefore
produce conservative false positives. Doors are recognized by asset names;
custom windows may need an explicit clearance choice. This is a 2D layout guard,
not an art judge, navigation solver or 3D physics/light simulator. Existing
cave/water topology, moved paths/materials, roofs and native/UI/undo operations
are not automatically validated. Terrain protection requires explicit zones.
Water/material decorative borders and smoothing are not measured; enlarge
protected zones to leave a visual buffer. Cave style changes are floor-wide.

Regions and room assignments belong to the **current floor of the open map
session**, survive MCP reconnects, and must be reapplied after reopening a saved
map. Every guarded edit takes a fresh snapshot; protocol 18 rejects the mutation
inside Dungeondraft if the geometry changes before commit. Update both halves
and reconnect the MCP client to refresh its tools.

## Version 0.2 additions

The existing drawing tools remain available. New high-level tools cover:

- Local PNG embedding (`import_image`), including transparent generated art. The
  saved map carries the pixels and does not require the original file. Whole-map
  art remains one movable prop; it is not automatically segmented into walls.
- Full native map serialization (`save_map`) and opening existing maps (`open_map`).
  Saves include all floors, terrain, water, materials, lights, embedded textures,
  native header/editor state and the original map's mod metadata. Existing output
  files receive `.mcp-backup`. Save paths must be absolute.
- 4/8 terrain slots, smooth blending, visibility, and expanded-slot undo/redo.
- Polygon water/material drawing, ambient lighting, light editing, draw layers,
  object mirroring and light occlusion, text/wall edits and reference images.
  Water color/blend settings affect subsequent brush strokes; existing polygons
  keep their own colors. Shoreline visibility applies to the whole floor.
- Floor renaming, duplication, ordering and comparison overlays.
- Visual cliff/plateau drawing and repeatable random object scattering.
- PNG/JPEG/WEBP/Universal VTT export to named files with completion checks.
  `export_to_file(grid=False)` explicitly hides the grid before rendering;
  `grid=True` includes it. This also changes the editor's grid visibility.
  On Dungeondraft 1.2.0.1, the native Universal VTT worker sometimes writes
  only a temporary PNG. The MCP server builds a valid UVTT 0.3 file from a
  native map snapshot and rendered PNG instead. It includes wall sight lines,
  wall and freestanding portals, environment and lights. Cave boundaries and
  object silhouettes are not included in this fallback's VTT sight lines.

`native_targets`, `native_describe`, `native_get`, `native_set` and `native_call`
provide access to the **installed version's public API**. Inspect method signatures
before calling. Godot vectors/colors/arrays/textures have explicit tagged values;
objects return reusable `$target` handles. Native access has no automatic undo.
Some C# collections are not exposed to GDScript; use Save*/Load* methods or controls
instead of assuming an advertised field is readable.

`ui_tree` and `ui_action` expose Dungeondraft's own controls for functions without
a dedicated drawing wrapper. Inspect controls before selecting an option, changing
a slider or pressing a button. Tool targets return their public control getters;
tools without such getters fall back to the Editor tree. Pressed button signals
are deferred so normal native handlers can run outside the mod update callback.
Native file dialogs may still require desktop interaction. This is an access path
to the application, not a claim that every button and version has been tested.

Elevation has three supported meanings: separate floors, draw order, and visual
cliffs/raised ground. Dungeondraft does not provide a 3D terrain heightmap here.

Lighting uses Dungeondraft's 2D falloff textures and wall occlusion. It supports
plausible local light and shadows, but is not a 3D ray tracer or a strict
inverse-square physical renderer.

Restart/reconnect the MCP server after updating Python code to refresh its tool
list, and reload the mod in Dungeondraft. Handles expire on mod/map reload. The
bridge shares its socket through the scene root and transfers ownership to the
new mod instance, avoiding a stranded listener after opening another map.

Verified on Dungeondraft 1.2.0.1: the original 71 tools, transparent PNG
embedding including temporary-source cleanup, terrain slots 5/undo/redo, ambient
and individual lights, water, materials, floor/layer management, native sliders
and a deferred Cancel button, cliffs/scatter, walls/doors/roofs/caves/text,
three-floor save/reopen and PNG export. Reopened drawing data matches after
ignoring regenerated water reference identifiers and empty material-layer lists.
Native API/UI access does not mean every possible operation has been tested.

Offline regression checks: `python -m unittest discover -s tests -v`.
Version 0.3 passed 30 offline regression tests and 28 live spatial checks on
Dungeondraft 1.2.0.1, with 76 tools discovered through MCP stdio. All five spatial
tools were called through MCP. Rejected prop/wall edits preserved the geometry
snapshot; rejected terrain/cave/water edits also preserved native drawing data.
Tests included stale snapshot refusal, image alpha bounds, texture replacement,
mirroring and duplication, and finished by reopening the original saved map.

## What the AI can do

- **Inspect:** `get_status`, `list_levels`, `list_elements`, `get_element`,
  `list_asset_categories`, `list_assets` (with substring search).
- **Create:** `place_object`, `draw_wall`, `draw_path`, `add_light`,
  `add_portal`, `add_roof`, `add_text`, `place_pattern` (tiled floor shapes —
  wood planks, tile, brick — rendered below objects), `build_room` (a wall loop
  + matching floor on one shared path, like the UI's combined trace).
- **Terrain:** `set_terrain_slot`, `fill_terrain` (whole level), `fill_region`
  (a rect/polygon, e.g. one room's floor), `paint_terrain` (a soft brush),
  `paint_path` (a smooth continuous stroke along a polyline — roads/trails).
- **Caves:** `dig_cave` carves caverns/tunnels along a path (the Cave Brush —
  dig open floor out of rock, with auto rocky walls + debris; `dig=false` fills
  back; optional ground/wall tints), `clear_caves` wipes the whole cave layer.
- **Edit:** `move_element`, `modify_object`, `duplicate_object`,
  `delete_element`, `select_elements`, `clear_selection`.
- **Levels:** `add_level`, `set_level`.
- **See:** `screenshot` (current window) and `export_map` (clean full-map
  render) return images, so the model can look at its own work and iterate.
- **Camera:** `get_camera`, `set_camera`, `focus_element` (center on one
  element), `fit_elements` (frame a group) — point the view before a
  `screenshot` to inspect specific spots like a door cut into a wall.
- **Undo:** the bridge keeps its own undo/redo stacks for create / move / modify
  / terrain edits, so `undo` / `redo` let the model reliably reverse its own
  changes (independent of Dungeondraft's Ctrl+Z; `delete_element` is not
  reversible).

Every element is referenced by an integer `id`; create and list calls return
ids you feed back into edit calls. Coordinates are woxel (pixel) space — call
`get_status` for `map_center`. Discover assets with `list_assets`.

## Setup

**Prerequisites:** [Dungeondraft](https://dungeondraft.net/) (tested on the
Godot 3.4.2 builds), Python **3.10+**, and an MCP client (e.g. Claude Code or
Claude Desktop). On Windows, `python`/`.venv\Scripts\` replace the `python3`/
`.venv/bin/` paths shown below.

### 1. Install the mod into Dungeondraft

1. In Dungeondraft's title screen, open **Mods** and note (or set) your mods
   folder.
2. Copy `mod/dungeondraft-mcp-bridge/` into that folder.
3. Enable **MCP Bridge** in the mod list, then open or create a map.

On load you should see in the Dungeondraft log:

```
[mcp-bridge] ready, protocol 18
```

### 2. Install the MCP server

Install into a dedicated venv (most distros' system Python is externally
managed, so a venv keeps the entrypoint clean and stable). Run from the repo
root:

```bash
python3 -m venv .venv
.venv/bin/pip install -e ./server
```

This installs the `dungeondraft_mcp` package and creates the
`.venv/bin/dungeondraft-mcp` entrypoint.

### 3. Verify the bridge works

With DD open and a map loaded, run the per-command validator. It builds a small
throwaway scene near the map center, prints PASS/FAIL for each command, then
deletes what it made:

```bash
.venv/bin/python server/test_bridge.py
```

If it fails to connect *and* you never saw the `listening` line in DD's log, the
sandbox blocked `TCP_Server` — see the fallback note in PROTOCOL.md.

To *see* something get built (a small furnished room left on the map, rather
than a self-cleaning test), run `.venv/bin/python server/demo_build.py`.

### 4. Wire up your MCP client

Register the entrypoint by its **absolute path**. For **Claude Code**:

```bash
claude mcp add dungeondraft -s user -- "$PWD/.venv/bin/dungeondraft-mcp"
```

Restart Claude Code so the server loads (`/mcp` shows its status and tools).
Or add to a client config (e.g. Claude Desktop `claude_desktop_config.json`),
using the absolute path:

```json
{
  "mcpServers": {
    "dungeondraft": {
      "command": "/abs/path/to/dungeondraft-mcp/.venv/bin/dungeondraft-mcp"
    }
  }
}
```

Then ask the model things like *"what's the status of my Dungeondraft map?"* or
*"list some object assets and drop a chair in the middle of the map."*

## Configuration

These env vars configure the **Python server** (set them where the MCP client
launches it). The defaults match the mod, so you only need them if you change
the mod's `HOST` / `PORT` consts in `mcp_bridge.gd` — both halves must agree.

| Env var | Default | Purpose |
| --- | --- | --- |
| `DD_BRIDGE_HOST` | `127.0.0.1` | host the server connects to |
| `DD_BRIDGE_PORT` | `8787` | port the server connects to (match the mod's `PORT`) |

## Extending

Adding a capability is symmetric — one handler on each side:

1. **Mod** (`mod/.../scripts/tools/mcp_bridge.gd`): add a `case` to the `match`
   in `_safe_dispatch()` and a `_my_command(req)` function returning
   `_ok(...)` / `_err(...)`.
2. **Server** (`server/dungeondraft_mcp/server.py`): add an `@mcp.tool()` that
   calls `bridge.request("my_command", ...)`.

For bulk edits, save a map copy first. `batch_commands` executes sequentially
and reports partial completion; it does not provide atomic rollback.

### Dev loop (read this before iterating on the mod)

Two things will bite you if you don't know them up front:

- **Editing the mod and the server are different reload paths.** GDScript
  changes in `mcp_bridge.gd` take effect when you **reload the mod inside
  Dungeondraft** (or restart DD). New or changed `@mcp.tool()` definitions in
  `server.py` only appear after the **MCP server process restarts** — in Claude
  Code that means `/mcp` → reconnect `dungeondraft` (or restart the client).
  The install is editable (`pip install -e`), so you never reinstall; you just
  cycle the process. Adding a *new tool* needs **both** reloads (mod for the
  handler, server for the tool registration); changing an *existing* handler's
  behavior needs only the mod reload.

- **There's no live `eval`/introspect command**, so probing a running node's
  properties needs a mod reload. When a DD API behaves unexpectedly (e.g. a
  setter that doesn't stick), a quick way to diagnose it is to **return
  intermediate state in the response** — stash before/after values in a debug
  field — so one reload shows where a value changes.

## Layout

```
mod/dungeondraft-mcp-bridge/   the Dungeondraft mod (copy into DD's mods folder)
  mcp_bridge.ddmod             manifest
  scripts/tools/mcp_bridge.gd  TCP server + command handlers
server/                        the Python MCP server
  dungeondraft_mcp/server.py   MCP tool definitions
  dungeondraft_mcp/bridge_client.py  TCP/JSON client
  test_bridge.py               standalone per-command smoke test
  demo_build.py                builds a visible sample room and leaves it
PROTOCOL.md                    wire protocol + implementation notes
```

## Credits

Built against the [Dungeondraft Modding API](https://megasploot.github.io/DungeondraftModdingAPI/).
Engine is Godot 3.4.2, so the GDScript uses Godot 3 networking class names.

## License

[MIT](LICENSE).
