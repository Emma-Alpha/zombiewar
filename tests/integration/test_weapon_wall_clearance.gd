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

	clearance.observe_trigger(true)
	_append(failures, Assertions.expect_true(
		not clearance.can_fire(),
		"Held trigger cannot fire while the rifle is raised"
	))
	var cursor_before := rifle.tracer_pool_cursor
	Input.action_press(player.primary_attack_action)
	player._physics_process(0.016)
	rifle._physics_process(0.20)
	_append(failures, Assertions.expect_equal(
		rifle.tracer_pool_cursor,
		cursor_before,
		"Held fire input does not create a tracer while raised"
	))

	wall.position.z = -4.0
	wall.force_update_transform()
	clearance.resolve_facing_yaw(0.15, Vector3.ZERO, 0.0)
	clearance._process(clearance.transition_duration)
	_append(failures, Assertions.expect_true(
		not clearance.is_raised() and not clearance.can_fire(),
		"Lowered rifle still requires trigger release"
	))
	Input.action_release(player.primary_attack_action)
	player._physics_process(0.016)
	_append(failures, Assertions.expect_true(
		clearance.can_fire(),
		"Trigger release re-enables the lowered rifle"
	))
	Input.action_press(player.primary_attack_action)
	player._physics_process(0.016)
	rifle._physics_process(0.20)
	_append(failures, Assertions.expect_true(
		rifle.tracer_pool_cursor != cursor_before,
		"A fresh press fires after clearance is restored"
	))
	Input.action_release(player.primary_attack_action)

	wall.position.z = -0.95
	wall.force_update_transform()
	player.equipment.equip_slot(0)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Wall-side pistol switch chooses the raised pose immediately"
	))

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
