@tool
extends EditorScenePostImportPlugin
## Every imported model (.glb, .gltf, .fbx, .obj) comes out PS2-ready, so
## nothing converts it at runtime:
##   - each surface's material becomes its PS2 model material
##     (ps2_materials.gd; unshaded/billboard ones stay as they are),
##   - each mesh goes through the PS2 geometry path (ps2_mesh.gd): 2-bone
##     skinning, quantised attributes, strip order.
## Look is still authored in Blender / the import dock as usual (albedo,
## colour, transparency, cull, emission, metallic/roughness → sphere-map
## shine); changing the conversion needs a reimport.

const Ps2Materials := preload("res://ps2/ps2_materials.gd")
const Ps2Mesh      := preload("res://ps2/ps2_mesh.gd")


func _post_process(scene: Node) -> void:
	var converted := {}   # source material -> PS2 material, shared like the source
	var built := {}       # source mesh -> PS2 mesh
	for n in [scene] + scene.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var src := mi.mesh
		if not built.has(src):
			built[src] = _build(src, converted)
		mi.mesh = built[src]
		for i in mi.get_surface_override_material_count():
			mi.set_surface_override_material(i, _material(mi.get_surface_override_material(i), converted))
		mi.material_override = _material(mi.material_override, converted)


func _material(m: Material, converted: Dictionary) -> Material:
	if not m is BaseMaterial3D:
		return m
	if not converted.has(m):
		var c := Ps2Materials.model(m)
		converted[m] = c if c != null else m
	return converted[m]


func _build(src: Mesh, converted: Dictionary) -> Mesh:
	for s in src.get_surface_count():
		src.surface_set_material(s, _material(src.surface_get_material(s), converted))
	var out := Ps2Mesh.convert(src)
	if out == null:
		push_warning("ps2_import: %s kept as is (not a triangle mesh)" % src.resource_name)
		return src
	out.resource_name = src.resource_name
	# Runtime bookkeeping only; ps2_source would save the original mesh too.
	for key in out.get_meta_list():
		out.remove_meta(key)
	return out
