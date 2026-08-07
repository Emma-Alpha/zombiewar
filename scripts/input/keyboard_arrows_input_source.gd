extends "res://scripts/input/player_input_source.gd"
class_name KeyboardArrowsInputSource

func sample():
	var move := Vector2(
		float(Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_LEFT)),
		float(Input.is_physical_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_UP))
	)
	return build_state(
		move,
		Input.is_physical_key_pressed(KEY_COMMA),
		Input.is_physical_key_pressed(KEY_PERIOD),
		Input.is_physical_key_pressed(KEY_SLASH),
		Input.is_physical_key_pressed(KEY_ENTER)
	)

func get_source_key() -> StringName:
	return &"keyboard_arrows"
