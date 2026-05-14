extends Node

signal player_moved(pos: Vector3)

var entities: Dictionary = {}  # net_id (int) -> StaticBody3D
var player_net_id: int = -1

const _PLAYER_SCENE := preload("res://player.tscn")

var _mesh_by_type: Dictionary = {}   # unit_type (int) -> PackedScene
var _first_person: bool = true

# 4 hues per unit type, indexed by headgear bits (variant >> 6) & 0x3
const _VARIANT_PALETTES := {
	Protocol.UNIT_MINOTAUR: [
		Color(0.70, 0.50, 0.30),  # 0 tan brown
		Color(0.50, 0.18, 0.10),  # 1 dark red
		Color(0.30, 0.30, 0.30),  # 2 stone grey
		Color(0.80, 0.60, 0.10),  # 3 golden
	],
	Protocol.UNIT_MINO_MAGE: [
		Color(0.50, 0.50, 0.70),  # 0 grey-blue
		Color(0.50, 0.18, 0.60),  # 1 purple
		Color(0.10, 0.50, 0.50),  # 2 teal
		Color(0.20, 0.10, 0.50),  # 3 dark purple
	],
}

func _ready() -> void:
	_mesh_by_type[Protocol.UNIT_MINOTAUR]  = load("res://assets/minotaur.obj")
	_mesh_by_type[Protocol.UNIT_MINO_MAGE] = load("res://assets/stone_man.glb")

	Network.unit_spawned.connect(_on_unit_spawned)
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
		for mi in body.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).visible = not fp

func _on_unit_spawned(net_id: int, unit_type: int, variant: int, pos: Vector3) -> void:
	if entities.has(net_id):
		return
	var body := _make_body(net_id, unit_type)
	body.position = pos
	get_parent().add_child(body)
	entities[net_id] = body
	_apply_variant(body, unit_type, variant)

func _on_unit_pos(net_id: int, pos: Vector3, rot_y: float) -> void:
	if not entities.has(net_id):
		var body := _make_body(net_id, Protocol.UNIT_MINO_MAGE)
		body.position = pos
		get_parent().add_child(body)
		entities[net_id] = body
		_apply_variant(body, Protocol.UNIT_MINO_MAGE, 0)
	var body := entities[net_id] as StaticBody3D
	body.position   = pos
	body.rotation.y = rot_y + PI
	if net_id == player_net_id:
		player_moved.emit(pos)

func _make_body(net_id: int, unit_type: int) -> StaticBody3D:
	var body: StaticBody3D
	if net_id == player_net_id:
		body = _PLAYER_SCENE.instantiate() as StaticBody3D
		for mi in body.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).visible = not _first_person
	else:
		body = StaticBody3D.new()
		var scene: PackedScene = _mesh_by_type.get(unit_type, null)
		if scene == null:
			scene = _mesh_by_type.get(Protocol.UNIT_MINO_MAGE)
		var mesh_node := scene.instantiate() as Node3D
		body.add_child(mesh_node)
		var shape := CylinderShape3D.new()
		shape.radius = 0.5
		shape.height = 2.0
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
	body.set_meta("net_id", net_id)
	return body

func _apply_variant(body: Node3D, unit_type: int, variant: int) -> void:
	var palette: Array = _VARIANT_PALETTES.get(unit_type, [])
	if palette.is_empty():
		return
	var headgear    := (variant >> 6) & 0x3
	var breastplate := (variant >> 4) & 0x3
	var base: Color  = palette[headgear]
	var brightness  := 0.8 + breastplate * 0.067  # 0.80 → 1.00 across 4 steps
	var tint        := Color(base.r * brightness, base.g * brightness, base.b * brightness)
	for mi: MeshInstance3D in body.find_children("*", "MeshInstance3D", true, false):
		var mat := StandardMaterial3D.new()
		var src := mi.get_active_material(0)
		if src is StandardMaterial3D:
			mat = (src as StandardMaterial3D).duplicate() as StandardMaterial3D
		mat.albedo_color = tint
		mi.material_override = mat
