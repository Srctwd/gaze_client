extends Node3D
class_name WorldEditor


var _wd: EditorWorldData
var _terrain: Node3D
var _cam: Camera3D
var _label: Label

var _cam_yaw   := 0.0
var _cam_pitch := -0.4
var _cam_pos   := Vector3(0.0, 20.0, 30.0)

var _rmb        := false
var _lmb        := false
var _snap_key_done := false  # one snap per N press — re-armed when N is released
var _brush_r    := 1.0
var _brush_str  := 30.0
var _world_path := ""
var _layer      := "h1"
var _water_height := 0.0  # Y of the water sheet [O] puts on an ocean chunk

var _mode        := "terrain"  # "terrain" | "place"
# Terrain-mode vertex selection: LMB picks the nearest vertex of the current
# layer, Ctrl+LMB (click or drag) adds every vertex under the brush. The
# panel's Height field then sets all of them to an exact value. Keyed by
# Vector2(x, z) world position; cleared on Esc or a layer change.
var _sel_verts:   Dictionary = {}
# Ctrl+LMB stroke mode, decided on press: true when the press landed on an
# already-selected vertex, so the stroke removes instead of adds.
var _sel_removing := false
var _sel_markers: MultiMeshInstance3D
var _sel_label:   Label
var _sel_height:  LineEdit
var _radius_edit: LineEdit     # terrain panel Radius field — kept in sync with _brush_r
var _layer_btns:  Dictionary = {}  # "h1"/"h2"/"h3" -> toggle Button; the pressed one is _layer
# _place_type is either an object-type id from the `object_types` file (see
# _object_type_defs), or one of the MODE_* sentinels below for placement
# modes that aren't a static object (they live in a disjoint numeric range
# so they can never collide with a real/future object-type id).
const MODE_CHUNK := 100
const MODE_WATER := 101
const MODE_BIOME := 102
const MODE_PROP  := 103
const MODE_WALL  := 104
const MODE_SPAWN := 105
const MODE_CELLS := 106
const MODE_ENTITY := 107
var _place_type  := 0          # default: object-type id 0 (Tree)
var _obj_radius  := 1.5

# Place-mode tools, one per page of the side panel (tools/*.gd, all built on
# tools/place_tool.gd). main.gd routes input to _active_tool(); each tool owns
# its own state, preview and panel page.
# Where the world .bin files (village.bin, rats.bin, ...) live; the file
# dialogs start here rather than in the project root (res://, the game).
var _worlds_dir := ProjectSettings.globalize_path("res://world_editor")

const PlaceTool  := preload("res://world_editor/tools/place_tool.gd")
const ObjectTool := preload("res://world_editor/tools/object_tool.gd")
const PropTool   := preload("res://world_editor/tools/prop_tool.gd")
const BiomeTool  := preload("res://world_editor/tools/biome_tool.gd")
const WallTool   := preload("res://world_editor/tools/wall_tool.gd")
const SpawnTool  := preload("res://world_editor/tools/spawn_tool.gd")
const CellTool   := preload("res://world_editor/tools/cell_tool.gd")
const EntityTool := preload("res://world_editor/tools/entity_tool.gd")
var _object_tool: ObjectTool   # static objects, water, chunk add (Objects + Chunks tabs)
var _prop_tool:   PropTool
var _biome_tool:  BiomeTool
var _wall_tool:   WallTool
var _spawn_tool:  SpawnTool
var _cell_tool:   CellTool
var _entity_tool: EntityTool
var _current_tool: PlaceTool   # the tool that got update() last frame — deactivated when it changes

# Walls, water and static objects are built only near the camera (AoiSet);
# props, spawns and chests have their own sets in their tools.
var _walls_aoi:      AoiSet
var _water_aoi:      AoiSet
var _objects_aoi:    AoiSet
var _pillars_aoi:    AoiSet
var _brush_mesh:     ImmediateMesh
# Right side panel: a dropdown (Menu, Terrain, Objects, ...) over the chosen
# page. Esc shows / hides it; see _sync_side_panel.
var _side_panel:   Panel
var _side_pick:    OptionButton
var _side_pages:   Array        # Array[Control], one per SIDE_PAGES entry
var _side_visible := true
var _menu_open    := false      # the Menu page is showing (the mode is kept underneath)
var _world_info:   Label        # Menu page: open file + size
var _brush_mat:    StandardMaterial3D
var _brush_verts:  MultiMeshInstance3D  # white markers on the vertices the terrain brush will touch
var _object_type_defs: Dictionary = {}  # id(int) -> {name, mesh, collision_ratio, height_ratio, scale_ratio, resource}
var _wall_type_defs:   Dictionary = {}  # id(int) -> {name, material, mesh}
var _new_dialog:    Panel
var _new_fields:    Array  # [chunks_x, chunks_z, chunk_cells, cell_size, base_h]
var _save_dialog:   FileDialog
# Terrain chunks within this many metres of the camera are built (meshes,
# collision, vertex markers); the rest stay data only. See update_streaming.
const TERRAIN_STREAM_RADIUS := 160.0
const UndoHistory := preload("res://world_editor/undo_history.gd")
const WorldShaders := preload("res://world/world_shaders.gd")  # gaze_client's materials, so walls look as in game

# Per-feature undo (Ctrl+Z / Ctrl+Shift+Z or Ctrl+Y): each feature keeps its
# own history, so undoing a wall never rewinds a terrain stroke. See the Undo
# section for how each feature records its steps.
var _history := { "walls": UndoHistory.new(), "terrain": UndoHistory.new(), "objects": UndoHistory.new(),
	"cells": UndoHistory.new(), "props": UndoHistory.new(), "biomes": UndoHistory.new(),
	"spawns": UndoHistory.new(), "entities": UndoHistory.new() }
var _history_wd: EditorWorldData  # the world the histories belong to — reset when another is loaded
var _undo_base := {}        # snapshot-diff feature -> its state as of the last recorded step
var _undo_check := false    # a mouse/key release happened — commit snapshot-diff features once idle
var _terrain_stroke = null  # open terrain stroke: {"chunks": {grid: state before}}, null between strokes
var _import_file_dialog: FileDialog
var _import_dialog:      Panel
var _import_fields:      Array       # [offset_x_edit, offset_z_edit]
var _import_layer_checks: Dictionary # layer name -> CheckBox
var _pending_import_path: String = ""
var _pending_import_frag: EditorWorldData = null
var _import_picking: bool = false
var _help_panel:    Panel
var _help_grid:     GridContainer
# Panel -> [confirm Callable (or invalid), cancel Callable]: what Enter and
# Esc do while that dialog is up (see _dialog_key).
var _dialog_keys:   Dictionary = {}
var _mode_select:      Panel
var _talent_tree_view: CanvasLayer = null
var _world_editor_entered: bool = false  # true only after "World Editor" is clicked on the startup screen


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Closing the window must never silently save — use Save/Save As
		# (Ctrl+S / Ctrl+Shift+S) or the Esc menu if you want to persist.
		get_tree().quit()

func _ready() -> void:
	get_tree().auto_accept_quit = false
	# Space is camera-up here. Godot binds it to ui_accept / ui_select by
	# default, so a focused button, ItemList or open dropdown popup would
	# activate on it. Unbind it from the UI actions (Enter still confirms;
	# text fields still type spaces, which come from unicode, not actions).
	for action in ["ui_accept", "ui_select"]:
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey and (ev.keycode == KEY_SPACE or ev.physical_keycode == KEY_SPACE):
				InputMap.action_erase_event(action, ev)
	_cam = Camera3D.new()
	add_child(_cam)
	_apply_camera()

	var fill := OmniLight3D.new()
	fill.omni_range    = 40.0
	fill.light_energy  = 1.2
	fill.light_color   = Color(1.0, 0.95, 0.85)
	_cam.add_child(fill)

	var sun := DirectionalLight3D.new()
	sun.rotation      = Vector3(-0.8, 0.5, 0.0)
	sun.light_energy  = 1.5
	sun.shadow_enabled = true
	add_child(sun)

	_load_object_types()
	_load_wall_types()
	_make_tools()

	_terrain = Node3D.new()
	add_child(_terrain)
	AoiSet.radius = TERRAIN_STREAM_RADIUS
	_walls_aoi = _make_aoi(
		func(): return _wd._walls if _wd != null else [],
		EditorWorldData.wall_footprint,
		func(d, _i, holder): _wd.build_wall(d, holder))
	_water_aoi = _make_aoi(
		func(): return _wd._water_rects if _wd != null else [],
		EditorWorldData.water_rect_footprint,
		func(d, _i, holder): _wd.build_water_rect(d, holder))
	_objects_aoi = _make_aoi(
		func(): return _wd._static_objects if _wd != null else [],
		func(d): return Rect2((d.x as float) - (d.radius as float), (d.z as float) - (d.radius as float), (d.radius as float) * 2.0, (d.radius as float) * 2.0),
		_build_object)
	_pillars_aoi = _make_aoi(
		func(): return _wd._pillars if _wd != null else [],
		EditorWorldData.pillar_footprint,
		func(d, _i, holder): _wd.build_pillar(d, holder))

	_brush_mesh = ImmediateMesh.new()
	_brush_mat  = StandardMaterial3D.new()
	_brush_mat.shading_mode    = BaseMaterial3D.SHADING_MODE_UNSHADED
	_brush_mat.albedo_color    = Color(1.0, 0.9, 0.1)
	_brush_mat.no_depth_test   = true
	_brush_mat.transparency    = BaseMaterial3D.TRANSPARENCY_ALPHA
	var brush_mi               := MeshInstance3D.new()
	brush_mi.mesh              = _brush_mesh
	brush_mi.material_override = _brush_mat
	add_child(brush_mi)

	var vmat := StandardMaterial3D.new()
	vmat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
	vmat.albedo_color  = Color(1.0, 1.0, 1.0)
	vmat.no_depth_test = true  # h2/h3 vertices sit under h1 — still show which ones the brush hits
	var vsp := SphereMesh.new()
	vsp.radial_segments = 6
	vsp.rings           = 3
	vsp.surface_set_material(0, vmat)
	var vmm := MultiMesh.new()
	vmm.transform_format = MultiMesh.TRANSFORM_3D
	vmm.mesh             = vsp
	_brush_verts           = MultiMeshInstance3D.new()
	_brush_verts.multimesh = vmm
	add_child(_brush_verts)

	var smat := vmat.duplicate() as StandardMaterial3D
	smat.albedo_color = Color(1.0, 0.2, 0.2)
	var ssp := vsp.duplicate() as SphereMesh
	ssp.surface_set_material(0, smat)
	var smm := MultiMesh.new()
	smm.transform_format = MultiMesh.TRANSFORM_3D
	smm.mesh             = ssp
	_sel_markers           = MultiMeshInstance3D.new()
	_sel_markers.multimesh = smm
	add_child(_sel_markers)

	var ui    := CanvasLayer.new()
	add_child(ui)
	_label = Label.new()
	_label.position = Vector2(10.0, 10.0)
	ui.add_child(_label)
	_label.text = "Open a world.bin to begin"

	var dialog := FileDialog.new()
	dialog.file_mode  = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access     = FileDialog.ACCESS_FILESYSTEM
	dialog.current_dir = _worlds_dir
	dialog.filters    = PackedStringArray(["*.bin ; World Binary"])
	dialog.file_selected.connect(_load_world)
	dialog.canceled.connect(func(): _label.text = "No file loaded")
	add_child(dialog)

	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access    = FileDialog.ACCESS_FILESYSTEM
	_save_dialog.current_dir = _worlds_dir
	_save_dialog.filters   = PackedStringArray(["*.bin ; World Binary"])
	_save_dialog.file_selected.connect(func(p: String):
		_world_path = p
		_save()
	)
	add_child(_save_dialog)

	_import_file_dialog = FileDialog.new()
	_import_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_import_file_dialog.access    = FileDialog.ACCESS_FILESYSTEM
	_import_file_dialog.current_dir = _worlds_dir
	_import_file_dialog.filters   = PackedStringArray(["*.bin ; World Binary"])
	_import_file_dialog.file_selected.connect(func(p: String):
		var frag := EditorWorldData.new()
		if not frag.load(p):
			_set_status("ERROR: cannot read fragment " + p.get_file())
			return
		_pending_import_path = p
		_pending_import_frag = frag
		_import_dialog.visible = true
	)
	add_child(_import_file_dialog)

	_new_dialog     = _build_new_dialog(ui)
	_import_dialog  = _build_import_dialog(ui)
	_side_panel     = _build_side_panel(ui)
	_help_panel     = _build_help_panel(ui)
	_dialog_keys = {
		_help_panel:    [Callable(), func(): _help_panel.visible = false],
		_import_dialog: [_confirm_import_fragment, func(): _import_dialog.visible = false],
		_new_dialog:    [_create_new_world, func(): _new_dialog.visible = false],
	}
	# A form dialog opens with its first field focused and selected, so it
	# can be typed into and submitted with Enter without touching the mouse.
	for dlg in [_new_dialog, _import_dialog]:
		var d: Panel = dlg
		d.visibility_changed.connect(func():
			if not d.visible: return
			var fields := d.find_children("*", "LineEdit", true, false)
			if not fields.is_empty():
				(fields[0] as LineEdit).grab_focus()
				(fields[0] as LineEdit).select_all()
		)

	_mode_select = _build_mode_select(ui, func():
		dialog.popup_centered_ratio(0.5)
	)


