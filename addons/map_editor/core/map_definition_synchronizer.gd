extends RefCounted
class_name MapDefinitionSynchronizer

const MAP_GRID_SNAP_SCRIPT = preload("res://addons/map_editor/core/map_grid_snap.gd")


static func synchronize(
	content_root: Node3D,
	definition: MapDefinition
) -> void:
	var players: Array[MapPlayerSpawnMarker] = []
	var zombies: Array[MapZombieSpawnMarker] = []
	var fixed_items: Array[MapFixedItemSpawnMarker] = []
	for node in content_root.find_children("*", "Node3D", true, false):
		if node is MapPlayerSpawnMarker:
			players.append(node)
		elif node is MapZombieSpawnMarker:
			zombies.append(node)
		elif node is MapFixedItemSpawnMarker:
			fixed_items.append(node)

	players.sort_custom(func(a, b):
		return a.slot_index < b.slot_index \
			if a.slot_index != b.slot_index \
			else String(a.marker_id) < String(b.marker_id)
	)
	zombies.sort_custom(func(a, b): return String(a.spawn_id) < String(b.spawn_id))
	fixed_items.sort_custom(func(a, b): return String(a.spawn_id) < String(b.spawn_id))

	definition.player_spawn_positions.clear()
	for marker in players:
		marker.position = MAP_GRID_SNAP_SCRIPT.snap_position(marker.position, definition)
		definition.player_spawn_positions.append(marker.position)

	definition.spawn_points.clear()
	for marker in zombies:
		marker.position = MAP_GRID_SNAP_SCRIPT.snap_position(marker.position, definition)
		var spawn := MapSpawnPointDefinition.new()
		spawn.spawn_id = marker.spawn_id
		spawn.position_xz = Vector2(marker.position.x, marker.position.z)
		spawn.spawn_radius = marker.spawn_radius
		spawn.minimum_spacing = marker.minimum_spacing
		definition.spawn_points.append(spawn)

	definition.fixed_item_spawns.clear()
	for marker in fixed_items:
		marker.position = MAP_GRID_SNAP_SCRIPT.snap_position(marker.position, definition)
		var fixed_spawn := FixedItemSpawnDefinition.new()
		fixed_spawn.spawn_id = marker.spawn_id
		fixed_spawn.position_xz = Vector2(marker.position.x, marker.position.z)
		fixed_spawn.pickup = marker.pickup
		fixed_spawn.amount = marker.amount
		fixed_spawn.respawn_delay_ticks = marker.respawn_delay_ticks
		definition.fixed_item_spawns.append(fixed_spawn)

	definition.emit_changed()
