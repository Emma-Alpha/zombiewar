extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const REQUIRED_ACTIONS: Array[StringName] = [
	&"move_left",
	&"move_right",
	&"move_forward",
	&"move_back",
	&"jump",
	&"fire",
]

func run() -> Array[String]:
	var failures: Array[String] = []
	var version := Engine.get_version_info()
	_append(failures, Assertions.expect_equal(version["major"], 4, "Godot major version"))
	_append(failures, Assertions.expect_true(int(version["minor"]) >= 7, "Godot minor version must be at least 7"))
	_append(failures, Assertions.expect_equal(
		ProjectSettings.get_setting("physics/3d/physics_engine"),
		"Jolt Physics",
		"3D physics engine"
	))
	for action in REQUIRED_ACTIONS:
		_append(failures, Assertions.expect_true(InputMap.has_action(action), "Missing input action: %s" % action))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
