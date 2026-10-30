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
const TALENT_SYNC        := 0x15
const LEARN_TALENT_REQUEST := 0x16
const FREE_AIM_SHOT        := 0x17
const CHAT_SAY             := 0x18
const PLAYER_CHAT          := 0x19
const NPC_SPEECH           := 0x1A
const DIALOG_OPTIONS       := 0x1B
const EQUIP_BAG_TOGGLE_REQUEST := 0x1C
const BAG_UNEQUIP_REQUEST      := 0x1D
const BAG_SLOT_SWAP_REQUEST    := 0x1E
const INSPECT_ITEM_REQUEST     := 0x1F
const INSPECT_ITEM_RESPONSE    := 0x20
const INTERACT_ENTITY          := 0x22
const CHEST_RESULT             := 0x23
const ACTION_WINDUP            := 0x24
const DELETE_CHARACTER_REQUEST  := 0x25
const DELETE_CHARACTER_RESPONSE := 0x26

# DeleteCharacterResponse results
const DELETE_OK        := 0
const DELETE_NOT_FOUND := 1  # not this account's character, or the login expired
const DELETE_IN_GAME   := 2  # someone is playing it right now
# ChestResult codes (ChestOpenResult, stone_gaze src/systems/chest.h)
const CHEST_OPENED         := 0
const CHEST_ALREADY_OPENED := 1
const CHEST_NO_ROOM        := 2

# ── Gear slots (must match GearSlot enum in inventory.h) ───────────────────
const SLOT_MAINHAND := 0
const SLOT_OFFHAND  := 1
const SLOT_HEADGEAR := 2
const SLOT_ARMOR    := 3
const SLOT_GLOVES   := 4
const SLOT_BOOTS    := 5
const SLOT_BAG      := 6
const SLOT_NECKLACE := 7
const SLOT_TRINKET  := 8
const SLOT_SHEATH   := 9
const SLOT_QUIVER   := 10
const SLOT_POUCH    := 11

# ── Item defs ──────────────────────────────────────────────────────────────
# Loaded at runtime from res://item_types.json (the server's single source of
# truth for item def ids) instead of being hardcoded here — see _load_item_types.
var item_defs: Dictionary = {}       # id (int) -> {name, slots, attack_style, damage, attack_speed_mult, two_handed, bag_capacity, container_category, max_stack, ammo_category, size, break_chance}
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
const UNIT_RAT       := 0x09
const UNIT_VALKYRIE  := 0x0A  # models.json "Valkyrie" on the server
const UNIT_CHEST     := 0x0B  # models.json "Chest" — a placed chest, never moves
const UNIT_CAVE_RAT  := 0x0C  # models.json "CaveRat"
const UNIT_FROZEN_STARLIGHT := 0x0D  # models.json "FrozenStarlight" — interaction only; world.bin's static object is what's drawn

# ── Locomotion animation state (AnimState enum, network/protocol.h) ────────
# Carried on SpawnUnit/UnitPos. Ground has no separate idle/walk/run signal —
# derive that from position delta between updates, same as movement.
const ANIM_GROUND := 0
const ANIM_JUMP   := 1
const ANIM_FALL   := 2
const ANIM_SWIM   := 3

# ── UnitPos orientation byte (pack_orient, network/protocol.h) ───────────
# Low 5 bits = yaw index (32 steps), high 3 bits = index into
# ORIENT_PITCH_LEVELS. Display only — shots use the exact floats server-side.
const ORIENT_YAW_STEPS := 32
const ORIENT_PITCH_LEVELS := [-1.0, -0.45, -0.15, 0.0, 0.15, 0.45, 1.0]

static func unpack_orient(orient: int) -> Vector2:
	var yaw := float(orient & 0x1F) * TAU / ORIENT_YAW_STEPS
	var pitch_index := mini(orient >> 5, ORIENT_PITCH_LEVELS.size() - 1)
	return Vector2(yaw, ORIENT_PITCH_LEVELS[pitch_index])

# ── Action types (ActionType enum) ────────────────────────────────────────
const ACTION_NOTHING := 0
const ACTION_JUMP    := 1
const ACTION_ATTACK  := 2
const ACTION_SPELL   := 3
const ACTION_ABILITY := 13  # actions.json ability — how monsters attack

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
const EFFECT_TELEPORT   := 0x05  # Blink/Translocate fired — no targets

func _ready() -> void:
	_load_item_types()

const _ITEM_PREFAB_DIR := "res://assets/items/"

# name (String) -> PackedScene, or null if no res://assets/items/<name>.tscn
# exists — cached both ways so a missing prefab is only checked on disk once.
var _item_prefab_cache: Dictionary = {}

# name (String) -> PackedScene, or null — the item prefab's own `projectile_scene`
# field, cached so effects.gd doesn't instantiate a whole ItemPrefab per shot.
var _item_projectile_cache: Dictionary = {}

