extends "res://world_editor/tools/place_tool.gd"

# Hand-placed spawn areas — the editor side of the server's spawns.json (see
# load_spawn_areas in src/systems/spawn.cpp). Each opened world keeps its own
# list next to it: world.bin <-> world.spawns.json; deploy copies that file to
# ~/stone_gaze/spawns.json. Each spawner is drawn with gaze_client's spawn
# portal (assets/effects/portal.tscn), looping, at the floor of its layer.
#
# Entry shape (same as the server reads):
#   {"name", "monster", "layer": "upper"|"lower",
#    "area": {"x","z","radius"} | {"x0","z0","x1","z1"},
#    "max", "interval", "prob", "level"}

const PORTAL_SCENE := preload("res://assets/effects/portal.tscn")
const LINE_COLOR   := Color(1.0, 0.35, 0.2, 0.9)
const SEL_COLOR    := Color(1.0, 0.9, 0.2, 1.0)
const GHOST_COLOR  := Color(0.4, 1.0, 0.4, 0.6)

var wd: EditorWorldData
var spawns: Array = []        # Array[Dictionary], entries as above
var selected: int = -1
var monsters: PackedStringArray = []

# Settings for the next placed spawner — also what the panel edits on the
# selected one. layer_mode "auto" picks the layer from where you click.
var monster: String = "Rat"
var max_count: int = 3
var interval: float = 5.0
var prob: float = 1.0
var level: int = 1
var layer_mode: String = "auto"   # "auto" | "upper" | "lower"
var radius: float = 4.0

var _markers: AoiSet   # spawn markers exist only near the camera
var _ghost: Node3D
var _ghost_ring: MeshInstance3D
var _ghost_rect: Array = []   # 4 edge MeshInstance3D
var _ghost_label: Label3D
var _list: ItemList
var _fields: Dictionary = {}  # field name -> Control
var _syncing := false         # true while _sync_fields writes to the widgets
var _dragging := false        # LMB went down on empty ground: a click places a circle, a drag a rectangle
var _drag_start := Vector3.ZERO


func _ready() -> void:
	_markers = AoiSet.new()
	add_child(_markers)
	_markers.setup(func(): return spawns, _footprint, _build_marker)
	_build_ghost()
	_load_monster_names()


# ── data ─────────────────────────────────────────────────────────────────────

func _load_monster_names() -> void:
	var path := ProjectSettings.globalize_path("res://").path_join("../stone_gaze/monster_types.json")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("SpawnTool: cannot open " + path)
		return
	var data = JSON.parse_string(f.get_as_text())
	if data is Array:
		for m in data:
			if m is Dictionary and (m as Dictionary).has("type"):
				monsters.append((m as Dictionary)["type"] as String)
	if not monsters.is_empty() and not monster in monsters:
		monster = monsters[0]


static func path_for(world_path: String) -> String:
	return world_path.get_basename() + ".spawns.json"


func setup(world: EditorWorldData) -> void:
	wd = world
	spawns.clear()
	selected = -1
	rebuild()


func load_for(world_path: String) -> int:
	spawns.clear()
	selected = -1
	var f := FileAccess.open(path_for(world_path), FileAccess.READ)
	if f != null:
		var data = JSON.parse_string(f.get_as_text())
		if data is Array:
			for e in data:
				if e is Dictionary: spawns.append(_normalized(e as Dictionary))
	rebuild()
	return spawns.size()


func save_for(world_path: String) -> bool:
	var f := FileAccess.open(path_for(world_path), FileAccess.WRITE)
	if f == null:
		push_error("SpawnTool: cannot write " + path_for(world_path))
		return false
	f.store_string(JSON.stringify(spawns, "  ", false) + "\n")
	return true


# JSON numbers load as floats — keep counts as ints so the file round-trips cleanly.
func _normalized(e: Dictionary) -> Dictionary:
	var out := e.duplicate(true)
	out["max"] = int(out.get("max", 1))
	out["level"] = int(out.get("level", 1))
	out["interval"] = float(out.get("interval", 5.0))
	out["prob"] = float(out.get("prob", 1.0))
	out["layer"] = str(out.get("layer", "upper"))
	return out


# ── layers ───────────────────────────────────────────────────────────────────

