extends Node

@onready var _entity_manager: Node = $"../EntityManager"

func _ready() -> void:
	Network.action_ok.connect(_on_action_ok)

func _on_action_ok(actor_id: int, _effect: int, target_id: int, action_type: int) -> void:
	if action_type == Protocol.ACTION_ATTACK:
		return  # swing handled by equipment.gd
	var actor  := _entity_manager.entities.get(actor_id)  as StaticBody3D
	var target := _entity_manager.entities.get(target_id) as StaticBody3D
	if actor == null or target == null:
		return
	if _effect == Protocol.EFFECT_PROJECTILE:
		_projectile(actor.position + Vector3(0, 0.7, 0), target)
	else:
		_lightning(actor.position + Vector3(0, 1, 0), target.position + Vector3(0, 1, 0))

func _projectile(from: Vector3, target: StaticBody3D) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.6, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.3, 0.6, 1.0)
	mat.emission_energy_multiplier = 3.0

	var sphere := SphereMesh.new()
	sphere.radius = 0.15
	sphere.height = 0.3
	sphere.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.mesh = sphere
	mi.position = from
	get_parent().add_child(mi)

	const SPEED := 7.0
	var elapsed := 0.0
	while is_instance_valid(target) and elapsed < 10.0:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		elapsed += dt
		var to   := target.position + Vector3(0, 0.7, 0)
		var diff := to - mi.position
		if diff.length() < 0.3:
			break
		mi.position += diff.normalized() * SPEED * dt

	mi.queue_free()

func _lightning(from: Vector3, to: Vector3) -> void:
	var dir     := (to - from).normalized()
	var up      := Vector3.UP if abs(dir.dot(Vector3.RIGHT)) < 0.9 else Vector3.RIGHT
	var right   := dir.cross(up).normalized()
	var forward := dir.cross(right).normalized()

	var pts: Array[Vector3] = [from]
	for i in range(1, 12):
		var t := float(i) / 12.0
		var p := from.lerp(to, t)
		p += right   * randf_range(-0.65, 0.65)
		p += forward * randf_range(-0.65, 0.65)
		pts.append(p)
	pts.append(to)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color  = Color(0.8, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.5, 1.0)
	mat.emission_energy_multiplier = 5.0

	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
	for p in pts:
		mesh.surface_add_vertex(p)
	mesh.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	get_parent().add_child(mi)

	await get_tree().create_timer(0.25).timeout
	mi.queue_free()
