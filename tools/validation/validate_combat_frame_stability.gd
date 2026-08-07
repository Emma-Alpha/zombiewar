extends SceneTree

const FireGate = preload("res://scripts/combat/fire_gate.gd")
const GroundBloodSplatScene = preload("res://scenes/fx/GroundBloodSplat.tscn")
const GroundBloodManagerScript = preload("res://scripts/fx/ground_blood_manager.gd")
const DemoArenaScene = preload("res://scenes/gameplay/DemoArena.tscn")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_test_large_frame_does_not_shorten_next_shot_interval(failures)
	_test_reused_ground_splat_keeps_its_material(failures)
	_test_ground_blood_queue_respects_frame_budget(failures)
	await _test_blood_impact_pool_reuses_bounded_nodes(failures)
	await _test_demo_arena_queues_ground_blood_requests(failures)
	if failures.is_empty():
		print("validate_combat_frame_stability: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _test_large_frame_does_not_shorten_next_shot_interval(
	failures: Array[String]
) -> void:
	var gate := FireGate.new(0.25)
	_expect(gate.try_consume(true), "the first held shot must fire", failures)
	gate.tick(0.40)
	_expect(
		gate.try_consume(true),
		"a held shot must fire after a frame longer than its cooldown",
		failures
	)
	_expect(
		is_equal_approx(gate.remaining, 0.25),
		"a large frame must not shorten the cooldown after the next real shot",
		failures
	)

func _test_reused_ground_splat_keeps_its_material(
	failures: Array[String]
) -> void:
	var splat := GroundBloodSplatScene.instantiate() as GroundBloodSplat
	var texture := (splat.material_override as StandardMaterial3D).albedo_texture
	splat.setup(
		Vector3.ZERO,
		Vector3.UP,
		Vector2.ONE,
		0.0,
		Color(0.4, 0.01, 0.02, 0.9),
		texture,
		0.4
	)
	var first_material_id := splat.material_override.get_instance_id()
	splat.setup(
		Vector3.ONE,
		Vector3.UP,
		Vector2.ONE * 1.2,
		0.2,
		Color(0.35, 0.01, 0.02, 0.92),
		texture,
		0.5
	)
	_expect(
		splat.material_override.get_instance_id() == first_material_id,
		"a reused ground splat must update its existing unique material",
		failures
	)
	splat.free()

func _test_ground_blood_queue_respects_frame_budget(
	failures: Array[String]
) -> void:
	var manager := GroundBloodManagerScript.new()
	_expect(
		manager.has_method(&"queue_hit_splat") and
		manager.has_method(&"get_pending_request_count"),
		"ground blood manager must expose queued hit requests for frame budgeting",
		failures
	)
	if (
		not manager.has_method(&"queue_hit_splat") or
		not manager.has_method(&"get_pending_request_count")
	):
		manager.free()
		return
	manager.max_requests_per_frame = 2
	for request_index in range(5):
		manager.queue_hit_splat(
			Vector3(request_index, 0.0, 0.0),
			Vector3.FORWARD,
			1.0
		)
	manager.call("_process", 0.0)
	_expect(
		manager.get_pending_request_count() == 3,
		"ground blood processing must consume no more than its per-frame budget",
		failures
	)
	manager.call("_process", 0.0)
	_expect(
		manager.get_pending_request_count() == 1,
		"queued ground blood requests must continue on later frames",
		failures
	)
	manager.call("_process", 0.0)
	_expect(
		manager.get_pending_request_count() == 0,
		"queued ground blood requests must eventually drain",
		failures
	)
	manager.free()

func _test_blood_impact_pool_reuses_bounded_nodes(
	failures: Array[String]
) -> void:
	var manager := GroundBloodManagerScript.new()
	var supports_pool := (
		"impact_pool_size" in manager and
		manager.has_method(&"spawn_blood_impact") and
		manager.has_method(&"get_impact_pool_count")
	)
	_expect(
		supports_pool,
		"blood FX manager must expose a bounded reusable impact pool",
		failures
	)
	if not supports_pool:
		manager.free()
		return
	manager.impact_pool_size = 3
	root.add_child(manager)
	await process_frame
	_expect(
		manager.get_impact_pool_count() == 3,
		"blood impact pool must preallocate its configured node count",
		failures
	)
	var pooled_ids: Array[int] = []
	for child in manager.get_children():
		if child is BloodImpact:
			pooled_ids.append(child.get_instance_id())
	for impact_index in range(5):
		manager.spawn_blood_impact(
			Vector3(impact_index, 0.0, 0.0),
			Vector3.FORWARD,
			1.0
		)
	var reused_ids: Array[int] = []
	for child in manager.get_children():
		if child is BloodImpact:
			reused_ids.append(child.get_instance_id())
	_expect(
		manager.get_impact_pool_count() == 3 and reused_ids == pooled_ids,
		"blood impacts beyond pool capacity must reuse existing nodes",
		failures
	)
	manager.queue_free()
	await process_frame

func _test_demo_arena_queues_ground_blood_requests(
	failures: Array[String]
) -> void:
	var arena := DemoArenaScene.instantiate()
	root.add_child(arena)
	await process_frame
	var manager := arena.get_node("GroundBloodManager") as GroundBloodManager
	manager.process_mode = Node.PROCESS_MODE_DISABLED
	var targets := arena.get_node("World/Targets")
	var zombie: ZombieTarget
	for child in targets.get_children():
		if child is ZombieTarget:
			zombie = child as ZombieTarget
			break
	_expect(zombie != null, "DemoArena must spawn a zombie for hit FX validation", failures)
	if zombie != null:
		var active_impacts_before := _count_active_impacts(manager)
		zombie.apply_hit(
			1.0,
			zombie.global_position + Vector3.UP,
			Vector3.FORWARD
		)
		_expect(
			_count_active_impacts(manager) == active_impacts_before + 1,
			"zombie hits must activate the scene-level blood impact pool",
			failures
		)
	var pending_requests_before := manager.get_pending_request_count()
	arena.call(
		"_on_ground_blood_requested",
		Vector3.ZERO,
		Vector3.FORWARD,
		1.0,
		false
	)
	arena.call(
		"_on_ground_blood_requested",
		Vector3.ZERO,
		Vector3.FORWARD,
		1.25,
		true
	)
	arena.call(
		"_on_ground_blood_trail_requested",
		Vector3.ZERO,
		Vector3.FORWARD,
		1.0,
		0.5
	)
	_expect(
		manager.get_pending_request_count() == pending_requests_before + 3,
		"DemoArena must queue hit, death, and trail blood work for later frames",
		failures
	)
	arena.queue_free()
	await process_frame

func _count_active_impacts(manager: GroundBloodManager) -> int:
	var active_count := 0
	for child in manager.get_children():
		if child is BloodImpact and (child as BloodImpact).is_active():
			active_count += 1
	return active_count

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