# A click below the cave ceiling of a cave chunk lands on the lower layer.
func detect_layer(hit: Vector3) -> String:
	if layer_mode != "auto": return layer_mode
	if wd == null or not EditorWorldData.is_cave_type(wd.get_chunk_type(hit.x, hit.z)): return "upper"
	var h2 := wd.get_layer_height_at(hit.x, hit.z, "h2")
	var h1 := wd.get_layer_height_at(hit.x, hit.z, "h1")
	if not is_nan(h2) and hit.y < h2 - 0.05: return "lower"
	if is_nan(h1) and is_nan(h2): return "lower"  # open hole / ramp down to h3
	return "upper"


func floor_y(x: float, z: float, layer: String) -> float:
	if wd == null: return 0.0
	var y := wd.get_layer_height_at(x, z, "h3" if layer == "lower" else "h1")
	return 0.0 if is_nan(y) else y


static func center_of(e: Dictionary) -> Vector2:
	var a := e["area"] as Dictionary
	if a.has("radius"): return Vector2(a["x"], a["z"])
	return Vector2((float(a["x0"]) + float(a["x1"])) * 0.5, (float(a["z0"]) + float(a["z1"])) * 0.5)


# ── editing ──────────────────────────────────────────────────────────────────

func _new_entry(layer: String, area: Dictionary, c: Vector2) -> Dictionary:
	return {
		"name": "%s_%d_%d" % [monster, roundi(c.x), roundi(c.y)],
		"monster": monster, "layer": layer, "area": area,
		"max": max_count, "interval": interval, "prob": prob, "level": level,
	}


func add_circle(hit: Vector3) -> void:
	var area := { "x": snappedf(hit.x, 0.1), "z": snappedf(hit.z, 0.1), "radius": radius }
	spawns.append(_new_entry(detect_layer(hit), area, Vector2(hit.x, hit.z)))
	select(spawns.size() - 1)


func add_rect(a: Vector3, b: Vector3) -> void:
	var area := {
		"x0": snappedf(minf(a.x, b.x), 0.1), "z0": snappedf(minf(a.z, b.z), 0.1),
		"x1": snappedf(maxf(a.x, b.x), 0.1), "z1": snappedf(maxf(a.z, b.z), 0.1),
	}
	spawns.append(_new_entry(detect_layer(a), area, Vector2((a.x + b.x) * 0.5, (a.z + b.z) * 0.5)))
	select(spawns.size() - 1)


# Index of the spawner whose area contains `hit` (nearest centre wins when
# they overlap), -1 if none. Height is ignored — a cave spawner under the
# cursor's XZ counts too, so it can be picked from above the hill.
func pick(hit: Vector3) -> int:
	var best := -1
	var best_d := INF
	for i in spawns.size():
		var e := spawns[i] as Dictionary
		var a := e["area"] as Dictionary
		var inside := false
		if a.has("radius"):
			inside = Vector2(hit.x - float(a["x"]), hit.z - float(a["z"])).length() <= float(a["radius"])
		else:
			inside = hit.x >= float(a["x0"]) and hit.x <= float(a["x1"]) and hit.z >= float(a["z0"]) and hit.z <= float(a["z1"])
		if not inside: continue
		var d := center_of(e).distance_to(Vector2(hit.x, hit.z))
		if d < best_d:
			best_d = d
			best = i
	return best


func remove(i: int) -> void:
	if i < 0 or i >= spawns.size(): return
	spawns.remove_at(i)
	selected = -1
	rebuild()


func select(i: int) -> void:
	selected = i
	if i >= 0 and i < spawns.size():
		var e := spawns[i] as Dictionary
		monster = e["monster"]
		max_count = e["max"]
		interval = e["interval"]
		prob = e["prob"]
		level = e["level"]
		# layer_mode is left alone: it's the placement setting, and copying a
		# cave spawner's "lower" into it would force every later placement
		# into the cave. The list and the label show each spawner's layer.
		var a := e["area"] as Dictionary
		if a.has("radius"): radius = float(a["radius"])
	_sync_fields()
	rebuild()


# Scroll wheel: brush radius for the next circle, and resizes the selected one.
func set_radius(r: float) -> void:
	radius = clampf(r, 0.5, 60.0)
	_sync_fields()
	_apply_to_selected()


