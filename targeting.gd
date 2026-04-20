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

	var pkt := PackedByteArray()
	pkt.resize(5)
	pkt[0] = 0x07
	pkt.encode_u32(1, chosen)
	print("[target] sending net_id=", chosen, " connected=", Network.is_connected_to_server())
	Network.send(pkt)

func _get_mi(net_id: int) -> MeshInstance3D:
	if not _entity_manager.entities.has(net_id):
		return null
	return (_entity_manager.entities[net_id] as StaticBody3D).get_child(0) as MeshInstance3D

func _set_highlight(net_id: int, on: bool) -> void:
	var mi := _get_mi(net_id)
	if mi == null:
		return
	if on:
		var mat := StandardMaterial3D.new()
		mat.emission_enabled           = true
		mat.emission                   = Color(0.2, 0.5, 1.0)
		mat.emission_energy_multiplier = 1.3
		mi.set_surface_override_material(0, mat)
	else:
		mi.set_surface_override_material(0, null)
