// Stylised grass blades (world/grass.gd). Each instance is a tuft cut from
// grass01.glb; mesh COLOR.r = per-blade random, COLOR.g = height along the
// blade (0 root .. 1 tip), COLOR.b = across it (0..1); INSTANCE_CUSTOM = (random, ground tile metres,
// ground tinted?, -). Lit like ps2_world.gdshader, but every blade takes the
// ground's normal (straight up) so the field shades as one soft surface
// instead of thousands of flickering cards.
shader_type spatial;
render_mode world_vertex_coords, ambient_light_disabled, specular_disabled, fog_disabled, cull_disabled, depth_draw_opaque;
#include "res://ps2/ps2_common.gdshaderinc"

uniform sampler2D blade_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D ground_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D gust_tex : filter_linear, repeat_enable;
uniform vec3  ground_tint = vec3(0.85, 1.2, 0.75);   // WorldShaders._GRASS_TINT (unpainted ground)
uniform vec3  tip_color   = vec3(0.66, 0.80, 0.34);  // gamma
uniform vec3  tip_color_b = vec3(0.52, 0.72, 0.28);  // per-blade variation
uniform vec3  gust_color  = vec3(0.86, 0.94, 0.58);  // bright sheen riding the gusts
uniform float tip_start   = 0.25;   // blade height where the tip colour starts
uniform float tip_amount  = 0.80;   // how far toward the tip colour the tip goes
uniform float root_ao     = 0.75;   // darkening at the very root
// Blade shape, cut procedurally (the texture's own blade is a thin strip of
// its card): half width 1 at the root, tapering to a point.
uniform float blade_width = 0.85;
uniform float taper_power = 0.7;

uniform vec2  wind_dir      = vec2(1.0, 0.35);
uniform float wind_strength = 0.30;   // sway, × blade height
uniform float wind_speed    = 1.6;
uniform float gust_strength = 0.55;
uniform float gust_speed    = 0.06;   // gust field scroll, UV per second

uniform vec3  push_pos = vec3(0.0, -10000.0, 0.0);
uniform float push_radius = 0.9;
uniform float push_strength = 0.9;

uniform float fade_start = 22.0;
uniform float fade_end   = 32.0;

varying vec3  v_light;
varying vec3  v_light_ns;
varying float v_fog;
varying vec3  v_ground;
varying float v_h;
varying float v_rand;
varying float v_gust;
varying float v_across;
varying float v_grow;

void vertex() {
	vec3  tuft = MODEL_MATRIX[3].xyz;
	float height = length(MODEL_MATRIX[1].xyz);
	float h = COLOR.g;
	float bend = h * h;
	vec3  wp = VERTEX;   // world space (world_vertex_coords)

	// Sink into the ground with distance instead of popping out.
	float d = distance(tuft, CAMERA_POSITION_WORLD);
	float grow = 1.0 - smoothstep(fade_start, fade_end, d);
	wp.y = tuft.y + (wp.y - tuft.y) * grow;

	// Wind: a slow travelling sway plus a scrolling gust field.
	vec2 wd = normalize(wind_dir);
	float phase = INSTANCE_CUSTOM.x * 6.2831 + COLOR.r * 1.7;
	float gust = texture(gust_tex, tuft.xz * 0.015 - wd * TIME * gust_speed).r;
	gust = smoothstep(0.35, 0.85, gust);
	float sway = sin(TIME * wind_speed + dot(tuft.xz, wd) * 0.45 + phase) * 0.5 + 0.35;
	vec2 off = wd * (sway * wind_strength + gust * gust_strength);
	off += vec2(sin(TIME * 2.3 + phase * 3.0), cos(TIME * 1.9 + phase * 2.0)) * 0.04;   // flutter

	// The player parts the grass.
	vec2  dv = tuft.xz - push_pos.xz;
	float pd = length(dv);
	float push = (1.0 - smoothstep(push_radius * 0.3, push_radius, pd))
			* (1.0 - smoothstep(1.2, 2.2, abs(tuft.y - push_pos.y)));
	off += (pd > 0.001 ? dv / pd : vec2(0.0)) * push * push_strength;

	vec2 disp = off * bend * height * grow;
	wp.xz += disp;
	wp.y  -= dot(disp, disp) / max(height, 0.01) * 0.5 * h;   // keep the blade's length while bending
	VERTEX = wp;
	NORMAL = vec3(0.0, 1.0, 0.0);
	POSITION = ps2_snap(PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0));

	float dir = ps2_sun_scale;
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 rest = ps2_light_rest(up, wp, dir, 1.0);
	v_light    = clamp(rest + ps2_light_sun(up, dir), 0.0, 1.0);
	v_light_ns = clamp(rest, 0.0, 1.0);
	v_fog = ps2_fog(-(VIEW_MATRIX * vec4(wp, 1.0)).z);

	// The terrain's own colour under the tuft: painted cells untinted at their
	// tile, unpainted ground tinted at surface_mat's 66 m.
	vec3 g = texture(ground_tex, tuft.xz / INSTANCE_CUSTOM.y).rgb;   // linear
	g = ps2_to_gamma(g);
	v_ground = INSTANCE_CUSTOM.z > 0.5 ? g * ground_tint : g;
	v_h = h;
	v_rand = fract(COLOR.r + INSTANCE_CUSTOM.x * 7.13);
	v_gust = gust;
	v_across = COLOR.b;
	v_grow = grow;
}

void fragment() {
	float half_w = blade_width * pow(max(1.0 - v_h, 0.0), taper_power);
	if (abs(v_across - 0.5) * 2.0 > half_w) {
		discard;
	}
	vec4 bt = texture(blade_tex, vec2(mix(0.47, 0.53, v_across), UV.y));
	vec3 tip  = mix(tip_color, tip_color_b, v_rand);
	// Far blades fade to the ground colour as they sink, so the field's edge
	// doesn't sparkle.
	float t   = smoothstep(tip_start, 1.0, v_h) * tip_amount * v_grow;
	vec3 base = mix(v_ground, tip, t);
	// A touch of the blade texture's streaks.
	float lum = dot(ps2_to_gamma(bt.rgb), vec3(0.299, 0.587, 0.114));
	base *= mix(1.0, lum / 0.45, 0.25);
	base *= mix(root_ao, 1.0, smoothstep(0.0, 0.35, v_h));
	base = mix(base, gust_color, v_gust * t * 0.30);
	base = clamp(base, 0.0, 1.0);

	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	if (ps2_godot_lighting) {
		ps2_godot_surface(base, vec3(0.0), v_fog, ALBEDO, EMISSION);
	} else {
		vec3 lit   = ps2_to_linear(ps2_apply_fog(clamp(ps2_modulate(base, v_light),    0.0, 1.0), v_fog));
		vec3 shade = ps2_to_linear(ps2_apply_fog(clamp(ps2_modulate(base, v_light_ns), 0.0, 1.0), v_fog));
		EMISSION = shade;
		ALBEDO   = max(lit - shade, vec3(0.0));
	}
	SPECULAR  = 0.0;
	METALLIC  = 0.0;
	ROUGHNESS = 1.0;
}
