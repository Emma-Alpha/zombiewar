extends SceneTree

const RootScript = preload(
	"res://scripts/gameplay/map/authoring/map_content_authoring_root.gd"
)
const PlayerMarkerScript = preload(
	"res://scripts/gameplay/map/authoring/map_player_spawn_marker.gd"
)
const ZombieMarkerScript = preload(
	"res://scripts/gameplay/map/authoring/map_zombie_spawn_marker.gd"
)
const FixedMarkerScript = preload(
	"res://scripts/gameplay/map/authoring/map_fixed_item_spawn_marker.gd"
)
const PrefabEntryScript = preload(
	"res://scripts/gameplay/map/authoring/prefab_catalog_entry.gd"
)
const PrefabCatalogScript = preload(
	"res://scripts/gameplay/map/authoring/prefab_catalog.gd"
)
const MapEntryScript = preload(
	"res://scripts/gameplay/map/authoring/map_catalog_entry.gd"
)
const MapCatalogScript = preload(
	"res://scripts/gameplay/map/authoring/map_catalog.gd"
)

func _init() -> void:
	var failures: Array[String] = []
	var authoring_root = RootScript.new()
	_expect(authoring_root.map_definition_path == "", "authoring root default path", failures)
	_expect(not authoring_root.managed_template_geometry, "authoring root default geometry flag", failures)
	authoring_root.map_definition_path = "res://resources/maps/demo/demo_map.tres"
	_expect(
		authoring_root.map_definition_path.ends_with("demo_map.tres"),
		"authoring root must retain map definition path",
		failures
	)

	var player = PlayerMarkerScript.new()
	_expect(player.marker_id == &"", "player marker default id", failures)
	_expect(player.slot_index == 0, "player marker default slot", failures)
	player.marker_id = &"player_02"
	player.slot_index = 1
	_expect(player.slot_index == 1, "player marker slot", failures)

	var zombie = ZombieMarkerScript.new()
	_expect(zombie.spawn_id == &"", "zombie marker default id", failures)
	_expect(zombie.spawn_radius == 1.75, "zombie marker default radius", failures)
	_expect(zombie.minimum_spacing == 1.1, "zombie marker default spacing", failures)
	zombie.spawn_id = &"north"
	zombie.spawn_radius = 2.0
	zombie.minimum_spacing = 1.25
	_expect(zombie.spawn_id == &"north", "zombie marker id", failures)

	var fixed = FixedMarkerScript.new()
	_expect(fixed.spawn_id == &"", "fixed marker default id", failures)
	_expect(fixed.pickup == null, "fixed marker default pickup", failures)
	_expect(fixed.amount == 1, "fixed marker default amount", failures)
	_expect(fixed.respawn_delay_ticks == 60, "fixed marker default respawn delay", failures)
	fixed.spawn_id = &"ammo"
	fixed.amount = 90
	fixed.respawn_delay_ticks = 60
	_expect(fixed.amount == 90, "fixed marker amount", failures)

	var prefab_entry = PrefabEntryScript.new()
	_expect(prefab_entry.prefab_id == &"", "prefab entry default id", failures)
	_expect(prefab_entry.display_name == "预制件", "prefab entry default display name", failures)
	_expect(prefab_entry.category == &"misc", "prefab entry default category", failures)
	_expect(prefab_entry.search_tags.is_empty(), "prefab entry default tags", failures)
	_expect(prefab_entry.scene == null, "prefab entry default scene", failures)
	_expect(prefab_entry.thumbnail == null, "prefab entry default thumbnail", failures)
	_expect(
		prefab_entry.kind == PrefabEntryScript.Kind.DECORATION,
		"prefab entry default kind",
		failures
	)
	prefab_entry.prefab_id = &"traffic_barrier"
	prefab_entry.display_name = "交通路障"
	prefab_entry.category = &"obstacle"
	prefab_entry.search_tags = PackedStringArray(["barrier", "路障"])
	var prefab_catalog = PrefabCatalogScript.new()
	_expect(prefab_catalog.entries.is_empty(), "prefab catalog default entries", failures)
	var prefab_entries: Array[PrefabCatalogEntry] = [prefab_entry]
	prefab_catalog.entries = prefab_entries
	_expect(
		prefab_catalog.entries[0].prefab_id == &"traffic_barrier",
		"prefab catalog entry",
		failures
	)

	var late = MapEntryScript.new()
	_expect(late.map_id == &"", "map entry default id", failures)
	_expect(late.entry_scene == null, "map entry default scene", failures)
	_expect(late.display_name == "地图", "map entry default display name", failures)
	_expect(late.description == "", "map entry default description", failures)
	_expect(late.cover == null, "map entry default cover", failures)
	_expect(late.sort_order == 0, "map entry default sort order", failures)
	late.map_id = &"late"
	late.sort_order = 20
	var alpha = MapEntryScript.new()
	alpha.map_id = &"alpha"
	alpha.sort_order = 10
	var beta = MapEntryScript.new()
	beta.map_id = &"beta"
	beta.sort_order = 10
	var map_catalog = MapCatalogScript.new()
	_expect(map_catalog.entries.is_empty(), "map catalog default entries", failures)
	var map_entries: Array[MapCatalogEntry] = [late, beta, alpha]
	map_catalog.entries = map_entries
	var sorted = map_catalog.sorted_entries()
	_expect(sorted.map(func(entry): return entry.map_id) == [
		&"alpha", &"beta", &"late",
	], "map catalog stable order", failures)
	_expect(map_catalog.entries.map(func(entry): return entry.map_id) == [
		&"late", &"beta", &"alpha",
	], "map catalog sort must preserve resource order", failures)
	sorted.reverse()
	_expect(map_catalog.entries.map(func(entry): return entry.map_id) == [
		&"late", &"beta", &"alpha",
	], "returned map catalog entries must be independent", failures)

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_authoring_resources: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
