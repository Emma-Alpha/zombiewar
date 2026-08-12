extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var virtual_joystick_script := load("res://scripts/ui/virtual_joystick.gd") as Script
	_expect(virtual_joystick_script != null, "VirtualJoystick project script must load", failures)
	if virtual_joystick_script != null:
		_expect(virtual_joystick_script.can_instantiate(), "VirtualJoystick project script must be instantiable", failures)
		if virtual_joystick_script.can_instantiate():
			var virtual_joystick = virtual_joystick_script.new()
			_expect(virtual_joystick != null, "VirtualJoystick project script must create an instance", failures)
			if virtual_joystick != null:
				virtual_joystick.free()

	var scene := load("res://scenes/ui/MobileControls.tscn") as PackedScene
	_expect(scene != null, "MobileControls scene must load", failures)
	if scene == null:
		_finish(failures)
		return
	var controls = scene.instantiate()
	controls.force_visible = true
	root.add_child(controls)
	await process_frame
	var virtual_joystick_node := controls.get_node_or_null("Layout/VirtualJoystick")
	_expect(virtual_joystick_node != null, "MobileControls VirtualJoystick node must exist", failures)
	if virtual_joystick_node != null and virtual_joystick_script != null:
		_expect(
			virtual_joystick_node.get_script() == virtual_joystick_script,
			"MobileControls VirtualJoystick node must use the project joystick script",
			failures
		)
	for legacy_action in [
		&"move_left",
		&"move_right",
		&"move_forward",
		&"move_back",
		&"primary_attack",
	]:
		_expect(not InputMap.has_action(legacy_action), "%s legacy action must be removed" % legacy_action, failures)
	for touch_action in [
		&"touch_move_left",
		&"touch_move_right",
		&"touch_move_forward",
		&"touch_move_back",
	]:
		_expect(InputMap.has_action(touch_action), "%s action must exist for VirtualJoystick" % touch_action, failures)

	var previous_button := controls.get_node_or_null("Layout/PreviousButton")
	var next_button := controls.get_node_or_null("Layout/NextButton")
	var use_button := controls.get_node_or_null("Layout/UseButton")
	_expect(previous_button != null, "PreviousButton must exist", failures)
	_expect(next_button != null, "NextButton must exist", failures)
	_expect(use_button != null, "UseButton must exist", failures)
	_expect(controls.get_node_or_null("Layout/FireButton") == null, "FireButton must be removed", failures)
	_expect(controls.get_node_or_null("Layout/PlaceItemButton") == null, "PlaceItemButton must be removed", failures)

	for button in [previous_button, next_button, use_button]:
		if button == null:
			continue
		var property_names: Array[StringName] = []
		for property in button.get_property_list():
			property_names.append(property["name"])
		_expect(not property_names.has(&"action"), "%s must not expose an InputMap action" % button.name, failures)

	if previous_button != null and next_button != null and use_button != null:
		_expect(not previous_button.get_global_rect().intersects(next_button.get_global_rect()), "PreviousButton and NextButton must not overlap", failures)
		_expect(not previous_button.get_global_rect().intersects(use_button.get_global_rect()), "PreviousButton and UseButton must not overlap", failures)
		_expect(not next_button.get_global_rect().intersects(use_button.get_global_rect()), "NextButton and UseButton must not overlap", failures)

	_expect(controls.has_method("get_input_source"), "MobileControls must expose its touch input source", failures)
	if controls.has_method("get_input_source") and use_button != null:
		var source = controls.get_input_source()
		_expect(source != null, "MobileControls touch input source must exist", failures)
		if source != null:
			use_button.set_pressed(true)
			var normal_press = source.sample()
			_expect(normal_press.use_pressed, "UseButton must set held use state", failures)
			_expect(normal_press.use_just_pressed, "UseButton must set use press edge", failures)
			_expect(not normal_press.confirm_just_pressed, "UseButton must not confirm during gameplay", failures)
			var held_press = source.sample()
			_expect(not held_press.use_just_pressed, "held UseButton must not repeat its edge", failures)
			use_button.set_pressed(false)
			source.sample()
			source.set_game_over_active(true)
			use_button.set_pressed(true)
			var game_over_press = source.sample()
			_expect(game_over_press.use_just_pressed, "UseButton must keep its use edge during game over", failures)
			_expect(game_over_press.confirm_just_pressed, "UseButton must confirm during game over", failures)
			controls.cancel_all_input()
			var canceled = source.sample()
			_expect(canceled.move_vector == Vector2.ZERO, "cancel must clear touch movement", failures)
			_expect(not canceled.use_pressed, "cancel must release UseButton", failures)

	controls.queue_free()
	await process_frame

	var demo_scene := load("res://scenes/maps/demo/DemoMap.tscn") as PackedScene
	_expect(demo_scene != null, "DemoMap scene must load", failures)
	if demo_scene != null:
		var demo = demo_scene.instantiate()
		var demo_controls = demo.get_node("MobileControls")
		_expect(
			demo.single_player_input.touch_source == demo_controls.get_input_source(),
			"GameplayArena must inject the MobileControls touch source into single-player input",
			failures
		)
		var detached_team_state := demo.get("local_team_state") as Node
		demo.free()
		if detached_team_state != null and is_instance_valid(detached_team_state):
			detached_team_state.free()
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_mobile_equipment_controls: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
