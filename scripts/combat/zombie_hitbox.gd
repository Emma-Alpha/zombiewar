extends Area3D
class_name ZombieHitbox

const HitResult = preload("res://scripts/combat/hit_result.gd")

func apply_hit(
	amount: float,
	hit_position: Vector3,
	shot_direction: Vector3
) -> HitResult:
	var target: Node = get_parent().get_parent()
	if target == null or not target.has_method("apply_hit"):
		return HitResult.miss(hit_position)
	var result: Variant = target.call(
		"apply_hit",
		amount,
		hit_position,
		shot_direction
	)
	return result as HitResult if result is HitResult else HitResult.miss(hit_position)
