extends Node3D
class_name FollowCamera

@export var follow_speed: float = 10.0
@export var shot_impulse_strength := 0.06
@export var shot_impulse_maximum := 0.12
@export var shot_impulse_recovery := 1.5

var target: Node3D
var shot_impulse_offset := Vector3.ZERO

static func smoothing_weight(speed: float, delta: float) -> float:
	return 1.0 - exp(-maxf(speed, 0.0) * maxf(delta, 0.0))

func set_target(value: Node3D) -> void:
	target = value
	if target != null:
		global_position.x = target.global_position.x
		global_position.z = target.global_position.z

func add_shot_impulse(
	shot_direction: Vector3,
	strength: float = -1.0
) -> void:
	var planar := Vector3(shot_direction.x, 0.0, shot_direction.z)
	if planar.length_squared() <= 0.000001:
		return
	var resolved_strength := shot_impulse_strength if strength < 0.0 else strength
	shot_impulse_offset -= planar.normalized() * maxf(resolved_strength, 0.0)
	if shot_impulse_offset.length() > shot_impulse_maximum:
		shot_impulse_offset = shot_impulse_offset.normalized() * shot_impulse_maximum

func _physics_process(delta: float) -> void:
	if target == null:
		return
	shot_impulse_offset = shot_impulse_offset.move_toward(
		Vector3.ZERO,
		shot_impulse_recovery * delta
	)
	var desired := Vector3(
		target.global_position.x,
		global_position.y,
		target.global_position.z
	) + shot_impulse_offset
	global_position = global_position.lerp(desired, smoothing_weight(follow_speed, delta))
