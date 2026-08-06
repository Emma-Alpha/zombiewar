extends Node
class_name PlaceItemController

signal item_count_changed(display_name: String, remaining_count: int)
signal placement_geometry_changed
signal placement_rejected(reason: StringName)

@export var item_display_name := ""
@export var place_item_scene: PackedScene
@export_range(0, 999999, 1) var initial_item_count := 0
@export_node_path("PlaceItemGrid") var grid_path: NodePath
@export_node_path("Node3D") var placed_items_path: NodePath

var remaining_count := -1
var tracked_items: Dictionary = {}

func _ready() -> void:
	if remaining_count < 0:
		remaining_count = maxi(initial_item_count, 0)
	call_deferred("_emit_current_count")

func get_remaining_count() -> int:
	return maxi(initial_item_count, 0) if remaining_count < 0 else remaining_count

func request_place_item(
	requester: CollisionObject3D,
	origin: Vector3,
	direction: Vector3
) -> bool:
	if remaining_count <= 0:
		return _reject(&"out_of_stock")
	var grid := get_node_or_null(grid_path) as PlaceItemGrid
	var container := get_node_or_null(placed_items_path) as Node3D
	if grid == null or container == null or place_item_scene == null:
		push_warning(
			"PlaceItemController has invalid scene, grid, or container configuration"
		)
		return _reject(&"invalid_configuration")
	if Vector2(direction.x, direction.z).length_squared() <= 0.000001:
		return _reject(&"invalid_direction")
	var cell := grid.target_cell(origin, direction)
	if grid.is_cell_reserved(cell):
		return _reject(&"reserved_cell")
	var excluded: Array[RID] = []
	if requester != null and is_instance_valid(requester):
		excluded.append(requester.get_rid())
	if grid.has_dynamic_blocker(grid.get_world_3d(), cell, excluded):
		return _reject(&"dynamic_blocker")
	var instance := place_item_scene.instantiate()
	if not instance is Node3D:
		instance.free()
		return _reject(&"invalid_scene_root")
	var item := instance as Node3D
	container.add_child(item)
	item.global_position = grid.cell_to_world(cell)
	if not grid.reserve_cells(item, [cell]):
		item.free()
		return _reject(&"reserved_cell")
	tracked_items[item.get_instance_id()] = item
	item.tree_exiting.connect(_on_item_tree_exiting.bind(item), CONNECT_ONE_SHOT)
	remaining_count -= 1
	item_count_changed.emit(item_display_name, remaining_count)
	placement_geometry_changed.emit()
	return true

func _reject(reason: StringName) -> bool:
	placement_rejected.emit(reason)
	return false

func _emit_current_count() -> void:
	item_count_changed.emit(item_display_name, remaining_count)

func _on_item_tree_exiting(item: Node3D) -> void:
	var item_id := item.get_instance_id()
	if not tracked_items.erase(item_id):
		return
	var grid := get_node_or_null(grid_path) as PlaceItemGrid
	if grid != null:
		grid.release_owner(item)
	if is_inside_tree():
		placement_geometry_changed.emit()
