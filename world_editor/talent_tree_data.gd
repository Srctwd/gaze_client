class_name TalentTreeData
extends RefCounted

# Loads and interprets the talent tree data file for the design-review graph
# view (see talent_tree_view.gd). Adapted from gaze_client/game/talent_tree.gd
# — this is a read-only design tool, not gameplay, so there's no "learned"
# state or requirement_met() here, just parsing + a human-readable summary of
# each talent's requirements.
#
# Default path resolves to the server's live copy at <repo_root>/build/
# talents.json (see talent_tree_view.gd's use of exe-relative pathing) so
# editing the tree here always reflects what the server will actually load.

# Each entry: { id, key, name, tier, tags: Array[String], prereq: Requirement
# dict, bonus, effects, description, x, y }
# x/y are normalized 0..1 canvas-fraction positions (same convention as
# _col_frac/_row_frac in talent_tree_view.gd: x=0 left, y=0 top), null when
# the talent has never been manually positioned — in that case the view
# falls back to its own tier/prereq-based auto layout. Set by dragging a
# node in the editor; read by both the editor and gaze_client so a saved
# layout renders identically in both.
# Requirement dict shapes:
#   {"type": "none"}
#   {"type": "has", "node": int}
#   {"type": "and"/"or", "children": Array[Requirement]}
#   {"type": "sum", "group": String, "threshold": int}
#   {"type": "stat", "name": String, "threshold": int}
var talents: Array = []
var by_id: Dictionary = {}      # node_id -> talent dict
var key_to_id: Dictionary = {}  # kept around (not just local to load()) so edits can be re-parsed


func load(path: String) -> bool:
	talents.clear()
	by_id.clear()
	key_to_id.clear()

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("TalentTreeData: failed to open " + path)
		return false

	var rows = JSON.parse_string(f.get_as_text())
	if typeof(rows) != TYPE_ARRAY:
		push_error("TalentTreeData: " + path + " is not a JSON array")
		return false

	# First pass: collect id/key pairs so the requires-tree parser (second
	# pass) can resolve references regardless of declaration order.
	for row: Dictionary in rows:
		key_to_id[row.key] = int(row.id)

	for row: Dictionary in rows:
		var node_id: int = int(row.id)
		var talent := {
			"id": node_id,
			"key": row.key,
			"name": row.name,
			"tier": int(row.tier),
			"tags": row.get("tags", []),
			"requires_raw": row.get("requires"),  # the exact JSON value — kept for save(), see requires_json_text()
			"prereq": _parse_requires(row.get("requires"), key_to_id),
			"bonus": row.get("bonus", []),
			"effects": row.get("effects", []),
			"params": row.get("params", {}),
			"description": row.get("description", ""),
			"x": row.get("x"),
			"y": row.get("y"),
		}
		talents.append(talent)
		by_id[node_id] = talent

	return true


# Writes `talents` back to `path` as a JSON array, in the same field shape
# load() reads (id/key/name/tier/tags/requires/bonus/effects/description) and
# the same talent order. `requires` comes from each talent's "requires_raw" —
# set it via set_requires() so it stays consistent with "prereq".
func save(path: String) -> bool:
	var rows: Array = []
	for t in talents:
		var row := {
			"id": t.id,
			"key": t.key,
			"name": t.name,
			"tier": t.tier,
			"tags": t.tags,
			"requires": t.requires_raw,
			"bonus": t.bonus,
			"effects": t.effects,
			"description": t.description,
		}
		# Effect tuning values (e.g. Climb's climb_ratio) — only written when set.
		if not (t.get("params", {}) as Dictionary).is_empty():
			row["params"] = t.params
		# Omitted (not written as null) for a talent that's never been
		# manually positioned, so it keeps auto-laying-out as the tree
		# structure around it changes.
		if t.x != null and t.y != null:
			row["x"] = t.x
			row["y"] = t.y
		rows.append(row)

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("TalentTreeData: failed to open " + path + " for writing")
		return false
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
	return true


# Parses a requires JSON value (already decoded, e.g. from JSON.parse_string
# on user-edited text) into the internal requirement-dict shape, using this
# tree's own key_to_id — public so talent_tree_view can re-parse an edited
# talent's requires without a full reload().
func parse_requires(node) -> Dictionary:
	return _parse_requires(node, key_to_id)


func _parse_requires(node, key_to_id: Dictionary) -> Dictionary:
	if node == null:
		return { "type": "none" }

	if node is String:
		if not key_to_id.has(node):
			push_error("TalentTreeData: unknown talent key '" + node + "' in requires")
			return { "type": "none" }
		return { "type": "has", "node": key_to_id[node] }

	if node is Dictionary:
		if node.has("and"):
			var children: Array = []
			for c in node["and"]:
				children.append(_parse_requires(c, key_to_id))
			return { "type": "and", "children": children }
		if node.has("or"):
			var children: Array = []
			for c in node["or"]:
				children.append(_parse_requires(c, key_to_id))
			return { "type": "or", "children": children }
		if node.has("sum"):
			var s: Dictionary = node["sum"]
			return { "type": "sum", "group": s.group, "threshold": int(s.threshold) }
		if node.has("stat"):
			var st: Dictionary = node["stat"]
			return { "type": "stat", "name": st.name, "threshold": int(st.at_least) }

	push_error("TalentTreeData: malformed requires node: " + str(node))
	return { "type": "none" }


# All node ids referenced anywhere in a requirement tree (dedup'd) — used both
# for drawing connector lines and for the column-averaging layout in
# talent_tree_view.gd. Ignores "sum"/"stat" (they don't reference a specific
# node) — same as the client.
func prereq_nodes(req: Dictionary) -> Array:
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


# Like prereq_nodes(), but tags each referenced node with whether it's
# obligatory ("and") or an either/or option ("or") — for arrow direction in
# the graph view, not an AND/OR evaluation. A "has" leaf's kind is whichever
# and/or group directly encloses it (deepest wins) — a leaf with no
# enclosing group at all (a bare "requires": "SomeKey") defaults to "and".
# Returns Array[{"node": int, "kind": String}].
func edges_with_kind(req: Dictionary) -> Array:
	var out: Array = []
	_collect_edges_with_kind(req, "and", out)
	return out

func _collect_edges_with_kind(req: Dictionary, kind: String, out: Array) -> void:
	match req.type:
		"has":
			out.append({ "node": req.node, "kind": kind })
		"and":
			for c in req.children:
				_collect_edges_with_kind(c, "and", out)
		"or":
			for c in req.children:
				_collect_edges_with_kind(c, "or", out)


# Human-readable requirement summary, e.g. "Dual Wield and Weapon Mastery and
# Strength >= 15" or "4+ magic talents" — shown in the description panel so
# and/or/sum/stat structure is reviewable without reading the JSON.
func requirement_to_text(req: Dictionary) -> String:
	match req.type:
		"none":
			return "None"
		"has":
			return by_id[req.node].name if by_id.has(req.node) else "?"
		"and":
			var parts: Array = []
			for c in req.children:
				parts.append(_maybe_parenthesize(c))
			return " and ".join(parts)
		"or":
			var parts: Array = []
			for c in req.children:
				parts.append(_maybe_parenthesize(c))
			return " or ".join(parts)
		"sum":
			return "%d+ %s talents" % [req.threshold, req.group]
		"stat":
			return "%s >= %d" % [req.name.capitalize(), req.threshold]
	return "?"

func _maybe_parenthesize(req: Dictionary) -> String:
	var text := requirement_to_text(req)
	return "(%s)" % text if req.type == "or" else text
