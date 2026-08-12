extends Resource
class_name FixedItemSpawnDefinition

const PICKUP_DEFINITION_SCRIPT = preload("res://scripts/gameplay/pickup_definition.gd")

@export var spawn_id: StringName
@export var position_xz := Vector2.ZERO
@export var pickup: PickupDefinition
@export_range(1, 9999, 1) var amount := 1
@export_range(0, 1000000, 1) var respawn_delay_ticks := 60

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if spawn_id.is_empty():
		errors.append("spawn_id is required")
	if pickup == null:
		errors.append("pickup is required")
	elif pickup.resource_path.is_empty():
		errors.append("pickup must use an external resource")
	if amount <= 0:
		errors.append("amount must be positive")
	if respawn_delay_ticks < 0:
		errors.append("respawn_delay_ticks cannot be negative")
	return errors
