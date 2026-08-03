extends Node

signal player_id_changed(net_id: int)
signal first_person_changed(enabled: bool)
signal aim_enabled_changed(enabled: bool)

var player_net_id: int = -1:
	set(value):
		player_net_id = value
		player_id_changed.emit(value)

var first_person: bool = true:
	set(value):
		first_person = value
		first_person_changed.emit(value)

var aim_enabled: bool = false:
	set(value):
		aim_enabled = value
		aim_enabled_changed.emit(value)

# How fast remote entities (and the local player's camera) ease toward their
# latest server position — see entity_manager.gd's _process(). Higher = snappier
# but more tick-jitter visible; lower = smoother but trails the server more.
var interp_rate: float = 24.0
