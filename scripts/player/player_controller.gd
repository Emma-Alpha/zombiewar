extends CharacterBody3D
class_name PlayerController

const PlayerMotion = preload("res://scripts/player/player_motion.gd")
const PlayerScreenBoundsScript = preload(
	"res://scripts/camera/player_screen_bounds.gd"
)
const HitResult = preload("res://scripts/combat/hit_result.gd")
const Health = preload("res://scripts/combat/health.gd")
const WeaponMath = preload("res://scripts/combat/weapon_math.gd")
const RangedWeaponDefinition = preload(
	"res://scripts/combat/weapons/ranged_weapon_definition.gd"
)
const PlayerInputStateScript = preload("res://scripts/input/player_input_state.gd")

signal attack_resolved(
	direction: Vector3,
	result: HitResult,
	camera_impulse_strength: float
)
signal health_changed(current: float, maximum: float)
signal damaged(amount: float)
signal died

@export_group("Survivability")
@export var player_index := 0
@export var max_health := 100.0
@export var hit_reaction_duration := 0.24
@export var hit_attack_lock_duration := 1.2
@export var hit_knockback_speed := 8.0
@export var hit_knockback_deceleration := 18.0

@export_group("Movement Feel")
@export var move_speed: float = 5.0
@export var ground_acceleration: float = 30.0
@export var ground_deceleration: float = 42.0
@export var air_acceleration: float = 12.0
@export var gravity: float = 24.0
@export_range(0.0, 0.25, 0.01) var screen_safe_margin_ratio := 0.08

@export_group("Weapon Feel")
@export var visual_recoil_recovery := 1.2

@onready var visual_root: Node3D = $VisualRoot
@onready var equipment: EquipmentController = $EquipmentController
@onready var functional_ray_origin: Marker3D = $FunctionalRayOrigin
@onready var weapon_clearance: WeaponClearanceController = $WeaponClearanceController
@onready var health_bar: HealthBar3D = get_node_or_null("HealthBar3D") as HealthBar3D
@onready var equipment_label = get_node_or_null(
	"PlayerEquipmentLabel"
)

var movement_camera: Camera3D
var screen_camera: Camera3D
var animation_player: AnimationPlayer
var aim_direction := Vector3.FORWARD
var visual_rest_position := Vector3.ZERO
var visual_recoil_offset := 0.0
var health: Health
var defeated := false
var hit_reaction_remaining := 0.0
var hit_attack_lock_remaining := 0.0
var knockback_velocity := Vector3.ZERO
var attack_animation_remaining := 0.0
var health_bar_initialized := false
var missing_health_bar_warned := false
var input_source
var last_input_state = PlayerInputStateScript.new()
var place_item_service

func _ready() -> void:
	_ensure_health_initialized()
	_sync_health_bar(false)
	health_bar_initialized = true
	animation_player = visual_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	visual_rest_position = visual_root.position
	weapon_clearance.setup(self)
	equipment.attack_started.connect(_on_weapon_attack_started)
	equipment.attack_resolved.connect(_on_weapon_attack_resolved)
	equipment.weapon_changed.connect(_on_weapon_changed)
	equipment.equipment_changed.connect(_on_equipment_changed)
	equipment.setup(
		self,
		visual_root,
		functional_ray_origin,
		Callable(weapon_clearance, "try_bind_weapon")
	)
	equipment.set_place_item_service(place_item_service)
	_on_equipment_changed(
		equipment.get_current_display_name(),
		equipment.get_current_count_text()
	)

func _process(delta: float) -> void:
	hit_reaction_remaining = maxf(hit_reaction_remaining - delta, 0.0)
	hit_attack_lock_remaining = maxf(hit_attack_lock_remaining - delta, 0.0)
	attack_animation_remaining = maxf(attack_animation_remaining - delta, 0.0)
	visual_recoil_offset = move_toward(
		visual_recoil_offset,
		0.0,
		visual_recoil_recovery * delta
	)
	visual_root.position = visual_rest_position + Vector3(0.0, 0.0, visual_recoil_offset)

func set_movement_camera(camera: Camera3D) -> void:
	movement_camera = camera

func set_screen_camera(camera: Camera3D) -> void:
	screen_camera = camera

