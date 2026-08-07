extends "res://scripts/input/player_input_source.gd"
class_name TouchInputSource

var move_vector := Vector2.ZERO
var previous_pressed := false
var next_pressed := false
var use_pressed := false
var game_over_active := false

func set_move_vector(value: Vector2) -> void:
	move_vector = value.limit_length(1.0)

func set_previous_pressed(value: bool) -> void:
	previous_pressed = value

func set_next_pressed(value: bool) -> void:
	next_pressed = value

func set_use_pressed(value: bool) -> void:
	use_pressed = value

func set_game_over_active(value: bool) -> void:
	game_over_active = value
	previous_confirm_pressed = use_pressed if value else false

func clear_input() -> void:
	move_vector = Vector2.ZERO
	previous_pressed = false
	next_pressed = false
	use_pressed = false
	reset_edges()

func sample():
	return build_state(
		move_vector,
		previous_pressed,
		next_pressed,
		use_pressed,
		game_over_active and use_pressed
	)

func get_source_key() -> StringName:
	return &"touch"
