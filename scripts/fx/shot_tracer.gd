extends MeshInstance3D
class_name ShotTracer

@export var lifetime: float = 0.08

var remaining: float

func setup(from: Vector3, to: Vector3) -> void:
	var distance := from.distance_to(to)
	if distance <= 0.001:
		queue_free()
		return

	remaining = lifetime
	global_position = (from + to) * 0.5
	look_at(to, Vector3.UP)

	var tracer_mesh := BoxMesh.new()
	tracer_mesh.size = Vector3(0.035, 0.035, distance)
	mesh = tracer_mesh

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.78, 0.18)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.45, 0.05)
	material.emission_energy_multiplier = 3.0
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = material

func _process(delta: float) -> void:
	remaining -= delta
	transparency = clampf(1.0 - remaining / lifetime, 0.0, 1.0)
	if remaining <= 0.0:
		queue_free()
