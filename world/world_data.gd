class_name WorldData
extends RefCounted

const MAGIC        := 0x47574C44  # "GWLD" - legacy, biome props have no weight
const MAGIC_W      := 0x47574C32  # "GWL2" - biome props are (path, weight)
const MAGIC_B      := 0x47574C33  # "GWL3" - adds a box-collider section (OBB walls)
const WorldShaders  = preload("res://world/world_shaders.gd")

# Preloaded so the exporter includes them (paths come from world.bin at runtime)
const _PRELOAD_FERN01   = preload("res://assets/fern01.glb")
const _PRELOAD_FERN02   = preload("res://assets/fern02.glb")
const _PRELOAD_GRASS_BUSH_SMALL = preload("res://assets/stylized_grass_bush_small.glb")

var chunk_cells : int
var chunks_x    : int
var chunks_z    : int
var cell_size   : float
var origin_cx   : int = 0
var origin_cz   : int = 0
var world_ox    : float = 0.0
var world_oz    : float = 0.0
var _chunks     : Array = []
var _static_objects : Array = []
var _static_boxes   : Array = []  # OBB walls: {type, x, z, half_x, half_z, rot_y, height, y_offset}
var _water_rects    : Array = []
var _biomes         : Array = []  # [{id, name, material, props[]}]
var _prop_types     : Array = []
var _prop_instances : Array = []
var _biomes_by_id   : Dictionary = {}
const _PROP_SCATTER_MIN := 16
const _PROP_SCATTER_MAX := 32
const _PROP_SCALE_MIN   := 3.0
const _PROP_SCALE_MAX   := 5.0
const _PROP_STRETCH     := 0.30
const _PROP_CELL_JITTER := 0.35
var _material      : Material
var _mat_cave      : ShaderMaterial
var _mat_cave_floor: ShaderMaterial
var _fallback_scene        : PackedScene = null
const _FALLBACK_PATH := "res://assets/fushi.glb"
# Wall type id -> ShaderMaterial, built from wall_types.json (id, name, texture
# path) rather than world.bin's own trailing wall-type table — that table is
# written by the same in-progress tool producing world.bin's box section and
# isn't reliable yet (e.g. every id currently points at the same texture in
# the file, while wall_types.json already distinguishes them correctly).
const _WALL_TYPES_PATH := "res://wall_types.json"
var _wall_mats        : Dictionary = {}
var _wall_mat_default : ShaderMaterial
# Static object type id -> {mesh, scale_ratio, resource}. Read directly from
# world.bin's trailing static-type table (written by world_editor's save(),
# derived from its `object_types` file) — so a new object type needs no code
# change here at all. Missing/corrupt table (old world.bin) or an id absent
# from it falls back to _FALLBACK_PATH instead of the wrong mesh/scale.
var _static_type_defs : Dictionary = {}


