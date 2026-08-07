extends RefCounted
class_name FlowFieldGrid

## XZ 平面的整数阻挡网格。与 PlaceItemGrid 的网格语义对齐（同样的 cell 边长），
## 但是独立实例：它保存的是「僵尸能否通过」，不是「放置位是否被占」。
const DEFAULT_CELL_SIZE := 1.0

var origin := Vector2.ZERO
var cell_size := DEFAULT_CELL_SIZE
var width := 0
var height := 0
var blocked := PackedByteArray()
var dirty := true

func configure(
	value_origin: Vector2,
	value_cell_size: float,
	value_width: int,
	value_height: int
) -> void:
	origin = value_origin
	cell_size = maxf(value_cell_size, 0.001)
	width = maxi(value_width, 1)
	height = maxi(value_height, 1)
	blocked = PackedByteArray()
	blocked.resize(width * height)
	blocked.fill(0)
	dirty = true

func get_cell_size() -> float:
	return cell_size

func get_width() -> int:
	return width

func get_height() -> int:
	return height

func get_cell_count() -> int:
	return width * height

func get_blocked_bytes() -> PackedByteArray:
	return blocked

func world_to_cell(world_xz: Vector2) -> Vector2i:
	return Vector2i(
		floori((world_xz.x - origin.x) / cell_size),
		floori((world_xz.y - origin.y) / cell_size)
	)

func cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(
		origin.x + (float(cell.x) + 0.5) * cell_size,
		origin.y + (float(cell.y) + 0.5) * cell_size
	)

func is_inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height

func cell_index(cell: Vector2i) -> int:
	return cell.y * width + cell.x if is_inside(cell) else -1

func index_to_cell(index: int) -> Vector2i:
	if index < 0 or index >= width * height:
		return Vector2i(-1, -1)
	return Vector2i(index % width, index / width)

## 网格外一律视为阻挡，BFS 与碰撞都靠这条把僵尸关在场内。
func is_blocked(cell: Vector2i) -> bool:
	var index := cell_index(cell)
	return true if index < 0 else blocked[index] == 1

func set_blocked(cell: Vector2i, value: bool) -> bool:
	var index := cell_index(cell)
	if index < 0:
		return false
	var next_value := 1 if value else 0
	if blocked[index] == next_value:
		return false
	blocked[index] = next_value
	dirty = true
	return true

## 运行时增删阻挡几何统一走这里：任何改变都会置脏，下一 tick 触发流场重算。
## 最大角按半开区间处理：`world_to_cell()` 用 floori，落在 cell 边界上的最大角本身属于下一个
## cell，而矩形并没有真的盖住它。因此最大角先内缩千分之一个 cell 再取整，否则每面 +X / +Z 边
## 都会多阻挡一整行；DemoArena 的原点 -24.5 让 cell 边界正好落在半整数世界坐标上，也正是轴对齐
## 墙体范围的落点，不内缩的话几乎每面墙都会多堵一行。退化矩形则夹回最小 cell，至少标记一格。
func set_blocked_world_rect(min_xz: Vector2, max_xz: Vector2, value: bool) -> bool:
	var low_cell := world_to_cell(
		Vector2(minf(min_xz.x, max_xz.x), minf(min_xz.y, max_xz.y))
	)
	var high_corner := Vector2(maxf(min_xz.x, max_xz.x), maxf(min_xz.y, max_xz.y))
	var high_cell := world_to_cell(
		high_corner - Vector2(cell_size * 0.001, cell_size * 0.001)
	)
	high_cell = Vector2i(
		maxi(high_cell.x, low_cell.x),
		maxi(high_cell.y, low_cell.y)
	)
	var changed := false
	for cell_z in range(low_cell.y, high_cell.y + 1):
		for cell_x in range(low_cell.x, high_cell.x + 1):
			changed = set_blocked(Vector2i(cell_x, cell_z), value) or changed
	return changed

func mark_dirty() -> void:
	dirty = true

func consume_dirty() -> bool:
	if not dirty:
		return false
	dirty = false
	return true
