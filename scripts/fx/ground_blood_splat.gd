extends MeshInstance3D
class_name GroundBloodSplat

@export var surface_offset := 0.012

var base_size := Vector2.ONE
var current_size := Vector2.ONE
var current_tint := Color.WHITE
var current_surface_normal := Vector3.UP
var current_rotation := 0.0

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
	size: Vector2,
	random_rotation: float,
	tint: Color,
	texture: Texture2D,
	roughness: float
) -> void:
	var normal := surface_normal.normalized()
	if normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	base_size = Vector2(maxf(size.x, 0.05), maxf(size.y, 0.05))
	current_size = base_size
	current_tint = tint
	current_surface_normal = normal
	current_rotation = random_rotation
	var resolved_position := surface_position + normal * surface_offset
	if is_inside_tree():
		global_position = resolved_position
	else:
		position = resolved_position
	_apply_size_basis()
	var material := material_override as StandardMaterial3D
	material = material.duplicate() as StandardMaterial3D
	material.albedo_texture = texture
	material.albedo_color = tint
	material.roughness = clampf(roughness, 0.2, 0.8)
	material_override = material
	visible = true

func merge_limited(size_growth: float, darken_amount: float) -> void:
	var maximum_size := base_size * clampf(size_growth, 1.0, 1.15)
	current_size = Vector2(
		minf(current_size.x * 1.03, maximum_size.x),
		minf(current_size.y * 1.03, maximum_size.y)
	)
	current_tint = Color(
		maxf(current_tint.r - maxf(darken_amount, 0.0), 0.24),
		maxf(current_tint.g - maxf(darken_amount, 0.0) * 0.08, 0.002),
		maxf(current_tint.b - maxf(darken_amount, 0.0) * 0.08, 0.006),
		minf(current_tint.a + 0.02, 0.96)
	)
	_apply_size_basis()
	var material := material_override as StandardMaterial3D
	material.albedo_color = current_tint

func _apply_size_basis() -> void:
	var resolved_basis := surface_basis(
		current_surface_normal,
		current_rotation
	).scaled(Vector3(current_size.x, current_size.y, 1.0))
	if is_inside_tree():
		global_basis = resolved_basis
	else:
		basis = resolved_basis
