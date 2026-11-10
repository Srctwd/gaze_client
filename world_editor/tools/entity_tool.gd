extends "res://world_editor/tools/place_tool.gd"

# Hand-placed entities — the editor side of the server's entities.json (see
# entities_load in src/systems/entities.cpp): chests and berry bushes. Each
# opened world keeps its own list next to it: world.bin <-> world.entities.json;
# deploy copies that file to ~/stone_gaze/entities.json.
#
# Entry shapes (same as the server reads; keys this tool doesn't know are kept):
#   {"type": "Chest", "id", "x", "z", "y"?, "rot_y", "items": [{"item", "quantity"?}]}
#   {"type": "BerryBush", "x", "z", "y"?, "rot_y", "max", "regrow"}
# "y" is written only when the entity stands off the terrain (a floor, a cave),
# like the hand-written chests — the server uses the terrain height otherwise.

const TYPES        := ["Chest", "BerryBush"]
const PICK_RADIUS  := 1.2
const CHEST_COLOR  := Color(0.65, 0.4, 0.15)
const BUSH_COLOR   := Color(0.2, 0.7, 0.25)
const SEL_COLOR    := Color(1.0, 0.9, 0.2)
const GHOST_ALPHA  := 0.45
const ROT_STEP     := PI / 12.0  # 15° per scroll notch

var wd: EditorWorldData
var entities: Array = []   # Array[Dictionary], entries as above
var selected: int = -1
var item_names: PackedStringArray = []

# Settings for the next placed entity — also what the panel edits on the selected one.
var type: String = "BerryBush"
var rot_y: float = 0.0
var items_text: String = "Torch"   # chest contents: "Torch, Arrow x5"
var bush_max: int = 12
var bush_regrow: float = 60.0

var _markers: AoiSet   # entity markers exist only near the camera
var _ghost: MeshInstance3D
var _list: ItemList
var _fields: Dictionary = {}  # field name -> Control
var _syncing := false
var _moving := false          # LMB went down on an entity: dragging moves it


func _ready() -> void:
	_markers = AoiSet.new()
	add_child(_markers)
	_markers.setup(func(): return entities,
		func(e): return Rect2(float(e["x"]), float(e["z"]), 0.0, 0.0),
		_build_marker)
	_ghost = MeshInstance3D.new()
	add_child(_ghost)
	_ghost.visible = false
	_load_item_names()


# ── data ─────────────────────────────────────────────────────────────────────

func _load_item_names() -> void:
	var path := ProjectSettings.globalize_path("res://").path_join("../stone_gaze/item_types.json")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("EntityTool: cannot open " + path)
		return
	var data = JSON.parse_string(f.get_as_text())
	if data is Array:
		for it in data:
			if it is Dictionary and (it as Dictionary).has("name"):
				item_names.append((it as Dictionary)["name"] as String)


static func path_for(world_path: String) -> String:
	return world_path.get_basename() + ".entities.json"


func setup(world: EditorWorldData) -> void:
	wd = world
	entities.clear()
	selected = -1
	rebuild()


func load_for(world_path: String) -> int:
	entities.clear()
	selected = -1
	var f := FileAccess.open(path_for(world_path), FileAccess.READ)
	if f != null:
		var data = JSON.parse_string(f.get_as_text())
		if data is Array:
			for e in data:
				if e is Dictionary: entities.append(_normalized(e as Dictionary))
	rebuild()
	return entities.size()


# One entry per line, keys in a fixed order — easy to read and diff.
func save_for(world_path: String) -> bool:
	var f := FileAccess.open(path_for(world_path), FileAccess.WRITE)
	if f == null:
		push_error("EntityTool: cannot write " + path_for(world_path))
		return false
	var lines := PackedStringArray()
	for e in entities:
		lines.append("  " + _entry_json(e as Dictionary))
	f.store_string("[\n" + ",\n".join(lines) + "\n]\n")
	return true


func _entry_json(e: Dictionary) -> String:
	var order := ["type", "id", "x", "y", "z", "rot_y", "max", "regrow", "items"]
	var parts := PackedStringArray()
	for k in order:
		if e.has(k): parts.append("%s: %s" % [JSON.stringify(k), JSON.stringify(e[k])])
	for k in e:
		if not k in order: parts.append("%s: %s" % [JSON.stringify(k), JSON.stringify(e[k])])
	return "{ " + ", ".join(parts) + " }"


