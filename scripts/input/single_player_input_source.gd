extends "res://scripts/input/composite_input_source.gd"
class_name SinglePlayerInputSource

const KeyboardWasdInputSourceScript = preload("res://scripts/input/keyboard_wasd_input_source.gd")
const KeyboardArrowsInputSourceScript = preload("res://scripts/input/keyboard_arrows_input_source.gd")
const GamepadInputSourceScript = preload("res://scripts/input/gamepad_input_source.gd")

var keyboard_wasd := KeyboardWasdInputSourceScript.new()
var keyboard_arrows := KeyboardArrowsInputSourceScript.new()
var gamepad_sources: Dictionary = {}
var touch_source

func _init() -> void:
	super([keyboard_wasd, keyboard_arrows])

func set_touch_source(source) -> void:
	if touch_source != null:
		remove_source(touch_source)
	touch_source = source
	if touch_source != null:
		add_source(touch_source)

func sample():
	_sync_gamepads()
	return super()

func _sync_gamepads() -> void:
	var connected := Input.get_connected_joypads()
	for device_id in connected:
		if not gamepad_sources.has(device_id):
			var source := GamepadInputSourceScript.new(device_id)
			gamepad_sources[device_id] = source
			add_source(source)
	for device_id in gamepad_sources.keys():
		if not connected.has(device_id):
			remove_source(gamepad_sources[device_id])
			gamepad_sources.erase(device_id)
