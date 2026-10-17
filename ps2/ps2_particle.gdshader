// Alpha-blended sprites: GS (Cs - Cd) * As + Cd. Body: ps2_particle.gdshaderinc.
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;
#include "res://ps2/ps2_particle.gdshaderinc"
