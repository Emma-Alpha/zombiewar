extends SceneTree

const SPAWNER_SCENE_PATH := "res://scenes/gameplay/PickupSpawnPoint.tscn"
const PICKUP_CHEST_SCENE_PATH := "res://scenes/gameplay/PickupChest.tscn"
const DEMO_SCENE_PATH := "res://scenes/gameplay/DemoArena.tscn"
const RIFLE_PICKUP_DEFINITION_PATH := "res://resources/pickups/rifle_pickup.tres"
const RIFLE_AMMO_PICKUP_DEFINITION_PATH := "res://resources/pickups/rifle_ammo_pickup.tres"
const OIL_BARREL_PICKUP_DEFINITION_PATH := "res://resources/pickups/oil_barrel_pickup.tres"

const DEMO_PICKUP_DEFINITIONS := {
	"Rifle": RIFLE_PICKUP_DEFINITION_PATH,
	"RifleAmmo": RIFLE_AMMO_PICKUP_DEFINITION_PATH,
	"OilBarrel": OIL_BARREL_PICKUP_DEFINITION_PATH,
}

const REMOVED_PICKUP_SCENE_PATHS := [
	"res://scenes/gameplay/RiflePickupChest.tscn",
	"res://scenes/gameplay/RifleAmmoPickupChest.tscn",
	"res://scenes/gameplay/OilBarrelPickupChest.tscn",
]

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
	_test_pickup_definition_resources(failures)
	await _test_spawn_and_respawn_lifecycle(failures)
	await _test_demo_pickup_spawner_wiring(failures)
	_finish(failures)

func _test_pickup_definition_resources(failures: Array[String]) -> void:
	var expected := {
		RIFLE_PICKUP_DEFINITION_PATH: {
			"reward_mode": PickupDefinition.RewardMode.EQUIPMENT,
			"item_id": &"rifle",
			"amount": 60,
			"auto_equip": true,
			"display_name": "步枪",
			"marker_color": Color(1.0, 0.45, 0.08, 1.0),
		},
		RIFLE_AMMO_PICKUP_DEFINITION_PATH: {
			"reward_mode": PickupDefinition.RewardMode.AMMO,
			"item_id": &"rifle",
			"amount": 90,
			"auto_equip": false,
			"display_name": "步枪弹药",
			"marker_color": Color(0.20, 0.55, 1.0, 1.0),
		},
		OIL_BARREL_PICKUP_DEFINITION_PATH: {
			"reward_mode": PickupDefinition.RewardMode.EQUIPMENT,
			"item_id": &"oil_barrel",
			"amount": 30,
			"auto_equip": false,
			"display_name": "油桶",
			"marker_color": Color(0.20, 0.90, 0.35, 1.0),
		},
	}
	for definition_path: String in expected:
		var definition := load(definition_path) as PickupDefinition
		_expect(definition != null, "%s must load as a PickupDefinition" % definition_path, failures)
		if definition == null:
			continue
		for property_name: String in expected[definition_path]:
			_expect(
				definition.get(property_name) == expected[definition_path][property_name],
				"%s must configure %s" % [definition_path, property_name],
				failures
			)
	for removed_scene_path: String in REMOVED_PICKUP_SCENE_PATHS:
		_expect(
			not ResourceLoader.exists(removed_scene_path),
			"specialized pickup scene must be removed: %s" % removed_scene_path,
			failures
		)

func _test_spawn_and_respawn_lifecycle(failures: Array[String]) -> void:
	var spawner_scene := load(SPAWNER_SCENE_PATH) as PackedScene
	var pickup_definition := load(RIFLE_PICKUP_DEFINITION_PATH) as PickupDefinition
	_expect(spawner_scene != null, "PickupSpawnPoint scene must load", failures)
	_expect(pickup_definition != null, "rifle Definition must load", failures)
	if spawner_scene == null or pickup_definition == null:
		return
	var spawner = spawner_scene.instantiate()
	_expect(
		"pickup_definition" in spawner,
		"PickupSpawnPoint must expose pickup_definition",
		failures
	)
	if not ("pickup_definition" in spawner):
		spawner.free()
		return
	spawner.pickup_definition = pickup_definition
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
		spawner.current_pickup != null and spawner.current_pickup.definition == pickup_definition,
		"spawned PickupChest must be configured with the injected Definition",
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
			"Rifle": Vector3(-4.5, 0.0, 6.0),
			"RifleAmmo": Vector3(0.0, 0.0, 9.0),
			"OilBarrel": Vector3(4.5, 0.0, 6.0),
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
				spawner.position.is_equal_approx(expected[spawner_name]),
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
				"pickup_definition" in spawner,
				"%s must expose a pickup Definition" % spawner_name,
				failures
			)
			if "pickup_definition" in spawner:
				_expect(
					spawner.pickup_definition != null
					and spawner.pickup_definition.resource_path == DEMO_PICKUP_DEFINITIONS[spawner_name],
					"%s must use the configured pickup Definition" % spawner_name,
					failures
				)
			_expect(
				spawner.current_pickup != null
				and spawner.current_pickup.scene_file_path == PICKUP_CHEST_SCENE_PATH,
				"%s must instantiate the shared PickupChest scene" % spawner_name,
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