func _make_tools() -> void:
	_object_tool = ObjectTool.new()
	_prop_tool   = PropTool.new()
	_biome_tool  = BiomeTool.new()
	_wall_tool   = WallTool.new()
	_spawn_tool  = SpawnTool.new()
	_cell_tool   = CellTool.new()
	_entity_tool = EntityTool.new()
	for t in _tools():
		t.ed = self
		add_child(t)


func _tools() -> Array:
	return [_object_tool, _prop_tool, _biome_tool, _wall_tool, _spawn_tool, _cell_tool, _entity_tool]


# The tool that owns the current _place_type. Object-type ids, water and
# chunk-add all belong to the object tool.
func _active_tool() -> PlaceTool:
	match _place_type:
		MODE_PROP:  return _prop_tool
		MODE_BIOME: return _biome_tool
		MODE_WALL:  return _wall_tool
		MODE_SPAWN: return _spawn_tool
		MODE_CELLS: return _cell_tool
		MODE_ENTITY: return _entity_tool
	return _object_tool


# A world was just opened or created: every tool rebuilds what it derives from it.
func _notify_world_loaded() -> void:
	for t in _tools():
		t.on_world_loaded()
	_clear_vertex_selection()
	_menu_open = false  # opened from the Menu page: go back to the tool page
	_history_wd = _wd
	_history_clear()


# First thing shown on launch: choose between the terrain/object editor and
# the read-only talent tree graph viewer. Returns the panel so _ready() can
# hide it once a choice is made.
func _build_mode_select(ui: CanvasLayer, on_world_editor: Callable) -> Panel:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(280, 220)
	panel.anchor_left = 0.5; panel.anchor_right  = 0.5
	panel.anchor_top  = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left = -140; panel.offset_right  = 140
	panel.offset_top  = -110; panel.offset_bottom = 110
	ui.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "What do you want to open?"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var world_btn := Button.new()
	world_btn.text = "World Editor"
	world_btn.custom_minimum_size = Vector2(0, 40)
	world_btn.pressed.connect(func():
		panel.visible = false
		_world_editor_entered = true
		on_world_editor.call()
	)
	vbox.add_child(world_btn)

	var new_world_btn := Button.new()
	new_world_btn.text = "New World"
	new_world_btn.custom_minimum_size = Vector2(0, 40)
	new_world_btn.pressed.connect(func():
		panel.visible = false
		_world_editor_entered = true
		_new_dialog.visible = true
	)
	vbox.add_child(new_world_btn)

	var talent_btn := Button.new()
	talent_btn.text = "Talent Tree"
	talent_btn.custom_minimum_size = Vector2(0, 40)
	talent_btn.pressed.connect(_open_talent_tree)
	vbox.add_child(talent_btn)

	return panel


func _open_talent_tree() -> void:
	_mode_select.visible = false
	if _talent_tree_view == null:
		_talent_tree_view = load("res://world_editor/talent_tree_view.gd").new()
		add_child(_talent_tree_view)
		_talent_tree_view.closed.connect(func():
			_mode_select.visible = true
		)
		var path := ProjectSettings.globalize_path("res://").path_join("../stone_gaze/build/talents.json")
		_talent_tree_view.open(path)
	else:
		_talent_tree_view.visible = true


func _load_world(path: String) -> void:
	for child in _terrain.get_children():
		child.queue_free()
	_world_path = path
	_wd = EditorWorldData.new()
	if _wd.load(_world_path):
		_wd.load_cells(EditorWorldData.cells_path_for(_world_path))
		_spawn_world()
		_build_grid()
		_notify_world_loaded()
		_frame_world()
		_set_status("Loaded %s (%dx%d chunks) — %d spawner(s), %d entities" % [_world_path.get_file(), _wd.chunks_x, _wd.chunks_z, _spawn_tool.spawns.size(), _entity_tool.entities.size()])
	else:
		_wd = null
		_set_status("ERROR loading " + _world_path)


# Drops the camera above the center of the world just loaded — without this
# it stays wherever it was before, often nowhere near the world.
func _frame_world() -> void:
	if _wd == null: return
	var span_x: float = _wd.chunks_x * _wd.chunk_cells * _wd.cell_size
	var span_z: float = _wd.chunks_z * _wd.chunk_cells * _wd.cell_size
	var center_x := _wd.world_ox + span_x * 0.5
	var center_z := _wd.world_oz + span_z * 0.5
	var ground_y := _wd._get_height_at(center_x, center_z)
	if is_nan(ground_y): ground_y = 0.0
	# how far back/up the camera sits scales with how much ground was loaded,
	# so a single chunk fills the view and a big range still fits on screen
	var back := clampf(maxf(span_x, span_z) * 0.9, 12.0, 220.0)
	_cam_yaw   = 0.0
	_cam_pitch = -0.5
	_cam_pos   = Vector3(center_x, ground_y + back * 0.55, center_z + back)


func _build_import_dialog(ui: CanvasLayer) -> Panel:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(300, 340)
	panel.visible = false
	ui.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Import World Fragment"
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	var labels   := ["Offset X", "Offset Z"]
	var defaults := ["0", "0"]
	_import_fields = []
	for i in labels.size():
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = labels[i]
		lbl.custom_minimum_size = Vector2(90, 0)
		var ed := LineEdit.new()
		ed.text = defaults[i]
		ed.custom_minimum_size = Vector2(100, 0)
		row.add_child(lbl); row.add_child(ed)
		vbox.add_child(row)
		_import_fields.append(ed)

	vbox.add_child(HSeparator.new())
	var layers_label := Label.new()
	layers_label.text = "Layers"
	vbox.add_child(layers_label)

	_import_layer_checks = {}
	var layer_labels := [
		["terrain", "Terrain"], ["objects", "Static Objects"],
		["walls", "Walls"], ["water", "Water"], ["props", "Props"],
	]
	for pair in layer_labels:
		var cb := CheckBox.new()
		cb.text = pair[1]
		cb.button_pressed = true
		vbox.add_child(cb)
		_import_layer_checks[pair[0]] = cb

	var pick_btn := Button.new()
	pick_btn.text = "Pick Chunk in Viewport"
	pick_btn.pressed.connect(_start_import_picking)
	vbox.add_child(pick_btn)

	vbox.add_child(HSeparator.new())
	var btn := Button.new()
	btn.text = "Import"
	btn.pressed.connect(_confirm_import_fragment)
	vbox.add_child(btn)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func(): panel.visible = false)
	vbox.add_child(cancel)

	_center_panel(panel)
	return panel


func _confirm_import_fragment() -> void:
	_import_dialog.visible = false
	var offset_x := float((_import_fields[0] as LineEdit).text)
	var offset_z := float((_import_fields[1] as LineEdit).text)
	_do_import(offset_x, offset_z)


func _start_import_picking() -> void:
	if _wd == null:
		_set_status("Import failed: no world is currently open")
		return
	_import_dialog.visible = false
	_import_picking = true
	_set_status("Click a chunk to center the fragment there — Esc to cancel")


func _cancel_import_picking() -> void:
	_import_picking = false
	_import_dialog.visible = true
	_set_status("Import pick cancelled")


