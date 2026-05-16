extends Node

@onready var _camera:    CameraController = $"../Camera3D"
@onready var _targeting                  = $"../Targeting"

var player_net_id: int  = -1
var floor_items:   Node = null
var _last_intent   := Vector2.ZERO
var _last_yaw      := 0.0
const _YAW_THRESHOLD := 0.1  # ~6 degrees

func _process(_delta: float) -> void:
	if player_net_id == -1:
		return
	var intent := _get_intent()
	var yaw    := _camera.yaw
	if intent != _last_intent or absf(yaw - _last_yaw) >= _YAW_THRESHOLD:
		_last_intent = intent
		_last_yaw    = yaw
		_send_intent(intent, yaw)

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
	if player_net_id == -1:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		Network.send(Protocol.pkt_action(Protocol.ACTION_REQ_PUNCH))
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_1:
		Network.send(Protocol.pkt_cast(0))
	if event.keycode == KEY_SPACE:
		Network.send(Protocol.pkt_action(Protocol.ACTION_REQ_JUMP))
	if event.keycode == KEY_E and floor_items != null:
		var item_id: int = _targeting.pick_aimed_item(floor_items._items)
		if item_id != -1:
			Network.send(Protocol.pkt_pickup(item_id))

func _send_intent(dir: Vector2, rot_y: float) -> void:
	if not Network.is_connected_to_server():
		return
	Network.send(Protocol.pkt_move_intent(dir, rot_y))
