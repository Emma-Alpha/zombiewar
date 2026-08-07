# 帧同步 Plan 6：确定性世界交互与完整玩法循环 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在完全不实例化表现节点的 `SimulationWorld` 中实现整数油桶与爆炸连锁、放置与动态障碍、拾取/掉落/玩家库存、波次、全员失败和命令驱动重开，并让同一录像的直接命令与编解码命令路径逐 Tick Hash 一致。

**Architecture:** Plan 6 在 Plan 1～5 的稳定接口上扩展 `SimulationWorld`，不改变 `SimulationWorld.new(session)` 或 `step(tick, frame)`；新系统全部是 `RefCounted`/纯数据对象，并严格插入 SPEC 的第 2、3、10、11、12、13、14、15 阶段。油桶、拾取和库存使用固定容量 SoA；阶段 2/12 只形成定长实体命令，阶段 13 才统一生成/销毁；地图占用只通过 Plan 2 的 `SimDynamicOccupancyChange` 在确定 Tick 提交；枪械、爆炸和僵尸攻击共用 Plan 5 的唯一 `SimDamageQueue`。重开由失败状态下玩家槽位 0 的 `CONFIRM` 命令触发，在 Tick 末原子重建本局玩法状态，保留稳定玩家 ID/generation，模拟 Tick 继续递增。

**Tech Stack:** Godot 4.7.1、GDScript、`PackedInt32Array` / `PackedByteArray`、Plan 1 `FixedMath` / `ParkMillerRng` / `StateHasher` / `InputTape`、Plan 2 `SimMapGrid` / `SimDynamicOccupancyChange` / `SimFlowFieldSet`、Plan 3 `SimPlayerState`、Plan 4 `ZombieState`、Plan 5 `SimEquipmentState` / `SimDamageQueue` / `SimEventBuffer`、headless Godot 验证脚本。

## Global Constraints

- 唯一规格来源为 `docs/superpowers/specs/2026-08-08-local-deterministic-frame-sync-design.md`；任何既有计划或旧玩法实现与 SPEC 冲突时，以 SPEC 为准。
- 本计划依赖 Plan 1～5 各自自动验证、Headless 导入检查和人工门槛全部通过；任一前置门槛失败时停止实现，不以旧 Node 玩法判定填补新模拟缺口。
- `SimulationWorld` 保持 `SimulationWorld.new(session: LocalSimulationSession)`、`step(tick: int, frame: LocalFrameCommandSet) -> bool`；不接收 `delta`，不继承 `Node`，不持有 Node、RID、NodePath 或 instance ID。
- 模拟固定 30 Hz；`0.12` 秒油桶连锁延迟固定为 `4 Tick`，`1.5` 秒自动下一波固定为 `45 Tick`，`3.0` 秒固定补给重生固定为 `90 Tick`。
- 1 Godot 世界单位等于 1024 模拟单位；位置、半径、生命、伤害、弹药、库存、冷却、波次、计数与 Tick 全部使用整数；中间乘法使用 GDScript `int` 的 int64 语义。
- 不调用 Jolt、`PhysicsDirectSpaceState3D`、`CharacterBody3D`、`Area3D`、`NavigationAgent3D`、`NavigationServer3D`、运行时 NavMesh、`Timer`、动画回调、`RandomNumberGenerator`、全局 `rand*`、浮点三角函数或 `sqrt` 作为玩法判定。
- 玩家槽位固定为 `0..3`；玩家实体 ID/generation 来自 Plan 3，僵尸实体 ID/generation 来自 Plan 4；油桶实体 ID 固定为 `0x20000000 + slot + 1`，拾取实体 ID 固定为 `0x30000000 + slot + 1`，generation 独立存储并随槽位复用递增，两类容量均不得超过 128。
- 遍历按玩家 slot、僵尸 slot、油桶 slot、拾取 slot或实体 ID 升序；任何 `Dictionary` 只可按 ID 查询，不得依赖遍历顺序。
- Plan 2 动态占用只能通过 `SimDynamicOccupancyChange.new(tick, source_entity_id, local_sequence, owner_entity_id, operation, cell_ids)` 和 `SimulationWorld.queue_map_change(change)` 修改；放置在阶段 2 形成请求，阶段 3 提交，地图 revision 变化后阶段 4 原子重建流场。
- Plan 5 `SimDamageQueue` 是唯一伤害链；Plan 6 只追加 `TargetKind.BARREL = 3`，复用已冻结的 `DamageKind.EXPLOSION = 4`，不得创建第二套直接扣血路径。爆炸在阶段 10 append，阶段 11 与枪械、近战、僵尸攻击一起稳定排序并统一应用。
- 阶段 2/12 不得直接把新油桶、拾取或波次僵尸写成 alive；只可写入固定容量 `WorldEntityCommandBuffer`。阶段 13 按 `(phase, source_entity_id, source_generation, local_sequence, entity_kind, reserved_slot)` 提交，容量不足时写确定性拒绝事件且不得 resize。
- 掉落只消费 Plan 5 当 Tick 的稳定死亡记录；每个僵尸死亡恰好推进一次 drop PRNG，世界、波次、掉落和实体随机流彼此独立，全部编码进规范状态与 Hash。
- 旧 `DemoArena.tscn`、`ExplosiveBarrel.tscn` 与 `resources/pickups/*.tres` 只允许离线构建器读取；模拟运行时只加载已提交的整数 `WorldGameplaySimConfig`，其 32-byte `content_hash` 必须与规范整数 payload 相符。
- Plan 6 表现事件复用 Plan 5 `SimEventBuffer.append_presentation_candidate()` 和阶段 14 `finalize_presentation_events()`，事件类型从 Plan 5 保留的数值 8 开始追加；音频、FX、模型、HUD、摄像机和场景生命周期只能由 Plan 7 消费，不能回写模拟。
- 当前 `scenes/gameplay/DemoArena.tscn`、`scripts/gameplay/demo_arena.gd`、旧油桶/放置/拾取/掉落节点和主菜单入口不修改；Plan 8 资格验证完成前旧 DemoArena 继续是默认路径。
- 每个 Task 都遵循 TDD：先写会因缺失接口或行为失败的验证，再实现最小代码，再运行聚焦验证与 Headless 导入检查。
- 依项目约定，单独 Task 不创建提交；整个计划执行完成后由用户自行提交。执行本计划前必须询问用户是否需要隔离 worktree，默认在当前工作区执行。

---

## 文件结构与稳定边界

| 路径 | 职责 |
| --- | --- |
| `scripts/simulation/gameplay/world_gameplay_sim_config.gd` | DemoArena 世界交互的全整数配置、容量、固定初始实体、波次/掉落参数、流种子派生和上界校验。 |
| `scripts/simulation/gameplay/world_gameplay_sim_config_codec.gd` | Plan 6 配置的规范 little-endian payload、SHA-256 计算与 content hash 校验。 |
| `resources/simulation/demo_arena_world_gameplay.tres` | 提交到仓库的 Plan 6 整数配置；与地图和战斗配置共同进入 manifest/config Hash。 |
| `tools/simulation/build_world_gameplay_sim_config.gd` | 离线读取旧场景、油桶/放置场景和三份 pickup 资源，按冻结舍入规则生成整数配置。 |
| `scripts/simulation/session/simulation_config_bundle.gd` | 固定组合 map/player/zombie/combat/world 五份组件 Hash，生成完整玩法 `config_hash`。 |
| `scripts/simulation/events/sim_presentation_event.gd` | 在 Plan 5 表现事件类型后从数值 8 起追加世界玩法事件常量。 |
| `scripts/simulation/gameplay/barrel_state.gd` | 最多 128 个油桶的 alive/generation/位置/状态/命中/爆炸 Tick/占用 cell SoA。 |
| `scripts/simulation/gameplay/barrel_explosion_system.gd` | 枪械命中阈值、整数爆炸范围/遮挡、4 Tick 连锁和统一伤害队列写入。 |
| `scripts/simulation/gameplay/world_entity_command_buffer.gd` | 固定容量保存阶段 2/12 产生的油桶、拾取和僵尸生成/销毁命令，阶段 13 稳定排序后一次提交。 |
| `scripts/simulation/gameplay/player_inventory_state.gd` | 与玩家 slot 绑定的油桶库存 SoA；SMG 所有权与弹药继续由 Plan 5 `SimEquipmentState` 保存。 |
| `scripts/simulation/gameplay/placement_system.gd` | 消费 `USE_PRESSED`/`placement_heading`，稳定裁决同格放置，成功后扣一个油桶并提交动态占用。 |
| `scripts/simulation/gameplay/pickup_state.gd` | 固定补给与随机掉落的固定容量 SoA、稳定 ID、重生 Tick、奖励种类和整数位置。 |
| `scripts/simulation/gameplay/loot_pickup_system.gd` | 消费 Plan 1 world-owned drop RNG，处理死亡掉落、槽位升序拾取、奖励拒绝、固定补给 90 Tick 重生和动态占用。 |
| `scripts/simulation/gameplay/match_loop_state.gd` | match generation、STARTING/RUNNING/DEFEATED、波次号、下一波 Tick 与规范编码；不重复持有 Plan 1 RNG。 |
| `scripts/simulation/gameplay/wave_match_system.gd` | 四角整数波次生成、45 Tick 自动下一波、全员失败和 slot 0 `CONFIRM` 重开请求。 |
| `scripts/simulation/events/sim_event_buffer.gd` | 复用并扩容 Plan 4/5 攻击意图、死亡记录和固定表现候选/最终事件缓冲，不建立第二套事件链。 |
| `scripts/simulation/combat/sim_damage_queue.gd` | 增加 `TargetKind.BARREL = 3`，复用 Plan 5 的 `DamageKind.EXPLOSION = 4`。 |
| `scripts/simulation/combat/sim_hit_candidate_buffer.gd` | 在 Plan 5 候选列尾部增加 target kind 与 blocks-shot，保持旧五参数 append 兼容。 |
| `scripts/simulation/combat/sim_combat_geometry.gd` | 把 alive 油桶作为有 generation 的终止型枪械圆形候选，目标自身动态格可忽略。 |
| `scripts/simulation/combat/sim_combat_system.gd` | 阶段 9 枪械候选加入油桶，并在选中油桶装备时禁止武器攻击。 |
| `scripts/simulation/combat/sim_damage_resolver.gd` | 在既有 `apply_all()` 稳定伤害提交中路由油桶目标，并让油桶命中/连锁只通过统一队列发生。 |
| `scripts/simulation/players/sim_player_state.gd` | 增加保留玩家稳定 ID/generation 的 `reset_for_match()`，只复位位置、生命、速度、击退和硬直。 |
| `scripts/simulation/world/simulation_world.gd` | 按 SPEC 固定阶段接入 Plan 6 系统、原子重开、规范状态和公开只读状态。 |
| `scripts/simulation/testing/world_game_loop_fixture.gd` | 构造不含 Node 的 DemoArena 小型完整循环世界与固定资格输入带。 |
| `scripts/simulation/testing/first_divergence_harness.gd` | 在跨计划统一 harness 中新增完整世界循环双实例逐 Tick Hash 与首分歧报告入口。 |
| `tools/validation/validate_frame_sync_barrels_placement.gd` | 油桶、爆炸、连锁、遮挡、放置、动态地图的聚焦验证。 |
| `tools/validation/validate_frame_sync_world_gameplay_config.gd` | 旧资源离线转换、重复构建、component hash 与最终 config bundle Hash 验证。 |
| `tools/validation/validate_frame_sync_loot_inventory.gd` | 固定补给、随机掉落、库存、奖励拒绝、重生与 PRNG 的聚焦验证。 |
| `tools/validation/validate_frame_sync_wave_restart.gd` | 波次、失败、slot 0 确认、原子重开和 Tick 连续性的聚焦验证。 |
| `tools/validation/validate_frame_sync_world_game_loop_replay.gd` | 无表现完整循环与 100,000 Tick 双实例 Hash 门槛。 |

