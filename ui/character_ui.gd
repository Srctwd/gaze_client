extends CanvasLayer

signal character_confirmed(char_id: int)

const CharacterCreateUI := preload("res://ui/character_create_ui.gd")

var _token: String = ""
var _selected_char_id: int = -1
# Set by main.gd (player_controller's wiring pattern); the create screen
# picks the starting talent with it.
var talent_tree_ui: Node = null:
	set(value):
		talent_tree_ui = value
		_create_screen.talent_tree_ui = value
var _characters: Array = []  # last-fetched character list, for the create screen's dupe-name check

var _select_panel: VBoxContainer
var _create_screen: CharacterCreateUI
var _list_container: VBoxContainer
var _delete_dialog: ConfirmationDialog
var _delete_char_id: int = -1  # waiting on the confirm dialog
var _delete_char_name: String = ""
var _delete_label: Label
var _delete_name_field: LineEdit
var _select_error: Label


func _ready() -> void:
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

	_select_error = Label.new()
	_select_error.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_select_error.modulate = Color(1, 0.3, 0.3)
	_select_panel.add_child(_select_error)

	_select_panel.add_child(HSeparator.new())

	var new_btn := Button.new()
	new_btn.text = "New Character"
	new_btn.pressed.connect(_show_create)
	_select_panel.add_child(new_btn)

	# ── Create screen (character_create_ui.gd) ─────────────────────
	_create_screen = CharacterCreateUI.new()
	add_child(_create_screen)
	_create_screen.create_requested.connect(_on_create_requested)
	_create_screen.cancelled.connect(_show_select)

	# ── Delete confirmation ────────────────────────────────────────
	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.title = "Delete Character"
	_delete_dialog.ok_button_text = "Delete"
	_delete_dialog.confirmed.connect(_on_delete_confirmed)
	_delete_dialog.canceled.connect(func() -> void: _delete_char_id = -1)
	add_child(_delete_dialog)

	# Typing the name is the confirmation — Delete stays disabled until it matches.
	var del_box := VBoxContainer.new()
	_delete_dialog.add_child(del_box)
	_delete_label = Label.new()
	del_box.add_child(_delete_label)
	_delete_name_field = LineEdit.new()
	_delete_name_field.placeholder_text = "Character name"
	_delete_name_field.text_changed.connect(func(text: String) -> void:
		_delete_dialog.get_ok_button().disabled = text != _delete_char_name)
	del_box.add_child(_delete_name_field)
	_delete_dialog.register_text_enter(_delete_name_field)
	Network.character_deleted.connect(_on_character_deleted)
	Network.character_list.connect(_on_character_list)
	Network.character_created.connect(_on_character_created)

	visible = false


# Everything at character select goes over the game connection — the web
# server only logs in. The list arrives as CharacterList (_on_character_list).
func show_for_token(token: String) -> void:
	_token = token
	_request_list()


func _request_list() -> void:
	Network.send(Protocol.pkt_character_list(_token))


func _show_select() -> void:
	_select_error.text = ""
	_select_panel.visible = true
	_create_screen.visible = false


func _show_create() -> void:
	_select_panel.visible = false
	_create_screen.open(_characters.map(func(c: Dictionary) -> String: return c["name"]))


func _populate_list(characters: Array) -> void:
	_characters = characters
	for child in _list_container.get_children():
		child.queue_free()
	for c in characters:
		var row := HBoxContainer.new()
		_list_container.add_child(row)
		var btn := Button.new()
		btn.text = "%s  (Lvl %d %s)" % [c["name"], _xp_to_level(c["experience"]), Races.ALL[c["race"]]["name"]]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_character_selected.bind(c["id"]))
		row.add_child(btn)
		var del_btn := Button.new()
		del_btn.text = "Delete"
		del_btn.pressed.connect(_on_delete_pressed.bind(c["id"], c["name"]))
		row.add_child(del_btn)


func _on_character_selected(char_id: int) -> void:
	_selected_char_id = char_id
	get_viewport().gui_release_focus()
	visible = false
	character_confirmed.emit(_selected_char_id)


func _on_delete_pressed(char_id: int, char_name: String) -> void:
	_delete_char_id = char_id
	_delete_char_name = char_name
	_delete_label.text = 'Delete "%s"? This can\'t be undone.\nType its name to confirm.' % char_name
	_delete_name_field.text = ""
	_delete_dialog.get_ok_button().disabled = true
	_delete_dialog.popup_centered()
	_delete_name_field.grab_focus()


func _on_delete_confirmed() -> void:
	var char_id := _delete_char_id
	_delete_char_id = -1
	if _delete_name_field.text != _delete_char_name:  # Enter in the field confirms too
		return
	# Over the game connection, not the web API: only the game server knows
	# whether someone is playing this character right now.
	Network.send(Protocol.pkt_delete_character(_token, char_id))


func _on_character_deleted(result: int) -> void:
	if result == Protocol.DELETE_OK:
		_request_list()
	elif result == Protocol.DELETE_IN_GAME:
		_select_error.text = "That character is in game right now."
	else:
		_select_error.text = "Couldn't delete. Log in again and retry."


func _on_create_requested(char_name: String, race: int, talent: int, skin_color: int) -> void:
	Network.send(Protocol.pkt_create_character(_token, char_name, race, talent, skin_color))


func _on_character_list(ok: bool, characters: Array) -> void:
	_populate_list(characters)
	_show_select()
	if not ok:
		_select_error.text = "Your login expired. Log in again."
	visible = true


func _on_character_created(result: int) -> void:
	_create_screen.show_result(result)
	if result == Protocol.CREATE_OK:
		_request_list()


func _xp_to_level(xp: int) -> int:
	return xp / 1000 + 1
