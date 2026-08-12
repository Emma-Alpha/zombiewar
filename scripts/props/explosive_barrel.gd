extends StaticBody3D
class_name ExplosiveBarrel

## 纯表现件 + 玩家伤害源。
##
## 血量、命中计数、引信、连锁、对僵尸的伤害、以及自己占的阻挡 cell，
## 全部住在 SimWorld 的油桶实体里（sim_world.gd 的 barrel_* 数组）。
## 基线用场景树计时器做连锁延时，那是墙钟计时，各端会落在不同 tick 上，
## 被炸死的僵尸随之分叉——这正是本节点被掏空的原因。
## 注：Step 13 的表现件闸门按被禁关键字的字面名 grep 本文件且不区分代码与注释，
## 因此这段注释里不能出现那几个关键字的字面写法。
##
## 本节点只做四件事：
##   1. 把自己的导出参数交给地图运行时装配层注册进模拟层
##      （GameplayArena._register_barrel()）；
##   2. 收到模拟层的「受损」事件时切换外观；
##   3. 收到模拟层的「引爆」事件时播特效，并对**玩家**结算爆炸伤害；
##   4. 引爆表现完成后释放节点。
## 它不得再持有任何参与判定的状态，也不得自行决定何时爆炸。
const ExplosionResolver = preload("res://scripts/combat/explosion_resolver.gd")
const BARREL_EXPLOSION_SCENE := preload("res://scenes/fx/BarrelExplosion.tscn")
const AIM_POINT_HEIGHT := 0.72

@export_range(1, 10, 1) var firearm_hits_to_explode := 3
@export_range(1, 9, 1) var firearm_hits_to_damage := 2
@export_range(0.0, 2.0, 0.01) var chain_delay_seconds := 0.12
@export_range(0.1, 20.0, 0.1) var explosion_radius := 4.5
@export_range(0.0, 500.0, 1.0) var explosion_center_damage := 80.0
@export_range(0.0, 500.0, 1.0) var explosion_edge_damage := 20.0
## 基线是 7（层 1 世界 | 层 2 玩家 | 层 3 目标），现在收窄到只剩玩家层 2：
## 僵尸已退出物理世界（表现节点在层 4 且不在 damageable_targets 组），
## 其他油桶的连锁改由模拟层负责——保留层 1 会让物理侧再引爆一次
## 已经在模拟层引爆过的桶，两条路径各炸一遍。
@export_flags_3d_physics var explosion_target_mask := 2
@export_flags_3d_physics var explosion_obstacle_mask := 1

@onready var visual_root: Node3D = $VisualRoot
@onready var damage_smoke: Node3D = $DamageSmoke
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

## 模拟层实体 id，由 GameplayArena 在注册后回填。0 表示尚未注册。
var sim_barrel_id := 0
var exploded := false

func bind_sim_barrel(barrel_id_value: int) -> void:
	sim_barrel_id = barrel_id_value

func get_sim_barrel_id() -> int:
	return sim_barrel_id

## 爆心。模拟层的 SimHitGeometry.BARREL_AIM_HEIGHT 与本常量必须一致。
func get_explosion_aim_point() -> Vector3:
	return global_position + Vector3.UP * AIM_POINT_HEIGHT

## 模拟层判定命中数达到损伤阈值。纯外观，不改变任何参与判定的状态。
func play_damaged() -> void:
	visual_root.scale = Vector3(1.06, 0.88, 1.06)
	visual_root.rotation_degrees.z = 7.0
	if damage_smoke != null and damage_smoke.has_method("activate"):
		damage_smoke.call("activate")

## 模拟层判定本桶引爆。爆心由模拟层给出，保证与僵尸伤害用的是同一个点。
## 只对玩家结算：can_trigger_explosives = false 关掉物理侧的连锁，
## explosion_target_mask 也已收窄到玩家层——两道闸门都要在。
func play_explosion(origin: Vector3) -> void:
	if exploded:
		return
	exploded = true
	if collision_shape != null:
		collision_shape.set_deferred("disabled", true)
	if damage_smoke != null:
		if damage_smoke.has_method("deactivate"):
			damage_smoke.call("deactivate")
		else:
			damage_smoke.visible = false
	_spawn_explosion_fx(origin)
	var world := get_world_3d()
	if world != null:
		ExplosionResolver.resolve(
			world,
			origin,
			explosion_radius,
			explosion_center_damage,
			explosion_edge_damage,
			self,
			false,
			explosion_target_mask,
			explosion_obstacle_mask
		)
	queue_free()

func _spawn_explosion_fx(origin: Vector3) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var effect := BARREL_EXPLOSION_SCENE.instantiate() as BarrelExplosion
	parent.add_child(effect)
	effect.explode_at(origin)
