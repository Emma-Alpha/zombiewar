extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ARENA_SCENE := preload("res://scenes/gameplay/DemoArena.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var arena := ARENA_SCENE.instantiate()
	var grid := arena.get_node_or_null(
		"World/Placement/PlaceItemGrid"
	) as PlaceItemGrid
	var controller := arena.get_node_or_null(
		"PlaceItemController"
	) as PlaceItemController
	var player := arena.get_node_or_null("Player") as PlayerController
	var barrels := arena.get_node_or_null(
		"World/Props/ExplosiveBarrels"
	) as Node3D
	_append(failures, Assertions.expect_true(
		grid != null and is_equal_approx(grid.cell_size, 1.0) and
		grid.grid_origin == Vector3.ZERO,
		"Demo owns a one-meter world-origin placement grid"
	))
	_append(failures, Assertions.expect_true(
		controller != null and controller.item_display_name == "油桶" and
		controller.initial_item_count == 999 and
		controller.place_item_scene.resource_path ==
		"res://scenes/props/ExplosiveBarrel.tscn",
		"Demo configures 999 explosive barrels as its place item"
	))
	var obstacle_paths := [
		"World/Boundaries/North",
		"World/Boundaries/South",
		"World/Boundaries/West",
		"World/Boundaries/East",
		"World/Props/PickupCollision",
		"World/Props/ContainerACollision",
		"World/Props/ContainerBCollision",
	]
	for path in obstacle_paths:
		var obstacle := arena.get_node_or_null(path)
		_append(failures, Assertions.expect_true(
			obstacle != null and obstacle.is_in_group(&"place_item_obstacle"),
			"Demo placement grid registers obstacle %s" % path
		))
	if barrels != null:
		for barrel in barrels.get_children():
			_append(failures, Assertions.expect_true(
				barrel.is_in_group(&"place_item_obstacle"),
				"Every initial demo barrel occupies placement grid cells"
			))
	_append(failures, Assertions.expect_true(
		not arena.get_node("World/Ground").is_in_group(&"place_item_obstacle"),
		"Demo ground does not reserve every placement cell"
	))
	_append(failures, Assertions.expect_true(
		player != null and controller != null and
		player.place_item_requested.is_connected(controller.request_place_item) and
		controller.placement_geometry_changed.is_connected(
			Callable(arena, "_on_barrel_navigation_geometry_changed")
		),
		"Demo wires player placement to inventory and scene navigation"
	))
	if grid == null or controller == null or player == null or barrels == null:
		arena.free()
		return failures
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)
	player.set_physics_process(false)
	grid.register_initial_obstacles()
	var initial_children := barrels.get_child_count()
	var success := controller.request_place_item(
		player,
		Vector3(0.0, 0.0, 6.0),
		Vector3.FORWARD
	)
	_append(failures, Assertions.expect_true(
		success and barrels.get_child_count() == initial_children + 1 and
		(barrels.get_child(-1) as Node3D).global_position == Vector3(0.0, 0.0, 5.0) and
		controller.get_remaining_count() == 998,
		"Demo places one barrel in the facing adjacent empty cell"
	))
	var count_before_blocked := controller.get_remaining_count()
	var blocked := controller.request_place_item(
		player,
		Vector3(-7.0, 0.0, -3.0),
		Vector3.FORWARD
	)
	_append(failures, Assertions.expect_true(
		not blocked and controller.get_remaining_count() == count_before_blocked,
		"Demo container occupancy rejects placement without consuming stock"
	))
	arena.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
