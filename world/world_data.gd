class_name WorldData
extends RefCounted

const MAGIC        := 0x47574C44  # "GWLD" - legacy, biome props have no weight
const MAGIC_W      := 0x47574C32  # "GWL2" - biome props are (path, weight)
const MAGIC_B      := 0x47574C33  # "GWL3" - adds a box-collider section (OBB walls)
# "GWL4" - identical to GWL3 except each biome's spawner field is a pascal
# string (monster name, resolved server-side via name_to_type()) instead of a
# raw u8 monster id — not used on client either way, just read to advance
# the cursor correctly.
const MAGIC_G      := 0x47574C34
# "GWL5" - identical to GWL4 except each water rect carries 1 extra trailing
# field (is_waterfall: u8). Gameplay-wise this is still a normal flat
# WaterRect placed exactly like any other (same x/z/width/depth/y); when set,
# this client instead samples the terrain heightmap under the rect's
# footprint to find the lowest point and renders a box volume from y down to
# it, so it always reaches the ground however steep the slope is there.
const MAGIC_F      := 0x47574C35
# "GWL6" - identical to GWL5 except each wall record is followed by a u8
# opening count and that many carved openings (6 floats each: x/y/z min/max
# in the wall's local frame, y = 0 at the wall's base). Rendered by slicing
# the wall into whatever solid boxes remain — see _carve_wall_pieces().
const MAGIC_O      := 0x47574C36
const WorldShaders  = preload("res://world/world_shaders.gd")

# Preloaded so the exporter includes them (paths come from world.bin at runtime)
const _PRELOAD_FERN01   = preload("res://assets/meshes/fern01.glb")
const _PRELOAD_FERN02   = preload("res://assets/meshes/fern02.glb")
const _PRELOAD_GRASS_BUSH_SMALL = preload("res://assets/meshes/stylized_grass_bush_small.glb")

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
var _static_boxes   : Array = []  # OBB walls: {type, x, z, half_x, half_z, rot_y, height, y_offset, openings}
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
var _biome_mat_cache : Dictionary = {}  # biome id -> Material, shared by every streamed chunk
var _prop_cache      : Dictionary = {}  # prop path -> PackedScene
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
	if first == MAGIC or first == MAGIC_W or first == MAGIC_B or first == MAGIC_G or first == MAGIC_F or first == MAGIC_O:
		chunk_cells   = f.get_32()
		chunks_x      = f.get_32()
		chunks_z      = f.get_32()
		cell_size     = f.get_float()
		var raw_ocx   := f.get_32()
		var raw_ocz   := f.get_32()
		static_offset = f.get_32()
		origin_cx = raw_ocx if raw_ocx < 0x80000000 else int(raw_ocx) - 0x100000000
		origin_cz = raw_ocz if raw_ocz < 0x80000000 else int(raw_ocz) - 0x100000000
		if first == MAGIC_B or first == MAGIC_G or first == MAGIC_F or first == MAGIC_O:
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

	var has_biome := (first == MAGIC or first == MAGIC_W or first == MAGIC_B or first == MAGIC_G or first == MAGIC_F or first == MAGIC_O)
	var has_prop_weight := (first == MAGIC_W or first == MAGIC_B or first == MAGIC_G or first == MAGIC_F or first == MAGIC_O)
	var has_boxes := (first == MAGIC_B or first == MAGIC_G or first == MAGIC_F or first == MAGIC_O)
	var has_waterfall := (first == MAGIC_F or first == MAGIC_O)
	var has_openings := (first == MAGIC_O)

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
			var wr := {
				"x": f.get_float(), "z": f.get_float(),
				"width": f.get_float(), "depth": f.get_float(), "y": f.get_float(),
				"is_waterfall": false,
			}
			if has_waterfall:
				wr.is_waterfall = f.get_8() != 0
			_water_rects.append(wr)

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
			# spawner fields (not used on client — read to advance position).
			# GWL4 re-encodes the monster-id field as a pascal string (the
			# monster's name, resolved server-side via name_to_type()) instead
			# of a raw u8 id — everything else about the biome record is
			# unchanged from GWL3.
			var bst
			if first == MAGIC_G or first == MAGIC_F or first == MAGIC_O:
				n = f.get_8(); bst = f.get_buffer(n).get_string_from_utf8() if n > 0 else ""
			else:
				bst = f.get_8()
			var bsi := f.get_float()
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
			var openings: Array = []
			if has_openings:
				var ocount := f.get_8()
				for _oi in range(ocount):
					openings.append({
						"x_min": f.get_float(), "x_max": f.get_float(),
						"y_min": f.get_float(), "y_max": f.get_float(),
						"z_min": f.get_float(), "z_max": f.get_float(),
					})
			_static_boxes.append({ "type": btype, "x": bx, "z": bz,
				"half_x": bhalf_x, "half_z": bhalf_z, "rot_y": brot_y, "height": bheight,
				"y_offset": byoffset, "openings": openings })

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


