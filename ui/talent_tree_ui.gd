extends CanvasLayer

# Renders the tree built by TalentTree (game/talent_tree.gd) and drives it
# off Network's TalentSync/LearnTalentRequest traffic. No parsing or
# requirement-evaluation logic lives here — see talent_tree.gd for that.
#
# Fullscreen, opaque, starry backdrop. Tier 0 sits at the bottom of the
# tree, higher tiers stack upward. The tree is laid out on a fixed-spacing
# canvas that can be much bigger than the screen — drag to pan, scroll to
# zoom — so a wide tier never squeezes its nodes on top of each other.

# Emitted by selection mode (character creation, see start_selection()) — a
# purely local pick, no network traffic involved since there's no character/
# session to talk to yet.
signal talent_selected(node_id: int)
signal selection_cancelled

const _NODE_SIZE  := Vector2(100, 110)  # footprint: icon + name label stacked under it
const _ICON_SIZE  := Vector2(64, 64)
const _BG_COLOR   := Color(0.0, 0.0, 0.0, 1.0)
const _STAR_COUNT := 220
const _ARROW_LEN   := 22.0
const _ARROW_WIDTH := 16.0

# Canvas spacing at zoom 1: distance between neighboring columns' node
# centers, and between tiers.
const _COL_SPACING := 140.0
const _ROW_SPACING := 190.0
const _MIN_ZOOM := 0.3
const _MAX_ZOOM := 1.5
const _ZOOM_STEP := 1.1
# Opening the tree zooms out to fit, but never below this — any smaller and
# names stop being readable; pan the rest into view instead.
const _FIT_MIN_ZOOM := 0.8
const _HINT := "Drag to pan, scroll to zoom."

# A talent's icon is res://assets/talent_icons/<key>.png (e.g. Flames ->
# talent_icons/Flames.png), derived from the talent's own key — drop a
# matching PNG in place and it's picked up automatically, no lookup table
# to maintain.
const _ICON_DIR := "res://assets/talent_icons/"

var _tree := TalentTree.new()

var _starfield: Control
var _stars: Array = []  # Array[{"pos": Vector2 (0..1), "radius": float, "brightness": float}]

const _TITLE_DEFAULT   := "Talent Tree"
const _TITLE_SELECTION := "Choose your first talent"

var _title_label: Label
var _points_label: Label
var _desc_label: Label
var _tree_area: Control
var _canvas: Control  # child of _tree_area holding every node; panned/zoomed via its position/scale
var _grid_cols: int = 1  # widest tier's node count — the canvas is this many columns wide
var _max_tier: int = 0
var _buttons: Dictionary = {}   # node_id -> TextureButton (the clickable icon itself)
var _labels: Dictionary = {}    # node_id -> Label (name, shown under the icon)
var _containers: Dictionary = {}  # node_id -> VBoxContainer (icon + label, positioned as one unit)
var _placeholder_icon: Texture2D
var _row_frac: Dictionary = {}  # node_id -> float (0 = top, 1 = bottom)
var _col_frac: Dictionary = {}  # node_id -> float (0..1)
var _centers: Dictionary = {}   # node_id -> Vector2 (local to _canvas)
var _edges: Array = []          # Array[Dictionary] of {child, parent, optional}
var _pos_override: Dictionary = {}  # node_id -> Vector2 canvas top-left, set while selection mode compacts tier 0
var _needs_fit: bool = false    # _fit_view() pending until _tree_area has a real size

var _points_available: int = 0
var _learned: Dictionary = {}  # node_id -> true
var _close_btn: Button
var _expect_open: bool = false     # true after we explicitly requested a sync (FrozenStarlight interact)
var _selection_mode: bool = false  # true while picking a starting talent during character creation (no network involved)

# Click-drag panning of the tree layout within _tree_area. Tracked at the
# _input() level (not a Control's gui_input) so dragging keeps working even
# while the cursor crosses over a talent icon mid-drag — a child Button
# would otherwise swallow the motion events before _tree_area ever saw them.
# The pan itself is just _canvas.position.
var _dragging: bool = false
var _drag_last_mouse: Vector2 = Vector2.ZERO


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

	_title_label = Label.new()
	_title_label.text = _TITLE_DEFAULT
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 32)
	vbox.add_child(_title_label)

	_points_label = Label.new()
	_points_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_points_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(_points_label)

	_build_tree_area()
	vbox.add_child(_tree_area)

	_desc_label = Label.new()
	_desc_label.text = _HINT
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


