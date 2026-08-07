# 帧同步 Plan 4：确定性僵尸群体 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 在 Plan 1～3 已冻结的本地确定性模拟上实现容量固定的僵尸 SoA、流场驱动的群体移动、局部分离和仅含攻击意图的行为循环，并提供 100～150 只僵尸的确定性与性能基线。

**架构：** `ZombieState` 将每只僵尸的热状态保存在预分配 SoA 数组，槽位、生成代数和由两者编码的实体 ID 都只由模拟管理。`ZombieHordeSystem` 在 `SimulationWorld.step()` 的僵尸阶段按槽位升序依次选择玩家、读取 `SimFlowFieldSet`、计算移动、以 `SimSpatialHash` 做局部分离，并向 `SimEventBuffer` 写入攻击意图；它绝不结算伤害。`ZombieDebugView` 只读取模拟状态绘制调试线，旧 `ZombieTarget`/`DemoArena` 路径保持不变。

**技术栈：** Godot 4.7.1、GDScript、30 Hz 整数 Tick、`PackedInt32Array`、Plan 1 的 `SimulationWorld`/确定性回放 harness、Plan 2 的地图格/流场/空间哈希、Plan 3 的 `SimPlayerState`。

## 全局约束

- 本计划的前置门槛是 Plan 1、Plan 2、Plan 3 的 Headless、双实例 Hash 和人工验收已通过；缺少任一门槛时不得把本计划接入默认 DemoArena。
- `SimulationWorld.initialize(session: LocalSimulationSession, map_grid: SimMapGrid) -> Error` 与 `SimulationWorld.step(tick: int, frame: LocalFrameCommandSet) -> Error` 保持 Plan 1 的签名，`step()` 不接收 delta。
- 模拟只使用 XZ 平面整数；1 个 Godot 世界单位等于 1024 模拟单位；中间乘法使用 GDScript `int` 的 int64 范围。
- 热路径只使用预分配 `PackedInt32Array` 或定长数组；僵尸默认容量为 256，压测实例可配置为 512，容量耗尽不得扩容。
- 所有僵尸遍历、邻居遍历、目标 Tie-break、事件写入和攻击名额分配按稳定实体 ID（等价槽位升序）执行；不得依赖 `Dictionary` 的遍历顺序。
- 僵尸移动、攻击判定与路径读取不得调用 `CharacterBody3D`、Godot Physics 查询、`NavigationAgent3D`、`NavigationServer3D`、`sin`、`cos`、`atan2`、`sqrt` 或浮点 `Vector` 运算。
- 流场缺失、过期或当前位置不可达时，僵尸速度必须归零或执行已量化的游荡逻辑；不得向玩家位置作直线追击降级。
- 每名存活玩家每 Tick 最多获得 16 个僵尸攻击意图；本计划只写意图和冷却，Plan 5 才排序、伤害、死亡与表现事件。
- 保留 `scripts/combat/zombie_target.gd`、`scenes/targets/ZombieTarget.tscn` 和当前 `DemoArena` 的旧玩法逻辑，不修改它们。
- 验证脚本置于 `tools/validation/`；长期双实例回放扩展 `scripts/simulation/testing/determinism_harness.gd`；不引入 Godot 物理驱动的自动化验收。
- 完成所有任务和最终评审后只保留一个 squash 提交：`feat(simulation): add deterministic zombie horde`。

---

## 文件结构与稳定接口

| 路径 | 职责 |
| --- | --- |
| `scripts/simulation/zombies/zombie_sim_config.gd` | 只含整数的僵尸数值配置、上界校验和默认 256/压测 512 容量档。 |
| `scripts/simulation/zombies/zombie_state.gd` | 槽位分配、generation、稳定实体 ID 与僵尸热 SoA。 |
| `scripts/simulation/zombies/zombie_horde_system.gd` | 目标选择、游荡、流场追击、攻击意图、空间哈希和局部分离。 |
| `scripts/simulation/simulation_world.gd` | 持有 `ZombieState`/`ZombieHordeSystem`，在固定系统顺序的僵尸阶段调用它们。 |
| `scripts/simulation/sim_event_buffer.gd` | 增加定长僵尸攻击意图缓冲；Plan 5 通过其只读索引 API 消费。 |
| `scripts/simulation/testing/determinism_harness.gd` | 以同一录像运行直接命令与编解码命令的双世界，并报告首个状态差异。 |
| `scripts/simulation/view/zombie_debug_view.gd` | 仅从 `ZombieState` 读取位置、朝向、目标和状态，生成调试线。 |
| `scenes/simulation/ZombieDebugView.tscn` | 隔离的旁路调试视图入口，不引用 `ZombieTarget.tscn`。 |
| `tools/validation/validate_frame_sync_zombie_state.gd` | 验证容量、generation、稳定 ID 和容量耗尽。 |
| `tools/validation/validate_frame_sync_zombie_horde.gd` | 验证目标、流场、游荡、攻击名额、分离和无路径行为。 |
| `tools/validation/validate_frame_sync_zombie_horde_replay.gd` | 验证 150 只僵尸的 10,000/100,000 Tick 双实例回放。 |
| `tools/validation/validate_frame_sync_zombie_horde_benchmark.gd` | 输出 100、150、256、512 档的 P50/P95/P99 模拟 Tick 报告。 |

