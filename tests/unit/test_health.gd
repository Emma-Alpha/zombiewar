extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const HEALTH_PATH := "res://scripts/combat/health.gd"

var depleted_emissions: int = 0

func run() -> Array[String]:
	var failures: Array[String] = []
	var health_script := load(HEALTH_PATH) as Script
	if health_script == null:
		failures.append("Health script loads")
		return failures

	depleted_emissions = 0
	var health: Variant = health_script.new(50.0)
	health.depleted.connect(_on_depleted)
	_append(failures, Assertions.expect_float_near(health.current, 50.0, 0.0001, "Health starts full"))
	_append(failures, Assertions.expect_float_near(health.apply_damage(25.0), 25.0, 0.0001, "First shot damage"))
	_append(failures, Assertions.expect_float_near(health.current, 25.0, 0.0001, "Health after one shot"))
	_append(failures, Assertions.expect_float_near(health.apply_damage(40.0), 25.0, 0.0001, "Damage clamps at zero"))
	_append(failures, Assertions.expect_float_near(health.current, 0.0, 0.0001, "Health is depleted"))
	_append(failures, Assertions.expect_equal(depleted_emissions, 1, "Depletion signal emits once"))
	_append(failures, Assertions.expect_float_near(health.apply_damage(-10.0), 0.0, 0.0001, "Negative damage is ignored"))
	_append(failures, Assertions.expect_equal(depleted_emissions, 1, "Ignored damage does not re-emit depletion"))

	depleted_emissions = 0
	var near_zero_health: Variant = health_script.new(1.0)
	near_zero_health.depleted.connect(_on_depleted)
	near_zero_health.apply_damage(0.999999)
	_append(failures, Assertions.expect_true(near_zero_health.current > 0.0, "Near-zero health remains positive"))
	_append(failures, Assertions.expect_equal(depleted_emissions, 0, "Near-zero health does not emit depletion"))
	near_zero_health.apply_damage(near_zero_health.current)
	_append(failures, Assertions.expect_equal(near_zero_health.current, 0.0, "Exact remaining damage depletes health"))
	_append(failures, Assertions.expect_equal(depleted_emissions, 1, "Exact zero emits depletion once"))
	near_zero_health.apply_damage(1.0)
	_append(failures, Assertions.expect_equal(depleted_emissions, 1, "Further damage does not re-emit depletion"))
	return failures

func _on_depleted() -> void:
	depleted_emissions += 1

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
