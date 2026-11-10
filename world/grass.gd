# Stylised (Genshin-like) grass on the terrain's tileable_grass ground: tufts
# of blades cut from res://assets/meshes/grass01.glb, scattered over every
# cell whose ground texture is tileable_grass (the default unpainted ground or
# a painted tileable_grass cell) and drawn as MultiMeshes with grass.gdshader:
# root colour = the ground under it, so blades grow out of the terrain
# seamlessly, brightening to a warm tip; wind waves + gusts roll across the
# field and the player pushes blades aside.
#
# Placement runs on terrain.gd's worker threads (build_chunk — pure data);
# nodes are made on the main thread (make_nodes). Blades shrink into the
# ground with distance (shader) and each patch has a sparser far LOD.

const _SOURCE_SCENE := "res://assets/meshes/grass01.glb"
const _GROUND_TEX   = preload("res://assets/textures/tileable_grass.png")
const _SHADER       = preload("res://world/grass.gdshader")

# A cell's texture counts as "tiledgrass" when its path contains this.
const GRASS_TEXTURE_KEY := "tileable_grass"

const HEIGHT        := 0.55   # metres, tallest blade of a tuft at scale 1
const HEIGHT_JITTER := 0.30   # ± fraction
const SPACING       := 0.75   # metres between tufts (jittered grid)
const JITTER        := 0.45   # fraction of SPACING
const PATCH         := 8.0    # metres per MultiMesh patch side
# Cut a disk of blades from the middle of the source clump (fraction of its
# half width) and keep a share of those: footprint and density of one tuft.
const CROP          := 0.45
const KEEP_NEAR     := 0.15
const KEEP_FAR      := 0.05
# The source blades lean far over; scale each one's sideways reach from its
# root by this for the more upright stylised look.
const LEAN          := 0.55
const NEAR_END      := 16.0   # patch-centre distance where the far LOD takes over
const FADE_START    := 22.0   # blades start sinking into the ground
const FADE_END      := 32.0
# Skip cliffs: max height step (metres) between neighbouring height samples.
const MAX_STEP      := 0.45
# Blades stay off anything built at ground level (walls, floors): a box
# whose bottom is below ground + this and top above ground - BOX_BELOW.
const BOX_ABOVE     := 0.6
const BOX_BELOW     := 0.3

static var _mesh_near: ArrayMesh = null
static var _mesh_far:  ArrayMesh = null
static var _material:  ShaderMaterial = null
static var _failed := false


# Main thread, once: true when the meshes and material are ready.
static func ready() -> bool:
	if _material != null: return true
	if _failed: return false
	var scene := load(_SOURCE_SCENE) as PackedScene
	if scene == null:
		push_warning("Grass: cannot load %s — no grass" % _SOURCE_SCENE)
		_failed = true
		return false
	var root := scene.instantiate()
	var blades := _collect_blades(root)
	root.free()
	if blades.is_empty():
		push_warning("Grass: %s has no blades — no grass" % _SOURCE_SCENE)
		_failed = true
		return false
	_mesh_near = _build_tuft(blades, KEEP_NEAR)
	_mesh_far  = _build_tuft(blades, KEEP_FAR)
	_material  = _make_material(blades[0].texture)
	return true


# The player's position, for blades to bend away from (shared material).
static func set_push(pos: Vector3) -> void:
	if _material != null:
		_material.set_shader_parameter("push_pos", pos)


# --- tuft mesh ---------------------------------------------------------------

# Every blade of the source clump: Y-up vertices/UVs in clump space, its root
# (lowest vertex) and the albedo texture of its material.
static func _collect_blades(root: Node) -> Array:
	var out := []
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null: continue
		var xf := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != root:
			if p is Node3D: xf = (p as Node3D).transform * xf
			p = p.get_parent()
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var uv = arr[Mesh.ARRAY_TEX_UV]
			var idx = arr[Mesh.ARRAY_INDEX]
			if v.is_empty() or uv == null: continue
			var tv := PackedVector3Array()
			var tuv := PackedVector2Array()
			# Flatten to a plain triangle list.
			var order: PackedInt32Array = idx if idx != null else PackedInt32Array(range(v.size()))
			for i in order:
				tv.append(xf * v[i])
				tuv.append((uv as PackedVector2Array)[i])
			var lo := tv[0]
			for q in tv:
				if q.y < lo.y: lo = q
			var mat := mi.get_active_material(s)
			out.append({ "v": tv, "uv": tuv, "root": lo, "texture": _albedo_of(mat) })
	return out


static func _albedo_of(mat: Material) -> Texture2D:
	if mat is BaseMaterial3D:
		return (mat as BaseMaterial3D).albedo_texture
	if mat is ShaderMaterial:
		for name in ["albedo_tex", "texture_albedo", "albedo_texture"]:
			var t = (mat as ShaderMaterial).get_shader_parameter(name)
			if t is Texture2D: return t
	return null