# Reads mouse state directly rather than a Control's gui_input, and never
# calls set_input_as_handled() — talent icon buttons still get every event
# normally afterward, this just also watches the same events for panning.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _tree_area.get_global_rect().has_point(event.position):
			_dragging = true
			_drag_last_mouse = event.position
		else:
			_dragging = false
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] \
			and _tree_area.get_global_rect().has_point(event.position):
		var factor := _ZOOM_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / _ZOOM_STEP
		_zoom_at(event.position - _tree_area.global_position, factor)
	elif event is InputEventMouseMotion and _dragging:
		_canvas.position += event.position - _drag_last_mouse
		_drag_last_mouse = event.position


# Zooms keeping the canvas point under `at` (local to _tree_area) fixed.
func _zoom_at(at: Vector2, factor: float) -> void:
	var zoom := clampf(_canvas.scale.x * factor, _MIN_ZOOM, _MAX_ZOOM)
	var canvas_pt := (at - _canvas.position) / _canvas.scale.x
	_canvas.scale = Vector2.ONE * zoom
	_canvas.position = at - canvas_pt * zoom


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
	# Panning can push nodes outside this rect — clip them instead of letting
	# them draw over the title/points label above or description/close button below.
	_tree_area.clip_contents = true
	_tree_area.resized.connect(func(): if _needs_fit: _fit_view())

	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_edges)
	_tree_area.add_child(_canvas)

	var tiers: Dictionary = {}  # tier -> Array of talent dicts, in file order
	var max_tier := 0
	for t in _tree.talents:
		if not tiers.has(t.tier):
			tiers[t.tier] = []
		tiers[t.tier].append(t)
		max_tier = maxi(max_tier, t.tier)

	var tier_keys: Array = tiers.keys()
	tier_keys.sort()
	_max_tier = max_tier
	_grid_cols = 1
	for tier in tier_keys:
		_grid_cols = maxi(_grid_cols, tiers[tier].size())

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

		# One canvas column (_COL_SPACING px) between same-tier siblings —
		# the canvas is as many columns wide as the widest tier, so every
		# row fits without overlapping.
		var min_gap := 1.0 / _grid_cols
		_resolve_columns(sorted_row, desired, min_gap)

		# _resolve_columns keeps spacing but not bounds — slide the whole row
		# back inside the canvas if a cluster drifted past either edge.
		var lo := 0.5 / _grid_cols
		var first: float = _col_frac[sorted_row[0].id]
		var last: float = _col_frac[sorted_row[-1].id]
		var shift := maxf(lo - first, 0.0) + minf(1.0 - lo - last, 0.0)
		for t in sorted_row:
			_col_frac[t.id] += shift

		for t in row:
			# tier 0 at the bottom (frac 1.0), highest tier at the top (frac 0.0)
			_row_frac[t.id] = 1.0 if max_tier == 0 else 1.0 - float(t.tier) / max_tier
			# A position saved from the world_editor talent tree tool
			# overrides the auto layout — applied now (not before) so later
			# tiers that average from this node's column converge toward
			# where it actually ended up, same as an un-overridden node.
			if t.x != null and t.y != null:
				_col_frac[t.id] = t.x
				_row_frac[t.id] = t.y

	_placeholder_icon = _make_placeholder_icon()

	for t in _tree.talents:
		var container := VBoxContainer.new()
		container.alignment = BoxContainer.ALIGNMENT_CENTER
		container.size = _NODE_SIZE
		container.add_theme_constant_override("separation", 6)
		_canvas.add_child(container)
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
		var edges: Dictionary = _tree.prereq_edges(t.prereq)  # parent_id -> optional
		for parent_id in edges:
			_edges.append({"child": t.id, "parent": parent_id, "optional": edges[parent_id]})

	_canvas.size = Vector2(_grid_cols * _COL_SPACING, _max_tier * _ROW_SPACING + _NODE_SIZE.y)
	_layout()


