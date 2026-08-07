extends "res://scripts/input/player_input_source.gd"
class_name CompositeInputSource

var sources: Array = []

func _init(value_sources: Array = []) -> void:
	sources = value_sources.duplicate()

func add_source(source) -> void:
	if source != null and not sources.has(source):
		sources.append(source)

func remove_source(source) -> void:
	sources.erase(source)

func sample():
	var merged := PlayerInputStateScript.new()
	for source in sources:
		if source != null:
			merged.merge_from(source.sample())
	return merged

func is_online() -> bool:
	for source in sources:
		if source != null and source.is_online():
			return true
	return false

func reset_edges() -> void:
	for source in sources:
		if source != null:
			source.reset_edges()
