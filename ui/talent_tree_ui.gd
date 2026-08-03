extends CanvasLayer

# Renders the tree built by TalentTree (game/talent_tree.gd) and drives it
# off Network's TalentSync/LearnTalentRequest traffic. No parsing or
# requirement-evaluation logic lives here — see talent_tree.gd for that.
#
# Fullscreen, opaque, starry backdrop. Tier 0 sits at the bottom of the
# screen, higher tiers stack upward.

signal forced_pick_completed

const _NODE_SIZE  := Vector2(100, 110)  # footprint: icon + name label stacked under it
const _ICON_SIZE  := Vector2(64, 64)
const _BG_COLOR   := Color(0.0, 0.0, 0.0, 1.0)
const _STAR_COUNT := 220

# A talent's icon is res://assets/talent_icons/<key>.png (e.g. Flames ->
# talent_icons/Flames.png), derived from the talent's own key — drop a
# matching PNG in place and it's picked up automatically, no lookup table
# to maintain.
const _ICON_DIR := "res://assets/talent_icons/"

var _tree := TalentTree.new()

var _starfield: Control
var _stars: Array = []  # Array[{"pos": Vector2 (0..1), "radius": float, "brightness": float}]

var _points_label: Label
var _desc_label: Label
var _tree_area: Control
var _buttons: Dictionary = {}   # node_id -> TextureButton (the clickable icon itself)
var _labels: Dictionary = {}    # node_id -> Label (name, shown under the icon)
var _containers: Dictionary = {}  # node_id -> VBoxContainer (icon + label, positioned as one unit)
var _placeholder_icon: Texture2D
var _row_frac: Dictionary = {}  # node_id -> float (0 = top, 1 = bottom)
var _col_frac: Dictionary = {}  # node_id -> float (0..1)
var _centers: Dictionary = {}   # node_id -> Vector2 (local to _tree_area, updated on resize)
var _edges: Array = []          # Array[Vector2i] of (child_id, parent_id)

var _points_available: int = 0
var _learned: Dictionary = {}  # node_id -> true
var _close_btn: Button
var _forced: bool = false          # true while blocking on a mandatory first pick
var _expect_open: bool = false     # true after we explicitly requested a sync (FrozenStarlight interact)


func _ready() -> void:
	_tree.load()

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var bg := ColorRect.new()
	bg.color = _BG_COLOR
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	_starfield = Control.new()
	_starfield.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_starfield.draw.connect(_draw_stars)
	_starfield.resized.connect(_starfield.queue_redraw)
	root.add_child(_starfield)
	_generate_stars()

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	root.add_child(margin)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Talent Tree"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	vbox.add_child(title)

	_points_label = Label.new()
	_points_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_points_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(_points_label)

	_build_tree_area()
	vbox.add_child(_tree_area)

	_desc_label = Label.new()
	_desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.custom_minimum_size = Vector2(0, 40)
	_desc_label.add_theme_font_size_override("font_size", 16)
	_desc_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(_desc_label)

	_close_btn = Button.new()
	_close_btn.text = "Close"
	_close_btn.custom_minimum_size = Vector2(160, 40)
	_close_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_close_btn.pressed.connect(_close)
	vbox.add_child(_close_btn)

	visible = false
	Network.talent_synced.connect(_on_talent_synced)


func _generate_stars() -> void:
	_stars.clear()
	for i in _STAR_COUNT:
		_stars.append({
			"pos": Vector2(randf(), randf()),
			"radius": randf_range(0.6, 1.8),
			"brightness": randf_range(0.3, 1.0),
		})



# A plain filled circle, used for any talent without a matching res://assets/<id>.png
# so every node still has a clickable icon.
func _make_placeholder_icon() -> Texture2D:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size, size) * 0.5
	var radius := size * 0.5 - 2.0
	for y in size:
		for x in size:
			if Vector2(x, y).distance_to(center) <= radius:
				img.set_pixel(x, y, Color(0.4, 0.4, 0.45, 1.0))
	return ImageTexture.create_from_image(img)


func _draw_stars() -> void:
	var size := _starfield.size
	for star in _stars:
		var b: float = star.brightness
		_starfield.draw_circle(star.pos * size, star.radius, Color(b, b, b, 1.0))