### 供 Plan 7/8 消费的冻结接口

```gdscript
# scripts/simulation/world/simulation_world.gd
func configure_config_bundle(bundle: SimulationConfigBundle) -> bool
func configure_world_gameplay(config: WorldGameplaySimConfig) -> bool
func get_barrel_state() -> BarrelState
func get_pickup_state() -> PickupState
func get_player_inventory_state() -> PlayerInventoryState
func get_match_loop_state() -> MatchLoopState
func get_match_state() -> int
func get_match_generation() -> int
func get_last_presentation_events() -> Array[SimPresentationEvent]

# scripts/simulation/testing/world_game_loop_fixture.gd
const QUALIFICATION_SEED := 24681357
static func create_session(session_seed: int, active_player_mask: int) -> LocalSimulationSession
static func create_world(session_seed: int, active_player_mask: int) -> SimulationWorld
static func build_qualification_tape(active_player_mask: int, ticks: int) -> InputTape

# scripts/simulation/testing/first_divergence_harness.gd
func run_world_game_loop_replay(tape: InputTape, ticks: int) -> Dictionary
```

完整世界配置顺序冻结为 `SimulationWorld.new(session)` → `configure_config_bundle(bundle)` → `configure_map(map_asset)` → `configure_players(player_config)` → `configure_zombie_horde(zombie_config)` → `configure_combat(combat_config)` → `configure_world_gameplay(world_config)`；任一步乱序、重复、非 Tick 0 或 component hash 不匹配都返回 `false`。`get_last_presentation_events()` 复用 Plan 5 已冻结接口，返回 finalization 后的只读副本；world gameplay 类型值为 8～17。Plan 7 只读以上状态和统一表现事件建立视图，Plan 8 使用 fixture 与 harness 生成单人、2 人、4 人资格录像。重开不暴露外部直接调用，唯一玩法入口是失败状态下 slot 0 的 `CONFIRM` 帧命令。

### Task 1：建立整数世界配置、油桶爆炸连锁和动态占用

**Files:**
- Create: `scripts/simulation/gameplay/world_gameplay_sim_config.gd`
- Create: `scripts/simulation/gameplay/world_gameplay_sim_config_codec.gd`
- Create: `resources/simulation/demo_arena_world_gameplay.tres`
- Create: `tools/simulation/build_world_gameplay_sim_config.gd`
- Create: `scripts/simulation/session/simulation_config_bundle.gd`
- Modify: `scripts/simulation/events/sim_presentation_event.gd`
- Create: `scripts/simulation/gameplay/barrel_state.gd`
- Create: `scripts/simulation/gameplay/barrel_explosion_system.gd`
- Create: `scripts/simulation/gameplay/world_entity_command_buffer.gd`
- Modify: `scripts/simulation/combat/sim_damage_queue.gd`
- Modify: `scripts/simulation/combat/sim_hit_candidate_buffer.gd`
- Modify: `scripts/simulation/combat/sim_combat_geometry.gd`
- Modify: `scripts/simulation/combat/sim_combat_system.gd`
- Modify: `scripts/simulation/combat/sim_damage_resolver.gd`
- Modify: `scripts/simulation/events/sim_event_buffer.gd`
- Modify: `scripts/simulation/world/simulation_world.gd`
- Create: `tools/validation/validate_frame_sync_barrels_placement.gd`
- Create: `tools/validation/validate_frame_sync_world_gameplay_config.gd`

**Interfaces:**
- Consumes: `FixedMath.distance_squared()`、`ParkMillerRng`、`SimMapGrid.world_to_cell_id()` / `is_cell_blocked()` / `dynamic_owner_at()` / `has_clear_line()`、`SimulationWorld.queue_map_change()`、Plan 5 已冻结的 13 参数 `SimDamageQueue.append` 与稳定伤害提交。
- Produces: `WorldGameplaySimConfig.load_demo_arena() -> WorldGameplaySimConfig`、`validate() -> Error`、`get_content_hash() -> PackedByteArray`、`derive_stream_seed(session_seed: int, stream_tag: int, match_generation: int) -> int`；`WorldGameplaySimConfigCodec.encode_payload(config: WorldGameplaySimConfig) -> PackedByteArray`、`compute_hash(config: WorldGameplaySimConfig) -> PackedByteArray`、`validate_content_hash(config: WorldGameplaySimConfig) -> bool`；`BuildWorldGameplaySimConfig.build() -> WorldGameplaySimConfig`、`save_to(path: String) -> Error`。
- Produces: `SimulationConfigBundle.build(map_hash: PackedByteArray, player_hash: PackedByteArray, zombie_hash: PackedByteArray, combat_hash: PackedByteArray, world_hash: PackedByteArray) -> SimulationConfigBundle`、`get_component_hash(index: int) -> PackedByteArray`、`get_config_hash() -> PackedByteArray`。
- Produces: `BarrelState.spawn(pos_x: int, pos_z: int, heading: int, owner_player_slot: int, occupied_cell_id: int) -> Dictionary`、`spawn_reserved(reference: Dictionary, pos_x: int, pos_z: int, heading: int, owner_player_slot: int, occupied_cell_id: int) -> bool`、`despawn(entity_id: int, expected_generation: int) -> bool`、`despawn_all() -> void`、`slot_for_entity_id(entity_id: int, expected_generation: int) -> int`、`generation_for_slot(slot: int) -> int`、`encode_canonical(writer: LittleEndianWriter) -> void`。
- Produces: `WorldEntityCommandBuffer.new(capacity: int)`、`reserve_barrel_spawn(phase: int, source_entity_id: int, source_generation: int, local_sequence: int, barrels: BarrelState, pos_x: int, pos_z: int, heading: int, owner_player_slot: int, occupied_cell_id: int) -> Dictionary`、`append_zombie_spawn(phase: int, source_entity_id: int, source_generation: int, local_sequence: int, spawn_x: int, spawn_z: int, initial_health: int, initial_rng_state: int, profile_id: int) -> bool`、`append_despawn(phase: int, source_entity_id: int, source_generation: int, local_sequence: int, entity_kind: int, entity_id: int, entity_generation: int, keep_fixed_reservation: int = 0, respawn_tick: int = -1) -> bool`、`cancel_reserved_spawn(entity_kind: int, entity_id: int, entity_generation: int) -> bool`、`sort_canonical() -> void`、Task 1 中间 `commit(tick: int, zombies: ZombieState, barrels: BarrelState, pickups: RefCounted, events: SimEventBuffer) -> bool`、`clear() -> void`、`encode_canonical(writer: LittleEndianWriter) -> void`；barrel reservation 成功返回完整 `{entity_id, generation, slot}`，失败为空字典。Task 1 调用 commit 时 `pickups=null`，Task 2 在 `PickupState` 存在后收紧最终签名。
- Produces: `SimulationWorld.configure_config_bundle(bundle: SimulationConfigBundle) -> bool`，只允许 Tick 0 且先于任何 component 配置，验证 `_session.get_manifest().config_hash == bundle.get_config_hash()` 并保存五段只读 component hash；Task 3 完成最终 `configure_world_gameplay(config: WorldGameplaySimConfig) -> bool`。
- Produces: `BarrelExplosionSystem.new(config: WorldGameplaySimConfig)`、`step_explosions(tick: int, players: SimPlayerState, zombies: ZombieState, barrels: BarrelState, map_grid: SimMapGrid, damage_queue: SimDamageQueue, entity_commands: WorldEntityCommandBuffer, events: SimEventBuffer) -> bool`；`SimDamageResolver.apply_all(tick: int, queue: SimDamageQueue, players: SimPlayerState, zombies: ZombieState, barrels: BarrelState, equipment: SimEquipmentState, events: SimEventBuffer) -> bool`。
- Produces: `SimDamageResolver.new(config: SimCombatConfig, player_movement: PlayerMovementSystem, world_config: WorldGameplaySimConfig = null)`；`SimHitCandidateBuffer.append(sort_value: int, target_entity_id: int, target_generation: int, hit_x: int, hit_z: int, target_kind: int = SimDamageQueue.TargetKind.ZOMBIE, blocks_shot: int = 0) -> bool` 与 `target_kind_at(index: int) -> int` / `blocks_shot_at(index: int) -> int`。

- [ ] **Step 1：先写整数配置和油桶状态的失败验证**

在 `validate_frame_sync_world_gameplay_config.gd` 调用离线 builder，断言它从 `DemoArena.tscn`、`ExplosiveBarrel.tscn`、`OilBarrelEquipment.tscn` 与三份 `resources/pickups/*.tres` 得到当前数值；连续 build 两次的 canonical payload、`content_hash` 和最终 `SimulationConfigBundle.config_hash` 必须相同。在 `validate_frame_sync_barrels_placement.gd` 固定三个初始油桶位置 `(-14336,-3584)`、`(-11264,-3584)`、`(-15360,4096)`；第 2 次枪械命中进入 `DAMAGED`，第 3 次命中进入 `EXPLODING`；爆炸半径 `4608`、中心伤害 `80`、边缘伤害 `20`、连锁延迟 `4` Tick，并验证实体 ID namespace、generation 复用和容量耗尽：

