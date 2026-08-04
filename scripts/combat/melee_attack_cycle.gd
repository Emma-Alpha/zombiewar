extends RefCounted
class_name MeleeAttackCycle

var cooldown_duration: float
var windup_duration: float
var cooldown_remaining := 0.0
var windup_remaining := 0.0
var pending := false

func _init(cooldown_seconds: float, windup_seconds: float) -> void:
	cooldown_duration = maxf(cooldown_seconds, 0.01)
	windup_duration = maxf(windup_seconds, 0.0)

func tick(delta: float, target_in_range: bool, target_alive: bool) -> bool:
	var safe_delta := maxf(delta, 0.0)
	cooldown_remaining = maxf(cooldown_remaining - safe_delta, 0.0)
	if pending:
		windup_remaining = maxf(windup_remaining - safe_delta, 0.0)
		if windup_remaining <= 0.0:
			pending = false
			return target_in_range and target_alive
	if not pending and target_in_range and target_alive and cooldown_remaining <= 0.0:
		pending = true
		windup_remaining = windup_duration
		cooldown_remaining = cooldown_duration
	return false

func is_winding_up() -> bool:
	return pending

func cancel_pending() -> void:
	pending = false
	windup_remaining = 0.0