# Parses res://item_types.json, the shared item def table also read by the server
# (src/systems/item_types.cpp) — a JSON array of objects, not the old line-
# based format. Adding a new server-side item requires no client changes
# here — only authoring res://assets/items/<Name>.tscn in the editor (see
# get_item_prefab).

func _load_item_types() -> void:
	var f := FileAccess.open("res://item_types.json", FileAccess.READ)
	if f == null:
		push_error("Protocol: failed to open res://item_types.json")
		return
	var text := f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Array):
		push_error("Protocol: res://item_types.json is not a JSON array")
		return

	for entry: Dictionary in parsed:
		var id: int = entry.get("id", -1)
		var item_name: String = entry.get("name", "")
		if id < 0 or item_name.is_empty():
			continue
		item_defs[id] = {
			"name":              item_name,
			"slots":             entry.get("slots", []),
			"attack_style":      entry.get("attack_style", "Melee"),
			"damage":            entry.get("damage", {}),  # element name -> amount, e.g. {"physical": 4.0}
			"attack_speed_mult": float(entry.get("attack_speed_mult", 1.0)),
			"two_handed":        entry.get("two_handed", false),
			"bag_capacity":      int(entry.get("bag_capacity", 0)),
			"container_category": entry.get("container_category", "None"),
			"max_stack":         int(entry.get("max_stack", 1)),
			"ammo_category":     entry.get("ammo_category", ""),
			"size":              entry.get("size", "Small"),
			"break_chance":      float(entry.get("break_chance", 0.0)),
		}
		item_id_by_name[item_name] = id
		item_name_by_id[id] = item_name

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

# Same layout as pkt_login — only valid at character select.
static func pkt_delete_character(token: String, char_id: int) -> PackedByteArray:
	var pkt := pkt_login(token, char_id)
	pkt[0] = DELETE_CHARACTER_REQUEST
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

static func pkt_interact_entity(net_id: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(5)
	pkt[0] = INTERACT_ENTITY
	pkt.encode_u32(1, net_id)
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

# (no payload) — server always moves MainHand's bag into the dedicated Bag slot.
static func pkt_equip_bag_toggle() -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(1)
	pkt[0] = EQUIP_BAG_TOGGLE_REQUEST
	return pkt

# (no payload) — server always moves the Bag slot's bag back into MainHand.
static func pkt_bag_unequip() -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(1)
	pkt[0] = BAG_UNEQUIP_REQUEST
	return pkt

# bag_slot is 0-8 (keys 1-9) — always the Bag-slot bag's own contents, never
# one currently held in MainHand/OffHand.
static func pkt_bag_slot_swap(bag_slot: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(2)
	pkt[0] = BAG_SLOT_SWAP_REQUEST
	pkt[1] = bag_slot
	return pkt

# gear_slot is a GearSlot index (e.g. SLOT_BAG/SLOT_QUIVER/SLOT_POUCH) —
# read-only, fires instantly server-side (doesn't cost an action slot).
static func pkt_inspect_item(gear_slot: int) -> PackedByteArray:
	var pkt := PackedByteArray()
	pkt.resize(2)
	pkt[0] = INSPECT_ITEM_REQUEST
	pkt[1] = gear_slot
	return pkt

static func pkt_chat_say(text: String) -> PackedByteArray:
	var text_bytes := text.to_utf8_buffer()
	var pkt := PackedByteArray()
	pkt.resize(2 + text_bytes.size())
	pkt[0] = CHAT_SAY
	pkt[1] = text_bytes.size()
	for i in text_bytes.size():
		pkt[2 + i] = text_bytes[i]
	return pkt

# ── Chat/dialog text markup ────────────────────────────────────────────────
# Shared by chat_input.gd's own "say" label and entity_manager.gd's NPC
# speech bubbles, so both render npcs.json's keyword convention identically
# (e.g. "Would you like to *Trade*?").

# Splits text on '*' pairs so odd-indexed segments ("*Trade*") can be drawn
# highlighted. Segments alternate plain/emphasis starting with plain; an
# unpaired trailing '*' just ends up emphasized like any other segment — not
# worth special-casing for dialog text that's always author-controlled.
static func split_emphasis(text: String) -> Array:
	var parts := text.split("*")
	var segments: Array = []
	for i in parts.size():
		if not parts[i].is_empty():
			segments.append({text = parts[i], emphasis = (i % 2) == 1})
	return segments

# Renders `text` as BBCode for a RichTextLabel, coloring emphasized segments
# with highlight_color (everything else is left to the label's own default
# text color). BBCode escaping is limited to '[' — chat/dialog text isn't
# run through any other markup engine downstream.
static func text_to_bbcode(text: String, highlight_color: Color) -> String:
	var bb := ""
	for seg: Dictionary in split_emphasis(text):
		var escaped: String = (seg.text as String).replace("[", "[lb]")
		if seg.emphasis:
			bb += "[color=#%s]%s[/color]" % [highlight_color.to_html(false), escaped]
		else:
			bb += escaped
	return bb
