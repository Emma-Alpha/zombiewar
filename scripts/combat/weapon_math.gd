extends RefCounted
class_name WeaponMath

static func forward_direction(player_basis: Basis) -> Vector3:
	return flat_direction(-player_basis.z)

static func ray_end(origin: Vector3, player_basis: Basis, max_range: float) -> Vector3:
	return ray_end_from_direction(origin, -player_basis.z, max_range)

static func flat_direction(direction: Vector3) -> Vector3:
	var flat := Vector3(direction.x, 0.0, direction.z)
	return flat.normalized() if flat.length_squared() > 0.000001 else Vector3.FORWARD

static func ray_end_from_direction(
	origin: Vector3,
	direction: Vector3,
	max_range: float
) -> Vector3:
	return origin + flat_direction(direction) * maxf(max_range, 0.0)
