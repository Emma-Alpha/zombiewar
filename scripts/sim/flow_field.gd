extends RefCounted
class_name FlowField

## 替代 300 个逐僵尸导航代理：以全部存活玩家为源做多源 BFS，
## 整数代价，生成到最近玩家的方向场。僵尸只查自己所在 cell，寻路成本与僵尸数量无关。
const UNREACHABLE := 0x7FFFFFFF

const ORTHOGONAL_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
]

const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, -1),
	Vector2i(1, 0),
	Vector2i(1, 1),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(-1, -1),
]

var grid: FlowFieldGrid
var cost := PackedInt32Array()
var direction_x := PackedFloat32Array()
var direction_z := PackedFloat32Array()
var direction_ready := PackedByteArray()
var last_sources := PackedInt32Array()
var rebuild_count := 0

func setup(value_grid: FlowFieldGrid) -> void:
	grid = value_grid
	var cell_count := grid.get_cell_count()
	cost = PackedInt32Array()
	cost.resize(cell_count)
	cost.fill(UNREACHABLE)
	direction_x = PackedFloat32Array()
	direction_x.resize(cell_count)
	direction_x.fill(0.0)
	direction_z = PackedFloat32Array()
	direction_z.resize(cell_count)
	direction_z.fill(0.0)
	direction_ready = PackedByteArray()
	direction_ready.resize(cell_count)
	direction_ready.fill(0)
	last_sources = PackedInt32Array()
	rebuild_count = 0

## 重算时机：任一玩家跨越 cell 边界（source 集合变化），或阻挡集合变脏。
## 调用方必须传入升序去重后的 cell index 数组。返回是否真的重算过。
func update(source_cell_indices: PackedInt32Array) -> bool:
	var grid_changed := grid.consume_dirty()
	if not grid_changed and source_cell_indices == last_sources:
		return false
	rebuild(source_cell_indices)
	return true

func rebuild(source_cell_indices: PackedInt32Array) -> void:
	rebuild_count += 1
	last_sources = source_cell_indices.duplicate()
	var cell_count := grid.get_cell_count()
	cost.fill(UNREACHABLE)
	direction_ready.fill(0)
	var queue := PackedInt32Array()
	queue.resize(cell_count)
	var queue_end := 0
	for source_index in source_cell_indices:
		if source_index < 0 or source_index >= cell_count:
			continue
		if cost[source_index] == 0:
			continue
		cost[source_index] = 0
		queue[queue_end] = source_index
		queue_end += 1
	var queue_head := 0
	var grid_width := grid.get_width()
	while queue_head < queue_end:
		var current_index := queue[queue_head]
		queue_head += 1
		var next_cost := cost[current_index] + 1
		var current_cell := Vector2i(
			current_index % grid_width,
			current_index / grid_width
		)
		for offset in ORTHOGONAL_OFFSETS:
			var neighbor := current_cell + offset
			var neighbor_index := grid.cell_index(neighbor)
			if neighbor_index < 0 or grid.is_blocked(neighbor):
				continue
			if cost[neighbor_index] <= next_cost:
				continue
			cost[neighbor_index] = next_cost
			queue[queue_end] = neighbor_index
			queue_end += 1

func get_cost(cell: Vector2i) -> int:
	var index := grid.cell_index(cell)
	return UNREACHABLE if index < 0 else cost[index]

func is_reachable(cell: Vector2i) -> bool:
	return get_cost(cell) != UNREACHABLE

func get_direction(cell: Vector2i) -> Vector2:
	var index := grid.cell_index(cell)
	if index < 0:
		return Vector2.ZERO
	if direction_ready[index] == 0:
		_compute_direction(index, cell)
	return Vector2(direction_x[index], direction_z[index])

func get_rebuild_count() -> int:
	return rebuild_count

func _compute_direction(index: int, cell: Vector2i) -> void:
	direction_ready[index] = 1
	direction_x[index] = 0.0
	direction_z[index] = 0.0
	var current_cost := cost[index]
	if current_cost == UNREACHABLE or current_cost == 0:
		return
	var best_cost := current_cost
	var best_offset := Vector2i.ZERO
	for offset in NEIGHBOR_OFFSETS:
		var neighbor := cell + offset
		var neighbor_index := grid.cell_index(neighbor)
		if neighbor_index < 0 or grid.is_blocked(neighbor):
			continue
		if offset.x != 0 and offset.y != 0:
			if grid.is_blocked(Vector2i(cell.x + offset.x, cell.y)):
				continue
			if grid.is_blocked(Vector2i(cell.x, cell.y + offset.y)):
				continue
		var neighbor_cost := cost[neighbor_index]
		if neighbor_cost < best_cost:
			best_cost = neighbor_cost
			best_offset = offset
	if best_offset == Vector2i.ZERO:
		return
	var direction := Vector2(float(best_offset.x), float(best_offset.y)).normalized()
	direction_x[index] = direction.x
	direction_z[index] = direction.y
