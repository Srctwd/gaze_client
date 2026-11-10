extends CanvasLayer

# Read-only talent tree graph viewer for reviewing the tree's design (tiers,
# prereq structure, tag families) without needing a live server/character.
# Layout algorithm (tier rows, column-averaging from prereqs, isotonic
# collision resolution) is copied from gaze_client/ui/talent_tree_ui.gd —
# see TalentTreeData (talent_tree_data.gd) for parsing/prereq logic.

signal closed

# preload (not the bare TalentTreeData class_name) — the global class table
# is only populated after the editor has indexed the project once, so a
# fresh checkout run headless/via `load()` can't resolve the class_name yet.
const TalentTreeData := preload("res://world_editor/talent_tree_data.gd")

const _NODE_SIZE := Vector2(110, 120)
const _ICON_SIZE := Vector2(56, 56)
const _BG_COLOR  := Color(0.05, 0.05, 0.07, 1.0)

# First matching tag wins — order matters (e.g. a talent tagged both "weapon"
# and "thief" reads as a thief talent here since thief is checked first).
const _TAG_COLORS := {
	"void":    Color(0.62, 0.42, 0.82),
	"shadow":  Color(0.62, 0.42, 0.82),
	"thief":   Color(0.45, 0.68, 0.38),
	"warrior": Color(0.75, 0.30, 0.28),
	"fire":    Color(0.88, 0.45, 0.28),
	"frost":   Color(0.38, 0.72, 0.80),
	"arcane":  Color(0.48, 0.44, 0.82),
	"weapon":  Color(0.72, 0.66, 0.52),
	"magic":   Color(0.55, 0.50, 0.85),
}
const _DEFAULT_COLOR := Color(0.6, 0.6, 0.6)

# Obligatory (and) edges point from the prerequisite to the talent that
# requires it — the normal "this unlocks that" direction. Optional (or)
# edges are inverted — the talent with the choice points back at each
# either/or option — and dashed, so the distinction reads even at a glance
# without following arrowheads.
const _AND_EDGE_COLOR := Color(0.55, 0.55, 0.55)
const _OR_EDGE_COLOR  := Color(0.85, 0.65, 0.25)

var _tree := TalentTreeData.new()
var _loaded_path: String = ""

var _points_label: Label
var _tree_area: Control
var _icons: Dictionary = {}      # node_id -> TextureRect
var _labels: Dictionary = {}     # node_id -> Label
var _containers: Dictionary = {} # node_id -> VBoxContainer
var _row_frac: Dictionary = {}
var _col_frac: Dictionary = {}
var _centers: Dictionary = {}
var _edges: Array = []           # Array[{"child": int, "parent": int, "kind": "and"/"or"}]

var _pan_offset: Vector2 = Vector2.ZERO
var _dragging: bool = false
var _drag_last_mouse: Vector2 = Vector2.ZERO

var _dragging_node: int = -1        # -1 = none

# A press that ends near where it started (within _CLICK_DRAG_THRESHOLD) is a
# click (select/deselect); one that moves further was a pan/node-drag and
# shouldn't also change selection.
const _CLICK_DRAG_THRESHOLD := 6.0
var _press_pos: Vector2 = Vector2.ZERO
var _press_hit_node: int = -1
var _press_on_panel: bool = false

var _selected_node: int = -1
var _edit_panel: PanelContainer
var _edit_header: Label
var _edit_name: LineEdit
var _edit_tier: LineEdit
var _edit_tags: LineEdit
var _edit_requires: TextEdit
var _edit_bonus: TextEdit
var _edit_effects: LineEdit
var _edit_description: TextEdit
var _edit_status: Label
var _layout_status: Label


