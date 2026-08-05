extends MeshInstance3D
class_name ShotTracer

@export var lifetime: float = 0.08

var remaining: float

func _ready() -> void:
	deactivate()

func setup(from: Vector3, to: Vector3) -> void:
	var distance := from.distance_to(to)
	if distance <= 0.001:
		deactivate()
		return

	remaining = maxf(lifetime, 0.001)
	global_position = (from + to) * 0.5
	scale = Vector3.ONE
	look_at(to, Vector3.UP)
	scale.z = distance
	set_instance_shader_parameter("lifetime_alpha", 1.0)
	visible = true
	set_process(true)

func deactivate() -> void:
	remaining = 0.0
	set_instance_shader_parameter("lifetime_alpha", 0.0)
	visible = false
	set_process(false)

func _process(delta: float) -> void:
	remaining -= delta
	var alpha := clampf(
		remaining / maxf(lifetime, 0.001),
		0.0,
		1.0
	)
	set_instance_shader_parameter("lifetime_alpha", alpha)
	if remaining <= 0.0:
		deactivate()
