extends Node

signal player_id_changed(net_id: int)
signal first_person_changed(enabled: bool)

var player_net_id: int = -1:
	set(value):
		player_net_id = value
		player_id_changed.emit(value)

var first_person: bool = true:
	set(value):
		first_person = value
		first_person_changed.emit(value)
