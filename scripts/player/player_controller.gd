extends CharacterBody3D
class_name PlayerController

const PlayerMotion = preload("res://scripts/player/player_motion.gd")
const HitResult = preload("res://scripts/combat/hit_result.gd")
const Health = preload("res://scripts/combat/health.gd")
const HIDDEN_WEAPONS: Array[String] = [
	"Axe", "Guitar", "Knife", "Pistol", "Shotgun", "SMG", "Spear",
	"WoodenBat_Barbed", "WoodenBat_Saw",
]

signal shot_fired(direction: Vector3, result: HitResult)
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
@export var fire_action: StringName = &"fire"

@export_group("Movement Feel")
@export var move_speed: float = 6.0
@export var ground_acceleration: float = 42.0
@export var ground_deceleration: float = 60.0
@export var air_acceleration: float = 12.0
@export var gravity: float = 24.0
@export var jump_speed: float = 8.5

@export_group("Weapon Feel")
@export var visual_recoil_kick := 0.08
@export var visual_recoil_recovery := 1.2

@onready var visual_root: Node3D = $VisualRoot
@onready var weapon: PlayerWeapon = $Weapon
@onready var functional_ray_origin: Marker3D = $FunctionalRayOrigin

var movement_camera: Camera3D
var animation_player: AnimationPlayer
var aim_direction := Vector3.FORWARD
var visual_rest_position := Vector3.ZERO
var visual_recoil_offset := 0.0
var health: Health
var defeated := false
var hit_reaction_remaining := 0.0

func _ready() -> void:
	_ensure_health_initialized()
	animation_player = visual_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	for weapon_name in HIDDEN_WEAPONS:
		var weapon_visual := visual_root.find_child(weapon_name, true, false) as Node3D
		if weapon_visual != null:
			weapon_visual.visible = false
	var rifle_visual := visual_root.find_child("Rifle", true, false) as Node3D
	if rifle_visual != null:
		weapon.bind_visual_anchor(rifle_visual)
	functional_ray_origin.global_position = weapon.muzzle.global_position
	weapon.bind_functional_ray_origin(functional_ray_origin)
	visual_rest_position = visual_root.position
	if not weapon.shot_fired.is_connected(_on_weapon_shot_fired):
		weapon.shot_fired.connect(_on_weapon_shot_fired)

func _process(delta: float) -> void:
	hit_reaction_remaining = maxf(hit_reaction_remaining - delta, 0.0)
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
	var trigger_pressed := Input.is_action_pressed(fire_action)
	var trigger_just_pressed := Input.is_action_just_pressed(fire_action)

	aim_direction = PlayerMotion.next_aim_direction(
		move_direction,
		aim_direction
	)
	rotation.y = PlayerMotion.next_facing_yaw(aim_direction, rotation.y)
	weapon.set_combat_input(trigger_pressed, trigger_just_pressed, aim_direction)

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
	if animation_player == null or defeated or hit_reaction_remaining > 0.0:
		return
	var animation_name := &"Idle_Gun"
	if not is_on_floor():
		animation_name = &"Jump_Idle"
	elif horizontal_speed > 0.2:
		animation_name = &"Run_Gun"
	if animation_player.current_animation != animation_name:
		animation_player.play(animation_name, 0.15)

func _on_weapon_shot_fired(
	_origin: Vector3,
	direction: Vector3,
	result: HitResult
) -> void:
	visual_recoil_offset = minf(visual_recoil_offset + visual_recoil_kick, 0.12)
	shot_fired.emit(direction, result)

func apply_damage(amount: float, _source_position := Vector3.ZERO) -> float:
	_ensure_health_initialized()
	if defeated:
		return 0.0
	var applied := health.apply_damage(amount)
	if applied <= 0.0:
		return 0.0
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
	weapon.set_combat_input(false, false, aim_direction)
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
	defeated = true
	hit_reaction_remaining = 0.0
	velocity.x = 0.0
	velocity.z = 0.0
	weapon.set_combat_input(false, false, aim_direction)
	weapon.set_physics_process(false)
	weapon.set_aim_indicator_visible(false)
	if animation_player != null and animation_player.has_animation(&"Death"):
		animation_player.play(&"Death", 0.08)
	died.emit()
