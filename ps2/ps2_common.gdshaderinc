// PS2 maths shared by every ps2_* shader. See ps2/PS2_RENDERING.md.
//
// Units follow the GS: every colour here is a gamma-space value where 0.5
// stands for 0x80, the GS's "1.0". Lit vertex colours run 0..1 (0x00..0xFF),
// so lighting can push a texture up to ×2 ("overbright").

// Per-frame light set, written by ps2.gd. On the PS2 this is the block of
// VU1 constants the EE uploads once per frame (or once per object).
global uniform vec3  ps2_light_dir0;   // unit vectors pointing TOWARD the light
global uniform vec3  ps2_light_dir1;
global uniform vec3  ps2_light_dir2;
global uniform vec3  ps2_light_col0;
global uniform vec3  ps2_light_col1;
global uniform vec3  ps2_light_col2;
global uniform vec3  ps2_ambient;
// Point lights in view, nearest the camera first (ps2.gd uploads up to MAX_POINTS):
// light i is (pos, range) at texel 2i and (colour, 0) at texel 2i + 1.
global uniform sampler2D ps2_point_tex;
global uniform int   ps2_point_count;
global uniform float ps2_point_flat;     // fraction of a point light's range lit at full strength (see ps2_falloff)
global uniform float ps2_point_wrap;     // point-light N·L wrap: 0 = Lambert, 1 = half-Lambert (see ps2_point)
global uniform bool  ps2_godot_points;   // test: Godot's own per-pixel OmniLights instead of the table (see light())
global uniform float ps2_godot_point_gain;
global uniform vec3  ps2_fog_color;
global uniform float ps2_fog_near;
global uniform float ps2_fog_far;
global uniform float ps2_shadow_strength;   // 0 = ignore shadow maps, 1 = full
global uniform vec2  ps2_screen_size;       // internal render size in pixels
global uniform float ps2_subpixel;          // GS vertex precision: 16 = 12.4 fixed point

// Per-object light scale (0 inside caves, etc.): the PS2 picked a light set
// per object/zone instead of casting shadows.
instance uniform float ps2_sun_scale = 1.0;

vec3 ps2_to_gamma(vec3 c)  { return pow(max(c, vec3(0.0)), vec3(1.0 / 2.2)); }
vec3 ps2_to_linear(vec3 c) { return pow(max(c, vec3(0.0)), vec3(2.2)); }

// §4.2 attenuation, as a flat-topped pool rather than the classic
// 1 / (k0 + k2·d²) peak: full strength out to ps2_point_flat of the light's
// range, then a smoothstep down to exactly 0 at the range, so a torch lights
// an even spot instead of a hot centre.
float ps2_falloff(float dist, float range) {
	float x = dist / max(range, 0.0001);
	return 1.0 - smoothstep(min(ps2_point_flat, 0.999), 1.0, x);
}

// Point light folded into a directional one, §4.2. `at` is the object centre
// for models (per-object, as the EE did it) or the vertex for scenery.
// N·L is wrapped by ps2_point_wrap: a torch a few units up hits the ground
// around it at a grazing angle, and plain Lambert left the ground dark a few
// units out whatever the range.
vec3 ps2_point(vec3 n, vec3 at, vec3 pos, vec3 col, float range) {
	vec3  v    = pos - at;
	float dist = length(v);
	float att  = ps2_falloff(dist, range);
	float ndl  = (dot(n, v / max(dist, 0.0001)) + ps2_point_wrap) / (1.0 + ps2_point_wrap);
	return col * att * max(ndl, 0.0);
}

// §4.1: d = max(L·n, 0); lit = ambient + C·d (+ point lights).
// Split in two so the sun (slot 0) can be shadowed: ps2_light_rest() is
// everything except the sun, ps2_light_sun() is the sun's N·L term.
vec3 ps2_light_rest(vec3 n, vec3 at, float dir_scale, float ambient_scale) {
	vec2 d = max(vec2(dot(n, ps2_light_dir1), dot(n, ps2_light_dir2)), 0.0) * dir_scale;
	vec3 lit = ps2_ambient * ambient_scale + ps2_light_col1 * d.x + ps2_light_col2 * d.y;
	// Point lights don't add up: each spot takes the brightest one reaching
	// it (per channel), so overlapping torches are no brighter than one.
	vec3 points = vec3(0.0);
	for (int i = 0; i < ps2_point_count; i++) {
		vec4 pr = texelFetch(ps2_point_tex, ivec2(i * 2, 0), 0);
		vec4 c  = texelFetch(ps2_point_tex, ivec2(i * 2 + 1, 0), 0);
		points = max(points, ps2_point(n, at, pr.xyz, c.rgb, pr.w));
	}
	lit += points;
	return lit;
}

