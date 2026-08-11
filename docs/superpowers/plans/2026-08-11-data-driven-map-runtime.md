# 数据驱动地图运行时与 Demo 地图迁移 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立由 `MapDefinition` 驱动的确定性地图运行时，并把现有 `DemoArena` 迁移成通过地图资源和地图内容场景加载的 Demo 地图。

**Architecture:** 通用 `GameplayArena` 继续持有玩家、HUD、联网帧消费、`SimWorld`、渲染器和放置服务；地图资源提供网格、玩家出生点、僵尸类型、波次、固定物品和死亡事件规则，地图内容场景只提供模型、碰撞、灯光、装饰和场景爆炸桶。所有会改变玩法的波次推进、刷怪类型、死亡事件随机、补给领取与补给重生均由固定 tick 的模拟层决定；旧 Godot 导航系统已经删除，不得恢复任何 NavMesh、导航服务器或异步烘焙路径。

**Tech Stack:** Godot 4.7.1、GDScript、`.tres` Resource、`.tscn` 场景、`SimWorld`、`DeterministicRng`、整数流场、无头 Godot 验证脚本。

## Global Constraints

- 计划范围只包含数据驱动运行时与现有 Demo 地图迁移，不包含 Godot 地图编辑器 Dock、新建地图向导、Gizmo 或运行时玩家地图编辑器。
- 时间字段在资源中直接保存 tick；`spawn_interval_ticks`、`inter_wave_delay_ticks`、`respawn_delay_ticks` 不接受秒数。
- 概率字段直接保存万分比整数，合法范围为 `0..10000`；运行时必须使用整数随机判定，不比较浮点概率。
- 每波按 `zombie_entries` 的资源顺序展开；每个条目保存精确 `count`，不保留当前“每角随机 12..18”语义。
- 同一波的生成点从 `spawn_points` 按稳定 `spawn_id` 排序后轮询分配；不得依赖场景树遍历顺序。
- `spawn_interval_ticks == 0` 表示在同一 tick 内尽可能生成整波；大于 `0` 表示相邻两只僵尸的计划生成 tick 相差该值。
- `end_mode == COMPLETE` 时，最后一波清空后结束地图并返回主菜单；`end_mode == LOOP` 时回到第 1 波，不增加生命、速度、数量或其他强化系数。
- Demo 地图使用 `LOOP`，每轮一波普通僵尸 `×60`、`spawn_interval_ticks = 0`、`inter_wave_delay_ticks = 30`，以固定总量替代当前每角 12..18 的随机数量。
- 固定物品开局立即出现；成功领取后等待 `respawn_delay_ticks`，在确定的模拟 tick 原位置重新出现。
- 僵尸死亡事件按地图配置：不同事件组独立判定，同一组命中后按整数权重互斥选择一个事件。
- 第一版只执行 `DROP_ITEM` 死亡事件；资源枚举保留 `ENHANCEMENT`，地图校验必须拒绝尚无运行时消费者的强化事件，不能静默吞掉。
- 随机刷怪位置继续使用 `DeterministicRng.Stream.ZOMBIE_SPAWN`；死亡事件使用 `DeterministicRng.Stream.LOOT_DROP`。
- 新增或改变的模拟状态必须进入 `SimHasher`，包括僵尸类型、波次运行状态、补给奖励/状态/重生 tick。
- 地图碰撞对象继续以 `place_item_obstacle` 分组作为静态流场阻挡来源，但扫描范围必须限制在当前地图内容根节点内。
- 爆炸桶不得进入普通静态阻挡烘焙；仍由 `SimWorld.spawn_barrel()`、引爆事件和 `queue_barrel_removal()`独占管理阻挡生命周期。
- 不得出现 `NavigationWorldManager`、`NavigationChunk3D`、`NavigationBakeState`、`NavigationAgent3D`、`NavigationServer3D`、`NavigationRegion3D`、`navigation_geometry_changed` 或 `navigation_source`。
- 联机客户端仍然只消费服务端下发的帧，每帧恰好推进一个 tick；本计划不新增地图选择协议，联机入口继续固定加载 Demo 地图。
- `LobbyProtocol.QUANT`、`LobbyProtocol.TICK_HZ` 和客户端/服务端 `PROTOCOL_VERSION` 不因纯资源化而变化；如实现期间修改线上帧字段，则必须另行提升双方协议版本。
- 保留当前未跟踪的 `scripts/menu/menu_entrance.gd.uid`，不得把它纳入本功能提交。
- 每个任务可保留临时 Conventional Commit；全部任务与最终评审完成后，在合并目标分支前 squash 为一个计划提交：`feat: add data-driven map runtime`。

## File Structure

### 新增地图数据资源类型

- `scripts/gameplay/map/zombie_definition.gd`：全局僵尸类型，保存稳定 ID、显示场景、生命值和移动速度倍率。
- `scripts/gameplay/map/map_spawn_point_definition.gd`：地图刷怪点稳定 ID、XZ 位置、生成半径和最小间距。
- `scripts/gameplay/map/wave_zombie_entry_definition.gd`：一条“僵尸类型 × 精确数量”。
- `scripts/gameplay/map/map_wave_definition.gd`：一波的生成间隔和条目列表。
- `scripts/gameplay/map/death_event_definition.gd`：死亡事件类型、权重、物品 Definition、数量和未来强化 ID。
- `scripts/gameplay/map/death_event_group_definition.gd`：万分比触发概率与组内互斥事件。
- `scripts/gameplay/map/map_zombie_death_rule_definition.gd`：地图内某种僵尸对应的死亡事件组。
- `scripts/gameplay/map/fixed_item_spawn_definition.gd`：固定补给稳定 ID、位置、物品、数量和 tick 重生间隔。
- `scripts/gameplay/map/map_definition.gd`：地图入口资源，汇总内容场景、网格、镜头、玩家出生点、刷怪点、波次、固定物品和死亡规则。

### 新增或重组运行时

- `scripts/sim/sim_wave_director.gd`：纯确定性波次状态机，不持有 Node 或 Resource。
- `scripts/gameplay/map/game_map_runtime.gd`：把 `MapDefinition` 编译进 `SimWorld`，实例化内容场景并限定静态阻挡扫描范围。
- `scripts/gameplay/gameplay_arena.gd`：由现有 `demo_arena.gd` 迁移而来的通用竞技场控制器。
- `scenes/gameplay/GameplayArena.tscn`：由现有 `DemoArena.tscn` 抽出的通用玩法宿主。
- `scenes/maps/demo/DemoMapContent.tscn`：现有 Demo 的地面、边界、道具、灯光、装饰和场景爆炸桶。
- `scenes/maps/demo/DemoMap.tscn`：继承 `GameplayArena.tscn`，只绑定 Demo `MapDefinition`。
- `resources/maps/demo/demo_map.tres`：Demo 地图全部玩法数据。
- `resources/zombies/normal_zombie.tres`：当前普通僵尸类型。

### 聚焦验证

- `tools/validation/validate_map_definitions.gd`
- `tools/validation/validate_sim_zombie_types.gd`
- `tools/validation/validate_zombie_renderer_types.gd`
- `tools/validation/validate_sim_wave_director.gd`
- `tools/validation/validate_sim_death_events.gd`
- `tools/validation/validate_sim_pickup_respawn.gd`
- `tools/validation/validate_demo_map_data_driven.gd`

---

### Task 1: 建立地图 Resource 数据模型与静态校验

**Files:**
- Create: `scripts/gameplay/map/zombie_definition.gd`
- Create: `scripts/gameplay/map/map_spawn_point_definition.gd`
- Create: `scripts/gameplay/map/wave_zombie_entry_definition.gd`
- Create: `scripts/gameplay/map/map_wave_definition.gd`
- Create: `scripts/gameplay/map/death_event_definition.gd`
- Create: `scripts/gameplay/map/death_event_group_definition.gd`
- Create: `scripts/gameplay/map/map_zombie_death_rule_definition.gd`
- Create: `scripts/gameplay/map/fixed_item_spawn_definition.gd`
- Create: `scripts/gameplay/map/map_definition.gd`
- Create: `resources/zombies/normal_zombie.tres`
- Create: `tools/validation/validate_map_definitions.gd`

