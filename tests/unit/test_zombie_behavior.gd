extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZombieBehaviorMath = preload("res://scripts/combat/zombie_behavior_math.gd")

class FixedNavigationZombie:
	extends ZombieTarget

	var fixed_navigation_velocity := Vector3.ZERO

	func _navigation_velocity(
		_target_position: Vector3,
		_stop_range: float,
		_move_speed: float,
		_slow_radius: float
	) -> Vector3:
		return fixed_navigation_velocity

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var camera := Camera3D.new()
	camera.current = true
	var player := (load("res://scenes/player/Player.tscn") as PackedScene).instantiate() as PlayerController
	var zombie := (load("res://scenes/targets/ZombieTarget.tscn") as PackedScene).instantiate() as ZombieTarget
	zombie.set_script(FixedNavigationZombie)
	host.add_child(camera)
	host.add_child(player)
	host.add_child(zombie)
	tree.root.add_child(host)
	player.set_physics_process(false)
	zombie.set_physics_process(false)
	zombie.set_attack_target(player)
	var navigation_agent := zombie.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	_append(failures, Assertions.expect_true(
		navigation_agent != null and not navigation_agent.avoidance_enabled,
		"Zombie owns navigation agent with avoidance disabled"
	))
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
	zombie.set("fixed_navigation_velocity", Vector3(0.0, 0.0, -1.30))

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
	_append(failures, Assertions.expect_float_near(
		absf(zombie.rotation.y),
		PI,
		0.0001,
		"Aware approach faces its non-zero path velocity instead of the player"
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
	_append(failures, Assertions.expect_float_near(
		zombie.rotation.y,
		PI * 0.5,
		0.0001,
		"Attack continues facing the player"
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
	_append_attack_clearance_failures(failures)
	return failures

func _append_attack_clearance_failures(failures: Array[String]) -> void:
	_assert_attack_clearance(
		failures,
		null,
		true,
		"Unobstructed real physics ray leaves the attack path clear"
	)
	var area := Area3D.new()
	area.collision_layer = 1
	area.position = Vector3(1.0, 0.90, 0.0)
	area.add_child(_make_box_collision(Vector3(0.40, 1.0, 1.0)))
	_assert_attack_clearance(
		failures,
		area,
		true,
		"Layer-1 Area3D is ignored by the real attack clearance ray"
	)
	var blocker := StaticBody3D.new()
	blocker.collision_layer = 1
	blocker.position = Vector3(1.0, 0.90, 0.0)
	blocker.add_child(_make_box_collision(Vector3(0.40, 1.0, 1.0)))
	_assert_attack_clearance(
		failures,
		blocker,
		false,
		"Layer-1 PhysicsBody3D blocks the real attack clearance ray"
	)

func _assert_attack_clearance(
	failures: Array[String],
	obstacle: CollisionObject3D,
	expected_clear: bool,
	message: String
) -> void:
	var host := Node3D.new()
	var camera := Camera3D.new()
	camera.current = true
	var player := (load("res://scenes/player/Player.tscn") as PackedScene).instantiate() as PlayerController
	var zombie := (load("res://scenes/targets/ZombieTarget.tscn") as PackedScene).instantiate() as ZombieTarget
	zombie.position = Vector3.ZERO
	player.position = Vector3(2.0, 0.0, 0.0)
	host.add_child(camera)
	host.add_child(zombie)
	host.add_child(player)
	if obstacle != null:
		host.add_child(obstacle)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)
	zombie.set_physics_process(false)
	player.set_physics_process(false)
	zombie.set_attack_target(player)
	_append(failures, Assertions.expect_equal(
		bool(zombie.call("_attack_path_is_clear")),
		expected_clear,
		message
	))
	host.free()

func _make_box_collision(size: Vector3) -> CollisionShape3D:
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	return collision

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
