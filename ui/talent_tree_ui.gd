extends CanvasLayer

# Talent tree data is loaded from res://talents at runtime — see that file's
# header comment for the column format. This mirrors the parser in
# stone_gaze/src/systems/talents.cpp (split_fields + RequiresParser).
#
# IMPORTANT: the numeric node id sent over the wire (InteractRequest/TalentSync/
# LearnTalentRequest) is NOT the row order in the data file — it's the
# TalentId enum declaration order on the server (kIdNames in talents.cpp).
# _ID_NAMES below must be kept in sync with that array whenever a talent is
# added there.
const _ID_NAMES := [
	"ArcaneKnowledge",
	"FireKnowledge",
	"FrostKnowledge",
	"Flames",
	"FireBolt",
	"ArcaneBurst",
	"BasicTraining",
]

const _TALENTS_PATH := "res://talents"

const _COL_STEP  := 130.0
const _ROW_STEP  := 110.0
const _NODE_SIZE := Vector2(110, 50)
const _PADDING   := Vector2(20, 20)

# Each entry: { id, name, tier, tags: Array[String], prereq: Requirement dict, description, col }
# Requirement dict shapes:
#   {"type": "none"}
#   {"type": "has", "node": int}
#   {"type": "and"/"or", "children": Array[Requirement]}
#   {"type": "sum", "group": String, "threshold": int}
var _talents: Array = []
var _talent_by_id: Dictionary = {}  # node_id -> talent dict

var _points_label: Label
var _tree_area: Control
var _buttons: Dictionary = {}  # node_id -> Button
var _centers: Dictionary = {}  # node_id -> Vector2 (local to _tree_area)
var _edges: Array = []          # Array[Vector2i] of (child_id, parent_id)

var _points_available: int = 0
var _learned: Dictionary = {}  # node_id -> true


func _ready() -> void:
	_load_talents(_TALENTS_PATH)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Talent Tree"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_points_label = Label.new()
	_points_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_points_label)

	vbox.add_child(HSeparator.new())

	_build_tree_area()
	vbox.add_child(_tree_area)

	vbox.add_child(HSeparator.new())

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(_close)
	vbox.add_child(close_btn)

	visible = false
	Network.talent_synced.connect(_on_talent_synced)


# ── Data file loading ───────────────────────────────────────────────────────

func _load_talents(path: String) -> void:
	_talents.clear()
	_talent_by_id.clear()

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("talent_tree_ui: failed to open " + path)
		return

	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty() or line.begins_with("#"):
			continue
		var fields := _split_fields(line)
		if fields.size() < 6:
			continue

		var id_name: String = fields[0]
		var node_id := _ID_NAMES.find(id_name)
		if node_id == -1:
			push_error("talent_tree_ui: unknown talent id '" + id_name + "' — add it to _ID_NAMES")
			continue

		var tags: Array = [] if fields[3] == "-" else fields[3].split(",")
		var talent := {
			"id": node_id,
			"name": fields[1],
			"tier": int(fields[2]),
			"tags": tags,
			"prereq": _RequiresParser.new(fields[4], _ID_NAMES).parse(),
			"description": fields[5],
		}
		_talents.append(talent)
		_talent_by_id[node_id] = talent


func _split_fields(line: String) -> Array:
	var fields: Array = []
	var i := 0
	var n := line.length()
	while i < n:
		while i < n and line[i] == " ":
			i += 1
		if i >= n:
			break
		if line[i] == "\"":
			var end := line.find("\"", i + 1)
			if end == -1:
				end = n
			fields.append(line.substr(i + 1, end - i - 1))
			i = end + 1
		else:
			var start := i
			while i < n and line[i] != " ":
				i += 1
			fields.append(line.substr(start, i - start))
	return fields


# Recursive-descent parser for the "requires" expression column, mirroring
# stone_gaze's RequiresParser (and/or/parens/sum(group,N)).
class _RequiresParser:
	var s: String
	var pos: int = 0
	var id_names: Array

	func _init(expr: String, names: Array) -> void:
		s = expr
		id_names = names

	func parse() -> Dictionary:
		if s.is_empty() or s == "-":
			return { "type": "none" }
		return _parse_or()

	func _peek() -> String:
		return s[pos] if pos < s.length() else ""

	func _parse_or() -> Dictionary:
		var children: Array = [_parse_and()]
		while _peek() == "|":
			pos += 1
			children.append(_parse_and())
		return children[0] if children.size() == 1 else { "type": "or", "children": children }

	func _parse_and() -> Dictionary:
		var children: Array = [_parse_atom()]
		while _peek() == "&":
			pos += 1
			children.append(_parse_atom())
		return children[0] if children.size() == 1 else { "type": "and", "children": children }

	func _parse_atom() -> Dictionary:
		if _peek() == "(":
			pos += 1
			var r := _parse_or()
			if _peek() == ")":
				pos += 1
			return r

		var start := pos
		while pos < s.length() and not (s[pos] in ["&", "|", "(", ")"]):
			pos += 1
		var token := s.substr(start, pos - start)

		if token.begins_with("sum(") and token.ends_with(")"):
			var inner := token.substr(4, token.length() - 5)
			var comma := inner.rfind(",")
			var group := inner.substr(0, comma)
			var threshold := int(inner.substr(comma + 1))
			return { "type": "sum", "group": group, "threshold": threshold }

		var node_id := id_names.find(token)
		if node_id == -1:
			push_error("talent_tree_ui: unknown talent id '" + token + "' in requires expression")
			return { "type": "none" }
		return { "type": "has", "node": node_id }


