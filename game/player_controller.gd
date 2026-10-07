extends Node

@onready var _camera:         CameraController = $"../Camera3D"
@onready var _targeting                       = $"../Targeting"
@onready var _entity_manager: Node             = $"../EntityManager"
@onready var _terrain:        Node3D           = $"../Terrain"

var floor_items:      Node = null
var talent_tree_ui:   Node = null
var equipment:        Node = null  # set externally; used to tell E+B which direction to toggle
var _last_intent   := Vector2.ZERO
var _last_yaw      := 0.0
var _last_pitch    := 0.0
var _e_held        := 0.0
const _YAW_THRESHOLD  := 0.033
const _PICKUP_HOLD    := 0.15
const _INTERACT_RANGE := 3.0
const _PICKUP_RANGE   := 3.0
const OBJ_TYPE_FROZENSTARLIGHT := 2

const _BAG_DIGIT_KEYS := {
	KEY_1: 0, KEY_2: 1, KEY_3: 2, KEY_4: 3, KEY_5: 4,
	KEY_6: 5, KEY_7: 6, KEY_8: 7, KEY_9: 8,
}

# Shift alone inspects every container slot you're wearing (server no-ops
# for whichever aren't holding one); Shift+left-click inspects whatever
# floor item is aimed at (same targeting as E-hold pickup) using data
# already delivered in SpawnFloorItem — no round trip needed for that one.
const _INSPECT_SLOTS := [Protocol.SLOT_BAG, Protocol.SLOT_QUIVER, Protocol.SLOT_POUCH]

func _ready() -> void:
	Network.item_inspected.connect(_on_item_inspected)

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
		if Input.is_key_pressed(KEY_SHIFT):
			_inspect_world_aim()
			return
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
			KEY_5:
				Network.send(Protocol.pkt_slot_swap(Protocol.SLOT_MAINHAND, Protocol.SLOT_POUCH))
				return
			KEY_TAB:
				Network.send(Protocol.pkt_slot_swap(Protocol.SLOT_MAINHAND, Protocol.SLOT_SHEATH))
				return
			KEY_B:
				# Same combo either direction, like the other E+<slot> swaps above —
				# an empty MainHand means the bag (if any) is already stowed in the
				# Bag slot, so this toggle brings it back instead of trying (and
				# silently failing server-side) to stow an empty hand again.
				var mainhand_item: int = equipment.get_mainhand_item(GameState.player_net_id) if equipment != null else -1
				if mainhand_item <= 0:
					Network.send(Protocol.pkt_bag_unequip())
				else:
					Network.send(Protocol.pkt_equip_bag_toggle())
				return
	if Input.is_key_pressed(KEY_B) and _BAG_DIGIT_KEYS.has(event.keycode):
		Network.send(Protocol.pkt_bag_slot_swap(_BAG_DIGIT_KEYS[event.keycode]))
		return
	if event.keycode == KEY_SHIFT:
		_inspect_own_gear()
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

# Asks the server what's in every container slot worn right now — it
# silently no-ops (no response) for any slot that isn't holding one, so
# firing all three blind is simpler than tracking which ones are equipped.
func _inspect_own_gear() -> void:
	for slot in _INSPECT_SLOTS:
		Network.send(Protocol.pkt_inspect_item(slot))

func _on_item_inspected(container_def_id: int, contents: Array) -> void:
	var container_name: String = Protocol.item_name_by_id.get(container_def_id, "?")
	print("[inspect] %s: %s" % [container_name, _format_contents(contents)])

# No server round trip — a floor container's contents already arrived with
# its SpawnFloorItem (see floor_items.gd), same as its position/model.
func _inspect_world_aim() -> void:
	if floor_items == null:
		return
	var item_id: int = _targeting.pick_aimed_item(floor_items._items)
	if item_id == -1 or not _is_item_in_pickup_range(item_id):
		return
	var data: Dictionary = floor_items.get_item_data(item_id)
	if data.is_empty():
		return
	var item_name: String = Protocol.item_name_by_id.get(data.def_id, "?")
	print("[inspect] %s on the ground: %s" % [item_name, _format_contents(data.contents)])

# Formats a container's 9 {def_id, quantity} slots into a player-readable
# list — quantity shown in brackets only for stackable items (max_stack > 1
# in item_types), matching the resume's example ("Arrow [4]" vs plain "Sword").
func _format_contents(contents: Array) -> String:
	var parts: Array = []
	for slot: Dictionary in contents:
		var def_id: int = slot.def_id
		if def_id == 0:
			continue
		var item_name: String = Protocol.item_name_by_id.get(def_id, "?")
		var max_stack: int = Protocol.item_defs.get(def_id, {}).get("max_stack", 1)
		parts.append("%s [%d]" % [item_name, slot.quantity] if max_stack > 1 else item_name)
	return ", ".join(parts) if not parts.is_empty() else "(empty)"
