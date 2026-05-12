extends Node

signal player_moved(pos: Vector3)

var entities: Dictionary = {}  # net_id (int) -> StaticBody3D
var player_net_id: int = -1

const _PLAYER_SCENE := preload("res://player.tscn")
var _npc_mesh: Mesh

const _NPC_SCALE := 1.0

var _bear_mat: StandardMaterial3D
var _first_person: bool = true

func _ready() -> void:
	_npc_mesh = load("res://assets/ursotopeira.obj")
	if _npc_mesh:
		_bear_mat = StandardMaterial3D.new()
		_bear_mat.albedo_color = Color(0.55, 0.35, 0.18)
		for s in _npc_mesh.get_surface_count():
			_npc_mesh.surface_set_material(s, _bear_mat)
	Network.unit_pos.connect(_on_unit_pos)
	Network.unit_destroyed.connect(_on_unit_destroyed)

func _on_unit_destroyed(net_id: int) -> void:
	if entities.has(net_id):
		entities[net_id].queue_free()
		entities.erase(net_id)

func set_first_person(fp: bool) -> void:
	_first_person = fp
	if entities.has(player_net_id):
		var body := entities[player_net_id] as StaticBody3D
		for child in body.get_children():
			if child is MeshInstance3D:
				child.visible = not fp

func _on_unit_pos(net_id: int, pos: Vector3, rot_y: float) -> void:
	if not entities.has(net_id):
		var body: StaticBody3D
		if net_id == player_net_id:
			body = _PLAYER_SCENE.instantiate() as StaticBody3D
			for child in body.get_children():
				if child is MeshInstance3D:
					child.visible = not _first_person
		else:
			body = StaticBody3D.new()
			var mi := MeshInstance3D.new()
			mi.mesh  = _npc_mesh
			mi.scale = Vector3.ONE * _NPC_SCALE
			body.add_child(mi)
			var shape := CylinderShape3D.new()
			shape.radius = 0.5
			shape.height = 2.0
			var col := CollisionShape3D.new()
			col.shape = shape
			body.add_child(col)

		body.set_meta("net_id", net_id)
		get_parent().add_child(body)
		entities[net_id] = body

	var body := entities[net_id] as StaticBody3D
	body.position   = pos
	body.rotation.y = rot_y + PI

	if net_id == player_net_id:
		player_moved.emit(pos)
