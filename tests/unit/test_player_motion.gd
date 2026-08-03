extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var player_motion := load("res://scripts/player/player_motion.gd") as Script
	_append(failures, Assertions.expect_true(
		player_motion != null,
		"PlayerMotion script loads"
	))
	if player_motion == null:
		return failures

	var camera_basis := Basis(Vector3.UP, deg_to_rad(45.0))
	var expected_forward := -camera_basis.z
	expected_forward.y = 0.0
	expected_forward = expected_forward.normalized()

	_append(failures, Assertions.expect_vector3_near(
		player_motion.world_direction(Vector2(0.0, -1.0), camera_basis),
		expected_forward,
		0.0001,
		"Forward input follows camera forward"
	))
	_append(failures, Assertions.expect_float_near(
		player_motion.world_direction(Vector2(1.0, -1.0), camera_basis).length(),
		1.0,
		0.0001,
		"Diagonal movement is normalized"
	))
	_append(failures, Assertions.expect_float_near(
		player_motion.next_vertical_velocity(0.0, true, true, 0.016, 24.0, 8.5),
		8.5,
		0.0001,
		"Grounded jump applies jump speed"
	))
	_append(failures, Assertions.expect_float_near(
		player_motion.next_vertical_velocity(2.0, false, true, 0.5, 24.0, 8.5),
		-10.0,
		0.0001,
		"Airborne jump input does not bypass gravity"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
