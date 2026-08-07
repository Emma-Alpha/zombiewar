extends WeaponBase
class_name RangedWeapon

const TRACER_SCENE := preload("res://scenes/fx/ShotTracer.tscn")
const MuzzleFlash = preload("res://scripts/fx/muzzle_flash.gd")
const WeaponTrigger = preload("res://scripts/combat/weapons/weapon_trigger.gd")
const MAX_PENETRATION_QUERY_COUNT := 64
const WALL_IMPACT_SOUNDS := [
	preload("res://assets/sfx/boxhead/bullet_wall_1.mp3"),
	preload("res://assets/sfx/boxhead/bullet_wall_2.mp3"),
	preload("res://assets/sfx/boxhead/bullet_wall_3.mp3"),
]
const WeaponSpreadState = preload(
	"res://scripts/combat/weapons/weapon_spread_state.gd"
)

@onready var muzzle: Marker3D = $Muzzle
@onready var muzzle_flash: MuzzleFlash = $Muzzle/MuzzleFlash
@onready var shot_audio: AudioStreamPlayer3D = $ShotAudio

var weapon_trigger: WeaponTrigger
var spread_state: WeaponSpreadState
var spread_rng := RandomNumberGenerator.new()
var tracer_pool: Array[ShotTracer] = []
var tracer_pool_cursor := 0
var current_ammo := 0
var spatial_sfx_pool: SpatialSfxPool

func _ready() -> void:
	var ranged_definition := definition as RangedWeaponDefinition
	weapon_trigger = WeaponTrigger.new(
		ranged_definition.trigger_mode,
		ranged_definition.attacks_per_second
	)
	spread_state = WeaponSpreadState.new(
		ranged_definition.base_spread_degrees,
		ranged_definition.max_spread_degrees,
		ranged_definition.spread_increase_per_shot_degrees,
		ranged_definition.spread_recovery_degrees_per_second
	)
	spread_rng.randomize()
	spatial_sfx_pool = SpatialSfxPool.find_for(self)
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
	spread_state.tick(delta)
	weapon_trigger.tick(delta)
	if (
		has_ammo_for_shot() and
		weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed) and
		try_consume_ammo()
	):
		_fire(aim_direction)
	trigger_just_pressed = false

func set_ammo_count(amount: int) -> void:
	var next_ammo := clampi(amount, 0, get_max_ammo()) if _uses_ammo() else 0
	if next_ammo == current_ammo:
		return
	current_ammo = next_ammo
	count_changed.emit(current_ammo)

func add_ammo(amount: int) -> int:
	if not _uses_ammo() or amount <= 0:
		return 0
	var before := current_ammo
	set_ammo_count(current_ammo + amount)
	return current_ammo - before

func receive_pickup(amount: int) -> bool:
	var ownership_changed := set_owned(true)
	var added_ammo := add_ammo(amount)
	return ownership_changed or added_ammo > 0

func get_ammo_count() -> int:
	return current_ammo

func get_max_ammo() -> int:
	var ranged_definition := definition as RangedWeaponDefinition
	return maxi(ranged_definition.max_ammo, 0) if ranged_definition != null else 0

func get_remaining_count() -> int:
	return current_ammo if _uses_ammo() else -1

func get_count_text() -> String:
	return str(get_ammo_count()) if _uses_ammo() else "∞"

func has_ammo_for_shot() -> bool:
	return not _uses_ammo() or current_ammo > 0

func try_consume_ammo() -> bool:
	if not _uses_ammo():
		return true
	if current_ammo <= 0:
		return false
	set_ammo_count(current_ammo - 1)
	return true

func _uses_ammo() -> bool:
	var ranged_definition := definition as RangedWeaponDefinition
	return ranged_definition != null and ranged_definition.uses_ammo

func set_equipped(value: bool) -> void:
	super.set_equipped(value)
	if not value and spread_state != null:
		spread_state.reset()

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
	var ray_direction := spread_state.resolve_shot_direction(
		shot_direction,
		spread_rng.randf_range(-1.0, 1.0)
	)
	var ray_end := WeaponMath.ray_end_from_direction(
		ray_origin,
		ray_direction,
		ranged_definition.attack_range
	)
	var resolution := _resolve_shot(ray_origin, ray_end, ray_direction)
	var hit_position: Vector3 = resolution["end_position"]
	var hit_result: HitResult = resolution["hit_result"]
	var hit_world_surface: bool = resolution["hit_world_surface"]

	var tracer := _acquire_tracer()
	tracer.setup(ray_origin, hit_position)
	muzzle_flash.flash()
	shot_audio.pitch_scale = randf_range(0.97, 1.03)
	shot_audio.play()
	if hit_world_surface and spatial_sfx_pool != null:
		var wall_stream: AudioStream = WALL_IMPACT_SOUNDS[
			spread_rng.randi_range(0, WALL_IMPACT_SOUNDS.size() - 1)
		]
		spatial_sfx_pool.play_at(
			wall_stream,
			hit_position,
			-7.0,
			spread_rng.randf_range(0.96, 1.04),
			24.0
		)
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

