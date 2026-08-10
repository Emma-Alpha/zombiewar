extends Node3D
class_name BloodImpact

@export var lifetime: float = 0.45
@export var minimum_intensity: float = 0.75
@export var maximum_intensity: float = 1.35

@onready var splat: Sprite3D = $Splat
@onready var droplets: GPUParticles3D = $Droplets

var remaining: float = 0.0
var splat_start_scale := Vector3.ONE
var pooled := false

func _ready() -> void:
	_ensure_nodes()
	set_process(remaining > 0.0)

func setup(hit_position: Vector3, shot_direction: Vector3, intensity: float = 1.0) -> void:
	_ensure_nodes()
	visible = true
	if is_inside_tree():
		global_position = hit_position
	else:
		position = hit_position

	var spray_direction := shot_direction.normalized()
	if spray_direction.length_squared() <= 0.000001:
		spray_direction = Vector3.FORWARD
	if is_inside_tree():
		var up_direction := Vector3.UP
		if absf(spray_direction.dot(up_direction)) > 0.98:
			up_direction = Vector3.RIGHT
		look_at(global_position + spray_direction, up_direction)

	var resolved_intensity := clampf(intensity, minimum_intensity, maximum_intensity)
	splat_start_scale = Vector3.ONE * resolved_intensity
	splat.scale = splat_start_scale * 0.72
	splat.rotation.z = randf_range(-PI, PI)
	var splat_color := splat.modulate
	splat_color.a = 0.94
	splat.modulate = splat_color

	remaining = maxf(lifetime, 0.05)
	if is_inside_tree():
		droplets.restart()
		droplets.emitting = true
	set_process(true)

func set_pooled(value: bool) -> void:
	pooled = value
	if pooled:
		deactivate()

func is_active() -> bool:
	return remaining > 0.0 and visible

func deactivate() -> void:
	remaining = 0.0
	if droplets != null:
		droplets.emitting = false
	visible = false
	set_process(false)

func warmup_for_render(context: FxWarmupContext) -> void:
	setup(
		context.position_in_view(3.0, Vector2(0.0, -0.2)),
		context.forward_direction(),
		1.0
	)
	set_process(false)

func finish_render_warmup() -> void:
	deactivate()

func _process(delta: float) -> void:
	remaining -= delta
	var duration := maxf(lifetime, 0.05)
	var progress := clampf(1.0 - remaining / duration, 0.0, 1.0)
	splat.scale = splat_start_scale * lerpf(0.72, 1.28, progress)
	var splat_color := splat.modulate
	splat_color.a = 0.94 * (1.0 - progress)
	splat.modulate = splat_color
	if remaining <= 0.0:
		if pooled:
			deactivate()
		else:
			queue_free()

func _ensure_nodes() -> void:
	if splat == null:
		splat = get_node("Splat") as Sprite3D
	if droplets == null:
		droplets = get_node("Droplets") as GPUParticles3D
