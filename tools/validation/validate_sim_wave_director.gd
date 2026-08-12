extends SceneTree

const SimHasherScript = preload("res://scripts/sim/sim_hasher.gd")
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const SIM_WAVE_DIRECTOR_PATH := "res://scripts/sim/sim_wave_director.gd"

const ROOM_SEED := 20260811
const GRID_ORIGIN := Vector2(-12.5, -12.5)
const GRID_SIZE := 25
const NORMAL_PROFILE := 0
const ELITE_PROFILE := 1

var sim_wave_director_script: GDScript

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	sim_wave_director_script = load(SIM_WAVE_DIRECTOR_PATH) as GDScript
	if sim_wave_director_script == null:
		failures.append("sim_wave_director.gd must exist")
		_finish(failures)
		return
	_check_interval_zero_order(failures)
	_check_wave_started_events(failures)
	_check_positive_interval_and_advance_guard(failures)
	_check_active_cap_backpressure(failures)
	_check_complete_emits_once(failures)
	_check_loop_delay_and_profile_values(failures)
	_check_blocked_samples_fall_back_to_clear_center(failures)
	_check_new_spawn_does_not_push_existing_zombie(failures)
	_check_wave_state_hashing(failures)
	_check_pending_spawn_request_hashing(failures)
	_finish(failures)

func _check_wave_started_events(failures: Array[String]) -> void:
	var world := _new_world()
	world.configure_wave_schedule(
		[_one_zombie_wave(NORMAL_PROFILE)],
		_default_points(),
		sim_wave_director_script.EndMode.LOOP,
		0,
		300
	)
	world.start_wave_schedule()
	world.step_tick()
	var started := _first_wave_event(world, &"wave_started")
	_expect(not started.is_empty(), "first wave must emit wave_started", failures)
	_expect(int(started.get("wave_number", -1)) == 1, "first wave number must be one", failures)
	world.step_tick()
	_expect(
		_count_wave_events(world, &"wave_started") == 0,
		"wave_started must not repeat while waiting for clear",
		failures
	)
	_kill_all(world)
	world.step_tick()
	world.step_tick()
	started = _first_wave_event(world, &"wave_started")
	_expect(not started.is_empty(), "loop restart must emit wave_started", failures)
	_expect(int(started.get("wave_number", -1)) == 2, "loop wave number must increase", failures)

func _check_interval_zero_order(failures: Array[String]) -> void:
	var world := _new_world()
	var waves: Array[Dictionary] = [{
		"spawn_interval_ticks": 0,
		"entries": [
			{"profile_index": NORMAL_PROFILE, "count": 2},
			{"profile_index": ELITE_PROFILE, "count": 1},
		],
	}]
	var points: Array[Dictionary] = [
		{"spawn_id": &"west", "position": Vector2(-10, 0), "radius": 0.0, "spacing": 0.0},
		{"spawn_id": &"east", "position": Vector2(10, 0), "radius": 0.0, "spacing": 0.0},
	]
	world.configure_wave_schedule(
		waves, points, sim_wave_director_script.EndMode.LOOP, 2, 300
	)
	world.start_wave_schedule()
	world.step_tick()
	_expect(world.get_zombie_count() == 3, "interval zero must spawn full wave", failures)
	_expect(world.get_zombie_profile_index(0) == 0, "entry order normal 1", failures)
	_expect(world.get_zombie_profile_index(1) == 0, "entry order normal 2", failures)
	_expect(world.get_zombie_profile_index(2) == 1, "entry order elite", failures)
	_expect(
		world.get_zombie_position(0) == Vector2(10, 0),
		"first sorted point (got %s)" % world.get_zombie_position(0),
		failures
	)
	_expect(
		world.get_zombie_position(1) == Vector2(-10, 0),
		"round robin point (got %s)" % world.get_zombie_position(1),
		failures
	)

func _check_positive_interval_and_advance_guard(failures: Array[String]) -> void:
	var world := _new_world()
	world.configure_wave_schedule(
		[{
			"spawn_interval_ticks": 3,
			"entries": [{"profile_index": NORMAL_PROFILE, "count": 2}],
		}],
		_default_points(),
		sim_wave_director_script.EndMode.LOOP,
		5,
		300
	)
	world.start_wave_schedule()
	var spawn_ticks := PackedInt32Array()
	for _step in range(4):
		world.step_tick()
		if not world.tick_spawn_events.is_empty():
			spawn_ticks.append(world.get_tick())
		if world.get_tick() == 1:
			_expect(
				not world.can_advance_wave(),
				"advance must be unavailable while spawning",
				failures
			)
			world.request_advance_wave()
	_expect(spawn_ticks == PackedInt32Array([1, 4]), "spawn ticks must be exactly 3 apart", failures)
	_expect(
		not world.can_advance_wave(),
		"advance must be unavailable while waiting for the current wave to clear",
		failures
	)
	world.request_advance_wave()
	world.step_tick()
	_expect(
		world.tick_spawn_events.is_empty() and world.get_zombie_count() == 2,
		"advance request must not stack a wave while waiting for clear",
		failures
	)

	_kill_all(world)
	world.step_tick()
	world.step_tick()
	_expect(world.can_advance_wave(), "advance must be available in intermission", failures)
	world.request_advance_wave()
	world.step_tick()
	_expect(
		world.tick_spawn_events.size() == 1,
		"advance request must skip only the current intermission",
		failures
	)

