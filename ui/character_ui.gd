extends CanvasLayer

signal character_confirmed(char_id: int)

const RACES := ["Human", "Homunculi", "Elf", "Orc", "Ogre", "Naga"]

var _token: String = ""
var _http: HTTPRequest
var _selected_char_id: int = -1

var _select_panel: VBoxContainer
var _create_panel: VBoxContainer
var _list_container: VBoxContainer
var _name_field: LineEdit
var _race_option: OptionButton
var _create_error: Label


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_http_response)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	# ── Select screen ──────────────────────────────────────────────
	_select_panel = VBoxContainer.new()
	_select_panel.custom_minimum_size = Vector2(300, 0)
	center.add_child(_select_panel)

	var sel_title := Label.new()
	sel_title.text = "Select Character"
	sel_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_select_panel.add_child(sel_title)

	_list_container = VBoxContainer.new()
	_select_panel.add_child(_list_container)

	_select_panel.add_child(HSeparator.new())

	var new_btn := Button.new()
	new_btn.text = "New Character"
	new_btn.pressed.connect(_show_create)
	_select_panel.add_child(new_btn)

	# ── Create screen ──────────────────────────────────────────────
	_create_panel = VBoxContainer.new()
	_create_panel.custom_minimum_size = Vector2(300, 0)
	center.add_child(_create_panel)

	var cre_title := Label.new()
	cre_title.text = "New Character"
	cre_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_create_panel.add_child(cre_title)

	_name_field = LineEdit.new()
	_name_field.placeholder_text = "Name"
	_create_panel.add_child(_name_field)

	_race_option = OptionButton.new()
	for race in RACES:
		_race_option.add_item(race)
	_create_panel.add_child(_race_option)

	_create_error = Label.new()
	_create_error.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_create_error.modulate = Color(1, 0.3, 0.3)
	_create_panel.add_child(_create_error)

	var btn_row := HBoxContainer.new()
	_create_panel.add_child(btn_row)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back_btn.pressed.connect(_show_select)
	btn_row.add_child(back_btn)

	var create_btn := Button.new()
	create_btn.text = "Create"
	create_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create_btn.pressed.connect(_on_create_pressed)
	btn_row.add_child(create_btn)

	visible = false


func show_for_token(token: String) -> void:
	_token = token
	_http.request(Config.WEBSERVER + "/api/characters?token=" + token,
		[], HTTPClient.METHOD_GET)


func _show_select() -> void:
	_select_panel.visible = true
	_create_panel.visible = false


func _show_create() -> void:
	_name_field.text = ""
	_create_error.text = ""
	_select_panel.visible = false
	_create_panel.visible = true


func _populate_list(characters: Array) -> void:
	for child in _list_container.get_children():
		child.queue_free()
	for c in characters:
		var btn := Button.new()
		btn.text = "%s  (Lvl %d %s)" % [c["name"], _xp_to_level(c["experience"]), RACES[c["race"]]]
		btn.pressed.connect(_on_character_selected.bind(c["id"]))
		_list_container.add_child(btn)


func _on_character_selected(char_id: int) -> void:
	_selected_char_id = char_id
	get_viewport().gui_release_focus()
	visible = false
	character_confirmed.emit(_selected_char_id)


func _on_create_pressed() -> void:
	var name_val := _name_field.text.strip_edges()
	if name_val.is_empty():
		_create_error.text = "Enter a name."
		return
	var body := JSON.stringify({"token": _token, "name": name_val, "race": _race_option.selected})
	_http.request(Config.WEBSERVER + "/api/characters",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)


func _on_http_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var json: Variant = JSON.parse_string(body.get_string_from_utf8())
	if code == 200 and json is Array:
		_populate_list(json)
		_show_select()
		visible = true
		return
	if code == 200 and json is Dictionary and json.get("ok"):
		_http.request(Config.WEBSERVER + "/api/characters?token=" + _token,
			[], HTTPClient.METHOD_GET)
		return
	if code == 400 and json is Dictionary and json.get("detail") == "Name already taken":
		_create_error.text = 'A character named "%s" already exists.' % _name_field.text.strip_edges()
		return
	_create_error.text = "Error. Try again."


func _xp_to_level(xp: int) -> int:
	return xp / 1000 + 1
