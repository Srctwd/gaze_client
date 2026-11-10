extends "res://world_editor/tools/place_tool.gd"

# Objects + Chunks pages: static objects, water rects and adding chunks.
# Reaches the editor (world, camera, shared type tables, status line, undo
# history) through `ed`; see tools/place_tool.gd for the hooks main.gd calls.

var _ghost: Node3D  # this tool's own placement preview

var _water_drag_start:  Vector3 = Vector3.ZERO
var _water_dragging:    bool    = false
var _water_y_offset:    float   = 0.0
var _water_is_waterfall: bool   = false

func _place_object() -> void:
	var hit := ed._raycast_or_plane(get_viewport().get_mouse_position())
	if ed._place_type == ed.MODE_WATER:
		var size := ed._obj_radius * 2.0
		ed._wd.add_water_rect(hit.x, hit.z, size, size, hit.y, _water_is_waterfall)
		ed._rebuild_water()
		var kind := "Waterfall" if _water_is_waterfall else "Water"
		ed._set_status("%s placed at (%.1f, %.1f) y=%.2f size=%.1f" % [kind, hit.x, hit.z, hit.y, size])
		return
	if ed._place_type == ed.MODE_CHUNK:
		var chunk_size := ed._wd.chunk_cells * ed._wd.cell_size
		var ax := floori((hit.x - ed._wd.world_ox) / chunk_size)
		var az := floori((hit.z - ed._wd.world_oz) / chunk_size)
		var cx := ed._wd.origin_cx + ax
		var cz := ed._wd.origin_cz + az
		if not ed._wd.add_chunk_at(cx, cz):
			ed._set_status("Chunk already exists at (%d, %d)" % [cx, cz])
			return
		for child in ed._terrain.get_children():
			child.queue_free()
		ed._spawn_world()
		ed._build_grid()
		ed._set_status("Added chunk (%d, %d) — world now %dx%d" % [cx, cz, ed._wd.chunks_x, ed._wd.chunks_z])
		return
	if not ed._object_type_defs.has(ed._place_type):
		ed._set_status("Unknown object type %d" % ed._place_type)
		return
	var def := ed._object_type_defs[ed._place_type] as Dictionary
	var height := ed._obj_radius * (def.get("height_ratio", 1.5) as float)
	ed._wd.add_static_object(ed._place_type, hit.x, hit.z, ed._obj_radius, height)
	ed._rebuild_objects()
	ed._set_status("Placed %s at (%.0f, %.0f)" % [def.get("name", "?"), hit.x, hit.z])

func _update_chunk_ghost(hit: Vector3) -> void:
	var chunk_size := ed._wd.chunk_cells * ed._wd.cell_size
	var ax := floori((hit.x - ed._wd.world_ox) / chunk_size)
	var az := floori((hit.z - ed._wd.world_oz) / chunk_size)
	var valid    := not (ax >= 0 and ax < ed._wd.chunks_x and az >= 0 and az < ed._wd.chunks_z)
	var center_x := ed._wd.world_ox + (ax + 0.5) * chunk_size
	var center_z := ed._wd.world_oz + (az + 0.5) * chunk_size

	if _ghost == null or _ghost.get_meta("type") != ed.MODE_CHUNK:
		if _ghost: _ghost.queue_free()
		var plane := PlaneMesh.new()
		plane.size = Vector2(chunk_size, chunk_size)
		var mi := MeshInstance3D.new()
		mi.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.3, 0.85, 0.3, 0.35)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		_ghost = Node3D.new()
		_ghost.set_meta("type", ed.MODE_CHUNK)
		_ghost.add_child(mi)
		add_child(_ghost)

	var mi := _ghost.get_child(0) as MeshInstance3D
	var mat := mi.material_override as StandardMaterial3D
	mat.albedo_color = Color(0.3, 0.85, 0.3, 0.35) if valid else Color(0.85, 0.3, 0.3, 0.35)
	_ghost.position = Vector3(center_x, 0.15, center_z)
	_ghost.visible  = true

