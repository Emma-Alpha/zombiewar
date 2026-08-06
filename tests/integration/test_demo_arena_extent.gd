extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ARENA_SCENE := preload("res://scenes/gameplay/DemoArena.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var arena := ARENA_SCENE.instantiate()
	var ground_mesh_node := arena.get_node_or_null(
		"World/Ground/MeshInstance3D"
	) as MeshInstance3D
	var ground_shape_node := arena.get_node_or_null(
		"World/Ground/CollisionShape3D"
	) as CollisionShape3D
	var ground_mesh: BoxMesh
	var ground_shape: BoxShape3D
	if ground_mesh_node != null:
		ground_mesh = ground_mesh_node.mesh as BoxMesh
	if ground_shape_node != null:
		ground_shape = ground_shape_node.shape as BoxShape3D
	_append(failures, Assertions.expect_true(
		ground_mesh != null and ground_shape != null,
		"Expanded demo owns box ground mesh and collision"
	))
	if ground_mesh != null:
		_append(failures, Assertions.expect_vector3_near(
			ground_mesh.size,
			Vector3(48.0, 0.3, 38.0),
			0.001,
			"Demo visual ground expands to 48 by 38 meters"
		))
	if ground_shape != null:
		_append(failures, Assertions.expect_vector3_near(
			ground_shape.size,
			Vector3(48.0, 0.3, 38.0),
			0.001,
			"Demo collision ground expands to 48 by 38 meters"
		))

	var chunk := arena.get_node_or_null(
		"World/Navigation/DemoArenaChunk"
	) as NavigationChunk3D
	_append(failures, Assertions.expect_true(
		chunk != null,
		"Expanded demo keeps one navigation chunk"
	))
	if chunk != null:
		_append(failures, Assertions.expect_vector3_near(
			chunk.baking_bounds.position,
			Vector3(-24.25, -0.5, -19.25),
			0.001,
			"Navigation baking origin covers expanded borders"
		))
		_append(failures, Assertions.expect_vector3_near(
			chunk.baking_bounds.size,
			Vector3(48.5, 4.0, 38.5),
			0.001,
			"Navigation baking size covers expanded arena"
		))

	var boundary_positions := {
		"North": Vector3(0.0, 1.0, -19.0),
		"South": Vector3(0.0, 1.0, 19.0),
		"West": Vector3(-24.0, 1.0, 0.0),
		"East": Vector3(24.0, 1.0, 0.0),
	}
	for boundary_name in boundary_positions:
		var boundary := arena.get_node_or_null(
			"World/Boundaries/%s" % boundary_name
		) as StaticBody3D
		_append(failures, Assertions.expect_true(
			boundary != null,
			"Expanded demo keeps boundary %s" % boundary_name
		))
		if boundary != null:
			_append(failures, Assertions.expect_vector3_near(
				boundary.position,
				boundary_positions[boundary_name],
				0.001,
				"Expanded boundary moves to its planned edge: %s" % boundary_name
			))

	var spawn_positions := {
		"NorthWest": Vector3(-19.0, 0.0, -14.0),
		"NorthEast": Vector3(19.0, 0.0, -14.0),
		"SouthWest": Vector3(-19.0, 0.0, 14.0),
		"SouthEast": Vector3(19.0, 0.0, 14.0),
	}
	for spawn_name in spawn_positions:
		var marker := arena.get_node_or_null(
			"World/SpawnPoints/%s" % spawn_name
		) as Marker3D
		_append(failures, Assertions.expect_true(
			marker != null,
			"Expanded demo keeps spawn marker %s" % spawn_name
		))
		if marker != null:
			_append(failures, Assertions.expect_vector3_near(
				marker.position,
				spawn_positions[spawn_name],
				0.001,
				"Spawn marker moves with expanded edge: %s" % spawn_name
			))

	var player := arena.get_node_or_null("Player") as Node3D
	var camera := arena.get_node_or_null("FollowCamera/Camera3D") as Camera3D
	_append(failures, Assertions.expect_true(
		player != null and player.position == Vector3(0.0, 0.0, 6.0),
		"Expansion preserves the player spawn"
	))
	_append(failures, Assertions.expect_true(
		camera != null and camera.projection == Camera3D.PROJECTION_ORTHOGONAL and
		is_equal_approx(camera.size, 15.0),
		"Expansion preserves the orthographic camera framing"
	))
	arena.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
