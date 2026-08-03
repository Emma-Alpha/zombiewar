extends RefCounted
class_name WeaponMath

static func forward_direction(player_basis: Basis) -> Vector3:
	var direction := -player_basis.z
	direction.y = 0.0
	return direction.normalized()

static func ray_end(origin: Vector3, player_basis: Basis, max_range: float) -> Vector3:
	return origin + forward_direction(player_basis) * maxf(max_range, 0.0)
