extends Node3D
class_name FollowCamera

const PlayerMotion = preload("res://scripts/player/player_motion.gd")
const SharedCameraMathScript = preload("res://scripts/camera/shared_camera_math.gd")
const SharedCameraPlayerSampleScript = preload(
	"res://scripts/camera/shared_camera_player_sample.gd"
)

@export_range(0.5, 20.0, 0.1) var follow_speed := 6.0
@export_range(0.5, 0.95, 0.01) var edge_start_ratio := 0.72
@export_range(0.0, 8.0, 0.1) var max_direction_offset := 3.0
@export_range(0.0, 0.25, 0.01) var safe_margin_ratio := 0.08
@export var shot_impulse_strength := 0.06
@export var shot_impulse_maximum := 0.12
@export var shot_impulse_recovery := 1.5

@onready var visual_offset: Node3D = $VisualOffset
@onready var camera: Camera3D = $VisualOffset/Camera3D

var player_registry: PlayerRegistry
var shot_impulse_offset := Vector3.ZERO
var visual_offset_base_position := Vector3.ZERO
var world_bounds := Rect2()
var has_world_bounds := false

static func smoothing_weight(speed: float, delta: float) -> float:
	return 1.0 - exp(-maxf(speed, 0.0) * maxf(delta, 0.0))

func _ready() -> void:
	visual_offset_base_position = visual_offset.position

func set_player_registry(registry: PlayerRegistry) -> void:
	player_registry = registry

func set_world_bounds(bounds: Rect2) -> void:
	world_bounds = bounds.abs()
	has_world_bounds = world_bounds.size.x > 0.0 and world_bounds.size.y > 0.0

func get_anchor_position() -> Vector3:
	return global_position

func get_camera() -> Camera3D:
	return camera

func add_shot_impulse(
	shot_direction: Vector3,
	strength: float = -1.0
) -> void:
	var planar := Vector3(shot_direction.x, 0.0, shot_direction.z)
	if planar.length_squared() <= 0.000001:
		return
	var resolved_strength := shot_impulse_strength if strength < 0.0 else strength
	shot_impulse_offset -= planar.normalized() * maxf(resolved_strength, 0.0)
	if shot_impulse_offset.length() > shot_impulse_maximum:
		shot_impulse_offset = shot_impulse_offset.normalized() * shot_impulse_maximum

func _physics_process(delta: float) -> void:
	shot_impulse_offset = shot_impulse_offset.move_toward(
		Vector3.ZERO,
		shot_impulse_recovery * delta
	)
	visual_offset.position = visual_offset_base_position + shot_impulse_offset
	var samples := _build_samples()
	if samples.is_empty():
		return
	var desired := SharedCameraMathScript.desired_position(
		samples,
		get_viewport().get_visible_rect().size,
		edge_start_ratio,
		max_direction_offset,
		global_position
	)
	if has_world_bounds:
		desired.x = clampf(desired.x, world_bounds.position.x, world_bounds.end.x)
		desired.z = clampf(desired.z, world_bounds.position.y, world_bounds.end.y)
	desired.y = global_position.y
	global_position = global_position.lerp(
		desired,
		smoothing_weight(follow_speed, delta)
	)

func _build_samples() -> Array:
	var samples: Array = []
	if player_registry == null or camera == null or visual_offset == null:
		return samples
	var saved_visual_offset := visual_offset.position
	visual_offset.position = visual_offset_base_position
	for player in player_registry.get_players():
		if (
			not is_instance_valid(player) or
			not player.is_alive() or
			not player.is_input_online()
		):
			continue
		var sample = SharedCameraPlayerSampleScript.new()
		sample.world_position = player.global_position
		sample.screen_position = camera.unproject_position(player.global_position)
		var move_world := PlayerMotion.world_direction(
			player.get_last_input_state().move_vector,
			camera.global_basis
		)
		sample.world_move_direction = move_world
		if move_world.length_squared() > 0.000001:
			sample.screen_move_direction = (
				camera.unproject_position(player.global_position + move_world) -
				sample.screen_position
			).normalized()
		samples.append(sample)
	visual_offset.position = saved_visual_offset
	return samples
