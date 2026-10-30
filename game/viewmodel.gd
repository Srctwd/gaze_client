extends CanvasLayer
## First-person held items, drawn over the 3D view like UI so walls never hide
## them. equipment.gd moves our own hand items onto LAYER in first person; the
## main camera never draws that layer, and this overlay's camera — a copy of
## the main one — draws only it, into a transparent SubViewport sharing the
## main World3D (same lights and environment). Under ps2.gd's post layer (-1),
## so PS2 dither and line filter apply to it too.
##
## A camera only uses the lights whose layers it sees, so every Light3D (sun,
## moon, torches, effects) also gets LAYER, or the held items render unlit.

const LAYER := 1 << 19   # render layer 20

var _main: Camera3D
var _view: SubViewport
var _cam: Camera3D


func _ready() -> void:
	layer = -2
	process_priority = 1000   # after everything that moves the main camera (entity_manager, input)
	_main = get_parent() as Camera3D
	_main.cull_mask &= ~LAYER

	var box := SubViewportContainer.new()
	box.stretch = true
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view = SubViewport.new()
	_view.transparent_bg = true
	_view.gui_disable_input = true
	_cam = Camera3D.new()
	_cam.cull_mask = LAYER
	_view.add_child(_cam)
	box.add_child(_view)
	add_child(box)
	_cam.current = true

	for light in get_tree().root.find_children("*", "Light3D", true, false):
		_light_on_layer(light)
	get_tree().node_added.connect(_light_on_layer)
	GameState.first_person_changed.connect(_set_on)
	_set_on(GameState.first_person)


func _light_on_layer(node: Node) -> void:
	if node is Light3D:
		(node as Light3D).layers |= LAYER


func _set_on(on: bool) -> void:
	visible = on
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED


# Last in the frame's process step, so the copy lands in the same frame as the
# main camera's own move (a copy made at frame_pre_draw only reaches the
# renderer a frame late). The 3D scaling follows the main view's, i.e. ps2.gd's
# 448-line mode; set only on change, since a new value rebuilds the buffers.
func _process(_delta: float) -> void:
	if not visible or not _main.is_inside_tree():
		return
	_cam.global_transform = _main.global_transform
	_cam.fov  = _main.fov
	_cam.near = _main.near
	_cam.far  = _main.far
	var vp := get_viewport()
	if _view.scaling_3d_mode != vp.scaling_3d_mode:
		_view.scaling_3d_mode = vp.scaling_3d_mode
	if _view.scaling_3d_scale != vp.scaling_3d_scale:
		_view.scaling_3d_scale = vp.scaling_3d_scale
