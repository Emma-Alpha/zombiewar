extends CharacterBody3D
class_name PlayerController

const PlayerMotion = preload("res://scripts/player/player_motion.gd")
const HIDDEN_WEAPONS: Array[String] = [
	"Axe", "Guitar", "Knife", "Pistol", "Shotgun", "SMG", "Spear",
	"WoodenBat_Barbed", "WoodenBat_Saw",
]

@export var move_speed: float = 6.0
@export var ground_acceleration: float = 30.0
@export var air_acceleration: float = 12.0
@export var gravity: float = 24.0
@export var jump_speed: float = 8.5

@onready var visual_root: Node3D = $VisualRoot
@onready var weapon: Node3D = $Weapon

var aim_camera: Camera3D
var animation_player: AnimationPlayer

func _ready() -> void:
	animation_player = visual_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	for weapon_name in HIDDEN_WEAPONS:
		var weapon_visual := visual_root.find_child(weapon_name, true, false) as Node3D
		if weapon_visual != null:
			weapon_visual.visible = false

func set_aim_camera(camera: Camera3D) -> void:
	aim_camera = camera
	if weapon.has_method("set_aim_camera"):
		weapon.call("set_aim_camera", camera)

func face_world_point(world_point: Vector3) -> void:
	var flat_target := Vector3(world_point.x, global_position.y, world_point.z)
	if global_position.distance_squared_to(flat_target) > 0.0001:
		look_at(flat_target, Vector3.UP)

func _physics_process(delta: float) -> void:
	var input_vector := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var camera_basis := aim_camera.global_basis if aim_camera != null else Basis.IDENTITY
	var direction := PlayerMotion.world_direction(input_vector, camera_basis)
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
