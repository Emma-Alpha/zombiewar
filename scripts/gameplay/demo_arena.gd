extends Node3D

func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_wire_dependencies()

func _enter_tree() -> void:
	_wire_dependencies()

func _wire_dependencies() -> void:
	var player := get_node_or_null("Player") as PlayerController
	var follow_camera := get_node_or_null("FollowCamera") as FollowCamera
	var movement_camera := get_node_or_null("FollowCamera/Camera3D") as Camera3D
	if player == null or follow_camera == null or movement_camera == null:
		return
	if follow_camera.is_inside_tree():
		follow_camera.set_target(player)
	else:
		follow_camera.target = player
	player.set_movement_camera(movement_camera)
