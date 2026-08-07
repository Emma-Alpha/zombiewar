extends RefCounted
class_name SimHitGeometry

## zombie_hitbox.gd 的命中框在模拟层的解析几何表达。
##
## 基线事实：scenes/targets/ZombieTarget.tscn 只有一个 Hitboxes/BodyHitbox
## （CylinderShape3D，radius 1.1、height 2.2，局部偏移 y = 1.1），命中区只有
## &"body" 一种、倍率 1.0。因此这里建模为单段竖直圆柱，并保留分区表结构，
## 将来新增头/侧身/腿部只需扩表，射线求交与伤害应用无需改动。
##
## 射击方向经 WeaponMath.flat_direction() 压平，射线恒为水平，
## 因此圆柱求交退化为「XZ 平面圆求交 + 高度区间判定」。
const ZONE_BODY: StringName = &"body"
const BODY_CENTER_HEIGHT := 1.1
const BODY_RADIUS := 1.1
const BODY_HALF_HEIGHT := 1.1
const ZONE_DAMAGE_MULTIPLIERS := {
	ZONE_BODY: 1.0,
}

## 爆炸与近战使用的瞄准点高度，等价于 ZombieTarget.get_aim_point() 的 BodyHitbox 中心。
static func aim_point_height(zombie_height: float) -> float:
	return zombie_height + BODY_CENTER_HEIGHT

static func contains_height(zombie_height: float, probe_height: float) -> bool:
	var low := zombie_height + BODY_CENTER_HEIGHT - BODY_HALF_HEIGHT
	var high := zombie_height + BODY_CENTER_HEIGHT + BODY_HALF_HEIGHT
	return probe_height >= low and probe_height <= high

static func zone_for_height(zombie_height: float, probe_height: float) -> StringName:
	return ZONE_BODY if contains_height(zombie_height, probe_height) else &""

static func damage_multiplier(zone: StringName) -> float:
	return float(ZONE_DAMAGE_MULTIPLIERS.get(zone, 0.0))

## 返回沿 direction 命中圆的最小非负距离；未命中返回 -1.0。
## direction 必须已归一化。
static func ray_circle_distance(
	origin: Vector2,
	direction: Vector2,
	center: Vector2,
	radius: float,
	max_distance: float
) -> float:
	var to_center := center - origin
	var projection := to_center.dot(direction)
	var closest_squared := to_center.length_squared() - projection * projection
	var radius_squared := radius * radius
	if closest_squared > radius_squared:
		return -1.0
	var half_chord := sqrt(maxf(radius_squared - closest_squared, 0.0))
	var near_distance := projection - half_chord
	var far_distance := projection + half_chord
	var distance := near_distance if near_distance >= 0.0 else far_distance
	if distance < 0.0 or distance > max_distance:
		return -1.0
	return distance
