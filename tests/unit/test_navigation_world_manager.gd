extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var manager := NavigationWorldManager.new()
	var first := NavigationChunk3D.new()
	first.chunk_id = &"arena"
	var duplicate := NavigationChunk3D.new()
	duplicate.chunk_id = &"arena"
	var mismatched := NavigationChunk3D.new()
	mismatched.chunk_id = &"mismatched"
	mismatched.cell_size = 0.25

	_append(failures, Assertions.expect_true(
		manager.register_chunk(first),
		"Manager registers chunk"
	))
	_append(failures, Assertions.expect_true(
		not manager.register_chunk(duplicate),
		"Manager rejects duplicate chunk id"
	))
	_append(failures, Assertions.expect_true(
		not manager.register_chunk(mismatched),
		"Manager rejects mismatched chunk voxel settings"
	))
	_append(failures, Assertions.expect_true(
		manager.get_chunk_state(&"arena").has("status"),
		"Manager exposes registered chunk state"
	))
	_append(failures, Assertions.expect_true(
		not manager.is_navigation_ready_at(Vector3.ZERO),
		"Queued chunk is not reported ready"
	))
	_append(failures, Assertions.expect_true(
		manager.mark_chunk_dirty(&"arena"),
		"Manager forwards dirty request"
	))
	_append(failures, Assertions.expect_true(
		not manager.mark_chunk_dirty(&"missing"),
		"Manager rejects unknown dirty request"
	))
	_append(failures, Assertions.expect_true(
		manager.unregister_chunk(&"arena"),
		"Manager unregisters chunk"
	))
	_append(failures, Assertions.expect_true(
		manager.get_chunk_state(&"arena").is_empty(),
		"Unregistered state is removed"
	))
	first.free()
	duplicate.free()
	mismatched.free()
	manager.free()
	_append_tree_lifecycle_failures(failures)
	return failures

func _append_tree_lifecycle_failures(failures: Array[String]) -> void:
	var packed := load(
		"res://scenes/navigation/NavigationChunk3D.tscn"
	) as PackedScene
	var host := Node3D.new()
	var manager := NavigationWorldManager.new()
	manager.name = "Navigation"
	var registered := packed.instantiate() as NavigationChunk3D
	registered.chunk_id = &"arena"
	registered.source_root_path = NodePath("../..")
	manager.add_child(registered)
	host.add_child(manager)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)
	var registered_region := registered.get_node(
		"NavigationRegion3D"
	) as NavigationRegion3D
	var started_forwarder := Callable(manager, "_on_chunk_bake_started")
	var succeeded_forwarder := Callable(manager, "_on_chunk_bake_succeeded")
	var failed_forwarder := Callable(manager, "_on_chunk_bake_failed")

	_append(failures, Assertions.expect_true(
		manager.chunks.get(&"arena") == registered and registered_region.enabled,
		"Tree-ready manager registers and enables its initial chunk"
	))
	_append(failures, Assertions.expect_true(
		registered.bake_started.is_connected(started_forwarder) and
		registered.bake_succeeded.is_connected(succeeded_forwarder) and
		registered.bake_failed.is_connected(failed_forwarder),
		"Tree-ready manager connects the initial chunk signals once"
	))

	var runtime_chunk := packed.instantiate() as NavigationChunk3D
	runtime_chunk.chunk_id = &"runtime"
	runtime_chunk.source_root_path = NodePath("../..")
	manager.add_child(runtime_chunk)
	var runtime_region := runtime_chunk.get_node(
		"NavigationRegion3D"
	) as NavigationRegion3D
	_append(failures, Assertions.expect_true(
		manager.chunks.get(&"runtime") == runtime_chunk and
		runtime_region.enabled and
		int(runtime_chunk.get_state_snapshot().get("requested_generation", 0)) == 1,
		"Runtime unique child resolves its region, enables it, and requests baking"
	))
	runtime_chunk.bake_state.has_usable_mesh = true
	runtime_region.enabled = false
	_append(failures, Assertions.expect_true(
		not manager.is_navigation_ready_at(Vector3.ZERO),
		"Usable mesh is not ready while its registered region is disabled"
	))
	runtime_region.enabled = true
	_append(failures, Assertions.expect_true(
		manager.is_navigation_ready_at(Vector3.ZERO),
		"Usable mesh is ready when its registered region is enabled"
	))

	var rejected := packed.instantiate() as NavigationChunk3D
	rejected.chunk_id = &"arena"
	rejected.source_root_path = NodePath("../..")
	var rejected_region := rejected.get_node(
		"NavigationRegion3D"
	) as NavigationRegion3D
	rejected_region.enabled = true
	manager.add_child(rejected)
	_append(failures, Assertions.expect_true(
		manager.chunks.get(&"arena") == registered,
		"Runtime duplicate child is rejected without replacing the registered chunk"
	))
	_append(failures, Assertions.expect_true(
		not rejected_region.enabled,
		"Rejected pre-enabled duplicate cannot contribute navigation"
	))
	manager.remove_child(rejected)
	_append(failures, Assertions.expect_true(
		manager.chunks.get(&"arena") == registered and registered_region.enabled,
		"Rejected duplicate exit preserves the registered chunk and region"
	))
	_append(failures, Assertions.expect_true(
		registered.bake_started.is_connected(started_forwarder) and
		registered.bake_succeeded.is_connected(succeeded_forwarder) and
		registered.bake_failed.is_connected(failed_forwarder),
		"Rejected duplicate exit preserves registered chunk signal forwarding"
	))

	var mismatched := packed.instantiate() as NavigationChunk3D
	mismatched.chunk_id = &"mismatched_runtime"
	mismatched.source_root_path = NodePath("../..")
	mismatched.cell_size = 0.25
	var mismatched_region := mismatched.get_node(
		"NavigationRegion3D"
	) as NavigationRegion3D
	mismatched_region.enabled = true
	manager.add_child(mismatched)
	_append(failures, Assertions.expect_true(
		not manager.chunks.has(&"mismatched_runtime") and not mismatched_region.enabled,
		"Rejected pre-enabled voxel mismatch cannot contribute navigation"
	))
	manager.remove_child(mismatched)

	manager.remove_child(registered)
	_append(failures, Assertions.expect_true(
		manager.get_chunk_state(&"arena").is_empty() and
		not registered_region.enabled,
		"Registered child exit automatically unregisters and disables its region"
	))
	_append(failures, Assertions.expect_true(
		not registered.bake_started.is_connected(started_forwarder) and
		not registered.bake_succeeded.is_connected(succeeded_forwarder) and
		not registered.bake_failed.is_connected(failed_forwarder),
		"Registered child exit disconnects manager signal forwarding"
	))
	manager.remove_child(runtime_chunk)
	rejected.free()
	mismatched.free()
	runtime_chunk.free()
	registered.free()
	host.free()

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
