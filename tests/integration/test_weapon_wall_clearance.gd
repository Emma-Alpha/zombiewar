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
	if not clearance.has_method("update_clearance"):
		_append(failures, Assertions.expect_true(
			false,
			"Clearance updates weapon pose without rejecting body yaw"
		))
		_cleanup(player, wall, zombie)
		return failures
	rifle._process(0.0)
	var stale_muzzle_position := rifle.muzzle.global_position
	var rifle_rest_transform := rifle.visual_anchor.transform
	var pistol := player.equipment.weapons[0] as RangedWeapon
	var pistol_rest_transform := pistol.visual_anchor.transform

	clearance.call(
		"update_clearance",
		0.016,
		Vector3(0.0, 0.0, -0.15),
		0.0
	)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Approaching a rifle-length wall clearance raises the rifle"
	))
	var committed_muzzle_position := (
		rifle.visual_anchor.global_transform * rifle.muzzle.position
	)
	_append(failures, Assertions.expect_true(
		committed_muzzle_position.distance_to(stale_muzzle_position) > 0.1,
		"Same-frame muzzle fixture commits a visibly different raised anchor"
	))
	var raised_axis := weapon_collision.transform.basis.y.normalized()
	_append(failures, Assertions.expect_true(
		not weapon_collision.disabled and absf(raised_axis.y) > 0.85,
		"Raised rifle keeps an active capsule aimed upward"
	))

	wall.position.z = -1.1
	wall.force_update_transform()
	var cursor_before := rifle.tracer_pool_cursor
	Input.action_press(player.primary_attack_action)
	player._physics_process(0.016)
	var shot_muzzle_position := _capsule_muzzle_endpoint(weapon_collision)
	rifle._physics_process(0.20)
	_append(failures, Assertions.expect_true(
		clearance.is_raised() and rifle.tracer_pool_cursor != cursor_before,
		"Raised rifle keeps firing at the existing cadence"
	))
	var same_frame_tracer := rifle.tracer_pool[cursor_before] as ShotTracer
	_append(failures, Assertions.expect_vector3_near(
		_tracer_start(same_frame_tracer),
		shot_muzzle_position,
		0.001,
		"Same-frame raised shot starts its tracer at the committed raised muzzle"
	))

	wall.position.z = -4.0
	wall.force_update_transform()
	clearance.call("update_clearance", 0.15, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		not clearance.is_raised() and rifle.visual_anchor.transform.is_equal_approx(rifle_rest_transform),
		"Clearance restores normal pose and the exact visual rest transform after 0.15 seconds"
	))
	Input.action_release(player.primary_attack_action)

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
	clearance.call("update_clearance", 0.016, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		not clearance.is_raised(),
		"Zombie bodies and hit areas do not trigger firearm clearance"
	))
	_cleanup(player, active_wall, zombie)
	_test_tucked_turn_uses_body_facing(failures)
	_test_switching_contract(failures)
	_test_normal_rebind_restores_stale_raised_visual(failures)
	_test_real_weapon_collision_motion(failures)
	_test_capsule_muzzle_origins_and_directions(failures)
	_test_raised_shot_obstruction_and_feedback(failures)
	return failures

func _test_real_weapon_collision_motion(failures: Array[String]) -> void:
	_assert_weapon_collision_motion(
		failures,
		0.0,
		Vector3(0.0, 1.12, -1.54),
		Vector3(3.0, 0.3, 0.02),
		Vector3(0.0, 0.0, -0.20),
		Vector3(0.10, 0.0, 0.0),
		"Forward",
		true
	)
	_assert_weapon_collision_motion(
		failures,
		PI * 0.5,
		Vector3(-1.54, 1.12, 0.0),
		Vector3(0.02, 0.3, 3.0),
		Vector3(-0.20, 0.0, 0.0),
		Vector3(0.0, 0.0, 0.10),
		"Yaw-90",
		false
	)

