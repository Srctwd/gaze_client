extends Node

signal player_moved(pos: Vector3)
signal player_head_moved(pos: Vector3)

var entities:  Dictionary = {}  # net_id (int) -> StaticBody3D
var _xp_orbs:  Array     = []  # {node: GPUParticles3D, target_id: int}
var _xp_pmat:  ParticleProcessMaterial
var _xp_mesh:  SphereMesh

# Every entity's most recent server position/facing — _process() smoothly
# eases each body toward these instead of snapping, since UNIT_POS arrives at
# the server's tick rate, not every rendered frame. This includes the local
# player: player_moved is re-emitted each frame with the eased position, so
# the camera (camera_controller.gd's follow()) tracks the same smoothing.
var _targets: Dictionary = {}  # net_id (int) -> {pos, rot_y, anim_state, is_moving}

const _PLAYER_SCENE := preload("res://player.tscn")

# net_id -> AnimationPlayer, cached on spawn for whichever entities have one
# (only some models do — everything else silently no-ops in _drive_animation).
var _anim_players: Dictionary = {}
var _current_anim: Dictionary = {}  # net_id -> currently playing clip name

# Local player's bone-attached Head Marker3D (assets/monsters/ManlyMan.tscn),
# cached on spawn so the FP camera can track the actual head bone instead of
# a fixed eye-height guess. Null if the equipped model has no such marker.
var _player_head: Node3D = null

# Per-tick position delta above which Ground state counts as "moving" rather
# than idle — small enough to catch normal walk speed, big enough to ignore
# interpolation/network jitter.
const _MOVE_EPS := 0.05

const _ANIM_CLIP := {
	Protocol.ANIM_JUMP: "Jump",
	Protocol.ANIM_FALL: "Fall",
	Protocol.ANIM_SWIM: "Swim",
}

# Looping locomotion clips — forced to loop in _cache_anim_player since baked
# glTF clips import as one-shot. One-shot action clips (e.g. "Swing") must NOT
# be in this list: _drive_animation lets them play to completion undisturbed,
# and looping one would never stop.
const _LOCOMOTION_CLIPS := ["Idle", "Walk", "Jump", "Fall", "Swim"]

var _mesh_by_type:  Dictionary = {}  # unit_type (int) -> PackedScene
var _slime_scenes: Array     = []  # index by (variant >> 6) & 0x3

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
	Protocol.UNIT_SLIME: [
		Color(0.20, 0.75, 0.20),  # 0 green
		Color(0.15, 0.30, 0.90),  # 1 blue
		Color(0.85, 0.15, 0.15),  # 2 red
		Color(0.12, 0.08, 0.12),  # 3 black
	],
}

func _ready() -> void:
	_mesh_by_type[Protocol.UNIT_PLAYER]    = load("res://assets/monsters/ManlyMan.tscn")
	_mesh_by_type[Protocol.UNIT_MINOTAUR]  = load("res://assets/minotaur.obj")
	_mesh_by_type[Protocol.UNIT_MINO_MAGE] = load("res://assets/stone_man.glb")
	_mesh_by_type[Protocol.UNIT_SNAKE]     = load("res://assets/snake.glb")
	_mesh_by_type[Protocol.UNIT_GOBLIN]    = load("res://assets/monsters/Goblin.tscn")
	_mesh_by_type[Protocol.UNIT_DEMON]     = load("res://assets/monsters/low_poly_demon_man_v_3.tscn")
	_slime_scenes = [
		load("res://assets/monsters/GreenSlime.tscn"),  # 0 green
		load("res://assets/slime_blue.glb"),             # 1 blue
		load("res://assets/slime_red.glb"),              # 2 red
		load("res://assets/monsters/GreenSlime.tscn"),  # 3 fallback
	]

	Network.unit_spawned.connect(_on_unit_spawned)
	Network.unit_pos.connect(_on_unit_pos)
	Network.unit_destroyed.connect(_on_unit_destroyed)
	Network.xp_gained.connect(_on_xp_gained)
	Network.level_up.connect(_on_level_up)
	Network.action_ok.connect(_on_action_ok)
	GameState.first_person_changed.connect(set_first_person)
	_build_xp_materials()
	call_deferred(&"_prewarm_xp_shader")

func _on_unit_destroyed(net_id: int) -> void:
	if entities.has(net_id):
		entities[net_id].queue_free()
		entities.erase(net_id)
		_targets.erase(net_id)
		_anim_players.erase(net_id)
		_current_anim.erase(net_id)

