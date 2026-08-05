extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const TRACER_SCRIPT := preload("res://scripts/fx/shot_tracer.gd")
const EquipmentController = preload("res://scripts/player/equipment_controller.gd")
const RangedWeapon = preload("res://scripts/combat/weapons/ranged_weapon.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	var weapon := equipment.get_current_weapon() as RangedWeapon
	var tracers := _tracers_in(weapon)
	_append(failures, Assertions.expect_true(
		tracers.size() >= 8,
		"Weapon prewarms at least eight reusable tracers"
	))
	if not tracers.is_empty():
		var functional_origin := player.get_node("FunctionalRayOrigin") as Marker3D
		functional_origin.global_position += Vector3(0.4, 0.0, 0.0)
		var expected_origin := Vector3(0.0, 1.12, -1.395)
		weapon._fire(-player.global_basis.z)

		var fired_tracer := tracers[0] as ShotTracer
		var tracer_near_end := fired_tracer.to_global(Vector3(0.0, 0.0, 0.5))
		_append(failures, Assertions.expect_vector3_near(
			tracer_near_end,
			expected_origin,
			0.001,
			"Fired tracer starts at the hand-derived capsule muzzle endpoint"
		))
		_append(failures, Assertions.expect_true(
			fired_tracer.visible and fired_tracer.is_processing(),
			"Fired tracer becomes visible and active"
		))
		fired_tracer._process(fired_tracer.lifetime + 0.001)
		_append(failures, Assertions.expect_true(
			not fired_tracer.visible and not fired_tracer.is_processing(),
			"Fired tracer deactivates after its lifetime"
		))

	if tracers.size() >= 2:
		var first := tracers[0] as MeshInstance3D
		var second := tracers[1] as MeshInstance3D
		_append(failures, Assertions.expect_true(first.mesh != null, "Tracer has a prebuilt mesh"))
		_append(failures, Assertions.expect_true(
			first.mesh == second.mesh,
			"Pooled tracers share one mesh resource"
		))
		_append(failures, Assertions.expect_true(
			first.material_override != null,
			"Tracer has a prebuilt material"
		))
		_append(failures, Assertions.expect_true(
			first.material_override == second.material_override,
			"Pooled tracers share one material resource"
		))
		_append(failures, Assertions.expect_equal(
			first.physics_interpolation_mode,
			Node.PHYSICS_INTERPOLATION_MODE_OFF,
			"Teleporting pooled tracers disable physics interpolation"
		))

	_append(failures, Assertions.expect_true(
		weapon.has_method("_acquire_tracer"),
		"Weapon exposes its reusable tracer acquisition path"
	))
	if weapon.has_method("_acquire_tracer") and not tracers.is_empty():
		var initial_weapon_children := weapon.get_child_count()
		var acquired_ids: Dictionary = {}
		for acquisition_index in range(tracers.size() * 3):
			var acquired := weapon.call("_acquire_tracer") as ShotTracer
			acquired_ids[acquired.get_instance_id()] = true
		_append(failures, Assertions.expect_equal(
			weapon.get_child_count(),
			initial_weapon_children,
			"Repeated tracer acquisition does not grow the scene"
		))
		_append(failures, Assertions.expect_equal(
			acquired_ids.size(),
			tracers.size(),
			"Tracer acquisition cycles through the prewarmed pool"
		))

	tracers = _tracers_in(weapon)
	if tracers.size() >= 2:
		var shared_mesh: Mesh = (tracers[0] as MeshInstance3D).mesh
		var shared_material: Material = (tracers[0] as MeshInstance3D).material_override
		for tracer in tracers:
			_append(failures, Assertions.expect_true(
				(tracer as MeshInstance3D).mesh == shared_mesh,
				"Firing keeps the shared tracer mesh"
			))
			_append(failures, Assertions.expect_true(
				(tracer as MeshInstance3D).material_override == shared_material,
				"Firing keeps the shared tracer material"
			))

	player.free()
	return failures

func _tracers_in(weapon: Node) -> Array[Node]:
	var tracers: Array[Node] = []
	for child in weapon.get_children():
		if child.get_script() == TRACER_SCRIPT:
			tracers.append(child)
	return tracers

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
