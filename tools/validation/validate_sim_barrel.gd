extends SceneTree

## 爆炸桶模拟层的回归。守住：命中阈值与状态迁移、射线在油桶处终止、
## 爆炸真的伤到僵尸、连锁延时逐 tick 精确、引爆清掉阻挡格、
## 油桶状态真的进了帧哈希、以及同一场景重放逐 tick 哈希一致。
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const SimHasherScript = preload("res://scripts/sim/sim_hasher.gd")

const GRID_ORIGIN := Vector2(-24.5, -19.5)
const GRID_CELL_SIZE := 1.0
const GRID_WIDTH := 49
const GRID_HEIGHT := 39
const ROOM_SEED := 20260807
const PROFILE := 0
const SHOT_ORIGIN := Vector2(0.0, 0.0)
const MUZZLE_HEIGHT := 1.1
const AIM := Vector2(1.0, 0.0)
const BARREL_A := Vector2(5.0, 0.0)
const BARREL_B := Vector2(8.0, 0.0)
const CHAIN_DELAY_SECONDS := 0.12
const EXPECTED_CHAIN_TICKS := 3    # ceili(0.12 / 0.05)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_hit_thresholds(failures)
	_check_ray_stops_at_barrel(failures)
	_check_explosion_damages_zombies(failures)
	_check_chain_delay_is_tick_exact(failures)
	_check_blocker_cleared_on_detonation(failures)
	_check_barrel_state_is_hashed(failures)
	_check_replay_is_identical(failures)
	_finish(failures)

func _new_world() -> SimWorld:
	var world: SimWorld = SimWorldScript.new()
	world.configure(GRID_ORIGIN, GRID_CELL_SIZE, GRID_WIDTH, GRID_HEIGHT)
	world.reset(ROOM_SEED)
	# 无散布、无穿透的步枪档案：射向恒等于瞄准方向，命中序列可断言。
	world.configure_weapon_profile(PROFILE, 25.0, 30.0, 0.0, 0.0, 0.0, 0.0, 0, 0.0)
	return world

func _spawn_barrel(world: SimWorld, position: Vector2) -> int:
	return world.spawn_barrel(
		position,
		0.0,
		position - Vector2(0.44, 0.44),
		position + Vector2(0.44, 0.44),
		3,
		2,
		CHAIN_DELAY_SECONDS,
		4.5,
		80.0,
		20.0
	)

func _fire_once(world: SimWorld) -> void:
	world.queue_fire_event(0, PROFILE, SHOT_ORIGIN, MUZZLE_HEIGHT, AIM)
	world.step_tick()

func _check_hit_thresholds(failures: Array[String]) -> void:
	var world := _new_world()
	_spawn_barrel(world, BARREL_A)
	_fire_once(world)
	_expect(
		world.get_barrel_hit_count(0) == 1,
		"the first shot must register on the barrel",
		failures
	)
	_expect(
		world.get_barrel_state(0) == SimWorldScript.BARREL_STATE_INTACT,
		"one hit must not damage the barrel",
		failures
	)
	_fire_once(world)
	_expect(
		world.get_barrel_state(0) == SimWorldScript.BARREL_STATE_DAMAGED,
		"the second hit must enter the damaged state",
		failures
	)
	_expect(
		_count_events(world.tick_barrel_events, &"barrel_damaged") == 1,
		"entering the damaged state must emit exactly one presentation event",
		failures
	)
	_fire_once(world)
	_expect(
		world.get_barrel_state(0) == SimWorldScript.BARREL_STATE_DESTROYED,
		"the third hit must detonate the barrel",
		failures
	)
	_expect(
		_count_events(world.tick_barrel_events, &"barrel_exploded") == 1,
		"detonation must emit exactly one presentation event",
		failures
	)
	_fire_once(world)
	_expect(
		_count_events(world.tick_barrel_events, &"barrel_exploded") == 0,
		"a destroyed barrel must not detonate twice",
		failures
	)

func _check_ray_stops_at_barrel(failures: Array[String]) -> void:
	var world := _new_world()
	_spawn_barrel(world, BARREL_A)
	# 油桶正后方 2 m 的僵尸：基线的物理射线打中层 1 静态体后 break，
	# 模拟层必须给出同样的结论。
	world.spawn_zombie(Vector2(7.0, 0.0), 0.0, 50.0)
	var full_health := world.get_zombie_health(0)
	_fire_once(world)
	_expect(
		world.get_barrel_hit_count(0) == 1,
		"the shot must land on the barrel that stands in front",
		failures
	)
	_expect(
		world.get_zombie_health(0) == full_health,
		"a zombie behind a barrel must not take bullet damage",
		failures
	)
	var shot_events := world.tick_shot_events
	_expect(shot_events.size() == 1, "one shot must produce one shot event", failures)
	if shot_events.size() == 1:
		_expect(
			bool(shot_events[0]["did_hit"]),
			"hitting a barrel must report did_hit (baseline returns HitResult.resolved)",
			failures
		)
		_expect(
			StringName(shot_events[0]["zone"]) == &"barrel",
			"a barrel hit must report the barrel hit zone",
			failures
		)

