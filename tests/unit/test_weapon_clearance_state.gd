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

	var tucked_pose := int(WeaponClearanceState.Pose.get("TUCKED", -1))
	if tucked_pose < 0:
		_append(failures, Assertions.expect_true(
			false,
			"Clearance state exposes a tucked pose for fully blocked turns"
		))
		state.reset()
		return failures

	state.configure(WeaponClearanceState.Pose.NORMAL)
	var tucked_request := int(state.call("request_pose", 0.016, false, false))
	_append(failures, Assertions.expect_equal(
		tucked_request,
		tucked_pose,
		"Blocked normal and raised poses request tucked without mutating committed pose"
	))
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.NORMAL,
		"Tucked request stays separate from the committed normal pose"
	))
	state.call("commit_pose", tucked_request)
	_append(failures, Assertions.expect_equal(
		int(state.call("request_pose", 0.016, true, false)),
		tucked_pose,
		"Tucked pose stays committed until raised clearance is available"
	))
	var raised_request := int(state.call("request_pose", 0.016, true, true))
	_append(failures, Assertions.expect_equal(
		raised_request,
		WeaponClearanceState.Pose.RAISED,
		"Tucked pose restores to raised before starting normal restore timing"
	))
	state.call("commit_pose", raised_request)
	_append(failures, Assertions.expect_equal(
		int(state.call("request_pose", 0.10, true, true)),
		WeaponClearanceState.Pose.RAISED,
		"Restored raised pose waits for the full normal restore delay"
	))
	_append(failures, Assertions.expect_equal(
		int(state.call("request_pose", 0.05, true, true)),
		WeaponClearanceState.Pose.NORMAL,
		"Restored raised pose requests normal after 0.15 seconds of clearance"
	))

	state.configure(WeaponClearanceState.Pose.RAISED)
	_append(failures, Assertions.expect_equal(
		int(state.call("request_pose", 0.016, true, false)),
		tucked_pose,
		"Raised pose requests tucked when its committed volume becomes blocked"
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
