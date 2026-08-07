# 僵尸死亡随机拾取物实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 每只僵尸死亡时进行一次 `0.2` 概率判定，成功后在死亡位置生成内容随机的一次性拾取箱。

**架构：** `ZombieTarget` 只发出死亡位置事件；场景级 `RandomPickupDropManager` 负责概率、随机 Definition 和动态生成。随机掉落复用 `PickupSpawnPoint`，但开启一次性模式：领取成功后箱子消失，生成点在箱子退出树并发出导航移除通知后自动回收。

**技术栈：** Godot 4.7.1、GDScript、`PickupDefinition`、`PickupSpawnPoint`、场景级 RNG、头部验证脚本。

## 全局约束

- 仅在生命值首次归零时判定一次，不在每次命中时判定。
- 默认掉落概率必须精确为 `0.2`。
- 随机内容池为步枪 `+60`、步枪弹药 `+90`、油桶 `+30`，三项等概率。
- 随机掉落不进行三秒原地刷新；固定地图补给点继续保持三秒刷新。
- 领取失败时箱子和一次性生成点继续存在；成功领取后箱子先退出树并通知导航，再回收一次性生成点。
- 只奖励实际进入 Area3D 的玩家，装备和弹药仍按玩家实例独立保存。
- 不使用 Autoload；随机掉落状态由每个可玩场景自己的管理器持有。
- 管理器提供 `random_seed`，`0` 表示运行时随机，非零值用于固定验证。
- 保留当前工作区未提交的射速、血液、武器资源和相机改动，不覆盖无关内容。

---

### Task 1：死亡事件与一次性 PickupSpawnPoint 生命周期

**文件：**
- 修改：`scripts/combat/zombie_target.gd`
- 修改：`scripts/gameplay/pickup_spawn_point.gd`
- 新建：`tools/validation/validate_random_pickup_drops.gd`

**接口：**
- 产出：`ZombieTarget.died(world_position: Vector3)`。
- 产出：`PickupSpawnPoint.remove_after_collection: bool`，默认 `false`。
- 保留：固定补给点的 `respawn_enabled` 与 `respawn_delay_seconds`。

- [ ] **Step 1：编写失败验证**

验证必须覆盖：

```gdscript
var death_positions: Array[Vector3] = []
zombie.died.connect(func(position: Vector3) -> void: death_positions.append(position))
zombie.apply_hit(zombie.max_health, zombie.global_position, Vector3.FORWARD)
zombie.apply_hit(1.0, zombie.global_position, Vector3.FORWARD)
_expect(death_positions.size() == 1, "death must emit exactly once", failures)
```

以及一次性生成点成功领取的箱子退出树后，先产生导航移除通知，再让生成点进入删除队列；失败领取不得回收生成点。

- [ ] **Step 2：运行验证并确认 RED**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_random_pickup_drops.gd
```

预期退出码 `1`：缺少 `died` 信号或 `remove_after_collection` 生命周期。

- [ ] **Step 3：实现死亡信号**

在 `_on_depleted()` 首次设置 `depleted = true` 后保存当前世界位置并发出：

```gdscript
signal died(world_position: Vector3)

var death_position := global_position if is_inside_tree() else position
died.emit(death_position)
```

- [ ] **Step 4：实现一次性生成点回收**

```gdscript
@export var remove_after_collection := false
var collected_successfully := false
```

成功 `collected` 时记录 `collected_successfully = true`；在 `_on_pickup_tree_exited()` 完成 `current_pickup = null` 和 `navigation_geometry_changed.emit()` 后：

```gdscript
if remove_after_collection and collected_successfully:
	queue_free()
	return
```

外部删除或领取失败不能回收一次性生成点。

- [ ] **Step 5：运行验证并确认 GREEN**

运行随机掉落聚焦验证和 `validate_pickup_spawn_point.gd`，预期均退出码 `0`。

---

### Task 2：随机掉落管理器与 Demo 场景接线

**文件：**
- 新建：`scripts/gameplay/random_pickup_drop_manager.gd`
- 新建：`scenes/gameplay/RandomPickupDropManager.tscn`
- 修改：`scripts/gameplay/demo_arena.gd`
- 修改：`scenes/gameplay/DemoArena.tscn`
- 修改：`tools/validation/validate_random_pickup_drops.gd`

**接口：**
- 消费：`ZombieTarget.died(world_position: Vector3)`。
- 消费：三份现有 `PickupDefinition` 资源。
- 产出：`RandomPickupDropManager.try_spawn_drop(world_position: Vector3) -> PickupSpawnPoint`。
- 产出：`RandomPickupDropManager.navigation_geometry_changed`。

- [ ] **Step 1：扩展验证并确认 RED**

验证：默认概率为 `0.2`；`drop_chance = 0.0` 永不生成；`drop_chance = 1.0` 必定生成；生成点位于死亡位置、`respawn_enabled == false`、`remove_after_collection == true`，其 Definition 属于配置池；Demo 三个 Definition 都已配置并将僵尸死亡信号连接到管理器。

- [ ] **Step 2：实现 RandomPickupDropManager**

```gdscript
extends Node3D
class_name RandomPickupDropManager

signal navigation_geometry_changed

const SPAWN_POINT_SCENE := preload("res://scenes/gameplay/PickupSpawnPoint.tscn")

@export_range(0.0, 1.0, 0.01) var drop_chance := 0.2
@export var pickup_definitions: Array[PickupDefinition] = []
@export var random_seed := 0

var rng := RandomNumberGenerator.new()

func _ready() -> void:
	if random_seed == 0:
		rng.randomize()
	else:
		rng.seed = random_seed

func try_spawn_drop(world_position: Vector3) -> PickupSpawnPoint:
	if pickup_definitions.is_empty() or rng.randf() >= drop_chance:
		return null
	var spawner := SPAWN_POINT_SCENE.instantiate() as PickupSpawnPoint
	spawner.pickup_definition = pickup_definitions[rng.randi_range(0, pickup_definitions.size() - 1)]
	spawner.respawn_enabled = false
	spawner.remove_after_collection = true
	spawner.navigation_geometry_changed.connect(navigation_geometry_changed.emit)
	add_child(spawner)
	spawner.global_position = world_position
	return spawner
```

- [ ] **Step 3：接入 DemoArena**

`DemoArena.tscn` 新增场景级管理器并配置三份 Definition。`_wire_target()` 为每个 ZombieTarget 连接 `died`；死亡回调只调用管理器的 `try_spawn_drop(position)`。管理器的导航信号连接现有 `_on_runtime_navigation_geometry_changed()`。

- [ ] **Step 4：运行完整验证**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_random_pickup_drops.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_spawn_point.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_zombie_multiplayer_wiring.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --script res://tools/validation/validate_combat_frame_stability.gd --path .
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

预期全部退出码 `0`，且无新增脚本或场景解析错误。

- [ ] **Step 5：最终检查**

运行 `git diff --check`，确认固定补给点仍使用单 Definition 和三秒刷新，随机掉落只在死亡时触发并自动回收一次性生成点。
