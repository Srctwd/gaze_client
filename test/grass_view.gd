extends SceneTree
# Off-screen render of the grass: saves the viewport to user://grass_view*.png.
var _frames := 0
var _cam: Camera3D
var _terrain
var _shots := [[Vector3(0, 0, 0), 0.0], [Vector3(0, 0, 0), 2.2]]
func _init() -> void:
	var root3d := Node3D.new()
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.7, 0.9)
	env.environment.ambient_light_color = Color(0.7, 0.75, 0.8)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	root3d.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	root3d.add_child(sun)
	var terrain = load("res://world/terrain.gd").new()
	terrain.name = "Terrain"
	_terrain = terrain
	root3d.add_child(terrain)
	_cam = Camera3D.new()
	root3d.add_child(_cam)
	get_root().add_child(root3d)
	get_root().size = Vector2i(1280, 720)
func _process(_d: float) -> bool:
	_frames += 1
	var terrain = _terrain
	if _frames == 2:
		var wd = terrain._wd
		var x: float = wd.world_ox + wd.chunks_x * wd.chunk_cells * wd.cell_size * 0.62
		var z: float = wd.world_oz + wd.chunks_z * wd.chunk_cells * wd.cell_size * 0.30
		var y: float = wd._get_height_at(x, z)
		_cam.position = Vector3(x, y + 1.7, z)
		_cam.rotation_degrees = Vector3(-12, 20, 0)
		terrain.set_grass_push(Vector3(x, y, z - 2.0))
	if _frames == 240 or _frames == 300:
		var img := get_root().get_texture().get_image()
		img.save_png(OS.get_environment("SHOT") + "_%d.png" % _frames)
		if _frames == 240: _cam.rotation_degrees = Vector3(-30, 200, 0)
	return _frames > 300
