extends RefCounted
class_name SimClock

## 固定 20Hz 模拟节拍，与渲染帧率解耦。
## 模拟层函数一律不接收 delta，只使用 TICK_SECONDS。
const TICK_SECONDS := 0.05
const MAX_CATCHUP_TICKS := 5

var accumulator := 0.0
var tick_index := 0

func reset() -> void:
	accumulator = 0.0
	tick_index = 0

## 消费一个渲染帧的真实 delta，返回本帧应推进的整数 tick 数。
## 单帧最多追赶 MAX_CATCHUP_TICKS 个 tick，超出的欠账直接丢弃以避免卡顿后雪崩。
func consume_frame(frame_delta: float) -> int:
	accumulator += maxf(frame_delta, 0.0)
	var ticks := 0
	while accumulator >= TICK_SECONDS and ticks < MAX_CATCHUP_TICKS:
		accumulator -= TICK_SECONDS
		ticks += 1
	# 丢弃欠账时必须清零而不是钳到 TICK_SECONDS：钳到 TICK_SECONDS 会让
	# 下一帧即使 delta 为 0 也满足 accumulator >= TICK_SECONDS 并再吐一个 tick，
	# 被丢弃的欠账就以「每帧多一个 tick」的形式重新浮现。
	if accumulator >= TICK_SECONDS:
		accumulator = 0.0
	tick_index += ticks
	return ticks

func get_tick_index() -> int:
	return tick_index

## 渲染帧在上一 tick 与当前 tick 之间的插值系数。
func get_interpolation_alpha() -> float:
	return clampf(accumulator / TICK_SECONDS, 0.0, 1.0)
