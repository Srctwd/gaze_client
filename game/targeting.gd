extends Node

@onready var _entity_manager: Node          = $"../EntityManager"
@onready var _camera:         CameraController = $"../Camera3D"

var _current_target: int = -1

func _ready() -> void:
	GameState.player_id_changed.connect(_on_player_id_changed)

func _on_player_id_changed(net_id: int) -> void:
	if net_id == -1:
		_set_highlight(_current_target, false)
		_current_target = -1

func _input(event: InputEvent) -> void:
	if event is InputEventKey \
			and event.keycode == KEY_TAB \
			and event.pressed and not event.echo \
			and GameState.player_net_id != -1:
		_select_target()

func _select_target() -> void:
	var screen_center := get_viewport().get_visible_rect().size * 0.5
	var player_pos    := Vector3.ZERO
	if _entity_manager.entities.has(GameState.player_net_id):
		player_pos = (_entity_manager.entities[GameState.player_net_id] as StaticBody3D).position

	var best_id      := -1
	var best_score   := INF
	var second_id    := -1
	var second_score := INF

	for net_id in _entity_manager.entities:
		if net_id == GameState.player_net_id:
			continue
		var body  := _entity_manager.entities[net_id] as StaticBody3D
		var score := _score_candidate(body.position, player_pos, screen_center)
		if score == INF:
			continue
		if score < best_score:
			second_score = best_score
			second_id    = best_id
			best_score   = score
			best_id      = net_id
		elif score < second_score:
			second_score = score
			second_id    = net_id

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

	Network.send(Protocol.pkt_target(chosen))

# Same aim-scoring as pick_aimed_item, but over combat units (_entity_manager.entities)
# instead of floor items — used for a single shot's target (e.g. the bow), not
# the persistent tab-target lock (_select_target/pkt_target).
func pick_aimed_unit() -> int:
	if GameState.player_net_id == -1:
		return -1
	var screen_center := get_viewport().get_visible_rect().size * 0.5
	var player_pos    := Vector3.ZERO
	if _entity_manager.entities.has(GameState.player_net_id):
		player_pos = (_entity_manager.entities[GameState.player_net_id] as StaticBody3D).position
	var best_id    := -1
	var best_score := INF
	for net_id in _entity_manager.entities:
		if net_id == GameState.player_net_id:
			continue
		var body := _entity_manager.entities[net_id] as StaticBody3D
		var score := _score_candidate(body.position, player_pos, screen_center)
		if score < best_score:
			best_score = score
			best_id    = net_id
	return best_id

func pick_aimed_item(items: Dictionary) -> int:
	if GameState.player_net_id == -1 or items.is_empty():
		return -1
	var screen_center := get_viewport().get_visible_rect().size * 0.5
	var player_pos    := Vector3.ZERO
	if _entity_manager.entities.has(GameState.player_net_id):
		player_pos = (_entity_manager.entities[GameState.player_net_id] as StaticBody3D).position
	var best_id    := -1
	var best_score := INF
	for net_id in items:
		var node := items[net_id] as Node3D
		if node == null: continue
		var score := _score_candidate(node.position, player_pos, screen_center)
		if score < best_score:
			best_score = score
			best_id    = net_id
	return best_id

# Returns INF if outside the targeting cone.
func _score_candidate(world_pos: Vector3, player_pos: Vector3, screen_center: Vector2) -> float:
	var to_target := (world_pos - _camera.global_position).normalized()
	if -_camera.global_transform.basis.z.dot(to_target) < cos(deg_to_rad(Config.TARGETING_FOV_DEG)):
		return INF
	var screen_dist := (_camera.unproject_position(world_pos) - screen_center).length() / screen_center.length()
	var world_dist  := world_pos.distance_to(player_pos) / Config.TARGETING_WORLD_NORM
	return screen_dist * Config.TARGETING_SCREEN_WEIGHT + world_dist * Config.TARGETING_WORLD_WEIGHT

func _get_mi(net_id: int) -> MeshInstance3D:
	if not _entity_manager.entities.has(net_id):
		return null
	var body    := _entity_manager.entities[net_id] as StaticBody3D
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
