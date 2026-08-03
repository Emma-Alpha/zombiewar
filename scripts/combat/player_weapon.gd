extends Node3D
class_name PlayerWeapon

const AimMath = preload("res://scripts/combat/aim_math.gd")
const FireGate = preload("res://scripts/combat/fire_gate.gd")
const TRACER_SCENE := preload("res://scenes/fx/ShotTracer.tscn")

@export var shots_per_second: float = 6.0
@export var damage: float = 25.0
@export var max_range: float = 80.0
@export var aim_plane_y: float = 0.0
@export_flags_3d_physics var aim_collision_mask: int = 5

@onready var muzzle: Marker3D = $Muzzle

var aim_camera: Camera3D
var fire_gate: FireGate

func _ready() -> void:
	fire_gate = FireGate.new(1.0 / shots_per_second)

func set_aim_camera(camera: Camera3D) -> void:
	aim_camera = camera

func _physics_process(delta: float) -> void:
	fire_gate.tick(delta)
	if aim_camera == null:
		return

	var mouse_position := get_viewport().get_mouse_position()
	var ray_origin := aim_camera.project_ray_origin(mouse_position)
	var ray_direction := aim_camera.project_ray_normal(mouse_position).normalized()
	var player := get_parent() as PlayerController
	var ground_point := AimMath.intersect_y_plane(ray_origin, ray_direction, aim_plane_y)
	if ground_point is Vector3:
		player.face_world_point(ground_point)

	if Input.is_action_pressed("fire") and fire_gate.try_consume():
		_fire(ray_origin, ray_direction, player)

func _fire(ray_origin: Vector3, ray_direction: Vector3, player: PlayerController) -> void:
	var ray_end := ray_origin + ray_direction * max_range
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin,
		ray_end,
		aim_collision_mask,
		[player.get_rid()]
	)
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	var hit_position: Vector3 = result.get("position", ray_end)
	var collider: Object = result.get("collider", null)
	if collider != null and collider.has_method("apply_damage"):
		collider.call("apply_damage", damage, hit_position)

	var tracer := TRACER_SCENE.instantiate() as ShotTracer
	get_tree().current_scene.add_child(tracer)
	tracer.setup(muzzle.global_position, hit_position)
