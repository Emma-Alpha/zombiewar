extends RefCounted
class_name WeaponSpreadState

const WeaponMath = preload("res://scripts/combat/weapon_math.gd")

var base_spread_degrees: float
var max_spread_degrees: float
var spread_increase_per_shot_degrees: float
var spread_recovery_degrees_per_second: float
var current_spread_degrees: float

func _init(
	value_base_spread_degrees: float,
	value_max_spread_degrees: float,
	value_spread_increase_per_shot_degrees: float,
	value_spread_recovery_degrees_per_second: float
) -> void:
	base_spread_degrees = maxf(value_base_spread_degrees, 0.0)
	max_spread_degrees = maxf(
		value_max_spread_degrees,
		base_spread_degrees
	)
	spread_increase_per_shot_degrees = maxf(
		value_spread_increase_per_shot_degrees,
		0.0
	)
	spread_recovery_degrees_per_second = maxf(
		value_spread_recovery_degrees_per_second,
		0.0
	)
	current_spread_degrees = base_spread_degrees

func tick(delta: float) -> void:
	current_spread_degrees = move_toward(
		current_spread_degrees,
		base_spread_degrees,
		spread_recovery_degrees_per_second * maxf(delta, 0.0)
	)

func resolve_shot_direction(
	base_direction: Vector3,
	normalized_random_offset: float
) -> Vector3:
	var resolved_base := WeaponMath.flat_direction(base_direction)
	var offset := clampf(normalized_random_offset, -1.0, 1.0)
	var angle := deg_to_rad(current_spread_degrees * offset)
	var resolved_direction := WeaponMath.flat_direction(
		resolved_base.rotated(Vector3.UP, angle)
	)
	current_spread_degrees = minf(
		current_spread_degrees + spread_increase_per_shot_degrees,
		max_spread_degrees
	)
	return resolved_direction

func reset() -> void:
	current_spread_degrees = base_spread_degrees

## ---- 模拟层：纯函数变体 ----
## 渐进散布属玩家状态但影响命中结果，必须进入模拟层。SimWorld 按槽位保存
## current_spread_degrees，用下面三个纯函数推进，不再由 RangedWeapon 持有。
static func recovered_degrees(
	current_degrees: float,
	base_degrees: float,
	recovery_degrees_per_second: float,
	elapsed_seconds: float
) -> float:
	return move_toward(
		current_degrees,
		base_degrees,
		maxf(recovery_degrees_per_second, 0.0) * maxf(elapsed_seconds, 0.0)
	)

static func increased_degrees(
	current_degrees: float,
	increase_degrees: float,
	maximum_degrees: float
) -> float:
	return minf(current_degrees + maxf(increase_degrees, 0.0), maximum_degrees)

## XZ 平面上的散布。Vector3.rotated(Vector3.UP, angle) 与 Vector2.rotated(-angle)
## 在 (x, z) -> (x, y) 映射下等价，这里保持与实例版本逐位一致的旋转方向。
static func spread_direction(
	base_direction: Vector2,
	degrees: float,
	normalized_offset: float
) -> Vector2:
	if base_direction.length_squared() <= 0.000001:
		return Vector2(0.0, -1.0)
	var angle := deg_to_rad(degrees * clampf(normalized_offset, -1.0, 1.0))
	return base_direction.normalized().rotated(-angle)
