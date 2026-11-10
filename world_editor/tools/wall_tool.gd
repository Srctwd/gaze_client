extends "res://world_editor/tools/place_tool.gd"

# Walls page: OBB walls, slabs, stairs, rooms and carved openings.
# Reaches the editor (world, camera, shared type tables, status line, undo
# history) through `ed`; see tools/place_tool.gd for the hooks main.gd calls.

var _ghost: Node3D  # this tool's own placement preview

const RampMesh := preload("res://world/ramp_mesh.gd")
const PillarTool := preload("res://world_editor/tools/pillar_tool.gd")
var _pillar: PillarTool            # the Pillar shape — its hooks are forwarded there
var _pillar_section: VBoxContainer # its settings, shown only for the Pillar shape
var _is_pillar: bool:
	get: return _wall_shape == "pillar"

var _wall_drag_start:      Vector3 = Vector3.ZERO
var _wall_dragging:        bool    = false
var _wall_height:          float   = 3.0
var _wall_half_thickness:  float   = 0.1
var _wall_y:               float   = 0.0     # absolute world Y of the wall's base — terrain height is ignored
var _wall_shape:           String  = "line"  # "line" (single segment), "square" (drags out a 4-wall rectangle) or "slab" (one floor/ceiling slab over the rectangle), "stairs" (a flight of solid steps along the drag), "ramp" (one sloped wedge along the drag, same rectangle as stairs), "room" (square walls + roof slab) or "negative" (carve)
var _stair_step:           float   = 0.2     # max rise per step — the step count rounds up so every step is <= this (server max_climb is 0.2)
var _stair_cut_slabs:      bool    = true    # carve a stairwell into floor/ceiling slabs the flight would bonk a player's head on
var _stair_step_row:       Control           # "Step" field row — only shown for the Stairs shape
var _stair_dir:            int     = 0       # Stairs/Ramp climb direction, cycled with R: 0 +X, 1 +Z, 2 -X, 3 -Z
var _room_floor:           bool    = false   # Room shape also places a floor slab under its walls
var _wall_thick_edit:      LineEdit          # Thickness field — refreshed when Alt copies a wall's thickness
var _wall_y_edit:          LineEdit          # Y field — refreshed by Shift+Scroll and [Y] (copy the selected wall's Y)
var _wall_height_edit:     LineEdit          # Height field — refreshed by Scroll and [Y] on a pillar
var _wall_alt_latched:     bool    = false   # Alt was held at some point during this drag — its snap/lock has been applied
var _neg_wall:             Dictionary = {}   # Negative + Alt: the wall this drag's cut is locked to ({} = free, slab-like rect)
var _neg_start_local:      Vector2 = Vector2.ZERO  # drag start in _neg_wall's local (x, z) frame
var _wall_snap_drag:       bool    = false   # Ctrl state latched at drag start — the whole drag (preview and placement) snaps or doesn't
var _wall_negative:        bool:              # the "negative" shape: drag carves the dragged rect (Y..Y+Height) out of walls
	get: return _wall_shape == "negative"
var _wall_selected:        Dictionary = {}   # the clicked wall (same Dictionary as in _wd._walls) — what Delete/G act on; {} = none
var _wall_press_mouse:     Vector2 = Vector2.ZERO  # screen position of the LMB press, to tell a click from a drag
var _wall_hover_mesh:      MeshInstance3D    # red highlight over the selected wall
var _wall_paint_type:  int        = 0

# Before the drag starts, every shape previews as a zero-thickness post (Height
# tall, from Y) on the exact point the drag will start from — the snapped
# corner for Square/Slab/Room/Stairs/Negative, the wall's end point for Line.
const ANCHOR_POST_SIZE := 0.03
# Line shape: a drag shorter than this is a click, which places a post.
const POST_CLICK_DIST := 0.05
# LMB press-to-release movement (pixels) under which it counts as a click,
# which selects the wall under the crosshair instead of building.
const SELECT_CLICK_PX := 4.0


# ── Stairs / Room — multi-box shapes ─────────────────────────────────────────
# Both are described as a list of "parts" ({cx, cz, half_x, half_z, rot_y,
# base, height}; base = absolute Y of the box's bottom) built by one function
# that the ghost and the placement share, so the preview IS the result.

const STAIR_MAX_STEPS    := 200
const PLAYER_CLEARANCE   := 1.5   # server player capsule is 1.4 tall (radius 0.4 + height 1.0)

func _ready() -> void:
	_pillar = PillarTool.new()
	_pillar.ed = ed
	_pillar.walls = self
	add_child(_pillar)


func _wall_type_name(id: int) -> String:
	if ed._wall_type_defs.has(id):
		return (ed._wall_type_defs[id] as Dictionary).get("name", "?") as String
	return "Unknown(%d)" % id


# Wall rotation convention: rot_y such that the wall's local +X axis (its
# length, half_x) points toward the drag end point. This must match the
# server's box-vs-capsule rotation convention (Matrix4::rotateY in scmath.h) —
# local→world is (x*cos+z*sin, -x*sin+z*cos), which is exactly Godot's own
# rotation.y convention, so no extra sign-flip is needed here.
func _wall_rot_from_drag(dx: float, dz: float) -> float:
	return atan2(-dz, dx)

# Where the mouse ray meets the horizontal plane at the wall Y — the height the
# wall's base is actually built at. Aiming at terrain instead would put the
# drag points under the cursor only when the terrain happens to be at that Y;
# anywhere else the ghost (drawn at the wall Y) drifts away from the cursor
# and the snapped grid points look shifted.
func _wall_cursor(mouse_pos: Vector2) -> Vector3:
	var origin := ed._cam.project_ray_origin(mouse_pos)
	var dir    := ed._cam.project_ray_normal(mouse_pos)
	if absf(dir.y) > 0.0001:
		var t := (_wall_y - origin.y) / dir.y
		if t > 0.0:
			return origin + dir * t
	return ed._raycast_or_plane(mouse_pos)

func _snap_wall_point(p: Vector3) -> Vector3:
	var snap := _wall_snap_drag if _wall_dragging else Input.is_key_pressed(KEY_CTRL)
	if not snap:
		return p
	var cs := ed._wd.cell_size
	return Vector3(roundf(p.x / cs) * cs, p.y, roundf(p.z / cs) * cs)

# Absolute Y of a wall's base — exactly the editor's Y value, never the terrain
# (height is always exactly _wall_height). Servers/clients re-derive the base
# from terrain under the wall's CENTER, so callers store y_offset relative to
# that — see _wall_stored_y_offset.
func _wall_base_y() -> float:
	return _wall_y

func _wall_stored_y_offset(base_y: float, cx: float, cz: float) -> float:
	return base_y - ed._wd._get_height_at(cx, cz)

func _wall_ghost_color() -> Color:
	return Color(0.95, 0.15, 0.15, 0.5) if _wall_negative else Color(0.9, 0.7, 0.1, 0.5)

# Keeps _ghost's child MeshInstance3Ds count equal to `count` (1 for a line
# wall, 4 for a square's edges) and re-tints them for the current negative
# state. Children are positioned/rotated directly in world space since this
# node and its parent are both at the origin.
func _ensure_wall_ghost_boxes(count: int) -> void:
	if _ghost == null or _ghost.get_meta("type") != ed.MODE_WALL:
		if _ghost: _ghost.queue_free()
		_ghost = Node3D.new()
		_ghost.set_meta("type", ed.MODE_WALL)
		add_child(_ghost)
	while _ghost.get_child_count() < count:
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency  = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		_ghost.add_child(mi)
	while _ghost.get_child_count() > count:
		var extra := _ghost.get_child(_ghost.get_child_count() - 1)
		_ghost.remove_child(extra)
		extra.queue_free()
	var col := _wall_ghost_color()
	for i in range(count):
		var mi := _ghost.get_child(i) as MeshInstance3D
		if not mi.mesh is BoxMesh: mi.mesh = BoxMesh.new()  # the Ramp ghost swaps in a wedge
		(mi.material_override as StandardMaterial3D).albedo_color = col

