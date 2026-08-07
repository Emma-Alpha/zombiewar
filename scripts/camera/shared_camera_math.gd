extends RefCounted
class_name SharedCameraMath

static func edge_axis_weight(
	position: float,
	size: float,
	direction: float,
	start_ratio: float
) -> float:
	var start := clampf(start_ratio, 0.5, 0.95)
	if direction > 0.0 and position > size * start:
		return inverse_lerp(size * start, size, position) * direction
	if direction < 0.0 and position < size * (1.0 - start):
		return inverse_lerp(size * (1.0 - start), 0.0, position) * -direction
	return 0.0

static func edge_push(
	samples: Array,
	viewport_size: Vector2,
	edge_start_ratio: float,
	max_offset: float
) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for sample in samples:
		var x_weight := edge_axis_weight(
			sample.screen_position.x,
			viewport_size.x,
			sample.screen_move_direction.x,
			edge_start_ratio
		)
		var y_weight := edge_axis_weight(
			sample.screen_position.y,
			viewport_size.y,
			sample.screen_move_direction.y,
			edge_start_ratio
		)
		var weight := clampf(maxf(x_weight, y_weight), 0.0, 1.0)
		sum += sample.world_move_direction.limit_length(1.0) * weight
	var maximum := maxf(max_offset, 0.0)
	return (sum / float(samples.size()) * maximum).limit_length(maximum)

static func player_center(samples: Array) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for sample in samples:
		sum += sample.world_position
	return sum / float(samples.size())

static func desired_position(
	samples: Array,
	viewport_size: Vector2,
	edge_start_ratio: float,
	max_offset: float,
	fallback: Vector3
) -> Vector3:
	if samples.is_empty():
		return fallback
	var desired := player_center(samples) + edge_push(
		samples,
		viewport_size,
		edge_start_ratio,
		max_offset
	)
	desired.y = fallback.y
	return desired