func set_input_source(value) -> void:
	input_source = value
	if input_source != null:
		input_source.reset_edges()

func get_input_source():
	return input_source

func get_last_input_state():
	return last_input_state

func is_input_online() -> bool:
	return input_source != null and input_source.is_online()

func set_place_item_service(service) -> void:
	place_item_service = service
	if equipment != null:
		equipment.set_place_item_service(place_item_service)

func receive_equipment_pickup(
	item_id: StringName,
	amount: int,
	auto_equip: bool = false
) -> bool:
	if defeated:
		return false
	return equipment.grant_item(item_id, amount, auto_equip)

func receive_ammo_pickup(item_id: StringName, amount: int) -> bool:
	if defeated:
		return false
	return equipment.add_ammo(item_id, amount) > 0

func _physics_process(delta: float) -> void:
	last_input_state = (
		input_source.sample() if input_source != null else PlayerInputStateScript.new()
	)
	if defeated:
		_update_defeated_motion(delta)
		return
	var knockback_active := knockback_velocity.length_squared() > 0.000001
	var input_vector: Vector2 = (
		Vector2.ZERO if knockback_active else last_input_state.move_vector
	)
	var camera_basis := movement_camera.global_basis if movement_camera != null else Basis.IDENTITY
	var move_direction := PlayerMotion.world_direction(input_vector, camera_basis)

	aim_direction = PlayerMotion.next_aim_direction(
		move_direction,
		aim_direction
	)
	var target_yaw := PlayerMotion.next_facing_yaw(aim_direction, rotation.y)
	if last_input_state.previous_equipment_just_pressed:
		equipment.equip_previous()
	elif last_input_state.next_equipment_just_pressed:
		equipment.equip_next()

	var acceleration := ground_acceleration if is_on_floor() else air_acceleration
	var deceleration := ground_deceleration if is_on_floor() else air_acceleration
	var planar_velocity := knockback_velocity
	if not knockback_active:
		planar_velocity = PlayerMotion.next_planar_velocity(
			velocity,
			move_direction,
			move_speed,
			acceleration,
			deceleration,
			delta
		)
	velocity.x = planar_velocity.x
	velocity.z = planar_velocity.z
	velocity.y = PlayerMotion.next_vertical_velocity(
		velocity.y,
		is_on_floor(),
		delta,
		gravity
	)
	var desired_motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	if screen_camera != null and is_input_online():
		desired_motion = PlayerScreenBoundsScript.limit_motion(
			screen_camera,
			global_position,
			desired_motion,
			screen_safe_margin_ratio
		)
		if delta > 0.000001:
			velocity.x = desired_motion.x / delta
			velocity.z = desired_motion.z / delta
			if knockback_active:
				knockback_velocity.x = velocity.x
				knockback_velocity.z = velocity.z
	weapon_clearance.update_clearance(
		delta,
		desired_motion,
		target_yaw
	)
	rotation.y = target_yaw
	var trigger_pressed: bool = last_input_state.use_pressed
	var trigger_just_pressed: bool = last_input_state.use_just_pressed
	var attack_locked := (
		hit_reaction_remaining > 0.0 or
		hit_attack_lock_remaining > 0.0
	)
	if attack_locked:
		trigger_pressed = false
		trigger_just_pressed = false
		equipment.cancel_use()
	var attack_direction := aim_direction
	if equipment.get_current_definition() is RangedWeaponDefinition:
		attack_direction = _actual_ranged_attack_direction()
	equipment.set_use_input(trigger_pressed, trigger_just_pressed, attack_direction)
	move_and_slide()
	if knockback_active:
		knockback_velocity = PlayerMotion.next_knockback_velocity(
			Vector3(velocity.x, 0.0, velocity.z),
			hit_knockback_deceleration,
			delta
		)
		velocity.x = knockback_velocity.x
		velocity.z = knockback_velocity.z
	_update_animation(Vector2(velocity.x, velocity.z).length())

func _actual_ranged_attack_direction() -> Vector3:
	return WeaponMath.flat_direction(-global_basis.z)

