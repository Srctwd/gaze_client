@tool
extends Node3D
class_name BerryBush

## How many berries hang on the bush: the first berry_count children of
## "Berries" show, the rest hide. entity_manager.gd sets it from the unit's
## variant (berries left). The children are ordered so any prefix is spread
## around the bush rather than bunched on one side.
@export_range(0, 12) var berry_count: int = 12:
	set(value):
		berry_count = value
		_apply()

func _ready() -> void:
	_apply()

func _apply() -> void:
	var berries := get_node_or_null(^"Berries")
	if berries == null:
		return
	for i in berries.get_child_count():
		(berries.get_child(i) as Node3D).visible = i < berry_count
