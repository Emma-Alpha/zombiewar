extends SceneTree

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const SimHasherScript = preload("res://scripts/sim/sim_hasher.gd")

const ROOM_SEED := 20260811
const BLOCKER_MIN := Vector2(-0.5, -0.5)
const BLOCKER_MAX := Vector2(0.5, 0.5)
const CHEST_BLOCKER_HALF_SIZE := Vector2(0.24, 0.18)
const CHEST_STATE_ACTIVE := 0
const CHEST_STATE_WAITING_RESPAWN := 1
const CHEST_STATE_CONSUMED := 2

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_fixed_chest_claim_and_exact_respawn(failures)
	_check_respawned_chest_can_be_claimed_in_same_tick(failures)
	_check_one_shot_chest_never_respawns(failures)
	_check_overlapping_runtime_blockers_are_reference_counted(failures)
	_check_death_drop_materializes_before_flow_update(failures)
	_check_hasher_covers_chest_lifecycle_fields(failures)
	_finish(failures)

## Catches a claim that leaves a ghost blocker, uses wall-clock respawn, or restores
## one tick early/late.
func _check_fixed_chest_claim_and_exact_respawn(failures: Array[String]) -> void:
	var world: SimWorld = _new_world()
	var chest_id := _spawn_chest(world, [
		Vector2.ZERO, 0, 30, 3, BLOCKER_MIN, BLOCKER_MAX, 0.9,
	], failures)
	if chest_id < 0:
		return
	var chest_cell: Vector2i = world.get_grid().world_to_cell(Vector2.ZERO)
	_expect(world.get_grid().is_blocked(chest_cell), "spawn must insert chest blocker", failures)
	world.set_player_snapshot(0, Vector2.ZERO, true, true)
	world.step_tick()
	_expect(_has_event(world.tick_chest_events, &"chest_claimed", chest_id), "claim event", failures)
	_expect(
		world.get_chest_state(0) == CHEST_STATE_WAITING_RESPAWN,
		"fixed chest waits for respawn",
		failures
	)
	_expect(
		not world.get_grid().is_blocked(chest_cell),
		"claim must clear blocker in the same tick",
		failures
	)

	world.set_player_snapshot(0, Vector2(8.0, 8.0), true, true)
	for _tick in range(2):
		world.step_tick()
		_expect(
			world.get_chest_state(0) == CHEST_STATE_WAITING_RESPAWN,
			"fixed chest must stay absent before exact respawn tick",
			failures
		)
		_expect(
			not _has_event(world.tick_chest_events, &"chest_respawned", chest_id),
			"fixed chest must not emit an early respawn",
			failures
		)
	world.step_tick()
	_expect(
		_has_event(world.tick_chest_events, &"chest_respawned", chest_id),
		"fixed chest must respawn on the exact third tick",
		failures
	)
	_expect(world.get_chest_state(0) == CHEST_STATE_ACTIVE, "respawned chest must be active", failures)
	_expect(world.get_grid().is_blocked(chest_cell), "respawn must restore the blocker", failures)

## Catches the wrong update order: claims must scan after respawns so a player who
## remains in place receives respawned then claimed in the same tick.
func _check_respawned_chest_can_be_claimed_in_same_tick(
	failures: Array[String]
) -> void:
	var world: SimWorld = _new_world()
	var chest_id := _spawn_chest(world, [
		Vector2.ZERO, 1, 7, 1, BLOCKER_MIN, BLOCKER_MAX, 0.9,
	], failures)
	if chest_id < 0:
		return
	world.set_player_snapshot(0, Vector2.ZERO, true, true)
	world.step_tick()
	world.step_tick()
	_expect(world.tick_chest_events.size() == 2, "respawn tick must emit exactly two events", failures)
	if world.tick_chest_events.size() == 2:
		_expect(
			world.tick_chest_events[0].get("kind") == &"chest_respawned"
			and int(world.tick_chest_events[0].get("chest_id", -1)) == chest_id,
			"respawn event must precede same-tick claim",
			failures
		)
		_expect(
			world.tick_chest_events[1].get("kind") == &"chest_claimed"
			and int(world.tick_chest_events[1].get("chest_id", -1)) == chest_id,
			"same-tick claim must follow respawn",
			failures
		)
	_expect(
		world.get_chest_state(0) == CHEST_STATE_WAITING_RESPAWN,
		"same-tick claimed chest must return to waiting state",
		failures
	)
	_expect(
		not world.get_grid().is_blocked(world.get_grid().world_to_cell(Vector2.ZERO)),
		"same-tick claim must leave the blocker cleared",
		failures
	)

