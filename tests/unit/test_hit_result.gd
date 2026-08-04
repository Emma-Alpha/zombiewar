extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const HitResult = preload("res://scripts/combat/hit_result.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var miss := HitResult.miss(Vector3(0, 1.2, -28))
	_append(failures, Assertions.expect_true(not miss.did_hit, "Miss result is not a hit"))
	var critical := HitResult.resolved(37.5, &"head", true, true, Vector3.UP)
	_append(failures, Assertions.expect_true(critical.did_hit, "Resolved result is a hit"))
	_append(failures, Assertions.expect_true(critical.critical, "Head result is critical"))
	_append(failures, Assertions.expect_true(critical.killed, "Kill result preserves killed state"))
	_append(failures, Assertions.expect_float_near(
		critical.damage_applied,
		37.5,
		0.0001,
		"Hit result preserves applied damage"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
