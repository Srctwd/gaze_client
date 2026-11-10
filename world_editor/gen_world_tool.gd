extends SceneTree

const WorldDataScript = preload("res://world_editor/world_data.gd")

var _rng := RandomNumberGenerator.new()

func _init() -> void:
	_rng.seed = 20260912

	var chunks_x := 8
	var chunks_z := 8
	var cells := 128
	var csize := 0.5
	var base_h := 0.0

	var wd = WorldDataScript.new()
	wd.create_new(chunks_x, chunks_z, cells, csize, base_h)
	_load_biomes(wd)

	var stride := cells + 1
	var grid_w := chunks_x * cells + 1
	var grid_h := chunks_z * cells + 1
	var world_ox: float = wd.world_ox
	var world_oz: float = wd.world_oz

	# ── noise fields — one per "zone" so each region of the map is shaped by a
	# different function (smooth rolling / warped bumps / terraced steps / ridged-sunken).
	var zone_noise := FastNoiseLite.new()
	zone_noise.seed = 1001
	zone_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	zone_noise.frequency = 1.0 / 190.0

	var base_noise := FastNoiseLite.new()
	base_noise.seed = 2002
	base_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	base_noise.fractal_octaves = 2
	base_noise.frequency = 1.0 / 150.0

	var n_plains := FastNoiseLite.new()
	n_plains.seed = 11; n_plains.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_plains.fractal_octaves = 2; n_plains.frequency = 1.0 / 55.0

	var n_starting := FastNoiseLite.new()
	n_starting.seed = 22; n_starting.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_starting.fractal_octaves = 3; n_starting.frequency = 1.0 / 38.0

	var n_forest := FastNoiseLite.new()
	n_forest.seed = 33; n_forest.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_forest.fractal_octaves = 3; n_forest.frequency = 1.0 / 30.0

	var n_demon := FastNoiseLite.new()
	n_demon.seed = 44; n_demon.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_demon.fractal_octaves = 3; n_demon.frequency = 1.0 / 24.0

	print("Generating height grid %d x %d ..." % [grid_w, grid_h])
	var grid := PackedFloat32Array()
	grid.resize(grid_w * grid_h)
	for gz in range(grid_h):
		var wz := world_oz + gz * csize
		for gx in range(grid_w):
			var wx := world_ox + gx * csize
			var zt := (zone_noise.get_noise_2d(wx, wz) + 1.0) * 0.5 * 4.0
			var za := clampi(int(floor(zt)), 0, 3)
			var zb := clampi(za + 1, 0, 3)
			var t := clampf(zt - za, 0.0, 1.0)
			t = t * t * (3.0 - 2.0 * t)
			var ha := _zone_height(za, wx, wz, base_noise, n_plains, n_starting, n_forest, n_demon)
			var hb := _zone_height(zb, wx, wz, base_noise, n_plains, n_starting, n_forest, n_demon)
			grid[gz * grid_w + gx] = lerpf(ha, hb, t)

	print("Smoothing (slope taming) ...")
	for _p in range(3):
		grid = _box_blur(grid, grid_w, grid_h)

	for i in range(grid.size()):
		grid[i] = clampf(grid[i], -3.0, 5.0)

	print("Carving lakes ...")
	var water_rects := []
	var lake_spots := _pick_lake_centers(grid, grid_w, grid_h, 2, 70, 24)
	for c in lake_spots:
		var wr := _carve_lake(grid, grid_w, grid_h, c[0], c[1], 16.0, 26.0, csize, world_ox, world_oz)
		water_rects.append(wr)

	print("Clamping slopes for navigability ...")
	_clamp_slope(grid, grid_w, grid_h, csize, 0.65, 80)
	for _p in range(2):
		grid = _box_blur(grid, grid_w, grid_h)

	print("Slicing into %d chunks ..." % (chunks_x * chunks_z))
	var biome_for_zone := [0, 2, 3, 4]
	for cz in range(chunks_z):
		for cx in range(chunks_x):
			var idx := cz * chunks_x + cx
			var h1 := PackedFloat32Array()
			h1.resize(stride * stride)
			for vz in range(stride):
				var gz := cz * cells + vz
				for vx in range(stride):
					var gx := cx * cells + vx
					h1[vz * stride + vx] = grid[gz * grid_w + gx]
			wd._chunks[idx]["h1"] = h1
			var ccx := world_ox + (cx + 0.5) * cells * csize
			var ccz := world_oz + (cz + 0.5) * cells * csize
			var zone_id := _zone_at(ccx, ccz, zone_noise)
			wd._chunks[idx]["biome"] = biome_for_zone[zone_id]

	wd._stitch_all_borders("h1")

	for wr in water_rects:
		wd.add_water_rect(wr.x, wr.z, wr.width, wr.depth, wr.y)

	print("Scattering props ...")
	_scatter_props(wd, chunks_x, chunks_z, cells, csize, world_ox, world_oz, water_rects)

	_report_stats(grid, grid_w, grid_h, csize)
	print("Water rects placed: %d" % water_rects.size())
	print("Static objects placed: %d" % wd._static_objects.size())

	var object_type_defs := _load_type_defs(ProjectSettings.globalize_path("res://").path_join("../stone_gaze/object_types.json"), "mesh", "scale_ratio")
	var wall_type_defs := _load_type_defs("res://wall_types.json", "material", "")

	var out_path := "res://world_editor/generated.bin"
	if wd.save(out_path, object_type_defs, wall_type_defs):
		print("SAVED OK -> %s" % ProjectSettings.globalize_path(out_path))
	else:
		print("SAVE FAILED")

	quit()


