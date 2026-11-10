extends Control
## New-character screen: name, race (with its stats and a turning preview of
## the body), skin colour, and the starting talent through talent_tree_ui's
## selection mode. Owns no networking — character_ui.gd sends create_requested on to
## the server and hands the CreateCharacterResponse code back to show_result.

signal create_requested(char_name: String, race: int, talent: int, skin_color: int)
signal cancelled
signal created

const _PREVIEW_TURN_SPEED := 0.5   # rad/s
# Swatches offered in the skin picker (any colour can still be picked).
const SKIN_PRESETS: Array[Color] = [
	Color("#f6dcc8"), Color("#e8bf9a"), Color("#d09a6c"), Color("#a86e45"),
	Color("#7a4a2c"), Color("#4e2e1c"), Color("#8fa86a"), Color("#7d8fb0"),
]
# characters.name is varchar(64) — the server refuses longer (in UTF-8 bytes).
const NAME_MAX_BYTES := 64

var talent_tree_ui: Node = null:   # set through character_ui.gd (main.gd's wiring pattern)
	set(value):
		talent_tree_ui = value
		talent_tree_ui.talent_selected.connect(_on_talent_selected)
		talent_tree_ui.selection_cancelled.connect(_on_talent_cancelled)

var _existing_names: Array = []
var _race := 0
var _talent := -1
var _skin := Color.WHITE
var _talents := TalentTree.new()   # names for the chosen-talent row
var _picking_talent := false   # talent_tree_ui's signals are ours only while this is set

var _root: Control
var _name_field: LineEdit
var _race_buttons: Array[Button] = []
var _race_title: Label
var _race_blurb: Label
var _race_stats: GridContainer
var _talent_label: Label
var _talent_btn: Button
var _skin_picker: ColorPickerButton
var _error: Label
var _create_btn: Button
var _back_btn: Button
var _preview_pivot: Node3D
var _preview_skin: SkinTint
var _preview_body: Node3D
var _preview_cam: Camera3D


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_talents.load()
	_root = MarginContainer.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		_root.add_theme_constant_override("margin_" + side, 48)
	add_child(_root)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 32)
	_root.add_child(columns)

	columns.add_child(_make_form())
	columns.add_child(_make_preview())

	visible = false


func _make_form() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(340, 0)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title := Label.new()
	title.text = "New Character"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)

	box.add_child(_heading("Name"))
	_name_field = LineEdit.new()
	_name_field.placeholder_text = "Name"
	_name_field.text_submitted.connect(func(_t: String) -> void: _on_create_pressed())
	_name_field.text_changed.connect(func(_t: String) -> void: _error.text = "")
	box.add_child(_name_field)

	box.add_child(_heading("Race"))
	var grid := GridContainer.new()
	grid.columns = 3
	var group := ButtonGroup.new()
	for i in Races.ALL.size():
		var b := Button.new()
		b.text = Races.ALL[i]["name"]
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_select_race.bind(i))
		grid.add_child(b)
		_race_buttons.append(b)
	box.add_child(grid)

	var info := PanelContainer.new()
	var info_box := VBoxContainer.new()
	info.add_child(info_box)
	_race_title = Label.new()
	_race_title.add_theme_font_size_override("font_size", 18)
	info_box.add_child(_race_title)
	_race_blurb = Label.new()
	_race_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_race_blurb.modulate = Color(0.8, 0.8, 0.8)
	info_box.add_child(_race_blurb)
	_race_stats = GridContainer.new()
	_race_stats.columns = 2
	_race_stats.add_theme_constant_override("h_separation", 16)
	info_box.add_child(_race_stats)
	box.add_child(info)

	box.add_child(_heading("Skin"))
	_skin_picker = ColorPickerButton.new()
	_skin_picker.custom_minimum_size = Vector2(0, 28)
	_skin_picker.color_changed.connect(_set_skin)
	var picker := _skin_picker.get_picker()
	picker.edit_intensity = false   # HDR overbright, meaningless for skin (and the server's 8-bit RGBA)
	picker.presets_visible = true
	for c in SKIN_PRESETS:
		picker.add_preset(c)
	box.add_child(_skin_picker)

	box.add_child(_heading("Starting Talent"))
	var talent_row := HBoxContainer.new()
	_talent_label = Label.new()
	_talent_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	talent_row.add_child(_talent_label)
	_talent_btn = Button.new()
	_talent_btn.text = "Choose…"
	_talent_btn.pressed.connect(_on_choose_talent_pressed)
	talent_row.add_child(_talent_btn)
	box.add_child(talent_row)

	_error = Label.new()
	_error.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.modulate = Color(1, 0.3, 0.3)
	box.add_child(_error)

	var row := HBoxContainer.new()
	box.add_child(row)
	_back_btn = Button.new()
	_back_btn.text = "Back"
	_back_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_back_btn.pressed.connect(_on_back_pressed)
	row.add_child(_back_btn)
	_create_btn = Button.new()
	_create_btn.text = "Create"
	_create_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_create_btn.pressed.connect(_on_create_pressed)
	row.add_child(_create_btn)
	return panel


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.modulate = Color(0.7, 0.7, 0.7)
	return l


# The body on a turntable, in its own world so it's lit and framed the same
# whatever the game world is doing behind this screen.
func _make_preview() -> Control:
	var box := SubViewportContainer.new()
	box.stretch = true
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var view := SubViewport.new()
	view.own_world_3d = true
	view.transparent_bg = true
	box.add_child(view)

	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.6)
	env.ambient_light_energy = 0.6
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	view.add_child(world_env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 30, 0)
	key.light_energy = 1.1
	view.add_child(key)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-20, 200, 0)
	rim.light_energy = 0.5
	rim.light_color = Color(0.7, 0.8, 1.0)
	view.add_child(rim)

	_preview_pivot = Node3D.new()
	view.add_child(_preview_pivot)
	_preview_cam = Camera3D.new()
	_preview_cam.fov = 30.0
	view.add_child(_preview_cam)
	return box


