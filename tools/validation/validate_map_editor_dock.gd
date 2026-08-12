extends SceneTree

const DOCK_SCENE_PATH := "res://addons/map_editor/ui/map_editor_dock.tscn"
const PREFAB_CATALOG_PATH := "res://resources/maps/catalogs/prefab_catalog.tres"
const MAP_CATALOG_PATH := "res://resources/maps/catalogs/map_catalog.tres"
const DEMO_CONTENT_SCENE_PATH := "res://scenes/maps/demo/DemoMapContent.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	var dock_scene := load(DOCK_SCENE_PATH) as PackedScene
	_expect(dock_scene != null, "dock scene loads", failures)
	if dock_scene == null:
		_finish(failures)
		return
	var dock = dock_scene.instantiate()
	root.add_child(dock)
	await process_frame
	_expect(dock.has_signal("create_map_requested"), "create signal", failures)
	_expect(dock.has_signal("open_scene_requested"), "open signal", failures)
	_expect(dock.has_signal("place_prefab_requested"), "place signal", failures)
	_expect(dock.has_signal("save_requested"), "save signal", failures)
	for path in [
		"Root/Toolbar/NewMapButton",
		"Root/Toolbar/OpenMapButton",
		"Root/Toolbar/SaveMapButton",
		"Root/Workspace/PrefabPanel/SearchEdit",
		"Root/Workspace/PrefabPanel/PrefabTree",
		"Root/Workspace/Details/TabContainer/Map",
		"Root/Workspace/Details/TabContainer/Waves",
		"Root/Workspace/Details/TabContainer/Drops",
		"Root/Workspace/Details/TabContainer/Catalog",
		"Root/StatusLabel",
	]:
		_expect(dock.get_node_or_null(path) != null, "dock node %s" % path, failures)

	var catalog := load(PREFAB_CATALOG_PATH) as PrefabCatalog
	dock.set_prefab_catalog(catalog)
	var tree := dock.get_node("Root/Workspace/PrefabPanel/PrefabTree") as Tree
	_expect(tree.get_root() != null, "prefab tree populated", failures)
	_expect(_leaf_count(tree.get_root()) == catalog.entries.size(), "catalog entries only", failures)
	var first_entry_item := _first_leaf(tree.get_root())
	_expect(
		first_entry_item != null
		and first_entry_item.get_metadata(0) is PrefabCatalogEntry,
		"prefab metadata keeps entry resource",
		failures
	)
	var search_edit := dock.get_node("Root/Workspace/PrefabPanel/SearchEdit") as LineEdit
	search_edit.text = "TRAFFIC BARRIER"
	search_edit.emit_signal("text_changed", search_edit.text)
	_expect(_leaf_count(tree.get_root()) == 1, "tag filtering ignores case", failures)
	search_edit.text = "OBSTACLE"
	search_edit.emit_signal("text_changed", search_edit.text)
	_expect(_leaf_count(tree.get_root()) == 2, "category filtering ignores case", failures)
	search_edit.text = ""
	search_edit.emit_signal("text_changed", search_edit.text)

	var placed_entries: Array[PrefabCatalogEntry] = []
	dock.place_prefab_requested.connect(
		func(entry: PrefabCatalogEntry) -> void: placed_entries.append(entry)
	)
	first_entry_item = _first_leaf(tree.get_root())
	first_entry_item.select(0)
	var drag_data = dock.call("_get_prefab_drag_data", Vector2.ZERO)
	_expect(
		drag_data is Dictionary
		and (drag_data as Dictionary).get("prefab_entry") == first_entry_item.get_metadata(0),
		"prefab drag data carries the selected catalog entry",
		failures
	)
	dock.get_node("Root/Workspace/PrefabPanel/PlaceButton").emit_signal("pressed")
	_expect(placed_entries.size() == 1, "place button emits selected entry", failures)
	tree.emit_signal("item_activated")
	_expect(placed_entries.size() == 2, "double click emits selected entry", failures)

	var create_requests: Array[Dictionary] = []
	dock.create_map_requested.connect(
		func(request: Dictionary) -> void: create_requests.append(request)
	)
	var new_dialog := dock.get_node("NewMapDialog")
	new_dialog.get_node("Fields/MapIdEdit").text = "  test_map  "
	new_dialog.get_node("Fields/DisplayNameEdit").text = "  测试地图  "
	new_dialog.call("_on_confirmed")
	_expect(create_requests.size() == 1, "new map request emitted", failures)
	if create_requests.size() == 1:
		_expect(
			create_requests[0].keys().size() == 5
			and create_requests[0]["map_id"] == &"test_map"
			and create_requests[0]["display_name"] == "测试地图",
			"new map request contains only authored fields",
			failures
		)
	var open_dialog := dock.get_node("OpenMapDialog") as FileDialog
	_expect(open_dialog.filters == PackedStringArray(["*.tscn"]), "open dialog only accepts scenes", failures)

	if Engine.is_editor_hint():
		_validate_resource_editors(dock, failures)

	dock.queue_free()
	await process_frame
	_finish(failures)