func _zone_height(zone: int, wx: float, wz: float, base_noise: FastNoiseLite,
		n_plains: FastNoiseLite, n_starting: FastNoiseLite, n_forest: FastNoiseLite,
		n_demon: FastNoiseLite) -> float:
	var base_v := base_noise.get_noise_2d(wx, wz) * 0.6
	match zone:
		0: # default / plains — smooth low rolling
			return base_v + n_plains.get_noise_2d(wx, wz) * 0.5
		1: # StartingForest — gentle bumps warped by a sinusoid (different fn)
			var warp := sin(wx * 0.05) * cos(wz * 0.05) * 0.2
			return base_v + n_starting.get_noise_2d(wx, wz) * 0.9 + warp
		2: # Forest — terraced/stepped hills (different fn: floor-quantized)
			var raw := base_v + n_forest.get_noise_2d(wx, wz) * 1.6
			var step := 0.6
			var terraced: float = floor(raw / step) * step
			return lerpf(raw, terraced, 0.6)
		3: # DemonForest — ridged, sunken/craggy (different fn: abs-ridge)
			var ridged := absf(n_demon.get_noise_2d(wx, wz)) * 2.2
			return -1.2 - ridged * 0.6 + base_v * 0.3
	return base_v


func _box_blur(grid: PackedFloat32Array, w: int, h: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(grid.size())
	for gz in range(h):
		var z0 := maxi(gz - 1, 0)
		var z1 := mini(gz + 1, h - 1)
		for gx in range(w):
			var x0 := maxi(gx - 1, 0)
			var x1 := mini(gx + 1, w - 1)
			var sum := 0.0
			var cnt := 0
			for zz in range(z0, z1 + 1):
				var row := zz * w
				for xx in range(x0, x1 + 1):
					sum += grid[row + xx]
					cnt += 1
			out[gz * w + gx] = sum / cnt
	return out


func _pick_lake_centers(grid: PackedFloat32Array, gw: int, gh: int, count: int,
		margin: int, step: int) -> Array:
	var candidates := []
	for gz in range(margin, gh - margin, step):
		for gx in range(margin, gw - margin, step):
			candidates.append([gx, gz, grid[gz * gw + gx]])
	candidates.sort_custom(func(a, b): return a[2] < b[2])
	var chosen := []
	var min_sep := 90
	for c in candidates:
		var ok := true
		for ch in chosen:
			var dx: float = c[0] - ch[0]
			var dz: float = c[1] - ch[1]
			if sqrt(dx * dx + dz * dz) < min_sep:
				ok = false
				break
		if ok:
			chosen.append(c)
		if chosen.size() >= count:
			break
	return chosen


func _carve_lake(grid: PackedFloat32Array, gw: int, gh: int, gx0: int, gz0: int,
		deep_radius: float, influence_radius: float, csize: float,
		world_ox: float, world_oz: float) -> Dictionary:
	# Wide, gentle falloff from a flat basin floor out to the untouched
	# surrounding terrain — the actual slope cap is enforced separately by
	# _clamp_slope, but a gradual approach here keeps that pass cheap.
	var idx_r := int(ceil(influence_radius / csize)) + 4
	var basin_target: float = grid[gz0 * gw + gx0] - 1.6
	var z0 := maxi(gz0 - idx_r, 0)
	var z1 := mini(gz0 + idx_r, gh - 1)
	var x0 := maxi(gx0 - idx_r, 0)
	var x1 := mini(gx0 + idx_r, gw - 1)
	for gz in range(z0, z1 + 1):
		for gx in range(x0, x1 + 1):
			var d := sqrt(float((gx - gx0) * (gx - gx0) + (gz - gz0) * (gz - gz0))) * csize
			if d < influence_radius:
				var t := 1.0 - clampf(d / influence_radius, 0.0, 1.0)
				t = t * t * (3.0 - 2.0 * t)
				var i := gz * gw + gx
				grid[i] = lerpf(grid[i], basin_target, t)
	var wx := world_ox + gx0 * csize
	var wz := world_oz + gz0 * csize
	return { "x": wx, "z": wz, "width": deep_radius * 1.6, "depth": deep_radius * 1.6,
		"y": basin_target + 0.7 }


func _clamp_slope(grid: PackedFloat32Array, w: int, h: int, csize: float,
		max_slope: float, max_iters: int) -> void:
	var max_delta := max_slope * csize
	for _iter in range(max_iters):
		var changed := false
		for gz in range(h):
			var row := gz * w
			for gx in range(w - 1):
				var i := row + gx
				var j := i + 1
				var d: float = grid[j] - grid[i]
				if absf(d) > max_delta:
					var excess := (absf(d) - max_delta) * 0.5 * signf(d)
					grid[i] += excess
					grid[j] -= excess
					changed = true
		for gz in range(h - 1):
			for gx in range(w):
				var i := gz * w + gx
				var j := i + w
				var d: float = grid[j] - grid[i]
				if absf(d) > max_delta:
					var excess := (absf(d) - max_delta) * 0.5 * signf(d)
					grid[i] += excess
					grid[j] -= excess
					changed = true
		if not changed:
			break


func _zone_at(wx: float, wz: float, zone_noise: FastNoiseLite) -> int:
	var zt := (zone_noise.get_noise_2d(wx, wz) + 1.0) * 0.5 * 4.0
	return clampi(int(round(zt)), 0, 3)


func _scatter_props(wd, chunks_x: int, chunks_z: int, cells: int, csize: float,
		world_ox: float, world_oz: float, water_rects: Array) -> void:
	var chunk_size := cells * csize
	var density_by_biome := { 0: 5, 2: 10, 3: 9, 4: 4 }
	var ids_by_biome := { 0: [0], 2: [0, 7, 9], 3: [7, 8, 9, 10], 4: [1, 1, 0] }
	for cz in range(chunks_z):
		for cx in range(chunks_x):
			var idx := cz * chunks_x + cx
			var biome_id: int = wd._chunks[idx]["biome"]
			var density: int = density_by_biome.get(biome_id, 5)
			var ids: Array = ids_by_biome.get(biome_id, [0])
			var placed := []
			var attempts := 0
			while placed.size() < density and attempts < density * 10:
				attempts += 1
				var lx := _rng.randf_range(4.0, chunk_size - 4.0)
				var lz := _rng.randf_range(4.0, chunk_size - 4.0)
				var wx := world_ox + cx * chunk_size + lx
				var wz := world_oz + cz * chunk_size + lz
				var near_water := false
				for wr in water_rects:
					if absf(wx - wr.x) < wr.width * 0.5 + 3.0 and absf(wz - wr.z) < wr.depth * 0.5 + 3.0:
						near_water = true
						break
				if near_water: continue
				var too_close := false
				for p in placed:
					if Vector2(wx, wz).distance_to(Vector2(p[0], p[1])) < 3.0:
						too_close = true
						break
				if too_close: continue
				var t: int = ids[_rng.randi() % ids.size()]
				var is_rock := (t == 1)
				var radius := _rng.randf_range(0.9, 1.6) if is_rock else _rng.randf_range(0.4, 0.55)
				var height := _rng.randf_range(1.0, 1.8) if is_rock else _rng.randf_range(7.0, 9.5)
				wd.add_static_object(t, wx, wz, radius, height)
				placed.append([wx, wz])


func _report_stats(grid: PackedFloat32Array, gw: int, gh: int, csize: float) -> void:
	var min_h := INF
	var max_h := -INF
	var max_slope := 0.0
	for gz in range(gh):
		for gx in range(gw):
			var h: float = grid[gz * gw + gx]
			min_h = minf(min_h, h)
			max_h = maxf(max_h, h)
			if gx + 1 < gw:
				max_slope = maxf(max_slope, absf(h - grid[gz * gw + gx + 1]) / csize)
			if gz + 1 < gh:
				max_slope = maxf(max_slope, absf(h - grid[(gz + 1) * gw + gx]) / csize)
	print("Height range: %.2f .. %.2f" % [min_h, max_h])
	print("Max adjacent-vertex slope (rise/run): %.3f  (%.1f deg)" % [max_slope, rad_to_deg(atan(max_slope))])


func _load_biomes(wd) -> void:
	if not FileAccess.file_exists("res://world_editor/biomes.json"): return
	var f := FileAccess.open("res://world_editor/biomes.json", FileAccess.READ)
	if f == null: return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Array and not (parsed as Array).is_empty():
		wd._biomes = parsed as Array
		for b in wd._biomes:
			var bd := b as Dictionary
			for k in ["material", "spawn_type", "spawn_interval", "spawn_max", "spawn_prob"]: bd.erase(k)
			var props_: Array = bd.get("props", []) as Array
			for i in range(props_.size()):
				var p = props_[i]
				if not (p is Dictionary):
					props_[i] = { "path": p as String, "weight": 1.0 }
			bd["props"] = props_


func _load_type_defs(path: String, value_key: String, default_extra) -> Dictionary:
	var defs := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("cannot open " + path)
		return defs
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Array): return defs
	for entry in parsed:
		var d := entry as Dictionary
		if not d.has("id"): continue
		var id := int(d["id"])
		if value_key == "mesh":
			defs[id] = { "mesh": d.get("mesh", ""), "scale_ratio": float(d.get("scale_ratio", 1.0)) }
		else:
			defs[id] = { "material": d.get("material", "") }
	return defs