### 供后续计划消费的接口

Plan 4 完成后，Plan 5 只能通过下面的接口读取僵尸攻击候选；它不得以旧 `ZombieTarget` 或 Godot 节点查询模拟目标：

```gdscript
# scripts/simulation/zombies/zombie_state.gd
const INVALID_ENTITY_ID := -1
const ENTITY_ID_SLOT_BITS := 10

var alive: PackedInt32Array
var generation: PackedInt32Array
var pos_x: PackedInt32Array
var pos_z: PackedInt32Array
var velocity_x: PackedInt32Array
var velocity_z: PackedInt32Array
var heading: PackedInt32Array
var health: PackedInt32Array
var state: PackedInt32Array
var target_id: PackedInt32Array
var cooldown_tick: PackedInt32Array
var rng_state: PackedInt32Array

func is_alive(slot: int) -> bool: pass
func entity_id_for_slot(slot: int) -> int: pass
func slot_for_entity_id(entity_id: int) -> int: pass

# scripts/simulation/sim_event_buffer.gd
func append_zombie_attack_intent(source_entity_id: int, target_entity_id: int) -> void: pass
func zombie_attack_intent_count() -> int: pass
func zombie_attack_intent_source_id(index: int) -> int: pass
func zombie_attack_intent_target_id(index: int) -> int: pass
```

`ZombieHordeSystem.step()` 的唯一写入外部副作用是以上攻击意图 API；成功写入时同步把该槽位的 `cooldown_tick` 推进到 `tick + attack_cooldown_ticks`。Plan 5 按意图索引升序读取，在自己的伤害阶段结算生命、死亡和表现事件。

### Task 1：建立整数配置、固定容量 SoA 与稳定实体 ID

**文件：**

- 创建：`scripts/simulation/zombies/zombie_sim_config.gd`
- 创建：`scripts/simulation/zombies/zombie_state.gd`
- 创建：`tools/validation/validate_frame_sync_zombie_state.gd`

**接口：**

- 消费：Plan 1 的 `FixedMath.floor_div(value: int, divisor: int) -> int`、Park–Miller 初始随机种子规则与规范状态编码约定。
- 产出：`ZombieSimConfig.default_config() -> ZombieSimConfig`、`ZombieSimConfig.benchmark_config() -> ZombieSimConfig`、`ZombieSimConfig.validate() -> Error`。
- 产出：`ZombieState.new(capacity: int)`、`spawn(spawn_x: int, spawn_z: int, initial_health: int, initial_rng_state: int) -> int`、`despawn(entity_id: int) -> bool`、本节列出的 SoA 字段和稳定 ID 查询 API。

- [ ] **步骤 1：先写失败的容量、generation 与 ID 验证**

创建 `tools/validation/validate_frame_sync_zombie_state.gd`，在尚未提供类型时使加载失败，并固定首个槽位复用规则：

```gdscript
extends SceneTree

const ZombieSimConfig = preload("res://scripts/simulation/zombies/zombie_sim_config.gd")
const ZombieState = preload("res://scripts/simulation/zombies/zombie_state.gd")

func _init() -> void:
	var config := ZombieSimConfig.default_config()
	_assert(config.capacity == 256, "默认容量必须是 256")
	_assert(ZombieSimConfig.benchmark_config().capacity == 512, "压测容量必须是 512")
	var zombies := ZombieState.new(2)
	var first_id := zombies.spawn(1024, -2048, 50, 17)
	_assert(first_id == (1 << 10), "slot 0 首次生成必须使用 generation 1")
	_assert(zombies.despawn(first_id), "首次实体必须可销毁")
	var reused_id := zombies.spawn(0, 0, 50, 19)
	_assert(reused_id == (2 << 10), "复用 slot 0 必须递增 generation")
	_assert(reused_id != first_id, "复用后实体 ID 不得碰撞")
	var second_id := zombies.spawn(0, 0, 50, 23)
	_assert(second_id == ((1 << 10) | 1), "slot 1 必须保持自己的 generation")
	_assert(zombies.spawn(0, 0, 50, 29) == ZombieState.INVALID_ENTITY_ID, "容量耗尽不得扩容")
	quit()

func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		quit(1)
```

- [ ] **步骤 2：运行验证并确认其因缺少实现失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_state.gd
```

预期：进程非零退出，错误指向缺少 `res://scripts/simulation/zombies/zombie_sim_config.gd` 或 `zombie_state.gd`；不得以跳过断言掩盖失败。

- [ ] **步骤 3：实现只含整数的配置与 SoA 分配**

创建配置，使默认与压测档不共享可变数组，所有数值均为 Tick 或模拟单位：