# Anchors the fragment's middle chunk on whichever destination chunk was
# clicked, so the rest of the fragment's footprint extends symmetrically
# around it rather than starting from its own (sx=0, sz=0) corner there.
func _import_pick_chunk(hit_collider: Object) -> void:
	_import_picking = false
	if hit_collider == null or not hit_collider.has_meta("chunk_index"):
		_set_status("Pick failed: no chunk under cursor")
		_import_dialog.visible = true
		return
	var frag := _pending_import_frag
	var chunk_span := frag.chunk_cells * frag.cell_size
	var i: int = hit_collider.get_meta("chunk_index")
	var cx: int = i % _wd.chunks_x
	var cz: int = i / _wd.chunks_x
	var target_gcx := _wd.origin_cx + cx
	var target_gcz := _wd.origin_cz + cz
	var sx_center := frag.chunks_x / 2
	var sz_center := frag.chunks_z / 2
	var chunk_off_x := target_gcx - frag.origin_cx - sx_center
	var chunk_off_z := target_gcz - frag.origin_cz - sz_center
	_do_import(chunk_off_x * chunk_span, chunk_off_z * chunk_span)


func _do_import(offset_x: float, offset_z: float) -> void:
	if _wd == null:
		_set_status("Import failed: no world is currently open")
		return
	var layers := {}
	for key in _import_layer_checks.keys():
		layers[key] = (_import_layer_checks[key] as CheckBox).button_pressed

	var frag := _pending_import_frag
	if frag == null:
		_set_status("ERROR: no fragment loaded")
		return

	var result   := _wd.import_from(frag, offset_x, offset_z, layers)
	var imported := result.imported as Dictionary
	var warnings := result.warnings as Array

	for child in _terrain.get_children():
		child.queue_free()
	_spawn_world()
	_history_clear()  # import rewrote this world in place — old steps no longer apply
	_build_grid()
	for t in _tools():
		t.on_world_changed()

	var summary := "Imported %s: %d chunks, %d objects, %d walls, %d water, %d props" % [
		_pending_import_path.get_file(), imported.terrain as int, imported.objects as int,
		imported.walls as int, imported.water as int, imported.props as int,
	]
	if not warnings.is_empty():
		summary += " (%d warning%s — see console)" % [warnings.size(), "" if warnings.size() == 1 else "s"]
		for w in warnings:
			push_warning("Import: " + (w as String))
	_set_status(summary)


# True while a text field (LineEdit, TextEdit, or a SpinBox's inner LineEdit)
# has keyboard focus. Keys typed there belong to the field, so everything
# that polls the keyboard directly (camera WASD/Space/Shift, terrain
# E/Q/F/X/G/N, Tab, the prop tool's held Delete) must stand down.
func _typing() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit


func _input(event: InputEvent) -> void:
	# Any release may end an edit (click, drag, held key, field edit) — let
	# _process commit snapshot-diff undo steps once nothing is held.
	if (event is InputEventMouseButton or event is InputEventKey) and not event.pressed:
		_undo_check = true
	if event is InputEventKey and event.pressed and not event.echo and _dialog_key(event):
		get_viewport().set_input_as_handled()
		return
	# Esc while typing just leaves the field — it must not also open the menu
	# or cancel a tool action.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE and _typing():
		get_viewport().gui_release_focus()
		get_viewport().set_input_as_handled()
		return
	# Intercept Tab before Godot's GUI focus navigation (ui_focus_next/prev) can
	# consume it, otherwise clicking a focusable control in a side panel steals
	# Tab for focus-cycling instead of toggling terrain/place mode. While typing,
	# Tab is left to the field.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB and not _any_dialog_open() and not _typing():
		_mode = "place" if _mode == "terrain" else "terrain"
		_menu_open = false
		_side_visible = true
		_set_status("Mode: " + _mode)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if _import_picking and event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var space  := get_world_3d().direct_space_state
		var origin := _cam.project_ray_origin(event.position)
		var dir    := _cam.project_ray_normal(event.position)
		var query  := PhysicsRayQueryParameters3D.create(origin, origin + dir * 2000.0)
		var result := space.intersect_ray(query)
		_import_pick_chunk(result.get("collider"))
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		if not event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			return
		# A click in the 3D view hands the keyboard back from any panel field,
		# otherwise the shortcuts stay dead until the field is clicked away.
		if event.pressed and _typing():
			get_viewport().gui_release_focus()
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				_rmb = event.pressed
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _rmb else Input.MOUSE_MODE_VISIBLE
			MOUSE_BUTTON_LEFT:
				_lmb = event.pressed
				if _mode == "place" and _wd != null and not _rmb and not _any_dialog_open():
					_active_tool().on_lmb(event.pressed, event)
				elif _mode == "terrain" and _wd != null and event.pressed and not _rmb and not _any_dialog_open():
					_select_vertices(event.position, event.ctrl_pressed, true)
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				var dir := 1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1
				if _mode == "place":
					_active_tool().on_scroll(dir)
				elif dir > 0:
					_brush_r = clampf(_brush_r + (0.1 if _brush_r < 0.95 else 0.5), 0.1, 30.0)
					_set_status("Brush radius: %.1f" % _brush_r)
				else:
					_brush_r = clampf(_brush_r - (0.1 if _brush_r < 1.05 else 0.5), 0.1, 30.0)
					_set_status("Brush radius: %.1f" % _brush_r)

	if event is InputEventMouseMotion and _rmb:
		_cam_yaw   -= event.relative.x * 0.003
		_cam_pitch  = clampf(_cam_pitch - event.relative.y * 0.003, -1.5, 0.2)

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			var cancelled := _active_tool().cancel() if _mode == "place" else ""
			if _mode == "terrain" and not _sel_verts.is_empty():
				_clear_vertex_selection()
				cancelled = "Vertex selection cleared"
			if _import_picking:
				_cancel_import_picking()
			elif cancelled != "":
				_set_status(cancelled)
			else:
				_side_visible = not _side_visible
			get_viewport().set_input_as_handled()
		if event.keycode == KEY_F1:
			_toggle_help()
			get_viewport().set_input_as_handled()
		if event.keycode == KEY_N and event.ctrl_pressed:
			_new_dialog.visible = true
			get_viewport().set_input_as_handled()
		if event.keycode == KEY_S and event.ctrl_pressed and event.shift_pressed:
			_save_dialog.popup_centered_ratio(0.4)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_S and event.ctrl_pressed:
			_save_or_prompt()
			get_viewport().set_input_as_handled()
		if event.keycode == KEY_Z and event.ctrl_pressed:
			_undo_redo(event.shift_pressed)
			get_viewport().set_input_as_handled()
		if event.keycode == KEY_Y and event.ctrl_pressed:
			_undo_redo(true)
			get_viewport().set_input_as_handled()
		if event.keycode == KEY_O and event.ctrl_pressed:
			_open_dialog()
			get_viewport().set_input_as_handled()
		if _mode == "place":
			# Number keys pick a place mode; the status line's hint then shows
			# that tool's current settings.
			var pick: Array = []
			for row in _place_picks():
				if (row[0] as Array).has(event.keycode): pick = row
			if not pick.is_empty():
				_place_type = pick[1]
				_menu_open = false
				_set_status(pick[2])
			elif event.keycode == KEY_DELETE and _wd != null:
				_active_tool().on_delete(event, _raycast_or_plane(get_viewport().get_mouse_position()))
			elif _wd != null and _active_tool().on_key(event):
				get_viewport().set_input_as_handled()
		if event.keycode == KEY_C and _mode == "terrain" and _wd != null:
			var hit := _raycast_or_plane(get_viewport().get_mouse_position())
			_terrain_touch(hit.x, hit.z, 0.0)
			if EditorWorldData.is_cave_type(_wd.get_chunk_type(hit.x, hit.z)):
				_wd.revert_cave_chunk(hit.x, hit.z)
				_layer = "h1"
				_clear_vertex_selection()
				_set_status("Chunk reverted to biome (h2/h3 cleared)")
			else:
				_wd.make_cave_chunk(hit.x, hit.z)
				_set_status("Chunk promoted to cave (P/H to edit h3)")
			_terrain_stroke_end()
		if event.keycode == KEY_O and not event.ctrl_pressed and _mode == "terrain" and _wd != null:
			var hit := _raycast_or_plane(get_viewport().get_mouse_position())
			_terrain_touch(hit.x, hit.z, 0.0)
			if _wd.toggle_ocean_chunk(hit.x, hit.z, _water_height):
				_set_status("Chunk is now ocean (water sheet at y=%.2f)" % _water_height)
			else:
				_set_status("Chunk is no longer ocean (water sheet removed)")
			_terrain_stroke_end()
			_rebuild_water()
		if (event.keycode == KEY_P or event.keycode == KEY_H) and _mode == "terrain":
			match _layer:
				"h1": _layer = "h2"
				"h2": _layer = "h3"
				_:    _layer = "h1"
			_clear_vertex_selection()
			_set_status("Layer: " + _layer)


func _any_dialog_open() -> bool:
	return (_help_panel  != null and _help_panel.visible)  or \
		   (_new_dialog   != null and _new_dialog.visible)   or \
		   (_import_dialog != null and _import_dialog.visible) or \
		   (_mode_select  != null and _mode_select.visible)  or \
		   (_talent_tree_view != null and _talent_tree_view.visible)


func _save_or_prompt() -> void:
	if _world_path.is_empty():
		_save_dialog.popup_centered_ratio(0.4)
	else:
		_save()

