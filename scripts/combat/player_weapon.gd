extends Node3D
class_name PlayerWeapon

const WeaponMath = preload("res://scripts/combat/weapon_math.gd")
const FireGate = preload("res://scripts/combat/fire_gate.gd")
const AimAssistMath = preload("res://scripts/combat/aim_assist_math.gd")
const HitResult = preload("res://scripts/combat/hit_result.gd")
const TRACER_SCENE := preload("res://scenes/fx/ShotTracer.tscn")
const MuzzleFlash = preload("res://scripts/fx/muzzle_flash.gd")

signal shot_fired(origin: Vector3, direction: Vector3, result: HitResult)

@export var shots_per_second: float = 6.0
@export var damage: float = 25.0
@export var max_range: float = 80.0
@export_flags_3d_physics var hit_collision_mask: int = 5
@export_range(1, 64, 1) var tracer_pool_size: int = 8
@export_range(0.0, 12.0, 0.25) var aim_assist_angle_degrees := 5.0
@export_range(0.0, 40.0, 0.5) var aim_assist_range := 18.0
@export var muzzle_anchor_offset := Vector3(0.84, 0.31, 0.61)

@onready var muzzle: Marker3D = $Muzzle
@onready var aim_indicator: Node3D = $AimIndicator
@onready var muzzle_flash: MuzzleFlash = $Muzzle/MuzzleFlash
@onready var shot_audio: AudioStreamPlayer3D = $ShotAudio

var fire_gate: FireGate
var tracer_pool: Array[ShotTracer] = []
var tracer_pool_cursor: int = 0
var trigger_pressed := false
var trigger_just_pressed := false
var aim_direction := Vector3.FORWARD
var visual_anchor: Node3D
var functional_ray_origin: Marker3D

func _ready() -> void:
	fire_gate = FireGate.new(1.0 / shots_per_second)
	aim_indicator.top_level = true
	_prewarm_tracers()

func _physics_process(delta: float) -> void:
	fire_gate.tick(delta)
	var player := get_parent() as PlayerController
	if player == null:
		return
	if trigger_just_pressed:
		fire_gate.request_shot(0.08)
	if fire_gate.try_consume(trigger_pressed):
		_fire(player, aim_direction)
	trigger_just_pressed = false

func _process(_delta: float) -> void:
	if visual_anchor != null and is_instance_valid(visual_anchor):
		global_transform = visual_anchor.global_transform
	_update_aim_indicator()

func _update_aim_indicator() -> void:
	if aim_indicator == null or not is_instance_valid(aim_indicator):
		return
	var direction := WeaponMath.flat_direction(aim_direction)
	aim_indicator.global_position = muzzle.global_position
	aim_indicator.look_at(aim_indicator.global_position + direction, Vector3.UP)

func set_aim_indicator_visible(value: bool) -> void:
	if aim_indicator != null and is_instance_valid(aim_indicator):
		aim_indicator.visible = value

func bind_visual_anchor(anchor: Node3D) -> void:
	visual_anchor = anchor
	top_level = visual_anchor != null
	muzzle.position = muzzle_anchor_offset
	if visual_anchor != null:
		global_transform = visual_anchor.global_transform

func bind_functional_ray_origin(origin: Marker3D) -> void:
	functional_ray_origin = origin

func get_ray_origin() -> Vector3:
	if functional_ray_origin != null and is_instance_valid(functional_ray_origin):
		return functional_ray_origin.global_position
	var player := get_parent() as Node3D
	return player.global_position if player != null else global_position

func set_combat_input(
	value_trigger_pressed: bool,
	value_trigger_just_pressed: bool,
	value_aim_direction: Vector3
) -> void:
	trigger_pressed = value_trigger_pressed
	trigger_just_pressed = value_trigger_just_pressed
	aim_direction = WeaponMath.flat_direction(value_aim_direction)

func _fire(player: PlayerController, shot_direction: Vector3) -> void:
	var ray_origin := get_ray_origin()
	var ray_direction := WeaponMath.flat_direction(shot_direction)
	var direct_end := WeaponMath.ray_end_from_direction(ray_origin, ray_direction, max_range)
	var resolved_end := direct_end
	var result := _intersect_shot(player, ray_origin, direct_end)
	var collider: Object = result.get("collider", null)

	if collider == null or (
		not collider.has_method("apply_hit") and
		not collider.has_method("apply_damage")
	):
		var assisted_target := _find_assisted_target(ray_origin, ray_direction)
		if assisted_target != null:
			var assisted_end: Vector3 = assisted_target.call("get_aim_point")
			resolved_end = assisted_end
			result = _intersect_shot(player, ray_origin, resolved_end)
			collider = result.get("collider", null)

	var hit_position: Vector3 = result.get("position", resolved_end)
	var hit_result := HitResult.miss(hit_position)
	if collider != null and collider.has_method("apply_hit"):
		var resolved: Variant = collider.call("apply_hit", damage, hit_position, ray_direction)
		if resolved is HitResult:
			hit_result = resolved as HitResult
	elif collider != null and collider.has_method("apply_damage"):
		var resolved: Variant = collider.call("apply_damage", damage, hit_position)
		if resolved is HitResult:
			hit_result = resolved as HitResult

	var tracer := _acquire_tracer()
	tracer.setup(muzzle.global_position, hit_position)
	muzzle_flash.flash()
	shot_audio.pitch_scale = randf_range(0.97, 1.03)
	shot_audio.play()
	shot_fired.emit(ray_origin, ray_direction, hit_result)

func _find_assisted_target(origin: Vector3, direction: Vector3) -> Node3D:
	var targets: Array[Node3D] = []
	var points: Array[Vector3] = []
	for node in get_tree().get_nodes_in_group(&"damageable_targets"):
		if node is Node3D and node.has_method("get_aim_point"):
			targets.append(node as Node3D)
			var aim_point: Vector3 = node.call("get_aim_point")
			points.append(aim_point)
	var selected := AimAssistMath.select_best_index(
		origin,
		direction,
		points,
		aim_assist_range,
		deg_to_rad(aim_assist_angle_degrees)
	)
	return targets[selected] if selected >= 0 else null

func _intersect_shot(
	player: PlayerController,
	from: Vector3,
	to: Vector3
) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		from,
		to,
		hit_collision_mask,
		[player.get_rid()]
	)
	query.collide_with_areas = true
	return get_world_3d().direct_space_state.intersect_ray(query)

func _prewarm_tracers() -> void:
	if not tracer_pool.is_empty():
		return
	for tracer_index in range(maxi(tracer_pool_size, 1)):
		var tracer := TRACER_SCENE.instantiate() as ShotTracer
		tracer.top_level = true
		add_child(tracer)
		tracer.deactivate()
		tracer_pool.append(tracer)

func _acquire_tracer() -> ShotTracer:
	if tracer_pool.is_empty():
		_prewarm_tracers()
	var tracer := tracer_pool[tracer_pool_cursor]
	tracer_pool_cursor = (tracer_pool_cursor + 1) % tracer_pool.size()
	return tracer
