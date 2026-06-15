extends Node

@onready var _camera:    CameraController = $"../Camera3D"
@onready var _targeting                  = $"../Targeting"

var floor_items:   Node = null
var _last_intent   := Vector2.ZERO
var _last_yaw      := 0.0
var _e_held        := 0.0
const _YAW_THRESHOLD  := 0.1
const _PICKUP_HOLD    := 0.15

func _process(delta: float) -> void:
	if GameState.player_net_id == -1:
		return
	var intent := _get_intent()
	var yaw    := _camera.yaw
	if intent != _last_intent or absf(yaw - _last_yaw) >= _YAW_THRESHOLD:
		_last_intent = intent
		_last_yaw    = yaw
		_send_intent(intent, yaw)
	if Input.is_key_pressed(KEY_E) and floor_items != null:
		_e_held += delta
		if _e_held >= _PICKUP_HOLD:
			_e_held = -INF
			var item_id: int = _targeting.pick_aimed_item(floor_items._items)
			if item_id != -1:
				Network.send(Protocol.pkt_pickup(item_id))
	else:
		_e_held = 0.0

func _get_intent() -> Vector2:
	var x := float(int(Input.is_key_pressed(KEY_D)) - int(Input.is_key_pressed(KEY_A)))
	var z := float(int(Input.is_key_pressed(KEY_S)) - int(Input.is_key_pressed(KEY_W)))
	var yaw: float = _camera.yaw
	var forward := Vector2(-sin(yaw), -cos(yaw))
	var right   := Vector2( cos(yaw), -sin(yaw))
	var dir := forward * (-z) + right * x
	if dir.length_squared() > 0.0:
		dir = dir.normalized()
	return dir

func _input(event: InputEvent) -> void:
	if GameState.player_net_id == -1:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		Network.send(Protocol.pkt_action(Protocol.ACTION_REQ_ATTACK))
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if Input.is_key_pressed(KEY_E):
		match event.keycode:
			KEY_1:
				Network.send(Protocol.pkt_slot_swap(Protocol.SLOT_MAINHAND, Protocol.SLOT_OFFHAND))
				return
			KEY_2:
				Network.send(Protocol.pkt_slot_swap(Protocol.SLOT_MAINHAND, Protocol.SLOT_OFFHAND))
				return
			KEY_3:
				Network.send(Protocol.pkt_slot_swap(Protocol.SLOT_MAINHAND, Protocol.SLOT_HEADGEAR))
				return
			KEY_4:
				Network.send(Protocol.pkt_slot_swap(Protocol.SLOT_MAINHAND, Protocol.SLOT_ARMOR))
				return
			KEY_TAB:
				Network.send(Protocol.pkt_slot_swap(Protocol.SLOT_MAINHAND, Protocol.SLOT_SHEATH))
				return
	if event.keycode == KEY_1:
		Network.send(Protocol.pkt_cast(0))
	if event.keycode == KEY_SPACE:
		Network.send(Protocol.pkt_action(Protocol.ACTION_REQ_JUMP))
	if event.keycode == KEY_G:
		Network.send(Protocol.pkt_action(Protocol.ACTION_REQ_DROP))

func _send_intent(dir: Vector2, rot_y: float) -> void:
	if not Network.is_connected_to_server():
		return
	Network.send(Protocol.pkt_move_intent(dir, rot_y))
