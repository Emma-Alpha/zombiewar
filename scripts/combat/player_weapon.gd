extends Node3D
class_name PlayerWeapon

const WeaponMath = preload("res://scripts/combat/weapon_math.gd")
const FireGate = preload("res://scripts/combat/fire_gate.gd")
const TRACER_SCENE := preload("res://scenes/fx/ShotTracer.tscn")

@export var shots_per_second: float = 6.0
@export var damage: float = 25.0
@export var max_range: float = 80.0
@export_flags_3d_physics var hit_collision_mask: int = 5

@onready var muzzle: Marker3D = $Muzzle

var fire_gate: FireGate

func _ready() -> void:
	fire_gate = FireGate.new(1.0 / shots_per_second)

func _physics_process(delta: float) -> void:
	fire_gate.tick(delta)
	var player := get_parent() as PlayerController
	if player == null:
		return
	if Input.is_action_pressed("fire") and fire_gate.try_consume():
		_fire(player)

func _fire(player: PlayerController) -> void:
	var ray_origin := muzzle.global_position
	var ray_direction := WeaponMath.forward_direction(player.global_basis)
	var ray_end := WeaponMath.ray_end(ray_origin, player.global_basis, max_range)
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin,
		ray_end,
		hit_collision_mask,
		[player.get_rid()]
	)
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	var hit_position: Vector3 = result.get("position", ray_end)
	var collider: Object = result.get("collider", null)
	if collider != null and collider.has_method("apply_damage"):
		collider.call("apply_damage", damage, hit_position)

	var tracer := TRACER_SCENE.instantiate() as ShotTracer
	get_tree().current_scene.add_child(tracer)
	tracer.setup(ray_origin, hit_position)
