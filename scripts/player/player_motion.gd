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
