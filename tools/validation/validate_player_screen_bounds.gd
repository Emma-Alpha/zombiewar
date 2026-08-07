extends SceneTree

const BOUNDS_PATH := "res://scripts/camera/player_screen_bounds.gd"
const PlayerScene = preload("res://scenes/player/Player.tscn")
const RawInputSource = preload("res://tools/validation/support/raw_input_source.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(BOUNDS_PATH), "PlayerScreenBounds script must exist", failures)
	if not failures.is_empty():
		_finish(failures)
		return
	var bounds = load(BOUNDS_PATH)
	var camera_scene := load("res://scenes/camera/FollowCamera.tscn") as PackedScene
	var follow = camera_scene.instantiate()
	root.add_child(follow)
	await process_frame
	var camera := follow.get_node("VisualOffset/Camera3D") as Camera3D
	var viewport_size := camera.get_viewport().get_visible_rect().size
	var margin := viewport_size * 0.10
	var safe_rect := Rect2(margin, viewport_size - margin * 2.0)
	var center_screen := viewport_size * 0.5
	var center_world: Vector3 = bounds.screen_to_plane(camera, center_screen, 0.0)
	var center_motion := Vector3(1.0, 0.0, 0.0)
	_expect(bounds.limit_motion(camera, center_world, center_motion, 0.10).is_equal_approx(center_motion), "screen-center motion must remain unchanged", failures)

	var right_screen := Vector2(safe_rect.end.x, center_screen.y)
	var right_world: Vector3 = bounds.screen_to_plane(camera, right_screen, 0.0)
	var outward_world: Vector3 = bounds.screen_to_plane(camera, right_screen + Vector2(100.0, 0.0), 0.0) - right_world
	var outward_limited: Vector3 = bounds.limit_motion(camera, right_world, outward_world, 0.10)
	_expect(outward_limited.length() < outward_world.length() * 0.05, "motion beyond right safe edge must be clipped", failures)

	var along_world: Vector3 = bounds.screen_to_plane(camera, right_screen + Vector2(0.0, 45.0), 0.0) - right_world
	_expect(bounds.limit_motion(camera, right_world, along_world, 0.10).is_equal_approx(along_world), "motion along right safe edge must remain", failures)
	var inward_world: Vector3 = bounds.screen_to_plane(camera, right_screen - Vector2(80.0, 0.0), 0.0) - right_world
	_expect(bounds.limit_motion(camera, right_world, inward_world, 0.10).is_equal_approx(inward_world), "motion back toward screen center must remain", failures)
	_expect(bounds.limit_motion(camera, right_world, outward_world, 0.10).is_equal_approx(outward_limited), "knockback must use the same deterministic limiter as ordinary motion", failures)

	var player = PlayerScene.instantiate()
	root.add_child(player)
	player.set_physics_process(false)
	_expect(player.has_method("set_screen_camera"), "PlayerController must accept the shared screen camera", failures)
	if player.has_method("set_screen_camera"):
		var source := RawInputSource.new()
		player.set_input_source(source)
		player.set_movement_camera(camera)
		player.set_screen_camera(camera)
		player.screen_safe_margin_ratio = 0.10
		player.global_position = right_world
		source.move = Vector2.RIGHT
		player._physics_process(0.1)
		_expect(camera.unproject_position(player.global_position).x <= safe_rect.end.x + 0.01, "PlayerController ordinary movement must stay inside safe edge", failures)
		player.global_position = right_world
		source.move = Vector2.ZERO
		player.knockback_velocity = outward_world.normalized() * 10.0
		player._physics_process(0.1)
		_expect(camera.unproject_position(player.global_position).x <= safe_rect.end.x + 0.01, "PlayerController knockback must stay inside safe edge", failures)
	player.queue_free()
	follow.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_player_screen_bounds: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
