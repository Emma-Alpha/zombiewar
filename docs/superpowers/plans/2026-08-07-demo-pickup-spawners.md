# Demo 拾取生成点与导航同步 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让场景级生成点拥有拾取箱生命周期，在 Demo 出生区域生成三类箱子、领取后等待 3 秒原地重生，并在实体碰撞增删后触发导航重烘焙。

**Architecture:** `PickupSpawnPoint` 始终拥有一个可选的 `PickupChest` 子实例。箱子成功领取并退出场景树后，生成点通知场景导航几何变化；只有配置了 `respawn_enabled` 的场景才启动 Timer 并再次生成。生成位置与刷新时间通过可覆盖方法隔离，为后续随机掉落或随机刷新策略保留扩展点。

**Tech Stack:** Godot 4.7.1、GDScript、PackedScene、Timer、现有 `NavigationWorldManager` 与 DemoArena 场景。

## Global Constraints

- 前置计划 `2026-08-07-pickup-chest-rewards.md` 必须完成。
- 通用拾取箱本身不刷新；生命周期只由 `PickupSpawnPoint` 控制。
- `PickupSpawnPoint.respawn_enabled` 默认必须为 `false`，其他场景默认是一次性拾取。
- Demo 的步枪、弹药、油桶生成点都配置为固定原位置和固定 3 秒刷新。
- Demo 不再给任何玩家出生步枪或 30 发弹药。
- 三个生成点不得与 P1-P4 出生胶囊重叠，也不得让一名玩家同时进入多个领取区域。
- 每次箱体碰撞生成或删除后，才发出 `navigation_geometry_changed`；不得在几何改变之前发信号。
- Demo 把该信号接入现有 `NavigationWorldManager.mark_chunk_dirty(&"demo_arena")`。
- 保留补给点现有四个 `SupplyChest` 为纯装饰物，不改为功能箱。
- 本次不实现随机位置、掉落概率或随机刷新时间；只提供可覆盖的生成 Transform 和刷新延迟方法。
- 当前仓库没有持久化自动测试套件；使用 headless import 和单人/多人 Demo 人工验收。
- 本计划最终只保留一个提交：`feat: add demo pickup spawners`。

---

### Task 1: 创建场景级生成器并配置 Demo 三个固定生成点

**Files:**
- Create: `scripts/gameplay/pickup_spawn_point.gd`
- Create (Godot-generated): `scripts/gameplay/pickup_spawn_point.gd.uid`
- Create: `scenes/gameplay/PickupSpawnPoint.tscn`
- Modify: `scripts/gameplay/demo_arena.gd:164-211`
- Modify: `scripts/gameplay/demo_arena.gd:355-368`
- Modify: `scenes/gameplay/DemoArena.tscn:1-26`
- Modify: `scenes/gameplay/DemoArena.tscn:430-492`

**Interfaces:**
- Consumes: `PickupChest.collected(pickup: PickupChest)`、`NavigationWorldManager.mark_chunk_dirty(chunk_id) -> bool`。
- Produces: `PickupSpawnPoint.navigation_geometry_changed`、`respawn_enabled: bool`、`respawn_delay_seconds: float`、`_next_spawn_transform() -> Transform3D`、`_next_respawn_delay() -> float`。

- [ ] **Step 1: 实现 PickupSpawnPoint 生命周期**

创建 `scripts/gameplay/pickup_spawn_point.gd`：

