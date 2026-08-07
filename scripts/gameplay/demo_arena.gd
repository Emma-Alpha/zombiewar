extends Node3D

signal restart_requested

const HitResult = preload("res://scripts/combat/hit_result.gd")
const ZombieDifficultyProfile = preload("res://scripts/gameplay/zombie_difficulty_profile.gd")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const SinglePlayerInputSourceScript = preload(
	"res://scripts/input/single_player_input_source.gd"
)
const LocalTeamStateScript = preload("res://scripts/gameplay/local_team_state.gd")
const AUTO_WAVE_STATUS := "下一波即将到来"
const ARENA_CAMERA_BOUNDS := Rect2(Vector2(-10.0, -7.0), Vector2(20.0, 14.0))
const SPAWN_POINT_NAMES: Array[StringName] = [
	&"NorthWest",
	&"NorthEast",
	&"SouthWest",
	&"SouthEast",
]

@export var zombie_difficulty: ZombieDifficultyProfile

@export_group("Wave Spawning")
@export_range(1, 8, 1) var minimum_zombies_per_corner := 1
@export_range(1, 8, 1) var maximum_zombies_per_corner := 2
@export_range(4, 128, 1) var maximum_active_zombies := 24
@export_range(0.0, 8.0, 0.05) var spawn_radius := 1.75
@export_range(0.0, 4.0, 0.05) var minimum_spawn_spacing := 1.1
@export_range(1.0, 100.0, 0.5) var wave_perception_range := 60.0
@export var random_seed: int = 0

var hit_confirm_tween: Tween
var damage_flash_tween: Tween
var wave_rng := RandomNumberGenerator.new()
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
	if random_seed == 0:
		wave_rng.randomize()
	else:
		wave_rng.seed = random_seed
	startup_pending = true
	if DisplayServer.get_name() == "headless":
		_complete_combat_startup(false)
		return
	for player in players:
		player.set_physics_process(false)
	call_deferred("_run_combat_startup")

