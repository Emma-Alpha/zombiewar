# 数据驱动拾取物定义实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 所有补给统一实例化 `PickupChest.tscn`，由 `PickupDefinition` 资源决定奖励、数量和视觉，不再维护步枪、步枪弹药、油桶三份专用拾取场景。

**架构：** `PickupDefinition` 是可复用的自定义 `Resource`，保存奖励模式、物品 ID、数量、自动装备与显示参数，并提供 `grant_to(player)`。`PickupSpawnPoint` 固定实例化唯一的 `PickupChest.tscn`，在加入场景树前注入 Definition；`PickupChest` 仅处理 Area3D 领取、视觉刷新和生命周期。

**技术栈：** Godot 4.7.1、GDScript、`.tres` 自定义资源、`.tscn` 场景、头部验证脚本。

## 全局约束

- Definition 必须使用同一个 `PickupDefinition` 类，不为步枪、弹药或油桶新增脚本子类。
- 保留 `Chest.gltf`、领取 Area3D、导航几何通知和场景级 3 秒刷新行为。
- 步枪奖励为装备 `rifle`、`+60`、自动装备；步枪弹药为弹药 `rifle`、`+90`；油桶为装备 `oil_barrel`、`+30`、不自动装备。
- 只奖励实际进入对应 Area3D 的玩家，每个玩家的装备和弹药保持独立。
- 为未来随机 Definition 与随机刷新时间保留现有 `_next_spawn_transform()`、`_next_respawn_delay()` 扩展点。
- 保留工作区中现有射速/血液优化及用户正在编辑的资源、相机改动，不覆盖无关文件。
- 按 TDD 先观察聚焦验证失败，再实现最小代码；所有任务完成后只保留一个计划提交，除非用户要求立即提交。

---

### Task 1：建立通用 PickupDefinition 与 PickupChest 契约

**文件：**
- 新建：`scripts/gameplay/pickup_definition.gd`
- 新建：`tools/validation/validate_pickup_definitions.gd`
- 修改：`scripts/gameplay/pickup_chest.gd`
- 修改：`scenes/gameplay/PickupChest.tscn`

**接口：**
- 产出：`PickupDefinition.grant_to(player: PlayerController) -> bool`
- 产出：`PickupChest.configure(value: PickupDefinition) -> void`
- 产出：`PickupChest.definition: PickupDefinition`
- 消费：`PlayerController.receive_equipment_pickup(item_id, amount, auto_equip)` 与 `receive_ammo_pickup(item_id, amount)`。

- [ ] **Step 1：编写失败验证**

在 `validate_pickup_definitions.gd` 中验证 `PickupDefinition` 配置、`PickupChest.configure()`、标签文本、空 Definition 拒绝领取，以及 AMMO/EQUIPMENT 两种模式调用玩家现有奖励入口。

- [ ] **Step 2：运行验证并确认 RED**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_definitions.gd
```

预期：退出码 `1`，原因是 `PickupDefinition`、`configure()` 或通用 Definition 契约尚不存在。

- [ ] **Step 3：实现 PickupDefinition**

```gdscript
extends Resource
class_name PickupDefinition

enum RewardMode { EQUIPMENT, AMMO }

@export var reward_mode := RewardMode.EQUIPMENT
@export var item_id: StringName
@export_range(1, 9999, 1) var amount := 1
@export var auto_equip := false
@export var display_name := "补给"
@export var marker_color := Color.WHITE

func grant_to(player: PlayerController) -> bool:
	if player == null or not player.is_alive() or item_id.is_empty() or amount <= 0:
		return false
	match reward_mode:
		RewardMode.EQUIPMENT:
			return player.receive_equipment_pickup(item_id, amount, auto_equip)
		RewardMode.AMMO:
			return player.receive_ammo_pickup(item_id, amount)
	return false

func get_label_text() -> String:
	return "%s +%d" % [display_name, amount]
```

- [ ] **Step 4：把 PickupChest 改为消费 Definition**

删除 `RewardType`、硬编码物品 ID、`reward_type`、`reward_amount` 和三个奖励分支，改为：

```gdscript
@export var definition: PickupDefinition

func configure(value: PickupDefinition) -> void:
	definition = value
	if is_node_ready():
		_apply_reward_visuals()

func _grant_reward(player: PlayerController) -> bool:
	return definition != null and definition.grant_to(player)

func get_reward_label_text() -> String:
	return definition.get_label_text() if definition != null else "未配置补给"
```

视觉颜色统一读取 `definition.marker_color`；`PickupChest.tscn` 不预设具体奖励。

- [ ] **Step 5：运行验证并确认 GREEN**

运行 Task 1 的聚焦验证，预期退出码 `0` 且打印 `validate_pickup_definitions: PASS`。

---

### Task 2：迁移生成点、Definition 资源和 Demo 场景

**文件：**
- 新建：`resources/pickups/rifle_pickup.tres`
- 新建：`resources/pickups/rifle_ammo_pickup.tres`
- 新建：`resources/pickups/oil_barrel_pickup.tres`
- 修改：`scripts/gameplay/pickup_spawn_point.gd`
- 修改：`scenes/gameplay/DemoArena.tscn`
- 修改：`tools/validation/validate_pickup_spawn_point.gd`
- 删除：`scenes/gameplay/RiflePickupChest.tscn`
- 删除：`scenes/gameplay/RifleAmmoPickupChest.tscn`
- 删除：`scenes/gameplay/OilBarrelPickupChest.tscn`

**接口：**
- 消费：`PickupChest.configure(value: PickupDefinition) -> void`
- 产出：`PickupSpawnPoint.pickup_definition: PickupDefinition`
- 保留：`PickupChest.collected` 处理、导航几何信号、固定位置和 3 秒刷新。

- [ ] **Step 1：更新生成点验证并确认 RED**

验证 `pickup_definition` 注入、三个 Demo 生成点的 Definition、统一 `PickupChest.tscn`、专用场景移除、固定位置和三秒刷新配置。

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_spawn_point.gd
```

预期：退出码 `1`，原因是生成点仍使用 `pickup_scene`。

- [ ] **Step 2：创建三份 Definition 资源**

```text
rifle_pickup.tres       EQUIPMENT  rifle       60  auto_equip=true   步枪      橙色
rifle_ammo_pickup.tres  AMMO       rifle       90  auto_equip=false  步枪弹药  蓝色
oil_barrel_pickup.tres  EQUIPMENT  oil_barrel  30  auto_equip=false  油桶      绿色
```

- [ ] **Step 3：让 PickupSpawnPoint 固定实例化通用箱子**

```gdscript
const PICKUP_SCENE := preload("res://scenes/gameplay/PickupChest.tscn")
@export var pickup_definition: PickupDefinition
```

生成时先 `configure(pickup_definition)`，再 `add_child(current_pickup)`；其余 collected、tree_exited、Timer 和导航通知逻辑保持不变。

- [ ] **Step 4：迁移 DemoArena 并删除专用场景**

把三个生成点的 `pickup_scene` 引用替换为对应 `pickup_definition` 资源；删除三个专用 `.tscn`。不要改变生成位置、`respawn_enabled = true` 或 `respawn_delay_seconds = 3.0`。

- [ ] **Step 5：运行聚焦与回归验证**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_definitions.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_spawn_point.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

预期：全部退出码 `0`；Godot 不报告脚本、资源或场景解析错误。

- [ ] **Step 6：最终检查**

运行 `git diff --check`，确认只包含本计划文件与拾取重构文件。任务提交先保留在隔离分支，最终按项目约定 squash 为一个 Conventional Commit 后合并。
