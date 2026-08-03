class_name TalentTree
extends RefCounted

# Loads and evaluates the talent tree data file (res://talents by default),
# mirroring the parser in stone_gaze/src/systems/talents.cpp (split_fields +
# RequiresParser). Pure data/logic — no UI concerns live here.
#
# The numeric node id sent over the wire (InteractRequest/TalentSync/
# LearnTalentRequest) and the bare "key" used in requires expressions both
# come straight from the data file's id/key columns — this file must be an
# exact copy of the server's "talents" data file (same ids). Ids are never
# reassigned by row order: they're explicit and persisted in the DB
# (character_talents.node_id), so reordering/removing a row can't corrupt
# existing characters' learned talents.
const DEFAULT_PATH := "res://talents"

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

	var rows: Array = []  # Array of field-arrays, in file order
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty() or line.begins_with("#"):
			continue
		var fields := _split_fields(line)
		if fields.size() < 9:
			continue
		rows.append(fields)

	# First pass: collect id/key pairs so the requires-expression parser
	# (second pass) can resolve references regardless of declaration order.
	var key_to_id: Dictionary = {}
	for fields in rows:
		key_to_id[fields[1]] = int(fields[0])

	for fields in rows:
		var node_id: int = int(fields[0])
		var tags: Array = [] if fields[4] == "-" else fields[4].split(",")
		var effects: Array = [] if fields[7] == "-" else fields[7].split(",")
		var talent := {
			"id": node_id,
			"key": fields[1],
			"name": fields[2],
			"tier": int(fields[3]),
			"tags": tags,
			"prereq": _RequiresParser.new(fields[5], key_to_id).parse(),
			"bonus": fields[6],    # raw "stat<op>value,..." string — gameplay is server-authoritative
			"effects": effects,
			"description": fields[8],
		}
		talents.append(talent)
		by_id[node_id] = talent

	return true


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
	var key_to_id: Dictionary

	func _init(expr: String, keys: Dictionary) -> void:
		s = expr
		key_to_id = keys

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

		if not key_to_id.has(token):
			push_error("TalentTree: unknown talent key '" + token + "' in requires expression")
			return { "type": "none" }
		return { "type": "has", "node": key_to_id[token] }


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