func _process(delta: float) -> void:
	var t := 1.0 - exp(-GameState.interp_rate * delta)
	for net_id: int in _targets:
		var body := entities.get(net_id) as StaticBody3D
		if body == null:
			continue
		var tgt: Dictionary = _targets[net_id]
		body.position   = body.position.lerp(tgt.pos, t)
		body.rotation.y = lerp_angle(body.rotation.y, tgt.rot_y, t)
		_drive_animation(net_id, tgt)
		if net_id == GameState.player_net_id:
			player_moved.emit(body.position)
			if _player_head:
				player_head_moved.emit(_player_head.global_position)

	var i := _xp_orbs.size() - 1
	while i >= 0:
		var d: Dictionary = _xp_orbs[i]
		var orb: GPUParticles3D = d.node
		if not is_instance_valid(orb):
			_xp_orbs.remove_at(i)
			i -= 1
			continue
		if not entities.has(d.target_id):
			orb.queue_free()
			_xp_orbs.remove_at(i)
			i -= 1
			continue
		var target: Vector3 = entities[d.target_id].position + Vector3(0, 1.2, 0)
		var to_target := target - orb.global_position
		var dist := to_target.length()
		if dist < 0.4:
			orb.queue_free()
			_xp_orbs.remove_at(i)
			i -= 1
			continue
		d.speed = minf(d.speed + 10.0 * delta, 16.0)
		orb.global_position += to_target.normalized() * d.speed * delta
		i -= 1

func _on_level_up(net_id: int, _new_level: int) -> void:
	if not entities.has(net_id):
		return
	var body: Node3D = entities[net_id]
	var light := OmniLight3D.new()
	light.light_color = Color(0.9, 0.85, 1.0)
	light.light_energy = 12.0
	light.omni_range = 8.0
	light.shadow_enabled = false
	body.add_child(light)
	var tween := light.create_tween()
	tween.tween_property(light, "light_energy", 0.0, 2.0).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	tween.tween_callback(light.queue_free)

func _on_xp_gained(monster_net_id: int, player_ids: Array) -> void:
	if not entities.has(monster_net_id):
		return
	var from: Vector3 = entities[monster_net_id].position + Vector3(0, 1.0, 0)
	for pid in player_ids:
		if entities.has(pid):
			_spawn_xp_orb(from, pid)

const _XP_COLOR := Color(1.0, 1.0, 1.0, 0.33)

func _build_xp_materials() -> void:
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.albedo_color = _XP_COLOR
	glow.emission_enabled = true
	glow.emission = Color(_XP_COLOR.r, _XP_COLOR.g, _XP_COLOR.b)
	glow.emission_energy_multiplier = 2.0

	_xp_mesh = SphereMesh.new()
	_xp_mesh.radius = 0.25
	_xp_mesh.height = .25
	_xp_mesh.material = glow

	_xp_pmat = ParticleProcessMaterial.new()
	_xp_pmat.direction = Vector3(0, 1, 0)
	_xp_pmat.spread = 180.0
	_xp_pmat.initial_velocity_min = 1.0
	_xp_pmat.initial_velocity_max = 2.5
	_xp_pmat.gravity = Vector3.ZERO
	_xp_pmat.damping_min = 4.0
	_xp_pmat.damping_max = 6.0
	_xp_pmat.turbulence_enabled = true
	_xp_pmat.turbulence_noise_strength = 2.5
	_xp_pmat.turbulence_noise_scale = 3.0
	_xp_pmat.scale_min = 0.2
	_xp_pmat.scale_max = 0.2
	_xp_pmat.color = _XP_COLOR
	_xp_pmat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_xp_pmat.emission_sphere_radius = 0.3

func _prewarm_xp_shader() -> void:
	var warmup := GPUParticles3D.new()
	warmup.position = Vector3(0.0, -9999.0, 0.0)
	warmup.process_material = _xp_pmat
	warmup.draw_pass_1 = _xp_mesh
	warmup.amount = 1
	warmup.lifetime = 0.1
	warmup.one_shot = true
	warmup.emitting = true
	get_parent().add_child(warmup)
	warmup.finished.connect(warmup.queue_free)

func _spawn_xp_orb(from: Vector3, target_net_id: int) -> void:
	var particles := GPUParticles3D.new()
	particles.position = from
	particles.local_coords = true
	particles.amount = 9
	particles.lifetime = 1.5
	particles.one_shot = false
	particles.preprocess = particles.lifetime
	particles.emitting = true
	particles.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	particles.process_material = _xp_pmat
	particles.draw_pass_1 = _xp_mesh

	get_parent().add_child(particles)
	_xp_orbs.append({node = particles, target_id = target_net_id, speed = 1.0})

func set_first_person(fp: bool) -> void:
	if entities.has(GameState.player_net_id):
		var body := entities[GameState.player_net_id] as StaticBody3D
		for mi in body.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).visible = not fp