# Ray-vs-OBB intersection test for one wall entry ({x,z,half_x,half_z,rot_y,
# height,y_offset}), in the same local frame the ghost/placement code uses.
# Returns the ray parameter t of the nearest intersection, or null.
func _ray_wall_intersect(origin: Vector3, dir: Vector3, w: Dictionary):
	var half_x   := w.half_x as float
	var half_z   := w.half_z as float
	var height   := w.height as float
	var y_offset := w.get("y_offset", 0.0) as float
	var rot_y    := w.rot_y as float
	var wy       := ed._wd._get_height_at(w.x as float, w.z as float)
	var cy       := wy + y_offset + height * 0.5
	var half_y   := height * 0.5

	var cr := cos(rot_y)
	var sr := sin(rot_y)
	var rel := origin - Vector3(w.x as float, cy, w.z as float)
	var lox := cr * rel.x - sr * rel.z
	var loy := rel.y
	var loz := sr * rel.x + cr * rel.z
	var ldx := cr * dir.x - sr * dir.z
	var ldy := dir.y
	var ldz := sr * dir.x + cr * dir.z

	var tmin := -INF
	var tmax := INF

	if absf(ldx) < 1e-8:
		if lox < -half_x or lox > half_x: return null
	else:
		var t1 := (-half_x - lox) / ldx
		var t2 := (half_x - lox) / ldx
		if t1 > t2: var tmp := t1; t1 = t2; t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax: return null

	if absf(ldy) < 1e-8:
		if loy < -half_y or loy > half_y: return null
	else:
		var t1 := (-half_y - loy) / ldy
		var t2 := (half_y - loy) / ldy
		if t1 > t2: var tmp := t1; t1 = t2; t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax: return null

	if absf(ldz) < 1e-8:
		if loz < -half_z or loz > half_z: return null
	else:
		var t1 := (-half_z - loz) / ldz
		var t2 := (half_z - loz) / ldz
		if t1 > t2: var tmp := t1; t1 = t2; t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax: return null

	if tmax < 0.0: return null
	return maxf(tmin, 0.0)

# Finds the wall the crosshair is actually aiming at (nearest ray-vs-OBB hit),
# -1 when the ray lands on no wall — clicking empty ground selects nothing.
func _pick_wall_under_cursor() -> int:
	if ed._wd == null: return -1
	var mouse  := get_viewport().get_mouse_position()
	var origin := ed._cam.project_ray_origin(mouse)
	var dir    := ed._cam.project_ray_normal(mouse)

	var best_i := -1
	var best_t := INF
	for i in range(ed._wd._walls.size()):
		var t = _ray_wall_intersect(origin, dir, ed._wd._walls[i] as Dictionary)
		if t != null and (t as float) < best_t:
			best_t = t as float
			best_i = i
	return best_i

func _ensure_wall_hover_mesh() -> void:
	if _wall_hover_mesh != null: return
	_wall_hover_mesh = MeshInstance3D.new()
	_wall_hover_mesh.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency  = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.albedo_color  = Color(1.0, 0.1, 0.1, 0.01)   # steady, faint red tint
	_wall_hover_mesh.material_override = mat
	_wall_hover_mesh.visible = false
	add_child(_wall_hover_mesh)

func _hide_wall_hover() -> void:
	if _wall_hover_mesh: _wall_hover_mesh.visible = false

# Index of _wall_selected in _wd._walls (by identity), -1 when nothing is
# selected or the wall is gone (removed by a carve, undo, load...).
func _selected_wall_index() -> int:
	if _wall_selected.is_empty() or ed._wd == null: return -1
	for i in range(ed._wd._walls.size()):
		if is_same(ed._wd._walls[i], _wall_selected): return i
	_wall_selected = {}
	return -1

func _select_wall(index: int) -> void:
	if index < 0:
		if not _wall_selected.is_empty(): ed._set_status("Wall selection cleared")
		_wall_selected = {}
		return
	_wall_selected = ed._wd._walls[index] as Dictionary
	ed._set_status("Wall selected — [Del] remove  [G] clear openings  [Esc] deselect")

# Tints the selected wall red — the one Delete/G, Negative and every Alt
# action (corner snap, thickness copy, locked cut) work on. Hidden while
# dragging (unless Alt), since the drag ghost is the indicator then.
func _update_wall_hover() -> void:
	_ensure_wall_hover_mesh()
	var shown := _selected_wall_index()
	if shown < 0 or (_wall_dragging and not Input.is_key_pressed(KEY_ALT)):
		_wall_hover_mesh.visible = false
		return
	var w        := ed._wd._walls[shown] as Dictionary
	var half_x   := w.half_x as float
	var half_z   := w.half_z as float
	var height   := w.height as float
	var y_offset := w.get("y_offset", 0.0) as float
	var wy       := ed._wd._get_height_at(w.x as float, w.z as float)
	(_wall_hover_mesh.mesh as BoxMesh).size = Vector3(half_x * 2.0, height, half_z * 2.0)
	_wall_hover_mesh.position   = Vector3(w.x as float, wy + y_offset + height * 0.5, w.z as float)
	_wall_hover_mesh.rotation   = Vector3.ZERO
	_wall_hover_mesh.rotation.y = w.rot_y as float
	_wall_hover_mesh.visible = true

# Deletes the selected (clicked) wall — the Delete key.
func _delete_selected_wall() -> void:
	var i := _selected_wall_index()
	if i < 0:
		ed._set_status("No wall selected — click a wall first")
		return
	if ed._wd.remove_wall_at(i):
		ed._set_status("Wall removed")
	_wall_selected = {}
	ed._rebuild_walls()

# Removes every carved opening from the selected wall — back to its plain box.
func _clear_selected_wall_openings() -> void:
	var i := _selected_wall_index()
	if i < 0:
		ed._set_status("No wall selected — click a wall first")
		return
	var n := ed._wd.clear_wall_openings(i)
	ed._set_status("Removed %d opening(s) from wall" % n if n > 0 else "Wall has no openings")
	if n > 0: ed._rebuild_walls()

func _update_wall_ghost(hit_in: Vector3) -> void:
	_update_wall_hover()
	if _wall_negative:
		var w := _neg_target()
		if not w.is_empty():
			_update_neg_wall_ghost(w)
			return
	var hit := _snap_wall_point(hit_in)
	if not _wall_dragging:
		# Alt previews the start snap; the drag's end is never Alt-snapped,
		# so a new wall can be dragged away from the selected one.
		var corner = _alt_corner(get_viewport().get_mouse_position())
		if corner != null and not _wall_negative:
			hit = corner
		_update_wall_ghost_anchor(hit)
		return
	if _wall_shape == "square":
		_update_wall_ghost_square(hit)
	elif _wall_shape == "slab" or _wall_shape == "negative":
		_update_wall_ghost_slab(hit)
	elif _wall_shape == "stairs" or _wall_shape == "ramp" or _wall_shape == "room":
		_update_wall_ghost_parts(hit)
	else:
		_update_wall_ghost_line(hit)

