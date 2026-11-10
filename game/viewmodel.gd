extends CanvasLayer
## First-person held items, drawn over the 3D view like UI so walls never hide
## them. Held items here are on LAYER; the main camera never draws that layer,
## and this overlay's camera — a copy of the main one — draws only it, into a
## transparent SubViewport sharing the main World3D (same lights and environment). Under ps2.gd's post layer (-1),
## so PS2 dither and line filter apply to it too.
##
## A camera only uses the lights whose layers it sees, so every Light3D (sun,
## moon, torches, effects) also gets LAYER, or the held items render unlit.
##
## The held items here are their own copies (set_item), on the hands of a
## first-person rig in front of the overlay camera: Human, mesh hidden, its
## head at the eye, holding them on its FirstPersonHandGrip/
## FirstPersonOffHandGrip markers (tuned for the view, apart from the
## HandGrip/OffHandGrip a Human body holds by) whatever body model players
## use. It plays its Swing on our melee windups and swings,
## Idle otherwise — not Walk, whose arms are just a different still pose, so
## switching to it (on every network tick that says we moved) jolted them. equipment.gd hides the body's copies in
## first person.

const LAYER := 1 << 19   # render layer 20

const _RIG_SCENE := preload("res://assets/monsters/Human2.tscn")
const _RIG_HEIGHT := 2.0   # m, a player body's (radius 0.3 + height 1.7)
const _HAND_MARKERS: Array[String] = ["FirstPersonHandGrip", "FirstPersonOffHandGrip"]
# Where Swing's windup ends: the hand cocked at head height, before the chop.
const _SWING_IMPACT := 0.6
# Same as entity_manager.gd's windup handling.
const _WINDUP_MIN_SPEED := 0.6

static var current   # the one under the main camera, for equipment.gd (untyped: no class_name)

var _main: Camera3D
var _view: SubViewport
var _cam: Camera3D
var _rig: Node3D
var _anim: AnimationPlayer
var _hands: Array[Node3D] = []    # [main hand, off hand] grip markers on the rig
# Holding a windup's end pose. Only the server ends it: ActionOk, a cancel
# (ActionWindup with ACTION_NOTHING), or a FreeAimShot (a ranged attack).
var _winding_up := false
var _swinging := false


func _ready() -> void:
	layer = -2
	process_priority = 1000   # after everything that moves the main camera (entity_manager, input)
	_main = get_parent() as Camera3D
	_main.cull_mask &= ~LAYER

	var box := SubViewportContainer.new()
	box.stretch = true
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view = SubViewport.new()
	_view.transparent_bg = true
	_view.gui_disable_input = true
	_cam = Camera3D.new()
	_cam.cull_mask = LAYER
	_view.add_child(_cam)
	box.add_child(_view)
	add_child(box)
	_cam.current = true
	_make_rig()
	current = self

	for light in get_tree().root.find_children("*", "Light3D", true, false):
		_light_on_layer(light)
	get_tree().node_added.connect(_light_on_layer)
	GameState.first_person_changed.connect(_set_on)
	_set_on(GameState.first_person)
	# The held items are the local player's: a new one (death, relog) starts
	# empty-handed, since the server sends EquipSync only for filled slots.
	GameState.player_id_changed.connect(func(_id: int) -> void:
		for hand in _hands.size():
			set_item(hand, null))
	Network.action_windup.connect(_on_action_windup)
	Network.action_ok.connect(_on_action_ok)
	Network.free_aim_shot.connect(_on_free_aim_shot)


# The rig faces the view (models face +Z, the camera looks down -Z), standing
# so its Head marker, in the Idle pose, is at the camera; the first-person
# markers place the held items from there. Its own mesh is hidden; it's in the
# shared world, where the main camera would see it.
func _make_rig() -> void:
	_rig = _RIG_SCENE.instantiate() as Node3D
	# Fit like entity_manager.gd fits a body to its height.
	_rig.scale = Vector3.ONE * _RIG_HEIGHT / ModelBounds.rest_aabb(_rig).end.y
	_rig.rotation.y = PI
	_cam.add_child(_rig)
	for mi in _rig.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).visible = false
	for marker in _HAND_MARKERS:
		_hands.append(_rig.find_child(marker, true, false) as Node3D)
	_anim = _rig.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_anim.get_animation("Idle").loop_mode = Animation.LOOP_LINEAR
	_anim.speed_scale *= 2.0   # TEMP: 2x speed for testing
	_anim.animation_finished.connect(func(_clip: StringName) -> void: _swinging = false)
	_anim.play("Idle")
	_anim.seek(0.0, true)
	_rig.position = -(_rig.basis * _posed_in_rig(_rig.find_child("Head", true, false) as Node3D).origin)