## Catches accidentally treating a death drop like a fixed supply spawn.
func _check_one_shot_chest_never_respawns(failures: Array[String]) -> void:
	var world: SimWorld = _new_world()
	var position := Vector2(2.0, 0.0)
	var chest_id := _spawn_chest(world, [
		position, 2, 11, -1, position + BLOCKER_MIN, position + BLOCKER_MAX, 0.9,
	], failures)
	if chest_id < 0:
		return
	world.set_player_snapshot(0, position, true, true)
	world.step_tick()
	_expect(world.get_chest_state(0) == CHEST_STATE_CONSUMED, "one-shot chest must be consumed", failures)
	_expect(
		not world.get_grid().is_blocked(world.get_grid().world_to_cell(position)),
		"one-shot claim must clear its blocker",
		failures
	)
	world.set_player_snapshot(0, Vector2(8.0, 8.0), true, true)
	for _tick in range(8):
		world.step_tick()
		_expect(
			not _has_event(world.tick_chest_events, &"chest_respawned", chest_id),
			"one-shot chest must never emit respawn",
			failures
		)
	_expect(world.get_chest_state(0) == CHEST_STATE_CONSUMED, "one-shot chest must stay consumed", failures)

## Catches source removal implemented as direct boolean clearing instead of a
## reference count, and catches dirtying when final passability did not change.
func _check_overlapping_runtime_blockers_are_reference_counted(
	failures: Array[String]
) -> void:
	var grid: FlowFieldGrid = _new_world().get_grid()
	for method_name in [&"add_static_blocker_world_rect", &"remove_static_blocker_world_rect"]:
		if not grid.has_method(method_name):
			failures.append("FlowFieldGrid must expose %s" % method_name)
			return
	var cell: Vector2i = grid.world_to_cell(Vector2.ZERO)
	grid.consume_dirty()
	grid.call(&"add_static_blocker_world_rect", BLOCKER_MIN, BLOCKER_MAX)
	_expect(grid.is_blocked(cell), "first runtime source must block the cell", failures)
	_expect(grid.consume_dirty(), "first runtime source must dirty passability", failures)
	grid.call(&"add_static_blocker_world_rect", BLOCKER_MIN, BLOCKER_MAX)
	_expect(not grid.consume_dirty(), "overlap must not dirty unchanged passability", failures)
	grid.call(&"remove_static_blocker_world_rect", BLOCKER_MIN, BLOCKER_MAX)
	_expect(grid.is_blocked(cell), "removing one source must preserve the blocker", failures)
	_expect(not grid.consume_dirty(), "partial removal must not dirty unchanged passability", failures)
	grid.call(&"remove_static_blocker_world_rect", BLOCKER_MIN, BLOCKER_MAX)
	_expect(not grid.is_blocked(cell), "last source removal must restore passability", failures)
	_expect(grid.consume_dirty(), "last source removal must dirty passability", failures)

## Catches death drops materialized by presentation code or after the flow rebuild.
func _check_death_drop_materializes_before_flow_update(failures: Array[String]) -> void:
	var world: SimWorld = _new_world()
	world.configure_zombie_profile(0, 50, 1.3)
	world.configure_zombie_death_groups(0, [{
		"group_id": &"guaranteed",
		"trigger_chance_per_10000": 10000,
		"events": [{
			"event_type": 0,
			"weight": 1,
			"reward_profile_index": 2,
			"amount": 13,
		}],
	}])
	var death_position := Vector2(3.0, -2.0)
	world.spawn_zombie(death_position, 0.0, 0)
	world.queue_explosion_event(death_position, 0.0, 2.0, 500.0, 500.0)
	world.step_tick()
	_expect(world.get_chest_count() == 1, "death rule must materialize one simulated chest", failures)
	if world.get_chest_count() != 1:
		return
	var spawned := _first_event(world.tick_chest_events, &"chest_spawned")
	_expect(not spawned.is_empty(), "death materialization must emit chest_spawned", failures)
	if not spawned.is_empty():
		_expect(spawned.get("position") == death_position, "spawn must preserve death position", failures)
		_expect(int(spawned.get("reward_profile_index", -1)) == 2, "spawn must preserve reward", failures)
		_expect(int(spawned.get("amount", -1)) == 13, "spawn must preserve amount", failures)
	var fields := [&"chest_respawn_delay_ticks", &"chest_blocker_min", &"chest_blocker_max"]
	if not _require_properties(world, fields, failures):
		return
	var respawn_delays: Variant = world.get(&"chest_respawn_delay_ticks")
	var blocker_mins: Variant = world.get(&"chest_blocker_min")
	var blocker_maxes: Variant = world.get(&"chest_blocker_max")
	_expect(respawn_delays[0] == -1, "death drop must be one-shot", failures)
	_expect(
		blocker_mins[0] == death_position - CHEST_BLOCKER_HALF_SIZE
		and blocker_maxes[0] == death_position + CHEST_BLOCKER_HALF_SIZE,
		"death drop must use the shared blocker extent",
		failures
	)
	# 战利品**不**占阻挡格。原先它占，是因为死亡掉落与固定补给箱共用 spawn_chest，
	# 顺带继承了后者的阻挡语义——而两者的处境完全不同：固定刷新点的落位在
	# game_map_runtime 里有越界与重叠校验，死亡掉落却直接用僵尸咽气的那一点、
	# 不做任何可通行性检查。
	#
	# 占格的后果是玩家可见的三件事：地上的战利品把战场织成迷宫、子弹被自己刚
	# 打出来的战利品挡住（阻挡格同时进 ray_blocked_distance 的静态图）、
	# 以及每掉一件就标脏流场触发一次全网格 BFS 重建。
	#
	# blocker_min/max 仍然逐箱记录（上面那条断言），这样"生成时标没标"与
	# "领取时清不清"始终对称——清掉一个当初没标过的矩形会在墙上开洞。
	_expect(
		not world.get_grid().is_blocked(world.get_grid().world_to_cell(death_position)),
		"death drop must NOT block movement or bullets",
		failures
	)
	_expect(
		not world.get_grid().consume_dirty(),
		"death blocker must be consumed by the same tick flow update",
		failures
	)