```gdscript
# scripts/simulation/zombies/zombie_sim_config.gd
extends RefCounted
class_name ZombieSimConfig

const DEFAULT_CAPACITY := 256
const BENCHMARK_CAPACITY := 512

var capacity := DEFAULT_CAPACITY
var health := 50
var radius_units := 410
var move_speed_per_tick := 45
var perception_range_units := 7168
var attack_range_units := 1485
var attack_cooldown_ticks := 42
var wander_radius_units := 3584
var wander_arrive_units := 256
var separation_radius_units := 820
var separation_push_per_tick := 24

static func default_config() -> ZombieSimConfig:
	return ZombieSimConfig.new()

static func benchmark_config() -> ZombieSimConfig:
	var config := ZombieSimConfig.new()
	config.capacity = BENCHMARK_CAPACITY
	return config

func validate() -> Error:
	if capacity < 1 or capacity > BENCHMARK_CAPACITY:
		return ERR_INVALID_PARAMETER
	if health < 1 or radius_units < 1 or move_speed_per_tick < 0:
		return ERR_INVALID_PARAMETER
	if attack_range_units < 1 or attack_cooldown_ticks < 1:
		return ERR_INVALID_PARAMETER
	return OK
```

创建 `ZombieState`，使用槽位 0～511，generation 从 1 起始，并将 `slot` 固定编码在实体 ID 的低 10 位：

```gdscript
# scripts/simulation/zombies/zombie_state.gd
extends RefCounted
class_name ZombieState

const INVALID_ENTITY_ID := -1
const ENTITY_ID_SLOT_BITS := 10
const ENTITY_ID_SLOT_MASK := (1 << ENTITY_ID_SLOT_BITS) - 1

var capacity: int
var alive := PackedInt32Array()
var generation := PackedInt32Array()
var pos_x := PackedInt32Array()
var pos_z := PackedInt32Array()
var velocity_x := PackedInt32Array()
var velocity_z := PackedInt32Array()
var heading := PackedInt32Array()
var health := PackedInt32Array()
var state := PackedInt32Array()
var target_id := PackedInt32Array()
var cooldown_tick := PackedInt32Array()
var rng_state := PackedInt32Array()

func _init(initial_capacity: int) -> void:
	capacity = initial_capacity
	alive.resize(capacity)
	generation.resize(capacity)
	pos_x.resize(capacity)
	pos_z.resize(capacity)
	velocity_x.resize(capacity)
	velocity_z.resize(capacity)
	heading.resize(capacity)
	health.resize(capacity)
	state.resize(capacity)
	target_id.resize(capacity)
	cooldown_tick.resize(capacity)
	rng_state.resize(capacity)
	for slot in capacity:
		target_id[slot] = INVALID_ENTITY_ID

func spawn(spawn_x: int, spawn_z: int, initial_health: int, initial_rng_state: int) -> int:
	for slot in capacity:
		if alive[slot] != 0:
			continue
		generation[slot] = max(generation[slot] + 1, 1)
		alive[slot] = 1
		pos_x[slot] = spawn_x
		pos_z[slot] = spawn_z
		health[slot] = initial_health
		rng_state[slot] = initial_rng_state
		target_id[slot] = INVALID_ENTITY_ID
		return entity_id_for_slot(slot)
	return INVALID_ENTITY_ID

func entity_id_for_slot(slot: int) -> int:
	return (generation[slot] << ENTITY_ID_SLOT_BITS) | slot
```

补齐 `despawn()`、`is_alive()` 与 `slot_for_entity_id()`：解码后必须同时比较 `alive`、slot 范围与完整 generation，过期 ID 返回 `-1`。每次 spawn/despawn 都清空速度、朝向、状态、目标和冷却，避免复用槽位残留上局状态。

- [ ] **步骤 4：运行状态验证与 Headless 导入检查**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_state.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

预期：两个命令均以 0 退出；验证涵盖默认 256、512 压测档、slot 复用 generation 递增、失效旧 ID 和容量耗尽。若 `generation << 10` 超过本局规范状态的 int32 上界，初始化必须返回 `ERR_INVALID_PARAMETER`，不能产生截断 ID。

### Task 2：实现确定性目标、游荡、流场追击与局部分离

**文件：**

- 创建：`scripts/simulation/zombies/zombie_horde_system.gd`
- 创建：`tools/validation/validate_frame_sync_zombie_horde.gd`

**接口：**

- 消费：Plan 2 的 `SimMapGrid.move_circle_x_then_z(x: int, z: int, radius: int, delta_x: int, delta_z: int) -> Vector2i`、`SimFlowFieldSet.field_for_slot(slot: int)` 和 `SimSpatialHash`；该流场对象必须提供 `is_reachable(x: int, z: int) -> bool` 与 `next_step(x: int, z: int) -> Vector2i`，返回的步长为整数世界方向。
- 消费：Plan 3 的 `SimPlayerState.is_alive(slot: int) -> bool`、`entity_id_for_slot(slot: int) -> int`、`pos_x[slot]`、`pos_z[slot]`，玩家槽位恒为 0～3。
- 产出：`ZombieHordeSystem.new(config: ZombieSimConfig, zombies: ZombieState)`、`spawn(spawn_x: int, spawn_z: int, rng_seed: int) -> int`、`step(tick: int, players: SimPlayerState, map_grid: SimMapGrid, flow_fields: SimFlowFieldSet, spatial_hash: SimSpatialHash, events: SimEventBuffer) -> void`。