func _assert_weapon_collision_motion(
	failures: Array[String],
	yaw: float,
	wall_position: Vector3,
	wall_size: Vector3,
	requested_motion: Vector3,
	lateral_motion: Vector3,
	label: String,
	verify_disabled_control: bool
) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	tree.root.add_child(player)
	player.rotation.y = yaw
	player.force_update_transform()
	var wall := _make_wall(wall_position, wall_size)
	tree.root.add_child(wall)
	wall.force_update_transform()
	var weapon_collision := player.get_node("WeaponCollision") as CollisionShape3D
	var expected_center := Basis(Vector3.UP, yaw) * Vector3(0.0, 1.12, -0.62)
	var expected_axis := Basis(Vector3.UP, yaw) * Vector3.BACK
	_append(failures, Assertions.expect_vector3_near(
		weapon_collision.global_position,
		expected_center,
		0.0001,
		"%s WeaponCollision world center inherits yaw exactly once" % label
	))
	_append(failures, Assertions.expect_true(
		absf(weapon_collision.global_basis.y.normalized().dot(expected_axis)) > 0.999,
		"%s WeaponCollision long axis inherits yaw exactly once" % label
	))
	var start_position := player.global_position
	var collision := player.move_and_collide(requested_motion)
	_append(failures, Assertions.expect_true(
		collision != null,
		"%s real motion is blocked before full travel" % label
	))
	if collision != null:
		var actual_travel := player.global_position - start_position
		var wall_normal := -requested_motion.normalized()
		var wall_face := wall.position + wall_normal * 0.01
		var contact_position := collision.get_position()
		_append(failures, Assertions.expect_true(
			collision.get_collider() == wall and
				collision.get_local_shape() == weapon_collision,
			"%s first collision comes from WeaponCollision" % label
		))
		_append(failures, Assertions.expect_true(
			actual_travel.distance_to(collision.get_travel()) < 0.001 and
				actual_travel.length() > 0.08 and
				actual_travel.length() < requested_motion.length() - 0.01,
			"%s applies partial real travel before contact" % label
		))
		_append(failures, Assertions.expect_true(
			absf((contact_position - wall_face).dot(wall_normal)) < 0.03 and
				contact_position.y > 0.95 and contact_position.y < 1.29,
			"%s first-contact point lies on the weapon-height wall" % label
		))
		var body_front := player.global_position + requested_motion.normalized() * 0.45
		_append(failures, Assertions.expect_true(
			(body_front - wall_face).dot(wall_normal) > 0.8,
			"%s body capsule remains clear at weapon contact" % label
		))
		var contact_player_position := player.global_position
		var escape_motion := -requested_motion.normalized() * 0.10
		var escape_start := player.global_position
		player.move_and_collide(escape_motion)
		_append(failures, Assertions.expect_vector3_near(
			player.global_position - escape_start,
			escape_motion,
			0.001,
			"%s real backward motion escapes contact" % label
		))
		player.global_position = contact_player_position
		player.force_update_transform()
		var lateral_start := player.global_position
		var lateral_collision := player.move_and_collide(lateral_motion)
		_append(failures, Assertions.expect_true(
			lateral_collision == null and
				player.global_position.is_equal_approx(lateral_start + lateral_motion),
			"%s real lateral motion remains available" % label
		))
	if verify_disabled_control:
		player.global_position = start_position
		player.force_update_transform()
		weapon_collision.disabled = true
		var disabled_collision := player.move_and_collide(requested_motion)
		_append(failures, Assertions.expect_true(
			disabled_collision == null and
				player.global_position.is_equal_approx(start_position + requested_motion),
			"Disabling WeaponCollision makes the weapon-only fixture pass through"
		))
		weapon_collision.disabled = false
	_release_player_input(player)
	wall.free()
	player.free()

func _test_raised_shot_obstruction_and_feedback(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var clearance_wall := _make_wall(
		Vector3(0.0, 1.12, -1.1),
		Vector3(3.0, 0.3, 0.2)
	)
	var wall := _make_wall(
		Vector3(0.0, 2.3843, -1.4),
		Vector3(3.0, 0.3, 0.2)
	)
	var wall_target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	wall_target.position = Vector3(0.0, 1.4, -4.0)
	wall_target.set_physics_process(false)
	tree.root.add_child(player)
	tree.root.add_child(clearance_wall)
	tree.root.add_child(wall)
	tree.root.add_child(wall_target)
	var clearance := player.get_node("WeaponClearanceController") as WeaponClearanceController
	var rifle := player.equipment.get_current_weapon() as RangedWeapon
	clearance.call("update_clearance", 0.016, Vector3.ZERO, 0.0)
	rifle._process(0.0)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Layer-one wall fixture commits RAISED before firing"
	))
	var feedback_positions: Array[Vector3] = []
	rifle.attack_resolved.connect(func(
		_origin: Vector3,
		_direction: Vector3,
		result: HitResult,
		_recoil: float,
		_impulse: float
	) -> void:
		feedback_positions.append(result.position)
	)
	_assert_raised_blocker_pair(
		failures,
		rifle,
		clearance,
		wall,
		wall_target,
		feedback_positions,
		"wall"
	)
	wall_target.free()

	var area := _make_area(
		Vector3(0.0, 2.3843, -1.4),
		Vector3(2.0, 2.0, 0.2)
	)
	var area_target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	area_target.position = Vector3(0.0, 1.4, -4.0)
	area_target.set_physics_process(false)
	tree.root.add_child(area)
	tree.root.add_child(area_target)
	_assert_raised_blocker_pair(
		failures,
		rifle,
		clearance,
		area,
		area_target,
		feedback_positions,
		"Area"
	)
	_release_player_input(player)
	area_target.free()
	clearance_wall.free()
	player.free()

