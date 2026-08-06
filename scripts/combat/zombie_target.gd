extends CharacterBody3D
class_name ZombieTarget

const Health = preload("res://scripts/combat/health.gd")
const HitResponseMath = preload("res://scripts/combat/hit_response_math.gd")
const HitResult = preload("res://scripts/combat/hit_result.gd")
const MeleeAttackCycle = preload("res://scripts/combat/melee_attack_cycle.gd")
const ZombieBehaviorMath = preload("res://scripts/combat/zombie_behavior_math.gd")
const BloodTrailState = preload("res://scripts/fx/blood_trail_state.gd")
const BLOOD_IMPACT_SCENE := preload("res://scenes/fx/BloodImpact.tscn")

signal ground_blood_requested(
	origin: Vector3,
	direction: Vector3,
	intensity: float,
	death_pool: bool
)
signal ground_blood_trail_requested(
	position: Vector3,
	direction: Vector3,
	intensity: float,
	progress: float
)

@export var max_health: float = 50.0
@export var knockback_impulse: float = 6.0
@export var ground_drag: float = 11.0
@export var air_drag: float = 2.5
@export var gravity_multiplier: float = 1.0
@export var reaction_spring: float = 18.0
@export var reaction_damping: float = 8.0
@export var max_visual_tilt_degrees: float = 18.0

@export_group("Ambient Behavior")
@export var perception_range := 7.0
@export var perception_exit_margin := 1.0
@export var wander_speed := 0.55
@export var wander_radius := 3.5
@export var wander_arrive_range := 0.25
@export var wander_pause_min := 0.4
@export var wander_pause_max := 1.2
@export var perception_slow_radius := 1.5
@export var movement_acceleration := 5.0

@export_group("Attack Behavior")
@export var attack_range := 1.45
@export var attack_damage := 10.0
@export var attack_cooldown := 1.40
@export var attack_windup := 0.50
@export var attack_animation_duration := 0.70

@export_group("Navigation")
@export var navigation_target_refresh_distance := 0.35
@export_flags_3d_physics var attack_obstacle_mask := 1

@onready var visual_root: Node3D = $VisualRoot
@onready var motion_collision: CollisionShape3D = $MotionCollision
@onready var hitbox_root: Node3D = $Hitboxes
@onready var health_label: Label3D = $HealthLabel
@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D

var health: Health
var animation_player: AnimationPlayer
var visual_rest_rotation: Vector3
var reaction_rotation := Vector3.ZERO
var reaction_angular_velocity := Vector3.ZERO
var depleted := false
var hit_animation_cooldown := 0.0
var attack_target: PlayerController
var attack_cycle: MeleeAttackCycle
var attack_animation_remaining := 0.0
var perception_move_speed := 1.30
var behavior_state := ZombieBehaviorMath.State.WANDER
var home_position := Vector3.ZERO
var wander_target := Vector3.ZERO
var wander_pause_remaining := 0.0
var wander_rng := RandomNumberGenerator.new()
var blood_trail_state := BloodTrailState.new()
var has_navigation_target := false
var last_navigation_target := Vector3.ZERO
var navigation_manager: NavigationWorldManager

func _ready() -> void:
	_ensure_initialized()
	home_position = global_position
	wander_rng.seed = hash(str(get_path()))
	_select_wander_target()

func _ensure_initialized() -> void:
	if visual_root == null:
		visual_root = get_node("VisualRoot") as Node3D
	if motion_collision == null:
		motion_collision = get_node("MotionCollision") as CollisionShape3D
	if hitbox_root == null:
		hitbox_root = get_node("Hitboxes") as Node3D
	if health_label == null:
		health_label = get_node("HealthLabel") as Label3D
	if health == null:
		health = Health.new(max_health)
		health.changed.connect(_on_health_changed)
		health.depleted.connect(_on_depleted)
		visual_rest_rotation = visual_root.rotation
		_refresh_label()
	if attack_cycle == null:
		attack_cycle = MeleeAttackCycle.new(attack_cooldown, attack_windup)
	if animation_player == null:
		animation_player = visual_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if animation_player != null:
			if not animation_player.animation_finished.is_connected(_on_animation_finished):
				animation_player.animation_finished.connect(_on_animation_finished)
			animation_player.play(&"Idle")

func set_attack_target(target: PlayerController) -> void:
	attack_target = target

func set_navigation_manager(manager: NavigationWorldManager) -> void:
	navigation_manager = manager

