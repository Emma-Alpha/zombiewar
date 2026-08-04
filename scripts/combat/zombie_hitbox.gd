extends Area3D
class_name ZombieHitbox

const HitResult = preload("res://scripts/combat/hit_result.gd")

@export var hit_zone: StringName = &"torso"
@export_range(0.1, 3.0, 0.05) var damage_multiplier: float = 1.0
@export_range(0.1, 3.0, 0.05) var knockback_multiplier: float = 1.0
@export_range(0.0, 1.0, 0.01) var vertical_bias: float = 0.05

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
		shot_direction,
		hit_zone,
		damage_multiplier,
		knockback_multiplier,
		vertical_bias
	)
	return result as HitResult if result is HitResult else HitResult.miss(hit_position)
