extends Node3D

@onready var status_label:     Label           = $CanvasLayer/StatusLabel
@onready var camera:           CameraController = $Camera3D
@onready var entity_manager:   Node            = $EntityManager
@onready var player_controller: Node           = $PlayerController
@onready var targeting:        Node            = $Targeting
@onready var login_ui:         CanvasLayer     = $LoginUI

func _ready() -> void:
	Network.connected.connect(_on_connected)
	Network.disconnected.connect(_on_disconnected)
	Network.login_ok.connect(_on_login_ok)
	Network.login_fail.connect(_on_login_fail)

	login_ui.login_pressed.connect(_on_login_pressed)
	camera.first_person_changed.connect(entity_manager.set_first_person)
	entity_manager.player_moved.connect(camera.follow)


func _on_login_pressed(username: String, password: String) -> void:
	var user_bytes := username.to_utf8_buffer()
	var pass_bytes := password.to_utf8_buffer()
	var pkt := PackedByteArray()
	pkt.append(0x05)
	pkt.append(user_bytes.size())
	pkt.append_array(user_bytes)
	pkt.append(pass_bytes.size())
	pkt.append_array(pass_bytes)
	Network.send(pkt)

func _on_connected() -> void:
	status_label.text = "Connected"
	login_ui.visible = true

func _on_disconnected() -> void:
	status_label.text = "Disconnected"
	login_ui.visible = false
	_set_player_id(-1)

func _on_login_ok(net_id: int) -> void:
	login_ui.visible = false
	login_ui.clear_error()
	_set_player_id(net_id)

func _on_login_fail() -> void:
	login_ui.show_error("Invalid credentials")

func _set_player_id(net_id: int) -> void:
	entity_manager.player_net_id   = net_id
	player_controller.player_net_id = net_id
	targeting.player_net_id        = net_id
