extends CanvasLayer
class_name MobileOrientationGuard

const MobileTouchscreen = preload("res://scripts/ui/mobile_touchscreen.gd")

@export var force_touchscreen := false
@export_node_path("Node") var input_cancel_target_path: NodePath

@onready var overlay: Control = $Overlay

var paused_by_guard := false

static func should_block(
	touchscreen_available: bool,
	viewport_size: Vector2
) -> bool:
	return touchscreen_available and viewport_size.y > viewport_size.x

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not get_viewport().size_changed.is_connected(refresh_orientation):
		get_viewport().size_changed.connect(refresh_orientation)
	refresh_orientation()

func _exit_tree() -> void:
	if paused_by_guard and get_tree() != null:
		get_tree().paused = false
	paused_by_guard = false

func refresh_orientation() -> void:
	var touchscreen_available := force_touchscreen or (
		MobileTouchscreen.is_physical_touchscreen_available()
	)
	var blocked := should_block(
		touchscreen_available,
		get_viewport().get_visible_rect().size
	)
	overlay.visible = blocked
	if blocked:
		_cancel_gameplay_input()
		if not get_tree().paused:
			get_tree().paused = true
			paused_by_guard = true
	elif paused_by_guard:
		get_tree().paused = false
		paused_by_guard = false

func _cancel_gameplay_input() -> void:
	if input_cancel_target_path.is_empty():
		return
	var target := get_node_or_null(input_cancel_target_path)
	if target != null and target.has_method("cancel_all_input"):
		target.call("cancel_all_input")
