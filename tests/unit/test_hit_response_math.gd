extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const HitResponseMath = preload("res://scripts/combat/hit_response_math.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var torso := HitResponseMath.knockback_velocity(Vector3(2.0, 1.0, 0.0), 6.0, 1.0, 0.05)
	var head := HitResponseMath.knockback_velocity(Vector3(2.0, 1.0, 0.0), 6.0, 1.35, 0.22)

	_append(failures, Assertions.expect_float_near(
		torso.x,
		6.0,
		0.0001,
		"Knockback normalizes the horizontal shot direction"
	))
	_append(failures, Assertions.expect_float_near(
		torso.z,
		0.0,
		0.0001,
		"Knockback does not introduce sideways drift"
	))
	_append(failures, Assertions.expect_true(
		head.x > torso.x,
		"Head hit has stronger horizontal impulse"
	))
	_append(failures, Assertions.expect_true(
		head.y > torso.y,
		"Head hit has stronger lift"
	))

	var fallback := HitResponseMath.knockback_velocity(Vector3.ZERO, 4.0, 1.0, 0.0)
	_append(failures, Assertions.expect_float_near(
		fallback.length(),
		4.0,
		0.0001,
		"Zero shot direction still produces a stable fallback impulse"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
