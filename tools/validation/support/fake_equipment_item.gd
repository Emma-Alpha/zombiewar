extends "res://scripts/player/equipment_item.gd"

@export var display_name := ""
@export var remaining_count := -1
@export var available := true

var use_calls := 0

func set_use_input(_pressed: bool, just_pressed: bool, _aim: Vector3) -> void:
	if just_pressed:
		use_calls += 1

func is_available() -> bool:
	return available and remaining_count != 0

func get_display_name() -> String:
	return display_name

func get_remaining_count() -> int:
	return remaining_count

func consume_last() -> void:
	remaining_count = 0
	available = false
	count_changed.emit(remaining_count)
