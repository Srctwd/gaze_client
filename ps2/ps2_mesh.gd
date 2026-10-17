extends RefCounted
## Rebuilds a mesh along the PS2 geometry path (PS2_RENDERING.md §2, §7):
##   1. quantise every attribute to its VIF UNPACK format,
##   2. turn the triangle list into triangle strips with ADC restart flags,
##   3. cut the vertex stream into VU1-buffer-sized batches,
##   4. decode the stream the way the GS kicks triangles.
## The result is a plain triangle-list ArrayMesh holding exactly what the GS
## would have drawn. There is no index buffer: like on the PS2, a vertex
## shared by two strips is sent twice.
##
## Use convert() for a one-off, or extract() on the main thread, run() on a
## worker thread (pure data) and finish() back on the main thread.

const BATCH_VERTS    := 72   # vertices per VU1 double-buffer half (§7)
const MAX_INFLUENCES := 2    # bones per vertex, 8-bit weights

# Bytes per vertex in the VIF stream (one UNPACK per attribute).
const BYTES_POS    := 8   # V4-16: x, y, z, ADC flag in w
const BYTES_NORMAL := 4   # V3-8, rows padded to 4 bytes
const BYTES_UV     := 4   # V2-16
const BYTES_COLOR  := 4   # V4-8
const BYTES_SKIN   := 4   # V4-8: 2 bone indices + 2 weights
const BYTES_BATCH  := 48  # per batch: GIF tag, UNPACK/MSCAL codes, XGKICK

# Large primitives are split into cells this size: the GS clips nothing, so
# big polygons had to be cut to stay inside the guard band (§3.4), and fog
# and light only exist at vertices (§4, §6.4).
const PRIMITIVE_CELL := 4.0
const MAX_SUBDIVIDE  := 63


## Returns the PS2-built copy of `src`, or null when it can't be converted.
## grid > 0 quantises positions on a world-aligned grid of that step instead
## of per mesh, so neighbouring meshes (terrain chunks) meet without cracks;
## `xform` is then the mesh's global transform.
static func convert(src: Mesh, grid: float = 0.0, xform := Transform3D.IDENTITY) -> ArrayMesh:
	var job := extract(src, grid, xform)
	if job.is_empty():
		return null
	run(job)
	return finish(job)


## Main thread: snapshot everything the worker needs. Empty if unsupported.
static func extract(src: Mesh, grid: float = 0.0, xform := Transform3D.IDENTITY) -> Dictionary:
	var mesh := _tessellate(src)
	var am := mesh as ArrayMesh
	if am == null and not mesh is PrimitiveMesh:
		return {}
	var surfaces := []
	for s in mesh.get_surface_count():
		var wpv := 4
		if am != null:
			if am.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				return {}
			if (am.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS) != 0:
				wpv = 8
		surfaces.append({
			"arrays":   mesh.surface_get_arrays(s),
			"shapes":   am.surface_get_blend_shape_arrays(s) if am != null else [],
			"wpv":      wpv,
			"material": mesh.surface_get_material(s),
			"name":     am.surface_get_name(s) if am != null else "",
		})
	var shape_names := []
	if am != null:
		for i in am.get_blend_shape_count():
			shape_names.append(am.get_blend_shape_name(i))
	return {"source": src, "surfaces": surfaces, "shape_names": shape_names,
			"shape_mode": am.blend_shape_mode if am != null else Mesh.BLEND_SHAPE_MODE_RELATIVE,
			"grid": grid, "xform": xform}


## Worker thread: the whole geometry path, pure data.
static func run(job: Dictionary) -> void:
	for surf: Dictionary in job["surfaces"]:
		surf["built"] = _build(surf["arrays"], surf["shapes"], surf["wpv"], job["grid"], job["xform"])


