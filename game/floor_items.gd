extends Node

var _items: Dictionary = {}  # net_id (int) -> Node3D

func _ready() -> void:
	Network.floor_item_spawned.connect(_on_spawned)
	Network.floor_item_destroyed.connect(_on_destroyed)

func _on_spawned(net_id: int, def_id: int, pos: Vector3) -> void:
	if _items.has(net_id):
		return
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
