extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/menu/MenuBackdrop.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Menu backdrop scene loads"
	))
	if packed == null:
		return failures

	var backdrop := packed.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(backdrop)

	_append(failures, Assertions.expect_true(
		backdrop.get_node_or_null("CameraRig/Camera3D") is Camera3D,
		"Backdrop has a camera"
	))
	_append(failures, Assertions.expect_true(
		backdrop.get_node_or_null("WarningLight") is OmniLight3D,
		"Backdrop has a warning light"
	))
	for node_path in [
		"SetDressing/PlayerHero",
		"SetDressing/ZombieBasic",
		"SetDressing/ZombieChubby",
		"SetDressing/Pickup",
		"SetDressing/Container",
	]:
		_append(failures, Assertions.expect_true(
			backdrop.get_node_or_null(node_path) != null,
			"Backdrop contains %s" % node_path
		))

	var player_animation := backdrop.get_node("SetDressing/PlayerHero").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	var basic_animation := backdrop.get_node("SetDressing/ZombieBasic").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	var chubby_animation := backdrop.get_node("SetDressing/ZombieChubby").find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	_append(failures, Assertions.expect_true(
		player_animation != null and player_animation.current_animation == &"Idle_Gun",
		"Menu player uses the armed idle animation"
	))
	_append(failures, Assertions.expect_true(
		basic_animation != null and basic_animation.current_animation == &"Walk",
		"Basic zombie uses the walk animation"
	))
	_append(failures, Assertions.expect_true(
		chubby_animation != null and chubby_animation.current_animation == &"Idle_Attack",
		"Chubby zombie uses the attack idle animation"
	))

	var menu_packed := load("res://scenes/menu/MainMenu.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		menu_packed != null,
		"Main menu scene loads"
	))
	if menu_packed == null:
		backdrop.free()
		return failures

	var menu := menu_packed.instantiate()
	menu.get_node("SelectAudio").stream = null
	menu.get_node("ConfirmAudio").stream = null
	menu.get_node("BackAudio").stream = null
	tree.root.add_child(menu)
	var start_button := menu.get_node_or_null(
		"MenuLayer/MenuRoot/LeftColumn/Actions/StartButton"
	) as Button
	var quit_button := menu.get_node_or_null(
		"MenuLayer/MenuRoot/LeftColumn/Actions/QuitButton"
	) as Button
	var exit_dialog := menu.get_node_or_null(
		"MenuLayer/MenuRoot/ExitDialog"
	) as Control
	var cancel_button := menu.get_node_or_null(
		"MenuLayer/MenuRoot/ExitDialog/DialogPanel/DialogMargin/DialogContent/DialogActions/CancelExitButton"
	) as Button
	var orientation_guard := menu.get_node_or_null(
		"MobileOrientationGuard"
	) as MobileOrientationGuard

	_append(failures, Assertions.expect_true(
		start_button != null and start_button.text == "开始游戏",
		"Main menu has the start action"
	))
	_append(failures, Assertions.expect_true(
		quit_button != null and quit_button.text == "退出游戏",
		"Main menu has the quit action"
	))
	_append(failures, Assertions.expect_true(
		exit_dialog != null and not exit_dialog.visible,
		"Exit dialog starts hidden"
	))
	_append(failures, Assertions.expect_true(
		menu.get("game_scene_path") == "res://scenes/gameplay/DemoArena.tscn",
		"Start action targets DemoArena"
	))
	_append(failures, Assertions.expect_true(
		orientation_guard != null and
		orientation_guard.input_cancel_target_path.is_empty(),
		"Main menu blocks portrait interaction without a gameplay input target"
	))
	_append(failures, Assertions.expect_true(
		ResourceLoader.exists(menu.get("game_scene_path")),
		"Configured gameplay destination exists"
	))
	_append(failures, Assertions.expect_true(
		menu.get_viewport().gui_get_focus_owner() == start_button,
		"Start button owns initial keyboard focus"
	))
	var configured_main_scene: String = ProjectSettings.get_setting(
		"application/run/main_scene", ""
	)
	var resolved_main_scene := configured_main_scene
	if configured_main_scene.begins_with("uid://"):
		resolved_main_scene = ResourceUID.get_id_path(
			ResourceUID.text_to_id(configured_main_scene)
		)
	_append(failures, Assertions.expect_equal(
		resolved_main_scene,
		"res://scenes/menu/MainMenu.tscn",
		"Main menu is the project entry scene"
	))

	quit_button.pressed.emit()
	_append(failures, Assertions.expect_true(
		exit_dialog.visible,
		"Quit action opens confirmation"
	))
	cancel_button.pressed.emit()
	_append(failures, Assertions.expect_true(
		not exit_dialog.visible,
		"Cancel action closes confirmation"
	))

	menu.free()

	backdrop.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