# Panel edits go to the selected spawner (as well as becoming the settings
# for the next placement).
func _apply_to_selected() -> void:
	if _syncing or selected < 0 or selected >= spawns.size(): return
	var e := spawns[selected] as Dictionary
	var old_monster := e["monster"] as String
	e["monster"] = monster
	e["max"] = max_count
	e["interval"] = interval
	e["prob"] = prob
	e["level"] = level
	if layer_mode != "auto": e["layer"] = layer_mode
	var a := e["area"] as Dictionary
	if a.has("radius"): a["radius"] = radius
	# Keep auto-generated names in step with the monster; custom names are left alone.
	if (e["name"] as String).begins_with(old_monster + "_"):
		e["name"] = monster + (e["name"] as String).substr(old_monster.length())
	rebuild()


# ── visuals ──────────────────────────────────────────────────────────────────

func _line_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true  # cave spawners stay visible through the hill above them
	return m


# A torus, not a flat ring — a zero-height mesh gets culled by Forward+.
func _ring(r: float, color: Color) -> MeshInstance3D:
	var t := TorusMesh.new()
	t.inner_radius = maxf(r - 0.08, 0.01)
	t.outer_radius = r + 0.08
	t.rings = 48
	t.ring_segments = 4
	var mi := MeshInstance3D.new()
	mi.mesh = t
	mi.material_override = _line_mat(color)
	return mi


func _edge(color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	mi.material_override = _line_mat(color)
	return mi


func _place_rect_edges(edges: Array, x0: float, z0: float, x1: float, z1: float, y: float) -> void:
	var w := x1 - x0
	var d := z1 - z0
	var specs := [
		[Vector3((x0 + x1) * 0.5, y, z0), Vector3(w, 0.1, 0.12)],
		[Vector3((x0 + x1) * 0.5, y, z1), Vector3(w, 0.1, 0.12)],
		[Vector3(x0, y, (z0 + z1) * 0.5), Vector3(0.12, 0.1, d)],
		[Vector3(x1, y, (z0 + z1) * 0.5), Vector3(0.12, 0.1, d)],
	]
	for k in 4:
		var mi := edges[k] as MeshInstance3D
		mi.position = specs[k][0]
		(mi.mesh as BoxMesh).size = specs[k][1]


func _label(text: String, color: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.modulate = color
	l.outline_size = 8
	l.font_size = 48
	l.pixel_size = 0.01
	return l


# The game's spawn portal, looping instead of one-shot. Same transparency
# fix as gaze_client effects.gd (_fix_portal_transparency).
func _portal() -> Node3D:
	var p := PORTAL_SCENE.instantiate() as Node3D
	for mi: MeshInstance3D in p.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s) as BaseMaterial3D
			if mat == null or mat.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA: continue
			var dup := mat.duplicate() as BaseMaterial3D
			dup.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
			mi.set_surface_override_material(s, dup)
	for ap in p.find_children("*", "AnimationPlayer", true, false):
		var player := ap as AnimationPlayer
		var anims := player.get_animation_list()
		if anims.is_empty(): continue
		var anim := player.get_animation(anims[0])
		if anim: anim.loop_mode = Animation.LOOP_LINEAR
		player.play(anims[0])
	return p


func rebuild() -> void:
	if _markers == null: return
	_markers.invalidate()
	_refresh_list()


static func _footprint(e: Dictionary) -> Rect2:
	var a := e["area"] as Dictionary
	if a.has("radius"):
		var r := float(a["radius"])
		return Rect2(float(a["x"]) - r, float(a["z"]) - r, r * 2.0, r * 2.0)
	return Rect2(float(a["x0"]), float(a["z0"]), float(a["x1"]) - float(a["x0"]), float(a["z1"]) - float(a["z0"])).abs()


func _build_marker(e: Dictionary, i: int, holder: Node3D) -> void:
	var color := SEL_COLOR if i == selected else LINE_COLOR
	var c := center_of(e)
	var layer := e["layer"] as String
	var y := floor_y(c.x, c.y, layer)
	var root := Node3D.new()
	holder.add_child(root)

	var portal := _portal()
	root.add_child(portal)
	# portal.tscn's Marker3D is its centre/ground point — line it up with the
	# floor, as effects.gd does with the spawning monster.
	portal.global_position = Vector3(c.x, y, c.y)
	var markers := portal.find_children("*", "Marker3D", true, false)
	if not markers.is_empty():
		portal.global_position += Vector3(c.x, y + 1.0, c.y) - (markers[0] as Node3D).global_position

	var a := e["area"] as Dictionary
	if a.has("radius"):
		var ring := _ring(float(a["radius"]), color)
		ring.position = Vector3(c.x, y + 0.1, c.y)
		root.add_child(ring)
	else:
		var edges := []
		for k in 4:
			var ed := _edge(color)
			root.add_child(ed)
			edges.append(ed)
		_place_rect_edges(edges, float(a["x0"]), float(a["z0"]), float(a["x1"]), float(a["z1"]), y + 0.1)

	var lbl := _label("%s ×%d  L%d  %s" % [e["monster"], e["max"], e["level"], layer], color)
	lbl.position = Vector3(c.x, y + 3.2, c.y)
	root.add_child(lbl)


func _build_ghost() -> void:
	_ghost = Node3D.new()
	add_child(_ghost)
	_ghost_ring = _ring(1.0, GHOST_COLOR)
	_ghost.add_child(_ghost_ring)
	for k in 4:
		var ed := _edge(GHOST_COLOR)
		_ghost.add_child(ed)
		_ghost_rect.append(ed)
	_ghost_label = _label("", GHOST_COLOR)
	_ghost.add_child(_ghost_label)
	_ghost.visible = false


# Preview at the cursor: the circle a click would place, or the rectangle a
# drag (from drag_start) would.
func update_ghost(hit: Vector3, dragging: bool, drag_start: Vector3) -> void:
	_ghost.visible = true
	var from := drag_start if dragging else hit
	var layer := detect_layer(from)
	var y := floor_y(from.x, from.z, layer) if layer == "lower" else hit.y
	var is_rect := dragging and Vector2(hit.x - drag_start.x, hit.z - drag_start.z).length() > 0.5
	_ghost_ring.visible = not is_rect
	for ed in _ghost_rect: (ed as Node3D).visible = is_rect
	if is_rect:
		_place_rect_edges(_ghost_rect, minf(drag_start.x, hit.x), minf(drag_start.z, hit.z),
			maxf(drag_start.x, hit.x), maxf(drag_start.z, hit.z), y + 0.1)
		_ghost_label.position = Vector3((drag_start.x + hit.x) * 0.5, y + 2.0, (drag_start.z + hit.z) * 0.5)
	else:
		var t := _ghost_ring.mesh as TorusMesh
		t.inner_radius = maxf(radius - 0.08, 0.01)
		t.outer_radius = radius + 0.08
		_ghost_ring.position = Vector3(hit.x, y + 0.1, hit.z)
		_ghost_label.position = Vector3(hit.x, y + 2.0, hit.z)
	_ghost_label.text = "%s ×%d  %s" % [monster, max_count, layer]


func hide_ghost() -> void:
	if _ghost: _ghost.visible = false


# ── panel page ───────────────────────────────────────────────────────────────

func _row(vbox: VBoxContainer, label: String, ctrl: Control) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(70, 0)
	row.add_child(l)
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ctrl)
	vbox.add_child(row)


