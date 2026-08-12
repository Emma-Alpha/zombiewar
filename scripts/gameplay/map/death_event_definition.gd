extends Resource
class_name DeathEventDefinition

const PICKUP_DEFINITION_SCRIPT = preload("res://scripts/gameplay/pickup_definition.gd")

enum EventType { DROP_ITEM, DROP_MATERIAL, ENHANCEMENT }

@export var event_type := EventType.DROP_ITEM
@export_range(1, 1000000, 1) var weight := 1
@export var pickup: PickupDefinition
@export_range(1, 9999, 1) var amount := 1
## DROP_MATERIAL 时用：掉落的材料数。可设 min/max 用 interval，见 material_drop_max。
@export_range(1, 999, 1) var material_drop_min := 1
@export_range(1, 999, 1) var material_drop_max := 1
@export var enhancement_id: StringName

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if weight <= 0:
		errors.append("weight must be positive")
	match event_type:
		EventType.DROP_ITEM:
			if pickup == null:
				errors.append("pickup is required")
			elif pickup.resource_path.is_empty():
				errors.append("pickup must use an external resource")
			if amount <= 0:
				errors.append("amount must be positive")
		EventType.DROP_MATERIAL:
			if material_drop_min < 1 or material_drop_max < material_drop_min:
				errors.append("material_drop range must satisfy 1 <= min <= max")
		EventType.ENHANCEMENT:
			errors.append("enhancement events are not supported")
		_:
			errors.append("event_type is invalid")
	return errors
