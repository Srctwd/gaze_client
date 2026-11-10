const _GRASS_TEX = preload("res://assets/textures/tileable_grass.png")
const _CAVE_TEX  = preload("res://assets/textures/cave_texture.jpg")


# Every world material is a PS2 one (res://ps2/, PS2_RENDERING.md): terrain,
# caves and walls share ps2_world.gdshader, picking its texture projection
# per material; water uses ps2_water.gdshader. Their lighting and fog come
# from the global uniforms the Ps2 autoload sets every frame.
const PS2_WORLD_SHADER = preload("res://ps2/ps2_world.gdshader")
const PS2_WATER_SHADER = preload("res://ps2/ps2_water.gdshader")
const PROJECTION_TOP_DOWN := 1
const PROJECTION_TRIPLANAR := 2
# Caves get the full scene ambient (× Ps2.ambient_gain 0.6 ≈ 1.0) and no sun;
# less leaves a torch as the only light, so caves go red.
const CAVE_AMBIENT := 1.67


static func water_mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PS2_WATER_SHADER
	m.set_shader_parameter("water_color", Vector4(0.08, 0.38, 0.65, 0.6))
	m.set_shader_parameter("wave_speed", 0.25)
	m.set_shader_parameter("wave_scale", 5.0)
	return m


static func cave_mat(tint: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PS2_WORLD_SHADER
	m.set_shader_parameter("albedo_tex", _CAVE_TEX)
	# Triplanar: a top-down projection alone smears into streaks on steep cave
	# surfaces (tunnel arches, chamber walls).
	m.set_shader_parameter("projection", PROJECTION_TRIPLANAR)
	m.set_shader_parameter("tile_scale", 4.0)
	m.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	m.set_shader_parameter("dir_light_scale", 0.0)   # no sun underground
	m.set_shader_parameter("ambient_scale", CAVE_AMBIENT)
	return m


# Default grass look keeps its green boost.
const _GRASS_TINT := Color(0.85, 1.2, 0.75)


static func surface_mat(tex: Texture2D = _GRASS_TEX, top_tint: Color = _GRASS_TINT, tile_size: float = 66.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PS2_WORLD_SHADER
	m.set_shader_parameter("albedo_tex", tex)
	m.set_shader_parameter("projection", PROJECTION_TOP_DOWN)
	m.set_shader_parameter("tile_scale", tile_size)
	m.set_shader_parameter("tint", Vector3(top_tint.r, top_tint.g, top_tint.b))
	# Undersides (seen from caves below) are a flat earth colour.
	m.set_shader_parameter("flat_backface", true)
	m.set_shader_parameter("backface_color", Vector3(0.25, 0.22, 0.20))
	return m


# Fallback for walls whose type has no material. Each wall type is a
# ShaderMaterial .tres on ps2_world.gdshader under res://assets/materials/walls/
# (wall_types.json "material").
static func wall_mat(texture: Texture2D = _CAVE_TEX) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PS2_WORLD_SHADER
	m.set_shader_parameter("albedo_tex", texture)
	m.set_shader_parameter("projection", PROJECTION_TRIPLANAR)
	m.set_shader_parameter("tile_scale", 2.0)
	return m


# Per-cell terrain textures (world_data.gd, terrain_cells.gdshaderinc): every
# texture of the cells file's list, resized to one size, as one array.
const CELL_TEX_SIZE := 256
const CELL_TEX_MAX  := 64   # terrain_cells.gdshaderinc's cell_tile[] size


static func cell_texture_array(paths: Array) -> Texture2DArray:
	var images: Array[Image] = []
	for path in paths:
		var tex := resolve_texture(path as String)
		var img: Image
		if tex != null:
			img = tex.get_image()
			if img.is_compressed():
				img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			img.resize(CELL_TEX_SIZE, CELL_TEX_SIZE, Image.INTERPOLATE_BILINEAR)
		else:
			push_warning("WorldShaders: cell texture not found: %s" % path)
			img = Image.create_empty(CELL_TEX_SIZE, CELL_TEX_SIZE, false, Image.FORMAT_RGBA8)
			img.fill(Color.MAGENTA)
		img.generate_mipmaps()
		images.append(img)
	var arr := Texture2DArray.new()
	arr.create_from_images(images)
	return arr


# `base` (a surface_mat) with chunk cells painted on: `cells` holds one byte
# per cell, row by row, for a chunk of `cells_n`² cells at `origin`.
static func cell_surface_mat(base: ShaderMaterial, cells: PackedByteArray, cells_n: int, origin: Vector2,
		cell_size: float, tex_array: Texture2DArray, tiles: PackedFloat32Array) -> ShaderMaterial:
	var mat := base.duplicate() as ShaderMaterial
	var index := ImageTexture.create_from_image(Image.create_from_data(cells_n, cells_n, false, Image.FORMAT_R8, cells))
	mat.set_shader_parameter("use_cells",   true)
	mat.set_shader_parameter("cell_index",  index)
	mat.set_shader_parameter("cell_tex",    tex_array)
	mat.set_shader_parameter("cell_tile",   tiles)
	mat.set_shader_parameter("cell_origin", origin)
	mat.set_shader_parameter("cell_size",   cell_size)
	return mat


# Surface textures (painted cells, walls) all live in TEXTURE_DIR.
# A path may be res://-absolute, relative to res://assets
# ("textures/grass.png") or a bare file name ("grass.png", "grass"). Older
# worlds name e.g. res://assets/city_ph.png, so if the exact path is missing,
# look for the same file stem in TEXTURE_DIR with any common image extension.
const TEXTURE_DIR := "res://assets/textures"


static func resolve_texture(path: String) -> Texture2D:
	if not path.begins_with("res://"):
		path = "res://assets/" + path if path.contains("/") else TEXTURE_DIR.path_join(path)
	var tex := _load_texture(path)
	if tex != null:
		return tex
	var stem := path.get_file().get_basename()
	for dir in [TEXTURE_DIR, path.get_base_dir()]:
		for ext in ["png", "jpg", "jpeg", "webp"]:
			tex = _load_texture("%s/%s.%s" % [dir, stem, ext])
			if tex != null:
				return tex
	return null


static func _load_texture(path: String) -> Texture2D:
	if not path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
		return null
	if not FileAccess.file_exists(path) and not ResourceLoader.exists(path):
		return null
	if ResourceLoader.exists(path):
		var tex := ResourceLoader.load(path) as Texture2D
		if tex != null:
			return tex
	# Not imported yet (dropped in while the editor wasn't scanning): read the
	# raw image so the texture still renders.
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
