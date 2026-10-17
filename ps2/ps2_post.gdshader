// PS2 video output, §6.5: 16-bit framebuffer dither (GS DTHE with the
// standard 4×4 DIMX matrix, then truncate to 5 bits per channel) and the
// CRTC flicker filter (blend with the neighbouring lines). Works in the
// internal-resolution pixel grid that ps2.gd renders the 3D view at.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float ps2_lines = 448.0;        // internal vertical resolution
uniform bool  dither = true;
uniform float flicker_filter = 0.5;     // 0 = off, 1 = full 1-2-1 blend

// DIMX[x][y]: column x, row y. Rows: -4 2 -3 3 / 0 -2 1 -1 / -3 3 -4 2 / 1 -1 0 -2
const mat4 DIMX = mat4(
	vec4(-4.0,  0.0, -3.0,  1.0),
	vec4( 2.0, -2.0,  3.0, -1.0),
	vec4(-3.0,  1.0, -4.0,  0.0),
	vec4( 3.0, -1.0,  2.0, -2.0));

void fragment() {
	float scale = clamp(ps2_lines * SCREEN_PIXEL_SIZE.y, 0.0, 1.0);  // internal / screen
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;

	if (flicker_filter > 0.0) {
		float line = SCREEN_PIXEL_SIZE.y / max(scale, 0.0001);
		vec3 up = texture(screen_tex, SCREEN_UV - vec2(0.0, line)).rgb;
		vec3 dn = texture(screen_tex, SCREEN_UV + vec2(0.0, line)).rgb;
		c = mix(c, (up + 2.0 * c + dn) * 0.25, flicker_filter);
	}

	if (dither) {
		ivec2 p = ivec2(floor(FRAGCOORD.xy * scale)) & ivec2(3);
		float d = DIMX[p.x][p.y];
		c = floor(clamp(c * 255.0 + d, 0.0, 255.0) / 8.0) * 8.0 / 255.0;
	}
	COLOR = vec4(c, 1.0);
}
