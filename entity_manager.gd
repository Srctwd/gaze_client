extends Node

signal player_moved(pos: Vector3)

var entities: Dictionary = {}  # net_id (int) -> StaticBody3D
var player_net_id: int = -1

func _ready() -> void:
	Network.unit_pos.connect(_on_unit_pos)

func set_first_person(fp: bool) -> void:
	if entities.has(player_net_id):
		(entities[player_net_id] as StaticBody3D).visible = not fp

func _on_unit_pos(net_id: int, pos: Vector3) -> void:
	if not entities.has(net_id):
		var body := StaticBody3D.new()
		body.set_meta("net_id", net_id)

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 0.5, 1.0)
		var cyl := CylinderMesh.new()
		cyl.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = cyl
		body.add_child(mi)

		var shape := CylinderShape3D.new()
		shape.radius = 0.5
		shape.height = 2.0
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)

		get_parent().add_child(body)
		entities[net_id] = body

	(entities[net_id] as StaticBody3D).position = pos

	if net_id == player_net_id:
		player_moved.emit(pos)
