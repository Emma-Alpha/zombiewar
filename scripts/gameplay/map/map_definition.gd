extends Resource
class_name MapDefinition

const MAP_SPAWN_POINT_DEFINITION_SCRIPT = preload("res://scripts/gameplay/map/map_spawn_point_definition.gd")
const MAP_WAVE_DEFINITION_SCRIPT = preload("res://scripts/gameplay/map/map_wave_definition.gd")
const FIXED_ITEM_SPAWN_DEFINITION_SCRIPT = preload("res://scripts/gameplay/map/fixed_item_spawn_definition.gd")
const MAP_ZOMBIE_DEATH_RULE_DEFINITION_SCRIPT = preload("res://scripts/gameplay/map/map_zombie_death_rule_definition.gd")

enum EndMode { COMPLETE, LOOP }

@export var map_id: StringName
@export var display_name := "地图"
## 地图卡上的缩略图。允许为空——空时地图卡画一块用 display_name 打底的占位色块，
## 而不是留一个空洞。真实缩略图需要人进游戏俯视截图，不该阻塞这条链路。
@export var thumbnail: Texture2D
## 地图卡上的难度星级，1..5。
@export_range(1, 5, 1) var difficulty := 3
@export var content_scene: PackedScene
@export var end_mode := EndMode.COMPLETE
@export var grid_origin := Vector2.ZERO
@export_range(0.25, 4.0, 0.25) var grid_cell_size := 1.0
@export_range(1, 4096, 1) var grid_width := 1
@export_range(1, 4096, 1) var grid_height := 1
@export var camera_bounds := Rect2(Vector2(-10.0, -7.0), Vector2(20.0, 14.0))
@export_range(1, 4000, 1) var maximum_active_zombies := 300
@export_range(1.0, 200.0, 0.5) var zombie_perception_range := 60.0
@export_range(0, 1000000, 1) var inter_wave_delay_ticks := 30
@export var player_spawn_positions: Array[Vector3] = []
@export var spawn_points: Array[MapSpawnPointDefinition] = []
@export var waves: Array[MapWaveDefinition] = []
@export var fixed_item_spawns: Array[FixedItemSpawnDefinition] = []
@export var zombie_death_rules: Array[MapZombieDeathRuleDefinition] = []

func validate_configuration() -> PackedStringArray:
	var errors := PackedStringArray()
	if map_id.is_empty():
		errors.append("map_id is required")
	if content_scene == null:
		errors.append("content_scene is required")
	if end_mode != EndMode.COMPLETE and end_mode != EndMode.LOOP:
		errors.append("end_mode must be COMPLETE or LOOP")
	if grid_cell_size <= 0.0:
		errors.append("grid_cell_size must be positive")
	if grid_width <= 0:
		errors.append("grid_width must be positive")
	if grid_height <= 0:
		errors.append("grid_height must be positive")
	if maximum_active_zombies <= 0:
		errors.append("maximum_active_zombies must be positive")
	if zombie_perception_range <= 0.0:
		errors.append("zombie_perception_range must be positive")
	if inter_wave_delay_ticks < 0:
		errors.append("inter_wave_delay_ticks cannot be negative")
	var grid_bounds := Rect2()
	if grid_cell_size > 0.0 and grid_width > 0 and grid_height > 0:
		grid_bounds = Rect2(
			grid_origin,
			Vector2(grid_width * grid_cell_size, grid_height * grid_cell_size)
		)
		for index in player_spawn_positions.size():
			var player_position := player_spawn_positions[index]
			if not grid_bounds.has_point(Vector2(player_position.x, player_position.z)):
				errors.append("player_spawn_positions[%d] is outside grid bounds" % index)
	var spawn_ids: Dictionary[StringName, bool] = {}
	for index in spawn_points.size():
		var spawn_point := spawn_points[index]
		if spawn_point == null:
			errors.append("spawn_points[%d] is required" % index)
			continue
		if not spawn_point.spawn_id.is_empty():
			if spawn_ids.has(spawn_point.spawn_id):
				errors.append("duplicate spawn point id: %s" % spawn_point.spawn_id)
			else:
				spawn_ids[spawn_point.spawn_id] = true
		if grid_bounds.size != Vector2.ZERO and not grid_bounds.has_point(spawn_point.position_xz):
			errors.append("spawn_points[%d] is outside grid bounds" % index)
		errors.append_array(spawn_point.validate_configuration())
	if waves.is_empty():
		errors.append("waves must not be empty")
	for index in waves.size():
		var wave := waves[index]
		if wave == null:
			errors.append("waves[%d] is required" % index)
			continue
		errors.append_array(wave.validate_configuration())
	var fixed_spawn_ids: Dictionary[StringName, bool] = {}
	for index in fixed_item_spawns.size():
		var fixed_item_spawn := fixed_item_spawns[index]
		if fixed_item_spawn == null:
			errors.append("fixed_item_spawns[%d] is required" % index)
			continue
		if not fixed_item_spawn.spawn_id.is_empty():
			if fixed_spawn_ids.has(fixed_item_spawn.spawn_id):
				errors.append("duplicate fixed item spawn id: %s" % fixed_item_spawn.spawn_id)
			else:
				fixed_spawn_ids[fixed_item_spawn.spawn_id] = true
		if grid_bounds.size != Vector2.ZERO and not grid_bounds.has_point(fixed_item_spawn.position_xz):
			errors.append("fixed_item_spawns[%d] is outside grid bounds" % index)
		errors.append_array(fixed_item_spawn.validate_configuration())
	var death_rule_zombies: Dictionary[StringName, bool] = {}
	for index in zombie_death_rules.size():
		var death_rule := zombie_death_rules[index]
		if death_rule == null:
			errors.append("zombie_death_rules[%d] is required" % index)
			continue
		if death_rule.zombie != null and not death_rule.zombie.type_id.is_empty():
			if death_rule_zombies.has(death_rule.zombie.type_id):
				errors.append("duplicate zombie death rule: %s" % death_rule.zombie.type_id)
			else:
				death_rule_zombies[death_rule.zombie.type_id] = true
		errors.append_array(death_rule.validate_configuration())
	return errors
