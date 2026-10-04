# dungeondraft-mcp

An MCP server that drives a **running Dungeondraft instance** over a localhost
socket. Two halves: a Python MCP server (`server/`) and a GDScript mod
(`mod/`) that runs inside Dungeondraft. See [README.md](README.md) for the
architecture and [PROTOCOL.md](PROTOCOL.md) for every command + implementation
notes.

## Before you call any tool

The tools talk to a live Dungeondraft, not this repo. They only work when:

1. **Dungeondraft is running** with the **MCP Bridge mod enabled**, and
2. **a map is open**.

If both aren't true, calls fail (connection refused, or `"no map open"`).
**Verify first:** call `ping` (expect `pong` + a protocol version), then
`get_status` (expect `map_open: true` and a `map_center`). If `ping` fails, the
mod isn't loaded or DD isn't running — ask the user to start it; don't retry
blindly.

## Working with the map

- Coordinates are **woxel** (world-pixel) space; get `map_center` from
  `get_status`. There are 256 woxels per tile.
- Every element has an integer `id`; create calls return it, `list_elements` /
  `get_element` report it. Feed ids back into move/modify/delete.
- Discover assets with `list_assets` (it takes a `category` and a substring
  `search`); list categories with `list_asset_categories`.
- **Look at your work**: `screenshot` (current view) and the camera tools
  (`set_camera`, `focus_element`, `fit_elements`) return/aim the view so you can
  inspect what you built and iterate. Use them.
- Geometry checks do not check draw order: a floor at z=100 can hide a new
  object at z=0. Explicitly set furniture above its floor with
  `set_element_layer` (for example 150 when that layer exists); put tabletop
  decorations above the table. Inspect the export, not just returned IDs.
- Light `range` is a dimensionless texture scale, **not world pixels**. Start
  around 1-3, attach every light to a lamp/fire, and inspect shadows in a dusk
  export. Passing 256 or 600 creates a vastly oversized light.
- Save and reopen the result, then reapply spatial regions, audit every floor,
  and compare rendered results. Check terrain texture slots, draw layers and
  lighting as well as element counts; geometry success alone is insufficient.
- `open_map` begins asynchronous native loading. Seeing the expected number of
  floors alone does not prove loading is finished. Wait for matching objects
  and stable scene state, then verify the actual floor ID before editing/export.
- The bridge keeps its **own** `undo` / `redo` stacks (independent of DD's
  Ctrl+Z). `delete_element` is **not** undoable.

## Spatial planning (protocol 18+)

Read `get_asset_footprint` before choosing furniture scale. Use the whole rotated
footprint, not the center point. Define interior `room` polygons and pass their
names as `region`; reserve passages with `clearance`, and protect completed
buildings/banks with `protected` before terrain, cave, water or path edits.
Reapply these regions after a saved map is reopened; they are session metadata.
Use `check_object_placement` before costly work and `validate_layout` on each
floor after furnishing, followed by an exported visual inspection.

A rejected edit has not changed the map. Read its conflicts, choose a smaller
asset, change position/rotation/scale, or revise the layout. Never automatically
set `spatial_check=False` to make a rejected edit succeed. `allow_overlap=True`
is appropriate for explicitly intended tabletop decor or canopies; walls,
doorways and zones still apply. Full overrides are for deliberately overlapping
art such as wall ornaments or full-map images. Conservative rectangles can
over-report irregular silhouettes; inspect before overriding. Native/UI/undo
edits bypass these checks, and floor geometry does not model real 3D physics.

## Editing the bridge itself

If you change code (not just drive the map), the two halves reload differently:

- **Mod** (`mod/.../mcp_bridge.gd`, GDScript): reload the mod inside Dungeondraft
  (keeps the current map). Changing an existing handler needs only this.
- **Server** (`server/dungeondraft_mcp/server.py`): new/changed `@mcp.tool()`
  defs need an **MCP-server reconnect** (`/mcp` → reconnect). Adding a *new tool*
  needs **both** reloads. The install is editable — never reinstall.
- GDScript on Godot 3.4.2 has **no try/catch**: an unhandled runtime error in a
  handler crashes the mod and kills the bridge (full DD restart). Validate
  inputs before calling DD API methods.
