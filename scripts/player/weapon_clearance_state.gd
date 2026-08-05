extends RefCounted
class_name WeaponClearanceState

enum Pose { DISABLED, NORMAL, RAISED, TUCKED }

var pose := Pose.DISABLED
var restore_delay: float
var restore_elapsed := 0.0

func _init(value_restore_delay := 0.15) -> void:
	restore_delay = maxf(value_restore_delay, 0.0)

func configure(initial_pose: int) -> void:
	pose = initial_pose
	restore_elapsed = 0.0

func request_pose(
	delta: float,
	normal_clear: bool,
	raised_clear := true
) -> int:
	if pose == Pose.DISABLED:
		return Pose.DISABLED
	if pose == Pose.NORMAL:
		restore_elapsed = 0.0
		if normal_clear:
			return Pose.NORMAL
		return Pose.RAISED if raised_clear else Pose.TUCKED
	if pose == Pose.TUCKED:
		restore_elapsed = 0.0
		return Pose.RAISED if raised_clear else Pose.TUCKED
	if not raised_clear:
		restore_elapsed = 0.0
		return Pose.TUCKED
	if not normal_clear:
		restore_elapsed = 0.0
		return Pose.RAISED
	restore_elapsed += maxf(delta, 0.0)
	return Pose.NORMAL if restore_elapsed >= restore_delay else Pose.RAISED

func commit_pose(requested_pose: int) -> bool:
	var changed := pose != requested_pose
	pose = requested_pose
	if changed:
		restore_elapsed = 0.0
	return changed

func reset() -> void:
	pose = Pose.DISABLED
	restore_elapsed = 0.0
