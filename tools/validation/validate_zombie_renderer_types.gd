extends SceneTree

const ZombieScene := preload("res://scenes/targets/ZombieTarget.tscn")
const ZombieRendererScript := preload("res://scripts/render/zombie_renderer.gd")
const SimWorldScript := preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var anchor := Node3D.new()
	var renderer: ZombieRenderer = ZombieRendererScript.new()
	root.add_child(anchor)
	root.add_child(renderer)
	var world: SimWorld = SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(20260811)
	# 此验证故意复用同一表现资源：检验的不是美术差异，而是类型索引
	# 会隔离近景池和远景 MultiMesh bucket。
	renderer.configure_zombie_scenes([ZombieScene, ZombieScene])
	renderer.setup(anchor)
	_test_released_views_rebalance_across_profiles(anchor, failures)
	world.configure_zombie_profile(0, 50, 1.3)
	world.configure_zombie_profile(1, 100, 1.6)
	world.spawn_zombie(Vector2.ZERO, 0.0, 0)
	var elite_id := world.spawn_zombie(Vector2.ONE, 0.0, 1)
	renderer.sync_lod(world)
	_expect(renderer.get_type_bucket_count() == 2, "two render buckets", failures)
	_expect(
		renderer.get_near_view_profile(elite_id) == 1,
		"elite view must use elite bucket",
		failures
	)
	world.tick_death_events = [elite_id]
	renderer.notify_deaths(world)
	await create_timer(1.4).timeout
	_expect(
		(renderer.type_buckets[1]["free_views"] as Array).size() == 1,
		"completed elite death must return its view to the elite bucket",
		failures
	)
	_expect(
		not renderer.near_view_profile.has(elite_id),
		"completed elite death must clear its profile mapping",
		failures
	)
	renderer.configure_zombie_scenes([])
	_expect(
		renderer.get_type_bucket_count() == 0,
		"reconfiguring with no scenes must discard prior render buckets",
		failures
	)
	renderer.clear()
	renderer.queue_free()
	anchor.queue_free()
	await process_frame
	_finish(failures)

func _test_released_views_rebalance_across_profiles(
	anchor: Node3D,
	failures: Array[String]
) -> void:
	var renderer: ZombieRenderer = ZombieRendererScript.new()
	root.add_child(renderer)
	var profile_b_scene := ZombieScene.duplicate() as PackedScene
	_expect(profile_b_scene != null, "profile B replacement scene", failures)
	if profile_b_scene == null:
		renderer.free()
		return
	renderer.configure_zombie_scenes([ZombieScene, profile_b_scene])
	renderer.setup(anchor)
	var world: SimWorld = SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(20260812)
	world.configure_zombie_profile(0, 50, 1.3)
	world.configure_zombie_profile(1, 100, 1.6)
	var profile_a_ids := PackedInt32Array()
	for index in range(ZombieRenderer.NEAR_LOD_COUNT):
		profile_a_ids.append(world.spawn_zombie(Vector2.ZERO, 0.0, 0))
	renderer.sync_lod(world)
	var profile_a_view_count := 0
	var profile_a_view_instance_ids := PackedInt64Array()
	for zombie_id_value in profile_a_ids:
		var view := renderer.get_near_view(zombie_id_value)
		if view != null:
			profile_a_view_count += 1
			profile_a_view_instance_ids.append(view.get_instance_id())
	_expect(
		profile_a_view_count == ZombieRenderer.NEAR_LOD_COUNT,
		"profile A must obtain all 48 near views before release",
		failures
	)

	world.reset(20260812)
	renderer.sync_lod(world)
	world.configure_zombie_profile(0, 50, 1.3)
	world.configure_zombie_profile(1, 100, 1.6)
	var profile_b_id := world.spawn_zombie(Vector2.ZERO, 0.0, 1)
	renderer.sync_lod(world)
	var profile_b_view := renderer.get_near_view(profile_b_id)
	_expect(
		profile_b_view != null,
		"profile B must reclaim an idle near-view slot released by profile A",
		failures
	)
	_expect(
		renderer.get_near_view_profile(profile_b_id) == 1,
		"rebalanced near view must belong to profile B",
		failures
	)
	_expect(
		profile_b_view != null and not profile_a_view_instance_ids.has(
			profile_b_view.get_instance_id()
		),
		"a different profile scene must replace, not reuse, the idle instance",
		failures
	)
	renderer.free()

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_zombie_renderer_types: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
