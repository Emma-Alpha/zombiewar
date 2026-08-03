extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var follow_camera := load("res://scripts/camera/follow_camera.gd") as Script
	_append(failures, Assertions.expect_true(
		follow_camera != null,
		"FollowCamera script loads"
	))
	if follow_camera == null:
		return failures

	_append(failures, Assertions.expect_float_near(
		follow_camera.smoothing_weight(10.0, 0.0), 0.0, 0.0001, "Zero delta has zero camera movement"
	))
	var one_frame: float = follow_camera.smoothing_weight(10.0, 1.0 / 60.0)
	_append(failures, Assertions.expect_true(one_frame > 0.0 and one_frame < 1.0, "One frame weight is bounded"))
	_append(failures, Assertions.expect_true(
		follow_camera.smoothing_weight(10.0, 1.0) > 0.999,
		"Long delta converges to target"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
