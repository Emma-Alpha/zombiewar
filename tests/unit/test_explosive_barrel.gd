extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const BARREL_SCENE_PATH := "res://scenes/props/ExplosiveBarrel.tscn"

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load(BARREL_SCENE_PATH) as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Explosive barrel scene loads"
	))
	if packed == null:
		return failures

	var tree := Engine.get_main_loop() as SceneTree
	var barrel := packed.instantiate() as Node3D
	var requested_delays: Array[float] = []
	barrel.connect(
		"explosion_requested",
		Callable(self, "_capture_delay").bind(requested_delays)
	)
	tree.root.add_child(barrel)
	barrel.set_physics_process(false)

	barrel.call("apply_hit", 35.0, barrel.global_position, Vector3.FORWARD)
	_append(failures, Assertions.expect_equal(
		barrel.call("get_firearm_hit_count"),
		1,
		"First firearm hit increments the barrel once"
	))
	_append(failures, Assertions.expect_equal(
		barrel.call("get_state"),
		0,
		"First firearm hit keeps the barrel intact"
	))

	barrel.call("apply_hit", 25.0, barrel.global_position, Vector3.FORWARD)
	var damage_smoke := barrel.get_node_or_null("DamageSmoke") as Node3D
	_append(failures, Assertions.expect_equal(
		barrel.call("get_firearm_hit_count"),
		2,
		"Second firearm hit increments the barrel once"
	))
	_append(failures, Assertions.expect_equal(
		barrel.call("get_state"),
		1,
		"Second firearm hit enters the damaged state"
	))
	_append(failures, Assertions.expect_true(
		damage_smoke != null and damage_smoke.visible,
		"Second firearm hit enables persistent damage feedback"
	))

	barrel.call("apply_hit", 25.0, barrel.global_position, Vector3.FORWARD)
	barrel.call("apply_hit", 25.0, barrel.global_position, Vector3.FORWARD)
	_append(failures, Assertions.expect_equal(
		barrel.call("get_firearm_hit_count"),
		3,
		"Barrel stops counting firearm hits after ignition"
	))
	_append(failures, Assertions.expect_equal(
		barrel.call("get_state"),
		2,
		"Third firearm hit locks the barrel in the exploding state"
	))
	_append(failures, Assertions.expect_equal(
		requested_delays.size(),
		1,
		"Third firearm hit requests exactly one explosion"
	))
	if not requested_delays.is_empty():
		_append(failures, Assertions.expect_float_near(
			requested_delays[0],
			0.0,
			0.0001,
			"Third firearm hit requests an immediate explosion"
		))
	barrel.free()

	var chained := packed.instantiate() as Node3D
	var chained_delays: Array[float] = []
	chained.connect(
		"explosion_requested",
		Callable(self, "_capture_delay").bind(chained_delays)
	)
	tree.root.add_child(chained)
	chained.set_physics_process(false)
	var rejected: bool = chained.call(
		"apply_explosion_damage",
		0.0,
		Vector3.ZERO
	)
	var accepted: bool = chained.call(
		"apply_explosion_damage",
		20.0,
		Vector3.ZERO
	)
	chained.call("apply_explosion_damage", 80.0, Vector3.ZERO)
	_append(failures, Assertions.expect_true(
		not rejected and accepted,
		"Barrel accepts only positive explosion damage"
	))
	_append(failures, Assertions.expect_equal(
		chained.call("get_state"),
		2,
		"Explosion damage immediately locks a chained barrel"
	))
	_append(failures, Assertions.expect_equal(
		chained_delays.size(),
		1,
		"Repeated explosion damage queues a chained barrel once"
	))
	if not chained_delays.is_empty():
		_append(failures, Assertions.expect_float_near(
			chained_delays[0],
			0.12,
			0.0001,
			"Explosion damage uses the readable chain delay"
		))
	chained.free()
	return failures

func _capture_delay(delay_seconds: float, values: Array[float]) -> void:
	values.append(delay_seconds)

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
