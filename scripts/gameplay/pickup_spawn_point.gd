extends Node3D
class_name PickupSpawnPoint

signal navigation_geometry_changed

@export var pickup_scene: PackedScene
@export var respawn_enabled := false
@export_range(0.0, 300.0, 0.1) var respawn_delay_seconds := 3.0

@onready var respawn_timer: Timer = $RespawnTimer

var current_pickup: PickupChest
var current_pickup_id := 0
var respawn_requested := false

func _ready() -> void:
	respawn_timer.timeout.connect(_spawn_pickup)
	call_deferred("_spawn_pickup")

func _spawn_pickup() -> void:
	if current_pickup != null and is_instance_valid(current_pickup):
		return
	if pickup_scene == null:
		push_warning("PickupSpawnPoint has no pickup scene: %s" % get_path())
		return
	var instance := pickup_scene.instantiate()
	if not instance is PickupChest:
		push_warning("PickupSpawnPoint requires a PickupChest scene: %s" % get_path())
		instance.free()
		return
	current_pickup = instance as PickupChest
	add_child(current_pickup)
	current_pickup.transform = _next_spawn_transform()
	current_pickup_id = current_pickup.get_instance_id()
	respawn_requested = false
	current_pickup.collected.connect(_on_pickup_collected)
	current_pickup.tree_exited.connect(
		_on_pickup_tree_exited.bind(current_pickup_id),
		CONNECT_ONE_SHOT
	)
	navigation_geometry_changed.emit()

func _on_pickup_collected(pickup: PickupChest) -> void:
	if pickup == current_pickup:
		respawn_requested = respawn_enabled

func _on_pickup_tree_exited(pickup_id: int) -> void:
	if pickup_id != current_pickup_id:
		return
	current_pickup = null
	current_pickup_id = 0
	navigation_geometry_changed.emit()
	if not respawn_requested:
		return
	respawn_requested = false
	respawn_timer.start(maxf(_next_respawn_delay(), 0.0))

func _next_spawn_transform() -> Transform3D:
	return Transform3D.IDENTITY

func _next_respawn_delay() -> float:
	return respawn_delay_seconds
