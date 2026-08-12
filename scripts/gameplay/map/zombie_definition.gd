extends Resource
class_name ZombieDefinition

@export var type_id: StringName
@export var display_name := "僵尸"
@export var view_scene: PackedScene
@export_range(1, 100000, 1) var max_health := 50
@export_range(1, 100000, 1) var move_speed_scale_per_10000 := 10000

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if type_id.is_empty():
		errors.append("type_id is required")
	if view_scene == null:
		errors.append("view_scene is required")
	if max_health <= 0:
		errors.append("max_health must be positive")
	if move_speed_scale_per_10000 <= 0:
		errors.append("move_speed_scale_per_10000 must be positive")
	return errors