func _update_wall_ghost_anchor(hit: Vector3) -> void:
	_ensure_wall_ghost_boxes(1)
	var mi := _ghost.get_child(0) as MeshInstance3D
	var h := maxf(_wall_height, 0.05)
	(mi.mesh as BoxMesh).size = Vector3(ANCHOR_POST_SIZE, h, ANCHOR_POST_SIZE)
	mi.position = Vector3(hit.x, _wall_base_y() + h * 0.5, hit.z)
	mi.rotation = Vector3.ZERO
	_ghost.visible = true

func _update_wall_ghost_line(hit: Vector3) -> void:
	var ax := _wall_drag_start.x if _wall_dragging else hit.x
	var az := _wall_drag_start.z if _wall_dragging else hit.z
	var bx := hit.x
	var bz := hit.z
	var dx := bx - ax
	var dz := bz - az
	var length := Vector2(dx, dz).length()
	if length < POST_CLICK_DIST:
		length = 0.0   # a click places a post: thickness x thickness, see _place_wall_line
	var cx := (ax + bx) * 0.5
	var cz := (az + bz) * 0.5
	var rot_y := _wall_rot_from_drag(dx, dz) if length > 0.0 else 0.0

	_ensure_wall_ghost_boxes(1)
	var mi := _ghost.get_child(0) as MeshInstance3D
	# Ends padded by half a thickness, like _place_wall_line.
	(mi.mesh as BoxMesh).size = Vector3(length + _wall_half_thickness * 2.0, _wall_height, _wall_half_thickness * 2.0)
	mi.position       = Vector3(cx, _wall_base_y() + _wall_height * 0.5, cz)
	mi.rotation       = Vector3.ZERO
	mi.rotation.y     = rot_y
	_ghost.visible    = true

	if _wall_dragging:
		ed._set_status("Wall: %.2fm  rot=%.0f°  h=%.2f  t=%.2f  y=%.2f  [Scroll] height  [Shift+Scroll] Y  [Esc] cancel" %
			[length, rad_to_deg(rot_y), _wall_height, _wall_half_thickness * 2.0, _wall_y])

func _update_wall_ghost_square(hit: Vector3) -> void:
	var ax := _wall_drag_start.x if _wall_dragging else hit.x
	var az := _wall_drag_start.z if _wall_dragging else hit.z
	var bx := hit.x
	var bz := hit.z
	var x0 := minf(ax, bx)
	var z0 := minf(az, bz)
	var w  := maxf(maxf(ax, bx) - x0, 0.5)
	var d  := maxf(maxf(az, bz) - z0, 0.5)
	var x1 := x0 + w
	var z1 := z0 + d

	_ensure_wall_ghost_boxes(4)
	var base_y := _wall_base_y()
	# Perimeter edges, each running toward the next corner (matches the line
	# wall's rotation convention so corners seal the same way).
	var edges := [
		[x0, z0, x1, z0],
		[x1, z0, x1, z1],
		[x1, z1, x0, z1],
		[x0, z1, x0, z0],
	]
	for i in range(4):
		var e: Array = edges[i]
		var edx := e[0] as float
		var edz := e[1] as float
		var fdx := e[2] as float
		var fdz := e[3] as float
		var dx  := fdx - edx
		var dz  := fdz - edz
		var length := Vector2(dx, dz).length()
		var cx  := (edx + fdx) * 0.5
		var cz  := (edz + fdz) * 0.5
		var rot_y := _wall_rot_from_drag(dx, dz)
		var mi  := _ghost.get_child(i) as MeshInstance3D
		(mi.mesh as BoxMesh).size = Vector3(length + _wall_half_thickness * 2.0, _wall_height, _wall_half_thickness * 2.0)
		mi.position   = Vector3(cx, base_y + _wall_height * 0.5, cz)
		mi.rotation   = Vector3.ZERO
		mi.rotation.y = rot_y
	_ghost.visible = true

	if _wall_dragging:
		ed._set_status("Square: %.2f x %.2f  h=%.2f  t=%.2f  y=%.2f  [Esc] cancel" %
			[w, d, _wall_height, _wall_half_thickness * 2.0, _wall_y])

# ── Negative + Alt: cut aligned to one wall ───────────────────────────────────
# Holding Alt locks the cut to the selected wall's own frame, so it follows
# that wall's rotation (diagonal walls too) and only affects that wall. Upright
# walls: the drag sets the span along the wall, Y..Y+Height the vertical span,
# and the cut always goes through the full thickness — a door/window. Slabs:
# the drag sets both horizontal spans and the cut goes through the full
# height — a floor hole. Same split as EditorWorldData._compute_wall_carve.

# Alt with a placing shape: the nearest corner (to the cursor) of the selected
# upright wall — an end of its centre line, i.e. the grid point walls meet at
# (every wall is padded past its corner by half its thickness). null when Alt
# isn't held or no upright wall is selected; slabs have no such corner.
# Only ever applied to a drag's START (see _apply_alt_latch).
func _alt_corner(mouse_pos: Vector2) -> Variant:
	if not Input.is_key_pressed(KEY_ALT) or _selected_wall_index() < 0:
		return null
	var w := _wall_selected
	if not _wall_is_upright(w):
		return null
	var axis := _wall_long_axis(w)
	var e := maxf(_wall_half_len(w) - _wall_half_thick(w), 0.0)
	var l := _neg_cursor_local(w, mouse_pos)
	var corner := Vector2.ZERO
	corner[axis] = e if l[axis] >= 0.0 else -e
	var c := _wall_to_world(w, corner)
	return Vector3(c.x, _wall_base_y(), c.y)

# Alt-press with a wall selected: its thickness becomes the Thickness setting,
# so what gets built from its corner matches it.
func _copy_selected_wall_thickness() -> void:
	var w := _wall_selected
	_wall_half_thickness = _wall_half_thick(w)
	if _wall_thick_edit: _wall_thick_edit.text = "%.3f" % (_wall_half_thickness * 2.0)
	ed._set_status("Alt: snapped to wall corner, thickness %.2f" % (_wall_half_thickness * 2.0))

func _neg_target() -> Dictionary:
	if _wall_dragging: return _neg_wall
	if Input.is_key_pressed(KEY_ALT) and _selected_wall_index() >= 0:
		return _wall_selected
	return {}

# Walls are stored either way round: the Line/Square tools put the length on
# local X (half_x) and the thickness on Z, but generated walls (make_village.py)
# also run along local Z (half_x = thickness, rot_y 0). The long axis as a
# Vector2 index into the wall's local (x, z): 0 = X, 1 = Z.
func _wall_long_axis(w: Dictionary) -> int:
	return 1 if (w.half_z as float) > (w.half_x as float) else 0

func _wall_half_len(w: Dictionary) -> float:
	return maxf(w.half_x as float, w.half_z as float)

func _wall_half_thick(w: Dictionary) -> float:
	return minf(w.half_x as float, w.half_z as float)

func _wall_is_upright(w: Dictionary) -> bool:
	return _wall_half_thick(w) * 2.0 <= (w.height as float)

func _wall_bottom(w: Dictionary) -> float:
	return ed._wd._get_height_at(w.x as float, w.z as float) + (w.get("y_offset", 0.0) as float)

func _wall_to_local(w: Dictionary, p: Vector3) -> Vector2:
	var r := w.rot_y as float
	var c := cos(r); var s := sin(r)
	var dx := p.x - (w.x as float); var dz := p.z - (w.z as float)
	return Vector2(dx * c - dz * s, dx * s + dz * c)

func _wall_to_world(w: Dictionary, l: Vector2) -> Vector2:
	var r := w.rot_y as float
	var c := cos(r); var s := sin(r)
	return Vector2((w.x as float) + l.x * c + l.y * s, (w.z as float) - l.x * s + l.y * c)

