// Per-cell terrain textures (<world>.cells.bin, read by world_data.gd). Each
// heightmap cell of a chunk names a layer of cell_tex, or 0 for the chunk's
// own texture. Blended between the four nearest cell centres, so painted
// patches meet over one cell instead of a hard square edge.
// Also included by world_editor/terrain_cells_editor.gdshader.

uniform bool  use_cells = false;
uniform sampler2D cell_index : filter_nearest;   // chunk_cells², R8: 0 = own texture, k = cell_tex layer k - 1
uniform sampler2DArray cell_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float cell_tile[64];                     // metres per texture repeat, per layer
uniform vec2  cell_origin;                       // the chunk's world XZ origin
uniform float cell_size = 0.5;

// `own` is the chunk's own texture at this pixel; linear colour in and out.
vec3 terrain_cells(vec3 own, vec2 wxz) {
	if (!use_cells) {
		return own;
	}
	ivec2 n  = textureSize(cell_index, 0);
	vec2  p  = (wxz - cell_origin) / cell_size - 0.5;
	ivec2 c0 = ivec2(floor(p));
	vec2  f  = p - vec2(c0);
	// Gradients from the pixel's own position: the layers sampled differ
	// between neighbouring pixels, so implicit ones would pick wrong mips.
	vec2 dx = dFdx(wxz);
	vec2 dy = dFdy(wxz);
	vec3 sum = vec3(0.0);
	for (int k = 0; k < 4; k++) {
		ivec2 o   = ivec2(k & 1, k >> 1);
		ivec2 c   = clamp(c0 + o, ivec2(0), n - 1);
		int   idx = int(texelFetch(cell_index, c, 0).r * 255.0 + 0.5);
		vec3  col = own;
		if (idx > 0) {
			float t = cell_tile[idx - 1];
			col = textureGrad(cell_tex, vec3(wxz / t, float(idx - 1)), dx / t, dy / t).rgb;
		}
		float w = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
		sum += col * w;
	}
	return sum;
}
