extends WeaponBase
class_name MeleeWeapon

const WeaponTrigger = preload("res://scripts/combat/weapons/weapon_trigger.gd")
const MAX_MELEE_INTERSECTIONS := 64

var weapon_trigger: WeaponTrigger
var attack_pending := false
var attack_elapsed := 0.0
var impact_resolved := false

func _ready() -> void:
	var melee_definition := definition as MeleeWeaponDefinition
	weapon_trigger = WeaponTrigger.new(
		melee_definition.trigger_mode,
		melee_definition.attacks_per_second
	)

func _physics_process(delta: float) -> void:
	weapon_trigger.tick(delta)
	if (
		not attack_pending and
		weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed)
	):
		_start_attack()
	trigger_just_pressed = false
	if not attack_pending:
		return
	attack_elapsed += maxf(delta, 0.0)
	var melee_definition := definition as MeleeWeaponDefinition
	if not impact_resolved and attack_elapsed >= melee_definition.impact_delay:
		impact_resolved = true
		var result := _resolve_melee_hit()
		var impact_origin := (
			wielder.global_transform * Transform3D(
				Basis.IDENTITY,
				melee_definition.hitbox_offset
			)
		).origin
		attack_resolved.emit(
			impact_origin,
			aim_direction,
			result,
			melee_definition.visual_recoil_kick,
			melee_definition.camera_impulse_strength
		)
	if attack_elapsed >= melee_definition.attack_lock_duration:
		attack_pending = false

func set_equipped(value: bool) -> void:
	super.set_equipped(value)
	if not value:
		cancel_attack()

func cancel_attack() -> void:
	super.cancel_attack()
	_cancel_pending_impact()
	if weapon_trigger != null:
		weapon_trigger.clear_buffered_trigger()

func _cancel_pending_impact() -> void:
	attack_pending = false
	attack_elapsed = 0.0
	impact_resolved = false

func _start_attack() -> void:
	var melee_definition := definition as MeleeWeaponDefinition
	attack_pending = true
	attack_elapsed = 0.0
	impact_resolved = false
	attack_started.emit(
		melee_definition.attack_animation,
		melee_definition.attack_lock_duration
	)

func _resolve_melee_hit() -> HitResult:
	var melee_definition := definition as MeleeWeaponDefinition
	var shape := BoxShape3D.new()
	shape.size = melee_definition.hitbox_size
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = wielder.global_transform * Transform3D(
		Basis.IDENTITY,
		melee_definition.hitbox_offset
	)
	query.collision_mask = melee_definition.hit_collision_mask
	query.collide_with_areas = true
	query.collide_with_bodies = false
	query.exclude = [wielder.get_rid()]
	var intersections := get_world_3d().direct_space_state.intersect_shape(
		query,
		MAX_MELEE_INTERSECTIONS
	)
	var closest_target: Node3D
	var closest_distance := INF
	var visited: Dictionary = {}
	var wielder_forward := -wielder.global_transform.basis.z
	wielder_forward.y = 0.0
	for intersection in intersections:
		var collider: Object = intersection.get("collider")
		var target := _find_damage_target(collider)
		if target == null:
			continue
		var target_offset := target.global_position - wielder.global_position
		target_offset.y = 0.0
		if target_offset.dot(wielder_forward) <= 0.0:
			continue
		var target_id := target.get_instance_id()
		if visited.has(target_id):
			continue
		visited[target_id] = true
		var distance := wielder.global_position.distance_squared_to(
			target.global_position
		)
		if distance < closest_distance:
			closest_distance = distance
			closest_target = target
	var miss_position := query.transform.origin
	if closest_target == null:
		return HitResult.miss(miss_position)
	var hit_position := closest_target.global_position + Vector3.UP
	if closest_target.has_method("get_aim_point"):
		hit_position = closest_target.call("get_aim_point")
	var resolved: Variant = closest_target.call(
		"apply_hit",
		melee_definition.damage,
		hit_position,
		aim_direction
	)
	return resolved as HitResult if resolved is HitResult else HitResult.miss(hit_position)

func _find_damage_target(collider: Object) -> Node3D:
	var current := collider as Node
	while current != null:
		if current is Node3D and current.is_in_group(&"damageable_targets"):
			return current as Node3D
		current = current.get_parent()
	return null
