extends Node3D
class_name HealthBar3D

const BAR_WIDTH := 1.10
const TRANSITION_DURATION := 0.20
const HIGH_HEALTH_COLOR := Color("43cf66")
const MEDIUM_HEALTH_COLOR := Color("e5c642")
const LOW_HEALTH_COLOR := Color("e44b46")

@onready var fill: MeshInstance3D = $Fill

var target_ratio := 1.0
var displayed_ratio := 1.0
var fill_tween: Tween

func _ready() -> void:
	_set_displayed_ratio(displayed_ratio)

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
	displayed_ratio = ratio
	fill.scale.x = ratio
	fill.position.x = -BAR_WIDTH * 0.5 + BAR_WIDTH * ratio * 0.5
	fill.visible = ratio > 0.0