func set_perception_move_speed(speed: float) -> void:
	perception_move_speed = maxf(speed, 0.0)

func get_behavior_state() -> int:
	return behavior_state

func get_aim_point() -> Vector3:
	var body := get_node_or_null("Hitboxes/BodyHitbox") as Area3D
	return body.global_position if body != null else global_position + Vector3.UP * 1.1

func apply_hit(
	amount: float,
	hit_position: Vector3,
	shot_direction: Vector3
) -> HitResult:
	_ensure_initialized()
	if depleted:
		return HitResult.miss(hit_position)
	attack_cycle.cancel_pending()
	attack_animation_remaining = 0.0
	var applied_damage := health.apply_damage(maxf(amount, 0.0))
	if applied_damage <= 0.0:
		return HitResult.miss(hit_position)

	var knockback_multiplier := 1.0
	var impulse := HitResponseMath.knockback_velocity(
		shot_direction,
		knockback_impulse,
		knockback_multiplier,
		0.05
	)
	velocity += impulse
	var knockback_origin := global_position if is_inside_tree() else position
	blood_trail_state.start(knockback_origin, knockback_multiplier)
	_apply_visual_torque(hit_position, impulse)
	_spawn_blood_impact(hit_position, shot_direction, 1.0)
	visual_root.scale = Vector3.ONE * 1.08
	var killed := health.current <= 0.0
	var ground_blood_direction := _ground_blood_direction(shot_direction)
	ground_blood_requested.emit(hit_position, ground_blood_direction, knockback_multiplier, false)
	if killed:
		ground_blood_requested.emit(knockback_origin, ground_blood_direction, 1.25, true)
	if not killed:
		_play_hit_reaction()
	return HitResult.resolved(
		applied_damage,
		&"body",
		false,
		killed,
		hit_position
	)

func apply_damage(amount: float, hit_position: Vector3) -> HitResult:
	return apply_hit(amount, hit_position, Vector3.ZERO)

func _physics_process(delta: float) -> void:
	_ensure_initialized()
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	if not is_on_floor():
		velocity.y -= gravity * gravity_multiplier * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0

	var target_alive := _target_is_alive() and not depleted
	var direction_to_target := Vector3.ZERO
	var distance_to_target := INF
	if target_alive:
		direction_to_target = attack_target.global_position - global_position
		direction_to_target.y = 0.0
		distance_to_target = direction_to_target.length()
		if distance_to_target > 0.001:
			direction_to_target /= distance_to_target
	else:
		has_navigation_target = false
	var attack_path_clear := (
		target_alive and
		distance_to_target <= attack_range and
		_attack_path_is_clear()
	)
	var approach_stop_range := ZombieBehaviorMath.approach_stop_range(
		distance_to_target,
		attack_range,
		attack_path_clear
	)

	var previous_state := behavior_state
	behavior_state = ZombieBehaviorMath.next_state(
		behavior_state,
		distance_to_target,
		target_alive,
		perception_range,
		perception_exit_margin,
		attack_range,
		attack_path_clear
	)
	if previous_state == ZombieBehaviorMath.State.ATTACK and behavior_state != ZombieBehaviorMath.State.ATTACK:
		attack_cycle.cancel_pending()
		attack_animation_remaining = 0.0
	if behavior_state == ZombieBehaviorMath.State.ATTACK:
		has_navigation_target = false
	var target_in_range := (
		behavior_state == ZombieBehaviorMath.State.ATTACK and
		target_alive and
		distance_to_target <= attack_range
	)

	var was_winding_up := attack_cycle.is_winding_up()
	var attack_landed := attack_cycle.tick(
		delta,
		target_in_range and hit_animation_cooldown <= 0.0 and not depleted,
		target_alive and not depleted
	)
	if not was_winding_up and attack_cycle.is_winding_up():
		_play_attack_animation()
	if attack_landed and _target_is_alive():
		attack_target.apply_damage(attack_damage, global_position)

	var target_planar_velocity := Vector3.ZERO
	if not depleted and hit_animation_cooldown <= 0.0:
		match behavior_state:
			ZombieBehaviorMath.State.WANDER:
				target_planar_velocity = _wander_velocity(delta)
			ZombieBehaviorMath.State.AWARE_APPROACH:
				target_planar_velocity = _navigation_velocity(
					attack_target.global_position,
					approach_stop_range,
					perception_move_speed,
					perception_slow_radius
				)
			ZombieBehaviorMath.State.ATTACK:
				target_planar_velocity = Vector3.ZERO
	var facing_direction := direction_to_target
	if (
		behavior_state == ZombieBehaviorMath.State.WANDER or
		(
			behavior_state == ZombieBehaviorMath.State.AWARE_APPROACH and
			target_planar_velocity.length_squared() > 0.0001
		)
	):
		facing_direction = target_planar_velocity
	if facing_direction.length_squared() > 0.0001:
		rotation.y = ZombieBehaviorMath.facing_yaw(facing_direction, rotation.y)
	var moving := target_planar_velocity.length_squared() > 0.0001
	var planar_rate := movement_acceleration if moving else (
		ground_drag if is_on_floor() else air_drag
	)
	velocity.x = move_toward(velocity.x, target_planar_velocity.x, planar_rate * delta)
	velocity.z = move_toward(velocity.z, target_planar_velocity.z, planar_rate * delta)
	move_and_slide()
	var trail_samples := blood_trail_state.advance(
		global_position,
		delta,
		Vector2(velocity.x, velocity.z).length(),
		perception_move_speed
	)
	for sample in trail_samples:
		ground_blood_trail_requested.emit(
			sample["position"],
			sample["direction"],
			sample["intensity"],
			sample["progress"]
		)
	_update_visual_reaction(delta)
	_update_locomotion_animation()

