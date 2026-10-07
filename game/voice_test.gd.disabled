extends Node

# Push-to-talk speech-to-text test: hold PUSH_TO_TALK_KEY, speak, release —
# the transcribed words show in a label on the local player's screen.
# Uses the godot-whisper GDExtension (addons/godot_whisper, v1.0.5 binaries —
# newer nightly builds need a glibc too recent for this machine). No networking yet.
#
# CaptureStreamToText's _ready() unconditionally starts its transcription
# thread as soon as it enters the tree, so push-to-talk is implemented by
# instantiating/freeing the node per press rather than toggling a flag on
# one long-lived node.

const PUSH_TO_TALK_KEY := KEY_V
const RECORD_BUS := "Record"
const MODEL_PATH := "res://addons/godot_whisper/models/ggml-tiny.en.bin"

var _mic_player: AudioStreamPlayer
var _stt: CaptureStreamToText
var _language_model: WhisperResource
var _text_label: RichTextLabel
var _status_label: Label
var _was_pressed := false

func _ready() -> void:
	_setup_record_bus()
	_setup_mic_player()
	_language_model = load(MODEL_PATH)
	_setup_overlay()

func _setup_record_bus() -> void:
	if AudioServer.get_bus_index(RECORD_BUS) >= 0:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, RECORD_BUS)
	AudioServer.set_bus_volume_db(idx, -80.0) # silent — we only want the capture tap, not audible mic monitoring
	AudioServer.add_bus_effect(idx, AudioEffectCapture.new(), 0)

func _setup_mic_player() -> void:
	_mic_player = AudioStreamPlayer.new()
	_mic_player.bus = RECORD_BUS
	add_child(_mic_player)

func _setup_overlay() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_status_label = Label.new()
	_status_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_status_label.position = Vector2(-150, -110)
	_status_label.custom_minimum_size = Vector2(300, 20)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.text = "Hold V to talk"
	layer.add_child(_status_label)

	_text_label = RichTextLabel.new()
	_text_label.bbcode_enabled = true
	_text_label.fit_content = true
	_text_label.scroll_active = false
	_text_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_text_label.position = Vector2(-250, -90)
	_text_label.custom_minimum_size = Vector2(500, 80)
	_text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_text_label)

func _process(_delta: float) -> void:
	var pressed := Input.is_key_pressed(PUSH_TO_TALK_KEY)
	if pressed and not _was_pressed:
		_start_talking()
	elif not pressed and _was_pressed:
		_stop_talking()
	_was_pressed = pressed

func _start_talking() -> void:
	_text_label.text = ""
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.play()

	_stt = CaptureStreamToText.new()
	_stt.record_bus = RECORD_BUS
	_stt.audio_effect_capture_index = 0
	_stt.language_model = _language_model
	_stt.transcribe_interval = 0.3
	_stt.minimum_sentence_time = 0
	_stt.transcribed_msg.connect(_on_transcribed)
	add_child(_stt) # enters tree -> CaptureStreamToText._ready() starts the transcription thread

	_status_label.text = "Listening..."

func _stop_talking() -> void:
	_status_label.text = "Hold V to talk"
	_mic_player.stop()
	if _stt == null:
		return
	_stt.recording = false # stops the transcription thread (blocks briefly on thread.wait_to_finish())
	remove_child(_stt)
	_stt.queue_free()
	_stt = null

func _on_transcribed(_is_complete: bool, new_text: String) -> void:
	if not new_text.is_empty():
		_text_label.text = new_text
