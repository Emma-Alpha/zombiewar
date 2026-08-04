extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const MeleeAttackCycle = preload("res://scripts/combat/melee_attack_cycle.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var cycle := MeleeAttackCycle.new(0.8, 0.25)
	_append(failures, Assertions.expect_true(
		not cycle.tick(0.0, true, true) and cycle.is_winding_up(),
		"Entering range starts windup without immediate damage"
	))
	_append(failures, Assertions.expect_true(
		not cycle.tick(0.20, true, true),
		"Attack does not land before windup completes"
	))
	_append(failures, Assertions.expect_true(
		cycle.tick(0.05, true, true),
		"Attack lands when windup completes"
	))
	_append(failures, Assertions.expect_true(
		not cycle.tick(0.30, true, true) and not cycle.is_winding_up(),
		"Cooldown prevents an immediate second attack"
	))
	cycle.tick(0.50, true, true)
	_append(failures, Assertions.expect_true(
		cycle.is_winding_up(),
		"A new attack starts after cooldown"
	))
	cycle.cancel_pending()
	_append(failures, Assertions.expect_true(
		not cycle.is_winding_up() and not cycle.tick(0.30, true, true),
		"Cancelling a windup prevents its pending hit"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
