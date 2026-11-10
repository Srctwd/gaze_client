extends Node3D
class_name ItemPrefab

## Fired instead of the item's own model when used at range (dagger throw,
## arrow, staff bolt). Null = melee. Shared across items that use the same
## projectile visual (e.g. multiple arrow types).
@export var projectile_scene: PackedScene

## Played when a hit with this item lands (sounds/hit_<name>.wav) — melee,
## or a ranged shot whose projectile leaves its own hit_sound on "default".
## Same list as Projectile.hit_sound.
@export_enum("default", "blunt", "slash", "pierce", "rock", "fire", "magic") var hit_sound: String = "default"

## Returns the HandGrip (or, for headgear, HeadGrip; for body armor, ChestGrip)
## marker's frame relative to wherever this node itself ends up parented
## (this node's own baked transform composed with the marker's local one),
## position and rotation only — the item's baked scale stays its own. The
## caller parents this node under grip.affine_inverse(), which puts the marker
## on the anchor, axes on the anchor's axes: turning the marker turns how the
## item is held, without ever touching this node's own transform, which would
## destroy the model's baked scale/rotation.
func get_grip_transform() -> Transform3D:
	var marker := get_node_or_null(^"HandGrip") as Node3D
	if marker == null:
		marker = get_node_or_null(^"HeadGrip") as Node3D
	if marker == null:
		marker = get_node_or_null(^"ChestGrip") as Node3D
	return _frame(marker) if marker else Transform3D.IDENTITY

## Same as get_grip_transform, for the first-person copy (viewmodel.gd): the
## FirstPersonGrip marker, so an item can sit differently in the first-person
## hand than on a body. Falls back to the regular grip.
func get_first_person_grip_transform() -> Transform3D:
	var marker := get_node_or_null(^"FirstPersonGrip") as Node3D
	return _frame(marker) if marker else get_grip_transform()

func _frame(marker: Node3D) -> Transform3D:
	var xform := transform * marker.transform
	return Transform3D(xform.basis.orthonormalized(), xform.origin)
