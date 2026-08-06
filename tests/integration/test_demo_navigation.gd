extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Navigation test loads DemoArena"
	))
	if packed == null:
		return failures

	var arena := packed.instantiate()
	arena.set("random_seed", 20260805)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)
	var manager := arena.get_node_or_null("World/Navigation") as NavigationWorldManager
	var chunk := arena.get_node_or_null(
		"World/Navigation/DemoArenaChunk"
	) as NavigationChunk3D
	_append(failures, Assertions.expect_true(
		manager != null,
		"Demo owns scene navigation manager"
	))
	_append(failures, Assertions.expect_true(
		chunk != null and chunk.chunk_id == &"demo_arena",
		"Demo registers one named navigation chunk"
	))
	_append(failures, Assertions.expect_true(
		chunk != null and chunk.threaded_baking,
		"Demo uses threaded runtime baking"
	))
	_append(failures, Assertions.expect_true(
		manager != null and not manager.get_chunk_state(&"demo_arena").is_empty(),
		"Demo chunk registers after the shared navigation map is configured"
	))
	var region: NavigationRegion3D
	if chunk != null:
		region = chunk.get_node_or_null("NavigationRegion3D") as NavigationRegion3D
	_append(failures, Assertions.expect_true(
		region != null and region.enabled,
		"Demo chunk enables its region after registration"
	))
	var navigation_map := manager.get_world_3d().navigation_map if manager != null else RID()
	_append(failures, Assertions.expect_float_near(
		NavigationServer3D.map_get_cell_size(navigation_map) if navigation_map.is_valid() else -1.0,
		0.20,
		0.0001,
		"Demo navigation map shares chunk cell size"
	))
	_append(failures, Assertions.expect_float_near(
		NavigationServer3D.map_get_cell_height(navigation_map) if navigation_map.is_valid() else -1.0,
		0.10,
		0.0001,
		"Demo navigation map shares chunk cell height"
	))
	for path in [
		"World/Ground",
		"World/Boundaries/North",
		"World/Boundaries/South",
		"World/Boundaries/West",
		"World/Boundaries/East",
		"World/Props/Incident/PickupCollision",
		"World/Props/HazardZone/ContainerACollision",
		"World/Props/Checkpoint/ContainerBCollision",
	]:
		var source := arena.get_node_or_null(path)
		_append(failures, Assertions.expect_true(
			source != null and source.is_in_group(&"navigation_source"),
			"Demo navigation source is tagged: %s" % path
		))
	for root_path in [
		"World/Props/Checkpoint/TrafficBarriers",
		"World/Props/Checkpoint/PlasticBarriers",
		"World/Props/SupplyPoint/PerimeterProps",
		"World/Props/SupplyPoint/Chests",
	]:
		var root := arena.get_node_or_null(root_path)
		_append(failures, Assertions.expect_true(
			root != null,
			"Demo navigation prop root exists: %s" % root_path
		))
		if root == null:
			continue
		for child in root.get_children():
			_append(failures, Assertions.expect_true(
				child.is_in_group(&"navigation_source"),
				"Checkpoint static prop is a navigation source: %s/%s" % [
					root_path,
					child.name,
				]
			))
	for path in [
		"World/Props/Incident/PickupVisual",
		"World/Props/HazardZone/ContainerAVisual",
		"World/Props/Checkpoint/ContainerBVisual",
	]:
		var visual := arena.get_node_or_null(path)
		_append(failures, Assertions.expect_true(
			visual != null and not visual.is_in_group(&"navigation_source"),
			"Visual model is excluded from baking: %s" % path
		))
	var targets := arena.get_node_or_null("World/Targets")
	var zombie_count := 0
	if targets != null:
		for child in targets.get_children():
			if child is ZombieTarget:
				zombie_count += 1
				var zombie := child as ZombieTarget
				var navigation_agent := zombie.get_node_or_null(
					"NavigationAgent3D"
				) as NavigationAgent3D
				_append(failures, Assertions.expect_true(
					navigation_agent != null and not navigation_agent.avoidance_enabled,
					"Wave zombie owns navigation agent with avoidance disabled"
				))
				_append(failures, Assertions.expect_true(
					zombie.get("navigation_manager") == manager,
					"Demo injects scene navigation manager into wave zombie"
				))
	_append(failures, Assertions.expect_true(
		zombie_count >= 4 and zombie_count <= 8,
		"Initial wave spawns without waiting for navigation baking"
	))
	arena.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
