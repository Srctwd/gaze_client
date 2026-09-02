extends Node

# Client-only chat text entry: Enter opens typing mode (no visible input box —
# an invisible, off-screen LineEdit captures keystrokes so normal text editing
# just works), Enter again sends and the words show as billboarded 3D text
# floating in front of the camera (parented to it, so it tracks wherever you
# look). No networking yet — nothing is sent anywhere.

@onready var _camera: Camera3D = $"../Camera3D"
@onready var _player_controller: Node = $"../PlayerController"

const LABEL_OFFSET := Vector3(0, -0.25, -2.0) # local to the camera
const HIDE_DELAY    := 4.0
const MAX_LENGTH    := 80

var _line_edit:  LineEdit
var _label3d:    Label3D
var _hide_timer: Timer
var _typing      := false

func _ready() -> void:
	_setup_input_capture()
	_setup_label()
	_setup_hide_timer()

func _setup_input_capture() -> void:
	_line_edit = LineEdit.new()
	_line_edit.size = Vector2(1, 1)
	_line_edit.position = Vector2(-200, -200) # off-screen — invisible, still focusable
	_line_edit.max_length = MAX_LENGTH
	_line_edit.context_menu_enabled = false
	_line_edit.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_line_edit.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_line_edit.add_theme_color_override("font_color", Color(0, 0, 0, 0))
	_line_edit.add_theme_color_override("caret_color", Color(0, 0, 0, 0))
	_line_edit.text_changed.connect(_on_text_changed)
	_line_edit.text_submitted.connect(_on_text_submitted)
	_line_edit.focus_exited.connect(_on_focus_exited)
	_line_edit.gui_input.connect(_on_line_edit_gui_input)
	var layer := CanvasLayer.new()
	layer.add_child(_line_edit)
	add_child(layer)

func _setup_label() -> void:
	_label3d = Label3D.new()
	_label3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label3d.font_size = 16
	_label3d.outline_size = 3
	_label3d.position = LABEL_OFFSET
	_label3d.no_depth_test = true    # ignore world geometry in front of it — never occluded
	_label3d.render_priority = 127   # draw last among transparent objects too
	_label3d.visible = false
	_camera.add_child(_label3d)

func _setup_hide_timer() -> void:
	_hide_timer = Timer.new()
	_hide_timer.one_shot = true
	_hide_timer.wait_time = HIDE_DELAY
	_hide_timer.timeout.connect(func(): _label3d.visible = false)
	add_child(_hide_timer)

func _unhandled_key_input(event: InputEvent) -> void:
	if _typing or GameState.player_net_id == -1 or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
		_start_typing()

func _start_typing() -> void:
	_typing = true
	GameState.chat_typing = true
	_player_controller.stop_movement()
	_line_edit.text = ""
	_hide_timer.stop()
	_line_edit.grab_focus()
	_label3d.text = ""
	_label3d.visible = true

func _on_text_changed(new_text: String) -> void:
	_label3d.text = new_text

func _on_text_submitted(final_text: String) -> void:
	_stop_typing()
	final_text = final_text.strip_edges()
	if final_text.is_empty():
		_label3d.visible = false
		return
	_label3d.text = final_text
	_hide_timer.start()

func _on_focus_exited() -> void:
	if _typing:
		_stop_typing()
		_label3d.visible = false

# LineEdit doesn't release focus or emit text_submitted on Escape by itself —
# without this, Escape would leave _typing/chat_typing stuck true forever
# (movement blocked, nothing ever sent).
func _on_line_edit_gui_input(event: InputEvent) -> void:
	if _typing and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		_stop_typing()
		_label3d.visible = false

func _stop_typing() -> void:
	_typing = false
	GameState.chat_typing = false
	_line_edit.release_focus()