func _process(delta: float) -> void:
	if _wd != null:
		_wd.update_streaming(_cam_pos, TERRAIN_STREAM_RADIUS, 1)
		get_tree().call_group(AoiSet.GROUP, "update_center", _cam_pos)
	if _side_panel != null:
		_sync_side_panel()
	var dialogs_open := _any_dialog_open()
	var typing := _typing()
	if not dialogs_open and not typing:
		_move_camera(delta)
	_apply_camera()
	var mouse := get_viewport().get_mouse_position()
	if _wd != null:
		_update_brush(mouse)
		var tool: PlaceTool = _active_tool() if _mode == "place" else null
		if tool != _current_tool:
			if _current_tool: _current_tool.deactivate()
			_current_tool = tool
		if tool:
			tool.update(delta, mouse, _raycast_or_plane(mouse))
		if _undo_check and not _lmb and not typing and not Input.is_key_pressed(KEY_DELETE) \
				and not (tool != null and tool.is_dragging()):
			_undo_check = false
			_undo_commit_all()
		if _mode == "terrain" and not dialogs_open and not typing:
			var fine := Input.is_key_pressed(KEY_CTRL)
			# LMB selects vertices (_select_vertices); painting is on the keys.
			# Ctrl+LMB drag keeps adding whatever the brush passes over.
			if not Input.is_key_pressed(KEY_N): _snap_key_done = false
			if _lmb and not _rmb and Input.is_key_pressed(KEY_CTRL):
				_select_vertices(mouse, true)
			# With a vertex selection, E/Q move only the selected vertices
			# (all by the same amount); otherwise they paint under the brush.
			# The other brushes (F/X/G/N) stay brush-driven but only touch
			# selected vertices — see EditorWorldData.vertex_mask.
			var eq := 1.0 if Input.is_key_pressed(KEY_E) else (-1.0 if Input.is_key_pressed(KEY_Q) else 0.0)
			if eq != 0.0 and not _sel_verts.is_empty():
				_raise_selection(eq * _brush_str * (0.05 if fine else 1.0) * delta)
			elif eq > 0.0:
				_edit(mouse, delta, true, fine)
			elif eq < 0.0:
				_edit(mouse, delta, false, fine)
			if Input.is_key_pressed(KEY_F):
				_smooth(mouse, delta)
			if Input.is_key_pressed(KEY_X):
				_hole(mouse)
			if Input.is_key_pressed(KEY_G):
				_fill(mouse, _layer)
			if Input.is_key_pressed(KEY_N) and Input.is_key_pressed(KEY_ALT):
				_glue(_raycast_or_plane(mouse), not fine)
			elif Input.is_key_pressed(KEY_N) and not _snap_key_done:
				_snap_key_done = true
				_snap()
		# The stroke ends once no terrain edit key is held (or typing, a
		# dialog or the other mode took over).
		var stroke_keys := _mode == "terrain" and not dialogs_open and not typing and (
			Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_F)
			or Input.is_key_pressed(KEY_X) or Input.is_key_pressed(KEY_G) or Input.is_key_pressed(KEY_N))
		if not stroke_keys:
			_terrain_stroke_end()
		_update_selection_markers()


# The terrain panel follows the real state, however it changed: scroll resizes
# the brush, P/H cycles the layer, C on a cave chunk drops back to h1.
func _sync_terrain_panel() -> void:
	if not _radius_edit.has_focus():
		var r := "%.2f" % _brush_r
		if _radius_edit.text != r and not (_radius_edit.text.is_valid_float() and is_equal_approx(_radius_edit.text.to_float(), _brush_r)):
			_radius_edit.text = r
	for lname in _layer_btns:
		var b := _layer_btns[lname] as Button
		if b.button_pressed != (lname == _layer): b.set_pressed_no_signal(lname == _layer)


# LMB picks the vertex nearest the cursor (replacing the selection, or
# clearing it when that vertex is already selected); add =
# Ctrl held, which instead adds every vertex the brush covers.
func _select_vertices(mouse_pos: Vector2, add: bool, press := false) -> void:
	var hit := _raycast_or_plane(mouse_pos)
	var before := _sel_verts.size()
	if add and press:
		# Ctrl+click on a selected (red) vertex starts a removing stroke.
		var pv := _wd.nearest_vertex(hit.x, hit.z, _layer)
		_sel_removing = _sel_verts.has(Vector2(pv.x, pv.z))
	if add and _sel_removing:
		# Removing stroke: drop the vertex nearest the cursor.
		var rv := _wd.nearest_vertex(hit.x, hit.z, _layer)
		if not _sel_verts.erase(Vector2(rv.x, rv.z)):
			return
	elif add:
		var t := _brush_target(hit)
		for p in _wd.brush_vertex_positions(t.x, t.z, t.y, _layer):
			_sel_verts[Vector2(p.x, p.z)] = true
		if _sel_verts.size() == before:
			return
	else:
		var v := _wd.nearest_vertex(hit.x, hit.z, _layer)
		# Clicking a vertex that's already selected (alone or in a group)
		# drops the whole selection.
		if _sel_verts.has(Vector2(v.x, v.z)):
			_clear_vertex_selection()
			_set_status("Vertex selection cleared")
			return
		_sel_verts.clear()
		if not is_nan(v.y):
			_sel_verts[Vector2(v.x, v.z)] = true
	_on_selection_changed()


func _clear_vertex_selection() -> void:
	if _sel_verts.is_empty(): return
	_sel_verts.clear()
	_on_selection_changed()


# Refreshes the panel: the count, and the Height field prefilled with the
# selection's height (the first vertex's, when they differ).
func _on_selection_changed() -> void:
	# The brushes only touch the selected vertices while there is a selection.
	if _wd != null:
		_wd.vertex_mask.clear()
		for k in _sel_verts:
			_wd.vertex_mask[_wd.vertex_key((k as Vector2).x, (k as Vector2).y)] = true
	if _sel_label == null: return
	var n := _sel_verts.size()
	_sel_height.editable = n > 0
	if n == 0:
		_sel_label.text = "No vertex selected"
		_sel_height.text = ""
		return
	var first: Vector2 = _sel_verts.keys()[0]
	var h := _wd.nearest_vertex(first.x, first.y, _layer).y
	_sel_label.text = "%d vertex selected (%s)" % [n, _layer] if n == 1 else "%d vertices selected (%s)" % [n, _layer]
	_sel_height.text = "%.2f" % h if not is_nan(h) else ""
	_set_status("Selected %d vertex(es) at x=%.1f z=%.1f" % [n, first.x, first.y] if n == 1 else "Selected %d vertices" % n)


func _apply_selection_height(text: String) -> void:
	if _sel_verts.is_empty() or not text.strip_edges().is_valid_float():
		_set_status("Height must be a number")
		return
	var value := text.strip_edges().to_float()
	var pts: Array = []
	for k in _sel_verts:
		pts.append(Vector3((k as Vector2).x, 0.0, (k as Vector2).y))
	for p in pts: _terrain_touch((p as Vector3).x, (p as Vector3).z, 0.0)
	_wd.set_vertices_height(pts, value, _layer)
	_terrain_stroke_end()
	_sel_height.release_focus()
	_set_status("Set %d vertex(es) to %.2f" % [pts.size(), value])


func _raise_selection(amount: float) -> void:
	var pts: Array = []
	for k in _sel_verts:
		pts.append(Vector3((k as Vector2).x, 0.0, (k as Vector2).y))
	# The selection can't change mid-stroke, so its chunks are backed up once.
	if _terrain_stroke == null or not _terrain_stroke.has("sel"):
		for p in pts: _terrain_touch((p as Vector3).x, (p as Vector3).z, 0.0)
		_terrain_stroke["sel"] = true
	_wd.raise_vertices(pts, amount, _layer)
	if not _sel_height.has_focus():
		var first: Vector2 = _sel_verts.keys()[0]
		var h := _wd.nearest_vertex(first.x, first.y, _layer).y
		_sel_height.text = "%.2f" % h if not is_nan(h) else ""


# Red markers on the selected vertices, at their current heights (so they
# follow E/Q edits too). Hidden outside terrain mode.
func _update_selection_markers() -> void:
	var mm := _sel_markers.multimesh
	if _mode != "terrain" or _sel_verts.is_empty():
		if mm.instance_count != 0: mm.instance_count = 0
		return
	var sp := mm.mesh as SphereMesh
	var vr := minf(_wd.cell_size * 0.08, 0.25)
	if not is_equal_approx(sp.radius, vr):
		sp.radius = vr
		sp.height = vr * 2.0
	# Resizing reallocates the buffer — only when the count really changes.
	if mm.instance_count != _sel_verts.size():
		mm.instance_count = _sel_verts.size()
	var j := 0
	for k in _sel_verts:
		var v := _wd.nearest_vertex((k as Vector2).x, (k as Vector2).y, _layer)
		if is_nan(v.y): v.y = -10000.0  # holed since it was picked — park the marker out of sight
		mm.set_instance_transform(j, Transform3D(Basis.IDENTITY, v))
		j += 1


# N: snap the current layer onto the one it pairs with (h1 <-> h2, h3 -> the
# first solid layer above). With a vertex selection it snaps every selected
# vertex, wherever the cursor is (like E/Q); otherwise the vertices under the
# brush. Only cave chunks have layers to snap between.
func _snap() -> void:
	if _sel_verts.is_empty():
		var t := _brush_target(_raycast_or_plane(get_viewport().get_mouse_position()))
		_terrain_touch(t.x, t.z, t.y)
		_wd.snap_brush(t.x, t.z, t.y, _layer)
		return
	var pts: Array = []
	for k in _sel_verts:
		pts.append(Vector3((k as Vector2).x, 0.0, (k as Vector2).y))
	for p in pts: _terrain_touch((p as Vector3).x, (p as Vector3).z, 0.0)
	var n := _wd.snap_vertices(pts, _layer)
	_terrain_stroke_end()
	if n == 0:
		_set_status("Snap: nothing to snap (%s) — only cave chunks have layers to snap between" % _layer)
		return
	_set_status("Snapped %d of %d selected vertices (%s → %s)" % [n, pts.size(), _layer,
		{"h1": "h2", "h2": "h1", "h3": "h2/h1"}[_layer]])
	if not _sel_height.has_focus():
		var first: Vector2 = _sel_verts.keys()[0]
		var h := _wd.nearest_vertex(first.x, first.y, _layer).y
		_sel_height.text = "%.2f" % h if not is_nan(h) else ""


# Alt+N: glue the h1/h2 pairs under the brush so they move together
# (cave entrances); + Ctrl unglues. In memory only — gone on restart.
func _glue(hit: Vector3, on: bool) -> void:
	var anchor := _layer if _layer in ["h1", "h2"] else "h1"
	var t := _brush_target(hit)
	_terrain_touch(t.x, t.z, maxf(t.y, _wd.cell_size * 0.75))
	var n := _wd.glue_brush(t.x, t.z, t.y, anchor, on)
	if n > 0:
		_set_status("%s %d h1/h2 pair(s)" % ["Glued" if on else "Unglued", n])


