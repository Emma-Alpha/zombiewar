extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const MOBILE_ACTION_BUTTON_PATH := "res://scripts/ui/mobile_action_button.gd"
const MOBILE_CONTROLS_PATH := "res://scripts/ui/mobile_controls.gd"

func run() -> Array[String]:
	var failures: Array[String] = []
	_release_test_actions()
	var action_button_script := load(MOBILE_ACTION_BUTTON_PATH) as Script
	_append(failures, Assertions.expect_true(
		ClassDB.class_exists(&"VirtualJoystick"),
		"Godot exposes the native VirtualJoystick control"
	))
	_append(failures, Assertions.expect_true(
		action_button_script != null,
		"Mobile action button script loads"
	))
	if action_button_script == null:
		return failures

	var player_scene := load("res://scenes/player/Player.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		player_scene != null,
		"Player scene loads for mapped movement input"
	))
	if player_scene != null:
		var player := player_scene.instantiate()
		Input.action_press(&"move_right", 0.75)
		Input.action_press(&"move_forward", 0.40)
		var resolved_input: Vector2 = player.get_move_input_vector()
		_append(failures, Assertions.expect_true(
			resolved_input.distance_to(Vector2(0.75, -0.40)) <= 0.0001,
			"Player does not apply the InputMap 0.5 deadzone twice"
		))
		player.free()
	_release_test_actions()

	var fire_button: Variant = action_button_script.new()
	fire_button.action = &"primary_attack"
	fire_button.set_pressed(true)
	_append(failures, Assertions.expect_true(
		Input.is_action_pressed(&"primary_attack"),
		"Mobile action button presses configured action"
	))
	fire_button.cancel()
	_append(failures, Assertions.expect_true(
		not Input.is_action_pressed(&"primary_attack"),
		"Mobile action button cancel releases configured action"
	))
	fire_button.free()

	_release_test_actions()
	var mobile_controls_script := load(MOBILE_CONTROLS_PATH) as Script
	_append(failures, Assertions.expect_true(
		mobile_controls_script != null,
		"Mobile controls coordinator script loads"
	))
	if mobile_controls_script == null:
		return failures
	_append(failures, Assertions.expect_true(
		not mobile_controls_script.should_show_controls(false, false),
		"Desktop environment hides mobile controls"
	))
	_append(failures, Assertions.expect_true(
		mobile_controls_script.should_show_controls(true, false),
		"Touchscreen environment shows mobile controls"
	))
	_append(failures, Assertions.expect_true(
		mobile_controls_script.should_show_controls(false, true),
		"Explicit test override shows mobile controls"
	))
	_append_desktop_scene_visibility_failures(failures)
	_append_disjoint_touch_emulation_restore_failures(failures, mobile_controls_script)
	_append_raw_touch_event_failures(failures)
	_release_test_actions()
	return failures

func _append_desktop_scene_visibility_failures(failures: Array[String]) -> void:
	const EMULATE_TOUCH_SETTING := "input_devices/pointing/emulate_touch_from_mouse"
	var emulation_before := bool(ProjectSettings.get_setting(EMULATE_TOUCH_SETTING, false))
	var runtime_emulation_before := Input.is_emulating_touch_from_mouse()
	var arena_scene := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		arena_scene != null,
		"Demo arena scene loads for physical touchscreen detection"
	))
	if arena_scene == null:
		return
	var arena := arena_scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)
	var controls := arena.get_node_or_null("MobileControls") as MobileControls
	var desktop_help := arena.get_node_or_null("HUD/ControlsPanel") as CanvasItem
	_append(failures, Assertions.expect_true(
		controls != null and not controls.force_visible and
		not controls.visible and not controls.is_touch_mode(),
		"Desktop scene hides mobile controls despite mouse touch emulation"
	))
	_append(failures, Assertions.expect_true(
		desktop_help != null and desktop_help.visible,
		"Desktop scene keeps keyboard controls help visible"
	))
	_append(failures, Assertions.expect_true(
		bool(ProjectSettings.get_setting(EMULATE_TOUCH_SETTING, false)) == emulation_before,
		"Physical touchscreen detection restores mouse touch emulation setting"
	))
	_append(failures, Assertions.expect_true(
		Input.is_emulating_touch_from_mouse() == runtime_emulation_before,
		"Physical touchscreen detection restores runtime mouse touch emulation"
	))
	arena.free()

