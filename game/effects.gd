extends Node

const _FLAME_PARTICLES_SCENE := preload("res://assets/vfx/flame_particles_3d.tscn")
const _MELEE_EFFECT_SCENE := preload("res://assets/melee_effect.glb")

@onready var _entity_manager: Node = $"../EntityManager"

var equipment: Node = null  # set externally; used to look up the attacker's mainhand item

func _ready() -> void:
	Network.action_ok.connect(_on_action_ok)
	Network.free_aim_shot.connect(_on_free_aim_shot)

# Cosmetic-only approximation (see design discussion): the server resolves the
# actual hit itself (projectile_system's free-flight sweep); this just plays a
# straight-line flight of the full max_range every time, regardless of
# whether the real projectile stopped sooner. Good enough until/unless this
# becomes a real synced entity instead.
func _on_free_aim_shot(actor_id: int, origin: Vector3, yaw: float, pitch: float, speed: float, max_range: float, effect: int) -> void:
	if speed <= 0.0:
		return

	# The bow, dagger, and staff all now fire via this same free-aim path
	# (handle_freeaim_attack) — the visual is whatever the mainhand item's own
	# prefab declares as its projectile_scene; no mesh means nothing to show.
	var mesh: Node3D
	if effect == Protocol.EFFECT_FIREBALL:
		mesh = _build_fireball_orb()
	else:
		var projectile_scene := _mainhand_projectile_scene(actor_id)
		if projectile_scene == null:
			return
		mesh = projectile_scene.instantiate() as Node3D
		if mesh.get("random_roll_tumble"):
			mesh.rotation_degrees.z = randf_range(0, 360)
		_autoplay_animations(mesh)

	# yaw here is the server's already-adjusted value (rotation.y + PI), matching
	# handle_freeaim_attack's forward vector exactly — see that function's comment
	# for why this lines up with cos(pitch)/sin(pitch) with no further sign flip.
	var cp := cos(pitch)
	var dir := Vector3(sin(yaw) * cp, sin(pitch), cos(yaw) * cp)

	# A pivot handles facing (via look_at, world space); the mesh is its child,
	# holding whatever rest-pose correction its own prefab bakes in — not a
	# roll composed on top of look_at's basis, which is a different transform
	# despite using the same numbers (non-commutative), and was the actual
	# cause of hand/flying looking inconsistent with each other.
	var pivot := Node3D.new()
	pivot.position = origin
	pivot.look_at_from_position(origin, origin + dir, Vector3.UP)
	get_parent().add_child(pivot)
	pivot.add_child(mesh)

	var tween := pivot.create_tween()
	tween.tween_property(pivot, "global_position", origin + dir * max_range, max_range / speed)
	tween.tween_callback(func():
		if is_instance_valid(pivot):
			pivot.queue_free()
	)

func _on_action_ok(actor_id: int, effect: int, target_id: int, action_type: int) -> void:
	if target_id == 0:
		return
	var target := _entity_manager.entities.get(target_id) as Node3D
	if target == null:
		return

	if effect == Protocol.EFFECT_PROJECTILE and (action_type == Protocol.ACTION_ATTACK or action_type == Protocol.ACTION_SPELL):
		var actor := _entity_manager.entities.get(actor_id) as Node3D
		var flash_color := Color(0.0, 0.0, 0.0, 0.5) if action_type == Protocol.ACTION_ATTACK else Color(0.1, 0.2, 0.5, 0.5)
		if actor != null:
			var from := actor.global_position + Vector3(0, 0.7, 0)
			var projectile_scene: PackedScene = null
			if action_type == Protocol.ACTION_ATTACK:
				projectile_scene = _mainhand_projectile_scene(actor_id)
			if projectile_scene != null:
				_spawn_weapon_projectile(projectile_scene, from, target)
			else:
				_spawn_orb_projectile(from, target)
		else:
			_flash_color(target, flash_color)
	elif effect == Protocol.EFFECT_SWING and action_type == Protocol.ACTION_ATTACK:
		_flash_color(target, Color(0.0, 0.0, 0.0, 0.5))
		_spawn_melee_effect(_entity_manager.entities.get(actor_id) as Node3D, target)
	elif action_type == Protocol.ACTION_SPELL:
		if effect == Protocol.EFFECT_FLAME:
			_spawn_flame_effect(target)
		elif effect == Protocol.EFFECT_FIREBALL:
			var actor := _entity_manager.entities.get(actor_id) as Node3D
			if actor != null:
				_spawn_fireball_projectile(actor.global_position + Vector3(0, 0.7, 0), target)
			else:
				_flash_color(target, Color(1.0, 0.3, 0.0, 0.5))
		else:
			_flash_color(target, Color(0.1, 0.2, 0.5, 0.5))

# Imported glTF animations (e.g. a staff bolt's pulsing rotate/scale) don't
# autoplay — Godot just leaves the AnimationPlayer sitting idle at rest pose.
# Looping (rather than trusting the baked loop_mode) because the clip's own
# length rarely matches how long the projectile is actually in flight.
func _autoplay_animations(node: Node3D) -> void:
	for ap in node.find_children("*", "AnimationPlayer", true, false):
		var player := ap as AnimationPlayer
		var anims := player.get_animation_list()
		if anims.is_empty():
			continue
		var anim := player.get_animation(anims[0])
		if anim:
			anim.loop_mode = Animation.LOOP_LINEAR
		player.play(anims[0])

