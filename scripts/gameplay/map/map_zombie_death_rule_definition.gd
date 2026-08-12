extends Resource
class_name MapZombieDeathRuleDefinition

const ZOMBIE_DEFINITION_SCRIPT = preload("res://scripts/gameplay/map/zombie_definition.gd")
const DEATH_EVENT_GROUP_DEFINITION_SCRIPT = preload("res://scripts/gameplay/map/death_event_group_definition.gd")

@export var zombie: ZombieDefinition
@export var groups: Array[DeathEventGroupDefinition] = []

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if zombie == null:
		errors.append("zombie is required")
	else:
		errors.append_array(zombie.validate_configuration())
	if groups.is_empty():
		errors.append("groups must not be empty")
	var group_ids: Dictionary[StringName, bool] = {}
	for index in groups.size():
		var group := groups[index]
		if group == null:
			errors.append("groups[%d] is required" % index)
			continue
		if not group.group_id.is_empty():
			if group_ids.has(group.group_id):
				errors.append("duplicate death event group id: %s" % group.group_id)
			else:
				group_ids[group.group_id] = true
		errors.append_array(group.validate_configuration())
	return errors
