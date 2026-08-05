extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const ZombieHitbox = preload("res://scripts/combat/zombie_hitbox.gd")
const EquipmentController = preload("res://scripts/player/equipment_controller.gd")
const RangedWeapon = preload("res://scripts/combat/weapons/ranged_weapon.gd")
const HitResult = preload("res://scripts/combat/hit_result.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_pistol_damage_and_limit(failures)
	_test_rifle_damage_and_summary(failures)
	_test_wall_block_and_hitbox_deduplication(failures)
	_test_runtime_penetration_limit_is_clamped(failures)
	_test_unobstructed_penetration_reaches_max_range(failures)
	return failures

func _test_pistol_damage_and_limit(failures: Array[String]) -> void:
	var fixture := _make_fixture()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	fixture.add_child(player)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(0)
	var weapon := equipment.get_current_weapon() as RangedWeapon
	_disable_spread(weapon)
	var targets: Array[ZombieTarget] = [
		_spawn_target(fixture, Vector3(0.0, 0.0, -4.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -7.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -10.0)),
	]

	weapon._fire(Vector3.FORWARD)

	_append(failures, Assertions.expect_float_near(
		targets[0].health.current,
		15.0,
		0.0001,
		"Pistol first zombie receives full damage"
	))
	_append(failures, Assertions.expect_float_near(
		targets[1].health.current,
		32.5,
		0.0001,
		"Pistol second zombie receives coefficient damage"
	))
	_append(failures, Assertions.expect_float_near(
		targets[2].health.current,
		50.0,
		0.0001,
		"Pistol stops after one extra penetration"
	))
	fixture.free()

func _test_rifle_damage_and_summary(failures: Array[String]) -> void:
	var fixture := _make_fixture()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	fixture.add_child(player)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(1)
	var weapon := equipment.get_current_weapon() as RangedWeapon
	_disable_spread(weapon)
	var targets: Array[ZombieTarget] = [
		_spawn_target(fixture, Vector3(0.0, 0.0, -4.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -7.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -10.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -13.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -16.0)),
	]
	var feedback_results: Array[HitResult] = []
	weapon.attack_resolved.connect(func(
		_origin: Vector3,
		_direction: Vector3,
		result: HitResult,
		_visual_recoil_kick: float,
		_camera_impulse_strength: float
	) -> void:
		feedback_results.append(result)
	)

	weapon._fire(Vector3.FORWARD)

	var expected_health: Array[float] = [
		25.0,
		31.25,
		35.9375,
		39.453125,
		50.0,
	]
	for target_index in range(targets.size()):
		_append(failures, Assertions.expect_float_near(
			targets[target_index].health.current,
			expected_health[target_index],
			0.0001,
			"Rifle penetration health at target %d" % target_index
		))
	_append(failures, Assertions.expect_equal(
		feedback_results.size(),
		1,
		"Penetrating rifle shot emits one attack result"
	))
	if feedback_results.size() == 1:
		_append(failures, Assertions.expect_true(
			feedback_results[0].did_hit,
			"Penetrating rifle summary reports a hit"
		))
		_append(failures, Assertions.expect_float_near(
			feedback_results[0].damage_applied,
			68.359375,
			0.0001,
			"Penetrating rifle summary totals actual damage"
		))
	fixture.free()

func _test_wall_block_and_hitbox_deduplication(
	failures: Array[String]
) -> void:
	var wall_fixture := _make_fixture()
	var wall_player := PLAYER_SCENE.instantiate() as PlayerController
	wall_fixture.add_child(wall_player)
	var wall_equipment := wall_player.get_node(
		"EquipmentController"
	) as EquipmentController
	wall_equipment.equip_slot(0)
	var wall_weapon := wall_equipment.get_current_weapon() as RangedWeapon
	_disable_spread(wall_weapon)
	var front_target := _spawn_target(
		wall_fixture,
		Vector3(0.0, 0.0, -4.0)
	)
	var rear_target := _spawn_target(
		wall_fixture,
		Vector3(0.0, 0.0, -8.0)
	)
	var wall := _make_wall(
		Vector3(0.0, 1.1, -6.0),
		Vector3(2.0, 2.0, 0.2)
	)
	wall_fixture.add_child(wall)
	wall.force_update_transform()
	var tracer_index := wall_weapon.tracer_pool_cursor

	wall_weapon._fire(Vector3.FORWARD)

	var tracer := wall_weapon.tracer_pool[tracer_index] as ShotTracer
	_append(failures, Assertions.expect_float_near(
		front_target.health.current,
		15.0,
		0.0001,
		"Zombie before wall receives pistol damage"
	))
	_append(failures, Assertions.expect_float_near(
		rear_target.health.current,
		50.0,
		0.0001,
		"Wall blocks penetration damage behind it"
	))
	_append(failures, Assertions.expect_float_near(
		_tracer_end(tracer).z,
		-5.9,
		0.05,
		"Wall terminates the penetrating tracer"
	))
	wall_fixture.free()

	var dedupe_fixture := _make_fixture()
	var dedupe_player := PLAYER_SCENE.instantiate() as PlayerController
	dedupe_fixture.add_child(dedupe_player)
	var dedupe_equipment := dedupe_player.get_node(
		"EquipmentController"
	) as EquipmentController
	dedupe_equipment.equip_slot(0)
	var dedupe_weapon := dedupe_equipment.get_current_weapon() as RangedWeapon
	_disable_spread(dedupe_weapon)
	var multi_hitbox_target := _spawn_target(
		dedupe_fixture,
		Vector3(0.0, 0.0, -4.0)
	)
	_add_extra_hitbox(multi_hitbox_target)
	var next_target := _spawn_target(
		dedupe_fixture,
		Vector3(0.0, 0.0, -8.0)
	)

	dedupe_weapon._fire(Vector3.FORWARD)

	_append(failures, Assertions.expect_float_near(
		multi_hitbox_target.health.current,
		15.0,
		0.0001,
		"Multiple hitboxes damage one zombie once"
	))
	_append(failures, Assertions.expect_float_near(
		next_target.health.current,
		32.5,
		0.0001,
		"Duplicate hitbox does not consume penetration count"
	))
	dedupe_fixture.free()

func _test_runtime_penetration_limit_is_clamped(
	failures: Array[String]
) -> void:
	var fixture := _make_fixture()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	fixture.add_child(player)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(1)
	var weapon := equipment.get_current_weapon() as RangedWeapon
	_disable_spread(weapon)
	var ranged_definition := weapon.definition as RangedWeaponDefinition
	var original_max_penetration_count := ranged_definition.max_penetration_count
	var original_coefficient := ranged_definition.penetration_damage_coefficient
	ranged_definition.max_penetration_count = 17
	ranged_definition.penetration_damage_coefficient = 1.0
	var targets: Array[ZombieTarget] = []
	for target_index in range(18):
		var target := _spawn_target(
			fixture,
			Vector3(0.0, 0.0, -2.5 - float(target_index) * 0.75)
		)
		var collision := target.get_node(
			"Hitboxes/BodyHitbox/CollisionShape3D"
		) as CollisionShape3D
		var shape := collision.shape.duplicate() as CylinderShape3D
		shape.radius = 0.2
		collision.shape = shape
		target.force_update_transform()
		targets.append(target)

	weapon._fire(Vector3.FORWARD)
	ranged_definition.max_penetration_count = original_max_penetration_count
	ranged_definition.penetration_damage_coefficient = original_coefficient

	_append(failures, Assertions.expect_float_near(
		targets[16].health.current,
		25.0,
		0.0001,
		"Runtime penetration limit still allows sixteen extra zombies"
	))
	_append(failures, Assertions.expect_float_near(
		targets[17].health.current,
		50.0,
		0.0001,
		"Runtime penetration limit clamps extra zombies to sixteen"
	))
	fixture.free()

func _test_unobstructed_penetration_reaches_max_range(
	failures: Array[String]
) -> void:
	var fixture := _make_fixture()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	player.position = Vector3(0.0, 0.0, -20.0)
	fixture.add_child(player)
	player.force_update_transform()
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(0)
	var weapon := equipment.get_current_weapon() as RangedWeapon
	_disable_spread(weapon)
	var target := _spawn_target(fixture, Vector3(0.0, 0.0, -24.0))
	var ranged_definition := weapon.definition as RangedWeaponDefinition
	var ray_origin := weapon.get_ray_origin()
	var expected_end := ray_origin + Vector3.FORWARD * ranged_definition.attack_range
	var tracer_index := weapon.tracer_pool_cursor

	weapon._fire(Vector3.FORWARD)

	var tracer := weapon.tracer_pool[tracer_index] as ShotTracer
	_append(failures, Assertions.expect_float_near(
		target.health.current,
		15.0,
		0.0001,
		"Unobstructed penetration damages the zombie"
	))
	_append(failures, Assertions.expect_vector3_near(
		_tracer_end(tracer),
		expected_end,
		0.001,
		"Unobstructed penetration tracer reaches maximum range"
	))
	fixture.free()

func _make_fixture() -> Node3D:
	var fixture := Node3D.new()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(fixture)
	return fixture

func _spawn_target(parent: Node3D, position: Vector3) -> ZombieTarget:
	var target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	target.position = position
	target.set_physics_process(false)
	target.set_process(false)
	parent.add_child(target)
	target.force_update_transform()
	return target

func _disable_spread(weapon: RangedWeapon) -> void:
	weapon.spread_state.base_spread_degrees = 0.0
	weapon.spread_state.max_spread_degrees = 0.0
	weapon.spread_state.spread_increase_per_shot_degrees = 0.0
	weapon.spread_state.current_spread_degrees = 0.0

func _add_extra_hitbox(target: ZombieTarget) -> void:
	var area := Area3D.new()
	area.position = Vector3(0.0, 1.1, 1.4)
	area.collision_layer = 4
	area.collision_mask = 0
	area.monitoring = false
	area.set_script(ZombieHitbox)
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.3
	collision.shape = shape
	area.add_child(collision)
	target.get_node("Hitboxes").add_child(area)
	area.force_update_transform()

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

func _tracer_end(tracer: ShotTracer) -> Vector3:
	return tracer.to_global(Vector3(0.0, 0.0, -0.5))

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
