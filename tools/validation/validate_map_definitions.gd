extends SceneTree

const MapDefinitionScript = preload("res://scripts/gameplay/map/map_definition.gd")
const MapSpawnPointDefinitionScript = preload(
	"res://scripts/gameplay/map/map_spawn_point_definition.gd"
)
const MapWaveDefinitionScript = preload(
	"res://scripts/gameplay/map/map_wave_definition.gd"
)
const WaveZombieEntryDefinitionScript = preload(
	"res://scripts/gameplay/map/wave_zombie_entry_definition.gd"
)
const ZombieDefinitionScript = preload("res://scripts/gameplay/map/zombie_definition.gd")
const DeathEventDefinitionScript = preload(
	"res://scripts/gameplay/map/death_event_definition.gd"
)

func _init() -> void:
	var failures: Array[String] = []
	var definition := _valid_complete_definition()
	_expect(
		definition.validate_configuration().is_empty(),
		"a complete map fixture must validate",
		failures
	)

	var missing_content := definition.duplicate(true)
	missing_content.content_scene = null
	_expect_error(
		missing_content,
		"content_scene is required",
		"missing content scene must be rejected",
		failures
	)
	var invalid_end_mode := definition.duplicate(true)
	invalid_end_mode.end_mode = 99
	_expect_error(
		invalid_end_mode,
		"end_mode must be COMPLETE or LOOP",
		"unsupported end mode must be rejected",
		failures
	)
	var missing_id := definition.duplicate(true)
	missing_id.map_id = &""
	_expect_error(missing_id, "map_id is required", "missing map id", failures)
	var invalid_cell_size := definition.duplicate(true)
	invalid_cell_size.grid_cell_size = 0.0
	_expect_error(
		invalid_cell_size,
		"grid_cell_size must be positive",
		"non-positive grid cell size",
		failures
	)
	var outside_player := definition.duplicate(true)
	var outside_positions: Array[Vector3] = [Vector3(9.0, 0.0, 0.0)]
	outside_player.player_spawn_positions = outside_positions
	_expect_error(
		outside_player,
		"player_spawn_positions[0] is outside grid bounds",
		"player spawn outside the authored grid",
		failures
	)
	var duplicate_spawn := definition.duplicate(true)
	var repeated_point := definition.spawn_points[0].duplicate(true)
	var repeated_points: Array[MapSpawnPointDefinition] = [
		definition.spawn_points[0],
		repeated_point,
	]
	duplicate_spawn.spawn_points = repeated_points
	_expect_error(
		duplicate_spawn,
		"duplicate spawn point id: center",
		"duplicate spawn point ids",
		failures
	)
	var missing_waves := definition.duplicate(true)
	var no_waves: Array[MapWaveDefinition] = []
	missing_waves.waves = no_waves
	_expect_error(
		missing_waves,
		"waves must not be empty",
		"map without authored waves",
		failures
	)

	var enhancement := DeathEventDefinitionScript.new()
	enhancement.event_type = DeathEventDefinitionScript.EventType.ENHANCEMENT
	_expect(
		enhancement.validate_configuration().has(
			"enhancement events are not supported"
		),
		"reserved enhancement events must fail validation",
		failures
	)
	_finish(failures)

func _valid_complete_definition() -> MapDefinition:
	var zombie := ZombieDefinitionScript.new()
	zombie.type_id = &"normal"
	zombie.view_scene = _packed_node_scene()
	zombie.max_health = 50
	zombie.move_speed_scale_per_10000 = 10000
	var entry := WaveZombieEntryDefinitionScript.new()
	entry.zombie = zombie
	entry.count = 2
	var entries: Array[WaveZombieEntryDefinition] = [entry]
	var wave := MapWaveDefinitionScript.new()
	wave.spawn_interval_ticks = 0
	wave.zombie_entries = entries
	var waves: Array[MapWaveDefinition] = [wave]
	var spawn_point := MapSpawnPointDefinitionScript.new()
	spawn_point.spawn_id = &"center"
	spawn_point.position_xz = Vector2.ZERO
	spawn_point.spawn_radius = 0.5
	spawn_point.minimum_spacing = 0.5
	var spawn_points: Array[MapSpawnPointDefinition] = [spawn_point]
	var definition := MapDefinitionScript.new()
	definition.map_id = &"complete_fixture"
	definition.content_scene = _packed_node_scene()
	definition.end_mode = MapDefinition.EndMode.COMPLETE
	definition.grid_origin = Vector2(-4.0, -4.0)
	definition.grid_cell_size = 1.0
	definition.grid_width = 8
	definition.grid_height = 8
	definition.player_spawn_positions = [Vector3.ZERO]
	definition.spawn_points = spawn_points
	definition.waves = waves
	return definition

func _packed_node_scene() -> PackedScene:
	var scene := PackedScene.new()
	var root_node := Node3D.new()
	scene.pack(root_node)
	root_node.free()
	return scene

func _expect_error(
	definition: MapDefinition,
	expected_error: String,
	message: String,
	failures: Array[String]
) -> void:
	_expect(
		definition.validate_configuration().has(expected_error),
		message,
		failures
	)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_definitions: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