# Mouse ray onto the wall itself — its vertical mid-plane for an upright wall,
# its top face for a slab — in the wall's local (x, z). Ctrl snaps: along an
# upright wall in grid steps from its corner (its end minus the half-thickness
# padding every wall gets); a slab snaps to the world grid.
func _neg_cursor_local(w: Dictionary, mouse_pos: Vector2) -> Vector2:
	var origin := ed._cam.project_ray_origin(mouse_pos)
	var dir    := ed._cam.project_ray_normal(mouse_pos)
	var hit    := _wall_cursor(mouse_pos)
	if _wall_is_upright(w):
		var r := w.rot_y as float
		# The wall's thin axis in world space: local +Z for an X-long wall,
		# local +X for a Z-long one (see _wall_to_world).
		var n := Vector3(sin(r), 0.0, cos(r)) if _wall_long_axis(w) == 0 else Vector3(cos(r), 0.0, -sin(r))
		var denom := dir.dot(n)
		if absf(denom) > 0.0001:
			var t := (Vector3(w.x as float, 0.0, w.z as float) - origin).dot(n) / denom
			if t > 0.0: hit = origin + dir * t
	else:
		var top := _wall_bottom(w) + (w.height as float)
		if absf(dir.y) > 0.0001:
			var t := (top - origin.y) / dir.y
			if t > 0.0: hit = origin + dir * t
	var snap := _wall_snap_drag if _wall_dragging else Input.is_key_pressed(KEY_CTRL)
	if snap and not _wall_is_upright(w):
		hit = Vector3(roundf(hit.x / ed._wd.cell_size) * ed._wd.cell_size, hit.y, roundf(hit.z / ed._wd.cell_size) * ed._wd.cell_size)
	var l := _wall_to_local(w, hit)
	if snap and _wall_is_upright(w):
		var axis := _wall_long_axis(w)
		var o := -_wall_half_len(w) + _wall_half_thick(w)
		l[axis] = o + roundf((l[axis] - o) / ed._wd.cell_size) * ed._wd.cell_size
	return l

# The opening (wall-local, y from the wall's bottom) the current drag cuts
# into `w` — zero-width at the cursor before the drag starts.
func _neg_wall_opening(w: Dictionary) -> Dictionary:
	var hx := w.half_x as float; var hz := w.half_z as float; var h := w.height as float
	var cur := _neg_cursor_local(w, get_viewport().get_mouse_position())
	var a := _neg_start_local if _wall_dragging else cur  # pre-drag: zero-width marker at the start point
	var b := cur
	var op := { "x_min": clampf(minf(a.x, b.x), -hx, hx), "x_max": clampf(maxf(a.x, b.x), -hx, hx),
		"y_min": 0.0, "y_max": h,
		"z_min": clampf(minf(a.y, b.y), -hz, hz), "z_max": clampf(maxf(a.y, b.y), -hz, hz) }
	if _wall_is_upright(w):
		# Span along the wall from the drag, full thickness across it.
		if _wall_long_axis(w) == 0:
			op.z_min = -hz; op.z_max = hz
		else:
			op.x_min = -hx; op.x_max = hx
		var bottom := _wall_bottom(w)
		op.y_min = clampf(_wall_base_y() - bottom, 0.0, h)
		op.y_max = clampf(_wall_base_y() + _wall_height - bottom, 0.0, h)
	return op

func _update_neg_wall_ghost(w: Dictionary) -> void:
	var op := _neg_wall_opening(w)
	var sx := (op.x_max as float) - (op.x_min as float)
	var sy := (op.y_max as float) - (op.y_min as float)
	var sz := (op.z_max as float) - (op.z_min as float)
	_ensure_wall_ghost_boxes(1)
	var mi := _ghost.get_child(0) as MeshInstance3D
	# A hair thicker than the wall so the red cut shows on both faces.
	(mi.mesh as BoxMesh).size = Vector3(maxf(sx, ANCHOR_POST_SIZE), maxf(sy, ANCHOR_POST_SIZE), maxf(sz, ANCHOR_POST_SIZE) + 0.04)
	var c := _wall_to_world(w, Vector2(((op.x_min as float) + (op.x_max as float)) * 0.5,
		((op.z_min as float) + (op.z_max as float)) * 0.5))
	mi.position   = Vector3(c.x, _wall_bottom(w) + ((op.y_min as float) + (op.y_max as float)) * 0.5, c.y)
	mi.rotation   = Vector3.ZERO
	mi.rotation.y = w.rot_y as float
	_ghost.visible = true
	if not _wall_dragging: return
	if sy <= 0.0:
		ed._set_status("Carve (wall): Y..Y+Height is outside this wall — adjust Y/Height  [Esc] cancel")
	else:
		ed._set_status("Carve (wall): %.2f x %.2f x %.2f  from wall end %.2f  [Esc] cancel" %
			[sx, sy, sz, ((op.x_min as float) + (w.half_x as float)) if _wall_long_axis(w) == 0
				else ((op.z_min as float) + (w.half_z as float))])

func _place_neg_wall_cut() -> void:
	var w := _neg_wall
	if RampMesh.is_ramp(w):
		ed._set_status("Ramps can't be carved — [Del] removes it whole")
		return
	var op := _neg_wall_opening(w)
	if (op.x_max as float) - (op.x_min as float) < 0.05 or (op.y_max as float) - (op.y_min as float) < 0.05 \
			or (op.z_max as float) - (op.z_min as float) < 0.05:
		ed._set_status("Carve too small (or outside the wall's height) — nothing cut")
		return
	var removed := ed._wd.carve_wall_opening(w, op)
	ed._set_status("Wall removed (cut covered all of it)" if removed else "Carved opening into wall")
	ed._rebuild_walls()

# Slab: one floor/ceiling box over the dragged rectangle. Placed, it covers the
# OUTER faces of a Square wall dragged between the same corners (each side
# padded by half the wall thickness), so a roof fits that square exactly.
# Vertical size is the Height value, base at the wall Y. The Negative shape
# reuses it unchanged (same preview, same padding): it cuts exactly the box a
# Slab over the same corners would occupy.
func _slab_rect(hit: Vector3) -> Dictionary:
	var ax := _wall_drag_start.x if _wall_dragging else hit.x
	var az := _wall_drag_start.z if _wall_dragging else hit.z
	var x0 := minf(ax, hit.x); var x1 := maxf(ax, hit.x)
	var z0 := minf(az, hit.z); var z1 := maxf(az, hit.z)
	var pad := _wall_half_thickness  # Negative included: it cuts exactly what a Slab over the same corners covers
	return { "cx": (x0 + x1) * 0.5, "cz": (z0 + z1) * 0.5, "w": x1 - x0, "d": z1 - z0,
		"half_x": (x1 - x0) * 0.5 + pad, "half_z": (z1 - z0) * 0.5 + pad }

func _update_wall_ghost_slab(hit: Vector3) -> void:
	var r := _slab_rect(hit)
	_ensure_wall_ghost_boxes(1)
	var mi := _ghost.get_child(0) as MeshInstance3D
	var hx := maxf(r.half_x as float, 0.25)
	var hz := maxf(r.half_z as float, 0.25)
	(mi.mesh as BoxMesh).size = Vector3(hx * 2.0, _wall_height, hz * 2.0)
	mi.position = Vector3(r.cx as float, _wall_base_y() + _wall_height * 0.5, r.cz as float)
	mi.rotation = Vector3.ZERO
	_ghost.visible = true
	if _wall_dragging:
		ed._set_status("%s: %.2f x %.2f  h=%.2f  y=%.2f  [Esc] cancel" %
			["Carve" if _wall_negative else "Slab", hx * 2.0, hz * 2.0, _wall_height, _wall_y])