vec3 ps2_light_sun(vec3 n, float dir_scale) {
	return ps2_light_col0 * max(dot(n, ps2_light_dir0), 0.0) * dir_scale;
}

vec3 ps2_light(vec3 n, vec3 at, float dir_scale, float ambient_scale) {
	return ps2_light_rest(n, at, dir_scale, ambient_scale) + ps2_light_sun(n, dir_scale);
}

// §3.2: the GS takes screen X/Y as 12.4 fixed point, so every vertex lands
// on a 1/16-pixel grid of the internal resolution. (1 = whole pixels, which
// is the PS1's wobble, for comparison.)
vec4 ps2_snap(vec4 clip) {
	if (ps2_subpixel <= 0.0 || abs(clip.w) < 1e-5) {
		return clip;
	}
	vec2 grid = ps2_screen_size * 0.5 * ps2_subpixel;   // NDC units → grid steps
	vec2 ndc = round(clip.xy / clip.w * grid) / grid;
	return vec4(ndc * clip.w, clip.zw);
}

// §6.4: linear per-vertex fog, 8-bit like the GS FOG register (1 = clear).
float ps2_fog(float view_depth) {
	float f = clamp((ps2_fog_far - view_depth) / max(ps2_fog_far - ps2_fog_near, 0.001), 0.0, 1.0);
	return floor(f * 255.0) / 255.0;
}

// §5: TFX MODULATE, out = tex * vc / 128 → ×2 in normalised terms.
// (Not `lit`: the particle shaders have a `uniform bool lit`, and Godot
// resolves the name to that uniform, which breaks their compile.)
vec3 ps2_modulate(vec3 tex_gamma, vec3 light) {
	return clamp(tex_gamma * light * 2.0, 0.0, 1.0);
}

// GS fog blend: (F*C + (255-F)*FOGCOL) >> 8.
vec3 ps2_apply_fog(vec3 c, float fog) {
	return mix(ps2_fog_color, c, fog);
}

// --- Shadows (not PS2: Godot's sun shadow map on top of the PS2 maths) -------
// The fragment shader finishes two full PS2 colours, `shade` (no sun) and
// `lit` (with sun), and outputs EMISSION = shade, ALBEDO = lit - shade.
// Godot then computes ALBEDO * DIFFUSE_LIGHT + EMISSION, and light() below
// sets DIFFUSE_LIGHT to the sun's shadow factor, so the result is exactly
// mix(shade, lit, shadow): identical to the unshaded look in full sun.
// Render modes needed: ambient_light_disabled, specular_disabled.
//
// With ps2_godot_points on (a test, not PS2), ps2.gd uploads no point lights
// and Godot's OmniLights are added per pixel instead, as Godot's own Lambert
// on the fragment's texture: SPECULAR_LIGHT is added untouched, while
// DIFFUSE_LIGHT would be scaled by ALBEDO (= lit - shade).

varying vec3 ps2_omni_base;   // linear texture colour, fogged; the fragment sets it

void light() {
	vec3 sun_view = normalize(mat3(VIEW_MATRIX) * ps2_light_dir0);
	if (LIGHT_IS_DIRECTIONAL && dot(LIGHT, sun_view) > 0.999) {
		DIFFUSE_LIGHT += vec3(mix(1.0, ATTENUATION, ps2_shadow_strength));
	} else if (!LIGHT_IS_DIRECTIONAL && ps2_godot_points) {
		SPECULAR_LIGHT += ps2_omni_base * LIGHT_COLOR * ATTENUATION
				* max(dot(NORMAL, LIGHT), 0.0) * ps2_godot_point_gain / PI;
	}
}
