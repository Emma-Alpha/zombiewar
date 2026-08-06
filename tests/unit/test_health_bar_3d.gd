extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const HealthBar3D = preload("res://scripts/ui/health_bar_3d.gd")
const HEALTH_BAR_SCENE = preload("res://scenes/ui/HealthBar3D.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	_append(failures, Assertions.expect_float_near(
		HealthBar3D.health_ratio(90.0, 100.0), 0.9, 0.0001,
		"Health bar normalizes health"
	))
	_append(failures, Assertions.expect_float_near(
		HealthBar3D.health_ratio(-5.0, 100.0), 0.0, 0.0001,
		"Health bar clamps negative health"
	))
	_append(failures, Assertions.expect_float_near(
		HealthBar3D.health_ratio(200.0, 100.0), 1.0, 0.0001,
		"Health bar clamps health above maximum"
	))
	_append(failures, Assertions.expect_float_near(
		HealthBar3D.health_ratio(1.0, 0.0), 0.0, 0.0001,
		"Health bar handles invalid maximum"
	))
	_append(failures, Assertions.expect_equal(
		HealthBar3D.color_for_ratio(0.6001), HealthBar3D.HIGH_HEALTH_COLOR,
		"Health above 60 percent is green"
	))
	_append(failures, Assertions.expect_equal(
		HealthBar3D.color_for_ratio(0.60), HealthBar3D.MEDIUM_HEALTH_COLOR,
		"Health at 60 percent is yellow"
	))
	_append(failures, Assertions.expect_equal(
		HealthBar3D.color_for_ratio(0.30), HealthBar3D.MEDIUM_HEALTH_COLOR,
		"Health at 30 percent is yellow"
	))
	_append(failures, Assertions.expect_equal(
		HealthBar3D.color_for_ratio(0.2999), HealthBar3D.LOW_HEALTH_COLOR,
		"Health below 30 percent is red"
	))

	var scene_tree := Engine.get_main_loop() as SceneTree
	var follow_target := Node3D.new()
	var camera := Camera3D.new()
	scene_tree.root.add_child(follow_target)
	scene_tree.root.add_child(camera)
	follow_target.global_position = Vector3(3.0, 1.0, -2.0)
	camera.global_position = Vector3(0.0, 4.0, 8.0)
	camera.rotation_degrees = Vector3(-15.0, 25.0, 0.0)
	camera.make_current()

	var health_bar := HEALTH_BAR_SCENE.instantiate() as HealthBar3D
	follow_target.add_child(health_bar)
	var can_sync_to_camera := health_bar.has_method(&"_sync_to_camera")
	_append(failures, Assertions.expect_true(can_sync_to_camera, "Health bar exposes camera-plane synchronization"))
	if can_sync_to_camera:
		health_bar.anchor_offset = Vector3(0.0, 2.35, 0.0)
		health_bar._sync_to_camera()
		_append(failures, Assertions.expect_vector3_near(
			health_bar.global_position,
			Vector3(3.0, 3.35, -2.0),
			0.0001,
			"Health bar synchronizes to its follow target plus anchor offset"
		))
		_append(failures, Assertions.expect_true(
			health_bar.global_basis.x.dot(camera.global_basis.x) > 0.999,
			"Health bar local X axis aligns with the active camera"
		))
		_append(failures, Assertions.expect_true(
			health_bar.global_basis.y.dot(camera.global_basis.y) > 0.999,
			"Health bar local Y axis aligns with the active camera"
		))
		_append(failures, Assertions.expect_true(
			health_bar.global_basis.z.dot(camera.global_basis.z) > 0.999,
			"Health bar local Z axis aligns with the active camera"
		))
	_append(failures, Assertions.expect_true(health_bar.get_node("Background") is MeshInstance3D, "Background is a MeshInstance3D"))
	_append(failures, Assertions.expect_true(health_bar.get_node("Fill") is MeshInstance3D, "Fill is a MeshInstance3D"))
	_append(failures, Assertions.expect_true(health_bar.find_child("Label", true, false) == null, "Health bar has no Label"))

	for bar_part_name in [&"Background", &"Fill"]:
		var bar_part := health_bar.get_node(NodePath(bar_part_name)) as MeshInstance3D
		var material := bar_part.material_override as ShaderMaterial
		_append(failures, Assertions.expect_true(material != null, "%s uses a ShaderMaterial" % bar_part_name))
		if material != null and material.shader != null:
			var shader_code := material.shader.code
			_append(failures, Assertions.expect_true(shader_code.contains("unshaded"), "%s shader is unshaded" % bar_part_name))
			_append(failures, Assertions.expect_true(shader_code.contains("depth_test_disabled"), "%s shader disables depth testing" % bar_part_name))
			_append(failures, Assertions.expect_true(not shader_code.contains("MODELVIEW_MATRIX"), "%s shader relies on the root camera plane instead of billboarding" % bar_part_name))

	var fill := health_bar.get_node("Fill") as MeshInstance3D
	var background := health_bar.get_node("Background") as MeshInstance3D
	var fill_material := fill.material_override as ShaderMaterial
	var background_material := background.material_override as ShaderMaterial
	_append(failures, Assertions.expect_float_near(
		fill.position.z,
		0.0,
		0.0001,
		"Fill shares the background origin so player yaw cannot change its transparent depth"
	))
	_append(failures, Assertions.expect_float_near(
		background.position.z,
		0.0,
		0.0001,
		"Background remains in the root camera plane"
	))
	_append(failures, Assertions.expect_true(
		fill_material.render_priority > background_material.render_priority,
		"Fill renders after Background regardless of player yaw"
	))
	var background_tint: Variant = background_material.get_shader_parameter(&"tint_color")
	_append(failures, Assertions.expect_true(background_tint is Color, "Background exposes its tint color at runtime"))
	if background_tint is Color:
		_append(failures, Assertions.expect_float_near(
			background_tint.a,
			0.35,
			0.0001,
			"Background is a subdued empty-health track"
		))
	health_bar.set_health(25.0, 100.0, false)
	_append(failures, Assertions.expect_float_near(health_bar.get_target_ratio(), 0.25, 0.0001, "Immediate health update sets target ratio"))
	_append(failures, Assertions.expect_float_near(fill.scale.x, 0.25, 0.0001, "Immediate health update scales Fill"))
	_append(failures, Assertions.expect_float_near(fill.position.x, -0.4125, 0.0001, "Immediate health update anchors Fill position"))
	_append(failures, Assertions.expect_float_near(fill.position.x - 0.55 * fill.scale.x, -0.55, 0.0001, "Fill left edge remains fixed"))
	_append(failures, Assertions.expect_equal(fill_material.get_shader_parameter(&"tint_color"), Color("e44b46"), "Immediate health update tints Fill"))
	if can_sync_to_camera:
		var fill_left_edge := health_bar.to_global(fill.position - Vector3.RIGHT * 0.55 * fill.scale.x)
		follow_target.rotation.y = PI
		health_bar._sync_to_camera()
		var rotated_fill_left_edge := health_bar.to_global(fill.position - Vector3.RIGHT * 0.55 * fill.scale.x)
		_append(failures, Assertions.expect_vector3_near(
			rotated_fill_left_edge,
			fill_left_edge,
			0.0001,
			"Fill left edge stays fixed when the follow target turns 180 degrees"
		))

	health_bar.set_health(100.0, 100.0, true)
	var replaced_tween := health_bar.fill_tween
	health_bar.set_health(50.0, 100.0, true)
	_append(failures, Assertions.expect_true(not is_instance_valid(replaced_tween) or not replaced_tween.is_valid(), "Animated health update replaces active tween"))
	_append(failures, Assertions.expect_true(health_bar.fill_tween != replaced_tween and health_bar.fill_tween.is_valid(), "Replacement tween remains active"))

	health_bar.set_health(0.0, 100.0, false)
	_append(failures, Assertions.expect_float_near(health_bar.get_target_ratio(), 0.0, 0.0001, "Empty health sets target ratio to zero"))
	_append(failures, Assertions.expect_float_near(fill.scale.x, 0.0, 0.0001, "Empty health collapses Fill"))
	_append(failures, Assertions.expect_true(not fill.visible, "Empty health hides Fill"))

	health_bar.free()
	camera.free()
	follow_target.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
