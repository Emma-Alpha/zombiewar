extends SceneTree

const SAMPLE_PATH := "res://scripts/camera/shared_camera_player_sample.gd"
const MATH_PATH := "res://scripts/camera/shared_camera_math.gd"
const VIEWPORT_SIZE := Vector2(1000.0, 500.0)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(SAMPLE_PATH), "SharedCameraPlayerSample script must exist", failures)
	_expect(ResourceLoader.exists(MATH_PATH), "SharedCameraMath script must exist", failures)
	if not failures.is_empty():
		_finish(failures)
		return
	var sample_script = load(SAMPLE_PATH)
	var math = load(MATH_PATH)
	var center_samples := [
		_sample(sample_script, Vector3(0.0, 0.0, 0.0), Vector2(400.0, 250.0)),
		_sample(sample_script, Vector3(2.0, 0.0, 4.0), Vector2(600.0, 250.0)),
	]
	_expect(math.player_center(center_samples).is_equal_approx(Vector3(1.0, 0.0, 2.0)), "player center must average all world positions", failures)
	var center_mover = _sample(sample_script, Vector3.ZERO, Vector2(500.0, 250.0), Vector3.RIGHT, Vector2.RIGHT)
	_expect(math.edge_push([center_mover], VIEWPORT_SIZE, 0.72, 3.0).is_zero_approx(), "screen-center player must not push camera", failures)

	var right_a = _sample(sample_script, Vector3.ZERO, Vector2(950.0, 250.0), Vector3.RIGHT, Vector2.RIGHT)
	var right_b = _sample(sample_script, Vector3.ZERO, Vector2(980.0, 250.0), Vector3.RIGHT, Vector2.RIGHT)
	var right_push: Vector3 = math.edge_push([right_a, right_b], VIEWPORT_SIZE, 0.72, 3.0)
	_expect(right_push.x > 0.0, "two right-edge players moving right must push camera right", failures)

	var left = _sample(sample_script, Vector3.ZERO, Vector2(0.0, 250.0), Vector3.LEFT, Vector2.LEFT)
	var right = _sample(sample_script, Vector3.ZERO, Vector2(1000.0, 250.0), Vector3.RIGHT, Vector2.RIGHT)
	_expect(math.edge_push([left, right], VIEWPORT_SIZE, 0.72, 3.0).is_zero_approx(), "opposite edge pushes must cancel", failures)

	var idle_a = _sample(sample_script, Vector3.ZERO, Vector2(500.0, 250.0))
	var idle_b = _sample(sample_script, Vector3.ZERO, Vector2(500.0, 250.0))
	var idle_c = _sample(sample_script, Vector3.ZERO, Vector2(500.0, 250.0))
	var quarter_push: Vector3 = math.edge_push([right, idle_a, idle_b, idle_c], VIEWPORT_SIZE, 0.72, 4.0)
	_expect(is_equal_approx(quarter_push.x, 1.0), "one pusher among four must contribute one-quarter weight", failures)
	var diagonal = _sample(sample_script, Vector3.ZERO, Vector2(1000.0, 0.0), Vector3(1.0, 0.0, 1.0), Vector2(1.0, -1.0).normalized())
	_expect(math.edge_push([diagonal], VIEWPORT_SIZE, 0.72, 2.0).length() <= 2.00001, "edge push must never exceed max offset", failures)

	var fallback := Vector3(9.0, 7.0, 5.0)
	var first: Vector3 = math.desired_position([right_a, right_b], VIEWPORT_SIZE, 0.72, 3.0, fallback)
	var second: Vector3 = math.desired_position([right_a, right_b], VIEWPORT_SIZE, 0.72, 3.0, fallback)
	_expect(first == second, "identical samples must produce an exactly idempotent target", failures)
	_expect(is_equal_approx(first.y, fallback.y), "camera math must preserve fallback height", failures)
	_expect(math.desired_position([], VIEWPORT_SIZE, 0.72, 3.0, fallback) == fallback, "empty samples must return fallback", failures)
	_finish(failures)

func _sample(
	script,
	world_position: Vector3,
	screen_position: Vector2,
	world_move: Vector3 = Vector3.ZERO,
	screen_move: Vector2 = Vector2.ZERO
):
	var sample = script.new()
	sample.world_position = world_position
	sample.screen_position = screen_position
	sample.world_move_direction = world_move
	sample.screen_move_direction = screen_move
	return sample

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_shared_camera_math: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
