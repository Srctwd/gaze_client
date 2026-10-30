extends Node

signal connected
signal disconnected
signal unit_spawned(net_id: int, unit_type: int, variant: int, pos: Vector3, anim_state: int, radius: float, height: float)
signal unit_pos(net_id: int, unit_type: int, variant: int, pos: Vector3, rot_y: float, pitch: float, anim_state: int)
signal time_of_day(game_seconds: float)
signal login_ok(net_id: int)
signal login_fail
signal action_ok(actor_id: int, effect: int, target_id: int, action_type: int)
signal action_windup(actor_id: int, action_type: int, windup: float)
signal unit_hit(target_id: int, attacker_id: int, count: int, absorbed: int, armored: int, defended: int)
signal unit_destroyed(net_id: int)
signal unit_resized(net_id: int, radius: float, height: float)
signal vital_update(net_id: int, hp: float, max_hp: float, mana: float, max_mana: float)
signal floor_item_spawned(net_id: int, def_id: int, quantity: int, pos: Vector3, contents: Array)
signal floor_item_destroyed(net_id: int)
signal equip_synced(net_id: int, slot: int, item_def_id: int, quantity: int)
signal xp_gained(monster_net_id: int, player_ids: Array)
signal level_up(net_id: int, new_level: int)
signal talent_synced(points_available: int, learned: Array)
signal free_aim_shot(actor_id: int, origin: Vector3, yaw: float, pitch: float, speed: float, max_range: float, effect: int)
signal player_chat(player_net_id: int, text: String)
signal npc_speech(npc_net_id: int, target_player_net_id: int, text: String)
signal dialog_options(npc_net_id: int, options: Array)
signal item_inspected(container_def_id: int, contents: Array)
signal chest_result(chest_net_id: int, result: int)
signal character_deleted(result: int)

const HOST     = "stonegaze.link"
const PORT     = 7777
const CHANNELS = 2

var _host: ENetConnection
var _peer: ENetPacketPeer
# Set by logout() — the host only has one peer slot, so the fresh connection
# can't be opened until the old one's disconnect has actually completed.
var _reconnect_on_disconnect := false

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
				if _reconnect_on_disconnect:
					_reconnect_on_disconnect = false
					_peer = _host.connect_to_host(HOST, PORT, CHANNELS, 0)
			ENetConnection.EVENT_RECEIVE:
				var packet := (result[1] as ENetPacketPeer).get_packet()
				# A logged-out session keeps streaming UnitPos until the server
				# sees the disconnect; the reloaded scene would build those units
				# without their SpawnUnit (wrong body size, so sunk into the ground).
				if not _reconnect_on_disconnect:
					_parse(packet)

