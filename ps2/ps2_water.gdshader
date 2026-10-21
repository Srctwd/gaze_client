// PS2 version of WorldShaders.water_mat: flat colour, per-vertex light and
// fog, alpha blended (GS (Cs - Cd) * As + Cd) with the same wave ripple.
shader_type spatial;
render_mode ambient_light_disabled, specular_disabled, fog_disabled, cull_disabled, blend_mix, depth_draw_opaque;
#include "res://ps2/ps2_common.gdshaderinc"

uniform vec4  water_color = vec4(0.08, 0.38, 0.65, 0.6);  // raw (gamma)
uniform float wave_speed  = 0.25;
uniform float wave_scale  = 5.0;

varying vec3  v_light;      // with sun
varying vec3  v_light_ns;   // without sun
varying float v_fog;

void vertex() {
	vec3 world_n   = normalize(mat3(MODEL_MATRIX) * NORMAL);
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 rest  = ps2_light_rest(world_n, world_pos, ps2_sun_scale, 1.0);
	v_light    = clamp(rest + ps2_light_sun(world_n, ps2_sun_scale), 0.0, 1.0);
	v_light_ns = clamp(rest, 0.0, 1.0);
	v_fog   = ps2_fog(-(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z);
}

void fragment() {
	vec2  uv = UV * wave_scale;
	float w  = sin(uv.x + TIME * wave_speed) * cos(uv.y + TIME * wave_speed * 0.7) * 0.04;
	if (ps2_godot_lighting) {
		ps2_godot_surface(water_color.rgb, vec3(0.0), v_fog, ALBEDO, EMISSION);
	} else {
		vec3 lit   = ps2_to_linear(ps2_apply_fog(ps2_modulate(water_color.rgb, v_light),    v_fog));
		vec3 shade = ps2_to_linear(ps2_apply_fog(ps2_modulate(water_color.rgb, v_light_ns), v_fog));
		EMISSION  = shade;
		ALBEDO    = max(lit - shade, vec3(0.0));
	}
	SPECULAR  = 0.0;
	METALLIC  = 0.0;
	ROUGHNESS = 1.0;
	ALPHA  = clamp(water_color.a + w, 0.3, 0.85);
}