## Main thread: turn a finished job into the mesh. Null if a surface failed.
static func finish(job: Dictionary) -> ArrayMesh:
	var out := ArrayMesh.new()
	out.blend_shape_mode = job["shape_mode"]
	for name in job["shape_names"]:
		out.add_blend_shape(name)
	var stats := PackedStringArray()
	var s := 0
	for surf: Dictionary in job["surfaces"]:
		var built: Dictionary = surf["built"]
		if built.is_empty():
			return null
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, built["arrays"], built["shapes"])
		out.surface_set_material(s, surf["material"])
		out.surface_set_name(s, surf["name"])
		stats.append(built["stats"])
		s += 1
	out.set_meta("ps2", true)
	out.set_meta("ps2_source", job["source"])
	out.set_meta("ps2_stats", stats)
	return out


# Copies a plane/box primitive with at least enough subdivisions for
# PRIMITIVE_CELL (never fewer than it already had).
static func _tessellate(src: Mesh) -> Mesh:
	if src is PlaneMesh:
		var p := (src as PlaneMesh).duplicate() as PlaneMesh
		p.subdivide_width = maxi(p.subdivide_width, _cuts(p.size.x))
		p.subdivide_depth = maxi(p.subdivide_depth, _cuts(p.size.y))
		return p
	if src is BoxMesh:
		var b := (src as BoxMesh).duplicate() as BoxMesh
		b.subdivide_width  = maxi(b.subdivide_width, _cuts(b.size.x))
		b.subdivide_height = maxi(b.subdivide_height, _cuts(b.size.y))
		b.subdivide_depth  = maxi(b.subdivide_depth, _cuts(b.size.z))
		return b
	return src


static func _cuts(length: float) -> int:
	return clampi(ceili(length / PRIMITIVE_CELL) - 1, 0, MAX_SUBDIVIDE)


