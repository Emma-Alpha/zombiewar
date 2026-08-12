extends SceneTree

const SimHasherScript = preload("res://scripts/sim/sim_hasher.gd")
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var world: SimWorld = SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(20260811)
	world.configure_zombie_profile(0, 50, 1.3)
	world.configure_zombie_profile(1, 150, 1.8)
	var normal_id := world.spawn_zombie(Vector2.ZERO, 0.0, 0)
	var elite_id := world.spawn_zombie(Vector2(2.0, 0.0), 0.0, 1)
	_expect(world.get_zombie_profile_index(0) == 0, "normal type index", failures)
	_expect(world.get_zombie_profile_index(1) == 1, "elite type index", failures)
	_expect(world.get_zombie_max_health(0) == 5000, "normal health scale", failures)
	_expect(world.get_zombie_max_health(1) == 15000, "elite health scale", failures)
	_expect(
		is_equal_approx(world.zombie_move_speed[0], 1.3)
			and is_equal_approx(world.zombie_move_speed[1], 1.8),
		"profile speed must stay with its zombie",
		failures
	)
	var normal_index := world.index_of_zombie(normal_id)
	world.apply_zombie_damage(
		normal_index,
		99999,
		Vector2.ZERO,
		0.0,
		Vector2.RIGHT,
		&"body"
	)
	world.step_tick()
	_expect(world.index_of_zombie(elite_id) == 0, "compaction must retain elite", failures)
	_expect(
		world.get_zombie_profile_index(0) == 1,
		"type array must compact with entity",
		failures
	)

	var normal_world: SimWorld = SimWorldScript.new()
	normal_world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	normal_world.reset(20260811)
	normal_world.configure_zombie_profile(0, 50, 1.3)
	normal_world.spawn_zombie(Vector2.ZERO, 0.0, 0)
	var elite_world: SimWorld = SimWorldScript.new()
	elite_world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	elite_world.reset(20260811)
	elite_world.configure_zombie_profile(1, 50, 1.3)
	elite_world.spawn_zombie(Vector2.ZERO, 0.0, 1)
	_expect(
		SimHasherScript.hash_world(normal_world) != SimHasherScript.hash_world(elite_world),
		"profile index must affect the frame hash",
		failures
	)
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_sim_zombie_types: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
