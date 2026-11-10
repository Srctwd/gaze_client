extends Node

const Viewmodel := preload("res://game/viewmodel.gd")

const _HAND_POS := Vector3(0.45, 0.9, 0.1)
const _HAND_ROT := Vector3(0, 0, 90)
const _OFFHAND_POS := Vector3(-0.45, 0.9, 0.1)
const _OFFHAND_ROT := Vector3(0, 0, -90)
const _HEAD_POS := Vector3(0, 1.7, 0)
const _BACK_POS := Vector3(0, 1.0, -0.25)
const _HIP_POS  := Vector3(0.25, 0.9, 0)
const _TORSO_POS := Vector3(0, 1.2, 0)

@onready var _entity_manager: Node = $"../EntityManager"

var _mainhand: Dictionary = {}           # net_id -> item_def_id currently equipped in SLOT_MAINHAND
var _mainhand_quantity: Dictionary = {}  # net_id -> stack count (1 if not stackable, see EquipSync)
# net_id -> {slot: item_def_id}, every unit's last EquipSync per slot — put back
# on a player's body when its model arrives or changes (body_model_changed).
var _equipped: Dictionary = {}

func _ready() -> void:
	Network.equip_synced.connect(_on_equip_synced)
	Network.unit_destroyed.connect(func(net_id: int) -> void: _equipped.erase(net_id))
	_entity_manager.body_model_changed.connect(_on_body_model_changed)
	GameState.first_person_changed.connect(func(_fp: bool) -> void: _update_viewmodel.call_deferred())

func get_mainhand_item(net_id: int) -> int:
	return _mainhand.get(net_id, -1)

# 1 for anything non-stackable, or the real stack count while MainHand holds
# a stackable resource (e.g. a pile of arrows/stones) — see HeldStack, item.h.
func get_mainhand_quantity(net_id: int) -> int:
	return _mainhand_quantity.get(net_id, 1)

func _on_equip_synced(net_id: int, slot: int, item_def_id: int, quantity: int) -> void:
	if slot == Protocol.SLOT_MAINHAND:
		_mainhand[net_id] = item_def_id
		_mainhand_quantity[net_id] = quantity
	if not _equipped.has(net_id):
		_equipped[net_id] = {}
	_equipped[net_id][slot] = item_def_id
	# A player's body without its model yet: placed on body_model_changed.
	if _entity_manager.has_model(net_id):
		_place(net_id, slot, item_def_id)

func _on_body_model_changed(net_id: int) -> void:
	var slots: Dictionary = _equipped.get(net_id, {})
	for slot: int in slots:
		_place(net_id, slot, slots[slot])

func _place(net_id: int, slot: int, item_def_id: int) -> void:
	var item_name: String = Protocol.item_name_by_id.get(item_def_id, "")
	var prefab: PackedScene = Protocol.get_item_prefab(item_name)

	# Mainhand/offhand/headgear/bag/pouch all go through the body's baked
	# HandGrip/OffHandGrip/Head/Back/Hip markers (see _get_or_create_hand/
	# _offhand/_head/_back/_hip) — the local player's too, for third person.
	# Our own hand items also get a first-person copy in the viewmodel, which
	# doesn't depend on the body model's arms.
	var body := _entity_manager.entities.get(net_id) as StaticBody3D
	match slot:
		Protocol.SLOT_MAINHAND:
			_set_hand_node(_get_or_create_hand(body), prefab)
			if net_id == GameState.player_net_id:
				_set_viewmodel_item(0, prefab)
		Protocol.SLOT_OFFHAND:
			_set_hand_node(_get_or_create_offhand(body), prefab)
			if net_id == GameState.player_net_id:
				_set_viewmodel_item(1, prefab)
		Protocol.SLOT_HEADGEAR:
			var helmet := _set_hand_node(_get_or_create_head(body), prefab)
			# The first-person camera sits on this same Head marker, i.e. inside
			# the helmet — hide our own like the rest of the local body
			# (entity_manager.gd: _make_body/set_first_person, which also
			# toggles this node from then on since it lives under the body).
			if helmet != null and net_id == GameState.player_net_id:
				for mi in helmet.find_children("*", "MeshInstance3D", true, false):
					(mi as MeshInstance3D).visible = not GameState.first_person
		Protocol.SLOT_ARMOR:
			var armor := _set_hand_node(_get_or_create_torso(body), prefab)
			# Hidden on ourselves in first person, like the helmet and the
			# rest of the local body.
			if armor != null and net_id == GameState.player_net_id:
				for mi in armor.find_children("*", "MeshInstance3D", true, false):
					(mi as MeshInstance3D).visible = not GameState.first_person
		Protocol.SLOT_BAG:
			_set_hand_node(_get_or_create_back(body), prefab)
		Protocol.SLOT_POUCH:
			_set_hand_node(_get_or_create_hip(body), prefab)

