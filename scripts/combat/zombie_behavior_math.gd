extends RefCounted
class_name ZombieBehaviorMath

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
	attack_range: float
) -> int:
	if not target_alive:
		return State.WANDER
	var distance := maxf(distance_to_player, 0.0)
	if distance <= maxf(attack_range, 0.0):
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
	return home_position + Vector3(cos(angle_radians), 0.0, sin(angle_radians)) * radius

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

static func facing_yaw(direction: Vector3, current_yaw: float) -> float:
	var flat_direction := Vector3(direction.x, 0.0, direction.z)
	if flat_direction.length_squared() <= 0.0001:
		return current_yaw
	flat_direction = flat_direction.normalized()
	return atan2(flat_direction.x, flat_direction.z)