# Places sorted_row's columns as close as possible to `desired` while
# enforcing at least min_gap between neighbors — solved as isotonic
# regression (pool-adjacent-violators) rather than a one-directional greedy
# sweep. This is the placement that minimizes total displacement from each
# node's own desired column, and — unlike greedy, which only ever pushes
# later siblings further right — can't cascade a tight cluster's drift past
# column 1.0 just because its neighbors also wanted to be nearby.
func _resolve_columns(sorted_row: Array, desired: Dictionary, min_gap: float) -> void:
	var n := sorted_row.size()
	var group_val: Array = []   # pooled value once "de-trended" by i*min_gap
	var group_size: Array = []
	var group_members: Array = []  # Array[Array[int]] node ids, in column order
	for i in n:
		group_val.append(desired[sorted_row[i].id] - i * min_gap)
		group_size.append(1)
		group_members.append([sorted_row[i].id])

	var gi := 0
	while gi < group_val.size() - 1:
		if group_val[gi] > group_val[gi + 1]:
			var total: int = group_size[gi] + group_size[gi + 1]
			group_val[gi] = (group_val[gi] * group_size[gi] + group_val[gi + 1] * group_size[gi + 1]) / total
			group_size[gi] = total
			group_members[gi] += group_members[gi + 1]
			group_val.remove_at(gi + 1)
			group_size.remove_at(gi + 1)
			group_members.remove_at(gi + 1)
			gi = maxi(gi - 1, 0)
		else:
			gi += 1

	var idx := 0
	for g in group_val.size():
		for node_id in group_members[g]:
			_col_frac[node_id] = group_val[g] + idx * min_gap
			idx += 1


# Places every node on the canvas. Canvas coordinates don't depend on the
# screen size — fitting to the screen is _fit_view()'s job (zoom + pan).
func _layout() -> void:
	for node_id in _containers:
		var top_left: Vector2 = _pos_override.get(node_id, Vector2(
			_col_frac[node_id] * _grid_cols * _COL_SPACING - _NODE_SIZE.x * 0.5,
			_row_frac[node_id] * _max_tier * _ROW_SPACING))
		_containers[node_id].position = top_left
		# Edges connect at the icon's center, not the whole container's (which
		# includes the label below it).
		_centers[node_id] = top_left + Vector2(_NODE_SIZE.x * 0.5, _ICON_SIZE.y * 0.5)
	_canvas.queue_redraw()


# Zooms out to fit the visible nodes (down to _FIT_MIN_ZOOM) and centers
# them. If the tree is still taller than the view, tier 0 is kept on screen
# at the bottom — that's where every path starts.
func _fit_view() -> void:
	var area := _tree_area.size
	if area.x <= 0.0 or area.y <= 0.0:
		_needs_fit = true
		return
	_needs_fit = false

	var bounds := Rect2()
	var any := false
	for node_id in _containers:
		if not _containers[node_id].visible:
			continue
		var r := Rect2(_containers[node_id].position, _NODE_SIZE)
		bounds = r if not any else bounds.merge(r)
		any = true
	if not any:
		return
	bounds = bounds.grow(20.0)

	var zoom := clampf(minf(area.x / bounds.size.x, area.y / bounds.size.y), _FIT_MIN_ZOOM, 1.0)
	var pos := (area - bounds.size * zoom) * 0.5 - bounds.position * zoom
	if bounds.size.y * zoom > area.y:
		pos.y = area.y - bounds.end.y * zoom
	_canvas.scale = Vector2.ONE * zoom
	_canvas.position = pos


func _draw_edges() -> void:
	for edge in _edges:
		var child_id: int = edge.child
		var parent_id: int = edge.parent
		if not (_centers.has(child_id) and _centers.has(parent_id)):
			continue
		if not (_containers[child_id].visible and _containers[parent_id].visible):
			continue
		var learned := _learned.has(child_id) and _learned.has(parent_id)
		var color := Color(0.6, 1.0, 0.6) if learned else Color(0.5, 0.5, 0.5)

		# Mandatory prereqs arrow forward, prereq -> dependent ("this unlocks
		# that"); optional prereqs arrow backward, dependent -> prereq ("this
		# can also use that") — matches how the tree is meant to read.
		var from: Vector2 = _centers[child_id] if edge.optional else _centers[parent_id]
		var to: Vector2 = _centers[parent_id] if edge.optional else _centers[child_id]
		_canvas.draw_line(from, to, color, 3.0)

		var direction := (to - from).normalized()
		if direction != Vector2.ZERO:
			var tip := to - direction * (_ICON_SIZE.y * 0.5 - 6.0)
			_draw_arrowhead(tip, direction, color)


