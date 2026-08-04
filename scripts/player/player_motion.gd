extends RefCounted
class_name PlayerMotion

static func world_direction(input_vector: Vector2, camera_basis: Basis) -> Vector3:
	var camera_forward := -camera_basis.z
	camera_forward.y = 0.0
	camera_forward = camera_forward.normalized()

	var camera_right := camera_basis.x
	camera_right.y = 0.0
	camera_right = camera_right.normalized()

	var direction := camera_right * input_vector.x + camera_forward * -input_vector.y
	return direction.normalized() if direction.length_squared() > 1.0 else direction

static func next_facing_yaw(direction: Vector3, current_yaw: float) -> float:
	var flat_direction := Vector3(direction.x, 0.0, direction.z)
	if flat_direction.length_squared() <= 0.0001:
		return current_yaw
	flat_direction = flat_direction.normalized()
	return atan2(-flat_direction.x, -flat_direction.z)

static func next_aim_direction(
	move_direction: Vector3,
	current_aim_direction: Vector3
) -> Vector3:
	var flat_move := Vector3(move_direction.x, 0.0, move_direction.z)
	if flat_move.length_squared() > 0.000001:
		return flat_move.normalized()

	var flat_current := Vector3(
		current_aim_direction.x,
		0.0,
		current_aim_direction.z
	)
	if flat_current.length_squared() <= 0.000001:
		return Vector3.FORWARD
	return flat_current.normalized()

static func next_planar_velocity(
	current_velocity: Vector3,
	move_direction: Vector3,
	move_speed: float,
	acceleration: float,
	deceleration: float,
	delta: float
) -> Vector3:
	var current_planar := Vector3(current_velocity.x, 0.0, current_velocity.z)
	var flat_direction := Vector3(move_direction.x, 0.0, move_direction.z)
	var target := Vector3.ZERO
	var rate := maxf(deceleration, 0.0)
	if flat_direction.length_squared() > 0.000001:
		target = flat_direction.normalized() * maxf(move_speed, 0.0)
		rate = maxf(acceleration, 0.0)
	return current_planar.move_toward(target, rate * maxf(delta, 0.0))

static func next_vertical_velocity(
	current_y: float,
	grounded: bool,
	jump_pressed: bool,
	delta: float,
	gravity: float,
	jump_speed: float
) -> float:
	if grounded and jump_pressed:
		return jump_speed
	if not grounded:
		return current_y - gravity * delta
	return minf(current_y, 0.0)
