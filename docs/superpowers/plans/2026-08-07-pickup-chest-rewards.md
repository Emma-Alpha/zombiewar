# 通用拾取箱与奖励 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 使用统一 `Chest.gltf` 建立步枪、步枪弹药和油桶三类拾取箱，只奖励实际进入领取区域的玩家，并在成功后删除整个箱子实例。

**Architecture:** `PickupChest` 只负责实体碰撞、领取区域、奖励类型和视觉标记。它调用进入者自己的 `PlayerController` 拾取接口；奖励成功后发出 `collected` 并删除自身。是否刷新、何时刷新以及在哪里生成由下一计划的场景生成器负责。

**Tech Stack:** Godot 4.7.1、GDScript、StaticBody3D、Area3D、Label3D、Godot 原生几何、现有 `Chest.gltf` 与中文字体。

## Global Constraints

- 前置计划 `2026-08-07-weapon-ammo-core.md`、`2026-08-07-equipment-ownership-inventory.md` 和 `2026-08-07-player-equipment-label.md` 必须完成。
- 步枪箱增加 60 发并请求自动装备步枪；首次领取同时授予步枪拥有状态。
- 弹药箱增加 90 发，不授予尚未拥有的步枪，也不自动切换装备。
- 油桶箱增加 30 个，不自动切换装备。
- 步枪弹药上限为 360，油桶上限为 999。
- 只有实际改变进入者状态时才成功领取；满库存、无步枪领取弹药、死亡玩家都不能消耗箱子。
- 本地多人只奖励实际进入 `Area3D` 的 `PlayerController`，不得遍历其他玩家。
- 同一物理帧多个玩家同时进入时，只允许第一个成功领取者获得奖励。
- 三类箱子都复用 `assets/environment/Chest.gltf`。
- 步枪使用橙色、弹药使用蓝色、油桶使用绿色光圈/信标/短标签。
- 箱子具有实体碰撞，阻挡玩家和僵尸，并加入 `navigation_source` 与 `place_item_obstacle`。
- 通用拾取箱不包含 Timer、不保存刷新时间，也不自行重新生成。
- 所有运行时放置的拾取箱必须由下一计划的 `PickupSpawnPoint` 管理，以保证删除碰撞后通知导航 dirty。
- 不新增第三方素材。
- 本计划最终只保留一个提交：`feat: add pickup chest rewards`。

---

### Task 1: 创建通用拾取箱和三种奖励变体

**Files:**
- Create: `scripts/gameplay/pickup_chest.gd`
- Create (Godot-generated): `scripts/gameplay/pickup_chest.gd.uid`
- Create: `scenes/gameplay/PickupChest.tscn`
- Create: `scenes/gameplay/RiflePickupChest.tscn`
- Create: `scenes/gameplay/RifleAmmoPickupChest.tscn`
- Create: `scenes/gameplay/OilBarrelPickupChest.tscn`

**Interfaces:**
- Consumes: `PlayerController.receive_equipment_pickup(item_id: StringName, amount: int, auto_equip: bool = false) -> bool`、`PlayerController.receive_ammo_pickup(item_id: StringName, amount: int) -> bool`、`PlayerController.is_alive() -> bool`。
- Produces: `PickupChest.collected(pickup: PickupChest)`、`RewardType` 枚举、成功领取后 `queue_free()` 生命周期。

- [ ] **Step 1: 实现 PickupChest 奖励控制器**

创建 `scripts/gameplay/pickup_chest.gd`：