func _update_animation(horizontal_speed: float) -> void:
	if animation_player == null or defeated:
		return
	if hit_reaction_remaining > 0.0:
		return
	if attack_animation_remaining > 0.0:
		return
	var animation_name := equipment.get_idle_animation()
	if not is_on_floor():
		animation_name = &"Jump_Idle"
	elif horizontal_speed > 0.2:
		animation_name = equipment.get_run_animation()
	if animation_player.current_animation != animation_name:
		animation_player.play(animation_name, 0.15)

func _on_weapon_attack_started(
	animation_name: StringName,
	lock_duration: float
) -> void:
	if (
		defeated or
		hit_reaction_remaining > 0.0 or
		hit_attack_lock_remaining > 0.0
	):
		equipment.cancel_attack()
		attack_animation_remaining = 0.0
		return
	attack_animation_remaining = maxf(lock_duration, 0.0)
	if (
		animation_player != null and
		not animation_name.is_empty() and
		animation_player.has_animation(animation_name)
	):
		animation_player.play(animation_name, 0.05)

func _on_weapon_attack_resolved(
	_origin: Vector3,
	direction: Vector3,
	result: HitResult,
	recoil_kick: float,
	camera_impulse_strength: float
) -> void:
	visual_recoil_offset = minf(
		visual_recoil_offset + maxf(recoil_kick, 0.0),
		0.12
	)
	attack_resolved.emit(direction, result, camera_impulse_strength)

func _on_weapon_changed(_definition: WeaponDefinition) -> void:
	attack_animation_remaining = 0.0
	_update_animation(Vector2(velocity.x, velocity.z).length())

func _on_equipment_changed(display_name: String, count_text: String) -> void:
	if equipment_label != null:
		equipment_label.set_status(player_index, display_name, count_text)

func apply_damage(amount: float, source_position := Vector3.ZERO) -> float:
	_ensure_health_initialized()
	if defeated:
		return 0.0
	var applied := health.apply_damage(amount)
	if applied <= 0.0:
		return 0.0
	equipment.cancel_attack()
	attack_animation_remaining = 0.0
	damaged.emit(applied)
	if not defeated:
		hit_reaction_remaining = maxf(hit_reaction_duration, 0.0)
		hit_attack_lock_remaining = maxf(hit_attack_lock_duration, 0.0)
		var facing_direction := -global_basis.z
		knockback_velocity = PlayerMotion.knockback_direction(
			global_position,
			source_position,
			facing_direction
		) * maxf(hit_knockback_speed, 0.0)
		if animation_player != null and animation_player.has_animation(&"HitReact"):
			animation_player.play(&"HitReact", 0.05)
	return applied

func is_alive() -> bool:
	return not defeated

func _ensure_health_initialized() -> void:
	if health != null:
		return
	health = Health.new(max_health)
	health.changed.connect(_on_health_changed)
	health.depleted.connect(_on_depleted)
	health_changed.emit(health.current, health.maximum)

func _update_defeated_motion(delta: float) -> void:
	equipment.set_use_input(false, false, aim_direction)
	velocity.x = move_toward(velocity.x, 0.0, ground_deceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, ground_deceleration * delta)
	velocity.y = PlayerMotion.next_vertical_velocity(
		velocity.y,
		is_on_floor(),
		delta,
		gravity
	)
	move_and_slide()

func _on_health_changed(current: float, maximum: float) -> void:
	health_changed.emit(current, maximum)
	_sync_health_bar(health_bar_initialized)

func _sync_health_bar(animate: bool) -> void:
	if health_bar == null:
		if not missing_health_bar_warned:
			push_warning("Player is missing HealthBar3D")
			missing_health_bar_warned = true
		return
	if health != null:
		health_bar.set_health(health.current, health.maximum, animate)

func _on_depleted() -> void:
	equipment.cancel_attack()
	weapon_clearance.reset()
	attack_animation_remaining = 0.0
	defeated = true
	hit_reaction_remaining = 0.0
	hit_attack_lock_remaining = 0.0
	knockback_velocity = Vector3.ZERO
	velocity.x = 0.0
	velocity.z = 0.0
	if animation_player != null and animation_player.has_animation(&"Death"):
		animation_player.play(&"Death", 0.08)
	if equipment_label != null:
		equipment_label.set_status(player_index, "倒地", "")
	died.emit()
