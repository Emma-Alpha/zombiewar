extends RefCounted
class_name SimCombat

## 命中判定在 SimWorld 的僵尸状态上用确定性解算完成，
## 不查询 Godot 物理世界的射线接口。各客户端必然得到相同的击杀结果。
## 注：Step 8 的物理闸门按被禁 API 的字面名搜索整个 scripts/sim 且不区分代码与注释，
## 因此这句注释里不能出现那几个类名/方法名的字面写法。
const SimHitGeometryScript = preload("res://scripts/sim/sim_hit_geometry.gd")
const ExplosionMathScript = preload("res://scripts/combat/explosion_math.gd")

## 与 sim_world.gd 的 STATE_DEAD 同步；此处不引用全局类 SimWorld 以避免循环依赖：
## sim_world.gd 会 preload 本文件，若本文件再解析全局类 SimWorld
## （无论是签名里的类型标注，还是形如「SimWorld 点 STATE_DEAD」的常量访问），
## 就会形成 GDScript 循环类引用并在编辑器导入检查中报解析错误。
## 注：本文件内不得出现「SimWorld」后紧跟英文句点的写法，Step 8 的闸门按该模式搜索。
const STATE_DEAD := 3

## 返回按距离升序、同距按实体下标升序的命中列表，最多 maximum_targets 条。
## 元素：{index: int, distance: float, point: Vector2, height: float, zone: StringName}
static func resolve_ray_hits(
	world,                    # SimWorld，不加类型标注以避免与 sim_world.gd 的 preload 形成循环
	origin: Vector2,
	origin_height: float,
	direction: Vector2,
	max_distance: float,
	maximum_targets: int
) -> Array:
	var hits: Array = []
	if direction.length_squared() <= 0.000001 or max_distance <= 0.0:
		return hits
	var unit_direction := direction.normalized()
	var count: int = world.get_zombie_count()
	for index in range(count):
		if world.get_zombie_state(index) == STATE_DEAD:
			continue
		var zombie_height: float = world.get_zombie_height(index)
		if not SimHitGeometryScript.contains_height(zombie_height, origin_height):
			continue
		var distance := SimHitGeometryScript.ray_circle_distance(
			origin,
			unit_direction,
			world.get_zombie_position(index),
			SimHitGeometryScript.BODY_RADIUS,
			max_distance
		)
		if distance < 0.0:
			continue
		hits.append({
			"index": index,
			"distance": distance,
			"point": origin + unit_direction * distance,
			"height": origin_height,
			"zone": SimHitGeometryScript.zone_for_height(zombie_height, origin_height),
		})
	hits.sort_custom(_compare_hits)
	if hits.size() > maximum_targets:
		hits.resize(maxi(maximum_targets, 0))
	return hits

## 玩家近战：以 wielder 朝向为前向的矩形窗口，取最近的一只。
## 前向门限与 MeleeWeapon._resolve_melee_hit() 的 forward_distance 过滤一致。
static func resolve_melee_target(
	world,                    # SimWorld，同上：不加类型标注
	origin: Vector2,
	origin_height: float,
	aim_direction: Vector2,
	reach: float,
	half_width: float
) -> int:
	if aim_direction.length_squared() <= 0.000001:
		return -1
	var forward := aim_direction.normalized()
	var lateral := Vector2(-forward.y, forward.x)
	var lateral_limit := half_width + SimHitGeometryScript.BODY_RADIUS
	var best_index := -1
	var best_distance_squared := INF
	var count: int = world.get_zombie_count()
	for index in range(count):
		if world.get_zombie_state(index) == STATE_DEAD:
			continue
		var zombie_height: float = world.get_zombie_height(index)
		if not SimHitGeometryScript.contains_height(zombie_height, origin_height):
			continue
		var offset: Vector2 = world.get_zombie_position(index) - origin
		var forward_distance := offset.dot(forward)
		if forward_distance <= 0.0 or forward_distance > reach:
			continue
		if absf(offset.dot(lateral)) > lateral_limit:
			continue
		var distance_squared := offset.length_squared()
		if distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			best_index = index
	return best_index

## 爆炸的波及判定与伤害衰减。视觉与音效留在表现层。
## 元素：{index: int, damage: float, direction: Vector2, point: Vector2, height: float}
static func resolve_explosion_targets(
	world,                    # SimWorld，同上：不加类型标注
	origin: Vector2,
	origin_height: float,
	radius: float,
	center_damage: float,
	edge_damage: float
) -> Array:
	var affected: Array = []
	if radius <= 0.0:
		return affected
	var count: int = world.get_zombie_count()
	for index in range(count):
		if world.get_zombie_state(index) == STATE_DEAD:
			continue
		var position: Vector2 = world.get_zombie_position(index)
		var aim_height := SimHitGeometryScript.aim_point_height(
			world.get_zombie_height(index)
		)
		var planar_offset := position - origin
		var vertical_offset := aim_height - origin_height
		var distance := sqrt(
			planar_offset.length_squared() + vertical_offset * vertical_offset
		)
		var damage := ExplosionMathScript.damage_at_distance(
			distance, radius, center_damage, edge_damage
		)
		if damage <= 0.0:
			continue
		if not world.line_is_clear(origin, position):
			continue
		var direction := planar_offset
		if direction.length_squared() <= 0.000001:
			direction = Vector2(0.0, -1.0)
		else:
			direction = direction.normalized()
		affected.append({
			"index": index,
			"damage": damage,
			"direction": direction,
			"point": position,
			"height": aim_height,
		})
	return affected

static func _compare_hits(left: Dictionary, right: Dictionary) -> bool:
	var left_distance: float = left["distance"]
	var right_distance: float = right["distance"]
	if left_distance != right_distance:
		return left_distance < right_distance
	return int(left["index"]) < int(right["index"])
