extends Node3D
class_name NavigationWorldManager

signal chunk_bake_started(chunk_id: StringName, generation: int)
signal chunk_ready(chunk_id: StringName, generation: int)
signal chunk_bake_failed(chunk_id: StringName, generation: int, message: String)

@export var map_cell_size := 0.20
@export var map_cell_height := 0.10

var chunks: Dictionary = {}
var navigation_map_configured := false

func _enter_tree() -> void:
	_configure_navigation_map()
	if not child_entered_tree.is_connected(_on_child_entered_tree):
		child_entered_tree.connect(_on_child_entered_tree)
	if not child_exiting_tree.is_connected(_on_child_exiting_tree):
		child_exiting_tree.connect(_on_child_exiting_tree)

func _ready() -> void:
	if not navigation_map_configured and not _configure_navigation_map():
		push_warning("Shared navigation map is unavailable")
		return
	for child in get_children():
		if child is NavigationChunk3D:
			register_chunk(child as NavigationChunk3D)

func register_chunk(chunk: NavigationChunk3D) -> bool:
	if chunk == null or chunk.chunk_id.is_empty():
		push_warning("Cannot register navigation chunk without an id")
		return false
	if is_inside_tree() and not navigation_map_configured:
		if not _configure_navigation_map():
			push_warning("Cannot register navigation chunk before shared map setup")
			return false
	if (
		not is_equal_approx(chunk.cell_size, map_cell_size) or
		not is_equal_approx(chunk.cell_height, map_cell_height)
	):
		chunk.set_registered(false)
		push_warning(
			"Navigation chunk voxel settings do not match shared map: %s" %
			chunk.chunk_id
		)
		return false
	if chunks.has(chunk.chunk_id):
		if chunks[chunk.chunk_id] == chunk:
			chunk.set_registered(true)
			return true
		chunk.set_registered(false)
		push_warning("Duplicate navigation chunk id: %s" % chunk.chunk_id)
		return false
	chunks[chunk.chunk_id] = chunk
	chunk.set_registered(true)
	chunk.bake_started.connect(_on_chunk_bake_started)
	chunk.bake_succeeded.connect(_on_chunk_bake_succeeded)
	chunk.bake_failed.connect(_on_chunk_bake_failed)
	chunk.request_rebake()
	return true

func unregister_chunk(chunk_id: StringName) -> bool:
	var chunk := chunks.get(chunk_id) as NavigationChunk3D
	if chunk == null:
		return false
	chunk.invalidate_pending_bakes()
	chunk.set_registered(false)
	if chunk.bake_started.is_connected(_on_chunk_bake_started):
		chunk.bake_started.disconnect(_on_chunk_bake_started)
	if chunk.bake_succeeded.is_connected(_on_chunk_bake_succeeded):
		chunk.bake_succeeded.disconnect(_on_chunk_bake_succeeded)
	if chunk.bake_failed.is_connected(_on_chunk_bake_failed):
		chunk.bake_failed.disconnect(_on_chunk_bake_failed)
	chunks.erase(chunk_id)
	return true

func mark_chunk_dirty(chunk_id: StringName) -> bool:
	var chunk := chunks.get(chunk_id) as NavigationChunk3D
	if chunk == null:
		return false
	chunk.mark_dirty()
	return true

func request_rebake(chunk_id: StringName) -> bool:
	var chunk := chunks.get(chunk_id) as NavigationChunk3D
	if chunk == null:
		return false
	chunk.request_rebake()
	return true

func get_chunk_state(chunk_id: StringName) -> Dictionary:
	var chunk := chunks.get(chunk_id) as NavigationChunk3D
	return {} if chunk == null else chunk.get_state_snapshot()

func is_navigation_ready_at(world_position: Vector3) -> bool:
	for chunk_value in chunks.values():
		var chunk := chunk_value as NavigationChunk3D
		if chunk == null or not chunk.contains_global_position(world_position):
			continue
		if chunk.is_navigation_ready():
			return true
	return false

func _configure_navigation_map() -> bool:
	var world := get_world_3d()
	if world == null or not world.navigation_map.is_valid():
		return false
	NavigationServer3D.map_set_cell_size(world.navigation_map, map_cell_size)
	NavigationServer3D.map_set_cell_height(world.navigation_map, map_cell_height)
	NavigationServer3D.map_force_update(world.navigation_map)
	navigation_map_configured = true
	return true

func _on_child_entered_tree(child: Node) -> void:
	if child is NavigationChunk3D:
		if navigation_map_configured or _configure_navigation_map():
			register_chunk(child as NavigationChunk3D)

func _on_child_exiting_tree(child: Node) -> void:
	if not child is NavigationChunk3D:
		return
	var chunk := child as NavigationChunk3D
	if chunks.get(chunk.chunk_id) == chunk:
		unregister_chunk(chunk.chunk_id)

func _on_chunk_bake_started(chunk_id: StringName, generation: int) -> void:
	chunk_bake_started.emit(chunk_id, generation)

func _on_chunk_bake_succeeded(chunk_id: StringName, generation: int) -> void:
	chunk_ready.emit(chunk_id, generation)

func _on_chunk_bake_failed(
	chunk_id: StringName,
	generation: int,
	message: String
) -> void:
	chunk_bake_failed.emit(chunk_id, generation, message)
