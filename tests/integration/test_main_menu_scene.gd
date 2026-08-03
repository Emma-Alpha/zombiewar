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

	backdrop.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
