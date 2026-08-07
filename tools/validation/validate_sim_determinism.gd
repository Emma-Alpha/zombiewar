extends SceneTree

const SimClockScript = preload("res://scripts/sim/sim_clock.gd")
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const SimHasherScript = preload("res://scripts/sim/sim_hasher.gd")
const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")

const TICK_COUNT := 3000
const ZOMBIE_COUNT := 300
const ROOM_SEED := 20260807
const INPUT_SEED := 555
const GRID_ORIGIN := Vector2(-24.5, -19.5)
const GRID_CELL_SIZE := 1.0
const GRID_WIDTH := 49
const GRID_HEIGHT := 39
const PLAYER_SLOT_COUNT := 4
const SHOT_INTERVAL_TICKS := 25
const MUZZLE_HEIGHT := 1.1

# 与 DemoArena 一致的静态阻挡近似：四面边界墙 + 两个集装箱 + 一段路障。
const BLOCKER_RECTS: Array[Rect2] = [
	Rect2(Vector2(-24.5, -19.5), Vector2(49.0, 1.0)),
	Rect2(Vector2(-24.5, 18.5), Vector2(49.0, 1.0)),
	Rect2(Vector2(-24.5, -19.5), Vector2(1.0, 39.0)),
	Rect2(Vector2(23.5, -19.5), Vector2(1.0, 39.0)),
	Rect2(Vector2(-14.1, -12.05), Vector2(6.2, 2.5)),
	Rect2(Vector2(7.9, 5.75), Vector2(6.2, 2.5)),
	Rect2(Vector2(-6.0, -2.0), Vector2(12.0, 1.0)),
]

# 与 resources/weapons/rifle.tres 一致
const RIFLE_PROFILE := 0
const RIFLE_DAMAGE := 25.0
const RIFLE_RANGE := 28.0
const RIFLE_BASE_SPREAD := 0.5
const RIFLE_MAX_SPREAD := 5.0
const RIFLE_SPREAD_INCREASE := 0.65
const RIFLE_SPREAD_RECOVERY := 1.5

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var table := _build_input_table(TICK_COUNT)

	var first_pass := _run_scenario(table, 0.05)
	_expect(
		first_pass.size() == TICK_COUNT,
		"a full pass must produce one hash per tick (got %d)" % first_pass.size(),
		failures
	)
	var second_pass := _run_scenario(table, 0.05)
	_compare("second identical run", first_pass, second_pass, failures)

	var batched_pass := _run_scenario(table, 0.25)
	_compare("five ticks per frame", first_pass, batched_pass, failures)

	_expect(
		first_pass[0] != first_pass[TICK_COUNT - 1],
		"the hash must actually change as the world advances",
		failures
	)
	print("validate_sim_determinism: %d ticks, final hash %s" % [
		TICK_COUNT, first_pass[TICK_COUNT - 1]
	])
	_finish(failures)

## 输入表只与 tick 序号有关，用一个独立的 DeterministicRng 实例生成，
## 不触碰 SimWorld 自身的四条流。
func _build_input_table(tick_count: int) -> Array:
	var input_rng = DeterministicRngScript.new()
	input_rng.seed_streams(INPUT_SEED)
	var table: Array = []
	for tick in range(tick_count):
		var players := PackedVector2Array()
		for slot in range(PLAYER_SLOT_COUNT):
			var phase := float(tick) * 0.03 + float(slot) * 1.5707963
			players.append(Vector2(
				cos(phase) * 6.0 + float(slot) - 1.5,
				sin(phase) * 4.0 + 2.0
			))
		table.append({
			"players": players,
			"fire": tick % SHOT_INTERVAL_TICKS == 0,
			"aim": Vector2(
				input_rng.next_range(DeterministicRngScript.Stream.ZOMBIE_WANDER, -1.0, 1.0),
				input_rng.next_range(DeterministicRngScript.Stream.ZOMBIE_WANDER, -1.0, 1.0)
			),
		})
	return table

func _run_scenario(table: Array, frame_delta: float) -> PackedStringArray:
	var clock = SimClockScript.new()
	var world = SimWorldScript.new()
	world.configure(GRID_ORIGIN, GRID_CELL_SIZE, GRID_WIDTH, GRID_HEIGHT)
	for rect in BLOCKER_RECTS:
		world.set_blocker_world_rect(rect.position, rect.end, true)
	world.reset(ROOM_SEED)
	world.set_default_move_speed(1.30)
	world.set_perception_range(60.0)   # 与 DemoArena.wave_perception_range 的默认值一致
	world.configure_weapon_profile(
		RIFLE_PROFILE,
		RIFLE_DAMAGE,
		RIFLE_RANGE,
		RIFLE_BASE_SPREAD,
		RIFLE_MAX_SPREAD,
		RIFLE_SPREAD_INCREASE,
		RIFLE_SPREAD_RECOVERY,
		0,
		0.0
	)
	var per_corner := ZOMBIE_COUNT / 4
	world.queue_spawn_wave(
		PackedVector2Array([
			Vector2(-19.0, -14.0),
			Vector2(19.0, -14.0),
			Vector2(-19.0, 14.0),
			Vector2(19.0, 14.0),
		]),
		per_corner,
		per_corner,
		ZOMBIE_COUNT,
		6.0,
		0.9,
		50.0
	)
	var hashes := PackedStringArray()
	var applied := 0
	while applied < table.size():
		var ticks := clock.consume_frame(frame_delta)
		if ticks <= 0:
			continue
		for _tick_offset in range(ticks):
			if applied >= table.size():
				break
			var entry: Dictionary = table[applied]
			var players: PackedVector2Array = entry["players"]
			for slot in range(PLAYER_SLOT_COUNT):
				world.set_player_snapshot(slot, players[slot], true, true)
			if entry["fire"]:
				world.queue_fire_event(
					0, RIFLE_PROFILE, players[0], MUZZLE_HEIGHT, entry["aim"]
				)
			world.step_tick()
			hashes.append(SimHasherScript.hash_world(world))
			applied += 1
	return hashes

func _compare(
	label: String,
	expected: PackedStringArray,
	actual: PackedStringArray,
	failures: Array[String]
) -> void:
	if expected == actual:
		return
	if expected.size() != actual.size():
		failures.append(
			"%s produced %d hashes, expected %d" % [label, actual.size(), expected.size()]
		)
		return
	for index in range(expected.size()):
		if expected[index] != actual[index]:
			failures.append(
				"%s diverged at tick %d: %s vs %s" % [
					label, index + 1, expected[index], actual[index]
				]
			)
			return

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_sim_determinism: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
