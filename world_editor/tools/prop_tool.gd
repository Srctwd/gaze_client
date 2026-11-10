extends "res://world_editor/tools/place_tool.gd"

# Props page: prop scatter / single placement and the prop type list.
# Reaches the editor (world, camera, shared type tables, status line, undo
# history) through `ed`; see tools/place_tool.gd for the hooks main.gd calls.

var _ghost: Node3D  # this tool's own placement preview

var _prop_paint_type:   int     = 0       # index into _wd._prop_types of the selected prop
var _prop_paint_path:   String  = ""      # selected prop's path — survives world loads, resolved to _prop_paint_type
var _prop_asset_paths:  PackedStringArray  # every prop model/scene under res://assets/props, scanned once at startup
const MIN_PROP_SCALE := 0.01  # a 0 scale makes a node's transform non-invertible ("det == 0" errors)
var _prop_scale_min:    float   = 0.8
var _prop_scale_max:    float   = 1.4
var _prop_place_rot_deg: float  = 0.0  # Alt+LMB single placement: exact rotation/scale (not randomized like scatter)
var _prop_place_scale:   float  = 1.0
var _prop_place_y_offset: float = 0.0  # height above the raycast hit — lets a prop sit above terrain (e.g. a torch mounted on a wall)
var _prop_type_list:    ItemList
var _prop_path_edit:    LineEdit
var _props_aoi:             AoiSet  # prop nodes exist only near the camera
var _prop_scene_cache:      Dictionary = {}
var _prop_last_scatter_pos: Vector3    = Vector3(INF, 0.0, INF)


# Previews the currently selected prop at its Alt+LMB single-placement
# rotation/scale (see _place_single_prop) — scatter placement still randomizes
# per-instance, but this gives a stable reference to line up e.g. a torch.
func _update_prop_ghost(hit: Vector3) -> void:
	if ed._wd == null or ed._wd._prop_types.is_empty() or _prop_paint_type >= ed._wd._prop_types.size():
		if _ghost: _ghost.visible = false
		return
	var path := ed._wd._prop_types[_prop_paint_type] as String
	if _ghost == null or _ghost.get_meta("type", null) != ed.MODE_PROP or _ghost.get_meta("prop_path", "") != path:
		if _ghost: _ghost.queue_free()
		if not _prop_scene_cache.has(path):
			_prop_scene_cache[path] = load(path) as PackedScene
		var sc := _prop_scene_cache[path] as PackedScene
		if sc == null:
			_ghost = null
			return
		var node := sc.instantiate() as Node3D
		node.set_meta("type", ed.MODE_PROP)
		node.set_meta("prop_path", path)
		ed._disable_collision(node)
		if node is MeshInstance3D:
			(node as MeshInstance3D).material_overlay = ed._make_ghost_mat()
		else:
			for mi in node.find_children("*", "MeshInstance3D", true, false):
				mi.material_overlay = ed._make_ghost_mat()
		_ghost = node
		add_child(_ghost)
	_ghost.position   = Vector3(hit.x, hit.y + _prop_place_y_offset, hit.z)
	_ghost.scale      = Vector3.ONE * maxf(_prop_place_scale, MIN_PROP_SCALE)
	_ghost.rotation.y = deg_to_rad(_prop_place_rot_deg)
	_ghost.visible    = true


func _scatter_props(center: Vector3) -> void:
	if ed._wd == null or ed._wd._prop_types.is_empty(): return
	if _prop_paint_type >= ed._wd._prop_types.size(): return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var count := maxi(1, int(ed._obj_radius * 0.6))
	for _i in range(count):
		var angle := rng.randf() * TAU
		var dist  := sqrt(rng.randf()) * ed._obj_radius
		var px    := center.x + cos(angle) * dist
		var pz    := center.z + sin(angle) * dist
		var py    := ed._wd._get_height_at(px, pz)
		var rot_y := rng.randf() * TAU
		var gsc   := rng.randf_range(_prop_scale_min, _prop_scale_max)
		var sx    := gsc * rng.randf_range(0.75, 1.25)
		var sy    := gsc * rng.randf_range(0.75, 1.25)
		var sz    := gsc * rng.randf_range(0.75, 1.25)
		ed._wd.add_prop_instance(_prop_paint_type, px, py, pz, rot_y, sx, sy, sz)
		_props_aoi.add_item(ed._wd._prop_instances.size() - 1)
	ed._set_status("Scattered %d props  (total: %d)" % [count, ed._wd._prop_instances.size()])