func _place_wall_slab(hit: Vector3) -> void:
	var r := _slab_rect(hit)
	if (r.w as float) < 0.5 or (r.d as float) < 0.5:
		ed._set_status("%s too small — drag further before releasing" % ("Carve" if _wall_negative else "Slab"))
		return
	var cx := r.cx as float; var cz := r.cz as float
	if _wall_negative:
		var count := ed._wd.carve_walls_in_rect(cx, cz, r.half_x as float, r.half_z as float,
			_wall_base_y(), _wall_base_y() + _wall_height, false, _wall_selected)
		ed._set_status("Carved selected wall (%.2f x %.2f rect)" % [r.w, r.d] if count > 0
			else "Carve doesn't overlap the selected wall — nothing cut")
	else:
		ed._wd.add_wall(_wall_paint_type, cx, cz, r.half_x as float, r.half_z as float, 0.0,
			_wall_height, _wall_stored_y_offset(_wall_base_y(), cx, cz))
		ed._set_status("Slab placed: %.2f x %.2f at (%.2f, %.2f) y=%.2f" %
			[(r.half_x as float) * 2.0, (r.half_z as float) * 2.0, cx, cz, _wall_y])
	ed._rebuild_walls()

const STAIR_DIR_NAMES := ["+X", "+Z", "-X", "-Z"]

# Stair/Ramp footprint: exactly the rectangle between the dragged corners —
# the drag start and the cursor are the flight's corners, no inset or padding,
# so the ghost stays under the mouse. The drag only sets the footprint; the
# climb direction is _stair_dir (R cycles it).
func _stair_rect(ax: float, az: float, bx: float, bz: float) -> Dictionary:
	var x0 := minf(ax, bx); var x1 := maxf(ax, bx)
	var z0 := minf(az, bz); var z1 := maxf(az, bz)
	var along_x := _stair_dir % 2 == 0
	var sgn := 1.0 if _stair_dir < 2 else -1.0
	return { "x0": x0, "x1": x1, "z0": z0, "z1": z1, "along_x": along_x, "sign": sgn,
		"run": (x1 - x0) if along_x else (z1 - z0), "width": (z1 - z0) if along_x else (x1 - x0) }

# One solid block per step, from the wall Y up to that step's top. Step count
# rounds up so every rise is < _stair_step and all rises are equal; the
# flight climbs exactly _wall_height over the rectangle's run.
func _stair_parts(ax: float, az: float, bx: float, bz: float) -> Array:
	var r := _stair_rect(ax, az, bx, bz)
	var run := r.run as float; var width := r.width as float
	if run < 0.5 or width < 0.3 or _wall_height <= 0.0: return []
	# 1 mm margin: a rise of exactly the server's max_climb (0.2) could land a
	# float hair above it and block the step.
	var n := clampi(ceili(_wall_height / maxf(_stair_step - 0.001, 0.01)), 1, STAIR_MAX_STEPS)
	var rise := _wall_height / n
	var tread := run / n
	var along_x := r.along_x as bool
	var sgn := r.sign as float
	var cx := ((r.x0 as float) + (r.x1 as float)) * 0.5
	var cz := ((r.z0 as float) + (r.z1 as float)) * 0.5
	var parts: Array = []
	for i in range(n):
		var off := sgn * (-run * 0.5 + (i + 0.5) * tread)  # step centre along the run, from the low end
		parts.append({ "cx": cx + (off if along_x else 0.0), "cz": cz + (0.0 if along_x else off),
			"half_x": (tread if along_x else width) * 0.5, "half_z": (width if along_x else tread) * 0.5,
			"rot_y": 0.0, "base": _wall_base_y(), "height": rise * (i + 1) })
	return parts

# One wedge over the same rectangle as Stairs, from the wall Y at the low end
# up to Y + Height at the far end. Its local +X points up the slope.
func _ramp_parts(ax: float, az: float, bx: float, bz: float) -> Array:
	var r := _stair_rect(ax, az, bx, bz)
	var run := r.run as float; var width := r.width as float
	if run < 0.5 or width < 0.3 or _wall_height <= 0.0: return []
	var sgn := r.sign as float
	var rot_y := _wall_rot_from_drag(sgn, 0.0) if (r.along_x as bool) else _wall_rot_from_drag(0.0, sgn)
	return [{ "cx": ((r.x0 as float) + (r.x1 as float)) * 0.5, "cz": ((r.z0 as float) + (r.z1 as float)) * 0.5,
		"half_x": run * 0.5, "half_z": width * 0.5, "rot_y": rot_y, "base": _wall_base_y(),
		"height": _wall_height, "low_height": 0.0 }]

# Square walls between the dragged corners + a roof slab on top of them
# (covering the walls' outer faces, like Slab), optionally a floor slab under
# them. Slabs are one wall-thickness thick.
func _room_parts(ax: float, az: float, bx: float, bz: float) -> Array:
	var x0 := minf(ax, bx); var x1 := maxf(ax, bx)
	var z0 := minf(az, bz); var z1 := maxf(az, bz)
	if x1 - x0 < 0.5 or z1 - z0 < 0.5: return []
	var t := _wall_half_thickness
	var y := _wall_base_y()
	var parts: Array = []
	for e in [[x0, z0, x1, z0], [x1, z0, x1, z1], [x1, z1, x0, z1], [x0, z1, x0, z0]]:
		var edx := (e[2] as float) - (e[0] as float)
		var edz := (e[3] as float) - (e[1] as float)
		parts.append({ "cx": ((e[0] as float) + (e[2] as float)) * 0.5, "cz": ((e[1] as float) + (e[3] as float)) * 0.5,
			"half_x": Vector2(edx, edz).length() * 0.5 + t, "half_z": t,
			"rot_y": _wall_rot_from_drag(edx, edz), "base": y, "height": _wall_height })
	var slab := { "cx": (x0 + x1) * 0.5, "cz": (z0 + z1) * 0.5,
		"half_x": (x1 - x0) * 0.5 + t, "half_z": (z1 - z0) * 0.5 + t, "rot_y": 0.0, "height": t * 2.0 }
	var roof := slab.duplicate(); roof["base"] = y + _wall_height
	parts.append(roof)
	if _room_floor:
		var floor_slab := slab.duplicate(); floor_slab["base"] = y - t * 2.0
		parts.append(floor_slab)
	return parts

func _shape_parts(hit: Vector3) -> Array:
	var ax := _wall_drag_start.x if _wall_dragging else hit.x
	var az := _wall_drag_start.z if _wall_dragging else hit.z
	if _wall_shape == "stairs":
		return _stair_parts(ax, az, hit.x, hit.z)
	if _wall_shape == "ramp":
		return _ramp_parts(ax, az, hit.x, hit.z)
	return _room_parts(ax, az, hit.x, hit.z)

