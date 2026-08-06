extends RefCounted
class_name ExplosionMath

static func damage_at_distance(
	distance: float,
	radius: float,
	center_damage: float,
	edge_damage: float
) -> float:
	if radius <= 0.0 or distance > radius:
		return 0.0
	var ratio := clampf(maxf(distance, 0.0) / radius, 0.0, 1.0)
	return lerpf(
		maxf(center_damage, 0.0),
		maxf(edge_damage, 0.0),
		ratio
	)