- [ ] **步骤 1：写失败的行为矩阵验证**

在 `validate_frame_sync_zombie_horde.gd` 构造可控的 2×2 玩家、阻挡格和流场夹具，先固定以下断言：

```gdscript
var zombie_id := horde.spawn(0, 0, 17)
horde.step(1, players, map_grid, fields, spatial_hash, events)
_assert(zombies.target_id[0] == players.entity_id_for_slot(0), "距离相同必须选较小玩家实体 ID")
_assert(zombies.state[0] == ZombieHordeSystem.State.CHASE, "可达且感知到玩家必须进入追击")

fields.set_unreachable(0, 0, 0)
var before := Vector2i(zombies.pos_x[0], zombies.pos_z[0])
horde.step(2, players, map_grid, fields, spatial_hash, events)
_assert(Vector2i(zombies.pos_x[0], zombies.pos_z[0]) == before, "无路径时不得直线向玩家移动")

players.pos_x[0] = 900
players.pos_z[0] = 0
events.begin_tick(3)
horde.step(3, players, map_grid, fields, spatial_hash, events)
_assert(events.zombie_attack_intent_count() == 1, "一只就绪僵尸每 Tick 只能写入一个攻击意图")
```

同一脚本必须另建 17 只同距离、同 cooldown 的僵尸并断言只写入 16 条意图；创建两只重叠僵尸并断言分离后的坐标不相同，交换创建顺序后逐槽位规范状态不变。

- [ ] **步骤 2：运行验证并确认其因缺少群体系统失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde.gd
```

预期：进程非零退出，错误指向缺少 `ZombieHordeSystem` 或其 `step()`；未实现的流场夹具、攻击名额或分离断言不得被条件跳过。

- [ ] **步骤 3：写入固定状态机与目标选择**

在 `ZombieHordeSystem` 定义只含整数状态，并按僵尸 slot 升序选最近的存活玩家；距离相同按玩家实体 ID 小者胜出：

```gdscript
extends RefCounted
class_name ZombieHordeSystem

enum State { WANDER, CHASE, ATTACK }
const MAX_ATTACK_INTENTS_PER_PLAYER := 16

var config: ZombieSimConfig
var zombies: ZombieState
var _attack_slots := PackedInt32Array([0, 0, 0, 0])

func _select_target(slot: int, players: SimPlayerState) -> int:
	var best_id := ZombieState.INVALID_ENTITY_ID
	var best_distance_sq := 0
	for player_slot in 4:
		if not players.is_alive(player_slot):
			continue
		var dx := players.pos_x[player_slot] - zombies.pos_x[slot]
		var dz := players.pos_z[player_slot] - zombies.pos_z[slot]
		var distance_sq := dx * dx + dz * dz
		var player_id := players.entity_id_for_slot(player_slot)
		if best_id == ZombieState.INVALID_ENTITY_ID or distance_sq < best_distance_sq or (distance_sq == best_distance_sq and player_id < best_id):
			best_id = player_id
			best_distance_sq = distance_sq
	return best_id
```

目标在感知范围外时进入 `WANDER`。游荡目标由该僵尸自己的 Park–Miller 状态与 Plan 1 的十六方向表生成，抵达 `wander_arrive_units` 后才推进一次随机流；不得读取全局 RNG。目标可达且处于攻击范围时进入 `ATTACK`；其余可达目标进入 `CHASE`。将 `target_id` 写入对应 SoA 槽位，所有比较使用距离平方。

- [ ] **步骤 4：以流场和地图格驱动移动，不给无路径目标直线回退**

实现移动意图时只读取目标玩家槽位对应流场：

```gdscript
func _flow_velocity(slot: int, player_slot: int, fields: SimFlowFieldSet) -> Vector2i:
	var field = fields.field_for_slot(player_slot)
	if field == null or not field.is_reachable(zombies.pos_x[slot], zombies.pos_z[slot]):
		return Vector2i.ZERO
	var step := field.next_step(zombies.pos_x[slot], zombies.pos_z[slot])
	return Vector2i(step.x * config.move_speed_per_tick, step.y * config.move_speed_per_tick)

func _move_with_map(slot: int, map_grid: SimMapGrid, intended: Vector2i) -> void:
	var resolved := map_grid.move_circle_x_then_z(
		zombies.pos_x[slot], zombies.pos_z[slot], config.radius_units, intended.x, intended.y
	)
	zombies.velocity_x[slot] = resolved.x - zombies.pos_x[slot]
	zombies.velocity_z[slot] = resolved.y - zombies.pos_z[slot]
	zombies.pos_x[slot] = resolved.x
	zombies.pos_z[slot] = resolved.y