# One tuft: the blades rooted within CROP of the clump's middle, `keep` of
# them (the far LOD's blades are a subset of the near one's, so the swap
# only thins the tuft), recentred on the origin with the tallest blade
# 1 high. COLOR.r = per-blade random, COLOR.g = height along the blade 0..1,
# COLOR.b = across the blade 0..1 (the shader cuts the blade's shape from it).
static func _build_tuft(blades: Array, keep: float) -> ArrayMesh:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for b in blades:
		for q in b.v:
			lo = lo.min(q); hi = hi.max(q)
	var mid := Vector2((lo.x + hi.x) * 0.5, (lo.z + hi.z) * 0.5)
	var radius := minf(hi.x - lo.x, hi.z - lo.z) * 0.5 * CROP
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var chosen := []
	for b in blades:
		var r: Vector3 = b.root
		var pick := rng.randf()   # drawn for every blade: LODs share the sequence
		if Vector2(r.x, r.z).distance_to(mid) <= radius and pick < keep:
			chosen.append(b)
	var base_y := INF
	var top_y := -INF
	for b in chosen:
		base_y = minf(base_y, (b.root as Vector3).y)
		for q in b.v: top_y = maxf(top_y, q.y)
	var inv := 1.0 / maxf(top_y - base_y, 0.001)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var norms := PackedVector3Array()
	for b in chosen:
		var rnd := rng.randf()
		var r: Vector3 = b.root
		var blade_len := 0.001
		for q in b.v: blade_len = maxf(blade_len, q.y - r.y)
		var u_lo := INF
		var u_hi := -INF
		for t in b.uv:
			u_lo = minf(u_lo, t.x); u_hi = maxf(u_hi, t.x)
		var u_inv := 1.0 / maxf(u_hi - u_lo, 0.0001)
		for i in b.v.size():
			var q: Vector3 = b.v[i]
			q = Vector3(r.x + (q.x - r.x) * LEAN, q.y, r.z + (q.z - r.z) * LEAN)
			verts.append(Vector3(q.x - mid.x, q.y - base_y, q.z - mid.y) * inv)
			uvs.append(b.uv[i])
			cols.append(Color(rnd, clampf((q.y - r.y) / blade_len, 0.0, 1.0), (b.uv[i].x - u_lo) * u_inv))
			norms.append(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR]  = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


