extends Node
class_name EquipmentController

const HitResult = preload("res://scripts/combat/hit_result.gd")
const EMBEDDED_WEAPON_NAMES: Array[StringName] = [
	&"Axe", &"Guitar", &"Knife", &"Pistol", &"Rifle", &"Shotgun", &"SMG",
	&"Spear", &"WoodenBat_Barbed", &"WoodenBat_Saw",
]

signal attack_started(animation_name: StringName, lock_duration: float)
signal attack_resolved(
	origin: Vector3,
	direction: Vector3,
	result: HitResult,
	visual_recoil_kick: float,
	camera_impulse_strength: float
)
signal weapon_changed(definition: WeaponDefinition)

@export var loadout: Array[PackedScene] = []
@export_range(0, 8, 1) var starting_slot := 0

var weapons: Array[WeaponBase] = []
var current_slot := -1
var current_weapon: WeaponBase
var initialized := false

func setup(
	wielder: CharacterBody3D,
	visual_root: Node3D,
	functional_ray_origin: Marker3D
) -> void:
	if initialized:
		return
	initialized = true
	for weapon_name in EMBEDDED_WEAPON_NAMES:
		var embedded_visual := visual_root.find_child(
			String(weapon_name),
			true,
			false
		) as Node3D
		if embedded_visual != null:
			embedded_visual.visible = false
	for weapon_scene in loadout:
		var weapon := weapon_scene.instantiate() as WeaponBase
		add_child(weapon)
		weapon.bind_context(wielder, visual_root, functional_ray_origin)
		weapon.attack_started.connect(_on_attack_started)
		weapon.attack_resolved.connect(_on_attack_resolved)
		weapon.set_equipped(false)
		weapons.append(weapon)
	equip_slot(starting_slot)

func equip_slot(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= weapons.size():
		return false
	if slot_index == current_slot:
		return true
	if current_weapon != null:
		current_weapon.set_equipped(false)
	current_slot = slot_index
	current_weapon = weapons[current_slot]
	current_weapon.set_equipped(false)
	weapon_changed.emit(current_weapon.definition)
	current_weapon.set_equipped(true)
	return true

func set_attack_input(
	trigger_pressed: bool,
	trigger_just_pressed: bool,
	aim_direction: Vector3
) -> void:
	if current_weapon != null:
		current_weapon.set_attack_input(
			trigger_pressed,
			trigger_just_pressed,
			aim_direction
		)

func cancel_attack() -> void:
	if current_weapon != null:
		current_weapon.cancel_attack()

func get_current_weapon() -> WeaponBase:
	return current_weapon

func get_current_definition() -> WeaponDefinition:
	return current_weapon.definition if current_weapon != null else null

func get_idle_animation() -> StringName:
	return current_weapon.get_idle_animation() if current_weapon != null else &"Idle"

func get_run_animation() -> StringName:
	return current_weapon.get_run_animation() if current_weapon != null else &"Run"

func _on_attack_started(animation_name: StringName, lock_duration: float) -> void:
	attack_started.emit(animation_name, lock_duration)

func _on_attack_resolved(
	origin: Vector3,
	direction: Vector3,
	result: HitResult,
	visual_recoil_kick: float,
	camera_impulse_strength: float
) -> void:
	attack_resolved.emit(
		origin,
		direction,
		result,
		visual_recoil_kick,
		camera_impulse_strength
	)
