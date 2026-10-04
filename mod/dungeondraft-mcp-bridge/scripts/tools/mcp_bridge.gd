# MCP Bridge — Dungeondraft mod
#
# Opens a localhost TCP server inside Dungeondraft and speaks a tiny
# newline-delimited JSON protocol (see PROTOCOL.md) so an external MCP server
# can drive the currently-open map for AI-assisted map building.
#
# Engine: Dungeondraft runs Godot 3.4.2, so this uses the Godot 3 networking
# class names (TCP_Server / StreamPeerTCP) and the connect(sig, self, "method")
# signal form. Mod tool scripts receive a per-frame update(delta) callback but
# NOT _process / _input, so all socket polling happens in update().
#
# Element model: every element this bridge touches is referenced by an integer
# `id` == Dungeondraft's node_id (Global.World.AssignNodeID / GetNodeByID /
# DeleteNodeByID). Creation commands return the new id; query commands return
# ids you can pass back to move/modify/delete.
#
# Undo: reversible edits push an op onto the bridge's own undo/redo stacks
# (DD 3.4.2's History.CreateCustomRecord is unreliable); see _record_and_dispatch.

var script_class = "tool"

const HOST := "127.0.0.1"
const PORT := 8787
const PROTOCOL_VERSION := 18

# Commands that get wrapped in a Dungeondraft undo record (see _record_and_dispatch).
const CREATE_CMDS := [
	"import_image", "place_object", "draw_wall", "draw_path", "add_light",
	"add_portal", "add_roof", "add_text", "duplicate_object",
]
const TRANSFORM_CMDS := ["move_element", "modify_object"]
const TERRAIN_CMDS := ["fill_terrain", "fill_region", "paint_terrain", "paint_path"]
const CAVE_CMDS := ["dig_cave", "clear_caves"]
# Neutral opaque tint for pattern floors when no color is given. PatternShapeTool
# has no per-texture default (and its .Color leaks across calls), so we apply a
# deterministic wood/stone-neutral tone; callers pass an explicit color to override.
const DEFAULT_PATTERN_TINT := Color(0.62, 0.5, 0.34)

# SelectTool.GetSelectableType() integer -> readable kind.
const KIND_NAMES := {
	1: "wall", 2: "wall_portal", 3: "portal", 4: "object",
	5: "path", 6: "light", 7: "pattern", 8: "roof",
}
# kind string -> the Level child collection that holds those nodes.
const COLLECTIONS := {
	"objects": "Objects", "walls": "Walls", "lights": "Lights",
	"paths": "Pathways", "portals": "Portals", "roofs": "Roofs",
	"texts": "Texts",
}

var _server : TCP_Server = null
var _bridge_owner := 0
var _conns := []         # array of { "peer": StreamPeerTCP, "buf": String }
var _undo_stack := []    # bridge-managed undo ops (see _build_op / _apply_op)
var _redo_stack := []


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func start():
	_register_tool()
	var root = Global.World.get_tree().get_root()
	_bridge_owner = OS.get_ticks_usec()
	root.set_meta("dd_mcp_owner",_bridge_owner)
	if root.has_meta("dd_mcp_server"):
		_server = root.get_meta("dd_mcp_server")
		if _server != null and _server.is_listening(): return
	_server = TCP_Server.new()
	var error = _server.listen(PORT,HOST)
	if error != OK:
		_server = null
		print("[mcp-bridge] listen failed: ",error)
		return
	root.set_meta("dd_mcp_server",_server)
	print("[mcp-bridge] ready, protocol ",PROTOCOL_VERSION)


func update(delta : float):
	var root = Global.World.get_tree().get_root()
	if root.get_meta("dd_mcp_owner") != _bridge_owner: return
	if _server == null:
		return

	while _server.is_connection_available():
		var peer = _server.take_connection()
		peer.set_no_delay(true)
		_conns.append({ "peer": peer, "buf": "" })

	var still_open := []
	for c in _conns:
		var peer : StreamPeerTCP = c["peer"]
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		var avail = peer.get_available_bytes()
		if avail > 0:
			var res = peer.get_data(avail)   # [err, PoolByteArray]
			if res[0] == OK:
				c["buf"] += res[1].get_string_from_utf8()
		var nl = c["buf"].find("\n")
		while nl != -1:
			var line = c["buf"].substr(0, nl).strip_edges()
			c["buf"] = c["buf"].substr(nl + 1)
			if line != "":
				_handle_line(peer, line)
			nl = c["buf"].find("\n")
		still_open.append(c)
	_conns = still_open


# ---------------------------------------------------------------------------
# Request handling
# ---------------------------------------------------------------------------

func _handle_line(peer : StreamPeerTCP, line : String):
	var parsed = JSON.parse(line)
	var req = parsed.result
	var resp : Dictionary
	if parsed.error != OK or typeof(req) != TYPE_DICTIONARY:
		resp = _err("invalid JSON request")
	else:
		resp = _record_and_dispatch(req)
	peer.put_data((JSON.print(resp) + "\n").to_utf8())


# Runs a command and, if it succeeded and is a reversible map edit, pushes an op
# onto the bridge-managed undo stack. We do NOT use Dungeondraft's
# History.CreateCustomRecord — on 3.4.2 it invokes undo() unreliably and never
# round-trips redo(). Our own stacks are deterministic and fully under control.
# Pre-edit state (transform / terrain splat) is captured before the command runs.
func _record_and_dispatch(req : Dictionary) -> Dictionary:
	var cmd = req.get("cmd", "")

	var pre = null
	if cmd in TRANSFORM_CMDS and req.has("id"):
		var node = Global.World.GetNodeByID(int(req["id"]))
		if node != null:
			pre = _snapshot(node)

	var terrain_before = null
	if cmd in TERRAIN_CMDS:
		var lvl = Global.World.GetCurrentLevel()
		if lvl != null:
			terrain_before = _terrain_snapshot(lvl)

	var cave_before = null
	if cmd in CAVE_CMDS:
		cave_before = _cave_snapshot()

	var result = _safe_dispatch(req)
	if typeof(result) == TYPE_DICTIONARY and result.get("ok", false):
		if cmd in ["place_object", "import_image", "move_element", "modify_object", "duplicate_object"] and str(req.get("region", "")) != "":
			var placed_id = result.result.get("id", -1)
			var placed_node = Global.World.GetNodeByID(int(placed_id))
			if placed_node != null: placed_node.set_meta("dd_mcp_spatial_room", str(req.region))
		var op = _build_op(cmd, req, result, pre, terrain_before, cave_before)
		if op != null:
			_undo_stack.append(op)
			_redo_stack = []   # a fresh edit invalidates the redo branch
	return result


func _mark_native_modified():
	if not Global.Editor.History.has_method("CreateCustomRecord"):
		return
	var marker = Script.InstanceReference("library/mcp_history_marker.gd")
	if marker != null:
		Global.Editor.History.CreateCustomRecord(marker)


# Returns an undo op for a recordable command, or null. Ops are reversed by
# _apply_op (undo=true) and re-applied (undo=false).
func _build_op(cmd, req, result, pre, terrain_before, cave_before = null):
	if cmd in CREATE_CMDS:
		var id = result["result"].get("id", -1)
		if id != null and int(id) >= 0:
			var node = Global.World.GetNodeByID(int(id))
			if node != null:
				return { "kind": "create", "node": node, "parent": node.get_parent(), "id": int(id) }
	elif cmd in TRANSFORM_CMDS and pre != null:
		var node = Global.World.GetNodeByID(int(req["id"]))
		if node != null:
			return { "kind": "transform", "id": int(req["id"]), "old": pre, "new": _snapshot(node) }
	elif cmd in TERRAIN_CMDS and terrain_before != null:
		var lvl = Global.World.GetCurrentLevel()
		if lvl != null:
			return { "kind": "terrain", "before": terrain_before, "after": _terrain_snapshot(lvl), "level_id": lvl.ID }
	elif cmd in CAVE_CMDS and cave_before != null:
		var after = _cave_snapshot()
		if after != null:
			return { "kind": "cave", "before": cave_before, "after": after }
	return null


func _do_undo() -> Dictionary:
	if _undo_stack.empty():
		return _ok({ "undone": false, "reason": "nothing to undo" })
	var op = _undo_stack.pop_back()
	_apply_op(op, true)
	_redo_stack.append(op)
	return _ok({ "undone": true, "kind": op["kind"], "undo_depth": _undo_stack.size() })


func _do_redo() -> Dictionary:
	if _redo_stack.empty():
		return _ok({ "redone": false, "reason": "nothing to redo" })
	var op = _redo_stack.pop_back()
	_apply_op(op, false)
	_undo_stack.append(op)
	return _ok({ "redone": true, "kind": op["kind"], "redo_depth": _redo_stack.size() })


func _apply_op(op, undo : bool):
	match op["kind"]:
		"create":
			if undo:
				_detach_node(op["node"], int(op["id"]))
			else:
				_attach_node(op["node"], op["parent"], int(op["id"]))
		"transform":
			_apply_props(Global.World.GetNodeByID(int(op["id"])), op["old"] if undo else op["new"])
		"terrain":
			_restore_terrain(op["before"] if undo else op["after"], op.get("level_id", -1))
		"cave":
			_restore_cave(op["before"] if undo else op["after"])


func _detach_node(node, id : int):
	if is_instance_valid(node) and node.get_parent() != null:
		node.get_parent().remove_child(node)
	if Global.World.HasNodeID(id):
		Global.World.RemoveNodeID(id)


func _attach_node(node, parent, id : int):
	if not is_instance_valid(node):
		return
	if node.get_parent() == null and is_instance_valid(parent):
		parent.add_child(node)
	Global.World.SetNodeID(node, id)
	if node.has_method("RemakeLines"):
		node.RemakeLines()   # walls/paths cache geometry; refresh after re-adding


func _apply_props(node, snap):
	if node == null or snap == null:
		return
	if snap.get("position") != null:
		node.position = snap["position"]
	if snap.get("rotation") != null:
		node.rotation = snap["rotation"]
	if snap.get("scale") != null:
		node.scale = snap["scale"]
	if snap.get("shadow") != null:
		node.set("HasShadow", snap["shadow"])
	if snap.get("color") != null and node.has_method("SetCustomColor"):
		node.SetCustomColor(snap["color"])


func _restore_splat(img):
	if img == null:
		return
	var level = Global.World.GetCurrentLevel()
	if level == null:
		return
	level.Terrain.RestoreSplat(img)
	level.Terrain.UpdateSplat()


# Deep-copy the cave BitMap for the undo stack (Resource.duplicate(true) so the
# snapshot isn't aliased to the live bitmap). Returns null if no cave is present.
func _cave_snapshot():
	var cave = _cave_mesh()
	if cave == null or not cave.has_method("get_Bitmap"):
		return null
	var bm = cave.call("get_Bitmap")
	if bm == null:
		return null
	return bm.duplicate(true)


# Restore a snapshotted cave BitMap and rebuild the mesh (mirror of _restore_splat
# for the cave layer). A duplicate(true) of the stored snapshot is pushed so the
# op's snapshot stays pristine across repeated undo/redo.
func _restore_cave(bm):
	if bm == null:
		return
	var cave = _cave_mesh()
	if cave == null or not cave.has_method("SetBitmap"):
		return
	cave.call("SetBitmap", bm.duplicate(true))
	if cave.has_method("FinalizeMeshAndBorders"):
		cave.call("FinalizeMeshAndBorders")
	cave.call("UpdateMesh")


func _snapshot(node) -> Dictionary:
	var s := {}
	if node is Node2D:
		s["position"] = node.position
		s["rotation"] = node.rotation
		s["scale"] = node.scale
	if node.get("HasShadow") != null:
		s["shadow"] = node.get("HasShadow")
	if node.get("customColor") != null:
		s["color"] = node.get("customColor")
	return s


# Dispatch with a guard so a bad command can never take down the TCP loop.
func _safe_dispatch(req : Dictionary) -> Dictionary:
	var cmd = req.get("cmd", "")
	if req.has("_spatial_stamp"):
		var current = _spatial_scene()
		if not current.ok: return current
		if str(req._spatial_stamp) != str(current.result.stamp):
			return _err("Spatial snapshot changed before edit; inspect and retry. No edit performed.")
	match cmd:
		"spatial_snapshot": return _spatial_snapshot(req)
		"set_spatial_region": return _spatial_region(req, false)
		"remove_spatial_region": return _spatial_region(req, true)
		"native_describe": return _native_describe(req)
		"native_get": return _native_get(req)
		"native_call": return _native_call(req)
		"native_set": return _native_set(req)
		"ui_tree": return _ui_tree(req)
		"ui_action": return _ui_action(req)
		"native_targets": return _native_targets()
		"import_image": return _import_image(req)
		"configure_terrain": return _configure_terrain(req)
		"configure_environment": return _configure_environment(req)
		"modify_light": return _modify_light(req)
		"set_layer": return _set_layer(req)
		"set_element_layer": return _set_element_layer(req)
		"draw_water": return _draw_water(req)
		"configure_water": return _configure_water(req)
		"draw_material": return _draw_material(req)
		"configure_object": return _configure_object(req)
		"modify_text": return _modify_text(req)
		"modify_wall": return _modify_wall(req)
		"set_trace_image": return _set_trace_image(req)
		"rename_level": return _rename_level(req)
		"clone_level": return _clone_level(req)
		"reorder_levels": return _reorder_levels(req)
		"compare_levels": return _compare_levels(req)
		"save_document": return _save_document(req)
		"open_document": return _open_document(req)
		"export_document": return _export_document(req)
		"list_layers": return _list_layers()
		"capabilities": return _capabilities()
		# --- read / query ---
		"ping": return _ok({ "pong": true, "protocol": PROTOCOL_VERSION, "engine": Engine.get_version_info() })
		"get_status": return _get_status()
		"list_asset_categories": return _ok({ "categories": ASSET_CATEGORIES })
		"list_assets": return _list_assets(req)
		"list_elements": return _list_elements(req)
		"get_element": return _get_element(req)
		"list_levels": return _list_levels()
		"dig_cave": return _dig_cave(req)
		"clear_caves": return _clear_caves(req)
		# --- create ---
		"place_object": return _place_object(req)
		"draw_wall": return _draw_wall(req)
		"draw_path": return _draw_path(req)
		"add_light": return _add_light(req)
		"add_portal": return _add_portal(req)
		"add_roof": return _add_roof(req)
		"add_text": return _add_text(req)
		"place_pattern": return _place_pattern(req)
		"build_room": return _build_room(req)
		# --- terrain ---
		"set_terrain_slot": return _set_terrain_slot(req)
		"fill_terrain": return _fill_terrain(req)
		"fill_region": return _fill_region(req)
		"paint_terrain": return _paint_terrain(req)
		"paint_path": return _paint_path(req)
		# --- modify / delete ---
		"move_element": return _move_element(req)
		"modify_object": return _modify_object(req)
		"duplicate_object": return _duplicate_object(req)
		"finalize_object": return _finalize_object(req)
		"delete_element": return _delete_element(req)
		# --- levels ---
		"add_level": return _add_level(req)
		"set_level": return _set_level(req)
		# --- capture ---
		"screenshot": return _screenshot(req)
		"export_map": return _export_map(req)
		"save_map": return _save_document(req)
		"probe_save": return _probe_save(req)
		# --- camera ---
		"get_camera": return _get_camera()
		"set_camera": return _set_camera(req)
		"focus_element": return _focus_element(req)
		"fit_elements": return _fit_elements(req)
		# --- history (bridge-managed undo/redo of the model's own edits) ---
		"undo": return _do_undo()
		"redo": return _do_redo()
		# --- selection ---
		"select_elements": return _select_elements(req)
		"clear_selection": return _clear_selection()
		_: return _err("unknown cmd: " + str(cmd))


const ASSET_CATEGORIES := [
	"Objects", "Walls", "Paths", "Terrain", "Lights", "Portals", "Roofs",
	"Patterns", "Patterns Colorable", "Caves", "Materials",
	"Simple Tiles", "Smart Tiles", "Smart Tiles Double",
]