func _update_water_ghost(hit: Vector3) -> void:
	if _ghost == null or _ghost.get_meta("type") != ed.MODE_WATER:
		if _ghost: _ghost.queue_free()
		var mi := MeshInstance3D.new()
		mi.mesh = PlaneMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode    = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		_ghost = Node3D.new()
		_ghost.set_meta("type", ed.MODE_WATER)
		_ghost.add_child(mi)
		add_child(_ghost)

	var mi    := _ghost.get_child(0) as MeshInstance3D
	var plane := mi.mesh as PlaneMesh
	var mat   := mi.material_override as StandardMaterial3D
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.55) if _water_is_waterfall else Color(0.1, 0.5, 0.9, 0.5)

	var ax := _water_drag_start.x if _water_dragging else hit.x
	var az := _water_drag_start.z if _water_dragging else hit.z
	var bx := hit.x
	var bz := hit.z
	var cx := (ax + bx) * 0.5
	var cz := (az + bz) * 0.5
	var w  := maxf(absf(bx - ax), 0.5)
	var d  := maxf(absf(bz - az), 0.5)
	var y  := (_water_drag_start.y if _water_dragging else hit.y) + _water_y_offset

	plane.size       = Vector2(w, d)
	_ghost.transform = Transform3D(Basis(), Vector3(cx, y, cz))
	_ghost.visible   = true

	if _water_dragging:
		var kind := "Waterfall" if _water_is_waterfall else "Water"
		ed._set_status("%s: %.1f x %.1f  y=%.2f  [Scroll] adjust Y  [Esc] cancel" % [kind, w, d, y])

func _place_water_drag(mouse: Vector2) -> void:
	var hit := ed._raycast_or_plane(mouse)
	var ax  := _water_drag_start.x
	var az  := _water_drag_start.z
	var bx  := hit.x
	var bz  := hit.z
	var cx  := (ax + bx) * 0.5
	var cz  := (az + bz) * 0.5
	var w   := maxf(absf(bx - ax), 0.5)
	var d   := maxf(absf(bz - az), 0.5)
	var y   := _water_drag_start.y + _water_y_offset
	ed._wd.add_water_rect(cx, cz, w, d, y, _water_is_waterfall)
	ed._rebuild_water()
	var kind := "Waterfall" if _water_is_waterfall else "Water"
	ed._set_status("%s placed (%.1f x %.1f) at (%.1f, %.1f) y=%.2f" % [kind, w, d, cx, cz, y])


# Objects page — one button per object_types.json row (built dynamically, so
# a new object type needs no code here), plus Water.
func build_page(obj_vbox: VBoxContainer) -> void:
	var object_ids := ed._object_type_defs.keys()
	object_ids.sort()
	for id in object_ids:
		var def := ed._object_type_defs[id] as Dictionary
		var label := def.get("name", str(id)) as String
		var btn := Button.new()
		btn.text = label
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var pt: int = id as int
		btn.pressed.connect(func(): ed._place_type = pt; ed._set_status(label + " selected"))
		obj_vbox.add_child(btn)

	# Water isn't a static-object type (no entry in `object_types`), but it's
	# still placed from this page — its own MODE_WATER handles it separately.
	var water_btn := Button.new()
	water_btn.text = "Water"
	water_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	water_btn.pressed.connect(func(): ed._place_type = ed.MODE_WATER; ed._set_status("Water: r=%.1f" % ed._obj_radius))
	obj_vbox.add_child(water_btn)

	# Waterfall is not a separate data type — it's the exact same WaterRect
	# the server treats as flat water (see WaterRect.is_waterfall in
	# world.h), placed exactly like normal water. It's just rendered white
	# here so the designer can tell it apart from a lake; the game client is
	# the one that samples the terrain heightmap under this rect's footprint
	# and renders an actual cascade volume down to the lowest point instead
	# of a flat plane.
	var waterfall_check := CheckBox.new()
	waterfall_check.text = "Waterfall"
	waterfall_check.button_pressed = false
	waterfall_check.toggled.connect(func(pressed: bool):
		_water_is_waterfall = pressed
		ed._set_status("Waterfall: " + ("ON" if pressed else "off"))
	)
	obj_vbox.add_child(waterfall_check)

	obj_vbox.add_child(HSeparator.new())
	var obj_hint := Label.new()
	obj_hint.text = "[LMB] place / drag (Water)\n[Del] remove nearest\n[Scroll] radius / Y level (Water)"
	obj_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	obj_vbox.add_child(obj_hint)


# ── place_tool hooks ─────────────────────────────────────────────────────────

func on_lmb(pressed: bool, _event: InputEventMouseButton) -> void:
	if ed._place_type == ed.MODE_WATER:
		if pressed:
			_water_drag_start = ed._raycast_or_plane(get_viewport().get_mouse_position())
			_water_dragging   = true
		elif _water_dragging:
			_water_dragging = false
			_place_water_drag(get_viewport().get_mouse_position())
	elif pressed:
		_place_object()


func on_scroll(dir: int) -> void:
	if ed._place_type == ed.MODE_WATER:
		_water_y_offset += 0.10 * dir
		ed._set_status("Water Y offset: %+.2f" % _water_y_offset)
	else:
		ed._obj_radius = clampf(ed._obj_radius + 0.10 * dir, 0.10, 15.0)
		ed._set_status("Object radius: %.2f" % ed._obj_radius)


