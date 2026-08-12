extends RefCounted
class_name MapTemplateBuilder

const MAP_DEFINITION_SYNCHRONIZER = preload(
	"res://addons/map_editor/core/map_definition_synchronizer.gd"
)
const NORMAL_ZOMBIE_PATH := "res://resources/zombies/normal_zombie.tres"
const MAP_ID_PATTERN := "^[a-z][a-z0-9_]*$"


static func create_map(request: Dictionary) -> Dictionary:
	var map_id := String(request.get("map_id", &""))
	var map_id_regex := RegEx.new()
	map_id_regex.compile(MAP_ID_PATTERN)
	if map_id_regex.search(map_id) == null:
		return {
			"error": ERR_INVALID_PARAMETER,
			"message": "地图 ID 只允许小写字母、数字和下划线，且必须以字母开头",
		}

	var root_name := _pascal_case(map_id)
	var scene_directory := String(request.get("scene_maps_root", "")).path_join(map_id)
	var resource_directory := String(request.get("resource_maps_root", "")).path_join(map_id)
	var entry_scene_path := scene_directory.path_join("%sMap.tscn" % root_name)
	var content_scene_path := scene_directory.path_join("%sMapContent.tscn" % root_name)
	var definition_path := resource_directory.path_join("%s_map.tres" % map_id)
	var target_paths := [entry_scene_path, content_scene_path, definition_path]
	for target_path in target_paths:
		if (
			FileAccess.file_exists(target_path)
			or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(target_path))
			or ResourceLoader.exists(target_path)
		):
			return {
				"error": ERR_ALREADY_EXISTS,
				"message": "目标文件已存在，不会覆盖：%s" % target_path,
			}

	var created_paths: Array[String] = []
	var error := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(scene_directory)
	)
	if error != OK:
		return _failure(error, "无法创建场景目录 %s" % scene_directory, created_paths)
	error = DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(resource_directory)
	)
	if error != OK:
		return _failure(error, "无法创建资源目录 %s" % resource_directory, created_paths)

	var definition := MapDefinition.new()
	definition.map_id = StringName(map_id)
	definition.display_name = String(request.get("display_name", "地图"))
	definition.grid_width = int(request.get("grid_width", 1))
	definition.grid_height = int(request.get("grid_height", 1))
	definition.grid_cell_size = float(request.get("grid_cell_size", 1.0))
	definition.end_mode = MapDefinition.EndMode.COMPLETE
	var world_width := float(definition.grid_width) * definition.grid_cell_size
	var world_height := float(definition.grid_height) * definition.grid_cell_size
	definition.grid_origin = Vector2(-world_width * 0.5, -world_height * 0.5)
	definition.camera_bounds = Rect2(
		Vector2(-world_width * 0.5, -world_height * 0.5),
		Vector2(world_width, world_height)
	)

	var content_root := _create_content_root(root_name, definition_path)
	resize_managed_geometry(content_root, definition)
	_add_default_markers(content_root, definition)
	MAP_DEFINITION_SYNCHRONIZER.synchronize(content_root, definition)

	var normal_zombie := load(NORMAL_ZOMBIE_PATH) as ZombieDefinition
	if normal_zombie == null:
		content_root.free()
		return _failure(
			ERR_FILE_NOT_FOUND,
			"无法加载普通僵尸资源 %s" % NORMAL_ZOMBIE_PATH,
			created_paths
		)
	var zombie_entry := WaveZombieEntryDefinition.new()
	zombie_entry.zombie = normal_zombie
	zombie_entry.count = 20
	var wave := MapWaveDefinition.new()
	wave.spawn_interval_ticks = 1
	wave.zombie_entries = [zombie_entry]
	definition.waves = [wave]

	error = ResourceSaver.save(definition, definition_path)
	if error != OK:
		content_root.free()
		return _failure(error, "无法保存地图定义 %s" % definition_path, created_paths)
	created_paths.append(definition_path)

	_set_descendant_owners(content_root, content_root)
	var content_scene := PackedScene.new()
	error = content_scene.pack(content_root)
	content_root.free()
	if error != OK:
		return _failure(error, "无法打包内容场景 %s" % content_scene_path, created_paths)
	error = ResourceSaver.save(content_scene, content_scene_path)
	if error != OK:
		return _failure(error, "无法保存内容场景 %s" % content_scene_path, created_paths)
	created_paths.append(content_scene_path)

	var saved_content_scene := load(content_scene_path) as PackedScene
	if saved_content_scene == null:
		return _failure(
			ERR_FILE_CANT_OPEN,
			"无法重新加载内容场景 %s" % content_scene_path,
			created_paths
		)
	definition.content_scene = saved_content_scene
	error = ResourceSaver.save(definition, definition_path)
	if error != OK:
		return _failure(error, "无法更新地图定义 %s" % definition_path, created_paths)

	var entry_file := FileAccess.open(entry_scene_path, FileAccess.WRITE)
	if entry_file == null:
		return _failure(
			FileAccess.get_open_error(),
			"无法写入入口场景 %s" % entry_scene_path,
			created_paths
		)
	entry_file.store_string(_entry_scene_text(root_name, definition_path))
	entry_file.close()
	created_paths.append(entry_scene_path)

	var saved_entry_scene := load(entry_scene_path) as PackedScene
	if saved_entry_scene == null:
		return _failure(
			ERR_FILE_CANT_OPEN,
			"无法加载入口场景 %s" % entry_scene_path,
			created_paths
		)
	var map_catalog_path := String(request.get("map_catalog_path", ""))
	var catalog := load(map_catalog_path) as MapCatalog
	if catalog == null:
		return _failure(
			ERR_FILE_NOT_FOUND,
			"无法加载地图目录 %s" % map_catalog_path,
			created_paths
		)
	var maximum_sort_order := 0
	if not catalog.entries.is_empty():
		maximum_sort_order = catalog.entries[0].sort_order
		for existing_entry in catalog.entries:
			maximum_sort_order = maxi(maximum_sort_order, existing_entry.sort_order)
	var catalog_entry := MapCatalogEntry.new()
	catalog_entry.map_id = StringName(map_id)
	catalog_entry.entry_scene = saved_entry_scene
	catalog_entry.display_name = definition.display_name
	catalog_entry.sort_order = maximum_sort_order + 10
	catalog.entries.append(catalog_entry)
	error = ResourceSaver.save(catalog, map_catalog_path)
	if error != OK:
		return _failure(error, "无法保存地图目录 %s" % map_catalog_path, created_paths)

	return {
		"error": OK,
		"entry_scene_path": entry_scene_path,
		"content_scene_path": content_scene_path,
		"definition_path": definition_path,
	}


