extends Node3D
class_name EquipmentItem

signal count_changed(remaining_count: int)

func bind_context(
	_wielder: CharacterBody3D,
	_visual_root: Node3D,
	_functional_ray_origin: Marker3D
) -> void:
	pass

func set_use_input(_pressed: bool, _just_pressed: bool, _aim: Vector3) -> void:
	pass

func cancel_use() -> void:
	pass

func is_available() -> bool:
	return true

func get_item_id() -> StringName:
	return &""

func receive_pickup(_amount: int) -> bool:
	return false

func get_display_name() -> String:
	return ""

func get_remaining_count() -> int:
	return -1

func get_count_text() -> String:
	return "—"

func set_equipped(value: bool) -> void:
	visible = value
	set_process(value)
	set_physics_process(value)
	if not value:
		cancel_use()

func get_idle_animation() -> StringName:
	return &"Idle"

func get_run_animation() -> StringName:
	return &"Run"
