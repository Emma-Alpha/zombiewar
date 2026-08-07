extends RefCounted
class_name FireGate

var interval: float
var remaining: float = 0.0
var buffered_trigger_remaining := 0.0

func _init(seconds_between_shots: float) -> void:
	interval = maxf(seconds_between_shots, 0.001)

func request_shot(buffer_seconds: float) -> void:
	buffered_trigger_remaining = maxf(
		buffered_trigger_remaining,
		maxf(buffer_seconds, 0.0)
	)

func tick(delta: float) -> void:
	var safe_delta := maxf(delta, 0.0)
	var was_cooling_down := remaining > 0.0
	remaining -= safe_delta
	if not was_cooling_down:
		buffered_trigger_remaining = maxf(
			buffered_trigger_remaining - safe_delta,
			0.0
		)

func try_consume(trigger_held: bool = true) -> bool:
	if not trigger_held and buffered_trigger_remaining <= 0.0:
		return false
	if remaining > 0.0:
		return false
	remaining = interval
	buffered_trigger_remaining = 0.0
	return true