static func _build(arrays: Array, shapes: Array, wpv: int, grid: float, xform: Transform3D) -> Dictionary:
	var verts := _v3(arrays[Mesh.ARRAY_VERTEX])
	var n := verts.size()
	if n == 0:
		return {}
	var normals := _v3(arrays[Mesh.ARRAY_NORMAL])
	var uvs     := _v2(arrays[Mesh.ARRAY_TEX_UV])
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] != null else PackedInt32Array()
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		idx.resize(n)
		for i in n:
			idx[i] = i

	# 1. Quantise ----------------------------------------------------------------
	var qp := _pos_quantiser(verts, grid, xform)
	var q := _quantise(verts, normals, uvs, colors, bones, weights, wpv, qp)

	# 2. Strip -------------------------------------------------------------------
	var strips := _stripify(idx)

	# 3. Stream + VU1 batches ----------------------------------------------------
	var stream := PackedInt32Array()
	var adc    := PackedByteArray()
	var batches  := 1
	var in_batch := 0
	for strip: PackedInt32Array in strips:
		if in_batch + 3 > BATCH_VERTS:   # never start a strip without room for a triangle
			batches += 1
			in_batch = 0
		for j in strip.size():
			if in_batch == BATCH_VERTS:
				# Buffer full: XGKICK this batch, then restart the strip in the next
				# one by re-sending its last two vertices with ADC set. If the next
				# triangle has odd parity, a zero-area (degenerate) triangle is sent
				# first to flip the parity back: the GS draws nothing for it.
				batches += 1
				if (j - 2) % 2 == 0:
					stream.append_array([strip[j - 2], strip[j - 1]])
					adc.append_array([1, 1])
					in_batch = 2
				else:
					stream.append_array([strip[j - 1], strip[j - 2], strip[j - 1]])
					adc.append_array([1, 1, 0])
					in_batch = 3
			stream.append(strip[j])
			adc.append(1 if j < 2 else 0)
			in_batch += 1

	# 4. Decode like the GS: every vertex shifts the 3-vertex queue, and a
	# vertex without ADC draws a triangle (alternate ones flipped to keep winding).
	var corners := PackedInt32Array()
	var q0 := -1
	var q1 := -1
	var k  := 0
	for s in stream.size():
		var v := stream[s]
		if adc[s] == 1:
			k = 0
		elif q0 >= 0:
			if q0 == q1 or q1 == v or v == q0:
				pass   # zero area: rasterises to nothing
			elif k % 2 == 0:
				corners.append_array([q0, q1, v])
			else:
				corners.append_array([q1, q0, v])
			k += 1
		q0 = q1
		q1 = v

	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = _gather_v3(q["pos"], corners)
	if not normals.is_empty():
		out[Mesh.ARRAY_NORMAL] = _gather_v3(q["normal"], corners)
	if not uvs.is_empty():
		out[Mesh.ARRAY_TEX_UV] = _gather_v2(q["uv"], corners)
	if not colors.is_empty():
		var c := PackedColorArray()
		c.resize(corners.size())
		var qc: PackedColorArray = q["color"]
		for i in corners.size():
			c[i] = qc[corners[i]]
		out[Mesh.ARRAY_COLOR] = c
	if not bones.is_empty():
		var ob := PackedInt32Array()
		var ow := PackedFloat32Array()
		ob.resize(corners.size() * 4)
		ow.resize(corners.size() * 4)
		var qb: PackedInt32Array   = q["bones"]
		var qw: PackedFloat32Array = q["weights"]
		for i in corners.size():
			for m in 4:
				ob[i * 4 + m] = qb[corners[i] * 4 + m]
				ow[i * 4 + m] = qw[corners[i] * 4 + m]
		out[Mesh.ARRAY_BONES]   = ob
		out[Mesh.ARRAY_WEIGHTS] = ow

	# Blend shapes (morph targets): same quantisation, same stream order.
	var out_shapes := []
	for shape: Array in shapes:
		var sa := []
		sa.resize(Mesh.ARRAY_MAX)
		var sv := _v3(shape[Mesh.ARRAY_VERTEX])
		var qsv := PackedVector3Array()
		qsv.resize(sv.size())
		for i in sv.size():
			qsv[i] = _qpos(sv[i], qp)
		sa[Mesh.ARRAY_VERTEX] = _gather_v3(qsv, corners)
		if not normals.is_empty():
			var sn := _v3(shape[Mesh.ARRAY_NORMAL])
			var qsn := PackedVector3Array()
			qsn.resize(sn.size())
			for i in sn.size():
				qsn[i] = (sn[i] * 127.0).round() / 127.0
			sa[Mesh.ARRAY_NORMAL] = _gather_v3(qsn, corners)
		out_shapes.append(sa)

	var per_vert := BYTES_POS + (BYTES_NORMAL if not normals.is_empty() else 0) \
			+ (BYTES_UV if not uvs.is_empty() else 0) + (BYTES_COLOR if not colors.is_empty() else 0) \
			+ (BYTES_SKIN if not bones.is_empty() else 0)
	var tris := idx.size() / 3
	var degenerate := 0
	for t in tris:
		var a := idx[t * 3]
		var b := idx[t * 3 + 1]
		var c := idx[t * 3 + 2]
		if a == b or b == c or c == a:
			degenerate += 1
	var stats := "%d tris → %d strips (avg %.1f tris), %d stream verts (%.2f/tri), %d VU1 batches, %.1f KB VIF, UV fixed %s" % [
			corners.size() / 3, strips.size(), float(corners.size() / 3) / maxf(strips.size(), 1),
			stream.size(), float(stream.size()) / maxf(corners.size() / 3, 1), batches,
			(stream.size() * per_vert + batches * BYTES_BATCH) / 1024.0, q["uv_format"]]
	if not shapes.is_empty():
		stats += ", %d blend shapes" % shapes.size()
	if grid > 0.0:
		stats += ", world grid %s" % grid
	if qp["overflow"] > 0:
		stats += " (%d positions outside s16 range)" % qp["overflow"]
	if corners.size() / 3 != tris - degenerate:
		stats += " (WARNING: %d of %d triangles decoded)" % [corners.size() / 3, tris]
	return {"arrays": out, "shapes": out_shapes, "stats": stats}


# --- 1. Quantisation ----------------------------------------------------------

# Positions are s16, decoded on VU1 as p = s16 * scale + offset. Models use
# one scale around their own centre; world geometry (grid > 0) uses a fixed
# step on a world-aligned grid, so shared edges round identically.
static func _pos_quantiser(verts: PackedVector3Array, grid: float, xform: Transform3D) -> Dictionary:
	if grid > 0.0:
		var overflow := 0
		for v in verts:
			var c := v / grid
			if maxf(maxf(absf(c.x), absf(c.y)), absf(c.z)) > 32767.0:
				overflow += 1
		return {"grid": grid, "xform": xform, "inv": xform.affine_inverse(), "overflow": overflow}
	var lo := verts[0]
	var hi := verts[0]
	for v in verts:
		lo = lo.min(v)
		hi = hi.max(v)
	var half := (hi - lo) * 0.5
	var scale := maxf(maxf(half.x, half.y), half.z) / 32767.0
	return {"grid": 0.0, "centre": (lo + hi) * 0.5, "scale": scale if scale > 0.0 else 1.0, "overflow": 0}


static func _qpos(v: Vector3, qp: Dictionary) -> Vector3:
	if qp["grid"] > 0.0:
		var g: float = qp["grid"]
		return qp["inv"] * (((qp["xform"] * v) / g).round() * g)
	var scale: float = qp["scale"]
	var centre: Vector3 = qp["centre"]
	return ((v - centre) / scale).round() * scale + centre


static func _quantise(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array,
		colors: PackedColorArray, bones: PackedInt32Array, weights: PackedFloat32Array, wpv: int,
		qp: Dictionary) -> Dictionary:
	var n := verts.size()
	var pos := PackedVector3Array()
	pos.resize(n)
	for i in n:
		pos[i] = _qpos(verts[i], qp)

	# Normals: s8, n = s8 / 127.
	var nrm := PackedVector3Array()
	nrm.resize(normals.size())
	for i in normals.size():
		nrm[i] = (normals[i] * 127.0).round() / 127.0

	# UVs: s16 with the most fractional bits that still fit the range:
	# ITOF12 (±8, 1/4096), ITOF4 (±2048, 1/16) or ITOF0.
	var uv_max := 0.0
	for t in uvs:
		uv_max = maxf(uv_max, maxf(absf(t.x), absf(t.y)))
	var frac := 12 if uv_max < 7.99 else (4 if uv_max < 2047.0 else 0)
	var step := float(1 << frac)
	var uv := PackedVector2Array()
	uv.resize(uvs.size())
	for i in uvs.size():
		uv[i] = (uvs[i] * step).round() / step

	# Colours: u8 per channel.
	var col := PackedColorArray()
	col.resize(colors.size())
	for i in colors.size():
		var c := colors[i]
		col[i] = Color(roundf(clampf(c.r, 0.0, 1.0) * 255.0) / 255.0, roundf(clampf(c.g, 0.0, 1.0) * 255.0) / 255.0,
				roundf(clampf(c.b, 0.0, 1.0) * 255.0) / 255.0, roundf(clampf(c.a, 0.0, 1.0) * 255.0) / 255.0)

	# Skin: keep the MAX_INFLUENCES strongest bones, 8-bit weights where the
	# last one is 255 minus the others so they always sum to exactly 1.
	var ob := PackedInt32Array()
	var ow := PackedFloat32Array()
	if not bones.is_empty():
		ob.resize(n * 4)
		ow.resize(n * 4)
		for i in n:
			var pairs := []
			for m in wpv:
				pairs.append([weights[i * wpv + m], bones[i * wpv + m]])
			pairs.sort_custom(func(a, b): return a[0] > b[0])
			var total := 0.0
			for m in MAX_INFLUENCES:
				total += pairs[m][0]
			if total <= 0.0:
				total = 1.0
			var left := 255
			for m in 4:
				var w := 0
				if m < MAX_INFLUENCES:
					w = left if m == MAX_INFLUENCES - 1 else mini(left, roundi(pairs[m][0] / total * 255.0))
					left -= w
					ob[i * 4 + m] = pairs[m][1]
				ow[i * 4 + m] = w / 255.0

	return {"pos": pos, "normal": nrm, "uv": uv, "color": col, "bones": ob, "weights": ow,
			"uv_format": "1.%d.%d" % [15 - frac, frac]}


