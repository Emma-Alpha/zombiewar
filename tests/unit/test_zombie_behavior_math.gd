extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZombieBehaviorMath = preload("res://scripts/combat/zombie_behavior_math.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var state := ZombieBehaviorMath.State.WANDER
	state = ZombieBehaviorMath.next_state(state, 8.0, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.WANDER,
		"Player outside perception leaves zombie wandering"
	))
	state = ZombieBehaviorMath.next_state(state, 6.5, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.AWARE_APPROACH,
		"Player inside perception starts slow approach"
	))
	state = ZombieBehaviorMath.next_state(state, 7.6, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.AWARE_APPROACH,
		"Perception exit margin prevents boundary flicker"
	))
	state = ZombieBehaviorMath.next_state(state, 8.1, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.WANDER,
		"Zombie forgets player beyond perception exit margin"
	))
	state = ZombieBehaviorMath.next_state(state, 1.40, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.ATTACK,
		"Only attack range enters attack state"
	))
	state = ZombieBehaviorMath.next_state(state, 2.0, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.AWARE_APPROACH,
		"Leaving attack range returns to approach immediately"
	))
	_append(failures, Assertions.expect_equal(
		ZombieBehaviorMath.next_state(state, 1.0, false, 7.0, 1.0, 1.45),
		ZombieBehaviorMath.State.WANDER,
		"Dead or missing player always returns zombie to wander"
	))

	_append(failures, Assertions.expect_vector3_near(
		ZombieBehaviorMath.wander_point(Vector3(2.0, 0.0, 3.0), PI * 0.5, 0.5, 4.0),
		Vector3(2.0, 0.0, 5.0),
		0.0001,
		"Wander target is derived only from home position and random sample"
	))
	_append(failures, Assertions.expect_vector3_near(
		ZombieBehaviorMath.arrive_velocity(Vector3.ZERO, Vector3(4.0, 0.0, 0.0), 1.45, 1.30, 1.5),
		Vector3(1.30, 0.0, 0.0),
		0.0001,
		"Distant aware zombie uses full difficulty speed"
	))
	_append(failures, Assertions.expect_vector3_near(
		ZombieBehaviorMath.arrive_velocity(Vector3.ZERO, Vector3(1.825, 0.0, 0.0), 1.45, 1.30, 1.5),
		Vector3(0.325, 0.0, 0.0),
		0.0001,
		"Aware zombie slows down before attack range"
	))
	_append(failures, Assertions.expect_vector3_near(
		ZombieBehaviorMath.arrive_velocity(Vector3.ZERO, Vector3(1.40, 0.0, 0.0), 1.45, 1.30, 1.5),
		Vector3.ZERO,
		0.0001,
		"Attack range produces zero approach velocity"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
