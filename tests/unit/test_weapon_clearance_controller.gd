extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const WeaponClearanceState = preload(
	"res://scripts/player/weapon_clearance_state.gd"
)

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var wall := _new_clearance_wall()
	tree.root.add_child(host)
	host.add_child(player)
	host.add_child(wall)

	var controller := player.get_node_or_null(
		"WeaponClearanceController"
	) as WeaponClearanceController
	var weapon_collision := player.get_node_or_null(
		"WeaponCollision"
	) as CollisionShape3D
	var normal_probe := player.get_node_or_null(
		"WeaponClearanceController/NormalProbe"
	) as ShapeCast3D
	var raised_probe := player.get_node_or_null(
		"WeaponClearanceController/RaisedProbe"
	) as ShapeCast3D
	_append(failures, Assertions.expect_true(
		controller != null,
		"Player owns a weapon-clearance controller"
	))
	_append(failures, Assertions.expect_true(
		weapon_collision != null and weapon_collision.get_parent() == player,
		"Weapon collision is a direct CharacterBody child"
	))
	_append(failures, Assertions.expect_true(
		normal_probe != null and raised_probe != null,
		"Player owns normal and raised wall-clearance probes"
	))
	if controller == null or weapon_collision == null or normal_probe == null or raised_probe == null:
		host.free()
		return failures

	var rifle_shape := weapon_collision.shape as CapsuleShape3D
	var normal_shape := normal_probe.shape as CapsuleShape3D
	var raised_shape := raised_probe.shape as CapsuleShape3D
	_append(failures, Assertions.expect_true(
		rifle_shape != null and normal_shape != null and raised_shape != null,
		"Rifle collision and both probes use capsule shapes"
	))
	if rifle_shape == null or normal_shape == null or raised_shape == null:
		host.free()
		return failures
	_append(failures, Assertions.expect_true(
		rifle_shape != normal_shape and rifle_shape != raised_shape and
			normal_shape != raised_shape,
		"Collision and probes own independent mutable capsule instances"
	))
	for capsule in [rifle_shape, normal_shape, raised_shape]:
		_append(failures, Assertions.expect_float_near(
			capsule.height,
			1.55,
			0.0001,
			"Every runtime clearance capsule uses rifle length"
		))
		_append(failures, Assertions.expect_float_near(
			capsule.radius,
			0.12,
			0.0001,
			"Every runtime clearance capsule uses rifle radius"
		))
	_append(failures, Assertions.expect_true(
		not weapon_collision.disabled,
		"Starting rifle enables its fitted capsule collision"
	))
	for probe in [normal_probe, raised_probe]:
		_append(failures, Assertions.expect_true(
			probe.collision_mask == 1 and not probe.collide_with_areas,
			"Weapon clearance probe queries only solid world layer one"
		))

	var rifle := player.equipment.get_current_weapon()
	var rifle_visual := rifle.visual_anchor if rifle != null else null
	_append(failures, Assertions.expect_true(
		rifle != null and rifle_visual != null,
		"Starting rifle exposes its existing hand-mounted visual"
	))
	if rifle == null or rifle_visual == null:
		host.free()
		return failures
	var rest_transform := rifle_visual.transform

	var accepted_yaw := controller.resolve_facing_yaw(0.016, Vector3(0.0, 0.0, -0.15), 0.0)
	_append(failures, Assertions.expect_true(
		controller.is_raised() and accepted_yaw == 0.0 and
			not rifle_visual.transform.is_equal_approx(rest_transform),
		"Safe raised request snaps physical and visual pose in the obstruction frame"
	))

	var ceiling := _new_clearance_wall(
		Vector3(0.0, 2.25, -0.25),
		Vector3(3.0, 0.2, 2.0)
	)
	host.add_child(ceiling)
	var previous_pose := controller.state.pose
	var previous_collision := weapon_collision.transform
	var previous_visual := rifle_visual.transform
	var previous_yaw := player.rotation.y
	_append(failures, Assertions.expect_true(
		controller.resolve_facing_yaw(0.016, Vector3.ZERO, PI * 0.5) == previous_yaw,
		"Blocked normal and raised requests reject the target yaw"
	))
	_append(failures, Assertions.expect_true(
		controller.state.pose == previous_pose and
			weapon_collision.transform.is_equal_approx(previous_collision) and
			rifle_visual.transform.is_equal_approx(previous_visual),
		"Rejected pose preserves committed state, collision, and visual"
	))

	wall.position.z = -4.0
	wall.force_update_transform()
	controller.resolve_facing_yaw(0.10, Vector3.ZERO, PI * 0.5)
	_append(failures, Assertions.expect_true(
		controller.state.pose == previous_pose and
			weapon_collision.transform.is_equal_approx(previous_collision) and
			rifle_visual.transform.is_equal_approx(previous_visual) and
			player.rotation.y == previous_yaw,
		"Raised pose stays committed while a blocked raised probe prevents the yaw"
	))
	var restored_yaw := controller.resolve_facing_yaw(0.05, Vector3.ZERO, PI * 0.5)
	_append(failures, Assertions.expect_true(
		controller.state.pose == WeaponClearanceState.Pose.NORMAL and
			rifle_visual.transform.is_equal_approx(rest_transform) and
			restored_yaw == PI * 0.5,
		"A full 0.15 seconds of normal clearance atomically commits normal pose"
	))
	ceiling.free()

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
		rifle_visual.transform.is_equal_approx(rest_transform),
		"Unequipping restores the rifle local transform"
	))

	player.equipment.equip_slot(1)
	wall.position = Vector3(0.0, 1.12, -1.1)
	wall.force_update_transform()
	controller.resolve_facing_yaw(0.0, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		controller.is_raised() and not rifle_visual.transform.is_equal_approx(rest_transform),
		"A second real wall obstruction raises the rifle before lethal damage"
	))
	player.apply_damage(1000.0)
	_append(failures, Assertions.expect_true(
		weapon_collision.disabled,
		"Player death disables firearm wall collision"
	))
	_append(failures, Assertions.expect_true(
		rifle_visual.transform.is_equal_approx(rest_transform),
		"Player death immediately restores a raised rifle visual"
	))
	host.free()
	return failures

func _new_clearance_wall(
	position := Vector3(0.0, 1.12, -1.1),
	size := Vector3(1.0, 0.3, 0.2)
) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	wall.position = position
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	wall.add_child(collision)
	return wall

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
