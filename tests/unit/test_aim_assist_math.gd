extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const AimAssistMath = preload("res://scripts/combat/aim_assist_math.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var origin := Vector3(0, 1.2, 0)
	var candidates: Array[Vector3] = [
		Vector3(0.6, 1.1, -12.0),
		Vector3(2.5, 1.1, -10.0),
		Vector3(0.1, 1.1, -22.0),
	]
	_append(failures, Assertions.expect_equal(
		AimAssistMath.select_best_index(
			origin,
			Vector3.FORWARD,
			candidates,
			18.0,
			deg_to_rad(5.0)
		),
		0,
		"Aim assist prefers the on-angle target inside range"
	))
	_append(failures, Assertions.expect_equal(
		AimAssistMath.select_best_index(
			origin,
			Vector3.RIGHT,
			candidates,
			18.0,
			deg_to_rad(5.0)
		),
		-1,
		"Aim assist rejects candidates outside the cone"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
