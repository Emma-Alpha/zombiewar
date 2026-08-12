extends SceneTree

const PLUGIN_CFG_PATH := "res://addons/map_editor/plugin.cfg"
const PLUGIN_SCRIPT_PATH := "res://addons/map_editor/plugin.gd"
const GIZMO_SCRIPT_PATH := "res://addons/map_editor/gizmos/map_marker_gizmo_plugin.gd"
const DOCK_SCENE_PATH := "res://addons/map_editor/ui/map_editor_dock.tscn"
const DEMO_CONTENT_SCENE_PATH := "res://scenes/maps/demo/DemoMapContent.tscn"
const PREFAB_CATALOG_PATH := "res://resources/maps/catalogs/prefab_catalog.tres"
const MAP_CATALOG_PATH := "res://resources/maps/catalogs/map_catalog.tres"
const BEHAVIOR_VALIDATOR_PATH := "res://tools/validation/validate_map_editor_plugin_behavior.gd"
const CONTRACT_VALIDATOR_PATH := "res://tools/validation/validate_map_editor_plugin_contract.gd"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	_validate_controlled_mutation(failures)

	var plugin_cfg := ConfigFile.new()
	_expect(plugin_cfg.load(PLUGIN_CFG_PATH) == OK, "plugin cfg loads", failures)
	_expect(plugin_cfg.get_value("plugin", "script", "") == "plugin.gd", "plugin cfg points to plugin script", failures)
	var enabled: PackedStringArray = ProjectSettings.get_setting(
		"editor_plugins/enabled",
		PackedStringArray()
	)
	_expect(enabled.has(PLUGIN_CFG_PATH), "map editor plugin is enabled", failures)

	var plugin_script := load(PLUGIN_SCRIPT_PATH) as GDScript
	var gizmo_script := load(GIZMO_SCRIPT_PATH) as GDScript
	var behavior_validator := load(BEHAVIOR_VALIDATOR_PATH) as GDScript
	var contract_validator := load(CONTRACT_VALIDATOR_PATH) as GDScript
	_expect(plugin_script != null and plugin_script.can_instantiate(), "plugin script loads", failures)
	_expect(gizmo_script != null and gizmo_script.can_instantiate(), "gizmo script loads", failures)
	_expect(behavior_validator != null, "placement behavior validator loads", failures)
	_expect(contract_validator != null, "plugin contract validator loads", failures)
	_validate_plugin_contract_relationship(failures)

	var dock_scene := load(DOCK_SCENE_PATH) as PackedScene
	var demo_scene := load(DEMO_CONTENT_SCENE_PATH) as PackedScene
	var prefab_catalog := load(PREFAB_CATALOG_PATH) as PrefabCatalog
	var map_catalog := load(MAP_CATALOG_PATH) as MapCatalog
	_expect(dock_scene != null, "dock scene loads", failures)
	_expect(demo_scene != null, "demo content scene loads", failures)
	_expect(prefab_catalog != null, "prefab catalog loads", failures)
	_expect(map_catalog != null, "map catalog loads", failures)
	if prefab_catalog != null:
		_validate_prefab_catalog(prefab_catalog, failures)
	if map_catalog != null:
		_validate_map_catalog(map_catalog, failures)

	if dock_scene != null:
		var dock := dock_scene.instantiate() as Control
		_expect(dock != null, "dock instantiates", failures)
		if dock != null:
			root.add_child(dock)
			_expect(dock.has_method("set_prefab_catalog"), "dock exposes catalog setter", failures)
			_expect(dock.has_signal("place_prefab_requested"), "dock exposes placement signal", failures)
			if prefab_catalog != null:
				dock.call("set_prefab_catalog", prefab_catalog)
			dock.queue_free()

	if demo_scene != null:
		var demo_root := demo_scene.instantiate() as MapContentAuthoringRoot
		_expect(demo_root != null, "demo content root uses authoring protocol", failures)
		if demo_root != null:
			var context := MapAuthoringContext.load_from_root(demo_root, MAP_CATALOG_PATH)
			_expect(context.get("error", FAILED) == OK, "demo editor context loads", failures)
			_expect(context.get("definition") is MapDefinition, "demo context exposes map definition", failures)
			_expect(context.get("map_catalog") == map_catalog, "demo context uses map catalog", failures)
			demo_root.free()

	await process_frame
	_finish(failures)


func _validate_controlled_mutation(failures: Array[String]) -> void:
	var missing_entries_catalog := PrefabCatalog.new()
	_expect(
		not _catalog_has_loadable_prefabs(missing_entries_catalog),
		"controlled mutation rejects an empty prefab catalog",
		failures
	)


func _validate_plugin_contract_relationship(failures: Array[String]) -> void:
	var plugin_source := FileAccess.get_file_as_string(PLUGIN_SCRIPT_PATH)
	var gizmo_source := FileAccess.get_file_as_string(GIZMO_SCRIPT_PATH)
	var behavior_source := FileAccess.get_file_as_string(BEHAVIOR_VALIDATOR_PATH)
	var contract_source := FileAccess.get_file_as_string(CONTRACT_VALIDATOR_PATH)
	for required_plugin_api in [
		"func _place_prefab",
		"func _force_map_transform",
		"MapGridSnap.snap_position",
		"MapDefinitionSynchronizer.synchronize",
	]:
		_expect(plugin_source.contains(required_plugin_api), "plugin placement API %s" % required_plugin_api, failures)
	_expect(
		gizmo_source.contains("PlaceItemGrid.collision_object_world_aabb"),
		"gizmo uses runtime AABB contract",
		failures
	)
	_expect(
		behavior_source.contains("_place_prefab")
		and behavior_source.contains("_force_map_transform")
		and behavior_source.contains("collision_object_world_aabb"),
		"behavior validator exercises placement and AABB contracts",
		failures
	)
	_expect(
		contract_source.contains("MapGridSnap.snap_position")
		and contract_source.contains("PlaceItemGrid.collision_object_world_aabb"),
		"contract validator protects placement and AABB interfaces",
		failures
	)


func _validate_prefab_catalog(catalog: PrefabCatalog, failures: Array[String]) -> void:
	_expect(_catalog_has_loadable_prefabs(catalog), "prefab catalog has loadable entries", failures)
	for entry in catalog.entries:
		if entry == null or entry.scene == null:
			continue
		var instance := entry.scene.instantiate() as Node3D
		_expect(instance != null, "prefab %s instantiates as Node3D" % entry.prefab_id, failures)
		if instance != null:
			instance.free()


func _catalog_has_loadable_prefabs(catalog: PrefabCatalog) -> bool:
	if catalog == null or catalog.entries.is_empty():
		return false
	for entry in catalog.entries:
		if entry == null or entry.prefab_id.is_empty() or entry.scene == null:
			return false
	return true


func _validate_map_catalog(catalog: MapCatalog, failures: Array[String]) -> void:
	_expect(not catalog.entries.is_empty(), "map catalog has entries", failures)
	if catalog.entries.is_empty():
		return
	var demo_entry := catalog.entries[0]
	_expect(demo_entry.map_id == &"demo", "map catalog retains demo entry", failures)
	_expect(demo_entry.entry_scene != null, "demo catalog entry has runtime scene", failures)
	if demo_entry.entry_scene != null:
		var map_root := demo_entry.entry_scene.instantiate()
		_expect(map_root != null, "demo runtime scene instantiates", failures)
		if map_root != null:
			map_root.free()


func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_editor_integration: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