func load(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("WorldData: cannot open " + path)
		return false

	var first := f.get_32()
	var static_offset: int
	var box_offset: int = 0
	if first == MAGIC or first == MAGIC_W or first == MAGIC_B:
		chunk_cells   = f.get_32()
		chunks_x      = f.get_32()
		chunks_z      = f.get_32()
		cell_size     = f.get_float()
		var raw_ocx   := f.get_32()
		var raw_ocz   := f.get_32()
		static_offset = f.get_32()
		origin_cx = raw_ocx if raw_ocx < 0x80000000 else int(raw_ocx) - 0x100000000
		origin_cz = raw_ocz if raw_ocz < 0x80000000 else int(raw_ocz) - 0x100000000
		if first == MAGIC_B:
			box_offset = f.get_32()
	else:
		chunk_cells   = first
		chunks_x      = f.get_32()
		chunks_z      = f.get_32()
		cell_size     = f.get_float()
		static_offset = f.get_32()
		origin_cx = -(chunks_x / 2)
		origin_cz = -(chunks_z / 2)
	world_ox = origin_cx * chunk_cells * cell_size
	world_oz = origin_cz * chunk_cells * cell_size

	var total  := chunks_x * chunks_z
	var stride := chunk_cells + 1
	var cells  := stride * stride

	var has_biome := (first == MAGIC or first == MAGIC_W or first == MAGIC_B)
	var has_prop_weight := (first == MAGIC_W or first == MAGIC_B)
	var has_boxes := (first == MAGIC_B)

	var types   : Array[int] = []
	var biomes_ : Array[int] = []
	var offsets : Array[int] = []

	for i in range(total):
		types.append(f.get_8())
		biomes_.append(f.get_8() if has_biome else 0)
		offsets.append(f.get_32())

	_chunks.clear()

	for i in range(total):
		if offsets[i] >= f.get_length():
			push_error("WorldData: invalid offset at index " + str(i))
			f.close()
			return false

		f.seek(offsets[i])

		var h1 : Array[float] = []
		h1.resize(cells)
		for j in range(cells):
			h1[j] = f.get_float()

		var h2 : Array[float] = []
		var h3 : Array[float] = []
		if types[i] == 2:
			h2.resize(cells)
			for j in range(cells):
				h2[j] = f.get_float()
			h3.resize(cells)
			for j in range(cells):
				h3[j] = f.get_float()

		_chunks.append({ "type": types[i], "biome": biomes_[i], "h1": h1, "h2": h2, "h3": h3 })

	_static_objects.clear()
	f.seek(static_offset)
	var obj_count := f.get_32()
	for _i in range(obj_count):
		var type   := f.get_8()
		var ox_    := f.get_float()
		var oz_    := f.get_float()
		var radius := f.get_float()
		var height := f.get_float()
		_static_objects.append({ "type": type, "x": ox_, "z": oz_, "radius": radius, "height": height })

	# Each of the sections below is optional/trailing and was historically read
	# with a plain eof_reached() check — that alone breaks once has_boxes is
	# true, since the file doesn't end after the last trailing section anymore:
	# it ends after the box section, appended past all of these. Without also
	# checking against box_offset, a missing table (e.g. no static-type-defs
	# on this file) gets misread from the box section's own leading bytes
	# instead of being skipped, corrupting _static_type_defs and sending every
	# static object down the _fallback_scene path.
	_water_rects.clear()
	if not f.eof_reached() and (not has_boxes or f.get_position() < box_offset):
		var wcount := f.get_32()
		for _i in range(wcount):
			_water_rects.append({
				"x": f.get_float(), "z": f.get_float(),
				"width": f.get_float(), "depth": f.get_float(), "y": f.get_float()
			})

	_biomes.clear()
	if not f.eof_reached() and (not has_boxes or f.get_position() < box_offset):
		var bcount := f.get_8()
		for _bi in range(bcount):
			var bid   := f.get_8()
			var n     := f.get_8(); var bname := f.get_buffer(n).get_string_from_utf8() if n > 0 else ""
			n = f.get_8(); var bmat  := f.get_buffer(n).get_string_from_utf8() if n > 0 else ""
			var pc    := f.get_8()
			var bprops: Array[String] = []
			var bweights: Array[float] = []
			for _pi in range(pc):
				n = f.get_8(); bprops.append(f.get_buffer(n).get_string_from_utf8() if n > 0 else "")
				bweights.append(f.get_float() if has_prop_weight else 1.0)
			# spawner fields (not used on client — read to advance position)
			var bst  := f.get_8(); var bsi := f.get_float()
			var bsm  := f.get_8(); var bsp := f.get_float()
			_biomes.append({ "id": bid, "name": bname, "material": bmat, "props": bprops,
				"prop_weights": bweights,
				"spawn_type": bst, "spawn_interval": bsi, "spawn_max": bsm, "spawn_prob": bsp })

	_biomes_by_id.clear()
	for b in _biomes:
		_biomes_by_id[(b as Dictionary)["id"]] = b

	_prop_types.clear()
	_prop_instances.clear()
	if not f.eof_reached() and (not has_boxes or f.get_position() < box_offset):
		var ptcount := f.get_8()
		for _pti in range(ptcount):
			var pn := f.get_8(); _prop_types.append(f.get_buffer(pn).get_string_from_utf8() if pn > 0 else "")
	if not f.eof_reached() and (not has_boxes or f.get_position() < box_offset):
		var picount := f.get_32()
		for _pii in range(picount):
			_prop_instances.append({
				"type_idx": f.get_8(),
				"x": f.get_float(), "y": f.get_float(), "z": f.get_float(),
				"rot_y": f.get_float(),
				"sx": f.get_float(), "sy": f.get_float(), "sz": f.get_float()
			})

	# Static-object type table (type_id -> mesh path, scale_ratio) — written by
	# world_editor's save(), derived from its `object_types` file. Optional
	# trailing section: absent on world.bin files saved before this existed,
	# in which case every static object falls back to _fallback_scene below.
	_static_type_defs.clear()
	if not f.eof_reached() and (not has_boxes or f.get_position() < box_offset):
		var stcount := f.get_32()
		for _sti in range(stcount):
			var stid        := f.get_8()
			var n            := f.get_8()
			var mesh_path    := f.get_buffer(n).get_string_from_utf8() if n > 0 else ""
			var scale_ratio  := f.get_float()
			_static_type_defs[stid] = { "mesh": mesh_path, "scale_ratio": scale_ratio, "resource": null }

	# Box-collider (OBB wall) section — appended at the very end of the file,
	# after every other trailing section, so it's read via an explicit seek
	# rather than sequentially; reading it any earlier would leave the cursor
	# at EOF and silently skip everything that comes after it above.
	_static_boxes.clear()
	if has_boxes:
		f.seek(box_offset)
		var box_count := f.get_32()
		for _i in range(box_count):
			var btype    := f.get_8()
			var bx       := f.get_float()
			var bz       := f.get_float()
			var bhalf_x  := f.get_float()
			var bhalf_z  := f.get_float()
			var brot_y   := f.get_float()
			var bheight  := f.get_float()
			var byoffset := f.get_float()
			_static_boxes.append({ "type": btype, "x": bx, "z": bz,
				"half_x": bhalf_x, "half_z": bhalf_z, "rot_y": brot_y, "height": bheight,
				"y_offset": byoffset })

	f.close()

	_stitch_all_borders("h1")
	_stitch_all_borders("h2")
	_stitch_all_borders("h3")

	_material      = WorldShaders.surface_mat(Color(0.35, 0.52, 0.28))
	_mat_cave       = WorldShaders.cave_mat(Color(0.40, 0.33, 0.25))
	_mat_cave_floor = WorldShaders.cave_mat(Color(0.30, 0.20, 0.13))
	_fallback_scene = load(_FALLBACK_PATH)
	_load_wall_types()
	return true


func _load_wall_types() -> void:
	_wall_mats.clear()
	_wall_mat_default = WorldShaders.wall_mat()
	var wf := FileAccess.open(_WALL_TYPES_PATH, FileAccess.READ)
	if wf == null:
		push_error("WorldData: cannot open " + _WALL_TYPES_PATH)
		return
	var rows = JSON.parse_string(wf.get_as_text())
	if typeof(rows) != TYPE_ARRAY:
		push_error("WorldData: " + _WALL_TYPES_PATH + " is not a JSON array")
		return
	for row: Dictionary in rows:
		var wid  := int(row.get("id", 0))
		var path := row.get("texture", "") as String
		if path.is_empty():
			continue
		var tex := load(path) as Texture2D
		if tex == null:
			push_error("WorldData: wall type %d texture failed to load: %s" % [wid, path])
			continue
		_wall_mats[wid] = WorldShaders.wall_mat(tex)


func _static_type_resource(id: int) -> Resource:
	if not _static_type_defs.has(id): return null
	var def := _static_type_defs[id] as Dictionary
	if def["resource"] == null:
		var mesh_path := def["mesh"] as String
		if mesh_path.is_empty(): return null
		def["resource"] = load(mesh_path)
		_static_type_defs[id] = def
	return def["resource"] as Resource


# Meshes (.glb) import as a PackedScene; some assets could import as a bare
# Mesh instead — handle both without per-type branching.
func _instantiate_static_type(id: int) -> Node3D:
	var res := _static_type_resource(id)
	if res == null: return null
	if res is PackedScene:
		return (res as PackedScene).instantiate() as Node3D
	if res is Mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = res as Mesh
		return mi
	return null


func spawn_into(parent: Node3D) -> void:
	var ox := world_ox
	var oz := world_oz
	var biome_mat_cache: Dictionary = {}
	var prop_cache: Dictionary = {}

	for i in range(_chunks.size()):
		var cx := i % chunks_x
		var cz := int(i / chunks_x)
		var origin   := Vector3(ox + cx * chunk_cells * cell_size, 0.0, oz + cz * chunk_cells * cell_size)
		var biome_id := _chunks[i].get("biome", 0) as int

		var chunk_mat: Material
		if _biomes.is_empty():
			chunk_mat = _material
		else:
			if not biome_mat_cache.has(biome_id):
				biome_mat_cache[biome_id] = WorldShaders.biome_surface_mat(biome_id, _biomes)
			chunk_mat = biome_mat_cache[biome_id] as Material

		var floor_mi := _make_chunk(_chunks[i].h1, origin, chunk_mat)
		floor_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		parent.add_child(floor_mi)
		if _chunks[i].type == 2:
			var ceil_mi := _make_chunk(_chunks[i].h2, origin, _mat_cave)
			ceil_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
			parent.add_child(ceil_mi)
			parent.add_child(_make_chunk(_chunks[i].h3, origin, _mat_cave_floor))

		_scatter_biome_props(biome_id, origin, prop_cache, parent)

	for obj in _static_objects:
		var wy   := _get_height_at(obj.x, obj.z)
		var id   := obj.type as int
		var node := _instantiate_static_type(id)
		var scale_ratio := 1.0
		if node == null:
			if _fallback_scene == null: continue
			node = _fallback_scene.instantiate() as Node3D
		else:
			scale_ratio = (_static_type_defs[id] as Dictionary).get("scale_ratio", 1.0) as float
		node.position = Vector3(obj.x, wy, obj.z)
		node.scale    = Vector3.ONE * ((obj.radius as float) / scale_ratio)
		parent.add_child(node)

	for wb in _static_boxes:
		var wy := _get_height_at(wb.x as float, wb.z as float)
		if is_nan(wy): wy = 0.0
		parent.add_child(_make_wall_box(wb, wy))

	var water_mat := WorldShaders.water_mat()
	for wr in _water_rects:
		var plane := PlaneMesh.new()
		plane.size = Vector2(wr.width as float, wr.depth as float)
		plane.surface_set_material(0, water_mat)
		var mi := MeshInstance3D.new()
		mi.mesh     = plane
		mi.position = Vector3(wr.x as float, wr.y as float, wr.z as float)
		parent.add_child(mi)

	for pi_ in _prop_instances:
		var pd    := pi_ as Dictionary
		var tidx  := pd["type_idx"] as int
		if tidx < 0 or tidx >= _prop_types.size(): continue
		var path  := _prop_types[tidx] as String
		if not prop_cache.has(path):
			prop_cache[path] = load(path) as PackedScene
		var sc := prop_cache[path] as PackedScene
		if sc == null: continue
		var inst := sc.instantiate() as Node3D
		inst.position   = Vector3(pd["x"] as float, pd["y"] as float, pd["z"] as float)
		inst.rotation.y = pd["rot_y"] as float
		inst.scale      = Vector3(pd["sx"] as float, pd["sy"] as float, pd["sz"] as float)
		parent.add_child(inst)


func _randomize_prop_transform(inst: Node3D) -> void:
	inst.rotation.y = randf() * TAU
	var base := randf_range(_PROP_SCALE_MIN, _PROP_SCALE_MAX)
	var wide := base * randf_range(1.0 - _PROP_STRETCH, 1.0 + _PROP_STRETCH)
	var tall := base * randf_range(1.0 - _PROP_STRETCH, 1.0 + _PROP_STRETCH)
	var deep := base * randf_range(1.0 - _PROP_STRETCH, 1.0 + _PROP_STRETCH)
	inst.scale = Vector3(wide, tall, deep)


func _pick_weighted_prop(bprops: Array, bweights: Array) -> String:
	var total := 0.0
	for w in bweights:
		total += w as float
	if total <= 0.0:
		return bprops[randi() % bprops.size()] as String

	var roll := randf() * total
	for i in range(bprops.size()):
		roll -= bweights[i] as float
		if roll <= 0.0:
			return bprops[i] as String
	return bprops[bprops.size() - 1] as String


func _scatter_biome_props(biome_id: int, origin: Vector3, prop_cache: Dictionary, parent: Node3D) -> void:
	if not _biomes_by_id.has(biome_id):
		return
	var biome := _biomes_by_id[biome_id] as Dictionary
	var bprops: Array = biome.get("props", [])
	if bprops.is_empty():
		return
	var bweights: Array = biome.get("prop_weights", [])

	var chunk_size := chunk_cells * cell_size
	var count := randi_range(_PROP_SCATTER_MIN, _PROP_SCATTER_MAX)

	# Stratified jittered grid: one prop per cell so placements stay evenly
	# spread and never land on top of each other, instead of pure random XZ.
	var cols    := int(ceil(sqrt(float(count))))
	var rows    := int(ceil(float(count) / float(cols)))
	var cell_w  := chunk_size / cols
	var cell_h  := chunk_size / rows

	for idx in range(count):
		var gx := idx % cols
		var gz := int(idx / cols)

		var prop_path := _pick_weighted_prop(bprops, bweights)
		if not prop_cache.has(prop_path):
			prop_cache[prop_path] = load(prop_path) as PackedScene
		var sc := prop_cache[prop_path] as PackedScene
		if sc == null:
			continue

		var jitter_x := randf_range(-_PROP_CELL_JITTER, _PROP_CELL_JITTER) * cell_w
		var jitter_z := randf_range(-_PROP_CELL_JITTER, _PROP_CELL_JITTER) * cell_h
		var wx := origin.x + (gx + 0.5) * cell_w + jitter_x
		var wz := origin.z + (gz + 0.5) * cell_h + jitter_z
		var wy := _get_height_at(wx, wz)
		if is_nan(wy):
			continue

		var inst := sc.instantiate() as Node3D
		inst.position = Vector3(wx, wy, wz)
		_randomize_prop_transform(inst)
		parent.add_child(inst)


func _stitch_all_borders(layer: String) -> void:
	var stride := chunk_cells + 1
	for cz in range(chunks_z):
		for cx in range(chunks_x - 1):
			var lh: Array = (_chunks[cz * chunks_x + cx] as Dictionary)[layer]
			var rh: Array = (_chunks[cz * chunks_x + cx + 1] as Dictionary)[layer]
			if lh.is_empty() or rh.is_empty(): continue
			for vz in range(stride):
				rh[vz * stride] = lh[vz * stride + chunk_cells]
	for cz in range(chunks_z - 1):
		for cx in range(chunks_x):
			var th: Array = (_chunks[cz * chunks_x + cx] as Dictionary)[layer]
			var bh: Array = (_chunks[(cz + 1) * chunks_x + cx] as Dictionary)[layer]
			if th.is_empty() or bh.is_empty(): continue
			for vx in range(stride):
				bh[vx] = th[chunk_cells * stride + vx]


func _get_height_at(wx: float, wz: float) -> float:
	var lx := wx - world_ox
	var lz := wz - world_oz
	var cx := int(lx / (chunk_cells * cell_size))
	var cz := int(lz / (chunk_cells * cell_size))
	cx = clampi(cx, 0, chunks_x - 1)
	cz = clampi(cz, 0, chunks_z - 1)
	var chunk_ox := cx * chunk_cells * cell_size
	var chunk_oz := cz * chunk_cells * cell_size
	var local_x  := lx - chunk_ox
	var local_z  := lz - chunk_oz
	var gx := int(local_x / cell_size)
	var gz := int(local_z / cell_size)
	gx = clampi(gx, 0, chunk_cells - 1)
	gz = clampi(gz, 0, chunk_cells - 1)
	var stride := chunk_cells + 1
	var h1 : Array = (_chunks[cz * chunks_x + cx] as Dictionary)["h1"]
	var tl  := gz * stride + gx
	var h00 := h1[tl]           as float
	var h10 := h1[tl + 1]       as float
	var h01 := h1[tl + stride]  as float
	var h11 := h1[tl + stride + 1] as float
	var rx  := fmod(local_x, cell_size) / cell_size
	var rz  := fmod(local_z, cell_size) / cell_size
	if rx + rz <= 1.0:
		return h00 + (h10 - h00) * rx + (h01 - h00) * rz
	else:
		return h11 + (h01 - h11) * (1.0 - rx) + (h10 - h11) * (1.0 - rz)


func _make_chunk(h1: Array, origin: Vector3, mat: Material, flip_normals: bool = false) -> MeshInstance3D:
	var st     := SurfaceTool.new()
	var stride := chunk_cells + 1
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for gz in range(chunk_cells):
		for gx in range(chunk_cells):
			var tl := gz * stride + gx
			if is_nan(h1[tl]) or is_nan(h1[tl+1]) or is_nan(h1[tl+stride]) or is_nan(h1[tl+stride+1]):
				continue
			var v0 := Vector3(gx       * cell_size, h1[tl],          gz       * cell_size)
			var v1 := Vector3((gx+1)   * cell_size, h1[tl+1],        gz       * cell_size)
			var v2 := Vector3(gx       * cell_size, h1[tl+stride],   (gz+1)   * cell_size)
			var v3 := Vector3((gx+1)   * cell_size, h1[tl+stride+1], (gz+1)   * cell_size)
			var u0 := Vector2(float(gx)   / chunk_cells, float(gz)   / chunk_cells)
			var u1 := Vector2(float(gx+1) / chunk_cells, float(gz)   / chunk_cells)
			var u2 := Vector2(float(gx)   / chunk_cells, float(gz+1) / chunk_cells)
			var u3 := Vector2(float(gx+1) / chunk_cells, float(gz+1) / chunk_cells)
			st.set_uv(u0); st.add_vertex(v0)
			st.set_uv(u1); st.add_vertex(v1)
			st.set_uv(u2); st.add_vertex(v2)
			st.set_uv(u1); st.add_vertex(v1)
			st.set_uv(u3); st.add_vertex(v3)
			st.set_uv(u2); st.add_vertex(v2)
	st.generate_normals(flip_normals)
	st.index()
	var mesh := st.commit()
	if mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, mat)
	var mi      := MeshInstance3D.new()
	mi.mesh     = mesh
	mi.position = origin
	# Force a padded AABB so Forward+ doesn't cull flat or near-flat underground meshes
	var aabb := mesh.get_aabb()
	if aabb.size.y < 2.0:
		mi.custom_aabb = AABB(aabb.position + Vector3(0, -1, 0), aabb.size + Vector3(0, 2, 0))
	return mi


# OBB wall from world.bin's box-collider section. The wall_mat shader tiles
# from world-space position/normal (triplanar), so a plain BoxMesh's own UVs
# are irrelevant here — that's what keeps the texture at a consistent scale
# and aligned to each face regardless of the box's size or yaw.
func _make_wall_box(box: Dictionary, ground_y: float) -> MeshInstance3D:
	var height   := box.height as float
	var y_offset := box.get("y_offset", 0.0) as float
	var mesh := BoxMesh.new()
	mesh.size = Vector3((box.half_x as float) * 2.0, height, (box.half_z as float) * 2.0)
	var mat: ShaderMaterial = _wall_mats.get(box.type as int, _wall_mat_default)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh        = mesh
	# Base sits at ground_y + y_offset (lets a wall float, e.g. act as a
	# ceiling), box center is half its height above that — mirrors the
	# server's top_y = terrain + y_offset + height (world.h/world.cpp).
	mi.position    = Vector3(box.x as float, ground_y + y_offset + height * 0.5, box.z as float)
	mi.rotation.y  = box.rot_y as float
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	return mi