# A marker on a BoneAttachment3D, in rig space, at the skeleton's current pose
# (the attachment itself only catches up on the skeleton's next update).
func _posed_in_rig(marker: Node3D) -> Transform3D:
	var attachment := marker.get_parent() as BoneAttachment3D
	var skeleton := attachment.get_parent() as Skeleton3D
	var xform := skeleton.get_bone_global_pose(skeleton.find_bone(attachment.bone_name)) * marker.transform
	var node: Node = skeleton
	while node != _rig:
		xform = (node as Node3D).transform * xform
		node = node.get_parent()
	return xform


## Shows `prefab` in hand 0 (main) or 1 (off), replacing what was there; null
## empties it. Placed like equipment.gd does on a body's grip markers, but by
## the item's FirstPersonGrip marker (ItemPrefab.get_first_person_grip_transform).
## Lights are left to the body's copy, which stays in the world (hidden), so a
## torch doesn't light everything twice.
func set_item(hand: int, prefab: PackedScene) -> void:
	for c in _hands[hand].get_children():
		c.queue_free()
	if prefab == null:
		return
	var node := prefab.instantiate()
	var grip := Transform3D.IDENTITY
	if node is ItemPrefab:
		grip = (node as ItemPrefab).get_first_person_grip_transform()
	var correction := Vector3.ONE / _hands[hand].global_transform.basis.get_scale()
	var wrapper := Node3D.new()
	wrapper.transform = Transform3D(Basis().scaled(correction)) * grip.affine_inverse()
	wrapper.add_child(node)
	_hands[hand].add_child(wrapper)
	for gi in wrapper.find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).layers = LAYER
	for light in wrapper.find_children("*", "Light3D", true, false):
		(light as Light3D).visible = false


# Windup: Swing up to its cocked pose, stretched over the windup, held until
# the server resolves it (see _winding_up).
func _on_action_windup(actor_id: int, action_type: int, windup: float) -> void:
	if actor_id != GameState.player_net_id:
		return
	if action_type == Protocol.ACTION_NOTHING:
		_winding_up = false
		_swinging = false
	elif action_type == Protocol.ACTION_ATTACK or action_type == Protocol.ACTION_ABILITY:
		_anim.stop(true)
		_anim.play_section("Swing", 0.0, _SWING_IMPACT, -1, maxf(_SWING_IMPACT / maxf(windup, 0.01), _WINDUP_MIN_SPEED))
		_winding_up = true
		_swinging = true


# Swing: the chop, from the cocked pose if there was a windup.
func _on_action_ok(actor_id: int, effect: int, _target_id: int, action_type: int) -> void:
	if actor_id != GameState.player_net_id:
		return
	var was_winding_up := _winding_up
	_winding_up = false
	if action_type != Protocol.ACTION_ATTACK or effect != Protocol.EFFECT_SWING:
		_swinging = false
		return
	_anim.stop(true)
	if was_winding_up:
		_anim.play_section("Swing", _SWING_IMPACT)
		# Or the first frame shows the clip's start (stop() rewound it).
		_anim.seek(_SWING_IMPACT, true)
	else:
		_anim.play("Swing")
	_swinging = true


# A ranged attack resolves as a FreeAimShot, not an ActionOk.
func _on_free_aim_shot(actor_id: int, _origin: Vector3, _yaw: float, _pitch: float, _speed: float, _range: float, _effect: int) -> void:
	if actor_id != GameState.player_net_id:
		return
	_winding_up = false
	_swinging = false


# Back to Idle once a swing ends or the server ends a windup.
func _drive_rig() -> void:
	if _winding_up or _swinging:
		return
	if _anim.current_animation != "Idle":
		_anim.play("Idle", 0.15)   # Swing ends a couple of cm off Idle's pose


func _light_on_layer(node: Node) -> void:
	if node is Light3D:
		(node as Light3D).layers |= LAYER


func _set_on(on: bool) -> void:
	visible = on
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED


# Last in the frame's process step, so the copy lands in the same frame as the
# main camera's own move (a copy made at frame_pre_draw only reaches the
# renderer a frame late). The 3D scaling follows the main view's, i.e. ps2.gd's
# 448-line mode; set only on change, since a new value rebuilds the buffers.
func _process(_delta: float) -> void:
	if not visible or not _main.is_inside_tree():
		return
	_drive_rig()
	_cam.global_transform = _main.global_transform
	_cam.near = _main.near
	_cam.far  = _main.far
	_cam.keep_aspect = _main.keep_aspect
	_cam.fov = _main.fov
	var vp := get_viewport()
	if _view.scaling_3d_mode != vp.scaling_3d_mode:
		_view.scaling_3d_mode = vp.scaling_3d_mode
	if _view.scaling_3d_scale != vp.scaling_3d_scale:
		_view.scaling_3d_scale = vp.scaling_3d_scale