```gdscript
extends StaticBody3D
class_name PickupChest

enum RewardType {
	RIFLE,
	RIFLE_AMMO,
	OIL_BARREL,
}

signal collected(pickup: PickupChest)

const RIFLE_ID := &"rifle"
const OIL_BARREL_ID := &"oil_barrel"

@export var reward_type := RewardType.RIFLE
@export_range(1, 9999, 1) var reward_amount := 60

@onready var claim_area: Area3D = $ClaimArea
@onready var marker_ring: MeshInstance3D = $MarkerRing
@onready var marker_beacon: MeshInstance3D = $MarkerBeacon
@onready var reward_label: Label3D = $RewardLabel

var claim_locked := false

func _ready() -> void:
	claim_area.body_entered.connect(_on_body_entered)
	_apply_reward_visuals()

func _on_body_entered(body: Node3D) -> void:
	if claim_locked or not body is PlayerController:
		return
	var player := body as PlayerController
	if not player.is_alive() or not _grant_reward(player):
		return
	claim_locked = true
	claim_area.set_deferred("monitoring", false)
	collected.emit(self)
	queue_free()

func _grant_reward(player: PlayerController) -> bool:
	match reward_type:
		RewardType.RIFLE:
			return player.receive_equipment_pickup(
				RIFLE_ID,
				reward_amount,
				true
			)
		RewardType.RIFLE_AMMO:
			return player.receive_ammo_pickup(RIFLE_ID, reward_amount)
		RewardType.OIL_BARREL:
			return player.receive_equipment_pickup(
				OIL_BARREL_ID,
				reward_amount,
				false
			)
	return false

func _apply_reward_visuals() -> void:
	var color := _reward_color()
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
	reward_label.text = _reward_label_text()
	reward_label.modulate = color

func _reward_color() -> Color:
	match reward_type:
		RewardType.RIFLE:
			return Color(1.0, 0.42, 0.08, 1.0)
		RewardType.RIFLE_AMMO:
			return Color(0.12, 0.56, 1.0, 1.0)
		RewardType.OIL_BARREL:
			return Color(0.20, 0.90, 0.35, 1.0)
	return Color.WHITE

func _reward_label_text() -> String:
	match reward_type:
		RewardType.RIFLE:
			return "步枪 +%d" % reward_amount
		RewardType.RIFLE_AMMO:
			return "弹药 +%d" % reward_amount
		RewardType.OIL_BARREL:
			return "油桶 +%d" % reward_amount
	return "补给"
```

不要在脚本中创建 Timer 或调用场景级导航管理器。

- [ ] **Step 2: 创建带实体碰撞和领取区域的基础场景**

`PickupChest.tscn` 的根节点和关键子节点必须为：

```text
PickupChest (StaticBody3D, navigation_source, place_item_obstacle)
├── Visual (Chest.gltf)
├── CollisionShape3D (箱体实体碰撞)
├── ClaimArea (Area3D, mask=Player)
│   └── CollisionShape3D (大于箱体的领取范围)
├── MarkerRing (MeshInstance3D, TorusMesh)
├── MarkerBeacon (MeshInstance3D, SphereMesh)
└── RewardLabel (Label3D)
```

先声明资源和形状。标记材质必须挂到两个原生网格上，使 `_apply_reward_visuals()` 的 `get_active_material(0)` 一定能取得可复制材质：

```ini
[gd_scene load_steps=9 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/pickup_chest.gd" id="1_pickup"]
[ext_resource type="PackedScene" path="res://assets/environment/Chest.gltf" id="2_chest"]
[ext_resource type="FontFile" path="res://assets/fonts/NotoSansSC-UI.ttf" id="3_font"]

[sub_resource type="BoxShape3D" id="BoxShape3D_chest"]
size = Vector3(0.64, 0.41, 0.48)

[sub_resource type="CylinderShape3D" id="CylinderShape3D_claim"]
radius = 1.15
height = 1.8

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_marker"]
shading_mode = 0
albedo_color = Color(1, 1, 1, 0.82)
transparency = 1
emission_enabled = true
emission = Color(1, 1, 1, 1)
emission_energy_multiplier = 2.0

[sub_resource type="TorusMesh" id="TorusMesh_marker"]
material = SubResource("StandardMaterial3D_marker")
inner_radius = 0.72
outer_radius = 0.84

[sub_resource type="SphereMesh" id="SphereMesh_beacon"]
material = SubResource("StandardMaterial3D_marker")
radius = 0.11
height = 0.22
```

按以下节点参数落地场景：