func _move_camera(delta: float) -> void:
	# Ctrl is a shortcut modifier (Ctrl+S, Ctrl+Shift+S, Ctrl+D…), never movement.
	if Input.is_key_pressed(KEY_CTRL): return
	var speed      := 20.0 * delta
	var cam_basis  := _cam.global_transform.basis
	if Input.is_key_pressed(KEY_W):     _cam_pos -= cam_basis.z * speed
	if Input.is_key_pressed(KEY_S):     _cam_pos += cam_basis.z * speed
	if Input.is_key_pressed(KEY_A):     _cam_pos -= cam_basis.x * speed
	if Input.is_key_pressed(KEY_D):     _cam_pos += cam_basis.x * speed
	if Input.is_key_pressed(KEY_SPACE): _cam_pos.y += speed
	if Input.is_key_pressed(KEY_SHIFT): _cam_pos.y -= speed


func _apply_camera() -> void:
	_cam.position = _cam_pos
	_cam.rotation = Vector3(_cam_pitch, _cam_yaw, 0.0)


func _edit(mouse_pos: Vector2, delta: float, raise: bool, fine: bool = false) -> void:
	var space  := get_world_3d().direct_space_state
	var origin := _cam.project_ray_origin(mouse_pos)
	var target := origin + _cam.project_ray_normal(mouse_pos) * 2000.0
	var query  := PhysicsRayQueryParameters3D.create(origin, target)
	var result := space.intersect_ray(query)
	if result.is_empty(): return

	var hit := result.position as Vector3
	var str  := _brush_str * (0.05 if fine else 1.0) * delta * (1.0 if raise else -1.0)
	var t := _brush_target(hit)
	_terrain_touch(t.x, t.z, t.y)
	_wd.raise_brush(t.x, t.z, t.y, str, _layer)


func _raycast_or_plane(mouse_pos: Vector2) -> Vector3:
	var space  := get_world_3d().direct_space_state
	var origin := _cam.project_ray_origin(mouse_pos)
	var dir    := _cam.project_ray_normal(mouse_pos)
	var query  := PhysicsRayQueryParameters3D.create(origin, origin + dir * 2000.0)
	var result := space.intersect_ray(query)
	if not result.is_empty(): return result.position
	if absf(dir.y) < 0.001: return Vector3.ZERO
	var t := -origin.y / dir.y
	return origin + dir * maxf(t, 0.0)


func _fill(mouse_pos: Vector2, layer: String = "h1") -> void:
	var hit := _raycast_or_plane(mouse_pos)
	var t := _brush_target(hit)
	_terrain_touch(t.x, t.z, t.y)
	_wd.fill_brush(t.x, t.z, t.y, layer)


func _hole(mouse_pos: Vector2) -> void:
	var space  := get_world_3d().direct_space_state
	var origin := _cam.project_ray_origin(mouse_pos)
	var target := origin + _cam.project_ray_normal(mouse_pos) * 2000.0
	var query  := PhysicsRayQueryParameters3D.create(origin, target)
	var result := space.intersect_ray(query)
	if result.is_empty(): return
	var t := _brush_target(result.position as Vector3)
	_terrain_touch(t.x, t.z, t.y)
	_wd.hole_brush(t.x, t.z, t.y, _layer)


# Where the terrain brush actually lands, as (x, radius, z). A radius under
# half a cell snaps to the nearest vertex — single-vertex mode. The hole tool
# also has Ctrl = nearest vertex and Alt = the cell's 4 corners (the mesh drops
# every quad touching a removed vertex, so those open 2x2 and 3x3 cells), and
# Alt+N glue never goes below the half-diagonal so it always catches a vertex.
func _brush_target(hit: Vector3) -> Vector3:
	var cs := _wd.cell_size
	var vx := _wd.world_ox + roundf((hit.x - _wd.world_ox) / cs) * cs
	var vz := _wd.world_oz + roundf((hit.z - _wd.world_oz) / cs) * cs
	var holing := Input.is_key_pressed(KEY_X)
	if holing and Input.is_key_pressed(KEY_CTRL):
		return Vector3(vx, cs * 0.25, vz)
	if holing and Input.is_key_pressed(KEY_ALT):
		var mx := _wd.world_ox + (floorf((hit.x - _wd.world_ox) / cs) + 0.5) * cs
		var mz := _wd.world_oz + (floorf((hit.z - _wd.world_oz) / cs) + 0.5) * cs
		return Vector3(mx, cs * 0.75, mz)
	var r := _brush_r
	if r < cs * 0.5:
		return Vector3(vx, r, vz)
	if Input.is_key_pressed(KEY_N) and Input.is_key_pressed(KEY_ALT):
		r = maxf(r, cs * 0.75)
	return Vector3(hit.x, r, hit.z)


func _smooth(mouse_pos: Vector2, delta: float) -> void:
	var space  := get_world_3d().direct_space_state
	var origin := _cam.project_ray_origin(mouse_pos)
	var target := origin + _cam.project_ray_normal(mouse_pos) * 2000.0
	var query  := PhysicsRayQueryParameters3D.create(origin, target)
	var result := space.intersect_ray(query)
	if result.is_empty(): return
	var t := _brush_target(result.position as Vector3)
	_terrain_touch(t.x, t.z, t.y)
	_wd.smooth_brush(t.x, t.z, t.y, delta * 15.0, _layer)


func _build_grid() -> void:
	var world_w := _wd.chunks_x * _wd.chunk_cells * _wd.cell_size
	var world_d := _wd.chunks_z * _wd.chunk_cells * _wd.cell_size
	var plane   := PlaneMesh.new()
	plane.size  = Vector2(world_w, world_d)

	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;
uniform float cell_size;
uniform float chunk_size;
varying vec3 world_pos;
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 p = world_pos.xz;
	vec2 cell_f  = abs(fract(p / cell_size  - 0.5) - 0.5) / fwidth(p / cell_size);
	vec2 chunk_f = abs(fract(p / chunk_size - 0.5) - 0.5) / fwidth(p / chunk_size);
	float cell_line  = 1.0 - clamp(min(cell_f.x,  cell_f.y),  0.0, 1.0);
	float chunk_line = 1.0 - clamp(min(chunk_f.x, chunk_f.y), 0.0, 1.0);
	float a = max(cell_line * 0.35, chunk_line * 0.85);
	if (a < 0.01) discard;
	ALBEDO = mix(vec3(0.55), vec3(1.0, 0.8, 0.2), chunk_line);
	ALPHA  = a;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("cell_size",  _wd.cell_size)
	mat.set_shader_parameter("chunk_size", float(_wd.chunk_cells) * _wd.cell_size)

	var mi := MeshInstance3D.new()
	mi.mesh              = plane
	mi.material_override = mat
	mi.position          = Vector3(
		_wd.world_ox + world_w * 0.5,
		0.05,
		_wd.world_oz + world_d * 0.5)
	_terrain.add_child(mi)


func _update_brush(mouse: Vector2) -> void:
	_brush_mesh.clear_surfaces()
	var hit    := _raycast_or_plane(mouse)
	# Place mode: the active tool's own radius, or no ring at all when its
	# preview already shows the footprint (see PlaceTool.brush_radius).
	var radius := _active_tool().brush_radius() if _mode == "place" else _brush_r
	_brush_mat.albedo_color = Color(0.2, 1.0, 0.3) if _mode == "place" else Color(1.0, 0.9, 0.1)
	if radius > 0.0:
		_brush_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _brush_mat)
		const SEGS := 48
		for i in range(SEGS + 1):
			var a  := float(i) / SEGS * TAU
			var px := hit.x + cos(a) * radius
			var pz := hit.z + sin(a) * radius
			var py := _wd._get_height_at(px, pz) + 0.15
			_brush_mesh.surface_add_vertex(Vector3(px, py, pz))
		_brush_mesh.surface_end()

	var mm := _brush_verts.multimesh
	if _mode != "terrain" or _any_dialog_open():
		mm.instance_count = 0
		return
	var t   := _brush_target(hit)
	var pts := _wd.brush_vertex_positions(t.x, t.z, t.y, _layer)
	var sp  := mm.mesh as SphereMesh
	var vr  := minf(_wd.cell_size * 0.06, 0.2)
	if not is_equal_approx(sp.radius, vr):
		sp.radius = vr
		sp.height = vr * 2.0
	mm.instance_count = pts.size()
	for j in range(pts.size()):
		mm.set_instance_transform(j, Transform3D(Basis.IDENTITY, pts[j]))


func _make_aoi(items: Callable, footprint: Callable, build: Callable) -> AoiSet:
	var aoi := AoiSet.new()
	add_child(aoi)
	aoi.setup(items, footprint, build)
	return aoi


# (Re)builds everything the world shows once _wd is new or was rewritten:
# the terrain's streaming state plus the walls/water/objects sets.
func _spawn_world() -> void:
	_wd.spawn_into(_terrain)
	_rebuild_walls()
	_rebuild_water()
	_rebuild_objects()
	_rebuild_pillars()


func _rebuild_water() -> void:
	_water_aoi.invalidate()

func _rebuild_walls() -> void:
	_walls_aoi.invalidate()

func _rebuild_pillars() -> void:
	_pillars_aoi.invalidate()


# ── Object type table (data-driven — see the `object_types` file at the repo
# root, which is also read by the C++ server; add a new tree/rock/etc there
# and it shows up in the editor with zero code changes) ────────────────────

func _load_object_types() -> void:
	_object_type_defs.clear()
	var path := ProjectSettings.globalize_path("res://").path_join("../stone_gaze/object_types.json")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[object_types] failed to open " + path)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Array):
		push_error("[object_types] failed to parse " + path)
		return
	for entry in parsed:
		var d := entry as Dictionary
		if not d.has("id"): continue
		var id := int(d["id"])
		_object_type_defs[id] = {
			"name":            d.get("name", str(id)),
			"mesh":            d.get("mesh", ""),
			"collision_ratio": float(d.get("collision_ratio", 1.0)),
			"height_ratio":    float(d.get("height_ratio", 1.0)),
			"scale_ratio":     float(d.get("scale_ratio", 1.0)),
			"resource":        null,
		}
	print("[object_types] loaded %d type(s) from %s" % [_object_type_defs.size(), path])


# ── Wall type table (data-driven, mirrors object_types above) — id -> texture,
# so gaze_client can resolve the right material for each OBB wall without a
# hardcoded id -> texture table of its own. ─────────────────────────────────
func _load_wall_types() -> void:
	_wall_type_defs.clear()
	var path := "res://wall_types.json"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[wall_types] failed to open " + path)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Array):
		push_error("[wall_types] failed to parse " + path)
		return
	for entry in parsed:
		var d := entry as Dictionary
		if not d.has("id"): continue
		var id := int(d["id"])
		_wall_type_defs[id] = {
			"name":    d.get("name", str(id)),
			"material": d.get("material", ""),
			"mesh":     d.get("mesh", ""),
		}
	print("[wall_types] loaded %d type(s) from %s" % [_wall_type_defs.size(), path])
	_build_wall_looks()


