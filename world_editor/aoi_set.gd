class_name AoiSet
extends Node3D
## Area of interest for editor content (walls, water, objects, props, spawns,
## chests): only the items near the camera have scene nodes. The data for the
## whole world stays loaded; nodes are built as the camera approaches and
## freed once it's left, the same way EditorWorldData.update_streaming does
## for terrain chunks.
##
## An owner gives it three callables (setup) and then:
##  - invalidate() whenever the item list changed (add/remove/edit/undo/load):
##    rebuilds the nodes in range at once, so edits show up the same frame;
##  - add_item(i) after appending item i, to build just that one;
## main.gd calls update_center() on every set each frame (group GROUP).
##
## Items are bucketed into a CELL grid by their XZ footprint, so moving the
## camera only touches the buckets that entered or left the radius, never the
## whole list. Nodes are keyed by item index, which is why removing items
## means invalidate().

const GROUP := "editor_aoi"
const CELL := 32.0                  # bucket size (m)
const MOVE_BUDGET_USEC := 3000      # build time per frame while the camera moves

static var radius := 160.0          # main.gd keeps it equal to the terrain stream radius

var _items: Callable      # () -> Array
var _footprint: Callable  # (item) -> Rect2 on XZ (position = min x/z, size = width/depth)
var _build: Callable      # (item, index: int, holder: Node3D) -> void; adds the item's nodes under holder (already in the tree)

var _grid    := {}        # Vector2i -> Array of item indices (Array, not Packed: a cast copies a packed array)
var _holders := {}        # index -> Node3D
var _queue: Array[int] = []
var _queued  := {}        # index -> true, mirrors _queue
var _center  := Vector2(INF, INF)
var _center_cell := Vector2i(0x7fffffff, 0x7fffffff)
var _indexed := false


func _ready() -> void:
	add_to_group(GROUP)


func setup(items: Callable, footprint: Callable, build: Callable) -> void:
	_items = items
	_footprint = footprint
	_build = build
	invalidate()


# The item list changed: re-bucket everything and rebuild what's in range now.
func invalidate() -> void:
	_indexed = false
	_clear_nodes()
	if not is_finite(_center.x) or not _items.is_valid(): return
	_reindex()
	_retarget()
	_drain(-1)


# Item i was just appended: index it and build it if it's in range.
func add_item(i: int) -> void:
	if not _indexed:
		invalidate()
		return
	var items: Array = _items.call()
	if i < 0 or i >= items.size(): return
	var r := _footprint.call(items[i]) as Rect2
	var c0 := _cell_of(r.position)
	var c1 := _cell_of(r.end)
	var near := false
	for cz in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var k := Vector2i(cx, cz)
			if not _grid.has(k): _grid[k] = []
			(_grid[k] as Array).append(i)
			if _cell_distance(k) <= radius: near = true
	if near: _build_one(i, items)


func update_center(center: Vector3) -> void:
	_center = Vector2(center.x, center.z)
	if not _items.is_valid(): return
	if not _indexed:
		_reindex()
		_center_cell = _cell_of(_center)
		_retarget()
		_drain(-1)
		return
	var cell := _cell_of(_center)
	if cell != _center_cell:
		_center_cell = cell
		_retarget()
	if not _queue.is_empty():
		_drain(MOVE_BUDGET_USEC)


func built_count() -> int:
	return _holders.size()


func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / CELL), floori(p.y / CELL))


# Distance from the camera to bucket k's square (0 inside it).
func _cell_distance(k: Vector2i) -> float:
	var dx := maxf(maxf(k.x * CELL - _center.x, _center.x - (k.x + 1) * CELL), 0.0)
	var dz := maxf(maxf(k.y * CELL - _center.y, _center.y - (k.y + 1) * CELL), 0.0)
	return sqrt(dx * dx + dz * dz)


func _reindex() -> void:
	_grid.clear()
	var items: Array = _items.call()
	for i in items.size():
		var r := _footprint.call(items[i]) as Rect2
		var c0 := _cell_of(r.position)
		var c1 := _cell_of(r.end)
		for cz in range(c0.y, c1.y + 1):
			for cx in range(c0.x, c1.x + 1):
				var k := Vector2i(cx, cz)
				if not _grid.has(k): _grid[k] = []
				(_grid[k] as Array).append(i)
	_indexed = true


# Frees what's past radius + one bucket (the gap stops edge items flickering)
# and queues what's within radius but not built yet, nearest buckets first.
func _retarget() -> void:
	var keep_r := radius + CELL
	var span := ceili(keep_r / CELL) + 1
	var cc := _cell_of(_center)
	var keep := {}
	var want: Array = []  # [distance, index]
	for dz in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var k := Vector2i(cc.x + dx, cc.y + dz)
			if not _grid.has(k): continue
			var d := _cell_distance(k)
			if d > keep_r: continue
			for i in (_grid[k] as Array):
				keep[i] = true
				if d <= radius and not _holders.has(i) and not _queued.has(i):
					_queued[i] = true
					want.append([d, i])
	for i in _holders.keys():
		if not keep.has(i):
			(_holders[i] as Node3D).queue_free()
			_holders.erase(i)
	# Queued earlier but out of range now: drop.
	var still: Array[int] = []
	for i in _queue:
		if keep.has(i): still.append(i)
		else: _queued.erase(i)
	want.sort_custom(func(a, b): return a[0] < b[0])
	for w in want: still.append(w[1])
	_queue = still


# Builds queued items until budget_usec runs out (-1 = all of them).
func _drain(budget_usec: int) -> void:
	var items: Array = _items.call()
	var t0 := Time.get_ticks_usec()
	var n := 0
	while n < _queue.size():
		var i := _queue[n]
		n += 1
		_queued.erase(i)
		if i < items.size() and not _holders.has(i):
			_build_one(i, items)
		if budget_usec >= 0 and Time.get_ticks_usec() - t0 >= budget_usec: break
	_queue = _queue.slice(n)


func _build_one(i: int, items: Array) -> void:
	var holder := Node3D.new()
	add_child(holder)
	_holders[i] = holder
	_build.call(items[i], i, holder)


func _clear_nodes() -> void:
	for h in _holders.values():
		(h as Node3D).queue_free()
	_holders.clear()
	_queue.clear()
	_queued.clear()
