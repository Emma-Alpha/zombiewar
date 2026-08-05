extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var wall := _make_wall(Vector3(0.0, 1.0, -1.60), Vector3(3.0, 2.0, 0.20))
	var zombie: ZombieTarget
	_release_player_input(player)
	tree.root.add_child(player)
	tree.root.add_child(wall)

	var clearance := player.get_node_or_null(
		"WeaponClearanceController"
	) as WeaponClearanceController
	var weapon_collision := player.get_node_or_null(
		"WeaponCollision"
	) as CollisionShape3D
	var rifle := player.equipment.get_current_weapon() as RangedWeapon
	if clearance == null or weapon_collision == null or rifle == null:
		_append(failures, Assertions.expect_true(
			false,
			"Real player exposes clearance, weapon collision, and starting rifle"
		))
		_cleanup(player, wall, zombie)
		return failures
	var rifle_rest_transform := rifle.visual_anchor.transform
	var pistol := player.equipment.weapons[0] as RangedWeapon
	var pistol_rest_transform := pistol.visual_anchor.transform

	clearance.resolve_facing_yaw(
		0.016,
		Vector3(0.0, 0.0, -0.15),
		0.0
	)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Approaching a rifle-length wall clearance raises the rifle"
	))
	var raised_axis := weapon_collision.transform.basis.y.normalized()
	_append(failures, Assertions.expect_true(
		not weapon_collision.disabled and absf(raised_axis.y) > 0.85,
		"Raised rifle keeps an active capsule aimed upward"
	))

	wall.position.z = -1.1
	wall.force_update_transform()
	var start_position := player.global_position
	var collision := player.move_and_collide(Vector3(0.0, 0.0, -0.80), true)
	_append(failures, Assertions.expect_true(
		collision != null and player.global_position.is_equal_approx(start_position),
		"Direct WeaponCollision blocks forward motion before the body capsule reaches the wall"
	))
	_append(failures, Assertions.expect_true(
		player.move_and_collide(Vector3(0.0, 0.0, 0.20), true) == null,
		"Player can test a backward escape motion away from the wall"
	))
	var cursor_before := rifle.tracer_pool_cursor
	Input.action_press(player.primary_attack_action)
	player._physics_process(0.016)
	rifle._physics_process(0.20)
	_append(failures, Assertions.expect_true(
		clearance.is_raised() and rifle.tracer_pool_cursor != cursor_before,
		"Raised rifle keeps firing at the existing cadence"
	))

	wall.position.z = -4.0
	wall.force_update_transform()
	clearance.resolve_facing_yaw(0.15, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		not clearance.is_raised() and rifle.visual_anchor.transform.is_equal_approx(rifle_rest_transform),
		"Clearance restores normal pose and the exact visual rest transform after 0.15 seconds"
	))
	Input.action_release(player.primary_attack_action)
	var accepted_yaw := clearance.resolve_facing_yaw(0.016, Vector3.ZERO, PI * 0.5)
	player.rotation.y = accepted_yaw
	var expected_axis := Basis(Vector3.UP, accepted_yaw) * Vector3.BACK
	var actual_axis := weapon_collision.global_basis.y.normalized()
	_append(failures, Assertions.expect_true(
		absf(actual_axis.dot(expected_axis.normalized())) > 0.999,
		"WeaponCollision inherits accepted player yaw exactly once"
	))
	player.rotation.y = 0.0

	wall.position.z = -0.95
	wall.force_update_transform()
	player.equipment.equip_slot(0)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Wall-side pistol switch chooses the raised pose immediately"
	))
	_append(failures, Assertions.expect_true(
		pistol.visual_anchor.visible and not pistol.visual_anchor.transform.is_equal_approx(
			pistol_rest_transform
		),
		"Wall-side pistol switch shows a raised visual on its first visible frame"
	))

	wall.position.z = -1.45
	wall.force_update_transform()
	player.equipment.equip_slot(1)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Wall-side rifle switch chooses the raised pose immediately"
	))
	_append(failures, Assertions.expect_true(
		rifle.visual_anchor.visible and not rifle.visual_anchor.transform.is_equal_approx(
			rifle_rest_transform
		),
		"Wall-side rifle switch shows a raised visual on its first visible frame"
	))

	_test_side_facing_visual_and_restore_margin(
		failures,
		player,
		wall,
		clearance,
		rifle
	)

	player.equipment.equip_slot(2)
	_append(failures, Assertions.expect_true(
		weapon_collision.disabled,
		"Knife keeps only the player body capsule"
	))

	wall.free()
	var active_wall: StaticBody3D
	zombie = ZOMBIE_SCENE.instantiate() as ZombieTarget
	zombie.position = Vector3(0.0, 0.0, -1.0)
	zombie.set_physics_process(false)
	tree.root.add_child(zombie)
	player.equipment.equip_slot(1)
	clearance.resolve_facing_yaw(0.016, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		not clearance.is_raised(),
		"Zombie bodies and hit areas do not trigger firearm clearance"
	))
	_cleanup(player, active_wall, zombie)
	return failures