```gdscript
var config := WorldGameplaySimConfig.load_demo_arena()
_assert(config.validate() == OK, "DemoArena world gameplay config must validate")
_assert(config.chain_delay_ticks == 4, "0.12 seconds must canonicalize to 4 ticks")
_assert(config.initial_barrel_pos_x == PackedInt32Array([-14336, -11264, -15360]), "initial barrel X must be integer world units")

var barrels := BarrelState.new(2)
var first := barrels.spawn(0, 0, 1, -1, 7)
_assert(first == {"entity_id": 0x20000001, "generation": 1, "slot": 0}, "first barrel reference must use barrel namespace and generation 1")
_assert(barrels.despawn(first.entity_id, first.generation), "live barrel must despawn")
var reused := barrels.spawn(0, 0, 1, -1, 7)
_assert(reused.entity_id == first.entity_id and reused.generation == 2, "reused slot must retain entity id and increment generation")
```

- [ ] **Step 2：运行验证并确认缺少 Plan 6 类型时失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_world_gameplay_config.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_barrels_placement.gd
```

Expected: 至少一条非零退出，错误明确指向 builder、`WorldGameplaySimConfig`、`SimulationConfigBundle`、`BarrelState` 或 `BarrelExplosionSystem` 尚不存在；不得以跳过断言或在模拟运行时加载旧 Node/Resource 绕过。

- [ ] **Step 3：实现全整数配置资源和稳定世界事件类型**

`WorldGameplaySimConfig` 只暴露整数导出字段，构造 DemoArena 资源时写入以下值；`validate()` 拒绝容量超过 128、伤害负数、`edge_damage > center_damage`、Tick 小于 1、spawn 数量上下界颠倒、坐标或乘法可能超出 int32 设计范围的配置：

```gdscript
extends Resource
class_name WorldGameplaySimConfig

const STREAM_WORLD := 101
const STREAM_WAVE := 211
const STREAM_DROP := 307
const STREAM_ENTITY := 401
const STREAM_COMBAT := 503

@export var barrel_capacity := 128
@export var pickup_capacity := 128
@export var entity_command_capacity := 1024
@export var barrel_firearm_hits_to_damage := 2
@export var barrel_firearm_hits_to_explode := 3
@export var barrel_radius_units := 451
@export var chain_delay_ticks := 4
@export var explosion_radius_units := 4608
@export var explosion_center_damage := 80
@export var explosion_edge_damage := 20
@export var initial_barrel_pos_x := PackedInt32Array([-14336, -11264, -15360])
@export var initial_barrel_pos_z := PackedInt32Array([-3584, -3584, 4096])
@export var content_hash := PackedByteArray()

static func derive_stream_seed(session_seed: int, stream_tag: int, match_generation: int) -> int:
	var mixed := session_seed + stream_tag * 104729 + match_generation * 48271
	return FixedMath.euclidean_mod(mixed - 1, 2147483646) + 1
```

`BuildWorldGameplaySimConfig.build()` 读取以下唯一源：`DemoArena.tscn` 的三个初始油桶、四个 wave marker、波次范围/上限/半径/spacing、`AutoWaveTimer.wait_time`、三个固定 pickup spawner 的位置/respawn delay，以及随机掉落 manager 的 definition 顺序；`ExplosiveBarrel.tscn` 的命中阈值、chain delay、radius、中心/边缘伤害与圆柱半径；`OilBarrelEquipment.tscn` 的 max count 和后向放置方向；三份 pickup `.tres` 的 reward mode/item ID/amount/auto_equip；`RandomPickupDropManager` 默认 0.2 概率。离线舍入固定为 `round(world_units*1024)`、`ceil(seconds*30)`、`round(damage)`，概率化为最简整数分数 `1/5`。未知 item ID、固定 spawner delay 不一致、非后向油桶或任何超界值都使 build 失败。

`WorldGameplaySimConfigCodec.encode_payload()` 按字段声明顺序写 schema、全部标量和 PackedInt32Array 长度/值，不编码 `content_hash` 与 Resource 路径；`compute_hash()` 对 payload 做 SHA-256，`validate_content_hash()` 要求恰好 32 bytes。运行时 `load_demo_arena()` 只加载 `res://resources/simulation/demo_arena_world_gameplay.tres` 并验证 Hash，不读取旧源。

`SimulationConfigBundle` 固定组合五段 component Hash：Plan 2 `map_asset.get_content_hash()`、`SHA-256(player_config.encode_canonical())`、Plan 4 `zombie_config.get_content_hash()`、Plan 5 `combat_config.get_content_hash()`、Plan 6 `world_config.get_content_hash()`；索引常量固定为 `MAP=0/PLAYER=1/ZOMBIE=2/COMBAT=3/WORLD=4`，每段必须 32 bytes。最终 payload 为 `schema:u8=1 + 5*hash32`，`config_hash` 为其 SHA-256。完整世界先调用 `SimulationWorld.configure_config_bundle(bundle)`，通过 `_session.get_manifest().config_hash` 验证最终 Hash；之后必须在同一 Task 精确扩展既有配置方法的 hash 分支：有 bundle 时，`configure_map()` 比较 MAP component，`configure_players()` 比较 `StateHasher.hash_canonical(player_config.encode_canonical())` 与 PLAYER component，`configure_zombie_horde()` 比较 ZOMBIE component，`configure_combat()` 比较 COMBAT component，`configure_world_gameplay()` 比较 WORLD component。没有 bundle 时，Plan 2 保留“session config hash == map hash”、Plan 3 保留“session config hash == map+player combined hash”、Plan 4/5 保留各自聚焦 fixture 规则。任何方法都不得同时要求最终 bundle hash 等于某个单独 component；Plan 6 完整世界缺少 bundle必须拒绝启动。

在 Plan 5 的 `SimPresentationEvent` 类型后固定追加：`BARREL_DAMAGED=8`、`BARREL_EXPLODED=9`、`PLACEMENT_ACCEPTED=10`、`PLACEMENT_REJECTED=11`、`PICKUP_SPAWNED=12`、`PICKUP_COLLECTED=13`、`WAVE_STARTED=14`、`MATCH_DEFEATED=15`、`MATCH_RESTARTED=16`、`CAPACITY_REJECTED=17`。已分配数值后不得重排；新增类型只能追加。所有事件通过 Plan 5 完整签名 `append_presentation_candidate(phase, source_entity_id, source_generation, local_sequence, target_entity_id, target_generation, event_type, origin_x, origin_z, position_x, position_z, heading, value, aux)` 写入，并检查返回值；任何真实实体引用都必须同时携带当前 generation。

事件引用固定为：油桶 damaged/exploded 使用油桶作为 source；放置接受使用玩家作为 source、预留油桶作为 target；放置拒绝使用玩家作为 source、target 为 0/0；pickup spawned 使用生成原因实体作为 source（固定补给为 0/0）、pickup 作为 target；pickup collected 使用玩家作为 source、pickup 作为 target；wave/match 事件没有实体引用时统一为 0/0；capacity rejected 使用触发请求的实体作为 source。不得用旧 generation、slot、Node instance ID 或只写 entity ID 不写 generation。

- [ ] **Step 4：实现固定容量 `BarrelState` 与规范编码**

预分配以下 `PackedInt32Array`：`alive/generation/pos_x/pos_z/heading/state/firearm_hit_count/explosion_tick/owner_player_slot/occupied_cell_id`。`spawn()` 永远扫描最小空 slot；`despawn()` 清零除 generation 外的全部字段；旧 generation ID 不得命中新实体：

```gdscript
enum State { INTACT, DAMAGED, EXPLODING, DESTROYED }
const ENTITY_NAMESPACE := 0x20000000
const INVALID_ENTITY_ID := -1

func entity_id_for_slot(slot: int) -> int:
	return ENTITY_NAMESPACE + slot + 1

func slot_for_entity_id(entity_id: int, expected_generation: int) -> int:
	var slot := entity_id - ENTITY_NAMESPACE - 1
	if slot < 0 or slot >= capacity or alive[slot] == 0 or generation[slot] != expected_generation:
		return -1
	return slot
```

`encode_canonical()` 先写 capacity，再按 slot 升序写全部字段；死槽也写 generation 和其余已清零字段，确保槽位复用历史进入 Hash。`spawn_reserved()` 只接受 command buffer 预先算出的最小空 slot 和 `generation[slot] + 1`，否则返回 `false`；这样阶段 2 可确定 owner ID，但 `alive` 直到阶段 13 commit 才改变。

`WorldEntityCommandBuffer` 定义 `EntityKind { ZOMBIE=1, BARREL=2, PICKUP=3 }` 与 `Operation { SPAWN=1, DESPAWN=2 }`，按 config 的 `entity_command_capacity=1024` 为每列一次性预分配，至少保存 `phase/source_id/source_generation/local_sequence/entity_kind/operation/reserved_slot/reserved_generation/entity_id/pos_x/pos_z/initial_health/initial_rng_state/profile_id/value_a/value_b/value_c`。barrel/pickup reservation 计算时必须把本缓冲内较早命令已占用的 slot 视为不可用；zombie command 完整保存 `spawn_x/spawn_z/initial_health/initial_rng_state/profile_id`，阶段 13 严格调用 Plan 4 `ZombieState.spawn(spawn_x, spawn_z, initial_health, initial_rng_state)`，并验证返回 slot 与预期最小空槽一致。排序、提交、取消和清空都不得 resize；capacity 或目标 state 容量不足时 append 携带原请求 source/generation 的 `CAPACITY_REJECTED`。不允许直接调用 state 的 `spawn()` 绕过阶段 13。

- [ ] **Step 5：把油桶目标与爆炸接入唯一伤害队列**

