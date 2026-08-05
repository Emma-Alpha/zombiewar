extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")

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
			"Starting rifle applies its fitted capsule length"
		))
		_append(failures, Assertions.expect_float_near(
			capsule.radius,
			0.12,
			0.0001,
			"Starting rifle applies its fitted capsule radius"
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

	var raised_yaw := controller.resolve_facing_yaw(0.0, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_float_near(
		raised_yaw,
		0.0,
		0.0001,
		"Normal obstruction permits the safe raised facing"
	))
	_append(failures, Assertions.expect_true(
		controller.is_raised(),
		"Normal obstruction transitions the controller to its raised pose"
	))
	_append(failures, Assertions.expect_true(
		not controller.can_fire(),
		"Raised weapon cannot fire while clearance is constrained"
	))
	controller._process(controller.transition_duration)
	_append(failures, Assertions.expect_true(
		not rifle_visual.transform.is_equal_approx(rest_transform),
		"Public clearance resolution rotates the existing hand-mounted rifle"
	))

	wall.position = Vector3(0.0, 1.12, -5.0)
	wall.force_update_transform()
	controller.observe_trigger(false)
	controller.resolve_facing_yaw(0.10, Vector3.ZERO, 0.0)
	controller.resolve_facing_yaw(0.05, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		not controller.is_raised(),
		"Clear space for 0.15 seconds restores the normal pose"
	))
	_append(failures, Assertions.expect_true(
		not controller.can_fire(),
		"Restoring visual pose keeps fire gated until interpolation finishes"
	))
	controller._process(controller.transition_duration * 0.5)
	_append(failures, Assertions.expect_true(
		not controller.can_fire(),
		"Half-complete visual restoration still keeps fire gated"
	))
	controller._process(controller.transition_duration)
	_append(failures, Assertions.expect_true(
		rifle_visual.transform.is_equal_approx(rest_transform),
		"Completed normal restoration returns the rifle to its exact rest transform"
	))
	_append(failures, Assertions.expect_true(
		controller.can_fire(),
		"Released trigger can fire after visual restoration finishes"
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
		rifle_visual.transform.is_equal_approx(rest_transform),
		"Unequipping restores the rifle local transform"
	))

	player.equipment.equip_slot(1)
	wall.position = Vector3(0.0, 1.12, -1.1)
	wall.force_update_transform()
	controller.resolve_facing_yaw(0.0, Vector3.ZERO, 0.0)
	controller._process(controller.transition_duration)
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
	_test_side_facing_visual_and_restore_margin(failures, tree)
	return failures

func _test_side_facing_visual_and_restore_margin(
	failures: Array[String],
	tree: SceneTree
) -> void:
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var wall := _new_side_clearance_wall(1.35)
	tree.root.add_child(host)
	host.add_child(player)
	host.add_child(wall)

	var controller := player.get_node_or_null(
		"WeaponClearanceController"
	) as WeaponClearanceController
	var rifle := player.equipment.get_current_weapon() as RangedWeapon
	var rifle_visual := rifle.visual_anchor if rifle != null else null
	if controller == null or rifle_visual == null:
		_append(failures, Assertions.expect_true(
			false,
			"Side-facing player exposes real clearance and rifle visual"
		))
		host.free()
		return

	player.aim_direction = Vector3.RIGHT
	var side_yaw := -PI * 0.5
	var rest_barrel_axis := rifle_visual.global_basis.x.normalized()
	controller.resolve_facing_yaw(0.0, Vector3.ZERO, side_yaw)
	controller._process(controller.transition_duration)
	var raised_barrel_axis := rifle_visual.global_basis.x.normalized()
	var raised_angle := acos(clampf(
		rest_barrel_axis.dot(raised_barrel_axis),
		-1.0,
		1.0
	))
	_append(failures, Assertions.expect_true(
		controller.is_raised(),
		"Side wall blocks the normal rifle while the raised pose remains usable"
	))
	_append(failures, Assertions.expect_float_near(
		raised_angle,
		deg_to_rad(65.0),
		0.05,
		"Raised rifle rotates its visible local-X barrel axis by 65 degrees"
	))
	_append(failures, Assertions.expect_true(
		raised_barrel_axis.y > rest_barrel_axis.y + 0.75,
		"Raised rifle visibly lifts its barrel axis above the normal pose"
	))

	wall.position.x = 1.45
	wall.force_update_transform()
	controller.resolve_facing_yaw(0.15, Vector3.ZERO, side_yaw)
	_append(failures, Assertions.expect_true(
		controller.is_raised(),
		"Side-facing restore margin keeps the rifle raised inside its 0.08 meter buffer"
	))

	wall.position.x = 1.57
	wall.force_update_transform()
	controller.resolve_facing_yaw(0.15, Vector3.ZERO, side_yaw)
	_append(failures, Assertions.expect_true(
		not controller.is_raised(),
		"Side-facing rifle lowers only after clearing the 0.08 meter restore margin"
	))
	host.free()

func _new_clearance_wall() -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	wall.position = Vector3(0.0, 1.12, -1.1)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.0, 0.3, 0.2)
	collision.shape = shape
	wall.add_child(collision)
	return wall

func _new_side_clearance_wall(near_face_x: float) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	wall.position = Vector3(near_face_x + 0.01, 1.12, 0.0)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.02, 0.3, 1.0)
	collision.shape = shape
	wall.add_child(collision)
	return wall

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
