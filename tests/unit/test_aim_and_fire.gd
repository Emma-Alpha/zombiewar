extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const AIM_MATH_PATH := "res://scripts/combat/aim_math.gd"
const FIRE_GATE_PATH := "res://scripts/combat/fire_gate.gd"

func run() -> Array[String]:
	var failures: Array[String] = []
	var aim_math := load(AIM_MATH_PATH) as Script
	var fire_gate_script := load(FIRE_GATE_PATH) as Script
	_append(failures, Assertions.expect_true(aim_math != null, "Aim math helper loads"))
	_append(failures, Assertions.expect_true(fire_gate_script != null, "Fire gate helper loads"))

	if aim_math != null:
		var hit: Variant = aim_math.call("intersect_y_plane", Vector3(0, 10, 0), Vector3(0, -1, 0), 0.0)
		_append(failures, Assertions.expect_true(hit is Vector3, "Downward ray intersects ground"))
		if hit is Vector3:
			_append(failures, Assertions.expect_vector3_near(hit, Vector3.ZERO, 0.0001, "Ground hit position"))
		_append(failures, Assertions.expect_equal(
			aim_math.call("intersect_y_plane", Vector3(0, 10, 0), Vector3.RIGHT, 0.0),
			null,
			"Parallel ray has no ground intersection"
		))

	if fire_gate_script != null:
		var gate: RefCounted = fire_gate_script.new(1.0 / 6.0) as RefCounted
		_append(failures, Assertions.expect_true(gate.call("try_consume"), "First shot is immediately available"))
		_append(failures, Assertions.expect_true(not gate.call("try_consume"), "Second immediate shot is blocked"))
		gate.call("tick", 1.0 / 6.0)
		_append(failures, Assertions.expect_true(gate.call("try_consume"), "Shot is available after cooldown"))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
