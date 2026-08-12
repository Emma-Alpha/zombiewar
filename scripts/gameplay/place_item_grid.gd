extends Node3D
class_name PlaceItemGrid

const FACING_STEPS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, -1),
	Vector2i(1, 0),
	Vector2i(1, 1),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(-1, -1),
]

@export_range(0.25, 4.0, 0.25) var cell_size := 1.0
@export var grid_origin := Vector3.ZERO
@export_node_path("Node") var obstacle_root_path: NodePath
@export_flags_3d_physics var dynamic_blocker_mask := 6
@export_range(0.2, 4.0, 0.1) var dynamic_query_height := 1.8

var cell_owners: Dictionary = {}
var owner_cells: Dictionary = {}
## 固定/掉落补给可能落在同一批格子上。它们需要多 owner 计数；普通运行时
## 放置物仍使用上面的单 owner 表，避免改变 PlaceItemService 的占格合同。
var shared_cell_owners: Dictionary = {}
var shared_owner_cells: Dictionary = {}

func _ready() -> void:
	call_deferred("register_initial_obstacles")

func world_to_cell(world_position: Vector3) -> Vector2i:
	var size := maxf(cell_size, 0.001)
	return Vector2i(
		roundi((world_position.x - grid_origin.x) / size),
		roundi((world_position.z - grid_origin.z) / size)
	)

func cell_to_world(cell: Vector2i) -> Vector3:
	var size := maxf(cell_size, 0.001)
	return grid_origin + Vector3(cell.x * size, 0.0, cell.y * size)

func facing_step(direction: Vector3) -> Vector2i:
	var planar := Vector2(direction.x, direction.z)
	if planar.length_squared() <= 0.000001:
		return Vector2i.ZERO
	planar = planar.normalized()
	var best_step := Vector2i.ZERO
	var best_dot := -INF
	for step in FACING_STEPS:
		var candidate := Vector2(step.x, step.y).normalized()
		var score := planar.dot(candidate)
		if score > best_dot:
			best_dot = score
			best_step = step
	return best_step

func target_cell(origin: Vector3, direction: Vector3) -> Vector2i:
	return world_to_cell(origin) + facing_step(direction)

func reserve_cells(owner: Node, cells: Array[Vector2i]) -> bool:
	if owner == null or cells.is_empty():
		return false
	var owner_id := owner.get_instance_id()
	for cell in cells:
		if (
			(cell_owners.has(cell) and cell_owners[cell] != owner_id) or
			shared_cell_owners.has(cell)
		):
			return false
	for cell in cells:
		cell_owners[cell] = owner_id
	owner_cells[owner_id] = cells.duplicate()
	return true

func release_owner(owner: Node) -> bool:
	if owner == null:
		return false
	var owner_id := owner.get_instance_id()
	var released := false
	if owner_cells.has(owner_id):
		for cell in owner_cells[owner_id]:
			if cell_owners.get(cell) == owner_id:
				cell_owners.erase(cell)
		owner_cells.erase(owner_id)
		released = true
	if shared_owner_cells.has(owner_id):
		for cell in shared_owner_cells[owner_id]:
			var shared_owners: Dictionary = shared_cell_owners.get(cell, {})
			shared_owners.erase(owner_id)
			if shared_owners.is_empty():
				shared_cell_owners.erase(cell)
			else:
				shared_cell_owners[cell] = shared_owners
		shared_owner_cells.erase(owner_id)
		released = true
	return released

func is_cell_reserved(cell: Vector2i) -> bool:
	return cell_owners.has(cell) or shared_cell_owners.has(cell)

func cells_for_collision_object(
	obstacle: CollisionObject3D
) -> Array[Vector2i]:
	if obstacle == null:
		return []
	var combined := AABB()
	var has_bounds := false
	for candidate in obstacle.find_children(
		"*",
		"CollisionShape3D",
		true,
		false
	):
		var collision_shape := candidate as CollisionShape3D
		if (
			collision_shape == null or collision_shape.disabled or
			collision_shape.shape == null
		):
			continue
		if not _collision_shape_belongs_to(collision_shape, obstacle):
			continue
		var local_aabb := _shape_local_aabb(collision_shape.shape)
		if local_aabb.size == Vector3.ZERO:
			push_warning(
				"Unsupported place-item obstacle shape: %s (%s)" % [
					collision_shape.get_path(),
					collision_shape.shape.get_class(),
				]
			)
			continue
		var world_aabb := collision_shape.global_transform * local_aabb
		combined = world_aabb if not has_bounds else combined.merge(world_aabb)
		has_bounds = true
	return _cells_for_world_aabb(combined) if has_bounds else []

func register_obstacle(obstacle: CollisionObject3D) -> bool:
	if obstacle == null:
		return false
	var cells := cells_for_collision_object(obstacle)
	if cells.is_empty() or not reserve_cells(obstacle, cells):
		return false
	_connect_obstacle_exit(obstacle)
	return true

## 补给箱专用的多 owner 登记。共享 owner 之间、以及已存在的普通 owner 与
## 新共享 owner 之间都可重叠；之后普通放置请求仍会被 is/reserve 拒绝。
func register_shared_obstacle(obstacle: CollisionObject3D) -> bool:
	if obstacle == null:
		return false
	var cells := cells_for_collision_object(obstacle)
	if cells.is_empty() or not _reserve_shared_cells(obstacle, cells):
		return false
	_connect_obstacle_exit(obstacle)
	return true

