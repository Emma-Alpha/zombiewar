extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const WEAPON_MATH_PATH := "res://scripts/combat/weapon_math.gd"
const FIRE_GATE_PATH := "res://scripts/combat/fire_gate.gd"

func run() -> Array[String]:
	var failures: Array[String] = []
	var weapon_math := load(WEAPON_MATH_PATH) as Script
	var fire_gate_script := load(FIRE_GATE_PATH) as Script
	_append(failures, Assertions.expect_true(weapon_math != null, "Weapon math helper loads"))
	_append(failures, Assertions.expect_true(fire_gate_script != null, "Fire gate helper loads"))

	if weapon_math != null:
		_append(failures, Assertions.expect_vector3_near(
			weapon_math.forward_direction(Basis.IDENTITY),
			Vector3.FORWARD,
			0.0001,
			"Identity player basis fires along Godot forward"
		))
		var right_facing_basis := Basis(Vector3.UP, -PI / 2.0)
		_append(failures, Assertions.expect_vector3_near(
			weapon_math.forward_direction(right_facing_basis),
			Vector3.RIGHT,
			0.0001,
			"Rotated player fires along retained facing"
		))
		_append(failures, Assertions.expect_vector3_near(
			weapon_math.ray_end(Vector3(1.0, 1.2, 1.0), right_facing_basis, 80.0),
			Vector3(81.0, 1.2, 1.0),
			0.0001,
			"Directional ray keeps the 80 meter range"
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
