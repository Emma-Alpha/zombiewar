extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const REQUIRED_ACTIONS: Array[StringName] = [
	&"move_left",
	&"move_right",
	&"move_forward",
	&"move_back",
	&"place_item",
	&"primary_attack",
	&"weapon_pistol",
	&"weapon_rifle",
	&"weapon_knife",
	&"weapon_slot_4",
	&"spawn_wave",
	&"restart_demo",
]
const REQUIRED_KEY_BINDINGS: Dictionary = {
	&"move_left": KEY_A,
	&"move_right": KEY_D,
	&"move_forward": KEY_W,
	&"move_back": KEY_S,
	&"place_item": KEY_K,
	&"primary_attack": KEY_J,
	&"weapon_pistol": KEY_1,
	&"weapon_rifle": KEY_2,
	&"weapon_knife": KEY_3,
	&"weapon_slot_4": KEY_4,
	&"spawn_wave": KEY_T,
	&"restart_demo": KEY_R,
}

func run() -> Array[String]:
	var failures: Array[String] = []
	_append(failures, Assertions.expect_true(
		not InputMap.has_action(&"jump"),
		"Project removes the jump input action"
	))
	var version := Engine.get_version_info()
	_append(failures, Assertions.expect_equal(version["major"], 4, "Godot major version"))
	_append(failures, Assertions.expect_equal(version["minor"], 7, "Godot minor version"))
	_append(failures, Assertions.expect_equal(version["patch"], 1, "Godot patch version"))
	_append(failures, Assertions.expect_equal(
		ProjectSettings.get_setting("physics/3d/physics_engine"),
		"Jolt Physics",
		"3D physics engine"
	))
	_append(failures, Assertions.expect_equal(
		ProjectSettings.get_setting("physics/common/physics_interpolation", false),
		true,
		"Physics interpolation is enabled"
	))
	_append(failures, Assertions.expect_equal(
		ProjectSettings.get_setting(
			"input_devices/pointing/emulate_touch_from_mouse",
			false
		),
		true,
		"Mouse can emulate touch for local control testing"
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
		_append(failures, Assertions.expect_true(event is InputEventKey, "Input binding is a key: %s" % action))
		if event is InputEventKey:
			_append(failures, Assertions.expect_equal(event.keycode, REQUIRED_KEY_BINDINGS[action], "Key binding for %s" % action))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
