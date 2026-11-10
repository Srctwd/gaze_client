extends Node3D

# Base for a place-mode tool — one page of the side panel (Objects, Props,
# Biomes, Walls, Spawns, Paint, Entities). main.gd owns the world, camera, shared type tables,
# undo history and the status line, and routes input to whichever tool is
# active; each tool owns its own state, preview and panel page.
#
# Every hook is a no-op here, so a tool only overrides what it uses. Hooks are
# only called while this tool is the active one, except on_world_loaded.

var ed: WorldEditor  # main.gd


# All prop models (.glb) and prop scenes (.tscn, e.g. a torch with its light)
# under `dir`, recursively, sorted — the prop list is filled from these at
# startup, so props don't have to be typed in by path.
# Shared by the Props page and the Biomes page's prop scatter list.
static func scan_prop_assets(dir: String = "res://assets/props") -> PackedStringArray:
	var out := PackedStringArray()
	var da := DirAccess.open(dir)
	if da == null: return out
	for sub in da.get_directories():
		out.append_array(scan_prop_assets(dir.path_join(sub)))
	for f in da.get_files():
		if f.get_extension().to_lower() in ["glb", "tscn"]:
			out.append(dir.path_join(f))
	out.sort()
	return out


# Fill this tool's tab of the place panel.
func build_page(_vbox: VBoxContainer) -> void:
	pass


# A world was opened / created — rebuild anything derived from ed._wd.
func on_world_loaded() -> void:
	pass


# The open world's contents were rewritten in place (fragment import): refresh
# views derived from it, but keep tool state and anything not stored in it.
func on_world_changed() -> void:
	pass


# Left mouse button pressed / released over the 3D view (not over the UI).
func on_lmb(_pressed: bool, _event: InputEventMouseButton) -> void:
	pass


# Mouse wheel: dir = +1 (up) or -1 (down).
func on_scroll(_dir: int) -> void:
	pass


# Delete key pressed; `hit` is the point under the cursor.
func on_delete(_event: InputEventKey, _hit: Vector3) -> void:
	pass


# Any other key pressed in place mode (after the shared ones: number keys,
# Delete, Ctrl shortcuts). Return true when this tool used it.
func on_key(_event: InputEventKey) -> bool:
	return false


# Esc: abort an in-progress drag. Returns a status message when something
# was cancelled, "" when there was nothing to cancel (Esc then opens the menu).
func cancel() -> String:
	return ""


# Every frame while active: update the preview, apply held-button actions.
func update(_delta: float, _mouse: Vector2, _hit: Vector3) -> void:
	pass


# True while a mouse drag is in progress — undo/redo waits until it ends.
func is_dragging() -> bool:
	return false


# Another tool (or terrain mode) took over: hide previews and highlights.
func deactivate() -> void:
	pass


# Radius of the shared ground ring main.gd draws under the cursor, or < 0
# for none: tools whose preview already shows their footprint (ghost model,
# disc, rectangle) return -1 so a second, unrelated ring doesn't mislead.
func brush_radius() -> float:
	return -1.0


# Undo: the history this tool's Ctrl+Z works on ("" = none).
func undo_feature() -> String:
	return ""


# Undo by snapshot diff: a deep copy of everything this tool edits, or null
# when the tool records its own steps instead (walls, cells). main.gd compares
# it after every mouse/key release, once nothing is held or being typed, and
# records a step when it changed, so a tool needs no undo code of its own
# beyond these two hooks.
func undo_snapshot() -> Variant:
	return null


# Make `snap` (from undo_snapshot) the live state and refresh the views. Must
# copy out of it: main.gd keeps `snap` as the new comparison base.
func undo_restore(_snap: Variant) -> void:
	pass


# Second line of the status bar while this tool is active.
func status_hint() -> String:
	return ""