# Places exactly one instance at `hit` using the exact rotation/scale set in
# the Props panel, instead of _scatter_props' randomized brush — for props
# that need a deliberate placement (e.g. a torch mounted on a wall).
func _place_single_prop(hit: Vector3) -> void:
	if ed._wd == null or ed._wd._prop_types.is_empty(): return
	if _prop_paint_type >= ed._wd._prop_types.size(): return
	var path := ed._wd._prop_types[_prop_paint_type] as String
	var rot_y := deg_to_rad(_prop_place_rot_deg)
	var s := _prop_place_scale
	var pos := Vector3(hit.x, hit.y + _prop_place_y_offset, hit.z)
	ed._wd.add_prop_instance(_prop_paint_type, pos.x, pos.y, pos.z, rot_y, s, s, s)
	_props_aoi.add_item(ed._wd._prop_instances.size() - 1)
	ed._set_status("Placed %s at (%.1f, %.1f, %.1f) rot=%.0f° scale=%.2f  (total: %d)" %
		[path.get_file(), pos.x, pos.y, pos.z, _prop_place_rot_deg, s, ed._wd._prop_instances.size()])


func _rebuild_props() -> void:
	if _props_aoi != null: _props_aoi.invalidate()


func _build_prop(pd: Dictionary, _i: int, holder: Node3D) -> void:
	var tidx := pd["type_idx"] as int
	if tidx < 0 or tidx >= ed._wd._prop_types.size(): return
	var path := ed._wd._prop_types[tidx] as String
	if not _prop_scene_cache.has(path):
		_prop_scene_cache[path] = load(path) as PackedScene
	var sc := _prop_scene_cache[path] as PackedScene
	if sc == null: return
	var inst := sc.instantiate() as Node3D
	inst.position   = Vector3(pd["x"] as float, pd["y"] as float, pd["z"] as float)
	inst.rotation.y = pd["rot_y"] as float
	# Clamped: a prop saved with a 0 scale (e.g. placed mid-typing before the
	# scale fields rejected 0) would otherwise error every frame.
	inst.scale      = Vector3(maxf(pd["sx"] as float, MIN_PROP_SCALE), maxf(pd["sy"] as float, MIN_PROP_SCALE),
		maxf(pd["sz"] as float, MIN_PROP_SCALE))
	ed._disable_collision(inst)
	holder.add_child(inst)


func _cycle_prop_type(dir: int) -> void:
	if _prop_type_list == null or _prop_type_list.item_count == 0: return
	var sel := _prop_type_list.get_selected_items()
	var i := ((sel[0] as int) if not sel.is_empty() else 0) + dir
	i = (i + _prop_type_list.item_count) % _prop_type_list.item_count
	_prop_type_list.select(i)
	_prop_type_list.ensure_current_is_visible()
	var path := _prop_type_list.get_item_metadata(i) as String
	_select_prop_path(path)
	ed._set_status("Prop: %s" % path.get_file())


# List = every asset model + any prop type the loaded world uses that isn't
# under assets. Items carry their path as metadata; picking one adds it to the
# world's prop types (see _select_prop_path), so the world file only gains
# types that were actually chosen.
func _refresh_prop_list() -> void:
	if _prop_type_list == null: return
	_prop_type_list.clear()
	var paths := PackedStringArray(_prop_asset_paths)
	if ed._wd != null:
		for pt in ed._wd._prop_types:
			if not paths.has(pt as String): paths.append(pt as String)
	for path in paths:
		var i := _prop_type_list.add_item(path.trim_prefix("res://assets/props/").trim_prefix("res://assets/"))
		_prop_type_list.set_item_metadata(i, path)
		_prop_type_list.set_item_tooltip(i, path)
	if _prop_paint_path.is_empty() and ed._wd != null and not ed._wd._prop_types.is_empty():
		_prop_paint_path = ed._wd._prop_types[clampi(_prop_paint_type, 0, ed._wd._prop_types.size() - 1)] as String
	var sel := paths.find(_prop_paint_path)
	if sel >= 0:
		_prop_type_list.select(sel)
		_prop_type_list.ensure_current_is_visible()
		_select_prop_path(_prop_paint_path)

func _select_prop_path(path: String) -> void:
	_prop_paint_path = path
	if ed._wd != null:
		_prop_paint_type = ed._wd.ensure_prop_type(path)


func _add_prop_type_from_dialog() -> void:
	if ed._wd == null or _prop_path_edit == null: return
	var path := _prop_path_edit.text.strip_edges()
	if path.is_empty(): return
	_prop_paint_path = path
	_prop_path_edit.text = ""
	_refresh_prop_list()
	ed._set_status("Prop type added: %s" % path.get_file())


