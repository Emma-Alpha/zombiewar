extends SceneTree

const SnapScript = preload("res://addons/map_editor/core/map_grid_snap.gd")
const SyncScript = preload(
	"res://addons/map_editor/core/map_definition_synchronizer.gd"
)


func _init() -> void:
	var failures: Array[String] = []
	var definition := MapDefinition.new()
	definition.grid_origin = Vector2(-24.5, -19.5)
	definition.grid_cell_size = 1.0
	definition.grid_width = 49
	definition.grid_height = 39

	_expect(
		SnapScript.snap_position(Vector3(-1.24, 2.0, 6.17), definition)
			.is_equal_approx(Vector3(-1.2, 2.0, 6.2)),
		"snap must use 0.1m subgrid and preserve y",
		failures
	)

	var root_node := MapContentAuthoringRoot.new()
	var markers := Node3D.new()
	markers.name = "MapMarkers"
	root_node.add_child(markers)
	var players := Node3D.new()
	players.name = "PlayerSpawns"
	markers.add_child(players)
	var zombies := Node3D.new()
	zombies.name = "ZombieSpawns"
	markers.add_child(zombies)
	var fixed_items := Node3D.new()
	fixed_items.name = "FixedItemSpawns"
	markers.add_child(fixed_items)

	_add_player(players, &"player_02", 1, Vector3(1.24, 0.0, 6.17))
	_add_player(players, &"player_01", 0, Vector3(-1.24, 0.0, 6.17))
	_add_zombie(zombies, &"south", Vector3(19.04, 0.0, 14.04))
	_add_zombie(zombies, &"north", Vector3(-19.04, 0.0, -14.04))
	_add_fixed(fixed_items, &"oil", Vector3(4.46, 0.0, 6.04), 30)

	SyncScript.synchronize(root_node, definition)
	_expect(definition.player_spawn_positions == [
		Vector3(-1.2, 0.0, 6.2),
		Vector3(1.2, 0.0, 6.2),
	], "players must sort by slot then id", failures)
	_expect(
		definition.spawn_points.map(func(value): return value.spawn_id) == [
			&"north", &"south",
		], "zombies must sort by spawn id", failures
	)
	_expect(
		definition.fixed_item_spawns[0].position_xz == Vector2(4.5, 6.0),
		"fixed spawn snapped position",
		failures
	)
	var first_snapshot := _snapshot(definition)
	SyncScript.synchronize(root_node, definition)
	_expect(
		first_snapshot == _snapshot(definition),
		"repeated sync must be stable",
		failures
	)

	root_node.free()
	_finish(failures)


func _add_player(parent: Node3D, id: StringName, slot: int, position: Vector3) -> void:
	var marker := MapPlayerSpawnMarker.new()
	marker.marker_id = id
	marker.slot_index = slot
	marker.position = position
	parent.add_child(marker)


func _add_zombie(parent: Node3D, id: StringName, position: Vector3) -> void:
	var marker := MapZombieSpawnMarker.new()
	marker.spawn_id = id
	marker.position = position
	parent.add_child(marker)


func _add_fixed(parent: Node3D, id: StringName, position: Vector3, amount: int) -> void:
	var marker := MapFixedItemSpawnMarker.new()
	marker.spawn_id = id
	marker.position = position
	marker.amount = amount
	parent.add_child(marker)


func _snapshot(definition: MapDefinition) -> Array:
	return [
		definition.player_spawn_positions.duplicate(),
		definition.spawn_points.map(func(value): return [
			value.spawn_id,
			value.position_xz,
			value.spawn_radius,
			value.minimum_spacing,
		]),
		definition.fixed_item_spawns.map(func(value): return [
			value.spawn_id,
			value.position_xz,
			value.pickup,
			value.amount,
			value.respawn_delay_ticks,
		]),
	]


func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_definition_synchronizer: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
