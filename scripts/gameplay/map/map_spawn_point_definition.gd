extends Resource
class_name MapSpawnPointDefinition

@export var spawn_id: StringName
@export var position_xz := Vector2.ZERO
@export_range(0.0, 8.0, 0.05) var spawn_radius := 1.75
@export_range(0.0, 4.0, 0.05) var minimum_spacing := 1.1

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if spawn_id.is_empty():
		errors.append("spawn_id is required")
	if spawn_radius < 0.0:
		errors.append("spawn_radius cannot be negative")
	if minimum_spacing < 0.0:
		errors.append("minimum_spacing cannot be negative")
	return errors
