extends RefCounted
class_name MobileTouchscreen

const EMULATE_TOUCH_SETTING := "input_devices/pointing/emulate_touch_from_mouse"

static func is_physical_touchscreen_available() -> bool:
	var project_emulation := bool(ProjectSettings.get_setting(
		EMULATE_TOUCH_SETTING,
		false
	))
	var runtime_emulation := Input.is_emulating_touch_from_mouse()
	ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, false)
	Input.set_emulate_touch_from_mouse(false)
	var available := DisplayServer.is_touchscreen_available()
	Input.set_emulate_touch_from_mouse(runtime_emulation)
	ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, project_emulation)
	return available
