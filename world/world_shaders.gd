const _GRASS_TEX = preload("res://assets/tileable_grass.png")
const _CAVE_TEX  = preload("res://assets/cave_texture.jpg")


static func water_mat() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque;
uniform vec4  water_color : source_color = vec4(0.08, 0.38, 0.65, 0.6);
uniform float wave_speed  = 0.25;
uniform float wave_scale  = 5.0;
void fragment() {
	vec2 uv   = UV * wave_scale;
	float w   = sin(uv.x + TIME * wave_speed) * cos(uv.y + TIME * wave_speed * 0.7) * 0.04;
	ALBEDO    = water_color.rgb;
	ALPHA     = clamp(water_color.a + w, 0.3, 0.85);
	ROUGHNESS = 0.05;
	METALLIC  = 0.2;
	SPECULAR  = 1.0;
	NORMAL    = vec3(sin(uv.x + TIME * wave_speed) * 0.08, 1.0, cos(uv.y + TIME * wave_speed * 0.7) * 0.08);
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.render_priority = 1
	return m


static func cave_mat(tint: Color) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D cave_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float tile_scale = 4.0;
varying vec3 world_pos;
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	vec3 tex = texture(cave_tex, world_pos.xz / tile_scale).rgb;
	ALBEDO = tex * tint.rgb;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("cave_tex", _CAVE_TEX)
	m.set_shader_parameter("tint", tint)
	return m


# Default grass look keeps its green boost; biome textures from world.bin
# render untinted.
const _GRASS_TINT := Color(0.85, 1.2, 0.75)


static func surface_mat(color: Color, tex: Texture2D = _GRASS_TEX, top_tint: Color = _GRASS_TINT, tile_size: float = 66.0) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform float tile_scale = 2.0;
uniform vec4 albedo_bottom: source_color = vec4(0.25, 0.22, 0.20, 1.0);
uniform vec3 top_tint = vec3(0.85, 1.2, 0.75);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	vec4 tex = texture(albedo_texture, world_pos.xz / tile_scale);
	ALBEDO = FRONT_FACING ? tex.rgb * top_tint : albedo_bottom.rgb;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("albedo_texture", tex)
	mat.set_shader_parameter("top_tint",       Vector3(top_tint.r, top_tint.g, top_tint.b))
	mat.set_shader_parameter("tile_scale",     tile_size)
	mat.set_shader_parameter("albedo_bottom",  Color(0.25, 0.22, 0.20))
	return mat


# Shared by every wall type (one Shader, one compile); each type only gets
# its own ShaderMaterial for its texture.
static var _wall_shader: Shader


static func wall_mat(texture: Texture2D = _CAVE_TEX, tint: Color = Color(1.0, 1.0, 1.0, 1.0)) -> ShaderMaterial:
	if _wall_shader == null:
		_wall_shader = Shader.new()
		_wall_shader.code = _WALL_SHADER_CODE
	var m := ShaderMaterial.new()
	m.shader = _wall_shader
	m.set_shader_parameter("wall_tex", texture)
	m.set_shader_parameter("tint", tint)
	return m


const _WALL_SHADER_CODE := """
shader_type spatial;
uniform sampler2D wall_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float tile_scale = 2.0;
varying vec3 world_pos;
varying vec3 world_normal;
void vertex() {
	world_pos    = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	// Triplanar, world-space sampling: an OBB wall's own UVs would stretch the
	// texture to fit each box's size/rotation, so tile from world position
	// instead — every wall gets the same on-the-ground texel density and the
	// side faces stay aligned to the wall regardless of its yaw.
	vec3 blend = abs(world_normal);
	blend /= (blend.x + blend.y + blend.z);
	// Side faces map image-v to -world Y so the texture's top points up on
	// both X and Z facing walls (directional textures like vines climb).
	vec3 tex_x = texture(wall_tex, vec2(world_pos.z, -world_pos.y) / tile_scale).rgb;
	vec3 tex_y = texture(wall_tex, world_pos.xz / tile_scale).rgb;
	vec3 tex_z = texture(wall_tex, vec2(world_pos.x, -world_pos.y) / tile_scale).rgb;
	ALBEDO = (tex_x * blend.x + tex_y * blend.y + tex_z * blend.z) * tint.rgb;
}
"""


# Biome textures repeat this many times across each chunk edge.
const BIOME_TEX_REPEATS := 8


static func biome_surface_mat(biome_id: int, biomes: Array, chunk_size: float) -> ShaderMaterial:
	var mat_name := "grassland"
	for bdef in biomes:
		if (bdef as Dictionary)["id"] == biome_id:
			mat_name = (bdef as Dictionary).get("material", "grassland") as String
			break
	# Newer world.bin files store a texture path here instead of a name.
	if mat_name.begins_with("res://"):
		var tex := _resolve_biome_texture(mat_name)
		if tex != null:
			if tex == _GRASS_TEX:
				return surface_mat(Color.WHITE)
			return surface_mat(Color.WHITE, tex, Color.WHITE, chunk_size / BIOME_TEX_REPEATS)
		push_warning("WorldShaders: biome %d texture not found: %s" % [biome_id, mat_name])
	var color := Color(0.35, 0.52, 0.28)
	match mat_name:
		"grassland":    color = Color(0.35, 0.52, 0.28)
		"forest":       color = Color(0.18, 0.38, 0.16)
		"elven_floor":  color = Color(0.25, 0.48, 0.32)
		"slime_ground": color = Color(0.28, 0.50, 0.18)
		"desert_sand":  color = Color(0.78, 0.68, 0.45)
		"snow":         color = Color(0.88, 0.90, 0.93)
		"swamp_mud":    color = Color(0.28, 0.32, 0.18)
	return surface_mat(color)


# The editor's asset tree doesn't always match this project's, so if the
# exact path is missing, look for the same file stem under the usual texture
# folders with any common image extension.
static func _resolve_biome_texture(path: String) -> Texture2D:
	var tex := _load_texture(path)
	if tex != null:
		return tex
	var stem := path.get_file().get_basename()
	for dir in [path.get_base_dir(), "res://assets", "res://assets/textures"]:
		for ext in ["png", "jpg", "jpeg", "webp"]:
			tex = _load_texture("%s/%s.%s" % [dir, stem, ext])
			if tex != null:
				return tex
	return null


static func _load_texture(path: String) -> Texture2D:
	if not path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
		return null
	if not FileAccess.file_exists(path) and not ResourceLoader.exists(path):
		return null
	if ResourceLoader.exists(path):
		var tex := ResourceLoader.load(path) as Texture2D
		if tex != null:
			return tex
	# Not imported yet (dropped in while the editor wasn't scanning): read the
	# raw image so the biome still renders.
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
