extends CharacterBody3D
class_name PlayerController

const PlayerMotion = preload("res://scripts/player/player_motion.gd")
const HitResult = preload("res://scripts/combat/hit_result.gd")
const Health = preload("res://scripts/combat/health.gd")

signal attack_resolved(
	direction: Vector3,
	result: HitResult,
	camera_impulse_strength: float
)
signal health_changed(current: float, maximum: float)
signal damaged(amount: float)
signal died

@export_group("Survivability")
@export var max_health := 100.0
@export var hit_reaction_duration := 0.24

@export_group("Input Actions")
@export var move_left_action: StringName = &"move_left"
@export var move_right_action: StringName = &"move_right"
@export var move_forward_action: StringName = &"move_forward"
@export var move_back_action: StringName = &"move_back"
@export_range(0.0, 1.0, 0.01) var move_input_deadzone := 0.0
@export var jump_action: StringName = &"jump"
@export var primary_attack_action: StringName = &"primary_attack"
@export var pistol_action: StringName = &"weapon_pistol"
@export var rifle_action: StringName = &"weapon_rifle"
@export var knife_action: StringName = &"weapon_knife"
@export var slot_four_action: StringName = &"weapon_slot_4"

@export_group("Movement Feel")
@export var move_speed: float = 6.0
@export var ground_acceleration: float = 42.0
@export var ground_deceleration: float = 60.0
@export var air_acceleration: float = 12.0
@export var gravity: float = 24.0
@export var jump_speed: float = 8.5

@export_group("Weapon Feel")
@export var visual_recoil_recovery := 1.2

@onready var visual_root: Node3D = $VisualRoot
@onready var equipment: EquipmentController = $EquipmentController
@onready var functional_ray_origin: Marker3D = $FunctionalRayOrigin

var movement_camera: Camera3D
var animation_player: AnimationPlayer
var aim_direction := Vector3.FORWARD
var visual_rest_position := Vector3.ZERO
var visual_recoil_offset := 0.0
var health: Health
var defeated := false
var hit_reaction_remaining := 0.0
var attack_animation_remaining := 0.0

func _ready() -> void:
	_ensure_health_initialized()
	animation_player = visual_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	visual_rest_position = visual_root.position
	equipment.attack_started.connect(_on_weapon_attack_started)
	equipment.attack_resolved.connect(_on_weapon_attack_resolved)
	equipment.weapon_changed.connect(_on_weapon_changed)
	equipment.setup(self, visual_root, functional_ray_origin)

func _process(delta: float) -> void:
	hit_reaction_remaining = maxf(hit_reaction_remaining - delta, 0.0)
	attack_animation_remaining = maxf(attack_animation_remaining - delta, 0.0)
	visual_recoil_offset = move_toward(
		visual_recoil_offset,
		0.0,
		visual_recoil_recovery * delta
	)
	visual_root.position = visual_rest_position + Vector3(0.0, 0.0, visual_recoil_offset)

func set_movement_camera(camera: Camera3D) -> void:
	movement_camera = camera

func get_move_input_vector() -> Vector2:
	return Input.get_vector(
		move_left_action,
		move_right_action,
		move_forward_action,
		move_back_action,
		move_input_deadzone
	)

func _physics_process(delta: float) -> void:
	if defeated:
		_update_defeated_motion(delta)
		return
	var input_vector := get_move_input_vector()
	var camera_basis := movement_camera.global_basis if movement_camera != null else Basis.IDENTITY
	var move_direction := PlayerMotion.world_direction(input_vector, camera_basis)

	aim_direction = PlayerMotion.next_aim_direction(
		move_direction,
		aim_direction
	)
	rotation.y = PlayerMotion.next_facing_yaw(aim_direction, rotation.y)
	if Input.is_action_just_pressed(pistol_action):
		equipment.equip_slot(0)
	elif Input.is_action_just_pressed(rifle_action):
		equipment.equip_slot(1)
	elif Input.is_action_just_pressed(knife_action):
		equipment.equip_slot(2)
	elif Input.is_action_just_pressed(slot_four_action):
		equipment.equip_slot(3)

	var trigger_pressed := Input.is_action_pressed(primary_attack_action)
	var trigger_just_pressed := Input.is_action_just_pressed(primary_attack_action)
	if hit_reaction_remaining > 0.0:
		trigger_pressed = false
		trigger_just_pressed = false
	equipment.set_attack_input(trigger_pressed, trigger_just_pressed, aim_direction)

	var acceleration := ground_acceleration if is_on_floor() else air_acceleration
	var deceleration := ground_deceleration if is_on_floor() else air_acceleration
	var planar_velocity := PlayerMotion.next_planar_velocity(
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
		Input.is_action_just_pressed(jump_action),
		delta,
		gravity,
		jump_speed
	)
	move_and_slide()
	_update_animation(Vector2(velocity.x, velocity.z).length())

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
	if defeated or hit_reaction_remaining > 0.0:
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

func apply_damage(amount: float, _source_position := Vector3.ZERO) -> float:
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
		hit_reaction_remaining = hit_reaction_duration
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
	equipment.set_attack_input(false, false, aim_direction)
	velocity.x = move_toward(velocity.x, 0.0, ground_deceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, ground_deceleration * delta)
	velocity.y = PlayerMotion.next_vertical_velocity(
		velocity.y,
		is_on_floor(),
		false,
		delta,
		gravity,
		jump_speed
	)
	move_and_slide()

func _on_health_changed(current: float, maximum: float) -> void:
	health_changed.emit(current, maximum)

func _on_depleted() -> void:
	equipment.cancel_attack()
	attack_animation_remaining = 0.0
	defeated = true
	hit_reaction_remaining = 0.0
	velocity.x = 0.0
	velocity.z = 0.0
	if animation_player != null and animation_player.has_animation(&"Death"):
		animation_player.play(&"Death", 0.08)
	died.emit()
