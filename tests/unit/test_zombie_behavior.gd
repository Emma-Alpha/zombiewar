extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZombieBehaviorMath = preload("res://scripts/combat/zombie_behavior_math.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var player := (load("res://scenes/player/Player.tscn") as PackedScene).instantiate() as PlayerController
	var zombie := (load("res://scenes/targets/ZombieTarget.tscn") as PackedScene).instantiate() as ZombieTarget
	host.add_child(player)
	host.add_child(zombie)
	tree.root.add_child(host)
	player.set_physics_process(false)
	zombie.set_physics_process(false)
	zombie.set_attack_target(player)
	var has_speed_injection := zombie.has_method("set_perception_move_speed")
	var has_state_query := zombie.has_method("get_behavior_state")
	_append(failures, Assertions.expect_true(
		has_speed_injection,
		"Zombie exposes perception speed injection"
	))
	_append(failures, Assertions.expect_true(
		has_state_query,
		"Zombie exposes behavior state query"
	))
	if not has_speed_injection or not has_state_query:
		host.free()
		return failures
	zombie.set_perception_move_speed(1.30)

	player.global_position = zombie.global_position + Vector3(10.0, 0.0, 0.0)
	zombie.call("_physics_process", 0.1)
	_append(failures, Assertions.expect_equal(
		zombie.get_behavior_state(),
		ZombieBehaviorMath.State.WANDER,
		"Zombie wanders outside perception"
	))
	_append(failures, Assertions.expect_true(
		not zombie.attack_cycle.is_winding_up(),
		"Wandering zombie does not prepare an attack"
	))

	player.global_position = zombie.global_position + Vector3(5.0, 0.0, 0.0)
	zombie.call("_physics_process", 0.1)
	_append(failures, Assertions.expect_equal(
		zombie.get_behavior_state(),
		ZombieBehaviorMath.State.AWARE_APPROACH,
		"Zombie approaches inside perception"
	))
	_append(failures, Assertions.expect_true(
		Vector2(zombie.velocity.x, zombie.velocity.z).length() <= 1.3001,
		"Aware movement respects injected difficulty speed"
	))
	_append(failures, Assertions.expect_true(
		not zombie.attack_cycle.is_winding_up(),
		"Aware approach cannot start an attack outside attack range"
	))

	player.global_position = zombie.global_position + Vector3(5.0, 0.0, 0.0)
	zombie.call("_physics_process", 1.0)
	_append(failures, Assertions.expect_float_near(
		Vector2(zombie.velocity.x, zombie.velocity.z).length(),
		1.30,
		0.0001,
		"Aware movement reaches the injected difficulty speed"
	))

	player.global_position = zombie.global_position + Vector3(1.0, 0.0, 0.0)
	zombie.call("_physics_process", 0.0)
	_append(failures, Assertions.expect_equal(
		zombie.get_behavior_state(),
		ZombieBehaviorMath.State.ATTACK,
		"Zombie attacks only after player enters attack range"
	))
	_append(failures, Assertions.expect_true(
		zombie.attack_cycle.is_winding_up(),
		"Entering attack range starts the fixed attack windup"
	))
	var health_before_cancel := player.health.current
	player.global_position = zombie.global_position + Vector3(5.0, 0.0, 0.0)
	zombie.call("_physics_process", 0.1)
	_append(failures, Assertions.expect_equal(
		zombie.get_behavior_state(),
		ZombieBehaviorMath.State.AWARE_APPROACH,
		"Leaving attack range returns zombie to aware approach"
	))
	_append(failures, Assertions.expect_true(
		not zombie.attack_cycle.is_winding_up(),
		"Leaving attack range cancels the pending windup immediately"
	))
	zombie.call("_physics_process", 1.0)
	_append(failures, Assertions.expect_float_near(
		player.health.current,
		health_before_cancel,
		0.0001,
		"Cancelled attack cannot damage the player when advanced later"
	))

	host.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