## Catches a state field affecting claims/respawns/blockers without participating in
## the deterministic frame hash.
func _check_hasher_covers_chest_lifecycle_fields(failures: Array[String]) -> void:
	var world: SimWorld = _new_world()
	if _spawn_chest(
		world, [Vector2.ZERO, 4, 9, 3, BLOCKER_MIN, BLOCKER_MAX, 0.9], failures
	) < 0:
		return
	var field_names := [
		&"chest_radius",
		&"chest_reward_profile",
		&"chest_amount",
		&"chest_respawn_delay_ticks",
		&"chest_respawn_at_tick",
		&"chest_blocker_min",
		&"chest_blocker_max",
	]
	if not _require_properties(world, field_names, failures):
		return
	var baseline: String = SimHasherScript.hash_world(world)
	for mutation in [
		["radius", &"chest_radius", 1.1],
		["reward profile", &"chest_reward_profile", 5],
		["amount", &"chest_amount", 10],
		["respawn delay", &"chest_respawn_delay_ticks", 4],
		["respawn tick", &"chest_respawn_at_tick", 8],
	]:
		var property_name: StringName = mutation[1]
		var values: Variant = world.get(property_name)
		var original: Variant = values[0]
		values[0] = mutation[2]
		world.set(property_name, values)
		_expect(
			SimHasherScript.hash_world(world) != baseline,
			"SimHasher must include chest %s" % mutation[0],
			failures
		)
		values[0] = original
		world.set(property_name, values)
	var blocker_mins: Variant = world.get(&"chest_blocker_min")
	var original_min: Vector2 = blocker_mins[0]
	blocker_mins[0] = Vector2(-0.25, -0.5)
	world.set(&"chest_blocker_min", blocker_mins)
	_expect(SimHasherScript.hash_world(world) != baseline, "SimHasher must include chest blocker min", failures)
	blocker_mins[0] = original_min
	world.set(&"chest_blocker_min", blocker_mins)
	var blocker_maxes: Variant = world.get(&"chest_blocker_max")
	var original_max: Vector2 = blocker_maxes[0]
	blocker_maxes[0] = Vector2(0.25, 0.5)
	world.set(&"chest_blocker_max", blocker_maxes)
	_expect(SimHasherScript.hash_world(world) != baseline, "SimHasher must include chest blocker max", failures)
	blocker_maxes[0] = original_max
	world.set(&"chest_blocker_max", blocker_maxes)
	world.chest_state[0] = CHEST_STATE_CONSUMED
	_expect(SimHasherScript.hash_world(world) != baseline, "SimHasher must include chest state", failures)

func _new_world() -> SimWorld:
	var world: SimWorld = SimWorldScript.new()
	world.configure(Vector2(-12.5, -12.5), 1.0, 25, 25)
	world.configure_inventory_profiles(
		[{"category": 2, "max_stack": 999, "weapon_id": &"", "mod_id": -1}],
		PackedInt32Array([0, 0, 0, 0, 0, 0])
	)
	world.reset(ROOM_SEED)
	return world

func _spawn_chest(world: SimWorld, arguments: Array, failures: Array[String]) -> int:
	for method in world.get_method_list():
		if method.get("name") != &"spawn_chest":
			continue
		var method_arguments: Array = method.get("args", [])
		# 允许尾部追加带默认值的可选参数（blocks_movement 就是这样加进来的），
		# 但前面这几个必填参数的顺序不能动——调用方是按位置传的。
		if method_arguments.size() < arguments.size():
			failures.append(
				"spawn_chest must accept position, reward, amount, respawn, blocker bounds, and radius"
			)
			return -1
		return int(world.callv(&"spawn_chest", arguments))
	failures.append("SimWorld must expose spawn_chest")
	return -1

func _require_properties(
	object: Object,
	property_names: Array,
	failures: Array[String]
) -> bool:
	var available: Dictionary[StringName, bool] = {}
	for property in object.get_property_list():
		available[StringName(property.get("name", ""))] = true
	var found_all := true
	for property_name: StringName in property_names:
		if available.has(property_name):
			continue
		failures.append("missing simulation field: %s" % property_name)
		found_all = false
	return found_all

func _has_event(events: Array, kind: StringName, chest_id: int) -> bool:
	for event in events:
		if event.get("kind") == kind and int(event.get("chest_id", -1)) == chest_id:
			return true
	return false

func _first_event(events: Array, kind: StringName) -> Dictionary:
	for event in events:
		if event.get("kind") == kind:
			return event
	return {}

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_sim_pickup_respawn: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
