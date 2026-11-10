extends Node3D

# The Walls page's "Pillar" shape: upright cylinders with their own radius,
# from the wall tool's Y up by its Height (stored as y_offset over the terrain
# under the centre, like walls). Not a page of its own: wall_tool.gd owns it
# and forwards its hooks here while the Pillar shape is selected. Pillar edits
# share the walls' undo history (main.gd snapshots walls + pillars together).

var ed: WorldEditor  # main.gd
var walls            # tools/wall_tool.gd — Height, Y and the wall type are its fields

var _ghost: MeshInstance3D       # cylinder preview at the cursor / of the drag
var _hover: MeshInstance3D       # red highlight over the pillar Delete would remove

var _radius    := 0.4
var _on_ground := true           # base on the terrain under the centre, ignoring Y

var _dragging    := false
var _drag_start  := Vector3.ZERO # pillar centre, fixed at the press
var _press_mouse := Vector2.ZERO

var _radius_edit: LineEdit
var _ground_check: CheckBox

# A press-to-release move under this (pixels) is a click: place with the
# Radius field instead of the dragged radius.
const CLICK_PX := 4.0
# [Alt] snaps the centre to a wall corner or wall end within this distance.
const WALL_SNAP_DIST := 1.5


# A pillar's type is a wall type id: the Walls page's type buttons pick it
# and it is drawn in that wall type's material.
func _type_name(id: int) -> String:
	return walls._wall_type_name(id)


# ── Placement geometry ──────────────────────────────────────────────────────

# Base Y of a pillar centred at (x, z) with the current settings.
func _base_y(x: float, z: float) -> float:
	return ed._wd._get_height_at(x, z) if _on_ground else walls._wall_y


# The point under the cursor: on the terrain when placing on the ground, else
# on the horizontal plane at Y — the same cursor the wall shapes use.
func _cursor(mouse: Vector2) -> Vector3:
	return ed._raycast_or_plane(mouse) if _on_ground else walls._wall_cursor(mouse)


func _snap(p: Vector3, ctrl: bool) -> Vector3:
	if Input.is_key_pressed(KEY_ALT):
		var corner = _nearest_wall_point(p)
		if corner != null: return corner
	if not ctrl: return p
	var cs := ed._wd.cell_size
	return Vector3(roundf(p.x / cs) * cs, p.y, roundf(p.z / cs) * cs)


# Nearest wall corner or wall end (middle of a short side) to p in XZ, within
# WALL_SNAP_DIST, or null. Walls may have their length on either half axis.
func _nearest_wall_point(p: Vector3) -> Variant:
	var best = null
	var best_d := WALL_SNAP_DIST * WALL_SNAP_DIST
	for w in ed._wd._walls:
		var d := w as Dictionary
		var hx := d.half_x as float
		var hz := d.half_z as float
		var c := cos(d.rot_y as float)
		var s := sin(d.rot_y as float)
		var locals := [Vector2(hx, hz), Vector2(-hx, hz), Vector2(hx, -hz), Vector2(-hx, -hz)]
		locals.append(Vector2(hx, 0.0) if hx >= hz else Vector2(0.0, hz))
		locals.append(Vector2(-hx, 0.0) if hx >= hz else Vector2(0.0, -hz))
		for l: Vector2 in locals:
			# local -> world, the server's / Godot's rotation.y convention
			var wx := (d.x as float) + l.x * c + l.y * s
			var wz := (d.z as float) - l.x * s + l.y * c
			var dd := (wx - p.x) * (wx - p.x) + (wz - p.z) * (wz - p.z)
			if dd < best_d:
				best_d = dd
				best = Vector3(wx, p.y, wz)
	return best


# Radius of the drag so far: centre to the cursor, in XZ.
func _drag_radius(mouse: Vector2) -> float:
	var p := _cursor(mouse)
	return Vector2(p.x - _drag_start.x, p.z - _drag_start.z).length()


func _place(mouse: Vector2) -> void:
	var radius := _radius
	if (mouse - _press_mouse).length() >= CLICK_PX:
		radius = maxf(_drag_radius(mouse), 0.05)
		_radius = radius
		_refresh_fields()
	var x := _drag_start.x
	var z := _drag_start.z
	var height := walls._wall_height as float
	ed._wd.add_pillar(walls._wall_paint_type, x, z, radius, height, _base_y(x, z) - ed._wd._get_height_at(x, z))
	ed._rebuild_pillars()
	ed._set_status("Pillar placed: r=%.2f h=%.2f (%d pillars)" % [radius, height, ed._wd._pillars.size()])


