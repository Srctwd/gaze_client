extends Node3D
class_name ItemPrefab

## Fired instead of the item's own model when used at range (dagger throw, arrow, staff bolt). Null = melee.
@export var projectile_scene: PackedScene

## Marker3D child — the point on the model that should align to the hand/FP anchor.
## Lets each item define its own grip (a staff held near the base vs. a dagger held by the blade)
## instead of every item sharing one fixed _HAND_POS/_HAND_ROT.
@export var grip_point: NodePath = ^"HandGrip"

## Optional — name of a clip on this scene's own AnimationPlayer, played on attack.
## Left empty, the caller falls back to the current generic swing tween, so simple
## melee items (stick) don't need to author an animation at all.
@export var attack_animation: StringName = &""

## Returns the grip marker's transform relative to wherever this node itself
## ends up parented (composing this node's own baked transform with the
## marker's local one) — the caller aligns to this without ever touching
## this node's own transform, which would destroy the model's baked scale/rotation.
func get_grip_transform() -> Transform3D:
	var marker := get_node_or_null(grip_point) as Node3D
	return transform * marker.transform if marker else Transform3D.IDENTITY

func has_attack_animation() -> bool:
	return not attack_animation.is_empty()
