extends "res://world_editor/tools/place_tool.gd"

# Biomes page: painting chunk biomes and editing biome definitions. Biomes
# are visual only — a name and a prop scatter list; the server never reads them.
# Reaches the editor (world, camera, shared type tables, status line, undo
# history) through `ed`; see tools/place_tool.gd for the hooks main.gd calls.

var _ghost: Node3D  # this tool's own placement preview

var _biome_paint_id:    int     = 0
var _biome_hover_id:    int     = 0
var _biome_list_widget: ItemList
var _biome_name_edit:       LineEdit
var _biome_prop_list:       ItemList
var _biome_prop_picker:     OptionButton  # every prop asset under res://assets/props; item metadata = path
var _biome_prop_weight_edit: LineEdit

func _cycle_biome(dir: int) -> void:
	if ed._wd == null or ed._wd._biomes.is_empty(): return
	var ids: Array = []
	for b in ed._wd._biomes: ids.append((b as Dictionary)["id"] as int)
	var idx := ids.find(_biome_paint_id)
	if idx < 0: idx = 0
	idx = (idx + dir + ids.size()) % ids.size()
	# Same as clicking the row: the list highlight, the edit fields and the
	# paint biome stay in agreement (list rows are in _biomes order).
	if _biome_list_widget != null and idx < _biome_list_widget.item_count:
		_biome_list_widget.select(idx)
		_biome_list_widget.ensure_current_is_visible()
	_on_biome_selected(idx)
	ed._set_status("hover: %s  |  paint: %s" % [ed._wd.get_biome_name(_biome_hover_id), ed._wd.get_biome_name(_biome_paint_id)])


func _update_biome_ghost(hit: Vector3) -> void:
	if ed._wd == null: return
	var chunk_size := ed._wd.chunk_cells * ed._wd.cell_size
	var ax := floori((hit.x - ed._wd.world_ox) / chunk_size)
	var az := floori((hit.z - ed._wd.world_oz) / chunk_size)
	var center_x := ed._wd.world_ox + (ax + 0.5) * chunk_size
	var center_z := ed._wd.world_oz + (az + 0.5) * chunk_size

	if _ghost == null or _ghost.get_meta("type") != ed.MODE_BIOME:
		if _ghost: _ghost.queue_free()
		var plane := PlaneMesh.new()
		plane.size = Vector2(chunk_size, chunk_size)
		var mi := MeshInstance3D.new()
		mi.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.9, 0.6, 0.1, 0.4)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		_ghost = Node3D.new()
		_ghost.set_meta("type", ed.MODE_BIOME)
		_ghost.add_child(mi)
		add_child(_ghost)

	_ghost.position = Vector3(center_x, 0.2, center_z)
	_ghost.visible  = true
	_biome_hover_id = ed._wd.get_chunk_biome(hit.x, hit.z)
	ed._set_status("hover: %s  |  paint: %s" % [ed._wd.get_biome_name(_biome_hover_id), ed._wd.get_biome_name(_biome_paint_id)])


func _build_biome_tab(vbox: VBoxContainer) -> void:
	var title := Label.new()
	title.text = "Biome Manager"
	vbox.add_child(title)

	var list := ItemList.new()
	list.custom_minimum_size = Vector2(0, 130)
	list.item_selected.connect(_on_biome_selected)
	vbox.add_child(list)
	_biome_list_widget = list

	var sep := Label.new()
	sep.text = "── Edit ──"
	vbox.add_child(sep)

	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = "Name"
	lbl.custom_minimum_size = Vector2(80, 0)
	_biome_name_edit = LineEdit.new()
	_biome_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	row.add_child(_biome_name_edit)
	vbox.add_child(row)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)
	var add_btn := Button.new()
	add_btn.text = "Add"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(_add_biome_from_dialog)
	btn_row.add_child(add_btn)
	var upd_btn := Button.new()
	upd_btn.text = "Update"
	upd_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	upd_btn.pressed.connect(_update_biome_from_dialog)
	btn_row.add_child(upd_btn)
	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(_delete_biome_from_dialog)
	btn_row.add_child(del_btn)
	vbox.add_child(btn_row)

	# ── Props (scatter list for the selected biome) ─────
	vbox.add_child(HSeparator.new())
	var props_title := Label.new(); props_title.text = "─ Props ─"
	vbox.add_child(props_title)

	var prop_list := ItemList.new()
	prop_list.custom_minimum_size = Vector2(0, 90)
	vbox.add_child(prop_list)
	_biome_prop_list = prop_list

	var prop_add_row := HBoxContainer.new()
	# Picker filled from the prop assets on disk, so paths aren't typed in.
	var prop_ed := OptionButton.new()
	prop_ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prop_ed.clip_text = true
	for path in scan_prop_assets():
		prop_ed.add_item(path.trim_prefix("res://assets/props/"))
		var i := prop_ed.item_count - 1
		prop_ed.set_item_metadata(i, path)
		prop_ed.set_item_tooltip(i, path)
	var prop_wt := LineEdit.new()
	prop_wt.text = "1.0"
	prop_wt.custom_minimum_size = Vector2(44, 0)
	prop_wt.tooltip_text = "Weight — relative scatter chance vs. this biome's other props"
	var prop_add_btn := Button.new(); prop_add_btn.text = "+"
	prop_add_btn.pressed.connect(_add_biome_prop)
	prop_add_row.add_child(prop_ed); prop_add_row.add_child(prop_wt); prop_add_row.add_child(prop_add_btn)
	vbox.add_child(prop_add_row)
	_biome_prop_picker      = prop_ed
	_biome_prop_weight_edit = prop_wt

	var prop_del_btn := Button.new(); prop_del_btn.text = "Remove selected prop"
	prop_del_btn.pressed.connect(_remove_biome_prop)
	vbox.add_child(prop_del_btn)

	var biome_hint := Label.new()
	biome_hint.text = "[LMB] paint chunk\n[Scroll] cycle paint biome"
	biome_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(biome_hint)