# Drops the session: the server despawns the player on peer disconnect (see
# sessions_disconnect in stone_gaze), then this reconnects so `connected`
# brings the login screen back.
func logout() -> void:
	if not is_connected_to_server():
		return
	_reconnect_on_disconnect = true
	_peer.peer_disconnect()
	_host.flush()

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
		0x01: # SpawnUnit: one SpawnUnitBatch record (servers before batching)
			_emit_unit_spawned(data, 1)
		0x02: # UnitPos: one UnitPosBatch record (servers before batching)
			_emit_unit_pos(data, 1)
		0x27: # SpawnUnitBatch: count(u8) [27-byte SpawnUnit record]×count
			for i in data[1]:
				_emit_unit_spawned(data, 2 + i * 27)
		0x28: # UnitPosBatch: count(u8) [20-byte UnitPos record]×count
			for i in data[1]:
				_emit_unit_pos(data, 2 + i * 20)
		0x29: # UnitSize: net_id(u32) radius(f32) height(f32) — a live unit's new body (Wild Growth)
			unit_resized.emit(data.decode_u32(1), data.decode_float(5), data.decode_float(9))
		0x04: # TimeOfDay: game_seconds(f32)
			time_of_day.emit(data.decode_float(1))
		0x06: # LoginResponse: status(u8) [net_id(u32)]
			if data[1] == 0:
				login_ok.emit(data.decode_u32(2))
			else:
				login_fail.emit()
		0x09: # ActionOk: actor(u32) effect(u8) action_type(u8) count(u8) [target(u32)×count]
			var _actor := data.decode_u32(1)
			var _effect := data[5]
			var _atype := data[6]
			var _count := data[7]
			if _count == 0:
				action_ok.emit(_actor, _effect, 0, _atype)
			else:
				for i in _count:
					action_ok.emit(_actor, _effect, data.decode_u32(8 + i * 4), _atype)
		0x21: # UnitHit: target(u32) attacker(u32, 0=unknown) count(u8) absorbed(u8) armored(u8) defended(u8) — no amounts, HP stays hidden
			unit_hit.emit(data.decode_u32(1), data.decode_u32(5), data[9], data[10], data[11], data[12])
		0x0B: # DestroyUnit: net_id(u32)
			unit_destroyed.emit(data.decode_u32(1))
		0x0C: # VitalUpdate: net_id(u32) hp max_hp mana max_mana (f32×4)
			vital_update.emit(data.decode_u32(1),
				data.decode_float(5), data.decode_float(9),
				data.decode_float(13), data.decode_float(17))
		0x0D: # SpawnFloorItem: net_id(u32) def_id(u8) quantity(u8) x y z (f32×3) [item_def_id(u8) quantity(u8)]×9 (container contents, def_id=0=empty)
			var _contents: Array = []
			for i in 9:
				_contents.append({def_id = data[19 + i * 2], quantity = data[19 + i * 2 + 1]})
			floor_item_spawned.emit(data.decode_u32(1), data[5], data[6],
				Vector3(data.decode_float(7), data.decode_float(11), data.decode_float(15)), _contents)
		0x0E: # DestroyFloorItem: net_id(u32)
			floor_item_destroyed.emit(data.decode_u32(1))
		0x10: # EquipSync: net_id(u32) slot(u8) item_def_id(u8) quantity(u8, 1 if not stackable)
			equip_synced.emit(data.decode_u32(1), data[5], data[6], data[7])
		0x12: # LevelUp: player_net_id(u32) new_level(u32)
			level_up.emit(data.decode_u32(1), data.decode_u32(5))
		0x11: # XpGain: monster_net_id(u32) count(u8) [player_net_id(u32)×count]
			var _monster_id := data.decode_u32(1)
			var _count := data[5]
			var _ids: Array = []
			for i in _count:
				_ids.append(data.decode_u32(6 + i * 4))
			xp_gained.emit(_monster_id, _ids)
		0x15: # TalentSync: points_available(u8) count(u8) [node_id(u8)]×count
			var _points := data[1]
			var _count  := data[2]
			var _learned: Array = []
			for i in _count:
				_learned.append(data[3 + i])
			talent_synced.emit(_points, _learned)
		0x17: # FreeAimShot: actor(u32) origin(f32×3) yaw(f32) pitch(f32) speed(f32) max_range(f32) effect(u8)
			free_aim_shot.emit(data.decode_u32(1),
				Vector3(data.decode_float(5), data.decode_float(9), data.decode_float(13)),
				data.decode_float(17), data.decode_float(21), data.decode_float(25), data.decode_float(29),
				data[33])
		0x19: # PlayerChat: player_net_id(u32) text(str: len(u8) + bytes)
			var _pc_len := data[5]
			player_chat.emit(data.decode_u32(1),
				data.slice(6, 6 + _pc_len).get_string_from_utf8())
		0x1A: # NpcSpeech: npc_net_id(u32) target_player_net_id(u32) text(str)
			var _ns_len := data[9]
			npc_speech.emit(data.decode_u32(1), data.decode_u32(5),
				data.slice(10, 10 + _ns_len).get_string_from_utf8())
		0x1B: # DialogOptions: npc_net_id(u32) count(u8) [option(str)]×count
			var _do_npc_id := data.decode_u32(1)
			var _do_count  := data[5]
			var _do_opts: Array = []
			var _do_offset := 6
			for i in _do_count:
				var _opt_len := data[_do_offset]
				_do_opts.append(data.slice(_do_offset + 1, _do_offset + 1 + _opt_len).get_string_from_utf8())
				_do_offset += 1 + _opt_len
			dialog_options.emit(_do_npc_id, _do_opts)
		0x20: # InspectItemResponse: container_def_id(u8) [item_def_id(u8) quantity(u8)]×9 — owning peer only
			var _container_def_id := data[1]
			var _inspect_contents: Array = []
			for i in 9:
				_inspect_contents.append({def_id = data[2 + i * 2], quantity = data[2 + i * 2 + 1]})
			item_inspected.emit(_container_def_id, _inspect_contents)
		0x23: # ChestResult: chest_net_id(u32) result(u8) — requesting peer only
			chest_result.emit(data.decode_u32(1), data[5])
		0x24: # ActionWindup: actor(u32) action_type(u8, ACTION_NOTHING = cancelled) windup(f32, seconds until it fires) — the hit itself still comes as ActionOk
			action_windup.emit(data.decode_u32(1), data[5], data.decode_float(6))
		0x26: # DeleteCharacterResponse: result(u8) — requesting peer only
			character_deleted.emit(data[1])

# SpawnUnit record at `o`: net_id(u32) unit_type(u8) variant(u8) x y z (f32×3) anim_state(u8) radius(f32) height(f32)
func _emit_unit_spawned(data: PackedByteArray, o: int) -> void:
	unit_spawned.emit(data.decode_u32(o), data[o + 4], data[o + 5],
		Vector3(data.decode_float(o + 6), data.decode_float(o + 10), data.decode_float(o + 14)), data[o + 18],
		data.decode_float(o + 19), data.decode_float(o + 23))

# UnitPos record at `o`: net_id(u32) unit_type(u8) variant(u8) x y z (f32×3) orient(u8) anim_state(u8)
func _emit_unit_pos(data: PackedByteArray, o: int) -> void:
	var orient := Protocol.unpack_orient(data[o + 18])
	unit_pos.emit(data.decode_u32(o), data[o + 4], data[o + 5],
		Vector3(data.decode_float(o + 6), data.decode_float(o + 10), data.decode_float(o + 14)),
		orient.x, orient.y, data[o + 19])

func is_connected_to_server() -> bool:
	return _peer != null and _peer.get_state() == ENetPacketPeer.STATE_CONNECTED
