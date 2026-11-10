// Writes depth and no colour: the first pass under a see-through material
// (as its next_pass), so only the nearest surface of the mesh gets blended
// in and its far side and inner faces stay hidden. Transparent itself
// (ALPHA), so it sorts with the pass it guards: give it a lower
// render_priority than that pass.
shader_type spatial;
render_mode unshaded, depth_draw_always, cull_back, shadows_disabled;

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
