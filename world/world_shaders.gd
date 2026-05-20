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


static func surface_mat(color: Color, holes: Array) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform float tile_scale = 2.0;
uniform vec4 albedo_bottom: source_color = vec4(0.25, 0.22, 0.20, 1.0);
uniform vec2 hole_centers[16];
uniform float hole_radii[16];
uniform int hole_count = 0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	for (int i = 0; i < hole_count; i++) {
		if (length(world_pos.xz - hole_centers[i]) < hole_radii[i]) discard;
	}
	vec4 tex = texture(albedo_texture, world_pos.xz / 66.0);
	ALBEDO = FRONT_FACING ? tex.rgb * vec3(0.85, 1.2, 0.75) : albedo_bottom.rgb;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("albedo_texture", _GRASS_TEX)
	mat.set_shader_parameter("tile_scale",     21.0)
	mat.set_shader_parameter("albedo_bottom",  Color(0.25, 0.22, 0.20))
	mat.set_shader_parameter("hole_count",     mini(holes.size(), 16))

	var centers := PackedVector2Array()
	var radii   := PackedFloat32Array()
	for j in range(mini(holes.size(), 16)):
		centers.append((holes[j] as Dictionary)["center"])
		radii.append((holes[j] as Dictionary)["radius"])
	while centers.size() < 16:
		centers.append(Vector2.ZERO)
		radii.append(0.0)

	mat.set_shader_parameter("hole_centers", centers)
	mat.set_shader_parameter("hole_radii",   radii)
	return mat


static func biome_surface_mat(biome_id: int, holes: Array, biomes: Array) -> ShaderMaterial:
	var mat_name := "grassland"
	for bdef in biomes:
		if (bdef as Dictionary)["id"] == biome_id:
			mat_name = (bdef as Dictionary).get("material", "grassland") as String
			break
	var color := Color(0.35, 0.52, 0.28)
	match mat_name:
		"grassland":    color = Color(0.35, 0.52, 0.28)
		"forest":       color = Color(0.18, 0.38, 0.16)
		"elven_floor":  color = Color(0.25, 0.48, 0.32)
		"slime_ground": color = Color(0.28, 0.50, 0.18)
		"desert_sand":  color = Color(0.78, 0.68, 0.45)
		"snow":         color = Color(0.88, 0.90, 0.93)
		"swamp_mud":    color = Color(0.28, 0.32, 0.18)
	return surface_mat(color, holes)
