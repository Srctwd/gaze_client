extends Node3D
class_name ItemPrefab

## Fired instead of the item's own model when used at range (dagger throw,
## arrow, staff bolt). Null = melee. Shared across items that use the same
## projectile visual (e.g. multiple arrow types).
@export var projectile_scene: PackedScene

## Returns the HandGrip (or, for headgear, HeadGrip; for body armor, BodyGrip) marker's transform relative to wherever this node
## itself ends up parented (composing this node's own baked transform with
## the marker's local one) — the caller aligns to this without ever touching
## this node's own transform, which would destroy the model's baked scale/rotation.
func get_grip_transform() -> Transform3D:
	var marker := get_node_or_null(^"HandGrip") as Node3D
	if marker == null:
		marker = get_node_or_null(^"HeadGrip") as Node3D
	if marker == null:
		marker = get_node_or_null(^"BodyGrip") as Node3D
	return transform * marker.transform if marker else Transform3D.IDENTITY
