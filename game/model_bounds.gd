class_name ModelBounds
## Bounds of a model's meshes in its own space (its root's transform left
## out), in the rest pose. Works before the model is in the tree.


static func rest_aabb(model: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		var box := _mesh_transform(model, mi) * mi.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out


# A skinned mesh is drawn through its skin, in its skeleton's space: its own
# node transform plays no part (homunculi.glb's sits under an Armature raised
# 1.33 while the body is drawn from the ground up). At rest every bind maps the
# mesh to the same place, so the first one stands for all.
static func _mesh_transform(model: Node3D, mi: MeshInstance3D) -> Transform3D:
	var leaf: Node3D = mi
	var xf := mi.transform
	var skel := mi.get_node_or_null(mi.skeleton) as Skeleton3D
	if mi.skin != null and mi.skin.get_bind_count() > 0 and skel != null:
		var bone := mi.skin.get_bind_bone(0)
		if bone < 0:
			bone = skel.find_bone(mi.skin.get_bind_name(0))
		leaf = skel
		xf = skel.transform * skel.get_bone_global_rest(bone) * mi.skin.get_bind_pose(0)
	var p := leaf.get_parent()
	while p != null and p != model:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf
