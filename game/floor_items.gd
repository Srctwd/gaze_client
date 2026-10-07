extends Node

var _items: Dictionary = {}      # net_id (int) -> Node3D
var _item_data: Dictionary = {}  # net_id (int) -> {def_id, quantity, contents} — see get_item_data

func _ready() -> void:
	Network.floor_item_spawned.connect(_on_spawned)
	Network.floor_item_destroyed.connect(_on_destroyed)

# quantity (stack size, e.g. a pile of arrows) and contents (9 {def_id,
# quantity} pairs, only meaningful when def_id is itself a container) aren't
# rendered visually — no stack-count or dropped-container-contents UI exists —
# but are kept in _item_data so an aim-based world inspect (player_controller.gd)
# can read a floor container's contents straight from what SpawnFloorItem
# already sent, no extra round trip needed.
func _on_spawned(net_id: int, def_id: int, quantity: int, pos: Vector3, contents: Array) -> void:
	if _items.has(net_id):
		return
	_item_data[net_id] = {def_id = def_id, quantity = quantity, contents = contents}
	var item_name: String = Protocol.item_name_by_id.get(def_id, "")
	var prefab: PackedScene = Protocol.get_item_prefab(item_name)
	if prefab == null:
		return
	var node := prefab.instantiate() as Node3D
	node.position = pos
	get_parent().add_child(node)
	_items[net_id] = node

func _on_destroyed(net_id: int) -> void:
	if _items.has(net_id):
		(_items[net_id] as Node3D).queue_free()
		_items.erase(net_id)
	_item_data.erase(net_id)

# {} if net_id is unknown — otherwise {def_id, quantity, contents} as received
# in SpawnFloorItem.
func get_item_data(net_id: int) -> Dictionary:
	return _item_data.get(net_id, {})
