extends Node3D
class_name HealthBar3D

const BAR_WIDTH := 1.10
const TRANSITION_DURATION := 0.20
const HIGH_HEALTH_COLOR := Color("43cf66")
const MEDIUM_HEALTH_COLOR := Color("e5c642")
const LOW_HEALTH_COLOR := Color("e44b46")

@onready var fill: MeshInstance3D = $Fill

@export var anchor_offset := Vector3.ZERO

var target_ratio := 1.0
var displayed_ratio := 1.0
var fill_tween: Tween
var follow_target: Node3D
var missing_follow_target_warned := false
var missing_camera_warned := false

func _ready() -> void:
	follow_target = get_parent() as Node3D
	top_level = true
	_sync_to_camera()
	_set_displayed_ratio(displayed_ratio)

func _process(_delta: float) -> void:
	_sync_to_camera()

func _sync_to_camera() -> void:
	if not is_instance_valid(follow_target) or not follow_target.is_inside_tree():
		if not missing_follow_target_warned:
			push_warning("HealthBar3D requires an in-tree Node3D follow target.")
			missing_follow_target_warned = true
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		if not missing_camera_warned:
			push_warning("HealthBar3D requires an active Camera3D.")
			missing_camera_warned = true
		return
	global_position = follow_target.global_position + anchor_offset
	global_basis = camera.global_basis

func set_health(current: float, maximum: float, animate: bool = true) -> void:
	target_ratio = health_ratio(current, maximum)
	var fill_material := fill.material_override as ShaderMaterial
	fill_material.set_shader_parameter(&"tint_color", color_for_ratio(target_ratio))

	if is_instance_valid(fill_tween):
		fill_tween.kill()

	if not animate:
		_set_displayed_ratio(target_ratio)
		return

	fill_tween = create_tween()
	fill_tween.tween_method(_set_displayed_ratio, displayed_ratio, target_ratio, TRANSITION_DURATION)

func get_target_ratio() -> float:
	return target_ratio

static func health_ratio(current: float, maximum: float) -> float:
	return 0.0 if maximum <= 0.0 else clampf(current / maximum, 0.0, 1.0)

static func color_for_ratio(ratio: float) -> Color:
	if ratio > 0.60:
		return HIGH_HEALTH_COLOR
	if ratio >= 0.30:
		return MEDIUM_HEALTH_COLOR
	return LOW_HEALTH_COLOR

func _set_displayed_ratio(ratio: float) -> void:
	displayed_ratio = clampf(ratio, 0.0, 1.0)
	var fill_material := fill.material_override as ShaderMaterial
	fill_material.set_shader_parameter(&"fill_ratio", displayed_ratio)
	fill.position = Vector3.ZERO
	fill.scale = Vector3.ONE
	fill.visible = displayed_ratio > 0.0
