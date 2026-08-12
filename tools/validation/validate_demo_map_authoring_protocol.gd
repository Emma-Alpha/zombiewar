extends SceneTree

const DEMO_DEFINITION_PATH := "res://resources/maps/demo/demo_map.tres"
const DEMO_CONTENT_PATH := "res://scenes/maps/demo/DemoMapContent.tscn"
const PREFAB_CATALOG_PATH := "res://resources/maps/catalogs/prefab_catalog.tres"
const MAP_CATALOG_PATH := "res://resources/maps/catalogs/map_catalog.tres"
const SyncScript = preload(
	"res://addons/map_editor/core/map_definition_synchronizer.gd"
)

func _init() -> void:
	var failures: Array[String] = []
	var definition := load(DEMO_DEFINITION_PATH) as MapDefinition
	var content_scene := load(DEMO_CONTENT_PATH) as PackedScene
	_expect(definition != null, "demo definition loads", failures)
	_expect(content_scene != null, "demo content loads", failures)
	if definition == null or content_scene == null:
		_finish(failures)
		return

	var content := content_scene.instantiate() as MapContentAuthoringRoot
	_expect(content != null, "demo root uses authoring protocol", failures)
	if content == null:
		_finish(failures)
		return
	_expect(
		content.map_definition_path == DEMO_DEFINITION_PATH,
		"demo root points to definition",
		failures
	)
	_expect(not content.managed_template_geometry, "demo geometry remains unmanaged", failures)
	_expect(content.get_node_or_null("Props") != null, "demo Props root", failures)
	_expect(content.get_node_or_null("MapMarkers/PlayerSpawns") != null, "player marker root", failures)
	_expect(content.get_node_or_null("MapMarkers/ZombieSpawns") != null, "zombie marker root", failures)
	_expect(content.get_node_or_null("MapMarkers/FixedItemSpawns") != null, "fixed marker root", failures)
	_expect(content.find_children("*", "MapPlayerSpawnMarker").size() == 4, "four player markers", failures)
	_expect(content.find_children("*", "MapZombieSpawnMarker").size() == 4, "four zombie markers", failures)
	_expect(content.find_children("*", "MapFixedItemSpawnMarker").size() == 5, "five fixed markers", failures)
	_expect(
		_marker_ids(content, "MapPlayerSpawnMarker", "marker_id") == [
			&"player_01", &"player_02", &"player_03", &"player_04",
		],
		"exact player marker ids",
		failures
	)
	_expect(
		_marker_ids(content, "MapZombieSpawnMarker", "spawn_id") == [
			&"01_north_west", &"02_north_east",
			&"03_south_west", &"04_south_east",
		],
		"exact zombie marker ids",
		failures
	)
	_expect(
		_marker_ids(content, "MapFixedItemSpawnMarker", "spawn_id") == [
			&"01_smg", &"02_smg_ammo", &"03_oil", &"04_shotgun", &"05_rifle",
		],
		"exact fixed marker ids",
		failures
	)

	var before := _runtime_space_snapshot(definition)
	SyncScript.synchronize(content, definition)
	_expect(
		before == _runtime_space_snapshot(definition),
		"demo marker sync preserves runtime data",
		failures
	)

	var prefab_catalog := load(PREFAB_CATALOG_PATH) as PrefabCatalog
	_expect(prefab_catalog != null, "prefab catalog loads", failures)
	if prefab_catalog != null:
		_validate_prefab_catalog(prefab_catalog, failures)
		_validate_reusable_prefabs(prefab_catalog, failures)

	var map_catalog := load(MAP_CATALOG_PATH) as MapCatalog
	_expect(map_catalog != null, "map catalog loads", failures)
	if map_catalog != null:
		_validate_map_catalog(map_catalog, failures)

	content.free()
	_finish(failures)

