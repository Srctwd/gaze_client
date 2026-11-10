// PS2 version of the WorldShaders terrain materials (surface, cave, wall).
// Scenery is lit per vertex for BOTH sides, since cave ceilings and terrain
// undersides are seen from behind; the fragment picks the side it faces.
shader_type spatial;
render_mode ambient_light_disabled, specular_disabled, fog_disabled, cull_disabled, depth_draw_opaque;
#include "res://ps2/ps2_common.gdshaderinc"
#include "res://world/terrain_cells.gdshaderinc"

uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform int   projection = 1;               // 0 = mesh UV, 1 = top-down XZ, 2 = triplanar
uniform float tile_scale = 2.0;
uniform vec3  tint = vec3(1.0);              // raw multiplier, may exceed 1
uniform bool  flat_backface = false;         // surface_mat: undersides use backface_color
uniform vec3  backface_color = vec3(0.25, 0.22, 0.20);
uniform float dir_light_scale = 1.0;         // 0 for caves: no sun underground
uniform float ambient_scale = 1.0;
// Sphere-map shine (§6.3), the PS2's stand-in for specular: walls get it from
// their material's metallic / roughness (ps2.gd _from_world). Metal reflects
// tinted by its own colour, polished stone (marble) reflects white.
uniform sampler2D env_tex : source_color, hint_default_black, filter_linear;
uniform float env_metal = 0.0;
uniform float env_gloss = 0.0;

varying vec3  v_light_front;      // with sun
varying vec3  v_light_back;
varying vec3  v_light_front_ns;   // without sun (in its shadow)
varying vec3  v_light_back_ns;
varying float v_fog;
varying vec3  world_pos;
varying vec3  world_n;
varying vec2  v_env_uv;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_n   = normalize(mat3(MODEL_MATRIX) * NORMAL);
	POSITION  = ps2_snap(PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	float dir = dir_light_scale * ps2_sun_scale;
	// Point lights per vertex: scenery has no single "object centre".
	vec3 rest_f = ps2_light_rest( world_n, world_pos, dir, ambient_scale);
	vec3 rest_b = ps2_light_rest(-world_n, world_pos, dir, ambient_scale);
	v_light_front    = clamp(rest_f + ps2_light_sun( world_n, dir), 0.0, 1.0);
	v_light_back     = clamp(rest_b + ps2_light_sun(-world_n, dir), 0.0, 1.0);
	v_light_front_ns = clamp(rest_f, 0.0, 1.0);
	v_light_back_ns  = clamp(rest_b, 0.0, 1.0);
	v_fog = ps2_fog(-(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z);
	vec3 view_n = normalize(mat3(MODELVIEW_MATRIX) * NORMAL);
	v_env_uv = view_n.xy * vec2(0.5, -0.5) + 0.5;
}

void fragment() {
	vec3 tex;
	if (projection == 0) {
		tex = texture(albedo_tex, UV).rgb;
	} else if (projection == 1) {
		tex = texture(albedo_tex, world_pos.xz / tile_scale).rgb;
	} else {
		vec3 b = abs(normalize(world_n));
		b /= (b.x + b.y + b.z);
		tex = texture(albedo_tex, vec2(world_pos.z, -world_pos.y) / tile_scale).rgb * b.x
			+ texture(albedo_tex, world_pos.xz / tile_scale).rgb * b.y
			+ texture(albedo_tex, vec2(world_pos.x, -world_pos.y) / tile_scale).rgb * b.z;
	}

	vec3 base = ps2_to_gamma(tex) * tint;
	if (use_cells) {   // painted cells: untinted, as in surface_mat
		base = ps2_to_gamma(terrain_cells(ps2_to_linear(base), world_pos.xz));
	}
	if (!FRONT_FACING && flat_backface) {
		base = backface_color;
	}
	vec3 add = vec3(0.0);
	if (FRONT_FACING && env_metal + env_gloss > 0.0) {
		add = ps2_to_gamma(texture(env_tex, v_env_uv).rgb) * (env_metal * base + env_gloss);
	}
	if (ps2_godot_lighting) {
		ps2_godot_surface(base, add, v_fog, ALBEDO, EMISSION);
	} else {
		vec3 lit   = ps2_to_linear(ps2_apply_fog(clamp(ps2_modulate(base, FRONT_FACING ? v_light_front    : v_light_back)    + add, 0.0, 1.0), v_fog));
		vec3 shade = ps2_to_linear(ps2_apply_fog(clamp(ps2_modulate(base, FRONT_FACING ? v_light_front_ns : v_light_back_ns) + add, 0.0, 1.0), v_fog));
		// mix(shade, lit, sun shadow) via light(), see ps2_common.gdshaderinc.
		EMISSION  = shade;
		ALBEDO    = max(lit - shade, vec3(0.0));
	}
	SPECULAR  = 0.0;
	METALLIC  = 0.0;
	ROUGHNESS = 1.0;
}