func _select_wander_target() -> void:
	wander_target = ZombieBehaviorMath.wander_point(
		home_position,
		wander_rng.randf_range(0.0, TAU),
		wander_rng.randf_range(0.35, 1.0),
		wander_radius
	)

func _wander_velocity(delta: float) -> Vector3:
	if wander_pause_remaining > 0.0:
		wander_pause_remaining = maxf(wander_pause_remaining - delta, 0.0)
		if wander_pause_remaining <= 0.0:
			_select_wander_target()
		return Vector3.ZERO
	var offset := _navigation_velocity(
		wander_target,
		wander_arrive_range,
		wander_speed,
		0.8
	)
	if offset == Vector3.ZERO:
		var navigation_done := (
			_navigation_is_ready() and
			has_navigation_target and
			navigation_agent.is_navigation_finished()
		)
		var direct_done := (
			not _navigation_is_ready() and
			global_position.distance_to(wander_target) <= wander_arrive_range
		)
		if navigation_done or direct_done:
			wander_pause_remaining = wander_rng.randf_range(wander_pause_min, wander_pause_max)
			has_navigation_target = false
	return offset

func _navigation_is_ready() -> bool:
	if (
		navigation_agent == null or
		navigation_manager == null or
		not is_instance_valid(navigation_manager) or
		not navigation_manager.is_navigation_ready_at(global_position)
	):
		return false
	var navigation_map := navigation_agent.get_navigation_map()
	return (
		navigation_map.is_valid() and
		NavigationServer3D.map_get_iteration_id(navigation_map) > 0
	)

func _refresh_navigation_target(target_position: Vector3) -> void:
	if (
		not has_navigation_target or
		Vector2(last_navigation_target.x, last_navigation_target.z).distance_to(
			Vector2(target_position.x, target_position.z)
		) >= navigation_target_refresh_distance
	):
		navigation_agent.target_position = target_position
		last_navigation_target = target_position
		has_navigation_target = true

func _navigation_velocity(
	target_position: Vector3,
	stop_range: float,
	move_speed: float,
	slow_radius: float
) -> Vector3:
	if not _navigation_is_ready():
		has_navigation_target = false
		return ZombieBehaviorMath.arrive_velocity(
			global_position,
			target_position,
			stop_range,
			move_speed,
			slow_radius
		)
	_refresh_navigation_target(target_position)
	if navigation_agent.is_navigation_finished():
		return Vector3.ZERO
	var next_path_position := navigation_agent.get_next_path_position()
	return ZombieBehaviorMath.path_velocity(
		global_position,
		next_path_position,
		target_position,
		stop_range,
		move_speed,
		slow_radius
	)

