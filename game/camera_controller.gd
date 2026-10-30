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
# First-person eye vs world geometry: server collision is a sphere at the
# feet, so on a sloping cave wall or under a low ceiling the head bone — and
# the camera on it — can end up inside rock, and the near plane cuts it away.
const COLLISION_LAYER_WORLD := 2      # matches WorldData.COLLISION_LAYER_WORLD
const EYE_FRACTION:      float = 0.93 # fallback eye height, as a share of the body's full height
const EYE_MARGIN:        float = 0.15 # kept between the eye and rock; > the near plane's half-size
# The local player's server body (entity_manager.player_body_changed): a sphere
# of body_radius at the feet, reaching body_height above its centre.
var body_radius := 0.5
var body_height := 1.0

func _ready() -> void:
	_hud = load("res://ui/hud.gd").new()
	add_child(_hud)
	add_child(load("res://game/viewmodel.gd").new())

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
func set_body(radius: float, height: float) -> void:
	body_radius = radius
	body_height = height

func follow_head(pos: Vector3) -> void:
	head_target = pos
	_has_head = true
	if first_person:
		_apply()

func _apply() -> void:
	if first_person:
		var look := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
		position = _clear_eye(head_target if _has_head else target + Vector3(0, (body_radius + body_height) * EYE_FRACTION, 0), look)
		look_at(position + look, Vector3.UP)
	else:
		position = target + Vector3(sin(yaw), -sin(pitch), cos(yaw)) * cos(pitch) * distance
		look_at(target, Vector3.UP)


# `eye`, pulled back so it stays EYE_MARGIN clear of world geometry, in three
# rays: up the body's axis from its collision sphere centre (which the server
# keeps out of rock) to eye height — a low ceiling lowers the eye; then from
# there out to the head bone's offset — a wall in front pushes the eye back
# without lowering it; then along the view direction. Rays, not shape casts,
# because they also hit back faces — cave ceilings are trimeshes facing into
# the rock, i.e. away from someone standing in the cave.
func _clear_eye(eye: Vector3, look: Vector3) -> Vector3:
	if not is_inside_tree():
		return eye
	var space := get_world_3d().direct_space_state
	var from := target + Vector3(0, body_radius, 0)
	var axis := Vector3(target.x, maxf(eye.y, from.y), target.z)
	var hit := _world_ray(space, from, axis + Vector3.UP * EYE_MARGIN)
	if not hit.is_empty():
		axis.y = maxf((hit.position as Vector3).y - EYE_MARGIN, from.y)
	var head := Vector3(eye.x, axis.y, eye.z)
	var out := head - axis
	if out.length() > 0.001:
		var dir := out.normalized()
		hit = _world_ray(space, axis, head + dir * EYE_MARGIN)
		if not hit.is_empty():
			head = axis + dir * maxf(axis.distance_to(hit.position) - EYE_MARGIN, 0.0)
	eye = head
	var ahead := _world_ray(space, eye, eye + look * EYE_MARGIN)
	if not ahead.is_empty():
		eye = (ahead.position as Vector3) - look * EYE_MARGIN
	return eye


func _world_ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, COLLISION_LAYER_WORLD)
	q.hit_back_faces = true
	return space.intersect_ray(q)
