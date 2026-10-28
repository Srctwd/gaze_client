class_name WorldData
extends RefCounted

const MAGIC := 0x47574C36  # "GWL6"
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
# Wall type id -> jitter scale, from wall_types.json's "jitter" (1 = the full
# _WALL_JITTER / _WALL_JITTER_Y, 0 = flat, e.g. cut marble). Missing = 1.
var _wall_jitter      : Dictionary = {}
var _wall_mat_default : ShaderMaterial
# Wall type id -> {scene, aabb} for types drawn as a model instead of a
# textured box (wall_types.json "mesh", e.g. the ladder) — see _spawn_wall_prop.
var _wall_props       : Dictionary = {}
# Static object type id -> {mesh, scale_ratio, collision_ratio, resource}.
# From object_types.json — the same file the server sizes its colliders with
# (col_r = radius * collision_ratio), so both agree — like walls above.
# world.bin's trailing static-type table only fills in ids the JSON lacks.
# An id in neither falls back to _FALLBACK_PATH instead of the wrong mesh/scale.
const _OBJECT_TYPES_PATH := "res://object_types.json"
var _static_type_defs : Dictionary = {}


func load(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("WorldData: cannot open " + path)
		return false

	if f.get_32() != MAGIC:
		push_error("WorldData: unsupported world format in " + path + " — only GWL6 is supported")
		f.close()
		return false
	chunk_cells       = f.get_32()
	chunks_x          = f.get_32()
	chunks_z          = f.get_32()
	cell_size         = f.get_float()
	var raw_ocx       := f.get_32()
	var raw_ocz       := f.get_32()
	var static_offset := f.get_32()
	var box_offset    := f.get_32()
	origin_cx = raw_ocx if raw_ocx < 0x80000000 else int(raw_ocx) - 0x100000000
	origin_cz = raw_ocz if raw_ocz < 0x80000000 else int(raw_ocz) - 0x100000000
	world_ox = origin_cx * chunk_cells * cell_size
	world_oz = origin_cz * chunk_cells * cell_size

	var total  := chunks_x * chunks_z
	var stride := chunk_cells + 1
	var cells  := stride * stride

	var types   : Array[int] = []
	var biomes_ : Array[int] = []
	var offsets : Array[int] = []

	for i in range(total):
		types.append(f.get_8())
		biomes_.append(f.get_8())
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

	# Each of the sections below is optional/trailing. A plain eof_reached()
	# check isn't enough on its own, since the file doesn't end after the last
	# trailing section: it ends after the box section, appended past all of
	# these. Without also checking against box_offset, a missing table (e.g.
	# no static-type-defs on this file) gets misread from the box section's
	# own leading bytes instead of being skipped, corrupting _static_type_defs
	# and sending every static object down the _fallback_scene path.
	_water_rects.clear()
	if not f.eof_reached() and f.get_position() < box_offset:
		var wcount := f.get_32()
		for _i in range(wcount):
			var wr := {
				"x": f.get_float(), "z": f.get_float(),
				"width": f.get_float(), "depth": f.get_float(), "y": f.get_float(),
				"is_waterfall": f.get_8() != 0,
			}
			_water_rects.append(wr)

	_biomes.clear()
	if not f.eof_reached() and f.get_position() < box_offset:
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
				bweights.append(f.get_float())
			# spawner fields (not used on client — read to advance position)
			n = f.get_8(); var bst := f.get_buffer(n).get_string_from_utf8() if n > 0 else ""
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
	if not f.eof_reached() and f.get_position() < box_offset:
		var ptcount := f.get_8()
		for _pti in range(ptcount):
			var pn := f.get_8(); _prop_types.append(f.get_buffer(pn).get_string_from_utf8() if pn > 0 else "")
	if not f.eof_reached() and f.get_position() < box_offset:
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
	if not f.eof_reached() and f.get_position() < box_offset:
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
	if box_offset > 0:
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
	_mat_cave_floor = WorldShaders.cave_mat(Color(0.27, 0.23, 0.18))
	_fallback_scene = load(_FALLBACK_PATH)
	_load_wall_types()
	_load_object_types()
	return true


func _load_wall_types() -> void:
	_wall_mats.clear()
	_wall_jitter.clear()
	_wall_props.clear()
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
		_wall_jitter[wid] = float(row.get("jitter", 1.0))
		var mesh_path := row.get("mesh", "") as String
		if not mesh_path.is_empty():
			var scene := load(mesh_path) as PackedScene
			if scene == null:
				push_error("WorldData: wall type %d mesh failed to load: %s" % [wid, mesh_path])
			else:
				var probe := scene.instantiate() as Node3D
				_wall_props[wid] = {"scene": scene, "aabb": _node_aabb(probe, Transform3D.IDENTITY)}
				probe.free()
		var path := row.get("texture", "") as String
		if path.is_empty():
			continue
		var tex: Texture2D = null
		if ResourceLoader.exists(path):
			tex = load(path) as Texture2D
		else:
			# Not imported yet (a texture dropped in while the editor wasn't
			# scanning): read the raw image so the wall still renders.
			var img := Image.load_from_file(path)
			if img != null and not img.is_empty():
				img.generate_mipmaps()
				tex = ImageTexture.create_from_image(img)
		if tex == null:
			push_error("WorldData: wall type %d texture failed to load: %s" % [wid, path])
			continue
		_wall_mats[wid] = WorldShaders.wall_mat(tex)


func _load_object_types() -> void:
	var of := FileAccess.open(_OBJECT_TYPES_PATH, FileAccess.READ)
	if of == null:
		push_error("WorldData: cannot open " + _OBJECT_TYPES_PATH)
		return
	var rows = JSON.parse_string(of.get_as_text())
	if typeof(rows) != TYPE_ARRAY:
		push_error("WorldData: " + _OBJECT_TYPES_PATH + " is not a JSON array")
		return
	for row: Dictionary in rows:
		_static_type_defs[int(row.get("id", 0))] = {
			"mesh":            row.get("mesh", "") as String,
			"scale_ratio":     float(row.get("scale_ratio", 1.0)),
			"collision_ratio": float(row.get("collision_ratio", 1.0)),
			"resource":        null,
		}


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


# Footstep surface at feet position `feet`: "stone" on anything built (a floor,
# stairs, a wall top — feet off the terrain) or down in a cave, otherwise the
# terrain's biome — "grass" when its ground texture is a grass one.
func footstep_surface(feet: Vector3) -> String:
	var ground := _get_height_at(feet.x, feet.z)
	if is_nan(ground) or absf(feet.y - ground) > 0.3:
		return "stone"
	var i := chunk_index(chunk_coords_at(feet.x, feet.z))
	if i < 0:
		return "stone"
	var biome := _biomes_by_id.get((_chunks[i] as Dictionary).get("biome", 0), {}) as Dictionary
	return "grass" if str(biome.get("material", "")).to_lower().contains("grass") else "stone"


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
			_biome_mat_cache[biome_id] = WorldShaders.biome_surface_mat(biome_id, _biomes, chunk_cells * cell_size)
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
		var collision_ratio := 1.0
		if node == null:
			if _fallback_scene == null: continue
			node = _fallback_scene.instantiate() as Node3D
		else:
			scale_ratio     = (_static_type_defs[id] as Dictionary).get("scale_ratio", 1.0) as float
			collision_ratio = (_static_type_defs[id] as Dictionary).get("collision_ratio", 1.0) as float
		node.position = Vector3(obj.x, wy, obj.z)
		# collision_ratio scales the model with its collider (server col_r = radius * ratio).
		# Multiplied onto the scene's own root scale (e.g. a .tscn shrinking its model).
		node.scale    = node.scale * ((obj.radius as float) * collision_ratio / scale_ratio)
		parent.add_child(_with_cylinder_collision(node, (obj.radius as float) * collision_ratio, obj.height as float))

	_spawn_walls(parent)

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


# Wall faces are cut on a grid this size, aligned to the mesh's frame (world
# space for merged walls), plus their own edges. It sets the size of the
# bumps the vertex jitter makes, and staying at or under ps2_mesh.gd's
# PRIMITIVE_CELL means PS2 mode (light and fog per vertex) never has to
# re-tessellate walls itself.
const _WALL_CELL := 1.0
# Every wall vertex moves in world X and Z by up to ± _WALL_JITTER and in Y
# by up to ± _WALL_JITTER_Y, read from smooth noise over world position (see
# _wall_offset) with nodes every _WALL_NOISE_CELL. Each axis's offset ignores
# that axis's own coordinate, so opposite faces of a box (same position but
# for its thickness axis) move identically and can't cross at any thickness
# or jitter size. Y is larger because ceilings are only bumped by it, and
# from below small bumps on a big flat face don't show.
const _WALL_JITTER     := 0.1
const _WALL_JITTER_Y   := 0.15
const _WALL_NOISE_CELL := 1.0
# Merged wall meshes are split on a world grid this size, so a big connected
# group (a maze, a town) is still frustum-culled piece by piece.
const _WALL_TILE   := 32.0
# Cell size of the spatial hash that finds a box's (or corner's) neighbours.
const _WALL_BUCKET := 4.0
# Coordinates closer than this count as equal (float rounding).
const _WALL_EPS    := 1e-4


# OBB walls from world.bin's box-collider section. Each wall gets its own
# StaticBody3D with one BoxShape3D per solid piece (_carve_wall_pieces):
# exactly the server's boxes, solid (a trimesh is hollow, so rays and fast
# bodies starting inside one slip through) and cheap to test.
#
# The visuals are merged: walls of the same type that touch or overlap and
# are turned by a multiple of 90° become one mesh, built from their pieces
# in world space after cutting the overlaps away (_disjoint_boxes). That
# draws each connected room as one mesh per wall type (per _WALL_TILE), and
# leaves out every face buried in a neighbouring wall or lying against it —
# including the coplanar ones at overlapping corners that would otherwise
# flicker. A wall at any other angle keeps its own mesh, in its own frame.
func _spawn_walls(parent: Node3D) -> void:
	var merged: Array[Dictionary] = []   # {type, boxes} per axis-aligned wall, world space
	var jobs: Array[Dictionary] = []     # meshes to build: {boxes, xform, type, parent[, overlapping]}
	for wb in _static_boxes:
		var wy := _get_height_at(wb.x as float, wb.z as float)
		if is_nan(wy): wy = 0.0
		var xform  := _wall_transform(wb, wy)
		var pieces := _carve_wall_pieces(wb)
		var body   := StaticBody3D.new()
		body.collision_layer = COLLISION_LAYER_WORLD
		body.collision_mask  = 0
		body.transform       = xform
		for b in pieces:
			var shape := BoxShape3D.new()
			shape.size = b.size
			var cs := CollisionShape3D.new()
			cs.shape    = shape
			cs.position = b.get_center()
			body.add_child(cs)
		parent.add_child(body)
		if _wall_props.has(wb.type as int):
			for b in pieces:
				_spawn_wall_prop(body, b, _wall_props[wb.type as int])
			continue

		var turn := fposmod(wb.rot_y as float, PI * 0.5)
		if turn < 1e-3 or turn > PI * 0.5 - 1e-3:
			var world: Array[AABB] = []
			for b in pieces:
				# Snapped so walls that meet compute the exact same coordinate.
				var w := xform * b
				world.append(_aabb(w.position.snapped(Vector3.ONE * _WALL_EPS), w.end.snapped(Vector3.ONE * _WALL_EPS)))
			merged.append({"type": wb.type as int, "boxes": world})
		else:   # the mesh is in the body's frame
			jobs.append({"boxes": pieces, "xform": xform, "type": wb.type as int, "parent": body})
	for group in _wall_groups(merged):
		jobs.append({"boxes": group.boxes, "xform": Transform3D.IDENTITY, "type": group.type as int,
			"parent": parent, "overlapping": true})

	for job in jobs:
		job["jitter"] = _wall_jitter.get(job.type, 1.0)
	# Building the meshes is pure data, so every job runs on the worker pool;
	# each writes only its own job's "arrays". The nodes are made back here.
	var task := WorkerThreadPool.add_group_task(func(i: int) -> void:
		var job: Dictionary = jobs[i]
		var boxes: Array[AABB] = _disjoint_boxes(job.boxes) if job.get("overlapping", false) else job.boxes
		job["arrays"] = _wall_mesh_arrays(boxes, job.xform, job.jitter), jobs.size(), -1, true, "wall meshes")
	WorkerThreadPool.wait_for_group_task_completion(task)
	for job in jobs:
		var mat: ShaderMaterial = _wall_mats.get(job.type, _wall_mat_default)
		for arr: Array in job.arrays:
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			mesh.surface_set_material(0, mat)
			var mi := MeshInstance3D.new()
			mi.mesh        = mesh
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
			(job.parent as Node3D).add_child(mi)


# Fills one wall piece (body frame) with copies of a wall type's model: its
# width along the piece's longer side, tiled along that side and up the
# height in whole copies, each stretched to fill its cell; its depth fills
# the shorter side.
func _spawn_wall_prop(parent: Node3D, piece: AABB, prop: Dictionary) -> void:
	var m: AABB = prop.aabb
	if m.size.x <= 0.0 or m.size.y <= 0.0 or m.size.z <= 0.0: return
	var along_x := piece.size.x >= piece.size.z
	var w := piece.size.x if along_x else piece.size.z
	var d := piece.size.z if along_x else piece.size.x
	var nw := maxi(1, roundi(w / m.size.x))
	var nh := maxi(1, roundi(piece.size.y / m.size.y))
	var cell := Vector3(w / nw, piece.size.y / nh, d)
	var turn := Basis.IDENTITY if along_x else Basis(Vector3.UP, PI * 0.5)
	var fit := turn * Basis.from_scale(cell / m.size)
	var side := Vector3.RIGHT if along_x else Vector3.FORWARD
	var start := piece.get_center() - side * (w * 0.5) + Vector3(0.0, -piece.size.y * 0.5, 0.0)
	for i in nw:
		for j in nh:
			var center := start + side * cell.x * (i + 0.5) + Vector3.UP * cell.y * (j + 0.5)
			var inst := (prop.scene as PackedScene).instantiate() as Node3D
			inst.transform = Transform3D(fit, center - fit * m.get_center())
			parent.add_child(inst)


# Bounds of every mesh under `node`, in the frame `xform` maps node's own
# space into (identity for a scene root, whose transform placement replaces).
static func _node_aabb(node: Node, xform: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out = xform * (node as MeshInstance3D).mesh.get_aabb()
		first = false
	for child in node.get_children():
		var a := _node_aabb(child, xform * (child as Node3D).transform if child is Node3D else xform)
		if a.size == Vector3.ZERO: continue
		out = a if first else out.merge(a)
		first = false
	return out


# Base sits at ground_y + y_offset (lets a wall float, e.g. act as a
# ceiling) — mirrors the server's top_y = terrain + y_offset + height
# (world.h/world.cpp).
static func _wall_transform(box: Dictionary, ground_y: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, box.rot_y as float),
		Vector3(box.x as float, ground_y + (box.get("y_offset", 0.0) as float), box.z as float))


# Unions walls (from _spawn_walls' `merged`) of the same type whose pieces
# touch or overlap into {type, boxes} groups.
static func _wall_groups(walls: Array[Dictionary]) -> Array[Dictionary]:
	var root := range(walls.size())
	var find := func(i: int) -> int:
		while root[i] != i:
			root[i] = root[root[i]]
			i = root[i]
		return i
	var boxes: Array[AABB] = []
	var owner := PackedInt32Array()
	for i in walls.size():
		for b: AABB in walls[i].boxes:
			boxes.append(b.grow(1e-3))
			owner.append(i)
	var buckets := {}
	for bi in boxes.size():
		_bucket_add(buckets, boxes[bi], bi)
	for bi in boxes.size():
		var i := owner[bi]
		for oi: int in _bucket_query(buckets, boxes[bi]):
			var j := owner[oi]
			if j != i and walls[i].type == walls[j].type and boxes[bi].intersects(boxes[oi]):
				var ri: int = find.call(i)
				var rj: int = find.call(j)
				if ri != rj:
					root[rj] = ri
	var by_root := {}
	for i in walls.size():
		var r: int = find.call(i)
		if not by_root.has(r):
			by_root[r] = {"type": walls[i].type, "boxes": [] as Array[AABB]}
		(by_root[r].boxes as Array[AABB]).append_array(walls[i].boxes)
	var out: Array[Dictionary] = []
	for g: Dictionary in by_root.values():
		out.append(g)
	return out


# The same solid as `boxes`, as non-overlapping boxes: each box minus every
# box kept before it that it overlaps.
static func _disjoint_boxes(boxes: Array[AABB]) -> Array[AABB]:
	var out: Array[AABB] = []
	var buckets := {}
	for b in boxes:
		var parts: Array[AABB] = [b]
		for oi: int in _bucket_query(buckets, b):
			parts = _subtract_box(parts, out[oi])
			if parts.is_empty():
				break
		for p in parts:
			_bucket_add(buckets, p, out.size())
			out.append(p)
	return out


# Spatial hash: _WALL_BUCKET-sized cells -> indices (or points) in them.
static func _bucket_keys(b: AABB) -> Array[Vector3i]:
	var lo := Vector3i((b.position / _WALL_BUCKET).floor())
	var hi := Vector3i((b.end / _WALL_BUCKET).floor())
	var keys: Array[Vector3i] = []
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			for z in range(lo.z, hi.z + 1):
				keys.append(Vector3i(x, y, z))
	return keys


static func _bucket_add(buckets: Dictionary, b: AABB, item: Variant) -> void:
	for k in _bucket_keys(b):
		if buckets.has(k):
			(buckets[k] as Array).append(item)
		else:
			buckets[k] = [item]


# Indices stored in any cell `b` covers, each once.
static func _bucket_query(buckets: Dictionary, b: AABB) -> Array:
	var seen := {}
	for k in _bucket_keys(b):
		for i in buckets.get(k, []):
			seen[i] = true
	return seen.keys()




# Surface arrays (one per _WALL_TILE of world space) for non-overlapping
# `boxes`, as separate flat-shaded triangles, in the frame `xform` maps to
# world space. Pure data: safe on a worker thread.
#
#  1. Each box face is cut down to the parts no neighbouring box touches (the
#     rest is inside the solid).
#  2. Each remaining face rect is cut on the _WALL_CELL grid of the frame and
#     at its own edges. Grid cells on the rect's border also take every
#     corner of another face rect that lands on that border, and are then
#     fanned from their centre. Both faces along any shared edge therefore
#     have exactly the same vertices on it (no T-junctions), however the
#     boxes are laid out.
#  3. Every vertex moves by _wall_offset() of its world position, times
#     `jitter` (the wall type's, see _wall_jitter). That
#     depends on nothing else, so shared edges stay shut after it, inside a
#     mesh, between tiles and between separate walls' meshes.
#
# UVs are the pre-jitter face coordinates: the wall_mat shader tiles from
# world-space position/normal (triplanar), which is what keeps the texture
# at a consistent scale and aligned to each face regardless of the wall's
# size or yaw.
static func _wall_mesh_arrays(boxes: Array[AABB], xform: Transform3D, jitter := 1.0) -> Array:
	var buckets := {}
	for i in boxes.size():
		_bucket_add(buckets, boxes[i].grow(_WALL_EPS), i)

	var faces := []      # [axis, side, plane, Rect2 in (u, v)]
	var corners := {}    # bucket -> face rect corners in it
	for bi in boxes.size():
		var b := boxes[bi]
		var near := _bucket_query(buckets, b.grow(_WALL_EPS))
		for axis in 3:
			var u := (axis + 1) % 3
			var v := (axis + 2) % 3
			for side in 2:   # 0 = face at the box's min on `axis`, 1 = at its max
				var plane: float = b.end[axis] if side == 1 else b.position[axis]
				var rects: Array[Rect2] = [Rect2(b.position[u], b.position[v], b.size[u], b.size[v])]
				for oi: int in near:
					var o := boxes[oi]
					var touching: float = o.position[axis] if side == 1 else o.end[axis]
					if oi != bi and absf(touching - plane) < _WALL_EPS:
						rects = _subtract_rect(rects, Rect2(o.position[u], o.position[v], o.size[u], o.size[v]))
				for r in rects:
					if r.size.x < _WALL_EPS or r.size.y < _WALL_EPS:
						continue
					faces.append([axis, side, plane, r])
					for c in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
						var p := _face_point(axis, plane, c.x, c.y)
						_bucket_add(corners, AABB(p, Vector3.ZERO), p)

	# _moved_point adds to_local * _wall_offset(), so scaling it by `jitter`
	# scales the offset (0 leaves the vertices where they are).
	var to_local := xform.basis.inverse() * jitter
	var tiles := {}   # Vector2i -> [verts, norms, uvs]
	for f in faces:
		var axis: int = f[0]
		var side: int = f[1]
		var plane: float = f[2]
		var r: Rect2 = f[3]
		var us := _grid_cuts(r.position.x, r.end.x)
		var vs := _grid_cuts(r.position.y, r.end.y)
		# Other faces' corners on this rect's border: bottom/top edges give u
		# values, left/right edges v values.
		var on_v0 := _edge_extras(corners, axis, plane, r, 0)
		var on_v1 := _edge_extras(corners, axis, plane, r, 1)
		var on_u0 := _edge_extras(corners, axis, plane, r, 2)
		var on_u1 := _edge_extras(corners, axis, plane, r, 3)

		var mid := xform * _face_point(axis, plane, r.get_center().x, r.get_center().y)
		var tile := Vector2i(floori(mid.x / _WALL_TILE), floori(mid.z / _WALL_TILE))
		if not tiles.has(tile):
			tiles[tile] = [PackedVector3Array(), PackedVector3Array(), PackedVector2Array()]
		var arrs: Array = tiles[tile]

		# This face's grid points, moved, once for all the cells that share them.
		var nu := us.size()
		var grid := PackedVector3Array()
		for y in vs:
			for x in us:
				grid.append(_moved_point(axis, plane, x, y, xform, to_local))
		var last_i := nu - 2
		var last_j := vs.size() - 2
		for j in last_j + 1:
			for i in last_i + 1:
				var u0 := us[i]; var u1 := us[i + 1]
				var v0 := vs[j]; var v1 := vs[j + 1]
				# Cell outline, counter-clockwise in (u, v): corners from the
				# grid, extra border points moved here (border cells only).
				var pts := PackedVector3Array([grid[j * nu + i]])
				var uv  := PackedVector2Array([Vector2(u0, v0)])
				if j == 0:
					for x in on_v0:
						if x > u0 + _WALL_EPS and x < u1 - _WALL_EPS:
							pts.append(_moved_point(axis, plane, x, v0, xform, to_local)); uv.append(Vector2(x, v0))
				pts.append(grid[j * nu + i + 1]); uv.append(Vector2(u1, v0))
				if i == last_i:
					for y in on_u1:
						if y > v0 + _WALL_EPS and y < v1 - _WALL_EPS:
							pts.append(_moved_point(axis, plane, u1, y, xform, to_local)); uv.append(Vector2(u1, y))
				pts.append(grid[(j + 1) * nu + i + 1]); uv.append(Vector2(u1, v1))
				if j == last_j:
					for k in range(on_v1.size() - 1, -1, -1):
						var x := on_v1[k]
						if x > u0 + _WALL_EPS and x < u1 - _WALL_EPS:
							pts.append(_moved_point(axis, plane, x, v1, xform, to_local)); uv.append(Vector2(x, v1))
				pts.append(grid[(j + 1) * nu + i]); uv.append(Vector2(u0, v1))
				if i == 0:
					for k in range(on_u0.size() - 1, -1, -1):
						var y := on_u0[k]
						if y > v0 + _WALL_EPS and y < v1 - _WALL_EPS:
							pts.append(_moved_point(axis, plane, u0, y, xform, to_local)); uv.append(Vector2(u0, y))
				_emit_wall_cell(arrs, pts, uv, axis, side, plane, xform, to_local)

	var out := []
	for arrs: Array in tiles.values():
		if (arrs[0] as PackedVector3Array).is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = arrs[0]
		arr[Mesh.ARRAY_NORMAL] = arrs[1]
		arr[Mesh.ARRAY_TEX_UV] = arrs[2]
		out.append(arr)
	return out


# _wall_mesh_arrays() as ArrayMeshes (main thread).
static func _wall_meshes(boxes: Array[AABB], xform: Transform3D) -> Array[ArrayMesh]:
	var out: Array[ArrayMesh] = []
	for arr: Array in _wall_mesh_arrays(boxes, xform):
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.append(mesh)
	return out


# Triangulates one grid cell into `arrs`: `pts` (moved) and `uv` (their face
# coordinates) are its outline, counter-clockwise in (u, v), starting at its
# min corner. A plain quad takes the diagonal its first corner's hash picks;
# a cell with extra border points is fanned from its centre.
# Counter-clockwise triangles face -axis, so max-side faces are mirrored.
static func _emit_wall_cell(arrs: Array, pts: PackedVector3Array, uv: PackedVector2Array, axis: int,
		side: int, plane: float, xform: Transform3D, to_local: Basis) -> void:
	var tris: PackedInt32Array
	if pts.size() == 4:   # 0 a, 1 a+u, 2 a+u+v, 3 a+v
		var h := _wall_hash(xform * _face_point(axis, plane, uv[0].x, uv[0].y))
		tris = PackedInt32Array([0, 1, 2, 0, 2, 3]) if (h >> 17) & 1 else PackedInt32Array([0, 1, 3, 1, 2, 3])
	else:
		var n := pts.size()
		var lo := uv[0]
		var hi := uv[0]
		for q in uv:
			lo = lo.min(q)
			hi = hi.max(q)
		var mid := (lo + hi) * 0.5
		uv.append(mid)
		pts.append(_moved_point(axis, plane, mid.x, mid.y, xform, to_local))
		tris = PackedInt32Array()
		for k in n:
			tris.append_array(PackedInt32Array([n, k, (k + 1) % n]))
	var verts: PackedVector3Array = arrs[0]
	var norms: PackedVector3Array = arrs[1]
	var uvs:   PackedVector2Array = arrs[2]
	for t in range(0, tris.size(), 3):
		var k0 := tris[t]
		var k1 := tris[t + 2] if side == 1 else tris[t + 1]
		var k2 := tris[t + 1] if side == 1 else tris[t + 2]
		var nrm := (pts[k2] - pts[k0]).cross(pts[k1] - pts[k0]).normalized()
		verts.append(pts[k0]); verts.append(pts[k1]); verts.append(pts[k2])
		norms.append(nrm); norms.append(nrm); norms.append(nrm)
		uvs.append(uv[k0]); uvs.append(uv[k1]); uvs.append(uv[k2])


# The face point at (u, v), moved by the wall offset of its world position.
static func _moved_point(axis: int, plane: float, u: float, v: float, xform: Transform3D, to_local: Basis) -> Vector3:
	var p := _face_point(axis, plane, u, v)
	return p + to_local * _wall_offset(xform * p)


# The point at (u, v) on the plane `axis` = `plane` (u, v are the next two
# axes, wrapping).
static func _face_point(axis: int, plane: float, u: float, v: float) -> Vector3:
	var p := Vector3.ZERO
	p[axis] = plane
	p[(axis + 1) % 3] = u
	p[(axis + 2) % 3] = v
	return p


# lo, every _WALL_CELL grid line strictly between, hi.
static func _grid_cuts(lo: float, hi: float) -> PackedFloat64Array:
	var out := PackedFloat64Array([lo])
	for k in range(ceili(lo / _WALL_CELL), floori(hi / _WALL_CELL) + 1):
		var x := k * _WALL_CELL
		if x > lo + _WALL_EPS and x < hi - _WALL_EPS:
			out.append(x)
	out.append(hi)
	return out


# Sorted positions of other face rects' corners lying strictly inside one
# edge of `r` (on the plane `axis` = `plane`): edge 0/1 is v = v0/v1 (gives
# u values), edge 2/3 is u = u0/u1 (gives v values).
static func _edge_extras(corners: Dictionary, axis: int, plane: float, r: Rect2, edge: int) -> PackedFloat64Array:
	var along_u := edge < 2
	var fixed: float = [r.position.y, r.end.y, r.position.x, r.end.x][edge]
	var lo: float = r.position.x if along_u else r.position.y
	var hi: float = r.end.x if along_u else r.end.y
	var a := _face_point(axis, plane, lo if along_u else fixed, fixed if along_u else lo)
	var b := _face_point(axis, plane, hi if along_u else fixed, fixed if along_u else hi)
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	var vals := PackedFloat64Array()
	var seen := {}
	for k in _bucket_keys(_aabb(a.min(b), a.max(b)).grow(_WALL_EPS)):
		for p: Vector3 in corners.get(k, []):
			if seen.has(p):
				continue
			seen[p] = true
			if absf(p[axis] - plane) > _WALL_EPS:
				continue
			var pf: float = p[v] if along_u else p[u]
			var pa: float = p[u] if along_u else p[v]
			if absf(pf - fixed) <= _WALL_EPS and pa > lo + _WALL_EPS and pa < hi - _WALL_EPS:
				vals.append(pa)
	vals.sort()
	var out := PackedFloat64Array()
	for x in vals:
		if out.is_empty() or x - out[out.size() - 1] > _WALL_EPS:
			out.append(x)
	return out


# Stable random bits for a world point: the same point gives the same value
# on every face that shares it, on every run and on every client. Picks
# each quad's diagonal.
static func _wall_hash(world: Vector3) -> int:
	return hash(Vector3i((world * 64.0).round()))


# World-space vertex offset: X from the (y, z) position, Y from (x, z) and Z
# from (x, y), each its own 2D value noise (see _wall_noise). Being
# continuous, two walls' copies of a shared corner get the same offset even
# when their transforms round its position a hair differently.
static func _wall_offset(world: Vector3) -> Vector3:
	return Vector3(_wall_noise(world.y, world.z, 0) * _WALL_JITTER,
		_wall_noise(world.x, world.z, 1) * _WALL_JITTER_Y,
		_wall_noise(world.x, world.y, 2) * _WALL_JITTER)


# -1..1: a random value at every _WALL_NOISE_CELL node of the (a, b) plane,
# blended bilinearly between them; `channel` gives each axis its own values.
static func _wall_noise(a: float, b: float, channel: int) -> float:
	var g    := Vector2(a, b) / _WALL_NOISE_CELL
	var base := Vector2i(g.floor())
	var f    := g - Vector2(base)
	var acc  := 0.0
	for k in 4:
		var o := Vector2i(k & 1, k >> 1)
		var w := (f.x if o.x else 1.0 - f.x) * (f.y if o.y else 1.0 - f.y)
		acc += w * float(hash(Vector3i(base.x + o.x, base.y + o.y, channel)) & 0xFFFF) / 65535.0
	return acc * 2.0 - 1.0   # weights sum to 1


# `rects` minus `hole`, as the same picture-frame slicing in 2D.
static func _subtract_rect(rects: Array[Rect2], hole: Rect2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for r in rects:
		var c := r.intersection(hole)
		if not c.has_area():
			out.append(r)
			continue
		if c.position.x > r.position.x: out.append(Rect2(r.position.x, r.position.y, c.position.x - r.position.x, r.size.y))
		if c.end.x < r.end.x:           out.append(Rect2(c.end.x, r.position.y, r.end.x - c.end.x, r.size.y))
		if c.position.y > r.position.y: out.append(Rect2(c.position.x, r.position.y, c.size.x, c.position.y - r.position.y))
		if c.end.y < r.end.y:           out.append(Rect2(c.position.x, c.end.y, c.size.x, r.end.y - c.end.y))
	return out


# Splits a wall into the solid local-frame boxes (x/z pre-rotation, y = 0 at
# the wall's base) left after subtracting each of its openings — the same
# AABB-minus-AABB "picture frame" slicing world_editor's _carve_box_list()
# uses, so a window/door renders and collides as a real hole without a CSG
# boolean.
func _carve_wall_pieces(box: Dictionary) -> Array[AABB]:
	var hx := box.half_x as float; var hz := box.half_z as float
	var pieces: Array[AABB] = [_aabb(Vector3(-hx, 0.0, -hz), Vector3(hx, box.height as float, hz))]
	for op: Dictionary in box.get("openings", []):
		pieces = _subtract_box(pieces, _aabb(
			Vector3(op.x_min as float, op.y_min as float, op.z_min as float),
			Vector3(op.x_max as float, op.y_max as float, op.z_max as float)))
	return pieces


# `pieces` minus `hole`: each piece the hole cuts into is replaced by up to
# six boxes around the cut (x sides, then z, then y). Slivers thinner than
# 1e-4 (float rounding where boxes only touch) are dropped.
static func _subtract_box(pieces: Array[AABB], hole: AABB) -> Array[AABB]:
	var out: Array[AABB] = []
	for b in pieces:
		var c := b.intersection(hole)
		if c.size.x < 1e-4 or c.size.y < 1e-4 or c.size.z < 1e-4:
			out.append(b)
			continue
		var lo := b.position; var hi := b.end
		var clo := c.position; var chi := c.end
		for part in [
				[lo, Vector3(clo.x, hi.y, hi.z)],
				[Vector3(chi.x, lo.y, lo.z), hi],
				[Vector3(clo.x, lo.y, lo.z), Vector3(chi.x, hi.y, clo.z)],
				[Vector3(clo.x, lo.y, chi.z), Vector3(chi.x, hi.y, hi.z)],
				[Vector3(clo.x, lo.y, clo.z), Vector3(chi.x, clo.y, chi.z)],
				[Vector3(clo.x, chi.y, clo.z), Vector3(chi.x, hi.y, chi.z)]]:
			var s: Vector3 = part[1] - part[0]
			if s.x >= 1e-4 and s.y >= 1e-4 and s.z >= 1e-4:
				out.append(AABB(part[0], s))
	return out


static func _aabb(lo: Vector3, hi: Vector3) -> AABB:
	return AABB(lo, hi - lo)
