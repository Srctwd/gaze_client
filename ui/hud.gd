extends CanvasLayer

var _hp_bar:   ProgressBar
var _mana_bar: ProgressBar
var _underwater: ColorRect
var _crosshair: Control
var _auto_label: Label
var _notices: Control  # screen notifications (skill level-ups), each at a random spot
var _bars_visible: bool = false


func _ready() -> void:
	_underwater = ColorRect.new()
	_underwater.color = Color(0.04, 0.18, 0.48, 0.22)
	_underwater.set_anchors_preset(Control.PRESET_FULL_RECT)
	_underwater.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_underwater.visible = false
	add_child(_underwater)

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(16, 16)
	vbox.custom_minimum_size = Vector2(200, 0)
	add_child(vbox)

	_hp_bar = _make_bar(Color(0.15, 0.8, 0.15), Color(0.05, 0.25, 0.05))
	vbox.add_child(_hp_bar)

	_mana_bar = _make_bar(Color(0.15, 0.35, 0.9), Color(0.05, 0.1, 0.3))
	vbox.add_child(_mana_bar)

	# Shown while the server is repeating our auto action (Tab).
	_auto_label = Label.new()
	_auto_label.text = "AUTO"
	_auto_label.visible = false
	vbox.add_child(_auto_label)
	Network.auto_action_changed.connect(func(on: bool): _auto_label.visible = on)

	vbox.visible = false

	# Notices: each at a random spot on screen, fading out on its own.
	_notices = Control.new()
	_notices.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_notices.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_notices)
	Network.skill_up.connect(_on_skill_up)

	_crosshair = _make_crosshair()
	_crosshair.visible = false
	add_child(_crosshair)

	GameState.aim_enabled_changed.connect(func(_v): _update_crosshair())


const _BASE_WIDTH  := 200.0
const _MAX_WIDTH   := 500.0
const _BASE_HEALTH := 25.0

func show_bars() -> void:
	_hp_bar.get_parent().visible = true
	_bars_visible = true
	_update_crosshair()

func hide_bars() -> void:
	_hp_bar.get_parent().visible = false
	_auto_label.visible = false
	_bars_visible = false
	_update_crosshair()

func _update_crosshair() -> void:
	_crosshair.visible = _bars_visible and GameState.aim_enabled

func _make_crosshair() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(8, 8)
	c.size = c.custom_minimum_size
	c.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func():
		var mid := c.custom_minimum_size * 0.5
		var col := Color(1, 1, 1, 0.8)
		c.draw_line(Vector2(mid.x, 0), Vector2(mid.x, c.custom_minimum_size.y), col, 2.0)
		c.draw_line(Vector2(0, mid.y), Vector2(c.custom_minimum_size.x, mid.y), col, 2.0)
	)
	return c

const _NOTICE_HOLD := 4.0  # seconds fully shown
const _NOTICE_FADE := 1.0
const _NOTICE_MAX  := 4    # oldest goes first past this
const _NOTICE_MARGIN := 0.25  # share of the screen kept clear on each side — notices land in the middle half

func _on_skill_up(skill: int, level: int) -> void:
	if skill < 0 or skill >= Protocol.SKILL_NAMES.size():
		return
	_show_notice("Your %s increased to %d." % [Protocol.SKILL_NAMES[skill], level])

func _show_notice(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	_notices.add_child(label)
	var screen := _notices.get_viewport_rect().size
	var margin := screen * _NOTICE_MARGIN
	var room := screen - margin * 2.0 - label.get_combined_minimum_size()
	label.position = margin + Vector2(randf() * maxf(room.x, 0.0), randf() * maxf(room.y, 0.0))
	while _notices.get_child_count() > _NOTICE_MAX:
		var oldest := _notices.get_child(0)
		_notices.remove_child(oldest)
		oldest.queue_free()
	var tween := label.create_tween()
	tween.tween_interval(_NOTICE_HOLD)
	tween.tween_property(label, "modulate:a", 0.0, _NOTICE_FADE)
	tween.tween_callback(label.queue_free)

func set_underwater(val: bool) -> void:
	_underwater.visible = val

func set_health(ratio: float, max_val: float = _BASE_HEALTH) -> void:
	_hp_bar.value = clampf(ratio, 0.0, 1.0) * 100.0
	_hp_bar.custom_minimum_size.x = _bar_width(max_val)


func set_mana(ratio: float, max_val: float = _BASE_HEALTH) -> void:
	_mana_bar.value = clampf(ratio, 0.0, 1.0) * 100.0
	_mana_bar.custom_minimum_size.x = _bar_width(max_val)


func _bar_width(max_val: float) -> float:
	return clampf(_BASE_WIDTH * (1.0 + log(max(max_val, 1.0) / _BASE_HEALTH) / log(10.0)), _BASE_WIDTH, _MAX_WIDTH)


func _make_bar(fill: Color, bg: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 100
	bar.value     = 100
	bar.custom_minimum_size = Vector2(200, 18)
	bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	bar.show_percentage = false

	var style_fill := StyleBoxFlat.new()
	style_fill.bg_color = fill
	bar.add_theme_stylebox_override("fill", style_fill)

	var style_bg := StyleBoxFlat.new()
	style_bg.bg_color = bg
	bar.add_theme_stylebox_override("background", style_bg)

	return bar
