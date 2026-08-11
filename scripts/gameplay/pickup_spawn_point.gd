extends Node3D
class_name PickupSpawnPoint

## 拾取箱本身是静态阻挡（place_item_obstacle 组、collision_layer = 1），
## 出现与消失都必须标脏对应 cell。
signal blocker_changed(world_aabb: AABB, blocked: bool)
## 箱子落位后广播，供竞技场把它注册成模拟层实体。
## 领取判定住在模拟层，节点自己不再判（见 PickupChest）。
signal pickup_spawned(pickup: PickupChest)

const PICKUP_SCENE := preload("res://scenes/gameplay/PickupChest.tscn")

@export var pickup_definition: PickupDefinition
@export var respawn_enabled := false
@export_range(0.0, 300.0, 0.1) var respawn_delay_seconds := 3.0
@export var remove_after_collection := false

@onready var respawn_timer: Timer = $RespawnTimer

var current_pickup: PickupChest
var current_pickup_id := 0
var respawn_requested := false
var current_pickup_bounds := AABB()
var collected_successfully := false

func _ready() -> void:
	respawn_timer.timeout.connect(_spawn_pickup)
	call_deferred("_spawn_pickup")

func _spawn_pickup() -> void:
	if current_pickup != null and is_instance_valid(current_pickup):
		return
	if pickup_definition == null:
		push_warning("PickupSpawnPoint has no pickup Definition: %s" % get_path())
		return
	current_pickup = PICKUP_SCENE.instantiate() as PickupChest
	current_pickup.configure(pickup_definition)
	add_child(current_pickup)
	current_pickup.transform = _next_spawn_transform()
	current_pickup_id = current_pickup.get_instance_id()
	respawn_requested = false
	collected_successfully = false
	current_pickup.collected.connect(_on_pickup_collected)
	current_pickup.tree_exited.connect(
		_on_pickup_tree_exited.bind(current_pickup_id),
		CONNECT_ONE_SHOT
	)
	current_pickup_bounds = PlaceItemGrid.collision_object_world_aabb(current_pickup)
	blocker_changed.emit(current_pickup_bounds, true)
	# 必须排在 transform 落位之后：注册方要按世界坐标建模拟层实体。
	pickup_spawned.emit(current_pickup)

func _on_pickup_collected(pickup: PickupChest) -> void:
	if pickup == current_pickup:
		collected_successfully = true
		respawn_requested = respawn_enabled

func _on_pickup_tree_exited(pickup_id: int) -> void:
	if pickup_id != current_pickup_id:
		return
	current_pickup = null
	current_pickup_id = 0
	# 清阻挡必须排在 remove_after_collection 的提前返回**之前**：
	# 一次性拾取点在这里 queue_free() 自己，若先返回就再没有人来清这块格，
	# 箱子早就没了而僵尸还在绕着它走。
	blocker_changed.emit(current_pickup_bounds, false)
	current_pickup_bounds = AABB()
	if remove_after_collection and collected_successfully:
		queue_free()
		return
	if not respawn_requested:
		return
	respawn_requested = false
	respawn_timer.start(maxf(_next_respawn_delay(), 0.0))

func _next_spawn_transform() -> Transform3D:
	return Transform3D.IDENTITY

func _next_respawn_delay() -> float:
	return respawn_delay_seconds

func get_current_pickup() -> PickupChest:
	return current_pickup
