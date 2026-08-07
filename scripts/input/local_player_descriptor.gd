extends RefCounted
class_name LocalPlayerDescriptor

const KeyboardWasdInputSourceScript = preload(
	"res://scripts/input/keyboard_wasd_input_source.gd"
)
const KeyboardArrowsInputSourceScript = preload(
	"res://scripts/input/keyboard_arrows_input_source.gd"
)
const GamepadInputSourceScript = preload(
	"res://scripts/input/gamepad_input_source.gd"
)

enum SourceKind {
	KEYBOARD_WASD,
	KEYBOARD_ARROWS,
	GAMEPAD,
}

var player_index := 0
var source_kind := SourceKind.KEYBOARD_WASD
var gamepad_device_id := -1
var online := true

func source_key() -> StringName:
	match source_kind:
		SourceKind.KEYBOARD_WASD:
			return &"keyboard_wasd"
		SourceKind.KEYBOARD_ARROWS:
			return &"keyboard_arrows"
		SourceKind.GAMEPAD:
			return StringName("gamepad_%d" % gamepad_device_id)
		_:
			return &"invalid"

func create_input_source():
	match source_kind:
		SourceKind.KEYBOARD_WASD:
			return KeyboardWasdInputSourceScript.new()
		SourceKind.KEYBOARD_ARROWS:
			return KeyboardArrowsInputSourceScript.new()
		SourceKind.GAMEPAD:
			if gamepad_device_id < 0:
				return null
			return GamepadInputSourceScript.new(gamepad_device_id)
		_:
			return null