在 `SimDamageQueue` 追加常量 `TargetKind.BARREL = 3`；复用 Plan 5 已冻结的 `DamageKind.EXPLOSION = 4`。保持 append 签名和排序键 `(phase,source_entity_id,source_generation,local_sequence,target_entity_id,target_generation,target_kind)` 不变；把 `SimDamageResolver.apply_all(tick, queue, players, zombies, equipment, events)` 扩展为 `apply_all(tick, queue, players, zombies, barrels, equipment, events)`，在同一个稳定 apply 循环增加 BARREL 路由。玩家/僵尸目标仍走 Plan 5 原路径，保留玩家受击 knockback、8 Tick 硬直、36 Tick hit lock 与取消 pending knife 的语义：

```gdscript
func _apply_barrel_damage(tick: int, command_index: int, queue: SimDamageQueue, barrels: BarrelState, events: SimEventBuffer) -> bool:
	var barrel_id := queue.target_entity_id_at(command_index)
	var barrel_generation := queue.target_generation_at(command_index)
	var slot := barrels.slot_for_entity_id(barrel_id, barrel_generation)
	if slot < 0 or barrels.state[slot] >= BarrelState.State.EXPLODING:
		return true
	var previous_state := barrels.state[slot]
	if queue.damage_kind_at(command_index) == SimDamageQueue.DamageKind.RANGED:
		barrels.firearm_hit_count[slot] = mini(barrels.firearm_hit_count[slot] + 1, _world_config.barrel_firearm_hits_to_explode)
		if barrels.firearm_hit_count[slot] >= _world_config.barrel_firearm_hits_to_explode:
			barrels.state[slot] = BarrelState.State.EXPLODING
			barrels.explosion_tick[slot] = tick + 1
		elif barrels.firearm_hit_count[slot] >= _world_config.barrel_firearm_hits_to_damage:
			barrels.state[slot] = BarrelState.State.DAMAGED
	elif queue.damage_kind_at(command_index) == SimDamageQueue.DamageKind.EXPLOSION:
		barrels.state[slot] = BarrelState.State.EXPLODING
		barrels.explosion_tick[slot] = tick + _world_config.chain_delay_ticks
	if previous_state == BarrelState.State.INTACT and barrels.state[slot] == BarrelState.State.DAMAGED:
		return events.append_presentation_candidate(
			SimEventBuffer.PHASE_DAMAGE,
			barrel_id, barrel_generation, 0,
			0, 0, SimPresentationEvent.BARREL_DAMAGED,
			barrels.pos_x[slot], barrels.pos_z[slot], barrels.pos_x[slot], barrels.pos_z[slot],
			barrels.heading[slot], barrels.firearm_hit_count[slot], 0
		)
	return true
```

上述 helper 属于 `SimDamageResolver`；resolver 新增可空的 `_world_config` 构造依赖，使 Plan 5 的两参数构造和纯玩家/僵尸测试继续成立，完整 Plan 6 世界必须传入 world config。状态首次变为 `DAMAGED` 时 append 一条 `BARREL_DAMAGED`；重复命中不重复发 damaged 事件。任一事件/队列容量写满时返回 `false`，由 `SimulationWorld.step()` 原样失败，不得扩容或只打印日志。

把 `SimCombatGeometry.collect_ranged_candidates(origin_x: int, origin_z: int, end_x: int, end_z: int, zombies: ZombieState, barrels: BarrelState, map_grid: SimMapGrid, out_candidates: SimHitCandidateBuffer) -> bool` 增加只读 barrel 输入；本 Task 的中间战斗入口精确为 `SimCombatSystem.resolve_attack_phase(tick: int, frame: LocalFrameCommandSet, players: SimPlayerState, zombies: ZombieState, barrels: BarrelState, map_grid: SimMapGrid, equipment: SimEquipmentState, damage_queue: SimDamageQueue, events: SimEventBuffer) -> bool`，Task 2 再在 `equipment` 后插入 inventory 参数。alive 油桶以 `config.barrel_radius_units` 参与线段/圆候选，携带 `target_kind=BARREL`、entity ID、generation 和 `blocks_shot=1`；每个候选调用 `map_grid.has_clear_line(origin_x, origin_z, barrel_x, barrel_z, 0, barrel_id)`，只忽略目标油桶自己的动态 owner。枪械命中油桶后 append `DamageKind.RANGED` 并立即停止本发穿透；更近油桶的动态格仍会阻挡其后的僵尸。匕首不产生油桶候选，以保持现有 `ExplosiveBarrel.apply_hit()` 只累计 firearm hit 的语义。

- [ ] **Step 6：实现阶段 10 的整数爆炸、网格遮挡和 4 Tick 连锁**

`step_explosions()` 按 barrel slot 升序处理 `state == EXPLODING && explosion_tick <= tick`。目标候选按 `(distance_squared, target_kind, target_entity_id, target_generation)` 插入排序；调用 Plan 2 `map_grid.has_clear_line(origin_x, origin_z, target_x, target_z, barrel_id, target_dynamic_owner_id)` 判定整数 supercover 遮挡。端点格遵循 Plan 2 固定规则，只有指定的两个动态 owner 可忽略，静态格永不忽略。伤害只写 Plan 5 队列：

```gdscript
func _damage_at_distance(distance_sq: int) -> int:
	var radius_sq := config.explosion_radius_units * config.explosion_radius_units
	if distance_sq > radius_sq:
		return 0
	var span := config.explosion_center_damage - config.explosion_edge_damage
	return config.explosion_edge_damage + FixedMath.floor_div(span * (radius_sq - distance_sq), radius_sq)

damage_queue.append(
	10,
	barrel_id,
	barrels.generation_for_slot(slot),
	local_sequence,
	target_kind,
	target_id,
	target_generation,
	amount,
	barrels.pos_x[slot],
	barrels.pos_z[slot],
	target_x,
	target_z,
	SimDamageQueue.DamageKind.EXPLOSION
)
```

爆炸完成后状态改为 `DESTROYED`，append 携带油桶 ID/generation 的 `BARREL_EXPLODED`，并向 `WorldEntityCommandBuffer` 写本 Tick 阶段 13 的 despawn；阶段 10 不直接改 `alive`。同时 queue 一个 `tick + 1` 的 `RELEASE` 动态占用变化，因为本 Tick 阶段 3 已结束。`DESTROYED` 油桶在阶段 11 继续被 resolver 视为无效目标，阶段 13 才由 `despawn()` 清字段；爆炸不得直接调用玩家/僵尸/油桶扣血函数。

- [ ] **Step 7：在 `SimulationWorld` 的阶段 10/11 接线并补齐事件读取**

世界完整配置时加载 `demo_arena_world_gameplay.tres`、创建 `BarrelState` 与定长 `WorldEntityCommandBuffer`，并用 `match_generation=0` 与 `derive_stream_seed()` 重设 Plan 1 world-owned `_world_rng/_wave_rng/_drop_rng/_entity_rng`；不得另建同名流。三个初始油桶先 reservation，阶段 3 提交对应 CLAIM，阶段 13 才 `spawn_reserved()`。阶段顺序保持：阶段 10 `barrel_explosion_system.step_explosions()`，阶段 11 唯一一次 `sim_damage_resolver.apply_all(tick, damage_queue, player_state, zombie_state, barrel_state, equipment_state, event_buffer)`；Task 1 的阶段 13 依次调用 `entity_command_buffer.sort_canonical()`、`commit(tick, zombie_state, barrel_state, null, event_buffer)`、`clear()`，Task 2 创建 `PickupState` 后切换为最终 typed commit；阶段 14 仍由 Plan 5 `finalize_presentation_events(tick)` 统一排序和分配 event_id。表现候选复用 Plan 5 在 `configure_combat()` 时一次性配置的 `4096` 容量，Plan 6 不得二次调用 `configure_combat_capacities()` 或缩成 512；world config 验证必须证明单 Tick 最坏世界事件数仍小于 4096，超过时按 Plan 5 规则使 Tick 确定性失败。

- [ ] **Step 8：扩展验证并运行通过**

