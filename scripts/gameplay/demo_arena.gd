extends Node3D

signal restart_requested

const HitResult = preload("res://scripts/combat/hit_result.gd")
const ZombieDifficultyProfile = preload("res://scripts/gameplay/zombie_difficulty_profile.gd")
const SinglePlayerInputSourceScript = preload(
	"res://scripts/input/single_player_input_source.gd"
)
const LocalTeamStateScript = preload("res://scripts/gameplay/local_team_state.gd")
const AUTO_WAVE_STATUS := "下一波即将到来"
const ARENA_CAMERA_BOUNDS := Rect2(Vector2(-10.0, -7.0), Vector2(20.0, 14.0))
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const PlaceItemGridScript = preload("res://scripts/gameplay/place_item_grid.gd")
const BLOOD_IMPACT_SCENE := preload("res://scenes/fx/BloodImpact.tscn")
const ARENA_SIM_GRID_ORIGIN := Vector2(-24.5, -19.5)
const ARENA_SIM_CELL_SIZE := 1.0
const ARENA_SIM_GRID_WIDTH := 49
const ARENA_SIM_GRID_HEIGHT := 39
const DEFAULT_SIM_SEED := 20260807
const ZOMBIE_MAX_HEALTH := 50.0
const BLOCKER_GROUP: StringName = &"place_item_obstacle"
const SPAWN_POINT_NAMES: Array[StringName] = [
	&"NorthWest",
	&"NorthEast",
	&"SouthWest",
	&"SouthEast",
]

@export var zombie_difficulty: ZombieDifficultyProfile

@export_group("Wave Spawning")
@export_range(1, 40, 1) var minimum_zombies_per_corner := 12
@export_range(1, 40, 1) var maximum_zombies_per_corner := 18
@export_range(4, 400, 1) var maximum_active_zombies := 300
@export_range(0.0, 8.0, 0.05) var spawn_radius := 1.75
@export_range(0.0, 4.0, 0.05) var minimum_spawn_spacing := 1.1
@export_range(1.0, 100.0, 0.5) var wave_perception_range := 60.0
@export var random_seed: int = 0

var hit_confirm_tween: Tween
var damage_flash_tween: Tween
var sim_clock = SimClockScript.new()
var sim_world = SimWorldScript.new()
var zombie_renderer: ZombieRenderer
var wave_number := 0
var team_defeated := false
var restart_pending := false
var startup_pending := false
var warmup_overlay_tween: Tween
var single_player_input = SinglePlayerInputSourceScript.new()
var players: Array[PlayerController] = []
var local_team_state = LocalTeamStateScript.new()

func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_wire_dependencies()

func _enter_tree() -> void:
	_wire_dependencies()

func _ready() -> void:
	add_child(local_team_state)
	if not _spawn_session_players():
		_handle_player_spawn_failure()
		return
	local_team_state.all_players_defeated.connect(_on_all_players_defeated)
	local_team_state.setup(players)
	_set_touch_game_over_active(false)
	_wire_dependencies()
	_setup_simulation()
	startup_pending = true
	if DisplayServer.get_name() == "headless":
		_complete_combat_startup(false)
		return
	for player in players:
		player.set_physics_process(false)
	call_deferred("_run_combat_startup")

func _process(delta: float) -> void:
	if (
		team_defeated and
		not restart_pending and
		local_team_state.sample_restart_requested()
	):
		request_restart()
	if zombie_renderer != null:
		zombie_renderer.render_frame(
			sim_world,
			sim_clock.get_interpolation_alpha(),
			delta
		)

func _physics_process(delta: float) -> void:
	if startup_pending or zombie_renderer == null:
		return
	var ticks := sim_clock.consume_frame(delta)
	for _tick_offset in range(ticks):
		_push_player_snapshot()
		sim_world.step_tick()
		_consume_sim_events()
		zombie_renderer.sync_lod(sim_world)

func get_sim_world() -> SimWorld:
	return sim_world