**Interfaces:**
- Consumes: 现有 `PickupDefinition`、`ZombieDifficultyProfile`、`PackedScene` 和 `Rect2`。
- Produces: `ZombieDefinition`、`MapDefinition` 及其嵌套资源类型；后续任务只读取这些公开字段，不读取编辑器节点。

- [ ] **Step 1: 写入会失败的数据模型验证**

创建 `tools/validation/validate_map_definitions.gd`，至少构造以下非法与合法样例：

```gdscript
extends SceneTree

const MapDefinitionScript = preload("res://scripts/gameplay/map/map_definition.gd")
const ZombieDefinitionScript = preload("res://scripts/gameplay/map/zombie_definition.gd")
const DeathEventDefinitionScript = preload("res://scripts/gameplay/map/death_event_definition.gd")

func _init() -> void:
	var failures: Array[String] = []
	var zombie = ZombieDefinitionScript.new()
	zombie.type_id = &"normal"
	zombie.max_health = 50
	zombie.move_speed_scale_per_10000 = 10000
	var definition = MapDefinitionScript.new()
	definition.map_id = &"demo"
	definition.grid_cell_size = 1.0
	definition.grid_width = 49
	definition.grid_height = 39
	definition.player_spawn_positions = [Vector3.ZERO]
	_expect(definition.validate_configuration().has("content_scene is required"),
		"missing content scene must be rejected", failures)
	var enhancement = DeathEventDefinitionScript.new()
	enhancement.event_type = DeathEventDefinitionScript.EventType.ENHANCEMENT
	_expect(enhancement.validate_configuration().has("enhancement events are not supported"),
		"reserved enhancement events must fail validation", failures)
	_finish(failures)
```

`_expect()` 与 `_finish()` 采用仓库其他 `validate_*.gd` 的退出码模式：失败时 `quit(1)`，全部通过时打印 `validate_map_definitions: PASS` 并 `quit(0)`。

- [ ] **Step 2: 运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_map_definitions.gd
```

Expected: 退出码 `1`，错误指向缺少 `map_definition.gd` 或相关 `class_name`。

- [ ] **Step 3: 创建精简且类型明确的 Resource 类**

实现以下公开字段与校验接口。每个脚本只声明一个 `class_name`，使用 tab 缩进，并让 `validate_configuration()` 返回 `PackedStringArray`：

```gdscript
# zombie_definition.gd
extends Resource
class_name ZombieDefinition

@export var type_id: StringName
@export var display_name := "僵尸"
@export var view_scene: PackedScene
@export_range(1, 100000, 1) var max_health := 50
@export_range(1, 100000, 1) var move_speed_scale_per_10000 := 10000
```

```gdscript
# map_spawn_point_definition.gd
extends Resource
class_name MapSpawnPointDefinition

@export var spawn_id: StringName
@export var position_xz := Vector2.ZERO
@export_range(0.0, 8.0, 0.05) var spawn_radius := 1.75
@export_range(0.0, 4.0, 0.05) var minimum_spacing := 1.1
```

```gdscript
# wave_zombie_entry_definition.gd
extends Resource
class_name WaveZombieEntryDefinition

@export var zombie: ZombieDefinition
@export_range(1, 10000, 1) var count := 1
```

```gdscript
# map_wave_definition.gd
extends Resource
class_name MapWaveDefinition

@export_range(0, 1000000, 1) var spawn_interval_ticks := 0
@export var zombie_entries: Array[WaveZombieEntryDefinition] = []
```

```gdscript
# death_event_definition.gd
extends Resource
class_name DeathEventDefinition

enum EventType { DROP_ITEM, ENHANCEMENT }

@export var event_type := EventType.DROP_ITEM
@export_range(1, 1000000, 1) var weight := 1
@export var pickup: PickupDefinition
@export_range(1, 9999, 1) var amount := 1
@export var enhancement_id: StringName
```

```gdscript
# death_event_group_definition.gd
extends Resource
class_name DeathEventGroupDefinition

@export var group_id: StringName
@export_range(0, 10000, 1) var trigger_chance_per_10000 := 0
@export var events: Array[DeathEventDefinition] = []
```

```gdscript
# map_zombie_death_rule_definition.gd
extends Resource
class_name MapZombieDeathRuleDefinition

@export var zombie: ZombieDefinition
@export var groups: Array[DeathEventGroupDefinition] = []
```

```gdscript
# fixed_item_spawn_definition.gd
extends Resource
class_name FixedItemSpawnDefinition

@export var spawn_id: StringName
@export var position_xz := Vector2.ZERO
@export var pickup: PickupDefinition
@export_range(1, 9999, 1) var amount := 1
@export_range(0, 1000000, 1) var respawn_delay_ticks := 60
```

`MapDefinition` 使用以下稳定字段：

```gdscript
extends Resource
class_name MapDefinition

enum EndMode { COMPLETE, LOOP }

@export var map_id: StringName
@export var display_name := "地图"
@export var content_scene: PackedScene
@export var end_mode := EndMode.COMPLETE
@export var grid_origin := Vector2.ZERO
@export_range(0.25, 4.0, 0.25) var grid_cell_size := 1.0
@export_range(1, 4096, 1) var grid_width := 1
@export_range(1, 4096, 1) var grid_height := 1
@export var camera_bounds := Rect2(Vector2(-10.0, -7.0), Vector2(20.0, 14.0))
@export_range(1, 4000, 1) var maximum_active_zombies := 300
@export_range(1.0, 200.0, 0.5) var zombie_perception_range := 60.0
@export_range(0, 1000000, 1) var inter_wave_delay_ticks := 30
@export var player_spawn_positions: Array[Vector3] = []
@export var spawn_points: Array[MapSpawnPointDefinition] = []
@export var waves: Array[MapWaveDefinition] = []
@export var fixed_item_spawns: Array[FixedItemSpawnDefinition] = []
@export var zombie_death_rules: Array[MapZombieDeathRuleDefinition] = []
```

校验必须明确检查：空稳定 ID、重复 ID、缺少场景或资源、网格尺寸、出生点越界、空波次、重复僵尸死亡规则、概率范围、空事件组、总权重溢出、非正数量，以及 `ENHANCEMENT` 尚未支持。固定物品和死亡事件引用的 `PickupDefinition.resource_path` 必须非空，第一版不接受嵌入式 Pickup Resource，因为 reward profile 的稳定排序使用资源路径。

- [ ] **Step 4: 创建当前普通僵尸资源**

创建 `resources/zombies/normal_zombie.tres`，绑定现有 `res://scenes/targets/ZombieTarget.tscn`：

```ini
[gd_resource type="Resource" script_class="ZombieDefinition" load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/map/zombie_definition.gd" id="1_definition"]
[ext_resource type="PackedScene" path="res://scenes/targets/ZombieTarget.tscn" id="2_zombie_target"]

[resource]
script = ExtResource("1_definition")
type_id = &"normal"
display_name = "普通僵尸"
view_scene = ExtResource("2_zombie_target")
max_health = 50
move_speed_scale_per_10000 = 10000
```

- [ ] **Step 5: 运行数据模型验证并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_map_definitions.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两条命令退出码均为 `0`；Godot 生成新增脚本的 `.uid`，且没有 Resource 类型推断错误。

- [ ] **Step 6: 提交本任务**

```bash
git add scripts/gameplay/map resources/zombies tools/validation/validate_map_definitions.gd tools/validation/validate_map_definitions.gd.uid
git commit -m "feat: add map definition resources"
```

---

### Task 2: 让 SimWorld 支持稳定僵尸类型档案

**Files:**
- Modify: `scripts/sim/sim_world.gd:91-115, 469-526, 1153-1225`
- Modify: `scripts/sim/sim_hasher.gd:48-92`
- Create: `tools/validation/validate_sim_zombie_types.gd`

