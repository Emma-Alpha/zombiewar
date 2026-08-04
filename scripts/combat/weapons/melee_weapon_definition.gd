extends WeaponDefinition
class_name MeleeWeaponDefinition

@export_flags_3d_physics var hit_collision_mask: int = 4
@export var hitbox_size := Vector3(1.5, 1.4, 1.4)
@export var hitbox_offset := Vector3(0.0, 1.0, -0.85)
@export_range(0.0, 1.0, 0.01) var impact_delay := 0.22
