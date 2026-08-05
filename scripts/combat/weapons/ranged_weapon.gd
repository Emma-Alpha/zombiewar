extends WeaponBase
class_name RangedWeapon

const TRACER_SCENE := preload("res://scenes/fx/ShotTracer.tscn")
const MuzzleFlash = preload("res://scripts/fx/muzzle_flash.gd")
const WeaponTrigger = preload("res://scripts/combat/weapons/weapon_trigger.gd")

@onready var muzzle: Marker3D = $Muzzle
@onready var muzzle_flash: MuzzleFlash = $Muzzle/MuzzleFlash
@onready var shot_audio: AudioStreamPlayer3D = $ShotAudio

var weapon_trigger: WeaponTrigger
var tracer_pool: Array[ShotTracer] = []
var tracer_pool_cursor := 0

func _ready() -> void:
	var ranged_definition := definition as RangedWeaponDefinition
	weapon_trigger = WeaponTrigger.new(
		ranged_definition.trigger_mode,
		ranged_definition.attacks_per_second
	)
	_prewarm_tracers()

func bind_context(
	value_wielder: CharacterBody3D,
	value_visual_root: Node3D,
	value_functional_ray_origin: Marker3D
) -> void:
	super.bind_context(
		value_wielder,
		value_visual_root,
		value_functional_ray_origin
	)
	if visual_anchor != null:
		top_level = true
		_sync_to_visual_anchor()

func _physics_process(delta: float) -> void:
	weapon_trigger.tick(delta)
	if weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed):
		_fire(aim_direction)
	trigger_just_pressed = false

func _process(_delta: float) -> void:
	_sync_to_visual_anchor()
	_sync_muzzle_to_capsule()

func cancel_attack() -> void:
	super.cancel_attack()
	if weapon_trigger != null:
		weapon_trigger.reset()

func get_ray_origin() -> Vector3:
	var fallback := global_position
	if functional_ray_origin != null and is_instance_valid(functional_ray_origin):
		fallback = functional_ray_origin.global_position
	elif wielder != null:
		fallback = wielder.global_position
	if wielder != null:
		var clearance := wielder.get_node_or_null(
			"WeaponClearanceController"
		) as WeaponClearanceController
		if clearance != null:
			return clearance.get_weapon_muzzle_origin(fallback)
	return fallback

func _fire(shot_direction: Vector3) -> void:
	_sync_to_visual_anchor()
	var ranged_definition := definition as RangedWeaponDefinition
	var ray_origin := _sync_muzzle_to_capsule()
	var ray_direction := WeaponMath.flat_direction(shot_direction)
	var ray_end := WeaponMath.ray_end_from_direction(
		ray_origin,
		ray_direction,
		ranged_definition.attack_range
	)
	var result := _intersect_shot(ray_origin, ray_end)
	var collider: Object = result.get("collider", null)
	var hit_position: Vector3 = result.get("position", ray_end)
	var hit_result := HitResult.miss(hit_position)
	if collider != null and collider.has_method("apply_hit"):
		var resolved: Variant = collider.call(
			"apply_hit",
			ranged_definition.damage,
			hit_position,
			ray_direction
		)
		if resolved is HitResult:
			hit_result = resolved as HitResult
	elif collider != null and collider.has_method("apply_damage"):
		var resolved: Variant = collider.call(
			"apply_damage",
			ranged_definition.damage,
			hit_position
		)
		if resolved is HitResult:
			hit_result = resolved as HitResult

	var tracer := _acquire_tracer()
	tracer.setup(ray_origin, hit_position)
	muzzle_flash.flash()
	shot_audio.pitch_scale = randf_range(0.97, 1.03)
	shot_audio.play()
	attack_resolved.emit(
		ray_origin,
		ray_direction,
		hit_result,
		ranged_definition.visual_recoil_kick,
		ranged_definition.camera_impulse_strength
	)

func _sync_to_visual_anchor() -> void:
	if visual_anchor != null and is_instance_valid(visual_anchor):
		global_transform = visual_anchor.global_transform

func _sync_muzzle_to_capsule() -> Vector3:
	var origin := get_ray_origin()
	muzzle.global_position = origin
	return origin

func _intersect_shot(from: Vector3, to: Vector3) -> Dictionary:
	var ranged_definition := definition as RangedWeaponDefinition
	var hit_mask := ranged_definition.hit_collision_mask | 1
	var query := PhysicsRayQueryParameters3D.create(
		from,
		to,
		hit_mask,
		[wielder.get_rid()]
	)
	query.collide_with_areas = true
	query.hit_from_inside = true
	return get_world_3d().direct_space_state.intersect_ray(query)

func _prewarm_tracers() -> void:
	if not tracer_pool.is_empty():
		return
	var ranged_definition := definition as RangedWeaponDefinition
	for tracer_index in range(maxi(ranged_definition.tracer_pool_size, 1)):
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
