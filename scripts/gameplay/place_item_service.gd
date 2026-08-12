extends Node
class_name PlaceItemService

signal placement_rejected(reason: StringName)
## 运行时放置的物件是新的阻挡几何，必须标脏对应 cell；
## 若它是爆炸桶，还要由 GameplayArena 注册成模拟层实体
## （见 GameplayArena._on_item_placed()）。
signal item_placed(item: Node3D)
## 移除时把节点与消失前采集的世界 AABB 一起广播：
## 爆炸桶要靠节点本身拿到模拟层 id，光有 AABB 不够。
signal item_removed(item: Node3D, world_aabb: AABB)

@export var default_item_scene: PackedScene
@export_node_path("PlaceItemGrid") var grid_path: NodePath
@export_node_path("Node3D") var placed_items_path: NodePath

var tracked_items: Dictionary = {}

func request_place_item(
	requester: CollisionObject3D,
	origin: Vector3,
	direction: Vector3,
	item_scene: PackedScene = null
) -> bool:
	var resolved_scene := item_scene if item_scene != null else default_item_scene
	var grid := get_node_or_null(grid_path) as PlaceItemGrid
	var container := get_node_or_null(placed_items_path) as Node3D
	if grid == null or container == null or resolved_scene == null:
		push_warning("PlaceItemService has invalid scene, grid, or container configuration")
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
	var instance := resolved_scene.instantiate()
	if not instance is Node3D:
		instance.free()
		return _reject(&"invalid_scene_root")
	var item := instance as Node3D
	# 记下放置者座位：工兵「加固」被动需要知道这桶是谁放的，才能确定性缩放
	# 爆炸范围/伤害。requester 是本机玩家（PlayerController），其 player_index
	# 即模拟层座位号；用 get() 鸭子类型读，未知类型静默跳过。联机各端从同一份
	# 角色目录得到同一 owner 判定，确定性成立。
	var owner_index: Variant = requester.get("player_index") if requester != null else null
	if owner_index is int:
		item.set_meta("owner_slot", owner_index)
	container.add_child(item)
	item.global_position = grid.cell_to_world(cell)
	if not grid.reserve_cells(item, [cell]):
		item.free()
		return _reject(&"reserved_cell")
	tracked_items[item.get_instance_id()] = item
	item.tree_exiting.connect(_on_item_tree_exiting.bind(item), CONNECT_ONE_SHOT)
	# 必须在 item.global_position 落位之后再发：注册方要按它读世界坐标。
	item_placed.emit(item)
	return true

func _reject(reason: StringName) -> bool:
	placement_rejected.emit(reason)
	return false

func _on_item_tree_exiting(item: Node3D) -> void:
	var item_id := item.get_instance_id()
	if not tracked_items.erase(item_id):
		return
	var bounds := PlaceItemGrid.collision_object_world_aabb(
		item as CollisionObject3D
	)
	var grid := get_node_or_null(grid_path) as PlaceItemGrid
	if grid != null:
		grid.release_owner(item)
	item_removed.emit(item, bounds)
