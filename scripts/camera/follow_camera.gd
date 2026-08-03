extends Node3D
class_name FollowCamera

@export var follow_speed: float = 10.0

var target: Node3D

static func smoothing_weight(speed: float, delta: float) -> float:
	return 1.0 - exp(-maxf(speed, 0.0) * maxf(delta, 0.0))

func set_target(value: Node3D) -> void:
	target = value
	if target != null:
		global_position.x = target.global_position.x
		global_position.z = target.global_position.z

func _physics_process(delta: float) -> void:
	if target == null:
		return
	var desired := Vector3(target.global_position.x, global_position.y, target.global_position.z)
	global_position = global_position.lerp(desired, smoothing_weight(follow_speed, delta))