func _reserve_shared_cells(owner: Node, cells: Array[Vector2i]) -> bool:
	if owner == null or cells.is_empty():
		return false
	var owner_id := owner.get_instance_id()
	if shared_owner_cells.has(owner_id):
		return false
	for cell in cells:
		var shared_owners: Dictionary = shared_cell_owners.get(cell, {})
		shared_owners[owner_id] = true
		shared_cell_owners[cell] = shared_owners
	shared_owner_cells[owner_id] = cells.duplicate()
	return true

func _connect_obstacle_exit(obstacle: CollisionObject3D) -> void:
	var exit_callback := Callable(
		self,
		"_on_registered_obstacle_exiting"
	).bind(obstacle)
	if not obstacle.tree_exiting.is_connected(exit_callback):
		obstacle.tree_exiting.connect(exit_callback, CONNECT_ONE_SHOT)

func register_initial_obstacles() -> void:
	if not is_inside_tree():
		return
	var obstacle_root := get_node_or_null(obstacle_root_path)
	if obstacle_root == null:
		return
	_register_obstacles_in_subtree(obstacle_root)

func _register_obstacles_in_subtree(node: Node) -> void:
	if node is CollisionObject3D and node.is_in_group(&"place_item_obstacle"):
		register_obstacle(node as CollisionObject3D)
	for child in node.get_children():
		_register_obstacles_in_subtree(child)

func has_dynamic_blocker(
	world: World3D,
	cell: Vector2i,
	excluded: Array[RID]
) -> bool:
	if world == null or dynamic_blocker_mask == 0:
		return false
	var query_shape := BoxShape3D.new()
	query_shape.size = Vector3(
		maxf(cell_size * 0.9, 0.1),
		maxf(dynamic_query_height, 0.2),
		maxf(cell_size * 0.9, 0.1)
	)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = query_shape
	query.transform = Transform3D(
		Basis.IDENTITY,
		cell_to_world(cell) + Vector3.UP * (0.1 + query_shape.size.y * 0.5)
	)
	query.collision_mask = dynamic_blocker_mask
	query.collide_with_bodies = true
	query.collide_with_areas = true
	query.exclude = excluded
	return not world.direct_space_state.intersect_shape(query, 32).is_empty()

static func shape_local_aabb(shape: Shape3D) -> AABB:
	var half := Vector3.ZERO
	if shape is BoxShape3D:
		half = (shape as BoxShape3D).size * 0.5
	elif shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		half = Vector3(cylinder.radius, cylinder.height * 0.5, cylinder.radius)
	elif shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		half = Vector3(capsule.radius, capsule.height * 0.5, capsule.radius)
	elif shape is SphereShape3D:
		var radius := (shape as SphereShape3D).radius
		half = Vector3.ONE * radius
	else:
		return AABB()
	return AABB(-half, half * 2.0)

## 供流场烘焙与运行时标脏使用：把一个碰撞体的全部可用碰撞形状合并为世界 AABB。
static func collision_object_world_aabb(obstacle: CollisionObject3D) -> AABB:
	if obstacle == null:
		return AABB()
	var combined := AABB()
	var has_bounds := false
	for candidate in obstacle.find_children("*", "CollisionShape3D", true, false):
		var collision_shape := candidate as CollisionShape3D
		if (
			collision_shape == null or collision_shape.disabled or
			collision_shape.shape == null
		):
			continue
		if not _collision_shape_belongs_to(collision_shape, obstacle):
			continue
		var local_aabb := shape_local_aabb(collision_shape.shape)
		if local_aabb.size == Vector3.ZERO:
			continue
		var world_aabb := collision_shape.global_transform * local_aabb
		combined = world_aabb if not has_bounds else combined.merge(world_aabb)
		has_bounds = true
	return combined if has_bounds else AABB()

static func _collision_shape_belongs_to(
	collision_shape: CollisionShape3D,
	obstacle: CollisionObject3D
) -> bool:
	var ancestor := collision_shape.get_parent()
	while ancestor != null:
		if ancestor is CollisionObject3D:
			return ancestor == obstacle
		ancestor = ancestor.get_parent()
	return false

func _shape_local_aabb(shape: Shape3D) -> AABB:
	return shape_local_aabb(shape)

func _cells_for_world_aabb(bounds: AABB) -> Array[Vector2i]:
	var size := maxf(cell_size, 0.001)
	var half_cell := size * 0.5
	var min_x := ceili((bounds.position.x - grid_origin.x - half_cell) / size)
	var max_x := floori((bounds.end.x - grid_origin.x + half_cell) / size)
	var min_z := ceili((bounds.position.z - grid_origin.z - half_cell) / size)
	var max_z := floori((bounds.end.z - grid_origin.z + half_cell) / size)
	var cells: Array[Vector2i] = []
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			cells.append(Vector2i(x, z))
	return cells

func _on_registered_obstacle_exiting(obstacle: CollisionObject3D) -> void:
	release_owner(obstacle)
