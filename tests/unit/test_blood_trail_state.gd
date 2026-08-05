extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const BloodTrailState = preload("res://scripts/fx/blood_trail_state.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var state := BloodTrailState.new()

	_append(failures, Assertions.expect_equal(
		state.advance(Vector3(1, 0, 0), 0.1, 6.0, 1.3).size(),
		0,
		"Normal movement cannot emit blood before a knockback trail starts"
	))

	state.start(Vector3.ZERO, 1.2)
	var long_frame := state.advance(Vector3(1.0, 0, 0), 0.1, 5.0, 1.3)
	_append(failures, Assertions.expect_equal(
		long_frame.size(),
		2,
		"A one-meter low-frame-rate move fills every 0.36-meter sample"
	))
	if long_frame.size() == 2:
		_append(failures, Assertions.expect_vector3_near(
			long_frame[0]["position"], Vector3(0.36, 0, 0), 0.0001,
			"First interpolated trail point uses the fixed spacing"
		))
		_append(failures, Assertions.expect_vector3_near(
			long_frame[1]["position"], Vector3(0.72, 0, 0), 0.0001,
			"Second interpolated trail point stays ordered on the real segment"
		))
		_append(failures, Assertions.expect_vector3_near(
			long_frame[0]["direction"], Vector3.RIGHT, 0.0001,
			"Trail direction follows real displacement"
		))
		_append(failures, Assertions.expect_float_near(
			float(long_frame[0]["intensity"]), 1.2, 0.0001,
			"Trail samples preserve the hit intensity"
		))

	var accumulated := BloodTrailState.new()
	accumulated.start(Vector3.ZERO, 1.0)
	_append(failures, Assertions.expect_equal(
		accumulated.advance(Vector3(0.2, 0, 0), 0.05, 4.0, 1.3).size(), 0,
		"Sub-spacing movement waits for more distance"
	))
	var carried := accumulated.advance(Vector3(0.4, 0, 0), 0.05, 4.0, 1.3)
	_append(failures, Assertions.expect_equal(
		carried.size(), 1,
		"Distance carries across physics frames"
	))
	if carried.size() == 1:
		_append(failures, Assertions.expect_vector3_near(
			carried[0]["position"], Vector3(0.36, 0, 0), 0.0001,
			"Carried distance interpolates on the current segment"
		))

	var capped := BloodTrailState.new()
	capped.start(Vector3.ZERO, 1.0)
	var capped_points := capped.advance(Vector3(10, 0, 0), 0.1, 8.0, 1.3)
	_append(failures, Assertions.expect_equal(
		capped_points.size(), 8,
		"One knockback session cannot emit more than eight marks"
	))
	_append(failures, Assertions.expect_true(
		not capped.active,
		"Reaching the mark cap closes the trail session"
	))

	var slowed := BloodTrailState.new()
	slowed.start(Vector3.ZERO, 1.0)
	slowed.advance(Vector3(0.4, 0, 0), 0.05, 4.0, 1.3)
	slowed.advance(Vector3(0.45, 0, 0), 0.05, 1.5, 1.3)
	_append(failures, Assertions.expect_true(
		not slowed.active,
		"Trail stops after a mark when speed returns near normal movement"
	))

	var expired := BloodTrailState.new()
	expired.start(Vector3.ZERO, 1.0)
	expired.advance(Vector3(0.1, 0, 0), 0.76, 4.0, 1.3)
	_append(failures, Assertions.expect_true(
		not expired.active,
		"Trail session expires after 0.75 seconds"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