**Interfaces:**
- Consumes: Task 1 的 `ZombieDefinition` 仅由装配层读取；`SimWorld` 只接收整数档案下标和数值字段。
- Produces: `configure_zombie_profile(profile_index: int, max_health: int, move_speed: float) -> void`、`spawn_zombie(position_xz: Vector2, facing_yaw: float, profile_index: int) -> int`、`get_zombie_profile_index(index: int) -> int`。

- [ ] **Step 1: 编写两种僵尸档案的失败验证**

创建 `validate_sim_zombie_types.gd`，配置普通与精英两个档案，生成后断言类型、生命和速度互不串用，并在击杀压缩后保持数组对齐：

```gdscript
world.configure_zombie_profile(0, 50, 1.3)
world.configure_zombie_profile(1, 150, 1.8)
var normal_id := world.spawn_zombie(Vector2.ZERO, 0.0, 0)
var elite_id := world.spawn_zombie(Vector2(2.0, 0.0), 0.0, 1)
_expect(world.get_zombie_profile_index(0) == 0, "normal type index", failures)
_expect(world.get_zombie_profile_index(1) == 1, "elite type index", failures)
_expect(world.get_zombie_max_health(0) == 5000, "normal health scale", failures)
_expect(world.get_zombie_max_health(1) == 15000, "elite health scale", failures)
var normal_index := world.index_of_zombie(normal_id)
world.apply_zombie_damage(
	normal_index,
	99999,
	Vector2.ZERO,
	0.0,
	Vector2.RIGHT,
	&"body"
)
world.step_tick()
_expect(world.index_of_zombie(elite_id) == 0, "compaction must retain elite", failures)
_expect(world.get_zombie_profile_index(0) == 1, "type array must compact with entity", failures)
```

- [ ] **Step 2: 运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_zombie_types.gd
```

Expected: 退出码 `1`，缺少 `configure_zombie_profile()` 或旧 `spawn_zombie()` 签名不匹配。

- [ ] **Step 3: 在 SimWorld 增加类型档案与逐实体类型数组**

新增：

```gdscript
var zombie_profiles: Array[Dictionary] = []
var zombie_profile_index := PackedInt32Array()

func configure_zombie_profile(
	profile_index: int,
	max_health: int,
	move_speed: float
) -> void:
	while zombie_profiles.size() <= profile_index:
		zombie_profiles.append({})
	zombie_profiles[profile_index] = {
		"max_health": maxi(max_health, 1),
		"move_speed": maxf(move_speed, 0.0),
	}
```

`spawn_zombie()` 改为读取档案，向 `zombie_profile_index` 追加下标，同时让 `zombie_max_health`、`zombie_health` 和 `zombie_move_speed` 来自档案。`reset()` 必须清空逐实体数组但保留或明确重建档案；选择“`reset()` 清空档案，装配层每局重新配置”，避免上一地图配置泄漏到下一地图。

在 `_compact_dead()` 中创建 `new_profile_index` 并与其他逐实体数组相同顺序压缩。所有直接调用旧签名的验证与装配代码必须改为先配置档案再传 `profile_index`。

- [ ] **Step 4: 把僵尸类型纳入帧哈希**

在 `SimHasher.hash_world()` 的僵尸字段中增加：

```gdscript
hasher.mix_bytes(world.zombie_profile_index.to_byte_array())
```

类型数组必须位于 `zombie_id` 与其他逐实体数组附近，便于审查哈希覆盖。

- [ ] **Step 5: 运行类型、确定性和模拟数学验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_zombie_types.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_determinism.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_math.gd
```

Expected: 全部退出码为 `0`，相同输入的两次场景哈希完全一致。

- [ ] **Step 6: 提交本任务**

```bash
git add scripts/sim/sim_world.gd scripts/sim/sim_hasher.gd tools/validation/validate_sim_zombie_types.gd tools/validation/validate_sim_zombie_types.gd.uid
git commit -m "feat: add deterministic zombie profiles"
```

---

### Task 3: 让 ZombieRenderer 按僵尸类型选择表现资源

**Files:**
- Modify: `scripts/render/zombie_renderer.gd:1-230`
- Create: `tools/validation/validate_zombie_renderer_types.gd`

**Interfaces:**
- Consumes: `SimWorld.get_zombie_profile_index(index: int) -> int` 与 `Array[PackedScene]`。
- Produces: `configure_zombie_scenes(value: Array[PackedScene]) -> void`；近景池与远景 MultiMesh 都按 profile index 隔离。

- [ ] **Step 1: 编写类型渲染失败验证**

验证使用同一 `ZombieTarget.tscn` 配置两个 profile，以避免为了测试新增美术资源；断言两个 profile 分别建立远景桶，且绑定后的近景 View 记录正确 profile：

```gdscript
renderer.configure_zombie_scenes([ZOMBIE_SCENE, ZOMBIE_SCENE])
renderer.setup(anchor)
world.configure_zombie_profile(0, 50, 1.3)
world.configure_zombie_profile(1, 100, 1.6)
world.spawn_zombie(Vector2.ZERO, 0.0, 0)
world.spawn_zombie(Vector2.ONE, 0.0, 1)
renderer.sync_lod(world)
_expect(renderer.get_type_bucket_count() == 2, "two render buckets", failures)
_expect(renderer.get_near_view_profile(world.get_zombie_id_array()[1]) == 1,
	"elite view must use elite bucket", failures)
```

- [ ] **Step 2: 运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_zombie_renderer_types.gd
```

Expected: 退出码 `1`，缺少 `configure_zombie_scenes()`。

- [ ] **Step 3: 把单一 zombie_scene 改为按 profile 的桶**

保留全局 `NEAR_LOD_COUNT = 48`，不要变成“每种类型 48”。新增：

```gdscript
var zombie_scenes: Array[PackedScene] = []
var type_buckets: Array[Dictionary] = []
var near_view_profile: Dictionary = {}
var total_near_view_count := 0
```

每个 bucket 保存：

```gdscript
{
	"scene": scene,
	"multi_mesh": multi_mesh,
	"multi_mesh_instance": instance,
	"free_views": [],
	"far_slot": 0,
}
```

`_acquire_view(profile_index)` 只从对应 bucket 取 View；没有空闲 View 且全局 View 数小于 `NEAR_LOD_COUNT` 时才实例化该类型场景。`_release_view()` 根据 `near_view_profile[zombie_id]` 放回正确 bucket。远景渲染先把每个 bucket 的 `far_slot` 清零，再按实体 profile 写入对应 MultiMesh，最后分别更新 `visible_instance_count`。

保留旧 `@export var zombie_scene` 到本任务完成前会形成双来源；最终删除它，并由 `GameplayArena` 在 Task 7 调用 `configure_zombie_scenes()`。

- [ ] **Step 4: 运行渲染类型验证与无头导入**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_zombie_renderer_types.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 退出码为 `0`；两种 profile 使用两个独立 MultiMesh bucket，总近景实例数不超过 48。

- [ ] **Step 5: 提交本任务**

```bash
git add scripts/render/zombie_renderer.gd tools/validation/validate_zombie_renderer_types.gd tools/validation/validate_zombie_renderer_types.gd.uid
git commit -m "feat: render zombies by profile"
```

---

### Task 4: 实现 tick 驱动的波次状态机与精确组合刷怪

**Files:**
- Create: `scripts/sim/sim_wave_director.gd`
- Modify: `scripts/sim/sim_world.gd:140-160, 507-550, 800-870`
- Modify: `scripts/sim/sim_hasher.gd:48-92`
- Create: `tools/validation/validate_sim_wave_director.gd`

**Interfaces:**
- Consumes: 由装配层编译的 `Array[Dictionary]` 波次、稳定排序的 `Array[Dictionary]` 刷怪点和最大存活数。
- Produces: `SimWorld.configure_wave_schedule(waves: Array[Dictionary], spawn_points: Array[Dictionary], end_mode: int, inter_wave_delay_ticks: int, maximum_active_zombies: int) -> void`、`SimWorld.start_wave_schedule() -> void`、`SimWorld.request_advance_wave() -> void`、`SimWorld.can_advance_wave() -> bool`、`tick_wave_events: Array[Dictionary]`。

- [ ] **Step 1: 编写波次状态机失败验证**

覆盖以下稳定合同：

```gdscript
var waves := [
	{"spawn_interval_ticks": 0, "entries": [
		{"profile_index": 0, "count": 2},
		{"profile_index": 1, "count": 1},
	]},
]
var points := [
	{"spawn_id": &"east", "position": Vector2(10, 0), "radius": 0.0, "spacing": 0.0},
	{"spawn_id": &"west", "position": Vector2(-10, 0), "radius": 0.0, "spacing": 0.0},
]
world.configure_wave_schedule(waves, points, SimWaveDirector.EndMode.LOOP, 2, 300)
world.start_wave_schedule()
world.step_tick()
_expect(world.get_zombie_count() == 3, "interval zero must spawn full wave", failures)
_expect(world.get_zombie_profile_index(0) == 0, "entry order normal 1", failures)
_expect(world.get_zombie_profile_index(1) == 0, "entry order normal 2", failures)
_expect(world.get_zombie_profile_index(2) == 1, "entry order elite", failures)
_expect(world.get_zombie_position(0) == Vector2(10, 0), "first sorted point", failures)
_expect(world.get_zombie_position(1) == Vector2(-10, 0), "round robin point", failures)
```

另加用例：`spawn_interval_ticks = 3` 时生成 tick 间隔恰为 3；`COMPLETE` 最后一波清空后只发一次 `map_completed`；`LOOP` 等待 `inter_wave_delay_ticks` 后回到第 1 波且数值不增强；达到 `maximum_active_zombies` 时保留未生成数量，空出名额后继续。

- [ ] **Step 2: 运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_wave_director.gd
```

