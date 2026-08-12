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
var base_static_blocked := PackedByteArray()
var base_entity_blocked := PackedByteArray()
var static_blocker_count := PackedInt32Array()
var entity_blocker_count := PackedInt32Array()
## `blocked` 的子集：只含**静态几何**（墙、集装箱、路障、放置件、拾取箱），
## 不含模拟层自己用解析几何求解的实体（爆炸桶）。
## 分成两张图是必须的：`SimWorld.ray_blocked_distance()` 把子弹截到「第一个阻挡 cell 的
## **中心**」，那个点比 cell 里那件几何的真实表面更近。油桶自己的格若参与截断，
## 射程会停在桶的碰撞圆之前，桶就永远打不中——直径 0.88 m 的桶只要中心不在 cell 中心
## （场景里的 ChainA/ChainB 在 z = -3.5，正好压在 cell 边界上）就必然踩到。
## 油桶该在哪里挡住子弹，由 SimCombat 用桶自己的解析圆决定，不由格子代劳。
var static_blocked := PackedByteArray()
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
	base_static_blocked = PackedByteArray()
	base_static_blocked.resize(width * height)
	base_static_blocked.fill(0)
	base_entity_blocked = PackedByteArray()
	base_entity_blocked.resize(width * height)
	base_entity_blocked.fill(0)
	static_blocker_count = PackedInt32Array()
	static_blocker_count.resize(width * height)
	static_blocker_count.fill(0)
	entity_blocker_count = PackedInt32Array()
	entity_blocker_count.resize(width * height)
	entity_blocker_count.fill(0)
	static_blocked = PackedByteArray()
	static_blocked.resize(width * height)
	static_blocked.fill(0)
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

func get_static_blocked_bytes() -> PackedByteArray:
	return static_blocked

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

## 只看静态几何。网格外同样视为阻挡：子弹不该飞出场地。
func is_static_blocked(cell: Vector2i) -> bool:
	var index := cell_index(cell)
	return true if index < 0 else static_blocked[index] == 1

func set_blocked(cell: Vector2i, value: bool) -> bool:
	return _write_base_cell(cell, value, true)

## 只写通行图、不写静态阻挡图。供爆炸桶这类「模拟层用解析几何自行终止子弹」的实体使用：
## 它们仍然挡住僵尸的移动与视线，但不参与 `ray_blocked_distance()` 的射程截断。
func set_entity_blocked(cell: Vector2i, value: bool) -> bool:
	return _write_base_cell(cell, value, false)

func _write_base_cell(cell: Vector2i, value: bool, affects_static: bool) -> bool:
	var index := cell_index(cell)
	if index < 0:
		return false
	var next_value := 1 if value else 0
	if affects_static:
		if base_static_blocked[index] == next_value:
			return false
		base_static_blocked[index] = next_value
	else:
		if base_entity_blocked[index] == next_value:
			return false
		base_entity_blocked[index] = next_value
	return _refresh_cell(index)

func _change_runtime_cell(cell: Vector2i, delta: int, affects_static: bool) -> bool:
	var index := cell_index(cell)
	if index < 0:
		return false
	var previous_count := (
		static_blocker_count[index] if affects_static else entity_blocker_count[index]
	)
	var next_count := previous_count + delta
	if next_count < 0:
		push_error(
			"FlowFieldGrid blocker count underflow at cell %s (%s)"
			% [cell, "static" if affects_static else "entity"]
		)
		next_count = 0
	if previous_count == next_count:
		return false
	if affects_static:
		static_blocker_count[index] = next_count
	else:
		entity_blocker_count[index] = next_count
	return _refresh_cell(index)

func _refresh_cell(index: int) -> bool:
	var next_static := (
		base_static_blocked[index] == 1 or static_blocker_count[index] > 0
	)
	var next_blocked := (
		next_static or
		base_entity_blocked[index] == 1 or
		entity_blocker_count[index] > 0
	)
	var static_value := 1 if next_static else 0
	var blocked_value := 1 if next_blocked else 0
	var static_changed := static_blocked[index] != static_value
	var blocked_changed := blocked[index] != blocked_value
	static_blocked[index] = static_value
	blocked[index] = blocked_value
	if blocked_changed:
		dirty = true
	return static_changed or blocked_changed

## 运行时增删阻挡几何统一走这里：只有最终通行布尔值改变才置脏，下一 tick 重算流场。
## 最大角按半开区间处理：`world_to_cell()` 用 floori，落在 cell 边界上的最大角本身属于下一个
## cell，而矩形并没有真的盖住它。因此最大角先内缩千分之一个 cell 再取整，否则每面 +X / +Z 边
## 都会多阻挡一整行；DemoMap 的原点 -24.5 让 cell 边界正好落在半整数世界坐标上，也正是轴对齐
## 墙体范围的落点，不内缩的话几乎每面墙都会多堵一行。退化矩形则夹回最小 cell，至少标记一格。
func set_blocked_world_rect(min_xz: Vector2, max_xz: Vector2, value: bool) -> bool:
	return _write_base_world_rect(min_xz, max_xz, value, true)

## 只写通行图的矩形版本，语义同 `set_entity_blocked()`。
func set_entity_blocked_world_rect(
	min_xz: Vector2, max_xz: Vector2, value: bool
) -> bool:
	return _write_base_world_rect(min_xz, max_xz, value, false)

func add_static_blocker_world_rect(min_xz: Vector2, max_xz: Vector2) -> bool:
	return _change_runtime_world_rect(min_xz, max_xz, 1, true)

func remove_static_blocker_world_rect(min_xz: Vector2, max_xz: Vector2) -> bool:
	return _change_runtime_world_rect(min_xz, max_xz, -1, true)

func add_entity_blocker_world_rect(min_xz: Vector2, max_xz: Vector2) -> bool:
	return _change_runtime_world_rect(min_xz, max_xz, 1, false)

func remove_entity_blocker_world_rect(min_xz: Vector2, max_xz: Vector2) -> bool:
	return _change_runtime_world_rect(min_xz, max_xz, -1, false)

func _write_base_world_rect(
	min_xz: Vector2, max_xz: Vector2, value: bool, affects_static: bool
) -> bool:
	var bounds := _world_rect_cell_bounds(min_xz, max_xz)
	var low_cell: Vector2i = bounds[0]
	var high_cell: Vector2i = bounds[1]
	var changed := false
	for cell_z in range(low_cell.y, high_cell.y + 1):
		for cell_x in range(low_cell.x, high_cell.x + 1):
			changed = _write_base_cell(
				Vector2i(cell_x, cell_z), value, affects_static
			) or changed
	return changed

func _change_runtime_world_rect(
	min_xz: Vector2, max_xz: Vector2, delta: int, affects_static: bool
) -> bool:
	var bounds := _world_rect_cell_bounds(min_xz, max_xz)
	var low_cell: Vector2i = bounds[0]
	var high_cell: Vector2i = bounds[1]
	var changed := false
	for cell_z in range(low_cell.y, high_cell.y + 1):
		for cell_x in range(low_cell.x, high_cell.x + 1):
			changed = _change_runtime_cell(
				Vector2i(cell_x, cell_z), delta, affects_static
			) or changed
	return changed

func _world_rect_cell_bounds(min_xz: Vector2, max_xz: Vector2) -> Array[Vector2i]:
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
	return [low_cell, high_cell]

func mark_dirty() -> void:
	dirty = true

func consume_dirty() -> bool:
	if not dirty:
		return false
	dirty = false
	return true