func _remove_prop_type_from_dialog() -> void:
	if ed._wd == null or _prop_type_list == null: return
	var sel := _prop_type_list.get_selected_items()
	if sel.is_empty(): return
	var idx := ed._wd._prop_types.find(_prop_type_list.get_item_metadata(sel[0]) as String)
	if idx < 0:
		ed._set_status("That prop isn't used by this world — nothing to remove")
		return
	ed._wd._prop_types.remove_at(idx)
	for i in range(ed._wd._prop_instances.size() - 1, -1, -1):
		var inst := ed._wd._prop_instances[i] as Dictionary
		if inst["type_idx"] == idx:
			ed._wd._prop_instances.remove_at(i)
		elif (inst["type_idx"] as int) > idx:
			inst["type_idx"] = (inst["type_idx"] as int) - 1  # later types shifted down one slot
	_prop_paint_type = 0
	_prop_paint_path = ""
	_refresh_prop_list()
	_rebuild_props()
	ed._set_status("Prop type removed (all instances erased)")


# Panel page — built by main.gd's _build_side_panel into this page's VBox.
func build_page(prop_vbox: VBoxContainer) -> void:
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.item_selected.connect(func(idx: int):
		var path := list.get_item_metadata(idx) as String
		_select_prop_path(path)
		ed._set_status("Prop: %s" % path.get_file())
	)
	prop_vbox.add_child(list)
	_prop_type_list = list

	prop_vbox.add_child(HSeparator.new())

	var add_row := HBoxContainer.new()
	var ed := LineEdit.new()
	ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ed.placeholder_text = "res://assets/prop.glb"
	var add_btn := Button.new(); add_btn.text = "+"
	add_btn.pressed.connect(_add_prop_type_from_dialog)
	add_row.add_child(ed); add_row.add_child(add_btn)
	prop_vbox.add_child(add_row)
	_prop_path_edit = ed

	var del_btn := Button.new(); del_btn.text = "Remove selected"
	del_btn.pressed.connect(_remove_prop_type_from_dialog)
	prop_vbox.add_child(del_btn)

	var scatter_title := Label.new(); scatter_title.text = "─ Scatter (LMB) ─"
	prop_vbox.add_child(scatter_title)

	var scale_row := HBoxContainer.new()
	var slbl := Label.new(); slbl.text = "Scale"
	slbl.custom_minimum_size = Vector2(36, 0)
	var smin := LineEdit.new(); smin.text = "0.8"; smin.custom_minimum_size = Vector2(44, 0)
	var smax := LineEdit.new(); smax.text = "1.4"; smax.custom_minimum_size = Vector2(44, 0)
	# Scale fields ignore values <= 0 — typing "0.5" passes through "0" and "0.",
	# and a zero scale would place/preview a degenerate node.
	smin.text_changed.connect(func(v: String): _prop_scale_min = v.to_float() if v.is_valid_float() and v.to_float() > 0.0 else _prop_scale_min)
	smax.text_changed.connect(func(v: String): _prop_scale_max = v.to_float() if v.is_valid_float() and v.to_float() > 0.0 else _prop_scale_max)
	scale_row.add_child(slbl); scale_row.add_child(smin); scale_row.add_child(smax)
	prop_vbox.add_child(scale_row)

	prop_vbox.add_child(HSeparator.new())
	var single_title := Label.new(); single_title.text = "─ Single (Alt+LMB) ─"
	prop_vbox.add_child(single_title)

	var single_row := HBoxContainer.new()
	var rlbl := Label.new(); rlbl.text = "Rot° / Scale"
	rlbl.custom_minimum_size = Vector2(70, 0)
	var rot_ed := LineEdit.new(); rot_ed.text = "0"; rot_ed.custom_minimum_size = Vector2(44, 0)
	var pscale_ed := LineEdit.new(); pscale_ed.text = "1.0"; pscale_ed.custom_minimum_size = Vector2(44, 0)
	rot_ed.text_changed.connect(func(v: String): _prop_place_rot_deg = v.to_float() if v.is_valid_float() else _prop_place_rot_deg)
	pscale_ed.text_changed.connect(func(v: String): _prop_place_scale = v.to_float() if v.is_valid_float() and v.to_float() > 0.0 else _prop_place_scale)
	single_row.add_child(rlbl); single_row.add_child(rot_ed); single_row.add_child(pscale_ed)
	prop_vbox.add_child(single_row)

	var prop_yoff_row := HBoxContainer.new()
	var prop_ylbl := Label.new(); prop_ylbl.text = "Y"
	prop_ylbl.custom_minimum_size = Vector2(70, 0)
	var prop_yoff_ed := LineEdit.new(); prop_yoff_ed.text = str(_prop_place_y_offset); prop_yoff_ed.custom_minimum_size = Vector2(44, 0)
	prop_yoff_ed.text_changed.connect(func(v: String): _prop_place_y_offset = v.to_float() if v.is_valid_float() else _prop_place_y_offset)
	prop_yoff_row.add_child(prop_ylbl); prop_yoff_row.add_child(prop_yoff_ed)
	prop_vbox.add_child(prop_yoff_row)

	var prop_hint := Label.new()
	prop_hint.text = "[LMB] scatter (random rot/scale)\n[Alt+LMB] place one (exact rot/scale/y)\n[Alt+Scroll] Y offset\n[Del] erase radius\n[Scroll] brush radius"
	prop_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prop_vbox.add_child(prop_hint)
	_refresh_prop_list()  # asset models are listed from startup, before any world is open


