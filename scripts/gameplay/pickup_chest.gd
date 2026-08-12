extends StaticBody3D
class_name PickupChest

const PickupDefinition = preload("res://scripts/gameplay/pickup_definition.gd")
const PICKUP_SOUND := preload("res://assets/sfx/boxhead/pickup.mp3")

@export var definition: PickupDefinition

@onready var claim_area: Area3D = $ClaimArea
@onready var marker_ring: MeshInstance3D = $MarkerRing
@onready var marker_beacon: MeshInstance3D = $MarkerBeacon
@onready var reward_label: Label3D = $RewardLabel

var claim_locked := false
var spatial_sfx_pool: SpatialSfxPool
var reward_amount := -1
## 模拟层实体 id。0 表示还没注册（例如大厅预览里的箱子）。
var sim_chest_id := 0

func _ready() -> void:
	spatial_sfx_pool = SpatialSfxPool.find_for(self)
	# ClaimArea 不再驱动领取，只留着做碰撞外形；监听一律关掉。
	# 领取判定在 SimWorld._resolve_chest_claims() 里：物理重叠发生在表现层，
	# 而表现层各端的玩家位置本来就不一致（本机跑在前、远端是插值追上来的），
	# 用它来决定「谁拿到了这个箱子」必然分叉。
	claim_area.monitoring = false
	_apply_reward_visuals()

func configure(value: PickupDefinition, amount_override: int = -1) -> void:
	definition = value
	reward_amount = amount_override
	if is_node_ready():
		_apply_reward_visuals()

func bind_sim_chest(chest_id_value: int) -> void:
	sim_chest_id = chest_id_value

func get_sim_chest_id() -> int:
	return sim_chest_id

## 由竞技场在模拟层判定领取之后调用——「谁碰到了」已经判完，这里只兑现与演出。
##
## 兑现失败（弹药已满）时箱子**照样**消耗掉。基线在这里会提前返回、把箱子
## 留在地上，但那个判断读的是玩家当前的弹药与存活，而这两个量在各端差着一个
## RTT，于是同一个箱子在一端被消耗、在另一端被留下，模拟就此分叉。
## 详见 SimWorld 里 release_chest 缺席的那段说明。
func claim_by(player: PlayerController) -> void:
	if claim_locked:
		return
	claim_locked = true
	if player != null and definition != null:
		definition.grant_to(player, reward_amount)
	if spatial_sfx_pool != null:
		spatial_sfx_pool.play_at(PICKUP_SOUND, global_position, -5.0, 1.0, 24.0)
	queue_free()

func _apply_reward_visuals() -> void:
	var color: Color = definition.marker_color if definition != null else Color.WHITE
	for mesh_instance in [marker_ring, marker_beacon]:
		var material := mesh_instance.get_active_material(0) as StandardMaterial3D
		if material == null:
			continue
		material = material.duplicate() as StandardMaterial3D
		material.albedo_color = color
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = 2.0
		mesh_instance.set_surface_override_material(0, material)
	reward_label.text = get_reward_label_text()
	reward_label.modulate = color

func get_reward_label_text() -> String:
	return definition.get_label_text(reward_amount) if definition != null else "未配置补给"
