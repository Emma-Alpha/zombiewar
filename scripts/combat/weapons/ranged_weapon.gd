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
	var ranged_definition := definition as RangedWeaponDefinition
	muzzle.position = ranged_definition.muzzle_anchor_offset
	if visual_anchor != null:
		top_level = true
		global_transform = visual_anchor.global_transform
	if functional_ray_origin != null:
		functional_ray_origin.global_position = muzzle.global_position

func _physics_process(delta: float) -> void:
	weapon_trigger.tick(delta)
	if weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed):
		_fire(aim_direction)
	trigger_just_pressed = false

func _process(_delta: float) -> void:
	if visual_anchor != null and is_instance_valid(visual_anchor):
		global_transform = visual_anchor.global_transform

func set_equipped(value: bool) -> void:
	super.set_equipped(value)
	if value and functional_ray_origin != null:
		functional_ray_origin.global_position = muzzle.global_position

func cancel_attack() -> void:
	super.cancel_attack()
	if weapon_trigger != null:
		weapon_trigger.reset()

func get_ray_origin() -> Vector3:
	if functional_ray_origin != null and is_instance_valid(functional_ray_origin):
		return functional_ray_origin.global_position
	return wielder.global_position if wielder != null else global_position

func _fire(shot_direction: Vector3) -> void:
	var ranged_definition := definition as RangedWeaponDefinition
	var ray_origin := get_ray_origin()
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
	tracer.setup(muzzle.global_position, hit_position)
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

func _intersect_shot(from: Vector3, to: Vector3) -> Dictionary:
	var ranged_definition := definition as RangedWeaponDefinition
	var query := PhysicsRayQueryParameters3D.create(
		from,
		to,
		ranged_definition.hit_collision_mask,
		[wielder.get_rid()]
	)
	query.collide_with_areas = true
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
