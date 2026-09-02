extends Node

@onready var _camera:         CameraController = $"../Camera3D"
@onready var _targeting                       = $"../Targeting"
@onready var _entity_manager: Node             = $"../EntityManager"
@onready var _terrain:        Node3D           = $"../Terrain"

var floor_items:      Node = null
var talent_tree_ui:   Node = null
var _last_intent   := Vector2.ZERO
var _last_yaw      := 0.0
var _last_pitch    := 0.0
var _e_held        := 0.0
const _YAW_THRESHOLD  := 0.033
const _PICKUP_HOLD    := 0.15
const _INTERACT_RANGE := 3.0
const _PICKUP_RANGE   := 3.0
const OBJ_TYPE_FROZENSTARLIGHT := 2

func _process(delta: float) -> void:
	if GameState.player_net_id == -1 or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or GameState.chat_typing:
		return
	var intent := _get_intent()
	var yaw    := _camera.yaw
	var pitch  := _camera.pitch
	if intent != _last_intent or absf(yaw - _last_yaw) >= _YAW_THRESHOLD \
			or absf(pitch - _last_pitch) >= _YAW_THRESHOLD:
		_last_intent = intent
		_last_yaw    = yaw
		_last_pitch  = pitch
		_send_intent(intent, yaw, pitch)
	if Input.is_key_pressed(KEY_E):
		_e_held += delta
		if _e_held >= _PICKUP_HOLD:
			_e_held = -INF
			var item_id: int = -1
			if floor_items != null:
				item_id = _targeting.pick_aimed_item(floor_items._items)
				if item_id != -1 and not _is_item_in_pickup_range(item_id):
					item_id = -1
			if item_id != -1:
				Network.send(Protocol.pkt_pickup(item_id))
			else:
				_try_interact_frozenstarlight()
	else:
		_e_held = 0.0

func _is_item_in_pickup_range(item_id: int) -> bool:
	if not _entity_manager.entities.has(GameState.player_net_id):
		return false
	var player_pos: Vector3 = (_entity_manager.entities[GameState.player_net_id] as StaticBody3D).position
	var item_node := floor_items._items.get(item_id) as Node3D
	if item_node == null:
		return false
	return player_pos.distance_to(item_node.position) <= _PICKUP_RANGE

func _try_interact_frozenstarlight() -> void:
	if _terrain == null or not _entity_manager.entities.has(GameState.player_net_id):
		return
	var player_pos: Vector3 = (_entity_manager.entities[GameState.player_net_id] as StaticBody3D).position
	var obj: Variant = _terrain.nearest_static_object(player_pos, OBJ_TYPE_FROZENSTARLIGHT, _INTERACT_RANGE)
	if obj == null:
		return
	if talent_tree_ui != null:
		talent_tree_ui.expect_open()
	Network.send(Protocol.pkt_interact(OBJ_TYPE_FROZENSTARLIGHT, obj.x, obj.z))

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
	if GameState.player_net_id == -1 or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or GameState.chat_typing:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# Force a fresh aim sync right before firing — MoveIntent is normally rate-limited
		# by _YAW_THRESHOLD, so a small look adjustment just before the click could
		# otherwise leave the server's known aim slightly stale for this exact shot.
		_last_intent = _get_intent()
		_last_yaw    = _camera.yaw
		_last_pitch  = _camera.pitch
		_send_intent(_last_intent, _last_yaw, _last_pitch)

		var aimed_id: int = _targeting.pick_aimed_unit()
		Network.send(Protocol.pkt_action(Protocol.ACTION_REQ_ATTACK, aimed_id if aimed_id != -1 else 0))
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
		var aimed_id: int = _targeting.pick_aimed_unit()
		Network.send(Protocol.pkt_cast(0, aimed_id if aimed_id != -1 else 0))
	if event.keycode == KEY_2:
		Network.send(Protocol.pkt_cast(1, 0))
	if event.keycode == KEY_SPACE:
		Network.send(Protocol.pkt_action(Protocol.ACTION_REQ_JUMP))
	if event.keycode == KEY_G:
		Network.send(Protocol.pkt_action(Protocol.ACTION_REQ_DROP))

func _send_intent(dir: Vector2, rot_y: float, pitch: float) -> void:
	if not Network.is_connected_to_server():
		return
	Network.send(Protocol.pkt_move_intent(dir, rot_y, pitch))

# Force-sends a zero move intent so the server stops the player immediately —
# used when chat typing opens, since _process() stops sending updates at all
# while GameState.chat_typing is true, and whatever intent was last sent
# (e.g. still holding W) would otherwise keep the player moving server-side.
func stop_movement() -> void:
	_last_intent = Vector2.ZERO
	_last_yaw    = _camera.yaw
	_last_pitch  = _camera.pitch
	_send_intent(_last_intent, _last_yaw, _last_pitch)
