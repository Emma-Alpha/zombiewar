extends RefCounted
class_name MenuEntrance

## 三个菜单屏共用的「开机自检」入场：元素从左侧错峰滑入，标题先落地，
## 其余元素随后级联。和主菜单用的是同一套节奏，保证整个前端像一套系统。

const SLIDE_DISTANCE := 26.0
const FADE_DURATION := 0.42
const SLIDE_DURATION := 0.5
const TITLE_GAP := 0.075
const CASCADE_GAP := 0.05

## host 用来创建 Tween；elements 按入场顺序排列；title_index 是标题的位置，
## 它落地后跟一个稍长的停顿，让级联有「先定调、再展开」的呼吸感。
static func play(host: Node, elements: Array, title_index := 0) -> void:
	var delay := 0.0
	for index in elements.size():
		var element := elements[index] as Control
		if element == null:
			continue
		_reveal(host, element, delay)
		delay += TITLE_GAP if index == title_index else CASCADE_GAP

static func _reveal(host: Node, element: Control, delay: float) -> void:
	var start_x := element.position.x - SLIDE_DISTANCE
	element.modulate.a = 0.0
	element.position.x = start_x
	var tween := host.create_tween().set_parallel(true)
	tween.tween_property(element, "modulate:a", 1.0, FADE_DURATION) \
		.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(element, "position:x", start_x + SLIDE_DISTANCE, SLIDE_DURATION) \
		.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