Expected: 退出码 `1`，缺少 `sim_wave_director.gd` 或 `configure_wave_schedule()`。

- [ ] **Step 3: 实现纯数据 SimWaveDirector**

`SimWaveDirector` 不得持有 `Node`、`Resource`、`Timer` 或墙钟时间。公开状态：

```gdscript
enum EndMode { COMPLETE, LOOP }
enum State { IDLE, SPAWNING, WAITING_CLEAR, INTERMISSION, COMPLETE }

var state := State.IDLE
var wave_index := 0
var entry_index := 0
var remaining_in_entry := 0
var spawn_point_cursor := 0
var next_spawn_tick := 0
var intermission_end_tick := 0
var completion_emitted := false
```

核心接口：

```gdscript
func configure(
	value_waves: Array[Dictionary],
	value_spawn_points: Array[Dictionary],
	value_end_mode: int,
	value_inter_wave_delay_ticks: int,
	value_maximum_active_zombies: int
) -> void

func start(current_tick: int) -> void
func request_advance(current_tick: int) -> void
func can_advance() -> bool
func step_tick(current_tick: int, active_count: int, pending_count: int) -> Array[Dictionary]
func get_state_words() -> PackedInt32Array
```

`step_tick()` 返回本 tick 的生成命令和波次事件。生成命令固定包含：

```gdscript
{
	"kind": &"spawn_zombie",
	"profile_index": profile_index,
	"center": spawn_point["position"],
	"radius": spawn_point["radius"],
	"minimum_spacing": spawn_point["spacing"],
}
```

刷怪点必须在 `configure()` 内按 `String(spawn_id)` 升序复制排序。条目不排序，保留资源顺序。

- [ ] **Step 4: 将波次状态机接入 SimWorld tick 顺序**

在 `step_tick()` 中使用固定顺序：

```text
清 tick 事件
→ 推进波次状态机并排入本 tick 生成命令
→ 应用生成命令
→ 补给领取/重生
→ 油桶与玩家事件
→ 流场、僵尸移动、碰撞、攻击
→ 压缩死亡实体
```

删除旧 `pending_spawn_waves`、`pending_spawn_capacity`、`queue_spawn_wave()` 与随机每中心数量逻辑，改成精确 `pending_spawn_requests`。位置采样仍调用 `_sample_spawn_position()`，随机流仍是 `ZOMBIE_SPAWN`。

`_sample_spawn_position()` 的候选点除了检查僵尸间距，还必须检查 `grid.is_blocked(grid.world_to_cell(candidate)) == false`；网格外天然视为阻挡。16 次采样都失败时只允许回退到已由地图校验确认可通行的刷怪点中心。

`request_advance_wave()` 只允许跳过 `INTERMISSION`；在 `SPAWNING` 或 `WAITING_CLEAR` 中不并发叠加下一波，避免破坏作者定义的波次边界。
`can_advance_wave()` 只在 `INTERMISSION` 返回 `true`，供 HUD 按钮和输入提示同步状态。

- [ ] **Step 5: 把波次状态纳入 SimHasher**

在 `hash_world()` 中遍历：

```gdscript
for state_word in world.get_wave_state_words():
	hasher.mix_uint32(state_word)
```

`get_wave_state_words()` 必须包含 state、wave index、entry index、remaining、spawn cursor、next spawn tick、intermission end tick 和 completion flag。

- [ ] **Step 6: 运行波次、流场和确定性验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_wave_director.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_flow_field.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_determinism.gd
```

Expected: 全部退出码为 `0`，LOOP 重复后仍使用相同档案数值和精确数量。

- [ ] **Step 7: 提交本任务**

```bash
git add scripts/sim/sim_wave_director.gd scripts/sim/sim_wave_director.gd.uid scripts/sim/sim_world.gd scripts/sim/sim_hasher.gd tools/validation/validate_sim_wave_director.gd tools/validation/validate_sim_wave_director.gd.uid
git commit -m "feat: add deterministic wave schedule"
```

---

### Task 5: 在模拟层解析按地图配置的死亡事件组

**Files:**
- Modify: `scripts/sim/sim_world.gd:140-160, 632-680, 820-840`
- Create: `tools/validation/validate_sim_death_events.gd`

**Interfaces:**
- Consumes: 每个 zombie profile 对应的已编译事件组；概率为 `0..10000` 整数，事件权重为正整数。
- Produces: `configure_zombie_death_groups(profile_index: int, groups: Array[Dictionary]) -> void` 与 `tick_death_rule_events: Array[Dictionary]`。

- [ ] **Step 1: 编写独立事件组与互斥选择的失败验证**

构造两个事件组：常规掉落组 `10000` 必触发，内含两个权重事件；稀有组 `0` 永不触发。使用固定 seed 重跑两次并断言事件序列完全一致：

```gdscript
world.configure_zombie_death_groups(0, [
	{
		"group_id": &"common",
		"trigger_chance_per_10000": 10000,
		"events": [
			{"event_type": 0, "weight": 3, "reward_profile_index": 0, "amount": 30},
			{"event_type": 0, "weight": 1, "reward_profile_index": 1, "amount": 1},
		],
	},
	{
		"group_id": &"rare",
		"trigger_chance_per_10000": 0,
		"events": [
			{"event_type": 0, "weight": 1, "reward_profile_index": 2, "amount": 1},
		],
	},
])
```

每只僵尸死亡时，`common` 只允许产生一条事件，`rare` 不产生事件。再增加两个 `10000` 的事件组，断言同一只僵尸可以从不同组各产生一条事件。

- [ ] **Step 2: 运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_death_events.gd
```

Expected: 退出码 `1`，缺少 `configure_zombie_death_groups()`。

- [ ] **Step 3: 使用整数 RNG 实现死亡事件选择**

新增按 profile 保存的配置：

```gdscript
var zombie_death_groups: Array[Array] = []
var tick_death_rule_events: Array[Dictionary] = []
```

概率判定必须是：

```gdscript
var chance_roll := rng.next_uint32(DeterministicRngScript.Stream.LOOT_DROP) % 10000
if chance_roll >= trigger_chance_per_10000:
	continue
```

组内权重选择必须先求正整数总权重，再用：