func _update_wall_ghost_parts(hit: Vector3) -> void:
	var parts := _shape_parts(hit)
	_ensure_wall_ghost_boxes(parts.size())
	for i in range(parts.size()):
		var pt := parts[i] as Dictionary
		var mi := _ghost.get_child(i) as MeshInstance3D
		mi.rotation   = Vector3.ZERO
		if pt.has("low_height"):
			mi.mesh     = RampMesh.mesh(pt)  # base at the mesh origin
			mi.position = Vector3(pt.cx as float, pt.base as float, pt.cz as float)
			mi.rotation.y = pt.rot_y as float
			continue
		(mi.mesh as BoxMesh).size = Vector3((pt.half_x as float) * 2.0, pt.height as float, (pt.half_z as float) * 2.0)
		mi.position   = Vector3(pt.cx as float, (pt.base as float) + (pt.height as float) * 0.5, pt.cz as float)
		mi.rotation.y = pt.rot_y as float
	_ghost.visible = parts.size() > 0
	if not _wall_dragging: return
	if _wall_shape == "stairs" and parts.size() > 0:
		var n := parts.size()
		var r := _stair_rect(_wall_drag_start.x, _wall_drag_start.z, hit.x, hit.z)
		var tread := (r.run as float) / n
		ed._set_status("Stairs: %d steps  rise=%.3f  tread=%.2f  width=%.2f  climbs %s  climb=%.2f  y=%.2f%s  [R] direction  [Esc] cancel" %
			[n, _wall_height / n, tread, r.width, STAIR_DIR_NAMES[_stair_dir], _wall_height, _wall_y,
			"  (tread < 0.4: steep)" if tread < 0.4 else ""])
	elif _wall_shape == "ramp" and parts.size() > 0:
		var ramp := parts[0] as Dictionary
		var run := (ramp.half_x as float) * 2.0
		var slope := _wall_height / run
		ed._set_status("Ramp: run=%.2f  width=%.2f  climbs %s  climb=%.2f  slope=%.0f°  y=%.2f%s  [R] direction  [Esc] cancel" %
			[run, (ramp.half_z as float) * 2.0, STAIR_DIR_NAMES[_stair_dir], _wall_height, rad_to_deg(atan(slope)), _wall_y,
			"  (over 45°: too steep to walk up)" if slope > 1.0 else ""])
	elif _wall_shape == "room" and parts.size() > 0:
		var roof := parts[4] as Dictionary
		ed._set_status("Room: %.2f x %.2f outer  h=%.2f  t=%.2f  y=%.2f%s  [Esc] cancel" %
			[(roof.half_x as float) * 2.0, (roof.half_z as float) * 2.0, _wall_height, _wall_half_thickness * 2.0, _wall_y,
			"  +floor" if _room_floor else ""])

func _place_wall_parts(hit: Vector3) -> void:
	var parts := _shape_parts(hit)
	if parts.is_empty():
		ed._set_status("%s too small — drag further before releasing" % _wall_shape.capitalize())
		return
	var msg := "%s placed (%d boxes)" % [_wall_shape.capitalize(), parts.size()]
	if (_wall_shape == "stairs" or _wall_shape == "ramp") and _stair_cut_slabs:
		# Stairwell: cut every floor/ceiling slab over the flight's footprint
		# between the first step's top and head height above the last step.
		# Upright walls are left alone. Runs BEFORE the steps are added — low
		# steps are wider than tall, so they'd pass the slab test themselves.
		var r := _stair_rect(_wall_drag_start.x, _wall_drag_start.z, hit.x, hit.z)
		# The cut starts one step up (a ramp has no steps: one Step of rise).
		var rise := _wall_height / parts.size() if _wall_shape == "stairs" else minf(_stair_step, _wall_height)
		var cut := ed._wd.carve_walls_in_rect(
			((r.x0 as float) + (r.x1 as float)) * 0.5, ((r.z0 as float) + (r.z1 as float)) * 0.5,
			((r.x1 as float) - (r.x0 as float)) * 0.5, ((r.z1 as float) - (r.z0 as float)) * 0.5,
			_wall_base_y() + rise, _wall_base_y() + _wall_height + PLAYER_CLEARANCE, true)
		if cut > 0: msg += ", stairwell cut in %d slab(s)" % cut
	for p in parts:
		var pt := p as Dictionary
		var cx := pt.cx as float; var cz := pt.cz as float
		ed._wd.add_wall(_wall_paint_type, cx, cz, pt.half_x as float, pt.half_z as float, pt.rot_y as float,
			pt.height as float, _wall_stored_y_offset(pt.base as float, cx, cz), [], pt.get("low_height", -1.0) as float)
	ed._set_status(msg)
	ed._rebuild_walls()

func _place_wall_drag(mouse: Vector2) -> void:
	var hit := _snap_wall_point(_wall_cursor(mouse))
	if _wall_negative and not _neg_wall.is_empty():
		# Alt cut: measured along the wall, so narrow windows aren't mistaken
		# for a click; a real click (no movement) just selects that wall.
		if (_neg_cursor_local(_neg_wall, mouse) - _neg_start_local).length() < 0.05:
			_wall_selected = _neg_wall
			ed._set_status("Wall selected — [Del] remove  [G] clear openings  [Esc] deselect")
		else:
			_place_neg_wall_cut()
		return
	if _wall_negative:
		var drag_dist := Vector2(hit.x - _wall_drag_start.x, hit.z - _wall_drag_start.z).length()
		if drag_dist < 1.0:
			# Barely dragged — treat it as a click and select the wall under
			# the crosshair, instead of the tiny-rect erase below.
			_select_wall(_pick_wall_under_cursor())
			return
		if _selected_wall_index() < 0:
			ed._set_status("Negative only cuts the selected wall — click a wall first")
			return
	if _wall_shape == "square":
		_place_wall_square(hit)
	elif _wall_shape == "slab" or _wall_shape == "negative":
		_place_wall_slab(hit)
	elif _wall_shape == "stairs" or _wall_shape == "ramp" or _wall_shape == "room":
		_place_wall_parts(hit)
	else:
		_place_wall_line(hit)

func _place_wall_line(hit: Vector3) -> void:
	var ax := _wall_drag_start.x
	var az := _wall_drag_start.z
	var bx := hit.x
	var bz := hit.z
	var dx := bx - ax
	var dz := bz - az
	var length := Vector2(dx, dz).length()
	if length < POST_CLICK_DIST:
		# A click without a drag: a square post (thickness x thickness) on the point.
		length = 0.0
		bx = ax
		bz = az
	var cx := (ax + bx) * 0.5
	var cz := (az + bz) * 0.5
	var rot_y := _wall_rot_from_drag(dx, dz) if length > 0.0 else 0.0
	# Extend each end by half_thickness to match the ghost preview — keeps
	# perpendicular walls meeting at a grid corner sealed, with no gap.
	var half_x := length * 0.5 + _wall_half_thickness
	ed._wd.add_wall(_wall_paint_type, cx, cz, half_x, _wall_half_thickness, rot_y,
		_wall_height, _wall_stored_y_offset(_wall_base_y(), cx, cz))
	ed._set_status("Wall placed: %.2fm long at (%.2f, %.2f) rot=%.0f° y=%.2f" % [length, cx, cz, rad_to_deg(rot_y), _wall_y])
	ed._rebuild_walls()

func _place_wall_square(hit: Vector3) -> void:
	var ax := _wall_drag_start.x
	var az := _wall_drag_start.z
	var bx := hit.x
	var bz := hit.z
	var x0 := minf(ax, bx)
	var z0 := minf(az, bz)
	var w  := maxf(ax, bx) - x0
	var d  := maxf(az, bz) - z0
	if w < 0.5 or d < 0.5:
		ed._set_status("Square wall too small — drag further before releasing")
		return
	var x1 := x0 + w
	var z1 := z0 + d
	var edges := [
		[x0, z0, x1, z0],
		[x1, z0, x1, z1],
		[x1, z1, x0, z1],
		[x0, z1, x0, z0],
	]
	for e in edges:
		var edx := e[0] as float
		var edz := e[1] as float
		var fdx := e[2] as float
		var fdz := e[3] as float
		var dx := fdx - edx
		var dz := fdz - edz
		var length := Vector2(dx, dz).length()
		var cx := (edx + fdx) * 0.5
		var cz := (edz + fdz) * 0.5
		var rot_y := _wall_rot_from_drag(dx, dz)
		var half_x := length * 0.5 + _wall_half_thickness
		ed._wd.add_wall(_wall_paint_type, cx, cz, half_x, _wall_half_thickness, rot_y,
			_wall_height, _wall_stored_y_offset(_wall_base_y(), cx, cz))
	ed._rebuild_walls()
	ed._set_status("Square wall placed: %.2f x %.2f at (%.2f, %.2f)" % [w, d, x0 + w * 0.5, z0 + d * 0.5])