func _add_biome_from_dialog() -> void:
	if ed._wd == null: return
	var name_ := _biome_name_edit.text.strip_edges()
	if name_.is_empty(): return
	ed._wd.add_biome(name_, [])
	_refresh_biome_list()
	_refresh_biome_props_list()
	_biome_name_edit.text = ""
	_save_biomes()


func _save_biomes() -> void:
	if ed._wd == null: return
	var f := FileAccess.open("res://world_editor/biomes.json", FileAccess.WRITE)
	if f == null:
		ed._set_status("ERROR: cannot write biomes.json")
		return
	f.store_string(JSON.stringify(ed._wd._biomes, "\t"))
	f.close()

func _load_biomes() -> void:
	if ed._wd == null: return
	if not FileAccess.file_exists("res://world_editor/biomes.json"): return
	var f := FileAccess.open("res://world_editor/biomes.json", FileAccess.READ)
	if f == null: return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Array and not (parsed as Array).is_empty():
		ed._wd._biomes = parsed as Array
		for b in ed._wd._biomes:
			var bd := b as Dictionary
			for k in ["material", "spawn_type", "spawn_interval", "spawn_max", "spawn_prob"]: bd.erase(k)
			var props_: Array = bd.get("props", []) as Array
			for i in range(props_.size()):
				var p = props_[i]
				if not (p is Dictionary):
					props_[i] = { "path": p as String, "weight": 1.0 }
			bd["props"] = props_

func _refresh_biome_list() -> void:
	if _biome_list_widget == null or ed._wd == null: return
	_biome_list_widget.clear()
	for b in ed._wd._biomes:
		var bd := b as Dictionary
		_biome_list_widget.add_item("[%d] %s" % [bd["id"], bd.get("name","?")])


func _refresh_biome_props_list() -> void:
	if _biome_prop_list == null: return
	_biome_prop_list.clear()
	if ed._wd == null or _biome_list_widget == null: return
	var sel := _biome_list_widget.get_selected_items()
	if sel.is_empty(): return
	var idx := sel[0] as int
	if idx < 0 or idx >= ed._wd._biomes.size(): return
	var bd := ed._wd._biomes[idx] as Dictionary
	var props_: Array = bd.get("props", []) as Array
	for p in props_:
		var pd := p as Dictionary
		var pname := (pd.get("path", "") as String).get_file()
		_biome_prop_list.add_item("%s  (w: %.2f)" % [pname, pd.get("weight", 1.0) as float])


func _add_biome_prop() -> void:
	if ed._wd == null or _biome_list_widget == null or _biome_prop_picker == null: return
	var sel := _biome_list_widget.get_selected_items()
	if sel.is_empty():
		ed._set_status("Select a biome first")
		return
	var idx := sel[0] as int
	if idx < 0 or idx >= ed._wd._biomes.size(): return
	if _biome_prop_picker.selected < 0:
		ed._set_status("No prop assets found under res://assets/props")
		return
	var path := _biome_prop_picker.get_item_metadata(_biome_prop_picker.selected) as String
	var weight := 1.0
	if _biome_prop_weight_edit != null and (_biome_prop_weight_edit.text as String).is_valid_float():
		weight = (_biome_prop_weight_edit.text as String).to_float()
	var bd := ed._wd._biomes[idx] as Dictionary
	var props_: Array = bd.get("props", []) as Array
	props_.append({ "path": path, "weight": weight })
	bd["props"] = props_
	ed._wd._biomes[idx] = bd
	_refresh_biome_props_list()
	_save_biomes()
	ed._set_status("Prop added to biome: %s (w: %.2f)" % [path.get_file(), weight])


