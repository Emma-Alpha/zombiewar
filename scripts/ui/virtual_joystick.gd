extends Control
class_name VirtualJoystick
## Virtual touch joystick (mobile). Outputs to the touch_move_* input actions.
## Minimal re-implementation restoring a reference that was missing from the
## repo (MobileControls.tscn referenced this type but the script was absent),
## which blocked DemoArena compilation entirely.

# Anonymous enum so members are accessible as VirtualJoystick.JOYSTICK_FIXED.
enum {
	JOYSTICK_FIXED,
	JOYSTICK_FLOATING,
}

@export var joystick_mode := JOYSTICK_FIXED
@export var joystick_size := 204.0
@export var tip_size := 88.0
@export var deadzone_ratio := 0.12
@export var clampzone_ratio := 1.0
@export var initial_offset_ratio := Vector2(0.5, 0.5)
@export var visibility_mode := 0

@export var action_left: StringName = &"touch_move_left"
@export var action_right: StringName = &"touch_move_right"
@export var action_up: StringName = &"touch_move_forward"
@export var action_down: StringName = &"touch_move_back"

var _active := false
var _base := Vector2.ZERO
var _delta := Vector2.ZERO

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed and not _active:
			_active = true
			_base = touch.position
			_delta = Vector2.ZERO
			_emit()
		elif not touch.pressed and _active:
			_active = false
			_delta = Vector2.ZERO
			_emit()
		accept_event()
	elif event is InputEventScreenDrag and _active:
		var drag := event as InputEventScreenDrag
		var range := joystick_size * 0.5 * clampzone_ratio
		if range > 0.0:
			_delta = (drag.position - _base) / range
			_delta = _delta.limit_length(1.0)
			_emit()
		accept_event()

func _emit() -> void:
	var axis_left := maxf(-_delta.x, 0.0)
	var axis_right := maxf(_delta.x, 0.0)
	var axis_up := maxf(-_delta.y, 0.0)
	var axis_down := maxf(_delta.y, 0.0)
	# Normalize diagonal by scaling to the max component so the output stays ≤1.
	var max_axis := maxf(maxf(axis_left, axis_right), maxf(axis_up, axis_down))
	if max_axis > 1.0:
		var inv := 1.0 / max_axis
		axis_left *= inv
		axis_right *= inv
		axis_up *= inv
		axis_down *= inv
	# Deadzone: zero out near-centre input.
	var magnitude := max_axis
	if magnitude < deadzone_ratio:
		axis_left = 0.0
		axis_right = 0.0
		axis_up = 0.0
		axis_down = 0.0
	Input.action_press(action_left, axis_left)
	Input.action_press(action_right, axis_right)
	Input.action_press(action_up, axis_up)
	Input.action_press(action_down, axis_down)
