extends RefCounted
class_name HitResponseMath

static func knockback_velocity(
	shot_direction: Vector3,
	impulse: float,
	multiplier: float,
	vertical_bias: float
) -> Vector3:
	var planar_direction := Vector3(shot_direction.x, 0.0, shot_direction.z)
	if planar_direction.length_squared() <= 0.000001:
		planar_direction = Vector3.FORWARD
	else:
		planar_direction = planar_direction.normalized()

	var base_impulse := maxf(impulse, 0.0)
	var horizontal_strength := base_impulse * maxf(multiplier, 0.0)
	var vertical_strength := base_impulse * maxf(vertical_bias, 0.0)
	return planar_direction * horizontal_strength + Vector3.UP * vertical_strength
