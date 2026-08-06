extends Node3D
class_name NavigationChunk3D

const NavigationBakeState = preload("res://scripts/navigation/navigation_bake_state.gd")

signal bake_started(chunk_id: StringName, generation: int)
signal bake_succeeded(chunk_id: StringName, generation: int)
signal bake_failed(chunk_id: StringName, generation: int, message: String)

@export var chunk_id: StringName
@export var source_root_path: NodePath
@export var source_group_name: StringName = &"navigation_source"
@export var baking_bounds := AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 2.0, 2.0))
@export var threaded_baking := true
@export var agent_radius := 0.60
@export var agent_height := 1.90
@export var agent_max_climb := 0.20
@export var cell_size := 0.20
@export var cell_height := 0.10
@export var border_size := 0.60
@export var edge_max_error := 1.0

@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D

var bake_state := NavigationBakeState.new()

func request_rebake() -> void:
	if bake_state.queue_bake():
		call_deferred("_start_queued_bake")

func mark_dirty() -> void:
	request_rebake()

func invalidate_pending_bakes() -> void:
	bake_state.invalidate()

func set_registered(value: bool) -> void:
	if navigation_region == null:
		navigation_region = get_node_or_null("NavigationRegion3D") as NavigationRegion3D
	if navigation_region == null:
		return
	if not value:
		navigation_region.enabled = false
		return
	var navigation_map := navigation_region.get_navigation_map()
	var world := get_world_3d()
	if not navigation_map.is_valid() and world != null and world.navigation_map.is_valid():
		navigation_region.set_navigation_map(world.navigation_map)
		navigation_map = navigation_region.get_navigation_map()
	if not navigation_map.is_valid():
		navigation_region.enabled = false
		push_warning("Navigation map is unavailable for %s" % chunk_id)
		return
	if (
		not is_equal_approx(NavigationServer3D.map_get_cell_size(navigation_map), cell_size) or
		not is_equal_approx(NavigationServer3D.map_get_cell_height(navigation_map), cell_height)
	):
		navigation_region.enabled = false
		push_warning("Navigation chunk voxel settings do not match navigation map: %s" % chunk_id)
		return
	navigation_region.enabled = true

func is_navigation_ready() -> bool:
	if navigation_region == null:
		navigation_region = get_node_or_null("NavigationRegion3D") as NavigationRegion3D
	if (
		navigation_region == null or
		not navigation_region.enabled or
		not bool(bake_state.snapshot().get("has_usable_mesh", false))
	):
		return false
	return navigation_region.get_navigation_map().is_valid()

func contains_global_position(world_position: Vector3) -> bool:
	var source_root := get_node_or_null(source_root_path) as Node3D
	return source_root != null and baking_bounds.has_point(source_root.to_local(world_position))

func get_state_snapshot() -> Dictionary:
	return bake_state.snapshot()

func _start_queued_bake() -> void:
	if bake_state.status != NavigationBakeState.Status.QUEUED:
		return
	var validation_error := _validation_error()
	var generation := bake_state.begin_bake()
	if not validation_error.is_empty():
		_finish_failure(generation, validation_error)
		return
	bake_started.emit(chunk_id, generation)
	var candidate := _create_navigation_mesh()
	var source_data := NavigationMeshSourceGeometryData3D.new()
	var source_root := get_node(source_root_path) as Node3D
	navigation_region.global_transform = source_root.global_transform
	NavigationServer3D.parse_source_geometry_data(
		candidate,
		source_data,
		source_root,
		Callable(self, "_on_source_geometry_parsed").bind(
			generation,
			candidate,
			source_data
		)
	)

func _validation_error() -> String:
	if chunk_id.is_empty():
		return "Navigation chunk id is empty"
	if source_root_path.is_empty() or not get_node_or_null(source_root_path) is Node3D:
		return "Navigation source root is missing for %s" % chunk_id
	if baking_bounds.size.x <= 0.0 or baking_bounds.size.y <= 0.0 or baking_bounds.size.z <= 0.0:
		return "Navigation baking bounds are invalid for %s" % chunk_id
	if navigation_region == null:
		return "Navigation region is missing for %s" % chunk_id
	return ""

func _create_navigation_mesh() -> NavigationMesh:
	var navigation_mesh := NavigationMesh.new()
	navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	navigation_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	navigation_mesh.geometry_source_group_name = source_group_name
	navigation_mesh.filter_baking_aabb = baking_bounds
	navigation_mesh.agent_radius = agent_radius
	navigation_mesh.agent_height = agent_height
	navigation_mesh.agent_max_climb = agent_max_climb
	navigation_mesh.cell_size = cell_size
	navigation_mesh.cell_height = cell_height
	navigation_mesh.border_size = border_size
	navigation_mesh.edge_max_error = edge_max_error
	return navigation_mesh

func _on_source_geometry_parsed(
	generation: int,
	candidate: NavigationMesh,
	source_data: NavigationMeshSourceGeometryData3D
) -> void:
	if not bake_state.is_active_generation(generation):
		return
	if not source_data.has_data():
		_finish_failure(generation, "Navigation source geometry is empty for %s" % chunk_id)
		return
	var callback := Callable(self, "_on_navigation_mesh_baked").bind(generation, candidate)
	if threaded_baking:
		NavigationServer3D.bake_from_source_geometry_data_async(candidate, source_data, callback)
	else:
		NavigationServer3D.bake_from_source_geometry_data(candidate, source_data, callback)

func _on_navigation_mesh_baked(generation: int, candidate: NavigationMesh) -> void:
	if not bake_state.is_active_generation(generation):
		return
	if candidate.get_polygon_count() <= 0:
		_finish_failure(generation, "Navigation bake produced no polygons for %s" % chunk_id)
		return
	navigation_region.navigation_mesh = candidate
	if not bake_state.complete_success(generation):
		return
	bake_succeeded.emit(chunk_id, generation)
	_start_follow_up_if_queued()

func _finish_failure(generation: int, message: String) -> void:
	if not bake_state.complete_failure(generation, message):
		return
	push_warning(message)
	bake_failed.emit(chunk_id, generation, message)
	_start_follow_up_if_queued()

func _start_follow_up_if_queued() -> void:
	if bake_state.status == NavigationBakeState.Status.QUEUED:
		call_deferred("_start_queued_bake")
