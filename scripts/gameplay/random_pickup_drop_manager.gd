extends Node3D
class_name RandomPickupDropManager

signal navigation_geometry_changed

const SPAWN_POINT_SCENE := preload("res://scenes/gameplay/PickupSpawnPoint.tscn")

@export_range(0.0, 1.0, 0.01) var drop_chance := 0.2
@export var pickup_definitions: Array[PickupDefinition] = []
@export var random_seed := 0

var rng := RandomNumberGenerator.new()

func _ready() -> void:
	if random_seed == 0:
		rng.randomize()
	else:
		rng.seed = random_seed

func try_spawn_drop(world_position: Vector3) -> PickupSpawnPoint:
	if pickup_definitions.is_empty() or not _passes_drop_chance(rng.randf()):
		return null
	var spawner := SPAWN_POINT_SCENE.instantiate() as PickupSpawnPoint
	spawner.pickup_definition = pickup_definitions[rng.randi_range(0, pickup_definitions.size() - 1)]
	spawner.respawn_enabled = false
	spawner.remove_after_collection = true
	spawner.navigation_geometry_changed.connect(navigation_geometry_changed.emit)
	add_child(spawner)
	spawner.global_position = world_position
	return spawner

func _passes_drop_chance(roll: float) -> bool:
	if drop_chance <= 0.0:
		return false
	if drop_chance >= 1.0:
		return true
	return roll < drop_chance
