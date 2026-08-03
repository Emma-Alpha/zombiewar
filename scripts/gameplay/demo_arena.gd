extends Node3D

@onready var player: PlayerController = $Player
@onready var follow_camera: FollowCamera = $FollowCamera
@onready var camera: Camera3D = $FollowCamera/Camera3D

func _ready() -> void:
	follow_camera.set_target(player)
	player.set_aim_camera(camera)
