extends Node

@onready var _camera: CameraController = $"../Camera3D"

var player_net_id: int = -1
var _last_intent   := Vector2.ZERO

func _process(_delta: float) -> void:
	if player_net_id == -1:
		return
	var intent := _get_intent()
	if intent != _last_intent:
		_last_intent = intent
		_send_intent(intent)

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
	if not (event is InputEventKey) or not event.pressed or event.echo or player_net_id == -1:
		return
	if event.keycode == KEY_1:
		Network.send(Protocol.pkt_cast(0))
	if event.keycode == KEY_SPACE:
		Network.send(Protocol.pkt_action(Protocol.ACTION_JUMP))

func _send_intent(dir: Vector2) -> void:
	if not Network.is_connected_to_server():
		return
	Network.send(Protocol.pkt_move_intent(dir))
