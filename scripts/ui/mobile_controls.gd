extends CanvasLayer
class_name MobileControls

@export var force_visible := false
@export_node_path("CanvasItem") var desktop_help_path: NodePath

@onready var fire_button: MobileActionButton = $Layout/FireButton
@onready var jump_button: MobileActionButton = $Layout/JumpButton

var touch_mode := false

func _ready() -> void:
	set_touch_mode(should_show_controls(
		_is_physical_touchscreen_available(),
		force_visible
	))

func _is_physical_touchscreen_available() -> bool:
	const EMULATE_TOUCH_SETTING := "input_devices/pointing/emulate_touch_from_mouse"
	var project_emulate_touch_from_mouse := bool(ProjectSettings.get_setting(
		EMULATE_TOUCH_SETTING,
		false
	))
	var runtime_emulate_touch_from_mouse := Input.is_emulating_touch_from_mouse()
	ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, false)
	Input.set_emulate_touch_from_mouse(false)
	var touchscreen_available := DisplayServer.is_touchscreen_available()
	Input.set_emulate_touch_from_mouse(runtime_emulate_touch_from_mouse)
	ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, project_emulate_touch_from_mouse)
	return touchscreen_available

static func should_show_controls(
	touchscreen_available: bool,
	force_controls_visible: bool
) -> bool:
	return touchscreen_available or force_controls_visible

func set_touch_mode(enabled: bool) -> void:
	touch_mode = enabled
	visible = enabled
	if not enabled:
		_cancel_all_input()
	var desktop_help := get_node_or_null(desktop_help_path) as CanvasItem
	if desktop_help != null:
		desktop_help.visible = not enabled

func is_touch_mode() -> bool:
	return touch_mode

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		_cancel_all_input()

func _cancel_all_input() -> void:
	if not is_node_ready():
		return
	for action in [&"move_left", &"move_right", &"move_forward", &"move_back"]:
		Input.action_release(action)
	fire_button.cancel()
	jump_button.cancel()
