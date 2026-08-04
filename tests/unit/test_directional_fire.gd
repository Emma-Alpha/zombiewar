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
		_append(failures, Assertions.expect_vector3_near(
			weapon_math.ray_end_from_direction(
				Vector3(1.0, 1.2, 1.0),
				Vector3.RIGHT * 3.0,
				28.0
			),
			Vector3(29.0, 1.2, 1.0),
			0.0001,
			"Directional ray normalizes aim and uses the visible-arena range"
		))

	if fire_gate_script != null:
		var gate: RefCounted = fire_gate_script.new(1.0 / 6.0) as RefCounted
		_append(failures, Assertions.expect_true(gate.call("try_consume"), "First shot is immediately available"))
		_append(failures, Assertions.expect_true(not gate.call("try_consume"), "Second immediate shot is blocked"))
		gate.call("tick", 1.0 / 6.0)
		_append(failures, Assertions.expect_true(gate.call("try_consume"), "Shot is available after cooldown"))

		var carry_gate: RefCounted = fire_gate_script.new(1.0 / 6.0) as RefCounted
		_append(failures, Assertions.expect_true(
			carry_gate.try_consume(true),
			"Held trigger fires immediately"
		))
		carry_gate.tick(0.2)
		_append(failures, Assertions.expect_true(
			carry_gate.try_consume(true),
			"Overshoot frame still allows the next shot"
		))
		_append(failures, Assertions.expect_float_near(
			carry_gate.remaining,
			(1.0 / 6.0) - (0.2 - 1.0 / 6.0),
			0.0001,
			"Fire cadence carries frame overshoot into the next interval"
		))

		var buffered_gate: RefCounted = fire_gate_script.new(1.0 / 6.0) as RefCounted
		buffered_gate.try_consume(true)
		buffered_gate.request_shot(0.08)
		buffered_gate.tick(1.0 / 6.0)
		_append(failures, Assertions.expect_true(
			buffered_gate.try_consume(false),
			"Released tap fires when the buffered cooldown expires"
		))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