```gdscript
var choice := rng.next_uint32(DeterministicRngScript.Stream.LOOT_DROP) % total_weight
```

按资源事件顺序累计权重，首个覆盖 `choice` 的事件胜出。事件输出固定包含：

```gdscript
{
	"kind": &"drop_item",
	"zombie_id": zombie_id[index],
	"profile_index": zombie_profile_index[index],
	"group_id": group["group_id"],
	"reward_profile_index": event["reward_profile_index"],
	"amount": event["amount"],
	"position": zombie_position[index],
}
```

在 `apply_zombie_damage()` 首次把实体设置为死亡状态时立即解析，保证一次死亡只判定一次。`_clear_tick_events()` 必须清空 `tick_death_rule_events`。

- [ ] **Step 4: 明确拒绝未实现的强化事件**

装配层在 Task 7 编译 Resource 前会调用 `MapDefinition.validate_configuration()`；模拟层仍需防御性检查：`event_type != DROP_ITEM` 时 `push_error()` 并跳过，但合法 Demo 资源绝不能走到该分支。不要为强化条目创建空奖励、空事件或静默成功路径。

- [ ] **Step 5: 运行死亡事件、RNG 与确定性验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_death_events.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_deterministic_rng.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_determinism.gd
```

Expected: 全部退出码为 `0`；固定 seed 下事件类型、奖励下标、数量和顺序一致。

- [ ] **Step 6: 提交本任务**

```bash
git add scripts/sim/sim_world.gd scripts/sim/sim_hasher.gd tools/validation/validate_sim_death_events.gd tools/validation/validate_sim_death_events.gd.uid
git commit -m "feat: add deterministic zombie death events"
```

---

### Task 6: 把固定补给、掉落补给和重生生命周期迁入 SimWorld

**Files:**
- Modify: `scripts/sim/flow_field_grid.gd:1-150`
- Modify: `scripts/sim/sim_world.gd:160-180, 377-445, 800-840`
- Modify: `scripts/sim/sim_hasher.gd:48-92`
- Modify: `scripts/gameplay/pickup_definition.gd:1-30`
- Modify: `scripts/gameplay/pickup_chest.gd:1-105`
- Delete: `scripts/gameplay/pickup_spawn_point.gd`
- Delete: `scripts/gameplay/pickup_spawn_point.gd.uid`
- Delete: `scripts/gameplay/random_pickup_drop_manager.gd`
- Delete: `scripts/gameplay/random_pickup_drop_manager.gd.uid`
- Delete: `scenes/gameplay/PickupSpawnPoint.tscn`
- Delete: `scenes/gameplay/RandomPickupDropManager.tscn`
- Replace test: `tools/validation/validate_pickup_spawn_point.gd`
- Replace test: `tools/validation/validate_random_pickup_drops.gd`
- Modify: `tools/validation/validate_flow_field.gd`
- Create: `tools/validation/validate_sim_pickup_respawn.gd`

**Interfaces:**
- Consumes: Task 5 的 `tick_death_rule_events`，以及地图固定物品的 reward profile 下标与 tick 间隔。
- Produces: `spawn_chest(position_xz, reward_profile_index, amount, respawn_delay_ticks, blocker_min_xz, blocker_max_xz, claim_radius) -> int`；`tick_chest_events` 新增 `chest_spawned`、`chest_claimed`、`chest_respawned`。

- [ ] **Step 1: 编写领取同 tick 清阻挡与精确重生验证**

`validate_sim_pickup_respawn.gd` 配置玩家在箱子范围内并注册一个 `respawn_delay_ticks = 3` 的固定箱：

```gdscript
var chest_id := world.spawn_chest(
	Vector2.ZERO,
	0,
	30,
	3,
	Vector2(-0.5, -0.5),
	Vector2(0.5, 0.5),
	0.9
)
world.set_player_snapshot(0, Vector2.ZERO, true, true)
world.step_tick()
_expect(_has_event(world.tick_chest_events, &"chest_claimed"), "claim event", failures)
_expect(world.get_chest_state(0) == SimWorld.CHEST_STATE_WAITING_RESPAWN,
	"fixed chest waits for respawn", failures)
_expect(not world.get_grid().is_blocked(world.get_grid().world_to_cell(Vector2.ZERO)),
	"claim must clear blocker in the same tick", failures)
```

随后把玩家移开并推进 2 tick，断言仍未出现；第 3 个重生 tick 断言 `chest_respawned`、状态 ACTIVE、阻挡恢复。另注册 `respawn_delay_ticks = -1` 的死亡掉落箱，领取后必须进入 CONSUMED 且永不重生。

再覆盖重叠阻挡引用计数：先对同一格增加两个静态 blocker source，移除一个后该格仍必须阻挡，移除第二个后才恢复通行。该合同用于多个掉落箱、固定箱、静态场景物和放置物共享 cell 的情况。

- [ ] **Step 2: 运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_pickup_respawn.gd
```

Expected: 退出码 `1`，旧 `spawn_chest()` 签名不支持奖励和重生。

- [ ] **Step 3: 为流场静态阻挡增加引用计数**

保留 `FlowFieldGrid.set_blocked()` 与 `set_blocked_world_rect()` 的现有“直接设置基础阻挡”语义，避免破坏流场算法验证；另增运行时来源计数：

```gdscript
var base_static_blocked := PackedByteArray()
var base_entity_blocked := PackedByteArray()
var static_blocker_count := PackedInt32Array()
var entity_blocker_count := PackedInt32Array()

func add_static_blocker_world_rect(min_xz: Vector2, max_xz: Vector2) -> bool
func remove_static_blocker_world_rect(min_xz: Vector2, max_xz: Vector2) -> bool
func add_entity_blocker_world_rect(min_xz: Vector2, max_xz: Vector2) -> bool
func remove_entity_blocker_world_rect(min_xz: Vector2, max_xz: Vector2) -> bool
```

单格最终状态：

```text
static_blocked = base_static_blocked OR static_blocker_count > 0
blocked = static_blocked OR base_entity_blocked OR entity_blocker_count > 0
```

`set_blocked*()` 写 `base_static_blocked`，`set_entity_blocked*()` 写 `base_entity_blocked`，统一通过 `_refresh_cell(index)` 重算两个派生数组。移除时计数最低钳到 0，并对下溢 `push_error()`；只有最终布尔通行状态改变时才设置 `dirty = true`。`SimWorld.set_blocker_world_rect(..., true)` 调用 add，`false` 调用 remove；爆炸桶专用接口同理使用 entity count。这样保留现有 SimWorld API，又支持多个来源覆盖同一 cell。

- [ ] **Step 4: 扩展箱子模拟数组与状态**

定义：

```gdscript
const CHEST_STATE_ACTIVE := 0
const CHEST_STATE_WAITING_RESPAWN := 1
const CHEST_STATE_CONSUMED := 2

var chest_reward_profile := PackedInt32Array()
var chest_amount := PackedInt32Array()
var chest_respawn_delay_ticks := PackedInt32Array()
var chest_respawn_at_tick := PackedInt32Array()
var chest_blocker_min := PackedVector2Array()
var chest_blocker_max := PackedVector2Array()
```

注册时立即写入阻挡。领取时在同一个 `_resolve_chest_claims()` 调用内：

```text
ACTIVE → 清阻挡 → 发 chest_claimed
respawn_delay_ticks >= 0 → WAITING_RESPAWN，respawn_at = tick_index + delay
respawn_delay_ticks < 0 → CONSUMED
```

`_update_chest_respawns()` 必须在 `_resolve_chest_claims()` 之前运行；到 tick 时恢复 ACTIVE、恢复阻挡并发 `chest_respawned`。同一 tick 刚重生且玩家仍站在原地时允许再次被领取，事件顺序固定为 `chest_respawned` 后 `chest_claimed`。

- [ ] **Step 5: 在模拟 tick 内物化死亡掉落**

