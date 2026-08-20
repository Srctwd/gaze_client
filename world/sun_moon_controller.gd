extends DirectionalLight3D

@onready var moon: DirectionalLight3D   = $"../MoonLight3D"
@onready var _moon_mesh: MeshInstance3D = $"../Moon"
@onready var _env: Environment          = $"../WorldEnvironment".environment

const GAME_SPEED: float  = 12.0
const DAY: float         = 86400.0
const LUNAR_CYCLE: float = 2600000.0   # 2.5 real days at 12× speed (10 at 3×)
const SKY_DIST: float    = 800.0

# Sun-driven curves, all keyed by `elevation` (0 = horizon/night, 1 = zenith/noon).
const SUN_ENERGY_MAX       : float = 0.2
const AMBIENT_ENERGY_DAY   : float = 0.3025
const AMBIENT_ENERGY_NIGHT : float = 0.121
const AMBIENT_COLOR_DAY    : Color = Color(0.6, 0.65, 0.8)
const AMBIENT_COLOR_NIGHT  : Color = Color(0.15, 0.18, 0.28)

var _sync_game_time: float = 0.0
var _sync_real_time: float = 0.0

func _ready() -> void:
	Network.time_of_day.connect(_on_time_of_day)

	# Full-opacity, wide-range shadow: caves must read as fully dark rather
	# than dim, and the shadow frustum needs to cover normal walking distance
	# or the shadowed/lit boundary visibly trails the camera as it moves.
	shadow_opacity = 1.0
	directional_shadow_max_distance = 500.0

	# The moon is purely decorative — a sphere drifting across the sky. It
	# emits no light, so it needs no shadow map either.
	moon.light_energy   = 0.0
	moon.shadow_enabled = false

func _on_time_of_day(secs: float) -> void:
	_sync_game_time = secs
	_sync_real_time = Time.get_unix_time_from_system()

func _total_seconds() -> float:
	var elapsed: float = Time.get_unix_time_from_system() - _sync_real_time
	return _sync_game_time + elapsed * GAME_SPEED

func _process(_delta: float) -> void:
	var total_seconds := _total_seconds()
	_apply_sun(total_seconds)
	_apply_moon(total_seconds)

func _apply_sun(total_seconds: float) -> void:
	var angle: float = (fmod(total_seconds, DAY) - 21600.0) / DAY * TAU
	var sun_dir := Vector3(cos(angle), sin(angle), 0.0)
	basis = Basis.looking_at(-sun_dir, Vector3(0, 0, 1))

	# smoothstep (not a hard clamp) so sunrise/sunset fade in/out instead of
	# popping the instant the sun crosses the horizon.
	var elevation: float = smoothstep(-0.05, 0.15, sun_dir.y)

	light_energy = elevation * SUN_ENERGY_MAX
	light_color  = Color(1.0, 0.45 + 0.55 * elevation, 0.1 + 0.9 * elevation)

	_env.ambient_light_energy = lerpf(AMBIENT_ENERGY_NIGHT, AMBIENT_ENERGY_DAY, elevation)
	_env.ambient_light_color  = AMBIENT_COLOR_NIGHT.lerp(AMBIENT_COLOR_DAY, elevation)

func _apply_moon(total_seconds: float) -> void:
	var day_frac: float   = fmod(total_seconds, DAY) / DAY
	var lunar_frac: float = total_seconds / LUNAR_CYCLE

	var angle: float = (fmod(day_frac + lunar_frac, 1.0) - 0.25) * TAU
	var incl: float  = sin(lunar_frac * TAU) * 0.087  # ~5° orbital inclination
	var moon_dir     := Vector3(cos(angle), sin(angle), incl).normalized()

	moon.basis = Basis.looking_at(-moon_dir, Vector3(0, 0, 1))
	_moon_mesh.position = moon_dir * SKY_DIST
