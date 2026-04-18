class_name CameraController
extends Camera3D

signal first_person_changed(enabled: bool)

var target:       Vector3 = Vector3.ZERO
var yaw:          float   = 0.0
var pitch:        float   = -0.5
var distance:     float   = 12.0
var first_person: bool    = false

const MOUSE_SENSITIVITY: float = 0.005
const ZOOM_SPEED:        float = 1.5
const ZOOM_MIN:          float = 3.0
const ZOOM_MAX:          float = 40.0
const PITCH_MIN:         float = -1.4
const PITCH_MAX:         float = -0.05
const PITCH_FP_MIN:      float = -1.5
const PITCH_FP_MAX:      float =  1.5

func _ready() -> void:
	_apply()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_F \
			and event.pressed and not event.echo:
		first_person = not first_person
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if first_person \
						 else Input.MOUSE_MODE_VISIBLE
		first_person_changed.emit(first_person)
		_apply()
		return

	if event is InputEventMouseMotion \
			and (first_person or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)):
		yaw   -= event.relative.x * MOUSE_SENSITIVITY
		pitch  = clamp(pitch - event.relative.y * MOUSE_SENSITIVITY,
				PITCH_FP_MIN if first_person else PITCH_MIN,
				PITCH_FP_MAX if first_person else PITCH_MAX)
		_apply()

	if not first_person and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = max(ZOOM_MIN, distance - ZOOM_SPEED)
			_apply()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = min(ZOOM_MAX, distance + ZOOM_SPEED)
			_apply()

func follow(pos: Vector3) -> void:
	target = pos
	_apply()

func _apply() -> void:
	if first_person:
		position = target + Vector3(0, 1.7, 0)
		look_at(position + Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)),
				Vector3.UP)
	else:
		position = target + Vector3(sin(yaw), -sin(pitch), cos(yaw)) * cos(pitch) * distance
		look_at(target, Vector3.UP)
