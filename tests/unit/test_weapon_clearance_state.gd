extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const WeaponClearanceState = preload(
	"res://scripts/player/weapon_clearance_state.gd"
)

func run() -> Array[String]:
	var failures: Array[String] = []
	var state := WeaponClearanceState.new(0.15)

	if not state.has_method("request_pose") or not state.has_method("commit_pose"):
		_append(failures, Assertions.expect_true(
			false,
			"Clearance state exposes separate request and commit APIs"
		))
		return failures
	state.call("configure", WeaponClearanceState.Pose.NORMAL)
	var requested := int(state.call("request_pose", 0.016, false))
	_append(failures, Assertions.expect_equal(
		requested,
		WeaponClearanceState.Pose.RAISED,
		"Blocked normal pose requests raised without mutating committed pose"
	))
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.NORMAL,
		"Requested pose stays separate from committed pose"
	))
	_append(failures, Assertions.expect_true(
		bool(state.call("commit_pose", requested)) and state.pose == WeaponClearanceState.Pose.RAISED,
		"Safe requested pose becomes the committed raised pose"
	))
	_append(failures, Assertions.expect_equal(
		int(state.call("request_pose", 0.14, true)),
		WeaponClearanceState.Pose.RAISED,
		"Raised pose waits for the full restore delay"
	))
	_append(failures, Assertions.expect_equal(
		int(state.call("request_pose", 0.016, true)),
		WeaponClearanceState.Pose.NORMAL,
		"Raised pose requests normal after 0.15 seconds of clearance"
	))
	state.reset()
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.DISABLED,
		"Reset disables clearance"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