func _check_active_cap_backpressure(failures: Array[String]) -> void:
	var world := _new_world()
	world.configure_wave_schedule(
		[{
			"spawn_interval_ticks": 0,
			"entries": [{"profile_index": NORMAL_PROFILE, "count": 3}],
		}],
		_default_points(),
		sim_wave_director_script.EndMode.COMPLETE,
		0,
		2
	)
	world.start_wave_schedule()
	world.step_tick()
	_expect(world.get_zombie_count() == 2, "active cap must stop the current wave at two", failures)
	world.apply_zombie_damage(
		0, 999999, world.get_zombie_position(0), 0.0, Vector2.RIGHT, &"body"
	)
	world.step_tick()
	_expect(world.get_zombie_count() == 1, "dead zombie must compact before capacity reopens", failures)
	world.step_tick()
	_expect(
		world.get_zombie_count() == 2 and world.tick_spawn_events.size() == 1,
		"unspawned count must resume when one active slot reopens",
		failures
	)

func _check_complete_emits_once(failures: Array[String]) -> void:
	var world := _new_world()
	world.configure_wave_schedule(
		[_one_zombie_wave(NORMAL_PROFILE)],
		_default_points(),
		sim_wave_director_script.EndMode.COMPLETE,
		2,
		300
	)
	world.start_wave_schedule()
	world.step_tick()
	_kill_all(world)
	world.step_tick()
	var completed_events := 0
	for _step in range(10):
		world.step_tick()
		completed_events += _count_wave_events(world, &"map_completed")
	_expect(completed_events == 1, "COMPLETE must emit map_completed exactly once", failures)
	_expect(
		world.get_wave_state_words()[0] == sim_wave_director_script.State.COMPLETE,
		"final cleared wave must remain COMPLETE",
		failures
	)

func _check_loop_delay_and_profile_values(failures: Array[String]) -> void:
	var world := _new_world()
	world.configure_zombie_profile(NORMAL_PROFILE, 10, 1.25)
	world.configure_zombie_profile(ELITE_PROFILE, 30, 0.75)
	world.configure_wave_schedule(
		[{
			"spawn_interval_ticks": 0,
			"entries": [
				{"profile_index": NORMAL_PROFILE, "count": 2},
				{"profile_index": ELITE_PROFILE, "count": 1},
			],
		}],
		_default_points(),
		sim_wave_director_script.EndMode.LOOP,
		2,
		300
	)
	world.start_wave_schedule()
	for cycle in range(2):
		var wait_ticks := 0
		while world.get_zombie_count() == 0 and wait_ticks < 10:
			world.step_tick()
			wait_ticks += 1
		_expect(
			world.get_zombie_count() == 3,
			"LOOP cycle %d must preserve the authored count" % (cycle + 1),
			failures
		)
		var profile_indices := PackedInt32Array()
		var max_health := PackedInt32Array()
		var move_speeds := PackedFloat32Array()
		for index in range(world.get_zombie_count()):
			profile_indices.append(world.get_zombie_profile_index(index))
			max_health.append(world.get_zombie_max_health(index))
			move_speeds.append(world.zombie_move_speed[index])
		_expect(
			profile_indices == PackedInt32Array([0, 0, 1]),
			"LOOP cycle %d must preserve profile counts and order" % (cycle + 1),
			failures
		)
		_expect(
			max_health == PackedInt32Array([1000, 1000, 3000]),
			"LOOP cycle %d must not enhance profile health" % (cycle + 1),
			failures
		)
		_expect(
			move_speeds == PackedFloat32Array([1.25, 1.25, 0.75]),
			"LOOP cycle %d must not enhance profile speed" % (cycle + 1),
			failures
		)
		_kill_all(world)
		world.step_tick()

func _check_blocked_samples_fall_back_to_clear_center(failures: Array[String]) -> void:
	var world := _new_world()
	var center := Vector2.ZERO
	var center_cell := world.get_grid().world_to_cell(center)
	for cell_z in range(GRID_SIZE):
		for cell_x in range(GRID_SIZE):
			world.get_grid().set_blocked(Vector2i(cell_x, cell_z), true)
	world.get_grid().set_blocked(center_cell, false)
	world.configure_wave_schedule(
		[_one_zombie_wave(NORMAL_PROFILE)],
		[{
			"spawn_id": &"only",
			"position": center,
			"radius": 100.0,
			"spacing": 0.0,
		}],
		sim_wave_director_script.EndMode.COMPLETE,
		0,
		300
	)
	world.start_wave_schedule()
	world.step_tick()
	_expect(world.get_zombie_count() == 1, "a validated clear center must preserve exact count", failures)
	_expect(
		world.get_zombie_position(0) == center,
		"sixteen blocked samples may fall back only to the clear center (got %s)"
			% world.get_zombie_position(0),
		failures
	)
	_expect(
		not world.get_grid().is_blocked(world.get_grid().world_to_cell(world.get_zombie_position(0))),
		"spawned zombie must never occupy a blocked cell",
		failures
	)