func _process(_delta: float) -> void:
	if (
		team_defeated and
		not restart_pending and
		local_team_state.sample_restart_requested()
	):
		request_restart()

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
	var random_pickup_drops := get_node_or_null(
		"World/Props/RandomPickupDrops"
	) as RandomPickupDropManager
	if (
		random_pickup_drops != null and
		not random_pickup_drops.navigation_geometry_changed.is_connected(
			_on_runtime_navigation_geometry_changed
		)
	):
		random_pickup_drops.navigation_geometry_changed.connect(
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
	var targets := get_node_or_null("World/Targets")
	if targets != null:
		for target in targets.get_children():
			_wire_target(target)
		if not targets.child_entered_tree.is_connected(_wire_target):
			targets.child_entered_tree.connect(_wire_target)
		if not targets.child_exiting_tree.is_connected(_on_target_exiting_tree):
			targets.child_exiting_tree.connect(_on_target_exiting_tree)
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

func _wire_target(target: Node) -> void:
	_wire_target_blood(target)
	if not target is ZombieTarget:
		return
	var zombie := target as ZombieTarget
	var random_pickup_drops := get_node_or_null(
		"World/Props/RandomPickupDrops"
	) as RandomPickupDropManager
	if (
		random_pickup_drops != null and
		not zombie.died.is_connected(random_pickup_drops.try_spawn_drop)
	):
		zombie.died.connect(random_pickup_drops.try_spawn_drop)
	var player_registry := get_node_or_null("PlayerRegistry") as PlayerRegistry
	var navigation_manager := get_node_or_null(
		"World/Navigation"
	) as NavigationWorldManager
	if navigation_manager != null:
		zombie.set_navigation_manager(navigation_manager)
	if player_registry != null:
		zombie.set_player_registry(player_registry)
	if zombie_difficulty != null:
		zombie.set_perception_move_speed(zombie_difficulty.perception_move_speed)

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

func _wire_target_blood(target: Node) -> void:
	if not target is ZombieTarget:
		return
	var zombie := target as ZombieTarget
	if not zombie.blood_impact_requested.is_connected(_on_blood_impact_requested):
		zombie.blood_impact_requested.connect(_on_blood_impact_requested)
	if not zombie.ground_blood_requested.is_connected(_on_ground_blood_requested):
		zombie.ground_blood_requested.connect(_on_ground_blood_requested)
	if not zombie.ground_blood_trail_requested.is_connected(
		_on_ground_blood_trail_requested
	):
		zombie.ground_blood_trail_requested.connect(_on_ground_blood_trail_requested)

func _on_ground_blood_requested(
	origin: Vector3,
	direction: Vector3,
	intensity: float,
	death_pool: bool
) -> void:
	var manager := get_node("GroundBloodManager") as GroundBloodManager
	if death_pool:
		manager.queue_death_pool(origin, intensity)
	else:
		manager.queue_hit_splat(origin, direction, intensity)

func _on_ground_blood_trail_requested(
	position: Vector3,
	direction: Vector3,
	intensity: float,
	progress: float
) -> void:
	var manager := get_node("GroundBloodManager") as GroundBloodManager
	manager.queue_trail_splat(position, direction, intensity, progress)

func _on_blood_impact_requested(
	position: Vector3,
	direction: Vector3,
	intensity: float
) -> void:
	var manager := get_node("GroundBloodManager") as GroundBloodManager
	manager.spawn_blood_impact(position, direction, intensity)

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

func spawn_wave() -> int:
	if team_defeated:
		return 0
	var targets := get_node_or_null("World/Targets") as Node3D
	if targets == null:
		_report_wave_problem("MISSING TARGET CONTAINER")
		return 0
	var spawn_points := _get_spawn_points()
	if spawn_points.size() != SPAWN_POINT_NAMES.size():
		_report_wave_problem("MISSING CORNER SPAWN POINT")
		return 0

	var remaining_capacity := maximum_active_zombies - get_active_zombie_count()
	if remaining_capacity <= 0:
		_show_wave_status("MAX ZOMBIES: %d" % maximum_active_zombies)
		return 0

	var occupied_positions := _collect_zombie_positions()
	var spawned := 0
	var next_wave_number := wave_number + 1
	for marker in spawn_points:
		var requested := wave_rng.randi_range(
			minimum_zombies_per_corner,
			maximum_zombies_per_corner
		)
		for _index in range(requested):
			if spawned >= remaining_capacity:
				break
			var spawn_position := _sample_spawn_position(
				marker.global_position,
				occupied_positions
			)
			var zombie := ZOMBIE_SCENE.instantiate() as ZombieTarget
			if zombie == null:
				_report_wave_problem("FAILED TO CREATE ZOMBIE")
				return spawned
			zombie.name = "Wave%02dZombie%02d" % [
				next_wave_number,
				spawned + 1,
			]
			zombie.perception_range = wave_perception_range
			zombie.position = targets.to_local(spawn_position)
			targets.add_child(zombie)
			occupied_positions.append(spawn_position)
			spawned += 1
		if spawned >= remaining_capacity:
			break

	if spawned > 0:
		wave_number = next_wave_number
	_update_wave_hud()
	return spawned

func get_active_zombie_count() -> int:
	var targets := get_node_or_null("World/Targets")
	if targets == null:
		return 0
	var count := 0
	for child in targets.get_children():
		if child is ZombieTarget:
			count += 1
	return count

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

func _collect_zombie_positions() -> Array[Vector3]:
	var positions: Array[Vector3] = []
	var targets := get_node_or_null("World/Targets")
	if targets == null:
		return positions
	for child in targets.get_children():
		if child is ZombieTarget:
			positions.append((child as ZombieTarget).global_position)
	return positions

func _sample_spawn_position(
	center: Vector3,
	occupied_positions: Array[Vector3]
) -> Vector3:
	var fallback := center
	for _attempt in range(16):
		var angle := wave_rng.randf_range(0.0, TAU)
		var radius := sqrt(wave_rng.randf()) * spawn_radius
		var candidate := center + Vector3(
			cos(angle) * radius,
			0.0,
			sin(angle) * radius
		)
		fallback = candidate
		if _has_spawn_clearance(candidate, occupied_positions):
			return candidate
	return fallback

func _has_spawn_clearance(
	candidate: Vector3,
	occupied_positions: Array[Vector3]
) -> bool:
	for occupied in occupied_positions:
		if Vector2(candidate.x, candidate.z).distance_to(
			Vector2(occupied.x, occupied.z)
		) < minimum_spawn_spacing:
			return false
	return true

func _on_target_exiting_tree(target: Node) -> void:
	if target is ZombieTarget:
		call_deferred("_refresh_wave_state_after_target_exit")

func _refresh_wave_state_after_target_exit() -> void:
	_update_wave_hud()
	_schedule_auto_wave_if_empty()

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
