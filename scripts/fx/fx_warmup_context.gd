extends RefCounted
class_name FxWarmupContext

var camera: Camera3D
var host: Node3D

func _init(value_camera: Camera3D, value_host: Node3D) -> void:
	camera = value_camera
	host = value_host

func forward_direction() -> Vector3:
	return -camera.global_basis.z.normalized()

func position_in_view(
	distance: float,
	offset: Vector2 = Vector2.ZERO
) -> Vector3:
	var forward := forward_direction()
	var right := camera.global_basis.x.normalized()
	var up := camera.global_basis.y.normalized()
	return (
		camera.global_position +
		forward * maxf(distance, 0.1) +
		right * offset.x +
		up * offset.y
	)
