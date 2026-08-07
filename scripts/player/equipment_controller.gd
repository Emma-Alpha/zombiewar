extends Node
class_name EquipmentController

const HitResult = preload("res://scripts/combat/hit_result.gd")
const EquipmentItemScript = preload("res://scripts/player/equipment_item.gd")
const WeaponBaseScript = preload("res://scripts/combat/weapons/weapon_base.gd")
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
signal equipment_changed(display_name: String, remaining_count: int)

@export var loadout: Array[PackedScene] = []
@export_range(0, 8, 1) var starting_slot := 0

var equipment_items: Array = []
var current_slot := -1
var current_item
var initialized := false
var switch_guard := Callable()
var place_item_service

func set_switch_guard(value: Callable) -> void:
	switch_guard = value

func set_place_item_service(service) -> void:
	place_item_service = service
	for item in equipment_items:
		if item.has_method("set_place_item_service"):
			item.set_place_item_service(place_item_service)

func setup(
	wielder: CharacterBody3D,
	visual_root: Node3D,
	functional_ray_origin: Marker3D,
	value_switch_guard: Callable = Callable()
) -> void:
	if initialized:
		return
	initialized = true
	switch_guard = value_switch_guard
	_hide_embedded_weapons(visual_root)
	for item_scene in loadout:
		if item_scene == null:
			push_warning("EquipmentController skipped a null equipment scene")
			continue
		var item = item_scene.instantiate()
		if not item is EquipmentItemScript:
			push_warning("EquipmentController skipped a non-EquipmentItem scene")
			item.free()
			continue
		add_child(item)
		item.bind_context(wielder, visual_root, functional_ray_origin)
		if item.has_signal("attack_started"):
			item.attack_started.connect(_on_attack_started)
		if item.has_signal("attack_resolved"):
			item.attack_resolved.connect(_on_attack_resolved)
		item.count_changed.connect(_on_item_count_changed.bind(item))
		if item.has_method("set_place_item_service"):
			item.set_place_item_service(place_item_service)
		item.set_equipped(false)
		equipment_items.append(item)
	if not equip_slot(starting_slot):
		var fallback_slot := _find_available_slot(starting_slot - 1, 1)
		if fallback_slot >= 0:
			_equip_slot_unchecked(fallback_slot)
		else:
			_clear_current()

func equip_previous() -> bool:
	var slot := _find_available_slot(current_slot, -1)
	if slot < 0:
		return false
	return _equip_slot_unchecked(slot)

func equip_next() -> bool:
	var slot := _find_available_slot(current_slot, 1)
	if slot < 0:
		return false
	return _equip_slot_unchecked(slot)

func equip_slot(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= equipment_items.size():
		return false
	if not equipment_items[slot_index].is_available():
		return false
	if slot_index == current_slot:
		_emit_equipment_changed()
		return true
	return _equip_slot_unchecked(slot_index)

func set_use_input(
	pressed: bool,
	just_pressed: bool,
	aim_direction: Vector3
) -> void:
	if current_item != null:
		current_item.set_use_input(pressed, just_pressed, aim_direction)

func cancel_use() -> void:
	if current_item != null:
		current_item.cancel_use()

func set_attack_input(
	trigger_pressed: bool,
	trigger_just_pressed: bool,
	aim_direction: Vector3
) -> void:
	set_use_input(trigger_pressed, trigger_just_pressed, aim_direction)

func cancel_attack() -> void:
	cancel_use()

func get_current_item():
	return current_item

func get_current_weapon():
	return current_item if current_item is WeaponBaseScript else null

func get_current_definition() -> WeaponDefinition:
	var weapon = get_current_weapon()
	return weapon.definition if weapon != null else null

func get_current_display_name() -> String:
	return current_item.get_display_name() if current_item != null else "无可用装备"

func get_current_count() -> int:
	return current_item.get_remaining_count() if current_item != null else -1

func get_idle_animation() -> StringName:
	return current_item.get_idle_animation() if current_item != null else &"Idle"

func get_run_animation() -> StringName:
	return current_item.get_run_animation() if current_item != null else &"Run"

func _find_available_slot(start: int, direction: int) -> int:
	if equipment_items.is_empty():
		return -1
	for offset in range(1, equipment_items.size() + 1):
		var index := posmod(start + direction * offset, equipment_items.size())
		if equipment_items[index].is_available():
			return index
	return -1

func _equip_slot_unchecked(slot_index: int) -> bool:
	var candidate = equipment_items[slot_index]
	if switch_guard.is_valid() and candidate is WeaponBaseScript:
		if not bool(switch_guard.call(candidate)):
			return false
	if current_item != null:
		current_item.cancel_use()
		current_item.set_equipped(false)
	current_slot = slot_index
	current_item = candidate
	current_item.set_equipped(true)
	var definition := get_current_definition()
	if definition != null:
		weapon_changed.emit(definition)
	_emit_equipment_changed()
	return true

func _clear_current() -> void:
	if current_item != null:
		current_item.cancel_use()
		current_item.set_equipped(false)
	current_item = null
	current_slot = -1
	equipment_changed.emit("无可用装备", -1)

func _emit_equipment_changed() -> void:
	equipment_changed.emit(get_current_display_name(), get_current_count())

func _on_item_count_changed(_remaining_count: int, item) -> void:
	if item != current_item:
		return
	if not item.is_available():
		if not equip_next():
			_clear_current()
		return
	_emit_equipment_changed()

func _hide_embedded_weapons(visual_root: Node3D) -> void:
	for weapon_name in EMBEDDED_WEAPON_NAMES:
		var embedded_visual := visual_root.find_child(String(weapon_name), true, false) as Node3D
		if embedded_visual != null:
			embedded_visual.visible = false

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
