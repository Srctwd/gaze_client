extends CanvasLayer

signal login_pressed(email: String, passkey: String)

const _SAVE_PATH := "user://login.cfg"

var _username_field: LineEdit
var _password_field: LineEdit
var _remember_check: CheckBox
var _error_label:    Label

func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(260, 0)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Stone Gaze"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_username_field = LineEdit.new()
	_username_field.placeholder_text = "Email"
	vbox.add_child(_username_field)

	_password_field = LineEdit.new()
	_password_field.placeholder_text = "Passkey"
	_password_field.secret = true
	vbox.add_child(_password_field)

	var btn := Button.new()
	btn.text = "Login"
	btn.pressed.connect(_on_login_pressed)
	vbox.add_child(btn)

	_remember_check = CheckBox.new()
	_remember_check.text = "Remember email"
	vbox.add_child(_remember_check)

	_error_label = Label.new()
	_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error_label.visible = false
	vbox.add_child(_error_label)

	visible = false
	_load_saved_email()

func show_error(msg: String) -> void:
	_error_label.text = msg
	_error_label.visible = true

func clear_error() -> void:
	_error_label.text = ""
	_error_label.visible = false

func _load_saved_email() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_SAVE_PATH) != OK:
		return
	var email: String = cfg.get_value("login", "email", "")
	if not email.is_empty():
		_username_field.text = email
		_remember_check.button_pressed = true

func _save_email(email: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(_SAVE_PATH)  # ignore errors — a missing/corrupt file just starts empty
	cfg.set_value("login", "email", email if _remember_check.button_pressed else "")
	cfg.save(_SAVE_PATH)

func _on_login_pressed() -> void:
	_save_email(_username_field.text)
	login_pressed.emit(_username_field.text, _password_field.text)