func _make_wall(position: Vector3, size: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.position = position
	wall.collision_layer = 1
	wall.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	wall.add_child(collision)
	return wall

func _test_side_facing_visual_and_restore_margin(
	failures: Array[String],
	player: PlayerController,
	wall: StaticBody3D,
	clearance: WeaponClearanceController,
	rifle: RangedWeapon
) -> void:
	var collision := wall.get_child(0) as CollisionShape3D
	var shape := collision.shape as BoxShape3D
	player.position.y = 0.0
	player.velocity = Vector3.ZERO
	player.rotation.y = 0.0
	wall.position = Vector3(0.0, 1.12, -4.0)
	shape.size = Vector3(3.0, 2.0, 0.20)
	wall.force_update_transform()
	player.rotation.y = clearance.resolve_facing_yaw(0.15, Vector3.ZERO, 0.0)

	var side_yaw := -PI * 0.5
	player.rotation.y = side_yaw
	var rest_barrel_axis := rifle.visual_anchor.global_basis.x.normalized()
	player.rotation.y = 0.0
	wall.position = Vector3(1.36, 1.12, 0.0)
	shape.size = Vector3(0.02, 0.3, 1.0)
	wall.force_update_transform()
	player.rotation.y = clearance.resolve_facing_yaw(
		0.0,
		Vector3.ZERO,
		side_yaw
	)
	var raised_barrel_axis := rifle.visual_anchor.global_basis.x.normalized()
	var raised_angle := acos(clampf(
		rest_barrel_axis.dot(raised_barrel_axis),
		-1.0,
		1.0
	))
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Side wall blocks the normal rifle while the raised pose remains usable"
	))
	_append(failures, Assertions.expect_float_near(
		raised_angle,
		deg_to_rad(65.0),
		0.05,
		"Raised rifle rotates its visible local-X barrel axis by 65 degrees at a real non-zero yaw"
	))
	_append(failures, Assertions.expect_true(
		raised_barrel_axis.y > rest_barrel_axis.y + 0.75,
		"Raised rifle visibly lifts its barrel axis above the normal pose at a real non-zero yaw"
	))

	wall.position.x = 1.45
	wall.force_update_transform()
	player.rotation.y = clearance.resolve_facing_yaw(
		0.15,
		Vector3.ZERO,
		side_yaw
	)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Side-facing restore margin keeps the rifle raised inside its 0.08 meter buffer"
	))

	wall.position.x = 1.57
	wall.force_update_transform()
	player.rotation.y = clearance.resolve_facing_yaw(
		0.15,
		Vector3.ZERO,
		side_yaw
	)
	_append(failures, Assertions.expect_true(
		not clearance.is_raised(),
		"Side-facing rifle lowers only after clearing the 0.08 meter restore margin"
	))

func _cleanup(
	player: PlayerController,
	wall: StaticBody3D,
	zombie: ZombieTarget
) -> void:
	if player != null:
		_release_player_input(player)
	if zombie != null and is_instance_valid(zombie):
		zombie.free()
	if wall != null and is_instance_valid(wall):
		wall.free()
	if player != null and is_instance_valid(player):
		player.free()

func _release_player_input(player: PlayerController) -> void:
	for action in [
		player.move_left_action,
		player.move_right_action,
		player.move_forward_action,
		player.move_back_action,
		player.jump_action,
		player.primary_attack_action,
		player.pistol_action,
		player.rifle_action,
		player.knife_action,
		player.slot_four_action,
	]:
		Input.action_release(action)

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
