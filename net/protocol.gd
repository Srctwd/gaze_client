extends Node

# ── Opcodes ────────────────────────────────────────────────────────────────
const SPAWN_UNIT     := 0x01
const UNIT_POS       := 0x02
const MOVE_INTENT    := 0x03
const TIME_OF_DAY    := 0x04
const LOGIN_REQUEST  := 0x05
const LOGIN_RESPONSE := 0x06
const TARGET_REQUEST := 0x07
const CAST_REQUEST   := 0x08
const CAST_OK        := 0x09
const ACTION_REQUEST := 0x0A
const DESTROY_UNIT   := 0x0B
const VITAL_UPDATE   := 0x0C

# ── Unit types ─────────────────────────────────────────────────────────────
const UNIT_PLAYER    := 0x01
const UNIT_MINOTAUR  := 0x02
const UNIT_MINO_MAGE := 0x03

# ── Action types ───────────────────────────────────────────────────────────
const ACTION_JUMP    := 0x01

# ── Packet builders (client → server) ─────────────────────────────────────
static func pkt_login(token: String, char_id: int) -> PackedByteArray:
	var token_bytes := token.to_utf8_buffer()
	var pkt := PackedByteArray()
	pkt.resize(2 + token_bytes.size() + 4)
	pkt[0] = LOGIN_REQUEST
	pkt[1] = token_bytes.size()
	for i in token_bytes.size():
		pkt[2 + i] = token_bytes[i]
	pkt.encode_u32(2 + token_bytes.size(), char_id)
	return pkt

static func pkt_move_intent(dir: Vector2) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(9)
	pkt[0] = MOVE_INTENT
	pkt.encode_float(1, dir.x)
	pkt.encode_float(5, dir.y)
	return pkt

static func pkt_target(net_id: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(5)
	pkt[0] = TARGET_REQUEST
	pkt.encode_u32(1, net_id)
	return pkt

static func pkt_cast(slot: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(2)
	pkt[0] = CAST_REQUEST
	pkt[1] = slot
	return pkt

static func pkt_action(action_type: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(2)
	pkt[0] = ACTION_REQUEST
	pkt[1] = action_type
	return pkt
