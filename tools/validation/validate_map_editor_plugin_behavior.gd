extends SceneTree

const PLUGIN_SCRIPT := preload("res://addons/map_editor/plugin.gd")
const GIZMO_SCRIPT := preload(
	"res://addons/map_editor/gizmos/map_marker_gizmo_plugin.gd"
)
const DOCK_SCENE := preload("res://addons/map_editor/ui/map_editor_dock.tscn")
const DEFINITION_PATH := "res://resources/maps/demo/demo_map.tres"
const PREFAB_CATALOG_PATH := "res://resources/maps/catalogs/prefab_catalog.tres"
const FIXTURE_SCENE_PATH := "user://map_editor_plugin_behavior_fixture.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	_remove_fixture_scene()
	var content_root := MapContentAuthoringRoot.new()
	content_root.name = "BehaviorFixture"
	var props := Node3D.new()
	props.name = "Props"
	content_root.add_child(props)
	props.owner = content_root
	root.add_child(content_root)

	var definition := load(DEFINITION_PATH) as MapDefinition
	var prefab_catalog := load(PREFAB_CATALOG_PATH) as PrefabCatalog
	var status_dock := DOCK_SCENE.instantiate() as Control
	root.add_child(status_dock)
	await process_frame
	var plugin = PLUGIN_SCRIPT.new()
	plugin.set("_content_root", content_root)
	plugin.set("_definition", definition)
	plugin.set("_prefab_catalog", prefab_catalog)
	plugin.set("_dock", status_dock)

	var entry := prefab_catalog.entries[0]
	var instance := plugin.call(
		"_place_prefab",
		entry,
		Vector3(1.24, 3.25, -2.26)
	) as Node3D
	_expect(instance != null, "catalog prefab places", failures)
	if instance != null:
		_expect(instance.get_parent() == props, "prefab is added under Props", failures)
		_expect(instance.owner == content_root, "prefab root owner is content root", failures)
		_expect(
			instance.has_meta(&"map_editor_managed")
			and bool(instance.get_meta(&"map_editor_managed")),
			"prefab is marked managed",
			failures
		)
		_expect(
			instance.scene_file_path == entry.scene.resource_path,
			"prefab instance keeps packed-scene association",
			failures
		)
		_expect(
			instance.position.is_equal_approx(Vector3(1.2, 3.25, -2.3)),
			"placement snaps XZ and preserves Y",
			failures
		)
		instance.position = Vector3(1.26, 4.5, -2.24)
		instance.rotation = Vector3(0.4, 0.75, -0.2)
		plugin.call("_force_map_transform", instance)
		_expect(
			instance.position.is_equal_approx(Vector3(1.3, 4.5, -2.2)),
			"managed transform re-snaps XZ and preserves Y",
			failures
		)
		_expect(
			instance.rotation.is_equal_approx(Vector3(0.0, 0.75, 0.0)),
			"managed transform preserves only Y rotation",
			failures
		)
		_validate_saved_prefab_instance(content_root, instance, entry, failures)

		var gizmo_plugin = GIZMO_SCRIPT.new()
		var marker := MapZombieSpawnMarker.new()
		_expect(bool(gizmo_plugin.call("_has_gizmo", content_root)), "authoring root has gizmo", failures)
		_expect(bool(gizmo_plugin.call("_has_gizmo", marker)), "marker has gizmo", failures)
		_expect(
			instance is CollisionObject3D
			and bool(gizmo_plugin.call("_has_gizmo", instance)),
			"managed collision object has gizmo",
			failures
		)
		if instance is CollisionObject3D:
			_expect(
				PlaceItemGrid.collision_object_world_aabb(instance).size != Vector3.ZERO,
				"runtime helper provides managed obstacle bounds",
				failures
			)
		marker.free()
		gizmo_plugin = null

	plugin.free()
	status_dock.queue_free()
	content_root.queue_free()
	await process_frame
	_remove_fixture_scene()
	_finish(failures)


func _validate_saved_prefab_instance(
	content_root: MapContentAuthoringRoot,
	instance: Node3D,
	entry: PrefabCatalogEntry,
	failures: Array[String]
) -> void:
	var source_instance := entry.scene.instantiate() as Node3D
	_expect(source_instance != null, "source prefab instantiates for reload baseline", failures)
	var expected_descendant_count := 0
	if source_instance != null:
		expected_descendant_count = _descendant_count(source_instance)
		source_instance.free()

	var packed_scene := PackedScene.new()
	_expect(packed_scene.pack(content_root) == OK, "placed prefab fixture packs", failures)
	_expect(
		ResourceSaver.save(packed_scene, FIXTURE_SCENE_PATH) == OK,
		"placed prefab fixture saves",
		failures
	)
	var reloaded_scene := ResourceLoader.load(
		FIXTURE_SCENE_PATH,
		"PackedScene",
		ResourceLoader.CACHE_MODE_IGNORE
	) as PackedScene
	_expect(reloaded_scene != null, "placed prefab fixture reloads", failures)
	if reloaded_scene == null:
		return
	var reloaded_root := reloaded_scene.instantiate() as MapContentAuthoringRoot
	_expect(reloaded_root != null, "reloaded fixture instantiates", failures)
	if reloaded_root == null:
		return
	var reloaded_instance := reloaded_root.get_node_or_null(
		NodePath("Props/%s" % instance.name)
	) as Node3D
	_expect(reloaded_instance != null, "reloaded prefab root exists once", failures)
	if reloaded_instance != null:
		_expect(
			reloaded_instance.scene_file_path == entry.scene.resource_path,
			"reloaded prefab keeps packed-scene association",
			failures
		)
		_expect(
			_descendant_count(reloaded_instance) == expected_descendant_count,
			"reloaded prefab internal nodes are not duplicated",
			failures
		)
		_expect(
			reloaded_instance.has_meta(&"map_editor_managed")
			and bool(reloaded_instance.get_meta(&"map_editor_managed")),
			"reloaded prefab keeps managed metadata",
			failures
		)
		_expect(
			reloaded_instance.position.is_equal_approx(Vector3(1.3, 4.5, -2.2))
			and reloaded_instance.rotation.is_equal_approx(Vector3(0.0, 0.75, 0.0)),
			"reloaded prefab keeps snapped transform",
			failures
		)
		for child in reloaded_instance.get_children():
			_expect(
				child.owner == reloaded_instance,
				"reloaded prefab preserves internal owner boundary for %s" % child.name,
				failures
			)
	reloaded_root.free()


func _descendant_count(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		count += 1 + _descendant_count(child)
	return count


func _remove_fixture_scene() -> void:
	var absolute_path := ProjectSettings.globalize_path(FIXTURE_SCENE_PATH)
	if FileAccess.file_exists(absolute_path):
		DirAccess.remove_absolute(absolute_path)


func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_editor_plugin_behavior: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