func _remove_biome_prop() -> void:
	if ed._wd == null or _biome_list_widget == null or _biome_prop_list == null: return
	var bsel := _biome_list_widget.get_selected_items()
	if bsel.is_empty(): return
	var bidx := bsel[0] as int
	if bidx < 0 or bidx >= ed._wd._biomes.size(): return
	var psel := _biome_prop_list.get_selected_items()
	if psel.is_empty(): return
	var pidx := psel[0] as int
	var bd := ed._wd._biomes[bidx] as Dictionary
	var props_: Array = bd.get("props", []) as Array
	if pidx < 0 or pidx >= props_.size(): return
	props_.remove_at(pidx)
	bd["props"] = props_
	ed._wd._biomes[bidx] = bd
	_refresh_biome_props_list()
	_save_biomes()
	ed._set_status("Prop removed from biome")


func _on_biome_selected(idx: int) -> void:
	if ed._wd == null or idx < 0 or idx >= ed._wd._biomes.size(): return
	var bd := ed._wd._biomes[idx] as Dictionary
	_biome_name_edit.text = bd.get("name", "")
	_refresh_biome_props_list()
	_biome_paint_id = bd.get("id", 0) as int
	ed._set_status("Paint biome: %s" % ed._wd.get_biome_name(_biome_paint_id))


func _update_biome_from_dialog() -> void:
	if ed._wd == null or _biome_list_widget == null: return
	var sel := _biome_list_widget.get_selected_items()
	if sel.is_empty(): return
	var idx := sel[0] as int
	if idx < 0 or idx >= ed._wd._biomes.size(): return
	var name_ := _biome_name_edit.text.strip_edges()
	if name_.is_empty(): return
	var bd := ed._wd._biomes[idx] as Dictionary
	bd["name"] = name_
	ed._wd._biomes[idx] = bd
	_refresh_biome_list()
	_refresh_biome_props_list()
	_save_biomes()
	ed._set_status("Biome updated: %s" % name_)


func _delete_biome_from_dialog() -> void:
	if ed._wd == null or _biome_list_widget == null: return
	var sel := _biome_list_widget.get_selected_items()
	if sel.is_empty(): return
	var idx := sel[0] as int
	if idx < 0 or idx >= ed._wd._biomes.size(): return
	if ed._wd._biomes.size() <= 1:
		ed._set_status("Cannot delete the last biome")
		return
	var removed_id := (ed._wd._biomes[idx] as Dictionary).get("id", -1) as int
	ed._wd._biomes.remove_at(idx)
	if _biome_paint_id == removed_id:
		_biome_paint_id = (ed._wd._biomes[0] as Dictionary).get("id", 0) as int
	_refresh_biome_list()
	_refresh_biome_props_list()
	_save_biomes()
	ed._set_status("Biome deleted")


# ── place_tool hooks ─────────────────────────────────────────────────────────

func build_page(vbox: VBoxContainer) -> void:
	_build_biome_tab(vbox)


func on_world_loaded() -> void:
	_load_biomes()
	on_world_changed()


func on_world_changed() -> void:
	_refresh_biome_list()
	_refresh_biome_props_list()


func on_lmb(pressed: bool, _event: InputEventMouseButton) -> void:
	if not pressed: return
	var hit := ed._raycast_or_plane(get_viewport().get_mouse_position())
	ed._wd.set_chunk_biome(hit.x, hit.z, _biome_paint_id)
	ed._set_status("Painted '%s' on chunk" % ed._wd.get_biome_name(_biome_paint_id))


func on_scroll(dir: int) -> void:
	_cycle_biome(dir)


func update(_delta: float, _mouse: Vector2, hit: Vector3) -> void:
	_update_biome_ghost(hit)


func deactivate() -> void:
	if _ghost: _ghost.visible = false


func status_hint() -> String:
	var hover := ed._wd.get_biome_name(_biome_hover_id) if ed._wd != null else "?"
	var paint := ed._wd.get_biome_name(_biome_paint_id) if ed._wd != null else "?"
	return "[LMB] paint  [Scroll] cycle  [B] biome tab  — hover: %s  |  paint: %s" % [hover, paint]


# ── Undo ─────────────────────────────────────────────────────────────────────
# Chunk painting only: biome definitions live in the shared biomes.json,
# written on every edit, so they stay out of a per-world history.

func undo_feature() -> String:
	return "biomes"


func undo_snapshot() -> Variant:
	if ed._wd == null: return null
	return ed._wd.chunk_biomes_snapshot()


func undo_restore(snap: Variant) -> void:
	ed._wd.chunk_biomes_restore(snap as Dictionary)