func _num_edit(key: String, value: Variant, on_change: Callable) -> LineEdit:
	var e := LineEdit.new()
	e.text = str(value)
	e.text_changed.connect(func(v: String):
		if v.is_valid_float():
			on_change.call(v)
			_apply_to_selected()
	)
	_fields[key] = e
	return e


func build_page(vbox: VBoxContainer) -> void:
	var mon := OptionButton.new()
	for m in monsters: mon.add_item(m)
	mon.selected = maxi(monsters.find(monster), 0)
	mon.item_selected.connect(func(i: int):
		monster = monsters[i]
		_apply_to_selected()
		ed._set_status("Spawn monster: " + monster)
	)
	_fields["monster"] = mon
	_row(vbox, "Monster", mon)

	var lay := OptionButton.new()
	for l in ["auto", "upper", "lower"]: lay.add_item(l)
	lay.item_selected.connect(func(i: int):
		layer_mode = ["auto", "upper", "lower"][i]
		_apply_to_selected()
	)
	_fields["layer"] = lay
	_row(vbox, "Layer", lay)

	_row(vbox, "Max", _num_edit("max", max_count, func(v: String): max_count = maxi(int(v), 1)))
	_row(vbox, "Interval", _num_edit("interval", interval, func(v: String): interval = maxf(float(v), 0.1)))
	_row(vbox, "Prob", _num_edit("prob", prob, func(v: String): prob = clampf(float(v), 0.0, 1.0)))
	_row(vbox, "Level", _num_edit("level", level, func(v: String): level = maxi(int(v), 1)))
	_row(vbox, "Radius", _num_edit("radius", radius, func(v: String): radius = clampf(float(v), 0.5, 60.0)))

	vbox.add_child(HSeparator.new())
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 180)
	_list.item_selected.connect(func(i: int): select(i))
	vbox.add_child(_list)

	var btns := HBoxContainer.new()
	var del := Button.new()
	del.text = "Delete selected"
	del.pressed.connect(func(): remove(selected))
	btns.add_child(del)
	var desel := Button.new()
	desel.text = "Deselect"
	desel.pressed.connect(func(): select(-1))
	btns.add_child(desel)
	vbox.add_child(btns)

	vbox.add_child(HSeparator.new())
	var hint := Label.new()
	hint.text = "[LMB] click: circle spawner (radius)  ·  drag: rectangle\n[LMB] inside an existing one: select it — the fields above then edit it\n[Scroll] radius (also resizes the selected one)   [Del] remove the one under the cursor\nLayer auto: clicking a cave floor (below the ceiling) makes a lower (h3) spawner, anywhere else upper (h1)\nSaved with the world as <world>.spawns.json — deploy it as spawns.json"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(hint)
	_refresh_list()


