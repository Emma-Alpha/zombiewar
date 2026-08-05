extends RefCounted
class_name WeaponSpreadState

const WeaponMath = preload("res://scripts/combat/weapon_math.gd")

var base_spread_degrees: float
var max_spread_degrees: float
var spread_increase_per_shot_degrees: float
var spread_recovery_degrees_per_second: float
var current_spread_degrees: float

func _init(
	value_base_spread_degrees: float,
	value_max_spread_degrees: float,
	value_spread_increase_per_shot_degrees: float,
	value_spread_recovery_degrees_per_second: float
) -> void:
	base_spread_degrees = maxf(value_base_spread_degrees, 0.0)
	max_spread_degrees = maxf(
		value_max_spread_degrees,
		base_spread_degrees
	)
	spread_increase_per_shot_degrees = maxf(
		value_spread_increase_per_shot_degrees,
		0.0
	)
	spread_recovery_degrees_per_second = maxf(
		value_spread_recovery_degrees_per_second,
		0.0
	)
	current_spread_degrees = base_spread_degrees

func tick(delta: float) -> void:
	current_spread_degrees = move_toward(
		current_spread_degrees,
		base_spread_degrees,
		spread_recovery_degrees_per_second * maxf(delta, 0.0)
	)

func resolve_shot_direction(
	base_direction: Vector3,
	normalized_random_offset: float
) -> Vector3:
	var resolved_base := WeaponMath.flat_direction(base_direction)
	var offset := clampf(normalized_random_offset, -1.0, 1.0)
	var angle := deg_to_rad(current_spread_degrees * offset)
	var resolved_direction := WeaponMath.flat_direction(
		resolved_base.rotated(Vector3.UP, angle)
	)
	current_spread_degrees = minf(
		current_spread_degrees + spread_increase_per_shot_degrees,
		max_spread_degrees
	)
	return resolved_direction

func reset() -> void:
	current_spread_degrees = base_spread_degrees