# JSON numbers load as floats — keep counts and ids as ints so the file round-trips cleanly.
func _normalized(e: Dictionary) -> Dictionary:
	var out := e.duplicate(true)
	out["type"] = str(out.get("type", "Chest"))
	if out.has("id"): out["id"] = int(out["id"])
	if out.has("max"): out["max"] = int(out["max"])
	if out.has("items"):
		for it in out["items"]:
			if it is Dictionary and (it as Dictionary).has("quantity"):
				(it as Dictionary)["quantity"] = int((it as Dictionary)["quantity"])
	return out


func _next_chest_id() -> int:
	var top := 0
	for e in entities:
		if (e as Dictionary).get("type") == "Chest": top = maxi(top, int((e as Dictionary).get("id", 0)))
	return top + 1


# "Torch, Arrow x5" <-> [{"item": "Torch"}, {"item": "Arrow", "quantity": 5}]
func _parse_items(text: String) -> Array:
	var out := []
	for part in text.split(",", false):
		var p := part.strip_edges()
		if p.is_empty(): continue
		var qty := 1
		var m := RegEx.create_from_string("^(.*?)\\s+x(\\d+)$").search(p)
		if m:
			p = m.get_string(1).strip_edges()
			qty = maxi(int(m.get_string(2)), 1)
		out.append({ "item": p } if qty == 1 else { "item": p, "quantity": qty })
	return out


static func _items_text(items: Array) -> String:
	var parts := PackedStringArray()
	for it in items:
		var d := it as Dictionary
		var q := int(d.get("quantity", 1))
		parts.append(str(d.get("item", "")) + ("" if q == 1 else " x%d" % q))
	return ", ".join(parts)


func _unknown_items(items: Array) -> PackedStringArray:
	var bad := PackedStringArray()
	for it in items:
		var n := str((it as Dictionary).get("item", ""))
		if not item_names.is_empty() and not n in item_names: bad.append(n)
	return bad


# ── editing ──────────────────────────────────────────────────────────────────

func _terrain_y(x: float, z: float) -> float:
	if wd == null: return 0.0
	var y := wd.get_layer_height_at(x, z, "h1")
	return 0.0 if is_nan(y) else y


func _entity_y(e: Dictionary) -> float:
	return float(e["y"]) if e.has("y") else _terrain_y(float(e["x"]), float(e["z"]))


# Writes the position; "y" only when the point is off the terrain.
func _set_pos(e: Dictionary, hit: Vector3) -> void:
	e["x"] = snappedf(hit.x, 0.1)
	e["z"] = snappedf(hit.z, 0.1)
	if absf(hit.y - _terrain_y(hit.x, hit.z)) > 0.05: e["y"] = snappedf(hit.y, 0.01)
	else: e.erase("y")


func add_at(hit: Vector3) -> void:
	var e := { "type": type, "rot_y": snappedf(rot_y, 0.01) }
	if type == "Chest":
		e["id"] = _next_chest_id()
		e["items"] = _parse_items(items_text)
	else:
		e["max"] = bush_max
		e["regrow"] = bush_regrow
	_set_pos(e, hit)
	entities.append(e)
	select(entities.size() - 1)


# Index of the entity nearest `hit` within PICK_RADIUS (planar), -1 if none.
func pick(hit: Vector3) -> int:
	var best := -1
	var best_d := PICK_RADIUS
	for i in entities.size():
		var e := entities[i] as Dictionary
		var d := Vector2(hit.x - float(e["x"]), hit.z - float(e["z"])).length()
		if d < best_d:
			best_d = d
			best = i
	return best


func remove(i: int) -> void:
	if i < 0 or i >= entities.size(): return
	entities.remove_at(i)
	selected = -1
	rebuild()


func select(i: int) -> void:
	selected = i
	if i >= 0 and i < entities.size():
		var e := entities[i] as Dictionary
		type = e["type"]
		rot_y = float(e.get("rot_y", 0.0))
		if type == "Chest":
			items_text = _items_text(e.get("items", []))
		else:
			bush_max = int(e.get("max", 1))
			bush_regrow = float(e.get("regrow", 60.0))
	_sync_fields()
	rebuild()


