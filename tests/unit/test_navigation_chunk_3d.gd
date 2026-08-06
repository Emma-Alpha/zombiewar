extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/navigation/NavigationChunk3D.tscn") as PackedScene
	_append(failures, Assertions.expect_true(packed != null, "Navigation chunk scene loads"))
	if packed == null:
		return failures

	var chunk := packed.instantiate() as NavigationChunk3D
	chunk.chunk_id = &"test_chunk"
	chunk.source_group_name = &"navigation_source"
	chunk.baking_bounds = AABB(Vector3(-5.0, -1.0, -5.0), Vector3(10.0, 3.0, 10.0))
	chunk.threaded_baking = false
	var navigation_mesh := chunk.call("_create_navigation_mesh") as NavigationMesh
	_append(failures, Assertions.expect_true(navigation_mesh != null, "Chunk creates navigation mesh"))
	if navigation_mesh != null:
		_append(failures, Assertions.expect_equal(
			navigation_mesh.geometry_parsed_geometry_type,
			NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS,
			"Chunk parses only static colliders"
		))
		_append(failures, Assertions.expect_equal(
			navigation_mesh.geometry_source_geometry_mode,
			NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN,
			"Chunk parses the configured source group"
		))
		_append(failures, Assertions.expect_equal(
			navigation_mesh.geometry_source_group_name,
			&"navigation_source",
			"Chunk uses the navigation source group"
		))
		_append(failures, Assertions.expect_float_near(
			navigation_mesh.agent_radius, 0.60, 0.0001, "Chunk reserves zombie clearance"
		))
		_append(failures, Assertions.expect_float_near(
			navigation_mesh.agent_height, 1.90, 0.0001, "Chunk matches zombie height"
		))
		_append(failures, Assertions.expect_float_near(
			navigation_mesh.cell_size, 0.20, 0.0001, "Chunk uses voxel-aligned cell size"
		))
		_append(failures, Assertions.expect_float_near(
			navigation_mesh.cell_height, 0.10, 0.0001, "Chunk uses shared map cell height"
		))
		_append(failures, Assertions.expect_float_near(
			navigation_mesh.agent_max_climb,
			0.20,
			0.0001,
			"Chunk uses voxel-aligned climb height"
		))
		_append(failures, Assertions.expect_float_near(
			navigation_mesh.edge_max_error,
			1.0,
			0.0001,
			"Chunk candidate tightens edge simplification for adjacent seams"
		))
		_append(failures, Assertions.expect_true(
			navigation_mesh.filter_baking_aabb == chunk.baking_bounds,
			"Chunk filters baking to its AABB"
		))

	var host := Node3D.new()
	host.position = Vector3(8.0, 2.0, -4.0)
	host.rotation.y = 0.5
	var ground := StaticBody3D.new()
	ground.add_to_group(&"navigation_source")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10.0, 0.2, 10.0)
	shape.position.y = -0.1
	shape.shape = box
	ground.add_child(shape)
	host.add_child(ground)
	chunk.source_root_path = NodePath("..")
	chunk.position = Vector3(3.0, 1.0, -2.0)
	host.add_child(chunk)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)
	var region := chunk.get_node("NavigationRegion3D") as NavigationRegion3D
	var navigation_map := host.get_world_3d().navigation_map
	var original_cell_size := NavigationServer3D.map_get_cell_size(navigation_map)
	var original_cell_height := NavigationServer3D.map_get_cell_height(navigation_map)
	NavigationServer3D.map_set_cell_size(navigation_map, chunk.cell_size)
	NavigationServer3D.map_set_cell_height(navigation_map, chunk.cell_height)
	NavigationServer3D.map_force_update(navigation_map)
	chunk.request_rebake()
	chunk.call("_start_queued_bake")
	var snapshot := chunk.get_state_snapshot()
	_append(failures, Assertions.expect_true(
		bool(snapshot.get("has_usable_mesh", false)),
		"Synchronous test bake produces usable data"
	))
	_append(failures, Assertions.expect_true(
		region.navigation_mesh != null and region.navigation_mesh.get_polygon_count() > 0,
		"Synchronous test bake commits a non-empty mesh"
	))
	_append(failures, Assertions.expect_true(
		region.top_level and region.global_transform.is_equal_approx(host.global_transform),
		"Top-level region matches source root transform"
	))
	_append(failures, Assertions.expect_true(
		chunk.contains_global_position(host.to_global(Vector3.ZERO)),
		"Chunk checks bounds in source root space"
	))
	_append(failures, Assertions.expect_true(
		not chunk.contains_global_position(host.to_global(Vector3(6.0, 0.0, 0.0))),
		"Chunk rejects positions outside source root bounds"
	))
	NavigationServer3D.map_set_cell_size(navigation_map, 0.25)
	NavigationServer3D.map_set_cell_height(navigation_map, 0.25)
	NavigationServer3D.map_force_update(navigation_map)
	chunk.set_registered(true)
	_append(failures, Assertions.expect_true(
		not region.enabled,
		"Mismatched map settings keep chunk region disabled"
	))
	NavigationServer3D.map_set_cell_size(navigation_map, original_cell_size)
	NavigationServer3D.map_set_cell_height(navigation_map, original_cell_height)
	NavigationServer3D.map_force_update(navigation_map)
	host.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
