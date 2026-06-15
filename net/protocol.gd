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
const ACTION_OK      := 0x09
const ACTION_REQUEST := 0x0A
const DESTROY_UNIT       := 0x0B
const VITAL_UPDATE       := 0x0C
const SPAWN_FLOOR_ITEM   := 0x0D
const DESTROY_FLOOR_ITEM := 0x0E
const PICKUP_REQUEST     := 0x0F
const EQUIP_SYNC         := 0x10
const XP_GAIN            := 0x11
const LEVEL_UP           := 0x12
const SLOT_SWAP_REQUEST  := 0x13

# ── Gear slots (must match GearSlot enum in inventory.h) ───────────────────
const SLOT_MAINHAND := 0
const SLOT_OFFHAND  := 1
const SLOT_HEADGEAR := 2
const SLOT_ARMOR    := 3
const SLOT_SHEATH   := 9

# ── Item defs ──────────────────────────────────────────────────────────────
const ITEM_STICK                := 1
const ITEM_ROUGH_LEATHER_HELMET := 2

# ── Unit types ─────────────────────────────────────────────────────────────
const UNIT_PLAYER    := 0x01
const UNIT_MINOTAUR  := 0x02
const UNIT_MINO_MAGE := 0x03
const UNIT_SLIME     := 0x04
const UNIT_SNAKE     := 0x05
const UNIT_GOBLIN    := 0x06

# ── Action types (ActionType enum) ────────────────────────────────────────
const ACTION_NOTHING := 0
const ACTION_JUMP    := 1
const ACTION_ATTACK  := 2
const ACTION_SPELL   := 3

# ── Action request opcodes (client → server) ───────────────────────────────
const ACTION_REQ_JUMP   := 0x01  # ActionType::Jump
const ACTION_REQ_ATTACK := 0x02  # ActionType::Attack
const ACTION_REQ_DROP   := 0x07  # ActionType::Drop

# ── Effect types ───────────────────────────────────────────────────────────
const EFFECT_LIGHTNING  := 0x01
const EFFECT_PROJECTILE := 0x02

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

static func pkt_move_intent(dir: Vector2, rot_y: float) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(13)
	pkt[0] = MOVE_INTENT
	pkt.encode_float(1, dir.x)
	pkt.encode_float(5, dir.y)
	pkt.encode_float(9, rot_y)
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


static func pkt_pickup(net_id: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(5)
	pkt[0] = PICKUP_REQUEST
	pkt.encode_u32(1, net_id)
	return pkt

static func pkt_action(action_type: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(2)
	pkt[0] = ACTION_REQUEST
	pkt[1] = action_type
	return pkt

static func pkt_slot_swap(slot_a: int, slot_b: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(3)
	pkt[0] = SLOT_SWAP_REQUEST
	pkt[1] = slot_a
	pkt[2] = slot_b
	return pkt