# ---------------------------------------------------------------------------
# Read / query
# ---------------------------------------------------------------------------

func _get_status() -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null:
		return _ok({ "map_open": false })
	var counts := {}
	for kind in COLLECTIONS:
		counts[kind] = _collection(level, kind).get_child_count()
	return _ok({
		"map_open": true,
		"level_id": level.ID, "level_index": Global.World.CurrentLevelId,
		"level_count": Global.World.levels.size(),
		"map_size_woxels": [Global.World.WoxelDimensions.x, Global.World.WoxelDimensions.y],
		"map_center": [Global.World.WoxelDimensions.x * 0.5, Global.World.WoxelDimensions.y * 0.5],
		"counts": counts,
		"active_tool": Global.Editor.ActiveToolName,
	})


func _list_assets(req : Dictionary) -> Dictionary:
	var category = req.get("category", "Objects")
	var search = str(req.get("search", "")).to_lower()
	var limit = int(req.get("limit", 100))
	var all = Script.GetAssetList(category)
	if all == null:
		return _err("unknown asset category: " + str(category))
	var out := []
	var matched := 0
	for path in all:
		if search != "" and str(path).to_lower().find(search) == -1:
			continue
		matched += 1
		if out.size() < limit:
			out.append(path)
	return _ok({ "category": category, "total": all.size(), "matched": matched, "returned": out.size(), "assets": out })


# Resolve the cave editing target: enable the CaveBrush (the UI path that wires
# the mesh to the level) and return its CaveMesh, or null if unavailable.
func _cave_mesh():
	if not Global.Editor.Tools.has("CaveBrush"):
		return null
	var brush = Global.Editor.Tools["CaveBrush"]
	brush.call("Enable")
	if not brush.has_method("get_Mesh"):
		return null
	return brush.call("get_Mesh")


# Woxel position -> cave-bitmap cell (the bitmap is the woxel grid at CellSize
# woxels/cell plus a MapEdgeBuffer border).
func _cave_cell(cave, world : Vector2) -> Vector2:
	var cs = cave.call("get_CellSize")
	var buf = int(cave.get("MapEdgeBuffer"))
	return Vector2(int(floor(world.x / cs)) + buf, int(floor(world.y / cs)) + buf)


