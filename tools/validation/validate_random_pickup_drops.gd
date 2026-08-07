extends SceneTree

const ZombieScene = preload("res://scenes/targets/ZombieTarget.tscn")
const PlayerScene = preload("res://scenes/player/Player.tscn")
const SpawnPointScene = preload("res://scenes/gameplay/PickupSpawnPoint.tscn")
const OilBarrelDefinition = preload(
	"res://resources/pickups/oil_barrel_pickup.tres"
)
const SmgAmmoDefinition = preload(
	"res://resources/pickups/smg_ammo_pickup.tres"
)
const SmgDefinition = preload("res://resources/pickups/smg_pickup.tres")
const DROP_MANAGER_SCENE_PATH := (
	"res://scenes/gameplay/RandomPickupDropManager.tscn"
)
const DemoArenaScene = preload("res://scenes/gameplay/DemoArena.tscn")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var camera := Camera3D.new()
	camera.current = true
	root.add_child(camera)
	await _test_zombie_emits_one_death_position(failures)
	await _test_one_shot_spawn_point_reclaims_after_success(failures)
	await _test_one_shot_spawn_point_survives_failed_claim(failures)
	await _test_random_drop_manager_probability_and_spawn_contract(failures)
	await _test_demo_routes_zombie_death_to_drop_manager(failures)
	camera.queue_free()
	await process_frame
	if failures.is_empty():
		print("validate_random_pickup_drops: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _test_zombie_emits_one_death_position(failures: Array[String]) -> void:
	var zombie := ZombieScene.instantiate() as ZombieTarget
	root.add_child(zombie)
	await process_frame
	_expect(
		zombie.has_signal(&"died"),
		"ZombieTarget must expose one death-position event",
		failures
	)
	if not zombie.has_signal(&"died"):
		zombie.queue_free()
		await process_frame
		return
	var death_positions: Array[Vector3] = []
	zombie.connect(
		&"died",
		func(position: Vector3) -> void: death_positions.append(position)
	)
	var expected_position := zombie.global_position
	zombie.apply_hit(
		zombie.max_health,
		expected_position + Vector3.UP,
		Vector3.FORWARD
	)
	zombie.apply_hit(1.0, expected_position, Vector3.FORWARD)
	_expect(
		death_positions.size() == 1,
		"one zombie death must emit exactly one drop opportunity",
		failures
	)
	if death_positions.size() == 1:
		_expect(
			death_positions[0].is_equal_approx(expected_position),
			"death event must carry the zombie world position",
			failures
		)
	if is_instance_valid(zombie):
		zombie.queue_free()
	await process_frame

func _test_one_shot_spawn_point_reclaims_after_success(
	failures: Array[String]
) -> void:
	var spawner = SpawnPointScene.instantiate()
	var player := PlayerScene.instantiate() as PlayerController
	_expect(
		"remove_after_collection" in spawner,
		"PickupSpawnPoint must support one-shot collection cleanup",
		failures
	)
	if not "remove_after_collection" in spawner:
		spawner.free()
		player.free()
		return
	spawner.pickup_definition = OilBarrelDefinition
	spawner.respawn_enabled = false
	spawner.remove_after_collection = true
	player.position = Vector3(100.0, 0.0, 100.0)
	var navigation_changes := [0]
	spawner.navigation_geometry_changed.connect(
		func() -> void: navigation_changes[0] += 1
	)
	root.add_child(player)
	root.add_child(spawner)
	await process_frame
	_expect(spawner.current_pickup != null, "one-shot spawner must create its pickup", failures)
	if spawner.current_pickup != null:
		spawner.current_pickup.claim_area.body_entered.emit(player)
	await process_frame
	await process_frame
	_expect(
		not is_instance_valid(spawner),
		"successful one-shot pickup must reclaim its spawn point",
		failures
	)
	_expect(
		navigation_changes[0] == 2,
		"one-shot pickup must notify navigation on insertion and removal",
		failures
	)
	if is_instance_valid(spawner):
		spawner.queue_free()
	player.queue_free()
	await process_frame

func _test_random_drop_manager_probability_and_spawn_contract(
	failures: Array[String]
) -> void:
	_expect(
		ResourceLoader.exists(DROP_MANAGER_SCENE_PATH),
		"random pickup drop manager scene must exist",
		failures
	)
	if not ResourceLoader.exists(DROP_MANAGER_SCENE_PATH):
		return
	var manager_scene := load(DROP_MANAGER_SCENE_PATH) as PackedScene
	var manager = manager_scene.instantiate()
	_expect(
		manager.get_script() != null,
		"random pickup drop manager scene must attach its manager script",
		failures
	)
	if manager.get_script() == null:
		manager.free()
		return
	_expect(
		manager.has_method(&"try_spawn_drop"),
		"random pickup drop manager must expose try_spawn_drop",
		failures
	)
	if not manager.has_method(&"try_spawn_drop"):
		manager.free()
		return
	_expect(
		manager.has_method(&"_passes_drop_chance"),
		"random pickup drop manager must expose deterministic chance evaluation",
		failures
	)
	if not manager.has_method(&"_passes_drop_chance"):
		manager.free()
		return
	_expect(
		is_equal_approx(manager.drop_chance, 0.2),
		"random pickup drop chance must default to 0.2",
		failures
	)
	manager.drop_chance = 0.0
	_expect(
		not manager._passes_drop_chance(0.0),
		"zero drop chance must reject a zero roll",
		failures
	)
	manager.drop_chance = 1.0
	_expect(
		manager._passes_drop_chance(1.0),
		"full drop chance must accept the inclusive 1.0 roll",
		failures
	)
	manager.drop_chance = 0.2
	_expect(
		not manager._passes_drop_chance(0.2),
		"a roll equal to a fractional drop chance must be rejected",
		failures
	)
	_expect(
		manager._passes_drop_chance(0.199),
		"a roll below a fractional drop chance must be accepted",
		failures
	)
	manager.random_seed = 4399
	var definitions: Array[PickupDefinition] = []
	definitions.append(SmgDefinition)
	definitions.append(SmgAmmoDefinition)
	definitions.append(OilBarrelDefinition)
	manager.pickup_definitions = definitions
	root.add_child(manager)
	await process_frame
	manager.drop_chance = 0.0
	_expect(
		manager.try_spawn_drop(Vector3.ONE) == null,
		"zero drop chance must never create a pickup",
		failures
	)
	manager.drop_chance = 1.0
	var expected_position := Vector3(4.0, 0.0, -3.0)
	var spawner = manager.try_spawn_drop(expected_position)
	_expect(spawner != null, "full drop chance must create a pickup", failures)
	if spawner != null:
		_expect(
			spawner.global_position.is_equal_approx(expected_position),
			"random pickup must spawn at the zombie death position",
			failures
		)
		_expect(
			spawner.remove_after_collection and not spawner.respawn_enabled,
			"random pickup spawn points must be one-shot without respawn",
			failures
		)
		_expect(
			manager.pickup_definitions.has(spawner.pickup_definition),
			"random pickup content must come from the configured Definition pool",
			failures
		)
	manager.queue_free()
	await process_frame

func _test_demo_routes_zombie_death_to_drop_manager(
	failures: Array[String]
) -> void:
	var arena := DemoArenaScene.instantiate()
	root.add_child(arena)
	await process_frame
	var manager = arena.get_node_or_null("World/Props/RandomPickupDrops")
	_expect(
		manager != null,
		"DemoArena must own a scene-level random pickup drop manager",
		failures
	)
	if manager == null:
		arena.queue_free()
		await process_frame
		return
	_expect(
		is_equal_approx(manager.drop_chance, 0.2) and
		manager.pickup_definitions.size() == 3,
		"DemoArena drop manager must use 20 percent and all three Definitions",
		failures
	)
	manager.drop_chance = 1.0
	var zombie: ZombieTarget
	for child in arena.get_node("World/Targets").get_children():
		if child is ZombieTarget:
			zombie = child as ZombieTarget
			break
	_expect(zombie != null, "DemoArena must spawn a zombie for drop wiring", failures)
	if zombie != null:
		var drop_count_before := manager.get_child_count()
		var death_position := Vector3(2.0, 0.0, -2.0)
		zombie.died.emit(death_position)
		_expect(
			manager.get_child_count() == drop_count_before + 1,
			"zombie death must request one random drop from the Demo manager",
			failures
		)
		var drop_spawner = manager.get_child(manager.get_child_count() - 1)
		_expect(
			drop_spawner.global_position.is_equal_approx(death_position),
			"Demo death wiring must preserve the zombie world position",
			failures
		)
	arena.queue_free()
	await process_frame

func _test_one_shot_spawn_point_survives_failed_claim(
	failures: Array[String]
) -> void:
	var spawner = SpawnPointScene.instantiate()
	var player := PlayerScene.instantiate() as PlayerController
	if not "remove_after_collection" in spawner:
		spawner.free()
		player.free()
		return
	spawner.pickup_definition = SmgAmmoDefinition
	spawner.respawn_enabled = false
	spawner.remove_after_collection = true
	player.position = Vector3(100.0, 0.0, 100.0)
	root.add_child(player)
	root.add_child(spawner)
	await process_frame
	var pickup = spawner.current_pickup
	_expect(pickup != null, "failed-claim fixture must create its pickup", failures)
	if pickup != null:
		pickup.claim_area.body_entered.emit(player)
	await process_frame
	_expect(
		is_instance_valid(spawner) and is_instance_valid(spawner.current_pickup),
		"failed pickup reward must keep the one-shot drop available",
		failures
	)
	if is_instance_valid(spawner):
		spawner.queue_free()
	player.queue_free()
	await process_frame

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