func _set_viewmodel_item(hand: int, prefab: PackedScene) -> void:
	if Viewmodel.current != null:
		Viewmodel.current.set_item(hand, prefab)
	_update_viewmodel()

# Our own MainHand/OffHand items on the body: hidden in first person, where
# the viewmodel draws its own copies instead, like the rest of our body
# (entity_manager.set_first_person only covers MeshInstance3D, not a torch's
# particles). Their lights stay on — the viewmodel copies have none.
func _update_viewmodel() -> void:
	var body := _entity_manager.entities.get(GameState.player_net_id) as StaticBody3D
	if body == null:
		return
	var fp := GameState.first_person
	for hand: Node3D in [_get_or_create_hand(body), _get_or_create_offhand(body)]:
		for gi in hand.find_children("*", "GeometryInstance3D", true, false):
			(gi as GeometryInstance3D).visible = not fp

# No prefab (res://assets/items/<Name>.tscn missing) means the item def has
# no client-side representation yet — render nothing rather than guess.
func _set_hand_node(parent: Node3D, prefab: PackedScene) -> Node3D:
	for c in parent.get_children():
		c.queue_free()
	if prefab == null:
		return null
	var node := prefab.instantiate()

	# Equip anchors (HandGrip/OffHandGrip/Head/Back/Hip) sit deep inside the
	# body model's own hierarchy, which may itself be authored at some
	# non-1.0 scale (e.g. Human2.tscn's root is 0.0415) — without canceling
	# that ambient scale here, the same item prefab renders smaller equipped
	# than it does as a floor item (floor_items.gd parents it straight to
	# the world, with no such scale in the way). Read at runtime rather than
	# hardcoded so it's correct for whatever body/marker it's attached to.
	var ambient_scale: Vector3 = parent.global_transform.basis.get_scale()
	var correction := Vector3.ONE / ambient_scale

	var grip := Transform3D.IDENTITY
	if node is ItemPrefab:
		# Align the prefab's own HandGrip marker to `parent` (the body's
		# HandGrip/OffHandGrip/Head/Back/Hip anchor), position and rotation,
		# through the wrapper — never touching the item's own root basis,
		# which is whatever orientation/scale correction its author baked in
		# (may live on the root itself, e.g. Torch, or on a child, e.g.
		# NoviceStaff) and must survive untouched.
		grip = (node as ItemPrefab).get_grip_transform()

	var wrapper := Node3D.new()
	wrapper.transform = Transform3D(Basis().scaled(correction)) * grip.affine_inverse()
	wrapper.add_child(node)
	parent.add_child(wrapper)
	return wrapper

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
	# Human2.tscn) over the synthetic fallback, same reasoning as
	# _get_or_create_hand above.
	var head := body.find_child("Head", true, false) as Node3D
	if head != null:
		return head
	head = Node3D.new()
	head.name     = "Head"
	head.position = _HEAD_POS
	body.add_child(head)
	return head

func _get_or_create_back(body: StaticBody3D) -> Node3D:
	# Prefer a bone-attached Back marker baked into the model (e.g.
	# Human2.tscn) over the synthetic fallback, same reasoning as
	# _get_or_create_hand above.
	var back := body.find_child("Back", true, false) as Node3D
	if back != null:
		return back
	back = Node3D.new()
	back.name     = "Back"
	back.position = _BACK_POS
	body.add_child(back)
	return back

func _get_or_create_torso(body: StaticBody3D) -> Node3D:
	# Body armor sits at the chest bone's origin — the same BoneAttachment3D
	# that holds the Back marker (Human2.tscn), so it follows the torso.
	# Falls back to a fixed offset on models without that marker.
	var torso := body.find_child("Torso", true, false) as Node3D
	if torso != null:
		return torso
	torso = Node3D.new()
	torso.name = "Torso"
	var back := body.find_child("Back", true, false) as Node3D
	if back != null and back.get_parent() is BoneAttachment3D:
		back.get_parent().add_child(torso)
	else:
		torso.position = _TORSO_POS
		body.add_child(torso)
	return torso

func _get_or_create_hip(body: StaticBody3D) -> Node3D:
	# Prefer a bone-attached Hip marker baked into the model (e.g.
	# Human2.tscn) over the synthetic fallback, same reasoning as
	# _get_or_create_hand above.
	var hip := body.find_child("Hip", true, false) as Node3D
	if hip != null:
		return hip
	hip = Node3D.new()
	hip.name     = "Hip"
	hip.position = _HIP_POS
	body.add_child(hip)
	return hip
