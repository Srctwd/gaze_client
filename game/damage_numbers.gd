extends Node

@onready var _entity_manager: Node = $"../EntityManager"

func _ready() -> void:
	Network.action_ok.connect(_on_action_ok)

func _on_action_ok(_actor_id: int, _effect: int, target_id: int, action_type: int) -> void:
	if target_id == 0:
		return
	var target := _entity_manager.entities.get(target_id) as Node3D
	if target == null:
		return
	if action_type == Protocol.ACTION_ATTACK:
		_flash(target, Color(0.0, 0.0, 0.0, 0.5))
	elif action_type == Protocol.ACTION_SPELL:
		_flash(target, Color(0.1, 0.2, 0.5, 0.5))

func _flash(target: Node3D, color: Color) -> void:
	var meshes := target.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty():
		return

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	for mi in meshes:
		mi.material_overlay = mat

	await get_tree().create_timer(0.2).timeout

	for mi in meshes:
		if is_instance_valid(mi):
			mi.material_overlay = null