func _assert_raised_blocker_pair(
	failures: Array[String],
	rifle: RangedWeapon,
	clearance: WeaponClearanceController,
	blocker: CollisionObject3D,
	target: ZombieTarget,
	feedback_positions: Array[Vector3],
	label: String
) -> void:
	var ray_origin := rifle.get_ray_origin()
	var ray_end := ray_origin + Vector3.FORWARD * (
		rifle.definition as RangedWeaponDefinition
	).attack_range
	var blocked_result := rifle.call("_intersect_shot", ray_origin, ray_end) as Dictionary
	var blocked_hit: Vector3 = blocked_result.get("position", ray_end)
	var blocked_health := target.health.current
	var blocked_tracer_index := rifle.tracer_pool_cursor
	rifle._fire(-rifle.wielder.global_basis.z)
	var blocked_tracer := rifle.tracer_pool[blocked_tracer_index] as ShotTracer
	_append(failures, Assertions.expect_true(
		clearance.is_raised() and blocked_result.get("collider", null) == blocker and
			is_equal_approx(target.health.current, blocked_health),
		"RAISED layer-one %s is first hit and protects its target" % label
	))
	_append(failures, Assertions.expect_true(
		_tracer_end(blocked_tracer).distance_to(blocked_hit) < 0.001 and
			feedback_positions.back().distance_to(blocked_hit) < 0.001,
		"RAISED %s-blocked tracer and feedback end at first contact" % label
	))
	blocker.free()
	var clear_result := rifle.call("_intersect_shot", ray_origin, ray_end) as Dictionary
	var clear_hit: Vector3 = clear_result.get("position", ray_end)
	var clear_health := target.health.current
	var clear_tracer_index := rifle.tracer_pool_cursor
	rifle._fire(-rifle.wielder.global_basis.z)
	var clear_tracer := rifle.tracer_pool[clear_tracer_index] as ShotTracer
	_append(failures, Assertions.expect_true(
		clearance.is_raised() and target.health.current < clear_health,
		"Removing the %s lets the same RAISED shot damage its target" % label
	))
	_append(failures, Assertions.expect_true(
		_tracer_end(clear_tracer).distance_to(clear_hit) < 0.001 and
			feedback_positions.back().distance_to(clear_hit) < 0.001,
		"Unobstructed RAISED %s control reaches the target hit" % label
	))