func _setup_simulation() -> void:
	sim_world.configure(
		ARENA_SIM_GRID_ORIGIN,
		ARENA_SIM_CELL_SIZE,
		ARENA_SIM_GRID_WIDTH,
		ARENA_SIM_GRID_HEIGHT
	)
	_bake_static_blockers()
	sim_world.reset(DEFAULT_SIM_SEED if random_seed == 0 else random_seed)
	if zombie_difficulty != null:
		sim_world.set_default_move_speed(zombie_difficulty.perception_move_speed)
	# 基线的 spawn_wave() 用 wave_perception_range（默认 60.0）覆盖 ZombieTarget 的
	# 导出默认值 7.0；模拟层没有这一步的话，生成角 (±19, ±14) 上的僵尸
	# 在 48 × 38 的场地里永远够不到玩家，会原地游荡而不汇聚。
	sim_world.set_perception_range(wave_perception_range)
	sim_clock.reset()

func _bake_static_blockers() -> void:
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group(BLOCKER_GROUP):
		var obstacle := node as CollisionObject3D
		if obstacle != null:
			mark_blocker(obstacle, true)

## 运行时增删阻挡几何的统一入口。任何调用都会置脏对应 cell，
## 下一 tick 的 FlowField.update() 会同步重算。
func mark_blocker(obstacle: CollisionObject3D, blocked: bool) -> void:
	var bounds := PlaceItemGridScript.collision_object_world_aabb(obstacle)
	if bounds.size == Vector3.ZERO:
		return
	sim_world.set_blocker_world_rect(
		Vector2(bounds.position.x, bounds.position.z),
		Vector2(bounds.end.x, bounds.end.z),
		blocked
	)

func _player_for_slot(slot: int) -> PlayerController:
	if slot < 0 or slot >= players.size():
		return null
	var player := players[slot]
	return player if is_instance_valid(player) else null

## 玩家状态以量化后的快照进入 SimWorld；玩家自身位移仍由玩家层决定。
func _push_player_snapshot() -> void:
	for slot in range(SimWorldScript.MAX_PLAYER_SLOTS):
		var player := _player_for_slot(slot)
		if player == null:
			sim_world.set_player_snapshot(slot, Vector2.ZERO, false, false)
			continue
		sim_world.set_player_snapshot(
			slot,
			Vector2(player.global_position.x, player.global_position.z),
			player.is_alive(),
			true
		)

func _consume_sim_events() -> void:
	for event in sim_world.tick_hit_events:
		_on_sim_hit_event(event)
	for event in sim_world.tick_player_damage_events:
		_on_sim_player_damage_event(event)
	if sim_world.tick_death_events.size() > 0:
		zombie_renderer.notify_deaths(sim_world)
		call_deferred("_refresh_wave_state_after_deaths")

func _on_sim_hit_event(event: Dictionary) -> void:
	var planar: Vector2 = event["position"]
	var hit_position := Vector3(planar.x, float(event["height"]), planar.y)
	var planar_direction: Vector2 = event["direction"]
	var direction := Vector3(planar_direction.x, 0.0, planar_direction.y)
	var view := zombie_renderer.get_near_view(int(event["zombie_id"]))
	if view != null:
		view.play_hit_reaction(
			hit_position,
			direction * SimWorldScript.ZOMBIE_KNOCKBACK_IMPULSE
		)
	_spawn_blood_impact(hit_position, direction)
	var manager := get_node_or_null("GroundBloodManager") as GroundBloodManager
	if manager == null:
		return
	manager.spawn_hit_splat(hit_position, direction, 1.0)
	if bool(event["killed"]):
		manager.spawn_death_pool(Vector3(planar.x, 0.0, planar.y), 1.25)

func _on_sim_player_damage_event(event: Dictionary) -> void:
	var view := zombie_renderer.get_near_view(int(event["zombie_id"]))
	if event["kind"] == &"zombie_windup":
		if view != null:
			view.play_attack_windup()
		return
	var target := _player_for_slot(int(event["slot"]))
	if target == null or not target.is_alive():
		return
	var origin: Vector2 = event["origin"]
	target.apply_damage(float(event["damage"]), Vector3(origin.x, 0.0, origin.y))

func _spawn_blood_impact(hit_position: Vector3, direction: Vector3) -> void:
	var effect := BLOOD_IMPACT_SCENE.instantiate() as BloodImpact
	add_child(effect)
	effect.setup(hit_position, direction, 1.0)

