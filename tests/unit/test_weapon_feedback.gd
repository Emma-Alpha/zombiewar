extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const CAMERA_SCENE := preload("res://scenes/camera/FollowCamera.tscn")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const EquipmentController = preload("res://scripts/player/equipment_controller.gd")
const RangedWeapon = preload("res://scripts/combat/weapons/ranged_weapon.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	var weapon := equipment.get_current_weapon() as RangedWeapon
	var muzzle_flash := weapon.get_node_or_null("Muzzle/MuzzleFlash")
	var shot_audio := weapon.get_node_or_null("ShotAudio") as AudioStreamPlayer3D
	_append(failures, Assertions.expect_true(
		muzzle_flash != null and muzzle_flash.has_method("flash"),
		"Weapon has a reusable muzzle flash"
	))
	_append(failures, Assertions.expect_true(
		shot_audio != null and shot_audio.stream != null,
		"Weapon has a loaded 3D shot sound"
	))
	_append(failures, Assertions.expect_true(
		weapon.visual_anchor != null,
		"Weapon binds its muzzle to the animated rifle"
	))
	var expected_origin := Vector3(0.0, 1.12, -1.395)
	var functional_origin := player.get_node("FunctionalRayOrigin") as Marker3D

	weapon.set_attack_input(false, false, Vector3.RIGHT)
	weapon._process(0.0)
	var visual_root := player.get_node("VisualRoot") as Node3D
	var visual_muzzle_before := weapon.muzzle.global_position
	visual_root.position += Vector3(0.0, 0.0, 0.12)
	weapon._process(0.0)
	var visual_muzzle_after := weapon.muzzle.global_position
	_append(failures, Assertions.expect_vector3_near(
		visual_muzzle_after,
		visual_muzzle_before,
		0.0001,
		"Capsule muzzle origin is unchanged by VisualRoot recoil"
	))
	_append(failures, Assertions.expect_true(
		weapon.has_method("get_ray_origin"),
		"Weapon exposes a stable functional ray origin"
	))
	if weapon.has_method("get_ray_origin"):
		var functional_origin_before: Vector3 = weapon.call("get_ray_origin")
		_append(failures, Assertions.expect_vector3_near(
			functional_origin_before,
			expected_origin,
			0.001,
			"Functional ray origin uses the weapon capsule end"
		))
		visual_root.position += Vector3(0.0, 0.0, -0.12)
		weapon._process(0.0)
		var functional_origin_after: Vector3 = weapon.call("get_ray_origin")
		_append(failures, Assertions.expect_vector3_near(
			functional_origin_after,
			functional_origin_before,
			0.0001,
			"Capsule ray origin is unchanged by VisualRoot recoil"
		))

	var feedback_origins: Array[Vector3] = []
	weapon.attack_resolved.connect(func(
		origin: Vector3,
		_direction: Vector3,
		_result: HitResult,
		_visual_recoil_kick: float,
		_camera_impulse_strength: float
	) -> void:
		feedback_origins.append(origin)
)
	var tracer_index := weapon.tracer_pool_cursor
	weapon._fire(-player.global_basis.z)
	var tracer := weapon.tracer_pool[tracer_index] as ShotTracer
	_append(failures, Assertions.expect_vector3_near(
		weapon.muzzle.global_position,
		expected_origin,
		0.001,
		"Muzzle flash anchor uses the weapon capsule end"
	))
	_append(failures, Assertions.expect_vector3_near(
		weapon.get_ray_origin(),
		expected_origin,
		0.001,
		"Functional ray starts at the weapon capsule end"
	))
	_append(failures, Assertions.expect_vector3_near(
		_tracer_start(tracer),
		expected_origin,
		0.001,
		"Tracer starts at the weapon capsule end"
	))
	_append(failures, Assertions.expect_vector3_near(
		feedback_origins.back(),
		expected_origin,
		0.001,
		"Attack feedback origin uses the weapon capsule end"
	))

	var wall := _make_wall(
		Vector3(0.0, 1.1, -2.0),
		Vector3(2.0, 2.0, 0.2)
	)
	var target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	target.position = Vector3(0.0, 0.0, -4.0)
	target.set_physics_process(false)
	tree.root.add_child(wall)
	tree.root.add_child(target)
	var ranged_definition := weapon.definition as RangedWeaponDefinition
	var original_hit_mask: int = ranged_definition.hit_collision_mask
	ranged_definition.hit_collision_mask = original_hit_mask & ~1
	wall.force_update_transform()
	var ray_origin := weapon.get_ray_origin()
	var ray_result: Dictionary = weapon.call(
		"_intersect_shot",
		ray_origin,
		ray_origin + Vector3.FORWARD * ranged_definition.attack_range
	)
	_append(failures, Assertions.expect_true(
		ray_result.get("collider", null) == wall,
		"Layer-one wall is the first functional ray hit even when the resource mask omits it"
	))
	var health_before := target.health.current
	weapon.call("_fire", Vector3.FORWARD)
	_append(failures, Assertions.expect_float_near(
		target.health.current,
		health_before,
		0.0001,
		"Layer-one wall prevents damage to the target behind it"
	))
	wall.free()
	weapon.call("_fire", Vector3.FORWARD)
	_append(failures, Assertions.expect_true(
		target.health.current < health_before,
		"The same unobstructed shot still damages the target"
	))
	ranged_definition.hit_collision_mask = original_hit_mask
	target.free()

	var offset_target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	offset_target.position = Vector3(1.4, 0.0, -17.0)
	offset_target.set_physics_process(false)
	tree.root.add_child(offset_target)
	functional_origin.global_position = Vector3(0.0, 1.1, 0.0)
	weapon.call("_fire", Vector3.FORWARD)
	_append(failures, Assertions.expect_float_near(
		offset_target.health.current,
		50.0,
		0.0001,
		"Direct fire does not bend toward a nearby off-axis target"
	))
	offset_target.free()

	var follow_camera := CAMERA_SCENE.instantiate() as FollowCamera
	_append(failures, Assertions.expect_true(
		follow_camera.has_method("add_shot_impulse"),
		"Follow camera accepts bounded shot impulse"
	))
	if follow_camera.has_method("add_shot_impulse"):
		follow_camera.add_shot_impulse(Vector3.FORWARD, 1.0)
		var impulse: Vector3 = follow_camera.get("shot_impulse_offset")
		_append(failures, Assertions.expect_true(
			impulse.length() <= 0.1201,
			"Shot impulse is capped for sustained and two-player fire"
		))

	var material := tracer.material_override as ShaderMaterial
	var uniform_names: Array[StringName] = []
	if material != null and material.shader != null:
		for uniform: Dictionary in material.shader.get_shader_uniform_list():
			uniform_names.append(StringName(uniform.get("name", &"")))
	_append(failures, Assertions.expect_true(
		material != null and
			&"muzzle_alpha" in uniform_names and
			&"hit_alpha" in uniform_names and
			is_equal_approx(float(material.get_shader_parameter("muzzle_alpha")), 0.0) and
			is_equal_approx(float(material.get_shader_parameter("hit_alpha")), 1.0),
		"Tracer material exposes transparent muzzle and opaque hit endpoint contracts"
	))
	tracer.setup(Vector3.ZERO, Vector3(0.0, 0.0, -4.0))
	_append(failures, Assertions.expect_vector3_near(
		_tracer_start(tracer),
		Vector3.ZERO,
		0.0001,
		"Tracer geometry starts at its setup origin"
	))
	_append(failures, Assertions.expect_vector3_near(
		_tracer_end(tracer),
		Vector3(0.0, 0.0, -4.0),
		0.0001,
		"Tracer geometry ends at its setup hit position"
	))
	tracer.setup(Vector3.ZERO, Vector3.ZERO)
	_append(failures, Assertions.expect_true(
		not tracer.visible,
		"Zero-length tracer stays hidden"
	))
	tracer.setup(Vector3.ZERO, Vector3(0.0, 0.0, -4.0))
	var start_alpha_value: Variant = tracer.get_instance_shader_parameter("lifetime_alpha")
	var start_alpha := 0.0 if start_alpha_value == null else float(start_alpha_value)
	tracer._process(tracer.lifetime * 0.5)
	var middle_alpha_value: Variant = tracer.get_instance_shader_parameter("lifetime_alpha")
	var middle_alpha := 0.0 if middle_alpha_value == null else float(middle_alpha_value)
	tracer._process(tracer.lifetime * 0.5)
	_append(failures, Assertions.expect_true(
		is_equal_approx(start_alpha, 1.0) and
			middle_alpha < start_alpha and middle_alpha > 0.0 and
			not tracer.visible,
		"Tracer keeps its full line and fades its shared lifetime alpha to zero"
	))

	player.free()
	follow_camera.free()
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

func _tracer_start(tracer: ShotTracer) -> Vector3:
	return tracer.to_global(Vector3(0.0, 0.0, 0.5))

func _tracer_end(tracer: ShotTracer) -> Vector3:
	return tracer.to_global(Vector3(0.0, 0.0, -0.5))

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
