extends Node3D
class_name Projectile

## Cosmetic in-flight spin applied on spawn (e.g. a thrown dagger tumbling).
## A runtime random value can't be baked into the scene, so it's opt-in here.
@export var random_roll_tumble: bool = false

## Played when this projectile hits (sounds/hit_<name>.wav); "default" falls
## back to the weapon item's own hit_sound. Same list as ItemPrefab.hit_sound.
@export_enum("default", "blunt", "slash", "pierce", "rock", "fire", "magic") var hit_sound: String = "default"
