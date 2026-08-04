extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const CAMERA_SCENE := preload("res://scenes/camera/FollowCamera.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var weapon := player.get_node("Weapon") as PlayerWeapon
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
		weapon.has_method("bind_visual_anchor"),
		"Weapon can bind its muzzle to the animated rifle"
	))
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)
	var aim_indicator := weapon.get_node_or_null("AimIndicator") as Node3D
	_append(failures, Assertions.expect_vector3_near(
		weapon.muzzle.position,
		Vector3(0.84, 0.31, 0.61),
		0.0001,
		"Visual muzzle uses the Rifle local barrel-tip offset"
	))
	_append(failures, Assertions.expect_true(
		aim_indicator != null and aim_indicator.visible,
		"Weapon has a visible persistent aim guide"
	))

	var aim_segments: Array[MeshInstance3D] = []
	if aim_indicator != null:
		for child in aim_indicator.get_children():
			if child is MeshInstance3D:
				aim_segments.append(child as MeshInstance3D)
	_append(failures, Assertions.expect_equal(
		aim_segments.size(),
		5,
		"Aim guide uses five separated segments"
	))
	if not aim_segments.is_empty():
		var segment_mesh := aim_segments[0].mesh as BoxMesh
		var segment_material: StandardMaterial3D
		if segment_mesh != null:
			segment_material = segment_mesh.material as StandardMaterial3D
		_append(failures, Assertions.expect_true(
			segment_material != null and
			segment_material.albedo_color.b > segment_material.albedo_color.r and
			segment_material.albedo_color.a < 0.6,
			"Aim guide is translucent and cyan rather than tracer orange"
		))

	weapon.set_combat_input(false, false, Vector3.RIGHT)
	weapon._process(0.0)
	if aim_indicator != null:
		_append(failures, Assertions.expect_vector3_near(
			aim_indicator.global_position,
			weapon.muzzle.global_position,
			0.0001,
			"Aim guide starts at the live visual muzzle"
		))
		_append(failures, Assertions.expect_vector3_near(
			-aim_indicator.global_basis.z,
			Vector3.RIGHT,
			0.0001,
			"Aim guide points along the actual aim direction"
		))
	var visual_root := player.get_node("VisualRoot") as Node3D
	var visual_muzzle_before := weapon.muzzle.global_position
	visual_root.position += Vector3(0.0, 0.0, 0.12)
	weapon._process(0.0)
	var visual_muzzle_after := weapon.muzzle.global_position
	_append(failures, Assertions.expect_true(
		visual_muzzle_after.distance_to(visual_muzzle_before) > 0.11,
		"Visual muzzle follows the recoil-driven rifle"
	))
	if aim_indicator != null:
		_append(failures, Assertions.expect_vector3_near(
			aim_indicator.global_position,
			weapon.muzzle.global_position,
			0.0001,
			"Aim guide follows the recoil-driven rifle muzzle"
		))
	_append(failures, Assertions.expect_true(
		weapon.has_method("get_ray_origin"),
		"Weapon exposes a stable functional ray origin"
	))
	if weapon.has_method("get_ray_origin"):
		var functional_origin_before: Vector3 = weapon.call("get_ray_origin")
		visual_root.position += Vector3(0.0, 0.0, -0.12)
		weapon._process(0.0)
		var functional_origin_after: Vector3 = weapon.call("get_ray_origin")
		_append(failures, Assertions.expect_vector3_near(
			functional_origin_after,
			functional_origin_before,
			0.0001,
			"Functional ray origin is unchanged by VisualRoot recoil"
		))

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

	player.free()
	follow_camera.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
