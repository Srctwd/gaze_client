class_name TalentTree
extends RefCounted

# Loads and evaluates the talent tree data file (res://talents.json by
# default). Pure data/logic — no UI concerns live here.
#
# The numeric node id sent over the wire (InteractRequest/TalentSync/
# LearnTalentRequest) and the bare "key" used in requires expressions both
# come straight from the data file's id/key fields — this file must be an
# exact copy of the server's talent table (same ids). Ids are never
# reassigned by row order: they're explicit and persisted in the DB
# (character_talents.node_id), so reordering/removing an entry can't corrupt
# existing characters' learned talents.
const DEFAULT_PATH := "res://talents.json"

# Each entry: { id, key, name, tier, tags: Array[String], prereq: Requirement dict, description }
# Requirement dict shapes:
#   {"type": "none"}
#   {"type": "has", "node": int}
#   {"type": "and"/"or", "children": Array[Requirement]}
#   {"type": "sum", "group": String, "threshold": int}
var talents: Array = []
var by_id: Dictionary = {}  # node_id -> talent dict


func load(path: String = DEFAULT_PATH) -> bool:
	talents.clear()
	by_id.clear()

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("TalentTree: failed to open " + path)
		return false

	var rows = JSON.parse_string(f.get_as_text())
	if typeof(rows) != TYPE_ARRAY:
		push_error("TalentTree: " + path + " is not a JSON array")
		return false

	# First pass: collect id/key pairs so the requires-tree parser (second
	# pass) can resolve references regardless of declaration order.
	var key_to_id: Dictionary = {}
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
			"prereq": _parse_requires(row.get("requires"), key_to_id),
			"bonus": row.get("bonus", []),      # Array of {stat, op, value} — gameplay is server-authoritative
			"effects": row.get("effects", []),
			"description": row.get("description", ""),
			# Normalized 0..1 canvas position, set by dragging a node in the
			# world_editor talent tree tool — null if never manually placed,
			# in which case talent_tree_ui.gd falls back to its own
			# tier/prereq-based auto layout.
			"x": row.get("x"),
			"y": row.get("y"),
		}
		talents.append(talent)
		by_id[node_id] = talent

	return true


# Converts a "requires" JSON node into the same Requirement-dict shape
# requirement_met()/prereq_nodes() evaluate:
#   null                                  -> {"type": "none"}
#   "SomeKey"                             -> {"type": "has", "node": id}
#   {"and": [...]} / {"or": [...]}        -> {"type": "and"/"or", "children": [...]}
#   {"sum": {"group": g, "threshold": n}} -> {"type": "sum", "group": g, "threshold": n}
func _parse_requires(node, key_to_id: Dictionary) -> Dictionary:
	if node == null:
		return { "type": "none" }

	if node is String:
		if not key_to_id.has(node):
			push_error("TalentTree: unknown talent key '" + node + "' in requires")
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

	push_error("TalentTree: malformed requires node: " + str(node))
	return { "type": "none" }


# All node ids referenced anywhere in a requirement tree (dedup'd) — useful
# for drawing connector lines, not an AND/OR evaluation.
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


# Same node set as prereq_nodes(), but tagged with whether each is strictly
# required or just one of several alternatives — drives arrow direction in
# the tree UI: a node reachable only through "and" ancestors is mandatory
# (arrow prereq -> dependent, "this unlocks that"); a node reachable through
# any "or" ancestor is optional (arrow dependent -> prereq, "this can also
# use that"), even if that same "or" branch is itself an "and" of two nodes.
func prereq_edges(req: Dictionary) -> Dictionary:
	var result: Dictionary = {}  # node_id -> bool (true = optional)
	_collect_prereq_edges(req, false, result)
	return result

func _collect_prereq_edges(req: Dictionary, under_or: bool, result: Dictionary) -> void:
	match req.type:
		"has":
			result[req.node] = result.get(req.node, true) and under_or
		"and":
			for c in req.children:
				_collect_prereq_edges(c, under_or, result)
		"or":
			for c in req.children:
				_collect_prereq_edges(c, true, result)


func requirement_met(req: Dictionary, learned: Dictionary) -> bool:
	match req.type:
		"none":
			return true
		"has":
			return learned.has(req.node)
		"and":
			for c in req.children:
				if not requirement_met(c, learned):
					return false
			return true
		"or":
			for c in req.children:
				if requirement_met(c, learned):
					return true
			return false
		"sum":
			var count := 0
			for t in talents:
				if req.group in t.tags and learned.has(t.id):
					count += 1
			return count >= req.threshold
	return false