# The race's body on the turntable, in the current skin, framed by its bounds:
# centred, filling most of the view's height.
func _show_preview_body(race: int) -> void:
	if _preview_body != null:
		_preview_body.queue_free()
	_preview_body = Races.model(race).instantiate() as Node3D
	_preview_pivot.add_child(_preview_body)
	_preview_skin = SkinTint.new(_preview_body)
	_preview_skin.set_color(_skin)
	var anim := _preview_body.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if anim != null and anim.has_animation("Idle"):
		anim.get_animation("Idle").loop_mode = Animation.LOOP_LINEAR
		anim.play("Idle")

	var bounds := _preview_body.transform * ModelBounds.rest_aabb(_preview_body)
	_preview_body.position = -Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
	var h := bounds.size.y
	var eye := Vector3(0, h * 0.55, h * 2.4)
	_preview_cam.transform = Transform3D(Basis.looking_at(Vector3(0, h * 0.5, 0) - eye), eye)


func _process(delta: float) -> void:
	if is_visible_in_tree():
		_preview_pivot.rotate_y(_PREVIEW_TURN_SPEED * delta)


## Shows the screen with a fresh form. existing_names: this account's
## characters, for a quick duplicate check before talent selection (the
## server still checks names across all accounts).
func open(existing_names: Array) -> void:
	_existing_names = existing_names
	_name_field.text = ""
	_error.text = ""
	_set_busy(false)
	_select_race(0)
	_set_talent(-1)
	_skin_picker.color = Color.WHITE
	_set_skin(Color.WHITE)
	_root.visible = true
	visible = true
	_name_field.grab_focus()


## The server's CreateCharacterResponse to our create_requested.
func show_result(result: int) -> void:
	if result == Protocol.CREATE_OK:
		visible = false
		created.emit()
		return
	_set_busy(false)
	_root.visible = true
	match result:
		Protocol.CREATE_NAME_TAKEN:
			_error.text = 'The name "%s" is taken.' % _name_field.text.strip_edges()
			_name_field.grab_focus()
		Protocol.CREATE_INVALID:
			_error.text = "That name or choice isn't allowed."
		Protocol.CREATE_NOT_FOUND:
			_error.text = "Your login expired. Log in again."
		_:
			_error.text = "Couldn't create the character. Try again."


func _select_race(i: int) -> void:
	_race = i
	_race_buttons[i].button_pressed = true
	var r: Dictionary = Races.ALL[i]
	_show_preview_body(i)
	_race_title.text = r["name"]
	_race_blurb.text = r["blurb"]
	for c in _race_stats.get_children():
		c.queue_free()
	for stat: Array in [
			["Health", "%s  (×%s per level)" % [_num(r["hp"]), _num(r["hp_multi"])]],
			["Mana", "%s  (×%s per level)" % [_num(r["mana"]), _num(r["mana_multi"])]],
			["Swimming", "%d%% speed" % roundi(r["swim"] * 100.0)],
			["Climbing", "%s m steps" % _num(r["climb"])]]:
		var k := Label.new()
		k.text = stat[0]
		k.modulate = Color(0.7, 0.7, 0.7)
		_race_stats.add_child(k)
		var v := Label.new()
		v.text = stat[1]
		_race_stats.add_child(v)


func _num(x: float) -> String:
	return str(snappedf(x, 0.01)).trim_suffix(".0")


func _on_create_pressed() -> void:
	if _create_btn.disabled:
		return
	var char_name := _name_field.text.strip_edges()
	if char_name.is_empty():
		_error.text = "Enter a name."
		_name_field.grab_focus()
		return
	if char_name.to_utf8_buffer().size() > NAME_MAX_BYTES:
		_error.text = "That name is too long."
		return
	for n: String in _existing_names:
		if n.to_lower() == char_name.to_lower():
			_error.text = 'You already have a character named "%s".' % char_name
			return
	if _talent < 0:
		_error.text = "Choose a starting talent."
		return
	_set_busy(true)
	create_requested.emit(char_name, _race, _talent, _skin.to_rgba32())


func _on_choose_talent_pressed() -> void:
	if talent_tree_ui == null:
		return
	_picking_talent = true
	_root.visible = false
	talent_tree_ui.start_selection()


func _on_talent_selected(node_id: int) -> void:
	if not _picking_talent:
		return
	_picking_talent = false
	_root.visible = true
	_set_talent(node_id)


func _on_talent_cancelled() -> void:
	if not _picking_talent:
		return
	_picking_talent = false
	_root.visible = true


func _set_talent(node_id: int) -> void:
	_talent = node_id
	if node_id < 0:
		_talent_label.text = "None chosen"
		_talent_label.modulate = Color(0.6, 0.6, 0.6)
	else:
		_talent_label.text = _talents.by_id[node_id]["name"]
		_talent_label.modulate = Color.WHITE
		_error.text = ""


func _set_skin(c: Color) -> void:
	_skin = c
	_preview_skin.set_color(c)


func _on_back_pressed() -> void:
	visible = false
	cancelled.emit()


func _set_busy(busy: bool) -> void:
	_create_btn.disabled = busy
	_back_btn.disabled = busy
	_name_field.editable = not busy
	for b in _race_buttons:
		b.disabled = busy
	_skin_picker.disabled = busy
	_talent_btn.disabled = busy
	_create_btn.text = "Creating…" if busy else "Create"
