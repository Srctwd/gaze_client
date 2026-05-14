extends Node3D

const WorldData = preload("res://world/world_data.gd")

func _ready() -> void:
	var wd := WorldData.new()
	if wd.load("res://world.bin"):
		wd.spawn_into(self)