# Dig (or fill) a cave along a polyline brush stroke. The cave is a MeshInstance2D
# whose open/rock state is a Godot BitMap (true = open cave floor); editing it
# then SetBitmap + UpdateMesh rebuilds the floor, rocky wall border and debris
# (exactly what the UI's Cave Brush does). Params:
#   points:[[x,y]...] (>=1) woxel path; single point = one dab.
#   radius (woxels, default 256 = 1 tile), value/dig (true=dig open, false=fill),
#   ground_color / wall_color (optional tints), texture (optional Caves asset).
# A multi-point path is rasterized as a constant-width ribbon so it digs a smooth
# tunnel (like paint_path, but into the cave bitmap).
func _dig_cave(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var cave = _cave_mesh()
	if cave == null: return _err("cave brush/mesh unavailable")
	if not cave.has_method("get_Bitmap") or not cave.has_method("SetBitmap"):
		return _err("cave mesh missing BitMap API")

	# Optional cave tints / floor texture (apply before the mesh rebuild).
	if req.has("ground_color") and str(req.get("ground_color", "")) != "":
		var gc = _color(req["ground_color"], Color(0.5, 0.5, 0.45))
		if cave.has_method("SetGroundColor"): cave.call("SetGroundColor", gc)
	if req.has("wall_color") and str(req.get("wall_color", "")) != "":
		var wc = _color(req["wall_color"], Color(0.5, 0.5, 0.45))
		if cave.has_method("SetWallColor"): cave.call("SetWallColor", wc)
	if req.has("texture") and str(req.get("texture", "")) != "":
		var tex = _asset_tex("Caves", req["texture"])
		if tex != null and cave.has_method("SetFloorTexture"):
			cave.call("SetFloorTexture", tex)

	# Path -> cell-space points.
	var pts := []
	if req.has("points"):
		for p in req["points"]:
			pts.append(_cave_cell(cave, Vector2(float(p[0]), float(p[1]))))
	else:
		pts.append(_cave_cell(cave, _xy(req, Global.World.WoxelDimensions * 0.5)))
	if pts.empty(): return _err("provide 'points':[[x,y]...] or x/y")

	var value = bool(req.get("value", req.get("dig", true)))
	var cs = cave.call("get_CellSize")
	var rad_cells = max(int(round(float(req.get("radius", 256.0)) / cs)), 1)

	var bm = cave.call("get_Bitmap")
	if bm == null: return _err("cave bitmap is null")
	var size = bm.call("get_size")
	var bw = int(size.x)
	var bh = int(size.y)
	# Rasterize the stroke: dab each point, then thicken the segments between them.
	var n := 0
	for cell in pts:
		n += _cave_stamp(bm, cell, rad_cells, value, bw, bh)
	for i in range(pts.size() - 1):
		_cave_stroke_segment(bm, pts[i], pts[i + 1], rad_cells, value, bw, bh)

	cave.call("SetBitmap", bm)
	if cave.has_method("FinalizeMeshAndBorders"):
		cave.call("FinalizeMeshAndBorders")
	cave.call("UpdateMesh")
	return _ok({
		"dug": value, "cells_painted": n, "radius_cells": rad_cells,
		"points": pts.size(), "bitmap_size": [bw, bh],
	})


# Stamp a filled circle of cells into the BitMap. Returns the count set.
func _cave_stamp(bm, c : Vector2, rad : int, value : bool, bw : int, bh : int) -> int:
	var n := 0
	var x0 = max(int(c.x) - rad, 0)
	var y0 = max(int(c.y) - rad, 0)
	var x1 = min(int(c.x) + rad, bw - 1)
	var y1 = min(int(c.y) + rad, bh - 1)
	for iy in range(y0, y1 + 1):
		for ix in range(x0, x1 + 1):
			if Vector2(ix, iy).distance_to(c) <= rad:
				bm.call("set_bit", Vector2(ix, iy), value)
				n += 1
	return n


# Stamp a thick line of cells between two cell-space points (no gaps between dabs).
func _cave_stroke_segment(bm, a : Vector2, b : Vector2, rad : int, value : bool, bw : int, bh : int) -> void:
	var steps = int(ceil(a.distance_to(b)))
	if steps <= 0:
		return
	for s in range(steps + 1):
		_cave_stamp(bm, a.linear_interpolate(b, float(s) / steps), rad, value, bw, bh)


# Wipe the entire cave layer back to solid rock. Uses the native Clear() then
# rebuilds the mesh; if Clear isn't present, falls back to zeroing the BitMap
# (set every bit false) and pushing it back — both render via UpdateMesh. This is
# a CAVE_CMD, so it's BitMap-snapshotted for undo like dig_cave.
func _clear_caves(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var cave = _cave_mesh()
	if cave == null: return _err("cave brush/mesh unavailable")
	var method = ""
	if cave.has_method("Clear"):
		cave.call("Clear")
		method = "Clear"
	elif cave.has_method("get_Bitmap") and cave.has_method("SetBitmap"):
		var bm = cave.call("get_Bitmap")
		if bm != null:
			var size = bm.call("get_size")
			for iy in range(int(size.y)):
				for ix in range(int(size.x)):
					bm.call("set_bit", Vector2(ix, iy), false)
			cave.call("SetBitmap", bm)
			method = "zero_bitmap"
	else:
		return _err("cave mesh missing Clear/BitMap API")
	if cave.has_method("FinalizeMeshAndBorders"):
		cave.call("FinalizeMeshAndBorders")
	cave.call("UpdateMesh")
	return _ok({ "cleared": true, "method": method })


func _list_elements(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null:
		return _err("no map open")
	var kind = req.get("kind", "objects")
	if not COLLECTIONS.has(kind):
		return _err("unknown kind '%s' (one of: %s)" % [kind, COLLECTIONS.keys()])
	var limit = int(req.get("limit", 200))
	var out := []
	# Wall-mounted portals (doors/windows) live inside each wall's `Portals`
	# array, NOT in level.Portals — so listing "portals" must also walk the
	# walls, or hand-placed doors are invisible to query.
	if kind == "portals":
		for wall in level.Walls.get_children():
			var wp = wall.get("Portals")
			if wp == null:
				continue
			for portal in wp:
				if out.size() >= limit:
					break
				out.append(_describe_wall_portal(portal, wall))
	for node in _collection(level, kind).get_children():
		if out.size() >= limit:
			break
		out.append(_describe(node))
	return _ok({ "kind": kind, "count": out.size(), "elements": out })


# Describe a wall-mounted portal (a door/window living in a wall's Portals
# array). Reports its world `position`, the door's half-width `radius`, and an
# outward `normal` (unit vector pointing OUT of the building) plus `facing` in
# degrees. The normal is `Direction` (the along-wall tangent) rotated 90°,
# oriented to point away from the wall's centroid — so a caller can route a road
# to the door and offset along `normal` to stop at the threshold, with no
# knowledge of how the door was placed (it's pure geometry from the data).
func _describe_wall_portal(portal, wall) -> Dictionary:
	var pos = portal.get("position")
	if pos == null or not (pos is Vector2):
		pos = Vector2()
	var tangent = portal.get("Direction")
	if tangent == null or not (tangent is Vector2) or tangent.length() < 0.001:
		tangent = Vector2(1, 0)
	else:
		tangent = tangent.normalized()
	# Outward normal = tangent rotated 90 degrees, flipped to face away from the
	# wall's centroid (which is inside the enclosed room for a building loop).
	var normal = Vector2(-tangent.y, tangent.x)
	var centroid = _wall_centroid(wall)
	if centroid != null and (pos - centroid).dot(normal) < 0.0:
		normal = -normal
	var d := {
		"id": _id(portal), "kind": "wall_portal", "wall_id": _id(wall),
		"position": _vec(pos), "normal": _vec(normal),
		"facing": rad2deg(normal.angle()),
		"closed": bool(portal.get("Closed")),
	}
	var r = portal.get("Radius")
	if r != null:
		d["radius"] = float(r)
	var tex = portal.get("Texture")
	if tex != null and tex is Texture:
		d["asset"] = tex.resource_path
	return d


# Mean of a wall's points — used to orient a portal's normal outward. Returns
# null for a wall with no usable points.
func _wall_centroid(wall):
	var pts = wall.get("Points")
	if pts == null or pts.size() == 0:
		return null
	var sum = Vector2()
	for p in pts:
		sum += p
	return sum / pts.size()


func _get_element(req : Dictionary) -> Dictionary:
	var node = _resolve(req)
	if node == null:
		return _err("no element with id " + str(req.get("id")))
	return _ok(_describe(node))


func _list_levels() -> Dictionary:
	var out := []
	var levels = Global.World.levels
	for i in range(levels.size()):
		var lv = levels[i]
		out.append({ "index": i, "id": lv.ID, "label": lv.Label })
	return _ok({ "current_index": Global.World.CurrentLevelId, "current_id": Global.World.GetCurrentLevel().ID, "levels": out })


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

func _place_object(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var tex = _asset_tex("Objects", req.get("asset", ""))
	if tex == null: return _err("could not load object asset: " + str(req.get("asset")))
	var prop = level.Objects.CreateObject(int(req.get("sorting", 0)))
	prop.SetTexture(tex)
	prop.position = _xy(req, Global.World.WoxelDimensions * 0.5)
	var s = float(req.get("scale", 1.0))
	prop.scale = Vector2(s, s)
	prop.rotation = deg2rad(float(req.get("rotation", 0.0)))
	if req.has("color") and prop.has_method("SetCustomColor"):
		prop.SetCustomColor(_color(req["color"], Color(1, 1, 1)))
	# ObjectTool.Record() is the native path used by the editor after placing a
	# prop. It assigns a real node id, registers the object for selection, and
	# makes it part of Dungeondraft's serializable edit history. CreateObject()
	# alone only makes a temporary live node, which can disappear on save/reload.
	if Global.Editor.Tools.has("ObjectTool"):
		Global.Editor.Tools["ObjectTool"].Record(prop)
	elif level.Objects.has_method("AddToSearchTable"):
		level.Objects.AddToSearchTable(prop, int(req.get("sorting", 0)) == 1)
	return _ok({ "id": _id(prop), "position": _vec(prop.position) })


func _finalize_object(req : Dictionary) -> Dictionary:
	var node = _resolve(req)
	if node == null:
		return _err("no object with id " + str(req.get("id")))
	if not Global.Editor.Tools.has("ObjectTool"):
		return _err("ObjectTool is unavailable")
	Global.Editor.Tools["ObjectTool"].Record(node)
	return _ok({ "id": _id(node), "finalized": true })


func _draw_wall(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var pts = _points(req.get("points", []))
	if pts.size() < 2: return _err("'points' needs >= 2 [x,y] pairs")
	var tex = _asset_tex("Walls", req.get("asset", ""))
	var wall = level.Walls.AddWall(
		pts, tex, _wall_color(req, tex),
		bool(req.get("loop", false)), bool(req.get("shadow", true)),
		int(req.get("type", 0)), int(req.get("joint", 1)), true)
	if wall == null: return _err("AddWall returned null (bad asset/points?)")
	return _ok({ "id": _id(wall), "point_count": pts.size() })


# Wall tint: use the caller's `color` if given, else the texture's own default
# (WallTool.GetWallColor) so stone/wood walls render with their natural tint
# instead of a bleached white (Color(1,1,1) = no tint = washed-out base).
func _wall_color(req : Dictionary, tex) -> Color:
	if req.has("color") and str(req.get("color", "")) != "":
		return _color(req["color"], Color(1, 1, 1))
	if tex != null and Global.Editor.Tools.has("WallTool"):
		var wt = Global.Editor.Tools["WallTool"]
		if wt.has_method("GetWallColor"):
			var c = wt.GetWallColor(tex)
			if c != null and c is Color:
				return c
	return Color(1, 1, 1)


func _draw_path(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var pts = _points(req.get("points", []))
	if pts.size() < 2: return _err("'points' needs >= 2 [x,y] pairs")
	var tex = _asset_tex("Paths", req.get("asset", ""))
	if tex == null: return _err("could not load path asset: " + str(req.get("asset")))
	var path = level.Pathways.CreatePath(
		tex, int(req.get("layer", 0)), int(req.get("sorting", 0)),
		bool(req.get("fade_in", false)), bool(req.get("fade_out", false)),
		bool(req.get("grow", false)), bool(req.get("shrink", false)))
	path.set_meta("preview", false)
	path.SetEditPoints(pts)
	if req.has("smoothness"):
		path.Smoothness = float(req["smoothness"])
		path.Smooth()
	if req.has("width"):
		path.SetWidthScale(float(req["width"]))
	path.UpdateGradient()
	return _ok({ "id": _id(path), "point_count": pts.size() })


func _add_light(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var light = level.Lights.CreateLight(false)
	light.set_meta("preview", false)
	light.position = _xy(req, Global.World.WoxelDimensions * 0.5)
	light.color = _color(req.get("color", ""), Color(1, 0.9, 0.7))
	light.energy = float(req.get("energy", 1.0))
	light.texture_scale = float(req.get("range", 1.0))
	light.shadow_enabled = bool(req.get("shadows", true))
	var light_asset = str(req.get("asset", ""))
	if light_asset == "": light_asset = "res://textures/lights/soft.png"
	var tex = _asset_tex("Lights", light_asset)
	if tex != null:
		light.texture = tex
	return _ok({ "id": _id(light), "position": _vec(light.position) })


# Find the wall segment nearest to `pos`. Returns
# { wall, point_index, closest, direction, distance } or null if no walls.
# A wall is a polyline of `Points`; segment i goes Points[i] -> Points[i+1]
# (plus the closing segment when Loop). We pick the segment whose nearest
# point to `pos` is closest overall, and report that segment's unit tangent.
func _nearest_wall_segment(level, pos : Vector2):
	var best = null
	for wall in level.Walls.get_children():
		var pts = wall.get("Points")
		if pts == null or pts.size() < 2:
			continue
		var seg_count = pts.size() - 1
		if wall.get("Loop"):
			seg_count = pts.size()
		for i in range(seg_count):
			var a = pts[i]
			var b = pts[(i + 1) % pts.size()]
			var closest = _closest_point_on_segment(pos, a, b)
			var dist = pos.distance_to(closest)
			if best == null or dist < best.distance:
				var dir = (b - a)
				if dir.length() > 0.001:
					dir = dir.normalized()
				best = {
					"wall": wall, "point_index": i, "closest": closest,
					"direction": dir, "distance": dist,
				}
	return best


func _closest_point_on_segment(p : Vector2, a : Vector2, b : Vector2) -> Vector2:
	var ab = b - a
	var len2 = ab.dot(ab)
	if len2 < 0.0001:
		return a
	var t = clamp((p - a).dot(ab) / len2, 0.0, 1.0)
	return a + ab * t


func _add_portal(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var tex = _asset_tex("Portals", req.get("asset", ""))
	if tex == null: return _err("could not load portal asset: " + str(req.get("asset")))
	var pos = _xy(req, Global.World.WoxelDimensions * 0.5)
	var closed = bool(req.get("closed", false))
	var radius = float(req.get("radius", 64.0))
	# mount: "wall" (default) snaps onto the nearest wall and cuts a gap;
	# "free" forces a freestanding portal. snap_max caps how far (woxels) a
	# wall may be and still capture the portal.
	var mount = str(req.get("mount", "wall"))
	var snap_max = float(req.get("snap_max", 256.0))
	if mount != "free":
		var seg = _nearest_wall_segment(level, pos)
		if seg != null and seg.distance <= snap_max:
			# Mount onto the wall: snap to the segment, face along it, and let
			# the wall remake its lines so the portal cuts a gap.
			var flip = bool(req.get("flip", false))
			var portal = seg.wall.AddPortal(
				tex, closed, seg.closest, seg.direction,
				seg.point_index, radius, flip)
			seg.wall.RemakeLines()
			if portal == null: return _err("Wall.AddPortal returned null")
			return _ok({
				"id": _id(portal), "kind": "wall_portal",
				"position": _vec(seg.closest), "wall_id": _id(seg.wall),
				"snapped": _vec(seg.closest), "snap_distance": seg.distance,
			})
		if mount == "wall" and not req.get("fallback_free", true):
			return _err("no wall within snap_max (%d) of portal position" % int(snap_max))
	# Freestanding fallback (no wall nearby, or mount == "free").
	level.CreateFreestandingPortal(
		tex, pos, closed, radius, deg2rad(float(req.get("rotation", 0.0))))
	# CreateFreestandingPortal returns void; the new portal is the last child.
	var kids = level.Portals.get_children()
	if kids.empty(): return _err("portal was not created")
	return _ok({ "id": _id(kids[kids.size() - 1]), "kind": "portal", "position": _vec(pos) })


# TEMP DEBUG: dump AddPolygon/AddHip/Set arg signatures so we can find the proper
# CLOSED-roof entry point (Set duplicates the first vertex when we close it,
# which malforms the top-left hip face). Then build a test roof via AddPolygon.
# Add a roof. KEY MODEL (learned by probing): Roof.Set(points, width, type) takes
# the roof's RIDGE LINE (the peak), NOT a footprint to trace — it builds a
# complete, self-closing roof that slopes down `width` woxels perpendicular to
# each side of the ridge, with hips/gables off the ridge ends. So:
#   - 2 points = one clean roof (a short ridge -> a near-pyramid hip).
#   - the footprint covered = the ridge bounding box expanded by `width` on all
#     sides. For a building W x H, put the ridge along the LONG axis, centered,
#     and set width = half the SHORT dimension so the eaves reach the walls.
# (Earlier code wrongly treated points as a footprint and "closed" the loop,
# which duplicated a vertex and malformed the seam corner — removed.)
func _add_roof(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var pts = _points(req.get("points", []))
	if pts.size() < 2: return _err("'points' needs >= 2 [x,y] ridge points")
	var tex = _asset_tex("Roofs", req.get("asset", ""))
	if tex == null: return _err("could not load roof asset: " + str(req.get("asset")))
	var roof = level.Roofs.CreateRoof(int(req.get("sorting", 0)))
	roof.Set(pts, float(req.get("width", 256.0)), int(req.get("type", 0)))  # type: 0 gable,1 hip,2 dormer
	roof.SetTileTexture(tex)
	return _ok({ "id": _id(roof), "ridge_points": pts.size() })


# Place a tiled floor/pattern shape (the "Floor" / Pattern Shape Tool in the UI).
# The shape's texture is set on the PatternShapeTool, then DrawRect/DrawPolygon
# rasterizes the shape into the pattern layer. Pass `rect:[x,y,w,h]` OR
# `points:[[x,y]...]`. `category` selects the asset bank ("Patterns",
# "Patterns Colorable", "Materials", "Simple Tiles", "Smart Tiles").
func _place_pattern(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	if not Global.Editor.Tools.has("PatternShapeTool"):
		return _err("PatternShapeTool not available")
	var category = str(req.get("category", "Patterns"))
	var tex = _asset_tex(category, req.get("asset", ""))
	if tex == null: return _err("could not load pattern asset: " + str(req.get("asset")))

	var shapes = level.PatternShapes
	var tool = Global.Editor.Tools["PatternShapeTool"]
	tool.Texture = tex
	# NOTE: layer switching is intentionally not exposed. tool.SetLayer() on an
	# index DD hasn't created hard-crashes the mod (GDScript has no try/catch)
	# and the valid index range is undocumented. New shapes go to the tool's
	# current layer.
	#
	# Color. CRITICAL: PatternShapeTool.Color is PERSISTENT TOOL STATE that leaks
	# across calls — it holds whatever the previous place_pattern set, NOT a
	# per-texture default (unlike walls, which have WallTool.GetWallColor(tex);
	# patterns have no such per-texture lookup). Reading it back as a "default"
	# made every no-color call inherit the last call's tint, and if it was ever
	# left transparent (alpha~0) every subsequent floor rendered INVISIBLE. So we
	# never trust tool.Color: an explicit `color` is used verbatim; with no color
	# we set a deterministic OPAQUE neutral tint so each call is independent and
	# always renders. (Pass an explicit color for an exact look.)
	var color
	var used_default = false
	if req.has("color") and str(req.get("color", "")) != "":
		color = _color(req["color"], DEFAULT_PATTERN_TINT)
	else:
		color = DEFAULT_PATTERN_TINT
		used_default = true
	if color.a < 0.05:  # guard: never paint an invisible floor
		color = Color(color.r, color.g, color.b, 1.0)
	tool.Color = color  # always set, so we don't inherit/leave leaked state
	var rotation = float(req.get("rotation", 0.0))
	if tool.get("Rotation") != null:
		tool.Rotation.value = rotation

	var before := shapes.GetShapes().size()
	var kind : String
	if req.has("rect"):
		var r = req["rect"]
		if typeof(r) != TYPE_ARRAY or r.size() < 4:
			return _err("'rect' must be [x, y, w, h]")
		shapes.DrawRect(Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3])), false)
		kind = "rect"
	elif req.has("points"):
		var pts = _points(req["points"])
		if pts.size() < 3:
			return _err("'points' needs >= 3 [x,y] pairs for a polygon")
		shapes.DrawPolygon(pts, false)
		kind = "polygon"
	else:
		return _err("provide 'rect':[x,y,w,h] or 'points':[[x,y]...]")

	# DrawRect/DrawPolygon create the shape but don't apply the texture, so set
	# it on the new shape directly via SetOptions(texture, color, rotation).
	#
	# Z-ORDER: new shapes land in the tool's default "Layer 100" node, whose
	# z_index is 100 — ABOVE the Objects node (z 0), so the floor would cover
	# furniture. The shape's own z_index is z_as_relative, i.e. an offset from
	# that 100. To sit below objects we use an ABSOLUTE z: set z_as_relative=false
	# and z_index=`z` (default -100, between FloorShapes at -200 and Objects at 0).
	var all = shapes.GetShapes()
	var result := { "shape": kind, "category": category, "shape_count": all.size() }
	if color is Color:
		result["color"] = "#" + color.to_html(true)
	if used_default:
		# Signal we applied the neutral default (no per-texture tint exists for
		# patterns; pass an explicit `color` for an exact look).
		result["used_default_tint"] = true
	if all.size() > before and all.size() > 0:
		var shape = all[all.size() - 1]
		if shape.has_method("SetOptions"):
			shape.SetOptions(tex, color, rotation)
		shape.z_as_relative = false
		shape.z_index = int(req.get("z", -100))
		result["id"] = _id(shape)
		result["z_index"] = shape.z_index
	return _ok(result)


# Build a room in one call: a looped wall AND a floor along the SAME boundary
# path, so the floor meets the wall exactly (the wall covers the floor's outer
# edge) — the way the UI's combined wall+floor trace works. Pass `rect:[x,y,w,h]`
# or `points:[[x,y]...]`. Floor is a pattern by default (`floor:"pattern"`,
# floor_asset + floor_category) or terrain (`floor:"terrain"`, floor_asset +
# floor_slot). Pass `floor:"none"` for walls only. Reuses _draw_wall /
# _place_pattern / _fill_region so behavior matches those tools exactly.
func _build_room(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")

	# Normalize the boundary to a list of [x,y] points (rect -> 4 corners).
	var pts_raw := []
	if req.has("rect"):
		var r = req["rect"]
		if typeof(r) != TYPE_ARRAY or r.size() < 4:
			return _err("'rect' must be [x, y, w, h]")
		var x = float(r[0]); var y = float(r[1]); var w = float(r[2]); var h = float(r[3])
		pts_raw = [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]
	elif req.has("points"):
		if typeof(req["points"]) != TYPE_ARRAY or req["points"].size() < 3:
			return _err("'points' needs >= 3 [x,y] pairs")
		pts_raw = req["points"]
	else:
		return _err("provide 'rect':[x,y,w,h] or 'points':[[x,y]...]")

	var result := {}

	# 1) Wall loop along the boundary.
	var wall_req := {
		"points": pts_raw, "loop": true,
		"asset": req.get("wall_asset", ""),
		"type": req.get("wall_type", 0), "joint": req.get("wall_joint", 1),
		"shadow": req.get("wall_shadow", true),
	}
	var wall_res = _draw_wall(wall_req)
	if not wall_res.get("ok", false):
		return wall_res
	result["wall_id"] = wall_res["result"].get("id")

	# 2) Floor along the SAME boundary (no inset — the wall covers the seam).
	var floor_kind = str(req.get("floor", "pattern"))
	if floor_kind == "pattern":
		var fr := {
			"points": pts_raw,
			"asset": req.get("floor_asset", ""),
			"category": req.get("floor_category", "Simple Tiles"),
		}
		if req.has("floor_color"): fr["color"] = req["floor_color"]
		if req.has("floor_z"): fr["z"] = req["floor_z"]
		var fres = _place_pattern(fr)
		if fres.get("ok", false):
			result["floor_id"] = fres["result"].get("id")
		else:
			result["floor_error"] = fres.get("error")
	elif floor_kind == "terrain":
		var tr := {
			"points": pts_raw, "slot": int(req.get("floor_slot", 1)),
		}
		if req.has("floor_asset") and str(req.get("floor_asset", "")) != "":
			tr["asset"] = req["floor_asset"]
		var tres = _fill_region(tr)
		if tres.get("ok", false):
			result["floor_pixels"] = tres["result"].get("pixels")
		else:
			result["floor_error"] = tres.get("error")
	# floor_kind == "none" -> walls only

	result["points"] = pts_raw
	return _ok(result)


# A Dungeondraft Text extends Godot LineEdit: the string is the inherited
# `.text`, position is `rect_position`, and size/color must be applied through
# the TextTool (see below) because UpdateText repaints from the tool's settings.
func _add_text(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var text = level.Texts.CreateText()
	# A Text extends LineEdit (a Control): place it via rect_position, not the
	# Node2D `.position` (which silently does nothing on a Control).
	text.rect_position = _xy(req, Global.World.WoxelDimensions * 0.5)
	text.text = str(req.get("text", ""))
	# Font/size/color: TextTool.UpdateText() repaints the focused Text from the
	# TOOL's settings (FontSize/FontColor), overwriting anything set directly on
	# the node. So drive it through the tool: stash the tool's values, set ours,
	# repaint, then restore the tool so the user's UI state is unchanged.
	# A fresh Text reports fontSize 0 until repainted, so default to 32 (DD's
	# standard) rather than the node's pre-paint value when no size is given.
	var size = int(req.get("size", 32))
	if size <= 0:
		size = 32
	var col = _color(req.get("color", ""), Color(0, 0, 0, 1))
	var font_name = str(req.get("font", text.fontName))
	if req.has("font"):
		text.SetFont(font_name, size)  # font name has no tool-member path
	if Global.Editor.Tools.has("TextTool"):
		var tt = Global.Editor.Tools["TextTool"]
		var saved_size = tt.FontSize
		var saved_color = tt.FontColor
		tt.FontSize = size
		tt.FontColor = col
		tt.focus = text
		tt.UpdateText(text)
		tt.FontSize = saved_size
		tt.FontColor = saved_color
	else:
		# No tool available: best-effort direct set.
		text.fontSize = size
		text.fontColor = col
		text.SetFont(font_name, size)
		text.SetFontColor(col)
	return _ok({ "id": _id(text), "size": text.fontSize, "color": "#" + text.fontColor.to_html(false) })


# Dungeondraft 1.2 can leave its UI save worker busy on very large maps. Keep
# the valid map file as a skeleton and replace only the live editable sections
# exposed by the public API. This avoids the unsafe Level.Save()/World.Save()
# path while retaining the native .dungeondraft_map structure.
func _save_map(req : Dictionary) -> Dictionary:
	var path = str(req.get("path", ""))
	if path == "":
		path = str(Global.Editor.CurrentMapFile)
	if path == "":
		return _err("no output path and no current map file")
	var level = Global.World.GetCurrentLevel()
	if level == null:
		return _err("no current level exists")
	var source = File.new()
	var source_err = source.open(path, File.READ)
	if source_err != OK:
		return _err("the current map skeleton could not be read")
	var parsed = JSON.parse(source.get_as_text())
	source.close()
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return _err("the current map skeleton is invalid")
	var payload = parsed.result
	var world = payload.get("world", null)
	if typeof(world) != TYPE_DICTIONARY:
		return _err("the current map skeleton has no world section")
	var levels = world.get("levels", null)
	if typeof(levels) != TYPE_DICTIONARY:
		return _err("the current map skeleton has no levels section")
	var level_key = str(Global.World.CurrentLevelId)
	if not levels.has(level_key):
		return _err("the current map skeleton has no level %s" % level_key)
	var saved_level = levels[level_key]
	if typeof(saved_level) != TYPE_DICTIONARY:
		return _err("the current level section is invalid")
	var section = str(req.get("section", "all"))
	if section == "all" or section == "environment": saved_level["environment"] = level.SaveEnvironment()
	if section == "all" or section == "layers": saved_level["layers"] = level.SaveLayers()
	if section == "all" or section == "shapes": saved_level["shapes"] = level.FloorShapes.Save()
	if section == "all" or section == "patterns": saved_level["patterns"] = level.PatternShapes.Save()
	if section == "all" or section == "walls": saved_level["walls"] = level.Walls.Save()
	if section == "all" or section == "terrain": saved_level["terrain"] = level.Terrain.Save()
	if section == "all" or section == "materials": saved_level["materials"] = level.SaveMaterialMeshes()
	if section == "all" or section == "paths": saved_level["paths"] = level.Pathways.Save()
	if section == "all" or section == "objects": saved_level["objects"] = level.Objects.Save()
	if section == "all" or section == "lights": saved_level["lights"] = level.Lights.Save()
	if section == "all" or section == "roofs": saved_level["roofs"] = level.Roofs.Save()
	if section == "all" or section == "texts": saved_level["texts"] = level.Texts.Save()
	saved_level["label"] = level.Label
	levels[level_key] = saved_level
	world["levels"] = levels
	world["next_node_id"] = str(Global.World.nextNodeID)
	world["next_prefab_id"] = str(Global.World.nextPrefabID)
	payload["world"] = world
	var text = JSON.print(payload)
	var file = File.new()
	var err = file.open(path, File.WRITE)
	if err != OK:
		return _err("could not open output map (error %d): %s" % [err, path])
	file.store_string(text)
	file.close()
	return _ok({ "saved": true, "path": path, "bytes": text.to_utf8().size() })


func _probe_save(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null:
		return _err("no current level exists")
	var part = str(req.get("part", "objects"))
	var data = null
	match part:
		"objects": data = level.Objects.Save()
		"walls": data = level.Walls.Save()
		"paths": data = level.Pathways.Save()
		"lights": data = level.Lights.Save()
		"roofs": data = level.Roofs.Save()
		"texts": data = level.Texts.Save()
		"patterns": data = level.PatternShapes.Save()
		"shapes": data = level.FloorShapes.Save()
		"terrain": data = level.Terrain.Save()
		"materials": data = level.SaveMaterialMeshes()
		"environment": data = level.SaveEnvironment()
		"layers": data = level.SaveLayers()
		_: return _err("unknown save part: " + part)
	if data == null:
		return _err("save part returned null: " + part)
	var text = JSON.print(data)
	var path = str(req.get("path", "user://mcp_probe_" + part + ".json"))
	var file = File.new()
	var err = file.open(path, File.WRITE)
	if err != OK:
		return _err("could not open probe output (error %d)" % err)
	file.store_string(text)
	file.close()
	return _ok({ "part": part, "type": typeof(data), "bytes": text.to_utf8().size(), "path": path })


# ---------------------------------------------------------------------------
# Terrain
# ---------------------------------------------------------------------------

func _set_terrain_slot(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var tex = _asset_tex("Terrain", req.get("asset", ""))
	if tex == null: return _err("could not load terrain asset: " + str(req.get("asset")))
	var slot = int(req.get("slot", 0))
	if slot < 0 or slot >= (8 if level.Terrain.ExpandedSlots else 4): return _err("terrain slot is unavailable; enable expanded slots for 4-7")
	level.Terrain.SetTexture(tex, slot)
	level.Terrain.UpdateSplat()
	return _ok({ "slot": slot })


func _fill_terrain(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var slot = int(req.get("slot", 0))
	if slot < 0 or slot >= (8 if level.Terrain.ExpandedSlots else 4): return _err("terrain slot is unavailable; enable expanded slots for 4-7")
	if req.has("asset"):
		var tex = _asset_tex("Terrain", req["asset"])
		if tex == null: return _err("could not load terrain asset: " + str(req["asset"]))
		level.Terrain.SetTexture(tex, slot)
	level.Terrain.Fill(slot)
	level.Terrain.UpdateSplat()
	return _ok({ "filled_slot": slot })


# Paint a soft circular brush of a terrain slot at a woxel position. Like
# fill_region, this edits the splat weight image directly (Terrain.Paint is a
# no-op from a mod context). The brush has a smooth radial falloff so strokes
# blend; `rate` scales the peak strength at the center.
func _paint_terrain(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var slot = int(req.get("slot", 0))
	if slot < 0 or slot >= (8 if level.Terrain.ExpandedSlots else 4): return _err("terrain slot is unavailable; enable expanded slots for 4-7")
	var radius = float(req.get("radius", 64.0))
	var rate = clamp(float(req.get("rate", 1.0)), 0.0, 1.0)
	if req.has("asset"):
		var tex = _asset_tex("Terrain", req["asset"])
		if tex == null: return _err("could not load terrain asset: " + str(req["asset"]))
		level.Terrain.SetTexture(tex, slot)
	var world = _xy(req, Global.World.WoxelDimensions * 0.5)
	# Convert the brush center and radius into texture space (radius scales by
	# the woxel->texture ratio along x).
	var center = level.Terrain.WorldToTexture(world)
	var tscale = float(level.Terrain.width) / max(Global.World.WoxelDimensions.x, 1.0)
	var trad = max(radius * tscale, 0.5)

	var sp = _open_splat(level, slot)
	if sp == null: return _err("could not read splat image for slot " + str(slot))
	var img = sp.img
	var ch = sp.ch
	var iw = img.get_width()
	var ih = img.get_height()
	var x0 = int(floor(center.x - trad))
	var y0 = int(floor(center.y - trad))
	var x1 = int(ceil(center.x + trad))
	var y1 = int(ceil(center.y + trad))
	var painted := 0
	img.lock()
	for iy in range(max(y0, 0), min(y1 + 1, ih)):
		for ix in range(max(x0, 0), min(x1 + 1, iw)):
			var d = Vector2(ix + 0.5, iy + 0.5).distance_to(center)
			if d > trad:
				continue
			# Smooth falloff: full strength in the inner half, easing to 0 at the rim.
			var falloff = clamp(1.0 - (d / trad), 0.0, 1.0)
			falloff = falloff * falloff * (3.0 - 2.0 * falloff)  # smoothstep
			var w = rate * falloff
			if w <= 0.0:
				continue
			_splat_paint_pixel(sp, ix, iy, w)
			painted += 1
	img.unlock()
	_close_splat_state(level, sp)
	return _ok({ "painted_slot": slot, "pixels": painted })


# Paint a continuous terrain stroke along a polyline (a road/trail) in one call.
# Unlike stamping many `paint_terrain` dabs (whose overlaps double-paint and whose
# spacing the caller has to eyeball), this rasterizes a uniform ribbon: for each
# pixel near the line it measures the distance to the NEAREST segment and applies
# the soft falloff once, so the whole route has constant width and clean edges.
# `points` is a woxel polyline (>= 2 [x,y] pairs); `radius` is the half-width.
func _paint_path(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var slot = int(req.get("slot", 0))
	if slot < 0 or slot >= (8 if level.Terrain.ExpandedSlots else 4): return _err("terrain slot is unavailable; enable expanded slots for 4-7")
	var radius = float(req.get("radius", 96.0))
	var rate = clamp(float(req.get("rate", 1.0)), 0.0, 1.0)
	if not req.has("points"):
		return _err("provide 'points':[[x,y]...] (>= 2 points)")
	var pts = req["points"]
	if typeof(pts) != TYPE_ARRAY or pts.size() < 2:
		return _err("'points' needs >= 2 [x,y] pairs for a path")
	if req.has("asset"):
		var tex = _asset_tex("Terrain", req["asset"])
		if tex == null: return _err("could not load terrain asset: " + str(req["asset"]))
		level.Terrain.SetTexture(tex, slot)

	# Map the polyline into texture space; radius scales by the woxel->texture
	# ratio (same conversion paint_terrain uses for a single dab).
	var tscale = float(level.Terrain.width) / max(Global.World.WoxelDimensions.x, 1.0)
	var trad = max(radius * tscale, 0.5)
	var tpts := []
	var mn = Vector2(INF, INF)
	var mx = Vector2(-INF, -INF)
	for p in pts:
		var tp = level.Terrain.WorldToTexture(Vector2(float(p[0]), float(p[1])))
		tpts.append(tp)
		mn.x = min(mn.x, tp.x); mn.y = min(mn.y, tp.y)
		mx.x = max(mx.x, tp.x); mx.y = max(mx.y, tp.y)

	var sp = _open_splat(level, slot)
	if sp == null: return _err("could not read splat image for slot " + str(slot))
	var img = sp.img
	var ch = sp.ch
	var iw = img.get_width()
	var ih = img.get_height()
	# Bounding box of the whole stroke, padded by the brush radius.
	var x0 = max(int(floor(mn.x - trad)), 0)
	var y0 = max(int(floor(mn.y - trad)), 0)
	var x1 = min(int(ceil(mx.x + trad)), iw - 1)
	var y1 = min(int(ceil(mx.y + trad)), ih - 1)
	var painted := 0
	img.lock()
	for iy in range(y0, y1 + 1):
		for ix in range(x0, x1 + 1):
			var pix = Vector2(ix + 0.5, iy + 0.5)
			# Distance to the closest segment of the polyline.
			var d = INF
			for i in range(tpts.size() - 1):
				var sd = _dist_point_segment(pix, tpts[i], tpts[i + 1])
				if sd < d:
					d = sd
				if d <= 0.0:
					break
			if d > trad:
				continue
			# Same smoothstep falloff as paint_terrain, applied once per pixel.
			var falloff = clamp(1.0 - (d / trad), 0.0, 1.0)
			falloff = falloff * falloff * (3.0 - 2.0 * falloff)
			var w = rate * falloff
			if w <= 0.0:
				continue
			_splat_paint_pixel(sp, ix, iy, w)
			painted += 1
	img.unlock()
	_close_splat_state(level, sp)
	return _ok({ "painted_slot": slot, "segments": tpts.size() - 1, "pixels": painted })


# Shortest distance from point p to segment a-b (all in texture space).
func _dist_point_segment(p : Vector2, a : Vector2, b : Vector2) -> float:
	var ab = b - a
	var len2 = ab.x * ab.x + ab.y * ab.y
	if len2 <= 0.0000001:
		return p.distance_to(a)
	var t = clamp((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


# Fill a region (rectangle or polygon) with a terrain slot, in woxel coords.
# Unlike fill_terrain (whole level), this paints only inside the shape, so you
# can floor a single room. Pass `rect:[x,y,w,h]` OR `points:[[x,y]...]` (a
# polygon, >= 3 points). The shape is mapped to texture space and rasterized
# directly into the splat weight image (see below), not via Terrain.Paint.
func _fill_region(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var slot = int(req.get("slot", 0))
	if slot < 0 or slot >= (8 if level.Terrain.ExpandedSlots else 4): return _err("terrain slot is unavailable; enable expanded slots for 4-7")
	var rate = float(req.get("rate", 1.0))
	if req.has("asset"):
		var tex = _asset_tex("Terrain", req["asset"])
		if tex == null: return _err("could not load terrain asset: " + str(req["asset"]))
		level.Terrain.SetTexture(tex, slot)

	# Gather the shape's world-space polygon (rect -> 4 corners).
	var poly := []
	if req.has("rect"):
		var r = req["rect"]
		if typeof(r) != TYPE_ARRAY or r.size() < 4:
			return _err("'rect' must be [x, y, w, h]")
		var x = float(r[0]); var y = float(r[1]); var w = float(r[2]); var h = float(r[3])
		poly = [Vector2(x, y), Vector2(x + w, y), Vector2(x + w, y + h), Vector2(x, y + h)]
	elif req.has("points"):
		for p in req["points"]:
			poly.append(Vector2(float(p[0]), float(p[1])))
		if poly.size() < 3:
			return _err("'points' needs >= 3 [x,y] pairs for a polygon")
	else:
		return _err("provide 'rect':[x,y,w,h] or 'points':[[x,y]...]")

	# Map the polygon into texture space and find its pixel bounding box.
	var tpoly := []
	var mn = Vector2(INF, INF)
	var mx = Vector2(-INF, -INF)
	for wp in poly:
		var tp = level.Terrain.WorldToTexture(wp)
		tpoly.append(tp)
		mn.x = min(mn.x, tp.x); mn.y = min(mn.y, tp.y)
		mx.x = max(mx.x, tp.x); mx.y = max(mx.y, tp.y)
	var origin = Vector2(floor(mn.x), floor(mn.y))
	var bw = int(ceil(mx.x - origin.x))
	var bh = int(ceil(mx.y - origin.y))
	if bw < 1 or bh < 1:
		return _err("region is too small in texture space")

	# Edit the splat weight image directly (Terrain.Paint is a no-op from a mod
	# context). For each pixel inside the polygon, drive the target slot's
	# channel toward 1 by `rate`; _open/_close_splat handle clone + restore.
	var local := []
	for tp in tpoly:
		local.append(tp - origin)
	rate = clamp(rate, 0.0, 1.0)
	var sp = _open_splat(level, slot)
	if sp == null: return _err("could not read splat image for slot " + str(slot))
	var img = sp.img
	var iw = img.get_width()
	var ih = img.get_height()
	var painted := 0
	img.lock()
	for py in range(bh):
		var iy = int(origin.y) + py
		if iy < 0 or iy >= ih:
			continue
		for px in range(bw):
			var ix = int(origin.x) + px
			if ix < 0 or ix >= iw:
				continue
			if not _point_in_poly(Vector2(px + 0.5, py + 0.5), local):
				continue
			_splat_paint_pixel(sp, ix, iy, rate)
			painted += 1
	img.unlock()
	_close_splat_state(level, sp)

	return _ok({
		"filled_slot": slot, "shape": ("rect" if req.has("rect") else "polygon"),
		"texture_bbox": [_vec(origin), [origin.x + bw, origin.y + bh]],
		"pixels": painted,
	})


# Clone the splat weight image holding `slot` for direct editing. Returns
# { img, ch, which } where ch is the RGBA channel (0..3) for that slot and
# which is 0 (slots 0-3 -> splatImage) or 1 (slots 4-7 -> splatImage2), or null
# if the image isn't available. Pair with _close_splat to push edits back.
func _open_splat(level, slot : int):
	var which = 0 if slot < 4 else 1
	var img = level.Terrain.CloneSplatImage() if which == 0 else level.Terrain.CloneSplatImage2()
	if img == null: return null
	var other = null
	if level.Terrain.ExpandedSlots:
		other = level.Terrain.CloneSplatImage2() if which == 0 else level.Terrain.CloneSplatImage()
		if other != null: other.lock()
	return {"img":img,"other":other,"ch":slot % 4,"which":which}

func _splat_paint_pixel(sp, x : int, y : int, rate : float):
	if sp.other == null:
		sp.img.set_pixel(x,y,_splat_set_channel(sp.img.get_pixel(x,y),sp.ch,rate))
		return
	var c = sp.img.get_pixel(x,y)
	var d = sp.other.get_pixel(x,y)
	var weights = [c.r,c.g,c.b,c.a,d.r,d.g,d.b,d.a]
	var total = 0.0
	for weight in weights: total += weight
	if total > 0.0001:
		for i in range(8): weights[i] /= total
	var target = weights[sp.ch] + (1.0-weights[sp.ch])*rate
	var remaining = 1.0-weights[sp.ch]
	for i in range(8):
		if i == sp.ch: weights[i] = target
		else: weights[i] = weights[i]*(1.0-target)/remaining if remaining > 0.0001 else 0.0
	sp.img.set_pixel(x,y,Color(weights[0],weights[1],weights[2],weights[3]))
	sp.other.set_pixel(x,y,Color(weights[4],weights[5],weights[6],weights[7]))

func _close_splat_state(level, sp):
	if sp.other == null:
		_close_splat(level,sp.which,sp.img)
		return
	sp.other.unlock()
	if sp.which == 0: level.Terrain.RestoreSplat2(sp.img,sp.other)
	else: level.Terrain.RestoreSplat2(sp.other,sp.img)
	level.Terrain.UpdateSplat()


func _close_splat(level, which : int, img) -> void:
	if which == 0:
		level.Terrain.RestoreSplat(img)
	else:
		level.Terrain.RestoreSplat2(level.Terrain.CloneSplatImage(), img)
	level.Terrain.UpdateSplat()


# Push channel `ch` (0=R,1=G,2=B,3=A) of an RGBA splat weight toward 1 by `rate`,
# scaling the remaining channels down so the four weights still sum to ~1.
func _splat_set_channel(c : Color, ch : int, rate : float) -> Color:
	var w = [c.r, c.g, c.b, c.a]
	var target = w[ch] + (1.0 - w[ch]) * rate
	var rest = 1.0 - target
	var others = (w[0] + w[1] + w[2] + w[3]) - w[ch]
	for i in range(4):
		if i == ch:
			w[i] = target
		elif others > 0.0001:
			w[i] = w[i] / others * rest
		else:
			w[i] = 0.0
	return Color(w[0], w[1], w[2], w[3])


# Even-odd point-in-polygon test (ray cast). `poly` is an array of Vector2.
func _point_in_poly(pt : Vector2, poly : Array) -> bool:
	var inside = false
	var n = poly.size()
	var j = n - 1
	for i in range(n):
		var a = poly[i]
		var b = poly[j]
		if ((a.y > pt.y) != (b.y > pt.y)) and \
				(pt.x < (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x):
			inside = not inside
		j = i
	return inside


# ---------------------------------------------------------------------------
# Modify / delete
# ---------------------------------------------------------------------------

func _move_element(req : Dictionary) -> Dictionary:
	var node = _resolve(req)
	if node == null: return _err("no element with id " + str(req.get("id")))
	if _is_text(node):
		node.rect_position = _xy(req, node.rect_position)
		return _ok({ "id": req.get("id"), "position": _vec(node.rect_position) })
	if not (node is Node2D): return _err("element is not movable")
	node.position = _xy(req, node.position)
	return _ok({ "id": req.get("id"), "position": _vec(node.position) })


func _modify_object(req : Dictionary) -> Dictionary:
	var node = _resolve(req)
	if node == null: return _err("no element with id " + str(req.get("id")))
	if req.has("scale"):
		var s = float(req["scale"]); node.scale = Vector2(s, s)
	if req.has("rotation"):
		node.rotation = deg2rad(float(req["rotation"]))
	if req.has("color") and node.has_method("SetCustomColor"):
		node.SetCustomColor(_color(req["color"], Color(1, 1, 1)))
	if req.has("shadow"):
		node.set("HasShadow", bool(req["shadow"]))
	return _ok(_describe(node))


func _duplicate_object(req : Dictionary) -> Dictionary:
	var level = Global.World.GetCurrentLevel()
	if level == null: return _err("no map open")
	var src = _resolve(req)
	if src == null: return _err("no element with id " + str(req.get("id")))
	if src.get("Texture") == null: return _err("element has no Texture to duplicate")
	var prop = level.Objects.CreateObject(0)
	prop.SetTexture(src.Texture)
	prop.position = src.position + Vector2(float(req.get("dx", 64.0)), float(req.get("dy", 0.0)))
	prop.scale = src.scale
	prop.rotation = src.rotation
	if src.get("Mirror") != null: prop.set("Mirror", bool(src.get("Mirror")))
	for key in ["dd_mcp_alpha_rect", "dd_mcp_spatial_room"]:
		if src.has_meta(key): prop.set_meta(key, src.get_meta(key))
	if Global.Editor.Tools.has("ObjectTool"):
		Global.Editor.Tools["ObjectTool"].Record(prop)
	elif level.Objects.has_method("AddToSearchTable"):
		level.Objects.AddToSearchTable(prop, false)
	return _ok({ "id": _id(prop), "position": _vec(prop.position) })


func _delete_element(req : Dictionary) -> Dictionary:
	var ident = req.get("id")
	if ident == null: return _err("missing 'id'")
	var ok = Global.World.DeleteNodeByID(int(ident))
	return _ok({ "deleted": ok, "id": ident })


# ---------------------------------------------------------------------------
# Levels
# ---------------------------------------------------------------------------

func _add_level(req : Dictionary) -> Dictionary:
	var template = Global.World.GetCurrentLevel().Terrain.Save()
	template["enabled"] = true
	var lv = Global.World.CreateLevel(str(req.get("label", "Level")))
	lv.Terrain.Load(template)
	lv.Terrain.Fill(0)
	lv.Terrain.UpdateSplat()
	Global.Editor.UpdateLevelOptions()
	return _ok({ "id": lv.ID, "label": lv.Label, "terrain_initialized": true })


func _set_level(req : Dictionary) -> Dictionary:
	var idx = int(req.get("index", 0))
	if idx < 0 or idx >= Global.World.levels.size():
		return _err("level index out of range: " + str(idx))
	Global.World.SetLevel(idx, false)
	if Global.World.CurrentLevelId != idx: return _err("native floor switch failed")
	return _ok({ "current_index": idx })


# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

# Grab the current window (what's on screen) to a PNG. Synchronous: the texture
# holds the last drawn frame, so no yield is needed inside update().
func _screenshot(req : Dictionary) -> Dictionary:
	var path = str(req.get("path", ""))
	if path == "": return _err("missing 'path'")
	var img = Global.World.get_viewport().get_texture().get_data()
	if img == null: return _err("viewport capture returned null")
	img.flip_y()  # viewport textures come back vertically flipped
	var err = img.save_png(path)
	if err != OK: return _err("save_png failed (err %d): %s" % [err, path])
	return _ok({ "path": path, "width": img.get_width(), "height": img.get_height() })


# Render the whole map (no UI) to a clean PNG. Asynchronous: Exporter.Start runs
# on a separate thread, so the caller (MCP server) polls the path for the file.
func _export_map(req : Dictionary) -> Dictionary:
	var path = str(req.get("path", ""))
	if path == "": return _err("missing 'path'")
	var ppi = int(req.get("ppi", 40))
	Global.Exporter.Start(0, ppi, path)  # mode 0 = PNG
	return _ok({ "path": path, "ppi": ppi, "async": true })


# ---------------------------------------------------------------------------
# Camera
# ---------------------------------------------------------------------------
#
# The editor camera is a Camera2D at Global.Camera. Its world center is the
# inherited `global_position`; `zoom` is a Vector2 where LARGER = zoomed OUT
# (a Camera2D scales the view by `zoom`, so zoom 0.5 shows half as much = 2x
# magnification). We expose zoom as a single float = zoom.x and pan by setting
# global_position directly (unambiguous), then nudge DD's zoom dropdown to
# match via SetZoomOptionByRaw so the bottom bar stays in sync.

func _camera():
	return Global.get("Camera")


func _viewport_size() -> Vector2:
	return Global.World.get_viewport().get_visible_rect().size


func _apply_zoom(cam, z : float) -> void:
	z = max(0.01, z)
	cam.zoom = Vector2(z, z)
	# Keep DD's bottom-bar zoom dropdown in sync with the raw zoom value.
	if Global.Editor.has_method("SetZoomOptionByRaw"):
		Global.Editor.SetZoomOptionByRaw(z)


func _camera_state(cam) -> Dictionary:
	return {
		"position": _vec(cam.global_position),
		"zoom": cam.zoom.x,
		"viewport_size": _vec(_viewport_size()),
	}


func _get_camera() -> Dictionary:
	var cam = _camera()
	if cam == null: return _err("camera not available")
	return _ok(_camera_state(cam))


func _set_camera(req : Dictionary) -> Dictionary:
	var cam = _camera()
	if cam == null: return _err("camera not available")
	if req.has("x") or req.has("y"):
		cam.global_position = _xy(req, cam.global_position)
	if req.has("zoom"):
		_apply_zoom(cam, float(req["zoom"]))
	return _ok(_camera_state(cam))


# Center the camera on a single element (any kind, incl. text). Optional zoom.
func _focus_element(req : Dictionary) -> Dictionary:
	var cam = _camera()
	if cam == null: return _err("camera not available")
	var node = _resolve(req)
	if node == null: return _err("no element with id " + str(req.get("id")))
	var pos = _element_position(node)
	if pos == null: return _err("element has no position to focus")
	cam.global_position = pos
	if req.has("zoom"):
		_apply_zoom(cam, float(req["zoom"]))
	return _ok({ "id": req.get("id"), "focused": _vec(pos), "camera": _camera_state(cam) })


# Frame a set of elements: center on the UNION of their world-space bounding
# rects and zoom so it fits the viewport with `pad` (fraction of extra margin,
# default 0.15). Ids that don't resolve or lack bounds are skipped and reported
# in `missing`. Using real rects (not anchor points) keeps wall loops and large
# props correctly centered.
func _fit_elements(req : Dictionary) -> Dictionary:
	var cam = _camera()
	if cam == null: return _err("camera not available")
	var ids = req.get("ids", [])
	var mn = Vector2(INF, INF)
	var mx = Vector2(-INF, -INF)
	var used := 0
	var missing := []
	for ident in ids:
		var node = Global.World.GetNodeByID(int(ident))
		var rect = null
		if node != null:
			rect = _element_rect(node)
		if rect == null:
			missing.append(ident)
			continue
		mn.x = min(mn.x, rect.position.x); mn.y = min(mn.y, rect.position.y)
		mx.x = max(mx.x, rect.end.x); mx.y = max(mx.y, rect.end.y)
		used += 1
	if used == 0:
		return _err("no elements with bounds to fit")
	var center = (mn + mx) * 0.5
	cam.global_position = center
	# Zoom so the box fits: zoom (Camera2D) = world_span / viewport_span.
	var pad = 1.0 + float(req.get("pad", 0.15))
	var raw = mx - mn
	var vp = _viewport_size()
	var z
	if raw.length() < 1.0:
		# Degenerate box (one point, no derivable bounds): use a sane close zoom
		# instead of slamming to the minimum and burying the camera in a pixel.
		z = 1.0
	else:
		var span = raw * pad
		z = max(span.x / max(vp.x, 1.0), span.y / max(vp.y, 1.0))
	_apply_zoom(cam, z)
	return _ok({
		"fit": used, "missing": missing,
		"center": _vec(center), "bounds": [_vec(mn), _vec(mx)],
		"camera": _camera_state(cam),
	})


# A representative world point for any element kind: the center of its bounding
# rect (so walls/large props focus on their middle, not their anchor).
func _element_position(node):
	var rect = _element_rect(node)
	if rect != null:
		return rect.position + rect.size * 0.5
	return null


# A world-space Rect2 enclosing an element's visual extent, or null if none can
# be determined. Prefers the engine's own bounds (GlobalRect on walls/paths,
# get_global_rect on the LineEdit-based Text), then a prop's Rect, then a wall/
# path's Points, finally a zero-size rect at the node position.
func _element_rect(node):
	if _is_text(node):
		return node.get_global_rect()  # Control: world-space rect
	var grect = node.get("GlobalRect")
	if grect != null and grect is Rect2 and grect.size.length() > 0.0:
		return grect
	var prect = node.get("Rect")
	if prect != null and prect is Rect2 and prect.size.length() > 0.0:
		return prect
	# A prop's Rect can be empty until DD computes it; derive bounds from the
	# Sprite's texture size * node scale, centered on the node position.
	if node is Node2D:
		var spr = node.get("Sprite")
		if spr != null and spr.has_method("get_texture") and spr.get_texture() != null:
			var tsize = spr.get_texture().get_size() * node.scale
			if tsize.length() > 0.0:
				return Rect2(node.position - tsize * 0.5, tsize)
	var pts = node.get("Points")
	if pts != null and pts is PoolVector2Array and pts.size() > 0:
		var mn = Vector2(INF, INF)
		var mx = Vector2(-INF, -INF)
		for p in pts:
			mn.x = min(mn.x, p.x); mn.y = min(mn.y, p.y)
			mx.x = max(mx.x, p.x); mx.y = max(mx.y, p.y)
		return Rect2(mn, mx - mn)
	if node is Node2D:
		return Rect2(node.position, Vector2())
	return null


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

func _select_elements(req : Dictionary) -> Dictionary:
	var stool = Global.Editor.Tools["SelectTool"]
	stool.DeselectAll()
	var n := 0
	for ident in req.get("ids", []):
		var node = Global.World.GetNodeByID(int(ident))
		if node != null:
			stool.SelectThing(node, true)
			n += 1
	stool.EnableTransformBox(true)
	return _ok({ "selected": n })


func _clear_selection() -> Dictionary:
	Global.Editor.Tools["SelectTool"].DeselectAll()
	return _ok({ "cleared": true })


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _collection(level, kind : String) -> Node:
	return level.get(COLLECTIONS[kind])


# Stable id for a node: reuse its node_id meta, else allocate+register one.
# Returns -1 if the node type can't be registered (e.g. Text on some versions).
func _id(node) -> int:
	if node.has_meta("node_id"):
		return int(node.get_meta("node_id"))
	var nid = Global.World.AssignNodeID(node)
	if nid != null:
		return int(nid)
	if node.has_meta("node_id"):
		return int(node.get_meta("node_id"))
	return -1


func _resolve(req : Dictionary):
	if not req.has("id"):
		return null
	return Global.World.GetNodeByID(int(req["id"]))


# A DD Text node extends LineEdit (a Control), so GetSelectableType doesn't
# classify it and it has no Node2D `.position` — special-case it up front.
func _is_text(node) -> bool:
	return (node is Control) and node.has_method("SetFontSize")


func _describe(node) -> Dictionary:
	# A wall-mounted portal carries a WallID script var and lives under its wall;
	# describe it richly (position + outward normal) like list_elements does.
	if node.get("WallID") != null and node.get("Direction") != null:
		var parent = node.get_parent()
		if parent != null:
			return _describe_wall_portal(node, parent)
	if _is_text(node):
		# DD Text extends LineEdit (Control): position is rect_position, the
		# string is the inherited `.text`, and size/color are the `fontSize` /
		# `fontColor` members. LineEdit has no rotation, so none is reported.
		var td := {
			"id": _id(node), "kind": "text",
			"position": _vec(node.rect_position),
			"text": node.text,
		}
		var fsize = node.get("fontSize")
		if fsize != null:
			td["size"] = int(fsize)
		var fcolor = node.get("fontColor")
		if fcolor != null and fcolor is Color:
			td["color"] = "#" + fcolor.to_html(false)
		var fname = node.get("fontName")
		if fname != null and str(fname) != "":
			td["font"] = str(fname)
		return td
	var stool = Global.Editor.Tools["SelectTool"]
	var t = stool.GetSelectableType(node)
	var d := { "id": _id(node), "kind": KIND_NAMES.get(t, "unknown") }
	if node is Node2D:
		d["position"] = _vec(node.position)
		d["rotation"] = rad2deg(node.rotation)
		d["scale"] = node.scale.x
	var tex_path = _texture_path(node, t)
	if tex_path != "":
		d["asset"] = tex_path
	return d


func _texture_path(node, kind : int) -> String:
	var tex = null
	if kind in [1, 2, 3, 4]:
		tex = node.get("Texture")
	elif kind in [5, 6]:
		if node.has_method("get_texture"):
			tex = node.get_texture()
	elif kind == 8:
		tex = node.get("TilesTexture")
	if tex != null and tex is Texture:
		return tex.resource_path
	return ""


func _asset_tex(category : String, asset):
	if typeof(asset) != TYPE_STRING or asset == "":
		return null
	return Script.GetAssetTexture(category, asset)


func _xy(req : Dictionary, fallback : Vector2) -> Vector2:
	if req.has("x") and req.has("y"):
		return Vector2(float(req["x"]), float(req["y"]))
	return fallback


func _vec(v : Vector2) -> Array:
	return [v.x, v.y]


func _points(raw) -> PoolVector2Array:
	var pts := PoolVector2Array()
	if typeof(raw) != TYPE_ARRAY:
		return pts
	for p in raw:
		if typeof(p) == TYPE_ARRAY and p.size() >= 2:
			pts.append(Vector2(float(p[0]), float(p[1])))
	return pts


# Accepts "#rrggbb" / "rrggbb" string, or [r,g,b] / [r,g,b,a] floats 0..1.
func _color(v, fallback : Color) -> Color:
	if typeof(v) == TYPE_STRING and v != "":
		return Color(v)
	if typeof(v) == TYPE_ARRAY and v.size() >= 3:
		var a = 1.0
		if v.size() >= 4:
			a = float(v[3])
		return Color(float(v[0]), float(v[1]), float(v[2]), a)
	return fallback


func _ok(result) -> Dictionary:
	return { "ok": true, "result": result }


func _err(msg) -> Dictionary:
	return { "ok": false, "error": msg }


func _register_tool():
	var icon = _ensure_icon()
	var panel = Global.Editor.Toolset.CreateModTool(self, "Settings", "mcp_bridge", "MCP Bridge", icon)
	panel.CreateLabel("Listening on")
	panel.CreateLabel("%s:%d" % [HOST, PORT])


func _ensure_icon() -> String:
	var dir = Directory.new()
	if not dir.dir_exists(Global.Root + "icons"):
		dir.make_dir(Global.Root + "icons")
	var path = Global.Root + "icons/mcp_bridge.png"
	var f = File.new()
	if not f.file_exists(path):
		var img = Image.new()
		img.create(32, 32, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.18, 0.55, 0.95))
		img.save_png(path)
	return path


# Geometry is captured from the LIVE floor. Python checks proposals, and the
# dispatch stamp above makes snapshot-check-commit fail closed if anything moves.
var _spatial_alpha_cache := {}
var _spatial_embedded_file := ""
var _spatial_embedded_data := {}

func _spatial_alpha_rect(tex) -> Rect2:
	var key = str(tex.get_instance_id()) + ":" + str(tex.resource_path)
	if _spatial_alpha_cache.has(key): return _spatial_alpha_cache[key]
	var result = Rect2(Vector2(), tex.get_size())
	# Some DD renderers cannot read alpha back from GPU textures. Prefer the
	# source pixels, including PNG data embedded in a reopened map.
	var image = Image.new()
	var source = str(tex.resource_path)
	if source.begins_with("embedded://"): source = source.substr(11)
	if image.load(source) != OK:
		if str(tex.resource_path).begins_with("embedded://"):
			var map_file = str(Global.Editor.CurrentMapFile)
			if map_file != _spatial_embedded_file or not _spatial_embedded_data.has(source):
				_spatial_embedded_file = map_file
				_spatial_embedded_data = {}
				var file = File.new()
				if file.open(map_file, File.READ) == OK:
					var parsed = JSON.parse(file.get_as_text())
					file.close()
					if parsed.error == OK and typeof(parsed.result) == TYPE_DICTIONARY:
						_spatial_embedded_data = parsed.result.get("world", {}).get("embedded", {})
			if _spatial_embedded_data.has(source):
				image.load_png_from_buffer(Marshalls.base64_to_raw(str(_spatial_embedded_data[source].get("data", ""))))
		if image.empty(): image = tex.get_data()
	if image != null and not image.empty():
		if image.is_compressed():
			if image.decompress() != OK:
				_spatial_alpha_cache[key] = result
				return result
		result = image.get_used_rect()
	# Bound cache growth during long editor sessions with many custom assets.
	if _spatial_alpha_cache.size() > 4096: _spatial_alpha_cache.clear()
	_spatial_alpha_cache[key] = result
	return result

func _spatial_corners(rect : Rect2) -> Array:
	return [rect.position, rect.position + Vector2(rect.size.x, 0), rect.end, rect.position + Vector2(0, rect.size.y)]

func _spatial_matrix(node) -> Array:
	var t = Transform2D()
	if node is Node2D: t = node.global_transform
	return [t.x.x, t.x.y, t.y.x, t.y.y, t.origin.x, t.origin.y]

func _spatial_object(node):
	var sprite = _native_read(node, "Sprite")
	var tex = _native_read(node, "Texture")
	if not sprite is Sprite or tex == null or not tex is Texture: return null
	var used = _spatial_alpha_rect(tex)
	if node.has_meta("dd_mcp_alpha_rect"): used = node.get_meta("dd_mcp_alpha_rect")
	var size = tex.get_size()
	if size.x <= 0 or size.y <= 0: return null
	var draw = sprite.get_rect()
	if sprite.flip_h: used.position.x = size.x - used.end.x
	if sprite.flip_v: used.position.y = size.y - used.end.y
	var trimmed = Rect2(draw.position + used.position * draw.size / size, used.size * draw.size / size)
	var local := []
	var world := []
	for point in _spatial_corners(trimmed):
		local.append(_vec(sprite.transform.xform(point)))
		world.append(_vec(sprite.global_transform.xform(point)))
	return {"id": _id(node), "asset": tex.resource_path, "position": _vec(node.position),
		"scale": _vec(node.scale), "rotation": rad2deg(node.rotation), "mirror": bool(_native_read(node, "Mirror")),
		"layer": node.z_index, "local_polygon": local, "polygon": world,
		"parent_transform": _spatial_matrix(node.get_parent()), "empty": used.size.length() == 0,
		"region": node.get_meta("dd_mcp_spatial_room") if node.has_meta("dd_mcp_spatial_room") else ""}

func _spatial_wall_width(tex) -> float:
	if tex == null or not tex is Texture: return 32.0
	return max(1.0, _spatial_alpha_rect(tex).size.y * 0.5)

func _spatial_scene() -> Dictionary:
	var lvl = Global.World.GetCurrentLevel()
	if lvl == null: return _err("no map open")
	var objects := []
	var missing := []
	for node in lvl.Objects.get_children():
		var object = _spatial_object(node)
		if object == null: missing.append(_id(node))
		elif not object.empty: objects.append(object)
	var walls := []
	var portals := []
	for wall in lvl.Walls.get_children():
		var raw = _native_read(wall, "Points")
		if raw == null or raw.size() < 2: continue
		var route := []
		var local_route := []
		for point in raw:
			route.append(_vec(wall.global_transform.xform(point)))
			local_route.append(_vec(point))
		var tex = _native_read(wall, "Texture")
		walls.append({"id": _id(wall), "points": route, "loop": bool(_native_read(wall, "Loop")),
			"half_width": _spatial_wall_width(tex) * max(abs(wall.scale.x), abs(wall.scale.y)),
			"position": _vec(wall.position), "local_points": local_route, "scale": _vec(wall.scale),
			"rotation": rad2deg(wall.rotation), "parent_transform": _spatial_matrix(wall.get_parent())})
		var mounts = _native_read(wall, "Portals")
		if mounts == null: continue
		for portal in mounts:
			var d = _describe_wall_portal(portal, wall)
			var normal = Vector2(d.normal[0], d.normal[1])
			d["tangent"] = _vec(Vector2(normal.y, -normal.x))
			d["radius"] = float(d.get("radius", 128.0))
			d["window"] = str(d.get("asset", "")).to_lower().find("window") != -1
			portals.append(d)
	var regions = lvl.get_meta("dd_mcp_spatial_regions") if lvl.has_meta("dd_mcp_spatial_regions") else []
	var scene = {"floor_id": lvl.ID, "floor_instance": lvl.get_instance_id(), "dimensions": _vec(Global.World.WoxelDimensions),
		"objects": objects, "walls": walls, "portals": portals, "regions": regions,
		"unsupported_objects": missing, "object_parent_transform": _spatial_matrix(lvl.Objects)}
	var default_texture = _native_read(Global.Editor.Tools.get("WallTool", null), "Texture")
	scene["default_wall_half_width"] = _spatial_wall_width(default_texture)
	var pixel_x = Global.World.WoxelDimensions.x / max(float(lvl.Terrain.width), 1.0)
	var pixel_y = Global.World.WoxelDimensions.y / max(float(lvl.Terrain.height), 1.0)
	scene["terrain_raster_padding"] = Vector2(pixel_x, pixel_y).length()
	var cave = _cave_mesh()
	scene["cave_cell_size"] = float(cave.call("get_CellSize")) if cave != null and cave.has_method("get_CellSize") else 64.0
	scene["stamp"] = JSON.print(scene).sha256_text()
	return _ok(scene)

func _spatial_snapshot(req : Dictionary) -> Dictionary:
	var result = _spatial_scene()
	if not result.ok: return result
	if req.has("target_id"):
		var node = Global.World.GetNodeByID(int(req.target_id))
		result.result["target_kind"] = _describe(node).get("kind", "unknown") if node != null else "missing"
	var tex = null
	if req.has("image_path"):
		var image = Image.new()
		if image.load(str(req.image_path)) != OK: return _err("could not read image footprint")
		tex = ImageTexture.new()
		tex.create_from_image(image)
		_spatial_alpha_cache[str(tex.get_instance_id()) + ":" + str(tex.resource_path)] = image.get_used_rect()
	elif req.has("asset"):
		tex = _asset_tex(str(req.get("asset_category", "Objects")), req.asset)
		if tex == null: return _err("could not load asset footprint")
	if tex != null:
		var used = _spatial_alpha_rect(tex)
		var local := []
		for point in _spatial_corners(Rect2(used.position - tex.get_size()*0.5, used.size)): local.append(_vec(point))
		result.result["asset"] = {"width": tex.get_width(), "height": tex.get_height(),
			"local_polygon": local, "half_width": _spatial_wall_width(tex), "empty": used.size.length() == 0}
	return result

func _spatial_region(req : Dictionary, remove : bool) -> Dictionary:
	var lvl = Global.World.GetCurrentLevel()
	if lvl == null: return _err("no map open")
	var name = str(req.get("name", ""))
	if name.strip_edges() == "" or name.length() > 100: return _err("invalid spatial region name")
	var regions = lvl.get_meta("dd_mcp_spatial_regions") if lvl.has_meta("dd_mcp_spatial_regions") else []
	var out := []
	for r in regions:
		if r.name != name: out.append(r)
	if not remove:
		var kind = str(req.get("kind", "clearance"))
		if not kind in ["room", "clearance", "protected"]: return _err("invalid spatial region kind")
		var polygon = _points(req.get("points", []))
		if polygon.size() < 3: return _err("region needs at least 3 points")
		var packed := []
		for p in polygon: packed.append(_vec(p))
		out.append({"name": name, "kind": kind, "points": packed})
	lvl.set_meta("dd_mcp_spatial_regions", out)
	if remove:
		for node in lvl.Objects.get_children():
			if node.has_meta("dd_mcp_spatial_room") and node.get_meta("dd_mcp_spatial_room") == name:
				node.remove_meta("dd_mcp_spatial_room")
	return _ok({"regions": out, "scope": "current floor; open map session"})

# Runtime access to Dungeondraft's installed API. No eval, executable launch,
# or arbitrary scene-tree roots. Version-specific methods are discovered first.
var _native_handles := {}
var _native_handle_next := 1

func _native_read(obj, name):
	if obj == null or not is_instance_valid(obj): return null
	if obj.has_method("get_" + name): return obj.call("get_" + name)
	return obj.get(name)

func _native_public(name : String) -> bool:
	return name.substr(0,1) == name.substr(0,1).to_upper() or name in ["set_shader_param", "get_shader_param"] or ((name.begins_with("get_") or name.begins_with("set_")) and name.length()>4 and name.substr(4,1) == name.substr(4,1).to_upper())

func _native_target(path : String):
	var parts = path.split(".")
	var root = parts[0]
	var obj = null
	if root == "World": obj = Global.World
	elif root == "Header": obj = Global.Header
	elif root == "Editor": obj = Global.Editor
	elif root == "Exporter": obj = Global.Exporter
	elif root == "Camera": obj = Global.Camera
	elif root == "Level": obj = Global.World.GetCurrentLevel()
	elif root.begins_with("Tool:"): obj = Global.Editor.Tools.get(root.substr(5), null)
	elif root.begins_with("Window:"): obj = Global.Editor.Windows.get(root.substr(7), null)
	elif root.begins_with("Element:") and root.substr(8).is_valid_integer(): obj = Global.World.GetNodeByID(int(root.substr(8)))
	elif root.begins_with("Level:") and root.substr(6).is_valid_integer(): obj = Global.World.GetLevelByID(int(root.substr(6)))
	elif root.begins_with("Handle:"): obj = _native_handles.get(root.substr(7), null)
	for i in range(1, parts.size()):
		if obj == null or str(parts[i]).begins_with("_"): return null
		if parts[i] in ["owner", "multiplayer", "custom_multiplayer", "script"] or str(parts[i]).find("<") != -1: return null
		if typeof(obj) == TYPE_DICTIONARY: obj = obj.get(parts[i], null)
		elif typeof(obj) == TYPE_ARRAY:
			if not str(parts[i]).is_valid_integer(): return null
			var index = int(parts[i])
			if index < 0 or index >= obj.size(): return null
			obj = obj[index]
		elif typeof(obj) == TYPE_OBJECT and is_instance_valid(obj): obj = _native_read(obj, parts[i])
		else: return null
	if typeof(obj) == TYPE_OBJECT and not is_instance_valid(obj): return null
	return obj

func _native_pack(value, depth = 0):
	if depth > 8: return { "truncated": true }
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_REAL, TYPE_STRING: return value
		TYPE_VECTOR2: return { "$type": "Vector2", "value": [value.x, value.y] }
		TYPE_VECTOR3: return { "$type": "Vector3", "value": [value.x, value.y, value.z] }
		TYPE_COLOR: return { "$type": "Color", "value": [value.r, value.g, value.b, value.a], "hex": "#" + value.to_html() }
		TYPE_RECT2: return { "$type": "Rect2", "value": [value.position.x, value.position.y, value.size.x, value.size.y] }
		TYPE_DICTIONARY:
			var out := {}
			for key in value: out[str(key)] = _native_pack(value[key], depth + 1)
			return out
		TYPE_ARRAY, TYPE_VECTOR2_ARRAY, TYPE_STRING_ARRAY, TYPE_INT_ARRAY, TYPE_REAL_ARRAY, TYPE_COLOR_ARRAY:
			var out := []
			for item in value:
				if out.size() >= 1000: break
				out.append(_native_pack(item, depth + 1))
			return out
		TYPE_RAW_ARRAY: return { "$type": "bytes", "size": value.size() }
		TYPE_OBJECT:
			if not is_instance_valid(value): return null
			var key = str(value.get_instance_id())
			_native_handles[key] = value
			var out = { "$target": "Handle:" + key, "class": value.get_class() }
			if value is Resource: out["resource_path"] = value.resource_path
			return out
	return str(value)

func _native_decode(value):
	if typeof(value) == TYPE_DICTIONARY:
		if value.has("$target"):
			var obj = _native_target(str(value["$target"]))
			if obj == null: return _err("invalid target reference: " + str(value["$target"]))
			return _ok(obj)
		if value.has("$type"):
			var kind = str(value["$type"])
			var v = value.get("value", null)
			if kind in ["Vector2", "Vector3", "Rect2", "Color"]:
				if kind == "Color" and typeof(v) == TYPE_STRING and v.begins_with("#") and v.length() in [7, 9]: return _ok(Color(v))
				if typeof(v) != TYPE_ARRAY: return _err(kind + " requires a numeric value array")
				var count = 2 if kind == "Vector2" else 3 if kind == "Vector3" else 4
				if v.size() != count: return _err(kind + " requires %d numbers" % count)
				for n in v:
					if not typeof(n) in [TYPE_INT, TYPE_REAL]: return _err(kind + " requires numeric components")
				if kind == "Vector2": return _ok(Vector2(v[0], v[1]))
				if kind == "Vector3": return _ok(Vector3(v[0], v[1], v[2]))
				if kind == "Rect2": return _ok(Rect2(v[0], v[1], v[2], v[3]))
				return _ok(Color(v[0], v[1], v[2], v[3]))
			if kind == "Vector2Array":
				if typeof(v) != TYPE_ARRAY: return _err("Vector2Array requires an array")
				var points = PoolVector2Array()
				for p in v:
					if typeof(p) != TYPE_ARRAY or p.size() != 2: return _err("invalid Vector2Array point")
					if not typeof(p[0]) in [TYPE_INT, TYPE_REAL] or not typeof(p[1]) in [TYPE_INT, TYPE_REAL]: return _err("non-numeric point")
					points.append(Vector2(p[0], p[1]))
				return _ok(points)
			if kind == "StringArray":
				if typeof(v) != TYPE_ARRAY: return _err("StringArray requires an array")
				for s in v:
					if typeof(s) != TYPE_STRING: return _err("StringArray requires strings")
				return _ok(PoolStringArray(v))
			if kind == "Texture":
				var tex = _asset_tex(str(value.get("category", "Objects")), value.get("asset", ""))
				if tex == null: return _err("texture is not in the loaded asset bank")
				return _ok(tex)
			if kind == "Image":
				var path = str(value.get("path", ""))
				if path == "" or not File.new().file_exists(path): return _err("image file does not exist")
				var img = Image.new()
				var code = img.load(path)
				if code != OK: return _err("image decoding failed: %d" % code)
				return _ok(img)
			return _err("unsupported tagged type: " + kind)
		var out := {}
		for key in value:
			var decoded = _native_decode(value[key])
			if not decoded.ok: return decoded
			out[key] = decoded.result
		return _ok(out)
	if typeof(value) == TYPE_ARRAY:
		var out := []
		for item in value:
			var decoded = _native_decode(item)
			if not decoded.ok: return decoded
			out.append(decoded.result)
		return _ok(out)
	return _ok(value)

func _native_targets() -> Dictionary:
	var targets := ["World", "Header", "Editor", "Exporter", "Camera", "Level"]
	for key in Global.Editor.Tools: targets.append("Tool:" + str(key))
	for key in Global.Editor.Windows: targets.append("Window:" + str(key))
	var lvl = Global.World.GetCurrentLevel()
	if lvl != null:
		for prop in lvl.get_property_list():
			if int(prop.get("type", 0)) == TYPE_OBJECT and not str(prop.name).begins_with("_") and not prop.name in ["owner", "multiplayer", "custom_multiplayer", "script"] and str(prop.name).find("<") == -1: targets.append("Level." + str(prop.name))
	return _ok({ "targets": targets, "protocol": PROTOCOL_VERSION, "engine": Engine.get_version_info() })

func _native_describe(req : Dictionary) -> Dictionary:
	var target = str(req.get("target", "Level"))
	var obj = _native_target(target)
	if obj == null or typeof(obj) != TYPE_OBJECT: return _err("target is not an available object: " + target)
	var search = str(req.get("search", "")).to_lower()
	var methods := []
	var properties := []
	for info in obj.get_method_list():
		var name = str(info.name)
		if name.begins_with("_") or name.find("<") != -1 or name.begins_with(".") or (search != "" and name.to_lower().find(search) == -1): continue
		if _native_public(name): methods.append(_native_pack(info))
	for info in obj.get_property_list():
		var name = str(info.name)
		if name.begins_with("_") or name.find("<") != -1 or name in ["script", "owner", "multiplayer", "custom_multiplayer"] or int(info.get("usage", 0)) & 128 or (search != "" and name.to_lower().find(search) == -1): continue
		properties.append(_native_pack(info))
	return _ok({ "target": target, "class": obj.get_class(), "methods": methods, "properties": properties })

func _native_get(req : Dictionary) -> Dictionary:
	var obj = _native_target(str(req.get("target", "Level")))
	if obj == null or typeof(obj) != TYPE_OBJECT: return _err("target is not available")
	var names = req.get("properties", [])
	if typeof(names) != TYPE_ARRAY: return _err("properties must be an array")
	var out := {}
	for name in names:
		if typeof(name) != TYPE_STRING or str(name).begins_with("_") or str(name).find("<") != -1 or name in ["script","owner","multiplayer","custom_multiplayer"]: return _err("invalid property name")
		var found = obj.has_method("get_" + name)
		for info in obj.get_property_list():
			if str(info.name) == name: found = true
		if not found: return _err("property not advertised by this version: " + str(name))
		out[name] = _native_pack(_native_read(obj,name))
	return _ok(out)

func _native_call(req : Dictionary) -> Dictionary:
	var obj = _native_target(str(req.get("target", "Level")))
	if obj == null or typeof(obj) != TYPE_OBJECT: return _err("target is not available")
	var method = str(req.get("method", ""))
	if method == "" or method.begins_with("_") or method.find("<") != -1 or method.begins_with("."): return _err("a public method is required")
	if not _native_public(method): return _err("only Dungeondraft API methods are callable")
	var info = null
	for entry in obj.get_method_list():
		if str(entry.name) == method: info = entry
	if info == null: return _err("method is not advertised by this version: " + method)
	var args = req.get("args", [])
	if typeof(args) != TYPE_ARRAY: return _err("args must be an array")
	var declared = info.get("args", [])
	var defaults = info.get("default_args", [])
	if args.size() < declared.size() - defaults.size() or args.size() > declared.size(): return _err("wrong argument count; inspect native_describe first")
	var converted := []
	for i in range(args.size()):
		var decoded = _native_decode(args[i])
		if not decoded.ok: return decoded
		var val = decoded.result
		var wanted = int(declared[i].get("type", 0))
		if wanted == TYPE_INT and typeof(val) in [TYPE_INT, TYPE_REAL]:
			if float(val) != float(int(val)): return _err("non-integer argument: " + str(i))
			val = int(val)
		elif wanted == TYPE_REAL and typeof(val) in [TYPE_INT, TYPE_REAL]: val = float(val)
		elif wanted != TYPE_NIL and typeof(val) != wanted: return _err("argument %d type mismatch: expected %d, got %d" % [i, wanted, typeof(val)])
		if wanted == TYPE_OBJECT:
			var cls = str(declared[i].get("class_name", ""))
			if val == null or (cls != "" and not val.is_class(cls)): return _err("object argument class mismatch: " + cls)
		converted.append(val)
	return _ok({ "target": req.target, "method": method, "value": _native_pack(obj.callv(method, converted)), "undoable": false })

func _native_set(req : Dictionary) -> Dictionary:
	var obj = _native_target(str(req.get("target", "Level")))
	if obj == null or typeof(obj) != TYPE_OBJECT: return _err("target is not available")
	var prop = str(req.get("property", ""))
	if prop == "" or prop.begins_with("_") or prop.find("<") != -1 or prop in ["script", "owner", "filename", "multiplayer", "custom_multiplayer"]: return _err("invalid native property")
	var info = null
	for item in obj.get_property_list():
		if str(item.name) == prop: info = item
	if info == null: return _err("property not advertised by this version")
	if obj.has_method("get_"+prop) and not obj.has_method("set_"+prop): return _err("native property is read-only; call its documented operation instead")
	var decoded = _native_decode(req.get("value", null))
	if not decoded.ok: return decoded
	var val = decoded.result
	var wanted = int(info.get("type", 0))
	if wanted == TYPE_INT and typeof(val) in [TYPE_INT, TYPE_REAL]:
		if float(val) != float(int(val)): return _err("an integer value is required")
		val = int(val)
	elif wanted == TYPE_REAL and typeof(val) in [TYPE_INT, TYPE_REAL]: val = float(val)
	elif wanted != TYPE_NIL and typeof(val) != wanted: return _err("property type mismatch")
	if obj.has_method("set_" + prop): obj.call("set_" + prop, val)
	else: obj.set(prop, val)
	var actual = _native_read(obj, prop)
	if not _native_equal(actual, val): return _err("native property did not retain the requested value; use its documented setter")
	return _ok({ "target": req.target, "property": prop, "value": _native_pack(actual), "undoable": false })

func _native_equal(a, b) -> bool:
	if typeof(a) in [TYPE_INT,TYPE_REAL] and typeof(b) in [TYPE_INT,TYPE_REAL]:
		return abs(float(a)-float(b)) <= 0.000001 * max(1.0,max(abs(float(a)),abs(float(b))))
	if typeof(a) != typeof(b): return false
	if typeof(a) in [TYPE_VECTOR2,TYPE_VECTOR3,TYPE_COLOR,TYPE_RECT2]: return a.is_equal_approx(b)
	if typeof(a) == TYPE_ARRAY:
		if a.size() != b.size(): return false
		for i in range(a.size()):
			if not _native_equal(a[i],b[i]): return false
		return true
	return a == b

# High-level operations that retain the normal Dungeondraft save format.
func _terrain_snapshot(level) -> Dictionary:
	return { "splat": level.Terrain.CloneSplatImage(), "splat2": level.Terrain.CloneSplatImage2() if level.Terrain.ExpandedSlots else null, "textures": level.Terrain.textures.duplicate(), "expanded": level.Terrain.ExpandedSlots }

func _restore_terrain(state, level_id):
	var level = Global.World.GetLevelByID(int(level_id))
	if level == null: return
	level.Terrain.ExpandSlots(state.expanded)
	for slot in range(state.textures.size()):
		if state.textures[slot] != null: level.Terrain.SetTexture(state.textures[slot], slot)
	if state.splat2 != null: level.Terrain.RestoreSplat2(state.splat, state.splat2)
	else: level.Terrain.RestoreSplat(state.splat)
	level.Terrain.UpdateSplat()

func _import_image(req : Dictionary) -> Dictionary:
	var lvl = Global.World.GetCurrentLevel()
	if lvl == null: return _err("no map open")
	var path = str(req.get("path", ""))
	var input_file = File.new()
	if not input_file.file_exists(path): return _err("image file does not exist")
	if path.get_extension().to_lower() != "png": return _err("embedded images currently require PNG")
	var s = float(req.get("scale", 1.0))
	if s <= 0: return _err("invalid image scale")
	var layer = int(req.get("layer", 100))
	if not lvl.SaveLayers().has(layer): return _err("layer does not exist; call list_layers")
	# EmbedObject already creates and records a REAL prop in 1.2.0.1. It is not
	# a preview loader. Locate the newly recorded prop without finalizing a
	# tool preview a second time.
	var existing := {}
	for node in lvl.Objects.get_children(): existing[node.get_instance_id()] = true
	Global.Editor.Tools["ObjectTool"].EmbedObject(path)
	var prop = null
	for node in lvl.Objects.get_children():
		if not existing.has(node.get_instance_id()): prop = node
	if prop == null: return _err("native embedding did not create a prop")
	prop.position = _xy(req, Global.World.WoxelDimensions * 0.5)
	prop.scale = Vector2(s, s)
	prop.rotation = deg2rad(float(req.get("rotation", 0.0)))
	prop.z_index = layer
	prop.HasShadow = bool(req.get("shadow", false))
	var source_image = Image.new()
	if source_image.load(path) == OK:
		prop.set_meta("dd_mcp_alpha_rect", source_image.get_used_rect())
		_spatial_alpha_cache[str(prop.Texture.get_instance_id()) + ":" + str(prop.Texture.resource_path)] = source_image.get_used_rect()
	var nid = _id(prop)
	return _ok({ "id": nid, "embedded": true, "image_size": [prop.Texture.get_width(), prop.Texture.get_height()], "layer": layer, "position": _vec(prop.position), "scale": s })


func _configure_terrain(req : Dictionary) -> Dictionary:
	var lvl = Global.World.GetCurrentLevel()
	if lvl == null: return _err("no map open")
	if req.has("expanded"): lvl.Terrain.ExpandSlots(bool(req.expanded))
	if req.has("smooth"): lvl.Terrain.SetSmoothBlending(bool(req.smooth))
	if req.has("enabled"): lvl.Terrain.visible = bool(req.enabled)
	var textures := []
	for tex in lvl.Terrain.textures: textures.append(tex.resource_path if tex != null else "")
	return _ok({ "expanded": lvl.Terrain.ExpandedSlots, "smooth": lvl.Terrain.SmoothBlending, "enabled": lvl.Terrain.visible, "textures": textures })

func _configure_environment(req : Dictionary) -> Dictionary:
	var lvl = Global.World.GetCurrentLevel()
	if lvl == null: return _err("no map open")
	var before = lvl.SaveEnvironment()
	if req.has("ambient"):
		Global.Editor.Tools["Environment"].SetAmbientLight(_color(req.ambient, Color(1,1,1)))
	if req.has("lighting"):
		for level in Global.World.levels: level.ToggleLighting(bool(req.lighting))
		var toggle = _native_read(Global.Editor, "LightingToggle")
		if toggle != null: toggle.set_pressed_no_signal(bool(req.lighting))
	if req.has("grid"): Global.Editor.ToggleGrid(bool(req.grid))
	var settings = Global.Editor.Tools.get("MapSettings", null)
	if req.has("grid_color") and settings != null: settings.SetGridColor(_color(req.grid_color, Color(1,1,1)))
	if req.has("grid_style") and settings != null: settings.SetGridStyle(int(req.grid_style))
	if req.has("camera_filter") and settings != null: settings.SetCameraFilter(int(req.camera_filter))
	if req.has("building_wear") and settings != null: settings.SetBuildingWear(int(req.building_wear))
	return _ok({ "before": before, "environment": lvl.SaveEnvironment() })

func _modify_light(req : Dictionary) -> Dictionary:
	var node = _resolve(req)
	if node == null or not node is Light2D: return _err("id is not a light")
	node.set_meta("preview", false)
	if req.has("color"): node.color = _color(req.color, node.color)
	if req.has("energy"): node.energy = float(req.energy)
	if req.has("range"): node.texture_scale = float(req.range)
	if req.has("shadows"): node.shadow_enabled = bool(req.shadows)
	if req.has("enabled"): node.enabled = bool(req.enabled)
	if req.has("rotation"): node.rotation = deg2rad(float(req.rotation))
	if req.has("asset"):
		var tex = _asset_tex("Lights", req.asset)
		if tex == null: return _err("light texture unavailable")
		node.texture = tex
	return _ok({ "id": int(req.id), "color": "#" + node.color.to_html(), "energy": node.energy, "range": node.texture_scale, "shadows": node.shadow_enabled, "enabled": node.enabled })

func _list_layers() -> Dictionary:
	var lvl = Global.World.GetCurrentLevel()
	if lvl == null: return _err("no map open")
	return _ok({ "level_id": lvl.ID, "layers": _native_pack(lvl.SaveLayers()), "locked": _native_pack(lvl.LockedLayers) })

func _set_layer(req : Dictionary) -> Dictionary:
	var lvl = Global.World.GetCurrentLevel()
	if lvl == null: return _err("no map open")
	var index = int(req.get("index", 100))
	if index < -4096 or index > 4096: return _err("layer is outside Godot's z-index range")
	var label = str(req.get("label", "Layer " + str(index)))
	var locked = lvl.get("LockedLayers")
	if index in [-600,-500,-300,-200,0,500,600,800,1000]: return _err("built-in layer is locked")
	var current = lvl.SaveLayers()
	if current.has(index): return _err("layer already exists; rename it through Tool:LayerSettings controls")
	lvl.LoadLayers({str(index):label})
	lvl.AddMaterialLayer(index)
	return _list_layers()

func _set_element_layer(req : Dictionary) -> Dictionary:
	var node = _resolve(req)
	var lvl = Global.World.GetCurrentLevel()
	if node == null or not node is Node2D: return _err("element does not support layers")
	var layer = int(req.get("layer", 100))
	if not lvl.SaveLayers().has(layer): return _err("layer does not exist")
	node.z_index = layer
	return _ok({ "id": int(req.id), "layer": node.z_index })

func _draw_water(req : Dictionary) -> Dictionary:
	var lvl = Global.World.GetCurrentLevel()
	if lvl == null: return _err("no map open")
	var pts = _shape_points(req)
	if pts.size() < 3: return _err("rect or >= 3 polygon points required")
	var water = lvl.WaterMesh
	water.DrawPolygon(pts, bool(req.get("erase", false)))
	water.UpdateMesh(false)
	return _ok({ "drawn": true, "erase": bool(req.get("erase", false)), "points": _native_pack(pts) })

func _configure_water(req : Dictionary) -> Dictionary:
	var lvl = Global.World.GetCurrentLevel()
	if lvl == null: return _err("no map open")
	var water = lvl.WaterMesh
	if req.has("deep_color"): water.DeepColor = _color(req.deep_color, water.DeepColor)
	if req.has("shallow_color"): water.ShallowColor = _color(req.shallow_color, water.ShallowColor)
	if req.has("blend_distance"): water.BlendDistance = float(req.blend_distance)
	if req.has("border"): water.DisableBorder(not bool(req.border))
	water.UpdateMesh(false)
	return _ok({ "deep_color": "#" + water.DeepColor.to_html(), "shallow_color": "#" + water.ShallowColor.to_html(), "blend_distance": water.BlendDistance, "border": not water.disableBorder,"scope":"future_water_brush_defaults" })

func _shape_points(req : Dictionary) -> PoolVector2Array:
	if req.has("rect"):
		var r = req.rect
		if typeof(r) != TYPE_ARRAY or r.size() != 4: return PoolVector2Array()
		if float(r[2]) <= 0 or float(r[3]) <= 0: return PoolVector2Array()
		return PoolVector2Array([Vector2(r[0],r[1]), Vector2(r[0]+r[2],r[1]), Vector2(r[0]+r[2],r[1]+r[3]), Vector2(r[0],r[1]+r[3])])
	return _points(req.get("points", []))

func _draw_material(req : Dictionary) -> Dictionary:
	var lvl = Global.World.GetCurrentLevel()
	if lvl == null: return _err("no map open")
	var pts = _shape_points(req)
	if pts.size() < 3: return _err("rect or >= 3 polygon points required")
	var tex = _asset_tex("Materials", req.get("asset", ""))
	if tex == null: return _err("material asset unavailable")
	var layer = int(req.get("layer", 100))
	if not lvl.SaveLayers().has(layer): return _err("layer does not exist")
	var mesh = lvl.GetOrMakeMaterialMesh(layer, tex, bool(req.get("smooth", true)))
	if mesh == null or not mesh.has_method("get_Bitmap"): return _err("material bitmap API is unavailable")
	var bitmap = mesh.call("get_Bitmap").duplicate(true)
	var dims = bitmap.get_size()
	var cell_size = float(mesh.call("get_CellSize"))
	var buffer = int(_native_read(mesh,"MapEdgeBuffer"))
	if cell_size <= 0: return _err("material grid has invalid cell size")
	var polygon := []
	for point in pts: polygon.append(point)
	var minp = pts[0]
	var maxp = pts[0]
	for point in pts:
		minp.x = min(minp.x, point.x)
		minp.y = min(minp.y, point.y)
		maxp.x = max(maxp.x, point.x)
		maxp.y = max(maxp.y, point.y)
	for y in range(max(0,int(floor(minp.y/cell_size))+buffer), min(int(dims.y),int(ceil(maxp.y/cell_size))+buffer)):
		for x in range(max(0,int(floor(minp.x/cell_size))+buffer), min(int(dims.x),int(ceil(maxp.x/cell_size))+buffer)):
			if _point_in_poly(Vector2((x-buffer+0.5)*cell_size,(y-buffer+0.5)*cell_size), polygon): bitmap.set_bit(Vector2(x,y), not bool(req.get("erase", false)))
	mesh.call("SetBitmap", bitmap)
	mesh.call("UpdateMesh")
	if mesh.has_method("FinalizeMeshAndBorders"): mesh.call("FinalizeMeshAndBorders")
	return _ok({ "drawn": true, "layer": layer, "asset": req.asset,"cell_size":cell_size,"grid_buffer":buffer })

func _configure_object(req : Dictionary) -> Dictionary:
	var node = _resolve(req)
	if node == null: return _err("element not found")
	if req.has("mirror"):
		if node.get("Mirror") == null: return _err("element has no mirror setting")
		node.set("Mirror", bool(req.mirror))
	if req.has("block_light"):
		if not node.has_method("SetBlockLight"): return _err("element cannot block light")
		node.call("SetBlockLight", bool(req.block_light))
	if req.has("layer"):
		var res = _set_element_layer(req)
		if not res.ok: return res
	if req.has("asset"):
		var tex = _asset_tex("Objects", req.asset)
		if tex == null or not node.has_method("SetTexture"): return _err("object texture unavailable")
		node.call("SetTexture", tex)
		if node.has_meta("dd_mcp_alpha_rect"): node.remove_meta("dd_mcp_alpha_rect")
	return _ok({ "id": int(req.id), "layer": node.z_index, "mirror": node.get("Mirror"), "block_light": node.get("BlockLight") })

func _modify_text(req : Dictionary) -> Dictionary:
	var node = _resolve(req)
	if node == null or not _is_text(node): return _err("id is not a text label")
	if req.has("text"): node.text = str(req.text)
	if req.has("color"): node.SetFontColor(_color(req.color, Color(0,0,0)))
	if req.has("size") or req.has("font"): node.SetFont(str(req.get("font", node.fontName)), int(req.get("size", node.fontSize)))
	return _ok(_describe(node))

func _modify_wall(req : Dictionary) -> Dictionary:
	var node = _resolve(req)
	if node == null or not node.has_method("UpdateTexture") or not node.has_method("RemakeLines"): return _err("id is not a wall")
	if req.has("asset"):
		var tex = _asset_tex("Walls", req.asset)
		if tex == null: return _err("wall asset unavailable")
		node.UpdateTexture(tex)
	if req.has("color"): node.SetColor(_color(req.color, Color(1,1,1)))
	if req.has("shadow"): node.HasShadow = bool(req.shadow)
	if req.has("points"):
		var pts = _points(req.points)
		if pts.size() < 2: return _err(">= 2 wall points required")
		node.Set(pts, node.Texture, node.Color, bool(req.get("loop", node.Loop)), node.HasShadow, int(req.get("type", node.Type)), int(req.get("joint", node.Joint)), node.NormalizeUV)
	node.RemakeLines()
	return _ok(_describe(node))

func _set_trace_image(req : Dictionary) -> Dictionary:
	var path = str(req.get("path", ""))
	if path == "":
		Global.World.RemoveTraceImage()
		return _ok({ "cleared": true })
	if not File.new().file_exists(path): return _err("trace image does not exist")
	Global.World.AddTraceImage(path, float(req.get("scale", 1.0)), float(req.get("opacity", 0.5)))
	if bool(req.get("center", true)): Global.World.CenterTraceImage()
	Global.World.TraceImageVisible = bool(req.get("visible", true))
	return _ok({ "path": path, "reference_only": true })

func _rename_level(req : Dictionary) -> Dictionary:
	var level = Global.World.TryGetLevel(int(req.get("index", -1)))
	if level == null: return _err("level index out of range")
	level.Label = str(req.get("label", "Level"))
	Global.Editor.UpdateLevelOptions()
	return _list_levels()

func _clone_level(req : Dictionary) -> Dictionary:
	var level = Global.World.TryGetLevel(int(req.get("index", -1)))
	if level == null: return _err("level index out of range")
	var clone = Global.World.CloneLevel(level, str(req.get("label", "Copy")))
	if clone == null: return _err("clone failed")
	Global.Editor.UpdateLevelOptions()
	return _ok({ "id": clone.ID, "label": clone.Label })

func _reorder_levels(req : Dictionary) -> Dictionary:
	var ids = req.get("ids", [])
	if typeof(ids) != TYPE_ARRAY or ids.size() != Global.World.levels.size(): return _err("include every level id exactly once")
	var order := []
	var seen := {}
	for id in ids:
		var lv = Global.World.GetLevelByID(int(id))
		if lv == null or seen.has(int(id)): return _err("duplicate or unknown level")
		seen[int(id)] = true
		order.append(lv)
	Global.World.SetNewLevelOrder(order)
	return _list_levels()

func _compare_levels(req : Dictionary) -> Dictionary:
	var index = int(req.get("index", -1))
	if index == -1:
		Global.World.DisableCompareLevels()
		return _ok({ "enabled": false })
	var lv = Global.World.TryGetLevel(index)
	if lv == null: return _err("level index out of range")
	Global.World.SetCompareLevels(lv, float(req.get("reference_opacity", 0.35)), float(req.get("current_opacity", 1.0)), true)
	return _ok({ "enabled": true, "reference": lv.ID })

func _save_document(req : Dictionary) -> Dictionary:
	var source = str(_native_read(Global.Editor,"CurrentMapFile"))
	var path = str(req.get("path",source))
	if path == "" or not path.is_abs_path() or path.get_extension() != "dungeondraft_map": return _err("an absolute .dungeondraft_map path is required")
	for lvl in Global.World.levels:
		for container in [lvl.Lights,lvl.Pathways]:
			for node in container.get_children():
				if not node.has_meta("preview"): node.set_meta("preview",false)
	var world = Global.World.Save()
	if typeof(world) != TYPE_DICTIONARY: return _err("native world serialization failed; inspect component Save methods and asset availability")
	var payload = {"header":{"creation_build":"1.2.0.1 opulent kirin","creation_date":OS.get_datetime(),"uses_default_assets":true,"asset_manifest":[],"editor_state":{}},"world":world,"mod":{}}
	var file = File.new()
	if source != "" and file.open(source,File.READ) == OK:
		var original = JSON.parse(file.get_as_text())
		file.close()
		if original.error == OK and typeof(original.result) == TYPE_DICTIONARY:
			payload.header = original.result.get("header",payload.header)
			payload.mod = original.result.get("mod",{})
	var header = Global.Header.Save()
	if typeof(header) != TYPE_DICTIONARY: return _err("native header serialization failed")
	payload.header = header
	var temporary = path + ".mcp-tmp"
	if file.open(temporary,File.WRITE) != OK: return _err("cannot create map file")
	file.store_string(JSON.print(payload,"\t"))
	file.close()
	var directory = Directory.new()
	if file.file_exists(path):
		if directory.copy(path,path+".mcp-backup") != OK: return _err("cannot back up the existing destination")
		if directory.remove(path) != OK: return _err("cannot replace the existing destination")
	if directory.rename(temporary,path) != OK:
		if file.file_exists(path+".mcp-backup"): directory.copy(path+".mcp-backup",path)
		return _err("cannot finalize map file; previous destination restored where available")
	if bool(req.get("update_current",true)):
		Global.Editor.OnOpenedOrSaved(path)
	return _ok({"saved":true,"path":path,"levels":Global.World.levels.size(),"embedded_images":world.get("embedded",{}).size(),"native_serializer":true})

func _open_document(req : Dictionary) -> Dictionary:
	var path = str(req.get("path", ""))
	if not File.new().file_exists(path) or path.get_extension() != "dungeondraft_map": return _err("map file does not exist")
	var file = File.new()
	if file.open(path, File.READ) != OK: return _err("cannot read map file")
	var parsed = JSON.parse(file.get_as_text())
	file.close()
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY or not parsed.result.has("world"): return _err("invalid map file")
	Global.Editor.ForceOpenMap(path)
	_undo_stack.clear()
	_redo_stack.clear()
	return _ok({ "opened": true, "path": path })

func _export_document(req : Dictionary) -> Dictionary:
	var path = str(req.get("path", ""))
	var mode = int(req.get("mode", 0))
	var ppi = int(req.get("ppi", 128))
	if path == "" or not path.is_abs_path() or mode < 0 or mode > 3 or ppi < 8 or ppi > 1024: return _err("invalid export path, format or resolution")
	if req.has("quality"): Global.Exporter.Quality = int(req.quality)
	Global.Editor.ToggleGrid(bool(req.get("grid",false)))
	Global.Exporter.Start(mode, ppi, path)
	return _ok({ "path": path, "mode": mode, "ppi": ppi, "grid":bool(req.get("grid",false)),"async": true })

func _capabilities() -> Dictionary:
	return _ok({ "protocol": PROTOCOL_VERSION, "image_import": true, "native_api": true, "terrain": true, "water": true, "materials": true, "lighting": true, "levels": true, "layers": true, "elevation": { "native_3d_heightmap": false, "visual_cliffs": true, "layer_order": true, "multiple_floors": true }, "native_targets": _native_targets().result.targets })

# Access the application's own controls for operations with no public API.
# Only descendants of the discovered Editor/Tool/Window are accessible.
func _ui_tree(req : Dictionary) -> Dictionary:
	var target = str(req.get("target", "Editor"))
	var root = _native_target(target)
	if root == null: return _err("UI target is unavailable")
	var entries := []
	var search = str(req.get("search", "")).to_lower()
	var limit = int(req.get("limit",500))
	if root is Node: _ui_walk(root, "", 0, entries, search, limit)
	else:
		for method in root.get_method_list():
			if str(method.name).begins_with("get_") and method.args.empty() and int(method["return"].get("type",0)) == TYPE_OBJECT:
				var control = root.call(method.name)
				if control != null and control is Node: _ui_walk(control, target+"."+str(method.name).substr(4), 0, entries, search, limit)
		if entries.empty(): _ui_walk(Global.Editor, "",0,entries,search,limit)
	return _ok({"target":target,"controls":entries,"limit":int(req.get("limit",500))})

func _ui_walk(node, path, depth, entries, search, limit):
	if depth > 24 or entries.size() >= min(1500,max(1,limit)): return
	path += "/" + str(node.name)
	if node is Control:
		var entry = _native_pack(node)
		entry["path"] = path
		entry["visible"] = node.is_visible_in_tree()
		entry["kind"] = node.get_class()
		if node is BaseButton: entry["disabled"] = node.disabled
		if node is Button or node is Label or node is LineEdit or node is TextEdit: entry["text"] = node.text
		if node is BaseButton and node.toggle_mode: entry["checked"] = node.pressed
		if node is Range:
			entry["value"] = node.value
			entry["min"] = node.min_value
			entry["max"] = node.max_value
		if node is OptionButton:
			entry["selected"] = node.selected
			var items := []
			for index in range(node.get_item_count()): items.append({"index":index,"id":node.get_item_id(index),"text":node.get_item_text(index)})
			entry["items"] = items
		if node is ColorPickerButton: entry["color"] = _native_pack(node.color)
		if search == "" or JSON.print(entry).to_lower().find(search) != -1: entries.append(entry)
	for child in node.get_children(): _ui_walk(child,path,depth+1,entries,search,limit)

func _ui_action(req : Dictionary) -> Dictionary:
	var node = _native_target(str(req.get("target","")))
	if node == null or not node is Control: return _err("select a live control handle returned by ui_tree")
	var action = str(req.get("action", ""))
	var value = req.get("value",null)
	match action:
		"press":
			if not node is BaseButton or node.disabled: return _err("control is not an enabled button")
			if node.toggle_mode: node.pressed = not node.pressed
			node.call_deferred("emit_signal","pressed")
		"check":
			if not node is BaseButton or not node.toggle_mode or typeof(value) != TYPE_BOOL or node.disabled: return _err("a toggle button and boolean value are required")
			node.pressed = value
		"value":
			if not node is Range or not typeof(value) in [TYPE_INT,TYPE_REAL]: return _err("a numeric range control is required")
			if float(value)<node.min_value or float(value)>node.max_value: return _err("value is outside the control range")
			node.value = float(value)
		"text":
			if not (node is LineEdit or node is TextEdit) or typeof(value)!=TYPE_STRING: return _err("a text field is required")
			node.text = value
			node.emit_signal("text_changed",value) if node is LineEdit else node.emit_signal("text_changed")
		"submit":
			if not node is LineEdit: return _err("a line edit is required")
			node.emit_signal("text_entered",node.text)
		"select":
			if not node is OptionButton or not typeof(value) in [TYPE_INT,TYPE_REAL] or float(value)!=float(int(value)): return _err("an option button and integer index are required")
			var index = int(value)
			if index<0 or index>=node.get_item_count() or node.is_item_disabled(index): return _err("invalid option index")
			node.select(index)
			node.emit_signal("item_selected",index)
		"color":
			if not node is ColorPickerButton or typeof(value)!=TYPE_STRING: return _err("a color picker is required")
			node.color = Color(value)
			node.emit_signal("color_changed",node.color)
		"show":
			if node is Popup: node.popup_centered()
			else: node.show()
		"hide": node.hide()
		_: return _err("unsupported action; use press/check/value/text/submit/select/color/show/hide")
	return _ok({"target":req.target,"action":action,"undoable":false})