func _refresh_wave_state_after_deaths() -> void:
	_update_wave_hud()
	_schedule_auto_wave_if_empty()

func _exit_tree() -> void:
	_set_touch_game_over_active(false)

func _unhandled_input(event: InputEvent) -> void:
	if startup_pending:
		return
	if event is InputEventKey and (event as InputEventKey).echo:
		return
	if event.is_action_pressed(&"spawn_wave"):
		request_spawn_wave()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"restart_demo"):
		request_restart()
		get_viewport().set_input_as_handled()

## 返回本次授予的生成上限（不是实际生成数）：实际生成在下一个模拟 tick 才兑现。
func request_spawn_wave() -> int:
	if startup_pending or team_defeated:
		return 0
	_cancel_auto_wave()
	return spawn_wave()

func request_restart() -> void:
	if startup_pending or not team_defeated or restart_pending:
		return
	restart_pending = true
	_set_touch_game_over_active(false)
	restart_requested.emit()
	call_deferred("_reload_current_scene")

func _reload_current_scene() -> void:
	var scene_tree := get_tree()
	if scene_tree != null:
		scene_tree.reload_current_scene()

func _run_combat_startup() -> void:
	var prewarmer := get_node_or_null(
		"CombatFxPrewarmer"
	) as CombatFxPrewarmer
	var camera := get_node_or_null("FollowCamera/VisualOffset/Camera3D") as Camera3D
	var warmup_layer := get_node_or_null("WarmupLayer") as CanvasLayer
	if prewarmer != null:
		await get_tree().process_frame
		await get_tree().process_frame
		if warmup_layer != null:
			warmup_layer.hide()
		prewarmer.prewarm(camera)
		if warmup_layer != null:
			warmup_layer.show()
	_complete_combat_startup(true)

func _complete_combat_startup(animate_overlay: bool) -> void:
	if not startup_pending:
		return
	var mobile_controls := get_node_or_null("MobileControls") as MobileControls
	if mobile_controls != null:
		mobile_controls.cancel_all_input()
	_release_startup_actions()
	for player in players:
		player.set_physics_process(true)
	startup_pending = false
	spawn_wave()
	var warmup_layer := get_node_or_null("WarmupLayer") as CanvasLayer
	var overlay := get_node_or_null("WarmupLayer/Overlay") as ColorRect
	if warmup_layer == null or overlay == null:
		return
	if not animate_overlay:
		warmup_layer.hide()
		return
	if warmup_overlay_tween != null and warmup_overlay_tween.is_valid():
		warmup_overlay_tween.kill()
	warmup_overlay_tween = create_tween()
	warmup_overlay_tween.tween_property(overlay, "color:a", 0.0, 0.16)
	await warmup_overlay_tween.finished
	if is_instance_valid(warmup_layer):
		warmup_layer.hide()

func _release_startup_actions() -> void:
	for action in [
		&"spawn_wave",
		&"restart_demo",
	]:
		Input.action_release(action)

