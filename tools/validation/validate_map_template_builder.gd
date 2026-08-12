extends SceneTree

const BuilderScript = preload(
	"res://addons/map_editor/core/map_template_builder.gd"
)
const ContextScript = preload(
	"res://addons/map_editor/core/map_authoring_context.gd"
)

const FIXTURE_ROOT := "user://map_editor_template_fixture"

func _init() -> void:
	var failures: Array[String] = []
	_remove_fixture()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURE_ROOT))

	var catalog := MapCatalog.new()
	var catalog_path := FIXTURE_ROOT.path_join("map_catalog.tres")
	_expect(ResourceSaver.save(catalog, catalog_path) == OK, "save fixture catalog", failures)

	var result: Dictionary = BuilderScript.create_map({
		"map_id": &"test_yard",
		"display_name": "测试场地",
		"grid_width": 20,
		"grid_height": 12,
		"grid_cell_size": 1.0,
		"scene_maps_root": FIXTURE_ROOT.path_join("scenes"),
		"resource_maps_root": FIXTURE_ROOT.path_join("resources"),
		"map_catalog_path": catalog_path,
	})
	_expect(result.get("error", FAILED) == OK, "template creation succeeds", failures)
	for key in ["entry_scene_path", "content_scene_path", "definition_path"]:
		_expect(ResourceLoader.exists(String(result.get(key, ""))), "%s exists" % key, failures)

	var definition := load(String(result.get("definition_path", ""))) as MapDefinition
	_expect(definition != null, "generated definition loads", failures)
	if definition != null:
		_expect(definition.map_id == &"test_yard", "generated map id", failures)
		_expect(definition.display_name == "测试场地", "generated display name", failures)
		_expect(definition.grid_width == 20 and definition.grid_height == 12, "generated grid size", failures)
		_expect(definition.grid_cell_size == 1.0, "generated cell size", failures)
		_expect(definition.grid_origin == Vector2(-10.0, -6.0), "generated grid origin", failures)
		_expect(
			definition.camera_bounds == Rect2(Vector2(-10.0, -6.0), Vector2(20.0, 12.0)),
			"generated camera bounds",
			failures
		)
		_expect(definition.player_spawn_positions.size() == 4, "default four players", failures)
		_expect(definition.spawn_points.size() == 4, "default four zombie spawns", failures)
		_expect(definition.waves.size() == 1, "default wave", failures)
		_expect(definition.end_mode == MapDefinition.EndMode.COMPLETE, "default complete end mode", failures)
		if definition.waves.size() == 1:
			var wave := definition.waves[0]
			_expect(wave.spawn_interval_ticks == 1, "default wave interval", failures)
			_expect(wave.zombie_entries.size() == 1, "default wave zombie kind", failures)
			if wave.zombie_entries.size() == 1:
				_expect(wave.zombie_entries[0].count == 20, "default wave count", failures)
				_expect(
					wave.zombie_entries[0].zombie != null
						and wave.zombie_entries[0].zombie.resource_path
						== "res://resources/zombies/normal_zombie.tres",
					"default normal zombie",
					failures
				)

	var content := (load(String(result.get("content_scene_path", ""))) as PackedScene).instantiate()
	_expect(content is MapContentAuthoringRoot, "generated authoring root", failures)
	if content is MapContentAuthoringRoot:
		_expect(content.managed_template_geometry, "template geometry is managed", failures)
		_expect(
			content.map_definition_path == String(result.get("definition_path", "")),
			"authoring root definition path",
			failures
		)
		for node_path in [
			"Environment",
			"Environment/WorldEnvironment",
			"Environment/DirectionalLight3D",
			"Ground",
			"Boundaries/North",
			"Boundaries/South",
			"Boundaries/West",
			"Boundaries/East",
			"Props",
			"MapMarkers/PlayerSpawns",
			"MapMarkers/ZombieSpawns",
			"MapMarkers/FixedItemSpawns",
		]:
			_expect(content.get_node_or_null(node_path) != null, "%s structure" % node_path, failures)
		_expect(content.find_children("*", "MapPlayerSpawnMarker").size() == 4, "four player markers", failures)
		_expect(content.find_children("*", "MapZombieSpawnMarker").size() == 4, "four zombie markers", failures)
		_validate_geometry(content, Vector3(20.0, 0.3, 12.0), failures)
		var props_position: Vector3 = content.get_node("Props").position
		var marker_positions := _marker_positions(content)
		if definition != null:
			definition.grid_width = 8
			definition.grid_height = 6
			definition.grid_cell_size = 2.0
			BuilderScript.resize_managed_geometry(content, definition)
			_validate_geometry(content, Vector3(16.0, 0.3, 12.0), failures)
			_expect(content.get_node("Props").position == props_position, "resize preserves Props", failures)
			_expect(_marker_positions(content) == marker_positions, "resize preserves markers", failures)
		var context: Dictionary = ContextScript.load_from_root(content, catalog_path)
		_expect(context.get("error", FAILED) == OK, "load authoring context", failures)
		_expect(context.get("definition") is MapDefinition, "context definition", failures)
	content.free()

	var entry_scene := load(String(result.get("entry_scene_path", ""))) as PackedScene
	_expect(entry_scene != null, "entry scene loads", failures)
	if entry_scene != null:
		var entry_state := entry_scene.get_state()
		_expect(entry_state.get_node_name(0) == &"TestYardMap", "entry root name", failures)
		_expect(
			entry_state.get_node_instance(0) is PackedScene
				and entry_state.get_node_instance(0).resource_path
				== "res://scenes/gameplay/GameplayArena.tscn",
			"entry inherits GameplayArena",
			failures
		)
		_expect(
			_scene_state_property(entry_state, 0, &"map_definition") is MapDefinition
				and _scene_state_property(entry_state, 0, &"map_definition").resource_path
				== String(result.get("definition_path", "")),
			"entry binds generated definition",
			failures
		)

	var saved_catalog := load(catalog_path) as MapCatalog
	_expect(saved_catalog != null and saved_catalog.entries.size() == 1, "catalog appended", failures)
	if saved_catalog != null and saved_catalog.entries.size() == 1:
		var catalog_entry := saved_catalog.entries[0]
		_expect(catalog_entry.map_id == &"test_yard", "catalog map id", failures)
		_expect(catalog_entry.display_name == "测试场地", "catalog display name", failures)
		_expect(catalog_entry.sort_order == 10, "catalog sort order", failures)
		_expect(
			catalog_entry.entry_scene != null
				and catalog_entry.entry_scene.resource_path == String(result.get("entry_scene_path", "")),
			"catalog entry scene",
			failures
		)

	var duplicate := BuilderScript.create_map({
		"map_id": &"test_yard",
		"display_name": "重复场地",
		"grid_width": 20,
		"grid_height": 12,
		"grid_cell_size": 1.0,
		"scene_maps_root": FIXTURE_ROOT.path_join("scenes"),
		"resource_maps_root": FIXTURE_ROOT.path_join("resources"),
		"map_catalog_path": catalog_path,
	})
	_expect(duplicate.get("error", OK) == ERR_ALREADY_EXISTS, "duplicate never overwrites", failures)

	var invalid := BuilderScript.create_map({"map_id": &"Bad-Map"})
	_expect(invalid.get("error", OK) == ERR_INVALID_PARAMETER, "invalid map id rejected", failures)
	var plain_root := Node3D.new()
	var invalid_context := ContextScript.load_from_root(plain_root, catalog_path)
	_expect(invalid_context.get("error", OK) == ERR_INVALID_DATA, "non-map root rejected", failures)
	plain_root.free()

	_remove_fixture()
	_finish(failures)

