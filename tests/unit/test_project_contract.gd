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
const REQUIRED_KEY_BINDINGS: Dictionary = {
	&"move_left": KEY_A,
	&"move_right": KEY_D,
	&"move_forward": KEY_W,
	&"move_back": KEY_S,
	&"jump": KEY_SPACE,
}

func run() -> Array[String]:
	var failures: Array[String] = []
	var version := Engine.get_version_info()
	_append(failures, Assertions.expect_equal(version["major"], 4, "Godot major version"))
	_append(failures, Assertions.expect_equal(version["minor"], 7, "Godot minor version"))
	_append(failures, Assertions.expect_equal(version["patch"], 1, "Godot patch version"))
	_append(failures, Assertions.expect_equal(
		ProjectSettings.get_setting("physics/3d/physics_engine"),
		"Jolt Physics",
		"3D physics engine"
	))
	for action in REQUIRED_ACTIONS:
		_append(failures, Assertions.expect_true(InputMap.has_action(action), "Missing input action: %s" % action))
		if not InputMap.has_action(action):
			continue
		var events := InputMap.action_get_events(action)
		_append(failures, Assertions.expect_equal(events.size(), 1, "Input event count for %s" % action))
		if events.size() != 1:
			continue
		var event := events[0]
		if action == &"fire":
			_append(failures, Assertions.expect_true(event is InputEventMouseButton, "Fire binding is a mouse button"))
			if event is InputEventMouseButton:
				_append(failures, Assertions.expect_equal(event.button_index, MOUSE_BUTTON_LEFT, "Fire binding is primary mouse button"))
			continue
		_append(failures, Assertions.expect_true(event is InputEventKey, "Input binding is a key: %s" % action))
		if event is InputEventKey:
			_append(failures, Assertions.expect_equal(event.keycode, REQUIRED_KEY_BINDINGS[action], "Key binding for %s" % action))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
