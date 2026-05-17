extends Node

@onready var _entity_manager: Node = $"../EntityManager"

func _ready() -> void:
	Network.action_ok.connect(_on_action_ok)

func _on_action_ok(actor_id: int, effect: int, target_id: int, action_type: int) -> void:
	if target_id == 0:
		return
	var target := _entity_manager.entities.get(target_id) as Node3D
	if target == null:
		return

	if action_type == Protocol.ACTION_ATTACK:
		_flash(target, Color(0.0, 0.0, 0.0, 0.5))
	elif action_type == Protocol.ACTION_SPELL:
		if effect == Protocol.EFFECT_PROJECTILE:
			var actor := _entity_manager.entities.get(actor_id) as Node3D
			if actor != null:
				_spawn_projectile(actor.global_position + Vector3(0, 0.7, 0),
								  target)
			else:
				_flash(target, Color(0.1, 0.2, 0.5, 0.5))
		else:
			_flash(target, Color(0.1, 0.2, 0.5, 0.5))

func _spawn_projectile(from: Vector3, target: Node3D) -> void:
	var sp := SphereMesh.new()
	sp.radius = 0.18
	sp.height = 0.36
	sp.radial_segments = 6
	sp.rings = 4

	var mat := StandardMaterial3D.new()
	mat.shading_mode       = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color       = Color(0.3, 0.6, 1.0)
	mat.emission_enabled   = true
	mat.emission           = Color(0.3, 0.6, 1.0)
	mat.emission_energy_multiplier = 2.0
	sp.surface_set_material(0, mat)

	var orb := MeshInstance3D.new()
	orb.mesh = sp
	orb.position = from
	get_parent().add_child(orb)

	var travel := 0.35
	var tween  := orb.create_tween()
	tween.tween_method(
		func(t: float):
			if not is_instance_valid(orb): return
			if not is_instance_valid(target):
				orb.queue_free()
				return
			orb.global_position = from.lerp(target.global_position + Vector3(0, 0.7, 0), t),
		0.0, 1.0, travel)
	tween.tween_callback(func():
		if is_instance_valid(target):
			_flash(target, Color(0.1, 0.2, 0.5, 0.5))
		if is_instance_valid(orb):
			orb.queue_free()
	)

func _flash(target: Node3D, color: Color) -> void:
	var meshes := target.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty():
		return

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	for mi in meshes:
		mi.material_overlay = mat

	await get_tree().create_timer(0.2).timeout

	for mi in meshes:
		if is_instance_valid(mi):
			mi.material_overlay = null