static func _make_material(blade_tex: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _SHADER
	m.set_shader_parameter("blade_tex", blade_tex)
	m.set_shader_parameter("ground_tex", _GROUND_TEX)
	m.set_shader_parameter("fade_start", FADE_START)
	m.set_shader_parameter("fade_end", FADE_END)
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 2
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.noise = noise
	m.set_shader_parameter("gust_tex", tex)
	return m


# --- placement (worker thread) -------------------------------------------------

# Pure data, safe on a worker thread. `h1` = the chunk's (stride² = (cells+1)²)
# heights, `cells` = its painted-cell bytes (empty = all default ground),
# `is_grass[k]` = whether cell value k is tileable_grass, `tiles[k]` /
# `tinted[k]` = how the terrain draws that ground (so the blade roots match
# it), `boxes`/`pillars`/`water` = world.bin geometry as world_data.gd holds
# it, `ground_at` = Callable(x, z) -> terrain height (for box bases).
# Returns [{center: Vector3, near: PackedFloat32Array, far: …, count}] —
# one entry per non-empty patch, MultiMesh buffers relative to `center`.
static func build_chunk(origin: Vector3, chunk_cells: int, cell_size: float, h1: Array,
		cells: PackedByteArray, is_grass: PackedByteArray, tiles: PackedFloat32Array,
		tinted: PackedByteArray, boxes: Array, pillars: Array, water: Array,
		ground_at: Callable, seed_: int) -> Array:
	var size := chunk_cells * cell_size
	var stride := chunk_cells + 1
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_
	# Only geometry that can touch this chunk.
	var near_boxes := []
	for wb in boxes:
		var reach := Vector2(wb.half_x, wb.half_z).length()
		if wb.x + reach < origin.x or wb.x - reach > origin.x + size \
				or wb.z + reach < origin.z or wb.z - reach > origin.z + size:
			continue
		var base: float = ground_at.call(wb.x as float, wb.z as float)
		if is_nan(base): base = 0.0
		var bottom := base + (wb.get("y_offset", 0.0) as float)
		near_boxes.append({ "x": wb.x, "z": wb.z, "hx": wb.half_x, "hz": wb.half_z,
			"rot": wb.rot_y, "bottom": bottom, "top": bottom + (wb.height as float) })
	var near_pillars := []
	for p in pillars:
		if p.x + p.radius >= origin.x and p.x - p.radius <= origin.x + size \
				and p.z + p.radius >= origin.z and p.z - p.radius <= origin.z + size:
			near_pillars.append(p)

	var per_side := int(round(PATCH / SPACING))
	var patches := {}   # Vector2i -> [Transform3D, custom Color] pairs
	var n := int(size / SPACING)
	for tz in n:
		for tx in n:
			var lx := (tx + 0.5 + rng.randf_range(-JITTER, JITTER)) * SPACING
			var lz := (tz + 0.5 + rng.randf_range(-JITTER, JITTER)) * SPACING
			var yaw := rng.randf() * TAU
			var hs := 1.0 + rng.randf_range(-HEIGHT_JITTER, HEIGHT_JITTER)
			var ws := rng.randf_range(0.85, 1.15)
			var rnd := rng.randf()
			lx = clampf(lx, 0.0, size - 0.001)
			lz = clampf(lz, 0.0, size - 0.001)
			var cx := int(lx / cell_size)
			var cz := int(lz / cell_size)
			var cell := 0 if cells.is_empty() else cells[cz * chunk_cells + cx]
			if is_grass[cell] == 0: continue
			# Bilinear height; skip holes and cliffs.
			var i00: float = h1[cz * stride + cx]
			var i10: float = h1[cz * stride + cx + 1]
			var i01: float = h1[(cz + 1) * stride + cx]
			var i11: float = h1[(cz + 1) * stride + cx + 1]
			if is_nan(i00) or is_nan(i10) or is_nan(i01) or is_nan(i11): continue
			if maxf(maxf(i00, i10), maxf(i01, i11)) - minf(minf(i00, i10), minf(i01, i11)) > MAX_STEP: continue
			var fx := lx / cell_size - cx
			var fz := lz / cell_size - cz
			var y := lerpf(lerpf(i00, i10, fx), lerpf(i01, i11, fx), fz)
			var wx := origin.x + lx
			var wz := origin.z + lz
			if _blocked(wx, y, wz, near_boxes, near_pillars, water): continue
			var b := Basis(Vector3.UP, yaw).scaled(Vector3(HEIGHT * ws, HEIGHT * hs, HEIGHT * ws))
			var key := Vector2i(mini(tx / per_side, 999), mini(tz / per_side, 999))
			if not patches.has(key): patches[key] = []
			# Sink the roots a little so slopes don't show floating tufts.
			patches[key].append([Transform3D(b, Vector3(wx, y - 0.04, wz)),
				Color(rnd, tiles[cell], float(tinted[cell]), 0.0)])

	var out := []
	for key in patches:
		var items: Array = patches[key]
		var center := Vector3(origin.x + (key.x + 0.5) * per_side * SPACING, 0.0,
			origin.z + (key.y + 0.5) * per_side * SPACING)
		var ysum := 0.0
		for it in items: ysum += (it[0] as Transform3D).origin.y
		center.y = ysum / items.size()
		var buf := PackedFloat32Array()
		buf.resize(items.size() * 16)
		var o := 0
		for it in items:
			var t: Transform3D = it[0]
			var c: Color = it[1]
			var p := t.origin - center
			buf[o]      = t.basis.x.x; buf[o + 1] = t.basis.y.x; buf[o + 2]  = t.basis.z.x; buf[o + 3]  = p.x
			buf[o + 4]  = t.basis.x.y; buf[o + 5] = t.basis.y.y; buf[o + 6]  = t.basis.z.y; buf[o + 7]  = p.y
			buf[o + 8]  = t.basis.x.z; buf[o + 9] = t.basis.y.z; buf[o + 10] = t.basis.z.z; buf[o + 11] = p.z
			buf[o + 12] = c.r; buf[o + 13] = c.g; buf[o + 14] = c.b; buf[o + 15] = c.a
			o += 16
		out.append({ "center": center, "buffer": buf, "count": items.size() })
	return out


static func _blocked(x: float, y: float, z: float, boxes: Array, pillars: Array, water: Array) -> bool:
	for wb in boxes:
		if wb.bottom > y + BOX_ABOVE or wb.top < y - BOX_BELOW: continue
		var local := Vector2(x - (wb.x as float), z - (wb.z as float)).rotated(wb.rot as float)
		if absf(local.x) <= (wb.hx as float) + 0.1 and absf(local.y) <= (wb.hz as float) + 0.1:
			return true
	for p in pillars:
		if Vector2(x - (p.x as float), z - (p.z as float)).length() <= (p.radius as float) + 0.15:
			return true
	for wr in water:
		var hw := (wr.width as float) * 0.5
		var hd := (wr.depth as float) * 0.5
		if absf(x - (wr.x as float)) <= hw and absf(z - (wr.z as float)) <= hd and y < (wr.y as float):
			return true
	return false


# Main thread: one MultiMeshInstance3D pair (near + far LOD) per patch.
static func make_nodes(parent: Node3D, patches: Array) -> void:
	if patches.is_empty() or not ready(): return
	var holder := Node3D.new()
	holder.name = "Grass"
	parent.add_child(holder)
	for p in patches:
		for lod in 2:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true
			mm.mesh = _mesh_near if lod == 0 else _mesh_far
			mm.instance_count = p.count
			mm.buffer = p.buffer
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = _material
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.position = p.center
			if lod == 0:
				mmi.visibility_range_end = NEAR_END
			else:
				mmi.visibility_range_begin = NEAR_END
				mmi.visibility_range_end = FADE_END + PATCH
			holder.add_child(mmi)
