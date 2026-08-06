extends StaticBody3D
class_name ExplosiveBarrel

const HitResult = preload("res://scripts/combat/hit_result.gd")
const ExplosionResolver = preload("res://scripts/combat/explosion_resolver.gd")
const BARREL_EXPLOSION_SCENE := preload("res://scenes/fx/BarrelExplosion.tscn")

signal explosion_requested(delay_seconds: float)
signal navigation_geometry_changed

enum State {
	INTACT,
	DAMAGED,
	EXPLODING,
	DESTROYED,
}

@export_range(1, 10, 1) var firearm_hits_to_explode := 3
@export_range(1, 9, 1) var firearm_hits_to_damage := 2
@export_range(0.0, 2.0, 0.01) var chain_delay_seconds := 0.12
@export_range(0.1, 20.0, 0.1) var explosion_radius := 4.5
@export_range(0.0, 500.0, 1.0) var explosion_center_damage := 80.0
@export_range(0.0, 500.0, 1.0) var explosion_edge_damage := 20.0
@export_flags_3d_physics var explosion_target_mask := 7
@export_flags_3d_physics var explosion_obstacle_mask := 1

@onready var visual_root: Node3D = $VisualRoot
@onready var damage_smoke: Node3D = $DamageSmoke
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

var state := State.INTACT
var firearm_hit_count := 0

func _ready() -> void:
	if not explosion_requested.is_connected(_on_explosion_requested):
		explosion_requested.connect(_on_explosion_requested)

func apply_hit(
	amount: float,
	hit_position: Vector3,
	_shot_direction: Vector3
) -> HitResult:
	if amount <= 0.0 or state >= State.EXPLODING:
		return HitResult.miss(hit_position)

	firearm_hit_count = mini(
		firearm_hit_count + 1,
		maxi(firearm_hits_to_explode, 1)
	)
	if firearm_hit_count >= maxi(firearm_hits_to_explode, 1):
		_request_explosion(0.0)
	elif firearm_hit_count >= clampi(
		firearm_hits_to_damage,
		1,
		maxi(firearm_hits_to_explode, 1)
	):
		_enter_damaged_state()

	return HitResult.resolved(
		maxf(amount, 0.0),
		&"barrel",
		false,
		state >= State.EXPLODING,
		hit_position
	)

func apply_explosion_damage(amount: float, _origin: Vector3) -> bool:
	if amount <= 0.0 or state >= State.EXPLODING:
		return false
	_request_explosion(maxf(chain_delay_seconds, 0.0))
	return true

func get_state() -> int:
	return state

func get_firearm_hit_count() -> int:
	return firearm_hit_count

func get_explosion_aim_point() -> Vector3:
	return global_position + Vector3.UP * 0.72

func _enter_damaged_state() -> void:
	if state != State.INTACT:
		return
	state = State.DAMAGED
	visual_root.scale = Vector3(1.06, 0.88, 1.06)
	visual_root.rotation_degrees.z = 7.0
	if damage_smoke.has_method("activate"):
		damage_smoke.call("activate")

func _request_explosion(delay_seconds: float) -> void:
	if state >= State.EXPLODING:
		return
	state = State.EXPLODING
	explosion_requested.emit(maxf(delay_seconds, 0.0))

func _on_explosion_requested(delay_seconds: float) -> void:
	call_deferred("_begin_explosion", delay_seconds)

func _begin_explosion(delay_seconds: float) -> void:
	if state != State.EXPLODING or not is_inside_tree():
		return
	if delay_seconds > 0.0:
		await get_tree().create_timer(delay_seconds).timeout
	if state != State.EXPLODING or not is_inside_tree():
		return
	_execute_explosion()

func _execute_explosion() -> void:
	if state != State.EXPLODING:
		return
	var origin := get_explosion_aim_point()
	if collision_shape != null:
		collision_shape.set_deferred("disabled", true)
	if damage_smoke != null:
		if damage_smoke.has_method("deactivate"):
			damage_smoke.call("deactivate")
		else:
			damage_smoke.visible = false
	_spawn_explosion_fx(origin)
	var world := get_world_3d()
	if world != null:
		ExplosionResolver.resolve(
			world,
			origin,
			explosion_radius,
			explosion_center_damage,
			explosion_edge_damage,
			self,
			true,
			explosion_target_mask,
			explosion_obstacle_mask
		)
	state = State.DESTROYED
	call_deferred("_finish_destroyed")

func _spawn_explosion_fx(origin: Vector3) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var effect := BARREL_EXPLOSION_SCENE.instantiate() as BarrelExplosion
	parent.add_child(effect)
	effect.explode_at(origin)

func _finish_destroyed() -> void:
	if state != State.DESTROYED:
		return
	remove_from_group(&"navigation_source")
	navigation_geometry_changed.emit()
	queue_free()