# Terrain is streamed per chunk (see terrain.gd): build_chunk_arrays() does
# the pure-data mesh/collider work and is safe to run on a worker thread;
# make_chunk_node() turns its result into nodes on the main thread. Only the
# non-terrain content below (static objects, walls, water, placed props) is
# spawned up front — it's small, and gameplay code (is_in_water,
# nearest_static_object) reads it world-wide anyway.
func chunk_coords_at(wx: float, wz: float) -> Vector2i:
	var size := chunk_cells * cell_size
	return Vector2i(floori((wx - world_ox) / size), floori((wz - world_oz) / size))


func chunk_index(c: Vector2i) -> int:
	if c.x < 0 or c.y < 0 or c.x >= chunks_x or c.y >= chunks_z: return -1
	return c.y * chunks_x + c.x


# Worker-thread safe: only reads the (already stitched, never mutated again)
# height arrays and returns fresh packed arrays — no nodes, resources or
# server calls. Keys: "h1"/"h2"/"h3" -> mesh arrays (h2/h3 only for caves),
# plus "h1_heightmap" -> PackedFloat32Array when the floor has no holes and
# can use a cheap HeightMapShape3D instead of a trimesh collider.
func build_chunk_arrays(i: int) -> Dictionary:
	var chunk := _chunks[i] as Dictionary
	var out := { "h1": _build_mesh_arrays(chunk.h1) }
	if chunk.type == 2:
		out["h2"] = _build_mesh_arrays(chunk.h2)
		out["h3"] = _build_mesh_arrays(chunk.h3)
	var h1: Array = chunk.h1
	var hm := PackedFloat32Array(); hm.resize(h1.size())
	var inv := 1.0 / cell_size
	for j in range(h1.size()):
		var h: float = h1[j]
		if is_nan(h):
			hm = PackedFloat32Array()
			break
		hm[j] = h * inv
	if not hm.is_empty():
		out["h1_heightmap"] = hm
	return out


# Main thread: meshes + colliders + scattered biome props for chunk `i`, all
# under one Node3D so unloading the chunk is a single queue_free().
func make_chunk_node(i: int, arrays: Dictionary) -> Node3D:
	var cx := i % chunks_x
	var cz := int(i / chunks_x)
	var origin := Vector3(world_ox + cx * chunk_cells * cell_size, 0.0, world_oz + cz * chunk_cells * cell_size)
	var biome_id := _chunks[i].get("biome", 0) as int

	var chunk_mat: Material
	if _biomes.is_empty():
		chunk_mat = _material
	else:
		if not _biome_mat_cache.has(biome_id):
			_biome_mat_cache[biome_id] = WorldShaders.biome_surface_mat(biome_id, _biomes)
		chunk_mat = _biome_mat_cache[biome_id] as Material

	var node := Node3D.new()
	node.name = "Chunk_%d_%d" % [cx, cz]
	var floor_mi := _make_chunk(arrays.h1, origin, chunk_mat)
	floor_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	if arrays.has("h1_heightmap"):
		node.add_child(_with_heightmap_collision(floor_mi, arrays.h1_heightmap))
	else:
		node.add_child(_with_collision(floor_mi))
	if arrays.has("h2"):
		var ceil_mi := _make_chunk(arrays.h2, origin, _mat_cave)
		ceil_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
		node.add_child(_with_collision(ceil_mi))
		node.add_child(_with_collision(_make_chunk(arrays.h3, origin, _mat_cave_floor)))

	# Seeded per chunk so a chunk scatters the same props every time it
	# streams back in, instead of reshuffling whenever the player returns.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(cx + origin_cx, cz + origin_cz))
	_scatter_biome_props(biome_id, origin, _prop_cache, node, rng)
	return node


