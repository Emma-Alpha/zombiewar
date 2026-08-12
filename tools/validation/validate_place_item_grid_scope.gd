extends SceneTree

const PlaceItemGridScript = preload("res://scripts/gameplay/place_item_grid.gd")
const FlowFieldGridScript = preload("res://scripts/sim/flow_field_grid.gd")
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const PICKUP_CHEST_SCENE := preload("res://scenes/gameplay/PickupChest.tscn")
const DEMO_MAP_SCENE := preload("res://scenes/maps/demo/DemoMap.tscn")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var host := Node3D.new()
	var content := Node3D.new()
	content.name = "Content"
	var outside := Node3D.new()
	outside.name = "Outside"
	var grid: PlaceItemGrid = PlaceItemGridScript.new()
	grid.name = "Grid"
	host.add_child(content)
	host.add_child(outside)
	host.add_child(grid)
	var inside_obstacle := _make_obstacle(Vector3.ZERO)
	var outside_obstacle := _make_obstacle(Vector3(5.0, 0.0, 0.0))
	content.add_child(inside_obstacle)
	outside.add_child(outside_obstacle)
	var has_root_path := _has_property(grid, &"obstacle_root_path")
	_expect(has_root_path, "PlaceItemGrid must expose obstacle_root_path", failures)
	if has_root_path:
		grid.set(&"obstacle_root_path", NodePath("../Content"))
	root.add_child(host)
	await process_frame
	await process_frame
	_expect(grid.is_cell_reserved(Vector2i.ZERO), "content obstacle must be registered", failures)
	_expect(
		not grid.is_cell_reserved(Vector2i(5, 0)),
		"obstacles outside obstacle_root_path must be ignored",
		failures
	)
	host.free()
	_test_chest_shape_scope(failures)
	_test_shared_obstacle_owners(failures)
	await _test_claim_then_respawn_same_frame(failures)
	_finish(failures)

func _test_chest_shape_scope(failures: Array[String]) -> void:
	var host := Node3D.new()
	var grid: PlaceItemGrid = PlaceItemGridScript.new()
	grid.cell_size = 1.0
	grid.grid_origin = Vector3(-24.0, 0.0, -19.0)
	var chest := PICKUP_CHEST_SCENE.instantiate() as PickupChest
	_expect(chest != null, "pickup chest scene for shape scope", failures)
	if chest == null:
		return
	host.add_child(grid)
	host.add_child(chest)
	chest.position = Vector3(-4.5, 0.0, 6.0)
	root.add_child(host)
	var reserved_cells := grid.cells_for_collision_object(chest)
	reserved_cells.sort_custom(_cell_less)
	var expected_cells: Array[Vector2i] = [
		Vector2i(19, 25),
		Vector2i(20, 25),
	]
	_expect(
		reserved_cells == expected_cells,
		"chest reservation must use only its physical box (got %s)" % [reserved_cells],
		failures
	)

	var flow_grid: FlowFieldGrid = FlowFieldGridScript.new()
	flow_grid.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	var chest_position := Vector2(-4.5, 6.0)
	flow_grid.set_blocked_world_rect(
		chest_position - SimWorldScript.CHEST_BLOCKER_HALF_SIZE,
		chest_position + SimWorldScript.CHEST_BLOCKER_HALF_SIZE,
		true
	)
	var blocker_cells: Array[Vector2i] = []
	for index in range(flow_grid.get_cell_count()):
		var cell := flow_grid.index_to_cell(index)
		if flow_grid.is_blocked(cell):
			blocker_cells.append(cell)
	blocker_cells.sort_custom(_cell_less)
	_expect(
		reserved_cells == blocker_cells,
		"chest View reservation cells must match SimWorld blocker cells",
		failures
	)
	host.free()

