extends Resource
class_name DeathEventGroupDefinition

const DEATH_EVENT_DEFINITION_SCRIPT = preload("res://scripts/gameplay/map/death_event_definition.gd")

@export var group_id: StringName
@export_range(0, 10000, 1) var trigger_chance_per_10000 := 0
@export var events: Array[DeathEventDefinition] = []

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if group_id.is_empty():
		errors.append("group_id is required")
	if trigger_chance_per_10000 < 0 or trigger_chance_per_10000 > 10000:
		errors.append("trigger_chance_per_10000 must be between 0 and 10000")
	if events.is_empty():
		errors.append("events must not be empty")
	var total_weight := 0
	for index in events.size():
		var event := events[index]
		if event == null:
			errors.append("events[%d] is required" % index)
			continue
		total_weight += event.weight
		errors.append_array(event.validate_configuration())
	if total_weight > 1000000:
		errors.append("total event weight must not exceed 1000000")
	return errors