func spawn_static(parent: Node3D) -> void:
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
		parent.add_child(_with_cylinder_collision(node, obj.radius as float, obj.height as float))

	for wb in _static_boxes:
		var wy := _get_height_at(wb.x as float, wb.z as float)
		if is_nan(wy): wy = 0.0
		for piece in _carve_wall_pieces(wb):
			parent.add_child(_with_collision(_make_wall_box(wb, piece, wy)))

	var water_mat := WorldShaders.water_mat()
	for wr in _water_rects:
		if wr.get("is_waterfall", false):
			parent.add_child(_make_waterfall_volume(wr, water_mat))
			continue
		var plane := PlaneMesh.new()
		var mi := MeshInstance3D.new()
		plane.size = Vector2(wr.width as float, wr.depth as float)
		plane.surface_set_material(0, water_mat)
		mi.mesh     = plane
		mi.position = Vector3(wr.x as float, wr.y as float, wr.z as float)
		parent.add_child(mi)

	for pi_ in _prop_instances:
		var pd    := pi_ as Dictionary
		var tidx  := pd["type_idx"] as int
		if tidx < 0 or tidx >= _prop_types.size(): continue
		var path  := _prop_types[tidx] as String
		if not _prop_cache.has(path):
			_prop_cache[path] = load(path) as PackedScene
		var sc := _prop_cache[path] as PackedScene
		if sc == null: continue
		var inst := sc.instantiate() as Node3D
		inst.position   = Vector3(pd["x"] as float, pd["y"] as float, pd["z"] as float)
		inst.rotation.y = pd["rot_y"] as float
		inst.scale      = Vector3(pd["sx"] as float, pd["sy"] as float, pd["sz"] as float)
		parent.add_child(inst)


func _randomize_prop_transform(inst: Node3D, rng: RandomNumberGenerator) -> void:
	inst.rotation.y = rng.randf() * TAU
	var base := rng.randf_range(_PROP_SCALE_MIN, _PROP_SCALE_MAX)
	var wide := base * rng.randf_range(1.0 - _PROP_STRETCH, 1.0 + _PROP_STRETCH)
	var tall := base * rng.randf_range(1.0 - _PROP_STRETCH, 1.0 + _PROP_STRETCH)
	var deep := base * rng.randf_range(1.0 - _PROP_STRETCH, 1.0 + _PROP_STRETCH)
	inst.scale = Vector3(wide, tall, deep)