static func _validate_prefab_catalog(catalog: PrefabCatalog, failures: Array[String]) -> void:
	var prefab_expectations := _prefab_expectations()
	_expect(catalog.entries.size() == 6, "prefab catalog contains exactly six entries", failures)
	var entries_by_id := {}
	for entry in catalog.entries:
		_expect(not entries_by_id.has(entry.prefab_id), "unique prefab id %s" % entry.prefab_id, failures)
		entries_by_id[entry.prefab_id] = entry
	for prefab_id in prefab_expectations:
		_expect(entries_by_id.has(prefab_id), "prefab catalog contains %s" % prefab_id, failures)
		if not entries_by_id.has(prefab_id):
			continue
		var entry: PrefabCatalogEntry = entries_by_id[prefab_id]
		var expected: Array = prefab_expectations[prefab_id]
		_expect(entry.display_name == expected[0], "%s display name" % prefab_id, failures)
		_expect(entry.category == expected[1], "%s category" % prefab_id, failures)
		_expect(entry.search_tags == expected[2], "%s search tags" % prefab_id, failures)
		_expect(entry.scene != null, "%s scene resource" % prefab_id, failures)
		if entry.scene != null:
			_expect(entry.scene.resource_path == expected[3], "%s scene path" % prefab_id, failures)
		_expect(entry.thumbnail != null, "%s thumbnail resource" % prefab_id, failures)
		if entry.thumbnail != null:
			_expect(entry.thumbnail.resource_path == expected[4], "%s thumbnail path" % prefab_id, failures)
		_expect(entry.kind == expected[5], "%s kind" % prefab_id, failures)

static func _prefab_expectations() -> Dictionary:
	return {
		&"traffic_barrier": [
			"交通路障", &"obstacle", PackedStringArray(["交通路障", "traffic barrier"]),
			"res://scenes/props/TrafficBarrier.tscn",
			"res://assets/environment/TrafficBarrier_1_Zombie_Atlas.png",
			PrefabCatalogEntry.Kind.OBSTACLE,
		],
		&"plastic_barrier": [
			"塑料路障", &"obstacle", PackedStringArray(["塑料路障", "plastic barrier"]),
			"res://scenes/props/PlasticBarrier.tscn",
			"res://assets/environment/PlasticBarrier_Zombie_Atlas.png",
			PrefabCatalogEntry.Kind.OBSTACLE,
		],
		&"explosive_barrel": [
			"爆炸桶", &"hazard", PackedStringArray(["爆炸桶", "explosive barrel"]),
			"res://scenes/props/ExplosiveBarrel.tscn",
			"res://assets/environment/Barrel_Zombie_Atlas.png",
			PrefabCatalogEntry.Kind.EXPLOSIVE_BARREL,
		],
		&"vehicle_pickup": [
			"皮卡车", &"vehicle", PackedStringArray(["皮卡车", "pickup vehicle"]),
			"res://scenes/props/VehiclePickupObstacle.tscn",
			"res://assets/vehicles/Vehicle_Pickup_Zombie_Atlas.png",
			PrefabCatalogEntry.Kind.OBSTACLE,
		],
		&"container_red": [
			"红色集装箱", &"container", PackedStringArray(["红色集装箱", "red container"]),
			"res://scenes/props/ContainerRedObstacle.tscn",
			"res://assets/environment/Container_Red_Zombie_Atlas.png",
			PrefabCatalogEntry.Kind.OBSTACLE,
		],
		&"traffic_cone": [
			"交通锥", &"decoration", PackedStringArray(["交通锥", "traffic cone"]),
			"res://scenes/props/TrafficConeDecoration.tscn",
			"res://assets/environment/TrafficCone_1_Zombie_Atlas.png",
			PrefabCatalogEntry.Kind.DECORATION,
		],
	}

func _validate_reusable_prefabs(catalog: PrefabCatalog, failures: Array[String]) -> void:
	var entries_by_id := {}
	for entry in catalog.entries:
		entries_by_id[entry.prefab_id] = entry
	_validate_obstacle_prefab(
		entries_by_id.get(&"vehicle_pickup"),
		&"vehicle_pickup",
		Vector3(4.2, 1.8, 2.1),
		Vector3(0.0, 0.9, 0.0),
		"res://assets/vehicles/Vehicle_Pickup.gltf",
		failures
	)
	_validate_obstacle_prefab(
		entries_by_id.get(&"container_red"),
		&"container_red",
		Vector3(6.2, 2.8, 2.5),
		Vector3(0.0, 1.4, 0.0),
		"res://assets/environment/Container_Red.gltf",
		failures
	)
	var cone_entry := entries_by_id.get(&"traffic_cone") as PrefabCatalogEntry
	if cone_entry == null or cone_entry.scene == null:
		return
	var cone := cone_entry.scene.instantiate()
	_expect(cone.get_class() == "Node3D", "traffic_cone root Node3D", failures)
	_expect(not (cone is CollisionObject3D), "traffic_cone is not collision object", failures)
	_expect(not cone.is_in_group(&"place_item_obstacle"), "traffic_cone is not obstacle", failures)
	for node in cone.find_children("*", "Node", true, false):
		_expect(not (node is CollisionObject3D), "traffic_cone has no collision child", failures)
		_expect(not node.is_in_group(&"place_item_obstacle"), "traffic_cone has no obstacle child", failures)
	var cone_visual := cone.get_node_or_null("Visual")
	_expect(cone_visual != null, "traffic_cone visual child", failures)
	if cone_visual != null:
		_expect(
			cone_visual.scene_file_path == "res://assets/environment/TrafficCone_1.gltf",
			"traffic_cone associated visual scene",
			failures
		)
	cone.free()

