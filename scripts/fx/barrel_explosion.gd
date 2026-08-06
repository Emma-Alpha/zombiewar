extends Node3D
class_name BarrelExplosion

@export_range(0.2, 3.0, 0.05) var lifetime := 1.25
@export_range(0.0, 12.0, 0.1) var initial_light_energy := 7.0

@onready var fire: CPUParticles3D = $Fire
@onready var smoke: CPUParticles3D = $Smoke
@onready var sparks: CPUParticles3D = $Sparks
@onready var flash_light: OmniLight3D = $FlashLight
@onready var audio: AudioStreamPlayer3D = $AudioStreamPlayer3D

var remaining := 0.0

func _ready() -> void:
	_reset_effect()

func explode_at(world_position: Vector3) -> void:
	global_position = world_position
	_start_effect(true)

func warmup_for_render(context: FxWarmupContext) -> void:
	global_position = context.position_in_view(3.0, Vector2(0.4, -0.15))
	_start_effect(false)
	set_process(false)

func finish_render_warmup() -> void:
	_reset_effect()

func _start_effect(play_audio: bool) -> void:
	remaining = maxf(lifetime, 0.2)
	visible = true
	fire.restart()
	smoke.restart()
	sparks.restart()
	fire.emitting = true
	smoke.emitting = true
	sparks.emitting = true
	flash_light.light_energy = initial_light_energy
	flash_light.visible = true
	if play_audio:
		audio.play()
	set_process(true)

func _reset_effect() -> void:
	remaining = 0.0
	if fire != null:
		fire.emitting = false
	if smoke != null:
		smoke.emitting = false
	if sparks != null:
		sparks.emitting = false
	if flash_light != null:
		flash_light.visible = false
		flash_light.light_energy = 0.0
	if audio != null:
		audio.stop()
	visible = false
	set_process(false)

func _process(delta: float) -> void:
	remaining -= delta
	var duration := maxf(lifetime, 0.2)
	var progress := clampf(1.0 - remaining / duration, 0.0, 1.0)
	flash_light.light_energy = initial_light_energy * (1.0 - progress) * (1.0 - progress)
	if remaining <= 0.0:
		queue_free()