static func resize_managed_geometry(
	root: MapContentAuthoringRoot,
	definition: MapDefinition
) -> void:
	if not root.managed_template_geometry:
		return
	var world_width := float(definition.grid_width) * definition.grid_cell_size
	var world_height := float(definition.grid_height) * definition.grid_cell_size
	_set_box_geometry(
		root.get_node_or_null("Ground") as StaticBody3D,
		Vector3(world_width, 0.3, world_height),
		Vector3(0.0, -0.15, 0.0)
	)
	_set_boundary_geometry(
		root,
		"North",
		Vector3(world_width, 2.0, 0.5),
		Vector3(0.0, 1.0, -(world_height * 0.5 - 0.25))
	)
	_set_boundary_geometry(
		root,
		"South",
		Vector3(world_width, 2.0, 0.5),
		Vector3(0.0, 1.0, world_height * 0.5 - 0.25)
	)
	_set_boundary_geometry(
		root,
		"West",
		Vector3(0.5, 2.0, world_height),
		Vector3(-(world_width * 0.5 - 0.25), 1.0, 0.0)
	)
	_set_boundary_geometry(
		root,
		"East",
		Vector3(0.5, 2.0, world_height),
		Vector3(world_width * 0.5 - 0.25, 1.0, 0.0)
	)


static func _create_content_root(
	root_name: String,
	definition_path: String
) -> MapContentAuthoringRoot:
	var root := MapContentAuthoringRoot.new()
	root.name = "%sMapContent" % root_name
	root.map_definition_path = definition_path
	root.managed_template_geometry = true

	var environment_root := Node3D.new()
	environment_root.name = "Environment"
	root.add_child(environment_root)
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = Environment.new()
	environment_root.add_child(world_environment)
	var light := DirectionalLight3D.new()
	light.name = "DirectionalLight3D"
	light.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	light.shadow_enabled = true
	environment_root.add_child(light)

	var ground := _create_box_body("Ground", false)
	ground.add_to_group(&"blood_surface", true)
	root.add_child(ground)
	var boundaries := Node3D.new()
	boundaries.name = "Boundaries"
	root.add_child(boundaries)
	for boundary_name in ["North", "South", "West", "East"]:
		boundaries.add_child(_create_box_body(boundary_name, true))
	var props := Node3D.new()
	props.name = "Props"
	root.add_child(props)
	var markers := Node3D.new()
	markers.name = "MapMarkers"
	root.add_child(markers)
	for marker_root_name in ["PlayerSpawns", "ZombieSpawns", "FixedItemSpawns"]:
		var marker_root := Node3D.new()
		marker_root.name = marker_root_name
		markers.add_child(marker_root)
	return root


