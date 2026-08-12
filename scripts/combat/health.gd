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
	if current == 0.0:
		depleted.emit()
	return applied

## 治疗。返回实际恢复量；不超过上限。
func heal(amount: float) -> float:
	var applied := minf(maxf(amount, 0.0), maximum - current)
	if applied <= 0.0:
		return 0.0
	current += applied
	changed.emit(current, maximum)
	return applied
