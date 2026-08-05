extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const WeaponClearanceState = preload(
	"res://scripts/player/weapon_clearance_state.gd"
)

func run() -> Array[String]:
	var failures: Array[String] = []
	var state := WeaponClearanceState.new(0.15)

	state.configure(true, true, true)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.NORMAL,
		"Clear firearm starts in the normal pose"
	))

	var changed := state.update(0.016, false, true)
	_append(failures, Assertions.expect_true(
		changed and state.pose == WeaponClearanceState.Pose.RAISED,
		"Blocked normal pose raises when raised space is clear"
	))
	_append(failures, Assertions.expect_true(
		not state.can_fire(true),
		"Raised pose blocks firing"
	))

	state.observe_trigger(true)
	state.update(0.14, true, true)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.RAISED,
		"Normal space must remain clear for the full restore delay"
	))
	state.update(0.016, false, true)
	state.update(0.01, true, true)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.RAISED,
		"A renewed collision resets the normal-clear restore delay"
	))
	state.update(0.14, true, true)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.NORMAL,
		"Normal pose restores after a new full clear delay"
	))
	_append(failures, Assertions.expect_true(
		not state.can_fire(true),
		"Held trigger remains latched after lowering"
	))
	state.observe_trigger(false)
	_append(failures, Assertions.expect_true(
		not state.can_fire(false),
		"Normal pose blocks firing until the visual lowering settles"
	))
	_append(failures, Assertions.expect_true(
		state.can_fire(true),
		"Trigger release unlocks firing after lowering settles"
	))

	state.update(0.016, false, false)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.NORMAL,
		"State keeps the last legal pose when neither target pose is clear"
	))
	state.configure(true, false, true)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.RAISED,
		"Blocked firearm equips directly into the raised pose"
	))
	_append(failures, Assertions.expect_true(
		not state.can_fire(true),
		"Directly raised firearm requires trigger release before firing"
	))
	state.reset()
	state.configure(true, true, true)
	_append(failures, Assertions.expect_true(
		state.can_fire(true),
		"Reset clears the fire-release latch before a normal reconfigure"
	))
	state.configure(true, false, true)
	state.configure(false, false, false)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.DISABLED,
		"Melee weapon disables firearm clearance"
	))
	state.configure(true, true, true)
	_append(failures, Assertions.expect_true(
		state.can_fire(true),
		"Disabling clearance clears the fire-release latch before re-equipping"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
