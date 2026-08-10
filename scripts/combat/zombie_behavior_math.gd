extends RefCounted
class_name ZombieBehaviorMath

## 本文件的多数函数由 SimWorld 直接调用，因此属于模拟层：这里出现的每一个
## 数学调用都必须跨平台逐位一致，三角函数一律走 SimMath。
const SimMathScript = preload("res://scripts/sim/sim_math.gd")

enum State {
	WANDER,
	AWARE_APPROACH,
	ATTACK,
}

static func next_state(
	current_state: int,
	distance_to_player: float,
	target_alive: bool,
	perception_range: float,
	perception_exit_margin: float,
	attack_range: float,
	attack_path_clear: bool = true
) -> int:
	if not target_alive:
		return State.WANDER
	var distance := maxf(distance_to_player, 0.0)
	if distance <= maxf(attack_range, 0.0) and attack_path_clear:
		return State.ATTACK
	var exit_range := maxf(perception_range, 0.0) + maxf(perception_exit_margin, 0.0)
	if current_state == State.AWARE_APPROACH or current_state == State.ATTACK:
		return State.AWARE_APPROACH if distance <= exit_range else State.WANDER
	return State.AWARE_APPROACH if distance <= maxf(perception_range, 0.0) else State.WANDER

static func wander_point(
	home_position: Vector3,
	angle_radians: float,
	distance_ratio: float,
	wander_radius: float
) -> Vector3:
	var radius := maxf(wander_radius, 0.0) * clampf(distance_ratio, 0.0, 1.0)
	# 走 SimMath 而不是内置三角函数：游荡点进模拟层，平台 libm 的最后一位
	# 之差在这里就是各端的僵尸走向不同的地方。
	var direction := SimMathScript.direction_from_angle(angle_radians)
	return home_position + Vector3(direction.x, 0.0, direction.y) * radius

static func arrive_velocity(
	from_position: Vector3,
	target_position: Vector3,
	stop_range: float,
	move_speed: float,
	slow_radius: float
) -> Vector3:
	var offset := target_position - from_position
	offset.y = 0.0
	var distance := offset.length()
	var gap := distance - maxf(stop_range, 0.0)
	if gap <= 0.0 or distance <= 0.0001:
		return Vector3.ZERO
	var speed_factor := clampf(gap / maxf(slow_radius, 0.01), 0.25, 1.0)
	return offset / distance * maxf(move_speed, 0.0) * speed_factor

static func path_velocity(
	from_position: Vector3,
	next_path_position: Vector3,
	logical_target_position: Vector3,
	stop_range: float,
	move_speed: float,
	slow_radius: float
) -> Vector3:
	var path_offset := next_path_position - from_position
	path_offset.y = 0.0
	if path_offset.length_squared() <= 0.0001:
		return Vector3.ZERO
	var logical_offset := logical_target_position - from_position
	logical_offset.y = 0.0
	var gap := logical_offset.length() - maxf(stop_range, 0.0)
	if gap <= 0.0:
		return Vector3.ZERO
	var speed_factor := clampf(gap / maxf(slow_radius, 0.01), 0.25, 1.0)
	return path_offset.normalized() * maxf(move_speed, 0.0) * speed_factor

static func approach_stop_range(
	distance_to_target: float,
	attack_range: float,
	attack_path_clear: bool
) -> float:
	var safe_attack_range := maxf(attack_range, 0.0)
	if maxf(distance_to_target, 0.0) <= safe_attack_range and not attack_path_clear:
		return 0.0
	return safe_attack_range

static func facing_yaw(direction: Vector3, current_yaw: float) -> float:
	var flat_direction := Vector3(direction.x, 0.0, direction.z)
	if flat_direction.length_squared() <= 0.0001:
		return current_yaw
	# normalized() 底下是 sqrt 与除法，两者标准都要求正确舍入，保持内置即可；
	# atan2 底下是平台 libm，而这个 yaw 会进哈希，必须换成确定性实现。
	flat_direction = flat_direction.normalized()
	return SimMathScript.arc_tangent2(flat_direction.x, flat_direction.z)