func _resolve_shot(
	from: Vector3,
	to: Vector3,
	shot_direction: Vector3
) -> Dictionary:
	var ranged_definition := definition as RangedWeaponDefinition
	var excluded: Array[RID] = [wielder.get_rid()]
	var visited_targets: Dictionary = {}
	var maximum_zombie_hits := clampi(
		ranged_definition.max_penetration_count,
		0,
		16
	) + 1
	var coefficient := clampf(
		ranged_definition.penetration_damage_coefficient,
		0.0,
		1.0
	)
	var zombie_hit_count := 0
	var current_damage := maxf(ranged_definition.damage, 0.0)
	var end_position := to
	var summary := HitResult.miss(to)
	var hit_world_surface := false

	for _query_index in range(MAX_PENETRATION_QUERY_COUNT):
		var collision := _intersect_shot(from, to, excluded)
		var collider: Object = collision.get("collider", null)
		if collider == null:
			end_position = to
			break
		end_position = collision.get("position", to)
		var collision_object := collider as CollisionObject3D
		if collision_object != null:
			excluded.append(collision_object.get_rid())

		var target := _find_damage_target(collider)
		if target == null:
			var resolved := _apply_damage(
				collider,
				ranged_definition.damage,
				end_position,
				shot_direction
			)
			hit_world_surface = not summary.did_hit and not resolved.did_hit
			_merge_hit_result(summary, resolved)
			break

		var target_id := target.get_instance_id()
		if visited_targets.has(target_id):
			if collision_object == null:
				break
			continue
		visited_targets[target_id] = true
		zombie_hit_count += 1
		_merge_hit_result(
			summary,
			_apply_damage(collider, current_damage, end_position, shot_direction)
		)
		if zombie_hit_count >= maximum_zombie_hits or coefficient <= 0.0:
			break
		current_damage *= coefficient

	if not summary.did_hit:
		summary.position = end_position
	return {
		"end_position": end_position,
		"hit_result": summary,
		"hit_world_surface": hit_world_surface,
	}

func _find_damage_target(collider: Object) -> Node3D:
	var current := collider as Node
	while current != null:
		if current is Node3D and current.is_in_group(&"damageable_targets"):
			return current as Node3D
		current = current.get_parent()
	return null

func _apply_damage(
	collider: Object,
	amount: float,
	hit_position: Vector3,
	shot_direction: Vector3
) -> HitResult:
	if collider != null and collider.has_method("apply_hit"):
		var resolved: Variant = collider.call(
			"apply_hit",
			amount,
			hit_position,
			shot_direction
		)
		if resolved is HitResult:
			return resolved as HitResult
	elif collider != null and collider.has_method("apply_damage"):
		var resolved: Variant = collider.call(
			"apply_damage",
			amount,
			hit_position
		)
		if resolved is HitResult:
			return resolved as HitResult
	return HitResult.miss(hit_position)

func _merge_hit_result(summary: HitResult, resolved: HitResult) -> void:
	if resolved == null or not resolved.did_hit:
		return
	summary.did_hit = true
	summary.damage_applied += resolved.damage_applied
	summary.hit_zone = resolved.hit_zone
	summary.critical = summary.critical or resolved.critical
	summary.killed = summary.killed or resolved.killed
	summary.position = resolved.position

func _intersect_shot(
	from: Vector3,
	to: Vector3,
	excluded: Array[RID] = []
) -> Dictionary:
	var ranged_definition := definition as RangedWeaponDefinition
	var hit_mask := ranged_definition.hit_collision_mask | 1
	var effective_excluded := excluded
	if effective_excluded.is_empty() and wielder != null:
		effective_excluded = [wielder.get_rid()]
	var query := PhysicsRayQueryParameters3D.create(
		from,
		to,
		hit_mask,
		effective_excluded
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