func _refresh_list() -> void:
	if _list == null: return
	_list.clear()
	for e in spawns:
		var d := e as Dictionary
		_list.add_item("%s  (%s ×%d, %s)" % [d["name"], d["monster"], d["max"], d["layer"]])
	if selected >= 0 and selected < _list.item_count:
		_list.select(selected)


func _sync_fields() -> void:
	if _fields.is_empty(): return
	_syncing = true
	(_fields["monster"] as OptionButton).selected = maxi(monsters.find(monster), 0)
	(_fields["layer"] as OptionButton).selected = ["auto", "upper", "lower"].find(layer_mode)
	(_fields["max"] as LineEdit).text = str(max_count)
	(_fields["interval"] as LineEdit).text = str(interval)
	(_fields["prob"] as LineEdit).text = str(prob)
	(_fields["level"] as LineEdit).text = str(level)
	(_fields["radius"] as LineEdit).text = str(radius)
	_syncing = false


# ── place_tool hooks ─────────────────────────────────────────────────────────

func on_world_loaded() -> void:
	setup(ed._wd)
	if not ed._world_path.is_empty():
		load_for(ed._world_path)


# Import reshapes terrain under the spawners — re-seat their markers.
func on_world_changed() -> void:
	rebuild()


func on_lmb(pressed: bool, _event: InputEventMouseButton) -> void:
	var hit := ed._raycast_or_plane(get_viewport().get_mouse_position())
	if pressed:
		var picked := pick(hit)
		if picked >= 0:
			select(picked)
			ed._set_status("Spawner selected: " + (spawns[picked] as Dictionary)["name"])
		else:
			_drag_start = hit
			_dragging   = true
	elif _dragging:
		_dragging = false
		if Vector2(hit.x - _drag_start.x, hit.z - _drag_start.z).length() > 0.5:
			add_rect(_drag_start, hit)
		else:
			add_circle(_drag_start)
		var placed := spawns[selected] as Dictionary
		ed._set_status("Spawner placed: %s (%s layer)" % [placed["name"], placed["layer"]])


func on_scroll(dir: int) -> void:
	set_radius(radius + 0.5 * dir)
	ed._set_status("Spawn radius: %.1f" % radius)


func on_delete(_event: InputEventKey, hit: Vector3) -> void:
	var i := pick(hit)
	if i < 0: return
	var removed := (spawns[i] as Dictionary)["name"] as String
	remove(i)
	ed._set_status("Spawner removed: " + removed)


func cancel() -> String:
	if not _dragging: return ""
	_dragging = false
	return "Spawner drag cancelled"


func is_dragging() -> bool:
	return _dragging


func update(_delta: float, _mouse: Vector2, hit: Vector3) -> void:
	update_ghost(hit, _dragging, _drag_start)


func deactivate() -> void:
	hide_ghost()


func status_hint() -> String:
	return "[LMB] circle spawner  [LMB drag] rectangle  [LMB on one] select  [Scroll] radius  [Del] remove  — %s ×%d r=%.1f layer:%s  (%d spawners)" % \
		[monster, max_count, radius, layer_mode, spawns.size()]


# ── Undo ─────────────────────────────────────────────────────────────────────

func undo_feature() -> String:
	return "spawns"


func undo_snapshot() -> Variant:
	return spawns.duplicate(true)


func undo_restore(snap: Variant) -> void:
	spawns = (snap as Array).duplicate(true)
	selected = -1
	rebuild()
	_refresh_list()
