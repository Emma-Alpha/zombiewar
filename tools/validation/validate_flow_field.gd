extends SceneTree

const FlowFieldGridScript = preload("res://scripts/sim/flow_field_grid.gd")
const FlowFieldScript = preload("res://scripts/sim/flow_field.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_grid_mapping(failures)
	_check_world_rect_blocking(failures)
	_check_single_source_matches_reference(failures)
	_check_multi_source_is_minimum(failures)
	_check_walls_and_unreachable(failures)
	_check_dirty_triggers_rebuild(failures)
	_check_direction_rules(failures)
	_finish(failures)

func _check_grid_mapping(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	_expect(grid.get_cell_count() == 49 * 39, "grid must allocate width * height cells", failures)
	_expect(
		grid.world_to_cell(Vector2(-24.0, -19.0)) == Vector2i(0, 0),
		"the first cell must contain the arena's minimum corner",
		failures
	)
	_expect(
		grid.cell_to_world(Vector2i(0, 0)).is_equal_approx(Vector2(-24.0, -19.0)),
		"cell centres must land on integer world coordinates",
		failures
	)
	_expect(
		grid.cell_to_world(grid.world_to_cell(Vector2(7.0, -3.0))).is_equal_approx(
			Vector2(7.0, -3.0)
		),
		"world -> cell -> world must round-trip on cell centres",
		failures
	)
	_expect(grid.is_blocked(Vector2i(-1, 0)), "outside cells must read as blocked", failures)
	_expect(grid.cell_index(Vector2i(49, 0)) == -1, "outside cells must have no index", failures)

## 世界矩形 -> cell 的覆盖必须是半开区间：落在 cell 边界上的最大角属于下一个 cell，
## 而矩形并没有盖住它。DemoArena 的原点让 cell 边界落在半整数世界坐标上，正是轴对齐墙体
## 范围的落点，所以边界处多阻挡一行会影响几乎每一面墙，这里逐格对齐地锁死覆盖集合。
func _check_world_rect_blocking(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	_expect(
		grid.set_blocked_world_rect(Vector2(-20.5, -15.5), Vector2(-16.5, -13.5), true),
		"blocking a fresh world rect must report a change",
		failures
	)
	var wall_cells := _blocked_cells(grid)
	_expect(
		wall_cells.size() == 8,
		"a 4 x 2 world rect must block exactly 8 cells (got %d)" % wall_cells.size(),
		failures
	)
	var expected_wall: Array[Vector2i] = []
	for cell_z in range(4, 6):
		for cell_x in range(4, 8):
			expected_wall.append(Vector2i(cell_x, cell_z))
	_expect(
		wall_cells == expected_wall,
		"a 4 x 2 world rect must block exactly cells (4..7, 4..5), got %s" % [wall_cells],
		failures
	)
	_expect(
		not grid.set_blocked_world_rect(Vector2(-20.5, -15.5), Vector2(-16.5, -13.5), true),
		"re-blocking an unchanged rect must report no change",
		failures
	)
	_expect(
		grid.set_blocked_world_rect(Vector2(-16.5, -13.5), Vector2(-20.5, -15.5), false),
		"corner order must not matter when clearing the same rect",
		failures
	)
	_expect(
		_blocked_cells(grid).is_empty(),
		"clearing the rect must release exactly the cells it took",
		failures
	)

	var single = FlowFieldGridScript.new()
	single.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	single.set_blocked_world_rect(Vector2(-24.5, -19.5), Vector2(-23.5, -18.5), true)
	var single_cells := _blocked_cells(single)
	_expect(
		single_cells.size() == 1 and single_cells[0] == Vector2i(0, 0),
		"a one-cell world rect must block exactly cell (0, 0), got %s" % [single_cells],
		failures
	)

	var partial = FlowFieldGridScript.new()
	partial.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	partial.set_blocked_world_rect(Vector2(-20.5, -15.5), Vector2(-16.2, -13.5), true)
	_expect(
		_blocked_cells(partial).size() == 10,
		"a rect reaching into the next cell must block that cell too (got %d)"
			% _blocked_cells(partial).size(),
		failures
	)

	var degenerate = FlowFieldGridScript.new()
	degenerate.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	degenerate.set_blocked_world_rect(Vector2(-20.5, -15.5), Vector2(-20.5, -15.5), true)
	var degenerate_cells := _blocked_cells(degenerate)
	_expect(
		degenerate_cells.size() == 1 and degenerate_cells[0] == Vector2i(4, 4),
		"a degenerate rect must still mark the one cell holding it, got %s" % [degenerate_cells],
		failures
	)

	var clipped = FlowFieldGridScript.new()
	clipped.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	clipped.set_blocked_world_rect(Vector2(-30.0, -25.0), Vector2(-23.5, -18.5), true)
	var clipped_cells := _blocked_cells(clipped)
	_expect(
		clipped_cells.size() == 1 and clipped_cells[0] == Vector2i(0, 0),
		"cells outside the grid must be clipped away, got %s" % [clipped_cells],
		failures
	)

	var dirty_grid = FlowFieldGridScript.new()
	dirty_grid.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	dirty_grid.consume_dirty()
	dirty_grid.set_blocked_world_rect(Vector2(-20.5, -15.5), Vector2(-16.5, -13.5), true)
	_expect(
		dirty_grid.consume_dirty(),
		"blocking a world rect must leave the grid dirty",
		failures
	)

func _blocked_cells(grid) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var bytes: PackedByteArray = grid.get_blocked_bytes()
	for index in range(bytes.size()):
		if bytes[index] == 1:
			var cell: Vector2i = grid.index_to_cell(index)
			cells.append(cell)
	return cells

func _check_single_source_matches_reference(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2.ZERO, 1.0, 12, 9)
	for cell_z in range(1, 7):
		grid.set_blocked(Vector2i(5, cell_z), true)
	var field = FlowFieldScript.new()
	field.setup(grid)
	var sources := PackedInt32Array([grid.cell_index(Vector2i(0, 0))])
	field.rebuild(sources)
	var reference := _reference_costs(grid, sources)
	var mismatches := 0
	for cell_z in range(grid.get_height()):
		for cell_x in range(grid.get_width()):
			var cell := Vector2i(cell_x, cell_z)
			if field.get_cost(cell) != reference[grid.cell_index(cell)]:
				mismatches += 1
	_expect(mismatches == 0, "BFS costs must match the naive reference (%d mismatches)" % mismatches, failures)

func _check_multi_source_is_minimum(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2.ZERO, 1.0, 15, 11)
	var field = FlowFieldScript.new()
	field.setup(grid)
	var first_source := grid.cell_index(Vector2i(0, 0))
	var second_source := grid.cell_index(Vector2i(14, 10))
	var combined := PackedInt32Array([first_source, second_source])
	combined.sort()
	field.rebuild(combined)
	var first_only := _reference_costs(grid, PackedInt32Array([first_source]))
	var second_only := _reference_costs(grid, PackedInt32Array([second_source]))
	var mismatches := 0
	for index in range(grid.get_cell_count()):
		var expected: int = mini(first_only[index], second_only[index])
		if field.get_cost(grid.index_to_cell(index)) != expected:
			mismatches += 1
	_expect(
		mismatches == 0,
		"multi-source BFS must equal the per-source minimum (%d mismatches)" % mismatches,
		failures
	)

func _check_walls_and_unreachable(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2.ZERO, 1.0, 9, 9)
	for cell_z in range(9):
		grid.set_blocked(Vector2i(4, cell_z), true)
	var field = FlowFieldScript.new()
	field.setup(grid)
	field.rebuild(PackedInt32Array([grid.cell_index(Vector2i(0, 0))]))
	_expect(field.is_reachable(Vector2i(3, 8)), "cells on the source side must stay reachable", failures)
	_expect(
		not field.is_reachable(Vector2i(5, 0)),
		"a full wall must leave the far side unreachable",
		failures
	)
	_expect(
		field.get_cost(Vector2i(5, 0)) == FlowFieldScript.UNREACHABLE,
		"unreachable cells must report UNREACHABLE",
		failures
	)
	_expect(
		field.get_direction(Vector2i(5, 0)) == Vector2.ZERO,
		"unreachable cells must produce no direction",
		failures
	)
	_expect(
		not field.is_reachable(Vector2i(4, 4)),
		"blocked cells must never receive a cost",
		failures
	)

func _check_dirty_triggers_rebuild(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2.ZERO, 1.0, 9, 9)
	var field = FlowFieldScript.new()
	field.setup(grid)
	var sources := PackedInt32Array([grid.cell_index(Vector2i(0, 4))])
	_expect(field.update(sources), "the first update must rebuild", failures)
	var after_first := field.get_rebuild_count()
	_expect(not field.update(sources), "an unchanged update must not rebuild", failures)
	_expect(field.get_rebuild_count() == after_first, "rebuild count must stay put", failures)

	for cell_z in range(9):
		grid.set_blocked(Vector2i(4, cell_z), true)
	_expect(field.update(sources), "a dirty blocker set must force a rebuild", failures)
	_expect(
		not field.is_reachable(Vector2i(8, 4)),
		"the rebuilt field must respect the new wall",
		failures
	)
	grid.set_blocked(Vector2i(4, 4), false)
	_expect(field.update(sources), "opening a gap must force a rebuild", failures)
	_expect(
		field.is_reachable(Vector2i(8, 4)),
		"the rebuilt field must route through the reopened gap",
		failures
	)
	var moved := PackedInt32Array([grid.cell_index(Vector2i(1, 4))])
	_expect(field.update(moved), "a source crossing a cell boundary must force a rebuild", failures)

func _check_direction_rules(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2.ZERO, 1.0, 7, 7)
	var field = FlowFieldScript.new()
	field.setup(grid)
	field.rebuild(PackedInt32Array([grid.cell_index(Vector2i(0, 0))]))
	_expect(
		field.get_direction(Vector2i(0, 0)) == Vector2.ZERO,
		"the source cell must produce no direction",
		failures
	)
	var descending := field.get_direction(Vector2i(3, 3))
	_expect(
		field.get_cost(Vector2i(3, 3) + Vector2i(roundi(descending.x), roundi(descending.y)))
			< field.get_cost(Vector2i(3, 3)),
		"the direction must point at a strictly cheaper neighbour",
		failures
	)
	var repeated := field.get_direction(Vector2i(3, 3))
	_expect(repeated == descending, "cached directions must be stable", failures)

	var corner_grid = FlowFieldGridScript.new()
	corner_grid.configure(Vector2.ZERO, 1.0, 5, 5)
	corner_grid.set_blocked(Vector2i(1, 2), true)
	corner_grid.set_blocked(Vector2i(2, 1), true)
	var corner_field = FlowFieldScript.new()
	corner_field.setup(corner_grid)
	corner_field.rebuild(PackedInt32Array([corner_grid.cell_index(Vector2i(1, 1))]))
	_expect(
		corner_field.get_direction(Vector2i(2, 2)) != Vector2(-1.0, -1.0).normalized(),
		"diagonal steps must not cut between two blocked orthogonal neighbours",
		failures
	)

func _reference_costs(grid, sources: PackedInt32Array) -> PackedInt32Array:
	var costs := PackedInt32Array()
	costs.resize(grid.get_cell_count())
	costs.fill(FlowFieldScript.UNREACHABLE)
	var frontier: Array[Vector2i] = []
	for source_index in sources:
		costs[source_index] = 0
		frontier.append(grid.index_to_cell(source_index))
	var distance := 0
	while not frontier.is_empty():
		distance += 1
		var next_frontier: Array[Vector2i] = []
		for cell in frontier:
			for offset in FlowFieldScript.ORTHOGONAL_OFFSETS:
				var neighbor: Vector2i = cell + offset
				var neighbor_index: int = grid.cell_index(neighbor)
				if neighbor_index < 0 or grid.is_blocked(neighbor):
					continue
				if costs[neighbor_index] <= distance:
					continue
				costs[neighbor_index] = distance
				next_frontier.append(neighbor)
		frontier = next_frontier
	return costs

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_flow_field: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
