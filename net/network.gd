extends Node

signal connected
signal disconnected
signal unit_spawned(net_id: int, unit_type: int, variant: int, pos: Vector3)
signal unit_pos(net_id: int, pos: Vector3, rot_y: float)
signal time_of_day(game_seconds: float)
signal login_ok(net_id: int)
signal login_fail
signal cast_ok(actor_id: int, effect: int, target_id: int, spell_type: int)
signal unit_destroyed(net_id: int)
signal vital_update(net_id: int, hp: float, max_hp: float, mana: float, max_mana: float)

const HOST     = "127.0.0.1"
const PORT     = 7777
const CHANNELS = 2

var _host: ENetConnection
var _peer: ENetPacketPeer

func _ready() -> void:
	_host = ENetConnection.new()
	if _host.create_host(1, CHANNELS) != OK:
		push_error("Network: failed to create ENet host")
		return
	_peer = _host.connect_to_host(HOST, PORT, CHANNELS, 0)

func _process(_delta: float) -> void:
	if _host == null:
		return
	while true:
		var result  := _host.service(0)
		match result[0]:
			ENetConnection.EVENT_NONE:      break
			ENetConnection.EVENT_CONNECT:   connected.emit()
			ENetConnection.EVENT_DISCONNECT:
				_peer = null
				disconnected.emit()
			ENetConnection.EVENT_RECEIVE:
				_parse((result[1] as ENetPacketPeer).get_packet())

func send(data: PackedByteArray, channel: int = 0,
		flags: int = ENetPacketPeer.FLAG_RELIABLE) -> void:
	if not is_connected_to_server():
		return
	_peer.send(channel, data, flags)
	_host.flush()

func _parse(data: PackedByteArray) -> void:
	if data.is_empty():
		return
	match data[0]:
		0x01: # SpawnUnit: net_id(u32) unit_type(u8) variant(u8) x y z (f32×3)
			unit_spawned.emit(data.decode_u32(1), data[5], data[6],
				Vector3(data.decode_float(7), data.decode_float(11), data.decode_float(15)))
		0x02: # UnitPos: net_id(u32) x y z rot_y (f32×4)
			unit_pos.emit(data.decode_u32(1),
				Vector3(data.decode_float(5), data.decode_float(9), data.decode_float(13)),
				data.decode_float(17))
		0x04: # TimeOfDay: game_seconds(f32)
			time_of_day.emit(data.decode_float(1))
		0x06: # LoginResponse: status(u8) [net_id(u32)]
			if data[1] == 0:
				login_ok.emit(data.decode_u32(2))
			else:
				login_fail.emit()
		0x09: # CastOk: actor(u32) effect(u8) target(u32) spell_type(u8)
			cast_ok.emit(data.decode_u32(1), data[5], data.decode_u32(6), data[10])
		0x0B: # DestroyUnit: net_id(u32)
			unit_destroyed.emit(data.decode_u32(1))
		0x0C: # VitalUpdate: net_id(u32) hp max_hp mana max_mana (f32×4)
			vital_update.emit(data.decode_u32(1),
				data.decode_float(5), data.decode_float(9),
				data.decode_float(13), data.decode_float(17))

func is_connected_to_server() -> bool:
	return _peer != null and _peer.get_state() == ENetPacketPeer.STATE_CONNECTED
