extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const WeaponClearanceState = preload(
	"res://scripts/player/weapon_clearance_state.gd"
)

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)

	var controller := player.get_node_or_null(
		"WeaponClearanceController"
	) as WeaponClearanceController
	var weapon_collision := player.get_node_or_null(
		"WeaponCollision"
	) as CollisionShape3D
	_append(failures, Assertions.expect_true(
		controller != null,
		"Player owns a weapon-clearance controller"
	))
	_append(failures, Assertions.expect_true(
		weapon_collision != null and weapon_collision.get_parent() == player,
		"Weapon collision is a direct CharacterBody child"
	))
	if controller == null or weapon_collision == null:
		player.free()
		return failures

	var rifle_shape := weapon_collision.shape as CapsuleShape3D
	_append(failures, Assertions.expect_true(
		not weapon_collision.disabled and rifle_shape != null,
		"Starting rifle enables a capsule collision"
	))
	if rifle_shape != null:
		_append(failures, Assertions.expect_float_near(
			rifle_shape.height,
			1.55,
			0.0001,
			"Starting rifle applies its fitted capsule length"
		))
		_append(failures, Assertions.expect_float_near(
			rifle_shape.radius,
			0.12,
			0.0001,
			"Starting rifle applies its fitted capsule radius"
		))

	var rifle := player.equipment.get_current_weapon()
	var rifle_visual := rifle.visual_anchor
	var rest_transform := rifle_visual.transform
	controller.call("_apply_pose", WeaponClearanceState.Pose.RAISED)
	controller._process(controller.transition_duration)
	_append(failures, Assertions.expect_true(
		rifle_visual.transform != rest_transform,
		"Raised pose rotates the existing hand-mounted rifle"
	))
	var saved_anchor := rifle.visual_anchor
	rifle.visual_anchor = null
	controller.bind_weapon(rifle)
	_append(failures, Assertions.expect_true(
		weapon_collision.disabled,
		"Missing visual anchor safely disables weapon clearance"
	))
	rifle.visual_anchor = saved_anchor
	controller.bind_weapon(rifle)

	player.equipment.equip_slot(2)
	_append(failures, Assertions.expect_true(
		weapon_collision.disabled,
		"Knife disables firearm wall collision"
	))
	_append(failures, Assertions.expect_true(
		rifle_visual.transform == rest_transform,
		"Unequipping restores the rifle local transform"
	))
	player.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
