extends Node

signal player_moved(pos: Vector3)
signal player_head_moved(pos: Vector3)
signal player_body_changed(radius: float, height: float)

var entities:  Dictionary = {}  # net_id (int) -> StaticBody3D
var _xp_orbs:  Array     = []  # {node: GPUParticles3D, target_id: int}

# Every entity's most recent server position/facing — _process() smoothly
# eases each body toward these instead of snapping, since UNIT_POS arrives at
# the server's tick rate, not every rendered frame. This includes the local
# player: player_moved is re-emitted each frame with the eased position, so
# the camera (camera_controller.gd's follow()) tracks the same smoothing.
var _targets: Dictionary = {}  # net_id (int) -> {pos, rot_y, pitch, anim_state, is_moving}

const _PLAYER_SCENE := preload("res://player.tscn")

# net_id -> AnimationPlayer, cached on spawn for whichever entities have one
# (only some models do — everything else silently no-ops in _drive_animation).
var _anim_players: Dictionary = {}
var _current_anim: Dictionary = {}  # net_id -> currently playing clip name

# net_id -> PitchTilt on that body's skeleton, for other units with a humanoid
# spine (see _attach_pitch_tilt). Fed tgt.pitch every frame in _process.
var _pitch_tilts: Dictionary = {}

# Local player's bone-attached Head Marker3D (assets/monsters/ManlyMan.tscn),
# cached on spawn so the FP camera can track the actual head bone instead of
# a fixed eye-height guess. Null if the equipped model has no such marker.
var _player_head: Node3D = null
# Head position in the body's own space, from the last locomotion frame — the
# eye holds it while an action clip (Swing) throws the head around, so the
# view keeps walk bob but not the swing. See _player_eye.
var _player_head_offset: Vector3
var _player_head_offset_valid := false

# Per-tick position delta above which Ground state counts as "moving" rather
# than idle — small enough to catch normal walk speed, big enough to ignore
# interpolation/network jitter.
const _MOVE_EPS := 0.05

# Per-update position jump above which the body snaps instead of easing — a
# Blink/Translocate, not movement (a fall at 20 Hz would need ~120 m/s).
const _SNAP_DIST := 6.0

# How long a freshly spawned monster's meshes stay hidden before revealing —
# effects.gd's portal (also reacting to Network.unit_spawned) can lag a beat
# behind this body being added to the tree, and without this delay the
# monster visibly pops in before the portal has anything on screen yet.
const _SPAWN_REVEAL_DELAY := 0.1

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

# Windup (Network.action_windup) for models whose scene root sets
# metadata/swing_impact — seconds into "Swing" where the blow lands. The
# windup plays Swing up to that point, timed to arrive on the server's hit,
# and holds the pose there; ActionOk plays the rest. Models without it just
# play the whole Swing on ActionOk.
const _SWING_IMPACT_META := &"swing_impact"
# Slowest the lead-in plays — a long windup reaches the impact pose early and
# holds it instead of crawling there in slow motion.
const _WINDUP_MIN_SPEED := 0.6
# How long past the expected hit to keep holding before giving up on an
# ActionOk that isn't coming (e.g. a ranged attack resolves as FreeAimShot).
const _WINDUP_GRACE := 0.5

var _swing_impacts: Dictionary = {}  # net_id -> seconds into Swing, for models that set it
var _windup_until:  Dictionary = {}  # net_id -> Time.get_ticks_msec() to stop holding a windup

# Chests are units that never move. Whether one is open is per player and
# never sent ahead of time — it's learned from the server's ChestResult to our
# own E-press, so a chest we looted in an earlier session shows closed until
# we try it once more and the server answers "already opened".
var chests:        Dictionary = {}  # net_id -> true, every chest unit currently known
var opened_chests: Dictionary = {}  # net_id -> true, chests the server said we've looted
var _chest_anims:  Dictionary = {}  # net_id -> AnimationPlayer (Closed/Open clips)
const _CHEST_SCALE := 0.5

# FrozenStarlights are units only so E can name them by net id (InteractEntity);
# the crystal itself, and its collision, come from world.bin's static object.
var starlights: Dictionary = {}  # net_id -> true, every FrozenStarlight unit currently known

var _mesh_by_type:  Dictionary = {}  # unit_type (int) -> PackedScene
var _slime_scenes: Array     = []  # index by (variant >> 6) & 0x3