func _check_explosion_damages_zombies(failures: Array[String]) -> void:
	var world := _new_world()
	_spawn_barrel(world, BARREL_A)
	world.spawn_zombie(BARREL_A + Vector2(0.0, 2.0), 0.0, 50.0)
	var full_health := world.get_zombie_health(0)
	_fire_once(world)
	_fire_once(world)
	_fire_once(world)
	_expect(
		world.get_zombie_count() == 0 or world.get_zombie_health(0) < full_health,
		"a zombie inside the blast radius must take explosion damage",
		failures
	)

func _check_chain_delay_is_tick_exact(failures: Array[String]) -> void:
	var world := _new_world()
	_spawn_barrel(world, BARREL_A)
	_spawn_barrel(world, BARREL_B)
	_fire_once(world)
	_fire_once(world)
	_fire_once(world)
	var detonation_tick := world.get_tick()
	_expect(
		world.get_barrel_state(0) == SimWorldScript.BARREL_STATE_DESTROYED,
		"the shot barrel must detonate",
		failures
	)
	_expect(
		world.get_barrel_state(1) == SimWorldScript.BARREL_STATE_PENDING,
		"a barrel in range must only get a fuse, never detonate in the same tick",
		failures
	)
	_expect(
		world.get_barrel_fuse_ticks(1) == EXPECTED_CHAIN_TICKS,
		"the fuse must be ceili(chain_delay_seconds / TICK_SECONDS) ticks",
		failures
	)
	var chain_tick := -1
	for _step in range(EXPECTED_CHAIN_TICKS + 4):
		world.step_tick()
		if (
			chain_tick < 0 and
			world.get_barrel_state(1) == SimWorldScript.BARREL_STATE_DESTROYED
		):
			chain_tick = world.get_tick()
	_expect(
		chain_tick - detonation_tick == EXPECTED_CHAIN_TICKS,
		"the chained barrel must detonate exactly %d ticks later (got %d)" % [
			EXPECTED_CHAIN_TICKS, chain_tick - detonation_tick
		],
		failures
	)

func _check_blocker_cleared_on_detonation(failures: Array[String]) -> void:
	var world := _new_world()
	_spawn_barrel(world, BARREL_A)
	var grid := world.get_grid()
	var cell := grid.world_to_cell(BARREL_A)
	_expect(grid.is_blocked(cell), "a registered barrel must block its cell", failures)
	_fire_once(world)
	_fire_once(world)
	_fire_once(world)
	_expect(
		not grid.is_blocked(cell),
		"detonation must clear the cells the barrel occupied",
		failures
	)

## 负向对照。刻意用 apply_barrel_hit() 而不是 _fire_once()：
## 开火会消耗 Stream.WEAPON_SPREAD，RNG 的 state 本身就进了哈希，
## 那样即使油桶完全没进哈希这条断言也会绿——等于什么都没测。
## 直接打一发（只改 barrel_hit_count、不改状态、不碰 RNG）才真的在测油桶字段。
func _check_barrel_state_is_hashed(failures: Array[String]) -> void:
	var untouched := _new_world()
	_spawn_barrel(untouched, BARREL_A)
	untouched.step_tick()
	var hit_once := _new_world()
	_spawn_barrel(hit_once, BARREL_A)
	hit_once.apply_barrel_hit(0)
	hit_once.step_tick()
	_expect(
		hit_once.get_barrel_state(0) == SimWorldScript.BARREL_STATE_INTACT,
		"one hit must leave the barrel intact, so only barrel_hit_count differs",
		failures
	)
	_expect(
		SimHasherScript.hash_world(untouched) != SimHasherScript.hash_world(hit_once),
		"a barrel hit must change the frame hash, otherwise barrel desync is invisible",
		failures
	)

func _check_replay_is_identical(failures: Array[String]) -> void:
	var first := _run_chain_scenario()
	var second := _run_chain_scenario()
	_expect(
		first == second,
		"replaying the same barrel scenario must produce the same hash sequence",
		failures
	)

func _run_chain_scenario() -> PackedStringArray:
	var world := _new_world()
	_spawn_barrel(world, BARREL_A)
	_spawn_barrel(world, BARREL_B)
	world.spawn_zombie(Vector2(6.0, 1.0), 0.0, 50.0)
	world.spawn_zombie(Vector2(9.0, -1.0), 0.0, 50.0)
	world.set_player_snapshot(0, Vector2(-6.0, 0.0), true, true)
	var hashes := PackedStringArray()
	for tick in range(24):
		if tick < 3:
			world.queue_fire_event(0, PROFILE, SHOT_ORIGIN, MUZZLE_HEIGHT, AIM)
		world.step_tick()
		hashes.append(SimHasherScript.hash_world(world))
	return hashes

func _count_events(events: Array, kind: StringName) -> int:
	var total := 0
	for event in events:
		if StringName(event["kind"]) == kind:
			total += 1
	return total

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_sim_barrel: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
