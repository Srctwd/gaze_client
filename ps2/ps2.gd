extends Node
## PS2 render mode, toggled with F9.
##
## While on, every MeshInstance3D gets the matching res://ps2/ shader (built
## from its StandardMaterial3D or WorldShaders material), the scene's lights
## are fed to those shaders through global uniforms (the PS2's per-frame VU1
## constant upload), and the 3D view renders at 448 lines with 16-bit dither.
## Turning it off restores the original materials and settings.
## The maths is in ps2/PS2_RENDERING.md.

const MODEL_SHADER        := preload("res://ps2/ps2_model.gdshader")
const MODEL_DOUBLE_SHADER := preload("res://ps2/ps2_model_double.gdshader")
const MODEL_BLEND_SHADER  := preload("res://ps2/ps2_model_blend.gdshader")
const WORLD_SHADER        := preload("res://ps2/ps2_world.gdshader")
const WATER_SHADER        := preload("res://ps2/ps2_water.gdshader")
const POST_SHADER         := preload("res://ps2/ps2_post.gdshader")
const PARTICLE_SHADER     := preload("res://ps2/ps2_particle.gdshader")
const PARTICLE_ADD_SHADER := preload("res://ps2/ps2_particle_add.gdshader")
const Ps2Mesh             := preload("res://ps2/ps2_mesh.gd")
const Ps2Texture          := preload("res://ps2/ps2_texture.gd")

const TOGGLE_KEY    := KEY_F9
const SCAN_INTERVAL := 0.2   # s between material passes while on
const IDLE_INTERVAL := 1.0   # s between revert passes while off
const MESH_BUDGET_US := 2000 # per-frame main-thread time for starting/finishing rebuilds
const WORLD_GRID     := 1.0 / 64.0  # terrain/water position step (s16 → ±512 per chunk)

# Tuning. Light values are in GS units: 0.5 == 0x80 == "1.0".
var enabled_at_start := false
var internal_lines   := 448          # PS2 vertical resolution (448 or 512)
var sun_gain         := 1.75         # noon sun (energy 0.2) → ~0.35
var ambient_gain     := 0.6
var point_gain       := 1.5          # point-light brightness in PS2 mode (1 = raw colour × energy); level-up flash (12) clips to white
# Dim far glow added past the point-light falloff (see ps2_falloff), for more
# light radius. Up close the original curve is the brighter one, so the look
# right at the light is unchanged. point_tail = 0 turns it off (original).
# Godot's lighting saturates a warm light toward white near its source; the
# GS vertex colour can't, so the PS2 path blends point-light colour this far
# toward white (0 = the light's own colour).
var point_white      := 0.15
var point_tail       := 0.35
var point_reach      := 20.0
var sun_energy_ref   := 0.2          # sun_moon_controller.SUN_ENERGY_MAX
var cave_ambient     := 1.67         # caves get the full scene ambient (× ambient_gain 0.6 ≈ 1.0); less leaves the torch as the only light, so caves go red
var shadow_strength  := 0.5          # sun shadow map on top of PS2 light (0 = off)
var rebuild_meshes   := true         # run all meshes through the PS2 geometry path (ps2_mesh.gd)
var subpixel         := 16.0         # GS 12.4 vertex snap; 1 = whole pixels (PS1-style)
var log_mesh_stats   := true         # print strip/batch stats per rebuilt mesh
var fog_enabled      := true
var fog_near         := 60.0
var fog_far          := 350.0
var fog_color_day    := Color(0.62, 0.68, 0.80)
var fog_color_night  := Color(0.05, 0.06, 0.10)
var dither           := true
var flicker_filter   := 0.5

var enabled := false

var _meshes      := {}   # instance id -> true
var _particles   := {}   # GPUParticles3D / CPUParticles3D ids
var _tex_cache   := {}   # texture id + flags -> paletted ImageTexture
var _dir_lights  := {}
var _omni_lights := {}
const MAX_POINTS := 32   # point lights uploaded per frame; keep in sync with ps2_common.gdshaderinc
var _point_img:   Image          # the light table (see the light set below)
var _point_tex:   ImageTexture
var _world_env: WorldEnvironment
var _cache       := {}   # material key -> ShaderMaterial
var _scan_t      := 0.0
var _ever_on     := false
var _post: CanvasLayer
var _mesh_cache  := {}   # shared source mesh id -> PS2 ArrayMesh
var _mesh_queue: Array[int] = []   # MeshInstance3D ids waiting for a rebuild
var _queued      := {}
var _mesh_jobs   := {}   # key -> {task, job, waiting: Array[int], shared}
var _saved       := {}