# NPC speech bubble: a single 2D BBCode RichTextLabel, screen-projected each
# frame to sit chest-high above the NPC's body, shown whenever the server
# relays a reply (Network.npc_speech). One node per NPC (not several stitched
# together) so text wrapped in a pair of '*' (npcs.json's convention for
# keywords, e.g. "Would you like to *Trade*?") can just be colored inline via
# BBCode instead of manually laying out separate labels side by side.
const _NPC_SPEECH_HEIGHT     := 0.93  # share of the body's full height (_body_dims), up from body.position at the feet
const _NPC_SPEECH_JITTER     := 0.3  # random x/y offset so replies don't always land in the same spot
const _NPC_SPEECH_HIDE_DELAY := 6.0
const _NPC_SPEECH_COLOR      := Color.YELLOW
const _CHEST_SPEECH_COLOR    := Color.WHITE  # a chest "speaking", e.g. "Not enough room"
const _NPC_HIGHLIGHT_COLOR   := Color(0.55, 0.8, 1.0)  # lightish blue
const _NPC_SPEECH_FONT_SIZE  := 16

@onready var _npc_speech_camera: Camera3D = $"../Camera3D"
var _npc_speech_canvas: CanvasLayer

var _npc_labels:  Dictionary = {}  # net_id (int) -> RichTextLabel
var _npc_offsets: Dictionary = {}  # net_id (int) -> Vector3, world-space offset above the body
var _npc_active:  Dictionary = {}  # net_id (int) -> bool, true while the reply hasn't timed out yet
var _npc_timers:  Dictionary = {}  # net_id (int) -> Timer

# The server tracks position.y as the center of a physics sphere resting on
# the ground (stone_gaze/src/systems/physics.cpp: terrain_surface = sample_floor
# (...) + rb.radius, applied identically whether grounded, jumping, falling, or
# swimming) — so the Y it sends is always ground_height + radius, never literal
# feet height. Subtracted unconditionally in every anim state, since the
# server's offset is constant across all of them — conditioning this on Ground
# state (as an earlier attempt did) reintroduces exactly the pop this avoids,
# right at the Ground/Jump boundary.
# Each unit's body arrives in SpawnUnit (stone_gaze models.json, the single
# source): x = radius, y = height, spanning position.y - radius (feet) to
# position.y + height. Zero for units with no body (chests — y is the floor).
var _body_dims: Dictionary = {}  # net_id (int) -> Vector2(radius, height)
const _DEFAULT_BODY := Vector2(0.5, 1.0)  # ModelDef defaults, until SpawnUnit says otherwise
var _body_cols:  Dictionary = {}  # net_id -> CollisionShape3D sized to _body_dims
var _fit_models: Dictionary = {}  # net_id -> model root scaled to its body's height (players)
static var _model_tops: Dictionary = {}  # scene path -> _model_top()

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
	_mesh_by_type[Protocol.UNIT_GOBLIN]    = load("res://assets/meshes/goblin01.glb")
	_mesh_by_type[Protocol.UNIT_DEMON]     = load("res://assets/monsters/low_poly_demon_man_v_3.tscn")
	_mesh_by_type[Protocol.UNIT_RAT]       = load("res://assets/monsters/Rat.tscn")
	_mesh_by_type[Protocol.UNIT_CAVE_RAT]  = load("res://assets/monsters/CaveRat.tscn")
	_mesh_by_type[Protocol.UNIT_NPC]       = load("res://assets/npcs/Feras.tscn")
	_mesh_by_type[Protocol.UNIT_VALKYRIE]  = load("res://assets/monsters/Valkyrie.tscn")
	_mesh_by_type[Protocol.UNIT_CHEST]     = load("res://assets/meshes/chest01.glb")
	_slime_scenes = [
		load("res://assets/monsters/GreenSlime.tscn"),  # 0 green
		load("res://assets/slime_blue.glb"),             # 1 blue
		load("res://assets/slime_red.glb"),              # 2 red
		load("res://assets/monsters/GreenSlime.tscn"),  # 3 fallback
	]

	Network.unit_spawned.connect(_on_unit_spawned)
	Network.unit_pos.connect(_on_unit_pos)
	Network.unit_destroyed.connect(_on_unit_destroyed)
	Network.unit_resized.connect(set_body_size)
	Network.xp_gained.connect(_on_xp_gained)
	Network.level_up.connect(_on_level_up)
	Network.action_ok.connect(_on_action_ok)
	Network.action_windup.connect(_on_action_windup)
	Network.npc_speech.connect(_on_npc_speech)
	Network.chest_result.connect(_on_chest_result)
	Network.login_ok.connect(func(_id: int): opened_chests.clear())
	GameState.first_person_changed.connect(set_first_person)
	call_deferred(&"_prewarm_xp_shader")

	_npc_speech_canvas = CanvasLayer.new()
	add_child(_npc_speech_canvas)

