extends SceneTree

const PlayerInputState = preload("res://scripts/input/player_input_state.gd")
const PlayerInputSource = preload("res://scripts/input/player_input_source.gd")
const CompositeInputSource = preload("res://scripts/input/composite_input_source.gd")

class FixedInputSource extends PlayerInputSource:
	var next_state: PlayerInputState

	func _init(value: PlayerInputState) -> void:
		next_state = value

	func sample() -> PlayerInputState:
		return next_state

func _init() -> void:
	var failures: Array[String] = []
	_test_state_merge(failures)
	_test_edge_detection(failures)
	_test_composite_merge(failures)
	if failures.is_empty():
		print("validate_local_input_contracts: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _test_state_merge(failures: Array[String]) -> void:
	var left := PlayerInputState.new()
	left.move_vector = Vector2.LEFT
	left.previous_equipment_just_pressed = true
	var right := PlayerInputState.new()
	right.move_vector = Vector2.RIGHT
	right.next_equipment_just_pressed = true
	right.use_pressed = true
	right.use_just_pressed = true
	right.confirm_just_pressed = true
	left.merge_from(right)
	_expect(left.move_vector == Vector2.ZERO, "opposite movement must cancel", failures)
	_expect(left.previous_equipment_just_pressed, "previous edge must survive merge", failures)
	_expect(left.next_equipment_just_pressed, "next edge must merge with logical OR", failures)
	_expect(left.use_pressed and left.use_just_pressed, "use state must merge with logical OR", failures)
	_expect(left.confirm_just_pressed, "confirm edge must merge with logical OR", failures)

func _test_edge_detection(failures: Array[String]) -> void:
	var source := PlayerInputSource.new()
	var first = source.build_state(Vector2.UP, true, false, true, true)
	var held = source.build_state(Vector2.UP, true, false, true, true)
	var released = source.build_state(Vector2.ZERO, false, false, false, false)
	var pressed_again = source.build_state(Vector2.ZERO, true, false, true, true)
	_expect(first.previous_equipment_just_pressed, "first previous press must create an edge", failures)
	_expect(first.use_just_pressed and first.confirm_just_pressed, "first action press must create edges", failures)
	_expect(not held.previous_equipment_just_pressed, "held previous press must not repeat", failures)
	_expect(not held.use_just_pressed and not held.confirm_just_pressed, "held action must not repeat edges", failures)
	_expect(not released.use_pressed, "release must clear held state", failures)
	_expect(pressed_again.previous_equipment_just_pressed, "press after release must create a new edge", failures)
	_expect(pressed_again.use_just_pressed and pressed_again.confirm_just_pressed, "action press after release must create new edges", failures)

func _test_composite_merge(failures: Array[String]) -> void:
	var first := PlayerInputState.new()
	first.move_vector = Vector2(1.0, 0.0)
	first.use_pressed = true
	var second := PlayerInputState.new()
	second.move_vector = Vector2(0.0, -1.0)
	second.next_equipment_just_pressed = true
	var composite := CompositeInputSource.new([
		FixedInputSource.new(first),
		FixedInputSource.new(second),
	])
	var merged = composite.sample()
	_expect(merged.move_vector.is_equal_approx(Vector2(1.0, -1.0).normalized()), "composite movement must be length-limited", failures)
	_expect(merged.use_pressed, "composite must preserve held use", failures)
	_expect(merged.next_equipment_just_pressed, "composite must preserve equipment edges", failures)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
