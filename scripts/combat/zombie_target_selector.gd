extends RefCounted
class_name ZombieTargetSelector

static func select_target(
	origin: Vector3,
	current: PlayerController,
	candidates: Array[PlayerController],
	perception_range: float,
	switch_margin: float
) -> PlayerController:
	var current_distance := INF
	if _is_candidate(current, origin, perception_range):
		current_distance = origin.distance_to(current.global_position)
	var best := current if current_distance < INF else null
	var best_distance := current_distance
	for candidate in candidates:
		if not _is_candidate(candidate, origin, perception_range):
			continue
		var distance := origin.distance_to(candidate.global_position)
		if distance + maxf(switch_margin, 0.0) < best_distance:
			best = candidate
			best_distance = distance
	return best

static func _is_candidate(
	candidate: PlayerController,
	origin: Vector3,
	perception_range: float
) -> bool:
	return (
		is_instance_valid(candidate) and
		candidate.is_alive() and
		origin.distance_to(candidate.global_position) <= maxf(perception_range, 0.0)
	)
