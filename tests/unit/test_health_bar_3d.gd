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

	var health_bar := HEALTH_BAR_SCENE.instantiate() as HealthBar3D
	var scene_tree := Engine.get_main_loop() as SceneTree
	scene_tree.root.add_child(health_bar)
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
			_append(failures, Assertions.expect_true(shader_code.contains("MODELVIEW_MATRIX"), "%s shader billboards" % bar_part_name))
			var preserves_model_scale := (
				shader_code.contains("length(MODEL_MATRIX[0].xyz)")
				and shader_code.contains("length(MODEL_MATRIX[1].xyz)")
				and shader_code.contains("length(MODEL_MATRIX[2].xyz)")
				and shader_code.contains("INV_VIEW_MATRIX[0] * model_scale.x")
				and shader_code.contains("INV_VIEW_MATRIX[1] * model_scale.y")
				and shader_code.contains("INV_VIEW_MATRIX[2] * model_scale.z")
			)
			_append(failures, Assertions.expect_true(preserves_model_scale, "%s shader preserves model-axis scale while billboarding" % bar_part_name))

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
	_append(failures, Assertions.expect_true(
		fill_material.render_priority > background_material.render_priority,
		"Fill renders after Background regardless of player yaw"
	))
	health_bar.set_health(25.0, 100.0, false)
	_append(failures, Assertions.expect_float_near(health_bar.get_target_ratio(), 0.25, 0.0001, "Immediate health update sets target ratio"))
	_append(failures, Assertions.expect_float_near(fill.scale.x, 0.25, 0.0001, "Immediate health update scales Fill"))
	_append(failures, Assertions.expect_float_near(fill.position.x, -0.4125, 0.0001, "Immediate health update anchors Fill position"))
	_append(failures, Assertions.expect_float_near(fill.position.x - 0.55 * fill.scale.x, -0.55, 0.0001, "Fill left edge remains fixed"))
	_append(failures, Assertions.expect_equal(fill_material.get_shader_parameter(&"tint_color"), Color("e44b46"), "Immediate health update tints Fill"))

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
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
