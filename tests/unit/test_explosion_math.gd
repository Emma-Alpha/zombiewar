extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ExplosionMath = preload("res://scripts/combat/explosion_math.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	_append(failures, Assertions.expect_float_near(
		ExplosionMath.damage_at_distance(0.0, 4.5, 80.0, 20.0),
		80.0,
		0.0001,
		"Explosion keeps center damage at the origin"
	))
	_append(failures, Assertions.expect_float_near(
		ExplosionMath.damage_at_distance(2.25, 4.5, 80.0, 20.0),
		50.0,
		0.0001,
		"Explosion damage falls off linearly at half radius"
	))
	_append(failures, Assertions.expect_float_near(
		ExplosionMath.damage_at_distance(4.5, 4.5, 80.0, 20.0),
		20.0,
		0.0001,
		"Explosion keeps edge damage on the radius"
	))
	_append(failures, Assertions.expect_float_near(
		ExplosionMath.damage_at_distance(4.51, 4.5, 80.0, 20.0),
		0.0,
		0.0001,
		"Explosion deals no damage outside its radius"
	))
	_append(failures, Assertions.expect_float_near(
		ExplosionMath.damage_at_distance(0.0, 0.0, 80.0, 20.0),
		0.0,
		0.0001,
		"Explosion rejects an invalid radius"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
