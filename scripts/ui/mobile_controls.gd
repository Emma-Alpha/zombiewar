extends CanvasLayer
class_name MobileControls

const MobileTouchscreen = preload("res://scripts/ui/mobile_touchscreen.gd")
const JOYSTICK_VIEWPORT_HEIGHT_RATIO := 0.45
const BASE_JOYSTICK_CONTROL_SIZE := 252.0
const BASE_JOYSTICK_SIZE := 204.0
const BASE_JOYSTICK_TIP_SIZE := 88.0
const BASE_FIRE_BUTTON_SIZE := 160.0
const BASE_FIRE_LABEL_FONT_SIZE := 26.0
const BASE_SCREEN_MARGIN := 40.0
const BASE_JUMP_BUTTON_SIZE := 120.0
const BASE_JUMP_BUTTON_GAP := 16.0
const BASE_ACTION_OUTLINE_INSET := 4.0
const BASE_ACTION_OUTLINE_WIDTH := 4.0

@export var force_visible := false
@export_node_path("CanvasItem") var desktop_help_path: NodePath

@onready var virtual_joystick: VirtualJoystick = $Layout/VirtualJoystick
@onready var fire_button: MobileActionButton = $Layout/FireButton
@onready var jump_button: MobileActionButton = $Layout/JumpButton
@onready var fire_label: Label = $Layout/FireButton/Label

var touch_mode := false
var joystick_touch_id := -1
var joystick_touch_position := Vector2.ZERO

func _ready() -> void:
	var viewport := get_viewport()
	if not viewport.size_changed.is_connected(_apply_responsive_layout):
		viewport.size_changed.connect(_apply_responsive_layout)
	_apply_responsive_layout()
	set_touch_mode(should_show_controls(
		_is_physical_touchscreen_available(),
		force_visible
	))

func _exit_tree() -> void:
	var viewport := get_viewport()
	if viewport != null and viewport.size_changed.is_connected(_apply_responsive_layout):
		viewport.size_changed.disconnect(_apply_responsive_layout)

func _apply_responsive_layout() -> void:
	if not is_node_ready():
		return
	var viewport_height: float = get_viewport().get_visible_rect().size.y
	if viewport_height <= 0.0:
		return
	var joystick_control_size := viewport_height * JOYSTICK_VIEWPORT_HEIGHT_RATIO
	var scale_factor := joystick_control_size / BASE_JOYSTICK_CONTROL_SIZE
	var fire_button_size := BASE_FIRE_BUTTON_SIZE * scale_factor
	var screen_margin := BASE_SCREEN_MARGIN * scale_factor

	_set_anchored_rect(
		virtual_joystick,
		screen_margin,
		-screen_margin - joystick_control_size,
		screen_margin + joystick_control_size,
		-screen_margin
	)
	virtual_joystick.joystick_size = BASE_JOYSTICK_SIZE * scale_factor
	virtual_joystick.tip_size = BASE_JOYSTICK_TIP_SIZE * scale_factor

	var fire_left := -screen_margin - fire_button_size
	var fire_top := -screen_margin - fire_button_size
	_set_anchored_rect(
		fire_button,
		fire_left,
		fire_top,
		-screen_margin,
		-screen_margin
	)
	fire_label.add_theme_font_size_override(
		&"font_size",
		roundi(BASE_FIRE_LABEL_FONT_SIZE * scale_factor)
	)
	fire_button.outline_inset = BASE_ACTION_OUTLINE_INSET * scale_factor
	fire_button.outline_width = BASE_ACTION_OUTLINE_WIDTH * scale_factor
	fire_button.queue_redraw()

	var jump_gap := BASE_JUMP_BUTTON_GAP * scale_factor
	var jump_left := fire_left - jump_gap
	var jump_bottom := fire_top - jump_gap
	_set_anchored_rect(
		jump_button,
		jump_left,
		jump_bottom - BASE_JUMP_BUTTON_SIZE,
		jump_left + BASE_JUMP_BUTTON_SIZE,
		jump_bottom
	)

func _set_anchored_rect(
	control: Control,
	left: float,
	top: float,
	right: float,
	bottom: float
) -> void:
	control.custom_minimum_size = Vector2(right - left, bottom - top)
	control.offset_left = left
	control.offset_top = top
	control.offset_right = right
	control.offset_bottom = bottom

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