# Panel page — built by main.gd's _build_side_panel into this page's VBox.
func build_page(wall_vbox: VBoxContainer) -> void:
	# One button per row of the `wall_types` file, same pattern as the Objects
	# page — a new wall texture needs zero code changes here.
	var wall_type_ids := ed._wall_type_defs.keys()
	wall_type_ids.sort()
	for wtid in wall_type_ids:
		var wdef := ed._wall_type_defs[wtid] as Dictionary
		var wname := wdef.get("name", str(wtid)) as String
		var wbtn := Button.new()
		wbtn.text = wname
		wbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var wt: int = wtid as int
		wbtn.pressed.connect(func(): _wall_paint_type = wt; ed._set_status("Wall type: " + wname))
		wall_vbox.add_child(wbtn)

	wall_vbox.add_child(HSeparator.new())

	# Brush shape — Line drags a single wall segment; Square drags out a
	# 4-wall rectangle using the drag start/end as opposite corners.
	var shape_row := HBoxContainer.new()
	var shape_lbl := Label.new(); shape_lbl.text = "Shape"
	shape_lbl.custom_minimum_size = Vector2(50, 0)
	shape_row.add_child(shape_lbl)
	var line_btn := Button.new(); line_btn.text = "Line"; line_btn.toggle_mode = true
	var square_btn := Button.new(); square_btn.text = "Square"; square_btn.toggle_mode = true
	var slab_btn := Button.new(); slab_btn.text = "Slab"; slab_btn.toggle_mode = true
	var stairs_btn := Button.new(); stairs_btn.text = "Stairs"; stairs_btn.toggle_mode = true
	var ramp_btn := Button.new(); ramp_btn.text = "Ramp"; ramp_btn.toggle_mode = true
	var room_btn := Button.new(); room_btn.text = "Room"; room_btn.toggle_mode = true
	var neg_btn := Button.new(); neg_btn.text = "Negative"; neg_btn.toggle_mode = true
	var pillar_btn := Button.new(); pillar_btn.text = "Pillar"; pillar_btn.toggle_mode = true
	var shape_btns := { "line": line_btn, "square": square_btn, "slab": slab_btn, "stairs": stairs_btn, "ramp": ramp_btn, "room": room_btn, "negative": neg_btn, "pillar": pillar_btn }
	var shape_row2 := HBoxContainer.new()
	var pad_lbl := Label.new(); pad_lbl.custom_minimum_size = Vector2(50, 0)
	shape_row2.add_child(pad_lbl)
	for shape: String in shape_btns:
		var btn := shape_btns[shape] as Button
		btn.button_pressed = (_wall_shape == shape)
		btn.pressed.connect(func():
			_wall_shape = shape
			for other: String in shape_btns:
				(shape_btns[other] as Button).button_pressed = (other == shape)
			if _stair_step_row: _stair_step_row.visible = (shape == "stairs")
			if _pillar_section: _pillar_section.visible = (shape == "pillar")
			deactivate()  # the other shape's previews
			ed._set_status("Wall shape: " + btn.text))
		(shape_row2 if shape in ["stairs", "ramp", "room", "negative", "pillar"] else shape_row).add_child(btn)
	wall_vbox.add_child(shape_row)
	wall_vbox.add_child(shape_row2)


	var height_row := HBoxContainer.new()
	var hlbl := Label.new(); hlbl.text = "Height"
	hlbl.custom_minimum_size = Vector2(50, 0)
	var hedit := LineEdit.new(); hedit.text = str(_wall_height); hedit.custom_minimum_size = Vector2(44, 0)
	_wall_height_edit = hedit
	hedit.text_changed.connect(func(v: String): _wall_height = v.to_float() if v.is_valid_float() else _wall_height)
	height_row.add_child(hlbl); height_row.add_child(hedit)
	wall_vbox.add_child(height_row)

	var thick_row := HBoxContainer.new()
	var tlbl := Label.new(); tlbl.text = "Thickness"
	tlbl.custom_minimum_size = Vector2(50, 0)
	var tedit := LineEdit.new(); tedit.text = str(_wall_half_thickness * 2.0); tedit.custom_minimum_size = Vector2(44, 0)
	_wall_thick_edit = tedit
	tedit.text_changed.connect(func(v: String): _wall_half_thickness = (v.to_float() * 0.5) if v.is_valid_float() else _wall_half_thickness)
	thick_row.add_child(tlbl); thick_row.add_child(tedit)
	wall_vbox.add_child(thick_row)

	var yoff_row := HBoxContainer.new()
	var ylbl := Label.new(); ylbl.text = "Y"
	ylbl.custom_minimum_size = Vector2(50, 0)
	var yedit := LineEdit.new(); yedit.text = str(_wall_y); yedit.custom_minimum_size = Vector2(44, 0)
	_wall_y_edit = yedit
	yedit.text_changed.connect(func(v: String):
		if not v.is_valid_float(): return
		_wall_y = v.to_float()
		# A pillar "on ground" ignores Y — typing one means use it.
		if _is_pillar: _pillar.use_y())
	yoff_row.add_child(ylbl); yoff_row.add_child(yedit)
	wall_vbox.add_child(yoff_row)

	# Stairs: Height = total climb, Step = max rise per step.
	var step_row := HBoxContainer.new()
	var steplbl := Label.new(); steplbl.text = "Step"
	steplbl.custom_minimum_size = Vector2(50, 0)
	var sedit := LineEdit.new(); sedit.text = str(_stair_step); sedit.custom_minimum_size = Vector2(44, 0)
	sedit.text_changed.connect(func(v: String): _stair_step = maxf(v.to_float(), 0.01) if v.is_valid_float() else _stair_step)
	step_row.add_child(steplbl); step_row.add_child(sedit)
	wall_vbox.add_child(step_row)
	_stair_step_row = step_row
	step_row.visible = (_wall_shape == "stairs")

	var cut_check := CheckBox.new()
	cut_check.text = "Stairs/Ramp: cut stairwell in slabs"
	cut_check.button_pressed = _stair_cut_slabs
	cut_check.toggled.connect(func(on: bool): _stair_cut_slabs = on)
	wall_vbox.add_child(cut_check)

	var floor_check := CheckBox.new()
	floor_check.text = "Room: add floor slab"
	floor_check.button_pressed = _room_floor
	floor_check.toggled.connect(func(on: bool): _room_floor = on)
	wall_vbox.add_child(floor_check)

	_pillar_section = VBoxContainer.new()
	wall_vbox.add_child(HSeparator.new())
	wall_vbox.add_child(_pillar_section)
	_pillar.build_section(_pillar_section)
	_pillar_section.visible = _is_pillar

	wall_vbox.add_child(HSeparator.new())
	var wall_hint := Label.new()
	wall_hint.text = "[LMB drag] define wall — start to end point, any angle\nSquare: drag defines opposite corners of a 4-wall rectangle\nSlab: same corners → one floor/ceiling slab covering that square's outer faces (vertical size = Height)\nStairs: drag the flight's footprint corner to corner; [R] cycles the climb direction (+X, +Z, -X, -Z); Height = total climb, Step = max rise\nRamp: same drag and [R] as Stairs → one sloped wedge from Y up to Y + Height at the far end (walkable up to 45°; can't be carved)\nRoom: same corners as Square → 4 walls + roof slab (slab thickness = Thickness); stack the next room at Y + Height + Thickness\nNegative: only cuts the selected wall — drag like Slab → carves that box (Y to Y+Height) out of it\n[LMB click] select the wall under the crosshair (tinted red); click empty ground or [Esc] to deselect\n[Del] remove selected wall  [G] or [Shift+Del] remove all its openings (back to a plain box)\n[Ctrl+Z] undo  [Ctrl+Shift+Z / Ctrl+Y] redo — walls and pillars\n[Y] copy the selected wall's Y into the Y field\n[Hold Alt] (other shapes, before or during the drag) snap the start to the selected wall's nearest corner and copy its thickness\n[Hold Alt] (Negative, before or during the drag) lock the cut to the selected wall — follows its rotation, full thickness: door/window, or floor hole in a slab\n[Hold Ctrl] snap endpoints to grid\n[Scroll] height — also sets the carved opening's height\n[Shift+Scroll] Y — raise it to build a ceiling, or to place a window/door at the right height\n" + PillarTool.HINT
	wall_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wall_vbox.add_child(wall_hint)


