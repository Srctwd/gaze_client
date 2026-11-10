extends "res://world_editor/tools/place_tool.gd"

# Paint page: per-cell terrain textures (EditorWorldData.paint_cells, saved to
# <world>.cells.bin for the client only). The list's first row erases back to
# the chunk's own texture; the rest is the world's texture palette — every
# image in EditorWorldData.TEXTURE_DIR, added on world load and whenever this page
# opens (EditorWorldData.sync_cell_palette).
# Reaches the editor through `ed`; see tools/place_tool.gd for the hooks.

var _ghost: MeshInstance3D
var _list: ItemList
var _tile_edit: LineEdit
var _radius := 1.0
var _radius_label: Label
var _paint_value := 1          # 0 = erase, k = palette entry k - 1
var _painting := false
var _stroke_before: Variant   # cells snapshot when the stroke started (undo)
var _synced := false           # palette checked against TEXTURE_DIR since this page opened


func build_page(vbox: VBoxContainer) -> void:
	var title := Label.new()
	title.text = "Cell Textures"
	vbox.add_child(title)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 200)
	_list.item_selected.connect(func(idx: int) -> void:
		_paint_value = idx
		if idx > 0:
			_tile_edit.text = str(ed._wd.cell_palette[idx - 1]["tile"])
		ed._set_status("Paint: %s" % _value_name(_paint_value)))
	vbox.add_child(_list)

	var btn_row := HBoxContainer.new()
	_tile_edit = LineEdit.new()
	_tile_edit.text = str(EditorWorldData.DEFAULT_CELL_TILE)
	_tile_edit.custom_minimum_size = Vector2(44, 0)
	_tile_edit.tooltip_text = "Tile — metres per texture repeat"
	var tile_btn := Button.new(); tile_btn.text = "Set tile"
	tile_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile_btn.pressed.connect(_set_tile)
	var del_btn := Button.new(); del_btn.text = "Remove"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.tooltip_text = "Drops a texture whose file is gone; one still in the folder comes back next time"
	del_btn.pressed.connect(_remove_texture)
	btn_row.add_child(_tile_edit); btn_row.add_child(tile_btn); btn_row.add_child(del_btn)
	vbox.add_child(btn_row)

	var r_row := HBoxContainer.new()
	_radius_label = Label.new()
	_radius_label.custom_minimum_size = Vector2(110, 0)
	var slider := HSlider.new()
	slider.min_value = 0.25; slider.max_value = 10.0; slider.step = 0.25; slider.value = _radius
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(func(v: float) -> void:
		_radius = v
		_radius_label.text = "Brush: %.2f m" % v)
	r_row.add_child(_radius_label); r_row.add_child(slider)
	vbox.add_child(r_row)
	_radius_label.text = "Brush: %.2f m" % _radius

	var hint := Label.new()
	hint.text = "[LMB] paint cells (drag)\n[Scroll] cycle texture\nEvery image in %s is listed automatically.\nTextures are client-only: saved to <world>.cells.bin beside the .bin." % EditorWorldData.TEXTURE_DIR.trim_prefix("res://")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(hint)


func _value_name(v: int) -> String:
	if v == 0 or ed._wd == null or v > ed._wd.cell_palette.size():
		return "(erase)"
	return (ed._wd.cell_palette[v - 1]["path"] as String).get_file()


func _refresh_list() -> void:
	if _list == null: return
	_list.clear()
	_list.add_item("(erase — chunk's own texture)")
	if ed._wd != null:
		for k in range(ed._wd.cell_palette.size()):
			var e: Dictionary = ed._wd.cell_palette[k]
			_list.add_item("[%d] %s  (%.2f m)" % [k + 1, (e["path"] as String).get_file(), e["tile"] as float])
	_paint_value = clampi(_paint_value, 0, _list.item_count - 1)
	_list.select(_paint_value)


func _sync() -> void:
	_synced = true
	if ed._wd == null: return
	var added: int = ed._wd.sync_cell_palette()
	_refresh_list()
	if added > 0:
		ed._set_status("Added %d texture(s) from %s" % [added, EditorWorldData.TEXTURE_DIR.trim_prefix("res://")])


func _set_tile() -> void:
	if ed._wd == null or _paint_value == 0 or not _tile_edit.text.is_valid_float(): return
	ed._wd.set_cell_tile(_paint_value - 1, maxf(_tile_edit.text.to_float(), 0.1))
	_refresh_list()


func _remove_texture() -> void:
	if ed._wd == null or _paint_value == 0: return
	var gone := _value_name(_paint_value)
	ed._wd.remove_cell_texture(_paint_value - 1)
	ed._history_for("cells").clear()   # old snapshots hold the old numbering
	_refresh_list()
	ed._set_status("Removed %s — its cells show the chunk's own texture again" % gone)


func _end_stroke() -> void:
	if not _painting: return
	_painting = false
	if _stroke_before != null and _stroke_before != ed._feature_snapshot("cells"):
		ed._history_for("cells").record(_stroke_before)
	_stroke_before = null


# ── place_tool hooks ─────────────────────────────────────────────────────────

func on_world_loaded() -> void:
	_refresh_list()   # load_cells already synced the palette


func on_world_changed() -> void:
	_refresh_list()


func on_lmb(pressed: bool, _event: InputEventMouseButton) -> void:
	if pressed:
		if _paint_value > 0 and ed._wd.cell_palette.is_empty(): return
		_stroke_before = ed._feature_snapshot("cells")
		_painting = true
	else:
		_end_stroke()


func on_scroll(dir: int) -> void:
	if _list == null or _list.item_count == 0: return
	_paint_value = (_paint_value - dir + _list.item_count) % _list.item_count
	_list.select(_paint_value)
	_list.ensure_current_is_visible()
	ed._set_status("Paint: %s" % _value_name(_paint_value))


func update(_delta: float, _mouse: Vector2, hit: Vector3) -> void:
	if not _synced:
		_sync()
	if _ghost == null:
		var disc := CylinderMesh.new()
		disc.top_radius = 1.0; disc.bottom_radius = 1.0; disc.height = 0.05
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.2, 0.8, 1.0, 0.35)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.no_depth_test = true
		disc.surface_set_material(0, mat)
		_ghost = MeshInstance3D.new()
		_ghost.mesh = disc
		add_child(_ghost)
	_ghost.visible  = true
	_ghost.position = hit + Vector3(0, 0.05, 0)
	_ghost.scale    = Vector3(_radius, 1.0, _radius)
	if _painting:
		ed._wd.paint_cells(hit.x, hit.z, _radius, _paint_value)


func is_dragging() -> bool:
	return _painting


func deactivate() -> void:
	_end_stroke()
	_synced = false   # rescan TEXTURE_DIR next time the page opens
	if _ghost: _ghost.visible = false


func status_hint() -> String:
	var under := _value_name(ed._wd.get_cell(_ghost.position.x, _ghost.position.z)) if ed._wd != null and _ghost != null else "?"
	return "[LMB] paint  [Scroll] texture  [9] paint page  — paint: %s  |  under cursor: %s  |  brush %.2f m" % [_value_name(_paint_value), under, _radius]


func undo_feature() -> String:
	return "cells"