func _pick_weighted_prop(bprops: Array, bweights: Array, rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for w in bweights:
		total += w as float
	if total <= 0.0:
		return bprops[rng.randi() % bprops.size()] as String

	var roll := rng.randf() * total
	for i in range(bprops.size()):
		roll -= bweights[i] as float
		if roll <= 0.0:
			return bprops[i] as String
	return bprops[bprops.size() - 1] as String


func _scatter_biome_props(biome_id: int, origin: Vector3, prop_cache: Dictionary, parent: Node3D, rng: RandomNumberGenerator) -> void:
	if not _biomes_by_id.has(biome_id):
		return
	var biome := _biomes_by_id[biome_id] as Dictionary
	var bprops: Array = biome.get("props", [])
	if bprops.is_empty():
		return
	var bweights: Array = biome.get("prop_weights", [])

	var chunk_size := chunk_cells * cell_size
	var count := rng.randi_range(_PROP_SCATTER_MIN, _PROP_SCATTER_MAX)

	# Stratified jittered grid: one prop per cell so placements stay evenly
	# spread and never land on top of each other, instead of pure random XZ.
	var cols    := int(ceil(sqrt(float(count))))
	var rows    := int(ceil(float(count) / float(cols)))
	var cell_w  := chunk_size / cols
	var cell_h  := chunk_size / rows

	for idx in range(count):
		var gx := idx % cols
		var gz := int(idx / cols)

		var prop_path := _pick_weighted_prop(bprops, bweights, rng)
		if not prop_cache.has(prop_path):
			prop_cache[prop_path] = load(prop_path) as PackedScene
		var sc := prop_cache[prop_path] as PackedScene
		if sc == null:
			continue

		var jitter_x := rng.randf_range(-_PROP_CELL_JITTER, _PROP_CELL_JITTER) * cell_w
		var jitter_z := rng.randf_range(-_PROP_CELL_JITTER, _PROP_CELL_JITTER) * cell_h
		var wx := origin.x + (gx + 0.5) * cell_w + jitter_x
		var wz := origin.z + (gz + 0.5) * cell_h + jitter_z
		var wy := _get_height_at(wx, wz)
		if is_nan(wy):
			continue

		var inst := sc.instantiate() as Node3D
		inst.position = Vector3(wx, wy, wz)
		_randomize_prop_transform(inst, rng)
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


# A waterfall WaterRect is placed exactly like a normal lake (same flat
# x/z/width/depth/y) — this is what makes it "always fit": instead of storing
# a guessed drop height, we sample the real terrain heightmap across the
# rect's own footprint to find how low the ground actually goes there, and
# stretch a box down to it. Axis-aligned by design (no rotation), so this is
# just a min() over a small sample grid, not a full terrain-following mesh.
const _WATERFALL_SAMPLES := 5

func _make_waterfall_volume(wr: Dictionary, mat: Material) -> MeshInstance3D:
	var x      := wr.x as float
	var z      := wr.z as float
	var width  := wr.width as float
	var depth  := wr.depth as float
	var top_y  := wr.y as float

	var min_y := top_y
	for i in range(_WATERFALL_SAMPLES):
		var sx := x - width * 0.5 + width * (float(i) / (_WATERFALL_SAMPLES - 1))
		for j in range(_WATERFALL_SAMPLES):
			var sz := z - depth * 0.5 + depth * (float(j) / (_WATERFALL_SAMPLES - 1))
			var h := _get_height_at(sx, sz)
			if not is_nan(h):
				min_y = minf(min_y, h)

	var drop := maxf(top_y - min_y, 0.1)
	var box := BoxMesh.new()
	box.size = Vector3(width, drop, depth)
	box.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh     = box
	mi.position = Vector3(x, top_y - drop * 0.5, z)
	return mi


# Dedicated physics layer for terrain/wall colliders (see _with_collision) —
# nothing else in the client sets collision_layer/collision_mask explicitly
# today, so entity StaticBody3Ds (player/monster) stay on the untouched
# default layer 1 and can't be hit by anything querying this layer.
const COLLISION_LAYER_WORLD := 2

# Wraps `mesh_instance` in a StaticBody3D whose collision shape is derived
# directly from the mesh's own triangles (Mesh.create_trimesh_shape()) — so
# the collider is definitionally identical to what's rendered, including
# chunk-border stitching and cave floor/ceiling surfaces, with no separate
# geometry to keep in sync. Used so a free-aim projectile's client-side visual
# (see game/free_aim_projectile.gd) can raycast against real terrain/walls
# instead of always flying through them.
#
# create_trimesh_shape() bakes the mesh's raw LOCAL vertex data, with no
# knowledge of mesh_instance's own position/rotation — so the wrapper body
# has to take on that transform itself (and mesh_instance reset to identity)
# for the shape and the render mesh to end up at the same place; parenting
# both under an identity-transform body would leave every non-origin
# chunk/wall's collider sitting at world (0,0,0).
func _with_collision(mesh_instance: MeshInstance3D) -> Node3D:
	var mesh := mesh_instance.mesh
	if mesh == null or mesh.get_surface_count() == 0:
		return mesh_instance
	var shape := mesh.create_trimesh_shape()
	if shape == null:
		return mesh_instance
	var body := StaticBody3D.new()
	body.collision_layer = COLLISION_LAYER_WORLD
	body.collision_mask  = 0
	body.transform = mesh_instance.transform
	mesh_instance.transform = Transform3D.IDENTITY
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	body.add_child(mesh_instance)
	return body


# Same as _with_collision(), but for a hole-free floor layer: a
# HeightMapShape3D builds in well under a millisecond where the equivalent
# trimesh takes ~13 ms, which matters now that chunks stream in mid-game.
# The shape is centered on its own origin with 1-unit spacing, so it's
# scaled uniformly by cell_size (heights were pre-divided by cell_size in
# build_chunk_arrays to compensate) and shifted to the chunk's center.
func _with_heightmap_collision(mesh_instance: MeshInstance3D, heights: PackedFloat32Array) -> Node3D:
	var stride := chunk_cells + 1
	var shape := HeightMapShape3D.new()
	shape.map_width = stride
	shape.map_depth = stride
	shape.map_data  = heights
	var body := StaticBody3D.new()
	body.collision_layer = COLLISION_LAYER_WORLD
	body.collision_mask  = 0
	body.position = mesh_instance.position
	mesh_instance.position = Vector3.ZERO
	var half := chunk_cells * cell_size * 0.5
	var cs := CollisionShape3D.new()
	cs.shape    = shape
	cs.position = Vector3(half, 0.0, half)
	cs.scale    = Vector3.ONE * cell_size
	body.add_child(cs)
	body.add_child(mesh_instance)
	return body


# Static objects (trees/rocks) get a simple grounded cylinder collider sized
# from the same radius/height already used for their visual scale, mirroring
# how the server represents them (StaticCollider: a plain radius+height
# cylinder) — rather than deriving an exact trimesh, since `node` here is an
# arbitrary imported prop scene, not a single mesh we control.
func _with_cylinder_collision(node: Node3D, radius: float, height: float) -> Node3D:
	if radius <= 0.0:
		return node
	var body := StaticBody3D.new()
	body.collision_layer = COLLISION_LAYER_WORLD
	body.collision_mask  = 0
	body.position = node.position
	node.position = Vector3.ZERO
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var cs := CollisionShape3D.new()
	cs.shape = shape
	# Cylinder is centered on its own origin; body sits at ground level (node's
	# original position), so lift the shape to span [ground, ground + height],
	# matching the server's top_y = ground + height convention.
	cs.position.y = height * 0.5
	body.add_child(cs)
	body.add_child(node)
	return body


# Indexed grid mesh straight from a chunk's height layer — same vertices,
# winding and smooth (area-weighted) normals SurfaceTool.generate_normals()
# produced, but filled into packed arrays directly, which is ~2x faster and,
# unlike SurfaceTool, fine to run off the main thread. Quads touching a NaN
# height (holes, cave edges) are skipped; the NaN vertex itself is zeroed so
# it can't poison the AABB, and is never referenced by an index.
func _build_mesh_arrays(h1: Array, flip_normals: bool = false) -> Array:
	var stride := chunk_cells + 1
	var n      := stride * stride
	var verts  := PackedVector3Array(); verts.resize(n)
	var uvs    := PackedVector2Array(); uvs.resize(n)
	var norms  := PackedVector3Array(); norms.resize(n)
	var inv    := 1.0 / chunk_cells
	for gz in range(stride):
		for gx in range(stride):
			var vi := gz * stride + gx
			var h: float = h1[vi]
			verts[vi] = Vector3(gx * cell_size, 0.0 if is_nan(h) else h, gz * cell_size)
			uvs[vi]   = Vector2(gx * inv, gz * inv)
	var idx := PackedInt32Array(); idx.resize(chunk_cells * chunk_cells * 6)
	var k := 0
	for gz in range(chunk_cells):
		for gx in range(chunk_cells):
			var tl := gz * stride + gx
			var tr := tl + 1; var bl := tl + stride; var br := bl + 1
			if is_nan(h1[tl]) or is_nan(h1[tr]) or is_nan(h1[bl]) or is_nan(h1[br]):
				continue
			idx[k] = tl; idx[k + 1] = tr; idx[k + 2] = bl
			idx[k + 3] = tr; idx[k + 4] = br; idx[k + 5] = bl
			k += 6
			var v0 := verts[tl]; var v1 := verts[tr]; var v2 := verts[bl]; var v3 := verts[br]
			var fa := (v2 - v0).cross(v1 - v0)
			var fb := (v2 - v1).cross(v3 - v1)
			norms[tl] += fa; norms[tr] += fa + fb; norms[bl] += fa + fb; norms[br] += fb
	idx.resize(k)
	var sgn := -1.0 if flip_normals else 1.0
	for vi in range(n):
		norms[vi] = norms[vi].normalized() * sgn
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX]  = idx
	return arr