测试以下固定矩阵：三次枪击阈值；同一 Tick 重复命中不重复事件；A 在 Tick 5 爆炸、B 只在 Tick 9 爆炸；墙后目标无伤害；边缘目标伤害 20；同距离实体 ID 小者先进入队列；爆炸 Tick 后下一 Tick 释放动态 cell；旧 generation damage 被忽略。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/simulation/build_world_gameplay_sim_config.gd -- --output res://resources/simulation/demo_arena_world_gameplay.tres
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_world_gameplay_config.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_barrels_placement.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
! rg -n 'DemoArena\.tscn|ExplosiveBarrel\.tscn|resources/pickups|PhysicsDirectSpaceState3D|NavigationServer3D|RandomNumberGenerator|create_timer' scripts/simulation
! rg -n '[[:space:]]/[[:space:]]' scripts/simulation/gameplay
```

Expected: builder 打印稳定的 64 字符 SHA-256 十六进制 content hash；两个验证分别输出 `PASS`；Headless 导入退出 0；两条反向 `rg` 都因零匹配而整体成功，证明运行时代码不读取旧资源/非确定性系统，且整数商统一调用 `FixedMath.floor_div()`。

### Task 2：实现玩家油桶库存、确定性放置、拾取与死亡掉落

**Files:**
- Create: `scripts/simulation/gameplay/player_inventory_state.gd`
- Create: `scripts/simulation/gameplay/placement_system.gd`
- Create: `scripts/simulation/gameplay/pickup_state.gd`
- Create: `scripts/simulation/gameplay/loot_pickup_system.gd`
- Modify: `scripts/simulation/gameplay/world_entity_command_buffer.gd`
- Modify: `scripts/simulation/gameplay/world_gameplay_sim_config.gd`
- Modify: `resources/simulation/demo_arena_world_gameplay.tres`
- Modify: `scripts/simulation/combat/sim_equipment_state.gd`
- Modify: `scripts/simulation/combat/sim_combat_system.gd`
- Modify: `scripts/simulation/world/simulation_world.gd`
- Create: `tools/validation/validate_frame_sync_loot_inventory.gd`
- Modify: `tools/validation/validate_frame_sync_barrels_placement.gd`

**Interfaces:**
- Consumes: Plan 1 `PlayerFrameCommand.USE_PRESSED/equipment_delta`、Plan 2 map grid/change API、Plan 3 `SimPlayerState`、Plan 5 `SimEquipmentState.grant_weapon()` / `add_ammo()` 与 `SimEventBuffer` death record getters。
- Produces: `PlayerInventoryState.begin_tick(tick: int) -> void`、`get_selected_item(slot: int) -> int`、`apply_equipment_delta(tick: int, frame: LocalFrameCommandSet, players: SimPlayerState, equipment: SimEquipmentState, events: SimEventBuffer) -> bool`、`select_item(slot: int, item_id: int, tick: int, players: SimPlayerState, equipment: SimEquipmentState, events: SimEventBuffer) -> bool`、`get_oil_barrel_count(slot: int) -> int`、`add_oil_barrels(slot: int, amount: int) -> int`、`consume_oil_barrel(slot: int) -> bool`、`reset(active_mask: int) -> void`、`encode_canonical(writer: LittleEndianWriter) -> void`。
- Produces: `PlacementSystem.process_requests(tick: int, frame: LocalFrameCommandSet, players: SimPlayerState, inventory: PlayerInventoryState, barrels: BarrelState, map_grid: SimMapGrid, entity_commands: WorldEntityCommandBuffer, events: SimEventBuffer, queue_map_change: Callable) -> bool`；`SimCombatSystem.resolve_attack_phase(tick: int, frame: LocalFrameCommandSet, players: SimPlayerState, zombies: ZombieState, barrels: BarrelState, map_grid: SimMapGrid, equipment: SimEquipmentState, inventory: PlayerInventoryState, damage_queue: SimDamageQueue, events: SimEventBuffer) -> bool` 最终签名。
- Produces: `PickupState.spawn_reserved(reference: Dictionary, pos_x: int, pos_z: int, kind: int, amount: int, is_fixed_spawner: int, spawner_index: int, occupied_cell_id: int) -> bool`、`despawn(entity_id: int, expected_generation: int, keep_fixed_reservation: bool, respawn_tick: int) -> bool`、`despawn_all() -> void`、`slot_for_entity_id(entity_id: int, expected_generation: int) -> int`、`generation_for_slot(slot: int) -> int`、`encode_canonical(writer: LittleEndianWriter) -> void`；`LootPickupSystem.process_deaths_and_pickups(tick: int, players: SimPlayerState, equipment: SimEquipmentState, inventory: PlayerInventoryState, pickups: PickupState, map_grid: SimMapGrid, drop_rng: ParkMillerRng, entity_commands: WorldEntityCommandBuffer, events: SimEventBuffer, queue_map_change: Callable) -> bool`。
- Produces: `WorldEntityCommandBuffer.reserve_pickup_spawn(phase: int, source_entity_id: int, source_generation: int, local_sequence: int, pickups: PickupState, pos_x: int, pos_z: int, kind: int, amount: int, is_fixed_spawner: int, spawner_index: int, occupied_cell_id: int, forced_slot: int = -1) -> Dictionary`，并把 `commit` 最终收紧为 `commit(tick: int, zombies: ZombieState, barrels: BarrelState, pickups: PickupState, events: SimEventBuffer) -> bool`。

- [ ] **Step 1：先写库存、同格放置和拾取拒绝的失败验证**

验证油桶库存每玩家独立、上限 999、失败放置不扣库存、同 Tick 两玩家争同一 cell 时 slot 0 获胜、成功放置只扣 1。固定补给的奖励契约保持现有资源语义：SMG 装备 `+60` 并自动装备、SMG 弹药 `+90`、油桶 `+30`；未拥有 SMG 时弹药拾取失败且 pickup 保留：

```gdscript
inventory.reset(0b0011)
_assert(inventory.add_oil_barrels(0, 1000) == 999, "oil barrel inventory must cap at 999")
_assert(inventory.add_oil_barrels(1, 2) == 2, "inventory must be per player slot")
inventory.select_item(0, PlayerInventoryState.ITEM_OIL_BARREL, 19, players, equipment, events)
inventory.select_item(1, PlayerInventoryState.ITEM_OIL_BARREL, 19, players, equipment, events)

placement.process_requests(20, frame_with_two_same_cell_requests, players, inventory, barrels, map_grid, entity_commands, events, world.queue_map_change)
_assert(inventory.get_oil_barrel_count(0) == 998, "winning placement consumes exactly one")
_assert(inventory.get_oil_barrel_count(1) == 2, "losing placement consumes nothing")
```

- [ ] **Step 2：运行两个聚焦验证并确认新接口缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_grid.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_movement.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde_replay.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_actions.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_resolution.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_replay.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_world_gameplay_config.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_barrels_placement.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_loot_inventory.gd
```

Expected: 至少一条非零退出，错误指向 `PlayerInventoryState`、`PlacementSystem`、`PickupState` 或 `LootPickupSystem` 缺失。

- [ ] **Step 3：实现四槽油桶库存和整数奖励配置**

`PlayerInventoryState` 预分配长度 4 的 `selected_item`、`oil_barrel_count` 和本 Tick event local sequence；item ID 固定为 `PISTOL=1`、`SMG=2`、`KNIFE=3`、`OIL_BARREL=4`，初始选中手枪。inactive slot 恒为 0；油桶加法返回实际增加量，消费只在数量大于 0 时成功。`begin_tick()` 只重置四槽 sequence，不 resize。`apply_equipment_delta()` 按 item ID 循环并跳过未拥有 SMG 或数量为 0 的油桶；切到武器时调用 `equipment.equip_weapon(slot, item_id, tick)`，切到油桶时保留 Plan 5 的最后武器状态，但 `SimCombatSystem.resolve_attack_phase()` 必须因 `selected_item == OIL_BARREL` 跳过该玩家攻击。油桶耗尽时同 Tick自动循环到下一件可用装备，并用玩家 entity ID/generation 生成一次 `EQUIPMENT_CHANGED`；append 失败使整个阶段返回 `false`。向配置资源加入：

```gdscript
@export var oil_barrel_inventory_max := 999
@export var pickup_claim_radius_units := 768
@export var fixed_pickup_respawn_ticks := 90
@export var fixed_pickup_pos_x := PackedInt32Array([-4608, 0, 4608])
@export var fixed_pickup_pos_z := PackedInt32Array([6144, 9216, 6144])
@export var fixed_pickup_kind := PackedInt32Array([1, 2, 3])
@export var fixed_pickup_amount := PackedInt32Array([60, 90, 30])
@export var drop_chance_numerator := 1
@export var drop_chance_denominator := 5
```

奖励 kind 固定为 `SMG_EQUIPMENT=1`、`SMG_AMMO=2`、`OIL_BARREL=3`；数组顺序同时是随机掉落选择顺序，不能使用 Resource/Dictionary 遍历。

- [ ] **Step 4：实现 slot 升序放置裁决并在阶段 2/3 提交占用**

阶段 2 先由 `PlayerInventoryState.apply_equipment_delta()` 取代 Plan 5 原本直接处理 delta 的世界调用，保证一份输入只切换一次。只有 `selected_item == ITEM_OIL_BARREL`、库存大于 0 且 `USE_PRESSED` 为真时产生放置请求。方向使用 `placement_heading`，其为 0 时回退玩家保留的 `heading`；油桶延续旧玩法放在朝向反面，16 方向相反值固定为 `((heading - 1 + 8) % 16) + 1`。目标 cell 越界、已静态/动态阻挡、被本 Tick 更小 slot 预留或 barrel/command capacity 耗尽时 append 携带玩家 generation 的 `PLACEMENT_REJECTED`，不扣库存：

```gdscript
for player_slot in 4:
	if not players.is_alive(player_slot) or not _requests_barrel(frame.player_commands[player_slot], inventory, player_slot):
		continue
	var heading := _resolved_placement_heading(frame.player_commands[player_slot], players.heading[player_slot])
	var opposite := ((heading - 1 + 8) % 16) + 1
	var cell_id := _adjacent_cell(map_grid, players.pos_x[player_slot], players.pos_z[player_slot], opposite)
	if cell_id < 0 or map_grid.is_cell_blocked(cell_id) or _reserved_epoch[cell_id] == _current_epoch:
		_reject(player_slot, cell_id)
		continue
	var center := map_grid.cell_id_to_center(cell_id)
	var barrel_ref := entity_commands.reserve_barrel_spawn(
		2, players.entity_id_for_slot(player_slot), players.generation_for_slot(player_slot), 0,
		barrels, center.x, center.y, opposite, player_slot, cell_id
	)
	if barrel_ref.is_empty():
		_reject(player_slot, cell_id)
		continue
	_reserved_epoch[cell_id] = _current_epoch
	var change := SimDynamicOccupancyChange.new(tick, players.entity_id_for_slot(player_slot), 0, barrel_ref.entity_id, SimDynamicOccupancyChange.Operation.CLAIM, PackedInt32Array([cell_id]))
	if not queue_map_change.call(change):
		entity_commands.cancel_reserved_spawn(WorldEntityCommandBuffer.EntityKind.BARREL, barrel_ref.entity_id, barrel_ref.generation)
		_reject(player_slot, cell_id)
		continue
	inventory.consume_oil_barrel(player_slot)
	_append_placement_accepted(player_slot, barrel_ref, center, opposite)
```

实现中 `_reserved_epoch` 使用长度为 map cell count 的预分配 `PackedInt32Array` epoch 标记，不使用 Dictionary 遍历。`reserve_barrel_spawn()` 只写 command buffer，不修改 `BarrelState.alive`；库存只在 reservation、map change enqueue 和 `PLACEMENT_ACCEPTED` append 三者都成功后扣 1，任一失败必须撤销本请求的 reservation/change 或在预检查阶段拒绝，不能留下半提交。阶段 3 的 Plan 2 commit 成功后，阶段 4 flow field 原子重建；同 Tick 僵尸读取新障碍；油桶本体到阶段 13 才 alive，因此本 Tick 阶段 9 不能被射击。

- [ ] **Step 5：实现固定容量 `PickupState` 和动态占用生命周期**

SoA 字段固定为 `allocated/alive/generation/pos_x/pos_z/kind/amount/is_fixed_spawner/spawner_index/respawn_tick/occupied_cell_id`。`allocated` 区分“固定 spawner 保留槽”与“可供一次性掉落复用的空槽”：固定补给收集后阶段 13 变为 `allocated=1/alive=0` 并保留 spawner/kind/amount/respawn_tick；随机掉落收集后变为 `allocated=0/alive=0`，仅保留 generation。固定三个补给在 match STARTING 时按 spawner index 升序 reservation 并 CLAIM cell，阶段 13 `spawn_reserved()`；到 `respawn_tick` 时强制复用其保留 slot、generation 加 1，并 queue 下一 Tick CLAIM。spawn/command 容量不足 append `CAPACITY_REJECTED`，不得推进额外随机选择或抢占固定 spawner 槽。

