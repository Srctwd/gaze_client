class_name WorldData
extends RefCounted

var chunk_cells : int
var chunks_x    : int
var chunks_z    : int
var cell_size   : float
var _chunks     : Array = []
var _material   : Material
var _mat_cave   : Material


func load(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("WorldData: cannot open " + path)
		return false

	chunk_cells = f.get_32()
	chunks_x    = f.get_32()
	chunks_z    = f.get_32()
	cell_size   = f.get_float()

	var total  := chunks_x * chunks_z
	var stride := chunk_cells + 1
	var cells  := stride * stride

	var types   : Array[int] = []
	var offsets : Array[int] = []

	for i in range(total):
		types.append(f.get_8())
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
		if types[i] == 2:
			h2.resize(cells)
			for j in range(cells):
				h2[j] = f.get_float()

		_chunks.append({ "type": types[i], "h1": h1, "h2": h2 })

	f.close()

	var holes := _find_holes()
	_material = _make_surface_mat(Color(0.35, 0.52, 0.28), holes)
	_mat_cave = _make_standard_mat(Color(0.25, 0.22, 0.20))
	return true


func spawn_into(parent: Node3D) -> void:
	var ox := -(chunks_x * chunk_cells * cell_size * 0.5)
	var oz := -(chunks_z * chunk_cells * cell_size * 0.5)

	for i in range(_chunks.size()):
		var cx := i % chunks_x
		var cz := int(i / chunks_x)
		var origin := Vector3(ox + cx * chunk_cells * cell_size, 0.0, oz + cz * chunk_cells * cell_size)
		parent.add_child(_make_chunk(_chunks[i].h1, origin, _material))
		if _chunks[i].type == 2:
			parent.add_child(_make_chunk(_chunks[i].h2, origin, _mat_cave))


func _make_chunk(h1: Array, origin: Vector3, mat: Material) -> MeshInstance3D:
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
	st.generate_normals()
	st.index()
	var mesh := st.commit()
	mesh.surface_set_material(0, mat)
	var mi      := MeshInstance3D.new()
	mi.mesh     = mesh
	mi.position = origin
	return mi


func _find_holes() -> Array:
	var holes  := []
	var ox     := -(chunks_x * chunk_cells * cell_size * 0.5)
	var oz     := -(chunks_z * chunk_cells * cell_size * 0.5)
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


func _make_standard_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.cull_mode    = BaseMaterial3D.CULL_DISABLED
	return m


func _make_surface_mat(color: Color, holes: Array) -> Material:
	var sh  := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled;
uniform vec4 albedo_top   : source_color = vec4(1.0);
uniform vec4 albedo_bottom: source_color = vec4(0.25, 0.22, 0.20, 1.0);
uniform vec2 hole_centers[16];
uniform float hole_radii[16];
uniform int hole_count = 0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	for (int i = 0; i < hole_count; i++) {
		if (length(world_pos.xz - hole_centers[i]) < hole_radii[i]) discard;
	}
	ALBEDO = FRONT_FACING ? albedo_top.rgb : albedo_bottom.rgb;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("albedo_top",    color)
	mat.set_shader_parameter("albedo_bottom", Color(0.25, 0.22, 0.20))
	mat.set_shader_parameter("hole_count", mini(holes.size(), 16))

	var centers := PackedVector2Array()
	var radii   := PackedFloat32Array()
	for j in range(mini(holes.size(), 16)):
		centers.append((holes[j] as Dictionary)["center"])
		radii.append((holes[j] as Dictionary)["radius"])
	while centers.size() < 16:
		centers.append(Vector2.ZERO)
		radii.append(0.0)

	mat.set_shader_parameter("hole_centers", centers)
	mat.set_shader_parameter("hole_radii", radii)
	return mat
