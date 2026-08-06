extends Node3D
class_name BarrelDamageSmoke

@onready var smoke: CPUParticles3D = $Smoke
@onready var sparks: CPUParticles3D = $Sparks

func _ready() -> void:
	deactivate()

func activate() -> void:
	visible = true
	smoke.emitting = true
	sparks.emitting = true

func deactivate() -> void:
	if smoke != null:
		smoke.emitting = false
	if sparks != null:
		sparks.emitting = false
	visible = false

func warmup_for_render(context: FxWarmupContext) -> void:
	global_position = context.position_in_view(3.0, Vector2(-0.35, -0.25))
	activate()

func finish_render_warmup() -> void:
	deactivate()