# Panel edits go to the selected entity (as well as becoming the settings for
# the next placement). The type of a placed entity doesn't change.
func _apply_to_selected() -> void:
	if _syncing or selected < 0 or selected >= entities.size(): return
	var e := entities[selected] as Dictionary
	e["rot_y"] = snappedf(rot_y, 0.01)
	if e["type"] == "Chest":
		e["items"] = _parse_items(items_text)
	elif e["type"] == "BerryBush":
		e["max"] = bush_max
		e["regrow"] = bush_regrow
	rebuild()


# ── visuals ──────────────────────────────────────────────────────────────────

func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if color.a < 1.0: m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


# A chest-sized box, or a bush-sized sphere — the game's models live in gaze_client.
func _shape(t: String) -> Mesh:
	if t == "Chest":
		var b := BoxMesh.new()
		b.size = Vector3(1.25, 0.77, 0.74)
		return b
	var s := SphereMesh.new()
	s.radius = 0.7
	s.height = 1.3
	return s


func _shape_offset(t: String) -> Vector3:
	return Vector3(0, 0.385, 0) if t == "Chest" else Vector3(0, 0.65, 0)


func _label(text: String, color: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.modulate = color
	l.outline_size = 8
	l.font_size = 40
	l.pixel_size = 0.01
	return l


func _describe(e: Dictionary) -> String:
	if e["type"] == "Chest":
		return "Chest #%d: %s" % [int(e.get("id", 0)), _items_text(e.get("items", []))]
	return "BerryBush ×%d / %ds" % [int(e.get("max", 1)), int(float(e.get("regrow", 60.0)))]


func rebuild() -> void:
	if _markers == null: return
	_markers.invalidate()
	_refresh_list()


func _build_marker(e: Dictionary, i: int, holder: Node3D) -> void:
	var t := e["type"] as String
	var base := CHEST_COLOR if t == "Chest" else BUSH_COLOR
	var pos := Vector3(float(e["x"]), _entity_y(e), float(e["z"]))
	var root := Node3D.new()
	holder.add_child(root)
	root.position = pos
	root.rotation.y = float(e.get("rot_y", 0.0))
	var mi := MeshInstance3D.new()
	mi.mesh = _shape(t)
	mi.position = _shape_offset(t)
	mi.material_override = _mat(SEL_COLOR if i == selected else base)
	root.add_child(mi)
	var lbl := _label(_describe(e), SEL_COLOR if i == selected else Color.WHITE)
	lbl.position = Vector3(0, 2.0, 0)
	root.add_child(lbl)


func _update_ghost(hit: Vector3) -> void:
	_ghost.visible = true
	_ghost.mesh = _shape(type)
	var c := CHEST_COLOR if type == "Chest" else BUSH_COLOR
	_ghost.material_override = _mat(Color(c.r, c.g, c.b, GHOST_ALPHA))
	_ghost.position = hit + _shape_offset(type).rotated(Vector3.UP, rot_y)
	_ghost.rotation.y = rot_y


# ── panel page ───────────────────────────────────────────────────────────────

func _row(vbox: VBoxContainer, label: String, ctrl: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(70, 0)
	row.add_child(l)
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ctrl)
	vbox.add_child(row)
	return row


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
	var typ := OptionButton.new()
	for t in TYPES: typ.add_item(t)
	typ.selected = TYPES.find(type)
	typ.item_selected.connect(func(i: int):
		type = TYPES[i]
		_sync_fields()
		ed._set_status("Entity type: " + type)
	)
	_fields["type"] = typ
	_row(vbox, "Type", typ)

	_row(vbox, "Rot °", _num_edit("rot", roundi(rad_to_deg(rot_y)), func(v: String): rot_y = deg_to_rad(float(v))))

	var items := LineEdit.new()
	items.text = items_text
	items.placeholder_text = "Torch, Arrow x5"
	items.text_changed.connect(func(v: String):
		items_text = v
		var bad := _unknown_items(_parse_items(v))
		if not bad.is_empty(): ed._set_status("Unknown item(s): " + ", ".join(bad))
		_apply_to_selected()
	)
	_fields["items"] = items
	_fields["items_row"] = _row(vbox, "Items", items)

	_fields["max_row"] = _row(vbox, "Berries", _num_edit("max", bush_max, func(v: String): bush_max = clampi(int(v), 1, 12)))
	_fields["regrow_row"] = _row(vbox, "Regrow s", _num_edit("regrow", bush_regrow, func(v: String): bush_regrow = maxf(float(v), 1.0)))

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
	hint.text = "[LMB] place the chosen type   [LMB] on one: select it — drag to move it; the fields above then edit it\n[Scroll] rotate (the selected one too)   [Del] remove the one under the cursor\nChest ids are assigned automatically and must never be reused (they key who has looted it).\nSaved with the world as <world>.entities.json — deploy it as entities.json"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(hint)
	_sync_fields()
	_refresh_list()


func _refresh_list() -> void:
	if _list == null: return
	_list.clear()
	for e in entities:
		_list.add_item(_describe(e as Dictionary))
	if selected >= 0 and selected < _list.item_count:
		_list.select(selected)


func _sync_fields() -> void:
	if _fields.is_empty(): return
	_syncing = true
	(_fields["type"] as OptionButton).selected = TYPES.find(type)
	(_fields["rot"] as LineEdit).text = str(roundi(rad_to_deg(rot_y)))
	(_fields["items"] as LineEdit).text = items_text
	(_fields["max"] as LineEdit).text = str(bush_max)
	(_fields["regrow"] as LineEdit).text = str(bush_regrow)
	(_fields["items_row"] as Control).visible = type == "Chest"
	(_fields["max_row"] as Control).visible = type == "BerryBush"
	(_fields["regrow_row"] as Control).visible = type == "BerryBush"
	_syncing = false


# ── place_tool hooks ─────────────────────────────────────────────────────────

func on_world_loaded() -> void:
	setup(ed._wd)
	if not ed._world_path.is_empty():
		load_for(ed._world_path)


# Import reshapes terrain under the entities — re-seat their markers.
func on_world_changed() -> void:
	rebuild()


func on_lmb(pressed: bool, _event: InputEventMouseButton) -> void:
	var hit := ed._raycast_or_plane(get_viewport().get_mouse_position())
	if pressed:
		var picked := pick(hit)
		if picked >= 0:
			select(picked)
			_moving = true
			ed._set_status("Selected " + _describe(entities[picked] as Dictionary))
		else:
			add_at(hit)
			ed._set_status("Placed " + _describe(entities[selected] as Dictionary))
	elif _moving:
		_moving = false


func on_scroll(dir: int) -> void:
	rot_y = wrapf(rot_y + ROT_STEP * dir, -PI, PI)
	_sync_fields()
	_apply_to_selected()
	ed._set_status("Rotation: %d°" % roundi(rad_to_deg(rot_y)))


func on_delete(_event: InputEventKey, hit: Vector3) -> void:
	var i := pick(hit)
	if i < 0: return
	var removed := _describe(entities[i] as Dictionary)
	remove(i)
	ed._set_status("Removed " + removed)


func cancel() -> String:
	if not _moving: return ""
	_moving = false
	return "Entity move stopped"


func is_dragging() -> bool:
	return _moving


func update(_delta: float, _mouse: Vector2, hit: Vector3) -> void:
	if _moving and selected >= 0 and selected < entities.size():
		_ghost.visible = false
		_set_pos(entities[selected] as Dictionary, hit)
		rebuild()
		return
	_update_ghost(hit)


func deactivate() -> void:
	_moving = false
	if _ghost: _ghost.visible = false


func status_hint() -> String:
	return "[LMB] place  [LMB on one] select/drag to move  [Scroll] rotate  [Del] remove  — %s rot %d°  (%d entities)" % \
		[type, roundi(rad_to_deg(rot_y)), entities.size()]


# ── Undo ─────────────────────────────────────────────────────────────────────

func undo_feature() -> String:
	return "entities"


func undo_snapshot() -> Variant:
	return entities.duplicate(true)


func undo_restore(snap: Variant) -> void:
	entities = (snap as Array).duplicate(true)
	selected = -1
	rebuild()
	_sync_fields()
	_refresh_list()
