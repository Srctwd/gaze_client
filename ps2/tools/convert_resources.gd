extends SceneTree
## One-time migration: rewrites scenes whose own (embedded) materials are
## Godot StandardMaterial3Ds into PS2 materials (ps2_materials.gd), so nothing
## converts them at runtime. Imported models don't need this: the ps2_import
## addon converts them at import time.
##
##   godot --headless --path . -s res://ps2/tools/convert_resources.gd -- <scene.tscn>...
##
## Only materials the scene itself embeds are replaced; materials coming from
## an instanced model are left to that model's import. Unshaded/billboard
## mesh materials stay as they are (no PS2 form), particle draw materials are
## always converted. A particle texture's paletted copy (ps2_texture.gd) is
## saved beside it as <name>.ps2.res. The scene keeps its uid.

const Ps2Materials := preload("res://ps2/ps2_materials.gd")


func _init() -> void:
	var paths := OS.get_cmdline_user_args()
	var failed := false
	for path in paths:
		if not _convert_scene(path):
			failed = true
	quit(1 if failed else 0)


func _convert_scene(path: String) -> bool:
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("cannot load " + path)
		return false
	var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	var count := 0
	for n in [root] + root.find_children("*", "", true, false):
		if not _is_own(n, root):
			continue
		if n is GPUParticles3D or n is CPUParticles3D:
			count += _convert_particles(n as GeometryInstance3D)
		elif n is MeshInstance3D:
			count += _convert_mesh(n as MeshInstance3D, path)
	if count == 0:
		print("%s: nothing to convert" % path)
		root.free()
		return true
	var out := PackedScene.new()
	var err := out.pack(root)
	root.free()
	if err != OK:
		push_error("%s: pack failed (%d)" % [path, err])
		return false
	var uid := _scene_uid(path)
	err = ResourceSaver.save(out, path)
	if err != OK:
		push_error("%s: save failed (%d)" % [path, err])
		return false
	_restore_uid(path, uid)
	print("%s: %d material(s) converted" % [path, count])
	return true


# Nodes this scene file defines itself (not inside an instanced model).
func _is_own(n: Node, root: Node) -> bool:
	return n == root or n.owner == root


# The uid in the scene file's header, "" if none. A standalone script run has
# no uid cache, so ResourceSaver writes the header without it.
func _scene_uid(path: String) -> String:
	var head := FileAccess.get_file_as_string(path).get_slice("\n", 0)
	var at := head.find(" uid=\"")
	return "" if at < 0 else head.substr(at + 6, head.find("\"", at + 6) - at - 6)


func _restore_uid(path: String, uid: String) -> void:
	if uid.is_empty():
		return
	var text := FileAccess.get_file_as_string(path)
	var nl := text.find("\n")
	var head := text.substr(0, nl)
	if head.contains(" uid="):
		return
	head = head.trim_suffix("]") + " uid=\"%s\"]" % uid
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(head + text.substr(nl))


func _convert_particles(p: GeometryInstance3D) -> int:
	if p.material_override is BaseMaterial3D:
		p.material_override = _particle(p.material_override)
		return 1
	var mesh: Mesh = (p as GPUParticles3D).draw_pass_1 if p is GPUParticles3D else (p as CPUParticles3D).mesh
	if mesh != null and mesh.get_surface_count() > 0 and mesh.surface_get_material(0) is BaseMaterial3D:
		mesh.surface_set_material(0, _particle(mesh.surface_get_material(0)))
		return 1
	return 0


# Ps2Materials.particle, with its paletted texture saved as a file instead of
# embedded in the scene.
func _particle(m: BaseMaterial3D) -> ShaderMaterial:
	var mat := Ps2Materials.particle(m)
	var tex := mat.get_shader_parameter("albedo_tex") as Texture2D
	var src := m.albedo_texture
	if tex != null and src != null and not src.resource_path.is_empty():
		var out := "%s.%sps2.res" % [src.resource_path.get_basename(), "msdf." if m.albedo_texture_msdf else ""]
		for key in tex.get_meta_list():
			tex.remove_meta(key)
		if ResourceSaver.save(tex, out) == OK:
			mat.set_shader_parameter("albedo_tex", load(out))
		else:
			push_error("cannot save " + out)
	return mat


func _convert_mesh(mi: MeshInstance3D, scene_path: String) -> int:
	var count := 0
	if mi.material_override is BaseMaterial3D:
		var c := Ps2Materials.model(mi.material_override)
		if c != null:
			mi.material_override = c
			count += 1
	for i in mi.get_surface_override_material_count():
		var m := mi.get_surface_override_material(i)
		if m is BaseMaterial3D:
			var c := Ps2Materials.model(m)
			if c != null:
				mi.set_surface_override_material(i, c)
				count += 1
	# A mesh the scene embeds (a primitive) carries its own material.
	if mi.mesh != null and mi.mesh.resource_path.begins_with(scene_path + "::"):
		for i in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(i)
			if m is BaseMaterial3D:
				var c := Ps2Materials.model(m)
				if c != null:
					mi.mesh.surface_set_material(i, c)
					count += 1
	return count
