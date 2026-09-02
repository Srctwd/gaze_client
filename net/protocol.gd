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
const INTERACT_REQUEST   := 0x14
const TALENT_SYNC        := 0x15
const LEARN_TALENT_REQUEST := 0x16
const FREE_AIM_SHOT        := 0x17

# ── Gear slots (must match GearSlot enum in inventory.h) ───────────────────
const SLOT_MAINHAND := 0
const SLOT_OFFHAND  := 1
const SLOT_HEADGEAR := 2
const SLOT_ARMOR    := 3
const SLOT_SHEATH   := 9

# ── Item defs ──────────────────────────────────────────────────────────────
# Loaded at runtime from res://item_types (the server's single source of
# truth for item def ids) instead of being hardcoded here — see _load_item_types.
var item_defs: Dictionary = {}       # id (int) -> {name, slots, style, damage, speed}
var item_id_by_name: Dictionary = {} # name (String) -> id
var item_name_by_id: Dictionary = {} # id (int) -> name

# ── Unit types ─────────────────────────────────────────────────────────────
const UNIT_PLAYER    := 0x01
const UNIT_MINOTAUR  := 0x02
const UNIT_MINO_MAGE := 0x03
const UNIT_SLIME     := 0x04
const UNIT_SNAKE     := 0x05
const UNIT_GOBLIN    := 0x06
const UNIT_DEMON     := 0x07
const UNIT_NPC       := 0x08

# ── Locomotion animation state (AnimState enum, network/protocol.h) ────────
# Carried on SpawnUnit/UnitPos. Ground has no separate idle/walk/run signal —
# derive that from position delta between updates, same as movement.
const ANIM_GROUND := 0
const ANIM_JUMP   := 1
const ANIM_FALL   := 2
const ANIM_SWIM   := 3

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
const EFFECT_SWING      := 0x00
const EFFECT_LIGHTNING  := 0x01
const EFFECT_PROJECTILE := 0x02
const EFFECT_FLAME      := 0x03
const EFFECT_FIREBALL   := 0x04

func _ready() -> void:
	_load_item_types()

const _ITEM_PREFAB_DIR := "res://assets/items/"

# name (String) -> PackedScene, or null if no res://assets/items/<name>.tscn
# exists — cached both ways so a missing prefab is only checked on disk once.
var _item_prefab_cache: Dictionary = {}

# name (String) -> PackedScene, or null — the item prefab's own `projectile_scene`
# field, cached so effects.gd doesn't instantiate a whole ItemPrefab per shot.
var _item_projectile_cache: Dictionary = {}

# Parses res://item_types, the shared item def table also read by the server
# (src/systems/item_types.cpp). Adding a new server-side item requires no
# client changes here — only authoring res://assets/items/<Name>.tscn in the
# editor (see get_item_prefab).

func _load_item_types() -> void:
	var f := FileAccess.open("res://item_types", FileAccess.READ)
	if f == null:
		push_error("Protocol: failed to open res://item_types")
		return
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var fields: Array = line.split(" ", false)
		if fields.size() < 6:
			continue
		var id := int(fields[0])
		var item_name: String = fields[1]
		item_defs[id] = {
			"name":   item_name,
			"slots":  fields[2].split(","),
			"style":  fields[3],
			"damage": float(fields[4]),
			"speed":  float(fields[5]),
		}
		item_id_by_name[item_name] = id
		item_name_by_id[id] = item_name
	f.close()

func item_id(item_name: String) -> int:
	return item_id_by_name.get(item_name, -1)

# The single source for an item's visuals: res://assets/items/<name>.tscn,
# an ItemPrefab scene authored in the editor (model + grip point + optional
# projectile/attack animation, transform baked in). No file for that name =
# null, and callers must render nothing rather than fall back to a raw mesh.
func get_item_prefab(item_name: String) -> PackedScene:
	if item_name.is_empty():
		return null
	if _item_prefab_cache.has(item_name):
		return _item_prefab_cache[item_name]
	var path := _ITEM_PREFAB_DIR + item_name + ".tscn"
	var prefab: PackedScene = load(path) if ResourceLoader.exists(path) else null
	_item_prefab_cache[item_name] = prefab
	return prefab

# The ranged visual an item fires when attacking at range (e.g. an arrow, a
# thrown dagger, a staff's energy bolt) — read from that item's own prefab,
# not hardcoded per weapon. Null if the item has no prefab, or is melee-only.
func get_item_projectile_scene(item_name: String) -> PackedScene:
	if item_name.is_empty():
		return null
	if _item_projectile_cache.has(item_name):
		return _item_projectile_cache[item_name]
	var projectile: PackedScene = null
	var prefab := get_item_prefab(item_name)
	if prefab != null:
		var inst := prefab.instantiate()
		if inst is ItemPrefab:
			projectile = (inst as ItemPrefab).projectile_scene
		inst.free()
	_item_projectile_cache[item_name] = projectile
	return projectile

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

static func pkt_move_intent(dir: Vector2, rot_y: float, pitch: float) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(17)
	pkt[0] = MOVE_INTENT
	pkt.encode_float(1, dir.x)
	pkt.encode_float(5, dir.y)
	pkt.encode_float(9, rot_y)
	pkt.encode_float(13, pitch)
	return pkt

static func pkt_target(net_id: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(5)
	pkt[0] = TARGET_REQUEST
	pkt.encode_u32(1, net_id)
	return pkt

static func pkt_cast(slot: int, target_net_id: int = 0) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(6)
	pkt[0] = CAST_REQUEST
	pkt[1] = slot
	pkt.encode_u32(2, target_net_id)
	return pkt


static func pkt_pickup(net_id: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(5)
	pkt[0] = PICKUP_REQUEST
	pkt.encode_u32(1, net_id)
	return pkt

static func pkt_interact(obj_type: int, x: float, z: float) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(10)
	pkt[0] = INTERACT_REQUEST
	pkt[1] = obj_type
	pkt.encode_float(2, x)
	pkt.encode_float(6, z)
	return pkt

static func pkt_learn_talent(node_id: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(2)
	pkt[0] = LEARN_TALENT_REQUEST
	pkt[1] = node_id
	return pkt

static func pkt_action(action_type: int, target_net_id: int = 0) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(6)
	pkt[0] = ACTION_REQUEST
	pkt[1] = action_type
	pkt.encode_u32(2, target_net_id)
	return pkt

static func pkt_slot_swap(slot_a: int, slot_b: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(3)
	pkt[0] = SLOT_SWAP_REQUEST
	pkt[1] = slot_a
	pkt[2] = slot_b
	return pkt