func _validate_resource_editors(dock: Control, failures: Array[String]) -> void:
	var content_scene := load(DEMO_CONTENT_SCENE_PATH) as PackedScene
	var content_root := content_scene.instantiate() as MapContentAuthoringRoot
	var context := MapAuthoringContext.load_from_root(content_root, MAP_CATALOG_PATH)
	content_root.free()
	_expect(context.get("error", FAILED) == OK, "standard authoring context loads", failures)
	var definition := context.get("definition") as MapDefinition
	var map_catalog := context.get("map_catalog") as MapCatalog
	dock.set_context(context)
	var map_inspector := dock.get_node("Root/Workspace/Details/TabContainer/Map/MapInspector")
	_expect(
		map_inspector.call("get_edited_object") == definition,
		"map inspector edits definition resource",
		failures
	)

	var original_catalog_entry := map_catalog.entries[0]
	var expected_entry_scene := original_catalog_entry.entry_scene
	var expected_description := original_catalog_entry.description
	var expected_cover := original_catalog_entry.cover
	var expected_sort_order := original_catalog_entry.sort_order
	var original_catalog_count := map_catalog.entries.size()
	dock.call("_remove_catalog_entry")
	_expect(map_catalog.entries.size() == original_catalog_count - 1, "catalog removes current map", failures)
	dock.call("_add_catalog_entry")
	var restored_catalog_entry := map_catalog.entries[-1]
	_expect(
		map_catalog.entries.size() == original_catalog_count
		and restored_catalog_entry is MapCatalogEntry
		and restored_catalog_entry.map_id == definition.map_id
		and restored_catalog_entry.entry_scene == expected_entry_scene
		and restored_catalog_entry.description == expected_description
		and restored_catalog_entry.cover == expected_cover
		and restored_catalog_entry.sort_order == expected_sort_order,
		"catalog re-add preserves the real entry",
		failures
	)

	var wave_list := dock.get_node(
		"Root/Workspace/Details/TabContainer/Waves/WaveSplit/WaveList"
	) as ItemList
	var wave_inspector := dock.get_node(
		"Root/Workspace/Details/TabContainer/Waves/WaveSplit/WaveInspector"
	)
	wave_list.select(0)
	wave_list.emit_signal("item_selected", 0)
	var original_waves: Array[MapWaveDefinition] = []
	original_waves.append_array(definition.waves)
	var no_waves: Array[MapWaveDefinition] = []
	definition.waves = no_waves
	definition.emit_changed()
	_expect(wave_list.item_count == 0, "external wave changes refresh the list", failures)
	_expect(
		wave_inspector.call("get_edited_object") == null,
		"removed wave clears stale inspector",
		failures
	)
	dock.call("_delete_wave")
	dock.call("_move_wave", 1)
	definition.waves = original_waves
	definition.emit_changed()

	var drop_tree := dock.get_node(
		"Root/Workspace/Details/TabContainer/Drops/DropSplit/DropTree"
	) as Tree
	var drop_inspector := dock.get_node(
		"Root/Workspace/Details/TabContainer/Drops/DropSplit/DropInspector"
	)
	var first_rule_item := drop_tree.get_root().get_first_child()
	first_rule_item.select(0)
	drop_tree.emit_signal("item_selected")
	var original_death_rules: Array[MapZombieDeathRuleDefinition] = []
	original_death_rules.append_array(definition.zombie_death_rules)
	var no_death_rules: Array[MapZombieDeathRuleDefinition] = []
	definition.zombie_death_rules = no_death_rules
	definition.emit_changed()
	_expect(
		drop_tree.get_root().get_first_child() == null,
		"external drop changes refresh the tree",
		failures
	)
	_expect(
		drop_inspector.call("get_edited_object") == null,
		"removed drop resource clears stale inspector",
		failures
	)
	dock.call("_delete_drop_resource")
	definition.zombie_death_rules = original_death_rules
	definition.emit_changed()

	var original_wave_count := definition.waves.size()
	dock.call("_add_wave")
	_expect(
		definition.waves.size() == original_wave_count + 1
		and definition.waves[-1] is MapWaveDefinition,
		"wave add creates typed resource",
		failures
	)
	dock.call("_move_wave", -1)
	_expect(
		definition.waves[definition.waves.size() - 2] is MapWaveDefinition,
		"wave move keeps typed resources",
		failures
	)
	dock.call("_delete_wave")
	_expect(definition.waves.size() == original_wave_count, "wave delete changes memory resource", failures)

	dock.call("_add_death_rule")
	var rule := definition.zombie_death_rules[-1]
	_expect(rule is MapZombieDeathRuleDefinition, "drop add creates typed rule", failures)
	dock.call("_add_death_group")
	_expect(rule.groups.size() == 1 and rule.groups[0] is DeathEventGroupDefinition, "drop add creates typed group", failures)
	dock.call("_add_death_event")
	_expect(
		rule.groups[0].events.size() == 1
		and rule.groups[0].events[0] is DeathEventDefinition,
		"drop add creates typed event",
		failures
	)
	dock.call("_delete_drop_resource")
	_expect(rule.groups[0].events.is_empty(), "drop delete changes memory resource", failures)

	var old_definition := definition
	var replacement_context := context.duplicate()
	var replacement_definition := definition.duplicate(true) as MapDefinition
	replacement_context["definition"] = replacement_definition
	dock.set_context(replacement_context)
	var replacement_wave_count := wave_list.item_count
	var old_definition_empty_waves: Array[MapWaveDefinition] = []
	old_definition.waves = old_definition_empty_waves
	old_definition.emit_changed()
	_expect(
		wave_list.item_count == replacement_wave_count,
		"old definition is disconnected after context switch",
		failures
	)



func _leaf_count(item: TreeItem) -> int:
	if item == null:
		return 0
	var count := 0
	var child := item.get_first_child()
	while child != null:
		if child.get_first_child() == null and child.get_metadata(0) is PrefabCatalogEntry:
			count += 1
		else:
			count += _leaf_count(child)
		child = child.get_next()
	return count


func _first_leaf(item: TreeItem) -> TreeItem:
	if item == null:
		return null
	var child := item.get_first_child()
	while child != null:
		if child.get_metadata(0) is PrefabCatalogEntry:
			return child
		var nested := _first_leaf(child)
		if nested != null:
			return nested
		child = child.get_next()
	return null


func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_editor_dock: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
