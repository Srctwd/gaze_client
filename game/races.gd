class_name Races
## The playable races: what the client shows of them (name, display stats,
## body model). Shared by the create screen, the character list and the bodies
## entity_manager.gd builds.

# Playable races, by races.json id (stone_gaze) — the ids the server uses. Stats copied from races.json for display only; the
# server applies the real ones.
const ALL := [
	{ "name": "Human",     "hp": 10.0, "hp_multi": 1.0, "mana": 10.0, "mana_multi": 1.0, "swim": 0.40, "climb": 0.3,
	  "model": "res://assets/monsters/Human2.tscn",
	  "blurb": "Even-handed in body and mind." },
	{ "name": "Homunculi", "hp": 5.0,  "hp_multi": 0.8, "mana": 15.0, "mana_multi": 1.2, "swim": 0.45, "climb": 0.25,
	  "model": "res://assets/monsters/Homunculus.tscn",
	  "blurb": "Frail, but brimming with mana." },
	{ "name": "Elf",       "hp": 7.5,  "hp_multi": 0.9, "mana": 12.5, "mana_multi": 1.1, "swim": 0.50, "climb": 0.3,
	  "blurb": "Leans toward magic, swims well." },
	{ "name": "Orc",       "hp": 12.5, "hp_multi": 1.1, "mana": 7.5,  "mana_multi": 0.9, "swim": 0.35, "climb": 0.3,
	  "blurb": "Tough, with little patience for spells." },
	{ "name": "Ogre",      "hp": 15.0, "hp_multi": 1.2, "mana": 15.0, "mana_multi": 1.2, "swim": 0.30, "climb": 0.4,
	  "blurb": "Huge and strong; sinks like a stone." },
	{ "name": "Naga",      "hp": 12.5, "hp_multi": 1.1, "mana": 15.0, "mana_multi": 1.2, "swim": 0.90, "climb": 0.25,
	  "blurb": "At home in the water, clumsy on ledges." },
]
# Body for races without a "model" of their own yet, and for unknown ids.
const _DEFAULT_MODEL := "res://assets/monsters/Human2.tscn"


static func model(race: int) -> PackedScene:
	var path: String = _DEFAULT_MODEL
	if race >= 0 and race < ALL.size():
		path = ALL[race].get("model", _DEFAULT_MODEL)
	return load(path)
