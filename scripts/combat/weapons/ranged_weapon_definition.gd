extends WeaponDefinition
class_name RangedWeaponDefinition

@export_range(1.0, 100.0, 0.5) var attack_range := 28.0
@export_flags_3d_physics var hit_collision_mask: int = 5
@export_range(1, 64, 1) var tracer_pool_size := 8
@export var muzzle_anchor_offset := Vector3(0.0, 0.0, -0.55)

@export_group("Wall Clearance")
@export_range(0.0, 3.0, 0.01) var wall_capsule_length := 0.0
@export_range(0.0, 0.5, 0.01) var wall_capsule_radius := 0.0
@export var wall_capsule_offset := Vector3.ZERO
@export_range(0.0, 90.0, 1.0) var wall_raise_angle_degrees := 65.0

func has_wall_clearance_profile() -> bool:
	return (
		is_finite(wall_capsule_length) and
		is_finite(wall_capsule_radius) and
		is_finite(wall_capsule_offset.x) and
		is_finite(wall_capsule_offset.y) and
		is_finite(wall_capsule_offset.z) and
		wall_capsule_radius > 0.0 and
		wall_capsule_length >= wall_capsule_radius * 2.0
	)
