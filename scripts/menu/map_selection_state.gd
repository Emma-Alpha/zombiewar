extends RefCounted
class_name MapSelectionState

var entries: Array[MapCatalogEntry] = []
var selected_index := 0

func set_catalog(catalog: MapCatalog) -> void:
	entries.clear()
	if catalog != null:
		entries.append_array(catalog.sorted_entries())
	selected_index = 0

func move_selection(delta: int) -> void:
	if entries.is_empty():
		selected_index = 0
		return
	selected_index = posmod(selected_index + delta, entries.size())

func selected_entry() -> MapCatalogEntry:
	if selected_index < 0 or selected_index >= entries.size():
		return null
	return entries[selected_index]

func selected_scene_path() -> String:
	var entry := selected_entry()
	if entry == null or entry.entry_scene == null:
		return ""
	return entry.entry_scene.resource_path
