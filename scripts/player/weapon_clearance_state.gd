extends RefCounted
class_name WeaponClearanceState

enum Pose {
	DISABLED,
	NORMAL,
	RAISED,
}

var pose := Pose.DISABLED
var restore_delay: float
var restore_elapsed := 0.0
var fire_release_required := false

func _init(value_restore_delay := 0.15) -> void:
	restore_delay = maxf(value_restore_delay, 0.0)

func configure(enabled: bool, normal_clear: bool, raised_clear: bool) -> void:
	reset()
	if not enabled:
		return
	if normal_clear:
		pose = Pose.NORMAL
	elif raised_clear:
		_enter_raised()
	else:
		pose = Pose.NORMAL

func update(delta: float, normal_clear: bool, raised_clear: bool) -> bool:
	var previous_pose := pose
	match pose:
		Pose.NORMAL:
			if not normal_clear and raised_clear:
				_enter_raised()
		Pose.RAISED:
			if normal_clear:
				restore_elapsed += maxf(delta, 0.0)
				if restore_elapsed >= restore_delay:
					pose = Pose.NORMAL
					restore_elapsed = 0.0
			else:
				restore_elapsed = 0.0
	return pose != previous_pose

func observe_trigger(trigger_pressed: bool) -> void:
	if not trigger_pressed:
		fire_release_required = false

func can_fire(visual_settled: bool) -> bool:
	return (
		pose == Pose.NORMAL and
		visual_settled and
		not fire_release_required
	)

func reset() -> void:
	pose = Pose.DISABLED
	restore_elapsed = 0.0
	fire_release_required = false

func _enter_raised() -> void:
	pose = Pose.RAISED
	restore_elapsed = 0.0
	fire_release_required = true