func _spawn_orb_projectile(from: Vector3, target: Node3D) -> void:
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
	_animate_projectile(orb, from, target)

# actor_id's mainhand item's own ranged visual (arrow, dagger, staff bolt, ...),
# or null if it has no prefab or no projectile_scene set (melee item).
func _mainhand_projectile_scene(actor_id: int) -> PackedScene:
	if equipment == null:
		return null
	var item_def_id: int = equipment.get_mainhand_item(actor_id)
	var item_name: String = Protocol.item_name_by_id.get(item_def_id, "")
	return Protocol.get_item_projectile_scene(item_name)

func _spawn_weapon_projectile(scene: PackedScene, from: Vector3, target: Node3D) -> void:
	var node := scene.instantiate() as Node3D
	var to_pos := target.global_position + Vector3(0, 0.7, 0)
	if not to_pos.is_equal_approx(from):
		node.look_at_from_position(from, to_pos, Vector3.UP)
	if node.get("random_roll_tumble"):
		node.rotation_degrees.z = randf_range(0, 360)
	_autoplay_animations(node)
	_animate_projectile(node, from, target)

func _spawn_fireball_projectile(from: Vector3, target: Node3D) -> void:
	_animate_projectile(_build_fireball_orb(), from, target, Color(1.0, 0.3, 0.0, 0.5))

func _build_fireball_orb() -> MeshInstance3D:
	var sp := SphereMesh.new()
	sp.radius = 0.26
	sp.height = 0.52
	sp.radial_segments = 8
	sp.rings = 6

	var mat := StandardMaterial3D.new()
	mat.shading_mode       = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color       = Color(1.0, 0.35, 0.05)
	mat.emission_enabled   = true
	mat.emission           = Color(1.0, 0.25, 0.0)
	mat.emission_energy_multiplier = 3.0
	sp.surface_set_material(0, mat)

	var orb := MeshInstance3D.new()
	orb.mesh = sp
	return orb

# Places `node` at `from`, adds it to the scene, and tweens it toward `target`
# (tracking it live in case it moves), flashing and freeing on arrival.
func _animate_projectile(node: Node3D, from: Vector3, target: Node3D, impact_color := Color(0.1, 0.2, 0.5, 0.5)) -> void:
	node.position = from
	get_parent().add_child(node)

	# Capture the instance ID, not `target` itself — if the target dies mid-flight
	# and its Node gets freed, a captured Node reference errors on every tween
	# callback tick ("Lambda capture ... was freed"); a plain int never does.
	var target_id := target.get_instance_id()
	var travel := 0.35
	var tween  := node.create_tween()
	tween.tween_method(
		func(t: float):
			if not is_instance_valid(node): return
			var tgt := instance_from_id(target_id) as Node3D
			if tgt == null or not is_instance_valid(tgt):
				node.queue_free()
				return
			node.global_position = from.lerp(tgt.global_position + Vector3(0, 0.7, 0), t),
		0.0, 1.0, travel)
	tween.tween_callback(func():
		var tgt := instance_from_id(target_id) as Node3D
		if tgt != null and is_instance_valid(tgt):
			_flash_color(tgt, impact_color)
		if is_instance_valid(node):
			node.queue_free()
	)

func _spawn_melee_effect(actor: Node3D, target: Node3D) -> void:
	var fx := _MELEE_EFFECT_SCENE.instantiate() as Node3D
	get_parent().add_child(fx)
	fx.global_position = target.global_position + Vector3(0, 0.9, 0)
	# Face the swing toward the attacker; without one (shouldn't normally
	# happen for a melee hit) fall back to whatever rotation the model ships with.
	if actor != null and not actor.global_position.is_equal_approx(target.global_position):
		fx.look_at(actor.global_position + Vector3(0, 0.9, 0), Vector3.UP)

	await get_tree().create_timer(0.2).timeout
	if is_instance_valid(fx):
		fx.queue_free()

func _flash_color(target: Node3D, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash(target, mat)

func _spawn_flame_effect(target: Node3D) -> void:
	var particles := _FLAME_PARTICLES_SCENE.instantiate() as GPUParticles3D
	particles.one_shot = true
	get_parent().add_child(particles)
	# global_position, not position — get_parent()'s local space isn't world
	# origin, so a local-space assignment before this would misplace it.
	# target.global_position is already the entity's base/feet, so no offset.
	particles.global_position = target.global_position
	particles.emitting = true
	particles.restart()

	await get_tree().create_timer(particles.lifetime + 0.2).timeout
	if is_instance_valid(particles):
		particles.queue_free()

func _flash(target: Node3D, mat: Material) -> void:
	var meshes := target.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty():
		return

	for mi in meshes:
		mi.material_overlay = mat

	await get_tree().create_timer(0.2).timeout

	for mi in meshes:
		if is_instance_valid(mi):
			mi.material_overlay = null
