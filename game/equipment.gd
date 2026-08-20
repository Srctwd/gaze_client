extends Node

const _HAND_POS := Vector3(0.45, 0.9, 0.1)
const _HAND_ROT := Vector3(0, 0, 90)
const _OFFHAND_POS := Vector3(-0.45, 0.9, 0.1)
const _OFFHAND_ROT := Vector3(0, 0, -90)
const _HEAD_POS := Vector3(0, 1.7, 0)

@onready var _entity_manager: Node = $"../EntityManager"

var _mainhand: Dictionary = {}  # net_id -> item_def_id currently equipped in SLOT_MAINHAND

func _ready() -> void:
	Network.equip_synced.connect(_on_equip_synced)

func get_mainhand_item(net_id: int) -> int:
	return _mainhand.get(net_id, -1)

func _on_equip_synced(net_id: int, slot: int, item_def_id: int) -> void:
	if slot == Protocol.SLOT_MAINHAND:
		_mainhand[net_id] = item_def_id

	var item_name: String = Protocol.item_name_by_id.get(item_def_id, "")
	var prefab: PackedScene = Protocol.get_item_prefab(item_name)

	# Mainhand/offhand/headgear all go through the body's baked HandGrip/
	# OffHandGrip/Head markers (see _get_or_create_hand/_offhand/_head) — same
	# path for the local player and everyone else, so first-person weapons
	# swing with the actual hand bone instead of a hardcoded camera-relative
	# pose.
	var body := _entity_manager.entities.get(net_id) as StaticBody3D
	if body == null:
		return
	match slot:
		Protocol.SLOT_MAINHAND:
			_set_hand_node(_get_or_create_hand(body), prefab)
		Protocol.SLOT_OFFHAND:
			_set_hand_node(_get_or_create_offhand(body), prefab)
		Protocol.SLOT_HEADGEAR:
			_set_hand_node(_get_or_create_head(body), prefab)

# No prefab (res://assets/items/<Name>.tscn missing) means the item def has
# no client-side representation yet — render nothing rather than guess.
func _set_hand_node(parent: Node3D, prefab: PackedScene) -> void:
	for c in parent.get_children():
		c.queue_free()
	if prefab == null:
		return
	var node := prefab.instantiate()
	if node is ItemPrefab:
		# Align the prefab's own HandGrip marker to `parent` (the body's
		# HandGrip/OffHandGrip/Head anchor) by wrapping it in a node that
		# cancels the marker's POSITION only —
		# never rotation or scale. The item's root transform is whatever
		# orientation/scale correction its author baked in (which may live on
		# the root itself, e.g. Torch, or on a child, e.g. NoviceStaff) and
		# must survive untouched; a pure translation zeroes the marker's world
		# offset without ever touching that root basis.
		var grip: Transform3D = (node as ItemPrefab).get_grip_transform()
		var wrapper := Node3D.new()
		wrapper.transform = Transform3D(Basis.IDENTITY, -grip.origin)
		wrapper.add_child(node)
		parent.add_child(wrapper)
	else:
		parent.add_child(node)

func _get_or_create_hand(body: StaticBody3D) -> Node3D:
	# Prefer a bone-attached HandGrip marker baked into the model (e.g.
	# Goblin.tscn) over the synthetic RightHand fallback — it tracks the
	# actual forearm bone instead of a fixed offset guessed from the body root.
	var grip := body.find_child("HandGrip", true, false) as Node3D
	if grip != null:
		return grip
	var hand := body.get_node_or_null("RightHand")
	if hand == null:
		hand = Node3D.new()
		hand.name             = "RightHand"
		hand.position         = _HAND_POS
		hand.rotation_degrees = _HAND_ROT
		body.add_child(hand)
	return hand

func _get_or_create_offhand(body: StaticBody3D) -> Node3D:
	# Mirror of _get_or_create_hand for the offhand slot.
	var grip := body.find_child("OffHandGrip", true, false) as Node3D
	if grip != null:
		return grip
	var hand := body.get_node_or_null("LeftHand")
	if hand == null:
		hand = Node3D.new()
		hand.name             = "LeftHand"
		hand.position         = _OFFHAND_POS
		hand.rotation_degrees = _OFFHAND_ROT
		body.add_child(hand)
	return hand

func _get_or_create_head(body: StaticBody3D) -> Node3D:
	# Prefer a bone-attached Head marker baked into the model (e.g.
	# ManlyMan.tscn) over the synthetic fallback, same reasoning as
	# _get_or_create_hand above.
	var head := body.find_child("Head", true, false) as Node3D
	if head != null:
		return head
	head = Node3D.new()
	head.name     = "Head"
	head.position = _HEAD_POS
	body.add_child(head)
	return head