func _test_capsule_muzzle_origins_and_directions(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree

	var normal_player := PLAYER_SCENE.instantiate() as PlayerController
	tree.root.add_child(normal_player)
	_assert_capsule_shot_contract(
		failures,
		normal_player,
		Vector3(0.0, 1.12, -1.395),
		"NORMAL"
	)
	normal_player.free()

	var raised_player := PLAYER_SCENE.instantiate() as PlayerController
	var raised_clearance_wall := _make_wall(
		Vector3(0.0, 1.12, -1.1),
		Vector3(3.0, 0.3, 0.2)
	)
	tree.root.add_child(raised_player)
	tree.root.add_child(raised_clearance_wall)
	var raised_clearance := raised_player.get_node(
		"WeaponClearanceController"
	) as WeaponClearanceController
	raised_clearance.update_clearance(0.016, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		raised_clearance.state.pose == WeaponClearanceState.Pose.RAISED,
		"RAISED capsule fixture commits before checking its muzzle endpoint"
	))
	_assert_capsule_shot_contract(
		failures,
		raised_player,
		Vector3(0.0, 2.3843, -0.58955),
		"RAISED"
	)
	raised_clearance_wall.free()
	raised_player.free()

	var tucked_player := PLAYER_SCENE.instantiate() as PlayerController
	var tucked_front_wall := _make_wall(
		Vector3(-1.1, 1.12, 0.0),
		Vector3(0.2, 0.3, 3.0)
	)
	var tucked_ceiling := _make_wall(
		Vector3(0.0, 2.25, 0.0),
		Vector3(3.0, 0.2, 2.0)
	)
	tree.root.add_child(tucked_player)
	tree.root.add_child(tucked_front_wall)
	tree.root.add_child(tucked_ceiling)
	tucked_player.rotation.y = PI * 0.5
	tucked_player.force_update_transform()
	var tucked_clearance := tucked_player.get_node(
		"WeaponClearanceController"
	) as WeaponClearanceController
	tucked_clearance.update_clearance(0.016, Vector3.ZERO, PI * 0.5)
	_append(failures, Assertions.expect_true(
		tucked_clearance.state.pose == WeaponClearanceState.Pose.TUCKED,
		"TUCKED capsule fixture commits before checking its muzzle endpoint"
	))
	_assert_capsule_shot_contract(
		failures,
		tucked_player,
		Vector3(0.0, 1.675, 0.0),
		"TUCKED"
	)
	tucked_ceiling.free()
	tucked_front_wall.free()
	tucked_player.free()

func _assert_capsule_shot_contract(
	failures: Array[String],
	player: PlayerController,
	expected_origin: Vector3,
	label: String
) -> void:
	var rifle := player.equipment.get_current_weapon() as RangedWeapon
	var attack_origins: Array[Vector3] = []
	var attack_directions: Array[Vector3] = []
	rifle.attack_resolved.connect(func(
		origin: Vector3,
		direction: Vector3,
		_result: HitResult,
		_recoil: float,
		_impulse: float
	) -> void:
		attack_origins.append(origin)
		attack_directions.append(direction)
	)
	rifle._process(0.0)
	var tracer_index := rifle.tracer_pool_cursor
	var expected_direction := -player.global_basis.z.normalized()
	rifle._fire(expected_direction)
	var tracer := rifle.tracer_pool[tracer_index] as ShotTracer
	_append(failures, Assertions.expect_vector3_near(
		rifle.get_ray_origin(),
		expected_origin,
		0.001,
		"%s functional ray uses the hand-derived capsule endpoint" % label
	))
	_append(failures, Assertions.expect_vector3_near(
		rifle.muzzle.global_position,
		expected_origin,
		0.001,
		"%s muzzle flash uses the hand-derived capsule endpoint" % label
	))
	_append(failures, Assertions.expect_vector3_near(
		_tracer_start(tracer),
		expected_origin,
		0.001,
		"%s tracer uses the hand-derived capsule endpoint" % label
	))
	_append(failures, Assertions.expect_vector3_near(
		attack_origins.back(),
		expected_origin,
		0.001,
		"%s attack feedback uses the hand-derived capsule endpoint" % label
	))
	_append(failures, Assertions.expect_vector3_near(
		attack_directions.back(),
		expected_direction,
		0.001,
		"%s shot direction follows the player's actual forward basis" % label
	))