func _append_disjoint_touch_emulation_restore_failures(
	failures: Array[String],
	mobile_controls_script: Script
) -> void:
	const EMULATE_TOUCH_SETTING := "input_devices/pointing/emulate_touch_from_mouse"
	var project_setting_before := bool(ProjectSettings.get_setting(EMULATE_TOUCH_SETTING, false))
	var runtime_emulation_before := Input.is_emulating_touch_from_mouse()
	ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, true)
	Input.set_emulate_touch_from_mouse(false)
	var controls := mobile_controls_script.new() as MobileControls
	controls._is_physical_touchscreen_available()
	_append(failures, Assertions.expect_true(
		bool(ProjectSettings.get_setting(EMULATE_TOUCH_SETTING, false)),
		"Physical touchscreen detection restores an independent project setting"
	))
	_append(failures, Assertions.expect_true(
		not Input.is_emulating_touch_from_mouse(),
		"Physical touchscreen detection restores an independent runtime emulation state"
	))
	controls.free()
	ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, project_setting_before)
	Input.set_emulate_touch_from_mouse(runtime_emulation_before)

func _append_raw_touch_event_failures(failures: Array[String]) -> void:
	var packed := load("res://scenes/ui/MobileControls.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Mobile controls scene loads for raw touch events"
	))
	if packed == null:
		return
	var controls := packed.instantiate() as MobileControls
	controls.force_visible = true
	var tree := Engine.get_main_loop() as SceneTree
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	tree.root.add_child(viewport)
	viewport.add_child(controls)
	var guard_packed := load("res://scenes/ui/MobileOrientationGuard.tscn") as PackedScene
	var guard := guard_packed.instantiate() as MobileOrientationGuard
	guard.force_touchscreen = true
	guard.input_cancel_target_path = NodePath("../MobileControls")
	viewport.add_child(guard)
	var virtual_joystick := controls.get_node_or_null("Layout/VirtualJoystick") as VirtualJoystick
	var fire_button := controls.get_node_or_null("Layout/FireButton") as MobileActionButton
	var place_item_button := controls.get_node_or_null("Layout/PlaceItemButton") as MobileActionButton
	var fire_label := controls.get_node_or_null("Layout/FireButton/Label") as Label
	var place_item_label := controls.get_node_or_null(
		"Layout/PlaceItemButton/Label"
	) as Label
	_append(failures, Assertions.expect_true(
		virtual_joystick != null and
		virtual_joystick.size.is_equal_approx(Vector2(324.0, 324.0)) and
		is_equal_approx(virtual_joystick.joystick_size, 262.285714) and
		is_equal_approx(virtual_joystick.tip_size, 113.142857) and
		is_equal_approx(virtual_joystick.deadzone_ratio, 0.12),
		"A 720-high viewport sizes the movement joystick to 45 percent of screen height"
	))
	_append(failures, Assertions.expect_true(
		fire_button != null and place_item_button != null and
		fire_button.size.is_equal_approx(Vector2(205.714286, 205.714286)) and
		place_item_button.size.is_equal_approx(Vector2(120.0, 120.0)),
		"Fire scales with the joystick while place item keeps its fixed touch size"
	))
	_append(failures, Assertions.expect_true(
		fire_label != null and fire_label.get_theme_font_size(&"font_size") == 33,
		"The responsive fire button scales its label with the touch target"
	))
	if (
		virtual_joystick == null or fire_button == null or
		place_item_button == null or fire_label == null or
		place_item_label == null
	):
		viewport.free()
		return
	var has_place_item_status := controls.has_method("set_place_item_status")
	_append(failures, Assertions.expect_true(
		has_place_item_status,
		"Mobile controls expose place-item inventory status updates"
	))
	if has_place_item_status:
		controls.call("set_place_item_status", "油桶", 998)
		_append(failures, Assertions.expect_equal(
			place_item_label.text,
			"油桶\n998",
			"Mobile place-item label shows the current item and count"
		))
	var has_outline_inset := false
	var has_outline_width := false
	for property in fire_button.get_property_list():
		if property.name == &"outline_inset":
			has_outline_inset = true
		elif property.name == &"outline_width":
			has_outline_width = true
	var fire_outline_inset := float(fire_button.get(&"outline_inset")) if has_outline_inset else -1.0
	var fire_outline_width := float(fire_button.get(&"outline_width")) if has_outline_width else -1.0
	_append(failures, Assertions.expect_true(
		has_outline_inset and has_outline_width and
		is_equal_approx(fire_outline_inset, 5.142857) and
		is_equal_approx(fire_outline_width, 5.142857),
		"The responsive fire button scales its circle inset and outline"
	))
	var joystick_rect := virtual_joystick.get_global_rect()
	_append(failures, Assertions.expect_true(
		not joystick_rect.intersects(fire_button.get_global_rect()) and
		not joystick_rect.intersects(place_item_button.get_global_rect()) and
		not fire_button.get_global_rect().intersects(place_item_button.get_global_rect()),
		"Responsive touch controls do not overlap at 1280 by 720"
	))
	viewport.size = Vector2i(1600, 800)
	joystick_rect = virtual_joystick.get_global_rect()
	_append(failures, Assertions.expect_true(
		virtual_joystick.size.is_equal_approx(Vector2(360.0, 360.0)) and
		fire_button.size.is_equal_approx(Vector2(228.571429, 228.571429)) and
		place_item_button.size.is_equal_approx(Vector2(120.0, 120.0)),
		"Landscape viewport resizing recomputes height-relative touch target sizes"
	))
	_append(failures, Assertions.expect_true(
		not joystick_rect.intersects(fire_button.get_global_rect()) and
		not joystick_rect.intersects(place_item_button.get_global_rect()) and
		not fire_button.get_global_rect().intersects(place_item_button.get_global_rect()),
		"Responsive touch controls remain disjoint after landscape resizing"
	))
	viewport.size = Vector2i(1280, 720)
	joystick_rect = virtual_joystick.get_global_rect()
	var fire_center := fire_button.get_global_rect().get_center()
	var place_item_center := place_item_button.get_global_rect().get_center()
	var joystick_center := joystick_rect.get_center()
	virtual_joystick.get_viewport().push_input(
		_screen_touch(21, true, joystick_center), true
	)
	virtual_joystick.get_viewport().push_input(_screen_drag(
		21,
		joystick_center + Vector2(virtual_joystick.joystick_size * 0.5, 0.0)
	), true)
	_append(failures, Assertions.expect_true(
		Input.get_action_strength(&"move_right") > 0.99,
		"A held native joystick touch drives movement before portrait blocking"
	))
	viewport.size = Vector2i(720, 1280)
	_append(failures, Assertions.expect_true(
		guard.overlay.visible and tree.paused and guard.paused_by_guard and
		not Input.is_action_pressed(&"move_left") and
		not Input.is_action_pressed(&"move_right") and
		not Input.is_action_pressed(&"move_forward") and
		not Input.is_action_pressed(&"move_back"),
		"Portrait rotation cancels joystick input and pauses mobile gameplay"
	))
	viewport.size = Vector2i(1280, 720)
	_append(failures, Assertions.expect_true(
		not guard.overlay.visible and not tree.paused and not guard.paused_by_guard and
		not Input.is_action_pressed(&"move_left") and
		not Input.is_action_pressed(&"move_right") and
		not Input.is_action_pressed(&"move_forward") and
		not Input.is_action_pressed(&"move_back"),
		"Landscape restoration resumes mobile gameplay through size_changed"
	))
	virtual_joystick.get_viewport().push_input(_screen_drag(
		21,
		joystick_center + Vector2(0.0, -virtual_joystick.joystick_size * 0.5)
	), true)
	_append(failures, Assertions.expect_true(
		not Input.is_action_pressed(&"move_left") and
		not Input.is_action_pressed(&"move_right") and
		not Input.is_action_pressed(&"move_forward") and
		not Input.is_action_pressed(&"move_back"),
		"Portrait cancellation prevents stale joystick drag from restoring movement"
	))
	virtual_joystick.get_viewport().push_input(
		_screen_touch(22, true, joystick_center), true
	)
	virtual_joystick.get_viewport().push_input(_screen_drag(
		22,
		joystick_center + Vector2(-virtual_joystick.joystick_size * 0.5, 0.0)
	), true)
	_append(failures, Assertions.expect_true(
		Input.get_action_strength(&"move_left") > 0.99 and
		not Input.is_action_pressed(&"move_right"),
		"A new touch ID takes over the native joystick after landscape restoration"
	))
	virtual_joystick.get_viewport().push_input(
		_screen_touch(22, false, joystick_center), true
	)

	fire_button._input(_screen_touch(11, true, fire_center))
	_append(failures, Assertions.expect_true(
		fire_button.pressed and Input.is_action_pressed(&"primary_attack"),
		"Raw fire touch presses its action"
	))
	fire_button._input(_screen_touch(11, false, fire_center))
	_append(failures, Assertions.expect_true(
		not fire_button.pressed and not Input.is_action_pressed(&"primary_attack"),
		"Raw fire touch release releases its action"
	))

	fire_button._input(_screen_touch(12, true, fire_center))
	fire_button._input(_screen_touch(13, false, fire_center))
	_append(failures, Assertions.expect_true(
		fire_button.active_touch_id == 12 and fire_button.pressed and Input.is_action_pressed(&"primary_attack"),
		"A different touch release cannot release the active fire button"
	))
	var outside_fire := fire_button.get_global_rect().end + Vector2(32.0, 32.0)
	fire_button._input(_screen_drag(12, outside_fire))
	fire_button._input(_screen_touch(12, false, outside_fire))
	_append(failures, Assertions.expect_true(
		not fire_button.pressed and not Input.is_action_pressed(&"primary_attack"),
		"Releasing the active touch outside the button releases fire"
	))

	fire_button._input(_screen_touch(14, true, fire_center))
	place_item_button._input(_screen_touch(15, true, place_item_center))
	_append(failures, Assertions.expect_true(
		fire_button.active_touch_id == 14 and place_item_button.active_touch_id == 15 and
		Input.is_action_pressed(&"primary_attack") and Input.is_action_pressed(&"place_item"),
		"Different raw touch IDs hold fire and place item simultaneously"
	))
	for action in [&"move_left", &"move_right", &"move_forward", &"move_back"]:
		Input.action_press(action)
	controls.cancel_all_input()
	_append(failures, Assertions.expect_true(
		not Input.is_action_pressed(&"move_left") and
		not Input.is_action_pressed(&"move_right") and
		not Input.is_action_pressed(&"move_forward") and
		not Input.is_action_pressed(&"move_back") and
		not Input.is_action_pressed(&"primary_attack") and
		not Input.is_action_pressed(&"place_item") and
		fire_button.active_touch_id == -1 and not fire_button.pressed and
		place_item_button.active_touch_id == -1 and not place_item_button.pressed,
		"Coordinator cancellation releases all actions and resets both action buttons"
	))
	viewport.free()
	_release_test_actions()

func _screen_touch(index: int, pressed: bool, position: Vector2) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = pressed
	event.position = position
	return event

func _screen_drag(index: int, position: Vector2) -> InputEventScreenDrag:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = position
	return event

func _release_test_actions() -> void:
	for action in [
		&"move_left", &"move_right", &"move_forward", &"move_back", &"place_item",
		&"primary_attack"
	]:
		Input.action_release(action)

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
