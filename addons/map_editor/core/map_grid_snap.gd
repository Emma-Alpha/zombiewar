extends RefCounted
class_name MapGridSnap

const AUTHORING_SUBDIVISIONS := 10.0


static func snap_step(definition: MapDefinition) -> float:
	return maxf(definition.grid_cell_size / AUTHORING_SUBDIVISIONS, 0.001)


static func snap_position(
	position: Vector3,
	definition: MapDefinition
) -> Vector3:
	var step := snap_step(definition)
	return Vector3(
		definition.grid_origin.x
			+ roundf((position.x - definition.grid_origin.x) / step) * step,
		position.y,
		definition.grid_origin.y
			+ roundf((position.z - definition.grid_origin.y) / step) * step
	)
