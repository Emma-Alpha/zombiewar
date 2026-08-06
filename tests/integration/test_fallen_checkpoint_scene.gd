extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ARENA_SCENE := preload("res://scenes/gameplay/DemoArena.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var arena := ARENA_SCENE.instantiate()
	for path in [
		"World/Props/Checkpoint",
		"World/Props/Incident",
		"World/Props/HazardZone",
		"World/Props/SupplyPoint",
		"World/Props/RoadDetails",
	]:
		_append(failures, Assertions.expect_true(
			arena.get_node_or_null(path) is Node3D,
			"Fallen checkpoint exposes semantic scene group: %s" % path
		))

	var traffic_barriers := arena.get_node_or_null(
		"World/Props/Checkpoint/TrafficBarriers"
	) as Node3D
	var checkpoint_plastics := arena.get_node_or_null(
		"World/Props/Checkpoint/PlasticBarriers"
	) as Node3D
	var checkpoint_cones := arena.get_node_or_null(
		"World/Props/Checkpoint/TrafficCones"
	) as Node3D
	var incident_cones := arena.get_node_or_null(
		"World/Props/Incident/TrafficCones"
	) as Node3D
	var south_cones := arena.get_node_or_null(
		"World/Props/RoadDetails/SouthCones"
	) as Node3D
	var supply_perimeter := arena.get_node_or_null(
		"World/Props/SupplyPoint/PerimeterProps"
	) as Node3D
	var chests := arena.get_node_or_null(
		"World/Props/SupplyPoint/Chests"
	) as Node3D
	_append(failures, Assertions.expect_equal(
		_child_count(traffic_barriers), 6,
		"Checkpoint uses six traffic barriers"
	))
	_append(failures, Assertions.expect_equal(
		_child_count(checkpoint_plastics) + _child_count(supply_perimeter), 8,
		"Checkpoint and supply point use eight plastic barriers"
	))
	_append(failures, Assertions.expect_equal(
		_child_count(checkpoint_cones) + _child_count(incident_cones) +
		_child_count(south_cones),
		12,
		"Checkpoint story uses twelve collision-free traffic cones"
	))
	_append(failures, Assertions.expect_equal(
		_child_count(chests), 4,
		"Supply point uses four non-interactive chests"
	))

	for root in [traffic_barriers, checkpoint_plastics, supply_perimeter, chests]:
		if root == null:
			continue
		for child in root.get_children():
			_append(failures, Assertions.expect_true(
				child is StaticBody3D and
				child.is_in_group(&"navigation_source") and
				child.is_in_group(&"place_item_obstacle"),
				"Every substantial checkpoint prop blocks navigation and placement"
			))
	for root in [checkpoint_cones, incident_cones, south_cones]:
		if root == null:
			continue
		for child in root.get_children():
			_append(failures, Assertions.expect_true(
				not child.is_in_group(&"navigation_source") and
				not child.is_in_group(&"place_item_obstacle"),
				"Traffic cones remain visual-only story props"
			))

	if traffic_barriers != null and traffic_barriers.get_child_count() == 6:
		var barrier_shape_node := traffic_barriers.get_child(0).get_node_or_null(
			"CollisionShape3D"
		) as CollisionShape3D
		var barrier_shape: BoxShape3D
		if barrier_shape_node != null:
			barrier_shape = barrier_shape_node.shape as BoxShape3D
		if barrier_shape != null:
			var west_inner := traffic_barriers.get_node("WestInner") as Node3D
			var center_left := traffic_barriers.get_node("CenterLeft") as Node3D
			var center_right := traffic_barriers.get_node("CenterRight") as Node3D
			var east_inner := traffic_barriers.get_node("EastInner") as Node3D
			var west_gap := absf(center_left.position.x - west_inner.position.x) - barrier_shape.size.x
			var east_gap := absf(east_inner.position.x - center_right.position.x) - barrier_shape.size.x
			_append(failures, Assertions.expect_true(
				west_gap >= 2.4 and east_gap >= 2.4,
				"North checkpoint preserves two 2.4-meter entrance gaps"
			))

	var story_blood := arena.get_node_or_null(
		"World/Props/Incident/StoryBlood"
	) as Node3D
	var warning_label := arena.get_node_or_null(
		"World/Props/Checkpoint/WarningSign/Label3D"
	) as Label3D
	var warning_light := arena.get_node_or_null(
		"World/Props/Checkpoint/WarningSign/WarningLight"
	) as OmniLight3D
	_append(failures, Assertions.expect_equal(
		_child_count(story_blood), 6,
		"Incident path uses six fixed blood marks"
	))
	_append(failures, Assertions.expect_true(
		warning_label != null and String(warning_label.text).contains("检疫封锁区"),
		"Checkpoint sign names the quarantine area"
	))
	_append(failures, Assertions.expect_true(
		warning_light != null and not warning_light.shadow_enabled and
		warning_light.omni_range <= 6.0,
		"Checkpoint warning light is local and shadow-free"
	))
	_append(failures, Assertions.expect_true(
		arena.get_node_or_null("World/Props/RoadDetails/RoadSurface") is MeshInstance3D and
		arena.get_node_or_null("World/Props/RoadDetails/LaneMarkings") is Node3D and
		arena.get_node_or_null("World/Props/RoadDetails/HazardMarkings") is Node3D,
		"Checkpoint owns road, lane, and hazard markings"
	))

	var player := arena.get_node_or_null("Player") as Node3D
	for path in [
		"World/Props/Incident/PickupCollision",
		"World/Props/HazardZone/ContainerACollision",
		"World/Props/Checkpoint/ContainerBCollision",
	]:
		var obstacle := arena.get_node_or_null(path) as Node3D
		_append(failures, Assertions.expect_true(
			player != null and obstacle != null and
			_planar_distance(player.position, obstacle.position) >= 8.0,
			"Large checkpoint obstacle stays outside the player spawn buffer: %s" % path
		))
	arena.free()
	return failures

func _child_count(node: Node) -> int:
	return 0 if node == null else node.get_child_count()

func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