func _test_shared_obstacle_owners(failures: Array[String]) -> void:
	var host := Node3D.new()
	var grid: PlaceItemGrid = PlaceItemGridScript.new()
	var first := _make_obstacle(Vector3.ZERO)
	var second := _make_obstacle(Vector3.ZERO)
	host.add_child(grid)
	host.add_child(first)
	host.add_child(second)
	root.add_child(host)
	var supports_shared := grid.has_method("register_shared_obstacle")
	_expect(
		supports_shared,
		"PlaceItemGrid must support shared obstacle owners",
		failures
	)
	if supports_shared:
		_expect(
			bool(grid.call("register_shared_obstacle", first)),
			"first shared obstacle must register",
			failures
		)
		_expect(
			bool(grid.call("register_shared_obstacle", second)),
			"overlapping shared obstacle must register",
			failures
		)
		var ordinary_owner := Node.new()
		host.add_child(ordinary_owner)
		_expect(
			not grid.reserve_cells(ordinary_owner, [Vector2i.ZERO]),
			"ordinary placement must reject a shared obstacle cell",
			failures
		)
		_expect(grid.release_owner(first), "first shared owner must release", failures)
		_expect(
			grid.is_cell_reserved(Vector2i.ZERO),
			"second shared owner must keep the cell reserved",
			failures
		)
		_expect(grid.release_owner(second), "second shared owner must release", failures)
		_expect(
			not grid.is_cell_reserved(Vector2i.ZERO),
			"shared cell must clear after its final owner releases",
			failures
		)
		var competing_owner := Node.new()
		host.add_child(competing_owner)
		_expect(
			grid.reserve_cells(ordinary_owner, [Vector2i.ZERO]),
			"ordinary owner must reserve an empty cell",
			failures
		)
		_expect(
			not grid.reserve_cells(competing_owner, [Vector2i.ZERO]),
			"ordinary reservation must remain single-owner",
			failures
		)
		grid.release_owner(ordinary_owner)
		_expect(
			grid.reserve_cells(competing_owner, [Vector2i.ZERO]),
			"ordinary cell must become available after owner removal",
			failures
		)
	host.free()

func _test_claim_then_respawn_same_frame(failures: Array[String]) -> void:
	var arena := DEMO_MAP_SCENE.instantiate()
	root.add_child(arena)
	arena.set_process(false)
	arena.set_physics_process(false)
	var runtime = arena.get("map_runtime")
	var place_grid := arena.get_node_or_null(
		"World/Placement/PlaceItemGrid"
	) as PlaceItemGrid
	var chest_views: Dictionary = arena.get("chest_views")
	_expect(runtime != null, "demo map runtime", failures)
	_expect(place_grid != null, "gameplay arena place item grid", failures)
	_expect(not chest_views.is_empty(), "demo map initial chest views", failures)
	if runtime == null or place_grid == null or chest_views.is_empty():
		arena.free()
		return
	var spawn_event: Dictionary = runtime.initial_chest_events[0].duplicate(true)
	var chest_id := int(spawn_event["chest_id"])
	var old_view := chest_views.get(chest_id) as PickupChest
	_expect(old_view != null, "initial chest view for respawn test", failures)
	if old_view == null:
		arena.free()
		return
	# 本验证关注 queue/free 与占格，不启动退出时仍可能持有解码器的拾取音效。
	old_view.spatial_sfx_pool = null
	var reserved_cells := place_grid.cells_for_collision_object(old_view)
	_expect(not reserved_cells.is_empty(), "initial chest reserved cells", failures)
	arena.call("_on_sim_chest_event", {
		"kind": &"chest_claimed",
		"chest_id": chest_id,
		"slot": -1,
	})
	var respawn_event := spawn_event.duplicate(true)
	respawn_event["kind"] = &"chest_respawned"
	arena.call("_on_sim_chest_event", respawn_event)
	chest_views = arena.get("chest_views")
	var replacement := chest_views.get(chest_id) as PickupChest
	_expect(
		replacement != null and replacement != old_view,
		"same-frame respawn must create a replacement chest view",
		failures
	)
	await process_frame
	for cell in reserved_cells:
		_expect(
			place_grid.is_cell_reserved(cell),
			"respawned chest must keep cell %s reserved after old View exits" % cell,
			failures
		)
	if replacement != null:
		_expect(
			place_grid.release_owner(replacement),
			"respawned chest must own its reservation",
			failures
		)
	arena.free()

func _make_obstacle(position: Vector3) -> StaticBody3D:
	var obstacle := StaticBody3D.new()
	obstacle.position = position
	obstacle.add_to_group(&"place_item_obstacle")
	var collision_shape := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.8, 1.0, 0.8)
	collision_shape.shape = shape
	obstacle.add_child(collision_shape)
	return obstacle

func _cell_less(left: Vector2i, right: Vector2i) -> bool:
	return left.y < right.y or (left.y == right.y and left.x < right.x)

func _has_property(object: Object, property_name: StringName) -> bool:
	for property in object.get_property_list():
		if property.get("name") == property_name:
			return true
	return false

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_place_item_grid_scope: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
