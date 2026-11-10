// Editor view of a painted chunk's h1: its flat colour where unpainted, the
// palette textures where painted — blended like the client (terrain_cells.gdshaderinc).
shader_type spatial;
render_mode cull_disabled;
#include "res://world/terrain_cells.gdshaderinc"

uniform vec4 own_color : source_color = vec4(0.35, 0.52, 0.28, 1.0);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	ALBEDO = terrain_cells(own_color.rgb, world_pos.xz);
}