- [ ] **Step 6：以独立 drop PRNG 消费稳定死亡记录**

`LootPickupSystem.process_deaths_and_pickups(tick, players, equipment, inventory, pickups, map_grid, drop_rng, entity_commands, events, queue_map_change)` 显式接收 Plan 1 `SimulationWorld` 已持有的 `_drop_rng: ParkMillerRng`，自身不复制随机状态。它只遍历当 Tick death record，筛选 `victim_kind == ZOMBIE`，并读取 `death_victim_id(index)` 与 `death_victim_generation(index)` 保留完整死亡引用；依 record 已稳定的顺序对每个死亡恰好调用一次 `next_inclusive(1, 5)`，值为 1 才掉落，再调用一次 `next_inclusive(0, 2)` 选择固定奖励表：

```gdscript
for index in event_buffer.death_record_count():
	if event_buffer.death_victim_kind(index) != SimDamageQueue.TargetKind.ZOMBIE:
		continue
	var passed := drop_rng.next_inclusive(1, config.drop_chance_denominator) <= config.drop_chance_numerator
	if not passed:
		continue
	var reward_index := drop_rng.next_inclusive(0, config.fixed_pickup_kind.size() - 1)
	var cell_id := map_grid.world_to_cell_id(event_buffer.death_pos_x(index), event_buffer.death_pos_z(index))
	var pickup_ref := entity_commands.reserve_pickup_spawn(
		12,
		event_buffer.death_victim_id(index), event_buffer.death_victim_generation(index), index,
		pickups,
		event_buffer.death_pos_x(index), event_buffer.death_pos_z(index),
		config.fixed_pickup_kind[reward_index], config.fixed_pickup_amount[reward_index],
		0, -1, cell_id
	)
	if not pickup_ref.is_empty():
		var change := SimDynamicOccupancyChange.new(tick + 1, pickup_ref.entity_id, 0, pickup_ref.entity_id, SimDynamicOccupancyChange.Operation.CLAIM, PackedInt32Array([cell_id]))
		if not queue_map_change.call(change):
			entity_commands.cancel_reserved_spawn(WorldEntityCommandBuffer.EntityKind.PICKUP, pickup_ref.entity_id, pickup_ref.generation)
			return false
```

不得读取 zombie Node 位置，不得为无掉落死亡额外推进 reward selection 随机数。掉落通过概率后，即使 pickup/command capacity 已满，也已经固定消费一次 reward selection；失败只生成 `CAPACITY_REJECTED`，不得回退或重抽 PRNG。固定补给初始生成/重生使用同一 reservation → queue CLAIM → 阶段 13 `spawn_reserved()` 路径；CLAIM enqueue 失败必须调用 `cancel_reserved_spawn()`，不得留下 pending pickup 或占用半提交。

- [ ] **Step 7：按 pickup ID、玩家 slot 稳定处理拾取和奖励拒绝**

每个 alive pickup 按 slot 升序查找半径内存活玩家；距离相同按玩家 entity ID 小者获胜。`SMG_EQUIPMENT` 先调用 `equipment.grant_weapon(slot, SimCombatConfig.WEAPON_SMG, amount)`，成功后因旧资源 `auto_equip=true` 再调用 `inventory.select_item(slot, SimCombatConfig.WEAPON_SMG, tick, players, equipment, events)`；`SMG_AMMO` 调用 `add_ammo()`，油桶调用 `inventory.add_oil_barrels()`。实际增加量为 0 时 pickup 保持 alive 并继续阻挡；成功时先 append 含玩家/pickup 两侧 generation 的 `PICKUP_COLLECTED`，再 queue 下一 Tick RELEASE，并向阶段 13 command buffer 写固定保留或一次性 despawn。任一 enqueue/append 失败时不得授予奖励；实现必须先做容量预检，再原子执行奖励与命令写入。

- [ ] **Step 8：接入固定顺序并运行聚焦验证**

`SimulationWorld.step()` 的阶段 2 调用 placement；阶段 12 在 Plan 5 死亡已经提交后依次调用掉落、拾取、固定补给重生；阶段 13 提交实体 spawn/despawn。验证同格放置、前后方向、地图阻挡、容量耗尽、20% 金样掉落序列、奖励池顺序、满库存不消失、未拥有 SMG 不吃弹药、90 Tick 重生、drop/world/wave RNG 互不推进。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_barrels_placement.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_loot_inventory.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两个验证分别输出 `PASS`，三条命令退出码均为 0。

### Task 3：实现整数波次、全员失败与命令驱动原子重开

**Files:**
- Create: `scripts/simulation/gameplay/match_loop_state.gd`
- Create: `scripts/simulation/gameplay/wave_match_system.gd`
- Modify: `scripts/simulation/gameplay/world_gameplay_sim_config.gd`
- Modify: `resources/simulation/demo_arena_world_gameplay.tres`
- Modify: `scripts/simulation/players/sim_player_state.gd`
- Modify: `scripts/simulation/zombies/zombie_state.gd`
- Modify: `scripts/simulation/world/simulation_world.gd`
- Create: `tools/validation/validate_frame_sync_wave_restart.gd`

**Interfaces:**
- Consumes: Plan 2 `SimMapGrid.reset_dynamic_occupancy(tick: int) -> void`，Plan 3 `SimPlayerState.is_alive()` / 稳定玩家引用，Plan 4 `ZombieState.spawn()` / alive slots，Plan 5 `SimEquipmentState.new(config: SimCombatConfig, session_seed: int)`，Task 1/2 世界实体状态。
- Produces: `SimPlayerState.reset_for_match(config: PlayerSimConfig, map_grid: SimMapGrid) -> Error`，保留 active/entity ID/generation，只复位本局可变字段；`ZombieState.despawn_all() -> void`，逐个失效实体但保留 generation 历史。
- Produces: `MatchLoopState.State { STARTING, RUNNING, DEFEATED }`、`MatchLoopState.reset_for_new_match(start_tick: int) -> void`、`get_match_state() -> int`、`get_match_generation() -> int`；`WaveMatchSystem.step_after_deaths(tick: int, frame: LocalFrameCommandSet, players: SimPlayerState, zombies: ZombieState, map_grid: SimMapGrid, wave_rng: ParkMillerRng, entity_rng: ParkMillerRng, entity_commands: WorldEntityCommandBuffer, events: SimEventBuffer) -> bool` 表示处理成功，`has_restart_request() -> bool` 只读本 Tick 重开请求。
- Produces: `SimulationWorld.configure_world_gameplay(config: WorldGameplaySimConfig) -> bool`，只允许 Tick 0、只调用一次、要求 bundle/map/player/zombie/combat 已按冻结顺序配置并验证 bundle 的 world component hash。

- [ ] **Step 1：先写波次数量、45 Tick 延迟、失败和重开的失败验证**

固定 session seed 与四角坐标，断言第一波每角 1～2 只、总数 4～8、wave number 为 1；RUNNING 时 slot 0 `CONFIRM` 确定性追加一波且受 active 上限约束；杀清后只在 `last_death_tick + 45` 生成下一波；任一玩家存活时不失败；所有 active 玩家死亡时进入 `DEFEATED`；slot 1～3 的 `CONFIRM` 不重开；DEFEATED 时 slot 0 `CONFIRM` 使 `match_generation + 1`、Tick 不回零、玩家/波次/油桶/拾取/库存/地图动态占用回到确定初态：

```gdscript
var tick_before_restart := world.get_next_tick()
_step(world, frame_with_confirm_from_slot(1))
_assert(world.get_match_state() == MatchLoopState.State.DEFEATED, "non-zero slot confirm must not restart")
_step(world, frame_with_confirm_from_slot(0))
_assert(world.get_match_generation() == 1, "slot 0 confirm must advance match generation")
_assert(world.get_next_tick() == tick_before_restart + 2, "restart must not reset simulation tick")
_assert(world.get_match_state() == MatchLoopState.State.STARTING, "restart rebuilds before returning to running")
```

