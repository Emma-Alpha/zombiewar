extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const WeaponSpreadState = preload(
	"res://scripts/combat/weapons/weapon_spread_state.gd"
)

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_direction_and_single_shot_growth(failures)
	_test_maximum_and_recovery(failures)
	_test_reset(failures)
	_test_invalid_inputs_are_clamped(failures)
	return failures

func _test_direction_and_single_shot_growth(failures: Array[String]) -> void:
	var spread := WeaponSpreadState.new(0.5, 2.0, 0.75, 1.0)
	var centered := spread.resolve_shot_direction(Vector3.FORWARD, 0.0)
	_append(failures, Assertions.expect_vector3_near(
		centered,
		Vector3.FORWARD,
		0.0001,
		"Zero spread sample keeps the base direction"
	))
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		1.25,
		0.0001,
		"A resolved shot grows the next-shot spread"
	))

	spread.reset()
	var negative_edge := spread.resolve_shot_direction(Vector3.FORWARD, -1.0)
	spread.reset()
	var positive_edge := spread.resolve_shot_direction(Vector3.FORWARD, 1.0)
	_append(failures, Assertions.expect_float_near(
		Vector3.FORWARD.angle_to(negative_edge),
		deg_to_rad(0.5),
		0.0001,
		"Negative edge uses the full current spread angle"
	))
	_append(failures, Assertions.expect_float_near(
		Vector3.FORWARD.angle_to(positive_edge),
		deg_to_rad(0.5),
		0.0001,
		"Positive edge uses the full current spread angle"
	))
	_append(failures, Assertions.expect_true(
		negative_edge.x * positive_edge.x < 0.0 and
			is_equal_approx(negative_edge.y, 0.0) and
			is_equal_approx(positive_edge.y, 0.0),
		"Spread edges stay horizontal and land on opposite sides"
	))

func _test_maximum_and_recovery(failures: Array[String]) -> void:
	var spread := WeaponSpreadState.new(0.5, 2.0, 0.75, 1.0)
	for _shot_index in range(8):
		spread.resolve_shot_direction(Vector3.FORWARD, 0.0)
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		2.0,
		0.0001,
		"Repeated shots clamp at maximum spread"
	))
	spread.tick(0.5)
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		1.5,
		0.0001,
		"Spread recovers by degrees per second"
	))
	spread.tick(10.0)
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		0.5,
		0.0001,
		"Spread recovery never drops below base spread"
	))

func _test_reset(failures: Array[String]) -> void:
	var spread := WeaponSpreadState.new(0.35, 3.0, 0.8, 1.8)
	spread.resolve_shot_direction(Vector3.RIGHT, 1.0)
	spread.resolve_shot_direction(Vector3.RIGHT, 1.0)
	spread.reset()
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		0.35,
		0.0001,
		"Reset restores base spread immediately"
	))

func _test_invalid_inputs_are_clamped(failures: Array[String]) -> void:
	var spread := WeaponSpreadState.new(-1.0, -2.0, -3.0, -4.0)
	var direction := spread.resolve_shot_direction(Vector3.RIGHT, 2.0)
	_append(failures, Assertions.expect_vector3_near(
		direction,
		Vector3.RIGHT,
		0.0001,
		"Invalid negative configuration resolves to zero spread"
	))
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		0.0,
		0.0001,
		"Negative configuration cannot corrupt state"
	))

	var bounded := WeaponSpreadState.new(1.0, 0.5, 1.0, 1.0)
	var clamped_edge := bounded.resolve_shot_direction(Vector3.FORWARD, 2.0)
	var spread_after_shot := bounded.current_spread_degrees
	bounded.tick(-10.0)
	_append(failures, Assertions.expect_float_near(
		Vector3.FORWARD.angle_to(clamped_edge),
		deg_to_rad(1.0),
		0.0001,
		"Random offset clamps to one and maximum clamps to base"
	))
	_append(failures, Assertions.expect_float_near(
		bounded.current_spread_degrees,
		spread_after_shot,
		0.0001,
		"Negative delta cannot recover or corrupt spread"
	))

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
