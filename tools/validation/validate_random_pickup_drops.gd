extends SceneTree

const ZombieScene = preload("res://scenes/targets/ZombieTarget.tscn")
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
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

## 掉落机会现在由模拟层的击杀事件给出，而不是僵尸节点的 died 信号。
## 换接缝的理由不是好看：近景视图是池化的，远处的僵尸压根没有节点，
## 挂节点信号会让视野外的击杀一个都不掉东西——而尸潮里绝大多数击杀都在视野外。
## 这里守的仍是同一条不变量：一次死亡恰好给出一次掉落机会。
func _test_zombie_emits_one_death_position(failures: Array[String]) -> void:
	var world = SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(20260810)
	var expected_position := Vector2(2.0, -2.0)
	world.spawn_zombie(expected_position, 0.0, 50.0)
	world.step_tick()

	# 连打三次，只扫一次事件表：tick_hit_events 要到下一个 step_tick() 才清空，
	# 在循环里边打边扫会把同一条击杀事件重复计进去，于是一条「补刀不该再掉一次」
	# 的断言反而会被测试自己的重复计数弄假。
	for _attempt in range(3):
		world.apply_zombie_damage(
			0, 100 * 100, expected_position, 1.0, Vector2.RIGHT, &"body"
		)
	var kill_events: Array = []
	for event in world.tick_hit_events:
		if bool(event.get("killed", false)):
			kill_events.append(event)
	_expect(
		kill_events.size() == 1,
		"one zombie death must emit exactly one drop opportunity",
		failures
	)
	if kill_events.size() == 1:
		var reported: Vector2 = kill_events[0]["position"]
		_expect(
			reported.is_equal_approx(expected_position),
			"death event must carry the zombie world position",
			failures
		)

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
	# 打模拟层的击杀事件，而不是某个僵尸节点：竞技场就是从这里接掉落的，
	# 而视野外的击杀根本没有对应的节点可打。
	var drop_count_before := manager.get_child_count()
	var death_position := Vector3(2.0, 0.0, -2.0)
	arena._on_sim_hit_event({
		"zombie_id": 1,
		"position": Vector2(death_position.x, death_position.z),
		"height": 1.0,
		"direction": Vector2.RIGHT,
		"damage": 50.0,
		"zone": &"body",
		"killed": true,
	})
	_expect(
		manager.get_child_count() == drop_count_before + 1,
		"zombie death must request one random drop from the Demo manager",
		failures
	)
	if manager.get_child_count() > drop_count_before:
		var drop_spawner = manager.get_child(manager.get_child_count() - 1)
		_expect(
			drop_spawner.global_position.is_equal_approx(death_position),
			"Demo death wiring must preserve the zombie world position",
			failures
		)
		# 掉落出来的箱子也是阻挡几何，没接上标脏就会在被捡走后留下一格永久墙。
		_expect(
			drop_spawner.blocker_changed.is_connected(arena._on_pickup_blocker_changed),
			"dropped pickup must be wired into the flow field blocker dirtying",
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