- [ ] **Step 2：运行失败验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_wave_restart.gd
```

Expected: 非零退出，错误指向 `MatchLoopState`、`WaveMatchSystem`、`ZombieState.despawn_all()` 或重开行为缺失；Plan 2 的 `reset_dynamic_occupancy(tick)` 已是冻结依赖，不在本 Task 重写。

- [ ] **Step 3：扩展 DemoArena 整数波次配置**

写入现有场景语义对应的整数配置：

```gdscript
@export var minimum_zombies_per_corner := 1
@export var maximum_zombies_per_corner := 2
@export var maximum_active_zombies := 24
@export var wave_spawn_radius_units := 1792
@export var minimum_spawn_spacing_units := 1126
@export var auto_wave_delay_ticks := 45
@export var wave_spawn_pos_x := PackedInt32Array([-19456, 19456, -19456, 19456])
@export var wave_spawn_pos_z := PackedInt32Array([-14336, -14336, 14336, 14336])
```

spawn radius 和 spacing 分别是 `1.75*1024` 与 `round(1.1*1024)` 的离线整数值；运行时不做浮点换算。玩家出生点与初始生命只读取 Plan 3 `PlayerSimConfig`，Plan 6 配置不复制同一真值。

在本步骤完成最终 `configure_world_gameplay(config)`：验证 `config.validate() == OK`、content hash 等于 `SimulationConfigBundle` 的 world component、`get_next_tick() == 0`、combat/event buffer 已完成 Plan 5 的一次性 4096 容量配置；随后创建 `BarrelState`、`PickupState`、`PlayerInventoryState`、`WorldEntityCommandBuffer`、`PlacementSystem`、`BarrelExplosionSystem`、`LootPickupSystem`、`MatchLoopState` 和 `WaveMatchSystem`，库存按 active mask reset，对局设为 `match_generation=0/STARTING/start_tick=0`，并用该 generation 重设 Plan 1 已有四条 world-owned PRNG。该方法不生成实体、不提交地图变化、不二次配置 `SimEventBuffer`；Tick 0 阶段 2/12/13 走与重开相同的初始 reservation/commit 路径。

普通 DemoArena 配置的 `maximum_active_zombies=24` 是当前玩法语义，不是 100+ 性能上限。Plan 4 的 100/150/256/512 horde benchmark 和 Plan 7/8 的 100+ 表现/资格档使用独立 benchmark/qualification config，不得为压测悄悄修改 `demo_arena_world_gameplay.tres` 的 24 上限；Plan 6 fixture 验证完整生命周期，100+ 性能继续由对应专用档覆盖。

- [ ] **Step 4：实现独立 wave PRNG 和稳定四角生成**

`MatchLoopState` 只保存 `match_generation/state/wave_number/next_wave_tick/start_tick`；`reset_for_new_match(start_tick)` 不修改 `match_generation`，只设 `STARTING`、wave 0、`next_wave_tick=-1` 和给定 start tick。`WaveMatchSystem.step_after_deaths(tick, frame, players, zombies, map_grid, wave_rng, entity_rng, entity_commands, events)` 显式接收 Plan 1 world-owned `_wave_rng` 与 `_entity_rng`，自身不复制随机状态。每角按固定 NW、NE、SW、SE 顺序抽取 1～2；每只最多尝试 16 个候选，每次只由 wave RNG 抽 heading `1..16` 与 radius `0..1792`，使用方向表和 `floor_div` 得到整数位置；地图阻挡或与现存僵尸及本批较早 reservation 的距离平方小于 spacing 时继续，16 次失败使用首个未阻挡 fallback。只有 command buffer 已预检出 zombie slot/capacity 时才由独立 entity RNG 为该只推进一次 seed；容量耗尽 append 携带生成请求 source generation 的 `CAPACITY_REJECTED`，不得推进 entity RNG：

```gdscript
var heading := wave_rng.next_inclusive(1, 16)
var radius := wave_rng.next_inclusive(0, config.wave_spawn_radius_units)
var candidate_x := center_x + FixedMath.floor_div(FixedMath.heading_x(heading) * radius, 1024)
var candidate_z := center_z + FixedMath.floor_div(FixedMath.heading_z(heading) * radius, 1024)
```

所有 spawn 先写固定容量命令缓冲，阶段 13 按完整 canonical key 提交；遍历中不直接改变 zombie alive 数组。`WAVE_STARTED` 只在至少一个 zombie spawn command 成功写入时 append，`value=wave_number`、`aux=本波实际 reservation 数`；事件 source/target 均为 0/0。

- [ ] **Step 5：实现清场延迟与全员失败**

阶段 12 死亡处理后计算 alive zombie count。RUNNING 时 slot 0 `CONFIRM` 复用同一 `_queue_next_wave()`，取消尚未到期的自动 wave Tick，并在 `maximum_active_zombies` 剩余容量内追加新波；其他槽确认无效。RUNNING 且从非零变为零时设置 `next_wave_tick = tick + 45`；只有仍无僵尸、至少一名 active 玩家存活且 `tick >= next_wave_tick` 才自动生成新波。全体 active 玩家死亡立即进入 DEFEATED、清除 `next_wave_tick`、append 一次 `MATCH_DEFEATED`；DEFEATED 不生成波次、不推进额外世界玩法计时，也不消费 wave/drop RNG。

- [ ] **Step 6：实现唯一的 slot 0 CONFIRM 重开与 Tick 末原子重置**

`step_after_deaths()` 在 DEFEATED 时只检查 active slot 0 的 `action_bits & CONFIRM`，处理成功后由 `has_restart_request()` 暴露请求；失败状态的 world 在帧合法性与 `event_buffer.begin_tick()` 之后跳过阶段 2～12 的装备、移动、AI、攻击、爆炸、掉落、拾取和波次计时，只执行该重开检查、阶段 14 finalize 与 Tick 递增。`SimulationWorld` 阶段 13 在本 Tick普通实体命令提交完后执行 `_reset_match_at_tick_end(tick)`：

```gdscript
func _reset_match_at_tick_end(tick: int) -> bool:
	entity_command_buffer.clear()
	damage_queue.clear()
	match_loop_state.match_generation += 1
	map_grid.reset_dynamic_occupancy(tick)
	if player_state.reset_for_match(player_config, map_grid) != OK:
		return false
	equipment_state = SimEquipmentState.new(combat_config, WorldGameplaySimConfig.derive_stream_seed(session.get_session_seed(), WorldGameplaySimConfig.STREAM_COMBAT, match_loop_state.match_generation))
	player_inventory_state.reset(session.get_active_player_mask())
	zombie_state.despawn_all()
	barrel_state.despawn_all()
	pickup_state.despawn_all()
	if not _world_rng.set_state(WorldGameplaySimConfig.derive_stream_seed(session.get_session_seed(), WorldGameplaySimConfig.STREAM_WORLD, match_loop_state.match_generation)):
		return false
	if not _wave_rng.set_state(WorldGameplaySimConfig.derive_stream_seed(session.get_session_seed(), WorldGameplaySimConfig.STREAM_WAVE, match_loop_state.match_generation)):
		return false
	if not _drop_rng.set_state(WorldGameplaySimConfig.derive_stream_seed(session.get_session_seed(), WorldGameplaySimConfig.STREAM_DROP, match_loop_state.match_generation)):
		return false
	if not _entity_rng.set_state(WorldGameplaySimConfig.derive_stream_seed(session.get_session_seed(), WorldGameplaySimConfig.STREAM_ENTITY, match_loop_state.match_generation)):
		return false
	match_loop_state.reset_for_new_match(tick + 1)
	return event_buffer.append_presentation_candidate(13, 0, 0, 0, 0, 0, SimPresentationEvent.MATCH_RESTARTED, 0, 0, 0, 0, 0, match_loop_state.match_generation, 0)
```

`SimPlayerState.reset_for_match()` 验证 config/map 与现有 active mask，保留玩家 `entity_id/generation`，按 Plan 3 出生点恢复 alive、位置、heading、health 并清速度/击退/硬直；不得重新调用 allocator 或把玩家 generation 加 1。`reset_dynamic_occupancy(tick)` 清零动态 owner、丢弃旧 pending change、把动态 revision 递增一次、把全部玩家 flow field 标 dirty，并把下一次合法 commit Tick 设为 `tick + 1`。下一 Tick 的阶段 2 在 `tick == match_loop_state.start_tick` 时 reservation 初始油桶/固定 pickup 并 queue 当 Tick CLAIM，阶段 3 提交，阶段 4 rebuild，阶段 12 reservation 第一波，阶段 13统一 spawn 后进入 RUNNING。世界 `next_tick`、session、manifest、allocator、玩家稳定引用和输入录像位置都不重置；`STREAM_COMBAT` 只用作新 `SimEquipmentState` 内四条玩家战斗 RNG 的确定性 seed，不新增第五条 world-owned PRNG。

重开必须重建所有持有上一局对象引用的纯系统：至少重新绑定 `PlayerMovementSystem`/`SimDamageResolver` 所需状态，或保证它们只通过每 Tick 参数读取当前 `player_state/equipment_state`；验证要覆盖重开后的击退、hit lock、匕首 pending、弹药和散布 RNG 没有泄漏。`SimulationWorld.step()` 必须检查 `_reset_match_at_tick_end()` 返回值；任何 reset 或 `MATCH_RESTARTED` append 失败都不得增加 `next_tick`。

- [ ] **Step 7：规范化失败期间行为并验证重开金样**

失败后的普通帧、其他玩家确认、slot 0 中性帧均不得修改 wave/drop RNG、动态地图、库存或实体 generation；slot 0 确认后的 STARTING Tick 必须得到固定初始实体 ID 和 `WAVE_STARTED` 事件。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_wave_restart.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 验证输出 `validate_frame_sync_wave_restart: PASS`；两条命令退出码均为 0。

### Task 4：完成规范状态、无表现完整循环和 100,000 Tick 双实例门槛

**Files:**
- Create: `scripts/simulation/testing/world_game_loop_fixture.gd`
- Modify: `scripts/simulation/testing/first_divergence_harness.gd`
- Modify: `scripts/simulation/world/simulation_world.gd`
- Create: `tools/validation/validate_frame_sync_world_game_loop_replay.gd`
- Modify: `scripts/simulation/testing/determinism_test_runner.gd`
- Modify: `tools/validation/validate_local_frame_sync_core.gd`

**Interfaces:**
- Consumes: Plan 1 `InputTape` / codec / `StateHasher` / divergence report，Task 1～3 所有规范状态和只读接口。
- Produces: 冻结接口段所列 `WorldGameLoopFixture` 与 `FirstDivergenceHarness.run_world_game_loop_replay()`；保持 Plan 1 `canonical_schema:u8=1` 和既有 section 大类顺序，只在冻结 section hook 内追加 Plan 6 字段。

- [ ] **Step 1：先写无 Node 完整循环的失败回放验证**

fixture 构造 16×16 提交地图、小血量僵尸配置和一名玩家，但仍走真实帧命令、地图、战斗、爆炸、掉落、拾取、波次和重开系统。资格录像固定包含以下检查点：

```gdscript
var tape := WorldGameLoopFixture.build_qualification_tape(0b0001, 100000)
var session := WorldGameLoopFixture.create_session(WorldGameLoopFixture.QUALIFICATION_SEED, 0b0001)
var result := FirstDivergenceHarness.new(session).run_world_game_loop_replay(tape, 100000)
_assert(result.first_divergence_tick == -1, "direct and codec worlds must match every tick")
_assert(result.completed_lifecycle_count >= 2, "replay must complete at least two start-to-restart loops")
_assert(result.observed_barrel_explosion, "replay must exercise barrel explosion")
_assert(result.observed_chain_explosion, "replay must exercise four-tick chain")
_assert(result.observed_placement, "replay must place a dynamic obstacle")
_assert(result.observed_drop_and_pickup, "replay must drop and collect an item")
_assert(result.observed_defeat_and_restart, "replay must defeat all players and restart")
```

- [ ] **Step 2：运行回放并确认 harness API 缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_world_game_loop_replay.gd
```

Expected: 非零退出，指出 `WorldGameLoopFixture` 或 `run_world_game_loop_replay()` 不存在；不得把 100,000 Tick 改为抽样 Hash。

- [ ] **Step 3：在既有 SPEC section 中扩展规范状态编码**

`SimulationWorld.encode_canonical_state()` 保持 Plan 1 已冻结的大类顺序和 Plan 1～5 已有字节，不做“最终重排”，也不把 combat/equipment、动态地图或 PRNG 移到新位置。Plan 6 只扩展既有 section helper；未调用 `configure_config_bundle()`/`configure_world_gameplay()` 的 Plan 1～5 世界必须逐 byte 保持原 canonical golden：