static func _create_box_body(node_name: String, obstacle: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = 1
	body.collision_mask = 0
	if obstacle:
		body.add_to_group(&"place_item_obstacle", true)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "MeshInstance3D"
	mesh_instance.mesh = BoxMesh.new()
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	collision.shape = BoxShape3D.new()
	body.add_child(collision)
	return body


static func _add_default_markers(
	root: MapContentAuthoringRoot,
	definition: MapDefinition
) -> void:
	var cell_size := definition.grid_cell_size
	var player_positions := [
		Vector3(-cell_size, 0.0, -cell_size),
		Vector3(cell_size, 0.0, -cell_size),
		Vector3(-cell_size, 0.0, cell_size),
		Vector3(cell_size, 0.0, cell_size),
	]
	var player_root := root.get_node("MapMarkers/PlayerSpawns")
	for index in player_positions.size():
		var marker := MapPlayerSpawnMarker.new()
		marker.name = "Player%02d" % (index + 1)
		marker.marker_id = StringName("player_%02d" % (index + 1))
		marker.slot_index = index
		marker.position = player_positions[index]
		player_root.add_child(marker)

	var inset := 2.0 * cell_size
	var half_width := float(definition.grid_width) * cell_size * 0.5
	var half_height := float(definition.grid_height) * cell_size * 0.5
	var zombie_data := [
		["NorthWest", &"01_north_west", Vector3(-half_width + inset, 0.0, -half_height + inset)],
		["NorthEast", &"02_north_east", Vector3(half_width - inset, 0.0, -half_height + inset)],
		["SouthWest", &"03_south_west", Vector3(-half_width + inset, 0.0, half_height - inset)],
		["SouthEast", &"04_south_east", Vector3(half_width - inset, 0.0, half_height - inset)],
	]
	var zombie_root := root.get_node("MapMarkers/ZombieSpawns")
	for values in zombie_data:
		var marker := MapZombieSpawnMarker.new()
		marker.name = values[0]
		marker.spawn_id = values[1]
		marker.position = values[2]
		zombie_root.add_child(marker)


static func _set_boundary_geometry(
	root: MapContentAuthoringRoot,
	boundary_name: String,
	size: Vector3,
	position: Vector3
) -> void:
	var boundary := root.get_node_or_null("Boundaries/%s" % boundary_name) as StaticBody3D
	if boundary == null:
		return
	boundary.position = position
	_set_box_geometry(boundary, size, Vector3.ZERO)


static func _set_box_geometry(
	body: StaticBody3D,
	size: Vector3,
	child_position: Vector3
) -> void:
	if body == null:
		return
	var mesh_instance := body.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh is BoxMesh:
		mesh_instance.mesh.size = size
		mesh_instance.position = child_position
	var collision := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision != null and collision.shape is BoxShape3D:
		collision.shape.size = size
		collision.position = child_position


static func _set_descendant_owners(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_set_descendant_owners(child, owner)


static func _pascal_case(map_id: String) -> String:
	var result := ""
	for part in map_id.split("_", false):
		result += part.capitalize()
	return result


static func _failure(
	error: Error,
	message: String,
	created_paths: Array[String]
) -> Dictionary:
	if not created_paths.is_empty():
		message += "；已创建：%s" % ", ".join(created_paths)
	return {"error": error, "message": message}


static func _entry_scene_text(
	root_name: String,
	definition_path: String
) -> String:
	return """[gd_scene load_steps=3 format=3]

[ext_resource type="PackedScene" path="res://scenes/gameplay/GameplayArena.tscn" id="1_arena"]
[ext_resource type="Resource" path="%s" id="2_definition"]

[node name="%sMap" instance=ExtResource("1_arena")]
map_definition = ExtResource("2_definition")
""" % [definition_path, root_name]
