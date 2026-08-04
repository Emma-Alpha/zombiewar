extends RefCounted
class_name AimAssistMath

static func select_best_index(
	origin: Vector3,
	aim_direction: Vector3,
	candidate_points: Array[Vector3],
	max_distance: float,
	max_angle_radians: float
) -> int:
	var flat_aim := Vector3(aim_direction.x, 0.0, aim_direction.z)
	if flat_aim.length_squared() <= 0.000001:
		return -1
	flat_aim = flat_aim.normalized()
	var resolved_distance := maxf(max_distance, 0.001)
	var resolved_angle := maxf(max_angle_radians, 0.0001)
	var best_index := -1
	var best_score := INF

	for index in range(candidate_points.size()):
		var offset := candidate_points[index] - origin
		var planar := Vector3(offset.x, 0.0, offset.z)
		var distance := planar.length()
		if distance <= 0.0001 or distance > resolved_distance:
			continue
		var direction := planar / distance
		var angle := acos(clampf(flat_aim.dot(direction), -1.0, 1.0))
		if angle > resolved_angle:
			continue
		var score := angle / resolved_angle * 0.8 + distance / resolved_distance * 0.2
		if score < best_score:
			best_score = score
			best_index = index
	return best_index
