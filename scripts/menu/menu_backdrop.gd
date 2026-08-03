extends Node3D

@onready var camera_rig: Node3D = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var warning_light: OmniLight3D = $WarningLight

var elapsed := 0.0
var base_camera_yaw := 0.0

func _ready() -> void:
	base_camera_yaw = camera_rig.rotation.y
	camera.look_at(Vector3(0.0, 1.35, -1.5), Vector3.UP)
	_play_model_animation($SetDressing/PlayerHero, &"Idle_Gun")
	_play_model_animation($SetDressing/ZombieBasic, &"Walk")
	_play_model_animation($SetDressing/ZombieChubby, &"Idle_Attack")

func _process(delta: float) -> void:
	elapsed += delta
	camera_rig.rotation.y = base_camera_yaw + deg_to_rad(sin(elapsed * 0.22) * 0.7)
	warning_light.light_energy = 6.2 + sin(elapsed * 2.1) * 0.45

func _play_model_animation(model_root: Node, animation_name: StringName) -> void:
	var animation_player := model_root.find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if animation_player != null and animation_player.has_animation(animation_name):
		animation_player.play(animation_name, 0.2)
