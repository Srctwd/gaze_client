extends Node
## The PS2 renderer's per-frame side (ps2/PS2_RENDERING.md). Every material
## the game draws with is already a PS2 one (see ps2_materials.gd); this
## autoload feeds those shaders and finishes the picture:
##   - the scene's lights, ambient and fog go to the shaders as global
##     uniforms every frame (the PS2's per-frame VU1 constant upload),
##   - the tonemapper is linear (the GS had none),
##   - the 3D view renders at internal_lines (448) with 16-bit dither and the
##     flicker filter: the "screen". Always on in the game; the world editor
##     shares this autoload and keeps it off (a poor editing view).
## F10 toggles fixed_light.

const POST_SHADER := preload("res://ps2/ps2_post.gdshader")

const FIXED_LIGHT_KEY := KEY_F10
# fixed_light's light set: character_create_ui.gd's preview lighting, which
# this file once picked up by mistake — a look worth keeping.
const _FIXED_AMBIENT := Color(0.55, 0.55, 0.6)
const _FIXED_AMBIENT_ENERGY := 0.6
const _FIXED_LIGHTS := [   # [rotation (degrees), energy, colour]
	[Vector3(-35.0, 30.0, 0.0), 1.1, Color.WHITE],
	[Vector3(-20.0, 200.0, 0.0), 0.5, Color(0.7, 0.8, 1.0)],
]

# Tuning. Light values are in GS units: 0.5 == 0x80 == "1.0".
var internal_lines   := 448          # PS2 vertical resolution (448 or 512)
var sun_gain         := 1.75         # noon sun (energy 0.2) → ~0.35
var ambient_gain     := 0.6
var point_gain       := 0.4          # point-light brightness (1 = raw colour × energy); level-up flash (12) clips to white
# Godot's lighting saturates a warm light toward white near its source; the
# GS vertex colour can't, so the PS2 path blends point-light colour this far
# toward white (0 = the light's own colour).
var point_white      := 0.15
var point_range      := 1.0          # lights reach this × their omni_range, fading to 0 there (torches don't add up, so wider doesn't mean brighter)
var point_flat       := 0.6          # fraction of the reach lit at full strength before fading out (0 = fades from the centre, → 1 = hard edge)
var point_wrap       := 0.0          # point-light N·L wrap: 0 = Lambert (ground goes dark a few units from a torch, its light grazes it), 1 = half-Lambert, higher = more even
var godot_lighting   := true         # light everything (sun, ambient, OmniLights, shadows) with Godot's own per-pixel lighting instead of the PS2 light set
var godot_point_gain := 1.0          # OmniLight brightness in that mode (1 = as Godot draws them on its own)
var sun_energy_ref   := 0.2          # sun_moon_controller.SUN_ENERGY_MAX
var shadow_strength  := 0.5          # sun shadow map on top of PS2 light (0 = off)
var subpixel         := 16.0         # GS 12.4 vertex snap; 1 = whole pixels (PS1-style)
var fog_enabled      := true
var fog_near         := 60.0
var fog_far          := 350.0
var fog_color_day    := Color(0.62, 0.68, 0.80)
var fog_color_night  := Color(0.05, 0.06, 0.10)
var dither           := true
var flicker_filter   := 0.5
var fixed_light      := false        # light with _FIXED_LIGHTS and a steady ambient instead of the sun, moon and time of day: bright, flat, no sun shadows

var screen := false                  # 448-line view + dither (on in game, off in the world editor)

var _dir_lights  := {}
var _omni_lights := {}
const MAX_POINTS := 64   # point lights uploaded per frame (the table's size)
var _point_img:   Image          # the light table (see the light set below)
var _point_tex:   ImageTexture
var _world_env: WorldEnvironment
var _post: CanvasLayer
var _saved       := {}


func _ready() -> void:
	get_tree().node_added.connect(_track)
	_initial_scan.call_deferred()


func _initial_scan() -> void:
	for n in get_tree().root.find_children("*", "", true, false):
		_track(n)
	var scene := get_tree().current_scene
	var in_editor := scene != null and scene.scene_file_path.begins_with("res://world_editor/")
	set_screen(not in_editor)


func _track(n: Node) -> void:
	if not _in_game_world(n):
		# Lights and environments of another world (a SubViewport with its
		# own, like the character preview's) don't light this one.
		return
	if n is DirectionalLight3D:
		_dir_lights[n.get_instance_id()] = true
	elif n is OmniLight3D:
		_omni_lights[n.get_instance_id()] = true
	elif n is WorldEnvironment:
		_world_env = n
		_apply_env.call_deferred()


func _in_game_world(n: Node) -> bool:
	return n.get_viewport().find_world_3d() == get_tree().root.find_world_3d()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == FIXED_LIGHT_KEY:
		fixed_light = not fixed_light
		get_viewport().set_input_as_handled()


func set_screen(on: bool) -> void:
	screen = on
	_apply_viewport(on)
	_apply_post(on)


