extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const MANAGER_SCRIPT := preload("res://scripts/fx/ground_blood_manager.gd")
const SPLAT_TEXTURE := preload("res://assets/fx/blood/kenney_splat29.png")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_lit_mesh_contract(failures)
	_test_two_layers_and_limited_merging(failures)
	_test_fifo_reuse_updates_spatial_index(failures)
	_test_hit_splat_keeps_requested_horizontal_position(failures)
	return failures

func _test_lit_mesh_contract(failures: Array[String]) -> void:
	var manager := MANAGER_SCRIPT.new() as Node3D
	var first := manager.call(
		"place_splat",
		Vector3.ZERO,
		Vector3.UP,
		Vector2(0.9, 1.1),
		0.0,
		Color(0.42, 0.008, 0.015, 0.92),
		SPLAT_TEXTURE,
		0.38
	) as GroundBloodSplat
	var first_node := first as Node3D

	_append(failures, Assertions.expect_true(
		first_node is MeshInstance3D,
		"Persistent blood uses a lit mesh instance"
	))
	if first != null:
		var material := first.material_override as StandardMaterial3D
		_append(failures, Assertions.expect_true(
			material != null and material.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED,
			"Persistent blood keeps standard 3D lighting enabled"
		))
		_append(failures, Assertions.expect_true(
			material != null and
			material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR and
			material.cull_mode == BaseMaterial3D.CULL_DISABLED,
			"Blood uses alpha-scissored double-sided depth handling"
		))
		_append(failures, Assertions.expect_equal(
			first.cast_shadow,
			GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"Blood receives scene shadows without casting a floating plane shadow"
		))
		_append(failures, Assertions.expect_vector3_near(
			first.basis.z.normalized(),
			Vector3.UP,
			0.0001,
			"Blood mesh normal aligns to the hit surface"
		))
	manager.free()

func _test_two_layers_and_limited_merging(failures: Array[String]) -> void:
	var manager := MANAGER_SCRIPT.new() as Node3D
	var first := _place_test_splat(manager, Vector3(0.10, 0.0, 0.10))
	var second := _place_test_splat(manager, Vector3(0.12, 0.0, 0.11))
	_append(failures, Assertions.expect_equal(
		manager.get_child_count(),
		2,
		"A spatial cell keeps two visible blood layers"
	))

	var merged := _place_test_splat(manager, Vector3(0.14, 0.0, 0.13))
	var layer_ids := [first.get_instance_id(), second.get_instance_id()]
	_append(failures, Assertions.expect_equal(
		manager.get_child_count(),
		2,
		"A third request in one cell merges instead of allocating"
	))
	_append(failures, Assertions.expect_true(
		merged != null and layer_ids.has(merged.get_instance_id()),
		"A saturated cell returns one of its existing layers"
	))

	for request_index in range(10):
		_place_test_splat(
			manager,
			Vector3(0.11 + float(request_index) * 0.001, 0.0, 0.12)
		)
	_append(failures, Assertions.expect_equal(
		manager.get_child_count(),
		2,
		"Repeated requests never exceed the per-cell layer cap"
	))
	for splat in [first, second]:
		var base_size := splat.get("base_size") as Vector2
		var current_size := splat.get("current_size") as Vector2
		_append(failures, Assertions.expect_true(
			current_size.x <= base_size.x * 1.15 + 0.0001 and
			current_size.y <= base_size.y * 1.15 + 0.0001,
			"Merged blood growth stays within fifteen percent of its base size"
		))
	manager.free()

func _test_fifo_reuse_updates_spatial_index(failures: Array[String]) -> void:
	var manager := MANAGER_SCRIPT.new() as Node3D
	manager.set("max_splats", 3)
	var first := _place_test_splat(manager, Vector3(0.0, 0.0, 0.0))
	var second := _place_test_splat(manager, Vector3(1.0, 0.0, 0.0))
	var third := _place_test_splat(manager, Vector3(2.0, 0.0, 0.0))
	var reused := _place_test_splat(manager, Vector3(9.0, 0.0, 0.0))

	_append(failures, Assertions.expect_equal(
		manager.get_child_count(),
		3,
		"Ground blood never grows beyond the configured cap"
	))
	_append(failures, Assertions.expect_equal(
		reused.get_instance_id(),
		first.get_instance_id(),
		"The fourth distinct-cell splat reuses the oldest instance"
	))
	_append(failures, Assertions.expect_true(
		second.get_instance_id() != reused.get_instance_id() and
		third.get_instance_id() != reused.get_instance_id(),
		"Newer splats remain untouched during FIFO reuse"
	))
	var cell_splats := manager.get("cell_splats") as Dictionary
	var splat_cells := manager.get("splat_cells") as Dictionary
	var old_cell_layers := cell_splats.get(Vector2i.ZERO, []) as Array
	_append(failures, Assertions.expect_true(
		not old_cell_layers.has(reused) and
		splat_cells.get(reused.get_instance_id()) == Vector2i(20, 0),
		"FIFO reuse removes the instance from its old spatial cell"
	))
	_append(failures, Assertions.expect_true(
		not reused.is_processing(),
		"Persistent ground blood does not run a lifetime process"
	))
	manager.free()

func _test_hit_splat_keeps_requested_horizontal_position(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var surface := StaticBody3D.new()
	surface.add_to_group(&"blood_surface")
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(8.0, 0.1, 8.0)
	collision.shape = shape
	surface.position.y = -0.05
	surface.add_child(collision)
	host.add_child(surface)
	var manager := MANAGER_SCRIPT.new() as Node3D
	host.add_child(manager)
	tree.root.add_child(host)

	var splat := manager.call(
		"spawn_hit_splat",
		Vector3(0.25, 1.2, -0.4),
		Vector3.RIGHT,
		1.0
	) as GroundBloodSplat
	_append(failures, Assertions.expect_true(
		splat != null,
		"A hit above a blood surface creates a persistent splat"
	))
	if splat != null:
		_append(failures, Assertions.expect_float_near(
			splat.global_position.x,
			0.25,
			0.0001,
			"Hit splat keeps the requested world X coordinate"
		))
		_append(failures, Assertions.expect_float_near(
			splat.global_position.z,
			-0.4,
			0.0001,
			"Hit splat keeps the requested world Z coordinate"
		))
	host.free()

func _place_test_splat(manager: Node3D, position: Vector3) -> GroundBloodSplat:
	return manager.call(
		"place_splat",
		position,
		Vector3.UP,
		Vector2(0.9, 1.1),
		0.0,
		Color(0.42, 0.008, 0.015, 0.92),
		SPLAT_TEXTURE,
		0.38
	) as GroundBloodSplat

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
