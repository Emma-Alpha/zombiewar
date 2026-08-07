extends RefCounted
class_name PlayerScreenBounds

static func screen_to_plane(
	camera: Camera3D,
	screen_point: Vector2,
	plane_y: float
) -> Vector3:
	var origin := camera.project_ray_origin(screen_point)
	var direction := camera.project_ray_normal(screen_point)
	if absf(direction.y) <= 0.000001:
		return origin
	var distance := (plane_y - origin.y) / direction.y
	return origin + direction * distance

static func limit_motion(
	camera: Camera3D,
	world_position: Vector3,
	desired_motion: Vector3,
	safe_margin_ratio: float
) -> Vector3:
	if camera == null or not camera.is_inside_tree():
		return desired_motion
	var viewport_size := camera.get_viewport().get_visible_rect().size
	var margin := viewport_size * clampf(safe_margin_ratio, 0.0, 0.25)
	var safe_rect := Rect2(margin, viewport_size - margin * 2.0)
	var desired_world := world_position + desired_motion
	var desired_screen := camera.unproject_position(desired_world)
	var clamped_screen := Vector2(
		clampf(desired_screen.x, safe_rect.position.x, safe_rect.end.x),
		clampf(desired_screen.y, safe_rect.position.y, safe_rect.end.y)
	)
	if desired_screen.is_equal_approx(clamped_screen):
		return desired_motion
	var clamped_world := screen_to_plane(camera, clamped_screen, world_position.y)
	var limited := clamped_world - world_position
	limited.y = desired_motion.y
	return limited
