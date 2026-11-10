class_name SkinTint
extends RefCounted
## A body's skin colour: every surface of the meshes under `root` gets its
## own copy of its PS2 model material (the originals are shared with every
## other body of that model) and set_color tints them. See-through skin
## (alpha < 1) shows only the body's nearest surface: depth_only.gdshader
## lays down the body's depth first, then a blended copy of the tint draws on
## top.
##
## Build it before anything is attached to the body (held items, armour):
## only the meshes under `root` at that point are tinted.

const _DEPTH_ONLY := preload("res://game/depth_only.gdshader")
const Ps2Materials := preload("res://ps2/ps2_materials.gd")

# {mi, surface, tinted (opaque), blended (see-through), depth}
var _surfaces: Array[Dictionary] = []


func _init(root: Node) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(i)
			if not Ps2Materials.is_model(mat):
				continue
			var tinted := mat.duplicate() as ShaderMaterial
			tinted.render_priority = 1
			var blended := Ps2Materials.blended(tinted)
			var depth := ShaderMaterial.new()
			depth.shader = _DEPTH_ONLY
			depth.next_pass = blended
			_surfaces.append({ "mi": mi, "surface": i, "tinted": tinted, "blended": blended, "depth": depth })


func set_color(c: Color) -> void:
	var see_through := c.a < 1.0
	for surf in _surfaces:
		Ps2Materials.set_color(surf["tinted"], c)
		Ps2Materials.set_color(surf["blended"], c)
		(surf["mi"] as MeshInstance3D).set_surface_override_material(surf["surface"],
				surf["depth"] if see_through else surf["tinted"])