func open(path: String) -> void:
	if not _tree.load(path):
		return
	_loaded_path = path

	visible = true

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var bg := ColorRect.new()
	bg.color = _BG_COLOR
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	root.add_child(margin)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var hsplit := HBoxContainer.new()
	hsplit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hsplit.add_theme_constant_override("separation", 20)
	margin.add_child(hsplit)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hsplit.add_child(vbox)

	_edit_panel = _build_edit_panel()
	hsplit.add_child(_edit_panel)

	var title := Label.new()
	title.text = "Talent Tree — %d talents" % _tree.talents.size()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	vbox.add_child(title)

	_points_label = Label.new()
	_points_label.text = "Drag a node to move it · drag empty space to pan · solid arrow = required, dashed = either/or"
	_points_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_points_label.add_theme_font_size_override("font_size", 16)
	_points_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	vbox.add_child(_points_label)

	_build_tree_area()
	vbox.add_child(_tree_area)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	vbox.add_child(buttons)

	var save_layout_btn := Button.new()
	save_layout_btn.text = "Save Layout"
	save_layout_btn.custom_minimum_size = Vector2(160, 40)
	save_layout_btn.pressed.connect(func():
		_layout_status.text = "Layout saved." if _tree.save(_loaded_path) else "Failed to write " + _loaded_path
	)
	buttons.add_child(save_layout_btn)

	var reset_btn := Button.new()
	reset_btn.text = "Reset Layout"
	reset_btn.custom_minimum_size = Vector2(160, 40)
	reset_btn.pressed.connect(func():
		# Clears every talent's saved position (not just the ones touched
		# this session) — in memory only, until Save Layout is pressed.
		for t in _tree.talents:
			t.x = null
			t.y = null
		_populate_tree()
		_layout_status.text = "Layout reset (not saved yet)."
	)
	buttons.add_child(reset_btn)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.custom_minimum_size = Vector2(160, 40)
	close_btn.pressed.connect(func():
		visible = false
		closed.emit()
	)
	buttons.add_child(close_btn)

	_layout_status = Label.new()
	_layout_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_layout_status.add_theme_color_override("font_color", Color(1.0, 0.7, 0.4))
	vbox.add_child(_layout_status)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# A press starting on the edit panel itself (typing in a field,
			# pressing Save/Done) is its own controls' business — tracked so
			# the matching release doesn't run select/deselect below (that
			# used to fire on every such click, closing the panel out from
			# under whatever you were doing with it).
			_press_on_panel = _edit_panel.visible and _edit_panel.get_global_rect().has_point(event.position)
			if _press_on_panel:
				return
			_press_pos = event.position
			_press_hit_node = _node_at(event.position)
			_drag_last_mouse = event.position
			if _press_hit_node != -1:
				_dragging_node = _press_hit_node
			elif _tree_area.get_global_rect().has_point(event.position):
				_dragging = true
		else:
			# A press that never moved beyond the threshold is a click
			# (select/deselect) rather than a pan or node-drag. Always clear
			# drag state on release even if _press_on_panel — e.g. a node
			# dragged far enough to end up over the panel still needs to
			# stop dragging, it just doesn't also change selection.
			if not _press_on_panel and event.position.distance_to(_press_pos) < _CLICK_DRAG_THRESHOLD:
				if _press_hit_node != -1:
					_select_node(_press_hit_node)
				else:
					_deselect()
			_dragging = false
			_dragging_node = -1
			_press_hit_node = -1
			_press_on_panel = false
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _dragging_node != -1:
			# Mutates _col_frac/_row_frac directly (rather than a separate
			# pixel offset added on top) and mirrors it onto the talent's
			# x/y right away, so "Save Layout" always has the live position
			# and a saved layout is resolution-independent for gaze_client.
			var avail: Vector2 = _tree_area.size - _NODE_SIZE
			if avail.x > 0.0 and avail.y > 0.0:
				var frac_delta: Vector2 = (motion.position - _drag_last_mouse) / avail
				var new_x: float = clampf(_col_frac[_dragging_node] + frac_delta.x, 0.0, 1.0)
				var new_y: float = clampf(_row_frac[_dragging_node] + frac_delta.y, 0.0, 1.0)
				_col_frac[_dragging_node] = new_x
				_row_frac[_dragging_node] = new_y
				var t = _tree.by_id[_dragging_node]
				t.x = new_x
				t.y = new_y
			_drag_last_mouse = motion.position
			_reposition()
		elif _dragging:
			_pan_offset += motion.position - _drag_last_mouse
			_drag_last_mouse = motion.position
			_reposition()


func _select_node(node_id: int) -> void:
	_selected_node = node_id
	_populate_edit_panel(node_id)
	_edit_panel.visible = true
	if _tree_area != null:
		_tree_area.queue_redraw()


func _deselect() -> void:
	if _selected_node == -1:
		return
	_selected_node = -1
	_edit_panel.visible = false
	if _tree_area != null:
		_tree_area.queue_redraw()


# Hit-tests a node's container rect (icon + label together), not just the
# icon, so grabbing anywhere on a node's footprint starts a drag. Returns -1
# if the point isn't over any node.
func _node_at(global_pos: Vector2) -> int:
	for node_id in _containers:
		if (_containers[node_id] as Control).get_global_rect().has_point(global_pos):
			return node_id
	return -1


func _tag_color(tags: Array) -> Color:
	for tag in _TAG_COLORS:
		if tag in tags:
			return _TAG_COLORS[tag]
	return _DEFAULT_COLOR


func _make_icon(color: Color) -> Texture2D:
	var size := 56
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size, size) * 0.5
	var radius := size * 0.5 - 2.0
	for y in size:
		for x in size:
			var d := Vector2(x, y).distance_to(center)
			if d <= radius:
				img.set_pixel(x, y, color if d <= radius - 3.0 else color.lightened(0.4))
	return ImageTexture.create_from_image(img)


func _build_tree_area() -> void:
	_tree_area = Control.new()
	_tree_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree_area.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_tree_area.clip_contents = true
	_tree_area.draw.connect(_draw_edges)
	_tree_area.resized.connect(_reposition)
	_populate_tree()


# (Re)builds every node/edge from _tree.talents — callable again after an
# edit changes a talent's tier or requires, since either can change the
# layout. Wipes _tree_area's children and the per-node dictionaries first.
func _populate_tree() -> void:
	for child in _tree_area.get_children():
		_tree_area.remove_child(child)
		child.free()
	_icons.clear()
	_labels.clear()
	_containers.clear()
	_row_frac.clear()
	_col_frac.clear()
	_centers.clear()

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
	# diverge the way the dependency graph actually branches. See
	# gaze_client/ui/talent_tree_ui.gd for the original write-up of this.
	for tier_i in tier_keys.size():
		var tier = tier_keys[tier_i]
		var row: Array = tiers[tier]
		var desired: Dictionary = {}

		for t in row:
			var parent_ids := _tree.prereq_nodes(t.prereq)
			if tier_i == 0 or parent_ids.is_empty():
				desired[t.id] = -1.0
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

		var min_gap := 1.0 / maxf(row.size() + 1, 8.0)
		_resolve_columns(sorted_row, desired, min_gap)

		for t in row:
			_row_frac[t.id] = 1.0 if max_tier == 0 else 1.0 - float(t.tier) / max_tier
			# A saved/dragged position overrides the auto layout for this
			# node — applied now (not before) so later tiers that average
			# from this node's column converge toward where it actually
			# ended up, same as they would for an un-overridden node.
			if t.x != null and t.y != null:
				_col_frac[t.id] = t.x
				_row_frac[t.id] = t.y

	for t in _tree.talents:
		var container := VBoxContainer.new()
		container.alignment = BoxContainer.ALIGNMENT_CENTER
		container.size = _NODE_SIZE
		container.add_theme_constant_override("separation", 6)
		_tree_area.add_child(container)
		_containers[t.id] = container

		var color := _tag_color(t.tags)
		var icon := TextureRect.new()
		icon.texture = _make_icon(color)
		icon.custom_minimum_size = _ICON_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		icon.mouse_filter = Control.MOUSE_FILTER_STOP
		container.add_child(icon)
		_icons[t.id] = icon

		var label_bg := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = Color(_BG_COLOR.r, _BG_COLOR.g, _BG_COLOR.b, 0.85)
		style.set_corner_radius_all(4)
		style.set_content_margin_all(3)
		label_bg.add_theme_stylebox_override("panel", style)
		container.add_child(label_bg)

		var label := Label.new()
		label.text = t.name
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(_NODE_SIZE.x, 0)
		label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
		label_bg.add_child(label)
		_labels[t.id] = label

	_edges.clear()
	for t in _tree.talents:
		for e in _tree.edges_with_kind(t.prereq):
			_edges.append({ "child": t.id, "parent": e.node, "kind": e.kind })

	call_deferred("_reposition")


# Isotonic regression (pool-adjacent-violators): places sorted_row's columns
# as close as possible to `desired` while enforcing at least min_gap between
# neighbors, without letting a tight cluster's drift cascade past column 1.0.
func _resolve_columns(sorted_row: Array, desired: Dictionary, min_gap: float) -> void:
	var n := sorted_row.size()
	var group_val: Array = []
	var group_size: Array = []
	var group_members: Array = []
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


