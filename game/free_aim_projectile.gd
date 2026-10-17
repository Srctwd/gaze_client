class_name FreeAimProjectile
extends Node3D

# Client-only approximation of the server's projectile collision (see
# projectile_system in stone_gaze/src/systems/projectile.cpp) — stops this
# visual when it hits terrain, a wall, a static object (WorldData's
# COLLISION_LAYER_WORLD), or a player/monster body, instead of always flying
# the full max_range. No sync message exists between server and client for
# this, so the exact stop point can differ slightly (different collision
# geometry, different tick timing) — this only removes the obviously-wrong
# "flies through everything" case.
#
# Moves by directly setting position each physics tick (not move_and_slide),
# so detection has to be a swept segment test — a plain Area3D/body_entered
# overlap check isn't continuous and could tunnel through a thin wall between
# ticks at these speeds. The sweep is a small sphere (not a zero-width ray) so
# a shot that visibly grazes a monster still counts as touching it, and a
# shot that starts already overlapping one (point-blank) stops at once — a
# ray cast from inside a shape reports nothing.

const COLLISION_LAYER_WORLD := 2   # matches WorldData.COLLISION_LAYER_WORLD
const COLLISION_LAYER_ENTITY := 1  # Godot's implicit default layer — every
                                    # existing player/monster StaticBody3D
                                    # sits here, since entity_manager.gd never
                                    # sets collision_layer explicitly
const COLLISION_MASK := COLLISION_LAYER_WORLD | COLLISION_LAYER_ENTITY
const HIT_RADIUS := 0.15
const GROUP := &"free_aim_projectiles"

var dir: Vector3
var speed: float = 0.0
var max_range: float = 0.0
var shooter_id: int = 0
var _exclude: Array[RID] = []
var _shape := SphereShape3D.new()

var _traveled: float = 0.0


# `exclude` should carry the shooter's own StaticBody3D RID so the shot can't
# immediately register a hit on itself at spawn — mirrors the server's
# `candidate == p.owner` exclusion in projectile_system.
# `p_shooter_id` lets effects.gd find this shot again when the server reports
# the hit itself (UnitHit) — see Effects._on_unit_hit.
func launch(p_dir: Vector3, p_speed: float, p_max_range: float, exclude: Array[RID] = [], p_shooter_id: int = 0) -> void:
	dir = p_dir
	speed = p_speed
	max_range = p_max_range
	_exclude = exclude
	shooter_id = p_shooter_id
	_shape.radius = HIT_RADIUS
	add_to_group(GROUP)


func _physics_process(delta: float) -> void:
	if speed <= 0.0:
		queue_free()
		return

	var step := speed * delta
	if _traveled + step >= max_range:
		step = max_range - _traveled

	var from := global_position
	var to := from + dir * step

	var space_state := get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _shape
	query.transform = Transform3D(Basis(), from)
	query.motion = to - from
	query.collision_mask = COLLISION_MASK
	query.exclude = _exclude
	# [safe, unsafe] fractions of the motion; [1, 1] = nothing in the way,
	# [0, 0] = already overlapping something at `from`.
	var fractions := space_state.cast_motion(query)

	if fractions[1] < 1.0:
		global_position = from + (to - from) * fractions[1]
		queue_free()
		return

	global_position = to
	_traveled += step
	if _traveled >= max_range:
		queue_free()
