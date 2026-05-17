class_name WorldData
extends RefCounted

const MAGIC := 0x47574C44  # "GWLD"

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
var _material      : Material
var _mat_cave      : ShaderMaterial
var _mat_cave_floor: ShaderMaterial
var _grass_meshes  : Array = []
var _tree_scene   : PackedScene = null
var _rock_scene   : PackedScene = null

# Each entry: { scene, density, upright, scale_min, scale_max, seed_offset }
# upright=true: Y stays world-up (characters, props). upright=false: aligns to slope (plants).
var _veg_specs : Array = []


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
		var h3 : Array[float] = []
		if types[i] == 2:
			h2.resize(cells)
			for j in range(cells):
				h2[j] = f.get_float()
			h3.resize(cells)
			for j in range(cells):
				h3[j] = f.get_float()

		_chunks.append({ "type": types[i], "h1": h1, "h2": h2, "h3": h3 })

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

	f.close()

	var holes := _find_holes()
	_material      = _make_surface_mat(Color(0.35, 0.52, 0.28), holes)
	_mat_cave       = _make_cave_mat(Color(0.40, 0.33, 0.25))   # ceiling — mid brown
	_mat_cave_floor = _make_cave_mat(Color(0.30, 0.20, 0.13))  # floor — darker brown
	var m := _merge_glb_mesh("res://assets/stylized_grass_bush.glb")
	if m:
		_grass_meshes.append(m)
	_tree_scene = load("res://assets/tree01.glb")
	_rock_scene = load("res://assets/rock01.glb")
	_veg_specs = [
		{ "scene": load("res://assets/fern01.glb"), "density": 0.12, "upright": false, "scale_min": 3.0, "scale_max": 6.0, "seed_offset": 1.0 },
	]
	return true


func spawn_into(parent: Node3D) -> void:
	var ox := world_ox
	var oz := world_oz

	for i in range(_chunks.size()):
		var cx := i % chunks_x
		var cz := int(i / chunks_x)
		var origin := Vector3(ox + cx * chunk_cells * cell_size, 0.0, oz + cz * chunk_cells * cell_size)
		parent.add_child(_make_chunk(_chunks[i].h1, origin, _material))
		parent.add_child(_make_grass_chunk(_chunks[i].h1, origin))
		for spec in _veg_specs:
			parent.add_child(_make_veg_chunk(_chunks[i].h1, origin, spec))
		if _chunks[i].type == 2:
			parent.add_child(_make_chunk(_chunks[i].h2, origin, _mat_cave))
			parent.add_child(_make_chunk(_chunks[i].h3, origin, _mat_cave))

	for obj in _static_objects:
		var wy    := _get_height_at(obj.x, obj.z)
		var scene := _tree_scene if obj.type == 0 else _rock_scene
		if scene:
			var node := scene.instantiate() as Node3D
			node.position = Vector3(obj.x, wy, obj.z)
			parent.add_child(node)

	var water_mat := _make_water_mat()
	for wr in _water_rects:
		var plane := PlaneMesh.new()
		plane.size = Vector2(wr.width as float, wr.depth as float)
		plane.surface_set_material(0, water_mat)
		var mi := MeshInstance3D.new()
		mi.mesh     = plane
		mi.position = Vector3(wr.x as float, wr.y as float, wr.z as float)
		parent.add_child(mi)


func _make_water_mat() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled;
uniform vec4  water_color : source_color = vec4(0.08, 0.38, 0.65, 0.6);
uniform float wave_speed  = 0.25;
uniform float wave_scale  = 5.0;
void fragment() {
	vec2 uv   = UV * wave_scale;
	float w   = sin(uv.x + TIME * wave_speed) * cos(uv.y + TIME * wave_speed * 0.7) * 0.04;
	ALBEDO    = water_color.rgb;
	ALPHA     = clamp(water_color.a + w, 0.3, 0.85);
	ROUGHNESS = 0.05;
	METALLIC  = 0.2;
	SPECULAR  = 1.0;
	NORMAL    = vec3(sin(uv.x + TIME * wave_speed) * 0.08, 1.0, cos(uv.y + TIME * wave_speed * 0.7) * 0.08);
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	return m

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


func _make_cave_mat(tint: Color) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D cave_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float tile_scale = 4.0;
varying vec3 world_pos;
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	vec3 tex = texture(cave_tex, world_pos.xz / tile_scale).rgb;
	ALBEDO = tex * tint.rgb;
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("cave_tex", load("res://assets/cave_texture.jpg"))
	m.set_shader_parameter("tint", tint)
	return m

func _make_standard_mat(color: Color) -> ShaderMaterial:
	return _make_cave_mat(color)


func _make_surface_mat(color: Color, holes: Array) -> Material:
	var sh  := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform float tile_scale = 2.0;
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
	vec4 tex = texture(albedo_texture, world_pos.xz / 66.0);
	ALBEDO = FRONT_FACING ? tex.rgb * vec3(0.85, 1.2, 0.75) : albedo_bottom.rgb;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("albedo_texture", load("res://assets/tileable_grass.png"))
	mat.set_shader_parameter("tile_scale",     21.0)
	mat.set_shader_parameter("albedo_bottom",  Color(0.25, 0.22, 0.20))
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


func _merge_glb_mesh(path: String) -> ArrayMesh:
	var scene := load(path) as PackedScene
	if not scene:
		return null
	var root   := scene.instantiate()
	var result := ArrayMesh.new()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			st.append_from(mi.mesh, s, mi.transform)
			var tmp := st.commit()
			result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, tmp.surface_get_arrays(0))
			result.surface_set_material(result.get_surface_count() - 1, mi.mesh.surface_get_material(s))
	root.free()
	return result