func _attack_path_is_clear() -> bool:
	if not _target_is_alive() or get_world_3d() == null:
		return false
	var origin := global_position + Vector3.UP * 0.90
	var destination := attack_target.global_position + Vector3.UP * 0.90
	var query := PhysicsRayQueryParameters3D.create(
		origin,
		destination,
		attack_obstacle_mask,
		[get_rid(), attack_target.get_rid()]
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func _process(delta: float) -> void:
	hit_animation_cooldown = maxf(hit_animation_cooldown - delta, 0.0)
	attack_animation_remaining = maxf(attack_animation_remaining - delta, 0.0)
	visual_root.scale = visual_root.scale.move_toward(Vector3.ONE, delta * 1.5)

func _target_is_alive() -> bool:
	return (
		attack_target != null and
		is_instance_valid(attack_target) and
		attack_target.is_alive()
	)

func _play_attack_animation() -> void:
	attack_animation_remaining = attack_animation_duration
	if animation_player != null and animation_player.has_animation(&"Punch"):
		animation_player.play(&"Punch", 0.08)

func _update_locomotion_animation() -> void:
	if animation_player == null or depleted:
		return
	if hit_animation_cooldown > 0.0 or attack_animation_remaining > 0.0:
		return
	var animation_name := &"Walk" if Vector2(velocity.x, velocity.z).length() > 0.2 else &"Idle"
	if animation_player.current_animation != animation_name:
		animation_player.play(animation_name, 0.12)

func _play_hit_reaction() -> void:
	if animation_player == null or hit_animation_cooldown > 0.0:
		return
	attack_cycle.cancel_pending()
	attack_animation_remaining = 0.0
	if animation_player.has_animation(&"HitReact"):
		animation_player.play(&"HitReact", 0.05)
		hit_animation_cooldown = 0.2

func _on_animation_finished(animation_name: StringName) -> void:
	if depleted:
		return
	if animation_name == &"HitReact":
		hit_animation_cooldown = 0.0
	elif animation_name == &"Punch":
		attack_animation_remaining = 0.0
	_update_locomotion_animation()

func _apply_visual_torque(hit_position: Vector3, impulse: Vector3) -> void:
	var local_hit := hit_position - (global_position if is_inside_tree() else position)
	var target_basis := global_basis if is_inside_tree() else basis
	var local_impulse := target_basis.inverse() * impulse
	var torque := local_hit.cross(local_impulse) * 0.075
	reaction_angular_velocity += Vector3(torque.x, 0.0, torque.z)

func _update_visual_reaction(delta: float) -> void:
	reaction_angular_velocity -= reaction_rotation * reaction_spring * delta
	reaction_angular_velocity = reaction_angular_velocity.move_toward(
		Vector3.ZERO,
		reaction_damping * delta
	)
	reaction_rotation += reaction_angular_velocity * delta
	var max_tilt := deg_to_rad(max_visual_tilt_degrees)
	if reaction_rotation.length() > max_tilt:
		reaction_rotation = reaction_rotation.normalized() * max_tilt
	visual_root.rotation = visual_rest_rotation + reaction_rotation

func _spawn_blood_impact(
	hit_position: Vector3,
	shot_direction: Vector3,
	intensity: float
) -> void:
	var effect_parent := get_parent()
	if effect_parent == null:
		return
	var effect := BLOOD_IMPACT_SCENE.instantiate() as BloodImpact
	effect_parent.add_child(effect)
	effect.setup(hit_position, shot_direction, intensity)

func _ground_blood_direction(shot_direction: Vector3) -> Vector3:
	var horizontal_direction := Vector3(shot_direction.x, 0.0, shot_direction.z)
	if horizontal_direction.length_squared() <= 0.000001:
		horizontal_direction = -global_transform.basis.z
		horizontal_direction.y = 0.0
	if horizontal_direction.length_squared() <= 0.000001:
		return Vector3.FORWARD
	return horizontal_direction.normalized()

func _on_health_changed(_current: float, _maximum: float) -> void:
	_refresh_label()

func _on_depleted() -> void:
	depleted = true
	attack_target = null
	has_navigation_target = false
	attack_cycle.cancel_pending()
	attack_animation_remaining = 0.0
	motion_collision.set_deferred("disabled", true)
	for hitbox in hitbox_root.get_children():
		var hitbox_shape := hitbox.get_node_or_null("CollisionShape3D") as CollisionShape3D
		if hitbox_shape != null:
			hitbox_shape.set_deferred("disabled", true)
	health_label.visible = false
	var death_duration := 0.65
	if animation_player != null and animation_player.has_animation(&"Death"):
		animation_player.play(&"Death", 0.08)
		death_duration = minf(animation_player.get_animation(&"Death").length, 1.2)
	await get_tree().create_timer(death_duration).timeout
	queue_free()

func _refresh_label() -> void:
	health_label.text = "%d / %d" % [ceili(health.current), ceili(health.maximum)]