func _reposition() -> void:
	if _tree_area == null:
		return
	var avail := _tree_area.size - _NODE_SIZE
	if avail.x < 0 or avail.y < 0:
		return
	for node_id in _containers:
		var top_left := Vector2(_col_frac[node_id] * avail.x, _row_frac[node_id] * avail.y) + _pan_offset
		_containers[node_id].position = top_left
		_centers[node_id] = top_left + Vector2(_NODE_SIZE.x * 0.5, _ICON_SIZE.y * 0.5)
	_tree_area.queue_redraw()


func _draw_edges() -> void:
	for edge in _edges:
		var child_id: int = edge.child
		var parent_id: int = edge.parent
		if not (_centers.has(child_id) and _centers.has(parent_id)):
			continue
		if edge.kind == "and":
			# Obligatory — normal arrow: the prerequisite points to the
			# talent that has it as a requirement.
			_draw_arrow(_centers[parent_id], _centers[child_id], _AND_EDGE_COLOR, false)
		else:
			# Optional (or) — inverted: the talent with the choice points
			# back at each either/or option instead.
			_draw_arrow(_centers[child_id], _centers[parent_id], _OR_EDGE_COLOR, true)

	if _selected_node != -1 and _centers.has(_selected_node):
		_tree_area.draw_arc(_centers[_selected_node], _ICON_SIZE.x * 0.5 + 6.0, 0, TAU, 32, Color(1.0, 0.85, 0.3), 3.0)


# Draws a line from `from` to `to`, stopping short of each end so the
# arrowhead sits just outside the icon circle instead of under it, plus a
# small filled triangle arrowhead at `to`. `dashed` distinguishes optional
# (or) edges from obligatory (and) ones at a glance, on top of direction.
func _draw_arrow(from: Vector2, to: Vector2, color: Color, dashed: bool) -> void:
	var delta := to - from
	if delta.length() < 0.001:
		return
	var dir := delta.normalized()
	var r := _ICON_SIZE.x * 0.5 + 2.0
	var start := from + dir * r
	var end := to - dir * r

	if dashed:
		_draw_dashed_line(start, end, color, 2.5, 8.0, 5.0)
	else:
		_tree_area.draw_line(start, end, color, 2.5)

	var head_len := 11.0
	var head_w := 6.0
	var perp := Vector2(-dir.y, dir.x)
	var tip  := end
	var back := end - dir * head_len
	_tree_area.draw_colored_polygon(
		PackedVector2Array([tip, back + perp * head_w, back - perp * head_w]), color)


func _draw_dashed_line(from: Vector2, to: Vector2, color: Color, width: float, dash: float, gap: float) -> void:
	var total := from.distance_to(to)
	if total < 0.001:
		return
	var dir := (to - from) / total
	var pos := 0.0
	while pos < total:
		var seg_end := minf(pos + dash, total)
		_tree_area.draw_line(from + dir * pos, from + dir * seg_end, color, width)
		pos += dash + gap


# Fixed-width side panel, hidden until a node is selected (see _select_node).
# Requires is edited as raw JSON text (same shape as the file's "requires"
# field — null / "Key" / {"and":[...]} / {"or":[...]} / {"sum":{...}} /
# {"stat":{...}}) rather than a structured AND/OR builder, and bonus as one
# "stat op value" line per entry — both far simpler than building dedicated
# widgets for a nested/variadic shape, and this is a design tool for
# hand-editing data that's already hand-edited directly in the JSON file.
func _build_edit_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(340, 0)
	panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.13, 0.95)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	_edit_header = Label.new()
	_edit_header.add_theme_font_size_override("font_size", 18)
	_edit_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_edit_header)

	_edit_name = _edit_field(vbox, "Name")
	_edit_tier = _edit_field(vbox, "Tier")
	_edit_tags = _edit_field(vbox, "Tags (comma-separated)")

	var requires_caption := Label.new()
	requires_caption.text = "Requires (JSON — null, a key, or {and/or/sum/stat})"
	vbox.add_child(requires_caption)
	_edit_requires = TextEdit.new()
	_edit_requires.custom_minimum_size = Vector2(0, 90)
	_edit_requires.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	vbox.add_child(_edit_requires)

	var bonus_caption := Label.new()
	bonus_caption.text = "Bonus (one 'stat op value' per line)"
	vbox.add_child(bonus_caption)
	_edit_bonus = TextEdit.new()
	_edit_bonus.custom_minimum_size = Vector2(0, 60)
	_edit_bonus.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	vbox.add_child(_edit_bonus)

	_edit_effects = _edit_field(vbox, "Effects (comma-separated)")

	var description_caption := Label.new()
	description_caption.text = "Description"
	vbox.add_child(description_caption)
	_edit_description = TextEdit.new()
	_edit_description.custom_minimum_size = Vector2(0, 70)
	_edit_description.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	vbox.add_child(_edit_description)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	vbox.add_child(buttons)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.custom_minimum_size = Vector2(0, 36)
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_save_edit)
	buttons.add_child(save_btn)

	var deselect_btn := Button.new()
	deselect_btn.text = "Done"
	deselect_btn.custom_minimum_size = Vector2(0, 36)
	deselect_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deselect_btn.pressed.connect(_deselect)
	buttons.add_child(deselect_btn)

	_edit_status = Label.new()
	_edit_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_edit_status.add_theme_color_override("font_color", Color(1.0, 0.7, 0.4))
	vbox.add_child(_edit_status)

	return panel


