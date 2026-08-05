extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const BLOOD_SCENE_PATH := "res://scenes/fx/BloodImpact.tscn"

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load(BLOOD_SCENE_PATH) as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Blood impact scene loads"
	))
	if packed == null:
		return failures

	var effect := packed.instantiate()
	var splat := effect.get_node_or_null("Splat") as Sprite3D
	var droplets := effect.get_node_or_null("Droplets") as GPUParticles3D
	_append(failures, Assertions.expect_true(
		effect.has_method("setup"),
		"Blood impact exposes a setup entry point"
	))
	_append(failures, Assertions.expect_true(
		splat != null and splat.texture != null,
		"Blood impact uses an imported splat texture"
	))
	_append(failures, Assertions.expect_true(
		droplets != null and droplets.one_shot and droplets.amount >= 12,
		"Blood impact has a one-shot droplet burst"
	))
	effect.free()

	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	host.add_child(target)
	tree.root.add_child(host)
	target.set_physics_process(false)
	var hit_requests: Array[Dictionary] = []
	var trail_requests: Array[Dictionary] = []
	target.ground_blood_requested.connect(func(
		origin: Vector3, direction: Vector3, intensity: float, death_pool: bool
	) -> void:
		hit_requests.append({
			"origin": origin,
			"direction": direction,
			"intensity": intensity,
			"death_pool": death_pool,
		})
	)
	target.ground_blood_trail_requested.connect(func(
		position: Vector3, direction: Vector3, intensity: float, progress: float
	) -> void:
		trail_requests.append({
			"position": position,
			"direction": direction,
			"intensity": intensity,
			"progress": progress,
		})
	)
	var initial_children := host.get_child_count()
	var hit_position := Vector3(0.25, 1.1, -0.4)
	target.call(
		"apply_hit",
		10.0,
		hit_position,
		Vector3.FORWARD
	)
	_append(failures, Assertions.expect_equal(
		host.get_child_count(),
		initial_children + 1,
		"Successful zombie hit spawns one blood impact"
	))
	if host.get_child_count() == initial_children + 1:
		var spawned := host.get_child(initial_children)
		_append(failures, Assertions.expect_equal(
			spawned.scene_file_path,
			BLOOD_SCENE_PATH,
			"Zombie spawns the shared BloodImpact scene"
		))
	_append(failures, Assertions.expect_equal(
		hit_requests.size(),
		1,
		"A non-lethal hit requests exactly one persistent main splat"
	))
	if hit_requests.size() == 1:
		_append(failures, Assertions.expect_equal(
			hit_requests[0]["origin"],
			hit_position,
			"Persistent main splat uses the real hit position"
		))
		_append(failures, Assertions.expect_equal(
			hit_requests[0]["death_pool"],
			false,
			"A non-lethal hit does not request a death pool"
		))
	_append(failures, Assertions.expect_true(
		target.blood_trail_state.active,
		"A successful hit starts a knockback blood trail session"
	))
	_append(failures, Assertions.expect_equal(
		trail_requests.size(),
		0,
		"A hit does not request a trail before collision-aware movement"
	))
	var movement_start := target.global_position
	target.call("_physics_process", 0.1)
	var actual_movement := target.global_position - movement_start
	actual_movement.y = 0.0
	_append(failures, Assertions.expect_true(
		trail_requests.size() >= 1,
		"Knockback requests a trail after collision-aware movement"
	))
	if not trail_requests.is_empty() and actual_movement.length_squared() > 0.000001:
		_append(failures, Assertions.expect_vector3_near(
			trail_requests[0]["direction"],
			actual_movement.normalized(),
			0.0001,
			"Knockback trail follows the actual post-collision movement direction"
		))

	var idle_target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	host.add_child(idle_target)
	idle_target.set_physics_process(false)
	var idle_trail_requests: Array[Dictionary] = []
	idle_target.ground_blood_trail_requested.connect(func(
		position: Vector3, direction: Vector3, intensity: float, progress: float
	) -> void:
		idle_trail_requests.append({
			"position": position,
			"direction": direction,
			"intensity": intensity,
			"progress": progress,
		})
	)
	idle_target.call("_physics_process", 0.1)
	_append(failures, Assertions.expect_equal(
		idle_trail_requests.size(),
		0,
		"Normal movement without a hit does not request a blood trail"
	))

	var lethal_target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	host.add_child(lethal_target)
	lethal_target.set_physics_process(false)
	var lethal_requests: Array[Dictionary] = []
	lethal_target.ground_blood_requested.connect(func(
		origin: Vector3, direction: Vector3, intensity: float, death_pool: bool
	) -> void:
		lethal_requests.append({
			"origin": origin,
			"direction": direction,
			"intensity": intensity,
			"death_pool": death_pool,
		})
	)
	var lethal_hit_position := Vector3(-0.3, 1.4, 0.2)
	lethal_target.call("apply_hit", 100.0, lethal_hit_position, Vector3.RIGHT)
	_append(failures, Assertions.expect_equal(
		lethal_requests.size(),
		2,
		"A lethal hit requests both the main splat and the death pool"
	))
	if lethal_requests.size() == 2:
		_append(failures, Assertions.expect_true(
			lethal_requests[0]["origin"] == lethal_hit_position and
			not lethal_requests[0]["death_pool"],
			"A lethal hit still places its main splat at the real hit position"
		))
		_append(failures, Assertions.expect_true(
			lethal_requests[1]["origin"] == lethal_target.global_position and
			lethal_requests[1]["death_pool"],
			"A lethal hit adds a death pool at the zombie position"
		))
	host.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