func _on_unit_destroyed(net_id: int) -> void:
	if entities.has(net_id):
		entities[net_id].queue_free()
		entities.erase(net_id)
		_body_dims.erase(net_id)
		_body_cols.erase(net_id)
		_fit_models.erase(net_id)
		_targets.erase(net_id)
		_anim_players.erase(net_id)
		_current_anim.erase(net_id)
		_swing_impacts.erase(net_id)
		_windup_until.erase(net_id)
		_pitch_tilts.erase(net_id)
		if _npc_labels.has(net_id):
			_npc_labels[net_id].queue_free()  # also frees its child Timer, see _on_npc_speech
		_npc_labels.erase(net_id)
		_npc_offsets.erase(net_id)
		_npc_active.erase(net_id)
		_npc_timers.erase(net_id)
		chests.erase(net_id)
		_chest_anims.erase(net_id)
		starlights.erase(net_id)

func _on_npc_speech(npc_net_id: int, _target_player_net_id: int, text: String) -> void:
	if not entities.has(npc_net_id):
		return
	var label := _npc_labels.get(npc_net_id) as RichTextLabel
	if label == null:
		label = RichTextLabel.new()
		label.bbcode_enabled = true
		label.fit_content = true
		label.scroll_active = false
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		label.add_theme_font_size_override("normal_font_size", _NPC_SPEECH_FONT_SIZE)
		label.add_theme_color_override("default_color",
			_CHEST_SPEECH_COLOR if chests.has(npc_net_id) else _NPC_SPEECH_COLOR)
		label.add_theme_constant_override("outline_size", 3)
		label.add_theme_color_override("font_outline_color", Color.BLACK)
		label.visible = false
		_npc_speech_canvas.add_child(label)
		_npc_labels[npc_net_id] = label

		var timer := Timer.new()
		timer.one_shot = true
		timer.wait_time = _NPC_SPEECH_HIDE_DELAY
		timer.timeout.connect(func(): _npc_active[npc_net_id] = false)
		label.add_child(timer)
		_npc_timers[npc_net_id] = timer

	var dims: Vector2 = _body_dims.get(npc_net_id, _DEFAULT_BODY)
	_npc_offsets[npc_net_id] = Vector3(randf_range(-_NPC_SPEECH_JITTER, _NPC_SPEECH_JITTER),
		(dims.x + dims.y) * _NPC_SPEECH_HEIGHT + randf_range(-_NPC_SPEECH_JITTER, _NPC_SPEECH_JITTER), 0.0)
	label.text = Protocol.text_to_bbcode(text, _NPC_HIGHLIGHT_COLOR)
	label.reset_size()
	_npc_active[npc_net_id] = true
	(_npc_timers[npc_net_id] as Timer).start()

# Screen-projects each active NPC label to sit above wherever its body
# currently is, and hides it while its NPC is behind the camera (unproject
# gives nonsense screen coordinates for points behind the viewer).
func _update_npc_speech_labels() -> void:
	for npc_id: int in _npc_labels:
		var label: RichTextLabel = _npc_labels[npc_id]
		var body: Node3D = entities.get(npc_id)
		if body == null or not _npc_active.get(npc_id, false):
			label.visible = false
			continue
		var world_pos: Vector3 = body.global_position + (_npc_offsets[npc_id] as Vector3)
		if _npc_speech_camera.is_position_behind(world_pos):
			label.visible = false
			continue
		label.visible = true
		label.position = _npc_speech_camera.unproject_position(world_pos) - label.size * 0.5

