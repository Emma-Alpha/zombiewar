extends RefCounted
class_name FireGate

var interval: float
var remaining: float = 0.0

func _init(seconds_between_shots: float) -> void:
	interval = maxf(seconds_between_shots, 0.001)

func tick(delta: float) -> void:
	remaining = maxf(remaining - maxf(delta, 0.0), 0.0)

func try_consume() -> bool:
	if remaining > 0.0:
		return false
	remaining = interval
	return true
