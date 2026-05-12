extends DirectionalLight3D

@onready var moon: DirectionalLight3D  = $"../MoonLight3D"
@onready var _moon_mesh: MeshInstance3D = $"../Moon"

var _sync_game_time: float = 0.0
var _sync_real_time: float = 0.0

const GAME_SPEED: float  = 12.0
const DAY: float         = 86400.0
const LUNAR_CYCLE: float = 2600000.0   # 2.5 real days at 12× speed (10 at 3×)
const SKY_DIST: float    = 800.0

func _ready() -> void:
	Network.time_of_day.connect(_on_time_of_day)
	shadow_opacity = 0.4
	moon.shadow_opacity = 0.3

func _on_time_of_day(secs: float) -> void:
	_sync_game_time = secs
	_sync_real_time = Time.get_unix_time_from_system()

func _total_seconds() -> float:
	var elapsed: float = Time.get_unix_time_from_system() - _sync_real_time
	return _sync_game_time + elapsed * GAME_SPEED

func _process(_delta: float) -> void:
	var t := _total_seconds()
	_apply_sun(t)
	_apply_moon(t)

func _apply_sun(total_seconds: float) -> void:
	var angle: float = (fmod(total_seconds, DAY) - 21600.0) / DAY * TAU
	var sun_dir := Vector3(cos(angle), sin(angle), 0.0)

	basis = Basis.looking_at(-sun_dir, Vector3(0, 0, 1))

	var t: float = clamp(sun_dir.y, 0.0, 1.0)
	light_energy = t * 1.2
	light_color  = Color(1.0, 0.45 + 0.55 * t, 0.1 + 0.9 * t)

func _apply_moon(total_seconds: float) -> void:
	var day_frac: float   = fmod(total_seconds, DAY) / DAY
	var lunar_frac: float = total_seconds / LUNAR_CYCLE

	var angle: float = (fmod(day_frac + lunar_frac, 1.0) - 0.25) * TAU
	var incl: float  = sin(lunar_frac * TAU) * 0.087  # ~5° orbital inclination
	var moon_dir     := Vector3(cos(angle), sin(angle), incl).normalized()

	moon.basis = Basis.looking_at(-moon_dir, Vector3(0, 0, 1))

	var phase: float = max(0.15, (1.0 - cos(lunar_frac * TAU)) * 0.5)
	moon.light_energy = clamp(moon_dir.y, 0.0, 1.0) * phase * 0.3
	moon.light_color  = Color(0.7, 0.8, 1.0)

	_moon_mesh.position = moon_dir * SKY_DIST