```

`ATTACK` 状态的速度为零；`CHASE` 只有在 `field.is_reachable()` 时才使用 `_flow_velocity()`；不可达时保留 `CHASE` 状态、位置和速度归零，不能改用玩家相对坐标。更新 heading 时复用 Plan 1 的整数方向表，以移动向量量化，没有位移时保留旧朝向。

- [ ] **步骤 5：构建空间哈希并施加一次确定性局部分离**

每 Tick 在所有目标/移动意图计算后清空并重建哈希：先以 slot 升序插入所有活着的僵尸，再以 slot 升序查询九个相邻桶。候选 ID 必须升序读取，且只处理 `other_slot > slot`，把一对实体的反向等量修正累积进预分配的 `separation_x[]`、`separation_z[]`，最后统一应用：

```gdscript
func _accumulate_pair_separation(slot: int, other_slot: int, push_x: PackedInt32Array, push_z: PackedInt32Array) -> void:
	var dx := zombies.pos_x[other_slot] - zombies.pos_x[slot]
	var dz := zombies.pos_z[other_slot] - zombies.pos_z[slot]
	var distance_sq := dx * dx + dz * dz
	var limit_sq := config.separation_radius_units * config.separation_radius_units
	if distance_sq >= limit_sq:
		return
	var direction_index := FixedMath.quantize_heading_16(dx, dz)
	var direction := FixedMath.heading_vector(direction_index)
	push_x[slot] -= direction.x * config.separation_push_per_tick
	push_z[slot] -= direction.y * config.separation_push_per_tick
	push_x[other_slot] += direction.x * config.separation_push_per_tick
	push_z[other_slot] += direction.y * config.separation_push_per_tick
```

零距离使用 `entity_id_for_slot(slot) < entity_id_for_slot(other_slot)` 选择相反的固定十六方向，绝不使用随机数。最终分离位移也调用 `move_circle_x_then_z()`，固定先 X 后 Z，不能穿过 `SimMapGrid` 阻挡格。

- [ ] **步骤 6：运行行为验证与失败场景复查**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

预期：两个命令以 0 退出。验证必须在无流场、失效流场、地图阻挡、17 只同目标攻击、两个重叠僵尸、两个等距玩家及玩家死亡六个失败条件下完成；其中无流场断言位置不改变，不能接受任何直线移动。

### Task 3：写入攻击意图缓冲并接入 `SimulationWorld`

**文件：**

- 修改：`scripts/simulation/sim_event_buffer.gd`
- 修改：`scripts/simulation/simulation_world.gd`
- 修改：`tools/validation/validate_frame_sync_zombie_horde.gd`

**接口：**

- 消费：Task 1 的 `ZombieState`，Task 2 的 `ZombieHordeSystem`，Plan 1 的 `SimulationWorld` 固定阶段顺序与 `SimEventBuffer.begin_tick(tick: int) -> void`。
- 产出：本文件「供后续计划消费的接口」所列四个 `SimEventBuffer` 方法。
- 产出：`SimulationWorld.spawn_zombie(spawn_x: int, spawn_z: int, rng_seed: int) -> int`，仅供旁路测试入口和后续波次系统调用。

- [ ] **步骤 1：先让 17 只僵尸的攻击意图 API 失败**

把下段测试加入群体验证；此时 `SimEventBuffer` 不具备方法，应报脚本解析或方法缺失错误：

```gdscript
for slot in 17:
	var id := horde.spawn(900 + slot, 0, 31 + slot)
	_assert(id != ZombieState.INVALID_ENTITY_ID, "17 只测试僵尸必须成功生成")
horde.step(100, players, map_grid, fields, spatial_hash, events)
_assert(events.zombie_attack_intent_count() == 16, "单玩家攻击意图名额必须硬限制为 16")
for index in events.zombie_attack_intent_count():
	_assert(events.zombie_attack_intent_target_id(index) == players.entity_id_for_slot(0), "攻击意图必须指向已选玩家")
	_assert(events.zombie_attack_intent_source_id(index) < events.zombie_attack_intent_source_id(index + 1) if index < 15 else true, "意图必须按稳定来源 ID 升序")
```

- [ ] **步骤 2：运行失败验证**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde.gd
```

预期：进程非零退出，指出 `append_zombie_attack_intent`、计数或索引读取方法尚不存在；不得将攻击意图写成临时 `Array` 或直接改写玩家生命。

- [ ] **步骤 3：实现定长攻击意图缓冲及名额分配**

在 `SimEventBuffer` 添加初始容量为 `zombie_capacity`、上限与僵尸容量相同的 SoA 事件字段；`begin_tick()` 将计数重置为零但不重新分配数组：