```gdscript
extends Node3D
class_name PickupSpawnPoint

signal navigation_geometry_changed

@export var pickup_scene: PackedScene
@export var respawn_enabled := false
@export_range(0.0, 300.0, 0.1) var respawn_delay_seconds := 3.0

@onready var respawn_timer: Timer = $RespawnTimer

var current_pickup: PickupChest
var current_pickup_id := 0
var respawn_requested := false

func _ready() -> void:
	respawn_timer.timeout.connect(_spawn_pickup)
	call_deferred("_spawn_pickup")

func _spawn_pickup() -> void:
	if current_pickup != null and is_instance_valid(current_pickup):
		return
	if pickup_scene == null:
		push_warning("PickupSpawnPoint has no pickup scene: %s" % get_path())
		return
	var instance := pickup_scene.instantiate()
	if not instance is PickupChest:
		push_warning("PickupSpawnPoint requires a PickupChest scene: %s" % get_path())
		instance.free()
		return
	current_pickup = instance as PickupChest
	add_child(current_pickup)
	current_pickup.transform = _next_spawn_transform()
	current_pickup_id = current_pickup.get_instance_id()
	respawn_requested = false
	current_pickup.collected.connect(_on_pickup_collected)
	current_pickup.tree_exited.connect(
		_on_pickup_tree_exited.bind(current_pickup_id),
		CONNECT_ONE_SHOT
	)
	navigation_geometry_changed.emit()

func _on_pickup_collected(pickup: PickupChest) -> void:
	if pickup == current_pickup:
		respawn_requested = respawn_enabled

func _on_pickup_tree_exited(pickup_id: int) -> void:
	if pickup_id != current_pickup_id:
		return
	current_pickup = null
	current_pickup_id = 0
	navigation_geometry_changed.emit()
	if not respawn_requested:
		return
	respawn_requested = false
	respawn_timer.start(maxf(_next_respawn_delay(), 0.0))

func _next_spawn_transform() -> Transform3D:
	return Transform3D.IDENTITY

func _next_respawn_delay() -> float:
	return respawn_delay_seconds
```

`tree_exited` 回调是删除后的导航通知点；不要在 `collected` 回调中提前通知导航。

- [ ] **Step 2: 创建生成点场景**

`PickupSpawnPoint.tscn`：

```ini
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/pickup_spawn_point.gd" id="1_spawner"]

[node name="PickupSpawnPoint" type="Node3D"]
script = ExtResource("1_spawner")

[node name="RespawnTimer" type="Timer" parent="."]
one_shot = true
autostart = false
```

不要在场景中预设 `pickup_scene`；每个地图实例显式选择箱子类型。

- [ ] **Step 3: 把 Demo 的运行时导航回调改为通用名称**

在 `demo_arena.gd` 中把 `_on_barrel_navigation_geometry_changed()` 重命名为：

```gdscript
func _on_runtime_navigation_geometry_changed() -> void:
	var navigation_manager := get_node_or_null(
		"World/Navigation"
	) as NavigationWorldManager
	if navigation_manager != null:
		navigation_manager.mark_chunk_dirty(&"demo_arena")
```

同步更新以下现有连接：

- `ExplosiveBarrel.navigation_geometry_changed`
- `PlaceItemService.placement_geometry_changed`

在 `_wire_dependencies()` 中增加：

```gdscript
var pickup_spawners := get_node_or_null("World/Props/PickupSpawners")
if pickup_spawners != null:
	for child in pickup_spawners.get_children():
		if (
			child is PickupSpawnPoint and
			not child.navigation_geometry_changed.is_connected(
				_on_runtime_navigation_geometry_changed
			)
		):
			child.navigation_geometry_changed.connect(
				_on_runtime_navigation_geometry_changed
			)
```

由于 `PickupSpawnPoint` 使用 `call_deferred("_spawn_pickup")`，父场景 `_ready()` 完成依赖连接后才生成首个箱子，初次生成信号不会丢失。

- [ ] **Step 4: 在 Demo 配置三类固定生成点**

在 `DemoArena.tscn` 增加 ext_resource：

```ini
[ext_resource type="PackedScene" path="res://scenes/gameplay/PickupSpawnPoint.tscn" id="24_pickup_spawn_point"]
[ext_resource type="PackedScene" path="res://scenes/gameplay/RiflePickupChest.tscn" id="25_rifle_pickup"]
[ext_resource type="PackedScene" path="res://scenes/gameplay/RifleAmmoPickupChest.tscn" id="26_rifle_ammo_pickup"]
[ext_resource type="PackedScene" path="res://scenes/gameplay/OilBarrelPickupChest.tscn" id="27_oil_barrel_pickup"]
```

同时把 `DemoArena.tscn` 头部的 `load_steps` 从 `50` 更新为 `54`，并在 `World/Props` 下新增：