在玩家伤害/爆炸事件解析完成后、`_update_flow_field()` 之前消费本 tick 的 `tick_death_rule_events`：每条 `drop_item` 调用新 `spawn_chest()`，`respawn_delay_ticks = -1`，使用统一箱体半径和 blocker half extent 常量。新增 `chest_spawned` 事件，携带 id、位置、reward profile 和 amount。

这样死亡掉落出现的 tick、阻挡建立的 tick、领取和消失 tick 全部属于 `SimWorld`，不再由表现层 `RandomNumberGenerator`、`Timer` 或 `tree_exited` 决定。

- [ ] **Step 6: 让 PickupDefinition 和 PickupChest 接收数量覆盖**

修改接口：

```gdscript
func grant_to(player: PlayerController, amount_override: int = -1) -> bool:
	var grant_amount := amount if amount_override < 0 else amount_override
	if player == null or not player.is_alive() or item_id.is_empty() or grant_amount <= 0:
		return false
	match reward_mode:
		RewardMode.EQUIPMENT:
			return player.receive_equipment_pickup(item_id, grant_amount, auto_equip)
		RewardMode.AMMO:
			return player.receive_ammo_pickup(item_id, grant_amount)
	return false

func get_label_text(amount_override: int = -1) -> String:
	var label_amount := amount if amount_override < 0 else amount_override
	return "%s +%d" % [display_name, label_amount]
```

`PickupChest.configure(value: PickupDefinition, amount_override: int = -1)` 保存 `reward_amount`；`claim_by()` 调用 `definition.grant_to(player, reward_amount)`。删除节点自有的领取判定、重生 Timer 和阻挡信号依赖；`PickupChest` 继续只是一个被模拟事件创建/删除的表现节点。统一模拟几何必须与 `PickupChest.tscn` 一致：`CHEST_CLAIM_RADIUS = 1.15`，`CHEST_BLOCKER_HALF_SIZE = Vector2(0.24, 0.18)`。

- [ ] **Step 7: 删除旧表现层生成管理器并重写验证**

删除 `PickupSpawnPoint` 与 `RandomPickupDropManager` 的脚本和场景。把旧两个验证改成迁移守卫：扫描运行时代码和场景，确认不再出现 `respawn_delay_seconds`、`RandomNumberGenerator` 驱动掉落、`PickupSpawnPoint` 和 `RandomPickupDropManager`；真正的行为由 `validate_sim_pickup_respawn.gd` 覆盖。

- [ ] **Step 8: 把新箱子字段纳入 SimHasher**

在已有 chest hash 后加入 reward profile、amount、respawn delay、respawn tick、blocker min/max。状态与这些字段共同覆盖固定箱和一次性掉落的全部模拟生命周期。

- [ ] **Step 9: 运行补给、流场和确定性验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_pickup_respawn.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_pickup_spawn_point.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_random_pickup_drops.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_flow_field.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_determinism.gd
```

Expected: 全部退出码为 `0`；项目运行时代码不再存在秒级补给重生或表现层掉落 RNG。

- [ ] **Step 10: 提交本任务**

```bash
git add scripts/sim scripts/gameplay/pickup_definition.gd scripts/gameplay/pickup_chest.gd scripts/gameplay/pickup_spawn_point.gd scripts/gameplay/random_pickup_drop_manager.gd scenes/gameplay/PickupSpawnPoint.tscn scenes/gameplay/RandomPickupDropManager.tscn tools/validation
git commit -m "feat: move pickup lifecycle into simulation"
```

---

### Task 7: 抽取通用 GameplayArena 与地图运行时装配器

**Files:**
- Create: `scripts/gameplay/map/game_map_runtime.gd`
- Move: `scripts/gameplay/demo_arena.gd` → `scripts/gameplay/gameplay_arena.gd`
- Move: `scripts/gameplay/demo_arena.gd.uid` → `scripts/gameplay/gameplay_arena.gd.uid`
- Move: `scenes/gameplay/DemoArena.tscn` → `scenes/gameplay/GameplayArena.tscn`
- Modify: `scripts/gameplay/place_item_grid.gd:1-150`
- Create: `scenes/maps/demo/DemoMapContent.tscn`
- Create: `resources/maps/demo/demo_map.tres`
- Create: `scenes/maps/demo/DemoMap.tscn`
- Create: `tools/validation/validate_demo_map_data_driven.gd`

**Interfaces:**
- Consumes: Task 1 的 `MapDefinition`、Task 2–6 的模拟配置接口。
- Produces: `GameMapRuntime.load(definition: MapDefinition, world: SimWorld, content_parent: Node3D, difficulty: ZombieDifficultyProfile, seed: int) -> PackedStringArray`；通用 `GameplayArena` 只通过该接口读取地图。

- [ ] **Step 1: 编写 Demo 数据驱动迁移失败验证**

验证读取 `demo_map.tres` 并锁定当前 Demo 的迁移值：

```gdscript
_expect(definition.map_id == &"demo", "demo map id", failures)
_expect(definition.end_mode == MapDefinition.EndMode.LOOP, "demo loops", failures)
_expect(definition.grid_origin == Vector2(-24.5, -19.5), "grid origin", failures)
_expect(definition.grid_width == 49 and definition.grid_height == 39, "grid size", failures)
_expect(definition.maximum_active_zombies == 300, "active cap", failures)
_expect(is_equal_approx(definition.zombie_perception_range, 60.0), "perception range", failures)
_expect(definition.inter_wave_delay_ticks == 30, "inter-wave ticks", failures)
_expect(definition.waves.size() == 1, "one authored demo wave", failures)
_expect(definition.waves[0].zombie_entries[0].count == 60, "normal x60", failures)
_expect(definition.fixed_item_spawns.size() == 3, "three fixed pickups", failures)
```

再扫描 `gameplay_arena.gd`，禁止保留 `SPAWN_POINT_NAMES`、`minimum_zombies_per_corner`、`maximum_zombies_per_corner`、`ARENA_SIM_GRID_ORIGIN`、`RandomPickupDropManager` 和硬编码 `World/Props/PickupSpawners`。

- [ ] **Step 2: 运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_demo_map_data_driven.gd
```

Expected: 退出码 `1`，Demo 地图资源与通用竞技场尚不存在。

- [ ] **Step 3: 实现 GameMapRuntime 装配边界**

`GameMapRuntime` 负责：

1. 调用 `definition.validate_configuration()`，有错误时原样返回，不启动战斗。
2. 实例化 `definition.content_scene` 到 `content_parent`。
3. 收集地图引用到的 `ZombieDefinition`，按 `String(type_id)` 升序建立 profile index。
4. 收集死亡事件引用的 `PickupDefinition`，按 `resource_path` 升序建立 reward profile index。
5. 把波次、刷怪点和死亡事件组编译为不含 Resource 的临时 Dictionary。
6. 扫描 `content_root` 子树内的 `place_item_obstacle`，跳过 `ExplosiveBarrel`，暂存每个碰撞体的世界 AABB。
7. 用临时 `FlowFieldGrid` 应用静态 AABB，校验玩家出生点、僵尸刷怪点和固定物品位置全部位于网格内；玩家/刷怪点不得落在阻挡格，刷怪半径的包围矩形不得越出网格，两个固定物品不得占用同一个流场 cell，固定物品不得覆盖场景静态阻挡。
8. 错误列表为空后，调用 `SimWorld.configure(grid_origin, cell_size, width, height)` 与 `reset(seed)`。
9. 用 `zombie_difficulty.perception_move_speed * move_speed_scale_per_10000 / 10000.0` 配置每种僵尸速度，并配置感知范围、波次与死亡事件组。
10. 把暂存的静态 AABB 逐个写入 `SimWorld.set_blocker_world_rect()`。
11. 把固定物品按 `String(spawn_id)` 升序注册为可重生 chest。
12. 按相对 `NodePath` 字符串升序返回场景 `ExplosiveBarrel` 列表，交给竞技场使用现有 `_register_barrel()` 注册。

