extends WeaponDefinition
class_name RangedWeaponDefinition

@export_range(1.0, 100.0, 0.5) var attack_range := 28.0
@export_flags_3d_physics var hit_collision_mask: int = 5
@export_range(1, 64, 1) var tracer_pool_size := 8
@export_group("Ballistic Spread")
@export_range(0.0, 12.0, 0.05) var base_spread_degrees := 0.5
@export_range(0.0, 12.0, 0.05) var max_spread_degrees := 5.0
@export_range(0.0, 12.0, 0.05) var spread_increase_per_shot_degrees := 0.65
@export_range(0.0, 20.0, 0.05) var spread_recovery_degrees_per_second := 1.5
