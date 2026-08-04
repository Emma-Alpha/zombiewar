extends Sprite3D
class_name GroundBloodSplat

@export var base_diameter := 0.82
@export var surface_offset := 0.012

static func surface_basis(
	surface_normal: Vector3,
	random_rotation: float
) -> Basis:
	var normal := surface_normal.normalized()
	if normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	var reference := Vector3.RIGHT
	if absf(reference.dot(normal)) > 0.95:
		reference = Vector3.FORWARD
	var local_y := normal.cross(reference).normalized()
	var local_x := local_y.cross(normal).normalized()
	return Basis(local_x, local_y, normal).rotated(normal, random_rotation)

func _ready() -> void:
	set_process(false)

func setup(
	surface_position: Vector3,
	surface_normal: Vector3,
	diameter: float,
	random_rotation: float,
	tint: Color
) -> void:
	var normal := surface_normal.normalized()
	if normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	var resolved_position := surface_position + normal * surface_offset
	if is_inside_tree():
		global_position = resolved_position
		global_basis = surface_basis(normal, random_rotation)
	else:
		position = resolved_position
		basis = surface_basis(normal, random_rotation)
	var resolved_scale := maxf(diameter, 0.05) / maxf(base_diameter, 0.05)
	scale = Vector3.ONE * resolved_scale
	modulate = tint
	visible = true
