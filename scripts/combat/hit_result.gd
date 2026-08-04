extends RefCounted
class_name HitResult

var did_hit := false
var damage_applied := 0.0
var hit_zone: StringName = &""
var critical := false
var killed := false
var position := Vector3.ZERO

static func miss(end_position: Vector3) -> HitResult:
	var result := new()
	result.position = end_position
	return result

static func resolved(
	value_damage_applied: float,
	value_hit_zone: StringName,
	value_critical: bool,
	value_killed: bool,
	value_position: Vector3
) -> HitResult:
	var result := new()
	result.did_hit = true
	result.damage_applied = maxf(value_damage_applied, 0.0)
	result.hit_zone = value_hit_zone
	result.critical = value_critical
	result.killed = value_killed
	result.position = value_position
	return result
