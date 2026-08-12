@tool
extends EditorNode3DGizmoPlugin

const PLAYER_SPAWN_ICON := preload("res://addons/map_editor/icons/player_spawn.svg")
const ZOMBIE_SPAWN_ICON := preload("res://addons/map_editor/icons/zombie_spawn.svg")
const FIXED_ITEM_SPAWN_ICON := preload(
	"res://addons/map_editor/icons/fixed_item_spawn.svg"
)
const MANAGED_META := &"map_editor_managed"
const CIRCLE_SEGMENTS := 32


func _init() -> void:
	create_icon_material("player_spawn", PLAYER_SPAWN_ICON, false, Color.WHITE)
	create_icon_material("zombie_spawn", ZOMBIE_SPAWN_ICON, false, Color.WHITE)
	create_icon_material("fixed_item_spawn", FIXED_ITEM_SPAWN_ICON, false, Color.WHITE)
	create_material("zombie_radius", Color(1.0, 0.25, 0.18, 0.9))
	create_material("map_border", Color(0.1, 0.85, 1.0, 0.95))
	create_material("map_grid", Color(0.2, 0.65, 0.8, 0.38))
	create_material("managed_bounds", Color(1.0, 0.62, 0.12, 0.95))


func _get_gizmo_name() -> String:
	return "MapAuthoring"


func _has_gizmo(node: Node3D) -> bool:
	return (
		node is MapPlayerSpawnMarker
		or node is MapZombieSpawnMarker
		or node is MapFixedItemSpawnMarker
		or node is MapContentAuthoringRoot
		or (
			node is CollisionObject3D
			and node.has_meta(MANAGED_META)
		)
	)


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d()
	if node is MapPlayerSpawnMarker:
		gizmo.add_unscaled_billboard(
			get_material("player_spawn", gizmo),
			0.06
		)
		return
	if node is MapZombieSpawnMarker:
		gizmo.add_unscaled_billboard(
			get_material("zombie_spawn", gizmo),
			0.06
		)
		_draw_zombie_radius(gizmo, node as MapZombieSpawnMarker)
		return
	if node is MapFixedItemSpawnMarker:
		gizmo.add_unscaled_billboard(
			get_material("fixed_item_spawn", gizmo),
			0.06
		)
		return
	if node is MapContentAuthoringRoot:
		_draw_map_grid(gizmo, node as MapContentAuthoringRoot)
		return
	if node is CollisionObject3D and node.has_meta(MANAGED_META):
		_draw_managed_collision_bounds(gizmo, node as CollisionObject3D)


func _draw_zombie_radius(
	gizmo: EditorNode3DGizmo,
	marker: MapZombieSpawnMarker
) -> void:
	var radius := maxf(marker.spawn_radius, 0.0)
	if radius <= 0.0:
		return
	var lines := PackedVector3Array()
	for segment in CIRCLE_SEGMENTS:
		var angle_a := TAU * float(segment) / float(CIRCLE_SEGMENTS)
		var angle_b := TAU * float(segment + 1) / float(CIRCLE_SEGMENTS)
		lines.append(Vector3(cos(angle_a) * radius, 0.05, sin(angle_a) * radius))
		lines.append(Vector3(cos(angle_b) * radius, 0.05, sin(angle_b) * radius))
	gizmo.add_lines(lines, get_material("zombie_radius", gizmo), false)


func _draw_map_grid(
	gizmo: EditorNode3DGizmo,
	root: MapContentAuthoringRoot
) -> void:
	if root.map_definition_path.is_empty():
		return
	var definition := load(root.map_definition_path) as MapDefinition
	if definition == null:
		return
	var width := maxi(definition.grid_width, 1)
	var height := maxi(definition.grid_height, 1)
	var cell_size := maxf(definition.grid_cell_size, 0.001)
	var min_x := definition.grid_origin.x
	var min_z := definition.grid_origin.y
	var max_x := min_x + float(width) * cell_size
	var max_z := min_z + float(height) * cell_size
	var y := 0.03
	var border := PackedVector3Array([
		Vector3(min_x, y, min_z), Vector3(max_x, y, min_z),
		Vector3(max_x, y, min_z), Vector3(max_x, y, max_z),
		Vector3(max_x, y, max_z), Vector3(min_x, y, max_z),
		Vector3(min_x, y, max_z), Vector3(min_x, y, min_z),
	])
	gizmo.add_lines(border, get_material("map_border", gizmo), false)

	var grid_lines := PackedVector3Array()
	var x_stride := maxi(ceili(float(width) / 128.0), 1)
	for x_index in range(x_stride, width, x_stride):
		var x := min_x + float(x_index) * cell_size
		grid_lines.append(Vector3(x, y, min_z))
		grid_lines.append(Vector3(x, y, max_z))
	var z_stride := maxi(ceili(float(height) / 128.0), 1)
	for z_index in range(z_stride, height, z_stride):
		var z := min_z + float(z_index) * cell_size
		grid_lines.append(Vector3(min_x, y, z))
		grid_lines.append(Vector3(max_x, y, z))
	if not grid_lines.is_empty():
		gizmo.add_lines(grid_lines, get_material("map_grid", gizmo), false)


func _draw_managed_collision_bounds(
	gizmo: EditorNode3DGizmo,
	obstacle: CollisionObject3D
) -> void:
	var world_bounds := PlaceItemGrid.collision_object_world_aabb(obstacle)
	if world_bounds.size == Vector3.ZERO:
		return
	var world_corners: Array[Vector3] = [
		world_bounds.position,
		world_bounds.position + Vector3(world_bounds.size.x, 0.0, 0.0),
		world_bounds.position + Vector3(0.0, world_bounds.size.y, 0.0),
		world_bounds.position + Vector3(0.0, 0.0, world_bounds.size.z),
		world_bounds.position + Vector3(world_bounds.size.x, world_bounds.size.y, 0.0),
		world_bounds.position + Vector3(world_bounds.size.x, 0.0, world_bounds.size.z),
		world_bounds.position + Vector3(0.0, world_bounds.size.y, world_bounds.size.z),
		world_bounds.end,
	]
	var local_corners: Array[Vector3] = []
	for world_corner in world_corners:
		local_corners.append(obstacle.to_local(world_corner))
	var edge_indices := [
		[0, 1], [0, 2], [0, 3],
		[1, 4], [1, 5],
		[2, 4], [2, 6],
		[3, 5], [3, 6],
		[4, 7], [5, 7], [6, 7],
	]
	var lines := PackedVector3Array()
	for edge in edge_indices:
		lines.append(local_corners[edge[0]])
		lines.append(local_corners[edge[1]])
	gizmo.add_lines(lines, get_material("managed_bounds", gizmo), false)