func _remove_fixture() -> void:
	var absolute := ProjectSettings.globalize_path(FIXTURE_ROOT)
	if DirAccess.dir_exists_absolute(absolute):
		OS.move_to_trash(absolute)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_template_builder: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)

func _validate_geometry(root: Node3D, ground_size: Vector3, failures: Array[String]) -> void:
	var world_width := ground_size.x
	var world_height := ground_size.z
	var ground_mesh := root.get_node("Ground/MeshInstance3D") as MeshInstance3D
	var ground_collision := root.get_node("Ground/CollisionShape3D") as CollisionShape3D
	_expect(ground_mesh.mesh is BoxMesh and ground_mesh.mesh.size == ground_size, "ground mesh size", failures)
	_expect(
		ground_collision.shape is BoxShape3D and ground_collision.shape.size == ground_size,
		"ground collision size",
		failures
	)
	_expect(ground_mesh.position == Vector3(0.0, -0.15, 0.0), "ground mesh position", failures)
	_expect(ground_collision.position == Vector3(0.0, -0.15, 0.0), "ground collision position", failures)
	var expected := {
		"North": [Vector3(world_width, 2.0, 0.5), Vector3(0.0, 1.0, -(world_height * 0.5 - 0.25))],
		"South": [Vector3(world_width, 2.0, 0.5), Vector3(0.0, 1.0, world_height * 0.5 - 0.25)],
		"West": [Vector3(0.5, 2.0, world_height), Vector3(-(world_width * 0.5 - 0.25), 1.0, 0.0)],
		"East": [Vector3(0.5, 2.0, world_height), Vector3(world_width * 0.5 - 0.25, 1.0, 0.0)],
	}
	for boundary_name in expected:
		var boundary := root.get_node("Boundaries/%s" % boundary_name) as StaticBody3D
		var mesh := boundary.get_node("MeshInstance3D") as MeshInstance3D
		var collision := boundary.get_node("CollisionShape3D") as CollisionShape3D
		var values: Array = expected[boundary_name]
		_expect(boundary.is_in_group(&"place_item_obstacle"), "%s obstacle group" % boundary_name, failures)
		_expect(boundary.position == values[1], "%s position" % boundary_name, failures)
		_expect(mesh.mesh is BoxMesh and mesh.mesh.size == values[0], "%s mesh size" % boundary_name, failures)
		_expect(
			collision.shape is BoxShape3D and collision.shape.size == values[0],
			"%s collision size" % boundary_name,
			failures
		)

func _marker_positions(root: Node3D) -> Array[Vector3]:
	var positions: Array[Vector3] = []
	for marker in root.find_children("*", "MapPlayerSpawnMarker"):
		positions.append(marker.position)
	for marker in root.find_children("*", "MapZombieSpawnMarker"):
		positions.append(marker.position)
	return positions

func _scene_state_property(state: SceneState, node_index: int, property_name: StringName) -> Variant:
	for property_index in state.get_node_property_count(node_index):
		if state.get_node_property_name(node_index, property_index) == property_name:
			return state.get_node_property_value(node_index, property_index)
	return null