# ── place_tool hooks ─────────────────────────────────────────────────────────

func _ready() -> void:
	_prop_asset_paths = scan_prop_assets()
	_props_aoi = AoiSet.new()
	add_child(_props_aoi)
	_props_aoi.setup(
		func(): return ed._wd._prop_instances if ed != null and ed._wd != null else [],
		func(pd): return Rect2(pd["x"] as float, pd["z"] as float, 0.0, 0.0),
		_build_prop)


func on_world_loaded() -> void:
	_prop_scene_cache.clear()
	_rebuild_props()
	_refresh_prop_list()


func on_world_changed() -> void:
	on_world_loaded()


func on_lmb(pressed: bool, event: InputEventMouseButton) -> void:
	if pressed:
		if event.alt_pressed:
			_place_single_prop(ed._raycast_or_plane(get_viewport().get_mouse_position()))
	else:
		_prop_last_scatter_pos = Vector3(INF, 0.0, INF)


func on_scroll(dir: int) -> void:
	if Input.is_key_pressed(KEY_ALT):
		_prop_place_y_offset += 0.10 * dir
		ed._set_status("Prop Y offset: %+.2f" % _prop_place_y_offset)
	else:
		ed._obj_radius = clampf(ed._obj_radius + 0.5 * dir, 0.5, 30.0)
		ed._set_status("Prop brush: %.1f" % ed._obj_radius)


# Held LMB scatters along the drag; held Delete erases within the brush radius.
func update(_delta: float, _mouse: Vector2, hit: Vector3) -> void:
	_update_prop_ghost(hit)
	if ed._rmb or ed._any_dialog_open(): return
	if ed._lmb and not Input.is_key_pressed(KEY_ALT):
		var dx := hit.x - _prop_last_scatter_pos.x
		var dz := hit.z - _prop_last_scatter_pos.z
		if dx * dx + dz * dz >= (ed._obj_radius * 0.6) * (ed._obj_radius * 0.6):
			_scatter_props(hit)
			_prop_last_scatter_pos = hit
	if Input.is_key_pressed(KEY_DELETE) and not ed._typing():
		var n := ed._wd.remove_props_in_radius(hit.x, hit.z, ed._obj_radius)
		if n > 0:
			_rebuild_props()  # indices shifted — the set rebuilds what's in range


func deactivate() -> void:
	if _ghost: _ghost.visible = false


func status_hint() -> String:
	var pname := ""
	if ed._wd != null and _prop_paint_type < ed._wd._prop_types.size():
		pname = (ed._wd._prop_types[_prop_paint_type] as String).get_file()
	return "[LMB] scatter  [Alt+LMB] place one (rot=%.0f° scale=%.2f y=%+.2f)  [Alt+Scroll] Y offset  [Del] erase radius  — prop: %s  total: %d" % \
		[_prop_place_rot_deg, _prop_place_scale, _prop_place_y_offset, pname, (ed._wd._prop_instances.size() if ed._wd != null else 0)]


# ── Undo ─────────────────────────────────────────────────────────────────────

func undo_feature() -> String:
	return "props"


func undo_snapshot() -> Variant:
	if ed._wd == null: return null
	return { "types": ed._wd._prop_types.duplicate(), "instances": ed._wd._prop_instances.duplicate(true) }


func undo_restore(snap: Variant) -> void:
	var s := snap as Dictionary
	ed._wd._prop_types = (s["types"] as Array).duplicate()
	ed._wd._prop_instances = (s["instances"] as Array).duplicate(true)
	_prop_paint_type = clampi(_prop_paint_type, 0, maxi(ed._wd._prop_types.size() - 1, 0))
	_rebuild_props()
	_refresh_prop_list()


# The scatter / Delete-erase radius.
func brush_radius() -> float:
	return ed._obj_radius