func _test_tucked_turn_uses_body_facing(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var side_blocker := _make_wall(
		Vector3(1.1, 0.98, 0.0),
		Vector3(0.2, 0.14, 1.2)
	)
	var low_ceiling := _make_wall(
		Vector3(0.6, 2.25, 0.0),
		Vector3(2.0, 0.2, 2.0)
	)
	var right_side_target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	right_side_target.position = Vector3(4.0, 0.0, 0.0)
	right_side_target.set_physics_process(false)
	_release_player_input(player)
	tree.root.add_child(player)
	tree.root.add_child(side_blocker)
	tree.root.add_child(low_ceiling)
	tree.root.add_child(right_side_target)
	player.aim_direction = Vector3.RIGHT
	var resolved_directions: Array[Vector3] = [Vector3.ZERO]
	player.attack_resolved.connect(func(direction: Vector3, _result, _strength: float) -> void:
		resolved_directions[0] = direction
	)
	Input.action_press(player.primary_attack_action)
	player._physics_process(0.016)
	var rifle := player.equipment.get_current_weapon() as RangedWeapon
	rifle._physics_process(0.20)
	var actual_forward := -player.global_basis.z.normalized()
	var resolved_direction := resolved_directions[0]
	_append(failures, Assertions.expect_true(
		is_equal_approx(player.rotation.y, -PI * 0.5) and
			actual_forward.dot(Vector3.RIGHT) > 0.999 and
			resolved_direction.dot(actual_forward) > 0.999,
		"Fully blocked rifle tucks while the player completes the target turn"
	))
	var clearance := player.get_node(
		"WeaponClearanceController"
	) as WeaponClearanceController
	_append(failures, Assertions.expect_true(
		clearance.state.pose == WeaponClearanceState.Pose.TUCKED and
			right_side_target.health.current < right_side_target.health.maximum,
		"Tucked rifle still fires along the player's new body facing"
	))
	_release_player_input(player)
	right_side_target.free()
	low_ceiling.free()
	side_blocker.free()
	player.free()

func _test_switching_contract(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var front_wall := _make_wall(
		Vector3(0.0, 1.12, -1.1),
		Vector3(3.0, 0.3, 0.2)
	)
	tree.root.add_child(player)
	tree.root.add_child(front_wall)
	var clearance := player.get_node("WeaponClearanceController") as WeaponClearanceController
	var weapon_collision := player.get_node("WeaponCollision") as CollisionShape3D
	var normal_probe := player.get_node(
		"WeaponClearanceController/NormalProbe"
	) as ShapeCast3D
	var raised_probe := player.get_node(
		"WeaponClearanceController/RaisedProbe"
	) as ShapeCast3D
	clearance.call("update_clearance", 0.016, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Front wall commits the raised pose before ranged switching"
	))
	_append(failures, Assertions.expect_true(
		player.equipment.equip_slot(0) and clearance.is_raised() and
			not weapon_collision.disabled,
		"Ranged switch inherits the committed raised collision"
	))
	var runtime_capsules: Array[CapsuleShape3D] = [
		weapon_collision.shape as CapsuleShape3D,
		normal_probe.shape as CapsuleShape3D,
		raised_probe.shape as CapsuleShape3D,
	]
	for capsule: CapsuleShape3D in runtime_capsules:
		_append(failures, Assertions.expect_true(
			is_equal_approx(capsule.height, 1.55) and
				is_equal_approx(capsule.radius, 0.12),
			"Ranged switch preserves the unified runtime envelope"
		))
	var remote_switch_ceiling := _make_wall(
		Vector3(0.0, 2.25, -0.25),
		Vector3(3.0, 0.2, 2.0)
	)
	tree.root.add_child(remote_switch_ceiling)
	_append(failures, Assertions.expect_true(
		player.equipment.equip_slot(1) and
			clearance.state.pose == WeaponClearanceState.Pose.TUCKED and
			not weapon_collision.disabled,
		"Remote-to-remote switch inherits a safe tucked pose when both probes block"
	))
	_append(failures, Assertions.expect_true(
		normal_probe.enabled and raised_probe.enabled,
		"Tucked remote switch preserves both active clearance probes"
	))
	remote_switch_ceiling.free()
	clearance.call("update_clearance", 0.016, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Preserved probes still resolve the remaining front-wall obstruction"
	))
	front_wall.position.z = -4.0
	front_wall.force_update_transform()
	clearance.call("update_clearance", 0.15, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		not clearance.is_raised(),
		"Preserved probes still restore NORMAL after the wall clears"
	))
	player.equipment.equip_slot(0)

	var rifle_candidate := player.equipment.weapons[1]
	var saved_anchor := rifle_candidate.visual_anchor
	rifle_candidate.visual_anchor = null
	var before_weapon := player.equipment.get_current_weapon()
	_append(failures, Assertions.expect_true(
		not player.equipment.equip_slot(1) and
			player.equipment.get_current_weapon() == before_weapon and
			not weapon_collision.disabled,
		"Missing ranged visual rejects the switch without disabling current collision"
	))
	rifle_candidate.visual_anchor = saved_anchor
	var freed_anchor := Node3D.new()
	rifle_candidate.visual_anchor = freed_anchor
	freed_anchor.free()
	var before_slot := player.equipment.current_slot
	_append(failures, Assertions.expect_true(
		not player.equipment.equip_slot(1) and
			player.equipment.get_current_weapon() == before_weapon and
			player.equipment.current_slot == before_slot and
			not weapon_collision.disabled and normal_probe.enabled and raised_probe.enabled,
		"Freed ranged visual rejects transactionally without disturbing active clearance"
	))
	rifle_candidate.visual_anchor = saved_anchor

	player.equipment.equip_slot(2)
	front_wall.position.z = -1.1
	front_wall.force_update_transform()
	var low_ceiling := _make_wall(
		Vector3(0.0, 2.25, -0.25),
		Vector3(3.0, 0.2, 2.0)
	)
	tree.root.add_child(low_ceiling)
	_append(failures, Assertions.expect_true(
		player.equipment.equip_slot(1) and
			player.equipment.get_current_definition().weapon_id == &"rifle" and
			player.equipment.weapons[1].visible and
			clearance.state.pose == WeaponClearanceState.Pose.TUCKED and
			not weapon_collision.disabled,
		"Melee-to-ranged switch equips safely in tucked pose when both probes block"
	))
	_release_player_input(player)
	low_ceiling.free()
	front_wall.free()
	player.free()