# ── Picking ─────────────────────────────────────────────────────────────────

# Index of the pillar the mouse ray hits first (side or caps), or -1.
func _pick(mouse: Vector2) -> int:
	var o := ed._cam.project_ray_origin(mouse)
	var dir := ed._cam.project_ray_normal(mouse)
	var best := -1
	var best_t := INF
	for i in range(ed._wd._pillars.size()):
		var p := ed._wd._pillars[i] as Dictionary
		var r := p.radius as float
		var y0 := ed._wd._get_height_at(p.x as float, p.z as float) + (p.get("y_offset", 0.0) as float)
		var y1 := y0 + (p.height as float)
		var ox := o.x - (p.x as float)
		var oz := o.z - (p.z as float)
		var ts: Array[float] = []
		var a := dir.x * dir.x + dir.z * dir.z
		if a > 1e-9:
			var b := 2.0 * (ox * dir.x + oz * dir.z)
			var cc := ox * ox + oz * oz - r * r
			var disc := b * b - 4.0 * a * cc
			if disc >= 0.0:
				var sq := sqrt(disc)
				for t: float in [(-b - sq) / (2.0 * a), (-b + sq) / (2.0 * a)]:
					var y := o.y + dir.y * t
					if y >= y0 and y <= y1: ts.append(t)
		if absf(dir.y) > 1e-9:
			for cap: float in [y0, y1]:
				var t := (cap - o.y) / dir.y
				var hx := ox + dir.x * t
				var hz := oz + dir.z * t
				if hx * hx + hz * hz <= r * r: ts.append(t)
		for t in ts:
			if t > 0.0 and t < best_t:
				best_t = t
				best = i
	return best


# ── Preview ─────────────────────────────────────────────────────────────────

func _ensure_meshes() -> void:
	if _ghost == null:
		_ghost = MeshInstance3D.new()
		_ghost.mesh = CylinderMesh.new()
		_ghost.material_override = ed._make_ghost_mat()
		add_child(_ghost)
	if _hover == null:
		_hover = MeshInstance3D.new()
		_hover.mesh = CylinderMesh.new()
		var m := ed._make_ghost_mat()
		m.albedo_color = Color(1.0, 0.2, 0.2, 0.4)
		m.no_depth_test = true
		_hover.material_override = m
		add_child(_hover)


func _show_cylinder(mi: MeshInstance3D, x: float, z: float, base: float, radius: float, height: float) -> void:
	var cyl := mi.mesh as CylinderMesh
	cyl.top_radius    = radius
	cyl.bottom_radius = radius
	cyl.height        = height
	mi.position = Vector3(x, base + height * 0.5, z)
	mi.visible  = true


func _update_hover(mouse: Vector2) -> void:
	var i := _pick(mouse) if not _dragging else -1
	if i < 0:
		_hover.visible = false
		return
	var p := ed._wd._pillars[i] as Dictionary
	var base := ed._wd._get_height_at(p.x as float, p.z as float) + (p.get("y_offset", 0.0) as float)
	# Slightly larger so it shows over the pillar itself.
	_show_cylinder(_hover, p.x as float, p.z as float, base - 0.02, (p.radius as float) + 0.03, (p.height as float) + 0.04)


func _refresh_fields() -> void:
	if _radius_edit: _radius_edit.text = "%.2f" % _radius
	if _ground_check: _ground_check.set_pressed_no_signal(_on_ground)


# ── Walls page section (shown only while the Pillar shape is selected) ─────

func build_section(vbox: VBoxContainer) -> void:
	# No type buttons of its own: the wall type buttons above set the type.
	var row := HBoxContainer.new()
	var lbl := Label.new(); lbl.text = "Radius"
	lbl.custom_minimum_size = Vector2(50, 0)
	_radius_edit = LineEdit.new(); _radius_edit.text = str(_radius); _radius_edit.custom_minimum_size = Vector2(44, 0)
	_radius_edit.text_changed.connect(func(v: String): if v.is_valid_float(): _radius = maxf(v.to_float(), 0.05))
	row.add_child(lbl); row.add_child(_radius_edit)
	vbox.add_child(row)

	_ground_check = CheckBox.new()
	_ground_check.text = "Pillar on ground (ignore Y)"
	_ground_check.button_pressed = _on_ground
	_ground_check.toggled.connect(func(on: bool): _on_ground = on)
	vbox.add_child(_ground_check)


