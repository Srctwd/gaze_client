extends Node3D

const WorldData = preload("res://world/world_data.gd")

var _wd: RefCounted = null

func _ready() -> void:
	_wd = WorldData.new()
	if _wd.load("res://world.bin"):
		_wd.spawn_into(self)

func is_in_water(pos: Vector3) -> bool:
	if _wd == null: return false
	for wr in _wd._water_rects:
		var hw := (wr.width as float) * 0.5
		var hd := (wr.depth as float) * 0.5
		if pos.x >= wr.x - hw and pos.x <= wr.x + hw \
		and pos.z >= wr.z - hd and pos.z <= wr.z + hd \
		and pos.y <= wr.y:
			return true
	return false