# How each wall type is drawn (EditorWorldData.wall_looks): the type's
# material (a .tres on the client's res://ps2/ps2_world.gdshader), plus the model
# for mesh types (the ladder).
func _build_wall_looks() -> void:
	var looks := {}
	for id in _wall_type_defs:
		var def := _wall_type_defs[id] as Dictionary
		var look := {}
		var mat_path := def["material"] as String
		if not mat_path.is_empty():
			var mat := load(mat_path) as Material
			if mat == null:
				push_error("[wall_types] type %d material failed to load: %s" % [id, mat_path])
			else:
				look["mat"] = mat
		var mesh_path := def["mesh"] as String
		if not mesh_path.is_empty():
			var scene := load(mesh_path) as PackedScene
			if scene == null:
				push_error("[wall_types] type %d mesh failed to load: %s" % [id, mesh_path])
			else:
				var probe := scene.instantiate() as Node3D
				look["prop"] = { "scene": scene, "aabb": EditorWorldData.node_aabb(probe, Transform3D.IDENTITY) }
				probe.free()
		looks[id] = look
	EditorWorldData.wall_looks = looks


func _object_type_resource(id: int) -> Resource:
	if not _object_type_defs.has(id): return null
	var def := _object_type_defs[id] as Dictionary
	if def["resource"] == null:
		var mesh_path := def["mesh"] as String
		if mesh_path.is_empty(): return null
		def["resource"] = load(mesh_path)
		_object_type_defs[id] = def
	return def["resource"] as Resource


# Meshes (.glb) import as a PackedScene; some assets (e.g. frozenstarlight.obj)
# import as a bare Mesh instead — handle both without per-type branching.
func _instantiate_object_type(id: int) -> Node3D:
	var res := _object_type_resource(id)
	if res == null: return null
	if res is PackedScene:
		return (res as PackedScene).instantiate() as Node3D
	if res is Mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = res as Mesh
		return mi
	return null


func _object_type_name(id: int) -> String:
	if _object_type_defs.has(id):
		return (_object_type_defs[id] as Dictionary).get("name", "?") as String
	return "Unknown(%d)" % id


func _disable_collision(node: Node3D) -> void:
	for body in node.find_children("*", "CollisionObject3D", true, false):
		(body as CollisionObject3D).collision_layer = 0
		(body as CollisionObject3D).collision_mask  = 0

func _rebuild_objects() -> void:
	_objects_aoi.invalidate()


func _build_object(d: Dictionary, _i: int, holder: Node3D) -> void:
	var id   := d.type as int
	var node := _instantiate_object_type(id)
	if node == null: return
	var scale_ratio     := (_object_type_defs[id] as Dictionary).get("scale_ratio", 1.0) as float
	var collision_ratio := (_object_type_defs[id] as Dictionary).get("collision_ratio", 1.0) as float
	var wy := _wd._get_height_at(d.x, d.z)
	node.position = Vector3(d.x, wy, d.z)
	# Same as gaze_client: the model scales with its collider
	node.scale    = node.scale * ((d.radius as float) * collision_ratio / scale_ratio)
	_disable_collision(node)
	holder.add_child(node)

# ── Undo ─────────────────────────────────────────────────────────────────────

# Three ways a step gets recorded:
#  - walls / cells: the tool wraps each action (_with_history, or its own
#    stroke for cells) and records the state from before it.
#  - objects / props / biomes / spawns / entities: snapshot diff. After every
#    mouse/key release, once nothing is held or being typed, each such tool's
#    undo_snapshot() is compared with _undo_base; a change becomes one step.
#    Panel field edits are caught the same way, as one step per field.
#  - terrain: too big to copy whole, so a stroke backs up only the chunks it
#    is about to touch (_terrain_touch), the first time it reaches each one.

# Which feature Ctrl+Z applies to — the one currently being edited.
func _undo_feature() -> String:
	if _mode == "terrain": return "terrain"
	return _active_tool().undo_feature()

# The place tool whose undo works by snapshot diff for `feature`, or null.
func _diff_tool(feature: String) -> PlaceTool:
	for t in _tools():
		if (t as PlaceTool).undo_feature() == feature and (t as PlaceTool).undo_snapshot() != null:
			return t
	return null

# Full copy of a feature's current state (null = no undo for it). Terrain's
# is only the chunks (and ocean sheets) listed in `like`, a recorded step.
func _feature_snapshot(feature: String, like: Variant = null) -> Variant:
	if _wd == null: return null
	match feature:
		"walls": return { "walls": _wd._walls.duplicate(true), "pillars": _wd._pillars.duplicate(true) }  # the Walls page edits both
		"cells": return _wd.cells_snapshot()
		"terrain": return _terrain_capture(like) if like != null else null
	var t := _diff_tool(feature)
	return t.undo_snapshot() if t != null else null

func _feature_restore(feature: String, snapshot: Variant) -> void:
	match feature:
		"walls":
			_wd._walls   = ((snapshot as Dictionary)["walls"] as Array).duplicate(true)
			_wd._pillars = ((snapshot as Dictionary)["pillars"] as Array).duplicate(true)
			_wall_tool.on_walls_replaced()
			_rebuild_walls()
			_rebuild_pillars()
		"cells":
			_wd.cells_restore(snapshot)
		"terrain":
			_wd.terrain_restore((snapshot as Dictionary)["chunks"])
			_rebuild_water()
			if not _sel_verts.is_empty(): _on_selection_changed()
		_:
			var t := _diff_tool(feature)
			t.undo_restore(snapshot)
			_undo_base[feature] = snapshot

func _history_for(feature: String) -> UndoHistory:
	if _history_wd != _wd:
		_history_clear()
		_history_wd = _wd
	return _history[feature] as UndoHistory

# Forget every step and re-take the snapshot-diff bases from the current
# world. Call whenever the world is replaced or rewritten in place.
func _history_clear() -> void:
	for h in _history.values(): (h as UndoHistory).clear()
	_terrain_stroke = null
	_undo_base.clear()
	if _wd == null: return
	for t in _tools():
		var snap = (t as PlaceTool).undo_snapshot()
		if snap != null: _undo_base[(t as PlaceTool).undo_feature()] = snap

# Snapshot-diff features: record a step for each one that changed since its
# base. Cheap enough to run on every release: these lists are small next to
# terrain, and props (the largest) only copy plain dictionaries.
func _undo_commit_all() -> void:
	if _wd == null: return
	_history_for("objects")  # resets everything first if the world changed
	for t in _tools():
		var f := (t as PlaceTool).undo_feature()
		var now = (t as PlaceTool).undo_snapshot()
		if now == null: continue
		if not _undo_base.has(f):
			_undo_base[f] = now
		elif _undo_base[f] != now:
			_history_for(f).record(_undo_base[f])
			_undo_base[f] = now

# ── Terrain strokes ──────────────────────────────────────────────────────────
# A stroke runs from the first frame a terrain edit key (E/Q/F/X/G/N) is held
# until all are released, and becomes one undo step. One-shot edits (C, O,
# Height + Enter) are a stroke each. Before every brush application,
# _terrain_touch backs up the chunks within the brush plus two cells: edits
# never reach further (hole rims add one cell; glue and border stitching only
# reach neighbours along borders that are inside that range).

func _terrain_touch(x: float, z: float, r: float) -> void:
	if _wd == null: return
	if _terrain_stroke == null:
		_terrain_stroke = { "chunks": {} }
	var chunks: Dictionary = _terrain_stroke["chunks"]
	var span := _wd.chunk_cells * _wd.cell_size
	var m := r + _wd.cell_size * 2.0
	for i in range(_wd._chunks.size()):
		var o := _wd._chunk_origin(i)
		var nx := clampf(x, o.x, o.x + span)
		var nz := clampf(z, o.z, o.z + span)
		if (nx - x) * (nx - x) + (nz - z) * (nz - z) > m * m: continue
		var key := _wd._chunk_grid_key(i)
		if not chunks.has(key): chunks[key] = _wd.terrain_chunk_state(i)

func _terrain_stroke_end() -> void:
	if _terrain_stroke == null: return
	var before: Dictionary = _terrain_stroke
	_terrain_stroke = null
	if (before["chunks"] as Dictionary).is_empty(): return
	# var_to_bytes compares NaN holes exactly, which == on floats wouldn't
	if var_to_bytes(before["chunks"]) == var_to_bytes(_terrain_capture(before)["chunks"]): return
	_history_for("terrain").record({ "chunks": before["chunks"] })

# The current state of the chunks a recorded step covers, for its redo/undo.
func _terrain_capture(like: Dictionary) -> Dictionary:
	var chunks := {}
	var want: Dictionary = like["chunks"]
	for i in range(_wd._chunks.size()):
		var key := _wd._chunk_grid_key(i)
		if want.has(key): chunks[key] = _wd.terrain_chunk_state(i)
	return { "chunks": chunks }

# Runs one user action as a single undo step — recorded only if it changed
# something. Wrap at the action's entry point (mouse release, key press),
# never inside helpers, so one action is one step.
func _with_history(feature: String, action: Callable) -> void:
	var before = _feature_snapshot(feature)
	action.call()
	if before == null or before == _feature_snapshot(feature): return
	_history_for(feature).record(before)

func _undo_redo(redo: bool) -> void:
	if _active_tool().is_dragging(): return
	var feature := _undo_feature()
	if feature == "" or _wd == null:
		_set_status("Nothing to undo here")
		return
	_terrain_stroke_end()
	_undo_commit_all()  # an edit not yet committed would otherwise be lost
	var h := _history_for(feature)
	var next = h.peek_redo() if redo else h.peek_undo()
	if next == null:
		_set_status("Nothing to %s (%s)" % ["redo" if redo else "undo", feature])
		return
	var current = _feature_snapshot(feature, next)
	if current == null:
		_set_status("Undo isn't available for %s" % feature)
		return
	var snapshot = h.redo(current) if redo else h.undo(current)
	_feature_restore(feature, snapshot)
	_set_status("%s %s — %d undo / %d redo left" % ["Redo" if redo else "Undo", feature, h.undo_count(), h.redo_count()])

