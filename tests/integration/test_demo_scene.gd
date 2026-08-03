extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_append(failures, Assertions.expect_true(packed != null, "Demo arena scene loads"))
	if packed == null:
		return failures

	var arena := packed.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)
	var player := arena.get_node_or_null("Player")
	var visual_root := arena.get_node_or_null("Player/VisualRoot") as Node3D
	var follow_camera := arena.get_node_or_null("FollowCamera") as FollowCamera
	var camera := arena.get_node_or_null("FollowCamera/Camera3D") as Camera3D
	var targets := arena.get_node_or_null("World/Targets")
	var controls := arena.get_node_or_null("HUD/ControlsPanel/Controls") as Label
	_append(failures, Assertions.expect_true(player != null, "Demo has Player"))
	_append(failures, Assertions.expect_true(
		player != null and player.has_method("set_movement_camera"),
		"Player accepts movement camera"
	))
	if player != null and player.has_method("set_movement_camera"):
		_append(failures, Assertions.expect_true(
			player.get("movement_camera") == camera,
			"Demo wires camera-relative movement on startup"
		))
	_append(failures, Assertions.expect_true(
		follow_camera != null and follow_camera.target == player,
		"Demo wires camera follow on startup"
	))
	_append(failures, Assertions.expect_true(visual_root != null, "Player has VisualRoot"))
	if visual_root != null:
		_append(failures, Assertions.expect_float_near(
			absf(visual_root.rotation.y),
			PI,
			0.0001,
			"Player visual is corrected by 180 degrees"
		))
	_append(failures, Assertions.expect_true(camera != null, "Demo has Camera3D"))
	if camera != null:
		_append(failures, Assertions.expect_equal(camera.projection, Camera3D.PROJECTION_ORTHOGONAL, "Camera is orthographic"))
		_append(failures, Assertions.expect_float_near(camera.size, 18.0, 0.0001, "Camera orthographic size"))
	_append(failures, Assertions.expect_true(targets != null and targets.get_child_count() == 4, "Demo has four zombie targets"))
	_append(failures, Assertions.expect_true(controls != null, "Demo has controls label"))
	if controls != null:
		_append(failures, Assertions.expect_equal(
			controls.text,
			"WASD  MOVE + FACE    SPACE  JUMP    J  FIRE",
			"HUD documents keyboard-only controls"
		))
	var configured_main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	var resolved_main_scene := configured_main_scene
	if configured_main_scene.begins_with("uid://"):
		resolved_main_scene = ResourceUID.get_id_path(ResourceUID.text_to_id(configured_main_scene))
	_append(failures, Assertions.expect_equal(resolved_main_scene, "res://scenes/gameplay/DemoArena.tscn", "Demo arena is project main scene"))
	arena.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
