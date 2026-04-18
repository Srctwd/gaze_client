class_name WorldData
extends RefCounted

var chunk_cells : int
var chunks_x    : int
var chunks_z    : int
var cell_size   : float
var _chunks     : Array = []  # Array of {type, h1: Array[float]}
var _material   : StandardMaterial3D


func _init() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.35, 0.52, 0.28)
	_material.cull_mode    = BaseMaterial3D.CULL_DISABLED



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

		_chunks.append({ "type": types[i], "h1": h1 })

	f.close()
	return true


func spawn_into(parent: Node3D) -> void:
	var ox := -(chunks_x * chunk_cells * cell_size * 0.5)
	var oz := -(chunks_z * chunk_cells * cell_size * 0.5)

	for i in range(_chunks.size()):
		var cx := i % chunks_x
		var cz := i / chunks_x
		cz = int(cz) # ✅ FIXED (no float index)

		var origin := Vector3(
			ox + cx * chunk_cells * cell_size,
			0.0,
			oz + cz * chunk_cells * cell_size
		)

		var mi := _make_chunk(_chunks[i].h1, origin)
		parent.add_child(mi)

	print("[terrain] added ", parent.get_child_count(), " children")


func _make_chunk(h1: Array, origin: Vector3) -> MeshInstance3D:
	var st     := SurfaceTool.new()
	var stride := chunk_cells + 1
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for gz in range(chunk_cells):
		for gx in range(chunk_cells):
			var tl := gz * stride + gx
			var v0 := Vector3(gx       * cell_size, h1[tl],          gz       * cell_size)
			var v1 := Vector3((gx+1)   * cell_size, h1[tl+1],        gz       * cell_size)
			var v2 := Vector3(gx       * cell_size, h1[tl+stride],   (gz+1)   * cell_size)
			var v3 := Vector3((gx+1)   * cell_size, h1[tl+stride+1], (gz+1)   * cell_size)
			var u0 := Vector2(float(gx)   / chunk_cells, float(gz)   / chunk_cells)
			var u1 := Vector2(float(gx+1) / chunk_cells, float(gz)   / chunk_cells)
			var u2 := Vector2(float(gx)   / chunk_cells, float(gz+1) / chunk_cells)
			var u3 := Vector2(float(gx+1) / chunk_cells, float(gz+1) / chunk_cells)
			st.set_uv(u0); st.add_vertex(v0)
			st.set_uv(u2); st.add_vertex(v2)
			st.set_uv(u1); st.add_vertex(v1)
			st.set_uv(u1); st.add_vertex(v1)
			st.set_uv(u2); st.add_vertex(v2)
			st.set_uv(u3); st.add_vertex(v3)
	st.generate_normals()
	st.index()
	var mesh := st.commit()
	mesh.surface_set_material(0, _material)
	var mi := MeshInstance3D.new()
	mi.mesh     = mesh
	mi.position = origin
	return mi