# ── Layout ──────────────────────────────────────────────────────────────────

func _build_tree_area() -> void:
	var tiers: Dictionary = {}  # tier -> Array of talent dicts, in file order
	var max_tier := 0
	for t in _talents:
		if not tiers.has(t.tier):
			tiers[t.tier] = []
		tiers[t.tier].append(t)
		max_tier = maxi(max_tier, t.tier)

	var max_row_count := 1
	for tier in tiers:
		max_row_count = maxi(max_row_count, tiers[tier].size())

	var cols: Dictionary = {}  # node_id -> float col
	for tier in tiers:
		var row: Array = tiers[tier]
		var offset := (max_row_count - row.size()) / 2.0
		for i in row.size():
			cols[row[i].id] = i + offset

	_tree_area = Control.new()
	_tree_area.custom_minimum_size = Vector2(
		(max_row_count - 1) * _COL_STEP + _NODE_SIZE.x,
		max_tier * _ROW_STEP + _NODE_SIZE.y
	) + _PADDING * 2
	_tree_area.draw.connect(_draw_edges)

	for t in _talents:
		var top_left := _PADDING + Vector2(cols[t.id] * _COL_STEP, t.tier * _ROW_STEP)
		_centers[t.id] = top_left + _NODE_SIZE * 0.5

		var btn := Button.new()
		btn.position = top_left
		btn.size = _NODE_SIZE
		btn.tooltip_text = t.description
		btn.pressed.connect(_on_talent_pressed.bind(t.id))
		_tree_area.add_child(btn)
		_buttons[t.id] = btn

	_edges.clear()
	for t in _talents:
		for parent_id in _prereq_nodes(t.prereq):
			_edges.append(Vector2i(t.id, parent_id))


# All node ids referenced anywhere in a requirement tree (dedup'd), used only
# to draw connector lines — not evaluated as AND/OR here.
func _prereq_nodes(req: Dictionary) -> Array:
	var seen: Dictionary = {}
	_collect_prereq_nodes(req, seen)
	return seen.keys()

func _collect_prereq_nodes(req: Dictionary, seen: Dictionary) -> void:
	match req.type:
		"has":
			seen[req.node] = true
		"and", "or":
			for c in req.children:
				_collect_prereq_nodes(c, seen)


func _draw_edges() -> void:
	for edge in _edges:
		var child_id: int = edge.x
		var parent_id: int = edge.y
		var learned := _learned.has(child_id) and _learned.has(parent_id)
		var color := Color(0.6, 1.0, 0.6) if learned else Color(0.5, 0.5, 0.5)
		_tree_area.draw_line(_centers[child_id], _centers[parent_id], color, 2.0)


# ── State / network ─────────────────────────────────────────────────────────

func _on_talent_synced(points_available: int, learned: Array) -> void:
	_points_available = points_available
	_learned.clear()
	for id in learned:
		_learned[id] = true
	_refresh()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _refresh() -> void:
	_points_label.text = "Points available: %d" % _points_available
	for t in _talents:
		var btn: Button = _buttons[t.id]
		var learned: bool = _learned.has(t.id)
		var available := _requirement_met(t.prereq)
		btn.text = t.name + (" ✓" if learned else "")
		btn.disabled = learned or not available or _points_available <= 0
		btn.modulate = Color(0.6, 1.0, 0.6) if learned else (Color(1, 1, 1) if available else Color(0.5, 0.5, 0.5))
	_tree_area.queue_redraw()


func _requirement_met(req: Dictionary) -> bool:
	match req.type:
		"none":
			return true
		"has":
			return _learned.has(req.node)
		"and":
			for c in req.children:
				if not _requirement_met(c):
					return false
			return true
		"or":
			for c in req.children:
				if _requirement_met(c):
					return true
			return false
		"sum":
			var count := 0
			for t in _talents:
				if req.group in t.tags and _learned.has(t.id):
					count += 1
			return count >= req.threshold
	return false


func _on_talent_pressed(node_id: int) -> void:
	Network.send(Protocol.pkt_learn_talent(node_id))


func _close() -> void:
	visible = false
	if GameState.player_net_id != -1:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