```ini
[node name="PickupChest" type="StaticBody3D" groups=["navigation_source", "place_item_obstacle"]]
collision_layer = 1
collision_mask = 0
script = ExtResource("1_pickup")

[node name="Visual" parent="." instance=ExtResource("2_chest")]

[node name="CollisionShape3D" type="CollisionShape3D" parent="."]
position = Vector3(0, 0.205, 0)
shape = SubResource("BoxShape3D_chest")

[node name="ClaimArea" type="Area3D" parent="."]
collision_layer = 0
collision_mask = 2
monitoring = true
monitorable = false

[node name="CollisionShape3D" type="CollisionShape3D" parent="ClaimArea"]
position = Vector3(0, 0.9, 0)
shape = SubResource("CylinderShape3D_claim")

[node name="MarkerRing" type="MeshInstance3D" parent="."]
position = Vector3(0, 0.035, 0)
mesh = SubResource("TorusMesh_marker")

[node name="MarkerBeacon" type="MeshInstance3D" parent="."]
position = Vector3(0, 1.05, 0)
mesh = SubResource("SphereMesh_beacon")

[node name="RewardLabel" type="Label3D" parent="."]
position = Vector3(0, 1.35, 0)
font = ExtResource("3_font")
font_size = 24
outline_size = 8
billboard = 1
no_depth_test = true
fixed_size = true
```

领取区域半径为 `1.15`、高度为 `1.8`，确保玩家不必穿过实体碰撞才能领取。`collision_mask = 2` 对应当前 `project.godot` 的 Player 层；不要改为扫描玩家注册表。

- [ ] **Step 3: 创建三个固定奖励变体**

`RiflePickupChest.tscn`：

```ini
reward_type = 0
reward_amount = 60
```

`RifleAmmoPickupChest.tscn`：

```ini
reward_type = 1
reward_amount = 90
```

`OilBarrelPickupChest.tscn`：

```ini
reward_type = 2
reward_amount = 30
```

三个变体都继承 `PickupChest.tscn`；每份场景使用以下最小继承结构，不要复制 `Chest.gltf`、碰撞或视觉节点定义：

```ini
[gd_scene load_steps=2 format=3]

[ext_resource type="PackedScene" path="res://scenes/gameplay/PickupChest.tscn" id="1_base"]

[node name="RiflePickupChest" instance=ExtResource("1_base")]
reward_type = 0
reward_amount = 60
```

另外两份分别把根节点名和奖励值改为 `RifleAmmoPickupChest / 1 / 90`、`OilBarrelPickupChest / 2 / 30`。

- [ ] **Step 4: 运行资源导入与脚本检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
git diff --check
```

Expected: 五个功能文件能够导入；无脚本解析、场景继承或资源路径错误。

随后运行 `git status --short`，确认 Godot 已生成并跟踪 `scripts/gameplay/pickup_chest.gd.uid`；不得把 `.godot/` 加入提交。

- [ ] **Step 5: 检查领取安全条件**

Run:

```bash
rg -n "PlayerController|claim_locked|receive_equipment_pickup|receive_ammo_pickup|queue_free|Timer|mark_chunk_dirty" \
  scripts/gameplay/pickup_chest.gd
```

确认：

- 奖励只传给进入的 `body as PlayerController`。
- 只有奖励接口返回 `true` 才锁定并删除。
- 锁定发生在删除前，避免同帧双领。
- 脚本不包含 Timer、随机生成或导航管理器查询。

- [ ] **Step 6: 提交本计划**

```bash
git add \
  scripts/gameplay/pickup_chest.gd \
  scripts/gameplay/pickup_chest.gd.uid \
  scenes/gameplay/PickupChest.tscn \
  scenes/gameplay/RiflePickupChest.tscn \
  scenes/gameplay/RifleAmmoPickupChest.tscn \
  scenes/gameplay/OilBarrelPickupChest.tscn
git commit -m "feat: add pickup chest rewards"
```

Expected: 本计划只有一个提交；不修改 `DemoArena.tscn`，不包含刷新生成器。