func _validate_obstacle_prefab(
	entry: PrefabCatalogEntry,
	prefab_id: StringName,
	expected_size: Vector3,
	expected_position: Vector3,
	expected_visual_scene: String,
	failures: Array[String]
) -> void:
	if entry == null or entry.scene == null:
		return
	var root := entry.scene.instantiate()
	_expect(root.get_class() == "StaticBody3D", "%s root StaticBody3D" % prefab_id, failures)
	_expect(root.is_in_group(&"place_item_obstacle"), "%s obstacle group" % prefab_id, failures)
	if root is StaticBody3D:
		_expect(root.collision_layer == 1, "%s collision layer" % prefab_id, failures)
		_expect(root.collision_mask == 0, "%s collision mask" % prefab_id, failures)
	var collision := root.get_node_or_null("CollisionShape3D") as CollisionShape3D
	_expect(collision != null, "%s collision shape child" % prefab_id, failures)
	if collision != null:
		_expect(collision.position == expected_position, "%s collision position" % prefab_id, failures)
		_expect(collision.shape is BoxShape3D, "%s box collision" % prefab_id, failures)
		if collision.shape is BoxShape3D:
			_expect(collision.shape.size == expected_size, "%s collision size" % prefab_id, failures)
	var visual := root.get_node_or_null("Visual")
	_expect(visual != null, "%s visual child" % prefab_id, failures)
	if visual != null:
		_expect(visual.scene_file_path == expected_visual_scene, "%s associated visual scene" % prefab_id, failures)
	root.free()

func _validate_map_catalog(catalog: MapCatalog, failures: Array[String]) -> void:
	_expect(catalog.entries.size() == 1, "initial catalog contains demo only", failures)
	if catalog.entries.size() != 1:
		return
	var entry := catalog.entries[0]
	_expect(entry.map_id == &"demo", "demo catalog id", failures)
	_expect(entry.display_name == "Demo 检查站", "demo catalog display name", failures)
	_expect(entry.description == "守住检查站，在循环尸潮中尽可能生存。", "demo catalog description", failures)
	_expect(entry.sort_order == 0, "demo catalog sort order", failures)
	_expect(entry.entry_scene != null, "demo catalog scene resource", failures)
	if entry.entry_scene != null:
		_expect(entry.entry_scene.resource_path == "res://scenes/maps/demo/DemoMap.tscn", "demo catalog scene", failures)
	_expect(entry.cover != null, "demo catalog cover resource", failures)
	if entry.cover != null:
		_expect(entry.cover.resource_path == "res://assets/environment/Container_Red_Zombie_Atlas.png", "demo catalog cover", failures)

func _marker_ids(content: Node, type_name: String, property_name: String) -> Array[StringName]:
	var ids: Array[StringName] = []
	for marker in content.find_children("*", type_name):
		ids.append(marker.get(property_name) as StringName)
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return ids

func _runtime_space_snapshot(definition: MapDefinition) -> Array:
	return [
		definition.player_spawn_positions.duplicate(),
		definition.spawn_points.map(func(value): return [
			value.spawn_id,
			value.position_xz,
			value.spawn_radius,
			value.minimum_spacing,
		]),
		definition.fixed_item_spawns.map(func(value): return [
			value.spawn_id,
			value.position_xz,
			value.pickup.resource_path if value.pickup != null else "",
			value.amount,
			value.respawn_delay_ticks,
		]),
	]

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_demo_map_authoring_protocol: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

static func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