const HINT := "Pillar: [LMB click] place one with the Radius field; [LMB drag] centre at the press, drag out the radius — Height and Y as for walls (untick \"on ground\" to use Y)\nPillar: [Hold Alt] snap the centre to the nearest wall corner / wall end  [Alt+Scroll] radius  [Del] remove the pillar under the cursor (tinted red)  [Y] copy its type, radius, height and Y"


# ── Hooks, forwarded by wall_tool.gd while the Pillar shape is selected ────

func on_lmb(pressed: bool) -> void:
	var mouse := get_viewport().get_mouse_position()
	if pressed:
		_press_mouse = mouse
		_drag_start  = _snap(_cursor(mouse), Input.is_key_pressed(KEY_CTRL))
		_dragging    = true
	elif _dragging:
		_dragging = false
		ed._with_history("walls", func(): _place(mouse))


# Alt+Scroll: radius. Returns false for the scrolls the wall tool handles
# (Height, Shift = Y — Shift also turns "on ground" off, so Y takes effect).
func on_scroll(dir: int) -> bool:
	if Input.is_key_pressed(KEY_ALT):
		_radius = clampf(_radius + 0.05 * dir, 0.05, 15.0)
		_refresh_fields()
		ed._set_status("Pillar radius: %.2f" % _radius)
		return true
	if Input.is_key_pressed(KEY_SHIFT): use_y()
	return false


# Untick "on ground" so the wall tool's Y takes effect (Shift+Scroll, typing Y).
func use_y() -> void:
	if not _on_ground: return
	_on_ground = false
	_refresh_fields()


func on_delete() -> void:
	var i := _pick(get_viewport().get_mouse_position())
	if i < 0:
		ed._set_status("No pillar under the cursor")
		return
	ed._with_history("walls", func():
		ed._wd._pillars.remove_at(i)
		ed._rebuild_pillars())
	ed._set_status("Pillar removed (%d left)" % ed._wd._pillars.size())


# Y: copy the hovered pillar into the settings (type, radius, Height, Y).
func copy_hovered() -> void:
	var i := _pick(get_viewport().get_mouse_position())
	if i < 0:
		ed._set_status("No pillar under the cursor")
		return
	var p := ed._wd._pillars[i] as Dictionary
	walls._wall_y = ed._wd._get_height_at(p.x as float, p.z as float) + (p.get("y_offset", 0.0) as float)
	walls._wall_height = p.height as float
	walls._refresh_wall_y_edit()
	walls._refresh_wall_height_edit()
	_radius = p.radius as float
	walls._wall_paint_type = p.type as int
	_on_ground = is_zero_approx(p.get("y_offset", 0.0) as float)
	_refresh_fields()
	ed._set_status("Copied pillar: %s r=%.2f h=%.2f y=%.2f" % [_type_name(walls._wall_paint_type), _radius, walls._wall_height, walls._wall_y])


func cancel() -> String:
	if not _dragging: return ""
	_dragging = false
	return "Pillar drag cancelled"


func is_dragging() -> bool:
	return _dragging


func update(mouse: Vector2) -> void:
	_ensure_meshes()
	_update_hover(mouse)
	var height := walls._wall_height as float
	if _dragging:
		var r := maxf(_drag_radius(mouse), 0.05) if (mouse - _press_mouse).length() >= CLICK_PX else _radius
		_show_cylinder(_ghost, _drag_start.x, _drag_start.z, _base_y(_drag_start.x, _drag_start.z), r, height)
	else:
		var c := _snap(_cursor(mouse), Input.is_key_pressed(KEY_CTRL))
		_show_cylinder(_ghost, c.x, c.z, _base_y(c.x, c.z), _radius, height)


func deactivate() -> void:
	_dragging = false
	if _ghost: _ghost.visible = false
	if _hover: _hover.visible = false


func status_hint() -> String:
	return "[LMB] place / drag radius  [Ctrl] grid  [Alt] wall corner  [Scroll] height  [Alt+Scroll] radius  [Shift+Scroll] Y  [Del] remove  [Y] copy  — %s r=%.2f h=%.2f %s (%d pillars)" % \
		[_type_name(walls._wall_paint_type), _radius, walls._wall_height, "on ground" if _on_ground else "y=%.2f" % walls._wall_y, (ed._wd._pillars.size() if ed._wd != null else 0)]
