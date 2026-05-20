extends Node3D

@onready var camera:            CameraController = $Camera3D
@onready var entity_manager:    Node             = $EntityManager
@onready var player_controller: Node             = $PlayerController
@onready var targeting:         Node             = $Targeting
@onready var login_ui: CanvasLayer = $LoginUI
@onready var _terrain: Node3D      = $Terrain

var _http:        HTTPRequest
var _token:       String = ""
var character_ui: CanvasLayer
var _black_bg:     CanvasLayer
var equipment:     Node

func _ready() -> void:
	character_ui = preload("res://ui/character_ui.gd").new()
	add_child(character_ui)

	add_child(preload("res://game/effects.gd").new())

	var floor_items := preload("res://game/floor_items.gd").new()
	add_child(floor_items)
	equipment = preload("res://game/equipment.gd").new()
	add_child(equipment)
	player_controller.set("floor_items", floor_items)

	_black_bg = CanvasLayer.new()
	_black_bg.layer = -1
	var rect := ColorRect.new()
	rect.color = Color(0, 0, 0, 1)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_black_bg.add_child(rect)
	add_child(_black_bg)
	_black_bg.visible = false

	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_login_response)

	Network.connected.connect(_on_connected)
	Network.disconnected.connect(_on_disconnected)
	Network.login_ok.connect(_on_login_ok)
	Network.login_fail.connect(_on_login_fail)
	Network.unit_destroyed.connect(_on_unit_destroyed)
	Network.vital_update.connect(_on_vital_update)

	login_ui.login_pressed.connect(_on_login_pressed)
	character_ui.character_confirmed.connect(_on_character_confirmed)
	entity_manager.player_moved.connect(camera.follow)
	entity_manager.player_moved.connect(_on_player_moved)


func _on_login_pressed(email: String, passkey: String) -> void:
	var body := JSON.stringify({"email": email, "passkey": passkey})
	_http.request(Config.WEBSERVER + "/api/login",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST, body)


func _on_login_response(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		login_ui.show_error("Invalid credentials")
		return
	var json: Variant = JSON.parse_string(body.get_string_from_utf8())
	if json == null or not json.has("token"):
		login_ui.show_error("Auth error")
		return
	_token = json["token"]
	login_ui.visible = false
	_black_bg.visible = true
	character_ui.show_for_token(_token)


func _on_character_confirmed(char_id: int) -> void:
	Network.send(Protocol.pkt_login(_token, char_id))


func _on_connected() -> void:
	_black_bg.visible = true
	login_ui.visible = true

func _on_disconnected() -> void:
	login_ui.visible = false
	character_ui.visible = false
	_black_bg.visible = false
	GameState.player_net_id = -1

func _on_login_ok(net_id: int) -> void:
	login_ui.clear_error()
	_black_bg.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	GameState.player_net_id = net_id
	camera.show_hud()


func _on_vital_update(net_id: int, hp: float, max_hp: float, mana: float, max_mana: float) -> void:
	if net_id != GameState.player_net_id:
		return
	camera.set_health(hp / max_hp if max_hp > 0 else 0.0, max_hp)
	camera.set_mana(mana / max_mana if max_mana > 0 else 0.0, max_mana)


func _on_unit_destroyed(net_id: int) -> void:
	if net_id != GameState.player_net_id:
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	GameState.player_net_id = -1
	camera.hide_hud()
	var rect := _black_bg.get_child(0) as ColorRect
	rect.modulate.a = 0.0
	_black_bg.visible = true
	var tween := create_tween()
	tween.tween_property(rect, "modulate:a", 1.0, 1.5).set_ease(Tween.EASE_IN)
	tween.tween_callback(func(): character_ui.show_for_token(_token))

func _on_login_fail() -> void:
	login_ui.visible = true
	login_ui.show_error("Invalid credentials")

func _on_player_moved(_pos: Vector3) -> void:
	camera.set_underwater(_terrain.is_in_water(camera.global_position))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F12:
			var mode := DisplayServer.window_get_mode()
			if mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			else:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
