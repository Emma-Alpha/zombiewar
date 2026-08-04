extends CanvasLayer
class_name MobileControls

const MobileTouchscreen = preload("res://scripts/ui/mobile_touchscreen.gd")

@export var force_visible := false
@export_node_path("CanvasItem") var desktop_help_path: NodePath

@onready var virtual_joystick: VirtualJoystick = $Layout/VirtualJoystick
@onready var fire_button: MobileActionButton = $Layout/FireButton
@onready var jump_button: MobileActionButton = $Layout/JumpButton

var touch_mode := false
var joystick_touch_id := -1
var joystick_touch_position := Vector2.ZERO

func _ready() -> void:
	set_touch_mode(should_show_controls(
		_is_physical_touchscreen_available(),
		force_visible
	))

func _is_physical_touchscreen_available() -> bool:
	return MobileTouchscreen.is_physical_touchscreen_available()

static func should_show_controls(
	touchscreen_available: bool,
	force_controls_visible: bool
) -> bool:
	return touchscreen_available or force_controls_visible

func set_touch_mode(enabled: bool) -> void:
	touch_mode = enabled
	visible = enabled
	if not enabled:
		cancel_all_input()
	var desktop_help := get_node_or_null(desktop_help_path) as CanvasItem
	if desktop_help != null:
		desktop_help.visible = not enabled

func is_touch_mode() -> bool:
	return touch_mode

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		cancel_all_input()

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if (
			touch.pressed and joystick_touch_id == -1 and
			_is_joystick_touch_start(touch.position)
		):
			joystick_touch_id = touch.index
			joystick_touch_position = touch.position
		elif not touch.pressed and touch.index == joystick_touch_id:
			joystick_touch_position = touch.position
			joystick_touch_id = -1
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == joystick_touch_id:
			joystick_touch_position = drag.position

func cancel_all_input() -> void:
	if not is_node_ready():
		return
	_cancel_virtual_joystick()
	for action in [&"move_left", &"move_right", &"move_forward", &"move_back"]:
		Input.action_release(action)
	fire_button.cancel()
	jump_button.cancel()

func _is_joystick_touch_start(position: Vector2) -> bool:
	var touch_rect := virtual_joystick.get_global_rect()
	if virtual_joystick.joystick_mode == VirtualJoystick.JOYSTICK_FIXED:
		touch_rect = Rect2(
			touch_rect.get_center() - Vector2.ONE * virtual_joystick.joystick_size * 0.5,
			Vector2.ONE * virtual_joystick.joystick_size
		)
	return touch_rect.has_point(position)

func _cancel_virtual_joystick() -> void:
	if joystick_touch_id == -1:
		return
	var release_event := InputEventScreenTouch.new()
	release_event.index = joystick_touch_id
	release_event.pressed = false
	release_event.position = joystick_touch_position
	get_viewport().push_input(release_event, true)
	joystick_touch_id = -1
