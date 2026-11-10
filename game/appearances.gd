extends Node
## Player characters' looks (race, skin colour) by character id, kept in
## user://appearances.cfg across sessions. A player unit in view names its
## character (PlayerCharacter); the server is asked (AppearanceRequest) only
## about characters this file doesn't have yet. Race and skin are fixed at
## creation and character ids are never reused, so an entry never goes stale.

## A player unit's look, once both it and its character's look are known.
signal appearance_known(net_id: int, race: int, color: Color)

const _PATH := "user://appearances.cfg"

var _file := ConfigFile.new()     # [<char_id>] race=int skin=Color
var _chars: Dictionary = {}       # net_id -> char_id, player units in view
var _requested: Dictionary = {}   # char_id -> true, asked this connection, no answer yet
var _save_queued := false


func _ready() -> void:
	_file.load(_PATH)   # missing on first run: starts empty
	Network.player_character_synced.connect(_on_player_character)
	Network.appearance_received.connect(_on_appearance)
	Network.character_list.connect(_on_character_list)
	Network.unit_destroyed.connect(func(net_id: int) -> void: _chars.erase(net_id))
	Network.disconnected.connect(func() -> void:
		_chars.clear()
		_requested.clear())
	# Left the world (death, logout) or entered it: the server only answers
	# peers in the world, so anything still asked goes unanswered — ask again.
	GameState.player_id_changed.connect(func(_id: int) -> void: _requested.clear())


func _on_player_character(net_id: int, char_id: int) -> void:
	_chars[net_id] = char_id
	var key := str(char_id)
	if _file.has_section(key):
		appearance_known.emit(net_id, _file.get_value(key, "race"), _file.get_value(key, "skin"))
	elif not _requested.has(char_id):
		_requested[char_id] = true
		Network.send(Protocol.pkt_appearance_request(char_id))


func _on_appearance(char_id: int, race: int, color: Color) -> void:
	_requested.erase(char_id)
	_store(char_id, race, color)
	for net_id: int in _chars:
		if _chars[net_id] == char_id:
			appearance_known.emit(net_id, race, color)


# Our own characters come with their looks — no need to ask about them later.
func _on_character_list(ok: bool, characters: Array) -> void:
	if not ok:
		return
	for c: Dictionary in characters:
		_store(c["id"], c["race"], Color.hex(c["skin_color"]))


func _store(char_id: int, race: int, color: Color) -> void:
	var key := str(char_id)
	_file.set_value(key, "race", race)
	_file.set_value(key, "skin", color)
	# One write for a burst of answers (a crowd coming into view).
	if not _save_queued:
		_save_queued = true
		_save.call_deferred()


func _save() -> void:
	_save_queued = false
	var err := _file.save(_PATH)
	if err != OK:
		push_warning("Appearances: couldn't save %s (%s)" % [_PATH, error_string(err)])
