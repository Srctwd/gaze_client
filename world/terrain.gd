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

# Returns the nearest static object of the given type within max_dist (horizontal distance),
# as {"x": float, "z": float}, or null if none in range.
func nearest_static_object(pos: Vector3, obj_type: int, max_dist: float) -> Variant:
	if _wd == null: return null
	var best: Variant = null
	var best_dist := max_dist
	for obj in _wd._static_objects:
		if obj.type != obj_type: continue
		var d := Vector2(pos.x - (obj.x as float), pos.z - (obj.z as float)).length()
		if d <= best_dist:
			best_dist = d
			best = obj
	return best
