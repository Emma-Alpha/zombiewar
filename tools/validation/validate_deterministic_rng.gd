extends SceneTree

const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")

# PCG32-XSH-RR 已知向量（room_seed = 12345）
const SEED_12345_STREAM_0: Array[int] = [3165192603, 3360792183, 2433038347, 628889468]
const SEED_12345_STREAM_1: Array[int] = [3744665246, 682428536, 3931205900, 2624254912]
const SEED_12345_STREAM_2: Array[int] = [119260362, 2490054067]
const SEED_12345_STREAM_3: Array[int] = [318996717, 4017299320]
const SEED_1_STREAM_0: Array[int] = [1791099446, 124312908, 1968572995, 1080415314]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_known_vectors(failures)
	_check_stream_independence(failures)
	_check_reseed_reproducibility(failures)
	_check_value_ranges(failures)
	_check_clock(failures)
	_finish(failures)

func _check_known_vectors(failures: Array[String]) -> void:
	var expected := {
		DeterministicRngScript.Stream.ZOMBIE_WANDER: SEED_12345_STREAM_0,
		DeterministicRngScript.Stream.ZOMBIE_SPAWN: SEED_12345_STREAM_1,
		DeterministicRngScript.Stream.WEAPON_SPREAD: SEED_12345_STREAM_2,
		DeterministicRngScript.Stream.LOOT_DROP: SEED_12345_STREAM_3,
	}
	for stream_index in expected.keys():
		var rng = DeterministicRngScript.new()
		rng.seed_streams(12345)
		var vector: Array = expected[stream_index]
		for draw_index in range(vector.size()):
			var value: int = rng.next_uint32(stream_index)
			_expect(
				value == vector[draw_index],
				"stream %d draw %d must be %d, got %d" % [
					stream_index, draw_index, vector[draw_index], value
				],
				failures
			)
	var seeded_one = DeterministicRngScript.new()
	seeded_one.seed_streams(1)
	for draw_index in range(SEED_1_STREAM_0.size()):
		var value: int = seeded_one.next_uint32(
			DeterministicRngScript.Stream.ZOMBIE_WANDER
		)
		_expect(
			value == SEED_1_STREAM_0[draw_index],
			"seed 1 stream 0 draw %d must be %d, got %d" % [
				draw_index, SEED_1_STREAM_0[draw_index], value
			],
			failures
		)

func _check_stream_independence(failures: Array[String]) -> void:
	var baseline = DeterministicRngScript.new()
	baseline.seed_streams(12345)
	var first := baseline.next_uint32(DeterministicRngScript.Stream.ZOMBIE_WANDER)
	var second := baseline.next_uint32(DeterministicRngScript.Stream.ZOMBIE_WANDER)

	var interleaved = DeterministicRngScript.new()
	interleaved.seed_streams(12345)
	var interleaved_first := interleaved.next_uint32(
		DeterministicRngScript.Stream.ZOMBIE_WANDER
	)
	interleaved.next_uint32(DeterministicRngScript.Stream.ZOMBIE_SPAWN)
	interleaved.next_uint32(DeterministicRngScript.Stream.WEAPON_SPREAD)
	interleaved.next_uint32(DeterministicRngScript.Stream.LOOT_DROP)
	var interleaved_second := interleaved.next_uint32(
		DeterministicRngScript.Stream.ZOMBIE_WANDER
	)
	_expect(
		interleaved_first == first and interleaved_second == second,
		"drawing from other streams must not move ZOMBIE_WANDER",
		failures
	)
	var seeded = DeterministicRngScript.new()
	seeded.seed_streams(12345)
	var distinct: Dictionary = {}
	for stream_index in range(DeterministicRngScript.STREAM_COUNT):
		distinct[seeded.next_uint32(stream_index)] = true
	_expect(
		distinct.size() == DeterministicRngScript.STREAM_COUNT,
		"each stream must start from a distinct derived state",
		failures
	)

func _check_reseed_reproducibility(failures: Array[String]) -> void:
	var first_run: Array[int] = []
	var second_run: Array[int] = []
	var rng = DeterministicRngScript.new()
	rng.seed_streams(987654321)
	for draw_index in range(64):
		first_run.append(
			rng.next_uint32(draw_index % DeterministicRngScript.STREAM_COUNT)
		)
	rng.seed_streams(987654321)
	for draw_index in range(64):
		second_run.append(
			rng.next_uint32(draw_index % DeterministicRngScript.STREAM_COUNT)
		)
	_expect(first_run == second_run, "reseeding must reproduce the same sequence", failures)
	var state_words := rng.get_state_words()
	_expect(
		state_words.size() == DeterministicRngScript.STREAM_COUNT * 2,
		"state words must expose low and high halves for every stream",
		failures
	)

func _check_value_ranges(failures: Array[String]) -> void:
	var rng = DeterministicRngScript.new()
	rng.seed_streams(4242)
	var minimum_float := 2.0
	var maximum_float := -1.0
	for _draw_index in range(4096):
		var unit := rng.next_unit_float(DeterministicRngScript.Stream.WEAPON_SPREAD)
		minimum_float = minf(minimum_float, unit)
		maximum_float = maxf(maximum_float, unit)
		var ranged := rng.next_range(
			DeterministicRngScript.Stream.WEAPON_SPREAD, -1.0, 1.0
		)
		_expect(ranged >= -1.0 and ranged < 1.0, "next_range must stay inside bounds", failures)
		var integer := rng.next_int_range(
			DeterministicRngScript.Stream.ZOMBIE_SPAWN, 3, 7
		)
		_expect(integer >= 3 and integer <= 7, "next_int_range must be inclusive", failures)
	_expect(minimum_float >= 0.0, "next_unit_float must not go below 0.0", failures)
	_expect(maximum_float < 1.0, "next_unit_float must stay below 1.0", failures)

func _check_clock(failures: Array[String]) -> void:
	_expect(
		SimClockScript.TICK_SECONDS == 0.05,
		"SimClock.TICK_SECONDS must be 0.05",
		failures
	)
	_expect(
		SimClockScript.MAX_CATCHUP_TICKS == 5,
		"SimClock.MAX_CATCHUP_TICKS must be 5",
		failures
	)
	var clock = SimClockScript.new()
	var single_total := 0
	for _frame_index in range(600):
		single_total += clock.consume_frame(0.05)
	_expect(single_total == 600, "feeding 0.05 per frame must yield one tick per frame", failures)
	_expect(clock.get_tick_index() == 600, "tick index must equal consumed ticks", failures)

	var batched = SimClockScript.new()
	var batched_total := 0
	for _frame_index in range(120):
		batched_total += batched.consume_frame(0.25)
	_expect(batched_total == 600, "feeding 0.25 per frame must yield five ticks per frame", failures)

	var starved = SimClockScript.new()
	_expect(
		starved.consume_frame(2.0) == SimClockScript.MAX_CATCHUP_TICKS,
		"a long stall must be clamped to MAX_CATCHUP_TICKS",
		failures
	)
	_expect(
		starved.consume_frame(0.0) == 0,
		"the dropped backlog must not resurface on the next frame",
		failures
	)
	starved.reset()
	_expect(
		starved.get_tick_index() == 0 and starved.get_interpolation_alpha() == 0.0,
		"reset must clear both the tick index and the accumulator",
		failures
	)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_deterministic_rng: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
