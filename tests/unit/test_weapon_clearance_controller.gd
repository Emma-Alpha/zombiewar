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
	if not controller.has_method("update_clearance"):
		_append(failures, Assertions.expect_true(
			false,
			"Weapon clearance updates pose without deciding player yaw"
		))
		host.free()
		return failures

	controller.call("update_clearance", 0.016, Vector3(0.0, 0.0, -0.15), 0.0)
	_append(failures, Assertions.expect_true(
		controller.is_raised() and
			not rifle_visual.transform.is_equal_approx(rest_transform),
		"Safe raised request snaps physical and visual pose in the obstruction frame"
	))

	var ceiling := _new_clearance_wall(
		Vector3(0.0, 2.25, -0.25),
		Vector3(3.0, 0.2, 2.0)
	)
	host.add_child(ceiling)
	var target_yaw := PI * 0.5
	controller.call("update_clearance", 0.016, Vector3.ZERO, target_yaw)
	player.rotation.y = target_yaw
	_append(failures, Assertions.expect_true(
		controller.state.pose == WeaponClearanceState.Pose.TUCKED and
			is_equal_approx(player.rotation.y, target_yaw),
		"Blocked normal and raised poses tuck the rifle without rejecting player yaw"
	))
	var player_collision := player.get_node("CollisionShape3D") as CollisionShape3D
	var player_capsule := player_collision.shape as CapsuleShape3D
	var tucked_capsule := weapon_collision.shape as CapsuleShape3D
	_append(failures, Assertions.expect_true(
		player_capsule != null and tucked_capsule != null and
			tucked_capsule.height < player_capsule.height and
			tucked_capsule.radius < player_capsule.radius and
			weapon_collision.position.is_equal_approx(player_collision.position),
		"Tucked rifle capsule is fully contained by the player capsule"
	))
	_append(failures, Assertions.expect_true(
		is_equal_approx(tucked_capsule.height, 1.55) and
			is_equal_approx(tucked_capsule.radius, 0.12) and
			absf(weapon_collision.basis.y.normalized().dot(Vector3.DOWN)) > 0.999,
		"Tucked rifle keeps the shared envelope with its muzzle end pointing upward"
	))

	wall.position.z = -4.0
	wall.force_update_transform()
	ceiling.position.y = 5.0
	ceiling.force_update_transform()
	controller.call("update_clearance", 0.016, Vector3.ZERO, target_yaw)
	_append(failures, Assertions.expect_true(
		controller.state.pose == WeaponClearanceState.Pose.RAISED,
		"Tucked pose restores to raised as soon as raised clearance is available"
	))
	controller.call("update_clearance", 0.10, Vector3.ZERO, target_yaw)
	controller.call("update_clearance", 0.05, Vector3.ZERO, target_yaw)
	_append(failures, Assertions.expect_true(
		controller.state.pose == WeaponClearanceState.Pose.NORMAL and
			rifle_visual.transform.is_equal_approx(rest_transform),
		"A full 0.15 seconds of normal clearance restores normal pose"
	))
	ceiling.free()

	var saved_anchor := rifle.visual_anchor
	var collision_before_rejected_bind := weapon_collision.transform
	rifle.visual_anchor = null
	var rejected_bind := controller.try_bind_weapon(rifle)
	_append(failures, Assertions.expect_true(
		not rejected_bind and not weapon_collision.disabled and
			weapon_collision.transform.is_equal_approx(collision_before_rejected_bind),
		"Rejected ranged bind preserves the active weapon collision"
	))
	rifle.visual_anchor = saved_anchor
	controller.try_bind_weapon(rifle)
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
	controller.call("update_clearance", 0.0, Vector3.ZERO, 0.0)
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
	_test_exit_tree_restores_visual_transform(failures)
	return failures

func _test_exit_tree_restores_visual_transform(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var wall := _new_clearance_wall()
	tree.root.add_child(player)
	tree.root.add_child(wall)
	var controller := player.get_node("WeaponClearanceController") as WeaponClearanceController
	var rifle := player.equipment.get_current_weapon()
	var rifle_visual := rifle.visual_anchor
	var rest_transform := rifle_visual.transform
	controller.call("update_clearance", 0.016, Vector3.ZERO, 0.0)
	if not controller.has_method("_exit_tree"):
		_append(failures, Assertions.expect_true(
			false,
			"Clearance exit restores the raised weapon local transform"
		))
	else:
		controller.call("_exit_tree")
		_append(failures, Assertions.expect_true(
			rifle_visual.transform.is_equal_approx(rest_transform),
			"Clearance exit restores the raised weapon local transform"
		))
	wall.free()
	player.free()

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
