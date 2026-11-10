@tool
extends EditorPlugin

var _import: EditorScenePostImportPlugin


func _enter_tree() -> void:
	_import = preload("res://addons/ps2_import/ps2_post_import.gd").new()
	add_scene_post_import_plugin(_import)


func _exit_tree() -> void:
	remove_scene_post_import_plugin(_import)
	_import = null
