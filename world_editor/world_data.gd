class_name EditorWorldData
extends RefCounted

const MAGIC    := 0x47574C39  # "GWL9" — GWL8 plus a pillar section (header gains pillar_offset)
const MAGIC_V8 := 0x47574C38  # "GWL8" — still loads; no pillars
const MAGIC_V7 := 0x47574C37  # "GWL7" — still loads; its biome material/spawner fields are skipped
const RampMesh := preload("res://world/ramp_mesh.gd")

# Chunk types. Caves store three terrain sheets (h1/h2/h3), everything else
# just h1. Ocean chunks also get a water rect covering the whole chunk (see
# toggle_ocean_chunk) — that rect is the water sheet the server knows about.
const CHUNK_TERRAIN    := 1
const CHUNK_CAVE       := 2
const CHUNK_OCEAN      := 3
const CHUNK_OCEAN_CAVE := 4

static func is_cave_type(t: int) -> bool:
	return t == CHUNK_CAVE or t == CHUNK_OCEAN_CAVE

static func is_ocean_type(t: int) -> bool:
	return t == CHUNK_OCEAN or t == CHUNK_OCEAN_CAVE

var chunk_cells : int
var chunks_x    : int
var chunks_z    : int
var cell_size   : float
var origin_cx   : int = 0   # grid coord of array column 0
var origin_cz   : int = 0   # grid coord of array row 0
var world_ox    : float = 0.0  # derived: origin_cx * chunk_cells * cell_size
var world_oz    : float = 0.0

var _chunks         : Array = []
var _static_objects : Array = []
var _water_rects    : Array = []  # {x, z, width, depth, y}
var _biomes         : Array = []  # [{id, name, props[]}] — visual only (prop scatter)
var _prop_types     : Array = []  # [String path, ...]
var _prop_instances : Array = []  # [{type_idx, x, y, z, rot_y, sx, sy, sz}]
var _pillars        : Array = []  # [{type, x, z, radius, height, y_offset}] — upright cylinders; base = terrain under the centre + y_offset
var _walls          : Array = []  # [{type, x, z, half_x, half_z, rot_y, height, y_offset, low_height, openings[]}] — OBB wall colliders (low_height >= 0: a ramp, see world/ramp_mesh.gd)
var _chunk_roots    : Array = []
# h1/h2 vertex pairs that move together (cave entrances). Editor-only and
# in-memory: never saved, cleared whenever the chunk array is rebuilt.
# Keyed by grid chunk coord (survives add_chunk_at re-indexing) -> {vertex idx: true}.
var _glue           : Dictionary = {}
# Terrain-mode vertex selection, as absolute vertex indices (vertex_key) ->
# true. When non-empty, the brushes (raise/smooth/fill/hole/snap/glue) only
# touch these vertices; the brush still decides where and how strongly.
var vertex_mask     : Dictionary = {}
const GLUE_OFFSET   := 0.01  # glued h2 sits this far below h1 so the two surfaces don't z-fight
var _parent         : Node3D

# Per-cell terrain textures, in <world>.cells.bin beside the .bin — for the
# client only (the server never reads it). A painted chunk's dictionary gets
# "cells" (one byte per cell, row by row: 0 = its own texture, k =
# cell_palette[k - 1]) and "cells_mat", its material. The file keys chunks by
# grid coord, so a partial load only rewrites its own chunks on save.
const CELLS_MAGIC   := 0x31435747  # "GWC1"
const CELL_TEX_SIZE := 256         # every palette texture is resized to this
const CELL_TEX_MAX  := 64          # terrain_cells.gdshaderinc's cell_tile[] size
const CellsShader   := preload("res://world_editor/terrain_cells_editor.gdshader")
var cell_palette      : Array = []  # [{path, tile}] — tile = metres per texture repeat
var _cell_array       : Texture2DArray
var _cells_source     : String = ""  # cells file load_cells() read, merged into on save
# Old cell value -> current one, since load: removing a palette entry shifts
# the values of chunks not loaded (partial load) too, applied when saving.
var _cell_remap       := PackedByteArray()

var _mat_plains: StandardMaterial3D
var _mat_cave_surface: StandardMaterial3D
var _mat_cave_floor: StandardMaterial3D
var _mat_v_h1: StandardMaterial3D
var _mat_v_h2: StandardMaterial3D
var _mat_v_h3: StandardMaterial3D
var _mat_v_glue: StandardMaterial3D

func _init() -> void:
	_cell_remap.resize(256)
	for v in range(256): _cell_remap[v] = v
	_mat_plains       = _make_mat(Color(0.35, 0.52, 0.28))
	_mat_cave_surface = _make_mat(Color(0.30, 0.28, 0.25))
	_mat_cave_floor   = _make_mat(Color(0.25, 0.22, 0.20))
	_mat_v_h1 = _make_unshaded(Color(0.2, 1.0, 0.2))    # lime green
	_mat_v_h2 = _make_unshaded(Color(1.0, 0.0, 1.0))    # magenta
	_mat_v_h3 = _make_unshaded(Color(0.0, 0.9, 1.0))    # cyan
	_mat_v_glue = _make_unshaded(Color(1.0, 0.85, 0.0)) # yellow — glued h1/h2 pair

func _make_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.cull_mode    = BaseMaterial3D.CULL_DISABLED
	return m

