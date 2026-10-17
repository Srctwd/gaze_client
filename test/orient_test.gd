extends Node3D

# Debug scene for the UnitPos orientation byte: no server needed. Feeds raw
# UnitPos packets straight into Network._parse so the real decode path and
# EntityManager easing are exercised, with a player model slowly spinning in
# place. The orange arrow shows the exact (continuous) yaw; the body shows
# what other clients actually see after rounding to 32 steps.
# Run: Godot --path ~/gaze_client res://test/orient_test.tscn

const _TEST_NET_ID := 900001
const _SPIN_SPEED := 0.4      # rad/s — one 11.25° step roughly every 0.5s
const _SEND_INTERVAL := 0.05  # 20 Hz, roughly a server tick
const _PITCH_CYCLE := 4.0     # seconds per pitch sweep (spine tilt via PitchTilt)

var _yaw := 0.0
var _elapsed := 0.0
var _send_timer := 0.0
var _arrow: Node3D
var _label: Label

func _ready() -> void:
	# The Network autoload connects to the live server on startup; stop it
	# servicing so real SpawnUnit/UnitPos packets don't add units here.
	Network.set_process(false)

	var camera := Camera3D.new()
	camera.name = "Camera3D"
	add_child(camera)
	camera.position = Vector3(0.0, 4.0, 6.0)
	camera.look_at(Vector3(0.0, 1.0, 0.0))

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.9, 0.6, 0.0)
	add_child(light)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20.0, 20.0)
	ground.mesh = plane
	add_child(ground)

	var entity_manager := Node.new()
	entity_manager.name = "EntityManager"
	entity_manager.set_script(load("res://game/entity_manager.gd"))
	add_child(entity_manager)

	_arrow = Node3D.new()
	var arrow_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.08, 0.08, 1.6)
	arrow_mesh.mesh = box
	arrow_mesh.position = Vector3(0.0, 0.0, 0.8)  # models face +Z after the +PI yaw convention
	var arrow_material := StandardMaterial3D.new()
	arrow_material.albedo_color = Color(1.0, 0.5, 0.0)
	arrow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow_mesh.material_override = arrow_material
	_arrow.add_child(arrow_mesh)
	_arrow.position = Vector3(0.0, 2.3, 0.0)
	add_child(_arrow)

	var canvas := CanvasLayer.new()
	add_child(canvas)
	_label = Label.new()
	_label.position = Vector2(16.0, 16.0)
	_label.add_theme_font_size_override("font_size", 22)
	canvas.add_child(_label)

func _process(delta: float) -> void:
	_elapsed += delta
	_yaw = fposmod(_yaw + _SPIN_SPEED * delta, TAU)
	var pitch := sin(_elapsed * TAU / _PITCH_CYCLE) * 1.2
	# Server yaw convention: the client adds PI on receipt, so the arrow does too.
	_arrow.rotation.y = _yaw + PI

	_send_timer -= delta
	if _send_timer > 0.0:
		return
	_send_timer = _SEND_INTERVAL
	var orient := _pack_orient(_yaw, pitch)
	Network._parse(_build_unit_pos(orient))
	var decoded := Protocol.unpack_orient(orient)
	_label.text = "exact yaw %.3f  pitch %+.2f\nbyte 0x%02X -> yaw idx %d (%.3f)  pitch %+.2f" % [_yaw, pitch, orient, orient & 0x1F, decoded.x, decoded.y]

func _build_unit_pos(orient: int) -> PackedByteArray:
	var packet := PackedByteArray()
	packet.resize(21)
	packet[0] = Protocol.UNIT_POS
	packet.encode_u32(1, _TEST_NET_ID)
	packet[5] = Protocol.UNIT_PLAYER
	packet[6] = 0
	packet.encode_float(7, 0.0)
	packet.encode_float(11, 0.5)
	packet.encode_float(15, 0.0)
	packet[19] = orient
	packet[20] = Protocol.ANIM_GROUND
	return packet

# Mirror of pack_orient in stone_gaze/src/network/protocol.h.
func _pack_orient(yaw: float, pitch: float) -> int:
	var yaw_index := int(round(fposmod(yaw, TAU) / TAU * Protocol.ORIENT_YAW_STEPS)) % Protocol.ORIENT_YAW_STEPS
	var pitch_index := 0
	var best_distance := absf(pitch - Protocol.ORIENT_PITCH_LEVELS[0])
	for level_index in range(1, Protocol.ORIENT_PITCH_LEVELS.size()):
		var distance := absf(pitch - Protocol.ORIENT_PITCH_LEVELS[level_index])
		if distance < best_distance:
			best_distance = distance
			pitch_index = level_index
	return (pitch_index << 5) | yaw_index