# --- 2. Strips ------------------------------------------------------------------

# Greedy stripifier. Triangle i of a strip S is (S[i], S[i+1], S[i+2]) when i
# is even and (S[i+1], S[i], S[i+2]) when odd, so each next triangle must own
# the directed edge that keeps that winding.
static func _stripify(idx: PackedInt32Array) -> Array:
	var tri_count := idx.size() / 3
	var owner := {}   # (a << 32) | b -> triangle owning directed edge a→b
	var used := PackedByteArray()
	used.resize(tri_count)
	for t in tri_count:
		var a := idx[t * 3]
		var b := idx[t * 3 + 1]
		var c := idx[t * 3 + 2]
		if a == b or b == c or c == a:
			used[t] = 1   # degenerate: the exporter drops it
			continue
		owner[(a << 32) | b] = t
		owner[(b << 32) | c] = t
		owner[(c << 32) | a] = t

	# Start from triangles with the fewest neighbours (corners and edges first).
	var buckets := [[], [], [], []]
	for t in tri_count:
		if used[t]:
			continue
		var a := idx[t * 3]
		var b := idx[t * 3 + 1]
		var c := idx[t * 3 + 2]
		var nb := int(owner.has((b << 32) | a)) + int(owner.has((c << 32) | b)) + int(owner.has((a << 32) | c))
		buckets[nb].append(t)

	var strips := []
	for bucket: Array in buckets:
		for t: int in bucket:
			if used[t]:
				continue
			var a := idx[t * 3]
			var b := idx[t * 3 + 1]
			var c := idx[t * 3 + 2]
			var best: Array = []
			for rot in [[a, b, c], [b, c, a], [c, a, b]]:
				var grown := _grow(rot[0], rot[1], rot[2], t, idx, owner, used)
				if best.is_empty() or grown[1].size() > best[1].size():
					best = grown
			for tt in best[1]:
				used[tt] = 1
			strips.append(best[0])
	return strips


static func _grow(a: int, b: int, c: int, first: int, idx: PackedInt32Array, owner: Dictionary,
		used: PackedByteArray) -> Array:
	var strip := PackedInt32Array([a, b, c])
	var tris := PackedInt32Array([first])
	var taken := {first: true}
	while true:
		var i := strip.size() - 2   # index of the next triangle in the strip
		var x := strip[strip.size() - 2]
		var y := strip[strip.size() - 1]
		var key := ((x << 32) | y) if i % 2 == 0 else ((y << 32) | x)
		var t: int = owner.get(key, -1)
		if t < 0 or used[t] or taken.has(t):
			break
		strip.append(idx[t * 3] + idx[t * 3 + 1] + idx[t * 3 + 2] - x - y)   # third vertex
		tris.append(t)
		taken[t] = true
	return [strip, tris]


# --- helpers ------------------------------------------------------------------

static func _v3(v: Variant) -> PackedVector3Array:
	return v if v != null else PackedVector3Array()


static func _v2(v: Variant) -> PackedVector2Array:
	return v if v != null else PackedVector2Array()


static func _gather_v3(src: PackedVector3Array, corners: PackedInt32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(corners.size())
	for i in corners.size():
		out[i] = src[corners[i]]
	return out


static func _gather_v2(src: PackedVector2Array, corners: PackedInt32Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(corners.size())
	for i in corners.size():
		out[i] = src[corners[i]]
	return out
