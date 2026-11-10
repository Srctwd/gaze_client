# Ramp walls: a wall box whose top slopes. In the wall's own frame (x along
# half_x, z along half_z, y up from its base) the top rises from `low_height`
# at -half_x to `height` at +half_x; rot_y picks the direction. A wall without
# a "low_height", or with one < 0 or >= height, is a plain box. Mirrors
# StaticBox::is_ramp / top_at in the server's world.h. Shared by gaze_client's
# WorldData and the world editor.


static func is_ramp(d: Dictionary) -> bool:
	var low := d.get("low_height", -1.0) as float
	return low >= 0.0 and low < (d.height as float) and (d.half_x as float) > 0.0


# Top above the wall's base at wall-local x (clamped to the wall).
static func top_at(d: Dictionary, local_x: float) -> float:
	var height := d.height as float
	if not is_ramp(d): return height
	var half_x := d.half_x as float
	var low := d.low_height as float
	var along := clampf((local_x + half_x) / (2.0 * half_x), 0.0, 1.0)
	return low + (height - low) * along


# The wedge's corners in the wall frame (base at y = 0): bottom four, then top
# four (low end at -x, high end at +x). Also the convex collision hull.
static func corners(d: Dictionary) -> PackedVector3Array:
	var hx := d.half_x as float
	var hz := d.half_z as float
	var high := d.height as float
	var low := d.low_height as float
	return PackedVector3Array([
		Vector3(-hx, 0.0, -hz), Vector3(hx, 0.0, -hz), Vector3(hx, 0.0, hz), Vector3(-hx, 0.0, hz),
		Vector3(-hx, low, -hz), Vector3(hx, high, -hz), Vector3(hx, high, hz), Vector3(-hx, low, hz),
	])


# Surface arrays (vertex, normal, uv) of the wedge in the wall frame, flat
# shaded. Faces: bottom, sloped top, high end, low end (skipped when the ramp
# starts at the base), two sides.
static func arrays(d: Dictionary) -> Array:
	var c := corners(d)
	var faces := [
		[c[0], c[1], c[2], c[3]],  # bottom
		[c[4], c[5], c[6], c[7]],  # sloped top
		[c[1], c[2], c[6], c[5]],  # high end (+x)
		[c[0], c[3], c[7], c[4]],  # low end (-x)
		[c[0], c[1], c[5], c[4]],  # side -z
		[c[3], c[2], c[6], c[7]],  # side +z
	]
	var centre := Vector3.ZERO
	for p in c: centre += p
	centre /= c.size()
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	for quad: Array in faces:
		_add_triangle(verts, normals, uvs, quad[0], quad[1], quad[2], centre)
		_add_triangle(verts, normals, uvs, quad[0], quad[2], quad[3], centre)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TEX_UV] = uvs
	return arr


static func mesh(d: Dictionary) -> ArrayMesh:
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays(d))
	return m


# One triangle facing away from the wedge's centre (Godot fronts are
# clockwise seen from outside); degenerate ones (the low end of a ramp that
# starts at the base) are dropped. UVs are the two axes the face spans most.
static func _add_triangle(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, a: Vector3, b: Vector3, c: Vector3, centre: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-10: return
	n = n.normalized()
	var outward := n if n.dot((a + b + c) / 3.0 - centre) > 0.0 else -n
	var tri := [a, b, c] if n.dot(outward) < 0.0 else [a, c, b]
	var axis := outward.abs().max_axis_index()
	for p: Vector3 in tri:
		verts.append(p)
		normals.append(outward)
		match axis:
			Vector3.AXIS_X: uvs.append(Vector2(p.z, -p.y))
			Vector3.AXIS_Y: uvs.append(Vector2(p.x, p.z))
			_: uvs.append(Vector2(p.x, -p.y))