func on_delete(_event: InputEventKey, hit: Vector3) -> void:
	if ed._place_type == ed.MODE_WATER:
		if ed._wd.remove_nearest_water_rect(hit.x, hit.z, 100.0):
			ed._rebuild_water()
			ed._set_status("Water rect removed")
	elif ed._wd.remove_nearest_object(hit.x, hit.z, 20.0):
		ed._rebuild_objects()
		ed._set_status("Object removed")


func cancel() -> String:
	if not _water_dragging: return ""
	_water_dragging = false
	return "Water drag cancelled"


func is_dragging() -> bool:
	return _water_dragging


func update(_delta: float, _mouse: Vector2, hit: Vector3) -> void:
	if ed._place_type == ed.MODE_CHUNK:
		_update_chunk_ghost(hit)
	elif ed._place_type == ed.MODE_WATER:
		_update_water_ghost(hit)
	else:
		_update_object_ghost(hit)


func deactivate() -> void:
	if _ghost: _ghost.visible = false


func status_hint() -> String:
	if ed._place_type == ed.MODE_CHUNK:
		return "[LMB] place  [Delete] remove nearest  [1] tree  [2] rock  [3] chunk  [4] water — current: Chunk (green=valid red=occupied)"
	if ed._place_type == ed.MODE_WATER:
		var kind := "Waterfall" if _water_is_waterfall else "Water"
		return "[LMB drag] define rect  [Scroll] Y level  [Delete] remove nearest  [Esc] cancel  — %s y_offset=%+.2f" % [kind, _water_y_offset]
	return "[LMB] place  [Delete] remove nearest  [1] tree  [2] rock  [3] chunk  [4] water  [Scroll] size  — current: %s r=%.2f" % [ed._object_type_name(ed._place_type), ed._obj_radius]


# Preview of the selected static object, scaled to the placement radius.
func _update_object_ghost(hit: Vector3) -> void:
	if not ed._object_type_defs.has(ed._place_type):
		if _ghost: _ghost.visible = false
		return
	if _ghost == null or _ghost.get_meta("type") != ed._place_type:
		if _ghost: _ghost.queue_free()
		var node := ed._instantiate_object_type(ed._place_type)
		if node == null:
			return
		node.set_meta("type", ed._place_type)
		node.set_meta("base_scale", node.scale)  # the scene's own root scale, kept under ours
		ed._disable_collision(node)
		if node is MeshInstance3D:
			(node as MeshInstance3D).material_overlay = ed._make_ghost_mat()
		else:
			for mi in node.find_children("*", "MeshInstance3D", true, false):
				mi.material_overlay = ed._make_ghost_mat()
		_ghost = node
		add_child(_ghost)
	var wy := ed._wd._get_height_at(hit.x, hit.z)
	var def := ed._object_type_defs[ed._place_type] as Dictionary
	var scale_ratio     := def.get("scale_ratio", 1.0) as float
	var collision_ratio := def.get("collision_ratio", 1.0) as float
	_ghost.position = Vector3(hit.x, wy, hit.z)
	_ghost.scale    = (_ghost.get_meta("base_scale") as Vector3) * (ed._obj_radius * collision_ratio / scale_ratio)
	_ghost.visible  = true


# ── Undo ─────────────────────────────────────────────────────────────────────
# Static objects and water. Ocean sheets ([O] in terrain mode) are left to
# terrain undo, so the two histories never fight over the same rect. Adding a
# chunk isn't undoable.

func undo_feature() -> String:
	return "objects"


func undo_snapshot() -> Variant:
	if ed._wd == null: return null
	var water: Array = []
	for r in ed._wd._water_rects:
		if not ed._wd.is_ocean_sheet(r as Dictionary): water.append((r as Dictionary).duplicate(true))
	return { "objects": ed._wd._static_objects.duplicate(true), "water": water }


func undo_restore(snap: Variant) -> void:
	var s := snap as Dictionary
	var water: Array = []
	for r in ed._wd._water_rects:
		if ed._wd.is_ocean_sheet(r as Dictionary): water.append(r)
	water.append_array((s["water"] as Array).duplicate(true))
	ed._wd._water_rects = water
	ed._wd._static_objects = (s["objects"] as Array).duplicate(true)
	ed._rebuild_objects()
	ed._rebuild_water()


# Objects: the collider radius. Water: half the square's side. Chunk add has
# its own chunk-sized ghost.
func brush_radius() -> float:
	return -1.0 if ed._place_type == ed.MODE_CHUNK else ed._obj_radius
