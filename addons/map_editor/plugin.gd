@tool
extends EditorPlugin

const DOCK_SCENE := preload("res://addons/map_editor/ui/map_editor_dock.tscn")
const GIZMO_PLUGIN_SCRIPT := preload(
	"res://addons/map_editor/gizmos/map_marker_gizmo_plugin.gd"
)
const PLAYER_MARKER_SCRIPT := preload(
	"res://scripts/gameplay/map/authoring/map_player_spawn_marker.gd"
)
const ZOMBIE_MARKER_SCRIPT := preload(
	"res://scripts/gameplay/map/authoring/map_zombie_spawn_marker.gd"
)
const FIXED_ITEM_MARKER_SCRIPT := preload(
	"res://scripts/gameplay/map/authoring/map_fixed_item_spawn_marker.gd"
)
const MAP_EDITOR_ICON := preload("res://addons/map_editor/icons/map_editor.svg")
const PLAYER_SPAWN_ICON := preload("res://addons/map_editor/icons/player_spawn.svg")
const ZOMBIE_SPAWN_ICON := preload("res://addons/map_editor/icons/zombie_spawn.svg")
const FIXED_ITEM_SPAWN_ICON := preload(
	"res://addons/map_editor/icons/fixed_item_spawn.svg"
)

const MAP_CATALOG_PATH := "res://resources/maps/catalogs/map_catalog.tres"
const PREFAB_CATALOG_PATH := "res://resources/maps/catalogs/prefab_catalog.tres"
const CONTENT_SCENE_ROOT := "res://scenes/maps"
const DEFINITION_RESOURCE_ROOT := "res://resources/maps"
const EMPTY_CONTEXT_MESSAGE := "打开采用 MapContentAuthoringRoot 的内容场景以开始编辑"
const MANAGED_META := &"map_editor_managed"
const GROUND_PLANE := Plane(Vector3.UP, 0.0)

var _dock: Control
var _gizmo_plugin: EditorNode3DGizmoPlugin
var _content_root: MapContentAuthoringRoot
var _definition: MapDefinition
var _definition_path := ""
var _map_catalog: MapCatalog
var _prefab_catalog: PrefabCatalog
var _pending_prefab: PrefabCatalogEntry
var _preview_world_position := Vector3.ZERO
var _has_preview_world_position := false
var _pending_open_scene_path := ""


func _enter_tree() -> void:
	_dock = DOCK_SCENE.instantiate() as Control
	add_control_to_dock(DOCK_SLOT_LEFT_UL, _dock)

	add_custom_type(
		"MapPlayerSpawnMarker",
		"Node3D",
		PLAYER_MARKER_SCRIPT,
		PLAYER_SPAWN_ICON
	)
	add_custom_type(
		"MapZombieSpawnMarker",
		"Node3D",
		ZOMBIE_MARKER_SCRIPT,
		ZOMBIE_SPAWN_ICON
	)
	add_custom_type(
		"MapFixedItemSpawnMarker",
		"Node3D",
		FIXED_ITEM_MARKER_SCRIPT,
		FIXED_ITEM_SPAWN_ICON
	)

	_gizmo_plugin = GIZMO_PLUGIN_SCRIPT.new() as EditorNode3DGizmoPlugin
	add_node_3d_gizmo_plugin(_gizmo_plugin)

	scene_changed.connect(_on_scene_changed)
	var selection := EditorInterface.get_selection()
	selection.selection_changed.connect(_on_selection_changed)
	_dock.connect("create_map_requested", _on_create_map_requested)
	_dock.connect("open_scene_requested", _on_open_scene_requested)
	_dock.connect("place_prefab_requested", _on_place_prefab_requested)
	_dock.connect("save_requested", _save_current_map)

	_prefab_catalog = load(PREFAB_CATALOG_PATH) as PrefabCatalog
	_map_catalog = load(MAP_CATALOG_PATH) as MapCatalog
	_dock.call("set_prefab_catalog", _prefab_catalog)
	call_deferred("_load_current_scene_context")
	set_process(true)


func _exit_tree() -> void:
	set_process(false)
	_cancel_prefab_placement()
	var resource_filesystem := EditorInterface.get_resource_filesystem()
	if (
		resource_filesystem != null
		and resource_filesystem.filesystem_changed.is_connected(
			_on_filesystem_changed_for_new_map
		)
	):
		resource_filesystem.filesystem_changed.disconnect(
			_on_filesystem_changed_for_new_map
		)
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	var selection := EditorInterface.get_selection()
	if (
		selection != null
		and selection.selection_changed.is_connected(_on_selection_changed)
	):
		selection.selection_changed.disconnect(_on_selection_changed)
	if _dock != null:
		_disconnect_dock_signal("create_map_requested", _on_create_map_requested)
		_disconnect_dock_signal("open_scene_requested", _on_open_scene_requested)
		_disconnect_dock_signal("place_prefab_requested", _on_place_prefab_requested)
		_disconnect_dock_signal("save_requested", _save_current_map)
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	if _gizmo_plugin != null:
		remove_node_3d_gizmo_plugin(_gizmo_plugin)
		_gizmo_plugin = null
	remove_custom_type("MapFixedItemSpawnMarker")
	remove_custom_type("MapZombieSpawnMarker")
	remove_custom_type("MapPlayerSpawnMarker")
	_clear_context()


