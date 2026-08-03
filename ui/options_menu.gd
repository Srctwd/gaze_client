extends CanvasLayer

var _camera: CameraController
var _toggle_btn: Button
var _panel: PanelContainer


func _ready() -> void:
	layer = 5

	_toggle_btn = Button.new()
	_toggle_btn.text = "⚙"
	_toggle_btn.custom_minimum_size = Vector2(36, 36)
	_toggle_btn.position = Vector2(8, 8)
	_toggle_btn.pressed.connect(_toggle)
	add_child(_toggle_btn)

	_panel = PanelContainer.new()
	_panel.position = Vector2(8, 52)
	_panel.visible = false
	add_child(_panel)

	# ── Main page ─────────────────────────────────────────────────────
	var main_page := VBoxContainer.new()
	main_page.custom_minimum_size = Vector2(240, 0)
	main_page.name = "MainPage"
	_panel.add_child(main_page)

	_section_label(main_page, "Graphics")

	var window_opt := OptionButton.new()
	window_opt.add_item("Windowed")
	window_opt.add_item("Fullscreen")
	window_opt.item_selected.connect(_on_window_mode)
	_row(main_page, "Window", window_opt)

	var vsync_check := CheckButton.new()
	vsync_check.button_pressed = DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED
	vsync_check.toggled.connect(_on_vsync)
	_row(main_page, "VSync", vsync_check)

	var aim_check := CheckButton.new()
	aim_check.button_pressed = GameState.aim_enabled
	aim_check.toggled.connect(_on_aim)
	_row(main_page, "Aim", aim_check)

	var interp_slider := HSlider.new()
	interp_slider.min_value = 10.0
	interp_slider.max_value = 70.0
	interp_slider.step = 1.0
	interp_slider.value = GameState.interp_rate
	interp_slider.custom_minimum_size = Vector2(100, 0)
	interp_slider.value_changed.connect(_on_interp_rate)
	_row(main_page, "Interpolation Rate", interp_slider)

	main_page.add_child(HSeparator.new())

	var controls_btn := Button.new()
	controls_btn.text = "Controls"
	controls_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	controls_btn.pressed.connect(_show_controls)
	main_page.add_child(controls_btn)

	# ── Controls page ─────────────────────────────────────────────────
	var ctrl_page := VBoxContainer.new()
	ctrl_page.custom_minimum_size = Vector2(240, 0)
	ctrl_page.name = "ControlsPage"
	ctrl_page.visible = false
	_panel.add_child(ctrl_page)

	_section_label(ctrl_page, "Controls")

	const BINDINGS := [
		["Up",        "W"],
		["Down",      "S"],
		["Left",      "A"],
		["Right",     "D"],
		["Interact",  "E"],
		["Main Hand", "1"],
		["Off Hand",  "2"],
		["Head Gear", "3"],
		["Drop",      "G"],
	]
	for b in BINDINGS:
		_binding_row(ctrl_page, b[0], b[1])

	ctrl_page.add_child(HSeparator.new())

	var back_btn := Button.new()
	back_btn.text = "← Back"
	back_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	back_btn.pressed.connect(_show_main)
	ctrl_page.add_child(back_btn)

	Network.connected.connect(func(): visible = true)
	Network.disconnected.connect(func(): visible = false)
	GameState.player_id_changed.connect(func(id): visible = id == -1)
	visible = false


func set_camera(cam: CameraController) -> void:
	_camera = cam


func _toggle() -> void:
	_panel.visible = !_panel.visible


func _on_window_mode(idx: int) -> void:
	if idx == 1:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


func _on_vsync(enabled: bool) -> void:
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if enabled else DisplayServer.VSYNC_DISABLED
	)


func _on_aim(enabled: bool) -> void:
	GameState.aim_enabled = enabled


func _on_interp_rate(val: float) -> void:
	GameState.interp_rate = val


func _on_sensitivity(val: float) -> void:
	if _camera:
		_camera.mouse_sensitivity = val


func _show_controls() -> void:
	_panel.get_node("MainPage").visible = false
	_panel.get_node("ControlsPage").visible = true


func _show_main() -> void:
	_panel.get_node("ControlsPage").visible = false
	_panel.get_node("MainPage").visible = true


func _section_label(parent: VBoxContainer, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	parent.add_child(lbl)
	parent.add_child(HSeparator.new())


func _binding_row(parent: VBoxContainer, action: String, key: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = action
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var key_lbl := Label.new()
	key_lbl.text = key
	key_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key_lbl.custom_minimum_size = Vector2(32, 0)
	row.add_child(key_lbl)


func _row(parent: VBoxContainer, label_text: String, control: Control) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	row.add_child(control)
