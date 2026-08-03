extends RefCounted
class_name AimMath

static func intersect_y_plane(ray_origin: Vector3, ray_direction: Vector3, plane_y: float) -> Variant:
	if absf(ray_direction.y) < 0.00001:
		return null
	var distance := (plane_y - ray_origin.y) / ray_direction.y
	if distance < 0.0:
		return null
	return ray_origin + ray_direction * distance
