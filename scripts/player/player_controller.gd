extends CharacterBody3D
class_name PlayerController

const PlayerMotion = preload("res://scripts/player/player_motion.gd")
const HIDDEN_WEAPONS: Array[String] = [
	"Axe", "Guitar", "Knife", "Pistol", "Shotgun", "SMG", "Spear",
	"WoodenBat_Barbed", "WoodenBat_Saw",
]

@export_range(0.0, 1.0, 0.01) var move_input_deadzone := 0.0
@export var move_speed: float = 6.0
@export var ground_acceleration: float = 30.0
@export var air_acceleration: float = 12.0
@export var gravity: float = 24.0
@export var jump_speed: float = 8.5

@onready var visual_root: Node3D = $VisualRoot

var movement_camera: Camera3D
var animation_player: AnimationPlayer

func _ready() -> void:
	animation_player = visual_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	for weapon_name in HIDDEN_WEAPONS:
		var weapon_visual := visual_root.find_child(weapon_name, true, false) as Node3D
		if weapon_visual != null:
			weapon_visual.visible = false

func set_movement_camera(camera: Camera3D) -> void:
	movement_camera = camera

func get_move_input_vector() -> Vector2:
	return Input.get_vector(
		&"move_left",
		&"move_right",
		&"move_forward",
		&"move_back",
		move_input_deadzone
	)

func _physics_process(delta: float) -> void:
	var input_vector := get_move_input_vector()
	var camera_basis := movement_camera.global_basis if movement_camera != null else Basis.IDENTITY
	var direction := PlayerMotion.world_direction(input_vector, camera_basis)
	rotation.y = PlayerMotion.next_facing_yaw(direction, rotation.y)
	var target_velocity := direction * move_speed
	var acceleration := ground_acceleration if is_on_floor() else air_acceleration

	velocity.x = move_toward(velocity.x, target_velocity.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_velocity.z, acceleration * delta)
	velocity.y = PlayerMotion.next_vertical_velocity(
		velocity.y,
		is_on_floor(),
		Input.is_action_just_pressed("jump"),
		delta,
		gravity,
		jump_speed
	)
	move_and_slide()
	_update_animation(Vector2(velocity.x, velocity.z).length())

func _update_animation(horizontal_speed: float) -> void:
	if animation_player == null:
		return
	var animation_name := &"Idle_Gun"
	if not is_on_floor():
		animation_name = &"Jump_Idle"
	elif horizontal_speed > 0.2:
		animation_name = &"Run_Gun"
	if animation_player.current_animation != animation_name:
		animation_player.play(animation_name, 0.15)
