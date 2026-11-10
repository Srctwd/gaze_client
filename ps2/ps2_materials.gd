extends RefCounted
## Builds PS2 materials (res://ps2/ shaders, PS2_RENDERING.md) from Godot
## material settings. Every material the game draws with is a PS2 one; this
## is how they're made:
##   - imported models: at import time (addons/ps2_import, model()),
##   - scenes/resources: converted once (ps2/tools/convert_resources.gd),
##   - game code: model() / particle() on the material it configures,
##   - world: WorldShaders builds them directly.
## Unshaded and billboard materials (UI-like effects, the moon) have no PS2
## form and stay as they are: model() returns null for them.

const MODEL_SHADER                := preload("res://ps2/ps2_model.gdshader")
const MODEL_DOUBLE_SHADER         := preload("res://ps2/ps2_model_double.gdshader")
const MODEL_BLEND_SHADER          := preload("res://ps2/ps2_model_blend.gdshader")
const MODEL_PREPASS_SHADER        := preload("res://ps2/ps2_model_prepass.gdshader")
const MODEL_PREPASS_DOUBLE_SHADER := preload("res://ps2/ps2_model_prepass_double.gdshader")
const PARTICLE_SHADER             := preload("res://ps2/ps2_particle.gdshader")
const PARTICLE_ADD_SHADER         := preload("res://ps2/ps2_particle_add.gdshader")
const ENV_TEX                     := preload("res://ps2/ps2_env.png")   # sphere map, §6.3
const Ps2Texture                  := preload("res://ps2/ps2_texture.gd")

const MODEL_SHADERS := [MODEL_SHADER, MODEL_DOUBLE_SHADER, MODEL_BLEND_SHADER,
		MODEL_PREPASS_SHADER, MODEL_PREPASS_DOUBLE_SHADER]

# Sphere-map shine (§6.3) at metallic 1 / roughness 0, tinted by the surface
# colour, and the white shine of glossy non-metal at roughness 0. See
# env_params().
const ENV_METAL_GAIN := 0.75
const ENV_GLOSS_GAIN := 0.5


## The PS2 model material for `m`'s settings, or null when `m` has no PS2
## form (unshaded, billboard).
static func model(m: BaseMaterial3D) -> ShaderMaterial:
	if m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED \
			or m.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED:
		return null
	var blend := m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA
	var prepass := m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	var double := m.cull_mode == BaseMaterial3D.CULL_DISABLED
	var scissor := 0.0
	if m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
		scissor = m.alpha_scissor_threshold
	elif m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_HASH:
		scissor = 0.5
	var shader: Shader
	if prepass:
		shader = MODEL_PREPASS_DOUBLE_SHADER if double else MODEL_PREPASS_SHADER
	elif blend:
		shader = MODEL_BLEND_SHADER
	else:
		shader = MODEL_DOUBLE_SHADER if double else MODEL_SHADER

	var mat := ShaderMaterial.new()
	mat.resource_name = m.resource_name
	mat.shader = shader
	if m.albedo_texture != null:
		mat.set_shader_parameter("albedo_tex", m.albedo_texture)
	set_color(mat, m.albedo_color)
	mat.set_shader_parameter("uv1_scale", m.uv1_scale)
	mat.set_shader_parameter("uv1_offset", m.uv1_offset)
	mat.set_shader_parameter("use_vertex_colors", m.vertex_color_use_as_albedo)
	mat.set_shader_parameter("alpha_scissor", scissor)
	# Emission becomes the GS HIGHLIGHT add.
	if m.emission_enabled:
		mat.set_shader_parameter("highlight", _vec(m.emission) * m.emission_energy_multiplier)
	var env := env_params(m.metallic, m.roughness)
	if env != Vector2.ZERO:
		mat.set_shader_parameter("env_tex", ENV_TEX)
		mat.set_shader_parameter("env_metal", env.x)
		mat.set_shader_parameter("env_gloss", env.y)
	mat.render_priority = m.render_priority
	return mat


static func is_model(m: Material) -> bool:
	return m is ShaderMaterial and (m as ShaderMaterial).shader in MODEL_SHADERS


## A PS2 model material's colour (multiplies its texture; raw gamma, 1 = as is).
static func set_color(mat: ShaderMaterial, c: Color) -> void:
	mat.set_shader_parameter("albedo_color", Vector4(c.r, c.g, c.b, c.a))


## A copy of PS2 model material `mat` that alpha-blends (see-through).
static func blended(mat: ShaderMaterial) -> ShaderMaterial:
	var out := mat.duplicate() as ShaderMaterial
	out.shader = MODEL_BLEND_SHADER
	return out


## A copy of alpha-blended PS2 model material `mat` cut out at `threshold`
## instead: opaque, so it sorts per pixel against other geometry.
static func cut_out(mat: ShaderMaterial, threshold: float = 0.5) -> ShaderMaterial:
	var out := mat.duplicate() as ShaderMaterial
	out.shader = MODEL_SHADER
	out.set_shader_parameter("alpha_scissor", threshold)
	return out


## The PS2 particle material for particle draw material `m`.
static func particle(m: BaseMaterial3D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.resource_name = m.resource_name
	mat.shader = PARTICLE_ADD_SHADER if m.blend_mode == BaseMaterial3D.BLEND_MODE_ADD else PARTICLE_SHADER
	if m.albedo_texture != null:
		var tex := Ps2Texture.palettize(m.albedo_texture, 16, Ps2Texture.SPRITE_MAX_SIZE, m.albedo_texture_msdf)
		if tex != null:
			mat.set_shader_parameter("albedo_tex", tex)
	var col := m.albedo_color
	mat.set_shader_parameter("albedo_color", Vector4(col.r, col.g, col.b, col.a))
	mat.set_shader_parameter("use_vertex_colors", m.vertex_color_use_as_albedo)
	mat.set_shader_parameter("lit", m.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED)
	mat.render_priority = m.render_priority
	return mat


## No specular on the PS2: metallic / roughness become sphere-map shine
## instead, as (env_metal, env_gloss) for the ps2_model and ps2_world
## shaders. Rough metal still shines, just dimmer (a blurry reflection is a
## lower-contrast one). Non-metal only shines below roughness 0.5, so the
## Blender default of 0.5 on cloth and leather stays matte.
static func env_params(metallic: float, roughness: float) -> Vector2:
	var metal := clampf(metallic, 0.0, 1.0)
	var rough := clampf(roughness, 0.0, 1.0)
	var env_metal := metal * (1.0 - 0.5 * rough) * ENV_METAL_GAIN
	var env_gloss := clampf((0.5 - rough) / 0.5, 0.0, 1.0) * (1.0 - metal) * ENV_GLOSS_GAIN
	return Vector2(env_metal, env_gloss)


static func _vec(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)
