// Body of the ps2_particle* shaders: particles as GS SPRITE primitives.
// A sprite is two corner vertices of a screen-aligned rectangle, so it can't
// rotate; its colour is the particle's vertex colour (0x80 = 1.0), its
// texture a small 4-bit paletted image (ps2_texture.gd), and it is fogged
// per vertex like everything else. PS2_ADD selects the additive variant.
#include "res://ps2/ps2_common.gdshaderinc"

uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap;
uniform vec4 albedo_color = vec4(1.0);    // raw (gamma) colour
uniform bool use_vertex_colors = true;    // particle colour ramp
uniform bool lit = false;                 // flat per-emitter light; off = full bright

varying vec3  v_light;
varying float v_fog;

void vertex() {
	// Screen-aligned sprite at the particle's centre, keeping its scale but
	// none of its rotation (the GS SPRITE primitive can't rotate).
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	vec4 view_pos = VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0) + vec4(VERTEX * scale, 0.0);
	POSITION = ps2_snap(PROJECTION_MATRIX * view_pos);

	// Particles have no useful normal: one flat light for the whole sprite,
	// ambient plus half of each directional light, plus nearby point lights.
	if (lit) {
		vec3 at = MODEL_MATRIX[3].xyz;
		v_light = ps2_ambient + (ps2_light_col0 + ps2_light_col1 + ps2_light_col2) * 0.5 * ps2_sun_scale;
		for (int i = 0; i < ps2_point_count; i++) {
			vec4 pr = texelFetch(ps2_point_tex, ivec2(i * 2, 0), 0);
			vec4 c  = texelFetch(ps2_point_tex, ivec2(i * 2 + 1, 0), 0);
			v_light += c.rgb * ps2_falloff(distance(at, pr.xyz), pr.w);
		}
		v_light = clamp(v_light, 0.0, 1.0);
	} else {
		v_light = vec3(0.5);   // 0x80: texture × colour, unchanged
	}
	v_fog = ps2_fog(-view_pos.z);
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	vec4 col = use_vertex_colors ? COLOR : vec4(1.0);
	vec3 c = ps2_modulate(ps2_to_gamma(tex.rgb * col.rgb) * albedo_color.rgb, v_light);
#ifdef PS2_ADD
	// Additive sprites fade to black in fog, or they'd glow through it.
	c = mix(vec3(0.0), c, v_fog);
#else
	c = ps2_apply_fog(c, v_fog);
#endif
	ALBEDO = ps2_to_linear(c);
	ALPHA  = tex.a * col.a * albedo_color.a;
}
