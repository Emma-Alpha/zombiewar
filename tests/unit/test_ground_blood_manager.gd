extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const MANAGER_SCRIPT := preload("res://scripts/fx/ground_blood_manager.gd")
const SPLAT_TEXTURE := preload("res://assets/fx/blood/kenney_splat29.png")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_lit_mesh_contract(failures)
	_test_two_layers_and_limited_merging(failures)
	_test_saturated_cell_merges_into_size_matched_layer(failures)
	_test_fifo_reuse_updates_spatial_index(failures)
	_test_hit_splat_keeps_requested_horizontal_position(failures)
	_test_trail_size_endpoints_ignore_intensity(failures)
	_test_death_pool_size_stays_bounded_at_high_intensity(failures)
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
		_append(failures, Assertions.expect_true(
			material != null and
			is_equal_approx(material.alpha_scissor_threshold, 0.25) and
			material.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL and
			is_zero_approx(material.metallic),
			"Blood material keeps the precise lit alpha-scissor non-metal contract"
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

func _test_saturated_cell_merges_into_size_matched_layer(failures: Array[String]) -> void:
	var manager := MANAGER_SCRIPT.new() as Node3D
	var small_trail := manager.call(
		"place_splat", Vector3(0.10, 0.0, 0.10), Vector3.UP, Vector2(0.30, 0.65),
		0.0, Color.WHITE, SPLAT_TEXTURE, 0.55
	) as GroundBloodSplat
	var large_main_splat := manager.call(
		"place_splat", Vector3(0.12, 0.0, 0.12), Vector3.UP, Vector2(1.10, 1.10),
		0.0, Color.WHITE, SPLAT_TEXTURE, 0.38
	) as GroundBloodSplat
	var merged := manager.call(
		"place_splat", Vector3(0.14, 0.0, 0.14), Vector3.UP, Vector2(1.05, 1.15),
		0.0, Color.WHITE, SPLAT_TEXTURE, 0.38
	) as GroundBloodSplat
	_append(failures, Assertions.expect_equal(
		manager.get_child_count(),
		2,
		"A saturated cell still keeps exactly two blood layers"
	))
	_append(failures, Assertions.expect_equal(
		merged.get_instance_id(),
		large_main_splat.get_instance_id(),
		"A large request merges into the large matching layer instead of the small trail"
	))
	_append(failures, Assertions.expect_true(
		small_trail.get_instance_id() != merged.get_instance_id(),
		"Size-matched merging leaves the unrelated small trail layer intact"
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
		seed(20260805)
		var right_facing_splat := manager.call(
			"spawn_hit_splat",
			Vector3(1.25, 1.2, -0.4),
			Vector3.RIGHT,
			1.0
		) as GroundBloodSplat
		_append(failures, Assertions.expect_true(
			right_facing_splat != null,
			"A horizontal hit direction creates a directed main splat"
		))
		if right_facing_splat != null:
			var orientation_error := absf(wrapf(
				float(right_facing_splat.get("current_rotation")) - PI * 0.5,
				-PI,
				PI
			))
			_append(failures, Assertions.expect_true(
				orientation_error <= 0.13,
				"Main splat rotation follows shot direction with only a small random offset"
			))
	host.free()

func _test_trail_size_endpoints_ignore_intensity(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var host := _create_blood_surface_host()
	var manager := MANAGER_SCRIPT.new() as Node3D
	host.add_child(manager)
	tree.root.add_child(host)
	var cases: Array[Dictionary] = [
		{
			"position": Vector3(-1.5, 1.2, 0.0),
			"intensity": 0.75,
			"progress": 0.0,
			"expected_size": Vector2(0.45, 0.8),
		},
		{
			"position": Vector3(-0.5, 1.2, 0.0),
			"intensity": 1.35,
			"progress": 0.0,
			"expected_size": Vector2(0.45, 0.8),
		},
		{
			"position": Vector3(0.5, 1.2, 0.0),
			"intensity": 0.75,
			"progress": 1.0,
			"expected_size": Vector2(0.28, 0.5),
		},
		{
			"position": Vector3(1.5, 1.2, 0.0),
			"intensity": 1.35,
			"progress": 1.0,
			"expected_size": Vector2(0.28, 0.5),
		},
	]
	for trail_case in cases:
		var splat := manager.call(
			"spawn_trail_splat",
			trail_case["position"],
			Vector3.RIGHT,
			trail_case["intensity"],
			trail_case["progress"]
		) as GroundBloodSplat
		_append(failures, Assertions.expect_true(
			splat != null,
			"Trail endpoint creates a persistent splat"
		))
		if splat == null:
			continue
		var current_size := splat.get("current_size") as Vector2
		var expected_size := trail_case["expected_size"] as Vector2
		_append(failures, Assertions.expect_float_near(
			current_size.x,
			expected_size.x,
			0.0001,
			"Trail width follows progress endpoints regardless of intensity"
		))
		_append(failures, Assertions.expect_float_near(
			current_size.y,
			expected_size.y,
			0.0001,
			"Trail length follows progress endpoints regardless of intensity"
		))
	host.free()

func _test_death_pool_size_stays_bounded_at_high_intensity(
	failures: Array[String]
) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var host := _create_blood_surface_host()
	var manager := MANAGER_SCRIPT.new() as Node3D
	host.add_child(manager)
	tree.root.add_child(host)
	var splat := manager.call(
		"spawn_death_pool",
		Vector3(0.0, 1.2, 0.0),
		1.35
	) as GroundBloodSplat
	_append(failures, Assertions.expect_true(
		splat != null,
		"High-intensity death creates a persistent pool"
	))
	if splat != null:
		var current_size := splat.get("current_size") as Vector2
		_append(failures, Assertions.expect_true(
			current_size.x >= 1.15 and current_size.x <= 1.4 and
			current_size.y >= 1.15 and current_size.y <= 1.4,
			"High-intensity death pool keeps both axes within 1.15 to 1.4 meters"
		))
	host.free()

func _create_blood_surface_host() -> Node3D:
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
	return host

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