```gdscript
var _zombie_attack_source_ids := PackedInt32Array()
var _zombie_attack_target_ids := PackedInt32Array()
var _zombie_attack_count := 0

func configure_zombie_attack_capacity(capacity: int) -> void:
	_zombie_attack_source_ids.resize(capacity)
	_zombie_attack_target_ids.resize(capacity)

func append_zombie_attack_intent(source_entity_id: int, target_entity_id: int) -> void:
	if _zombie_attack_count >= _zombie_attack_source_ids.size():
		push_error("zombie attack intent buffer exhausted")
		return
	_zombie_attack_source_ids[_zombie_attack_count] = source_entity_id
	_zombie_attack_target_ids[_zombie_attack_count] = target_entity_id
	_zombie_attack_count += 1

func zombie_attack_intent_count() -> int:
	return _zombie_attack_count
```

补齐两个 index getter：索引不在 `[0, _zombie_attack_count)` 时返回 `ZombieState.INVALID_ENTITY_ID` 并在调试运行报告错误。`ZombieHordeSystem.step()` 开头把 `_attack_slots` 四项重置为 0；仅当僵尸在攻击范围、目标仍存活、流场把当前位置标记为可达、`cooldown_tick[slot] <= tick` 且对应玩家名额小于 16 时 append，并把该名额加一和推进冷却。不得调用任何 `Health`、伤害、死亡或 FX API。

- [ ] **步骤 4：在世界固定阶段接入僵尸系统**

在 `SimulationWorld.initialize()` 校验 `ZombieSimConfig.validate() == OK` 后创建 SoA、群体系统并配置事件容量；在 Plan 2 流场更新、Plan 3 玩家移动/队伍边界之后、Plan 5 战斗结算之前插入唯一调用：

```gdscript
func _step_zombies(tick: int) -> void:
	zombie_horde_system.step(
		tick,
		sim_players,
		map_grid,
		flow_fields,
		zombie_spatial_hash,
		event_buffer
	)

func spawn_zombie(spawn_x: int, spawn_z: int, rng_seed: int) -> int:
	return zombie_horde_system.spawn(spawn_x, spawn_z, rng_seed)
```

保持 `step(tick, frame)` 签名和其他阶段顺序。新旁路测试世界没有 zombie spawn 时，`_step_zombies()` 是固定容量零实体遍历；旧 `DemoArena` 不实例化或绑定新系统。

- [ ] **步骤 5：验证意图、冷却与世界接线**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

预期：17 只僵尸同 Tick 对一个玩家只保留来源 ID 最小的 16 个意图；同一只僵尸在 42 Tick 冷却结束前不重复写入；`SimulationWorld.spawn_zombie()` 产生的实体会在下一个 `step()` 由群体系统推进。验证输出中不得出现玩家生命变化、`ZombieTarget`、Physics 或 NavigationServer 调用。

### Task 4：加入最小只读 `ZombieDebugView` 与 150 只群体回放

**文件：**

- 创建：`scripts/simulation/view/zombie_debug_view.gd`
- 创建：`scenes/simulation/ZombieDebugView.tscn`
- 修改：`scripts/simulation/testing/determinism_harness.gd`
- 创建：`tools/validation/validate_frame_sync_zombie_horde_replay.gd`

**接口：**

- 消费：Task 1 的 `ZombieState`、Task 3 的 `SimulationWorld.zombie_state` 和 Plan 1 的输入录像二进制编解码、规范状态/Hash 比较。
- 产出：`ZombieDebugView.bind_world(world: SimulationWorld) -> void`，只读取状态；`DeterminismHarness.run_zombie_horde_replay(tape: InputTape, spawn_count: int, ticks: int) -> Dictionary`。

- [ ] **步骤 1：写失败的 150 只双实例回放验证**

创建回放验证，固定 150 个按 slot 可重复生成的位置和种子，直接命令世界与编解码命令世界逐 Tick 比较：

```gdscript
var result := harness.run_zombie_horde_replay(tape, 150, 10_000)
_assert(result["first_divergence_tick"] == -1, "10,000 Tick 不得出现 Hash 分歧")
_assert(result["final_alive_count"] == 150, "Plan 4 不结算伤害，150 只僵尸应保持存活")

result = harness.run_zombie_horde_replay(tape, 150, 100_000)
_assert(result["first_divergence_tick"] == -1, "100,000 Tick 不得出现 Hash 分歧")
_assert(result["capacity"] == 256, "150 只回放不得导致 SoA 扩容")
```

录像使用一名存活玩家的重复十六方向移动命令，周期性切换位置使流场更新；其中含 256 Tick 的无路径窗口。回放脚本必须将首个分歧的 Tick、输入帧、直接世界规范状态和编解码世界规范状态输出为 JSON，缺少任一字段视为失败。

