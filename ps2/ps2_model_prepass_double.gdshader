// ps2_model_prepass, double-sided. Body: ps2_model.gdshaderinc.
shader_type spatial;
render_mode ambient_light_disabled, specular_disabled, fog_disabled, cull_disabled, blend_mix, depth_prepass_alpha;
#define PS2_BLEND
#include "res://ps2/ps2_model.gdshaderinc"
