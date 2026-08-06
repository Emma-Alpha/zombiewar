extends Node3D
class_name MuzzleFlash

@export_range(0.02, 0.12, 0.005) var lifetime := 0.05

var remaining := 0.0

func _ready() -> void:
	visible = false
	set_process(false)

func flash() -> void:
	remaining = lifetime
	rotation.z = randf_range(-PI, PI)
	scale = Vector3.ONE * randf_range(0.85, 1.15)
	visible = true
	set_process(true)

func warmup_for_render(context: FxWarmupContext) -> void:
	global_position = context.position_in_view(2.5, Vector2(0.35, 0.15))
	flash()

func finish_render_warmup() -> void:
	remaining = 0.0
	visible = false
	set_process(false)

func _process(delta: float) -> void:
	remaining -= delta
	if remaining <= 0.0:
		visible = false
		set_process(false)
