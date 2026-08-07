extends "res://scripts/input/player_input_source.gd"
class_name GamepadInputSource

const MOVE_DEADZONE := 0.20
const USE_THRESHOLD := 0.50

var device_id := -1

func _init(value_device_id: int = -1) -> void:
	device_id = value_device_id

func sample():
	if not is_online():
		return build_state(Vector2.ZERO, false, false, false, false)
	var move := Vector2(
		Input.get_joy_axis(device_id, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(device_id, JOY_AXIS_LEFT_Y)
	)
	if move.length() <= MOVE_DEADZONE:
		move = Vector2.ZERO
	else:
		move = move.limit_length(1.0)
	return build_state(
		move,
		Input.is_joy_button_pressed(device_id, JOY_BUTTON_LEFT_SHOULDER),
		Input.is_joy_button_pressed(device_id, JOY_BUTTON_RIGHT_SHOULDER),
		Input.get_joy_axis(device_id, JOY_AXIS_TRIGGER_RIGHT) > USE_THRESHOLD,
		Input.is_joy_button_pressed(device_id, JOY_BUTTON_A)
	)

func is_online() -> bool:
	return Input.get_connected_joypads().has(device_id)

func get_source_key() -> StringName:
	return StringName("gamepad_%d" % device_id)
