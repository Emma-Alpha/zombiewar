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

## 与 sim_world.gd 的 BARREL_STATE_* 同步，理由同 STATE_DEAD：本文件不得引用全局类。
const BARREL_STATE_PENDING := 2
const BARREL_STATE_DESTROYED := 3

## 命中条目的实体类别。射线求解同时吐僵尸与油桶，调用方按 kind 分派。
const KIND_ZOMBIE: StringName = &"zombie"
const KIND_BARREL: StringName = &"barrel"

## 返回按距离升序、同距先僵尸后油桶、再按实体下标升序的命中列表。
## 元素：{kind: StringName, index: int, distance: float, point: Vector2,
##        height: float, zone: StringName}
## 僵尸与油桶参与**同一次**射线求解：基线的物理射线一次性看见两者，
## 打中油桶（层 1 的 StaticBody3D）后 break，不再穿透后面的目标，
## 因此这里在排序后遇到第一个油桶就收尾，油桶条目必定是最后一条。
## maximum_targets 只约束僵尸的穿透条数（等价基线的 maximum_zombie_hits），
## 油桶不占穿透名额——基线打中油桶那一支根本没走 zombie_hit_count 的计数。
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
		var hit_point := origin + unit_direction * distance
		# 基线远程武器的 hit_mask 是 hit_collision_mask 或上 1，
		# 物理射线命中第一个 collider 即停，层 1 的世界静态体会把子弹挡下。
		# 模拟层用与 resolve_explosion_targets() 相同的视线闸门复刻掩体。
		if not world.line_is_clear(origin, hit_point):
			continue
		hits.append({
			"kind": KIND_ZOMBIE,
			"index": index,
			"distance": distance,
			"point": hit_point,
			"height": origin_height,
			"zone": SimHitGeometryScript.zone_for_height(zombie_height, origin_height),
		})
	_append_barrel_hits(
		world, origin, origin_height, unit_direction, max_distance, hits
	)
	hits.sort_custom(_compare_hits)
	var resolved: Array = []
	var zombie_hits := 0
	for hit in hits:
		if hit["kind"] == KIND_BARREL:
			resolved.append(hit)
			break
		if zombie_hits >= maximum_targets:
			break
		resolved.append(hit)
		zombie_hits += 1
	return resolved

## 油桶候选。刻意**不做** line_is_clear 判定：油桶自身就是流场通行图里的阻挡 cell
## （spawn_barrel() 标记，引爆/移除时清除），视线闸门会被油桶自己占的格挡掉，
## 跨 cell 边界的桶甚至会自己挡住自己。
## 掩体判定由调用方承担：sim_world._resolve_shot_event() 先用
## ray_blocked_distance() 把射程截到第一个**静态**阻挡 cell（墙、集装箱、路障、
## 放置件、拾取箱），落在 max_distance 之内的油桶必然没有被静态几何挡住。
## 油桶自己的格**不在**那张静态图里：截断点是 cell 中心，比桶的碰撞圆表面更近，
## 桶的格若参与截断，射线会停在桶前面，桶永远打不爆。
## 「桶挡住桶」由本函数与 resolve_ray_hits() 的排序收尾共同完成：
## 两只桶都会被收进候选，排序后只保留最近的那一只，等价基线物理射线停在第一个圆柱面上。
## 状态闸门是 DESTROYED 而不是 PENDING：基线里已进入 EXPLODING 的桶碰撞体仍然启用，
## 子弹照样被它挡下（apply_hit() 返回 miss），只有真正炸掉才 disable 碰撞体。
static func _append_barrel_hits(
	world,                    # SimWorld，同上：不加类型标注
	origin: Vector2,
	origin_height: float,
	unit_direction: Vector2,
	max_distance: float,
	hits: Array
) -> void:
	var count: int = world.get_barrel_count()
	for index in range(count):
		if world.get_barrel_state(index) >= BARREL_STATE_DESTROYED:
			continue
		if not SimHitGeometryScript.barrel_contains_height(
			world.get_barrel_base_height(index), origin_height
		):
			continue
		var distance := SimHitGeometryScript.ray_circle_distance(
			origin,
			unit_direction,
			world.get_barrel_position(index),
			SimHitGeometryScript.BARREL_RADIUS,
			max_distance
		)
		if distance < 0.0:
			continue
		hits.append({
			"kind": KIND_BARREL,
			"index": index,
			"distance": distance,
			"point": origin + unit_direction * distance,
			"height": origin_height,
			"zone": SimHitGeometryScript.ZONE_BARREL,
		})

## 玩家近战：以 wielder 朝向为前向的矩形窗口，取最近的一只。
## 前向门限与 MeleeWeapon._resolve_melee_hit() 的 forward_distance 过滤一致。
## 刻意不做视线判定：基线 MeleeWeapon 的 query.collision_mask 是裸的 hit_collision_mask
## （knife.tres 未覆盖 → 默认 4，只有僵尸 hitbox 层，没有远程那句 `| 1`）
## 且 collide_with_bodies=false，世界几何本就不参与近战判定。此处补遮挡反而会偏离基线。
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

## 爆炸对其他油桶的波及判定：返回应被点燃的油桶下标，按下标升序。
## 与僵尸口径有两处刻意的不同，都取自基线 ExplosionResolver：
##   1. 距离用目标桶的**原点**（基线 `origin.distance_to(target.global_position)`，
##      y = 桶底），不是瞄准点；瞄准点只用在遮挡射线上。
##   2. 只判「够不够得到」，不产出伤害数值——基线 apply_explosion_damage()
##      只看 amount > 0，油桶没有血量。
## 遮挡沿用 line_is_clear()：基线 _is_blocked() 用 obstacle_mask = 1 打一条到
## 目标瞄准点的射线，命中目标自己不算挡。line_is_clear() 的终点 cell 豁免规则
## 与之等价。爆源自己的阻挡格由 SimWorld 在调用本函数之前就已清除，
## 复刻基线把 source 的 RID 排除在遮挡射线之外的效果。
static func resolve_explosion_barrels(
	world,                    # SimWorld，同上：不加类型标注
	origin: Vector2,
	origin_height: float,
	radius: float,
	center_damage: float,
	edge_damage: float,
	source_index: int
) -> PackedInt32Array:
	var affected := PackedInt32Array()
	if radius <= 0.0:
		return affected
	var count: int = world.get_barrel_count()
	for index in range(count):
		if index == source_index:
			continue
		if world.get_barrel_state(index) >= BARREL_STATE_PENDING:
			continue
		var position: Vector2 = world.get_barrel_position(index)
		var planar_offset := position - origin
		var vertical_offset: float = (
			world.get_barrel_base_height(index) - origin_height
		)
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
		affected.append(index)
	return affected

static func _compare_hits(left: Dictionary, right: Dictionary) -> bool:
	var left_distance: float = left["distance"]
	var right_distance: float = right["distance"]
	if left_distance != right_distance:
		return left_distance < right_distance
	var left_rank := 0 if left["kind"] == KIND_ZOMBIE else 1
	var right_rank := 0 if right["kind"] == KIND_ZOMBIE else 1
	if left_rank != right_rank:
		return left_rank < right_rank
	return int(left["index"]) < int(right["index"])