- [ ] **步骤 2：运行回放验证并确认其因 harness API 不存在失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde_replay.gd
```

预期：进程非零退出，指出 `run_zombie_horde_replay()` 未定义；不得把 100,000 Tick 缩短为抽样 Hash 或忽略无路径窗口。

- [ ] **步骤 3：扩展双实例 harness，并保持 Hash 编码完整**

在 harness 内按相同 `(slot, spawn_x, spawn_z, rng_seed)` 顺序给两个 `SimulationWorld` 调用 `spawn_zombie()`；每 Tick 对左世界提交原始 `LocalFrameCommandSet`，对右世界提交 `decode(encode(frame))` 的命令。每一步分别获得 Plan 1 的规范状态 Hash：

```gdscript
func run_zombie_horde_replay(tape: InputTape, spawn_count: int, ticks: int) -> Dictionary:
	var direct_world := _new_horde_world()
	var decoded_world := _new_horde_world()
	_spawn_horde_pair(direct_world, decoded_world, spawn_count)
	for tick in ticks:
		var direct_frame := tape.frame_at(tick)
		var decoded_frame := LocalFrameCommandSet.decode(direct_frame.encode())
		direct_world.step(tick, direct_frame)
		decoded_world.step(tick, decoded_frame)
		if direct_world.state_hash() != decoded_world.state_hash():
			return _divergence_result(tick, direct_frame, direct_world, decoded_world)
	return {"first_divergence_tick": -1, "final_alive_count": spawn_count, "capacity": 256}
```

把 `ZombieState` 的 capacity、每个 slot 的 `alive/generation/pos_x/pos_z/velocity_x/velocity_z/heading/health/state/target_id/cooldown_tick/rng_state` 按 slot 升序纳入 Plan 1 的规范状态编码。调试视图不进入 Hash，不调用 `world.step()`，也不向事件缓冲写入。

- [ ] **步骤 4：实现旁路调试视图且不接触旧僵尸节点**

创建仅含 `MeshInstance3D` 子节点的 `ZombieDebugView.tscn`，其脚本以 `ImmediateMesh` 绘制每只活僵尸的位置和朝向；绑定是显式的，未绑定时不绘制：

```gdscript
extends Node3D
class_name ZombieDebugView

var _world: SimulationWorld
var _mesh := ImmediateMesh.new()

func bind_world(world: SimulationWorld) -> void:
	_world = world
	($MeshInstance3D as MeshInstance3D).mesh = _mesh

func _process(_delta: float) -> void:
	_mesh.clear_surfaces()
	if _world == null:
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for slot in _world.zombie_state.capacity:
		if not _world.zombie_state.is_alive(slot):
			continue
		var x := float(_world.zombie_state.pos_x[slot]) / 1024.0
		var z := float(_world.zombie_state.pos_z[slot]) / 1024.0
		_mesh.surface_add_vertex(Vector3(x, 0.05, z))
		_mesh.surface_add_vertex(Vector3(x, 0.05, z + 0.4))
	_mesh.surface_end()
```

视图可用浮点换算和 `_process()`，因为它是纯表现；它不得 preload `ZombieTarget.tscn`、读取 `NodePath`、影响路径、攻击、随机数或 Hash。

- [ ] **步骤 5：运行两个时长的 replay、导入检查与人工旁路验收**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde_replay.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

预期：10,000 和 100,000 Tick 都返回 `first_divergence_tick = -1`，150 个活体且 capacity 为 256。人工验收：通过旁路模拟测试入口绑定 `ZombieDebugView`，观察 150 条朝向线随 SoA 更新；关闭或释放视图后继续无渲染回放，最终 Hash 必须相同。不要自动化操作 Godot 编辑器。

### Task 5：输出 100/150 性能报告并进行最终集成验证与单一提交

**文件：**

- 创建：`tools/validation/validate_frame_sync_zombie_horde_benchmark.gd`
- 修改：`tools/validation/validate_frame_sync_zombie_horde_replay.gd`

**接口：**

- 消费：Task 3 的 `SimulationWorld.spawn_zombie()`、Task 4 的 `DeterminismHarness.run_zombie_horde_replay()`；只读 `ZombieState.capacity`。
- 产出：stdout 中一份包含 100、150、256、512 档 `sample_count`、P50、P95、P99、最大值和容量的 JSON 报告；进程状态表达预算是否通过。

- [ ] **步骤 1：先写失败的预算断言和报告结构**

基准脚本预分配世界与 150 个僵尸，先运行 300 个预热 Tick，再采集 3,000 个 Tick 的单步耗时，单位统一为毫秒：

```gdscript
var report := _benchmark_tier(150, 3_000)
_assert(report["sample_count"] == 3_000, "报告必须保留全部采样")
_assert(report["p95_ms"] <= 8.0, "150 只僵尸 P95 必须不高于 8 ms")
_assert(report["p99_ms"] <= 16.0, "150 只僵尸 P99 必须不高于 16 ms")
print(JSON.stringify(report))
```

基准一并执行 100、256、512 档并输出 JSON Lines；100 与 150 档是硬门槛，256/512 档只记录结果和 `capacity`，不隐藏任何超预算样本。

- [ ] **步骤 2：运行预算验证并确认实现前失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde_benchmark.gd
```

预期：在 `_benchmark_tier()` 尚未实现时非零退出，或在未满足预算时以非零退出并打印实际 P95/P99；不得把失败改成警告或删去 150 档。

- [ ] **步骤 3：实现可复现的分位数报告**

