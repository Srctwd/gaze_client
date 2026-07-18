class_name WorldData
extends RefCounted

const MAGIC        := 0x47574C44  # "GWLD"
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
var _water_rects    : Array = []
var _biomes         : Array = []  # [{id, name, material, props[]}]
var _prop_types     : Array = []
var _prop_instances : Array = []
var _holes          : Array = []
var _material      : Material
var _mat_cave      : ShaderMaterial
var _mat_cave_floor: ShaderMaterial
var _tree_scene            : PackedScene = null
var _rock_scene            : PackedScene = null
var _frozenstarlight_scene : PackedScene = null


func load(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("WorldData: cannot open " + path)
		return false

	var first := f.get_32()
	var static_offset: int
	if first == MAGIC:
		chunk_cells   = f.get_32()
		chunks_x      = f.get_32()
		chunks_z      = f.get_32()
		cell_size     = f.get_float()
		var raw_ocx   := f.get_32()
		var raw_ocz   := f.get_32()
		static_offset = f.get_32()
		origin_cx = raw_ocx if raw_ocx < 0x80000000 else int(raw_ocx) - 0x100000000
		origin_cz = raw_ocz if raw_ocz < 0x80000000 else int(raw_ocz) - 0x100000000
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

	var has_biome := (first == MAGIC)

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

	_water_rects.clear()
	if not f.eof_reached():
		var wcount := f.get_32()
		for _i in range(wcount):
			_water_rects.append({
				"x": f.get_float(), "z": f.get_float(),
				"width": f.get_float(), "depth": f.get_float(), "y": f.get_float()
			})

	_biomes.clear()
	if not f.eof_reached():
		var bcount := f.get_8()
		for _bi in range(bcount):
			var bid   := f.get_8()
			var n     := f.get_8(); var bname := f.get_buffer(n).get_string_from_utf8() if n > 0 else ""
			n = f.get_8(); var bmat  := f.get_buffer(n).get_string_from_utf8() if n > 0 else ""
			var pc    := f.get_8()
			var bprops: Array[String] = []
			for _pi in range(pc):
				n = f.get_8(); bprops.append(f.get_buffer(n).get_string_from_utf8() if n > 0 else "")
			# spawner fields (not used on client — read to advance position)
			var bst  := f.get_8(); var bsi := f.get_float()
			var bsm  := f.get_8(); var bsp := f.get_float()
			_biomes.append({ "id": bid, "name": bname, "material": bmat, "props": bprops,
				"spawn_type": bst, "spawn_interval": bsi, "spawn_max": bsm, "spawn_prob": bsp })

	_prop_types.clear()
	_prop_instances.clear()
	if not f.eof_reached():
		var ptcount := f.get_8()
		for _pti in range(ptcount):
			var pn := f.get_8(); _prop_types.append(f.get_buffer(pn).get_string_from_utf8() if pn > 0 else "")
	if not f.eof_reached():
		var picount := f.get_32()
		for _pii in range(picount):
			_prop_instances.append({
				"type_idx": f.get_8(),
				"x": f.get_float(), "y": f.get_float(), "z": f.get_float(),
				"rot_y": f.get_float(),
				"sx": f.get_float(), "sy": f.get_float(), "sz": f.get_float()
			})

	f.close()

	_holes = _find_holes()
	_material      = WorldShaders.surface_mat(Color(0.35, 0.52, 0.28), _holes)
	_mat_cave       = WorldShaders.cave_mat(Color(0.40, 0.33, 0.25))
	_mat_cave_floor = WorldShaders.cave_mat(Color(0.30, 0.20, 0.13))
	_tree_scene           = load("res://assets/tree01.glb")
	_rock_scene           = load("res://assets/rock01.glb")
	_frozenstarlight_scene = load("res://assets/frozenstarlight.glb")
	return true


func spawn_into(parent: Node3D) -> void:
	var ox := world_ox
	var oz := world_oz
	var biome_mat_cache: Dictionary = {}

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
				biome_mat_cache[biome_id] = WorldShaders.biome_surface_mat(biome_id, _holes, _biomes)
			chunk_mat = biome_mat_cache[biome_id] as Material

		parent.add_child(_make_chunk(_chunks[i].h1, origin, chunk_mat))
		if _chunks[i].type == 2:
			parent.add_child(_make_chunk(_chunks[i].h2, origin, _mat_cave))
			parent.add_child(_make_chunk(_chunks[i].h3, origin, _mat_cave))

	for obj in _static_objects:
		var wy   := _get_height_at(obj.x, obj.z)
		var node : Node3D
		var sc   : float
		if obj.type == 2:
			if _frozenstarlight_scene == null: continue
			node = _frozenstarlight_scene.instantiate() as Node3D
			sc   = (obj.radius as float) / 1.5
		elif obj.type == 0:
			if _tree_scene == null: continue
			node = _tree_scene.instantiate() as Node3D
			sc   = (obj.radius as float) / 2.0
		else:
			if _rock_scene == null: continue
			node = _rock_scene.instantiate() as Node3D
			sc   = (obj.radius as float) / 1.0
		node.position = Vector3(obj.x, wy, obj.z)
		node.scale    = Vector3.ONE * sc
		parent.add_child(node)

	var water_mat := WorldShaders.water_mat()
	for wr in _water_rects:
		var plane := PlaneMesh.new()
		plane.size = Vector2(wr.width as float, wr.depth as float)
		plane.surface_set_material(0, water_mat)
		var mi := MeshInstance3D.new()
		mi.mesh     = plane
		mi.position = Vector3(wr.x as float, wr.y as float, wr.z as float)
		parent.add_child(mi)

	var prop_cache: Dictionary = {}
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


func _find_holes() -> Array:
	var holes  := []
	var ox     := world_ox
	var oz     := world_oz
	var stride := chunk_cells + 1

	for i in range(_chunks.size()):
		var cx       := i % chunks_x
		var cz       := int(i / chunks_x)
		var chunk_ox := ox + cx * chunk_cells * cell_size
		var chunk_oz := oz + cz * chunk_cells * cell_size
		var h: Array = (_chunks[i] as Dictionary)["h1"]

		var nan_pts := PackedVector2Array()
		for vz in range(stride):
			for vx in range(stride):
				if is_nan(h[vz * stride + vx]):
					nan_pts.append(Vector2(chunk_ox + vx * cell_size, chunk_oz + vz * cell_size))

		if nan_pts.is_empty(): continue

		var center := Vector2.ZERO
		for p in nan_pts: center += p
		center /= nan_pts.size()

		var radius := 0.0
		for p in nan_pts: radius = maxf(radius, center.distance_to(p))
		radius += cell_size

		holes.append({ "center": center, "radius": radius })

	return holes



