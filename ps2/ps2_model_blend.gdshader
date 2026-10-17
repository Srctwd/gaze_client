// Alpha blended: GS (Cs - Cd) * As + Cd, §6.1. Body: ps2_model.gdshaderinc.
shader_type spatial;
render_mode ambient_light_disabled, specular_disabled, fog_disabled, cull_back, blend_mix;
#define PS2_BLEND
#include "res://ps2/ps2_model.gdshaderinc"
