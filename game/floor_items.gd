extends Node

var _items: Dictionary = {}  # net_id (int) -> Node3D

func _ready() -> void:
	Network.floor_item_spawned.connect(_on_spawned)
	Network.floor_item_destroyed.connect(_on_destroyed)

func _on_spawned(net_id: int, def_id: int, pos: Vector3) -> void:
	if _items.has(net_id):
		return
	var node := _make_mesh(def_id)
	node.position = pos
	get_parent().add_child(node)
	_items[net_id] = node

func _on_destroyed(net_id: int) -> void:
	if _items.has(net_id):
		(_items[net_id] as Node3D).queue_free()
		_items.erase(net_id)

func _make_mesh(def_id: int) -> Node3D:
	match def_id:
		Protocol.ITEM_STICK: return _stick()
	return Node3D.new()

func _stick() -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.28, 0.12)

	var mesh := CylinderMesh.new()
	mesh.top_radius    = 0.09
	mesh.bottom_radius = 0.12
	mesh.height        = 2.1
	mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.rotation_degrees = Vector3(90, 0, 30)
	return mi
