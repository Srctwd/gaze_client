// Additive sprites: GS Cs * As + Cd. Body: ps2_particle.gdshaderinc.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_never, blend_add, shadows_disabled;
#define PS2_ADD
#include "res://ps2/ps2_particle.gdshaderinc"
