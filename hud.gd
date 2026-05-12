extends CanvasLayer

var _hp_bar:   ProgressBar
var _mana_bar: ProgressBar


func _ready() -> void:
	var vbox := VBoxContainer.new()
	vbox.position = Vector2(16, 16)
	vbox.custom_minimum_size = Vector2(200, 0)
	add_child(vbox)

	_hp_bar = _make_bar(Color(0.15, 0.8, 0.15), Color(0.05, 0.25, 0.05))
	vbox.add_child(_hp_bar)

	_mana_bar = _make_bar(Color(0.15, 0.35, 0.9), Color(0.05, 0.1, 0.3))
	vbox.add_child(_mana_bar)

	vbox.visible = false


const _BASE_WIDTH  := 200.0
const _MAX_WIDTH   := 500.0
const _BASE_HEALTH := 25.0

func show_bars() -> void:
	_hp_bar.get_parent().visible = true

func hide_bars() -> void:
	_hp_bar.get_parent().visible = false

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
