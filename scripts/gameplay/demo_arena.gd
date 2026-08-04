extends Node3D

const HitResult = preload("res://scripts/combat/hit_result.gd")
const ZombieDifficultyProfile = preload("res://scripts/gameplay/zombie_difficulty_profile.gd")

@export var zombie_difficulty: ZombieDifficultyProfile

var hit_confirm_tween: Tween
var damage_flash_tween: Tween

func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_wire_dependencies()

func _enter_tree() -> void:
	_wire_dependencies()

func _wire_dependencies() -> void:
	var player := get_node_or_null("Player") as PlayerController
	var targets := get_node_or_null("World/Targets")
	if targets != null:
		for target in targets.get_children():
			_wire_target(target)
		if not targets.child_entered_tree.is_connected(_wire_target):
			targets.child_entered_tree.connect(_wire_target)
	var follow_camera := get_node_or_null("FollowCamera") as FollowCamera
	var movement_camera := get_node_or_null("FollowCamera/Camera3D") as Camera3D
	if player == null or follow_camera == null or movement_camera == null:
		return
	if follow_camera.is_inside_tree():
		follow_camera.set_target(player)
	else:
		follow_camera.target = player
	player.set_movement_camera(movement_camera)
	if not player.shot_fired.is_connected(_on_player_shot):
		player.shot_fired.connect(_on_player_shot)
	if not player.health_changed.is_connected(_on_player_health_changed):
		player.health_changed.connect(_on_player_health_changed)
	if not player.damaged.is_connected(_on_player_damaged):
		player.damaged.connect(_on_player_damaged)
	if not player.died.is_connected(_on_player_died):
		player.died.connect(_on_player_died)
	var current_health := player.max_health
	var maximum_health := player.max_health
	if player.health != null:
		current_health = player.health.current
		maximum_health = player.health.maximum
	_on_player_health_changed(current_health, maximum_health)

func _wire_target(target: Node) -> void:
	_wire_target_blood(target)
	if not target is ZombieTarget:
		return
	var player := get_node_or_null("Player") as PlayerController
	var zombie := target as ZombieTarget
	if player != null:
		zombie.set_attack_target(player)
	if zombie_difficulty != null:
		zombie.set_perception_move_speed(zombie_difficulty.perception_move_speed)

func _wire_target_blood(target: Node) -> void:
	if not target is ZombieTarget:
		return
	var zombie := target as ZombieTarget
	if not zombie.ground_blood_requested.is_connected(_on_ground_blood_requested):
		zombie.ground_blood_requested.connect(_on_ground_blood_requested)

func _on_ground_blood_requested(
	origin: Vector3,
	direction: Vector3,
	intensity: float,
	death_pool: bool
) -> void:
	var manager := get_node("GroundBloodManager") as GroundBloodManager
	if death_pool:
		manager.spawn_death_pool(origin, intensity)
	else:
		manager.spawn_hit_splat(origin, direction, intensity)

func _on_player_shot(direction: Vector3, result: HitResult) -> void:
	var follow_camera := get_node("FollowCamera") as FollowCamera
	follow_camera.add_shot_impulse(direction)
	if not result.did_hit:
		return
	var label := get_node("HUD/HitConfirm") as Label
	label.text = "KILL" if result.killed else (
		"CRITICAL" if result.critical else "HIT"
	)
	label.modulate = Color(1.0, 0.3, 0.22, 1.0) if result.critical else Color.WHITE
	if hit_confirm_tween != null and hit_confirm_tween.is_valid():
		hit_confirm_tween.kill()
	hit_confirm_tween = create_tween()
	hit_confirm_tween.tween_property(label, "modulate:a", 0.0, 0.18)

func _on_player_health_changed(current: float, maximum: float) -> void:
	var label := get_node_or_null("HUD/PlayerHealth") as Label
	if label != null:
		label.text = "HP %d / %d" % [ceili(current), ceili(maximum)]

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

func _on_player_died() -> void:
	var game_over := get_node_or_null("HUD/GameOver") as Label
	if game_over != null:
		game_over.visible = true
	var objective := get_node_or_null("HUD/Objective") as Label
	if objective != null:
		objective.text = "OBJECTIVE FAILED — PLAYER DOWN"
