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

# The target is whatever unit the player is looking at, re-picked every
# frame with the same aim scoring as items (_score_candidate) — it's
# highlighted and synced to the server (pkt_target) whenever it changes, so
# what glows is exactly what an attack or cast will go for.
func _process(_delta: float) -> void:
	if GameState.player_net_id == -1:
		return
	var chosen := _pick_unit()
	if chosen == _current_target:
		return
	_set_highlight(_current_target, false)
	_set_highlight(chosen, true)
	_current_target = chosen
	# The server has no "clear target" — looking at nothing just drops the
	# local highlight and leaves its last target in place.
	if chosen != -1:
		Network.send(Protocol.pkt_target(chosen))

# Best-scoring unit in the aim cone, or -1. The current target is kept
# unless another one scores clearly better (_TARGET_STICKINESS), so two
# units at nearly the same spot on screen don't flicker back and forth.
const _TARGET_STICKINESS := 0.85

func _pick_unit() -> int:
	var screen_center := get_viewport().get_visible_rect().size * 0.5
	var player_pos    := Vector3.ZERO
	if _entity_manager.entities.has(GameState.player_net_id):
		player_pos = (_entity_manager.entities[GameState.player_net_id] as StaticBody3D).position
	var best_id       := -1
	var best_score    := INF
	var current_score := INF
	for net_id in _entity_manager.entities:
		if net_id == GameState.player_net_id or _entity_manager.chests.has(net_id):
			continue
		var body  := _entity_manager.entities[net_id] as StaticBody3D
		var score := _score_candidate(body.position, player_pos, screen_center)
		if net_id == _current_target:
			current_score = score
		if score < best_score:
			best_score = score
			best_id    = net_id
	if current_score != INF and current_score * _TARGET_STICKINESS <= best_score:
		return _current_target
	return best_id

# The unit an attack or cast should go for right now — refreshed first so a
# click on the same frame as a look adjustment still hits what's under aim.
func pick_aimed_unit() -> int:
	if GameState.player_net_id == -1:
		return -1
	_process(0.0)
	return _current_target

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

# The glow is an additive overlay drawn on top of the mesh, so the unit's own
# material (textures, PS2 shader) stays untouched while targeted.
var _highlight_mat: StandardMaterial3D

func _get_highlight_mat() -> StandardMaterial3D:
	if _highlight_mat == null:
		_highlight_mat = StandardMaterial3D.new()
		_highlight_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_highlight_mat.blend_mode   = BaseMaterial3D.BLEND_MODE_ADD
		_highlight_mat.albedo_color = Color(0.2, 0.5, 1.0) * 0.6
	return _highlight_mat

func _set_highlight(net_id: int, on: bool) -> void:
	var mi := _get_mi(net_id)
	if mi == null:
		return
	if on:
		mi.set_meta("_hl_orig", mi.material_overlay)
		mi.material_overlay = _get_highlight_mat()
	else:
		if mi.has_meta("_hl_orig"):
			mi.material_overlay = mi.get_meta("_hl_orig") as Material
			mi.remove_meta("_hl_orig")
