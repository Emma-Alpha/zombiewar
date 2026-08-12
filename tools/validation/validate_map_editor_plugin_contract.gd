extends SceneTree

const PLUGIN_CFG := "res://addons/map_editor/plugin.cfg"
const PLUGIN_SCRIPT := "res://addons/map_editor/plugin.gd"
const GIZMO_SCRIPT := "res://addons/map_editor/gizmos/map_marker_gizmo_plugin.gd"


func _init() -> void:
	var failures: Array[String] = []
	var cfg := ConfigFile.new()
	_expect(cfg.load(PLUGIN_CFG) == OK, "plugin cfg loads", failures)
	_expect(cfg.get_value("plugin", "script", "") == "plugin.gd", "plugin script path", failures)
	var enabled: PackedStringArray = ProjectSettings.get_setting(
		"editor_plugins/enabled",
		PackedStringArray()
	)
	_expect(enabled.has(PLUGIN_CFG), "map editor plugin enabled", failures)

	var plugin_script := load(PLUGIN_SCRIPT) as GDScript
	var gizmo_script := load(GIZMO_SCRIPT) as GDScript
	_expect(
		plugin_script != null and plugin_script.can_instantiate(),
		"plugin script instantiates",
		failures
	)
	_expect(
		gizmo_script != null and gizmo_script.can_instantiate(),
		"gizmo script instantiates",
		failures
	)

	var source := FileAccess.get_file_as_string(PLUGIN_SCRIPT)
	for required in [
		"MapGridSnap.snap_position",
		"MapDefinitionSynchronizer.synchronize",
		"MapTemplateBuilder.resize_managed_geometry",
		"EditorInterface.save_scene",
		"ResourceSaver.save",
		"map_editor_managed",
		"instantiate()",
	]:
		_expect(
			source.contains(required),
			"plugin source contains %s" % required,
			failures
		)

	var gizmo_source := FileAccess.get_file_as_string(GIZMO_SCRIPT)
	_expect(
		gizmo_source.contains("PlaceItemGrid.collision_object_world_aabb"),
		"gizmo reuses runtime AABB helper",
		failures
	)
	_finish(failures)


func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_editor_plugin_contract: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(
	condition: bool,
	message: String,
	failures: Array[String]
) -> void:
	if not condition:
		failures.append(message)
