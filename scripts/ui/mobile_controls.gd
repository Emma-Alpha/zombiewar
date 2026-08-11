extends CanvasLayer
class_name MobileControls

const MobileTouchscreen = preload("res://scripts/ui/mobile_touchscreen.gd")
const TouchInputSourceScript = preload("res://scripts/input/touch_input_source.gd")
## 不依赖全局类名 VirtualJoystick：该脚本曾是未追踪的孤儿文件，
## 在导出/headless 下全局类注册表拿不到它（Cannot get class），导致
## 场景里 joystick 节点变 placeholder、cancel_all_input() 崩在 Nil 上，
## 卡死「正在准备战斗」。改为 preload 直接拿脚本，与其它脚本同款写法。
const VirtualJoystickScript = preload("res://scripts/ui/virtual_joystick.gd")
## 对应 virtual_joystick.gd 里的 JOYSTICK_FIXED（匿名枚举首项）。
const JOYSTICK_MODE_FIXED := 0
const JOYSTICK_VIEWPORT_HEIGHT_RATIO := 0.45
const BASE_JOYSTICK_CONTROL_SIZE := 252.0
const BASE_JOYSTICK_SIZE := 204.0
const BASE_JOYSTICK_TIP_SIZE := 88.0
const BASE_USE_BUTTON_SIZE := 160.0
const BASE_USE_LABEL_FONT_SIZE := 26.0
const BASE_SCREEN_MARGIN := 40.0
const BASE_CYCLE_BUTTON_SIZE := 112.0
const BASE_ACTION_BUTTON_GAP := 16.0
const BASE_ACTION_OUTLINE_INSET := 4.0
const BASE_ACTION_OUTLINE_WIDTH := 4.0
const TOUCH_MOVE_ACTIONS: Array[StringName] = [
	&"touch_move_left",
	&"touch_move_right",
	&"touch_move_forward",
	&"touch_move_back",
]

@export var force_visible := false
@export_node_path("CanvasItem") var desktop_help_path: NodePath

@onready var virtual_joystick: VirtualJoystickScript = $Layout/VirtualJoystick
@onready var previous_button: MobileActionButton = $Layout/PreviousButton
@onready var next_button: MobileActionButton = $Layout/NextButton
@onready var use_button: MobileActionButton = $Layout/UseButton
@onready var use_label: Label = $Layout/UseButton/Label

var touch_mode := false
var joystick_touch_id := -1
var joystick_touch_position := Vector2.ZERO
var touch_input_source = TouchInputSourceScript.new()

func _ready() -> void:
	previous_button.pressed_changed.connect(touch_input_source.set_previous_pressed)
	next_button.pressed_changed.connect(touch_input_source.set_next_pressed)
	use_button.pressed_changed.connect(touch_input_source.set_use_pressed)
	if not visibility_changed.is_connected(_on_visibility_changed):
		visibility_changed.connect(_on_visibility_changed)
	var viewport := get_viewport()
	if not viewport.size_changed.is_connected(_apply_responsive_layout):
		viewport.size_changed.connect(_apply_responsive_layout)
	_apply_responsive_layout()
	set_touch_mode(should_show_controls(
		_is_physical_touchscreen_available(),
		force_visible
	))

func _process(_delta: float) -> void:
	if not touch_mode:
		return
	touch_input_source.set_move_vector(Input.get_vector(
		TOUCH_MOVE_ACTIONS[0],
		TOUCH_MOVE_ACTIONS[1],
		TOUCH_MOVE_ACTIONS[2],
		TOUCH_MOVE_ACTIONS[3]
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
	var use_button_size := BASE_USE_BUTTON_SIZE * scale_factor
	var cycle_button_size := BASE_CYCLE_BUTTON_SIZE * scale_factor
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

	var use_left := -screen_margin - use_button_size
	var use_top := -screen_margin - use_button_size
	_set_anchored_rect(
		use_button,
		use_left,
		use_top,
		-screen_margin,
		-screen_margin
	)
	use_label.add_theme_font_size_override(
		&"font_size",
		roundi(BASE_USE_LABEL_FONT_SIZE * scale_factor)
	)
	for button in [previous_button, next_button, use_button]:
		button.outline_inset = BASE_ACTION_OUTLINE_INSET * scale_factor
		button.outline_width = BASE_ACTION_OUTLINE_WIDTH * scale_factor
		button.queue_redraw()

	var action_gap := BASE_ACTION_BUTTON_GAP * scale_factor
	var next_left := use_left + (use_button_size - cycle_button_size) * 0.5
	var next_bottom := use_top - action_gap
	_set_anchored_rect(
		next_button,
		next_left,
		next_bottom - cycle_button_size,
		next_left + cycle_button_size,
		next_bottom
	)
	var previous_right := use_left - action_gap
	_set_anchored_rect(
		previous_button,
		previous_right - cycle_button_size,
		next_bottom - cycle_button_size,
		previous_right,
		next_bottom
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

func get_input_source():
	return touch_input_source

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
	touch_input_source.clear_input()
	for action in TOUCH_MOVE_ACTIONS:
		Input.action_release(action)
	if not is_node_ready():
		return
	_cancel_virtual_joystick()
	previous_button.cancel()
	next_button.cancel()
	use_button.cancel()

func _on_visibility_changed() -> void:
	if not visible:
		cancel_all_input()

func _is_joystick_touch_start(position: Vector2) -> bool:
	var touch_rect := virtual_joystick.get_global_rect()
	if virtual_joystick.joystick_mode == JOYSTICK_MODE_FIXED:
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
