extends RefCounted
class_name SimCollision

## 替代僵尸的角色体逐帧移动与滑行解算。
## 僵尸建模为 XZ 平面上的圆 + 高度标量；2.5D 平地场景不需要斜坡与台阶解算。
## 空间哈希只做键值查找，绝不遍历 Dictionary：所有配对遍历按实体下标升序，
## 而下标顺序即 id 顺序（SimWorld 保证压缩删除时保持顺序）。
const DEFAULT_HASH_CELL_SIZE := 1.0
const HASH_ORIGIN_BIAS := 32768
const HASH_ROW_STRIDE := 65536

static func hash_key(cell_x: int, cell_z: int) -> int:
	return (cell_z + HASH_ORIGIN_BIAS) * HASH_ROW_STRIDE + (cell_x + HASH_ORIGIN_BIAS)

## 桶内下标天然升序：插入按 index 升序进行。
static func build_spatial_hash(
	positions: PackedVector2Array,
	count: int,
	hash_cell_size: float
) -> Dictionary:
	var buckets: Dictionary = {}
	var size := maxf(hash_cell_size, 0.001)
	for index in range(count):
		var position := positions[index]
		var key := hash_key(floori(position.x / size), floori(position.y / size))
		if not buckets.has(key):
			buckets[key] = PackedInt32Array()
		var bucket: PackedInt32Array = buckets[key]
		bucket.append(index)
	return buckets

## 返回每个实体的互推位移。外层 i 升序、内层只处理 j > i、九宫格顺序固定，
## 因此浮点累加顺序完全确定。
static func accumulate_separation(
	positions: PackedVector2Array,
	radii: PackedFloat32Array,
	count: int,
	hash_cell_size: float,
	separation_ratio: float
) -> PackedVector2Array:
	var displacement := PackedVector2Array()
	displacement.resize(count)
	displacement.fill(Vector2.ZERO)
	if count <= 0:
		return displacement
	var size := maxf(hash_cell_size, 0.001)
	var buckets := build_spatial_hash(positions, count, size)
	var ratio := clampf(separation_ratio, 0.0, 1.0)
	var empty_bucket := PackedInt32Array()
	for index in range(count):
		var radius := radii[index]
		if radius <= 0.0:
			continue
		var position := positions[index]
		var cell_x := floori(position.x / size)
		var cell_z := floori(position.y / size)
		for offset_z in range(-1, 2):
			for offset_x in range(-1, 2):
				var bucket: PackedInt32Array = buckets.get(
					hash_key(cell_x + offset_x, cell_z + offset_z),
					empty_bucket
				)
				for other_index in bucket:
					if other_index <= index:
						continue
					var other_radius := radii[other_index]
					if other_radius <= 0.0:
						continue
					var offset := positions[other_index] - position
					var combined := radius + other_radius
					var distance_squared := offset.length_squared()
					if distance_squared >= combined * combined:
						continue
					var push := Vector2.ZERO
					if distance_squared <= 0.000001:
						push = Vector2(combined * 0.5 * ratio, 0.0)
					else:
						var distance := sqrt(distance_squared)
						push = offset / distance * ((combined - distance) * 0.5 * ratio)
					displacement[index] -= push
					displacement[other_index] += push
	return displacement

## 圆 vs 圆的单向推开：调用方被推开，另一方不动。
## 玩家位置是只读输入，僵尸被玩家推开而玩家不被模拟层反推。
static func resolve_circle_push(
	position: Vector2,
	radius: float,
	other_position: Vector2,
	other_radius: float
) -> Vector2:
	var offset := position - other_position
	var combined := radius + other_radius
	var distance_squared := offset.length_squared()
	if distance_squared >= combined * combined:
		return Vector2.ZERO
	if distance_squared <= 0.000001:
		return Vector2(combined, 0.0)
	var distance := sqrt(distance_squared)
	return offset / distance * (combined - distance)

## 圆 vs 阻挡 cell（轴对齐正方形），不做任何物理空间查询。
## 九宫格顺序固定，逐个 cell 累加修正量。
static func resolve_blocker(
	position: Vector2,
	radius: float,
	grid: FlowFieldGrid
) -> Vector2:
	var correction := Vector2.ZERO
	if radius <= 0.0:
		return correction
	var half := grid.get_cell_size() * 0.5
	var center_cell := grid.world_to_cell(position)
	for offset_z in range(-1, 2):
		for offset_x in range(-1, 2):
			var cell := Vector2i(center_cell.x + offset_x, center_cell.y + offset_z)
			if not grid.is_blocked(cell):
				continue
			var cell_center := grid.cell_to_world(cell)
			var probe := position + correction
			var closest := Vector2(
				clampf(probe.x, cell_center.x - half, cell_center.x + half),
				clampf(probe.y, cell_center.y - half, cell_center.y + half)
			)
			var offset := probe - closest
			var distance_squared := offset.length_squared()
			if distance_squared >= radius * radius:
				continue
			if distance_squared <= 0.000001:
				var to_center := probe - cell_center
				var push_x := (half + radius) - absf(to_center.x)
				var push_z := (half + radius) - absf(to_center.y)
				if push_x <= push_z:
					correction.x += push_x if to_center.x >= 0.0 else -push_x
				else:
					correction.y += push_z if to_center.y >= 0.0 else -push_z
				continue
			var distance := sqrt(distance_squared)
			correction += offset / distance * (radius - distance)
	return correction
