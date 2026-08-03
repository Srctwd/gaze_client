extends Node3D
class_name Projectile

## Cosmetic in-flight spin applied on spawn (e.g. a thrown dagger tumbling).
## A runtime random value can't be baked into the scene, so it's opt-in here.
@export var random_roll_tumble: bool = false