func _wire_dependencies() -> void:
	var navigation_manager := get_node_or_null(
		"World/Navigation"
	) as NavigationWorldManager
	if (
		navigation_manager != null and
		not navigation_manager.chunk_bake_failed.is_connected(
			_on_navigation_chunk_bake_failed
		)
	):
		navigation_manager.chunk_bake_failed.connect(
			_on_navigation_chunk_bake_failed
		)
	var barrels_root := get_node_or_null(
		"World/Props/HazardZone/ExplosiveBarrels"
	)
	if barrels_root != null:
		for barrel in barrels_root.get_children():
			if (
				barrel is ExplosiveBarrel and
				not barrel.navigation_geometry_changed.is_connected(
					_on_runtime_navigation_geometry_changed
				)
			):
				barrel.navigation_geometry_changed.connect(
					_on_runtime_navigation_geometry_changed
				)
	var pickup_spawners := get_node_or_null("World/Props/PickupSpawners")
	if pickup_spawners != null:
		for child in pickup_spawners.get_children():
			if (
				child is PickupSpawnPoint and
				not child.navigation_geometry_changed.is_connected(
					_on_runtime_navigation_geometry_changed
				)
			):
				child.navigation_geometry_changed.connect(
					_on_runtime_navigation_geometry_changed
				)
	var spawn_button := get_node_or_null("HUD/SpawnWaveButton") as Button
	if spawn_button != null and not spawn_button.pressed.is_connected(request_spawn_wave):
		spawn_button.pressed.connect(request_spawn_wave)
	var restart_button := get_node_or_null("HUD/RestartButton") as Button
	if restart_button != null and not restart_button.pressed.is_connected(request_restart):
		restart_button.pressed.connect(request_restart)
	_sync_command_controls()
	var mobile_controls := get_node_or_null("MobileControls") as MobileControls
	if mobile_controls != null:
		single_player_input.set_touch_source(mobile_controls.get_input_source())
	var place_item_service = get_node_or_null(
		"PlaceItemService"
	)
	if (
		place_item_service != null and
		not place_item_service.placement_geometry_changed.is_connected(
			_on_runtime_navigation_geometry_changed
		)
	):
		place_item_service.placement_geometry_changed.connect(
			_on_runtime_navigation_geometry_changed
		)
	var renderer := get_node_or_null(
		"World/Targets/ZombieRenderer"
	) as ZombieRenderer
	if renderer != null and zombie_renderer != renderer:
		zombie_renderer = renderer
		zombie_renderer.setup(get_node_or_null("FollowCamera") as Node3D)
	var status_timer := get_node_or_null("WaveStatusTimer") as Timer
	if (
		status_timer != null and
		not status_timer.timeout.is_connected(_hide_wave_status)
	):
		status_timer.timeout.connect(_hide_wave_status)
	var auto_wave_timer := get_node_or_null("AutoWaveTimer") as Timer
	if (
		auto_wave_timer != null and
		not auto_wave_timer.timeout.is_connected(_on_auto_wave_timeout)
	):
		auto_wave_timer.timeout.connect(_on_auto_wave_timeout)
	var follow_camera := get_node_or_null("FollowCamera") as FollowCamera
	var movement_camera := get_node_or_null(
		"FollowCamera/VisualOffset/Camera3D"
	) as Camera3D
	var current_players := _get_spawned_players()
	if current_players.is_empty() or follow_camera == null or movement_camera == null:
		return
	var player_registry := get_node_or_null("PlayerRegistry") as PlayerRegistry
	follow_camera.set_player_registry(player_registry)
	follow_camera.set_world_bounds(ARENA_CAMERA_BOUNDS)
	for player in current_players:
		player.set_movement_camera(movement_camera)
		player.set_place_item_service(place_item_service)
		if not player.attack_resolved.is_connected(_on_player_attack):
			player.attack_resolved.connect(_on_player_attack)
		if not player.damaged.is_connected(_on_player_damaged):
			player.damaged.connect(_on_player_damaged)

func _spawn_session_players() -> bool:
	var mobile_controls := get_node_or_null("MobileControls") as MobileControls
	if mobile_controls != null:
		single_player_input.set_touch_source(mobile_controls.get_input_source())
	var spawner = get_node_or_null("LocalPlayerSpawner")
	var container := get_node_or_null("Players") as Node3D
	var place_item_service = get_node_or_null("PlaceItemService")
	if spawner == null or container == null:
		var session := get_node_or_null("/root/GameSession")
		if session != null:
			session.last_error = "DemoArena player spawning nodes are missing"
		return false
	players = spawner.spawn_players(
		container,
		_get_player_spawn_points(),
		place_item_service,
		single_player_input
	)
	var player_registry := get_node_or_null("PlayerRegistry") as PlayerRegistry
	if player_registry != null:
		for player in players:
			player_registry.register_player(player)
	return not players.is_empty()

func _get_player_spawn_points() -> Array[Marker3D]:
	var points: Array[Marker3D] = []
	for index in range(1, 5):
		var marker := get_node_or_null(
			"PlayerSpawnPoints/P%d" % index
		) as Marker3D
		if marker == null:
			return []
		points.append(marker)
	return points

