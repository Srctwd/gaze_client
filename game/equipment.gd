extends Node

const _SLOT_MAINHAND := 0

const _ITEM_MESHES := {
	Protocol.ITEM_STICK: preload("res://assets/stick.glb"),
}

const _HAND_POS := Vector3(0.45, 0.9, 0.1)
const _HAND_ROT := Vector3(0, 0, 90)

const _FP_POS := Vector3(0.45, -0.75, -0.6)
const _FP_ROT := Vector3(80, 1, 90)

@onready var _entity_manager: Node            = $"../EntityManager"
@onready var _camera:         CameraController = $"../Camera3D"

var _fp_weapon: Node3D
var _swinging: bool = false
var player_net_id: int = -1

func _ready() -> void:
	_fp_weapon = Node3D.new()
	_fp_weapon.position       = _FP_POS
	_fp_weapon.rotation_degrees = _FP_ROT
	_fp_weapon.visible        = _camera.first_person
	_camera.add_child(_fp_weapon)
	_camera.first_person_changed.connect(_on_first_person_changed)
	Network.equip_synced.connect(_on_equip_synced)
	Network.action_ok.connect(_on_action_ok)

func _on_action_ok(actor_id: int, _effect: int, _target_id: int, action_type: int) -> void:
	if action_type != Protocol.ACTION_ATTACK:
		return
	if actor_id != player_net_id:
		return
	if not _swinging and _fp_weapon.visible:
		_swing()

func _swing() -> void:
	_swinging = true
	var tween := create_tween()
	tween.tween_property(_fp_weapon, "rotation_degrees",
		_FP_ROT - Vector3(75, 0, 0), 0.12).set_ease(Tween.EASE_OUT)
	tween.tween_property(_fp_weapon, "rotation_degrees",
		_FP_ROT, 0.2).set_ease(Tween.EASE_IN)
	tween.tween_callback(func(): _swinging = false)

func _on_first_person_changed(fp: bool) -> void:
	_fp_weapon.visible = fp

func _on_equip_synced(net_id: int, slot: int, item_def_id: int) -> void:
	if slot != _SLOT_MAINHAND:
		return
	var scene: PackedScene = _ITEM_MESHES.get(item_def_id)

	if net_id == player_net_id:
		_set_hand_node(_fp_weapon, scene)
	else:
		var body := _entity_manager.entities.get(net_id) as StaticBody3D
		if body:
			_set_hand_node(_get_or_create_hand(body), scene)

func _set_hand_node(parent: Node3D, scene: PackedScene) -> void:
	for c in parent.get_children():
		c.queue_free()
	if scene:
		parent.add_child(scene.instantiate())

func _get_or_create_hand(body: StaticBody3D) -> Node3D:
	var hand := body.get_node_or_null("RightHand")
	if hand == null:
		hand = Node3D.new()
		hand.name             = "RightHand"
		hand.position         = _HAND_POS
		hand.rotation_degrees = _HAND_ROT
		body.add_child(hand)
	return hand
