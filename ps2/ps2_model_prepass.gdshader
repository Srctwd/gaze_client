// Alpha blended with a depth pre-pass (TRANSPARENCY_ALPHA_DEPTH_PRE_PASS):
// opaque texels write depth and cast shadows, so foliage sorts and shadows
// like the original. Back-face culled. Body: ps2_model.gdshaderinc.
shader_type spatial;
render_mode ambient_light_disabled, specular_disabled, fog_disabled, cull_back, blend_mix, depth_prepass_alpha;
#define PS2_BLEND
#include "res://ps2/ps2_model.gdshaderinc"
