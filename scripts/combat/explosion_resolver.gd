extends RefCounted
class_name ExplosionResolver

## 物理世界里的爆炸波及判定，S0 之后**只剩玩家**这一类目标。
##
## 僵尸不在此列：僵尸已退出 Godot 物理世界（表现节点在层 4 ZombieBlocker，
## 且不在 damageable_targets 组），其波及判定与伤害衰减由
## SimCombat.resolve_explosion_targets() 在 SimWorld 上完成。
## 其他爆炸桶也不在此列：连锁引爆由 SimWorld 的 tick 引信驱动
## （SimCombat.resolve_explosion_barrels()），调用方必须传
## can_trigger_explosives = false，否则同一串桶会被物理与模拟各炸一遍。
## 两条路径共用 ExplosionMath.damage_at_distance() 的衰减公式。
const ExplosionMath = preload("res://scripts/combat/explosion_math.gd")
const MAX_INTERSECTIONS := 128

static func resolve(
	world: World3D,
	origin: Vector3,
	radius: float,
	center_damage: float,
	edge_damage: float,
	source: CollisionObject3D,
	can_trigger_explosives: bool = true,
	target_mask: int = 7,
	obstacle_mask: int = 1
) -> Array[Node3D]:
	var affected: Array[Node3D] = []
	if world == null or radius <= 0.0:
		return affected

	var shape := SphereShape3D.new()
	shape.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, origin)
	query.collision_mask = target_mask
	query.collide_with_bodies = true
	query.collide_with_areas = true
	if source != null and is_instance_valid(source):
		query.exclude = [source.get_rid()]

	var intersections := world.direct_space_state.intersect_shape(
		query,
		MAX_INTERSECTIONS
	)
	var visited: Dictionary = {}
	for intersection in intersections:
		var target := _resolve_target(intersection.get("collider", null))
		if target == null:
			continue
		var target_id := target.get_instance_id()
		if visited.has(target_id):
			continue
		visited[target_id] = true

		var distance := origin.distance_to(target.global_position)
		var damage := ExplosionMath.damage_at_distance(
			distance,
			radius,
			center_damage,
			edge_damage
		)
		if damage <= 0.0:
			continue
		var aim_point := _target_aim_point(target)
		if _is_blocked(
			world,
			origin,
			aim_point,
			target,
			source,
			obstacle_mask
		):
			continue

		var direction := aim_point - origin
		if direction.length_squared() <= 0.000001:
			direction = Vector3.UP
		else:
			direction = direction.normalized()
		if target.has_method("apply_explosion_damage"):
			if not can_trigger_explosives:
				continue
			target.call("apply_explosion_damage", damage, origin)
		elif target.has_method("apply_hit"):
			target.call("apply_hit", damage, aim_point, direction)
		elif target.has_method("apply_damage"):
			target.call("apply_damage", damage, origin)
		else:
			continue
		affected.append(target)
	return affected

static func _resolve_target(collider: Object) -> Node3D:
	var current := collider as Node
	var explosive_target: Node3D
	while current != null:
		if current is Node3D and current.is_in_group(&"damageable_targets"):
			return current as Node3D
		if (
			explosive_target == null and
			current is Node3D and
			current.has_method("apply_explosion_damage")
		):
			explosive_target = current as Node3D
		current = current.get_parent()
	return explosive_target

static func _target_aim_point(target: Node3D) -> Vector3:
	if target.has_method("get_explosion_aim_point"):
		return target.call("get_explosion_aim_point") as Vector3
	if target.has_method("get_aim_point"):
		return target.call("get_aim_point") as Vector3
	return target.global_position + Vector3.UP * 0.9

static func _is_blocked(
	world: World3D,
	origin: Vector3,
	aim_point: Vector3,
	target: Node3D,
	source: CollisionObject3D,
	obstacle_mask: int
) -> bool:
	if obstacle_mask == 0 or origin.distance_squared_to(aim_point) <= 0.000001:
		return false
	var excluded: Array[RID] = []
	if source != null and is_instance_valid(source):
		excluded.append(source.get_rid())
	var ray := PhysicsRayQueryParameters3D.create(
		origin,
		aim_point,
		obstacle_mask,
		excluded
	)
	ray.collide_with_areas = false
	ray.collide_with_bodies = true
	var collision := world.direct_space_state.intersect_ray(ray)
	if collision.is_empty():
		return false
	return _resolve_target(collision.get("collider", null)) != target