每个档位从相同会话 seed、相同地图格、相同 30 Hz 指令循环和相同僵尸生成序列开始；采样时只包围 `world.step(tick, frame)`，不包含场景、日志、JSON 序列化或 DebugView。排序副本后采用向上取整的秩，避免不同实现取值不一致：

```gdscript
func _percentile(sorted_samples: Array[float], numerator: int, denominator: int) -> float:
	var rank := (sorted_samples.size() * numerator + denominator - 1) / denominator
	return sorted_samples[maxi(rank - 1, 0)]

func _benchmark_tier(count: int, sample_count: int) -> Dictionary:
	var world := _new_benchmark_world(count)
	for warmup_tick in 300:
		world.step(warmup_tick, _benchmark_frame(warmup_tick))
	var samples: Array[float] = []
	for tick in sample_count:
		var started := Time.get_ticks_usec()
		world.step(tick + 300, _benchmark_frame(tick + 300))
		samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
	var sorted := samples.duplicate()
	sorted.sort()
	return {"zombie_count": count, "capacity": world.zombie_state.capacity, "sample_count": sample_count, "p50_ms": _percentile(sorted, 50, 100), "p95_ms": _percentile(sorted, 95, 100), "p99_ms": _percentile(sorted, 99, 100), "max_ms": sorted.back()}
```

在最低目标 Web 或移动设备执行同一命令并保存 stdout，报告必须明确设备型号、系统、Godot 版本、渲染后端、命令、100/150 的 P95/P99 与通过/失败结论；开发机 Headless 报告只能用于回归，不能替代最低目标设备结果。

- [ ] **步骤 4：运行全部自动验证并检查旧路径未被修改**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_state.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde_replay.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde_benchmark.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
git diff --check
git diff -- scripts/combat/zombie_target.gd scenes/targets/ZombieTarget.tscn scripts/gameplay/demo_arena.gd
```

预期：前四个验证与 Headless 导入均为 0；最后一条 diff 没有输出。100 和 150 档报告在最低目标设备上都满足 P95 ≤ 8 ms、P99 ≤ 16 ms；任何档位出现容量增长、Hash 分歧、无路径直线移动、超过 16 条攻击意图或旧路径 diff 时，本计划不得进入 Plan 5。

- [ ] **步骤 5：最终评审后创建唯一提交**

确认工作区仅包含本计划列出的模拟、调试视图和验证文件，并确认所有任务内容在同一分支的一个提交中：

```bash
git add scripts/simulation/zombies/zombie_sim_config.gd scripts/simulation/zombies/zombie_state.gd scripts/simulation/zombies/zombie_horde_system.gd scripts/simulation/sim_event_buffer.gd scripts/simulation/simulation_world.gd scripts/simulation/testing/determinism_harness.gd scripts/simulation/view/zombie_debug_view.gd scenes/simulation/ZombieDebugView.tscn tools/validation/validate_frame_sync_zombie_state.gd tools/validation/validate_frame_sync_zombie_horde.gd tools/validation/validate_frame_sync_zombie_horde_replay.gd tools/validation/validate_frame_sync_zombie_horde_benchmark.gd
git commit -m "feat(simulation): add deterministic zombie horde"
```

预期：提交只含本计划实现；提交后重新运行 Task 5 的五条 Godot 命令并保存最低目标设备报告。该提交是 Plan 4 的唯一 squash 提交，Plan 5 以本计划「供后续计划消费的接口」作为唯一僵尸战斗接缝。

## 规格覆盖复核

- 僵尸 SoA、默认 256、压测 512、稳定 ID/generation 与容量耗尽由 Task 1 覆盖。
- `SimPlayerState`、`SimMapGrid`、`SimFlowFieldSet`、`SimSpatialHash`、`SimEventBuffer` 与 `SimulationWorld` 的交界和调用顺序由 Task 2、3 覆盖。
- 目标选择、游荡、追击、攻击意图、每玩家 16 名额、局部分离及无路径不直线降级由 Task 2、3 的失败断言覆盖。
- 伤害、生命改写、死亡、命中和战斗表现明确留给 Plan 5；Plan 4 只生产攻击意图。
- 最小 `ZombieDebugView` 与旧 `ZombieTarget` 不改由 Task 4、5 的只读和 diff 验证覆盖。
- 150 只 10,000/100,000 Tick 双实例回放，以及 100/150 P95 ≤ 8 ms、P99 ≤ 16 ms 的报告由 Task 4、5 覆盖。

## 占位符与类型一致性复核

- 本文没有未定实现项、空白步骤或省略的失败条件；每个新增 API 都在接口段或产生它的任务中给出准确名称和参数。
- `ZombieState` 的实体 ID 使用低 10 位 slot、其余高位 generation；`ZombieHordeSystem`、事件缓冲和 Plan 5 消费方全部使用同一 `int` 实体 ID。
- 全文的回放入口统一为 `DeterminismHarness.run_zombie_horde_replay(tape, spawn_count, ticks)`，验证脚本统一位于 `tools/validation/`，长期 harness 路径统一为 `scripts/simulation/testing/determinism_harness.gd`。