实现采用两阶段：先实例化内容、收集/排序/校验所有配置并构造临时 Dictionary；只有错误列表为空时才调用 `SimWorld.reset()`、写阻挡、配置档案和注册实体。失败路径释放刚实例化的内容根，不能给 `SimWorld` 留下半张地图。

公开只读结果：

```gdscript
var content_root: Node3D
var zombie_definitions: Array[ZombieDefinition] = []
var reward_definitions: Array[PickupDefinition] = []
var initial_chest_events: Array[Dictionary] = []

func reward_definition(profile_index: int) -> PickupDefinition
func player_spawn_positions() -> Array[Vector3]
func camera_bounds() -> Rect2
func scene_barrels() -> Array[ExplosiveBarrel]
```

每个固定补给注册后向 `initial_chest_events` 追加与 `chest_spawned` 相同结构的 Dictionary，供竞技场在第一个 `step_tick()` 之前创建表现节点；不要依赖 `tick_chest_events`，因为 `_clear_tick_events()` 会在首 tick 清掉装配期事件。

- [ ] **Step 4: 限制 PlaceItemGrid 的障碍扫描范围**

为 `PlaceItemGrid` 增加：

```gdscript
@export_node_path("Node") var obstacle_root_path: NodePath
```

`register_initial_obstacles()` 从 `get_node_or_null(obstacle_root_path)` 开始递归查找 `CollisionObject3D`，而不是 `get_tree().get_nodes_in_group()`。运行时放置物继续通过 `PlaceItemService.reserve_cells()` 登记，不依赖全树扫描。

- [ ] **Step 5: 将 DemoArena 脚本改为通用 GameplayArena**

移动文件后，根脚本改名不需要 `class_name`。新增：

```gdscript
@export var map_definition: MapDefinition
var map_runtime := GameMapRuntime.new()
```

`_setup_simulation()` 改为调用 `map_runtime.load()`；删除竞技场内的网格常量、固定四角名字、随机波次数量、固定拾取节点路径和随机掉落管理器。`_get_player_spawn_points()` 从 `map_runtime.player_spawn_positions()` 创建或返回 Marker；镜头边界读取 `map_runtime.camera_bounds()`。

`load()` 返回非空错误列表时，把 `"; ".join(errors)` 写入 `GameSession.last_error`，停止启动并按当前模式返回主菜单、本地大厅或联机大厅；不得带着部分注册的地图继续运行。

调整 `_ready()` 初始化顺序，不能继续先生成玩家再读取地图：

```text
检测单机/本地/联机模式与 seed
→ map_runtime.load() 实例化内容并配置 SimWorld
→ zombie_renderer.configure_zombie_scenes(map_runtime 中按 profile 排序的 view_scene)
→ zombie_renderer.setup(FollowCamera)
→ 注册场景爆炸桶和固定箱 View
→ 按地图玩家出生点生成玩家
→ 连接团队状态、输入、HUD 和放置服务
→ sim_world.start_wave_schedule()
→ 战斗预热与首 tick
```

`_enter_tree()` 与 `NOTIFICATION_SCENE_INSTANTIATED` 阶段不得调用依赖僵尸类型或地图内容的 renderer setup；早期 `_wire_dependencies()` 只连接不依赖地图数据的 UI/输入信号，地图相关接线在 `map_runtime.load()` 成功后完成。

`_consume_sim_events()` 增加：

```gdscript
for event in sim_world.tick_wave_events:
	_on_sim_wave_event(event)
for event in sim_world.tick_chest_events:
	_on_sim_chest_event(event)
```

`_on_sim_chest_event()`：

- `chest_spawned` / `chest_respawned`：实例化 `PickupChest.tscn`，按 reward profile 与 amount 配置并写入 `chest_views`。
- `chest_claimed`：调用 View 的 `claim_by()`，若 View 不存在仍不得回写模拟层。

`_on_sim_wave_event()`：

- `wave_started` 更新 HUD 波次号。
- `map_completed` 调用 `_complete_map()`。

`request_spawn_wave()` 继续通过在线帧的 wave request bit 工作，但语义变为“跳过当前波间等待”；单机直接调用 `sim_world.request_advance_wave()`。

HUD 不再显示 `T: NEW WAVE`。目标文本只显示当前波次与存活数；`SpawnWaveButton` 文案改为“跳过等待”，并仅在 `sim_world.can_advance_wave()` 为 `true` 时可用。联机按钮仍只提交 frame request，不直接改变本机波次状态。

地图装配成功后必须调用 `sim_world.start_wave_schedule()`。遍历 `map_runtime.initial_chest_events` 创建三只固定箱 View，并对每只 View 调用 `PlaceItemGrid.register_obstacle()`；运行时 `chest_spawned` 与 `chest_respawned` 也走同一 View 创建函数，保证放置系统不会把油桶放到补给箱所在格。

View 创建顺序必须固定为：实例化 `PickupChest` → 加入 `$World/Pickups` → 写 `global_position` → `configure(definition, amount)` → `bind_sim_chest(id)` → `PlaceItemGrid.register_obstacle(view)` → 写入 `chest_views[id]`。不得在位置写入前注册阻挡。

- [ ] **Step 6: 拆分通用宿主与 Demo 内容场景**

`GameplayArena.tscn` 保留：

- `SpatialSfxPool`、`GameOverAudio`
- `World/MapContent` 挂载点
- `World/Placement/PlaceItemGrid`
- `World/Pickups`
- `World/PlacedItems`
- `World/Targets/ZombieRenderer`
- `Players`、`LocalPlayerSpawner`、`PlaceItemService`
- `GroundBloodManager`、`CombatFxPrewarmer`、`FollowCamera`
- HUD、MobileControls、游戏结束与预热节点

删除 `AutoWaveTimer` 以及 `_schedule_auto_wave_if_empty()`、`_cancel_auto_wave()`、`_on_auto_wave_timeout()`、`_tick_online_auto_wave()`；波间等待只能由 `SimWaveDirector` 的 tick 状态推进。

`DemoMapContent.tscn` 接收原场景中的：

- `WorldEnvironment`、`Sun`
- Ground 与四面 Boundaries
- Checkpoint、Incident、HazardZone、SupplyPoint、RoadDetails 等静态内容
- 场景自带 ExplosiveBarrels

删除内容场景里的：

- `SpawnPoints`
- `PlayerSpawnPoints`
- `PickupSpawners`
- `RandomPickupDrops`
- `ZombieRenderer`
- `PlaceItemGrid` 与 `PlaceItemService`

`World/PlacedItems` 是运行时放置桶的统一容器；`PlaceItemService.placed_items_path` 不再指向 Demo 特有的 `HazardZone/ExplosiveBarrels`。

- [ ] **Step 7: 创建 Demo MapDefinition**

`resources/maps/demo/demo_map.tres` 必须包含：

```text
map_id = demo
display_name = Demo 检查站
content_scene = DemoMapContent.tscn
end_mode = LOOP
grid_origin = (-24.5, -19.5)
grid_cell_size = 1.0
grid_width = 49
grid_height = 39
camera_bounds = Rect2((-10, -7), (20, 14))
maximum_active_zombies = 300
zombie_perception_range = 60.0
inter_wave_delay_ticks = 30
```

玩家位置按 P1–P4 顺序保存：

```text
(-1.2, 0, 6.2)
( 1.2, 0, 6.2)
(-1.2, 0, 4.2)
( 1.2, 0, 4.2)
```

刷怪点稳定 ID 与位置：

```text
01_north_west  (-19, -14)
02_north_east  ( 19, -14)
03_south_west  (-19,  14)
04_south_east  ( 19,  14)
```

排序后的实际轮询顺序必须是 NW→NE→SW→SE；本计划采用带数字前缀的 ID，禁止依赖自然语言排序偶然符合预期。

固定物品：

```text
01_smg       position=(-4.5,  6.0) pickup=smg_pickup       amount=60 respawn=60
02_smg_ammo  position=( 0.0,  9.0) pickup=smg_ammo_pickup  amount=90 respawn=60
03_oil       position=( 4.5,  6.0) pickup=oil_barrel_pickup amount=30 respawn=60
```