func _test_normal_rebind_restores_stale_raised_visual(
	failures: Array[String]
) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var front_wall := _make_wall(
		Vector3(0.0, 1.12, -1.1),
		Vector3(3.0, 0.3, 0.2)
	)
	tree.root.add_child(player)
	tree.root.add_child(front_wall)
	var clearance := player.get_node("WeaponClearanceController") as WeaponClearanceController
	var rifle := player.equipment.weapons[1] as RangedWeapon
	var rifle_rest_transform := rifle.visual_anchor.transform
	clearance.call("update_clearance", 0.016, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Front wall raises the old rifle before its pose becomes stale"
	))
	front_wall.position.z = -4.0
	front_wall.force_update_transform()
	var low_ceiling := _make_wall(
		Vector3(0.0, 2.25, -0.25),
		Vector3(3.0, 0.2, 2.0)
	)
	tree.root.add_child(low_ceiling)
	_append(failures, Assertions.expect_true(
		player.equipment.equip_slot(0) and not clearance.is_raised() and
			rifle.visual_anchor.transform.is_equal_approx(rifle_rest_transform),
		"Normal-only rebind restores the old raised rifle transform before hiding it"
	))
	_append(failures, Assertions.expect_true(
		player.equipment.equip_slot(1) and not clearance.is_raised() and
			rifle.visual_anchor.transform.is_equal_approx(rifle_rest_transform),
		"Returning to the rifle retains its original normal rest transform"
	))
	_release_player_input(player)
	low_ceiling.free()
	front_wall.free()
	player.free()

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

func _make_area(position: Vector3, size: Vector3) -> Area3D:
	var area := Area3D.new()
	area.position = position
	area.collision_layer = 1
	area.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	area.add_child(collision)
	return area

func _tracer_start(tracer: ShotTracer) -> Vector3:
	return tracer.to_global(Vector3(0.0, 0.0, 0.5))

func _tracer_end(tracer: ShotTracer) -> Vector3:
	return tracer.to_global(Vector3(0.0, 0.0, -0.5))

func _capsule_muzzle_endpoint(weapon_collision: CollisionShape3D) -> Vector3:
	var capsule := weapon_collision.shape as CapsuleShape3D
	return weapon_collision.global_position - (
		weapon_collision.global_basis.y.normalized() * capsule.height * 0.5
	)

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
	clearance.call("update_clearance", 0.15, Vector3.ZERO, 0.0)
	player.rotation.y = 0.0

	var side_yaw := -PI * 0.5
	player.rotation.y = side_yaw
	var rest_barrel_axis := rifle.visual_anchor.global_basis.x.normalized()
	player.rotation.y = 0.0
	wall.position = Vector3(1.36, 1.12, 0.0)
	shape.size = Vector3(0.02, 0.3, 1.0)
	wall.force_update_transform()
	clearance.call(
		"update_clearance",
		0.0,
		Vector3.ZERO,
		side_yaw
	)
	player.rotation.y = side_yaw
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
	clearance.call(
		"update_clearance",
		0.15,
		Vector3.ZERO,
		side_yaw
	)
	player.rotation.y = side_yaw
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Side-facing restore margin keeps the rifle raised inside its 0.08 meter buffer"
	))

	wall.position.x = 1.57
	wall.force_update_transform()
	clearance.call(
		"update_clearance",
		0.15,
		Vector3.ZERO,
		side_yaw
	)
	player.rotation.y = side_yaw
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
