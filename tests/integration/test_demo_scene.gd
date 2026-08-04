extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_append(failures, Assertions.expect_true(packed != null, "Demo arena scene loads"))
	if packed == null:
		return failures

	var arena := packed.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)
	var player := arena.get_node_or_null("Player")
	var visual_root := arena.get_node_or_null("Player/VisualRoot") as Node3D
	var follow_camera := arena.get_node_or_null("FollowCamera") as FollowCamera
	var camera := arena.get_node_or_null("FollowCamera/Camera3D") as Camera3D
	var targets := arena.get_node_or_null("World/Targets")
	var controls := arena.get_node_or_null("HUD/ControlsPanel/Controls") as Label
	var mobile_controls := arena.get_node_or_null("MobileControls")
	var virtual_joystick := arena.get_node_or_null(
		"MobileControls/Layout/VirtualJoystick"
	) as VirtualJoystick
	var fire_button := arena.get_node_or_null(
		"MobileControls/Layout/FireButton"
	) as MobileActionButton
	var jump_button := arena.get_node_or_null(
		"MobileControls/Layout/JumpButton"
	) as MobileActionButton
	var fire_label := arena.get_node_or_null(
		"MobileControls/Layout/FireButton/Label"
	) as Label
	var jump_label := arena.get_node_or_null(
		"MobileControls/Layout/JumpButton/Label"
	) as Label
	_append(failures, Assertions.expect_true(player != null, "Demo has Player"))
	_append(failures, Assertions.expect_true(
		player != null and player.has_method("set_movement_camera"),
		"Player accepts movement camera"
	))
	if player != null and player.has_method("set_movement_camera"):
		_append(failures, Assertions.expect_true(
			player.get("movement_camera") == camera,
			"Demo wires camera-relative movement on startup"
		))
	_append(failures, Assertions.expect_true(
		follow_camera != null and follow_camera.target == player,
		"Demo wires camera follow on startup"
	))
	_append(failures, Assertions.expect_true(visual_root != null, "Player has VisualRoot"))
	if visual_root != null:
		_append(failures, Assertions.expect_float_near(
			absf(visual_root.rotation.y),
			PI,
			0.0001,
			"Player visual is corrected by 180 degrees"
		))
	_append(failures, Assertions.expect_true(camera != null, "Demo has Camera3D"))
	if camera != null:
		_append(failures, Assertions.expect_equal(camera.projection, Camera3D.PROJECTION_ORTHOGONAL, "Camera is orthographic"))
		_append(failures, Assertions.expect_float_near(camera.size, 18.0, 0.0001, "Camera orthographic size"))
	_append(failures, Assertions.expect_true(targets != null and targets.get_child_count() == 4, "Demo has four zombie targets"))
	_append(failures, Assertions.expect_true(controls != null, "Demo has controls label"))
	if controls != null:
		_append(failures, Assertions.expect_equal(
			controls.text,
			"WASD  MOVE + FACE    SPACE  JUMP    J  FIRE",
			"HUD documents keyboard-only controls"
		))
	_append(failures, Assertions.expect_true(
		mobile_controls != null,
		"Demo owns a mobile controls layer"
	))
	_append(failures, Assertions.expect_true(
		virtual_joystick != null and virtual_joystick.joystick_size >= 144.0,
		"Demo has a thumb-sized native movement joystick"
	))
	_append(failures, Assertions.expect_true(
		virtual_joystick != null and
		virtual_joystick.action_left == &"move_left" and
		virtual_joystick.action_right == &"move_right" and
		virtual_joystick.action_up == &"move_forward" and
		virtual_joystick.action_down == &"move_back",
		"Native joystick maps to the existing movement actions"
	))
	_append(failures, Assertions.expect_float_near(
		virtual_joystick.deadzone_ratio if virtual_joystick != null else -1.0,
		0.15,
		0.0001,
		"Native joystick owns the radial deadzone"
	))
	_append(failures, Assertions.expect_true(
		fire_button != null and fire_button.action == &"fire" and
		fire_button.size.x >= 144.0 and fire_button.size.y >= 144.0,
		"Demo has a large hold-to-fire touch button"
	))
	_append(failures, Assertions.expect_true(
		jump_button != null and jump_button.action == &"jump" and
		jump_button.size.x >= 112.0 and jump_button.size.y >= 112.0,
		"Demo has a distinct jump touch button"
	))
	_append(failures, Assertions.expect_true(
		mobile_controls != null and
		mobile_controls.get("desktop_help_path") == NodePath("../HUD/ControlsPanel"),
		"Mobile controls toggle the existing desktop help panel"
	))
	for candidate in [fire_label, jump_label]:
		var label := candidate as Label
		_append(failures, Assertions.expect_true(
			label != null,
			"Mobile action button has a readable label"
		))
		if label == null:
			continue
		var font := label.get_theme_font(&"font")
		_append(failures, Assertions.expect_true(
			font != null,
			"Mobile action label has an embedded font"
		))
		if font == null:
			continue
		for glyph in label.text:
			var codepoint := glyph.unicode_at(0)
			_append(failures, Assertions.expect_true(
				font.has_char(codepoint),
				"Mobile action font includes glyph %s" % glyph
			))
	arena.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
