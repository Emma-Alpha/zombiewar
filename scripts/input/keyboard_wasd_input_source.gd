extends "res://scripts/input/player_input_source.gd"
class_name KeyboardWasdInputSource

func sample():
	var move := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
	)
	return build_state(
		move,
		Input.is_physical_key_pressed(KEY_Q),
		Input.is_physical_key_pressed(KEY_E),
		Input.is_physical_key_pressed(KEY_SPACE),
		Input.is_physical_key_pressed(KEY_ENTER)
	)

func get_source_key() -> StringName:
	return &"keyboard_wasd"
