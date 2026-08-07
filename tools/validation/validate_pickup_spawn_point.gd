extends SceneTree

const SPAWNER_SCENE_PATH := "res://scenes/gameplay/PickupSpawnPoint.tscn"
const RIFLE_PICKUP_PATH := "res://scenes/gameplay/RiflePickupChest.tscn"
const DEMO_SCENE_PATH := "res://scenes/gameplay/DemoArena.tscn"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(
		ResourceLoader.exists(SPAWNER_SCENE_PATH),
		"PickupSpawnPoint scene must exist",
		failures
	)
	if not failures.is_empty():
		_finish(failures)
		return
	await _test_spawn_and_respawn_lifecycle(failures)
	await _test_demo_pickup_spawner_wiring(failures)
	_finish(failures)

func _test_spawn_and_respawn_lifecycle(failures: Array[String]) -> void:
	var spawner_scene := load(SPAWNER_SCENE_PATH) as PackedScene
	var pickup_scene := load(RIFLE_PICKUP_PATH) as PackedScene
	_expect(spawner_scene != null, "PickupSpawnPoint scene must load", failures)
	_expect(pickup_scene != null, "Rifle pickup scene must load", failures)
	if spawner_scene == null or pickup_scene == null:
		return
	var spawner = spawner_scene.instantiate()
	spawner.pickup_scene = pickup_scene
	spawner.respawn_enabled = true
	spawner.respawn_delay_seconds = 60.0
	var geometry_changes := [0]
	spawner.navigation_geometry_changed.connect(
		func() -> void: geometry_changes[0] += 1
	)
	root.add_child(spawner)
	_expect(
		spawner.current_pickup == null,
		"initial pickup spawn must remain deferred until parent wiring completes",
		failures
	)
	await process_frame
	_expect(
		spawner.current_pickup != null and is_instance_valid(spawner.current_pickup),
		"deferred startup must create one pickup",
		failures
	)
	_expect(
		geometry_changes[0] == 1,
		"initial pickup insertion must emit one navigation geometry change",
		failures
	)
	if spawner.current_pickup == null:
		spawner.queue_free()
		await process_frame
		return

	var first_pickup = spawner.current_pickup
	first_pickup.collected.emit(first_pickup)
	_expect(
		geometry_changes[0] == 1,
		"successful collection must not notify navigation before geometry exits",
		failures
	)
	first_pickup.queue_free()
	await process_frame
	_expect(
		geometry_changes[0] == 2,
		"pickup tree exit must notify navigation after geometry is removed",
		failures
	)
	_expect(
		spawner.current_pickup == null,
		"pickup tree exit must clear the active instance",
		failures
	)
	_expect(
		not spawner.respawn_timer.is_stopped(),
		"successful collection must schedule the configured respawn",
		failures
	)

	spawner.respawn_timer.stop()
	spawner.respawn_timer.timeout.emit()
	_expect(
		spawner.current_pickup != null and is_instance_valid(spawner.current_pickup),
		"respawn timeout must create a replacement pickup",
		failures
	)
	_expect(
		geometry_changes[0] == 3,
		"replacement pickup insertion must notify navigation",
		failures
	)
	if spawner.current_pickup != null:
		spawner.current_pickup.queue_free()
	await process_frame
	_expect(
		geometry_changes[0] == 4,
		"external pickup removal must still notify navigation",
		failures
	)
	_expect(
		spawner.respawn_timer.is_stopped(),
		"external removal without collection must not schedule a respawn",
		failures
	)
	spawner.queue_free()
	await process_frame

func _test_demo_pickup_spawner_wiring(failures: Array[String]) -> void:
	var demo_scene := load(DEMO_SCENE_PATH) as PackedScene
	_expect(demo_scene != null, "DemoArena scene must load", failures)
	if demo_scene == null:
		return
	var arena = demo_scene.instantiate()
	root.add_child(arena)
	await process_frame
	var spawners_root := arena.get_node_or_null("World/Props/PickupSpawners")
	_expect(spawners_root != null, "DemoArena must contain pickup spawners", failures)
	if spawners_root != null:
		var expected := {
			"Rifle": [Vector3(-4.5, 0.0, 6.0), RIFLE_PICKUP_PATH],
			"RifleAmmo": [
				Vector3(0.0, 0.0, 9.0),
				"res://scenes/gameplay/RifleAmmoPickupChest.tscn",
			],
			"OilBarrel": [
				Vector3(4.5, 0.0, 6.0),
				"res://scenes/gameplay/OilBarrelPickupChest.tscn",
			],
		}
		_expect(
			spawners_root.get_child_count() == 3,
			"DemoArena must configure exactly three pickup spawners",
			failures
		)
		var runtime_navigation_callback := Callable(
			arena,
			"_on_runtime_navigation_geometry_changed"
		)
		for spawner_name: String in expected:
			var spawner = spawners_root.get_node_or_null(spawner_name)
			_expect(spawner != null, "DemoArena pickup spawner %s must exist" % spawner_name, failures)
			if spawner == null:
				continue
			_expect(
				spawner.position.is_equal_approx(expected[spawner_name][0]),
				"DemoArena pickup spawner %s must keep its fixed position" % spawner_name,
				failures
			)
			_expect(spawner.respawn_enabled, "%s respawn must be enabled" % spawner_name, failures)
			_expect(
				is_equal_approx(spawner.respawn_delay_seconds, 3.0),
				"%s respawn delay must remain three seconds" % spawner_name,
				failures
			)
			_expect(
				spawner.pickup_scene.resource_path == expected[spawner_name][1],
				"%s must use the configured pickup chest scene" % spawner_name,
				failures
			)
			_expect(
				spawner.navigation_geometry_changed.is_connected(
					runtime_navigation_callback
				),
				"%s must notify DemoArena runtime navigation" % spawner_name,
				failures
			)
	var decorative_chests := arena.get_node_or_null(
		"World/Props/SupplyPoint/Chests"
	)
	_expect(
		decorative_chests != null and decorative_chests.get_child_count() == 4,
		"DemoArena must preserve all four decorative SupplyChest instances",
		failures
	)
	arena.queue_free()
	await process_frame

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_pickup_spawn_point: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
