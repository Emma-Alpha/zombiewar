extends RefCounted
class_name PlayerInputSource

const PlayerInputStateScript = preload("res://scripts/input/player_input_state.gd")

var previous_previous_pressed := false
var previous_next_pressed := false
var previous_use_pressed := false
var previous_confirm_pressed := false

func sample():
	return PlayerInputStateScript.new()

func is_online() -> bool:
	return true

func get_source_key() -> StringName:
	return &"unknown"

func reset_edges() -> void:
	previous_previous_pressed = false
	previous_next_pressed = false
	previous_use_pressed = false
	previous_confirm_pressed = false

func build_state(
	move: Vector2,
	previous: bool,
	next: bool,
	use: bool,
	confirm: bool
):
	var state := PlayerInputStateScript.new()
	state.move_vector = move.limit_length(1.0)
	state.previous_equipment_just_pressed = previous and not previous_previous_pressed
	state.next_equipment_just_pressed = next and not previous_next_pressed
	state.use_pressed = use
	state.use_just_pressed = use and not previous_use_pressed
	state.confirm_just_pressed = confirm and not previous_confirm_pressed
	previous_previous_pressed = previous
	previous_next_pressed = next
	previous_use_pressed = use
	previous_confirm_pressed = confirm
	return state
