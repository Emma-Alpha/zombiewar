extends SceneTree

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

const ROOM_SEED := 20260811
const PROFILE_INDEX := 0
const ZOMBIE_COUNT := 12

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_weighted_group_is_exclusive_and_replayable(failures)
	_check_groups_resolve_independently(failures)
	_check_tick_events_clear(failures)
	_finish(failures)

## 这条会在以下错误实现时失败：每组输出多个事件、误触发 0 概率组、
## 或把掉落 RNG 换成非确定随机数/错误的流。
func _check_weighted_group_is_exclusive_and_replayable(failures: Array[String]) -> void:
	var first := _run_common_and_rare_scenario()
	var second := _run_common_and_rare_scenario()
	_expect(first == second, "fixed seed must replay identical death event sequence", failures)
	_expect(
		first.size() == ZOMBIE_COUNT,
		"a 10000 common group must emit exactly one event per zombie",
		failures
	)
	var events_by_zombie: Dictionary[int, int] = {}
	for event in first:
		_expect(event.size() == 7, "death event must contain exactly the specified fields", failures)
		_expect(event.get("kind") == &"drop_item", "death event kind must be drop_item", failures)
		_expect(event.get("profile_index") == PROFILE_INDEX, "profile index must be preserved", failures)
		_expect(event.get("group_id") == &"common", "only common group may trigger", failures)
		_expect(
			int(event.get("reward_profile_index", -1)) == 0
				or int(event.get("reward_profile_index", -1)) == 1,
			"weighted choice must select one configured reward",
			failures
		)
		var reward_index := int(event.get("reward_profile_index", -1))
		var expected_amount := 30 if reward_index == 0 else 1
		_expect(
			int(event.get("amount", -1)) == expected_amount,
			"selected reward must retain its configured amount",
			failures
		)
		var zombie_id := int(event.get("zombie_id", -1))
		events_by_zombie[zombie_id] = int(events_by_zombie.get(zombie_id, 0)) + 1
	for zombie_id in events_by_zombie:
		_expect(
			int(events_by_zombie[zombie_id]) == 1,
			"a group must select at most one event for each zombie",
			failures
		)

func _check_groups_resolve_independently(failures: Array[String]) -> void:
	var world: SimWorld = _new_world(ROOM_SEED)
	world.configure_zombie_death_groups(PROFILE_INDEX, [
		{
			"group_id": &"common",
			"trigger_chance_per_10000": 10000,
			"events": [{"event_type": 0, "weight": 1, "reward_profile_index": 0, "amount": 5}],
		},
		{
			"group_id": &"bonus",
			"trigger_chance_per_10000": 10000,
			"events": [{"event_type": 0, "weight": 1, "reward_profile_index": 2, "amount": 2}],
		},
	])
	var zombie_id := world.spawn_zombie(Vector2(3.0, -2.0), 0.0, PROFILE_INDEX)
	world.apply_zombie_damage(0, 999999, Vector2(3.0, -2.0), 0.0, Vector2.RIGHT, &"body")
	_expect(
		world.tick_death_rule_events.size() == 2,
		"two triggering groups must each emit one event for the same death",
		failures
	)
	var group_ids: Dictionary[StringName, bool] = {}
	for event in world.tick_death_rule_events:
		_expect(int(event.get("zombie_id", -1)) == zombie_id, "events must retain zombie id", failures)
		_expect(
			event.get("position") == Vector2(3.0, -2.0),
			"events must retain zombie position",
			failures
		)
		group_ids[event.get("group_id", StringName())] = true
	_expect(
		group_ids.size() == 2 and group_ids.has(&"common") and group_ids.has(&"bonus"),
		"independent groups must retain their own group ids",
		failures
	)

func _check_tick_events_clear(failures: Array[String]) -> void:
	var world: SimWorld = _new_world(ROOM_SEED)
	world.configure_zombie_death_groups(PROFILE_INDEX, [_always_drop_group(&"common")])
	world.spawn_zombie(Vector2.ZERO, 0.0, PROFILE_INDEX)
	world.apply_zombie_damage(0, 999999, Vector2.ZERO, 0.0, Vector2.RIGHT, &"body")
	_expect(not world.tick_death_rule_events.is_empty(), "death event must be emitted immediately", failures)
	world.step_tick()
	_expect(world.tick_death_rule_events.is_empty(), "death events must clear at next tick", failures)

func _run_common_and_rare_scenario() -> Array[Dictionary]:
	var world: SimWorld = _new_world(ROOM_SEED)
	world.configure_zombie_death_groups(PROFILE_INDEX, [
		{
			"group_id": &"common",
			"trigger_chance_per_10000": 10000,
			"events": [
				{"event_type": 0, "weight": 3, "reward_profile_index": 0, "amount": 30},
				{"event_type": 0, "weight": 1, "reward_profile_index": 1, "amount": 1},
			],
		},
		{
			"group_id": &"rare",
			"trigger_chance_per_10000": 0,
			"events": [{"event_type": 0, "weight": 1, "reward_profile_index": 2, "amount": 1}],
		},
	])
	var events: Array[Dictionary] = []
	for index in range(ZOMBIE_COUNT):
		var position := Vector2(float(index), -1.0)
		world.spawn_zombie(position, 0.0, PROFILE_INDEX)
		world.apply_zombie_damage(index, 999999, position, 0.0, Vector2.RIGHT, &"body")
		for event in world.tick_death_rule_events:
			events.append(event)
		world.tick_death_rule_events = []
	return events

func _new_world(room_seed: int) -> SimWorld:
	var world: SimWorld = SimWorldScript.new()
	world.configure(Vector2(-12.5, -12.5), 1.0, 25, 25)
	world.reset(room_seed)
	world.configure_zombie_profile(PROFILE_INDEX, 50, 1.3)
	return world

func _always_drop_group(group_id: StringName) -> Dictionary:
	return {
		"group_id": group_id,
		"trigger_chance_per_10000": 10000,
		"events": [{"event_type": 0, "weight": 1, "reward_profile_index": 0, "amount": 1}],
	}

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_sim_death_events: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