func _make_unshaded(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


func _set_origin(ocx: int, ocz: int) -> void:
	origin_cx = ocx
	origin_cz = ocz
	world_ox  = origin_cx * chunk_cells * cell_size
	world_oz  = origin_cz * chunk_cells * cell_size

func create_new(cx: int, cz: int, cells: int, csize: float, base_h: float) -> void:
	chunks_x    = cx
	chunks_z    = cz
	chunk_cells = cells
	cell_size   = csize
	_set_origin(-(cx / 2), -(cz / 2))
	var stride  := cells + 1
	var count   := stride * stride
	_chunks.clear()
	_glue.clear()
	_static_objects.clear()
	_water_rects.clear()
	_biomes = [{ "id": 0, "name": "default", "props": [] }]
	_prop_types.clear()
	_prop_instances.clear()
	_walls.clear()
	_pillars.clear()
	for _i in range(cx * cz):
		var h1 := PackedFloat32Array()
		h1.resize(count)
		h1.fill(base_h)
		_chunks.append({ "type": CHUNK_TERRAIN, "biome": 0, "h1": h1, "h2": PackedFloat32Array(), "h3": PackedFloat32Array() })
	_stitch_all_borders("h1")


var _box_offset: int = 0
var _pillar_offset: int = 0  # GWL9 only; 0 = no pillar section
var _legacy_biomes: bool = false  # true while loading GWL7 — biome records carry material + spawner fields

# Returns the static-object section offset, or -1 if the file isn't GWL7/GWL8/GWL9.
func _load_header(f: FileAccess) -> int:
	var magic := f.get_32()
	if magic != MAGIC and magic != MAGIC_V8 and magic != MAGIC_V7:
		push_error("EditorWorldData: unsupported world format — only GWL7/GWL8/GWL9 are supported")
		return -1
	_legacy_biomes = magic == MAGIC_V7
	chunk_cells = f.get_32()
	chunks_x    = f.get_32()
	chunks_z    = f.get_32()
	cell_size   = f.get_float()
	var raw_x := f.get_32(); var raw_z := f.get_32()
	var ocx := raw_x if raw_x < 0x80000000 else int(raw_x) - 0x100000000
	var ocz := raw_z if raw_z < 0x80000000 else int(raw_z) - 0x100000000
	_set_origin(ocx, ocz)
	var static_offset := f.get_32()
	_box_offset = f.get_32()
	_pillar_offset = f.get_32() if magic == MAGIC else 0
	return static_offset

func load(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("EditorWorldData: cannot open " + path)
		return false

	var static_offset := _load_header(f)
	if static_offset < 0:
		f.close()
		return false

	var total  := chunks_x * chunks_z
	var stride := chunk_cells + 1
	var cells  := stride * stride

	var types:   Array[int] = []
	var biomes_: Array[int] = []
	var offsets: Array[int] = []
	for _i in range(total):
		types.append(f.get_8())
		biomes_.append(f.get_8())
		offsets.append(f.get_32())

	_chunks.clear()
	_glue.clear()
	for i in range(total):
		f.seek(offsets[i])
		var h1 := f.get_buffer(cells * 4).to_float32_array()
		var h2 := PackedFloat32Array()
		var h3 := PackedFloat32Array()
		if is_cave_type(types[i]):
			h2 = f.get_buffer(cells * 4).to_float32_array()
			h3 = f.get_buffer(cells * 4).to_float32_array()

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
			var wr := {
				"x": f.get_float(), "z": f.get_float(),
				"width": f.get_float(), "depth": f.get_float(), "y": f.get_float(),
				"is_waterfall": f.get_8() != 0,
			}
			_water_rects.append(wr)

	_biomes.clear()
	if not f.eof_reached():
		var bcount := f.get_8()
		for _bi in range(bcount):
			var bid   := f.get_8()
			var bname := _read_pstr(f)
			if _legacy_biomes: _read_pstr(f)  # material
			var pc    := f.get_8()
			var bprops: Array = []
			for _pi in range(pc):
				var p_path := _read_pstr(f)
				var p_wt := f.get_float()
				bprops.append({ "path": p_path, "weight": p_wt })
			if _legacy_biomes:  # spawner: type(pstr) interval(f32) max(u8) prob(f32)
				_read_pstr(f); f.get_float(); f.get_8(); f.get_float()
			_biomes.append({ "id": bid, "name": bname, "props": bprops })

	_prop_types.clear()
	_prop_instances.clear()
	if not f.eof_reached():
		var ptcount := f.get_8()
		for _pti in range(ptcount): _prop_types.append(_read_pstr(f))
	if not f.eof_reached():
		var picount := f.get_32()
		for _pii in range(picount):
			_prop_instances.append({
				"type_idx": f.get_8(),
				"x": f.get_float(), "y": f.get_float(), "z": f.get_float(),
				"rot_y": f.get_float(),
				"sx": f.get_float(), "sy": f.get_float(), "sz": f.get_float()
			})

	_walls.clear()
	if _box_offset > 0:
		f.seek(_box_offset)
		var box_count := f.get_32()
		for _bi in range(box_count):
			var bt := f.get_8()
			var bx := f.get_float(); var bz := f.get_float()
			var bhx := f.get_float(); var bhz := f.get_float()
			var bry := f.get_float(); var bh := f.get_float()
			var byo := f.get_float()
			var blow := f.get_float()
			var openings := _read_wall_openings(f)
			_walls.append({ "type": bt, "x": bx, "z": bz, "half_x": bhx, "half_z": bhz, "rot_y": bry, "height": bh, "y_offset": byo, "low_height": blow, "openings": openings })

	_pillars.clear()
	if _pillar_offset > 0:
		f.seek(_pillar_offset)
		for _pi in range(f.get_32()):
			_pillars.append({ "type": f.get_8(), "x": f.get_float(), "z": f.get_float(),
				"radius": f.get_float(), "height": f.get_float(), "y_offset": f.get_float() })

	f.close()
	_stitch_all_borders("h1")
	_stitch_all_borders("h2")
	_stitch_all_borders("h3")
	return true


# Whole-file rewrite of the world in memory.
func save(path: String, object_type_defs: Dictionary = {}, wall_type_defs: Dictionary = {}) -> bool:
	var snap_dist := cell_size * 0.25
	for c in _chunks:
		var chunk: Dictionary = c
		if not is_cave_type(chunk["type"]): continue
		var h1: PackedFloat32Array = chunk["h1"]
		var h3: PackedFloat32Array = chunk["h3"]
		for i in range(h1.size()):
			if is_nan(h1[i]) or is_nan(h3[i]): continue
			if absf(h1[i] - h3[i]) < snap_dist:
				var mid: float = (h1[i] as float + h3[i] as float) * 0.5
				h1[i] = mid
				h3[i] = mid

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("EditorWorldData: cannot save " + path)
		return false

	var total  := chunks_x * chunks_z
	var stride := chunk_cells + 1
	var cells  := stride * stride

	# header = 10 × 4 = 40 bytes (box_off, pillar_off); table = total × (u8 + u8 + u32) = total × 6
	var cursor := 40 + total * 6
	var offsets: Array[int] = []
	for i in range(total):
		offsets.append(cursor)
		cursor += cells * 4
		if is_cave_type(_chunks[i].type):
			cursor += cells * 4 * 2
	var static_off := cursor

	f.store_32(MAGIC)
	f.store_32(chunk_cells)
	f.store_32(chunks_x)
	f.store_32(chunks_z)
	f.store_float(cell_size)
	f.store_32(origin_cx & 0xFFFFFFFF)
	f.store_32(origin_cz & 0xFFFFFFFF)
	f.store_32(static_off)
	# box_off can't be precomputed like static_off (the sections before it have
	# variable-length strings) — write a placeholder now and patch it below,
	# once the actual box section's position is known.
	var box_off_pos := f.get_position()
	f.store_32(0)
	var pillar_off_pos := f.get_position()  # patched by _write_pillars, same as box_off
	f.store_32(0)

	for i in range(total):
		f.store_8(_chunks[i].type)
		f.store_8((_chunks[i] as Dictionary).get("biome", 0) as int)
		f.store_32(offsets[i])

	for i in range(total):
		f.store_buffer((_chunks[i].h1 as PackedFloat32Array).to_byte_array())
		if is_cave_type(_chunks[i].type):
			f.store_buffer((_chunks[i].h2 as PackedFloat32Array).to_byte_array())
			f.store_buffer((_chunks[i].h3 as PackedFloat32Array).to_byte_array())

	_write_objects(f, _static_objects)
	_write_water_rects(f, _water_rects)
	_write_biomes(f)
	_write_props(f, _prop_instances)
	_write_static_type_table(f, _static_objects, object_type_defs)
	_write_walls_section(f, _walls, box_off_pos)
	_write_wall_type_table(f, _walls, wall_type_defs)
	_write_pillars(f, _pillars, pillar_off_pos)

	f.close()
	return true



func _write_objects(f: FileAccess, objects: Array) -> void:
	f.store_32(objects.size())
	for obj in objects:
		var d := obj as Dictionary
		f.store_8(d["type"])
		f.store_float(d["x"]); f.store_float(d["z"])
		f.store_float(d["radius"]); f.store_float(d["height"])


func _write_water_rects(f: FileAccess, rects: Array) -> void:
	f.store_32(rects.size())
	for wr in rects:
		var d := wr as Dictionary
		f.store_float(d["x"]); f.store_float(d["z"])
		f.store_float(d["width"]); f.store_float(d["depth"]); f.store_float(d["y"])
		f.store_8(1 if d.get("is_waterfall", false) else 0)


func _write_biomes(f: FileAccess) -> void:
	f.store_8(mini(_biomes.size(), 255))
	for _bdef in _biomes:
		var bd := _bdef as Dictionary
		f.store_8((bd["id"] as int) & 0xFF)
		_write_pstr(f, bd.get("name", "") as String)
		var bprops: Array = bd.get("props", []) as Array
		f.store_8(mini(bprops.size(), 255))
		for _bp in bprops:
			if _bp is Dictionary:
				_write_pstr(f, (_bp as Dictionary).get("path", "") as String)
				f.store_float((_bp as Dictionary).get("weight", 1.0) as float)
			else:
				_write_pstr(f, _bp as String)
				f.store_float(1.0)


func _write_props(f: FileAccess, prop_instances: Array) -> void:
	f.store_8(mini(_prop_types.size(), 255))
	for pt in _prop_types: _write_pstr(f, pt as String)
	f.store_32(prop_instances.size())
	for pi_ in prop_instances:
		var pd := pi_ as Dictionary
		f.store_8((pd["type_idx"] as int) & 0xFF)
		f.store_float(pd["x"] as float); f.store_float(pd["y"] as float); f.store_float(pd["z"] as float)
		f.store_float(pd["rot_y"] as float)
		f.store_float(pd["sx"] as float); f.store_float(pd["sy"] as float); f.store_float(pd["sz"] as float)


# Static-object type table: type_id -> (mesh path, scale_ratio), so the game
# client can resolve/scale static objects without hardcoding a type_id ->
# asset table of its own. Derived from `object_types` (passed in by
# main.gd) — a complete, authoritative list of every type id actually used
# by `objects`, not just newly added ones.
func _write_static_type_table(f: FileAccess, objects: Array, object_type_defs: Dictionary) -> void:
	var used_ids: Dictionary = {}
	for obj in objects:
		used_ids[(obj as Dictionary)["type"] as int] = true
	var type_entries: Array = []
	for id in used_ids.keys():
		if object_type_defs.has(id):
			var def := object_type_defs[id] as Dictionary
			type_entries.append({
				"id": id,
				"mesh": def.get("mesh", "") as String,
				"scale_ratio": def.get("scale_ratio", 1.0) as float,
			})
		else:
			push_error("EditorWorldData.save: static object type %d has no entry in object_types — omitting from static-type table" % id)
	f.store_32(type_entries.size())
	for te in type_entries:
		var ted := te as Dictionary
		f.store_8((ted["id"] as int) & 0xFF)
		_write_pstr(f, ted["mesh"] as String)
		f.store_float(ted["scale_ratio"] as float)


# Box/wall colliders — appended last; box_off_pos is patched back into the
# header now that its position is known.
func _write_walls_section(f: FileAccess, walls: Array, box_off_pos: int) -> void:
	var box_off := f.get_position()
	f.store_32(walls.size())
	for w in walls:
		var wd_ := w as Dictionary
		f.store_8((wd_["type"] as int) & 0xFF)
		f.store_float(wd_["x"] as float)
		f.store_float(wd_["z"] as float)
		f.store_float(wd_["half_x"] as float)
		f.store_float(wd_["half_z"] as float)
		f.store_float(wd_["rot_y"] as float)
		f.store_float(wd_["height"] as float)
		f.store_float(wd_.get("y_offset", 0.0) as float)
		f.store_float(wd_.get("low_height", -1.0) as float)
		_write_wall_openings(f, wd_.get("openings", []) as Array)
	var end_pos := f.get_position()
	f.seek(box_off_pos)
	f.store_32(box_off)
	f.seek(end_pos)


# Pillars (GWL9) — last in the file, located by the header's pillar_off, which
# is patched in here. Per pillar: u8 type, f32 x, z, radius, height, y_offset.
func _write_pillars(f: FileAccess, pillars: Array, pillar_off_pos: int) -> void:
	var pillar_off := f.get_position()
	f.store_32(pillars.size())
	for p in pillars:
		var d := p as Dictionary
		f.store_8((d["type"] as int) & 0xFF)
		f.store_float(d["x"] as float); f.store_float(d["z"] as float)
		f.store_float(d["radius"] as float); f.store_float(d["height"] as float)
		f.store_float(d.get("y_offset", 0.0) as float)
	var end_pos := f.get_position()
	f.seek(pillar_off_pos)
	f.store_32(pillar_off)
	f.seek(end_pos)


# Wall-type table: type_id -> material path (.tres), so gaze_client can resolve a
# material for each wall without a hardcoded id -> asset table of its own.
# Same convention as the static-object type table above; sequential, read by
# nothing (the pillar section after it is found by its own offset).
func _write_wall_type_table(f: FileAccess, walls: Array, wall_type_defs: Dictionary) -> void:
	var used_wall_ids: Dictionary = {}
	for w in walls:
		used_wall_ids[(w as Dictionary)["type"] as int] = true
	var wall_type_entries: Array = []
	for id in used_wall_ids.keys():
		if wall_type_defs.has(id):
			var wdef := wall_type_defs[id] as Dictionary
			wall_type_entries.append({ "id": id, "material": wdef.get("material", "") as String })
		else:
			push_error("EditorWorldData.save: wall type %d has no entry in wall_types — omitting from wall-type table" % id)
	f.store_32(wall_type_entries.size())
	for wte in wall_type_entries:
		var wted := wte as Dictionary
		f.store_8((wted["id"] as int) & 0xFF)
		_write_pstr(f, wted["material"] as String)


# Terrain chunks aren't built here: update_streaming() builds the ones near
# the camera and frees the rest, so a big world only ever has a few chunks'
# meshes, collision and vertex markers in memory. The height data for the
# whole world stays loaded. Walls and water work the same way through
# main.gd's AoiSets (build_wall / build_water_rect, one item at a time).
func spawn_into(parent: Node3D) -> void:
	_parent = parent
	_chunk_roots.clear()
	_tile_queue.clear()
	_chunk_roots.resize(_chunks.size())


# At most this many chunks are built at once (5x5 around the camera minus
# the corners); the rest of the world is data only.
const MAX_BUILT_CHUNKS := 21
# Streamed-in chunks build this many tiles per frame instead of all 64 at
# once (~1 ms each), so flying doesn't hitch. Edits still rebuild at once.
const STREAM_TILES_PER_FRAME := 8
var _tile_queue: Array = []  # [chunk i, tile t] still to build for streamed chunks

# The MAX_BUILT_CHUNKS chunks nearest `center` (and within `radius` metres,
# XZ) get built, nearest first and at most `budget` per call. Any other built
# chunk is freed, so there are never more than MAX_BUILT_CHUNKS.
func update_streaming(center: Vector3, radius: float, budget: int = 2) -> void:
	if _parent == null: return
	var near: Array = []
	for i in range(_chunks.size()):
		var d := _chunk_xz_distance(i, center)
		if d <= radius: near.append([d, i])
	near.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var want := {}
	for k in range(mini(MAX_BUILT_CHUNKS, near.size())):
		want[near[k][1]] = true
	for i in range(_chunk_roots.size()):
		if _chunk_roots[i] != null and not want.has(i):
			(_chunk_roots[i] as Node3D).queue_free()
			_chunk_roots[i] = null
	# Finish the tiles of chunks already started before starting another.
	if not _tile_queue.is_empty():
		var n := 0
		while n < STREAM_TILES_PER_FRAME and not _tile_queue.is_empty():
			var e: Array = _tile_queue.pop_front()
			var root = _chunk_roots[e[0]]
			if root == null: continue  # freed meanwhile
			var tiles: Array = (root as Node3D).get_meta("tiles")
			if tiles[e[1]] != null: continue
			tiles[e[1]] = _build_tile(e[0], e[1])
			(root as Node3D).add_child(tiles[e[1]])
			n += 1
		return
	var started := 0
	for k in range(mini(MAX_BUILT_CHUNKS, near.size())):
		var i: int = near[k][1]
		if _chunk_roots[i] != null: continue
		_spawn_chunk(i, true)
		started += 1
		if started >= budget: return


# Distance from `p` to chunk i's square on the XZ plane (0 inside it).
func _chunk_xz_distance(i: int, p: Vector3) -> float:
	var o := _chunk_origin(i)
	var span := chunk_cells * cell_size
	var dx := maxf(maxf(o.x - p.x, p.x - (o.x + span)), 0.0)
	var dz := maxf(maxf(o.z - p.z, p.z - (o.z + span)), 0.0)
	return sqrt(dx * dx + dz * dz)

# XZ footprint of a water rect, for AoiSet.
static func water_rect_footprint(d: Dictionary) -> Rect2:
	var w := d.width as float
	var dd := d.depth as float
	return Rect2((d.x as float) - w * 0.5, (d.z as float) - dd * 0.5, w, dd)


func build_water_rect(d: Dictionary, parent: Node3D) -> void:
	var is_wf := d.get("is_waterfall", false) as bool

	# Placed exactly like normal water — same flat AABB rect, same
	# gameplay fields. White so the designer can tell waterfalls apart
	# from lakes while editing; the client is the one that samples the
	# terrain heightmap under this footprint and renders an actual
	# cascade volume instead of a flat plane.
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.5) if is_wf else Color(0.1, 0.5, 0.9, 0.45)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode    = BaseMaterial3D.CULL_DISABLED

	var plane := PlaneMesh.new()
	plane.size = Vector2(d.width as float, d.depth as float)
	plane.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh     = plane
	mi.position = Vector3(d.x as float, d.y as float, d.z as float)
	parent.add_child(mi)


# XZ footprint of a wall (its rotated box's bounding square), for AoiSet.
static func pillar_footprint(d: Dictionary) -> Rect2:
	var r := d.radius as float
	return Rect2((d.x as float) - r, (d.z as float) - r, r * 2.0, r * 2.0)


# Cylinder sides of every pillar — gaze_client's world/world_data.gd matches it.
const PILLAR_SIDES := 12

# A pillar as gaze_client draws it: a cylinder in its wall type's material
# (type is a wall type id) from the terrain under its centre + y_offset, up by height.
func build_pillar(d: Dictionary, parent: Node3D) -> void:
	if _wall_fallback == null:
		_wall_fallback = preload("res://world/world_shaders.gd").wall_mat()
	var look: Dictionary = wall_looks.get(d.get("type", 0) as int, {})
	var height := d.height as float
	var cyl := CylinderMesh.new()
	cyl.top_radius      = d.radius as float
	cyl.bottom_radius   = d.radius as float
	cyl.height          = height
	cyl.radial_segments = PILLAR_SIDES
	cyl.rings           = 1
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = look.get("mat", _wall_fallback)
	mi.position = Vector3(d.x as float, _get_height_at(d.x as float, d.z as float) + (d.get("y_offset", 0.0) as float) + height * 0.5, d.z as float)
	parent.add_child(mi)


static func wall_footprint(d: Dictionary) -> Rect2:
	var r := Vector2(d.half_x as float, d.half_z as float).length()
	return Rect2((d.x as float) - r, (d.z as float) - r, r * 2.0, r * 2.0)


# Walls sit on the ground (plus y_offset) and extend upward by `height`,
# mirroring how the C++ server resolves top_y = terrain height + y_offset + height.
# A wall with carved openings is drawn as several boxes (whatever solid
# material remains once its holes are cut out) instead of one — see
# _carve_box_list.
# Wall type id -> {"mat": Material, "prop": {"scene", "aabb"} (mesh types
# only)}, built by main.gd from wall_types.json (see _build_wall_looks) and
# shared by every EditorWorldData. A type missing here gets _wall_fallback.
static var wall_looks: Dictionary = {}
static var _wall_fallback: Material


# Each wall is drawn the way gaze_client draws it: its type's material (a
# .tres on the client's world-space triplanar ps2_world.gdshader, so texel density
# matches the game), or, for a mesh type like the ladder,
# copies of that model filling each solid piece instead of a box.
func build_wall(d: Dictionary, parent: Node3D) -> void:
	if _wall_fallback == null:
		_wall_fallback = preload("res://world/world_shaders.gd").wall_mat()
	var half_x := d.half_x as float
	var half_z := d.half_z as float
	var height := d.height as float
	var y_offset := d.get("y_offset", 0.0) as float
	var wy := _get_height_at(d.x as float, d.z as float)
	var look: Dictionary = wall_looks.get(d.get("type", 0) as int, {})
	var mat: Material = look.get("mat", _wall_fallback)

	# One node per wall in its own frame (base centre, rotated); the
	# pieces below are local to it.
	var holder := Node3D.new()
	holder.position   = Vector3(d.x as float, wy + y_offset, d.z as float)
	holder.rotation.y = d.rot_y as float
	parent.add_child(holder)

	# A ramp is one sloped wedge — never carved, never filled with props.
	if RampMesh.is_ramp(d):
		var wedge := MeshInstance3D.new()
		wedge.mesh = RampMesh.mesh(d)
		wedge.material_override = mat
		holder.add_child(wedge)
		return

	var openings := d.get("openings", []) as Array
	var box_list: Array = [{ "x0": -half_x, "x1": half_x, "y0": 0.0, "y1": height, "z0": -half_z, "z1": half_z }]
	for op in openings:
		box_list = _carve_box_list(box_list, op as Dictionary)

	for b in box_list:
		var bd := b as Dictionary
		var lo := Vector3(bd.x0 as float, bd.y0 as float, bd.z0 as float)
		var hi := Vector3(bd.x1 as float, bd.y1 as float, bd.z1 as float)
		if look.has("prop"):
			_spawn_wall_prop(holder, AABB(lo, hi - lo), look["prop"])
			continue
		var box := BoxMesh.new()
		box.size = hi - lo
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.material_override = mat
		mi.position = (lo + hi) * 0.5
		holder.add_child(mi)


# Same as gaze_client's WorldData._spawn_wall_prop: fills one wall piece
# (wall frame) with copies of a wall type's model, its width along the
# piece's longer side, tiled along that side and up the height in whole
# copies, each stretched to fill its cell; its depth fills the shorter side.
# Collision is stripped so the copies never catch editor raycasts.
static func _spawn_wall_prop(parent: Node3D, piece: AABB, prop: Dictionary) -> void:
	var m: AABB = prop.aabb
	if m.size.x <= 0.0 or m.size.y <= 0.0 or m.size.z <= 0.0: return
	var along_x := piece.size.x >= piece.size.z
	var w := piece.size.x if along_x else piece.size.z
	var dd := piece.size.z if along_x else piece.size.x
	var nw := maxi(1, roundi(w / m.size.x))
	var nh := maxi(1, roundi(piece.size.y / m.size.y))
	var cell := Vector3(w / nw, piece.size.y / nh, dd)
	var turn := Basis.IDENTITY if along_x else Basis(Vector3.UP, PI * 0.5)
	var fit := turn * Basis.from_scale(cell / m.size)
	var side := Vector3.RIGHT if along_x else Vector3.FORWARD
	var start := piece.get_center() - side * (w * 0.5) + Vector3(0.0, -piece.size.y * 0.5, 0.0)
	for i in nw:
		for j in nh:
			var center := start + side * cell.x * (i + 0.5) + Vector3.UP * cell.y * (j + 0.5)
			var inst := (prop.scene as PackedScene).instantiate() as Node3D
			inst.transform = Transform3D(fit, center - fit * m.get_center())
			for body in inst.find_children("*", "CollisionObject3D", true, false):
				(body as CollisionObject3D).collision_layer = 0
				(body as CollisionObject3D).collision_mask  = 0
			parent.add_child(inst)


# Bounds of every mesh under `node`, in the frame `xform` maps node's own
# space into (identity for a scene root). Same as gaze_client's _node_aabb.
static func node_aabb(node: Node, xform: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out = xform * (node as MeshInstance3D).mesh.get_aabb()
		first = false
	for child in node.get_children():
		var a := node_aabb(child, xform * (child as Node3D).transform if child is Node3D else xform)
		if a.size == Vector3.ZERO: continue
		out = a if first else out.merge(a)
		first = false
	return out

# Subtracts one opening (local x/y/z min/max) from a list of local-frame
# boxes, splitting each overlapping box into up to 6 remaining pieces — the
# standard "picture frame" AABB-minus-AABB slicing used to render a wall
# with a hole punched in it without an actual CSG mesh boolean.
func _carve_box_list(box_list: Array, op: Dictionary) -> Array:
	var ox0 := op.x_min as float; var ox1 := op.x_max as float
	var oy0 := op.y_min as float; var oy1 := op.y_max as float
	var oz0 := op.z_min as float; var oz1 := op.z_max as float
	var result: Array = []
	for b in box_list:
		var bd := b as Dictionary
		var bx0 := bd.x0 as float; var bx1 := bd.x1 as float
		var by0 := bd.y0 as float; var by1 := bd.y1 as float
		var bz0 := bd.z0 as float; var bz1 := bd.z1 as float

		var ix0 := maxf(bx0, ox0); var ix1 := minf(bx1, ox1)
		var iy0 := maxf(by0, oy0); var iy1 := minf(by1, oy1)
		var iz0 := maxf(bz0, oz0); var iz1 := minf(bz1, oz1)
		if ix0 >= ix1 or iy0 >= iy1 or iz0 >= iz1:
			result.append(bd)
			continue

		if ix0 > bx0: result.append({ "x0": bx0, "x1": ix0, "y0": by0, "y1": by1, "z0": bz0, "z1": bz1 })
		if ix1 < bx1: result.append({ "x0": ix1, "x1": bx1, "y0": by0, "y1": by1, "z0": bz0, "z1": bz1 })
		if iz0 > bz0: result.append({ "x0": ix0, "x1": ix1, "y0": by0, "y1": by1, "z0": bz0, "z1": iz0 })
		if iz1 < bz1: result.append({ "x0": ix0, "x1": ix1, "y0": by0, "y1": by1, "z0": iz1, "z1": bz1 })
		if iy0 > by0: result.append({ "x0": ix0, "x1": ix1, "y0": by0, "y1": iy0, "z0": iz0, "z1": iz1 })
		if iy1 < by1: result.append({ "x0": ix0, "x1": ix1, "y0": iy1, "y1": by1, "z0": iz0, "z1": iz1 })
	return result

func add_chunk_at(grid_cx: int, grid_cz: int) -> bool:
	# convert to array index
	var ax := grid_cx - origin_cx
	var az := grid_cz - origin_cz
	if ax >= 0 and ax < chunks_x and az >= 0 and az < chunks_z:
		return false  # already exists

	var new_ocx := mini(origin_cx, grid_cx)
	var new_ocz := mini(origin_cz, grid_cz)
	var new_x   := maxi(origin_cx + chunks_x, grid_cx + 1) - new_ocx
	var new_z   := maxi(origin_cz + chunks_z, grid_cz + 1) - new_ocz
	var stride  := chunk_cells + 1
	var count   := stride * stride
	var shift_x := origin_cx - new_ocx  # how many cols prepended
	var shift_z := origin_cz - new_ocz

	var new_arr: Array = []
	for ncz in range(new_z):
		for ncx in range(new_x):
			var old_ax := ncx - shift_x
			var old_az := ncz - shift_z
			if old_ax >= 0 and old_ax < chunks_x and old_az >= 0 and old_az < chunks_z:
				new_arr.append(_chunks[old_az * chunks_x + old_ax])
			else:
				var h1 := PackedFloat32Array()
				h1.resize(count)
				h1.fill(0.0)
				new_arr.append({ "type": CHUNK_TERRAIN, "biome": 0, "h1": h1, "h2": PackedFloat32Array(), "h3": PackedFloat32Array() })

	_chunks  = new_arr
	chunks_x = new_x
	chunks_z = new_z
	_set_origin(new_ocx, new_ocz)
	_chunk_roots.clear()
	_tile_queue.clear()
	_chunk_roots.resize(_chunks.size())
	_stitch_all_borders("h1")
	return true

func add_static_object(type: int, x: float, z: float, radius: float, height: float) -> void:
	_static_objects.append({ "type": type, "x": x, "z": z, "radius": radius, "height": height })

func add_pillar(type: int, x: float, z: float, radius: float, height: float, y_offset: float) -> void:
	# A negative height hangs down from the base — stored as the same span
	# with a positive height, as add_wall does.
	if height < 0.0:
		y_offset += height
		height = -height
	_pillars.append({ "type": type, "x": x, "z": z, "radius": radius, "height": height, "y_offset": y_offset })

func add_water_rect(x: float, z: float, width: float, depth: float, y: float,
                     is_waterfall: bool = false) -> void:
	_water_rects.append({ "x": x, "z": z, "width": width, "depth": depth, "y": y,
		"is_waterfall": is_waterfall })

# low_height >= 0 (and < height) makes a ramp: the top rises from low_height at
# local -half_x to height at +half_x — see world/ramp_mesh.gd.
func add_wall(type: int, x: float, z: float, half_x: float, half_z: float, rot_y: float, height: float, y_offset: float = 0.0, openings: Array = [], low_height: float = -1.0) -> void:
	# A negative height (e.g. -6 typed into the wall tool) means the wall
	# hangs down from its base. Store it as the same span with a positive
	# height and the base moved down, since the client, server and colliders
	# all expect height > 0 (a negative one made a negative BoxShape3D).
	# Openings are base-relative, so they move up by the same amount.
	if height < 0.0:
		y_offset += height
		var moved: Array = []
		for op: Dictionary in openings:
			var o := op.duplicate()
			o.y_min = (op.y_min as float) - height
			o.y_max = (op.y_max as float) - height
			moved.append(o)
		openings = moved
		height = -height
	_walls.append({ "type": type, "x": x, "z": z, "half_x": half_x, "half_z": half_z, "rot_y": rot_y, "height": height, "y_offset": y_offset, "low_height": low_height, "openings": openings })

func remove_nearest_water_rect(wx: float, wz: float, max_dist: float) -> bool:
	var best_i := -1
	var best_d := max_dist * max_dist
	for i in range(_water_rects.size()):
		var wr := _water_rects[i] as Dictionary
		var dx := (wr.x as float) - wx
		var dz := (wr.z as float) - wz
		if dx*dx + dz*dz < best_d:
			best_d = dx*dx + dz*dz
			best_i = i
	if best_i < 0: return false
	_water_rects.remove_at(best_i)
	return true

func remove_nearest_object(wx: float, wz: float, max_dist: float) -> bool:
	var best_i := -1
	var best_d := max_dist * max_dist
	for i in range(_static_objects.size()):
		var obj := _static_objects[i] as Dictionary
		var dx  := (obj.x as float) - wx
		var dz  := (obj.z as float) - wz
		if dx*dx + dz*dz < best_d:
			best_d = dx*dx + dz*dz
			best_i = i
	if best_i < 0: return false
	_static_objects.remove_at(best_i)
	return true

# Removes exactly one wall by index — used by the world_editor's hover-pick
# Delete/erase-click flow, where the target wall was already resolved via a
# ray-vs-OBB test against the crosshair, not a nearest-point guess.
func remove_wall_at(index: int) -> bool:
	if index < 0 or index >= _walls.size(): return false
	_walls.remove_at(index)
	return true

# Carves a hole into every wall the given cutter box overlaps, for the
# world_editor's negative wall brush — punching a window/door/floor opening
# instead of deleting the whole wall. `(x, z, half_x, half_z)` is the
# cutter's world-space footprint (axis-aligned; wall rotation is ignored for
# the broad-phase overlap test, same approximation remove_wall_at's sibling
# _remove_overlapping_walls uses — acceptable for an interactive brush).
# `bottom_y`/`top_y` are the cutter's world-space vertical range (from the
# same height/y_offset the positive wall tool already exposes via scroll).
# A wall entirely swallowed by the cutter is deleted outright instead of
# growing a same-size opening. Returns the number of walls carved or removed.
# `only`, when given, restricts the carve to that one wall (same Dictionary as
# in _walls) — the editor's Negative brush cuts just the selected wall.
func carve_walls_in_rect(x: float, z: float, half_x: float, half_z: float, bottom_y: float, top_y: float,
                         slabs_only: bool = false, only: Dictionary = {}) -> int:
	var affected := 0
	var i := _walls.size() - 1
	while i >= 0:
		var w := _walls[i] as Dictionary
		if not only.is_empty() and not is_same(w, only):
			i -= 1
			continue
		# Ramps aren't carved (the server's sloped top assumes one solid piece).
		if RampMesh.is_ramp(w):
			i -= 1
			continue
		# Same slab test _compute_wall_carve uses: thicker than it is tall.
		if slabs_only and (w.half_z as float) * 2.0 <= (w.height as float):
			i -= 1
			continue
		if absf((w.x as float) - x) <= half_x + (w.half_x as float) and \
		   absf((w.z as float) - z) <= half_z + (w.half_z as float):
			var result := _compute_wall_carve(w, x, z, half_x, half_z, bottom_y, top_y)
			if result.get("delete", false):
				_walls.remove_at(i)
				affected += 1
			elif result.has("opening"):
				var openings: Array = (w.get("openings", []) as Array).duplicate()
				openings.append(result["opening"])
				w["openings"] = openings
				affected += 1
		i -= 1
	return affected

# Drops every opening from wall `index`, restoring its plain box. Returns how
# many were removed.
func clear_wall_openings(index: int) -> int:
	if index < 0 or index >= _walls.size(): return 0
	var w := _walls[index] as Dictionary
	var n := (w.get("openings", []) as Array).size()
	w["openings"] = []
	return n

# Adds one wall-local opening (x/z in the wall's frame, y from its bottom) to
# `w`, or removes the wall when the opening covers all of it (full length and
# full height for an upright wall; full footprint for a slab — the same
# coverage test _compute_wall_carve uses). Returns true if the wall was removed.
func carve_wall_opening(w: Dictionary, op: Dictionary) -> bool:
	const EPS := 0.02
	var hx := w.half_x as float; var hz := w.half_z as float; var h := w.height as float
	var full_x := (op.x_min as float) <= -hx + EPS and (op.x_max as float) >= hx - EPS
	var full := full_x and (op.y_min as float) <= EPS and (op.y_max as float) >= h - EPS
	if hz * 2.0 > h:
		full = full_x and (op.z_min as float) <= -hz + EPS and (op.z_max as float) >= hz - EPS
	if full:
		_walls.erase(w)
		return true
	var openings: Array = (w.get("openings", []) as Array).duplicate()
	openings.append(op)
	w["openings"] = openings
	return false

# Computes what a cutter box (world-space footprint x/z/half_x/half_z, world-
# space vertical range bottom_y/top_y) does to one existing wall: swallow it
# whole ({"delete": true}), carve a partial hole ({"opening": {...}}), or
# nothing ({} — cutter and wall don't actually overlap after clipping).
#
# The opening is expressed in the wall's own local frame (x along half_x,
# z along half_z, y from 0 at the wall's base to `height` at its top).
# Whichever of the wall's two thin dimensions — thickness (half_z*2) for an
# upright wall, or height for a thin floor/ceiling slab — is smaller is
# always carved full-range, so the result is a genuine through-hole (a
# window/door punches through the wall's thickness; a staircase hole punches
# through a floor's height) no matter how the cutter's own thickness lines
# up. The other two axes are clipped to wherever the cutter actually reaches.
func _compute_wall_carve(w: Dictionary, cx: float, cz: float, chalf_x: float, chalf_z: float,
                          bottom_y: float, top_y: float) -> Dictionary:
	var wx := w.x as float; var wz := w.z as float
	var half_x := w.half_x as float; var half_z := w.half_z as float
	var height := w.height as float
	var wall_bottom := _get_height_at(wx, wz) + (w.get("y_offset", 0.0) as float)

	if top_y <= wall_bottom or bottom_y >= wall_bottom + height:
		return {}

	var rot_y := w.rot_y as float
	var cr := cos(rot_y); var sr := sin(rot_y)
	var lx_min := INF; var lx_max := -INF
	var lz_min := INF; var lz_max := -INF
	for cxs: float in [cx - chalf_x, cx + chalf_x]:
		for czs: float in [cz - chalf_z, cz + chalf_z]:
			var dx := cxs - wx; var dz := czs - wz
			var lx := dx * cr - dz * sr
			var lz := dx * sr + dz * cr
			lx_min = minf(lx_min, lx); lx_max = maxf(lx_max, lx)
			lz_min = minf(lz_min, lz); lz_max = maxf(lz_max, lz)

	lx_min = maxf(lx_min, -half_x); lx_max = minf(lx_max, half_x)
	lz_min = maxf(lz_min, -half_z); lz_max = minf(lz_max, half_z)
	if lx_min >= lx_max or lz_min >= lz_max:
		return {}

	var ly_min := clampf(bottom_y - wall_bottom, 0.0, height)
	var ly_max := clampf(top_y - wall_bottom, 0.0, height)
	if ly_min >= ly_max:
		return {}

	const EPS := 0.02
	var opening: Dictionary
	var full_cover: bool
	if half_z * 2.0 <= height:
		# Upright wall, thin in Z — carve fully through its thickness.
		opening = { "x_min": lx_min, "x_max": lx_max, "y_min": ly_min, "y_max": ly_max,
			"z_min": -half_z, "z_max": half_z }
		full_cover = lx_min <= -half_x + EPS and lx_max >= half_x - EPS and \
			ly_min <= EPS and ly_max >= height - EPS
	else:
		# Thin floor/ceiling slab — carve fully through its height.
		opening = { "x_min": lx_min, "x_max": lx_max, "y_min": 0.0, "y_max": height,
			"z_min": lz_min, "z_max": lz_max }
		full_cover = lx_min <= -half_x + EPS and lx_max >= half_x - EPS and \
			lz_min <= -half_z + EPS and lz_max >= half_z - EPS

	if full_cover:
		return { "delete": true }
	return { "opening": opening }


func _get_height_at(wx: float, wz: float) -> float:
	var lx := wx - world_ox
	var lz := wz - world_oz
	var cx := clampi(int(lx / (chunk_cells * cell_size)), 0, chunks_x - 1)
	var cz := clampi(int(lz / (chunk_cells * cell_size)), 0, chunks_z - 1)
	var local_x := lx - cx * chunk_cells * cell_size
	var local_z := lz - cz * chunk_cells * cell_size
	var gx := clampi(int(local_x / cell_size), 0, chunk_cells - 1)
	var gz := clampi(int(local_z / cell_size), 0, chunk_cells - 1)
	var stride := chunk_cells + 1
	var h1: PackedFloat32Array = (_chunks[cz * chunks_x + cx] as Dictionary)["h1"]
	var tl := gz * stride + gx
	var h00 := h1[tl]              as float
	var h10 := h1[tl + 1]         as float
	var h01 := h1[tl + stride]    as float
	var h11 := h1[tl + stride + 1] as float
	# Over a hole the ground is 0, as in gaze_client and the server — a NaN
	# here would put walls standing on it at NaN, i.e. nowhere.
	if is_nan(h00) or is_nan(h10) or is_nan(h01) or is_nan(h11): return 0.0
	var rx  := fmod(local_x, cell_size) / cell_size
	var rz  := fmod(local_z, cell_size) / cell_size
	if rx + rz <= 1.0:
		return h00 + (h10 - h00) * rx + (h01 - h00) * rz
	else:
		return h11 + (h01 - h11) * (1.0 - rx) + (h10 - h11) * (1.0 - rz)


func _spawn_static_objects() -> void:
	for obj in _static_objects:
		var d    := obj as Dictionary
		var wy   := _get_height_at(d.x, d.z)
		var mi   := MeshInstance3D.new()
		var mat  := StandardMaterial3D.new()
		if d.type == 0:
			var m           := CylinderMesh.new()
			m.top_radius    = d.radius * 0.4
			m.bottom_radius = d.radius
			m.height        = 3.0
			mi.mesh         = m
			mat.albedo_color = Color(0.2, 0.7, 0.2, 0.7)
			mi.position     = Vector3(d.x, wy + 1.5, d.z)
		else:
			var m  := BoxMesh.new()
			m.size = Vector3(d.radius * 2.0, d.radius * 1.2, d.radius * 2.0)
			mi.mesh = m
			mat.albedo_color = Color(0.6, 0.55, 0.5, 0.7)
			mi.position     = Vector3(d.x, wy + d.radius * 0.6, d.z)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mi.material_override = mat
		_parent.add_child(mi)


static func cells_path_for(world_path: String) -> String:
	return world_path.get_basename() + ".cells.bin"


static func _s32(v: int) -> int:
	return v if v < 0x80000000 else v - 0x100000000


func _chunk_grid(i: int) -> Vector2i:
	return Vector2i(origin_cx + i % chunks_x, origin_cz + i / chunks_x)


# Palette and every chunk entry of a cells file: [palette, {Vector2i: bytes}],
# or [] when there's no (valid) file.
func _read_cells(path: String) -> Array:
	if path.is_empty() or not FileAccess.file_exists(path): return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_32() != CELLS_MAGIC or f.get_32() != chunk_cells: return []
	var palette: Array = []
	for _k in range(f.get_8()):
		var p := f.get_buffer(f.get_16()).get_string_from_utf8()
		palette.append({ "path": p, "tile": f.get_float() })
	var entries := {}
	for _c in range(f.get_32()):
		var key := Vector2i(_s32(f.get_32()), _s32(f.get_32()))
		entries[key] = f.get_buffer(chunk_cells * chunk_cells)
	return [palette, entries]


# After load()/load_range(), before spawn_into(): the painted cells of the
# loaded chunks.
func load_cells(path: String) -> void:
	_cells_source = path
	_cell_remap.resize(256)
	for v in range(256): _cell_remap[v] = v
	var data := _read_cells(path)
	cell_palette = data[0] if not data.is_empty() else []
	if not data.is_empty():
		for i in range(_chunks.size()):
			var key := _chunk_grid(i)
			if (data[1] as Dictionary).has(key):
				(_chunks[i] as Dictionary)["cells"] = data[1][key]
	if sync_cell_palette() == 0:
		_build_cell_array()


# Writes the palette and every painted chunk, merging into the file this
# world's cells came from (or `path` itself) so chunks outside a partial load
# keep theirs. No file at all while nothing is painted.
func save_cells(path: String) -> bool:
	var data := _read_cells(path)
	if data.is_empty(): data = _read_cells(_cells_source)
	var entries: Dictionary = data[1] if not data.is_empty() else {}
	for key in entries.keys():
		var b: PackedByteArray = entries[key]
		for j in range(b.size()): b[j] = _cell_remap[b[j]]
		entries[key] = b
	for i in range(_chunks.size()):
		var key := _chunk_grid(i)
		var cells: PackedByteArray = (_chunks[i] as Dictionary).get("cells", PackedByteArray())
		if cells.is_empty() or cells.count(0) == cells.size():
			entries.erase(key)
		else:
			entries[key] = cells
	if entries.is_empty():   # the palette alone comes back from TEXTURE_DIR
		if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
		return true
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null: return false
	f.store_32(CELLS_MAGIC)
	f.store_32(chunk_cells)
	f.store_8(cell_palette.size())
	for e in cell_palette:
		var b := (e["path"] as String).to_utf8_buffer()
		f.store_16(b.size()); f.store_buffer(b)
		f.store_float(e["tile"] as float)
	f.store_32(entries.size())
	for key: Vector2i in entries:
		f.store_32(key.x); f.store_32(key.y)
		f.store_buffer(entries[key])
	_cells_source = path
	for v in range(256): _cell_remap[v] = v
	return true


# Surface textures (painted cells, walls) all live in TEXTURE_DIR.
# A path may be res://-absolute, relative to res://assets
# ("textures/grass.png") or a bare file name ("grass.png", "grass"). Older
# worlds name e.g. res://assets/tileable_grass.png, so if the exact path is
# missing, look for the same file stem in TEXTURE_DIR with any image extension.
# Same lookup as gaze_client's WorldShaders.resolve_texture.
const TEXTURE_DIR := "res://assets/textures"


const TEXTURE_EXTS := ["png", "jpg", "jpeg", "webp"]


static func resolve_texture(path: String) -> Texture2D:
	var p := resolve_texture_path(path)
	if p.is_empty(): return null
	if ResourceLoader.exists(p):
		return load(p) as Texture2D
	# Not imported yet: read the raw image.
	var img := Image.load_from_file(p)
	if img == null or img.is_empty(): return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# The full res:// path resolve_texture would load for `path`, "" if none.
static func resolve_texture_path(path: String) -> String:
	if path.is_empty(): return ""
	if not path.begins_with("res://"):
		path = "res://assets/" + path if path.contains("/") else TEXTURE_DIR.path_join(path)
	var stem := path.get_file().get_basename()
	var candidates := [path]
	for dir in [TEXTURE_DIR, path.get_base_dir()]:
		for ext in TEXTURE_EXTS:
			candidates.append("%s/%s.%s" % [dir, stem, ext])
	for p in candidates:
		if not (p as String).get_extension().to_lower() in TEXTURE_EXTS: continue
		if ResourceLoader.exists(p) or FileAccess.file_exists(p):
			return p
	return ""


# Every image in TEXTURE_DIR, as full res:// paths, sorted.
static func list_textures() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(TEXTURE_DIR):
		f = f.trim_suffix(".import").trim_suffix(".remap")
		var p := TEXTURE_DIR.path_join(f)
		if f.get_extension().to_lower() in TEXTURE_EXTS and not out.has(p):
			out.append(p)
	out.sort()
	return out


func _build_cell_array() -> void:
	_cell_array = null
	if cell_palette.is_empty(): return
	var images: Array[Image] = []
	for e in cell_palette:
		var path := e["path"] as String
		var tex := resolve_texture(path)
		var img: Image
		if tex != null:
			img = tex.get_image()
			if img.is_compressed(): img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			img.resize(CELL_TEX_SIZE, CELL_TEX_SIZE, Image.INTERPOLATE_BILINEAR)
		else:
			img = Image.create_empty(CELL_TEX_SIZE, CELL_TEX_SIZE, false, Image.FORMAT_RGBA8)
			img.fill(Color.MAGENTA)  # missing texture
		img.generate_mipmaps()
		images.append(img)
	_cell_array = Texture2DArray.new()
	_cell_array.create_from_images(images)


func _cell_tiles() -> PackedFloat32Array:
	var t := PackedFloat32Array(); t.resize(CELL_TEX_MAX); t.fill(4.0)
	for k in range(mini(cell_palette.size(), CELL_TEX_MAX)):
		t[k] = cell_palette[k]["tile"] as float
	return t


# Chunk i's h1 material: its painted-cells material, or `base` while unpainted.
func _surface_mat_for(i: int, base: StandardMaterial3D) -> Material:
	var c := _chunks[i] as Dictionary
	if not c.has("cells") or _cell_array == null: return base
	var mat: ShaderMaterial = c.get("cells_mat")
	if mat == null:
		mat = ShaderMaterial.new()
		mat.shader = CellsShader
		c["cells_mat"] = mat
	mat.set_shader_parameter("own_color",   base.albedo_color)
	mat.set_shader_parameter("use_cells",   true)
	mat.set_shader_parameter("cell_index",  ImageTexture.create_from_image(
		Image.create_from_data(chunk_cells, chunk_cells, false, Image.FORMAT_R8, c["cells"])))
	mat.set_shader_parameter("cell_tex",    _cell_array)
	mat.set_shader_parameter("cell_tile",   _cell_tiles())
	var o := _chunk_origin(i)
	mat.set_shader_parameter("cell_origin", Vector2(o.x, o.z))
	mat.set_shader_parameter("cell_size",   cell_size)
	return mat


# Puts chunk i's current cells on screen: every tile's h1 mesh gets the
# chunk's (re)built material.
func _refresh_cells(i: int) -> void:
	if i >= _chunk_roots.size() or _chunk_roots[i] == null: return
	var c := _chunks[i] as Dictionary
	var base := _mat_cave_surface if is_cave_type(c.type) else _mat_plains
	_set_h1_material(i, _surface_mat_for(i, base))


func _set_h1_material(i: int, mat: Material) -> void:
	var root := _chunk_roots[i] as Node3D
	root.set_meta("h1_mat", mat)
	for tile in root.get_meta("tiles") as Array:
		if tile == null: continue
		var mi := (tile as Node3D).get_node_or_null("h1") as MeshInstance3D
		if mi: mi.material_override = mat


func _refresh_all_cells() -> void:
	for i in range(_chunks.size()):
		if (_chunks[i] as Dictionary).has("cells"): _refresh_cells(i)


# Sets every cell whose centre is within `radius` of (wx, wz) to `value`
# (0 = back to the chunk's own texture). True if anything changed.
func paint_cells(wx: float, wz: float, radius: float, value: int) -> bool:
	var changed := false
	var size := chunk_cells * cell_size
	var r2 := radius * radius
	for i in range(_chunks.size()):
		var o := _chunk_origin(i)
		if wx + radius < o.x or wx - radius > o.x + size or wz + radius < o.z or wz - radius > o.z + size:
			continue
		var c := _chunks[i] as Dictionary
		if value == 0 and not c.has("cells"): continue
		var cells: PackedByteArray = c.get("cells", PackedByteArray())
		if cells.is_empty():
			cells.resize(chunk_cells * chunk_cells)
			cells.fill(0)
		var x0 := clampi(floori((wx - radius - o.x) / cell_size), 0, chunk_cells - 1)
		var x1 := clampi(floori((wx + radius - o.x) / cell_size), 0, chunk_cells - 1)
		var z0 := clampi(floori((wz - radius - o.z) / cell_size), 0, chunk_cells - 1)
		var z1 := clampi(floori((wz + radius - o.z) / cell_size), 0, chunk_cells - 1)
		var hit := false
		for cz in range(z0, z1 + 1):
			for cx in range(x0, x1 + 1):
				var dx := o.x + (cx + 0.5) * cell_size - wx
				var dz := o.z + (cz + 0.5) * cell_size - wz
				var j := cz * chunk_cells + cx
				if dx * dx + dz * dz <= r2 and cells[j] != value:
					cells[j] = value
					hit = true
		if hit:
			c["cells"] = cells
			_refresh_cells(i)
			changed = true
	return changed


# Painted texture under (wx, wz): 0 = the chunk's own.
func get_cell(wx: float, wz: float) -> int:
	var i := _chunk_at(wx, wz)
	if i < 0 or not (_chunks[i] as Dictionary).has("cells"): return 0
	var o := _chunk_origin(i)
	var cx := clampi(floori((wx - o.x) / cell_size), 0, chunk_cells - 1)
	var cz := clampi(floori((wz - o.z) / cell_size), 0, chunk_cells - 1)
	return (_chunks[i]["cells"] as PackedByteArray)[cz * chunk_cells + cx]


const DEFAULT_CELL_TILE := 4.0


# Puts every image in TEXTURE_DIR in the palette: the ones it lacks are
# appended, so painted cells keep their numbers. Returns how many were added.
func sync_cell_palette() -> int:
	var have := {}
	for e in cell_palette:
		have[resolve_texture_path(e["path"] as String)] = true
	var added := 0
	for p in list_textures():
		if have.has(p) or cell_palette.size() >= CELL_TEX_MAX: continue
		cell_palette.append({ "path": p, "tile": DEFAULT_CELL_TILE })
		added += 1
	if added > 0:
		_build_cell_array()
		_refresh_all_cells()
	return added


func add_cell_texture(path: String, tile: float) -> bool:
	if cell_palette.size() >= CELL_TEX_MAX: return false
	cell_palette.append({ "path": path, "tile": tile })
	_build_cell_array()
	_refresh_all_cells()
	return true


func set_cell_tile(k: int, tile: float) -> void:
	if k < 0 or k >= cell_palette.size(): return
	cell_palette[k]["tile"] = tile
	_refresh_all_cells()


# Drops palette entry k: its cells go back to the chunk's own texture and
# every later entry's cells shift down one, here and (on save) in the file.
func remove_cell_texture(k: int) -> void:
	if k < 0 or k >= cell_palette.size(): return
	var gone := k + 1
	var shift := func(v: int) -> int: return 0 if v == gone else (v - 1 if v > gone else v)
	for v in range(256): _cell_remap[v] = shift.call(_cell_remap[v])
	for c in _chunks:
		if not (c as Dictionary).has("cells"): continue
		var cells: PackedByteArray = c["cells"]
		for j in range(cells.size()): cells[j] = shift.call(cells[j])
		c["cells"] = cells
	cell_palette.remove_at(k)
	_build_cell_array()
	if _cell_array == null:
		for i in range(_chunks.size()):
			(_chunks[i] as Dictionary).erase("cells_mat")
			if i < _chunk_roots.size() and _chunk_roots[i] != null:
				_set_h1_material(i, _mat_cave_surface if is_cave_type((_chunks[i] as Dictionary).type) else _mat_plains)
	_refresh_all_cells()


# Undo: every chunk's cells by grid coord (survives add_chunk_at re-indexing).
func cells_snapshot() -> Dictionary:
	var snap := {}
	for i in range(_chunks.size()):
		var c := _chunks[i] as Dictionary
		if c.has("cells"): snap[_chunk_grid(i)] = (c["cells"] as PackedByteArray).duplicate()
	return snap


func cells_restore(snap: Dictionary) -> void:
	for i in range(_chunks.size()):
		var c := _chunks[i] as Dictionary
		var key := _chunk_grid(i)
		if snap.has(key):
			c["cells"] = (snap[key] as PackedByteArray).duplicate()
		elif c.has("cells"):
			var cells: PackedByteArray = c["cells"]
			cells.fill(0)
			c["cells"] = cells
		if c.has("cells"): _refresh_cells(i)


# ── Undo helpers ─────────────────────────────────────────────────────────────
# Terrain undo copies only the chunks a stroke touches (main.gd decides which),
# so these work per chunk, keyed by grid coord so the key survives
# add_chunk_at re-indexing. A chunk's state is its type, its h1/h2/h3 heights
# (PackedFloat32Array copies, NaN holes included), its glue, and its ocean sheet: the water rect covering exactly this
# chunk that [O] adds. Ocean sheets belong to terrain undo; object undo
# handles every other water rect (see is_ocean_sheet).

func terrain_chunk_state(i: int) -> Dictionary:
	var c: Dictionary = _chunks[i]
	var g = _glue.get(_chunk_grid_key(i))
	var sheets: Array = []
	for k in _ocean_sheet_indices(i):
		sheets.append((_water_rects[k] as Dictionary).duplicate(true))
	return {
		"type": c["type"],
		"h1": (c["h1"] as PackedFloat32Array).duplicate(),
		"h2": (c["h2"] as PackedFloat32Array).duplicate(),
		"h3": (c["h3"] as PackedFloat32Array).duplicate(),
		"glue": (g as Dictionary).duplicate() if g != null else null,
		"sheets": sheets,
	}


# Puts back states from terrain_chunk_state ({grid coord: state}) and
# rebuilds those chunks plus their neighbours, whose border normals read them.
# Chunks no longer in the loaded range are skipped. Callers respawn water.
func terrain_restore(states: Dictionary) -> void:
	var to_rebuild := {}
	for i in range(_chunks.size()):
		var key := _chunk_grid_key(i)
		if not states.has(key): continue
		var s: Dictionary = states[key]
		var c: Dictionary = _chunks[i]
		c["type"] = s["type"]
		for layer in ["h1", "h2", "h3"]:
			c[layer] = (s[layer] as PackedFloat32Array).duplicate()
		if s["glue"] == null: _glue.erase(key)
		else: _glue[key] = (s["glue"] as Dictionary).duplicate()
		var idx := _ocean_sheet_indices(i)
		idx.reverse()
		for k in idx: _water_rects.remove_at(k)
		for r in s["sheets"]: _water_rects.append((r as Dictionary).duplicate(true))
		var cx := i % chunks_x
		var cz := i / chunks_x
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var nx: int = cx + dx
				var nz: int = cz + dz
				if nx >= 0 and nz >= 0 and nx < chunks_x and nz < chunks_z:
					to_rebuild[nz * chunks_x + nx] = true
	for i in to_rebuild:
		rebuild_chunk(i)


# Indices into _water_rects of chunk i's ocean sheet(s), ascending.
func _ocean_sheet_indices(i: int) -> Array:
	var out: Array = []
	for k in range(_water_rects.size()):
		if _sheet_chunk(_water_rects[k] as Dictionary) == i: out.append(k)
	return out


# The chunk a water rect exactly covers (an [O] ocean sheet), or -1.
func _sheet_chunk(d: Dictionary) -> int:
	if d.get("is_waterfall", false): return -1
	var span := chunk_cells * cell_size
	if absf((d.width as float) - span) >= 0.01 or absf((d.depth as float) - span) >= 0.01: return -1
	var i := _chunk_at(d.x as float, d.z as float)
	if i < 0: return -1
	var o := _chunk_origin(i)
	if absf((d.x as float) - (o.x + span * 0.5)) >= 0.01 or absf((d.z as float) - (o.z + span * 0.5)) >= 0.01: return -1
	return i


func is_ocean_sheet(d: Dictionary) -> bool:
	return _sheet_chunk(d) >= 0


# Biome painting undo: every chunk's biome id by grid coord.
func chunk_biomes_snapshot() -> Dictionary:
	var snap := {}
	for i in range(_chunks.size()):
		snap[_chunk_grid_key(i)] = (_chunks[i] as Dictionary).get("biome", 0)
	return snap


func chunk_biomes_restore(snap: Dictionary) -> void:
	for i in range(_chunks.size()):
		var key := _chunk_grid_key(i)
		if snap.has(key): (_chunks[i] as Dictionary)["biome"] = snap[key]


# Rebuilds chunk i from its data if it's on screen; a chunk that isn't is
# built from the current data when the camera gets near it.
func rebuild_chunk(i: int) -> void:
	if i < 0 or i >= _chunk_roots.size() or _chunk_roots[i] == null: return
	_chunk_roots[i].queue_free()
	_chunk_roots[i] = null
	_spawn_chunk(i)


func make_cave_chunk(wx: float, wz: float, ceil_offset: float = -3.0, floor_offset: float = -8.0) -> void:
	var i := _chunk_at(wx, wz)
	if i < 0: return
	if is_cave_type((_chunks[i] as Dictionary)["type"]): return
	_promote_to_cave(i, ceil_offset, floor_offset)
	rebuild_chunk(i)


func _promote_to_cave(i: int, ceil_offset: float = -3.0, floor_offset: float = -8.0) -> void:
	var c: Dictionary = _chunks[i]
	c["type"] = CHUNK_OCEAN_CAVE if is_ocean_type(c["type"]) else CHUNK_CAVE
	var h1: PackedFloat32Array = c["h1"]
	var h2 := PackedFloat32Array()
	var h3 := PackedFloat32Array()
	h2.resize(h1.size())
	h3.resize(h1.size())
	for j in range(h1.size()):
		h2[j] = h1[j] + ceil_offset
		h3[j] = h1[j] + floor_offset
	c["h2"] = h2
	c["h3"] = h3


func revert_cave_chunk(wx: float, wz: float) -> void:
	var i := _chunk_at(wx, wz)
	if i < 0: return
	var c: Dictionary = _chunks[i]
	if not is_cave_type(c["type"]): return
	c["type"] = CHUNK_OCEAN if is_ocean_type(c["type"]) else CHUNK_TERRAIN
	c["h2"] = PackedFloat32Array()
	c["h3"] = PackedFloat32Array()
	_glue.erase(_chunk_grid_key(i))
	rebuild_chunk(i)


# Adds/removes the chunk's water sheet: a water rect covering exactly this
# chunk at water_y. Cave sheets are kept either way. Returns whether the
# chunk is now ocean.
func toggle_ocean_chunk(wx: float, wz: float, water_y: float) -> bool:
	var i := _chunk_at(wx, wz)
	if i < 0: return false
	var c: Dictionary = _chunks[i]
	var cave := is_cave_type(c["type"])
	var ocean := not is_ocean_type(c["type"])
	var span := chunk_cells * cell_size
	var o := _chunk_origin(i)
	var mx := o.x + span * 0.5
	var mz := o.z + span * 0.5
	var sheets := _ocean_sheet_indices(i)
	sheets.reverse()
	for k in sheets:
		_water_rects.remove_at(k)
	if ocean:
		add_water_rect(mx, mz, span, span, water_y)
		c["type"] = CHUNK_OCEAN_CAVE if cave else CHUNK_OCEAN
	else:
		c["type"] = CHUNK_CAVE if cave else CHUNK_TERRAIN
	return ocean


# Same triangle interpolation as _get_height_at, for any layer ("h1"/"h2"/"h3").
# NAN outside the world, on a layer the chunk doesn't have (h2/h3 on plains),
# or over a hole — mirrors World::sample_layers on the server.
func get_layer_height_at(wx: float, wz: float, layer: String) -> float:
	var i := _chunk_at(wx, wz)
	if i < 0: return NAN
	var h: PackedFloat32Array = (_chunks[i] as Dictionary).get(layer, PackedFloat32Array())
	if h.is_empty(): return NAN
	var stride := chunk_cells + 1
	var local_x := wx - world_ox - (i % chunks_x) * chunk_cells * cell_size
	var local_z := wz - world_oz - (i / chunks_x) * chunk_cells * cell_size
	var gx := clampi(int(local_x / cell_size), 0, chunk_cells - 1)
	var gz := clampi(int(local_z / cell_size), 0, chunk_cells - 1)
	var tl := gz * stride + gx
	var h00 := h[tl] as float
	var h10 := h[tl + 1] as float
	var h01 := h[tl + stride] as float
	var h11 := h[tl + stride + 1] as float
	if is_nan(h00) or is_nan(h10) or is_nan(h01) or is_nan(h11): return NAN
	var rx := local_x / cell_size - gx
	var rz := local_z / cell_size - gz
	if rx + rz <= 1.0:
		return h00 + (h10 - h00) * rx + (h01 - h00) * rz
	return h11 + (h01 - h11) * (1.0 - rx) + (h10 - h11) * (1.0 - rz)


func get_chunk_type(wx: float, wz: float) -> int:
	var i := _chunk_at(wx, wz)
	if i < 0: return 1
	return (_chunks[i] as Dictionary)["type"] as int


func _chunk_at(wx: float, wz: float) -> int:
	var cx := int((wx - world_ox) / (chunk_cells * cell_size))
	var cz := int((wz - world_oz) / (chunk_cells * cell_size))
	if cx < 0 or cz < 0 or cx >= chunks_x or cz >= chunks_z: return -1
	return cz * chunks_x + cx


func _brush_vertex_range(chunk_ox: float, chunk_oz: float, wx: float, wz: float, radius: float, stride: int) -> Array:
	var lx := wx - chunk_ox
	var lz := wz - chunk_oz
	var vx_min := clampi(int(floor((lx - radius) / cell_size)), 0, stride - 1)
	var vx_max := clampi(int(ceil ((lx + radius) / cell_size)), 0, stride - 1)
	var vz_min := clampi(int(floor((lz - radius) / cell_size)), 0, stride - 1)
	var vz_max := clampi(int(ceil ((lz + radius) / cell_size)), 0, stride - 1)
	return [vx_min, vx_max, vz_min, vz_max]


func _mark_border_neighbors(to_rebuild: Dictionary, i: int, rng: Array) -> void:
	var cx: int = i % chunks_x
	var cz: int = i / chunks_x
	if cx > 0 and rng[0] == 0:                        to_rebuild[cz * chunks_x + cx - 1] = true
	if cx < chunks_x - 1 and rng[1] == chunk_cells:  to_rebuild[cz * chunks_x + cx + 1] = true
	if cz > 0 and rng[2] == 0:                        to_rebuild[(cz - 1) * chunks_x + cx] = true
	if cz < chunks_z - 1 and rng[3] == chunk_cells:  to_rebuild[(cz + 1) * chunks_x + cx] = true


# Absolute vertex index of world position (wx, wz) — independent of the
# world origin, which is always a whole number of cells.
func vertex_key(wx: float, wz: float) -> Vector2i:
	return Vector2i(roundi(wx / cell_size), roundi(wz / cell_size))


# True when vertex_mask is set and vertex (vx, vz) of chunk i isn't in it.
func _masked_out(i: int, vx: int, vz: int) -> bool:
	if vertex_mask.is_empty(): return false
	return not vertex_mask.has(Vector2i((origin_cx + i % chunks_x) * chunk_cells + vx, (origin_cz + i / chunks_x) * chunk_cells + vz))


func raise_brush(wx: float, wz: float, radius: float, amount: float, layer: String = "h1") -> void:
	var ox     := world_ox
	var oz     := world_oz
	var stride := chunk_cells + 1
	var dirty  := {}
	var rng_by_chunk := {}

	for i in _chunks_near(wx, wz, radius):
		var c: Dictionary = _chunks[i]
		if layer != "h1" and (not is_cave_type(c["type"]) or (c[layer] as PackedFloat32Array).is_empty()): continue
		var cx       := i % chunks_x
		var cz       := i / chunks_x
		var chunk_ox := ox + cx * chunk_cells * cell_size
		var chunk_oz := oz + cz * chunk_cells * cell_size
		var h: PackedFloat32Array = c[layer]

		var rng: Array = _brush_vertex_range(chunk_ox, chunk_oz, wx, wz, radius, stride)
		rng_by_chunk[i] = rng
		if rng[0] > rng[1] or rng[2] > rng[3]: continue
		for vz in range(rng[2], rng[3] + 1):
			for vx in range(rng[0], rng[1] + 1):
				var vwx  := chunk_ox + vx * cell_size
				var vwz  := chunk_oz + vz * cell_size
				var dist := sqrt((vwx - wx) * (vwx - wx) + (vwz - wz) * (vwz - wz))
				if dist > radius or _masked_out(i, vx, vz): continue
				var idx := vz * stride + vx
				if is_nan(h[idx]): continue
				var falloff: float = 1.0 - dist / radius
				h[idx] += amount * falloff
				dirty[i] = true

	if dirty.is_empty(): return
	_stitch_around(layer, dirty)

	var to_rebuild := {}
	for i in dirty:
		to_rebuild[i] = true
		_mark_border_neighbors(to_rebuild, i, rng_by_chunk[i])
	_apply_glue(layer, to_rebuild)

	rebuild_area(wx - radius, wz - radius, wx + radius, wz + radius)


# The vertex nearest (wx, wz) on a layer, as (x, height, z) — height is NAN
# when it's a hole or the layer isn't there. Used by terrain-mode vertex selection.
func nearest_vertex(wx: float, wz: float, layer: String = "h1") -> Vector3:
	# Direct lookup in the owning chunk (a shared border vertex belongs to the
	# left/top chunk, as in brush_vertex_positions) — called per selected
	# vertex every frame, so it must not scan every chunk.
	var gx := roundi((wx - world_ox) / cell_size)
	var gz := roundi((wz - world_oz) / cell_size)
	var cx := clampi((gx - 1) / chunk_cells if gx > 0 else 0, 0, chunks_x - 1)
	var cz := clampi((gz - 1) / chunk_cells if gz > 0 else 0, 0, chunks_z - 1)
	var i  := cz * chunks_x + cx
	var o  := _chunk_origin(i)
	var vx := gx - cx * chunk_cells
	var vz := gz - cz * chunk_cells
	var px := o.x + vx * cell_size
	var pz := o.z + vz * cell_size
	if vx < 0 or vz < 0 or vx > chunk_cells or vz > chunk_cells: return Vector3(px, NAN, pz)
	var h: PackedFloat32Array = (_chunks[i] as Dictionary)[layer]
	if h.is_empty(): return Vector3(px, NAN, pz)
	return Vector3(px, h[vz * (chunk_cells + 1) + vx], pz)


# Sets each vertex in points (world x/z, y ignored) to an exact height.
# Used by terrain-mode vertex selection.
func set_vertices_height(points: Array, value: float, layer: String = "h1") -> bool:
	return _edit_vertices(points, layer, func(_h: float) -> float: return value)


# Moves each vertex in points up by amount (down when negative) — E/Q on a
# terrain-mode vertex selection.
func raise_vertices(points: Array, amount: float, layer: String = "h1") -> bool:
	return _edit_vertices(points, layer, func(h: float) -> float: return h + amount)


# Applies f(old height) -> new height to each vertex in points, in every
# chunk that shares it, then stitches and rebuilds once like the brushes do.
# Shared border vertices are counted once (the owning chunk's value is used
# for every copy) so a raise doesn't apply twice.
func _edit_vertices(points: Array, layer: String, f: Callable) -> bool:
	var stride := chunk_cells + 1
	var dirty  := {}  # chunk -> [vx_min, vx_max, vz_min, vz_max] actually touched
	for p in points:
		var gx := roundi(((p as Vector3).x - world_ox) / cell_size)
		var gz := roundi(((p as Vector3).z - world_oz) / cell_size)
		# Only the 1-4 chunks that hold a copy of this vertex.
		var cx0 := maxi((gx - 1) / chunk_cells if gx > 0 else 0, 0)
		var cz0 := maxi((gz - 1) / chunk_cells if gz > 0 else 0, 0)
		var cx1 := mini(gx / chunk_cells, chunks_x - 1)
		var cz1 := mini(gz / chunk_cells, chunks_z - 1)
		var new_h := NAN
		for cz in range(cz0, cz1 + 1):
			for cx in range(cx0, cx1 + 1):
				var vx := gx - cx * chunk_cells
				var vz := gz - cz * chunk_cells
				if vx < 0 or vz < 0 or vx >= stride or vz >= stride: continue
				var i := cz * chunks_x + cx
				var h: PackedFloat32Array = (_chunks[i] as Dictionary)[layer]
				if h.is_empty(): continue
				var idx := vz * stride + vx
				if is_nan(h[idx]): continue
				if is_nan(new_h): new_h = f.call(h[idx] as float)  # once per vertex, not per copy
				h[idx] = new_h
				if not dirty.has(i):
					dirty[i] = [vx, vx, vz, vz]
				else:
					var r: Array = dirty[i]
					r[0] = mini(r[0], vx); r[1] = maxi(r[1], vx)
					r[2] = mini(r[2], vz); r[3] = maxi(r[3], vz)
	if dirty.is_empty(): return false
	var bx0 := INF; var bz0 := INF; var bx1 := -INF; var bz1 := -INF
	for p in points:
		bx0 = minf(bx0, (p as Vector3).x); bx1 = maxf(bx1, (p as Vector3).x)
		bz0 = minf(bz0, (p as Vector3).z); bz1 = maxf(bz1, (p as Vector3).z)
	_stitch_around(layer, dirty)
	var to_rebuild := {}
	for i in dirty:
		to_rebuild[i] = true
		_mark_border_neighbors(to_rebuild, i, dirty[i])
	_apply_glue(layer, to_rebuild)
	rebuild_area(bx0, bz0, bx1, bz1)
	return true


func fill_brush(wx: float, wz: float, radius: float, layer: String = "h1") -> void:
	var ox     := world_ox
	var oz     := world_oz
	var stride := chunk_cells + 1
	var dirty  := {}
	var rng_by_chunk := {}
	for i in _chunks_near(wx, wz, radius):
		var c: Dictionary = _chunks[i]
		if layer != "h1" and (not is_cave_type(c["type"]) or (c[layer] as PackedFloat32Array).is_empty()): continue
		var cx: int = i % chunks_x
		var cz: int = i / chunks_x
		var cox := ox + cx * chunk_cells * cell_size
		var coz := oz + cz * chunk_cells * cell_size
		var h: PackedFloat32Array = c[layer]
		var rng: Array = _brush_vertex_range(cox, coz, wx, wz, radius, stride)
		rng_by_chunk[i] = rng
		if rng[0] > rng[1] or rng[2] > rng[3]: continue
		for vz in range(rng[2], rng[3] + 1):
			for vx in range(rng[0], rng[1] + 1):
				if not is_nan(h[vz * stride + vx]): continue
				var dist := sqrt((cox + vx*cell_size - wx)**2 + (coz + vz*cell_size - wz)**2)
				if dist > radius or _masked_out(i, vx, vz): continue
				var sum := 0.0
				var count := 0
				for dvz in [-1, 0, 1]:
					for dvx in [-1, 0, 1]:
						if dvz == 0 and dvx == 0: continue
						var nvx: int = vx + (dvx as int)
						var nvz: int = vz + (dvz as int)
						if nvx < 0 or nvx >= stride or nvz < 0 or nvz >= stride: continue
						var nv: float = h[nvz * stride + nvx]
						if not is_nan(nv):
							sum += nv
							count += 1
				if count == 0: continue
				h[vz * stride + vx] = sum / count
				dirty[i] = true
	if dirty.is_empty(): return
	_stitch_around(layer, dirty)
	var to_rebuild := {}
	for i in dirty:
		to_rebuild[i] = true
		_mark_border_neighbors(to_rebuild, i, rng_by_chunk[i])
	_apply_glue(layer, to_rebuild)
	rebuild_area(wx - radius, wz - radius, wx + radius, wz + radius)


# An h1 hole with nothing under it is just a pit into the void, so holing h1
# promotes the chunk to a cave first and glues the hole's rim to h2 (h1 drops
# onto the cave ceiling): every h1 hole is a cave entrance.
func hole_brush(wx: float, wz: float, radius: float, layer: String = "h1") -> void:
	var ox     := world_ox
	var oz     := world_oz
	var stride := chunk_cells + 1
	var dirty  := {}
	var rng_by_chunk := {}
	for i in _chunks_near(wx, wz, radius):
		var c: Dictionary = _chunks[i]
		if layer != "h1" and (not is_cave_type(c["type"]) or (c[layer] as PackedFloat32Array).is_empty()): continue
		var cx: int = i % chunks_x
		var cz: int = i / chunks_x
		var cox := ox + cx * chunk_cells * cell_size
		var coz := oz + cz * chunk_cells * cell_size
		var h: PackedFloat32Array = c[layer]
		var rng: Array = _brush_vertex_range(cox, coz, wx, wz, radius, stride)
		rng_by_chunk[i] = rng
		if rng[0] > rng[1] or rng[2] > rng[3]: continue
		for vz in range(rng[2], rng[3] + 1):
			for vx in range(rng[0], rng[1] + 1):
				var dist := sqrt((cox + vx*cell_size - wx)**2 + (coz + vz*cell_size - wz)**2)
				if dist > radius or _masked_out(i, vx, vz): continue
				if layer == "h1" and not is_cave_type(c["type"]):
					_promote_to_cave(i)  # before the first NaN, so h2/h3 are derived from intact h1
				h[vz * stride + vx] = NAN
				dirty[i] = true
	if dirty.is_empty(): return
	var to_rebuild := {}
	for i in dirty:
		to_rebuild[i] = true
		_mark_border_neighbors(to_rebuild, i, rng_by_chunk[i])
	if layer == "h1":
		_glue_hole_rims(dirty, rng_by_chunk)
		_apply_glue("h2", to_rebuild)
	rebuild_area(wx - radius, wz - radius, wx + radius, wz + radius)


func snap_brush(wx: float, wz: float, radius: float, layer: String = "h1") -> void:
	# h1↔h2 swap as before.
	# h3: snaps to first valid layer above — h2 if solid, else h1 if solid, else skip.
	if layer not in ["h1", "h2", "h3"]: return
	var ox     := world_ox
	var oz     := world_oz
	var stride := chunk_cells + 1
	var dirty  := {}
	var rng_by_chunk := {}
	for i in _chunks_near(wx, wz, radius):
		var c: Dictionary = _chunks[i]
		if not is_cave_type(c["type"]) or (c[layer] as PackedFloat32Array).is_empty(): continue
		var cx: int = i % chunks_x
		var cz: int = i / chunks_x
		var cox := ox + cx * chunk_cells * cell_size
		var coz := oz + cz * chunk_cells * cell_size
		var src: PackedFloat32Array = c[layer]
		var glued = _glue.get(_chunk_grid_key(i))
		var rng: Array = _brush_vertex_range(cox, coz, wx, wz, radius, stride)
		rng_by_chunk[i] = rng
		if rng[0] > rng[1] or rng[2] > rng[3]: continue
		for vz in range(rng[2], rng[3] + 1):
			for vx in range(rng[0], rng[1] + 1):
				var idx := vz * stride + vx
				if is_nan(src[idx]): continue
				if layer != "h3" and glued != null and (glued as Dictionary).has(idx): continue
				var dist := sqrt((cox + vx*cell_size - wx)**2 + (coz + vz*cell_size - wz)**2)
				if dist > radius or _masked_out(i, vx, vz): continue
				var val := _snap_value(c, idx, layer)
				if is_nan(val): continue
				src[idx] = val
				dirty[i] = true
	if dirty.is_empty(): return
	_stitch_around(layer, dirty)
	rebuild_area(wx - radius, wz - radius, wx + radius, wz + radius)


# What N sets vertex idx of cave chunk c's `layer` to: h1 and h2 swap onto
# each other, h3 goes to the first solid layer above it (h2, else h1). NAN =
# nothing to snap to (the other layer is a hole there).
func _snap_value(c: Dictionary, idx: int, layer: String) -> float:
	var h1v: float = (c["h1"] as PackedFloat32Array)[idx]
	var h2v: float = (c["h2"] as PackedFloat32Array)[idx]
	match layer:
		"h1": return h2v
		"h2": return h1v
		"h3": return h2v if not is_nan(h2v) else h1v
	return NAN


# N with a terrain-mode vertex selection: snaps every selected vertex
# (points: world x/z, y ignored), wherever the cursor is. Glued pairs are left
# alone on h1/h2, as with the brush. Returns how many vertices moved.
func snap_vertices(points: Array, layer: String = "h1") -> int:
	if layer not in ["h1", "h2", "h3"]: return 0
	var stride := chunk_cells + 1
	var dirty  := {}  # chunk -> [vx_min, vx_max, vz_min, vz_max] touched
	var moved  := 0
	for p in points:
		var gx := roundi(((p as Vector3).x - world_ox) / cell_size)
		var gz := roundi(((p as Vector3).z - world_oz) / cell_size)
		var cx0 := maxi((gx - 1) / chunk_cells if gx > 0 else 0, 0)
		var cz0 := maxi((gz - 1) / chunk_cells if gz > 0 else 0, 0)
		var cx1 := mini(gx / chunk_cells, chunks_x - 1)
		var cz1 := mini(gz / chunk_cells, chunks_z - 1)
		var new_h := NAN  # taken from the first (owning) chunk, written to every copy
		for cz in range(cz0, cz1 + 1):
			for cx in range(cx0, cx1 + 1):
				var vx := gx - cx * chunk_cells
				var vz := gz - cz * chunk_cells
				if vx < 0 or vz < 0 or vx >= stride or vz >= stride: continue
				var i := cz * chunks_x + cx
				var c: Dictionary = _chunks[i]
				if not is_cave_type(c["type"]): continue
				var h: PackedFloat32Array = c[layer]
				if h.is_empty(): continue
				var idx := vz * stride + vx
				if is_nan(h[idx]): continue
				if layer != "h3" and _is_glued(i, idx): continue
				if is_nan(new_h):
					new_h = _snap_value(c, idx, layer)
					if is_nan(new_h): continue
					if h[idx] != new_h: moved += 1
				h[idx] = new_h
				if not dirty.has(i):
					dirty[i] = [vx, vx, vz, vz]
				else:
					var r: Array = dirty[i]
					r[0] = mini(r[0], vx); r[1] = maxi(r[1], vx)
					r[2] = mini(r[2], vz); r[3] = maxi(r[3], vz)
	if dirty.is_empty(): return 0
	var bx0 := INF; var bz0 := INF; var bx1 := -INF; var bz1 := -INF
	for p in points:
		bx0 = minf(bx0, (p as Vector3).x); bx1 = maxf(bx1, (p as Vector3).x)
		bz0 = minf(bz0, (p as Vector3).z); bz1 = maxf(bz1, (p as Vector3).z)
	_stitch_around(layer, dirty)
	rebuild_area(bx0, bz0, bx1, bz1)
	return moved


func smooth_brush(wx: float, wz: float, radius: float, strength: float, layer: String = "h1") -> void:
	var ox     := world_ox
	var oz     := world_oz
	var stride := chunk_cells + 1

	# Pass 1 — collect every vertex inside the brush and compute their mean.
	# Using the global mean (not per-vertex neighbour average) means holding F
	# long enough fully levels the area to a single height with no bias.
	var gathered: Array = []   # [{chunk_i, idx, falloff}]
	var mean_sum   := 0.0
	var mean_count := 0
	var rng_by_chunk := {}

	for i in _chunks_near(wx, wz, radius):
		var c: Dictionary = _chunks[i]
		if layer != "h1" and (not is_cave_type(c["type"]) or (c[layer] as PackedFloat32Array).is_empty()): continue
		var cxi: int = i % chunks_x
		var czi: int = i / chunks_x
		var cox  := ox + cxi * chunk_cells * cell_size
		var coz  := oz + czi * chunk_cells * cell_size
		var h: PackedFloat32Array = c[layer]
		var rng: Array = _brush_vertex_range(cox, coz, wx, wz, radius, stride)
		rng_by_chunk[i] = rng
		if rng[0] > rng[1] or rng[2] > rng[3]: continue
		for vz in range(rng[2], rng[3] + 1):
			for vx in range(rng[0], rng[1] + 1):
				var dist := sqrt((cox + vx * cell_size - wx) ** 2 + (coz + vz * cell_size - wz) ** 2)
				if dist > radius or _masked_out(i, vx, vz): continue
				var idx := vz * stride + vx
				var val := h[idx] as float
				if is_nan(val): continue
				mean_sum   += val
				mean_count += 1
				gathered.append({"ci": i, "idx": idx, "falloff": 1.0 - dist / radius})

	if mean_count == 0: return
	var mean := mean_sum / mean_count

	# Pass 2 — push each vertex toward the global mean.
	# strength * falloff is clamped to [0,1] so a single update can reach the mean.
	var dirty := {}
	for entry in gathered:
		var ci: int      = entry["ci"]
		var idx: int     = entry["idx"]
		var falloff: float = entry["falloff"]
		var h: PackedFloat32Array = (_chunks[ci] as Dictionary)[layer]
		h[idx] = lerpf(h[idx] as float, mean, clampf(strength * falloff, 0.0, 1.0))
		dirty[ci] = true

	_stitch_around(layer, dirty)
	var to_rebuild := {}
	for i in dirty:
		to_rebuild[i] = true
		_mark_border_neighbors(to_rebuild, i, rng_by_chunk[i])
	_apply_glue(layer, to_rebuild)
	rebuild_area(wx - radius, wz - radius, wx + radius, wz + radius)


# Alt+click with the Snap tool. Glues (on) or unglues (off) the h1/h2 pairs
# under the brush; the radius never drops below the cell half-diagonal, so a
# click always catches at least the nearest vertex. On glue, the layer that
# isn't `anchor` jumps to it ± GLUE_OFFSET. Returns how many pairs changed.
func glue_brush(wx: float, wz: float, radius: float, anchor: String, on: bool) -> int:
	if anchor not in ["h1", "h2"]: return 0
	var r      := maxf(radius, cell_size * 0.75)
	var stride := chunk_cells + 1
	var changed := 0
	var dirty  := {}
	var rng_by_chunk := {}
	for i in _chunks_near(wx, wz, r):
		var c: Dictionary = _chunks[i]
		if not is_cave_type(c["type"]) or (c["h2"] as PackedFloat32Array).is_empty(): continue
		var o   := _chunk_origin(i)
		var rng: Array = _brush_vertex_range(o.x, o.z, wx, wz, r, stride)
		rng_by_chunk[i] = rng
		if rng[0] > rng[1] or rng[2] > rng[3]: continue
		var h1: PackedFloat32Array = c["h1"]
		var h2: PackedFloat32Array = c["h2"]
		for vz in range(rng[2], rng[3] + 1):
			for vx in range(rng[0], rng[1] + 1):
				var dist := sqrt((o.x + vx*cell_size - wx)**2 + (o.z + vz*cell_size - wz)**2)
				if dist > r or _masked_out(i, vx, vz): continue
				var idx := vz * stride + vx
				if is_nan(h1[idx]) or is_nan(h2[idx]): continue
				if _is_glued(i, idx) == on: continue
				_glue_vertex(i, vx, vz, on)
				changed += 1
				dirty[i] = true
	if dirty.is_empty(): return 0
	var to_rebuild := {}
	for i in dirty:
		to_rebuild[i] = true
		_mark_border_neighbors(to_rebuild, i, rng_by_chunk[i])
	if on: _apply_glue(anchor, to_rebuild)
	rebuild_area(wx - r, wz - r, wx + r, wz + r)
	return changed


# World positions of the solid `layer` vertices inside the brush — what the
# editor highlights before an edit. Shared border vertices are listed once.
func brush_vertex_positions(wx: float, wz: float, radius: float, layer: String) -> PackedVector3Array:
	var out    := PackedVector3Array()
	var stride := chunk_cells + 1
	for i in _chunks_near(wx, wz, radius):
		var c: Dictionary = _chunks[i]
		var h: PackedFloat32Array = c[layer]
		if h.is_empty(): continue
		var o   := _chunk_origin(i)
		var rng: Array = _brush_vertex_range(o.x, o.z, wx, wz, radius, stride)
		if rng[0] > rng[1] or rng[2] > rng[3]: continue
		for vz in range(rng[2], rng[3] + 1):
			for vx in range(rng[0], rng[1] + 1):
				if (vx == 0 and i % chunks_x > 0) or (vz == 0 and i / chunks_x > 0): continue  # owned by the neighbour
				var px := o.x + vx * cell_size
				var pz := o.z + vz * cell_size
				if (px - wx) ** 2 + (pz - wz) ** 2 > radius * radius: continue
				var v: float = h[vz * stride + vx]
				if is_nan(v): continue
				out.append(Vector3(px, v, pz))
	return out


func _chunk_grid_key(i: int) -> Vector2i:
	return Vector2i(origin_cx + i % chunks_x, origin_cz + i / chunks_x)


func _is_glued(i: int, idx: int) -> bool:
	var g = _glue.get(_chunk_grid_key(i))
	return g != null and (g as Dictionary).has(idx)


# Glues/unglues vertex (vx, vz) of chunk i plus its copies in neighbouring
# chunks when it sits on a shared border — stitching copies border values
# between chunks, so an unglued copy would overwrite the glued one.
func _glue_vertex(i: int, vx: int, vz: int, on: bool) -> void:
	var stride := chunk_cells + 1
	var cx := i % chunks_x
	var cz := i / chunks_x
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var ncx: int = cx + dx
			var ncz: int = cz + dz
			if ncx < 0 or ncz < 0 or ncx >= chunks_x or ncz >= chunks_z: continue
			var lvx: int = vx - dx * chunk_cells
			var lvz: int = vz - dz * chunk_cells
			if lvx < 0 or lvz < 0 or lvx >= stride or lvz >= stride: continue
			var key := Vector2i(origin_cx + ncx, origin_cz + ncz)
			if on:
				if not _glue.has(key): _glue[key] = {}
				(_glue[key] as Dictionary)[lvz * stride + lvx] = true
			elif _glue.has(key):
				(_glue[key] as Dictionary).erase(lvz * stride + lvx)


# After an edit to `edited` (h1 or h2), moves the other layer of every glued
# pair in chunk_ids to follow it, then re-stitches that layer's borders.
func _apply_glue(edited: String, chunk_ids: Dictionary) -> void:
	if _glue.is_empty() or edited not in ["h1", "h2"]: return
	var moved := false
	for i in chunk_ids:
		var g = _glue.get(_chunk_grid_key(i))
		if g == null: continue
		var c: Dictionary = _chunks[i]
		if not is_cave_type(c["type"]): continue
		var h1: PackedFloat32Array = c["h1"]
		var h2: PackedFloat32Array = c["h2"]
		if h2.is_empty(): continue
		for idx in (g as Dictionary):
			if is_nan(h1[idx]) or is_nan(h2[idx]): continue
			if edited == "h1": h2[idx] = (h1[idx] as float) - GLUE_OFFSET
			else:              h1[idx] = (h2[idx] as float) + GLUE_OFFSET
			moved = true
	if moved: _stitch_around("h2" if edited == "h1" else "h1", chunk_ids)


# Glues every solid h1 vertex next to an h1 hole (8-neighbour) to h2, so the
# hole's rim meets the cave ceiling. Scans each dirty chunk's brush range
# plus one cell, which is where a rim can appear.
func _glue_hole_rims(dirty: Dictionary, rng_by_chunk: Dictionary) -> void:
	var stride := chunk_cells + 1
	for i in dirty:
		var c: Dictionary = _chunks[i]
		if not is_cave_type(c["type"]) or (c["h2"] as PackedFloat32Array).is_empty(): continue
		var h1: PackedFloat32Array = c["h1"]
		var rng: Array = rng_by_chunk[i]
		for vz in range(maxi(rng[2] - 1, 0), mini(rng[3] + 1, chunk_cells) + 1):
			for vx in range(maxi(rng[0] - 1, 0), mini(rng[1] + 1, chunk_cells) + 1):
				var idx := vz * stride + vx
				if is_nan(h1[idx]) or _is_glued(i, idx): continue
				var on_rim := false
				for dz in [-1, 0, 1]:
					for dx in [-1, 0, 1]:
						var nvx: int = vx + dx
						var nvz: int = vz + dz
						if nvx < 0 or nvz < 0 or nvx >= stride or nvz >= stride: continue
						if is_nan(h1[nvz * stride + nvx]): on_rim = true
				if on_rim: _glue_vertex(i, vx, vz, true)


# Indices of the chunks whose area (edges included — border vertices are
# shared) overlaps the square around (wx, wz) ± radius. Brushes only visit
# these, so an edit costs the same however big the world is.
func _chunks_near(wx: float, wz: float, radius: float) -> Array[int]:
	var w   := chunk_cells * cell_size
	var cx0 := maxi(ceili((wx - radius - world_ox) / w) - 1, 0)
	var cx1 := mini(floori((wx + radius - world_ox) / w), chunks_x - 1)
	var cz0 := maxi(ceili((wz - radius - world_oz) / w) - 1, 0)
	var cz1 := mini(floori((wz + radius - world_oz) / w), chunks_z - 1)
	var out: Array[int] = []
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			out.append(cz * chunks_x + cx)
	return out


# _stitch_all_borders limited to the chunks in ids (dict keys) and their 8
# neighbours — same copy direction (left->right, then top->bottom), so the
# result matches the full stitch; everything farther out is already in sync.
func _stitch_around(layer: String, ids: Dictionary) -> void:
	var stride := chunk_cells + 1
	var area := {}
	for i in ids:
		var cx: int = i % chunks_x
		var cz: int = i / chunks_x
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var nx: int = cx + dx
				var nz: int = cz + dz
				if nx >= 0 and nz >= 0 and nx < chunks_x and nz < chunks_z:
					area[nz * chunks_x + nx] = true
	for i in area:
		if i % chunks_x == chunks_x - 1: continue
		var lh: PackedFloat32Array = (_chunks[i] as Dictionary)[layer]
		var rh: PackedFloat32Array = (_chunks[i + 1] as Dictionary)[layer]
		if lh.is_empty() or rh.is_empty(): continue
		for vz in range(stride):
			rh[vz * stride] = lh[vz * stride + chunk_cells]
	for i in area:
		if i / chunks_x == chunks_z - 1: continue
		var th: PackedFloat32Array = (_chunks[i] as Dictionary)[layer]
		var bh: PackedFloat32Array = (_chunks[i + chunks_x] as Dictionary)[layer]
		if th.is_empty() or bh.is_empty(): continue
		for vx in range(stride):
			bh[vx] = th[chunk_cells * stride + vx]


func _stitch_all_borders(layer: String = "h1") -> void:
	var stride := chunk_cells + 1
	for cz in range(chunks_z):
		for cx in range(chunks_x - 1):
			var lh: PackedFloat32Array = (_chunks[cz * chunks_x + cx] as Dictionary)[layer]
			var rh: PackedFloat32Array = (_chunks[cz * chunks_x + cx + 1] as Dictionary)[layer]
			if lh.is_empty() or rh.is_empty(): continue
			for vz in range(stride):
				rh[vz * stride] = lh[vz * stride + chunk_cells]
	for cz in range(chunks_z - 1):
		for cx in range(chunks_x):
			var th: PackedFloat32Array = (_chunks[cz * chunks_x + cx] as Dictionary)[layer]
			var bh: PackedFloat32Array = (_chunks[(cz + 1) * chunks_x + cx] as Dictionary)[layer]
			if th.is_empty() or bh.is_empty(): continue
			for vx in range(stride):
				bh[vx] = th[chunk_cells * stride + vx]


func _chunk_origin(i: int) -> Vector3:
	var cx := i % chunks_x
	var cz := i / chunks_x
	return Vector3(world_ox + cx * chunk_cells * cell_size, 0.0, world_oz + cz * chunk_cells * cell_size)


# Each built chunk is split into TILE_CELLS x TILE_CELLS-cell tiles, each
# with its own meshes, collision and vertex markers, so a brush stroke only
# rebuilds the tiles it touched (rebuild_area) instead of the whole chunk —
# a full 128x128-cell chunk costs ~60 ms to build, a tile ~1 ms. Tiles live
# under the chunk root (root.get_meta("tiles"), index tz * n + tx) and keep
# chunk-local coordinates, so a tile is positioned by its chunk root alone.
const TILE_CELLS := 16


func _tiles_per_side() -> int:
	return ceili(chunk_cells / float(TILE_CELLS))


# Markers for the vertices of cells [x0, x1) x [z0, z1); a tile owns its low
# edges, and the chunk's last tiles also own its far edge, so no vertex is
# drawn twice.
func _make_vertex_markers(h: PackedFloat32Array, mat: StandardMaterial3D, size_mul: float,
		x0: int, x1: int, z0: int, z1: int) -> MultiMeshInstance3D:
	var stride    := chunk_cells + 1
	var xe := x1 + (1 if x1 == chunk_cells else 0)
	var ze := z1 + (1 if z1 == chunk_cells else 0)
	var positions := PackedVector3Array()
	for gz in range(z0, ze):
		for gx in range(x0, xe):
			var val := h[gz * stride + gx] as float
			if is_nan(val): continue
			positions.append(Vector3(gx * cell_size, val, gz * cell_size))
	if positions.is_empty():
		return null
	var r  := minf(cell_size * 0.03, 0.12) * size_mul
	var sp := SphereMesh.new()
	sp.radius          = r
	sp.height          = r * 2.0
	sp.radial_segments = 4
	sp.rings           = 2
	sp.surface_set_material(0, mat)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh             = sp
	mm.instance_count   = positions.size()
	for j in range(positions.size()):
		mm.set_instance_transform(j, Transform3D(Basis.IDENTITY, positions[j]))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	return mmi


# deferred = streaming: the root and its material now, the tiles later from
# update_streaming's _tile_queue (null until built).
func _spawn_chunk(i: int, deferred: bool = false) -> void:
	var chunk: Dictionary = _chunks[i]
	var root   := Node3D.new()
	root.position = _chunk_origin(i)
	_parent.add_child(root)
	_chunk_roots[i] = root
	# The h1 material is per chunk (painted cells), built once and shared by its tiles.
	root.set_meta("h1_mat", _surface_mat_for(i, _mat_cave_surface if is_cave_type(chunk.type) else _mat_plains))
	var n := _tiles_per_side()
	var tiles: Array = []
	tiles.resize(n * n)
	root.set_meta("tiles", tiles)
	for t in range(n * n):
		if deferred:
			_tile_queue.append([i, t])
		else:
			tiles[t] = _build_tile(i, t)
			root.add_child(tiles[t])


func _build_tile(i: int, t: int) -> Node3D:
	var chunk: Dictionary = _chunks[i]
	var n  := _tiles_per_side()
	var x0 := (t % n) * TILE_CELLS
	var z0 := (t / n) * TILE_CELLS
	var x1 := mini(x0 + TILE_CELLS, chunk_cells)
	var z1 := mini(z0 + TILE_CELLS, chunk_cells)
	var tile := Node3D.new()
	var root := _chunk_roots[i] as Node3D
	_add_layer(tile, i, chunk.h1, root.get_meta("h1_mat") as Material, _mat_v_h1, x0, x1, z0, z1, "h1")
	if is_cave_type(chunk.type) and (chunk.h2 as PackedFloat32Array).size() > 0:
		_add_layer(tile, i, chunk.h2, _mat_cave_surface, _mat_v_h2, x0, x1, z0, z1, "h2")
		var g = _glue.get(_chunk_grid_key(i))
		if g != null and not (g as Dictionary).is_empty():
			var glued_h1 := PackedFloat32Array()
			glued_h1.resize((chunk.h1 as PackedFloat32Array).size())
			glued_h1.fill(NAN)
			for idx in (g as Dictionary): glued_h1[idx] = chunk.h1[idx]
			var vmg := _make_vertex_markers(glued_h1, _mat_v_glue, 1.8, x0, x1, z0, z1)
			if vmg: tile.add_child(vmg)
		_add_layer(tile, i, chunk.h3, _mat_cave_floor, _mat_v_h3, x0, x1, z0, z1, "h3")
	return tile


# One layer of a tile: mesh (named after the layer), vertex markers, collision.
func _add_layer(tile: Node3D, i: int, h: PackedFloat32Array, mat: Material, marker_mat: StandardMaterial3D,
		x0: int, x1: int, z0: int, z1: int, layer: String) -> void:
	var mi := _make_mesh_instance(h, mat, x0, x1, z0, z1)
	if mi:
		mi.name = layer
		tile.add_child(mi)
	var vm := _make_vertex_markers(h, marker_mat, 1.0, x0, x1, z0, z1)
	if vm: tile.add_child(vm)
	var faces := _build_faces(h, x0, x1, z0, z1)
	if faces.is_empty(): return
	var body  := StaticBody3D.new()
	body.set_meta("chunk_index", i)
	var col   := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	col.shape = shape
	body.add_child(col)
	tile.add_child(body)


# Rebuilds the tiles (of built chunks) touching the world rect, padded by two
# cells: an edited vertex changes its neighbours' normals, and hole rims /
# glue reach one cell further. What brushes call instead of rebuild_chunk.
func rebuild_area(x0: float, z0: float, x1: float, z1: float) -> void:
	if _parent == null: return
	var pad := cell_size * 2.0
	x0 -= pad; z0 -= pad; x1 += pad; z1 += pad
	var w  := chunk_cells * cell_size
	var n  := _tiles_per_side()
	var cx0 := maxi(floori((x0 - world_ox) / w), 0)
	var cx1 := mini(floori((x1 - world_ox) / w), chunks_x - 1)
	var cz0 := maxi(floori((z0 - world_oz) / w), 0)
	var cz1 := mini(floori((z1 - world_oz) / w), chunks_z - 1)
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			var i := cz * chunks_x + cx
			if i >= _chunk_roots.size() or _chunk_roots[i] == null: continue
			var root := _chunk_roots[i] as Node3D
			var tiles: Array = root.get_meta("tiles")
			var o := _chunk_origin(i)
			# Cells [lx0, lx1] in this chunk; a tile holds cells [tx*T, tx*T+T).
			var lx0 := clampi(floori((x0 - o.x) / cell_size), 0, chunk_cells - 1)
			var lx1 := clampi(floori((x1 - o.x) / cell_size), 0, chunk_cells - 1)
			var lz0 := clampi(floori((z0 - o.z) / cell_size), 0, chunk_cells - 1)
			var lz1 := clampi(floori((z1 - o.z) / cell_size), 0, chunk_cells - 1)
			for tz in range(lz0 / TILE_CELLS, lz1 / TILE_CELLS + 1):
				for tx in range(lx0 / TILE_CELLS, lx1 / TILE_CELLS + 1):
					var t := tz * n + tx
					if tiles[t] == null: continue  # not streamed in yet — it'll be built from current data
					var fresh := _build_tile(i, t)
					root.add_child(fresh)
					(tiles[t] as Node3D).queue_free()
					tiles[t] = fresh


# Indexed grid mesh for cells [x0, x1) x [z0, z1), built straight into
# arrays (much faster than SurfaceTool + index + generate_normals). Normals
# come from the height field itself, so they match across tile edges.
func _make_mesh_instance(h: PackedFloat32Array, mat: Material, x0: int, x1: int, z0: int, z1: int) -> MeshInstance3D:
	var stride := chunk_cells + 1
	var w := x1 - x0 + 1
	var count := w * (z1 - z0 + 1)
	var verts := PackedVector3Array(); verts.resize(count)
	var norms := PackedVector3Array(); norms.resize(count)
	var k := 0
	for vz in range(z0, z1 + 1):
		for vx in range(x0, x1 + 1):
			var y: float = h[vz * stride + vx]
			verts[k] = Vector3(vx * cell_size, 0.0 if is_nan(y) else y, vz * cell_size)
			norms[k] = _grid_normal(h, vx, vz)
			k += 1
	var idx := PackedInt32Array()
	for gz in range(z0, z1):
		for gx in range(x0, x1):
			var tl := gz * stride + gx
			if is_nan(h[tl]) or is_nan(h[tl+1]) or is_nan(h[tl+stride]) or is_nan(h[tl+stride+1]):
				continue
			var a := (gz - z0) * w + (gx - x0)
			idx.append(a); idx.append(a + 1); idx.append(a + w)
			idx.append(a + 1); idx.append(a + w + 1); idx.append(a + w)
	if idx.is_empty(): return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX]  = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	return mi


# Height-field normal at vertex (vx, vz) of a chunk layer, from its solid
# neighbours (central difference, one-sided at holes and chunk edges).
func _grid_normal(h: PackedFloat32Array, vx: int, vz: int) -> Vector3:
	var stride := chunk_cells + 1
	var c: float = h[vz * stride + vx]
	if is_nan(c): return Vector3.UP
	var l: float = h[vz * stride + vx - 1] if vx > 0 else NAN
	var r: float = h[vz * stride + vx + 1] if vx < chunk_cells else NAN
	var u: float = h[(vz - 1) * stride + vx] if vz > 0 else NAN
	var d: float = h[(vz + 1) * stride + vx] if vz < chunk_cells else NAN
	var sx := 0.0
	var nx := (0 if is_nan(l) else 1) + (0 if is_nan(r) else 1)
	if nx > 0: sx = ((c if is_nan(r) else r) - (c if is_nan(l) else l)) / (nx * cell_size)
	var sz := 0.0
	var nz := (0 if is_nan(u) else 1) + (0 if is_nan(d) else 1)
	if nz > 0: sz = ((c if is_nan(d) else d) - (c if is_nan(u) else u)) / (nz * cell_size)
	return Vector3(-sx, 1.0, -sz).normalized()


func _normal_at(cx: int, cz: int, vx: int, vz: int) -> Vector3:
	var hr := _h1_at(cx, cz, vx + 1, vz)
	var hl := _h1_at(cx, cz, vx - 1, vz)
	var hd := _h1_at(cx, cz, vx,     vz + 1)
	var hu := _h1_at(cx, cz, vx,     vz - 1)
	if is_nan(hr) or is_nan(hl) or is_nan(hd) or is_nan(hu):
		return Vector3.UP
	return Vector3(-(hr - hl) / (2.0 * cell_size), 1.0, -(hd - hu) / (2.0 * cell_size)).normalized()


func _h1_at(cx: int, cz: int, vx: int, vz: int) -> float:
	var wvx := clampi(cx * chunk_cells + vx, 0, chunks_x * chunk_cells)
	var wvz := clampi(cz * chunk_cells + vz, 0, chunks_z * chunk_cells)
	var ncx  := mini(wvx / chunk_cells, chunks_x - 1)
	var nvx  := wvx - ncx * chunk_cells
	var ncz  := mini(wvz / chunk_cells, chunks_z - 1)
	var nvz  := wvz - ncz * chunk_cells
	var stride := chunk_cells + 1
	return (_chunks[ncz * chunks_x + ncx] as Dictionary)["h1"][nvz * stride + nvx]


func _build_faces(h: PackedFloat32Array, x0: int, x1: int, z0: int, z1: int) -> PackedVector3Array:
	var verts  := PackedVector3Array()
	var stride := chunk_cells + 1
	for gz in range(z0, z1):
		for gx in range(x0, x1):
			var tl := gz * stride + gx
			if is_nan(h[tl]) or is_nan(h[tl+1]) or is_nan(h[tl+stride]) or is_nan(h[tl+stride+1]):
				continue
			var v0 := Vector3(gx       * cell_size, h[tl],          gz       * cell_size)
			var v1 := Vector3((gx+1)   * cell_size, h[tl+1],        gz       * cell_size)
			var v2 := Vector3(gx       * cell_size, h[tl+stride],   (gz+1)   * cell_size)
			var v3 := Vector3((gx+1)   * cell_size, h[tl+stride+1], (gz+1)   * cell_size)
			verts.append_array([v0, v1, v2, v1, v3, v2])
	return verts


func _read_pstr(f: FileAccess) -> String:
	var n := f.get_8()
	if n == 0: return ""
	return f.get_buffer(n).get_string_from_utf8()

func _write_pstr(f: FileAccess, s: String) -> void:
	var b := s.to_utf8_buffer()
	var n := mini(b.size(), 255)
	f.store_8(n)
	if n > 0: f.store_buffer(b.slice(0, n))

# Reads one wall's carved-openings list — see _write_wall_openings and
# _compute_wall_carve for the format/semantics.
func _read_wall_openings(f: FileAccess) -> Array:
	var openings: Array = []
	var count := f.get_8()
	for _oi in range(count):
		openings.append({
			"x_min": f.get_float(), "x_max": f.get_float(),
			"y_min": f.get_float(), "y_max": f.get_float(),
			"z_min": f.get_float(), "z_max": f.get_float(),
		})
	return openings

func _write_wall_openings(f: FileAccess, openings: Array) -> void:
	f.store_8(mini(openings.size(), 255))
	for oi in range(mini(openings.size(), 255)):
		var op := openings[oi] as Dictionary
		f.store_float(op.x_min as float); f.store_float(op.x_max as float)
		f.store_float(op.y_min as float); f.store_float(op.y_max as float)
		f.store_float(op.z_min as float); f.store_float(op.z_max as float)

func set_chunk_biome(wx: float, wz: float, biome_id: int) -> void:
	var i := _chunk_at(wx, wz)
	if i < 0: return
	(_chunks[i] as Dictionary)["biome"] = biome_id

func get_chunk_biome(wx: float, wz: float) -> int:
	var i := _chunk_at(wx, wz)
	if i < 0: return 0
	return (_chunks[i] as Dictionary).get("biome", 0) as int

func get_biome_name(id_: int) -> String:
	for _bdef in _biomes:
		if (_bdef as Dictionary)["id"] == id_: return (_bdef as Dictionary).get("name", str(id_)) as String
	return str(id_)

func add_biome(name_: String, props_: Array) -> int:
	var next_id := 0
	for _bdef in _biomes: next_id = maxi(next_id, (_bdef as Dictionary)["id"] + 1)
	_biomes.append({ "id": next_id, "name": name_, "props": props_ })
	return next_id

func remove_biome(id_: int) -> void:
	for i in range(_biomes.size()):
		if (_biomes[i] as Dictionary)["id"] == id_:
			_biomes.remove_at(i)
			return

func ensure_prop_type(path: String) -> int:
	var idx := _prop_types.find(path)
	if idx >= 0: return idx
	_prop_types.append(path)
	return _prop_types.size() - 1

func add_prop_instance(type_idx: int, x: float, y: float, z: float, rot_y: float, sx: float, sy: float, sz: float) -> void:
	_prop_instances.append({ "type_idx": type_idx, "x": x, "y": y, "z": z, "rot_y": rot_y, "sx": sx, "sy": sy, "sz": sz })

func remove_props_in_radius(wx: float, wz: float, radius: float) -> int:
	var r2 := radius * radius
	var removed := 0
	var i := _prop_instances.size() - 1
	while i >= 0:
		var p := _prop_instances[i] as Dictionary
		var dx := (p["x"] as float) - wx
		var dz := (p["z"] as float) - wz
		if dx*dx + dz*dz <= r2:
			_prop_instances.remove_at(i)
			removed += 1
		i -= 1
	return removed


# --- Fragment import -------------------------------------------------------
# Merges another EditorWorldData (loaded from a separate .bin) into this one at a
# world-space offset. Always merges what it safely can — anything that can't
# be placed (misaligned/out-of-bounds terrain, a same-named-but-different
# biome) is skipped and reported in `warnings`, rather than aborting the
# whole import. `layers` is a Dictionary of booleans keyed by
# "terrain"/"objects"/"walls"/"water"/"props".
const _PROP_MERGE_EPSILON := 0.1

func import_from(source: EditorWorldData, offset_x: float, offset_z: float, layers: Dictionary) -> Dictionary:
	var warnings: Array[String] = []
	var imported := { "terrain": 0, "objects": 0, "walls": 0, "water": 0, "props": 0 }

	if layers.get("terrain", false):
		imported.terrain = _import_terrain(source, offset_x, offset_z, warnings)

	if layers.get("objects", false):
		for obj in source._static_objects:
			var d := obj as Dictionary
			var nx := (d.x as float) + offset_x
			var nz := (d.z as float) + offset_z
			var radius := d.radius as float
			_remove_overlapping_objects(nx, nz, radius)
			add_static_object(d.type as int, nx, nz, radius, d.height as float)
			imported.objects += 1

	if layers.get("walls", false):
		for w in source._walls:
			var d := w as Dictionary
			var nx := (d.x as float) + offset_x
			var nz := (d.z as float) + offset_z
			_remove_overlapping_walls(nx, nz, d.half_x as float, d.half_z as float)
			add_wall(d.type as int, nx, nz, d.half_x as float, d.half_z as float,
				d.rot_y as float, d.height as float, d.get("y_offset", 0.0) as float,
				(d.get("openings", []) as Array).duplicate())
			imported.walls += 1

	if layers.get("walls", false):  # pillars come along with the walls
		for p in source._pillars:
			var d := (p as Dictionary).duplicate()
			d.x = (d.x as float) + offset_x
			d.z = (d.z as float) + offset_z
			_pillars.append(d)

	if layers.get("water", false):
		for wr in source._water_rects:
			var d := wr as Dictionary
			var nx := (d.x as float) + offset_x
			var nz := (d.z as float) + offset_z
			_remove_overlapping_water(nx, nz, d.width as float, d.depth as float)
			add_water_rect(nx, nz, d.width as float, d.depth as float, d.y as float,
				d.get("is_waterfall", false) as bool)
			imported.water += 1

	if layers.get("props", false):
		for pi_ in source._prop_instances:
			var d := pi_ as Dictionary
			var nx := (d.x as float) + offset_x
			var nz := (d.z as float) + offset_z
			_remove_overlapping_props(nx, nz)
			var path := source._prop_types[d.type_idx as int] as String
			var idx := ensure_prop_type(path)
			add_prop_instance(idx, nx, d.y as float, nz, d.rot_y as float,
				d.sx as float, d.sy as float, d.sz as float)
			imported.props += 1

	return { "warnings": warnings, "imported": imported }


func _import_terrain(source: EditorWorldData, offset_x: float, offset_z: float, warnings: Array[String]) -> int:
	var chunk_span := chunk_cells * cell_size
	if not is_equal_approx(source.cell_size, cell_size) or source.chunk_cells != chunk_cells:
		warnings.append("Terrain skipped: fragment grid (cell_size=%.3f, chunk_cells=%d) doesn't match destination (cell_size=%.3f, chunk_cells=%d)"
			% [source.cell_size, source.chunk_cells, cell_size, chunk_cells])
		return 0
	if not is_equal_approx(fmod(offset_x, chunk_span), 0.0) or not is_equal_approx(fmod(offset_z, chunk_span), 0.0):
		warnings.append("Terrain skipped: offset (%.2f, %.2f) isn't aligned to the chunk grid (%.2f)"
			% [offset_x, offset_z, chunk_span])
		return 0

	var chunk_off_x := int(round(offset_x / chunk_span))
	var chunk_off_z := int(round(offset_z / chunk_span))
	var imported := 0
	for sz in range(source.chunks_z):
		for sx in range(source.chunks_x):
			var dst_gcx := source.origin_cx + sx + chunk_off_x
			var dst_gcz := source.origin_cz + sz + chunk_off_z
			var dax := dst_gcx - origin_cx
			var daz := dst_gcz - origin_cz
			if dax < 0 or dax >= chunks_x or daz < 0 or daz >= chunks_z:
				warnings.append("Terrain chunk (%d,%d) skipped: outside destination bounds" % [dst_gcx, dst_gcz])
				continue

			var src_chunk := source._chunks[sz * source.chunks_x + sx] as Dictionary
			var new_biome_id := _remap_biome(source, src_chunk.get("biome", 0) as int, warnings)
			if new_biome_id < 0:
				continue  # biome conflicts with an existing same-named one — chunk intentionally skipped

			_glue.erase(Vector2i(dst_gcx, dst_gcz))
			_chunks[daz * chunks_x + dax] = {
				"type": src_chunk.type,
				"biome": new_biome_id,
				"h1": (src_chunk.h1 as PackedFloat32Array).duplicate(),
				"h2": (src_chunk.h2 as PackedFloat32Array).duplicate(),
				"h3": (src_chunk.h3 as PackedFloat32Array).duplicate(),
			}
			imported += 1

	if imported > 0:
		_stitch_all_borders("h1")
		_stitch_all_borders("h2")
		_stitch_all_borders("h3")
	return imported


# Finds/creates the destination biome id that a fragment's chunk should use.
# Returns -1 if the fragment's biome shares a name with a destination biome
# but differs in content — the caller skips that chunk rather than risk
# silently reassigning it to the wrong biome.
func _remap_biome(source: EditorWorldData, src_biome_id: int, warnings: Array[String]) -> int:
	var src_def: Dictionary = {}
	for bd in source._biomes:
		if (bd as Dictionary).id == src_biome_id:
			src_def = bd as Dictionary
			break
	if src_def.is_empty():
		return 0  # fragment referenced a biome id it doesn't actually define — fall back to default

	for bd in _biomes:
		var dst_def := bd as Dictionary
		if dst_def.name != src_def.name:
			continue
		if _biomes_match(dst_def, src_def):
			return dst_def.id as int
		warnings.append("Biome '%s' differs from the destination's biome of the same name — its terrain was skipped"
			% (src_def.name as String))
		return -1

	return add_biome(src_def.name as String, (src_def.get("props", []) as Array).duplicate(true))


func _biomes_match(a: Dictionary, b: Dictionary) -> bool:
	var ap := a.get("props", []) as Array
	var bp := b.get("props", []) as Array
	if ap.size() != bp.size(): return false
	for i in range(ap.size()):
		var ad := ap[i] as Dictionary
		var bd := bp[i] as Dictionary
		if (ad.get("path", "") as String) != (bd.get("path", "") as String): return false
		if not is_equal_approx(ad.get("weight", 1.0) as float, bd.get("weight", 1.0) as float): return false
	return true


func _remove_overlapping_objects(x: float, z: float, radius: float) -> void:
	var i := _static_objects.size() - 1
	while i >= 0:
		var d := _static_objects[i] as Dictionary
		var dx := (d.x as float) - x
		var dz := (d.z as float) - z
		var rr := radius + (d.radius as float)
		if dx * dx + dz * dz <= rr * rr:
			_static_objects.remove_at(i)
		i -= 1


func _remove_overlapping_walls(x: float, z: float, half_x: float, half_z: float) -> void:
	var pad := maxf(half_x, half_z)
	var i := _walls.size() - 1
	while i >= 0:
		var d := _walls[i] as Dictionary
		var dpad := maxf(d.half_x as float, d.half_z as float)
		if absf((d.x as float) - x) <= pad + dpad and absf((d.z as float) - z) <= pad + dpad:
			_walls.remove_at(i)
		i -= 1


func _remove_overlapping_water(x: float, z: float, width: float, depth: float) -> void:
	var i := _water_rects.size() - 1
	while i >= 0:
		var d := _water_rects[i] as Dictionary
		if absf((d.x as float) - x) <= (width + (d.width as float)) * 0.5 \
		and absf((d.z as float) - z) <= (depth + (d.depth as float)) * 0.5:
			_water_rects.remove_at(i)
		i -= 1


func _remove_overlapping_props(x: float, z: float) -> void:
	var eps2 := _PROP_MERGE_EPSILON * _PROP_MERGE_EPSILON
	var i := _prop_instances.size() - 1
	while i >= 0:
		var d := _prop_instances[i] as Dictionary
		var dx := (d.x as float) - x
		var dz := (d.z as float) - z
		if dx * dx + dz * dz <= eps2:
			_prop_instances.remove_at(i)
		i -= 1
