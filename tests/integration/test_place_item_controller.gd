extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PlaceItemGridScript = preload("res://scripts/gameplay/place_item_grid.gd")
const PlaceItemControllerScript = preload("res://scripts/gameplay/place_item_controller.gd")
const BARREL_SCENE := preload("res://scenes/props/ExplosiveBarrel.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var host := Node3D.new()
	var grid := PlaceItemGridScript.new() as PlaceItemGrid
	grid.name = "Grid"
	var placed := Node3D.new()
	placed.name = "Placed"
	var controller := PlaceItemControllerScript.new() as PlaceItemController
	controller.name = "Controller"
	controller.item_display_name = "油桶"
	controller.place_item_scene = BARREL_SCENE
	controller.initial_item_count = 2
	controller.grid_path = NodePath("../Grid")
	controller.placed_items_path = NodePath("../Placed")
	host.add_child(grid)
	host.add_child(placed)
	host.add_child(controller)
	var requester := CharacterBody3D.new()
	requester.collision_layer = 2
	host.add_child(requester)
	var geometry_changes: Array[int] = []
	controller.placement_geometry_changed.connect(
		func() -> void: geometry_changes.append(1)
	)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)
	var first_success := controller.request_place_item(
		requester,
		Vector3.ZERO,
		Vector3.RIGHT
	)
	_append(failures, Assertions.expect_true(
		first_success and placed.get_child_count() == 1 and
		(placed.get_child(0) as Node3D).global_position == Vector3(1.0, 0.0, 0.0) and
		controller.get_remaining_count() == 1,
		"Successful placement snaps to the adjacent cell and consumes one item"
	))
	var occupied_success := controller.request_place_item(
		requester,
		Vector3.ZERO,
		Vector3.RIGHT
	)
	_append(failures, Assertions.expect_true(
		not occupied_success and placed.get_child_count() == 1 and
		controller.get_remaining_count() == 1,
		"A reserved target cell rejects placement without consuming inventory"
	))
	var first_barrel := placed.get_child(0)
	first_barrel.free()
	_append(failures, Assertions.expect_equal(
		controller.get_remaining_count(),
		1,
		"Destroying a placed item releases its cell without refunding inventory"
	))
	var reuse_success := controller.request_place_item(
		requester,
		Vector3.ZERO,
		Vector3.RIGHT
	)
	_append(failures, Assertions.expect_true(
		reuse_success and controller.get_remaining_count() == 0 and
		geometry_changes.size() == 3,
		"A released cell can be placed again and each geometry change emits once"
	))
	_append(failures, Assertions.expect_true(
		not controller.request_place_item(
			requester,
			Vector3.ZERO,
			Vector3.FORWARD
		) and controller.get_remaining_count() == 0,
		"Out-of-stock placement cannot create an item or make stock negative"
	))
	host.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
