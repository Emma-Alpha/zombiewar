extends "res://scripts/input/player_input_source.gd"

var move := Vector2.ZERO
var previous_pressed := false
var next_pressed := false
var use_pressed := false
var confirm_pressed := false

func sample():
	return build_state(
		move,
		previous_pressed,
		next_pressed,
		use_pressed,
		confirm_pressed
	)
