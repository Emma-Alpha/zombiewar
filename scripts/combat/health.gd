extends RefCounted
class_name Health

signal changed(current: float, maximum: float)
signal depleted

var maximum: float
var current: float

func _init(starting_maximum: float) -> void:
	maximum = maxf(starting_maximum, 1.0)
	current = maximum

func apply_damage(amount: float) -> float:
	var applied := minf(maxf(amount, 0.0), current)
	if applied <= 0.0:
		return 0.0
	current -= applied
	changed.emit(current, maximum)
	if is_zero_approx(current):
		depleted.emit()
	return applied
