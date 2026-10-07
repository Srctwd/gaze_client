extends Node3D

const WorldData = preload("res://world/world_data.gd")

# Terrain chunks are streamed around the active camera instead of all being
# built up front (a 32x32-chunk world took ~50 s and ~8 GB to build in full).
# Chunks within view_radius (Chebyshev distance, in chunks) are built on
# WorkerThreadPool threads, nearest first, then turned into nodes on the main
# thread; chunks past view_radius + 1 are freed — the extra ring of slack
# stops a chunk thrashing in and out while the player walks along its edge.
@export var view_radius := 5
@export var max_pending_builds := 4       # worker tasks in flight at once
@export var finalize_budget_msec := 4.0   # main-thread node creation per frame

var _wd: RefCounted = null
var _loaded: Dictionary = {}    # chunk index -> Node3D
var _pending: Dictionary = {}   # chunk index -> WorkerThreadPool task id
var _built: Dictionary = {}     # chunk index -> build_chunk_arrays() result, guarded by _built_mutex
var _built_mutex := Mutex.new()
var _center := Vector2i(-99999, -99999)
var _wanted: Array[int] = []    # indices within view_radius not yet loaded, nearest first

func _ready() -> void:
	_wd = WorldData.new()
	if _wd.load("res://world.bin"):
		_wd.spawn_static(self)
	else:
		_wd = null
		set_process(false)

func _exit_tree() -> void:
	for task_id in _pending.values():
		WorkerThreadPool.wait_for_task_completion(task_id)
	_pending.clear()

func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null: return
	var c: Vector2i = _wd.chunk_coords_at(cam.global_position.x, cam.global_position.z)
	if c != _center:
		_center = c
		_retarget()
	_collect_finished()
	_finalize_built()
	_submit_builds()

# Recomputes which chunks should exist for the new center chunk, frees the
# ones that fell out of range, and queues the missing ones nearest first.
func _retarget() -> void:
	for idx in _loaded.keys():
		var cc := _coords(idx)
		if _chebyshev(cc, _center) > view_radius + 1:
			(_loaded[idx] as Node3D).queue_free()
			_loaded.erase(idx)
	var wanted: Array[Vector2i] = []
	for dz in range(-view_radius, view_radius + 1):
		for dx in range(-view_radius, view_radius + 1):
			var cc := _center + Vector2i(dx, dz)
			var idx: int = _wd.chunk_index(cc)
			if idx >= 0 and not _loaded.has(idx):
				wanted.append(cc)
	wanted.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - _center).length_squared() < (b - _center).length_squared())
	_wanted.clear()
	for cc in wanted:
		_wanted.append(_wd.chunk_index(cc))

func _submit_builds() -> void:
	while _pending.size() < max_pending_builds and not _wanted.is_empty():
		var idx: int = _wanted.pop_front()
		if _loaded.has(idx) or _pending.has(idx): continue
		_pending[idx] = WorkerThreadPool.add_task(_build_task.bind(idx), false, "terrain chunk %d" % idx)

# Runs on a worker thread — touches nothing but WorldData's read-only height
# arrays and the mutex-guarded _built handoff.
func _build_task(idx: int) -> void:
	var arrays: Dictionary = _wd.build_chunk_arrays(idx)
	_built_mutex.lock()
	_built[idx] = arrays
	_built_mutex.unlock()

func _collect_finished() -> void:
	for idx in _pending.keys():
		var task_id: int = _pending[idx]
		if WorkerThreadPool.is_task_completed(task_id):
			WorkerThreadPool.wait_for_task_completion(task_id)
			_pending.erase(idx)

func _finalize_built() -> void:
	var t0 := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < finalize_budget_msec * 1000.0:
		_built_mutex.lock()
		var keys := _built.keys()
		if keys.is_empty():
			_built_mutex.unlock()
			return
		# Nearest first, so the ground under the player appears before the horizon.
		var best: int = keys[0]
		for k in keys:
			if _dist_to_center(k) < _dist_to_center(best): best = k
		var arrays: Dictionary = _built[best]
		_built.erase(best)
		_built_mutex.unlock()
		# The camera may have moved on while this was building.
		if _chebyshev(_coords(best), _center) > view_radius + 1 or _loaded.has(best):
			continue
		var node: Node3D = _wd.make_chunk_node(best, arrays)
		add_child(node)
		_loaded[best] = node

func _coords(idx: int) -> Vector2i:
	return Vector2i(idx % _wd.chunks_x, int(idx / _wd.chunks_x))

func _dist_to_center(idx: int) -> int:
	return (_coords(idx) - _center).length_squared()

func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))

# True once every chunk within view_radius of the camera has been built —
# e.g. to hold a loading screen until the ground around the player exists.
func is_area_loaded() -> bool:
	_built_mutex.lock()
	var none_built := _built.is_empty()
	_built_mutex.unlock()
	return _wanted.is_empty() and _pending.is_empty() and none_built

func is_in_water(pos: Vector3) -> bool:
	if _wd == null: return false
	for wr in _wd._water_rects:
		var hw := (wr.width as float) * 0.5
		var hd := (wr.depth as float) * 0.5
		if pos.x >= wr.x - hw and pos.x <= wr.x + hw \
		and pos.z >= wr.z - hd and pos.z <= wr.z + hd \
		and pos.y <= wr.y:
			return true
	return false

# Returns the nearest static object of the given type within max_dist (horizontal distance),
# as {"x": float, "z": float}, or null if none in range.
func nearest_static_object(pos: Vector3, obj_type: int, max_dist: float) -> Variant:
	if _wd == null: return null
	var best: Variant = null
	var best_dist := max_dist
	for obj in _wd._static_objects:
		if obj.type != obj_type: continue
		var d := Vector2(pos.x - (obj.x as float), pos.z - (obj.z as float)).length()
		if d <= best_dist:
			best_dist = d
			best = obj
	return best