func _process(delta: float) -> void:
	_update_npc_speech_labels()
	var t := 1.0 - exp(-GameState.interp_rate * delta)
	for net_id: int in _targets:
		var body := entities.get(net_id) as StaticBody3D
		if body == null:
			continue
		var tgt: Dictionary = _targets[net_id]
		body.position   = body.position.lerp(tgt.pos, t)
		_drive_animation(net_id, tgt)
		if net_id == GameState.player_net_id:
			# Own body faces the exact local camera yaw — the server's UnitPos
			# yaw is rounded to 11.25° steps, fine for others but visibly
			# steppy on yourself. Same +PI convention as _on_unit_pos.
			body.rotation.y = _npc_speech_camera.yaw + PI
			player_moved.emit(body.position)
			if _player_head:
				player_head_moved.emit(_player_eye(net_id, body))
		elif chests.has(net_id):
			body.rotation.y = tgt.rot_y
		else:
			body.rotation.y = lerp_angle(body.rotation.y, tgt.rot_y, t)
			var tilt := _pitch_tilts.get(net_id) as PitchTilt
			if tilt:
				tilt.target_pitch = tgt.pitch

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

# White droplet swarm (assets/effects/xp_sparkle.tscn, same look as the blood
# splatter) that streams around the orb as it flies to the player.
const _XP_SPARKLE_SCENE := preload("res://assets/effects/xp_sparkle.tscn")

# Runs the prefab once off-screen at startup so the first real XP orb doesn't
# hitch on shader compilation.
func _prewarm_xp_shader() -> void:
	var warmup := _XP_SPARKLE_SCENE.instantiate() as GPUParticles3D
	warmup.position = Vector3(0.0, -9999.0, 0.0)
	warmup.amount = 1
	warmup.one_shot = true
	warmup.emitting = true
	get_parent().add_child(warmup)
	warmup.finished.connect(warmup.queue_free)

func _spawn_xp_orb(from: Vector3, target_net_id: int) -> void:
	var particles := _XP_SPARKLE_SCENE.instantiate() as GPUParticles3D
	particles.position = from
	particles.emitting = true
	get_parent().add_child(particles)
	_xp_orbs.append({node = particles, target_id = target_net_id, speed = 1.0})

func set_first_person(fp: bool) -> void:
	if entities.has(GameState.player_net_id):
		var body := entities[GameState.player_net_id] as StaticBody3D
		for mi in body.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).visible = not fp

func _on_unit_spawned(net_id: int, unit_type: int, variant: int, pos: Vector3, _anim_state: int, radius: float, height: float) -> void:
	if entities.has(net_id):   # built from an earlier UnitPos, at the default size
		set_body_size(net_id, radius, height)
		return
	_body_dims[net_id] = Vector2(radius, height)
	var body := _make_body(net_id, unit_type, variant)
	pos.y -= radius
	body.position = pos
	get_parent().add_child(body)
	entities[net_id] = body
	if unit_type == Protocol.UNIT_CHEST:
		_setup_chest(net_id, body)
		return
	if unit_type == Protocol.UNIT_FROZEN_STARLIGHT:
		starlights[net_id] = true
		return
	_apply_variant(body, unit_type, variant)
	_cache_anim_player(net_id, body)
	_attach_pitch_tilt(net_id, body)
	if unit_type != Protocol.UNIT_PLAYER and unit_type != Protocol.UNIT_NPC:
		_delay_monster_reveal(body)

# Hides a freshly spawned monster's own meshes for a beat (see
# _SPAWN_REVEAL_DELAY) — not the portal, which effects.gd shows immediately.
func _delay_monster_reveal(body: Node3D) -> void:
	var meshes := body.find_children("*", "MeshInstance3D", true, false)
	for mi: MeshInstance3D in meshes:
		mi.visible = false
	get_tree().create_timer(_SPAWN_REVEAL_DELAY).timeout.connect(func():
		for mi in meshes:
			if is_instance_valid(mi):
				mi.visible = true
	)