# ── place_tool hooks ─────────────────────────────────────────────────────────

func on_world_loaded() -> void:
	on_walls_replaced()


# The wall list was swapped out (load, undo/redo): the selection is stale.
func on_walls_replaced() -> void:
	_wall_selected = {}


# Alt can be held at the press or pressed during the drag. The first frame
# Alt is seen while dragging, the start is anchored as if Alt had been held
# at the press: placing shapes snap the start to the selected wall's nearest
# corner (to the press point) and copy its thickness; Negative locks the cut
# to the selected wall. Latched — releasing Alt afterwards changes nothing.
func _apply_alt_latch() -> void:
	if _wall_alt_latched or not _wall_dragging or not Input.is_key_pressed(KEY_ALT): return
	if _selected_wall_index() < 0: return
	_wall_alt_latched = true
	if _wall_negative:
		_neg_wall = _wall_selected
		_neg_start_local = _neg_cursor_local(_neg_wall, _wall_press_mouse)
	else:
		var corner = _alt_corner(_wall_press_mouse)
		if corner != null:
			_wall_drag_start = corner
			_copy_selected_wall_thickness()

func on_lmb(pressed: bool, _event: InputEventMouseButton) -> void:
	if _is_pillar:
		_pillar.on_lmb(pressed)
		return
	var mouse := get_viewport().get_mouse_position()
	if pressed:
		_wall_press_mouse = mouse
		_wall_snap_drag = Input.is_key_pressed(KEY_CTRL)
		_neg_wall = {}
		_wall_alt_latched = false
		_wall_dragging   = true
		_wall_drag_start = _snap_wall_point(_wall_cursor(mouse))
		_apply_alt_latch()
	elif _wall_dragging:
		_apply_alt_latch()
		# A plain click (no Alt) on a wall selects it instead of building;
		# a click on empty ground clears the selection and builds as usual
		# (e.g. a Line post).
		if not _wall_alt_latched and not Input.is_key_pressed(KEY_ALT) \
				and (mouse - _wall_press_mouse).length() < SELECT_CLICK_PX:
			var picked := _pick_wall_under_cursor()
			_select_wall(picked)
			if picked >= 0:
				_wall_dragging = false
				return
		# Place while still "dragging" so the end point snaps by the latched
		# Ctrl state, same as the preview did.
		ed._with_history("walls", func(): _place_wall_drag(mouse))
		_wall_dragging = false


func on_scroll(dir: int) -> void:
	if _is_pillar and _pillar.on_scroll(dir): return
	if Input.is_key_pressed(KEY_SHIFT):
		_wall_y += 0.10 * dir
		_refresh_wall_y_edit()
		ed._set_status("Wall Y: %.2f" % _wall_y)
	else:
		_wall_height = clampf(_wall_height + 0.25 * dir, 0.25 if _is_pillar else 0.5, 60.0 if _is_pillar else 30.0)
		_refresh_wall_height_edit()
		ed._set_status("Height: %.2f" % _wall_height)


func on_delete(event: InputEventKey, _hit: Vector3) -> void:
	if _is_pillar:
		_pillar.on_delete()
		return
	if event.shift_pressed:
		ed._with_history("walls", _clear_selected_wall_openings)
	else:
		ed._with_history("walls", _delete_selected_wall)


func _refresh_wall_y_edit() -> void:
	if _wall_y_edit: _wall_y_edit.text = "%.3f" % _wall_y

func _refresh_wall_height_edit() -> void:
	if _wall_height_edit: _wall_height_edit.text = "%.2f" % _wall_height

# Y: the selected wall's base Y (terrain under its centre + its y_offset)
# becomes the panel's Y, so the next wall/cut starts at the same height.
func _copy_selected_wall_y() -> void:
	if _selected_wall_index() < 0:
		ed._set_status("No wall selected — click a wall first")
		return
	_wall_y = _wall_bottom(_wall_selected)
	_refresh_wall_y_edit()
	ed._set_status("Y copied from selected wall: %.3f" % _wall_y)

# G: strip every opening (negative carve) from the selected wall, back to a
# plain box — same as Shift+Delete. One undo step.
# R (Stairs/Ramp): cycle the climb direction, Shift+R backwards.
# Y: copy the selected wall's Y into the panel.
func on_key(event: InputEventKey) -> bool:
	if event.keycode == KEY_R and (_wall_shape == "stairs" or _wall_shape == "ramp") \
			and not event.ctrl_pressed and not event.alt_pressed:
		_stair_dir = (_stair_dir + (3 if event.shift_pressed else 1)) % 4
		ed._set_status("%s climbs %s" % [_wall_shape.capitalize(), STAIR_DIR_NAMES[_stair_dir]])
		return true
	if event.keycode == KEY_Y and not event.ctrl_pressed and not event.alt_pressed:
		if _is_pillar: _pillar.copy_hovered()
		else: _copy_selected_wall_y()
		return true
	if event.keycode != KEY_G or event.ctrl_pressed or event.alt_pressed: return false
	ed._with_history("walls", _clear_selected_wall_openings)
	return true


func cancel() -> String:
	if _is_pillar: return _pillar.cancel()
	if not _wall_dragging:
		if _selected_wall_index() < 0: return ""
		_wall_selected = {}
		return "Wall selection cleared"
	_wall_dragging = false
	return "Wall drag cancelled"


func is_dragging() -> bool:
	return _pillar.is_dragging() if _is_pillar else _wall_dragging


func update(_delta: float, mouse: Vector2, _hit: Vector3) -> void:
	if _is_pillar:
		_pillar.update(mouse)
		return
	_apply_alt_latch()
	_update_wall_ghost(_wall_cursor(mouse))


func deactivate() -> void:
	_hide_wall_hover()
	if _ghost: _ghost.visible = false
	_pillar.deactivate()


func status_hint() -> String:
	if _is_pillar: return _pillar.status_hint()
	return "[LMB drag] define wall  [Hold Ctrl] snap to grid  [Scroll] height  [Shift+Scroll] Y  [Click] select wall  [Delete] remove selected  [G] clear its openings  [Y] copy its Y  [Alt] snap to it  [Esc] cancel  — %s (%s) h=%.1f t=%.1f y=%.2f (%d walls)" % \
		[_wall_type_name(_wall_paint_type), _wall_shape, _wall_height, _wall_half_thickness * 2.0, _wall_y, (ed._wd._walls.size() if ed._wd != null else 0)]


func undo_feature() -> String:
	return "walls"
