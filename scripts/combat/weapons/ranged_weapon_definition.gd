extends WeaponDefinition
class_name RangedWeaponDefinition

@export_range(1.0, 100.0, 0.5) var attack_range := 28.0
@export_flags_3d_physics var hit_collision_mask: int = 5
@export_range(1, 64, 1) var tracer_pool_size := 8
@export_group("Ammo")
@export var uses_ammo := false
@export_range(0, 9999, 1) var max_ammo := 0
@export_group("Penetration")
@export_range(0.0, 1.0, 0.05) var penetration_damage_coefficient := 0.0
@export_range(0, 16, 1) var max_penetration_count := 0
@export_group("Pellets")
## 一次扣扳机打出的弹丸数。1 = 单发弹道；大于 1 时散布锥被均分给每颗弹丸，
## 于是「散布角」从命中抖动变成了扇面宽度，霰弹枪的距离衰减也随之成立：
## 近距离整簇打在同一个目标上，远距离散开、只有几颗能命中。
## damage 始终是**单颗弹丸**的伤害，不是一枪的总伤害。
@export_range(1, 32, 1) var pellet_count := 1

@export_group("Ballistic Spread")
@export_range(0.0, 12.0, 0.05) var base_spread_degrees := 0.5
@export_range(0.0, 12.0, 0.05) var max_spread_degrees := 5.0
@export_range(0.0, 12.0, 0.05) var spread_increase_per_shot_degrees := 0.65
@export_range(0.0, 20.0, 0.05) var spread_recovery_degrees_per_second := 1.5