func _on_unit_pos(net_id: int, unit_type: int, variant: int, pos: Vector3, rot_y: float, pitch: float, anim_state: int) -> void:
	# Chest models are authored facing the server's own yaw convention.
	var rot := rot_y if unit_type == Protocol.UNIT_CHEST else rot_y + PI
	pos.y -= (_body_dims.get(net_id, _DEFAULT_BODY) as Vector2).x
	if not entities.has(net_id):
		var body := _make_body(net_id, unit_type, variant)
		# Snap on first sight — nothing to interpolate from yet, and easing in
		# from the body's default (0,0,0) would visibly slide it into place.
		body.position   = pos
		body.rotation.y = rot
		get_parent().add_child(body)
		entities[net_id] = body
		if unit_type == Protocol.UNIT_CHEST:
			_setup_chest(net_id, body)
		elif unit_type == Protocol.UNIT_FROZEN_STARLIGHT:
			starlights[net_id] = true
		else:
			_apply_variant(body, unit_type, variant)
			_cache_anim_player(net_id, body)
			_attach_pitch_tilt(net_id, body)

	# Moving is inferred from how far this tick's position is from the last
	# one — the server doesn't split Ground into idle/walk/run on its own.
	var is_moving := false
	if _targets.has(net_id):
		var jump := (pos - (_targets[net_id].pos as Vector3)).length()
		is_moving = jump > _MOVE_EPS
		if jump > _SNAP_DIST:
			entities[net_id].position = pos
	_targets[net_id] = {pos = pos, rot_y = rot, pitch = pitch, anim_state = anim_state, is_moving = is_moving}

func _make_body(net_id: int, unit_type: int, variant: int = 0) -> StaticBody3D:
	var body: StaticBody3D
	if net_id == GameState.player_net_id:
		body = _PLAYER_SCENE.instantiate() as StaticBody3D
		for mi in body.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).visible = not GameState.first_person
		_player_head = body.find_child("Head", true, false) as Node3D
		_player_head_offset_valid = false
	else:
		body = StaticBody3D.new()
		if unit_type == Protocol.UNIT_FROZEN_STARLIGHT:
			body.set_meta("net_id", net_id)
			return body
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
		if unit_type == Protocol.UNIT_CHEST:
			mesh_node.scale = Vector3.ONE * _CHEST_SCALE
			# Same footprint as the server's wall-style collider (chest.cpp).
			var box := BoxShape3D.new()
			box.size = Vector3(1.25, 0.77, 0.74)
			var box_col := CollisionShape3D.new()
			box_col.shape = box
			box_col.position = Vector3(0.0, 0.385, -0.24)
			body.add_child(box_col)
			body.set_meta("net_id", net_id)
			return body
		if unit_type == Protocol.UNIT_PLAYER or unit_type == Protocol.UNIT_NPC:
			_fit_models[net_id] = mesh_node
	if net_id == GameState.player_net_id:
		_fit_models[net_id] = body.get_node("Mesh")
	# The server's body (see _body_dims), sized by _apply_body_size.
	var col := CollisionShape3D.new()
	col.shape = CylinderShape3D.new()
	body.add_child(col)
	_body_cols[net_id] = col
	body.set_meta("net_id", net_id)
	_apply_body_size(net_id)
	return body

# SpawnUnit's size, or a later UnitSize (Wild Growth) for a unit already here.
func set_body_size(net_id: int, radius: float, height: float) -> void:
	_body_dims[net_id] = Vector2(radius, height)
	_apply_body_size(net_id)

func _apply_body_size(net_id: int) -> void:
	var dims: Vector2 = _body_dims.get(net_id, _DEFAULT_BODY)
	var col := _body_cols.get(net_id) as CollisionShape3D
	if col != null:
		var shape := col.shape as CylinderShape3D
		shape.radius = dims.x
		shape.height = dims.x + dims.y
		# body.position is ground/feet level (see the XP-orb +Vector3(0,1.2,0)
		# offset elsewhere in this file); a CylinderShape3D is centered on its
		# own origin, so without this lift half the collider sits buried
		# underground. Mirrors world_data.gd's _with_cylinder_collision.
		col.position.y = shape.height * 0.5
	var model := _fit_models.get(net_id) as Node3D
	if model != null:
		var top := _model_top(model)
		if top > 0.0:
			model.scale = Vector3.ONE * (dims.x + dims.y) / top
	if net_id == GameState.player_net_id:
		_player_head_offset_valid = false
		player_body_changed.emit(dims.x, dims.y)

# Height of a model's mesh above its origin at scale 1, in its rest pose —
# measured once per scene, before anything (equipment) is attached to it.
func _model_top(model: Node3D) -> float:
	var key := model.scene_file_path
	if _model_tops.has(key):
		return _model_tops[key]
	var top := 0.0
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		var xf := mi.transform
		var p := mi.get_parent()
		while p != model:
			if p is Node3D:
				xf = (p as Node3D).transform * xf
			p = p.get_parent()
		top = maxf(top, (xf * mi.get_aabb()).end.y)
	if not key.is_empty():
		_model_tops[key] = top
	return top