func _on_unit_spawned(net_id: int, unit_type: int, variant: int, pos: Vector3, _anim_state: int) -> void:
	if entities.has(net_id):
		return
	var body := _make_body(net_id, unit_type, variant)
	body.position = pos
	get_parent().add_child(body)
	entities[net_id] = body
	_apply_variant(body, unit_type, variant)
	_cache_anim_player(net_id, body)

func _on_unit_pos(net_id: int, unit_type: int, variant: int, pos: Vector3, rot_y: float, anim_state: int) -> void:
	var rot := rot_y + PI
	if not entities.has(net_id):
		var body := _make_body(net_id, unit_type, variant)
		# Snap on first sight — nothing to interpolate from yet, and easing in
		# from the body's default (0,0,0) would visibly slide it into place.
		body.position   = pos
		body.rotation.y = rot
		get_parent().add_child(body)
		entities[net_id] = body
		_apply_variant(body, unit_type, variant)
		_cache_anim_player(net_id, body)

	# Moving is inferred from how far this tick's position is from the last
	# one — the server doesn't split Ground into idle/walk/run on its own.
	var is_moving := false
	if _targets.has(net_id):
		is_moving = (pos - (_targets[net_id].pos as Vector3)).length() > _MOVE_EPS
	_targets[net_id] = {pos = pos, rot_y = rot, anim_state = anim_state, is_moving = is_moving}

func _make_body(net_id: int, unit_type: int, variant: int = 0) -> StaticBody3D:
	var body: StaticBody3D
	if net_id == GameState.player_net_id:
		body = _PLAYER_SCENE.instantiate() as StaticBody3D
		for mi in body.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).visible = not GameState.first_person
		_player_head = body.find_child("Head", true, false) as Node3D
	else:
		body = StaticBody3D.new()
		var scene: PackedScene
		if unit_type == Protocol.UNIT_SLIME:
			scene = _slime_scenes[(variant >> 6) & 0x3]
		else:
			scene = _mesh_by_type.get(unit_type, null)
		if scene == null:
			scene = _mesh_by_type.get(Protocol.UNIT_MINO_MAGE)
		var mesh_node := scene.instantiate() as Node3D
		if unit_type == Protocol.UNIT_SLIME:
			mesh_node.scale = Vector3(0.5, 0.5, 0.5)
		body.add_child(mesh_node)
		var shape := CylinderShape3D.new()
		if unit_type == Protocol.UNIT_SLIME:
			shape.radius = 0.3
			shape.height = 0.6
		else:
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
	if unit_type == Protocol.UNIT_SLIME:
		return
	for mi: MeshInstance3D in body.find_children("*", "MeshInstance3D", true, false):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint
		mi.material_override = mat

func _cache_anim_player(net_id: int, body: Node3D) -> void:
	var players := body.find_children("*", "AnimationPlayer", true, false)
	if players.is_empty():
		return
	var player := players[0] as AnimationPlayer
	# Baked glTF locomotion clips import as one-shot (loop_mode NONE) — force
	# just those to loop so Idle/Walk/etc. play continuously instead of
	# freezing on the last frame. One-shot action clips (e.g. "Swing") are
	# left alone so they play once and stop.
	for anim_name in _LOCOMOTION_CLIPS:
		if player.has_animation(anim_name):
			player.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
	_anim_players[net_id] = player

func _on_action_ok(actor_id: int, effect: int, _target_id: int, action_type: int) -> void:
	if action_type != Protocol.ACTION_ATTACK or effect != Protocol.EFFECT_SWING:
		return
	var player := _anim_players.get(actor_id) as AnimationPlayer
	if player == null or not player.has_animation("Swing"):
		return
	player.play("Swing")
	_current_anim[actor_id] = "Swing"

func _drive_animation(net_id: int, tgt: Dictionary) -> void:
	var player := _anim_players.get(net_id) as AnimationPlayer
	if player == null:
		return
	# Let a one-shot action clip (e.g. Swing) finish before resuming
	# locomotion instead of stomping it every frame.
	if player.is_playing() and not (_current_anim.get(net_id) in _LOCOMOTION_CLIPS):
		return
	var clip: String
	if tgt.get("anim_state", Protocol.ANIM_GROUND) == Protocol.ANIM_GROUND:
		clip = "Walk" if tgt.get("is_moving", false) else "Idle"
	else:
		clip = _ANIM_CLIP.get(tgt.anim_state, "Idle")
	if _current_anim.get(net_id) == clip or not player.has_animation(clip):
		return
	player.play(clip)
	_current_anim[net_id] = clip