1. 世界头 helper：保留 manifest/session/next tick 原字节并消费 Plan 1 已冻结的 `config_bundle_marker:u8`；Plan 1～5 世界继续写 `0`，完整 bundle 世界写 `1 + bundle_schema:u8=1 + map/player/zombie/combat/world 五段 32-byte component hash + 最终 32-byte config hash`。
2. 玩家 section：Plan 3/5 已有玩家、equipment、combat cooldown/ammo/player RNG 字节保持原位和原顺序；Plan 6 不插入其中。
3. 僵尸 section：Plan 4/5 已有 zombie SoA、实体 RNG 和攻击相关字节保持原位和原顺序；Plan 6 不插入其中。
4. `_encode_other_entity_section(writer)`：在 Plan 5 已有 `combat_state_marker`/combat 字节之后消费 Plan 1 冻结的 `world_entity_marker:u8`。未配置 Plan 6 时仍写 `0` 且不追加字节；完整世界写 `1`，随后写 `world_entity_schema:u8=1`、`BarrelState`、`PickupState`、`PlayerInventoryState`，各自先 capacity，再按 barrel slot、pickup slot、player slot 写全部字段；死槽/未启用槽也编码 generation/零值。combat 子段保持原位。
5. 动态地图 section：继续只调用一次 Plan 2 `encode_canonical_dynamic()`，位置和字节完全不变；Plan 6 不复制 owner 或 revision。
6. PRNG section：继续按 Plan 1 tag 1～4 写 world/wave/drop/entity-spawn；Plan 6 只更新这些既有对象的 state，不追加重复流。玩家战斗和僵尸实体 RNG 保持 Plan 4/5 原位。
7. `_encode_wave_section(writer)`：消费 Plan 1 已冻结的 `wave_marker:u8`。未配置时仍写 `0`；完整世界写 `1 + wave_schema:u8=1 + match generation/state/wave number/next wave tick/start tick/alive zombie count`。
8. `_encode_pending_event_section(writer)`：保留 Plan 1 `pending_event_count`、Plan 4 `zombie_intent` 与 Plan 5 `combat_pending`（damage/death/presentation）的既有字节顺序，再消费 Plan 1 已冻结的 `world_command_marker:u8`。未配置时仍写 `0`；完整世界写 `1 + world_command_schema:u8=1 + WorldEntityCommandBuffer capacity/count/canonical commands`，最后仍由 Plan 1 位置写 debug `last_event_count`；Plan 2 的 pending map changes 只存在 dynamic-map section，不在这里复制，也不得把已 finalized 表现事件再编码一次。

每个数组先写固定 capacity/count，再按 slot 或稳定排序后的 index 写字段。Task 4 先断言 Plan 1 的 `config_bundle_marker/world_entity_marker/wave_marker/world_command_marker` 和 Plan 5 combat markers 在旧世界仍为 0/既有值，重跑 Plan 1～5 canonical Hash 金样完全不变，再为完整 bundle world 新增四个 Plan 6 marker 均为 1 的金样；若旧金样变化，视为 section 插入位置或 marker 使用错误。以下内容明确不编码：Node Transform、动画、音频、粒子、HUD、摄像机、视口、渲染插值、旧 DemoArena 节点和对象实例 ID。

- [ ] **Step 4：实现固定输入 fixture，不用测试专用直接伤害捷径**

`WorldGameLoopFixture.create_world()` 必须构造 map/player/zombie/combat/world config 与 `SimulationConfigBundle`，用 bundle 最终 hash 创建 manifest/session，再严格按 `new → configure_config_bundle → configure_map → configure_players → configure_zombie_horde → configure_combat → configure_world_gameplay` 配置；任一步失败返回 `null` 并保留稳定错误。`build_qualification_tape()` 只生成合法 `LocalFrameCommandSet`：移动到固定补给、切换装备、射击油桶、放置油桶、射击僵尸、收集掉落、等待下一波、让僵尸击败玩家、slot 0 确认重开。未启用槽位写全零；2/4 人 tape 由 slot 升序生成相同脚本并加入同时放置同格与同时拾取竞争。fixture 可以使用较低整数生命/伤害配置缩短循环，但不得直接调用 damage、despawn、grant inventory 或 restart API。

- [ ] **Step 5：实现直接命令/编解码命令双世界逐 Tick比较**

两个世界必须使用相同 session、manifest、map/config 资源和初始 seed；左侧直接 step 原帧，右侧 step `LocalFrameCommandCodec.decode(encode(frame))`。每 Tick 都计算 SHA-256；首个分歧立即返回并导出 tick、22 bytes 输入帧、左右 canonical bytes、首个不同 byte offset、左右事件和各独立 PRNG state：

```gdscript
func run_world_game_loop_replay(tape: InputTape, ticks: int) -> Dictionary:
	var direct := WorldGameLoopFixture.create_world(_session.get_session_seed(), _session.get_active_player_mask())
	var decoded := WorldGameLoopFixture.create_world(_session.get_session_seed(), _session.get_active_player_mask())
	for tick in ticks:
		var frame := tape.get_frame(tick)
		var decoded_frame := LocalFrameCommandCodec.decode(LocalFrameCommandCodec.encode(frame))
		if decoded_frame == null or not direct.step(tick, frame) or not decoded.step(tick, decoded_frame):
			return _world_loop_failure(tick, frame, direct, decoded)
		var left := direct.encode_canonical_state()
		var right := decoded.encode_canonical_state()
		if not StateHasher.equal(StateHasher.hash_canonical(left), StateHasher.hash_canonical(right)):
			return _world_loop_divergence(tick, frame, direct, decoded, left, right)
	return _world_loop_success(direct, ticks)
```

- [ ] **Step 6：加入 1/2/4 人完整循环和重启后继续回放**

聚焦验证先各跑 10,000 Tick，断言每种 active mask 都触发完整生命周期；随后单人跑 100,000 Tick 并逐 Tick Hash。重启至少两次，第二次重启后继续至少 1,000 Tick，防止只验证到 reset 边界。

- [ ] **Step 7：运行 Plan 6 全量自动验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_barrels_placement.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_world_gameplay_config.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_loot_inventory.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_wave_restart.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_world_game_loop_replay.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://scripts/simulation/testing/determinism_test_runner.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: Plan 1～5 回归命令全部退出 0，五个 Plan 6 验证均输出 `PASS`；determinism runner 报告 1/2/4 人直接/codec 世界零分歧；Headless 导入退出 0。任一首次分歧、capacity growth、旧 Node 玩法依赖或非零退出都阻断 Plan 7。

- [ ] **Step 8：验证旧 DemoArena 默认路径完全未变**

Run:

```bash
git diff --exit-code -- scenes/gameplay/DemoArena.tscn scripts/gameplay/demo_arena.gd scripts/props/explosive_barrel.gd scripts/gameplay/place_item_grid.gd scripts/gameplay/place_item_service.gd scripts/gameplay/pickup_chest.gd scripts/gameplay/pickup_spawn_point.gd scripts/gameplay/random_pickup_drop_manager.gd scripts/menu/main_menu.gd scripts/menu/local_multiplayer_lobby.gd
```

Expected: 退出码 0；主菜单和本地多人大厅仍指向 `res://scenes/gameplay/DemoArena.tscn`，Plan 6 只提供旁路 headless/测试入口。

## 规格覆盖复核

- Task 1 覆盖整数油桶、2/3 枪击状态、阶段 10 爆炸、阶段 11 统一伤害、距离平方、网格遮挡、4 Tick 连锁、稳定排序、动态 cell 释放和表现事件。
- Task 2 覆盖放置方向、同格 tie-break、成功才扣库存、动态障碍阶段提交、固定补给、20% 独立掉落流、三种奖励、拾取归属、失败领取保留、90 Tick 重生和每玩家库存。
- Task 3 覆盖四角随机波次、24 active 上限、45 Tick 自动下一波、死亡立即影响 alive count、全员失败、slot 0 CONFIRM、Tick 不归零的原子重开、地图/实体/库存/PRNG 重置。
- Task 4 覆盖无表现节点完整开局→战斗→爆炸/放置→掉落/拾取→波次→失败→重开循环、canonical state、独立 PRNG、逐 Tick SHA-256、首分歧诊断、1/2/4 人和 100,000 Tick 门槛。
- 旧 DemoArena、模型、动画、音频、FX、HUD、输入适配和主菜单默认入口明确不在本计划修改范围；Plan 7 才消费状态/事件建设可选表现路径，Plan 8 通过后才允许默认切换。

## 占位符与类型一致性复核

- 全文没有省略实现项、空白步骤或模糊错误处理；每个新增文件都有单一职责，每个跨 Task API 都在接口段给出准确路径、参数和返回类型。
- `SimulationWorld` 的构造和 `step()` 与 Plan 1 一致；map change 与 Plan 2 一致；玩家 slot/ID 与 Plan 3 一致；ZombieState 与 Plan 4 一致；damage/equipment/death records 与 Plan 5 一致。
- 油桶和拾取 ID namespace、capacity 128、generation/slot 位宽在状态、伤害、事件、动态 owner、Hash 和 Plan 7 读取接口中完全一致。
- 世界事件类型、奖励 kind、伤害 kind 和 match state 都使用只追加的整数常量；后续计划不得重排已有数值。
- 规范状态继续使用 Plan 1 冻结的大类顺序；Plan 6 只把 world header 预留的 `config_bundle_marker` 以及 `world_entity_marker`、`wave_marker`、`world_command_marker` 从 0 切为 1 后写对应 schema/data；Plan 5 的 `combat_state_marker` / `combat_pending_marker` 与全部既有字段不重排。fixture、harness 和 Plan 8 消费同一 `encode_canonical_state()`。

## 执行交接

计划已准备为四个顶层 Task。执行时先询问是否使用隔离 worktree（默认不使用），然后选择：

1. **Subagent-Driven（推荐）**：使用 `subagent-driven-development`，逐 Task 派发与两阶段复核，但整个计划期间不创建独立 Task 提交。
2. **Inline Execution**：使用 `executing-plans`，在当前会话分批执行并设置复核检查点。

整个计划实现和验证全部通过后停止，由用户自行检查并提交。
