// Body of the ps2_model* shaders: UV-mapped models (characters, monsters,
// items, props). The wrappers only differ in render_mode, and define
// PS2_BLEND for the alpha-blended variant.
#include "res://ps2/ps2_common.gdshaderinc"

uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4  albedo_color = vec4(1.0);      // raw (gamma) colour, 1 = neutral
uniform vec3  uv1_scale = vec3(1.0);
uniform vec3  uv1_offset = vec3(0.0);
uniform bool  use_vertex_colors = false;     // baked prelight in COLOR
uniform float alpha_scissor = 0.0;           // 0 = off
uniform vec3  highlight = vec3(0.0);         // TFX HIGHLIGHT add (from emission)
uniform sampler2D env_tex : source_color, hint_default_black, filter_linear;
uniform float env_strength = 0.0;            // sphere-map shine, §6.3

varying vec3  v_light;      // with sun
varying vec3  v_light_ns;   // without sun (in its shadow)
varying float v_alpha;
varying float v_fog;
varying vec2  v_env_uv;

void vertex() {
	UV = UV * uv1_scale.xy + uv1_offset.xy;
	POSITION = ps2_snap(PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0));

	vec3 world_n = normalize(mat3(MODEL_MATRIX) * NORMAL);
	vec3 rest = ps2_light_rest(world_n, MODEL_MATRIX[3].xyz, ps2_sun_scale, 1.0);
	vec3 sun  = ps2_light_sun(world_n, ps2_sun_scale);
	vec3 pre  = use_vertex_colors ? COLOR.rgb : vec3(1.0);
	// Vertex colours are 8-bit on the GS: anything above 0xFF saturates.
	v_light    = clamp(pre * (rest + sun), 0.0, 1.0);
	v_light_ns = clamp(pre * rest, 0.0, 1.0);
	v_alpha = use_vertex_colors ? COLOR.a : 1.0;

	v_fog = ps2_fog(-(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z);

	vec3 view_n = normalize(mat3(MODELVIEW_MATRIX) * NORMAL);
	v_env_uv = view_n.xy * vec2(0.5, -0.5) + 0.5;
}

void fragment() {
	vec4  tex = texture(albedo_tex, UV);
	float a   = tex.a * albedo_color.a * v_alpha;
	if (alpha_scissor > 0.0 && a < alpha_scissor) {
		discard;
	}

	vec3 base = ps2_to_gamma(tex.rgb) * albedo_color.rgb;
	vec3 add  = highlight;
	if (env_strength > 0.0) {
		add += ps2_to_gamma(texture(env_tex, v_env_uv).rgb) * env_strength;
	}
	if (ps2_godot_lighting) {
		// Prelight in COLOR tints the texture, as vertex_color_use_as_albedo did.
		ps2_godot_surface(base * (use_vertex_colors ? COLOR.rgb : vec3(1.0)), add, v_fog, ALBEDO, EMISSION);
	} else {
		vec3 lit   = ps2_to_linear(ps2_apply_fog(clamp(ps2_modulate(base, v_light)    + add, 0.0, 1.0), v_fog));
		vec3 shade = ps2_to_linear(ps2_apply_fog(clamp(ps2_modulate(base, v_light_ns) + add, 0.0, 1.0), v_fog));
		// mix(shade, lit, sun shadow) via light(), see ps2_common.gdshaderinc.
		EMISSION  = shade;
		ALBEDO    = max(lit - shade, vec3(0.0));
	}
	SPECULAR  = 0.0;
	METALLIC  = 0.0;
	ROUGHNESS = 1.0;
#ifdef PS2_BLEND
	ALPHA = a;
#endif
}