func _get_spawned_players() -> Array[PlayerController]:
	var result: Array[PlayerController] = []
	var container := get_node_or_null("Players")
	if container == null:
		return result
	for child in container.get_children():
		if child is PlayerController:
			result.append(child)
	players = result
	return result

func _handle_player_spawn_failure() -> void:
	startup_pending = false
	if DisplayServer.get_name() == "headless":
		return
	var session := get_node_or_null("/root/GameSession")
	var destination := "res://scenes/menu/MainMenu.tscn"
	if session != null and session.mode == 1:
		destination = "res://scenes/menu/LocalMultiplayerLobby.tscn"
	get_tree().change_scene_to_file.call_deferred(destination)

func _on_navigation_chunk_bake_failed(
	chunk_id: StringName,
	_generation: int,
	message: String
) -> void:
	push_warning("Navigation chunk %s failed: %s" % [chunk_id, message])
	_show_wave_status("NAVIGATION FAILED: %s" % chunk_id)

func _on_runtime_navigation_geometry_changed() -> void:
	var navigation_manager := get_node_or_null(
		"World/Navigation"
	) as NavigationWorldManager
	if navigation_manager != null:
		navigation_manager.mark_chunk_dirty(&"demo_arena")

func _on_player_attack(
	direction: Vector3,
	result: HitResult,
	camera_impulse_strength: float
) -> void:
	var follow_camera := get_node("FollowCamera") as FollowCamera
	follow_camera.add_shot_impulse(direction, camera_impulse_strength)
	if not result.did_hit:
		return
	var label := get_node("HUD/HitConfirm") as Label
	label.text = "KILL" if result.killed else "HIT"
	label.modulate = Color.WHITE
	if hit_confirm_tween != null and hit_confirm_tween.is_valid():
		hit_confirm_tween.kill()
	hit_confirm_tween = create_tween()
	hit_confirm_tween.tween_property(label, "modulate:a", 0.0, 0.18)

func _on_player_damaged(_amount: float) -> void:
	var flash := get_node_or_null("HUD/DamageFlash") as ColorRect
	if flash == null:
		return
	if damage_flash_tween != null and damage_flash_tween.is_valid():
		damage_flash_tween.kill()
	var flash_color := flash.color
	flash_color.a = 0.30
	flash.color = flash_color
	damage_flash_tween = create_tween()
	damage_flash_tween.tween_property(flash, "color:a", 0.0, 0.20)

func _on_all_players_defeated() -> void:
	if team_defeated:
		return
	team_defeated = true
	_cancel_auto_wave()
	var game_over := get_node_or_null("HUD/GameOver") as Label
	if game_over != null:
		game_over.text = "全员倒地"
		game_over.visible = true
	_set_touch_game_over_active(true)
	_sync_command_controls()
	_update_wave_hud()

func _set_touch_game_over_active(active: bool) -> void:
	var mobile_controls := get_node_or_null("MobileControls") as MobileControls
	if mobile_controls == null:
		return
	var touch_source = mobile_controls.get_input_source()
	if touch_source != null:
		touch_source.set_game_over_active(active)

func _sync_command_controls() -> void:
	var spawn_button := get_node_or_null("HUD/SpawnWaveButton") as Button
	if spawn_button != null:
		spawn_button.visible = not team_defeated
	var restart_button := get_node_or_null("HUD/RestartButton") as Button
	if restart_button != null:
		restart_button.visible = team_defeated

