extends RefCounted
class_name PlayerInputState

var move_vector := Vector2.ZERO
var previous_equipment_just_pressed := false
var next_equipment_just_pressed := false
var use_pressed := false
var use_just_pressed := false
var confirm_just_pressed := false

func merge_from(other) -> void:
	if other == null:
		return
	move_vector = (move_vector + other.move_vector).limit_length(1.0)
	previous_equipment_just_pressed = (
		previous_equipment_just_pressed or
		other.previous_equipment_just_pressed
	)
	next_equipment_just_pressed = (
		next_equipment_just_pressed or
		other.next_equipment_just_pressed
	)
	use_pressed = use_pressed or other.use_pressed
	use_just_pressed = use_just_pressed or other.use_just_pressed
	confirm_just_pressed = confirm_just_pressed or other.confirm_just_pressed
