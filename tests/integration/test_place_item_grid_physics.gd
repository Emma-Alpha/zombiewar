extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PlaceItemGridScript = preload("res://scripts/gameplay/place_item_grid.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var host := Node3D.new()
	var grid := PlaceItemGridScript.new() as PlaceItemGrid
	host.add_child(grid)
	var obstacle := StaticBody3D.new()
	obstacle.position = Vector3(2.0, 0.5, 0.0)
	obstacle.rotation_degrees.y = 45.0
	var obstacle_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 1.0, 1.0)
	obstacle_shape.shape = box
	obstacle.add_child(obstacle_shape)
	host.add_child(obstacle)
	var requester := CharacterBody3D.new()
	requester.collision_layer = 2
	var requester_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.45
	capsule.height = 1.8
	requester_shape.position.y = 0.9
	requester_shape.shape = capsule
	requester.add_child(requester_shape)
	host.add_child(requester)
	var zombie_area := Area3D.new()
	zombie_area.position = Vector3(0.0, 0.9, -1.0)
	zombie_area.collision_layer = 4
	var zombie_shape := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = 0.45
	cylinder.height = 1.6
	zombie_shape.shape = cylinder
	zombie_area.add_child(zombie_shape)
	host.add_child(zombie_area)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)
	host.force_update_transform()
	var covered: Array[Vector2i] = grid.cells_for_collision_object(obstacle)
	_append(failures, Assertions.expect_true(
		Vector2i(2, 0) in covered and covered.size() > 1,
		"A rotated box conservatively covers multiple world-grid cells"
	))
	_append(failures, Assertions.expect_true(
		grid.register_obstacle(obstacle) and grid.is_cell_reserved(Vector2i(2, 0)),
		"A supported static collision reserves its covered cells"
	))
	_append(failures, Assertions.expect_true(
		grid.has_dynamic_blocker(
			requester.get_world_3d(),
			Vector2i(0, -1),
			[requester.get_rid()]
		),
		"A target-layer area temporarily blocks its grid cell"
	))
	_append(failures, Assertions.expect_true(
		not grid.has_dynamic_blocker(
			requester.get_world_3d(),
			Vector2i(0, 0),
			[requester.get_rid()]
		),
		"The requesting player RID is excluded from dynamic blocking"
	))
	obstacle.free()
	_append(failures, Assertions.expect_true(
		not grid.is_cell_reserved(Vector2i(2, 0)),
		"A registered obstacle releases its grid cells when it exits"
	))
	host.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