func _load_current_scene_context() -> void:
	_on_scene_changed(EditorInterface.get_edited_scene_root())


func _on_scene_changed(root: Node) -> void:
	_cancel_prefab_placement()
	_clear_context()
	var node_3d := root as Node3D
	if node_3d == null:
		_show_empty_context()
		return
	var context := MapAuthoringContext.load_from_root(node_3d, MAP_CATALOG_PATH)
	if int(context.get("error", ERR_INVALID_DATA)) != OK:
		_show_empty_context()
		return
	_content_root = node_3d as MapContentAuthoringRoot
	_definition = context.get("definition") as MapDefinition
	_definition_path = String(context.get("definition_path", ""))
	_map_catalog = context.get("map_catalog") as MapCatalog
	_dock.call("set_context", context)


func _clear_context() -> void:
	_content_root = null
	_definition = null
	_definition_path = ""


func _show_empty_context() -> void:
	if _dock == null:
		return
	_dock.call("set_context", {})
	_dock.call("set_status", EMPTY_CONTEXT_MESSAGE)


func _on_place_prefab_requested(entry: PrefabCatalogEntry) -> void:
	if _content_root == null or _definition == null:
		_dock.call("set_status", EMPTY_CONTEXT_MESSAGE, true)
		return
	if entry == null or not _prefab_catalog_contains(entry):
		_dock.call("set_status", "只能放置预制件目录中的条目", true)
		return
	_pending_prefab = entry
	_has_preview_world_position = false
	_dock.call("set_status", "单击 3D 视口放置；右键或 Escape 取消")


func _forward_3d_gui_input(
	camera: Camera3D,
	event: InputEvent
) -> int:
	var drag_entry := _dragged_prefab_entry(camera)
	if _pending_prefab == null and drag_entry == null:
		return AFTER_GUI_INPUT_PASS
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and key_event.keycode == KEY_ESCAPE:
			_cancel_prefab_placement()
			return AFTER_GUI_INPUT_STOP
		return AFTER_GUI_INPUT_PASS
	if event is InputEventMouse:
		_update_preview_position(camera, (event as InputEventMouse).position)
	if not event is InputEventMouseButton:
		return AFTER_GUI_INPUT_PASS
	var mouse_button := event as InputEventMouseButton
	if mouse_button.button_index == MOUSE_BUTTON_RIGHT and mouse_button.pressed:
		_cancel_prefab_placement()
		return AFTER_GUI_INPUT_STOP
	if mouse_button.button_index != MOUSE_BUTTON_LEFT:
		return AFTER_GUI_INPUT_PASS
	if not _has_preview_world_position:
		return AFTER_GUI_INPUT_PASS
	if mouse_button.pressed and _pending_prefab != null:
		_place_prefab(_pending_prefab, _preview_world_position)
		_cancel_prefab_placement(false)
		return AFTER_GUI_INPUT_STOP
	if not mouse_button.pressed:
		drag_entry = _dragged_prefab_entry(camera)
		if drag_entry != null:
			_place_prefab(drag_entry, _preview_world_position)
			_cancel_prefab_placement(false)
			return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


func _update_preview_position(camera: Camera3D, screen_position: Vector2) -> void:
	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_direction := camera.project_ray_normal(screen_position)
	var intersection = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if intersection == null:
		_has_preview_world_position = false
		return
	_preview_world_position = MapGridSnap.snap_position(intersection, _definition)
	_has_preview_world_position = true


func _dragged_prefab_entry(camera: Camera3D) -> PrefabCatalogEntry:
	if camera == null or camera.get_viewport() == null:
		return null
	var drag_data = camera.get_viewport().gui_get_drag_data()
	if not drag_data is Dictionary:
		return null
	var entry := (drag_data as Dictionary).get("prefab_entry") as PrefabCatalogEntry
	return entry if _prefab_catalog_contains(entry) else null


func _prefab_catalog_contains(entry: PrefabCatalogEntry) -> bool:
	return (
		entry != null
		and _prefab_catalog != null
		and _prefab_catalog.entries.has(entry)
		and entry.scene != null
	)


func _cancel_prefab_placement(show_status: bool = true) -> void:
	var was_placing := _pending_prefab != null
	_pending_prefab = null
	_has_preview_world_position = false
	if show_status and was_placing and _dock != null:
		_dock.call("set_status", "已取消放置")


