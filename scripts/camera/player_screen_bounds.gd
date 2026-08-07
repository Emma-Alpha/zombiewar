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

## 联机模式的共享活动区：镜头中心 ± 固定半宽半高，不做屏幕反投影。
##
## 数值由现有取景反推，锁死在 16:9：
##   正交 size = 15.0（scenes/camera/FollowCamera.tscn）
##   俯角 40.3°，sin(40.3°) ≈ 0.6468
##   地面纵向可视高度 = 15.0 / 0.6468 ≈ 23.19，半高 ≈ 11.60
##   地面横向可视宽度 = 15.0 * 16 / 9 ≈ 26.67，半宽 ≈ 13.33
##   再乘以 safe_margin_ratio = 0.08 两侧留边后的 0.84
##   => 半宽 11.2、半深 9.7
## 宽高比更大的设备只是看得更多，走不到更远，因此各端边界一致。
const ONLINE_BOUNDS_HALF_WIDTH := 11.2
const ONLINE_BOUNDS_HALF_DEPTH := 9.7

static func limit_motion_in_world_rect(
	anchor_position: Vector3,
	world_position: Vector3,
	desired_motion: Vector3,
	half_width: float,
	half_depth: float
) -> Vector3:
	var desired := world_position + desired_motion
	var clamped := Vector3(
		clampf(
			desired.x,
			anchor_position.x - half_width,
			anchor_position.x + half_width
		),
		desired.y,
		clampf(
			desired.z,
			anchor_position.z - half_depth,
			anchor_position.z + half_depth
		)
	)
	var limited := clamped - world_position
	limited.y = desired_motion.y
	return limited

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