波次：普通僵尸 `×60`、`spawn_interval_ticks = 0`。死亡事件：普通僵尸一个 `common_drop` 组，`trigger_chance_per_10000 = 2000`，三项 `DROP_ITEM` 权重均为 `1`，数量分别使用当前资源的 60、90、30。

- [ ] **Step 8: 创建 DemoMap 包装场景**

`scenes/maps/demo/DemoMap.tscn` 继承 `GameplayArena.tscn`，只覆盖：

```ini
[gd_scene load_steps=3 format=3]

[ext_resource type="PackedScene" path="res://scenes/gameplay/GameplayArena.tscn" id="1_gameplay_arena"]
[ext_resource type="Resource" path="res://resources/maps/demo/demo_map.tres" id="2_demo_map_definition"]

[node name="DemoMap" instance=ExtResource("1_gameplay_arena")]
map_definition = ExtResource("2_demo_map_definition")
```

不要复制 GameplayArena 的子节点或脚本。

- [ ] **Step 9: 运行 Demo 数据、无头导入和核心模拟验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_demo_map_data_driven.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_sim_determinism.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_online_frame_sync.gd
```

Expected: 全部退出码为 `0`；通用场景不再包含 Demo 的网格、刷怪点、固定物品和掉落硬编码。

- [ ] **Step 10: 提交本任务**

```bash
git add scripts/gameplay scripts/render/zombie_renderer.gd scenes/gameplay scenes/maps resources/maps tools/validation/validate_demo_map_data_driven.gd tools/validation/validate_demo_map_data_driven.gd.uid
git commit -m "feat: load demo arena from map data"
```

---

### Task 8: 切换所有入口、处理 COMPLETE/LOOP 收尾并完成回归

**Files:**
- Modify: `scripts/menu/main_menu.gd:5`
- Modify: `scripts/menu/local_multiplayer_lobby.gd:14`
- Modify: `scripts/menu/online_lobby.gd:15`
- Modify: `scripts/gameplay/gameplay_arena.gd`
- Modify: `scripts/net/network_input_source.gd`
- Modify: `scripts/net/room_client.gd`
- Modify: `scripts/props/explosive_barrel.gd`
- Modify: `scripts/sim/sim_world.gd`
- Modify: `scripts/sim/flow_field_grid.gd`
- Modify: `scripts/gameplay/place_item_service.gd`
- Modify: `tools/validation/validate_retired_navigation_removed.gd`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: `DemoMap.tscn` 与 `SimWorld.tick_wave_events`。
- Produces: 所有单人、本地多人和联机入口统一加载 Demo 数据地图；COMPLETE/LOOP 行为稳定。

- [ ] **Step 1: 将所有游戏入口改为 DemoMap**

三个默认路径统一改成：

```gdscript
@export_file("*.tscn") var game_scene_path := "res://scenes/maps/demo/DemoMap.tscn"
```

当前三个菜单场景没有覆盖 `game_scene_path`，因此只修改脚本默认值。运行 `rg -n "DemoArena.tscn" scripts scenes project.godot`，预期没有结果。

- [ ] **Step 2: 实现地图完成返回主菜单**

在 `GameplayArena` 增加幂等状态 `map_completion_pending`。`_complete_map()`：

```gdscript
func _complete_map() -> void:
	if map_completion_pending:
		return
	map_completion_pending = true
	for player in players:
		player.set_physics_process(false)
	if online_mode:
		NetSession.leave_room()
	GameSession.clear()
	get_tree().change_scene_to_file.call_deferred(
		"res://scenes/menu/MainMenu.tscn"
	)
```

当前 Demo 使用 LOOP，因此联机现有流程不会自动结束；上述在线分支只保证未来 COMPLETE 地图不会把房间连接遗留到主菜单。

- [ ] **Step 3: 验证 LOOP 不增强且 COMPLETE 只完成一次**

扩展 `validate_sim_wave_director.gd`：

- LOOP 运行两个完整循环，比较两轮每个 profile 的生成数量、生命和速度完全相同。
- COMPLETE 清空最后一波后连续推进 10 tick，`map_completed` 总计只出现一次。
- `request_advance_wave()` 在 SPAWNING 与 WAITING_CLEAR 不产生额外波次。

- [ ] **Step 4: 更新项目架构约定**

在 `AGENTS.md` 的 Project Structure 或 3D Runtime Navigation 附近增加简短地图运行时约定：

```text
地图玩法数据来自 MapDefinition；GameplayArena 是通用宿主，DemoMap 是默认地图包装场景。
地图阻挡只通过当前地图内容根节点内的 place_item_obstacle 烘入 SimWorld，爆炸桶除外。
波次、死亡事件和固定补给重生只按模拟 tick 推进，不得新增 Timer 或表现层 RNG。
```

`validate_retired_navigation_removed.gd` 的扫描范围继续覆盖新 `scenes/maps/` 与 `scripts/gameplay/map/`，确认数据驱动迁移没有重新引入旧导航词元。

把运行时代码和当前 `AGENTS.md` 中指向旧类名的注释统一改为 `GameplayArena` 或“地图运行时装配层”，包括 `room_client.gd`、`network_input_source.gd`、`explosive_barrel.gd`、`sim_world.gd`、`flow_field_grid.gd` 和 `place_item_service.gd`。历史设计与计划文档不改写。

- [ ] **Step 5: 运行完整聚焦验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_map_definitions.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_zombie_types.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_zombie_renderer_types.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_wave_director.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_death_events.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_pickup_respawn.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_demo_map_data_driven.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_flow_field.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_collision.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_determinism.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_online_frame_sync.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_online_reconnect_resume.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_retired_navigation_removed.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_ui_font_coverage.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
git diff --check
```

Expected: 所有命令退出码为 `0`，没有解析错误、协议常量漂移、旧导航词元或空白错误。

- [ ] **Step 6: 进行聚焦人工 Smoke Test**

由于场景拆分、LOD 和拾取表现不适合完全自动化，按以下固定步骤验证：

1. 从主菜单开始单人游戏，确认进入的仍是检查站 Demo，灯光、地面、路障、装饰、镜头范围和 HUD 与迁移前一致。
2. 第一 tick 后确认总计生成 60 只普通僵尸，四个角按稳定顺序轮询分配。
3. 清空一波，确认等待 30 tick 后重新生成相同的 60 只；第二轮没有生命、速度或数量增强。
4. 领取冲锋枪、冲锋枪弹药和油桶固定箱，确认各自在领取后 60 tick 原地重生。
5. 连续击杀至少 100 只，确认死亡掉落约按 2000/10000 触发，单个 `common_drop` 组一次最多出现一个箱，箱内容只来自三项配置。
6. 本地双人同时靠近同一箱，确认仍由最低槽位确定领取者，另一端/另一玩家不会留下重复箱。
7. 放置并引爆油桶，确认出现、引爆和移除都会正确改变僵尸绕行，且桶仍可被枪命中。
8. 建立联机房间并进行一波，确认两端波次数、掉落内容、存活数和帧哈希没有分叉；重连后能继续追帧。

- [ ] **Step 7: 最终审查与 squash**

检查：

```bash
git status --short
git log --oneline --decorate -12
git diff origin/main...HEAD --stat
rg -n "DemoArena|RandomPickupDropManager|PickupSpawnPoint|respawn_delay_seconds|NavigationAgent3D|NavigationServer3D" scripts scenes resources
```

预期只允许历史文档出现旧名称；运行时代码、当前场景和资源不得出现。确认未跟踪的 `scripts/menu/menu_entrance.gd.uid` 仍未暂存。

在合并目标分支前把本计划产生的功能提交 squash 为一个：

```bash
plan_base=$(git merge-base origin/main HEAD)
git reset --soft "$plan_base"
git commit -m "feat: add data-driven map runtime"
git log -1 --oneline
```

该命令只在执行本计划时创建的隔离功能分支中运行；最终提交不得包含 `.godot/`、`build/` 或无关用户文件。