func _process(_delta: float) -> void:
	_update_globals()
	if screen:
		var vp := get_viewport()
		vp.scaling_3d_scale = _internal_scale(vp)


# --- Light set (global uniforms) ---------------------------------------------

func _update_globals() -> void:
	# [direction toward the light, colour, energy], brightest first.
	var dirs: Array = []
	if fixed_light:
		for f in _FIXED_LIGHTS:
			dirs.append([Basis.from_euler(f[0] * PI / 180.0).z, f[2], f[1]])
	else:
		for id in _dir_lights.keys():
			var l := instance_from_id(id) as DirectionalLight3D
			if l == null:
				_dir_lights.erase(id)
			elif l.is_visible_in_tree() and l.light_energy > 0.0:
				dirs.append([l.global_transform.basis.z.normalized(), l.light_color, l.light_energy])
	dirs.sort_custom(func(a, b): return a[2] > b[2])
	for i in 3:
		var dir := Vector3.UP
		var col := Vector3.ZERO
		if i < dirs.size():
			dir = dirs[i][0]
			col = _vec(dirs[i][1]) * dirs[i][2] * sun_gain
		RenderingServer.global_shader_parameter_set("ps2_light_dir%d" % i, dir)
		RenderingServer.global_shader_parameter_set("ps2_light_col%d" % i, col)

	var sun_energy: float = dirs[0][2] if not dirs.is_empty() else 0.0
	var daylight := clampf(sun_energy / sun_energy_ref, 0.0, 1.0)

	# fixed_light: no environment of its own, so no depth fog either.
	var env := _env()
	var amb_color := _FIXED_AMBIENT
	var amb_energy := _FIXED_AMBIENT_ENERGY
	if not fixed_light and env != null:
		amb_color = env.ambient_light_color
		amb_energy = env.ambient_light_energy
	elif not fixed_light:
		amb_energy = 0.0
	RenderingServer.global_shader_parameter_set("ps2_ambient", _vec(amb_color) * amb_energy * ambient_gain)
	RenderingServer.global_shader_parameter_set("ps2_godot_ambient", _vec(amb_color.srgb_to_linear()) * amb_energy)

	var near := fog_near
	var far  := fog_far
	var fog_col := fog_color_night.lerp(fog_color_day, daylight)
	if not fixed_light and env != null and env.fog_enabled and env.fog_mode == Environment.FOG_MODE_DEPTH:
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
	# MAX_POINTS nearest the camera stand in for that choice, out of the ones
	# whose range reaches into the view. Scenery is lit per vertex, so every
	# one of them shows. Without the frustum test, lights behind the camera or
	# indoors took the slots and far torch posts only lit up up close.
	var cam := get_viewport().get_camera_3d()
	var frustum: Array[Plane] = []
	if cam != null:
		frustum = cam.get_frustum()
	var omnis: Array[OmniLight3D] = []
	for id in _omni_lights.keys():
		var l := instance_from_id(id) as OmniLight3D
		if l == null:
			_omni_lights.erase(id)
		elif l.is_visible_in_tree() and l.light_energy > 0.0 and _reaches_view(frustum, l.global_position, l.omni_range * point_range):
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
	var count := 0 if godot_lighting else mini(omnis.size(), MAX_POINTS)
	for i in count:
		var l := omnis[i]
		var p := l.global_position
		var c := _vec(l.light_color.lerp(Color.WHITE, point_white)) * l.light_energy * point_gain
		_point_img.set_pixel(i * 2, 0, Color(p.x, p.y, p.z, l.omni_range * point_range))
		_point_img.set_pixel(i * 2 + 1, 0, Color(c.x, c.y, c.z, 0.0))
	_point_tex.update(_point_img)
	RenderingServer.global_shader_parameter_set("ps2_point_count", count)
	RenderingServer.global_shader_parameter_set("ps2_point_flat", point_flat)
	RenderingServer.global_shader_parameter_set("ps2_point_wrap", point_wrap)
	RenderingServer.global_shader_parameter_set("ps2_godot_lighting", godot_lighting)
	RenderingServer.global_shader_parameter_set("ps2_godot_point_gain", godot_point_gain)


# A light's sphere of influence touches the view: inside or across every
# frustum plane (their normals point out of the frustum).
static func _reaches_view(frustum: Array[Plane], pos: Vector3, radius: float) -> bool:
	for plane in frustum:
		if plane.distance_to(pos) > radius:
			return false
	return true


func _env() -> Environment:
	if _world_env != null and is_instance_valid(_world_env):
		return _world_env.environment
	return null


static func _vec(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)


# --- Output: resolution, tonemap, dither (the screen) --------------------------------------

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


# The GS had no tonemapper: ACES/Filmic would flatten the ×2 overbright the
# PS2 shaders output.
func _apply_env() -> void:
	var env := _env()
	if env == null:
		return
	env.tonemap_mode     = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.tonemap_white    = 1.0


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
