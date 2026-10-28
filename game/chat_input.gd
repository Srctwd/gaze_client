extends Node

# Chat text entry: Enter opens typing mode (no visible input box — an
# invisible, off-screen LineEdit captures keystrokes so normal text editing
# just works), Enter again sends and the words show as a 2D BBCode label
# centered on screen (same technique as entity_manager.gd's NPC speech
# bubbles), turning yellow to mark it as sent, and the text is relayed to
# the server as ChatSay (see chat.cpp — nearby NPCs may reply via
# NpcSpeech). Text wrapped in a pair of '*' (npcs.json's keyword convention,
# e.g. "*Trade*") renders highlighted, same as NPC replies.

@onready var _player_controller: Node = $"../PlayerController"

const LABEL_SCREEN_Y      := 0.6  # fraction down the viewport — roughly where the old camera-relative offset put it
const LABEL_FONT_SIZE     := 16
const LABEL_COLOR         := Color.WHITE
const LABEL_SENT_COLOR    := Color.YELLOW
const LABEL_HIGHLIGHT_COLOR := Color(0.55, 0.8, 1.0)  # lightish blue
const HIDE_DELAY    := 4.0
const MAX_LENGTH    := 80

var _line_edit:  LineEdit
var _label:      RichTextLabel
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
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_label.add_theme_font_size_override("normal_font_size", LABEL_FONT_SIZE)
	_label.add_theme_constant_override("outline_size", 3)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.visible = false
	var layer := CanvasLayer.new()
	layer.add_child(_label)
	add_child(layer)

func _setup_hide_timer() -> void:
	_hide_timer = Timer.new()
	_hide_timer.one_shot = true
	_hide_timer.wait_time = HIDE_DELAY
	_hide_timer.timeout.connect(func(): _label.visible = false)
	add_child(_hide_timer)

func _process(_delta: float) -> void:
	if _label.visible:
		_center_label()

func _center_label() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	_label.position = Vector2((viewport_size.x - _label.size.x) * 0.5, viewport_size.y * LABEL_SCREEN_Y)

func _set_label_text(text: String, base_color: Color) -> void:
	_label.add_theme_color_override("default_color", base_color)
	_label.text = Protocol.text_to_bbcode(text, LABEL_HIGHLIGHT_COLOR)
	_label.reset_size()
	_center_label()

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
	_set_label_text("", LABEL_COLOR)
	_label.visible = true

func _on_text_changed(new_text: String) -> void:
	_set_label_text(new_text, LABEL_COLOR)

func _on_text_submitted(final_text: String) -> void:
	_stop_typing()
	final_text = final_text.strip_edges()
	if final_text.is_empty():
		_label.visible = false
		return
	_set_label_text(final_text, LABEL_SENT_COLOR)  # spoken (sent) text reads differently from text still being typed
	_hide_timer.start()
	Network.send(Protocol.pkt_chat_say(final_text))

func _on_focus_exited() -> void:
	if _typing:
		_stop_typing()
		_label.visible = false

# LineEdit doesn't release focus or emit text_submitted on Escape by itself —
# without this, Escape would leave _typing/chat_typing stuck true forever
# (movement blocked, nothing ever sent).
func _on_line_edit_gui_input(event: InputEvent) -> void:
	if _typing and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		_stop_typing()
		_label.visible = false
		get_viewport().set_input_as_handled()  # don't let main.gd read it as logout

func _stop_typing() -> void:
	_typing = false
	GameState.chat_typing = false
	_line_edit.release_focus()
