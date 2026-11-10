extends RefCounted

# Snapshot undo/redo for ONE editor feature (walls, terrain, objects…). main.gd
# keeps one of these per feature, so Ctrl+Z only rewinds the feature being
# edited. A snapshot is whatever that feature's snapshot function returns —
# this class never looks inside it.

const LIMIT := 50

var _undo: Array = []
var _redo: Array = []

# Call with the state from BEFORE a change. A new change invalidates redo.
func record(snapshot: Variant) -> void:
	_undo.push_back(snapshot)
	if _undo.size() > LIMIT:
		_undo.pop_front()
	_redo.clear()

# Returns the state to restore (null if there's nothing to undo); `current`
# goes onto the redo stack so the undo can itself be undone.
func undo(current: Variant) -> Variant:
	if _undo.is_empty(): return null
	_redo.push_back(current)
	return _undo.pop_back()

func redo(current: Variant) -> Variant:
	if _redo.is_empty(): return null
	_undo.push_back(current)
	return _redo.pop_back()

# The snapshot undo()/redo() would return next, without taking it — for
# features whose `current` depends on it (terrain captures the same chunks).
func peek_undo() -> Variant:
	return null if _undo.is_empty() else _undo.back()

func peek_redo() -> Variant:
	return null if _redo.is_empty() else _redo.back()

func undo_count() -> int:
	return _undo.size()

func redo_count() -> int:
	return _redo.size()

func clear() -> void:
	_undo.clear()
	_redo.clear()
