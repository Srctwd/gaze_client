class_name CameraController
extends Camera3D

var target:       Vector3 = Vector3.ZERO
var head_target:  Vector3 = Vector3.ZERO
var _has_head:    bool    = false
var yaw:          float   = 0.0
var pitch:        float   = -0.5
var distance:     float   = 12.0
var first_person: bool    = true

var _hud: CanvasLayer

var mouse_sensitivity: float = 0.005
const ZOOM_SPEED:        float = 1.5
const ZOOM_MIN:          float = 3.0
const ZOOM_MAX:          float = 40.0
const PITCH_MIN:         float = -1.4
const PITCH_MAX:         float = -0.05
const PITCH_FP_MIN:      float = -1.5
const PITCH_FP_MAX:      float =  1.5

func _ready() -> void:
	_hud = load("res://ui/hud.gd").new()
	add_child(_hud)

	GameState.first_person = first_person

func show_hud() -> void: _hud.show_bars()
func hide_hud() -> void: _hud.hide_bars()

func set_health(ratio: float, max_val: float = 100.0) -> void:
	_hud.set_health(ratio, max_val)

func set_mana(ratio: float, max_val: float = 100.0) -> void:
	_hud.set_mana(ratio, max_val)

func set_underwater(val: bool) -> void:
	_hud.set_underwater(val)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and (first_person or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)):
		yaw   -= event.relative.x * mouse_sensitivity
		pitch  = clamp(pitch - event.relative.y * mouse_sensitivity,
				PITCH_FP_MIN if first_person else PITCH_MIN,
				PITCH_FP_MAX if first_person else PITCH_MAX)
		_apply()


func follow(pos: Vector3) -> void:
	target = pos
	_apply()

# Called with the local player's Head Marker3D world position (tracks the
# actual head bone, including animation bob) whenever the model provides one
# — falls back to a fixed eye-height offset from `target` otherwise.
func follow_head(pos: Vector3) -> void:
	head_target = pos
	_has_head = true
	if first_person:
		_apply()

func _apply() -> void:
	if first_person:
		position = head_target if _has_head else target + Vector3(0, 1.7, 0)
		look_at(position + Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)),
				Vector3.UP)
	else:
		position = target + Vector3(sin(yaw), -sin(pitch), cos(yaw)) * cos(pitch) * distance
		look_at(target, Vector3.UP)
