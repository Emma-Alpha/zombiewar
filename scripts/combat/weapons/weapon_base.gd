extends "res://scripts/player/equipment_item.gd"
class_name WeaponBase

const HitResult = preload("res://scripts/combat/hit_result.gd")
const WeaponMath = preload("res://scripts/combat/weapon_math.gd")

signal attack_started(animation_name: StringName, lock_duration: float)
signal attack_resolved(
	origin: Vector3,
	direction: Vector3,
	result: HitResult,
	visual_recoil_kick: float,
	camera_impulse_strength: float
)

@export var definition: WeaponDefinition

var wielder: CharacterBody3D
var character_visual_root: Node3D
var functional_ray_origin: Marker3D
var visual_anchor: Node3D
var trigger_pressed := false
var trigger_just_pressed := false
var aim_direction := Vector3.FORWARD

func bind_context(
	value_wielder: CharacterBody3D,
	value_visual_root: Node3D,
	value_functional_ray_origin: Marker3D
) -> void:
	wielder = value_wielder
	character_visual_root = value_visual_root
	functional_ray_origin = value_functional_ray_origin
	visual_anchor = character_visual_root.find_child(
		String(definition.visual_node_name),
		true,
		false
	) as Node3D

func set_attack_input(
	value_trigger_pressed: bool,
	value_trigger_just_pressed: bool,
	value_aim_direction: Vector3
) -> void:
	trigger_pressed = value_trigger_pressed
	trigger_just_pressed = value_trigger_just_pressed
	aim_direction = WeaponMath.flat_direction(value_aim_direction)

func set_use_input(
	value_trigger_pressed: bool,
	value_trigger_just_pressed: bool,
	value_aim_direction: Vector3
) -> void:
	set_attack_input(
		value_trigger_pressed,
		value_trigger_just_pressed,
		value_aim_direction
	)

func set_equipped(value: bool) -> void:
	visible = value
	set_process(value)
	set_physics_process(value)
	if visual_anchor != null:
		visual_anchor.visible = value
	if not value:
		cancel_attack()

func cancel_attack() -> void:
	trigger_pressed = false
	trigger_just_pressed = false

func cancel_use() -> void:
	cancel_attack()

func get_display_name() -> String:
	return definition.display_name if definition != null else ""

func get_remaining_count() -> int:
	return -1

func get_idle_animation() -> StringName:
	return definition.idle_animation

func get_run_animation() -> StringName:
	return definition.run_animation
