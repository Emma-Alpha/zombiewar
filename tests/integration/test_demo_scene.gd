extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_append(failures, Assertions.expect_true(packed != null, "Demo arena scene loads"))
	if packed == null:
		return failures

	var arena := packed.instantiate()
	var player := arena.get_node_or_null("Player")
	var camera := arena.get_node_or_null("FollowCamera/Camera3D") as Camera3D
	var targets := arena.get_node_or_null("World/Targets")
	_append(failures, Assertions.expect_true(player != null, "Demo has Player"))
	_append(failures, Assertions.expect_true(player != null and player.has_method("set_aim_camera"), "Player accepts aim camera"))
	_append(failures, Assertions.expect_true(camera != null, "Demo has Camera3D"))
	if camera != null:
		_append(failures, Assertions.expect_equal(camera.projection, Camera3D.PROJECTION_ORTHOGONAL, "Camera is orthographic"))
		_append(failures, Assertions.expect_float_near(camera.size, 18.0, 0.0001, "Camera orthographic size"))
	_append(failures, Assertions.expect_true(targets != null and targets.get_child_count() == 4, "Demo has four zombie targets"))
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