func _make_ghost_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color  = Color(0.4, 1.0, 0.4, 0.35)
	m.transparency  = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


# Menu page of the side panel: world file actions plus what's open.
func _build_menu_page(vbox: VBoxContainer) -> void:
	_world_info = Label.new()
	_world_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_world_info)
	vbox.add_child(HSeparator.new())
	var actions := [
		["New World  (Ctrl+N)",          func(): _new_dialog.visible = true],
		["Open World  (Ctrl+O)",         _open_dialog],
		["Import World Fragment…",       func(): _import_file_dialog.popup_centered_ratio(0.5)],
		["Save  (Ctrl+S)",               _save_or_prompt],
		["Save As  (Ctrl+Shift+S)",      func(): _save_dialog.popup_centered_ratio(0.4)],
		["Update World",                 _update_world],
		null,
		["Shortcuts  (F1)",              _toggle_help],
		["Hide Panel  (Esc)",            func(): _side_visible = false],
	]
	for act in actions:
		if act == null:
			vbox.add_child(HSeparator.new())
			continue
		var btn := Button.new()
		btn.text = act[0]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(act[1])
		vbox.add_child(btn)


func _update_world_info() -> void:
	if _world_info == null: return
	var t := "No world open"
	if _wd != null:
		var span_x: float = _wd.chunks_x * _wd.chunk_cells * _wd.cell_size
		var span_z: float = _wd.chunks_z * _wd.chunk_cells * _wd.cell_size
		t = "%s\n%dx%d chunks (%.0f x %.0f m), %d cells/chunk @ %.2f m" % [
			_world_path.get_file() if not _world_path.is_empty() else "(unsaved world)",
			_wd.chunks_x, _wd.chunks_z, span_x, span_z, _wd.chunk_cells, _wd.cell_size]
	if _world_info.text != t: _world_info.text = t


func _build_new_dialog(ui: CanvasLayer) -> Panel:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(300, 260)
	panel.visible = false
	ui.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "New World"
	vbox.add_child(title)

	var labels := ["Chunks X", "Chunks Z", "Cells/Chunk", "Cell Size", "Base Height"]
	var defaults := ["3", "3", "128", "0.5", "0.0"]
	_new_fields = []
	for i in labels.size():
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = labels[i]
		lbl.custom_minimum_size = Vector2(100, 0)
		var ed := LineEdit.new()
		ed.text = defaults[i]
		ed.custom_minimum_size = Vector2(120, 0)
		row.add_child(lbl)
		row.add_child(ed)
		vbox.add_child(row)
		_new_fields.append(ed)

	var btn := Button.new()
	btn.text = "Create"
	btn.pressed.connect(_create_new_world)
	vbox.add_child(btn)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func(): panel.visible = false)
	vbox.add_child(cancel)

	_center_panel(panel)
	return panel


func _create_new_world() -> void:
	var cx    := int((_new_fields[0] as LineEdit).text)
	var cz    := int((_new_fields[1] as LineEdit).text)
	var cells := int((_new_fields[2] as LineEdit).text)
	var csize := float((_new_fields[3] as LineEdit).text)
	var base  := float((_new_fields[4] as LineEdit).text)
	cx    = clampi(cx,    1, 32)
	cz    = clampi(cz,    1, 32)
	cells = maxi(cells, 4)
	csize = clampf(csize, 0.5, 16.0)

	for child in _terrain.get_children():
		child.queue_free()

	_wd = EditorWorldData.new()
	_wd.create_new(cx, cz, cells, csize, base)
	_spawn_world()
	_world_path = ""
	_build_grid()
	_notify_world_loaded()
	_new_dialog.visible = false
	_set_status("New world %dx%d — Ctrl+Shift+S to save" % [cx, cz])


func _save() -> void:
	if _wd == null or _world_path.is_empty(): return
	if _wd.save(_world_path, _object_type_defs, _wall_type_defs):
		var spawns_file   := SpawnTool.path_for(_world_path).get_file()
		var entities_file := EntityTool.path_for(_world_path).get_file()
		var cells_file    := EditorWorldData.cells_path_for(_world_path).get_file()
		if not _spawn_tool.save_for(_world_path):
			_set_status("Saved %s — ERROR writing %s" % [_world_path.get_file(), spawns_file])
		elif not _entity_tool.save_for(_world_path):
			_set_status("Saved %s — ERROR writing %s" % [_world_path.get_file(), entities_file])
		elif not _wd.save_cells(EditorWorldData.cells_path_for(_world_path)):
			_set_status("Saved %s — ERROR writing %s" % [_world_path.get_file(), cells_file])
		else:
			_set_status("Saved: %s + %s + %s + %s" % [_world_path.get_file(), spawns_file, entities_file, cells_file])
	else:
		_set_status("ERROR: save failed")


func _update_world() -> void:
	if _wd == null or _world_path.is_empty():
		_set_status("Nothing to update — open and save a world first")
		return
	_save()
	var project_dir := ProjectSettings.globalize_path("res://")
	var py_script   := project_dir.path_join("../stone_gaze/update_world.py")
	var exit_code   := OS.execute("python3", [py_script, _world_path])
	if exit_code == 0:
		_set_status("World updated → build/ and gaze_client/")
	else:
		_set_status("Update failed (exit %d) — check that python3 is on PATH" % exit_code)


func _open_dialog() -> void:
	for child in get_children():
		if child is FileDialog:
			child.popup_centered_ratio(0.5)
			return


func _set_status(text: String) -> void:
	# Two short lines: where you are, then the current tool's settings. Every
	# shortcut lives in the F1 overlay rather than on screen all the time.
	var hint := "%s mode  —  [F1] shortcuts  [Esc] panel  [Tab] switch mode\n" % _mode.capitalize()
	if _mode == "terrain":
		hint += "layer %s  brush %.2f  strength %.0f  —  [E/Q] raise/lower  [F] smooth  [X] hole  [Scroll] brush" % [_layer, _brush_r, _brush_str]
	else:
		hint += _active_tool().status_hint()
	_label.text = text + "\n" + hint


# Side panel pages, in dropdown order. "terrain" and the place tools set the
# edit mode when picked; "menu" leaves the mode (and the 3D view's tool) as is.
const SIDE_PAGES := ["Menu", "Terrain", "Objects", "Props", "Biomes", "Chunks", "Walls", "Spawns", "Paint", "Entities"]
const PAGE_MENU    := 0
const PAGE_TERRAIN := 1
const PAGE_PLACE0  := 2  # first place page (Objects); place page p is PAGE_PLACE0 + p


# The page the current state calls for: the menu while it's open (or no world
# is), else terrain or the active place tool's page.
func _side_page_for_state() -> int:
	if _menu_open or _wd == null: return PAGE_MENU
	if _mode == "terrain": return PAGE_TERRAIN
	match _place_type:
		MODE_PROP:   return PAGE_PLACE0 + 1
		MODE_BIOME:  return PAGE_PLACE0 + 2
		MODE_CHUNK:  return PAGE_PLACE0 + 3
		MODE_WALL:   return PAGE_PLACE0 + 4
		MODE_SPAWN:  return PAGE_PLACE0 + 5
		MODE_CELLS:  return PAGE_PLACE0 + 6
		MODE_ENTITY: return PAGE_PLACE0 + 7
	return PAGE_PLACE0  # any object-type id, or MODE_WATER — both live on the Objects page


# The panel follows the real state however it changed (dropdown, Tab, number
# keys, Esc), so nothing else has to keep it in step.
func _sync_side_panel() -> void:
	_side_panel.visible = _world_editor_entered and _side_visible and not _mode_select.visible
	if not _side_panel.visible: return
	var page := _side_page_for_state()
	if _side_pick.selected != page: _side_pick.select(page)
	for i in range(_side_pages.size()):
		var show := i == page
		if (_side_pages[i] as Control).visible != show: (_side_pages[i] as Control).visible = show
	# Tool pages need an open world.
	for i in range(1, SIDE_PAGES.size()):
		if _side_pick.is_item_disabled(i) != (_wd == null): _side_pick.set_item_disabled(i, _wd == null)
	if page == PAGE_MENU: _update_world_info()
	elif page == PAGE_TERRAIN: _sync_terrain_panel()


func _pick_side_page(idx: int) -> void:
	_menu_open = idx == PAGE_MENU
	if idx == PAGE_TERRAIN:
		_mode = "terrain"
	elif idx >= PAGE_PLACE0:
		_mode = "place"
		match idx - PAGE_PLACE0:
			0: if _place_type != MODE_WATER and not _object_type_defs.has(_place_type): _place_type = 0
			1: _place_type = MODE_PROP
			2: _place_type = MODE_BIOME
			3: _place_type = MODE_CHUNK
			4: _place_type = MODE_WALL
			5: _place_type = MODE_SPAWN
			6: _place_type = MODE_CELLS
			7: _place_type = MODE_ENTITY
	if idx != PAGE_MENU: _set_status(SIDE_PAGES[idx])
	# The dropdown keeps keyboard focus after a pick — hand it back to the
	# shortcuts (number keys, E/Q, ...).
	_side_pick.release_focus()


# The right side panel: a dropdown of pages (Menu, Terrain, then one per
# place tool) above the chosen page. Esc shows / hides it.
func _build_side_panel(ui: CanvasLayer) -> Panel:
	var panel := Panel.new()
	panel.anchor_left   = 1.0; panel.anchor_right  = 1.0
	panel.anchor_top    = 0.0; panel.anchor_bottom = 1.0
	panel.offset_left   = -320; panel.offset_right  = 0
	panel.offset_top    = 0;    panel.offset_bottom = -50
	panel.visible = false
	ui.add_child(panel)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 4; root.offset_right = -4; root.offset_top = 4
	root.add_theme_constant_override("separation", 6)
	panel.add_child(root)

	_side_pick = OptionButton.new()
	_side_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side_pick.focus_mode = Control.FOCUS_NONE  # never holds the keyboard
	for i in range(SIDE_PAGES.size()):
		_side_pick.add_item(SIDE_PAGES[i], i)  # item index == page index
	_side_pick.item_selected.connect(_pick_side_page)
	root.add_child(_side_pick)
	root.add_child(HSeparator.new())

	var pages_holder := Control.new()
	pages_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(pages_holder)

	_side_pages = []
	var builders := [
		_build_menu_page, _build_terrain_page,
		_object_tool.build_page, _prop_tool.build_page, _biome_tool.build_page,
		_build_chunk_page, _wall_tool.build_page, _spawn_tool.build_page,
		_cell_tool.build_page, _entity_tool.build_page,
	]
	for build in builders:
		var vbox := VBoxContainer.new()
		vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
		vbox.visible = false
		vbox.add_theme_constant_override("separation", 6)
		pages_holder.add_child(vbox)
		_side_pages.append(vbox)
		(build as Callable).call(vbox)
	return panel