func _setup_chest(net_id: int, body: Node3D) -> void:
	chests[net_id] = true
	var players := body.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		_chest_anims[net_id] = players[0]
	_set_chest_lid(net_id, opened_chests.has(net_id), false)

# Plays the lid open (animate) or snaps straight to its end pose — a chest we
# already know we looted, coming back into view or answered "already opened".
func _set_chest_lid(net_id: int, open: bool, animate: bool) -> void:
	var player := _chest_anims.get(net_id) as AnimationPlayer
	if player == null:
		return
	var clip := "Open" if open else "Closed"
	if not player.has_animation(clip):
		return
	player.get_animation(clip).loop_mode = Animation.LOOP_NONE
	player.play(clip)
	if not animate:
		player.seek(player.current_animation_length, true)

func _on_chest_result(chest_net_id: int, result: int) -> void:
	match result:
		Protocol.CHEST_OPENED:
			opened_chests[chest_net_id] = true
			_set_chest_lid(chest_net_id, true, true)
		Protocol.CHEST_ALREADY_OPENED:
			opened_chests[chest_net_id] = true
			_set_chest_lid(chest_net_id, true, false)
		# CHEST_NO_ROOM: the chest says so itself via NpcSpeech.

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

func _player_eye(net_id: int, body: Node3D) -> Vector3:
	if _current_anim.get(net_id) in _LOCOMOTION_CLIPS or not _player_head_offset_valid:
		_player_head_offset = body.to_local(_player_head.global_position)
		_player_head_offset_valid = true
		return _player_head.global_position
	return body.to_global(_player_head_offset)

# Not for the local player: the FP camera follows the Head bone (_player_head),
# so bending our own spine would move our eye.
func _attach_pitch_tilt(net_id: int, body: Node3D) -> void:
	if net_id == GameState.player_net_id:
		return
	var skeleton := body.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null or not PitchTilt.has_spine(skeleton):
		return
	var tilt := PitchTilt.new()
	skeleton.add_child(tilt)
	_pitch_tilts[net_id] = tilt

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
	# The model's scene root is the body's direct child (player.tscn's Mesh
	# for the local player).
	for child in body.get_children():
		if child.has_meta(_SWING_IMPACT_META):
			_swing_impacts[net_id] = float(child.get_meta(_SWING_IMPACT_META))

func _on_action_ok(actor_id: int, effect: int, _target_id: int, action_type: int) -> void:
	# Any resolved action ends a held windup, swing or not.
	var was_winding_up: bool = _windup_until.erase(actor_id)
	if action_type != Protocol.ACTION_ATTACK or effect != Protocol.EFFECT_SWING:
		return
	var player := _anim_players.get(actor_id) as AnimationPlayer
	if player == null or not player.has_animation("Swing"):
		return
	# stop() first: play() on the clip already loaded would just resume it.
	player.stop(true)
	if was_winding_up:
		player.play_section("Swing", _swing_impacts[actor_id])
	else:
		player.play("Swing")
	_current_anim[actor_id] = "Swing"

func _on_action_windup(actor_id: int, action_type: int, windup: float) -> void:
	var player := _anim_players.get(actor_id) as AnimationPlayer
	if player == null or not _swing_impacts.has(actor_id) or not player.has_animation("Swing"):
		return
	if action_type == Protocol.ACTION_NOTHING:
		# Cancelled — let _drive_animation resume locomotion.
		if _windup_until.erase(actor_id):
			player.stop()
			_current_anim.erase(actor_id)
		return
	if action_type != Protocol.ACTION_ATTACK and action_type != Protocol.ACTION_ABILITY:
		return
	var impact: float = _swing_impacts[actor_id]
	var speed := maxf(impact / maxf(windup, 0.01), _WINDUP_MIN_SPEED)
	player.stop(true)
	player.play_section("Swing", 0.0, impact, -1, speed)
	_current_anim[actor_id] = "Swing"
	_windup_until[actor_id] = Time.get_ticks_msec() + int((windup + _WINDUP_GRACE) * 1000.0)

func _drive_animation(net_id: int, tgt: Dictionary) -> void:
	var player := _anim_players.get(net_id) as AnimationPlayer
	if player == null:
		return
	# Hold a windup's impact pose until ActionOk, a cancel, or the grace runs out.
	if _windup_until.has(net_id):
		if Time.get_ticks_msec() < _windup_until[net_id]:
			return
		_windup_until.erase(net_id)
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