func _check_wave_state_hashing(failures: Array[String]) -> void:
	var idle_world := _new_world()
	var started_world := _new_world()
	var waves: Array[Dictionary] = [_one_zombie_wave(NORMAL_PROFILE)]
	var points := _default_points()
	for world in [idle_world, started_world]:
		world.configure_wave_schedule(
			waves,
			points,
			sim_wave_director_script.EndMode.COMPLETE,
			0,
			300
		)
	started_world.start_wave_schedule()
	_expect(
		started_world.get_wave_state_words().size() == 10,
		"wave hash state must expose all ten public state words",
		failures
	)
	_expect(
		SimHasherScript.hash_world(idle_world) != SimHasherScript.hash_world(started_world),
		"wave state must affect the frame hash before entities differ",
		failures
	)

func _check_pending_spawn_request_hashing(failures: Array[String]) -> void:
	var world := _new_world()
	var requests: Array[Dictionary] = [
		{
			"profile_index": NORMAL_PROFILE,
			"center": Vector2(1.25, -2.5),
			"radius": 3.5,
			"minimum_spacing": 0.9,
		},
		{
			"profile_index": ELITE_PROFILE,
			"center": Vector2(-4.0, 5.5),
			"radius": 1.75,
			"minimum_spacing": 1.2,
		},
	]
	world.pending_spawn_requests = requests.duplicate(true)
	var baseline := SimHasherScript.hash_world(world)
	for mutation in [
		["profile index", "profile_index", ELITE_PROFILE],
		["center", "center", Vector2(1.5, -2.5)],
		["radius", "radius", 4.0],
		["minimum spacing", "minimum_spacing", 1.0],
	]:
		var mutated_requests := requests.duplicate(true)
		mutated_requests[0][mutation[1]] = mutation[2]
		world.pending_spawn_requests = mutated_requests
		_expect(
			SimHasherScript.hash_world(world) != baseline,
			"SimHasher must include pending spawn request %s" % mutation[0],
			failures
		)
	world.pending_spawn_requests = [requests[0].duplicate(true)]
	_expect(
		SimHasherScript.hash_world(world) != baseline,
		"SimHasher must include pending spawn queue size",
		failures
	)
	world.pending_spawn_requests = [
		requests[1].duplicate(true),
		requests[0].duplicate(true),
	]
	_expect(
		SimHasherScript.hash_world(world) != baseline,
		"SimHasher must preserve pending spawn queue order",
		failures
	)
func _check_new_spawn_does_not_push_existing_zombie(
	failures: Array[String]
) -> void:
	var world := _new_world()
	var center := Vector2.ZERO
	world.spawn_zombie(center, 0.0, NORMAL_PROFILE)
	# 旧实体保持静止，以便断言只观察 separation 的影响。
	world.zombie_hit_stun_ticks[0] = 2
	world.configure_wave_schedule(
		[_one_zombie_wave(NORMAL_PROFILE)],
		_default_points(),
		sim_wave_director_script.EndMode.COMPLETE,
		0,
		300
	)
	world.start_wave_schedule()
	world.step_tick()
	_expect(world.get_zombie_count() == 2, "overlap scenario must spawn the new zombie", failures)
	_expect(
		world.get_zombie_position(0) == center,
		"a same-tick spawn must not push an existing zombie (got %s)"
			% world.get_zombie_position(0),
		failures
	)
	_expect(
		world.get_zombie_position(1) == center,
		"the new zombie must retain its exact spawn center",
		failures
	)

func _new_world() -> SimWorld:
	var world: SimWorld = SimWorldScript.new()
	world.configure(GRID_ORIGIN, 1.0, GRID_SIZE, GRID_SIZE)
	world.reset(ROOM_SEED)
	world.configure_zombie_profile(NORMAL_PROFILE, 10, 0.0)
	world.configure_zombie_profile(ELITE_PROFILE, 30, 0.0)
	return world

func _default_points() -> Array[Dictionary]:
	return [{
		"spawn_id": &"center",
		"position": Vector2.ZERO,
		"radius": 0.0,
		"spacing": 0.0,
	}]

func _one_zombie_wave(profile_index: int) -> Dictionary:
	return {
		"spawn_interval_ticks": 0,
		"entries": [{"profile_index": profile_index, "count": 1}],
	}

func _kill_all(world: SimWorld) -> void:
	for index in range(world.get_zombie_count() - 1, -1, -1):
		world.apply_zombie_damage(
			index, 999999, world.get_zombie_position(index), 0.0, Vector2.RIGHT, &"body"
		)

func _count_wave_events(world: SimWorld, kind: StringName) -> int:
	var count := 0
	for event in world.tick_wave_events:
		if event.get("kind", StringName()) == kind:
			count += 1
	return count

func _first_wave_event(world: SimWorld, kind: StringName) -> Dictionary:
	for event in world.tick_wave_events:
		if event.get("kind", StringName()) == kind:
			return event
	return {}

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_sim_wave_director: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