# Small helper: a caption Label above a LineEdit, both added to `parent`.
# Returns the LineEdit so the caller can keep a reference to it.
func _edit_field(parent: VBoxContainer, caption: String) -> LineEdit:
	var label := Label.new()
	label.text = caption
	parent.add_child(label)
	var edit := LineEdit.new()
	parent.add_child(edit)
	return edit


func _populate_edit_panel(node_id: int) -> void:
	var t = _tree.by_id[node_id]
	_edit_header.text = "%s  (id %d, key %s)" % [t.name, t.id, t.key]
	_edit_name.text = t.name
	_edit_tier.text = str(t.tier)
	_edit_tags.text = ", ".join(t.tags)
	_edit_requires.text = "null" if t.requires_raw == null else JSON.stringify(t.requires_raw, "  ")
	var bonus_lines: Array = []
	for b in t.bonus:
		bonus_lines.append("%s %s %s" % [b.stat, b.op, str(b.value)])
	_edit_bonus.text = "\n".join(bonus_lines)
	_edit_effects.text = ", ".join(t.effects)
	_edit_description.text = t.description
	_edit_status.text = ""


func _save_edit() -> void:
	if _selected_node == -1:
		return
	var t = _tree.by_id[_selected_node]

	var new_name := _edit_name.text.strip_edges()
	if new_name.is_empty():
		_edit_status.text = "Name can't be empty."
		return

	if not _edit_tier.text.is_valid_int():
		_edit_status.text = "Tier must be a whole number."
		return

	var new_tags: Array = []
	for part in _edit_tags.text.split(","):
		var s := part.strip_edges()
		if not s.is_empty():
			new_tags.append(s)

	var new_effects: Array = []
	for part in _edit_effects.text.split(","):
		var s := part.strip_edges()
		if not s.is_empty():
			new_effects.append(s)

	var new_bonus: Array = []
	for line in _edit_bonus.text.split("\n"):
		var s := line.strip_edges()
		if s.is_empty():
			continue
		var parts := s.split(" ", false)
		if parts.size() != 3 or not (parts[1] in ["+", "increased"]) or not parts[2].is_valid_float():
			_edit_status.text = "Bad bonus line: '%s' — expected 'stat op value' with op '+' or 'increased' (percent), e.g. 'physical_damage + 5' or 'fire_damage increased 3'" % s
			return
		new_bonus.append({"stat": parts[0], "op": parts[1], "value": float(parts[2])})

	var requires_text := _edit_requires.text.strip_edges()
	var new_requires_raw = null
	if not (requires_text.is_empty() or requires_text == "null"):
		var json := JSON.new()
		if json.parse(requires_text) != OK:
			_edit_status.text = "Requires isn't valid JSON (line %d: %s)" % [json.get_error_line(), json.get_error_message()]
			return
		new_requires_raw = json.get_data()
	var new_prereq := _tree.parse_requires(new_requires_raw)

	t.name         = new_name
	t.tier         = int(_edit_tier.text)
	t.tags         = new_tags
	t.effects      = new_effects
	t.bonus        = new_bonus
	t.requires_raw = new_requires_raw
	t.prereq       = new_prereq
	t.description  = _edit_description.text

	if not _tree.save(_loaded_path):
		_edit_status.text = "Applied in memory, but failed to write " + _loaded_path
		return

	_populate_tree()   # tier/requires may have changed — rebuild layout & edges
	_select_node(_selected_node)  # repopulates the panel from the just-saved data, which clears the status line
	_edit_status.text = "Saved."
