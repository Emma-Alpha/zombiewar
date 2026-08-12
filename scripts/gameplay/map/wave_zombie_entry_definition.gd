extends Resource
class_name WaveZombieEntryDefinition

const ZOMBIE_DEFINITION_SCRIPT = preload("res://scripts/gameplay/map/zombie_definition.gd")

@export var zombie: ZombieDefinition
@export_range(1, 10000, 1) var count := 1

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if zombie == null:
		errors.append("zombie is required")
	else:
		errors.append_array(zombie.validate_configuration())
	if count <= 0:
		errors.append("count must be positive")
	return errors
