class_name PitchTilt
extends SkeletonModifier3D

# Bends a humanoid spine (chest → neck → head) to show a unit's look pitch
# from UnitPos's orientation byte. Runs as a SkeletonModifier3D so it layers
# on top of whatever the AnimationPlayer posed this frame instead of fighting
# it. Eases toward target_pitch itself so the 7 discrete pitch levels don't
# visibly snap. Only for OTHER units — the local FP camera rides the Head
# bone, so tilting your own spine would move your eye.

# Fraction of the total pitch each bone takes — spread out so the bend reads
# as a whole upper body looking up/down rather than a broken neck. Sums to
# 0.5, so the body only shows ~50% of the real pitch (max ~29° at ±1.0 rad);
# the full amount looked exaggerated.
const _BONE_SHARES := {"chest": 0.2, "neck": 0.1, "head": 0.2}
const _EASE_RATE := 10.0
# Model faces +Z, and a positive rotation about +X tips +Z downward, so a
# positive (upward) pitch needs the negative angle.
const _PITCH_SIGN := -1.0

var target_pitch := 0.0
var _current_pitch := 0.0
var _bone_indices: Dictionary = {}  # bone name -> index in the skeleton

static func has_spine(skeleton: Skeleton3D) -> bool:
	for bone_name: String in _BONE_SHARES:
		if skeleton.find_bone(bone_name) == -1:
			return false
	return true

func _ready() -> void:
	var skeleton := get_skeleton()
	for bone_name: String in _BONE_SHARES:
		_bone_indices[bone_name] = skeleton.find_bone(bone_name)

func _process_modification_with_delta(delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	_current_pitch = lerpf(_current_pitch, target_pitch, 1.0 - exp(-_EASE_RATE * delta))
	for bone_name: String in _BONE_SHARES:
		var bone_index: int = _bone_indices[bone_name]
		var bend := Quaternion(Vector3.RIGHT, _current_pitch * _PITCH_SIGN * _BONE_SHARES[bone_name])
		skeleton.set_bone_pose_rotation(bone_index, skeleton.get_bone_pose_rotation(bone_index) * bend)
