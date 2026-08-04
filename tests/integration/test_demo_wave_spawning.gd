extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const SPAWN_POINT_NAMES: Array[StringName] = [
	&"NorthWest",
	&"NorthEast",
	&"SouthWest",
	&"SouthEast",
]

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Wave test loads DemoArena"
	))
	if packed == null:
		return failures

	var arena := packed.instantiate()
	arena.set("random_seed", 20260805)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)

	var targets := arena.get_node_or_null("World/Targets")
	var spawn_root := arena.get_node_or_null("World/SpawnPoints")
	var player := arena.get_node_or_null("Player")
	var initial_zombies := _get_zombies(targets)
	var has_wave_interface := (
		arena.has_method(&"spawn_wave") and
		arena.has_method(&"get_active_zombie_count")
	)

	_append(failures, Assertions.expect_true(
		spawn_root != null,
		"Demo exposes four-corner spawn points"
	))
	_append(failures, Assertions.expect_true(
		initial_zombies.size() >= 4 and initial_zombies.size() <= 8,
		"Initial wave contains four to eight zombies"
	))
	_append(failures, Assertions.expect_equal(
		arena.get("wave_number"),
		1,
		"Initial wave increments the wave number"
	))
	_append(failures, Assertions.expect_true(
		has_wave_interface,
		"Demo exposes dynamic wave spawning and active-count interfaces"
	))
	if not has_wave_interface:
		arena.free()
		return failures

	var corner_counts: Dictionary = {}
	for point_name in SPAWN_POINT_NAMES:
		corner_counts[point_name] = 0

	for zombie in initial_zombies:
		var nearest_name := _nearest_spawn_name(zombie, spawn_root)
		corner_counts[nearest_name] = int(corner_counts[nearest_name]) + 1
		var marker := spawn_root.get_node(String(nearest_name)) as Marker3D
		_append(failures, Assertions.expect_true(
			_planar_distance(zombie.global_position, marker.global_position) <= 1.751,
			"Zombie stays inside its corner spawn radius"
		))
		_append(failures, Assertions.expect_float_near(
			zombie.perception_range,
			60.0,
			0.0001,
			"Wave zombie detects the player across the arena"
		))
		_append(failures, Assertions.expect_true(
			zombie.attack_target == player,
			"Wave zombie targets the arena player"
		))

	for point_name in SPAWN_POINT_NAMES:
		_append(failures, Assertions.expect_true(
			int(corner_counts[point_name]) >= 1,
			"Every corner contributes at least one zombie: %s" % point_name
		))

	for first_index in range(initial_zombies.size()):
		for second_index in range(first_index + 1, initial_zombies.size()):
			_append(failures, Assertions.expect_true(
				_planar_distance(
					initial_zombies[first_index].global_position,
					initial_zombies[second_index].global_position
				) >= 1.099,
				"Initial wave zombies keep minimum horizontal spacing"
			))

	var initial_count := initial_zombies.size()
	var appended := int(arena.call("spawn_wave"))
	_append(failures, Assertions.expect_true(
		appended > 0,
		"Manual wave request creates zombies while capacity remains"
	))
	_append(failures, Assertions.expect_equal(
		int(arena.call("get_active_zombie_count")),
		initial_count + appended,
		"Active count follows the appended wave"
	))
	_append(failures, Assertions.expect_equal(
		int(arena.get("wave_number")),
		2,
		"Successful manual wave increments the wave number"
	))

	for _index in range(8):
		arena.call("spawn_wave")
	_append(failures, Assertions.expect_equal(
		int(arena.call("get_active_zombie_count")),
		24,
		"Repeated wave requests stop at the active-zombie cap"
	))
	_append(failures, Assertions.expect_equal(
		int(arena.call("spawn_wave")),
		0,
		"A full arena rejects another wave"
	))

	arena.free()
	return failures

func _get_zombies(targets: Node) -> Array[ZombieTarget]:
	var zombies: Array[ZombieTarget] = []
	if targets == null:
		return zombies
	for child in targets.get_children():
		if child is ZombieTarget:
			zombies.append(child as ZombieTarget)
	return zombies

func _nearest_spawn_name(zombie: ZombieTarget, spawn_root: Node) -> StringName:
	var nearest_name := StringName()
	var nearest_distance := INF
	for point_name in SPAWN_POINT_NAMES:
		var marker := spawn_root.get_node(String(point_name)) as Marker3D
		var distance := _planar_distance(
			zombie.global_position,
			marker.global_position
		)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_name = point_name
	return nearest_name

func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