func _make_chunk(arrays: Array, origin: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	if not (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
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
#
# `piece` is one local-frame sub-box of the wall ({x0,x1,y0,y1,z0,z1}, x/z
# pre-rotation, y = 0 at the wall's base) — the whole wall when it has no
# openings, otherwise one of the solid pieces from _carve_wall_pieces().
func _make_wall_box(box: Dictionary, piece: Dictionary, ground_y: float) -> MeshInstance3D:
	var y_offset := box.get("y_offset", 0.0) as float
	var rot_y    := box.rot_y as float
	var px0 := piece.x0 as float; var px1 := piece.x1 as float
	var py0 := piece.y0 as float; var py1 := piece.y1 as float
	var pz0 := piece.z0 as float; var pz1 := piece.z1 as float
	var mesh := BoxMesh.new()
	mesh.size = Vector3(px1 - px0, py1 - py0, pz1 - pz0)
	var mat: ShaderMaterial = _wall_mats.get(box.type as int, _wall_mat_default)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh        = mesh
	# Base sits at ground_y + y_offset (lets a wall float, e.g. act as a
	# ceiling) — mirrors the server's top_y = terrain + y_offset + height
	# (world.h/world.cpp). The piece's local center is rotated by the wall's
	# yaw the same way Node3D.rotation.y rotates its own local axes.
	var lx := (px0 + px1) * 0.5; var lz := (pz0 + pz1) * 0.5
	var cr := cos(rot_y); var sr := sin(rot_y)
	mi.position    = Vector3((box.x as float) + lx * cr + lz * sr,
		ground_y + y_offset + (py0 + py1) * 0.5,
		(box.z as float) - lx * sr + lz * cr)
	mi.rotation.y  = rot_y
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	return mi


# Splits a wall into the solid local-frame boxes left after subtracting each
# of its openings — the same AABB-minus-AABB "picture frame" slicing
# world_editor's _carve_box_list() uses, so a window/door renders (and
# collides, via _with_collision) as a real hole without a CSG boolean.
func _carve_wall_pieces(box: Dictionary) -> Array:
	var hx := box.half_x as float; var hz := box.half_z as float
	var pieces: Array = [{ "x0": -hx, "x1": hx, "y0": 0.0, "y1": box.height as float, "z0": -hz, "z1": hz }]
	for op: Dictionary in box.get("openings", []):
		var ox0 := op.x_min as float; var ox1 := op.x_max as float
		var oy0 := op.y_min as float; var oy1 := op.y_max as float
		var oz0 := op.z_min as float; var oz1 := op.z_max as float
		var result: Array = []
		for b: Dictionary in pieces:
			var bx0 := b.x0 as float; var bx1 := b.x1 as float
			var by0 := b.y0 as float; var by1 := b.y1 as float
			var bz0 := b.z0 as float; var bz1 := b.z1 as float
			var ix0 := maxf(bx0, ox0); var ix1 := minf(bx1, ox1)
			var iy0 := maxf(by0, oy0); var iy1 := minf(by1, oy1)
			var iz0 := maxf(bz0, oz0); var iz1 := minf(bz1, oz1)
			if ix0 >= ix1 or iy0 >= iy1 or iz0 >= iz1:
				result.append(b)
				continue
			if ix0 > bx0: result.append({ "x0": bx0, "x1": ix0, "y0": by0, "y1": by1, "z0": bz0, "z1": bz1 })
			if ix1 < bx1: result.append({ "x0": ix1, "x1": bx1, "y0": by0, "y1": by1, "z0": bz0, "z1": bz1 })
			if iz0 > bz0: result.append({ "x0": ix0, "x1": ix1, "y0": by0, "y1": by1, "z0": bz0, "z1": iz0 })
			if iz1 < bz1: result.append({ "x0": ix0, "x1": ix1, "y0": by0, "y1": by1, "z0": iz1, "z1": bz1 })
			if iy0 > by0: result.append({ "x0": ix0, "x1": ix1, "y0": by0, "y1": iy0, "z0": iz0, "z1": iz1 })
			if iy1 < by1: result.append({ "x0": ix0, "x1": ix1, "y0": iy1, "y1": by1, "z0": iz0, "z1": iz1 })
		pieces = result
	return pieces
