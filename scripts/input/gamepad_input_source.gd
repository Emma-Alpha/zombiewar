extends "res://scripts/input/player_input_source.gd"
class_name GamepadInputSource

const MOVE_AXIS_DEADZONE := 0.35
const USE_THRESHOLD := 0.50

var device_id := -1

func _init(value_device_id: int = -1) -> void:
	device_id = value_device_id

func sample():
	if not is_online():
		return build_state(Vector2.ZERO, false, false, false, false)
	var raw_move := Vector2(
		Input.get_joy_axis(device_id, JOY_AXIS_LEFT_X),
		Input.get_joy_axis(device_id, JOY_AXIS_LEFT_Y)
	)
	var move := quantize_move_vector(raw_move)
	return build_state(
		move,
		Input.is_joy_button_pressed(device_id, JOY_BUTTON_LEFT_SHOULDER),
		Input.is_joy_button_pressed(device_id, JOY_BUTTON_RIGHT_SHOULDER),
		Input.get_joy_axis(device_id, JOY_AXIS_TRIGGER_RIGHT) > USE_THRESHOLD,
		Input.is_joy_button_pressed(device_id, JOY_BUTTON_A)
	)

static func quantize_move_vector(raw_move: Vector2) -> Vector2:
	var digital_move := Vector2(
		_quantize_axis(raw_move.x),
		_quantize_axis(raw_move.y)
	)
	return digital_move.normalized() if digital_move != Vector2.ZERO else Vector2.ZERO

static func _quantize_axis(value: float) -> float:
	if value > MOVE_AXIS_DEADZONE:
		return 1.0
	if value < -MOVE_AXIS_DEADZONE:
		return -1.0
	return 0.0

func is_online() -> bool:
	return Input.get_connected_joypads().has(device_id)

func get_source_key() -> StringName:
	return StringName("gamepad_%d" % device_id)

func get_device_id() -> int:
	return device_id