## 把一次波次生成排入模拟层，由下一 tick 在 Stream.ZOMBIE_SPAWN 上确定性执行。
## 返回本次授予的生成上限；实际生成数在下一 tick 后才可由
## get_active_zombie_count() 读到。
##
## 返回值语义相对基线有变：基线返回「本次实际生成数」，这里返回「本次授予的名额」。
## 三个调用点（spawn_wave 输入动作、HUD 生成按钮、_on_auto_wave_timeout）都只判
## `> 0`，语义变化不影响它们；但 request_spawn_wave() -> int 的文档注释必须同步改成
## 「本次授予的生成上限」，不要留着「实际生成数」的旧措辞。
func spawn_wave() -> int:
	if team_defeated:
		return 0
	var spawn_points := _get_spawn_points()
	if spawn_points.size() != SPAWN_POINT_NAMES.size():
		_report_wave_problem("MISSING CORNER SPAWN POINT")
		return 0
	var remaining_capacity := maximum_active_zombies - get_active_zombie_count()
	if remaining_capacity <= 0:
		_show_wave_status("MAX ZOMBIES: %d" % maximum_active_zombies)
		return 0
	var centers := PackedVector2Array()
	for marker in spawn_points:
		centers.append(
			Vector2(marker.global_position.x, marker.global_position.z)
		)
	sim_world.queue_spawn_wave(
		centers,
		minimum_zombies_per_corner,
		maximum_zombies_per_corner,
		remaining_capacity,
		spawn_radius,
		minimum_spawn_spacing,
		ZOMBIE_MAX_HEALTH
	)
	# 与基线一致：只有真的授出了名额才推进波次号，避免 HUD 波次在空转的
	# 波次请求上虚增。上面的 `remaining_capacity <= 0` 分支已经提前 return，
	# 走到这里必然 > 0，这一行是把基线的 `if spawned > 0` 守卫显式保留下来。
	if remaining_capacity > 0:
		wave_number += 1
	_update_wave_hud()
	return remaining_capacity

## 必须把「已排队但尚未兑现」的名额算进来。sim_world.get_zombie_count() 要等
## 下一个 step_tick() 才会变化，若只读它：
##   1. 同一物理帧内连按两次 T，两次都看到同样的 remaining_capacity，
##      _apply_pending_spawn_waves() 会把两批都放出来，突破 maximum_active_zombies；
##   2. 排队后的那一 tick 里计数仍为 0，_schedule_auto_wave_if_empty() 会再排一次。
func get_active_zombie_count() -> int:
	return sim_world.get_zombie_count() + sim_world.get_pending_spawn_capacity()

func _get_spawn_points() -> Array[Marker3D]:
	var points: Array[Marker3D] = []
	for point_name in SPAWN_POINT_NAMES:
		var marker := get_node_or_null(
			"World/SpawnPoints/%s" % String(point_name)
		) as Marker3D
		if marker == null:
			return []
		points.append(marker)
	return points

func _schedule_auto_wave_if_empty() -> bool:
	if team_defeated or get_active_zombie_count() != 0:
		return false
	var timer := get_node_or_null("AutoWaveTimer") as Timer
	if timer == null or not timer.is_stopped():
		return false
	var status_timer := get_node_or_null("WaveStatusTimer") as Timer
	if status_timer != null:
		status_timer.stop()
	var status := get_node_or_null("HUD/WaveStatus") as Label
	if status != null:
		status.text = AUTO_WAVE_STATUS
		status.visible = true
	timer.start()
	return true

func _cancel_auto_wave() -> void:
	var timer := get_node_or_null("AutoWaveTimer") as Timer
	if timer != null:
		timer.stop()
	var status := get_node_or_null("HUD/WaveStatus") as Label
	if status != null and status.text == AUTO_WAVE_STATUS:
		status.visible = false

func _on_auto_wave_timeout() -> void:
	if team_defeated or get_active_zombie_count() != 0:
		return
	_hide_wave_status()
	spawn_wave()

func _update_wave_hud() -> void:
	var objective := get_node_or_null("HUD/Objective") as Label
	if objective == null:
		return
	var active_count := get_active_zombie_count()
	if team_defeated:
		objective.text = "FINAL WAVE %d    ZOMBIES %d" % [
			wave_number,
			active_count,
		]
	else:
		objective.text = "WAVE %d    ALIVE %d    T: NEW WAVE" % [
			wave_number,
			active_count,
		]

func _show_wave_status(message: String) -> void:
	var label := get_node_or_null("HUD/WaveStatus") as Label
	if label == null:
		return
	label.text = message
	label.visible = true
	var timer := get_node_or_null("WaveStatusTimer") as Timer
	if timer != null:
		timer.start()

func _hide_wave_status() -> void:
	var label := get_node_or_null("HUD/WaveStatus") as Label
	if label != null:
		label.visible = false

func _report_wave_problem(message: String) -> void:
	push_warning(message)
	_show_wave_status(message)
