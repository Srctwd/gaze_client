extends Node

@onready var _entity_manager: Node          = $"../EntityManager"
@onready var _camera:         CameraController = $"../Camera3D"

var player_net_id: int = -1:
	set(value):
		if value == -1:
			_set_highlight(_current_target, false)
			_current_target = -1
		player_net_id = value

var _current_target: int = -1

func _input(event: InputEvent) -> void:
	if event is InputEventKey \
			and event.keycode == KEY_TAB \
			and event.pressed and not event.echo \
			and player_net_id != -1:
		_select_target()

func _select_target() -> void:
	var screen_center := get_viewport().get_visible_rect().size * 0.5
	var player_pos    := Vector3.ZERO
	if _entity_manager.entities.has(player_net_id):
		player_pos = (_entity_manager.entities[player_net_id] as StaticBody3D).position

	var best_id      := -1
	var best_score   := INF
	var second_id    := -1
	var second_score := INF

	for net_id in _entity_manager.entities:
		if net_id == player_net_id:
			continue
		var body      := _entity_manager.entities[net_id] as StaticBody3D
		var to_target: Vector3 = (body.position - _camera.global_position).normalized()
		var cam_fwd:   Vector3 = -_camera.global_transform.basis.z
		if cam_fwd.dot(to_target) < cos(deg_to_rad(70.0)):
			continue
		var screen_pos  := _camera.unproject_position(body.position)
		var screen_dist := (screen_pos - screen_center).length() / screen_center.length()
		var world_dist  := body.position.distance_to(player_pos) / 100.0
		var score       := screen_dist * 3.0 + world_dist * 0.5
		if score < best_score:
			second_score = best_score
			second_id    = best_id
			best_score   = score
			best_id      = net_id
		elif score < second_score:
			second_score = score
			second_id    = net_id

	print("[target] best_id=", best_id, " second_id=", second_id, " current=", _current_target)
	if best_id == -1:
		return

	var chosen := best_id
	if best_id == _current_target:
		if second_id == -1 or second_score > best_score / 0.8:
			return
		chosen = second_id

	_set_highlight(_current_target, false)
	_set_highlight(chosen, true)
	_current_target = chosen

	print("[target] sending net_id=", chosen, " connected=", Network.is_connected_to_server())
	Network.send(Protocol.pkt_target(chosen))

func pick_aimed_item(items: Dictionary) -> int:
	if player_net_id == -1 or items.is_empty():
		return -1
	var screen_center := get_viewport().get_visible_rect().size * 0.5
	var player_pos    := Vector3.ZERO
	if _entity_manager.entities.has(player_net_id):
		player_pos = (_entity_manager.entities[player_net_id] as StaticBody3D).position
	var best_id    := -1
	var best_score := INF
	for net_id in items:
		var node := items[net_id] as Node3D
		if node == null: continue
		var to_item: Vector3 = (node.position - _camera.global_position).normalized()
		var cam_fwd: Vector3 = -_camera.global_transform.basis.z
		if cam_fwd.dot(to_item) < cos(deg_to_rad(70.0)):
			continue
		var screen_pos  := _camera.unproject_position(node.position)
		var screen_dist := (screen_pos - screen_center).length() / screen_center.length()
		var world_dist  := node.position.distance_to(player_pos) / 100.0
		var score       := screen_dist * 3.0 + world_dist * 0.5
		if score < best_score:
			best_score = score
			best_id    = net_id
	return best_id

func _get_mi(net_id: int) -> MeshInstance3D:
	if not _entity_manager.entities.has(net_id):
		return null
	var body := _entity_manager.entities[net_id] as StaticBody3D
	var results := body.find_children("*", "MeshInstance3D", true, false)
	return results[0] as MeshInstance3D if results.size() > 0 else null

func _set_highlight(net_id: int, on: bool) -> void:
	var mi := _get_mi(net_id)
	if mi == null:
		return
	if on:
		var orig := mi.material_override as StandardMaterial3D
		var base_color := Color(1, 1, 1)
		if orig:
			base_color = orig.albedo_color * Color(1, 1, 1)
		var mat := StandardMaterial3D.new()
		mat.albedo_color               = base_color
		mat.emission_enabled           = true
		mat.emission                   = Color(0.2, 0.5, 1.0)
		mat.emission_energy_multiplier = 1.3
		mi.set_meta("_hl_orig", mi.material_override)
		mi.material_override = mat
	else:
		if mi.has_meta("_hl_orig"):
			mi.material_override = mi.get_meta("_hl_orig") as Material
			mi.remove_meta("_hl_orig")
