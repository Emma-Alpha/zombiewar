extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PlaceItemGridScript = preload("res://scripts/gameplay/place_item_grid.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var grid := PlaceItemGridScript.new() as PlaceItemGrid
	grid.cell_size = 1.0
	grid.grid_origin = Vector3.ZERO
	_append(failures, Assertions.expect_equal(
		grid.world_to_cell(Vector3(1.49, 0.0, -2.49)),
		Vector2i(1, -2),
		"World positions round to the nearest one-meter cell"
	))
	_append(failures, Assertions.expect_equal(
		grid.cell_to_world(Vector2i(-3, 4)),
		Vector3(-3.0, 0.0, 4.0),
		"Cell centers align with the configured world origin"
	))
	var directions := {
		Vector3(0.0, 0.0, -1.0): Vector2i(0, -1),
		Vector3(1.0, 0.0, -1.0): Vector2i(1, -1),
		Vector3(1.0, 0.0, 0.0): Vector2i(1, 0),
		Vector3(1.0, 0.0, 1.0): Vector2i(1, 1),
		Vector3(0.0, 0.0, 1.0): Vector2i(0, 1),
		Vector3(-1.0, 0.0, 1.0): Vector2i(-1, 1),
		Vector3(-1.0, 0.0, 0.0): Vector2i(-1, 0),
		Vector3(-1.0, 0.0, -1.0): Vector2i(-1, -1),
	}
	for direction in directions:
		_append(failures, Assertions.expect_equal(
			grid.facing_step(direction),
			directions[direction],
			"Facing maps to the expected adjacent cell: %s" % direction
		))
	_append(failures, Assertions.expect_equal(
		grid.facing_step(Vector3.ZERO),
		Vector2i.ZERO,
		"Zero facing produces no placement step"
	))
	var first := Node.new()
	var second := Node.new()
	_append(failures, Assertions.expect_true(
		grid.reserve_cells(first, [Vector2i(2, 3)]) and
		grid.is_cell_reserved(Vector2i(2, 3)) and
		not grid.reserve_cells(second, [Vector2i(2, 3)]),
		"A reserved cell rejects a different owner"
	))
	_append(failures, Assertions.expect_true(
		grid.release_owner(first) and
		not grid.is_cell_reserved(Vector2i(2, 3)) and
		grid.reserve_cells(second, [Vector2i(2, 3)]),
		"Releasing an owner makes its cells reusable"
	))
	first.free()
	second.free()
	grid.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