func _build_tree_area() -> void:
	_tree_area = Control.new()
	_tree_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree_area.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_tree_area.draw.connect(_draw_edges)
	_tree_area.resized.connect(_reposition)

	var tiers: Dictionary = {}  # tier -> Array of talent dicts, in file order
	var max_tier := 0
	for t in _tree.talents:
		if not tiers.has(t.tier):
			tiers[t.tier] = []
		tiers[t.tier].append(t)
		max_tier = maxi(max_tier, t.tier)

	var tier_keys: Array = tiers.keys()
	tier_keys.sort()

	# Column layout: the root tier is spread evenly; every other node's column
	# is the average of its own prerequisites' columns, so lines converge and
	# diverge the way the dependency graph actually branches instead of
	# radiating out of a symmetric center (which reads as a pentagram/star).
	for tier_i in tier_keys.size():
		var tier = tier_keys[tier_i]
		var row: Array = tiers[tier]
		var desired: Dictionary = {}  # node_id -> float, before collision resolution

		for t in row:
			var parent_ids := _tree.prereq_nodes(t.prereq)
			if tier_i == 0 or parent_ids.is_empty():
				desired[t.id] = -1.0  # placeholder, filled below by even spacing
			else:
				var sum := 0.0
				for pid in parent_ids:
					sum += _col_frac[pid]
				desired[t.id] = sum / parent_ids.size()

		var evenly_spaced: Array = row.filter(func(t): return desired[t.id] < 0.0)
		for i in evenly_spaced.size():
			desired[evenly_spaced[i].id] = (i + 0.5) / evenly_spaced.size()

		var sorted_row := row.duplicate()
		sorted_row.sort_custom(func(a, b): return desired[a.id] < desired[b.id])

		var min_gap := 1.0 / (row.size() + 1)
		var prev_col := -INF
		for t in sorted_row:
			var col: float = maxf(desired[t.id], prev_col + min_gap)
			_col_frac[t.id] = col
			prev_col = col

		for t in row:
			# tier 0 at the bottom (frac 1.0), highest tier at the top (frac 0.0)
			_row_frac[t.id] = 1.0 if max_tier == 0 else 1.0 - float(t.tier) / max_tier

	_placeholder_icon = _make_placeholder_icon()

	for t in _tree.talents:
		var container := VBoxContainer.new()
		container.alignment = BoxContainer.ALIGNMENT_CENTER
		container.size = _NODE_SIZE
		container.add_theme_constant_override("separation", 6)
		_tree_area.add_child(container)
		_containers[t.id] = container

		var icon_btn := TextureButton.new()
		var icon_path: String = _ICON_DIR + t.key + ".png"
		icon_btn.texture_normal = load(icon_path) if ResourceLoader.exists(icon_path) else _placeholder_icon
		icon_btn.ignore_texture_size = true
		icon_btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		icon_btn.custom_minimum_size = _ICON_SIZE
		icon_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		icon_btn.pressed.connect(_on_talent_pressed.bind(t.id))
		icon_btn.mouse_entered.connect(_on_talent_hovered.bind(t.id))
		icon_btn.mouse_exited.connect(_on_talent_unhovered)
		container.add_child(icon_btn)
		_buttons[t.id] = icon_btn

		# An opaque backing panel behind the label: connector lines are drawn
		# behind the whole tree (z-order), but a Label has no background of
		# its own, so a line crossing behind it still shows through around
		# the glyphs and makes the text hard to read.
		var label_bg := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = Color(_BG_COLOR.r, _BG_COLOR.g, _BG_COLOR.b, 0.85)
		style.set_corner_radius_all(4)
		style.set_content_margin_all(3)
		label_bg.add_theme_stylebox_override("panel", style)
		container.add_child(label_bg)

		var label := Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(_NODE_SIZE.x, 0)
		label_bg.add_child(label)
		_labels[t.id] = label

	_edges.clear()
	for t in _tree.talents:
		for parent_id in _tree.prereq_nodes(t.prereq):
			_edges.append(Vector2i(t.id, parent_id))


func _reposition() -> void:
	var avail := _tree_area.size - _NODE_SIZE
	if avail.x < 0 or avail.y < 0:
		return
	for node_id in _containers:
		var top_left := Vector2(_col_frac[node_id] * avail.x, _row_frac[node_id] * avail.y)
		_containers[node_id].position = top_left
		# Edges connect at the icon's center, not the whole container's (which
		# includes the label below it).
		_centers[node_id] = top_left + Vector2(_NODE_SIZE.x * 0.5, _ICON_SIZE.y * 0.5)
	_tree_area.queue_redraw()


func _draw_edges() -> void:
	for edge in _edges:
		var child_id: int = edge.x
		var parent_id: int = edge.y
		if not (_centers.has(child_id) and _centers.has(parent_id)):
			continue
		var learned := _learned.has(child_id) and _learned.has(parent_id)
		var color := Color(0.6, 1.0, 0.6) if learned else Color(0.5, 0.5, 0.5)
		_tree_area.draw_line(_centers[child_id], _centers[parent_id], color, 3.0)


func force_first_pick() -> void:
	_forced = true
	_close_btn.visible = false
	_points_label.text = "Choose your first talent"
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# Called right before we send a FrozenStarlight InteractRequest, so the
# TalentSync that comes back in response is allowed to actually open the UI.
# Without this, ANY TalentSync — e.g. the server's routine broadcast when a
# level-up grants a new point — would pop the tree open uninvited.
func expect_open() -> void:
	_expect_open = true


func _on_talent_synced(points_available: int, learned: Array) -> void:
	_points_available = points_available
	_learned.clear()
	for id in learned:
		_learned[id] = true

	if _forced and not _learned.is_empty():
		_forced = false
		_close_btn.visible = true
		visible = false
		forced_pick_completed.emit()
		return

	_refresh()
	if not _expect_open:
		return
	_expect_open = false
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _refresh() -> void:
	_points_label.text = "Points available: %d" % _points_available
	_reposition()
	for t in _tree.talents:
		var btn: TextureButton = _buttons[t.id]
		var label: Label = _labels[t.id]
		var learned: bool = _learned.has(t.id)
		var available := _tree.requirement_met(t.prereq, _learned)
		var color := Color(0.6, 1.0, 0.6) if learned else (Color(1, 1, 1) if available else Color(0.5, 0.5, 0.5))
		label.text = t.name + (" ✓" if learned else "")
		label.modulate = color
		btn.disabled = learned or not available or _points_available <= 0
		btn.modulate = color
	_tree_area.queue_redraw()


func _on_talent_hovered(node_id: int) -> void:
	var t = _tree.by_id[node_id]
	_desc_label.text = "%s — %s" % [t.name, t.description]


func _on_talent_unhovered() -> void:
	_desc_label.text = ""


func _on_talent_pressed(node_id: int) -> void:
	var t = _tree.by_id[node_id]
	print("[talent-debug] pressed id=", node_id, " key=", t.key,
		" points_available=", _points_available, " disabled=", _buttons[node_id].disabled)
	Network.send(Protocol.pkt_learn_talent(node_id))


func _close() -> void:
	if _forced:
		return
	visible = false
	if GameState.player_net_id != -1:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
