extends MeshInstance3D
class_name GroundBloodSplat

## 共享材质缓存：血迹贴图总共只有寥寥几种，按贴图缓存一份共享 ShaderMaterial。
## 之前在 setup() 里给每个 splat duplicate() 一份独立 StandardMaterial3D，尸潮
## 一枪死一片时几十上百个 splat 各自成材质实例，在 Web/单线程下触发逐实例的
## 着色器编译与纹理上传——这是开枪瞬间整帧卡顿的主因。改成共享 ShaderMaterial 后，
## 同一贴图的所有 splat 只编译一次；每实例的明暗/透明度差异走 instance uniform
## （tint），不再触碰材质本身，因此不触发重编译。
static var shared_materials: Dictionary = {}

## 极简贴地血迹 shader：无光照、alpha 混合、双面。final = 贴图色 * instance tint。
## 地面血迹是被压平的贴片，不需要 StandardMaterial3D 的 PBR 光照。
const SPLAT_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled;

uniform sampler2D splat_texture : source_color, filter_linear_mipmap, repeat_disable;
instance uniform vec4 tint : source_color = vec4(1.0);

void fragment() {
	vec4 tex = texture(splat_texture, UV);
	ALBEDO = tex.rgb * tint.rgb;
	ALPHA = tex.a * tint.a;
}
"""

static var _shared_shader: Shader

static func _get_shader() -> Shader:
	if _shared_shader == null:
		_shared_shader = Shader.new()
		_shared_shader.code = SPLAT_SHADER_CODE
	return _shared_shader

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

@export var surface_offset := 0.012

var base_size := Vector2.ONE
var current_size := Vector2.ONE
var current_tint := Color.WHITE
var current_surface_normal := Vector3.UP
var current_rotation := 0.0

## 取（或建）某张贴图对应的共享材质。之后所有同贴图 splat 复用同一份。
func _shared_material_for(texture: Texture2D) -> ShaderMaterial:
	var key := texture.get_instance_id() if texture != null else 0
	var cached := shared_materials.get(key) as ShaderMaterial
	if cached != null:
		return cached
	var shared := ShaderMaterial.new()
	shared.shader = _get_shader()
	shared.set_shader_parameter("splat_texture", texture)
	shared_materials[key] = shared
	return shared

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
	material_override = _shared_material_for(texture)
	set_instance_shader_parameter("tint", tint)
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
	set_instance_shader_parameter("tint", current_tint)

## 场景里 StandardMaterial3D 模板的默认贴图（kenney_splat29），warmup 用它。
const DEFAULT_WARMUP_TEXTURE := preload("res://assets/fx/blood/kenney_splat29.png")

func warmup_for_render(context: FxWarmupContext) -> void:
	setup(
		context.position_in_view(3.5, Vector2(0.3, -0.3)),
		-context.forward_direction(),
		Vector2.ONE,
		0.0,
		Color(0.42, 0.008, 0.015, 0.92),
		DEFAULT_WARMUP_TEXTURE,
		0.4
	)

func finish_render_warmup() -> void:
	visible = false

func _apply_size_basis() -> void:
	var resolved_basis := surface_basis(
		current_surface_normal,
		current_rotation
	).scaled(Vector3(current_size.x, current_size.y, 1.0))
	if is_inside_tree():
		global_basis = resolved_basis
	else:
		basis = resolved_basis