func _ready() -> void:
	get_tree().node_added.connect(_track)
	_initial_scan.call_deferred()


func _initial_scan() -> void:
	for n in get_tree().root.find_children("*", "", true, false):
		_track(n)
	if enabled_at_start:
		set_enabled(true)


func _track(n: Node) -> void:
	if n is MeshInstance3D:
		_meshes[n.get_instance_id()] = true
	elif n is GPUParticles3D or n is CPUParticles3D:
		_particles[n.get_instance_id()] = true
	elif n is DirectionalLight3D:
		_dir_lights[n.get_instance_id()] = true
	elif n is OmniLight3D:
		_omni_lights[n.get_instance_id()] = true
	elif n is WorldEnvironment:
		_world_env = n
		if enabled:
			_apply_env.call_deferred(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == TOGGLE_KEY:
		set_enabled(not enabled)
		get_viewport().set_input_as_handled()


func set_enabled(on: bool) -> void:
	if on == enabled:
		return
	enabled = on
	_ever_on = _ever_on or on
	_apply_viewport(on)
	_apply_env(on)
	_apply_post(on)
	_sync_materials()


## The material the game assigned, for code that inspects material_override
## (e.g. targeting reads its albedo_color).
static func source_of(m: Material) -> Material:
	if m != null and m.has_meta("ps2"):
		return m.get_meta("ps2_source") as Material
	return m


func _process(delta: float) -> void:
	if enabled:
		_update_globals()
		var vp := get_viewport()
		vp.scaling_3d_scale = _internal_scale(vp)
	if enabled:
		_pump_meshes()
	_scan_t -= delta
	if _scan_t <= 0.0 and _ever_on:
		_scan_t = SCAN_INTERVAL if enabled else IDLE_INTERVAL
		_sync_materials()


# --- Light set (global uniforms) ---------------------------------------------

func _update_globals() -> void:
	var dirs: Array[DirectionalLight3D] = []
	for id in _dir_lights.keys():
		var l := instance_from_id(id) as DirectionalLight3D
		if l == null:
			_dir_lights.erase(id)
		elif l.is_visible_in_tree() and l.light_energy > 0.0:
			dirs.append(l)
	dirs.sort_custom(func(a, b): return a.light_energy > b.light_energy)
	for i in 3:
		var dir := Vector3.UP
		var col := Vector3.ZERO
		if i < dirs.size():
			var l := dirs[i]
			dir = l.global_transform.basis.z.normalized()   # toward the light
			col = _vec(l.light_color) * l.light_energy * sun_gain
		RenderingServer.global_shader_parameter_set("ps2_light_dir%d" % i, dir)
		RenderingServer.global_shader_parameter_set("ps2_light_col%d" % i, col)

	var sun_energy: float = dirs[0].light_energy if not dirs.is_empty() else 0.0
	var daylight := clampf(sun_energy / sun_energy_ref, 0.0, 1.0)

	var env := _env()
	var ambient := Vector3.ZERO
	if env != null:
		ambient = _vec(env.ambient_light_color) * env.ambient_light_energy * ambient_gain
	RenderingServer.global_shader_parameter_set("ps2_ambient", ambient)

	var near := fog_near
	var far  := fog_far
	var fog_col := fog_color_night.lerp(fog_color_day, daylight)
	if env != null and env.fog_enabled and env.fog_mode == Environment.FOG_MODE_DEPTH:
		near = env.fog_depth_begin
		far  = env.fog_depth_end
		fog_col = env.fog_light_color
	if not fog_enabled:
		near = 1.0e6
		far  = 1.0e6 + 1.0
	RenderingServer.global_shader_parameter_set("ps2_fog_color", _vec(fog_col))
	RenderingServer.global_shader_parameter_set("ps2_fog_near", near)
	RenderingServer.global_shader_parameter_set("ps2_fog_far", far)
	RenderingServer.global_shader_parameter_set("ps2_shadow_strength", shadow_strength)
	var vp_size := get_viewport().get_visible_rect().size * get_viewport().scaling_3d_scale
	RenderingServer.global_shader_parameter_set("ps2_screen_size", vp_size)
	RenderingServer.global_shader_parameter_set("ps2_subpixel", subpixel)

	# The EE picked the strongest few point lights per object; here the
	# MAX_POINTS nearest the camera stand in for that choice. Scenery is lit
	# per vertex, so every one of them shows: with only two slots a town full
	# of torches went dark except for the two nearest the player.
	var cam := get_viewport().get_camera_3d()
	var omnis: Array[OmniLight3D] = []
	for id in _omni_lights.keys():
		var l := instance_from_id(id) as OmniLight3D
		if l == null:
			_omni_lights.erase(id)
		elif l.is_visible_in_tree() and l.light_energy > 0.0:
			omnis.append(l)
	if cam != null:
		var eye := cam.global_position
		omnis.sort_custom(func(a, b): return a.global_position.distance_squared_to(eye) < b.global_position.distance_squared_to(eye))
	# Light table, one row of texels: light i is (pos, range) at x = 2i and
	# (colour, 0) at x = 2i + 1, read with texelFetch.
	if _point_tex == null:
		_point_img = Image.create_empty(MAX_POINTS * 2, 1, false, Image.FORMAT_RGBAF)
		_point_tex = ImageTexture.create_from_image(_point_img)
		RenderingServer.global_shader_parameter_set("ps2_point_tex", _point_tex)
	var count := mini(omnis.size(), MAX_POINTS)
	for i in count:
		var l := omnis[i]
		var p := l.global_position
		var c := _vec(l.light_color.lerp(Color.WHITE, point_white)) * l.light_energy * point_gain
		_point_img.set_pixel(i * 2, 0, Color(p.x, p.y, p.z, l.omni_range))
		_point_img.set_pixel(i * 2 + 1, 0, Color(c.x, c.y, c.z, 0.0))
	_point_tex.update(_point_img)
	RenderingServer.global_shader_parameter_set("ps2_point_count", count)
	RenderingServer.global_shader_parameter_set("ps2_point_tail", point_tail)
	RenderingServer.global_shader_parameter_set("ps2_point_reach", point_reach)


func _env() -> Environment:
	if _world_env != null and is_instance_valid(_world_env):
		return _world_env.environment
	return null


static func _vec(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)


# --- Output: resolution, tonemap, dither --------------------------------------

func _internal_scale(vp: Viewport) -> float:
	return clampf(float(internal_lines) / maxf(vp.get_visible_rect().size.y, 1.0), 0.1, 1.0)


func _apply_viewport(on: bool) -> void:
	var vp := get_viewport()
	if on:
		_saved["scale_mode"] = vp.scaling_3d_mode
		_saved["scale"]      = vp.scaling_3d_scale
		vp.scaling_3d_mode   = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale  = _internal_scale(vp)
	elif _saved.has("scale"):
		vp.scaling_3d_mode  = _saved["scale_mode"]
		vp.scaling_3d_scale = _saved["scale"]


# The GS had no tonemapper: ACES/Filmic would flatten the ×2 overbright.
func _apply_env(on: bool) -> void:
	var env := _env()
	if env == null:
		return
	if on:
		if not _saved.has("tonemap"):
			_saved["tonemap"]  = env.tonemap_mode
			_saved["exposure"] = env.tonemap_exposure
			_saved["white"]    = env.tonemap_white
		env.tonemap_mode     = Environment.TONE_MAPPER_LINEAR
		env.tonemap_exposure = 1.0
		env.tonemap_white    = 1.0
	elif _saved.has("tonemap"):
		env.tonemap_mode     = _saved["tonemap"]
		env.tonemap_exposure = _saved["exposure"]
		env.tonemap_white    = _saved["white"]
		_saved.erase("tonemap")


func _apply_post(on: bool) -> void:
	if on and _post == null:
		_post = CanvasLayer.new()
		_post.layer = -1   # under every UI layer, over the 3D view
		var rect := ColorRect.new()
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mat := ShaderMaterial.new()
		mat.shader = POST_SHADER
		mat.set_shader_parameter("ps2_lines", float(internal_lines))
		mat.set_shader_parameter("dither", dither)
		mat.set_shader_parameter("flicker_filter", flicker_filter)
		rect.material = mat
		_post.add_child(rect)
		add_child(_post)
	elif not on and _post != null:
		_post.queue_free()
		_post = null


# --- Material swap -------------------------------------------------------------

func _sync_materials() -> void:
	_sync_particles()
	for id in _meshes.keys():
		var mi := instance_from_id(id) as MeshInstance3D
		if mi == null:
			_meshes.erase(id)
		elif mi.is_inside_tree():
			if enabled:
				_convert_mesh(mi)
			else:
				_revert_mesh(mi)


func _sync_particles() -> void:
	for id in _particles.keys():
		var p := instance_from_id(id) as GeometryInstance3D
		if p == null:
			_particles.erase(id)
		elif p.is_inside_tree():
			if enabled:
				_convert_particles(p)
			else:
				_revert_particles(p)


# The material a particle system draws with: its override, else the draw
# mesh's own material.
static func _particle_source(p: GeometryInstance3D) -> Material:
	if p.material_override != null:
		return p.material_override
	var mesh: Mesh = (p as GPUParticles3D).draw_pass_1 if p is GPUParticles3D else (p as CPUParticles3D).mesh
	if mesh != null and mesh.get_surface_count() > 0:
		return mesh.surface_get_material(0)
	return null


func _convert_particles(p: GeometryInstance3D) -> void:
	var cur := p.material_override
	if _is_ps2(cur):
		return
	var src := _particle_source(p) as BaseMaterial3D
	if src == null:
		return
	var c := _particle_material(src)
	p.set_meta("_ps2_po", cur)
	p.material_override = c


func _revert_particles(p: GeometryInstance3D) -> void:
	if _is_ps2(p.material_override):
		p.material_override = p.get_meta("_ps2_po") if p.has_meta("_ps2_po") else null
	p.remove_meta("_ps2_po")


func _particle_material(m: BaseMaterial3D) -> ShaderMaterial:
	var add := m.blend_mode == BaseMaterial3D.BLEND_MODE_ADD
	var tex := m.albedo_texture
	var key := "part|%s|%d|%s|%s|%s|%s" % [add, tex.get_instance_id() if tex != null else 0,
			m.albedo_color, m.vertex_color_use_as_albedo, m.shading_mode, m.albedo_texture_msdf]
	if _cache.has(key):
		return _cache[key]
	var mat := ShaderMaterial.new()
	mat.shader = PARTICLE_ADD_SHADER if add else PARTICLE_SHADER
	if tex != null:
		var tkey := "%d|%s" % [tex.get_instance_id(), m.albedo_texture_msdf]
		if not _tex_cache.has(tkey):
			_tex_cache[tkey] = Ps2Texture.palettize(tex, 16, Ps2Texture.SPRITE_MAX_SIZE, m.albedo_texture_msdf)
		if _tex_cache[tkey] != null:
			mat.set_shader_parameter("albedo_tex", _tex_cache[tkey])
	var col := m.albedo_color
	mat.set_shader_parameter("albedo_color", Vector4(col.r, col.g, col.b, col.a))
	mat.set_shader_parameter("use_vertex_colors", m.vertex_color_use_as_albedo)
	mat.set_shader_parameter("lit", m.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED)
	mat.render_priority = m.render_priority
	return _remember(key, mat, m)


func _convert_mesh(mi: MeshInstance3D) -> void:
	var mo := mi.material_override
	if mo != null and not _is_ps2(mo):
		var c := _ps2_material(mo)
		if c != null:
			mi.set_meta("_ps2_mo", mo)
			mi.material_override = c
	if mi.mesh == null:
		return
	var originals: Dictionary = mi.get_meta("_ps2_so", {})
	for i in mi.get_surface_override_material_count():
		var cur := mi.get_surface_override_material(i)
		if cur != null and _is_ps2(cur):
			continue
		var src: Material = cur if cur != null else mi.mesh.surface_get_material(i)
		if src == null:
			continue
		var c := _ps2_material(src)
		if c != null:
			originals[i] = cur
			mi.set_surface_override_material(i, c)
	if not originals.is_empty():
		mi.set_meta("_ps2_so", originals)
	if rebuild_meshes and not mi.mesh.has_meta("ps2") and not mi.mesh.has_meta("ps2_skip") \
			and not _queued.has(mi.get_instance_id()):
		_queued[mi.get_instance_id()] = true
		_mesh_queue.append(mi.get_instance_id())


func _revert_mesh(mi: MeshInstance3D) -> void:
	if mi.mesh != null and mi.mesh.has_meta("ps2"):
		mi.set_meta("_ps2_built", mi.mesh)   # reused if PS2 mode comes back on
		mi.mesh = mi.mesh.get_meta("ps2_source")
	if _is_ps2(mi.material_override):
		mi.material_override = mi.get_meta("_ps2_mo", source_of(mi.material_override))
	mi.remove_meta("_ps2_mo")
	if mi.has_meta("_ps2_so"):
		var originals: Dictionary = mi.get_meta("_ps2_so")
		for i in originals:
			if i < mi.get_surface_override_material_count() and _is_ps2(mi.get_surface_override_material(i)):
				mi.set_surface_override_material(i, originals[i])
		mi.remove_meta("_ps2_so")


# Terrain and water (the PS2 world shaders) quantise on a shared world grid
# so chunk borders meet exactly; models use their own scale.
func _is_model(mi: MeshInstance3D) -> bool:
	for i in mi.get_surface_override_material_count():
		var m := mi.get_active_material(i) as ShaderMaterial
		if m != null and (m.shader == WORLD_SHADER or m.shader == WATER_SHADER):
			return false
	return true


# Starts queued rebuilds on worker threads and applies finished ones, within
# MESH_BUDGET_US of main-thread time per frame.
func _pump_meshes() -> void:
	var start := Time.get_ticks_usec()
	for key in _mesh_jobs.keys():
		var entry: Dictionary = _mesh_jobs[key]
		if not WorkerThreadPool.is_task_completed(entry["task"]):
			continue
		WorkerThreadPool.wait_for_task_completion(entry["task"])
		_mesh_jobs.erase(key)
		var job: Dictionary = entry["job"]
		var src: Mesh = job["source"]
		var built := Ps2Mesh.finish(job)
		if built == null:
			src.set_meta("ps2_skip", true)
			continue
		if entry["shared"]:
			_mesh_cache[key] = built
		if log_mesh_stats:
			for line in built.get_meta("ps2_stats"):
				print("ps2 mesh %s: %s" % [src.resource_path.get_file() if src.resource_path != "" else src.get_class(), line])
		for id in entry["waiting"]:
			var mi := instance_from_id(id) as MeshInstance3D
			if mi != null and enabled and mi.mesh == src:
				mi.mesh = built
		if Time.get_ticks_usec() - start > MESH_BUDGET_US:
			return

	while not _mesh_queue.is_empty() and Time.get_ticks_usec() - start < MESH_BUDGET_US:
		var id: int = _mesh_queue.pop_front()
		_queued.erase(id)
		var mi := instance_from_id(id) as MeshInstance3D
		if mi == null or not mi.is_inside_tree() or mi.mesh == null or mi.mesh.has_meta("ps2"):
			continue
		var src := mi.mesh
		var prev: Mesh = mi.get_meta("_ps2_built") if mi.has_meta("_ps2_built") else null
		if prev != null and prev.get_meta("ps2_source") == src:
			mi.mesh = prev
			continue
		var model := _is_model(mi)
		var shared := model and src.resource_path != ""   # imported meshes are shared
		var key: String = ("s%d" if shared else "i%d") % (src.get_instance_id() if shared else id)
		if shared and _mesh_cache.has(key):
			mi.mesh = _mesh_cache[key]
		elif _mesh_jobs.has(key):
			_mesh_jobs[key]["waiting"].append(id)
		else:
			var job := Ps2Mesh.extract(src, 0.0 if model else WORLD_GRID,
					Transform3D.IDENTITY if model else mi.global_transform)
			if job.is_empty():
				src.set_meta("ps2_skip", true)
				continue
			var task := WorkerThreadPool.add_task(Callable(Ps2Mesh, "run").bind(job), false, "ps2 mesh")
			_mesh_jobs[key] = {"task": task, "job": job, "waiting": [id], "shared": shared}


static func _is_ps2(m: Material) -> bool:
	return m != null and m.has_meta("ps2")


func _ps2_material(src: Material) -> ShaderMaterial:
	if src is BaseMaterial3D:
		return _from_base(src)
	if src is ShaderMaterial:
		return _from_world(src)
	return null


func _from_base(m: BaseMaterial3D) -> ShaderMaterial:
	if m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED \
			or m.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED:
		return null
	var blend := m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA \
			or m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	var scissor := 0.0
	if m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
		scissor = m.alpha_scissor_threshold
	elif m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_HASH:
		scissor = 0.5
	var shader: Shader = MODEL_BLEND_SHADER if blend \
			else (MODEL_DOUBLE_SHADER if m.cull_mode == BaseMaterial3D.CULL_DISABLED else MODEL_SHADER)
	# Emission becomes the GS HIGHLIGHT add (used by targeting's glow).
	var highlight := Vector3.ZERO
	if m.emission_enabled:
		highlight = _vec(m.emission) * m.emission_energy_multiplier
	var tex := m.albedo_texture
	var key := "base|%s|%d|%s|%s|%s|%s|%s|%s" % [shader.resource_path,
			tex.get_instance_id() if tex != null else 0, m.albedo_color, m.uv1_scale,
			m.uv1_offset, m.vertex_color_use_as_albedo, scissor, highlight]
	if _cache.has(key):
		return _cache[key]

	var mat := ShaderMaterial.new()
	mat.shader = shader
	if tex != null:
		mat.set_shader_parameter("albedo_tex", tex)
	var col := m.albedo_color
	mat.set_shader_parameter("albedo_color", Vector4(col.r, col.g, col.b, col.a))
	mat.set_shader_parameter("uv1_scale", m.uv1_scale)
	mat.set_shader_parameter("uv1_offset", m.uv1_offset)
	mat.set_shader_parameter("use_vertex_colors", m.vertex_color_use_as_albedo)
	mat.set_shader_parameter("alpha_scissor", scissor)
	mat.set_shader_parameter("highlight", highlight)
	mat.render_priority = m.render_priority
	return _remember(key, mat, m)


# Recognises the WorldShaders materials by their uniform names.
func _from_world(m: ShaderMaterial) -> ShaderMaterial:
	if m.shader == null:
		return null
	var key := "shader|%d" % m.get_instance_id()
	if _cache.has(key):
		return _cache[key]
	var names := {}
	for u in m.shader.get_shader_uniform_list():
		names[u["name"]] = true

	var mat := ShaderMaterial.new()
	mat.shader = WORLD_SHADER
	if names.has("top_tint"):            # surface_mat
		var tt: Vector3 = _param(m, "top_tint", Vector3.ONE)
		mat.set_shader_parameter("albedo_tex", _param(m, "albedo_texture", null))
		mat.set_shader_parameter("projection", 1)
		mat.set_shader_parameter("tile_scale", _param(m, "tile_scale", 2.0))
		mat.set_shader_parameter("tint", tt)
		mat.set_shader_parameter("flat_backface", true)
		mat.set_shader_parameter("backface_color", _vec(_param(m, "albedo_bottom", Color(0.25, 0.22, 0.20))))
	elif names.has("cave_tex"):          # cave_mat: zone lighting, no sun
		mat.set_shader_parameter("albedo_tex", _param(m, "cave_tex", null))
		mat.set_shader_parameter("projection", 1)
		mat.set_shader_parameter("tile_scale", _param(m, "tile_scale", 4.0))
		mat.set_shader_parameter("tint", _vec(_param(m, "tint", Color.WHITE)))
		mat.set_shader_parameter("dir_light_scale", 0.0)
		mat.set_shader_parameter("ambient_scale", cave_ambient)
	elif names.has("wall_tex"):          # wall_mat
		mat.set_shader_parameter("albedo_tex", _param(m, "wall_tex", null))
		mat.set_shader_parameter("projection", 2)
		mat.set_shader_parameter("tile_scale", _param(m, "tile_scale", 2.0))
		mat.set_shader_parameter("tint", _vec(_param(m, "tint", Color.WHITE)))
	elif names.has("water_color"):       # water_mat
		mat.shader = WATER_SHADER
		var wc: Color = _param(m, "water_color", Color(0.08, 0.38, 0.65, 0.6))
		mat.set_shader_parameter("water_color", Vector4(wc.r, wc.g, wc.b, wc.a))
		mat.set_shader_parameter("wave_speed", _param(m, "wave_speed", 0.25))
		mat.set_shader_parameter("wave_scale", _param(m, "wave_scale", 5.0))
	else:
		return null
	mat.render_priority = m.render_priority
	return _remember(key, mat, m)


func _remember(key: String, mat: ShaderMaterial, src: Material) -> ShaderMaterial:
	mat.set_meta("ps2", true)
	mat.set_meta("ps2_source", src)
	_cache[key] = mat
	return mat


static func _param(m: ShaderMaterial, name: String, fallback: Variant) -> Variant:
	var v: Variant = m.get_shader_parameter(name)
	return fallback if v == null else v
