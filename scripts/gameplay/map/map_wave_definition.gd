extends Resource
class_name MapWaveDefinition

const WAVE_ZOMBIE_ENTRY_DEFINITION_SCRIPT = preload("res://scripts/gameplay/map/wave_zombie_entry_definition.gd")

@export_range(0, 1000000, 1) var spawn_interval_ticks := 0
@export var zombie_entries: Array[WaveZombieEntryDefinition] = []

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if spawn_interval_ticks < 0:
		errors.append("spawn_interval_ticks cannot be negative")
	if zombie_entries.is_empty():
		errors.append("zombie_entries must not be empty")
	for index in zombie_entries.size():
		var entry := zombie_entries[index]
		if entry == null:
			errors.append("zombie_entries[%d] is required" % index)
			continue
		errors.append_array(entry.validate_configuration())
	return errors