func _make_grass_chunk(h1: Array, origin: Vector3) -> Node3D:
	var container := Node3D.new()
	container.position = origin

	if _grass_meshes.is_empty():
		return container

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(origin.x) + str(origin.z))

	var xforms : Array = []
	for _i in _grass_meshes.size():
		xforms.append([])

	var stride := chunk_cells + 1
	for gz in range(chunk_cells):
		for gx in range(chunk_cells):
			var tl := gz * stride + gx
			if is_nan(h1[tl]) or is_nan(h1[tl+1]) or is_nan(h1[tl+stride]) or is_nan(h1[tl+stride+1]):
				continue
			if rng.randf() > 0.25:
				continue
			for _b in range(4):
				var rx  := rng.randf()
				var rz  := rng.randf()
				var fx  := (gx + rx) * cell_size
				var fz  := (gz + rz) * cell_size
				var hy  := _sample_height(h1, tl, rx, rz)
				var n   := _sample_normal(h1, tl, rx, rz)
				var rot := rng.randf() * TAU
				var sc  := rng.randf_range(0.0005, 0.0010)
				var fwd := Vector3(cos(rot), 0.0, sin(rot)).slide(n).normalized()
				var t   := Transform3D(Basis(fwd.cross(n).normalized(), n, -fwd).scaled(Vector3.ONE * sc), Vector3(fx, hy, fz))
				(xforms[rng.randi() % _grass_meshes.size()] as Array).append(t)

	for i in _grass_meshes.size():
		var arr := xforms[i] as Array
		if arr.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.mesh             = _grass_meshes[i]
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.instance_count   = arr.size()
		for j in arr.size():
			mm.set_instance_transform(j, arr[j])
		var mmi       := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		container.add_child(mmi)

	return container


func _sample_height(h1: Array, tl: int, rx: float, rz: float) -> float:
	var stride := chunk_cells + 1
	var h00 := h1[tl]               as float
	var h10 := h1[tl + 1]           as float
	var h01 := h1[tl + stride]      as float
	var h11 := h1[tl + stride + 1]  as float
	if rx + rz <= 1.0:
		return h00 + (h10 - h00) * rx + (h01 - h00) * rz
	else:
		return h11 + (h01 - h11) * (1.0 - rx) + (h10 - h11) * (1.0 - rz)

func _sample_normal(h1: Array, tl: int, rx: float, rz: float) -> Vector3:
	var stride := chunk_cells + 1
	var h00 := h1[tl]          as float
	var h10 := h1[tl + 1]      as float
	var h01 := h1[tl + stride] as float
	if rx + rz <= 1.0:
		return Vector3(0.0, h01 - h00, cell_size).cross(Vector3(cell_size, h10 - h00, 0.0)).normalized()
	else:
		var h11 := h1[tl + stride + 1] as float
		return Vector3(-cell_size, h01 - h10, cell_size).cross(Vector3(0.0, h11 - h10, cell_size)).normalized()

func _make_veg_chunk(h1: Array, origin: Vector3, spec: Dictionary) -> Node3D:
	var container := Node3D.new()
	container.position = origin

	var scene: PackedScene = spec["scene"]
	if scene == null:
		return container

	var density:    float = spec["density"]
	var upright:    bool  = spec["upright"]
	var scale_min:  float = spec["scale_min"]
	var scale_max:  float = spec["scale_max"]
	var seed_off:   float = spec["seed_offset"]

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(origin.x + seed_off) + str(origin.z + seed_off))

	var stride := chunk_cells + 1
	for gz in range(chunk_cells):
		for gx in range(chunk_cells):
			if rng.randf() > density:
				continue
			var tl := gz * stride + gx
			if is_nan(h1[tl]) or is_nan(h1[tl+1]) or is_nan(h1[tl+stride]) or is_nan(h1[tl+stride+1]):
				continue
			var rx  := rng.randf()
			var rz  := rng.randf()
			var fx  := (gx + rx) * cell_size
			var fz  := (gz + rz) * cell_size
			var hy  := _sample_height(h1, tl, rx, rz)
			var rot := rng.randf() * TAU
			var sc  := rng.randf_range(scale_min, scale_max)
			var inst := scene.instantiate() as Node3D
			if upright:
				inst.position   = Vector3(fx, hy, fz)
				inst.rotation.y = rot
			else:
				var normal := _sample_normal(h1, tl, rx, rz)
				var fwd    := Vector3(cos(rot), 0.0, sin(rot)).slide(normal).normalized()
				var right  := fwd.cross(normal).normalized()
				inst.transform = Transform3D(Basis(right, normal, -fwd).scaled(Vector3.ONE * sc), Vector3(fx, hy, fz))
			container.add_child(inst)

	return container
