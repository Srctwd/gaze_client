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
# ticks at these speeds.

const COLLISION_LAYER_WORLD := 2   # matches WorldData.COLLISION_LAYER_WORLD
const COLLISION_LAYER_ENTITY := 1  # Godot's implicit default layer — every
                                    # existing player/monster StaticBody3D
                                    # sits here, since entity_manager.gd never
                                    # sets collision_layer explicitly
const COLLISION_MASK := COLLISION_LAYER_WORLD | COLLISION_LAYER_ENTITY

var dir: Vector3
var speed: float = 0.0
var max_range: float = 0.0
var _exclude: Array[RID] = []

var _traveled: float = 0.0


# `exclude` should carry the shooter's own StaticBody3D RID so the shot can't
# immediately register a hit on itself at spawn — mirrors the server's
# `candidate == p.owner` exclusion in projectile_system.
func launch(p_dir: Vector3, p_speed: float, p_max_range: float, exclude: Array[RID] = []) -> void:
	dir = p_dir
	speed = p_speed
	max_range = p_max_range
	_exclude = exclude


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
	var query := PhysicsRayQueryParameters3D.create(from, to, COLLISION_MASK, _exclude)
	var result := space_state.intersect_ray(query)

	if not result.is_empty():
		global_position = result.position
		queue_free()
		return

	global_position = to
	_traveled += step
	if _traveled >= max_range:
		queue_free()
