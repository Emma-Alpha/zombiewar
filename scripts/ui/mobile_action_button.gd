extends Control
class_name MobileActionButton

@export var action: StringName
@export var normal_color := Color(0.06, 0.08, 0.10, 0.58)
@export var pressed_color := Color(1.0, 0.38, 0.10, 0.88)
@export var outline_color := Color(1.0, 0.72, 0.12, 0.82)
@export var outline_inset := 4.0
@export var outline_width := 4.0

var active_touch_id := -1
var pressed := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not (event is InputEventScreenTouch):
		return
	var touch := event as InputEventScreenTouch
	if touch.pressed and active_touch_id == -1 and get_global_rect().has_point(touch.position):
		active_touch_id = touch.index
		set_pressed(true)
	elif not touch.pressed and touch.index == active_touch_id:
		cancel()

func set_pressed(value: bool) -> void:
	if pressed == value:
		return
	pressed = value
	if not action.is_empty():
		if pressed:
			Input.action_press(action)
		else:
			Input.action_release(action)
	queue_redraw()

func cancel() -> void:
	active_touch_id = -1
	set_pressed(false)

func _draw() -> void:
	var center := size * 0.5
	var radius := maxf(minf(size.x, size.y) * 0.5 - outline_inset, 0.0)
	draw_circle(center, radius, pressed_color if pressed else normal_color)
	draw_arc(center, radius, 0.0, TAU, 64, outline_color, outline_width, true)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()

func _exit_tree() -> void:
	cancel()