func _build_chunk_page(vbox: VBoxContainer) -> void:
	var chunk_hint := Label.new()
	chunk_hint.text = "[LMB] add chunk at grid cell\nExpands the world grid — grows chunks_x/chunks_z as needed."
	chunk_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(chunk_hint)


# Terrain page of the side panel: vertex selection, brush parameters, layer.
func _build_terrain_page(root: VBoxContainer) -> void:
	_sel_label = Label.new(); _sel_label.text = "No vertex selected"
	root.add_child(_sel_label)
	var height_row := HBoxContainer.new()
	var hlbl := Label.new(); hlbl.text = "Height"
	hlbl.custom_minimum_size = Vector2(50, 0)
	_sel_height = LineEdit.new(); _sel_height.custom_minimum_size = Vector2(44, 0)
	_sel_height.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sel_height.placeholder_text = "Enter to set"
	_sel_height.editable = false
	_sel_height.text_submitted.connect(_apply_selection_height)
	height_row.add_child(hlbl); height_row.add_child(_sel_height)
	root.add_child(height_row)

	root.add_child(HSeparator.new())

	var radius_row := HBoxContainer.new()
	var rlbl := Label.new(); rlbl.text = "Radius"
	rlbl.custom_minimum_size = Vector2(50, 0)
	var redit := LineEdit.new(); redit.text = str(_brush_r); redit.custom_minimum_size = Vector2(44, 0)
	_radius_edit = redit
	redit.text_changed.connect(func(v: String): _brush_r = v.to_float() if v.is_valid_float() else _brush_r)
	radius_row.add_child(rlbl); radius_row.add_child(redit)
	root.add_child(radius_row)

	var str_row := HBoxContainer.new()
	var slbl := Label.new(); slbl.text = "Strength"
	slbl.custom_minimum_size = Vector2(50, 0)
	var sedit := LineEdit.new(); sedit.text = str(_brush_str); sedit.custom_minimum_size = Vector2(44, 0)
	sedit.text_changed.connect(func(v: String): _brush_str = v.to_float() if v.is_valid_float() else _brush_str)
	str_row.add_child(slbl); str_row.add_child(sedit)
	root.add_child(str_row)

	var water_row := HBoxContainer.new()
	var wlbl := Label.new(); wlbl.text = "Water Y"
	wlbl.custom_minimum_size = Vector2(50, 0)
	var wedit := LineEdit.new(); wedit.text = str(_water_height); wedit.custom_minimum_size = Vector2(44, 0)
	wedit.text_changed.connect(func(v: String): _water_height = v.to_float() if v.is_valid_float() else _water_height)
	water_row.add_child(wlbl); water_row.add_child(wedit)
	root.add_child(water_row)

	root.add_child(HSeparator.new())

	var layer_lbl := Label.new(); layer_lbl.text = "Layer (cave chunks)"
	root.add_child(layer_lbl)
	var layer_row := HBoxContainer.new()
	var layer_group := ButtonGroup.new()
	for lname in ["h1", "h2", "h3"]:
		var lbtn := Button.new()
		lbtn.text = lname
		lbtn.toggle_mode = true
		lbtn.button_group = layer_group
		lbtn.button_pressed = lname == _layer
		lbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_layer_btns[lname] = lbtn
		var lkey: String = lname
		lbtn.pressed.connect(func(): _layer = lkey; _clear_vertex_selection(); _set_status("Layer: " + lkey))
		layer_row.add_child(lbtn)
	root.add_child(layer_row)

	root.add_child(HSeparator.new())
	var terrain_hint := Label.new()
	terrain_hint.text = "[LMB] select/unselect vertex  [Ctrl+LMB] add under brush (on a red vertex: remove it)\nHeight + [Enter]: set selection  [Esc] clear\n[E]/[Q] raise/lower  [F] smooth  [G] fill  [X] hole\n[N] snap  [C] cave  [O] ocean  [P/H] layer\n\n[F1] every shortcut"
	terrain_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(terrain_hint)

# ── Dialog keys, help overlay ────────────────────────────────────────────────

# Places a dialog panel in the middle of the screen at its minimum size.
func _center_panel(panel: Control) -> void:
	var sz := panel.custom_minimum_size
	panel.anchor_left = 0.5; panel.anchor_right  = 0.5
	panel.anchor_top  = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left = -sz.x * 0.5; panel.offset_right  = sz.x * 0.5
	panel.offset_top  = -sz.y * 0.5; panel.offset_bottom = sz.y * 0.5


# Enter confirms and Esc cancels whichever dialog is up. Runs from _input,
# ahead of the fields, so it works while typing; Enter on a focused button
# is left to that button. Returns whether the key was used.
func _dialog_key(event: InputEventKey) -> bool:
	var enter := event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER
	if not enter and event.keycode != KEY_ESCAPE: return false
	for panel in _dialog_keys:
		if not (panel as Control).visible: continue
		var actions: Array = _dialog_keys[panel]
		if event.keycode == KEY_ESCAPE:
			get_viewport().gui_release_focus()
			(actions[1] as Callable).call()
			return true
		if get_viewport().gui_get_focus_owner() is BaseButton: return false
		if (actions[0] as Callable).is_valid():
			get_viewport().gui_release_focus()
			(actions[0] as Callable).call()
			return true
		return false
	return false


# Number keys in place mode: [[keycodes], place type, status text]. Shared by
# the key handler and the help overlay so the two can't disagree. Keys 1 and
# 2 are the first two object types in object_types.json.
func _place_picks() -> Array:
	return [
		[[KEY_1], 0, "Object: " + _object_type_name(0)],
		[[KEY_2], 1, "Object: " + _object_type_name(1)],
		[[KEY_3], MODE_CHUNK, "Chunk add"],
		[[KEY_4], MODE_WATER, "Water"],
		[[KEY_5, KEY_B], MODE_BIOME, "Biome paint"],
		[[KEY_6], MODE_PROP, "Prop paint"],
		[[KEY_7], MODE_WALL, "Walls"],
		[[KEY_8], MODE_SPAWN, "Spawners"],
		[[KEY_9], MODE_CELLS, "Cell texture paint"],
		[[KEY_0], MODE_ENTITY, "Entities"],
	]


func _build_help_panel(ui: CanvasLayer) -> Panel:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(680, 560)
	panel.visible = false
	ui.add_child(panel)
	_center_panel(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 14; vbox.offset_right = -14
	vbox.offset_top  = 10; vbox.offset_bottom = -10
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Shortcuts"
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	_help_grid = GridContainer.new()
	_help_grid.columns = 2
	_help_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_help_grid.add_theme_constant_override("h_separation", 18)
	scroll.add_child(_help_grid)

	var close := Button.new()
	close.text = "Close  (F1 / Esc)"
	close.pressed.connect(func(): panel.visible = false)
	vbox.add_child(close)
	return panel


func _toggle_help() -> void:
	if _help_panel.visible:
		_help_panel.visible = false
		return
	for c in _help_grid.get_children(): c.queue_free()
	for row in _help_rows():
		var key := Label.new()
		var what := Label.new()
		if (row[0] as String).begins_with("#"):
			key.text = (row[0] as String).substr(1)
			key.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
		else:
			key.text = row[0]
		what.text = row[1]
		what.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_help_grid.add_child(key)
		_help_grid.add_child(what)
	_help_panel.visible = true


# [key, action] rows; "#Title" starts a section. The current mode's section
# comes first, and place mode ends with the active tool's own controls.
func _help_rows() -> Array:
	var general := [
		["#General", ""],
		["F1", "Show / hide this list"],
		["Esc", "Cancel the current action, leave a text field, or show / hide the side panel"],
		["Side panel dropdown", "Menu (open/save/...), Terrain, or a place tool"],
		["Tab", "Switch terrain / place mode"],
		["RMB drag", "Look around"],
		["W A S D", "Move"],
		["Space / Shift", "Move up / down"],
		["Ctrl+Z", "Undo (only the feature being edited)"],
		["Ctrl+Shift+Z, Ctrl+Y", "Redo"],
		["Ctrl+S / Ctrl+Shift+S", "Save / Save as"],
		["Ctrl+O / Ctrl+N", "Open / New world"],
		["Click the 3D view", "Hand the keyboard back from a text field"],
		["", ""],
	]
	var terrain := [
		["#Terrain mode", ""],
		["LMB", "Select the nearest vertex of the current layer (click a selected one to clear the selection)"],
		["Ctrl+LMB (drag)", "Add every vertex under the brush to the selection; starting on a selected vertex removes instead"],
		["Height + Enter", "Set the selected vertices to that height"],
		["E / Q", "Raise / lower (only the selection, if there is one)"],
		["Ctrl + E / Q", "Fine raise / lower"],
		["F", "Smooth"],
		["G", "Fill holes"],
		["X", "Hole (an h1 hole becomes a cave entrance)"],
		["Ctrl+X / Alt+X", "Hole a single vertex / a cell's 4 corners"],
		["N", "Snap layers together"],
		["Alt+N / Ctrl+Alt+N", "Glue / unglue h1 and h2 (move together)"],
		["Scroll", "Brush radius"],
		["C", "Toggle cave chunk"],
		["O", "Toggle ocean chunk (water at Water Y)"],
		["P / H", "Cycle layer h1 → h2 → h3"],
		["", ""],
	]
	var place := [["#Place mode", ""]]
	for row in _place_picks():
		var keys := PackedStringArray()
		for k in row[0]: keys.append(OS.get_keycode_string(k))
		place.append([" / ".join(keys), row[2]])
	place.append(["Delete", "Remove what's under the cursor (per tool)"])
	if _mode == "place":
		place.append(["Active tool", _active_tool().status_hint()])
	place.append(["", ""])
	return (terrain + place if _mode == "terrain" else place + terrain) + general