func _draw_arrowhead(tip: Vector2, direction: Vector2, color: Color) -> void:
	var back := tip - direction * _ARROW_LEN
	var perp := direction.orthogonal() * (_ARROW_WIDTH * 0.5)
	_canvas.draw_colored_polygon([tip, back + perp, back - perp], color)


# Called right before we send a FrozenStarlight InteractRequest, so the
# TalentSync that comes back in response is allowed to actually open the UI.
# Without this, ANY TalentSync — e.g. the server's routine broadcast when a
# level-up grants a new point — would pop the tree open uninvited.
func expect_open() -> void:
	_expect_open = true


# Character creation: let the player pick their starting talent before the
# character even exists server-side, so its node_id can ride along on the
# creation request instead of a separate post-creation learn-talent step.
# No character/session exists yet, so this never touches Network.
#
# Only the first tier is offered — talents.json's tier field is 0-indexed, so
# that's tier == 0 (a few tier-1 entries, e.g. "Lightning Knowledge", also
# happen to have no prereq, so filtering on empty `_learned`/requirement_met
# alone would leak them in too; tier is the only reliable filter here).
const _STARTING_TIER := 0

func start_selection() -> void:
	_selection_mode = true
	_points_available = 1
	_learned.clear()
	_close_btn.text = "Back"
	_title_label.text = _TITLE_SELECTION
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh()
	_set_tier_visibility(_STARTING_TIER)
	_fit_view.call_deferred()


# Shows one tier only, packed into a single compact row — in the full tree
# its nodes are spread under their subtrees, which would leave big empty
# gaps with every other tier hidden.
func _set_tier_visibility(only_tier: int) -> void:
	_pos_override.clear()
	var shown: Array = []
	for t in _tree.talents:
		_containers[t.id].visible = t.tier == only_tier
		if t.tier == only_tier:
			shown.append(t)
	shown.sort_custom(func(a, b): return _col_frac[a.id] < _col_frac[b.id])
	for i in shown.size():
		_pos_override[shown[i].id] = Vector2(i * _COL_SPACING, 0.0)
	_layout()


func _show_all_tiers() -> void:
	_title_label.text = _TITLE_DEFAULT
	for t in _tree.talents:
		_containers[t.id].visible = true
	_pos_override.clear()
	_layout()


func _on_talent_synced(points_available: int, learned: Array) -> void:
	_points_available = points_available
	_learned.clear()
	for id in learned:
		_learned[id] = true

	_refresh()

	# Only ever opens when explicitly requested (the FrozenStarlight menu
	# item) — the starting talent is now picked before the character even
	# exists (see start_selection()), so there's no "first login" case left
	# that should pop this open on its own, even if learned still came back
	# empty for some reason.
	if not _expect_open:
		return
	_expect_open = false
	if not visible:
		_fit_view.call_deferred()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _refresh() -> void:
	_points_label.text = "Points available: %d" % _points_available
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
	_canvas.queue_redraw()


func _on_talent_hovered(node_id: int) -> void:
	var t = _tree.by_id[node_id]
	_desc_label.text = "%s — %s" % [t.name, t.description]


func _on_talent_unhovered() -> void:
	_desc_label.text = _HINT


func _on_talent_pressed(node_id: int) -> void:
	var t = _tree.by_id[node_id]
	if _selection_mode:
		_selection_mode = false
		_close_btn.text = "Close"
		_show_all_tiers()
		visible = false
		talent_selected.emit(node_id)
		return
	print("[talent-debug] pressed id=", node_id, " key=", t.key,
		" points_available=", _points_available, " disabled=", _buttons[node_id].disabled)
	Network.send(Protocol.pkt_learn_talent(node_id))


func _close() -> void:
	visible = false
	if _selection_mode:
		_selection_mode = false
		_close_btn.text = "Close"
		_show_all_tiers()
		selection_cancelled.emit()
		return
	if GameState.player_net_id != -1:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