func _place_prefab(
	entry: PrefabCatalogEntry,
	world_position: Vector3
) -> Node3D:
	if (
		_content_root == null
		or _definition == null
		or not _prefab_catalog_contains(entry)
	):
		return null
	var props_root := _content_root.get_node_or_null("Props") as Node3D
	if props_root == null:
		_dock.call("set_status", "地图内容场景缺少 Props 节点", true)
		return null
	var instance := entry.scene.instantiate() as Node3D
	if instance == null:
		_dock.call("set_status", "预制件根节点必须是 Node3D", true)
		return null
	instance.set_meta(MANAGED_META, true)
	instance.position = MapGridSnap.snap_position(world_position, _definition)
	instance.rotation = Vector3.ZERO
	props_root.add_child(instance)
	instance.owner = _content_root
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(instance)
	EditorInterface.mark_scene_as_unsaved()
	_content_root.notify_property_list_changed()
	instance.update_gizmos()
	_dock.call("set_status", "已放置：%s" % entry.display_name)
	return instance

func _process(_delta: float) -> void:
	if _definition == null:
		return
	for selected_node in EditorInterface.get_selection().get_selected_nodes():
		var node_3d := selected_node as Node3D
		if node_3d == null or not _is_transform_managed(node_3d):
			continue
		if _force_map_transform(node_3d):
			EditorInterface.mark_scene_as_unsaved()
			node_3d.update_gizmos()


func _is_transform_managed(node: Node3D) -> bool:
	return (
		node is MapPlayerSpawnMarker
		or node is MapZombieSpawnMarker
		or node is MapFixedItemSpawnMarker
		or node.has_meta(MANAGED_META)
	)


func _force_map_transform(node: Node3D) -> bool:
	var snapped := MapGridSnap.snap_position(node.position, _definition)
	var y_rotation := node.rotation.y
	var normalized_rotation := Vector3(0.0, y_rotation, 0.0)
	var changed := not node.position.is_equal_approx(snapped)
	changed = changed or not node.rotation.is_equal_approx(normalized_rotation)
	if changed:
		node.position = snapped
		node.rotation = normalized_rotation
	return changed


func _force_all_map_transforms() -> void:
	if _content_root == null or _definition == null:
		return
	for candidate in _content_root.find_children("*", "Node3D", true, false):
		var node_3d := candidate as Node3D
		if node_3d != null and _is_transform_managed(node_3d):
			_force_map_transform(node_3d)


func _save_current_map() -> void:
	if _content_root == null or _definition == null or _map_catalog == null:
		_dock.call("set_status", EMPTY_CONTEXT_MESSAGE, true)
		return
	_force_all_map_transforms()
	MapTemplateBuilder.resize_managed_geometry(_content_root, _definition)
	MapDefinitionSynchronizer.synchronize(_content_root, _definition)
	var scene_error := EditorInterface.save_scene()
	if scene_error != OK:
		_dock.call("set_status", "内容场景保存失败：%s" % scene_error, true)
		return
	var definition_error := ResourceSaver.save(_definition, _definition_path)
	if definition_error != OK:
		_dock.call("set_status", "地图定义保存失败：%s" % definition_error, true)
		return
	var catalog_error := ResourceSaver.save(_map_catalog, MAP_CATALOG_PATH)
	if catalog_error != OK:
		_dock.call("set_status", "地图目录保存失败：%s" % catalog_error, true)
		return
	EditorInterface.get_resource_filesystem().scan_sources()
	_dock.call("set_status", "地图已保存")


func _on_create_map_requested(request: Dictionary) -> void:
	var production_request := request.duplicate(true)
	production_request["scene_maps_root"] = CONTENT_SCENE_ROOT
	production_request["resource_maps_root"] = DEFINITION_RESOURCE_ROOT
	production_request["map_catalog_path"] = MAP_CATALOG_PATH
	var result := MapTemplateBuilder.create_map(production_request)
	if int(result.get("error", ERR_CANT_CREATE)) != OK:
		_dock.call("set_status", String(result.get("message", "地图创建失败")), true)
		return
	_pending_open_scene_path = String(result.get("content_scene_path", ""))
	var resource_filesystem := EditorInterface.get_resource_filesystem()
	if not resource_filesystem.filesystem_changed.is_connected(
		_on_filesystem_changed_for_new_map
	):
		resource_filesystem.filesystem_changed.connect(
			_on_filesystem_changed_for_new_map,
			CONNECT_ONE_SHOT
		)
	resource_filesystem.scan()
	_dock.call("set_status", "地图已创建，正在导入内容场景")


func _on_filesystem_changed_for_new_map() -> void:
	if _pending_open_scene_path.is_empty():
		return
	var scene_path := _pending_open_scene_path
	_pending_open_scene_path = ""
	EditorInterface.open_scene_from_path(scene_path)


func _on_open_scene_requested(path: String) -> void:
	if path.is_empty():
		return
	EditorInterface.open_scene_from_path(path)


func _on_selection_changed() -> void:
	for selected_node in EditorInterface.get_selection().get_selected_nodes():
		if selected_node is Node3D:
			(selected_node as Node3D).update_gizmos()


func _disconnect_dock_signal(signal_name: StringName, callable: Callable) -> void:
	if _dock.is_connected(signal_name, callable):
		_dock.disconnect(signal_name, callable)