```ini
[node name="PickupSpawners" type="Node3D" parent="World/Props"]

[node name="Rifle" parent="World/Props/PickupSpawners" instance=ExtResource("24_pickup_spawn_point")]
position = Vector3(-4.5, 0, 6.0)
pickup_scene = ExtResource("25_rifle_pickup")
respawn_enabled = true
respawn_delay_seconds = 3.0

[node name="RifleAmmo" parent="World/Props/PickupSpawners" instance=ExtResource("24_pickup_spawn_point")]
position = Vector3(0, 0, 9.0)
pickup_scene = ExtResource("26_rifle_ammo_pickup")
respawn_enabled = true
respawn_delay_seconds = 3.0

[node name="OilBarrel" parent="World/Props/PickupSpawners" instance=ExtResource("24_pickup_spawn_point")]
position = Vector3(4.5, 0, 6.0)
pickup_scene = ExtResource("27_oil_barrel_pickup")
respawn_enabled = true
respawn_delay_seconds = 3.0
```

这些位置与 P1-P4 的出生位置 `(-1.2, 6.2)`、`(1.2, 6.2)`、`(-1.2, 4.2)`、`(1.2, 4.2)` 保持分离。

- [ ] **Step 5: 运行 Godot 解析和场景导入检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
git diff --check
```

Expected: 生成器、三个继承箱场景和 DemoArena 都能导入；没有丢失类名、信号或 PackedScene 路径。

随后运行 `git status --short`，确认 Godot 已生成并跟踪 `scripts/gameplay/pickup_spawn_point.gd.uid`；不得把 `.godot/` 加入提交。

- [ ] **Step 6: 人工验证单人核心路径**

1. 进入 Demo，确认默认只能切换手枪与匕首。
2. 靠近橙色箱，确认获得步枪 60 发并自动切换，标签显示 `P1 · 步枪:60`。
3. 开一枪，确认标签变为 `P1 · 步枪:59`。
4. 领取蓝色箱，确认增加 90 发但不强制切换；上限不超过 360。
5. 领取绿色箱，确认获得 30 个油桶，切换后显示 `P1 · 油桶:30`。
6. 三类箱子成功领取后都应整个消失，约 3 秒后在原位置重新出现。
7. 步枪 360 发或油桶 999 个时，对应箱子保持存在。
8. 尚未拥有步枪时接触蓝色弹药箱，箱子保持存在。

- [ ] **Step 7: 人工验证本地多人独立领取**

1. 创建至少 2 名本地玩家。
2. 只让 P1 进入步枪箱，确认 P1 获得步枪，P2 仍只能使用手枪和匕首。
3. 只让 P2 进入油桶箱，确认 P2 获得 30 个油桶，P1 库存不变。
4. 两名玩家同时靠近同一个箱子，确认只有第一个成功进入并改变状态的玩家得到奖励。
5. 确认箱体存在时玩家和僵尸会绕行；领取删除和 3 秒重生后，僵尸导航没有长期卡死或穿过已重生箱体。

- [ ] **Step 8: 审查未来生成扩展边界**

Run:

```bash
rg -n "_next_spawn_transform|_next_respawn_delay|rand|random|drop" \
  scripts/gameplay/pickup_spawn_point.gd
```

Expected:

- 基类提供 `_next_spawn_transform()` 与 `_next_respawn_delay()`。
- 当前实现不包含随机算法。
- 后续随机生成器可以继承或覆盖两个方法，而不修改 `PickupChest` 奖励逻辑。

- [ ] **Step 9: 提交本计划**

```bash
git add \
  scripts/gameplay/pickup_spawn_point.gd \
  scripts/gameplay/pickup_spawn_point.gd.uid \
  scenes/gameplay/PickupSpawnPoint.tscn \
  scripts/gameplay/demo_arena.gd \
  scenes/gameplay/DemoArena.tscn
git commit -m "feat: add demo pickup spawners"
```

Expected: 本计划只有一个提交；四个既有装饰 `SupplyChest` 保持未修改。
