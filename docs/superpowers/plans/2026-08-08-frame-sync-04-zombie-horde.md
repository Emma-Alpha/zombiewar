# 帧同步 Plan 4：确定性僵尸群体 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Plan 1～3 已冻结的本地确定性模拟上实现容量固定的僵尸 SoA、流场驱动的群体移动、局部分离和仅含攻击意图的行为循环，并提供 100～150 只僵尸的确定性与性能基线。

**Architecture:** `ZombieState` 将每只僵尸的热状态保存在预分配 SoA 数组；僵尸实体 ID 固定编码为 `(generation << 10) | slot`，因此首个僵尸 ID 为 1024，与 Plan 3 的玩家 ID `1..4` 命名空间不重叠，generation 仍单独保存在 SoA 供过期引用校验。`ZombieHordeSystem` 在 `SimulationWorld.step()` 的僵尸阶段按槽位升序依次选择玩家、读取 `SimFlowFieldSet`、计算移动、以 `SimSpatialHash` 做局部分离，并向 `SimEventBuffer` 写入攻击意图；它绝不结算伤害。`ZombieDebugView` 只读取模拟状态绘制调试线，旧 `ZombieTarget`/`DemoArena` 路径保持不变。

**Tech Stack:** Godot 4.7.1、GDScript、30 Hz 整数 Tick、`PackedInt32Array`、Plan 1 的 `SimulationWorld`/确定性回放 harness、Plan 2 的地图格/流场/空间哈希、Plan 3 的 `SimPlayerState`。

## Global Constraints

- 本计划的前置门槛是 Plan 1、Plan 2、Plan 3 的 Headless、双实例 Hash 和人工验收已通过；缺少任一门槛时不得把本计划接入默认 DemoArena。
- SPEC 是本计划的唯一需求准绳；若本文示例与 SPEC 或已通过门槛的 Plan 1～3 稳定接口冲突，必须先修正文档与实现，禁止另造兼容层掩盖冲突。
- 保持 Plan 1 的 `SimulationWorld.new(session: LocalSimulationSession)`、`step(tick: int, frame: LocalFrameCommandSet) -> bool`、`encode_canonical_state() -> PackedByteArray` 和 `get_last_error() -> String`；`step()` 不接收 delta，Plan 4 只能添加配置僵尸依赖的扩展方法。
- 模拟只使用 XZ 平面整数；1 个 Godot 世界单位等于 1024 模拟单位；中间乘法使用 GDScript `int` 的 int64 范围。
- 热路径只使用预分配 `PackedInt32Array` 或定长数组；僵尸默认容量为 256，压测实例可配置为 512，容量耗尽不得扩容。
- 僵尸状态与分离遍历按 slot 升序；邻居候选、目标 Tie-break、攻击候选排序、事件写入和每玩家攻击名额按稳定实体 ID 升序。generation 复用后 ID 顺序不再等价于 slot 顺序，因此攻击阶段必须显式排序，不得依赖 `Dictionary` 或生成顺序。
- 玩家 ID 固定为 Plan 3 的 `1..4`；僵尸 ID 固定使用低 10 位 slot、高位 generation 的命名空间，首代范围为 `1024..1535`，不得改成从 1 开始的独立 allocator 或与玩家/后续世界实体重叠的裸 ID。
- 僵尸移动、攻击判定与路径读取不得调用 `CharacterBody3D`、Godot Physics 查询、`NavigationAgent3D`、`NavigationServer3D`、`sin`、`cos`、`atan2`、`sqrt` 或浮点 `Vector` 运算。
- 流场缺失、过期或当前位置不可达时，不得选择该玩家作为本 Tick 的追击目标；若没有其他可达玩家，僵尸进入已量化的游荡并在后续 Tick 重新评估，禁止向玩家位置作直线追击降级或永久停留在不可达目标上。
- 每名存活玩家每 Tick 最多获得 16 个僵尸攻击意图；本计划只写意图和冷却，Plan 5 才排序、伤害、死亡与表现事件。
- easy/normal/hard 旧 `resources/difficulty/*.tres` 只允许离线 exporter 读取；运行时只加载 `resources/simulation/zombies/*_sim.tres` 并验证 32-byte content Hash。Plan 6 的 `SimulationConfigBundle` 按冻结顺序把该 Hash 聚合进最终 manifest；Plan 4 不另造不兼容的 manifest 拼接顺序。
- 保留 `scripts/combat/zombie_target.gd`、`scenes/targets/ZombieTarget.tscn` 和当前 `DemoArena` 的旧玩法逻辑，不修改它们。
- 验证脚本置于 `tools/validation/`；长期双实例回放扩展 Plan 1 的 `scripts/simulation/testing/first_divergence_harness.gd`；不引入 Godot 物理驱动的自动化验收。
- 本计划不包含 `git add` 或 `git commit` 步骤；全部实现与验证完成后由用户自行审阅并提交。

---

## 文件结构与稳定接口

| 路径 | 职责 |
| --- | --- |
| `scripts/simulation/zombies/zombie_sim_config.gd` | 只含整数的已提交 Resource、上界校验、32-byte content Hash 和默认 256/压测 512 容量档。 |
| `scripts/simulation/zombies/zombie_sim_config_codec.gd` | 按冻结字段顺序编码整数 payload、计算/验证 SHA-256。 |
| `tools/export/export_zombie_sim_configs.gd` | 离线读取现有 easy/normal/hard difficulty `.tres`，量化并生成模拟资源。 |
| `resources/simulation/zombies/zombie_{easy,normal,hard}_sim.tres` | 运行时唯一允许加载的三份整数僵尸 profile；旧 difficulty 资源只作离线构建源。 |
| `scripts/simulation/zombies/zombie_state.gd` | 槽位分配、generation、稳定实体 ID 与僵尸热 SoA。 |
| `scripts/simulation/zombies/zombie_horde_system.gd` | 目标选择、游荡、流场追击、攻击意图、空间哈希和局部分离。 |
| `scripts/simulation/world/simulation_world.gd` | 持有 `ZombieState`/`ZombieHordeSystem`，在固定系统顺序的僵尸阶段调用它们，并只在 Plan 1 预留的 zombie 与 pending/events hook 编码 SoA 和攻击意图。 |
| `scripts/simulation/events/sim_event_buffer.gd` | 增加定长僵尸攻击意图缓冲；Plan 5 通过其只读索引 API 消费。 |
| `scripts/simulation/testing/first_divergence_harness.gd` | 扩展 Plan 1 的双世界直接/编解码回放，并报告首个状态差异。 |
| `scripts/simulation/view/zombie_debug_view.gd` | 仅从 `ZombieState` 读取位置、朝向、目标和状态，生成调试线。 |
| `scenes/simulation/ZombieDebugView.tscn` | 隔离的旁路调试视图入口，不引用 `ZombieTarget.tscn`。 |
| `tools/validation/validate_frame_sync_zombie_state.gd` | 验证容量、generation、稳定 ID 和容量耗尽。 |
| `tools/validation/validate_frame_sync_zombie_horde.gd` | 验证目标、流场、游荡、攻击名额、分离和无路径行为。 |
| `tools/validation/validate_frame_sync_zombie_integer_division.gd` | 扫描 Plan 4 模拟 runtime，禁止直接 `/`，要求统一使用 `FixedMath.floor_div()`。 |
| `tools/validation/validate_frame_sync_zombie_horde_replay.gd` | 验证 150 只僵尸的 10,000/100,000 Tick 双实例回放。 |
| `tools/validation/validate_frame_sync_zombie_horde_benchmark.gd` | 输出 100、150、256、512 档的 P50/P95/P99 模拟 Tick 报告。 |
| `scripts/simulation/testing/zombie_horde_benchmark.gd` | Headless 与目标设备共用的预热、采样、分位数和容量签名逻辑。 |
| `scripts/simulation/testing/zombie_horde_benchmark_runner.gd` | 可导出的目标设备入口，打印 context 与四档 JSON Lines 并返回总判定。 |
| `scenes/simulation/ZombieHordeBenchmark.tscn` | 最低目标 Web/移动设备手工启动的隔离 benchmark 场景。 |

### 供后续计划消费的接口

Plan 4 完成后，Plan 5 只能通过下面的接口读取僵尸攻击候选；它不得以旧 `ZombieTarget` 或 Godot 节点查询模拟目标：

`scripts/simulation/zombies/zombie_state.gd` 公开 `INVALID_ENTITY_ID := -1`、`ENTITY_ID_SLOT_BITS := 10`、`ENTITY_ID_SLOT_MASK := 1023`，并提供 `alive`、`generation`、`pos_x`、`pos_z`、`velocity_x`、`velocity_z`、`heading`、`health`、`state`、`target_id`、`cooldown_tick`、`rng_state`、`wander_target_x`、`wander_target_z`、`wander_has_target` 这些定长 SoA 字段；查询接口固定为 `is_alive(slot: int) -> bool`、`entity_id_for_slot(slot: int) -> int`、`generation_for_slot(slot: int) -> int`、`slot_for_entity_id(entity_id: int, expected_generation: int) -> int`。

`scripts/simulation/events/sim_event_buffer.gd` 公开 `append_zombie_attack_intent(source_entity_id: int, source_generation: int, target_entity_id: int) -> bool`、`zombie_attack_intent_count() -> int`、`zombie_attack_intent_source_id(index: int) -> int`、`zombie_attack_intent_source_generation(index: int) -> int`、`zombie_attack_intent_target_id(index: int) -> int`。append 在容量耗尽时返回 `false`，不能只记录非确定性日志后继续推进冷却。

`ZombieHordeSystem.step()` 的唯一写入外部副作用是以上攻击意图 API；只有 append 返回 `true` 时才把该槽位的 `cooldown_tick` 推进到 `tick + attack_cooldown_ticks`。Plan 5 按意图索引升序读取，并用 source ID 与 generation 验证引用仍然有效，再在自己的伤害阶段结算生命、死亡和表现事件。

规范状态接缝也冻结为两处：`_encode_zombie_section(writer)` 只编码 Zombie config 与 `ZombieState` SoA；`_encode_pending_event_section(writer)` 的子段顺序固定为 `pending_event_count → zombie_intent_marker → combat_pending_marker → world_command_marker → last_event_count`，本计划只填充其中 zombie intent 子段。未配置群体时保留 Plan 1 的 `zombie_marker:u8 = 0 + zombie_slot_count:u16 = 0` 与 `zombie_intent_marker:u8 = 0`；配置后 marker 变为 1 并跟随各自 schema，禁止把攻击意图塞进 zombie section 或完整 canonical bytes 尾部。

### Task 1：建立整数配置、固定容量 SoA 与稳定实体 ID

**文件：**

- 创建：`scripts/simulation/zombies/zombie_sim_config.gd`
- 创建：`scripts/simulation/zombies/zombie_sim_config_codec.gd`
- 创建：`scripts/simulation/zombies/zombie_state.gd`
- 创建：`tools/export/export_zombie_sim_configs.gd`
- 创建：`resources/simulation/zombies/zombie_easy_sim.tres`
- 创建：`resources/simulation/zombies/zombie_normal_sim.tres`
- 创建：`resources/simulation/zombies/zombie_hard_sim.tres`
- 创建：`tools/validation/validate_frame_sync_zombie_state.gd`

**接口：**

- 消费：Plan 1 的 Park–Miller 初始随机种子规则、`LittleEndianWriter` 与规范状态编码约定；Plan 3 的玩家 ID 固定为 `slot + 1`（`1..4`）。
- 产出：`ZombieSimConfig.load_profile(profile_id: int) -> ZombieSimConfig`、`default_config() -> ZombieSimConfig`、`benchmark_config() -> ZombieSimConfig`、`validate_values() -> Error`、`get_content_hash() -> PackedByteArray`；`ZombieSimConfigCodec.encode_payload(config: ZombieSimConfig) -> PackedByteArray`、`compute_hash(config: ZombieSimConfig) -> PackedByteArray`、`validate_content_hash(config: ZombieSimConfig) -> bool`；`ZombieSimConfigExporter.build_all_in_memory() -> Dictionary`、`export_all() -> bool`。
- 产出：`ZombieState.new(capacity: int)`、`spawn(spawn_x: int, spawn_z: int, initial_health: int, initial_rng_state: int) -> Dictionary`（成功为 `{ "entity_id": int, "generation": int, "slot": int }`，容量耗尽为空字典）、`despawn(entity_id: int, expected_generation: int) -> bool`、`get_capacity_signature() -> PackedInt32Array`、本节列出的 SoA 字段和稳定 ID 查询 API。

- [ ] **步骤 1：先写失败的容量、generation 与 ID 验证**

创建 `tools/validation/validate_frame_sync_zombie_state.gd`，在尚未提供类型时使加载失败，并固定首个槽位复用规则：

```gdscript
extends SceneTree

const ZombieSimConfig = preload("res://scripts/simulation/zombies/zombie_sim_config.gd")
const ZombieSimConfigCodec = preload("res://scripts/simulation/zombies/zombie_sim_config_codec.gd")
const ZombieState = preload("res://scripts/simulation/zombies/zombie_state.gd")
const ZombieSimConfigExporter = preload("res://tools/export/export_zombie_sim_configs.gd")

func _init() -> void:
	var config := ZombieSimConfig.default_config()
	_assert(config.capacity == 256, "默认容量必须是 256")
	_assert(config.profile_id == ZombieSimConfig.Profile.NORMAL, "默认运行时 profile 必须是已提交的 normal 整数资源")
	_assert(config.move_speed_per_tick == 44, "normal 1.3 units/s 必须离线量化为 44 units/tick")
	_assert(ZombieSimConfig.load_profile(ZombieSimConfig.Profile.EASY).move_speed_per_tick == 31, "easy 速度量化金样必须为 31")
	_assert(ZombieSimConfig.load_profile(ZombieSimConfig.Profile.HARD).move_speed_per_tick == 61, "hard 速度量化金样必须为 61")
	_assert(ZombieSimConfigCodec.validate_content_hash(config), "已提交 normal profile Hash 必须有效")
	var first_build := ZombieSimConfigExporter.build_all_in_memory()
	var second_build := ZombieSimConfigExporter.build_all_in_memory()
	for profile_id in [ZombieSimConfig.Profile.EASY, ZombieSimConfig.Profile.NORMAL, ZombieSimConfig.Profile.HARD]:
		_assert(ZombieSimConfigCodec.encode_payload(first_build[profile_id]) == ZombieSimConfigCodec.encode_payload(second_build[profile_id]), "重复导出 payload 必须一致")
		_assert(first_build[profile_id].get_content_hash() == second_build[profile_id].get_content_hash(), "重复导出 Hash 必须一致")
	_assert(ZombieSimConfig.benchmark_config().capacity == 512, "压测容量必须是 512")
	var zombies := ZombieState.new(2)
	var first := zombies.spawn(1024, -2048, 50, 17)
	_assert(first == {"entity_id": 1024, "generation": 1, "slot": 0}, "首个僵尸 ID 必须从 1024 开始，不能与玩家 ID 冲突")
	_assert(zombies.despawn(first.entity_id, first.generation), "首次实体必须可销毁")
	var reused := zombies.spawn(0, 0, 50, 19)
	_assert(reused == {"entity_id": 2048, "generation": 2, "slot": 0}, "复用 slot 0 时 generation 与实体 ID 高位都必须递增")
	_assert(zombies.slot_for_entity_id(first.entity_id, first.generation) == -1, "旧 generation 必须失效")
	var second := zombies.spawn(0, 0, 50, 23)
	_assert(second == {"entity_id": 1025, "generation": 1, "slot": 1}, "slot 1 首代 ID 必须为 1025")
	_assert(zombies.spawn(0, 0, 50, 29).is_empty(), "容量耗尽不得扩容")
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

预期：进程非零退出，错误指向缺少 config/codec/exporter、三份已提交整数资源或 `zombie_state.gd`；不得以运行时回读 `resources/difficulty/*.tres` 或跳过断言掩盖失败。

- [ ] **步骤 3：实现只含整数的配置与 SoA 分配**

创建 Resource 配置。运行时字段只允许 `int` 与 32-byte `PackedByteArray content_hash`；profile 也用整数枚举，只有离线 exporter 可以读取旧浮点 difficulty 资源和字符串路径：

```gdscript
# scripts/simulation/zombies/zombie_sim_config.gd
extends Resource
class_name ZombieSimConfig

const DEFAULT_CAPACITY := 256
const BENCHMARK_CAPACITY := 512
const MAX_HEALTH := 1_000_000
const MAX_DISTANCE_UNITS := 1_048_576
const MAX_SPEED_PER_TICK := 65_536
const MAX_COOLDOWN_TICKS := 1_000_000
enum Profile { EASY = 1, NORMAL = 2, HARD = 3 }
const PROFILE_PATHS := {
	Profile.EASY: "res://resources/simulation/zombies/zombie_easy_sim.tres",
	Profile.NORMAL: "res://resources/simulation/zombies/zombie_normal_sim.tres",
	Profile.HARD: "res://resources/simulation/zombies/zombie_hard_sim.tres",
}

@export var schema_version := 1
@export var profile_id := Profile.NORMAL
@export var capacity := DEFAULT_CAPACITY
@export var health := 50
@export var radius_units := 410
@export var move_speed_per_tick := 44
@export var perception_range_units := 7168
@export var attack_range_units := 1485
@export var attack_cooldown_ticks := 42
@export var wander_speed_per_tick := 19
@export var wander_radius_units := 3584
@export var wander_arrive_units := 256
@export var separation_radius_units := 820
@export var separation_push_per_tick := 24
@export var content_hash := PackedByteArray()

static func load_profile(requested_profile_id: int) -> ZombieSimConfig:
	if not PROFILE_PATHS.has(requested_profile_id):
		return null
	return load(PROFILE_PATHS[requested_profile_id]) as ZombieSimConfig

static func default_config() -> ZombieSimConfig:
	return load_profile(Profile.NORMAL)

static func benchmark_config() -> ZombieSimConfig:
	var config := default_config().duplicate(true) as ZombieSimConfig
	config.capacity = BENCHMARK_CAPACITY
	config.content_hash = ZombieSimConfigCodec.compute_hash(config)
	return config

func validate_values() -> Error:
	if schema_version != 1:
		return ERR_UNAVAILABLE
	if profile_id < Profile.EASY or profile_id > Profile.HARD:
		return ERR_INVALID_PARAMETER
	if capacity < 1 or capacity > BENCHMARK_CAPACITY:
		return ERR_INVALID_PARAMETER
	if health < 1 or health > MAX_HEALTH:
		return ERR_INVALID_PARAMETER
	if radius_units < 1 or radius_units > MAX_DISTANCE_UNITS:
		return ERR_INVALID_PARAMETER
	if move_speed_per_tick < 0 or move_speed_per_tick > MAX_SPEED_PER_TICK:
		return ERR_INVALID_PARAMETER
	if perception_range_units < attack_range_units or perception_range_units > MAX_DISTANCE_UNITS:
		return ERR_INVALID_PARAMETER
	if attack_range_units < 1 or attack_range_units > MAX_DISTANCE_UNITS:
		return ERR_INVALID_PARAMETER
	if attack_cooldown_ticks < 1 or attack_cooldown_ticks > MAX_COOLDOWN_TICKS:
		return ERR_INVALID_PARAMETER
	if wander_speed_per_tick < 0 or wander_speed_per_tick > MAX_SPEED_PER_TICK:
		return ERR_INVALID_PARAMETER
	if wander_radius_units < wander_arrive_units or wander_radius_units > MAX_DISTANCE_UNITS or wander_arrive_units < 0:
		return ERR_INVALID_PARAMETER
	if separation_radius_units < 1 or separation_radius_units > MAX_DISTANCE_UNITS:
		return ERR_INVALID_PARAMETER
	if separation_push_per_tick < 0 or separation_push_per_tick > MAX_SPEED_PER_TICK:
		return ERR_INVALID_PARAMETER
	return OK

func get_content_hash() -> PackedByteArray:
	return content_hash.duplicate()
```

`ZombieSimConfigCodec.encode_payload()` 用 `LittleEndianWriter` 固定写入 schema `u8`，随后按顺序写 profile ID、capacity、health、radius、chase move speed、perception、attack range、attack cooldown、wander speed、wander radius、wander arrive、separation radius、separation push（全部 `i32`）；不得编码 `content_hash` 或任何字符串。`compute_hash()` 对 payload 计算 Plan 1 `StateHasher.hash_canonical()`；`validate_content_hash()` 要求 `validate_values() == OK`、Hash 长度 32 且与重算值相等。

这些上界是模拟输入契约，不是调参建议：距离/速度/生命/冷却超过常量时必须在本局创建前失败，避免距离平方、位置偏移和 Tick 加法依赖整数回绕。验证脚本要分别篡改 schema、perception、wander radius、speed、health 与 cooldown 到上界外，断言 `validate_values()` 和 content Hash 校验都失败。

```gdscript
static func encode_payload(config: ZombieSimConfig) -> PackedByteArray:
	var writer := LittleEndianWriter.new()
	writer.write_u8(config.schema_version)
	for value in [config.profile_id, config.capacity, config.health, config.radius_units, config.move_speed_per_tick, config.perception_range_units, config.attack_range_units, config.attack_cooldown_ticks, config.wander_speed_per_tick, config.wander_radius_units, config.wander_arrive_units, config.separation_radius_units, config.separation_push_per_tick]:
		writer.write_i32(value)
	return writer.to_bytes()

static func validate_content_hash(config: ZombieSimConfig) -> bool:
	return config != null and config.validate_values() == OK and config.content_hash.size() == 32 and StateHasher.equal(config.content_hash, compute_hash(config))
```

离线 exporter 固定映射并输出三份资源：

```gdscript
const SOURCE_PATHS := {
	ZombieSimConfig.Profile.EASY: "res://resources/difficulty/zombie_easy.tres",
	ZombieSimConfig.Profile.NORMAL: "res://resources/difficulty/zombie_normal.tres",
	ZombieSimConfig.Profile.HARD: "res://resources/difficulty/zombie_hard.tres",
}

static func _speed_per_tick(source_units_per_second: float) -> int:
	return roundi(source_units_per_second * 1024.0 / 30.0)

func _build_profile(profile_id: int, source: ZombieDifficultyProfile) -> ZombieSimConfig:
	var config := ZombieSimConfig.new()
	config.profile_id = profile_id
	config.move_speed_per_tick = _speed_per_tick(source.perception_move_speed)
	config.content_hash = ZombieSimConfigCodec.compute_hash(config)
	return config
```

`build_all_in_memory()` 按 easy、normal、hard 固定顺序加载源，要求脚本类为 `ZombieDifficultyProfile`，并返回以 profile ID 为键的三项 Dictionary；`export_all()` 消费该结果，要求每项 `validate_content_hash()` 为 true，再用 `ResourceSaver.save()` 写入 `PROFILE_PATHS` 对应路径。基础整数来自当前旧 `ZombieTarget` 的冻结量化：health 50、radius 410、perception 7168、attack range 1485、attack cooldown 42、wander speed 19、wander radius 3584、wander arrive 256、separation radius 820、separation push 24；运行时不加载 `zombie_target.gd` 或旧 difficulty 资源。

实现完成后生成三份待提交资源：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/export/export_zombie_sim_configs.gd -- --write
```

预期：仅创建或更新 `resources/simulation/zombies/zombie_easy_sim.tres`、`zombie_normal_sim.tres`、`zombie_hard_sim.tres`，输出每个 profile 的 64 字符 SHA-256 hex；不得修改三个旧 difficulty 源。

创建 `ZombieState`，使用槽位 0～511。generation 从 1 起始；slot 使用实体 ID 的低 10 位，generation 使用高位，因此玩家 `1..4` 与首代僵尸 `1024..1535` 不重叠：

```gdscript
# scripts/simulation/zombies/zombie_state.gd
extends RefCounted
class_name ZombieState

const INVALID_ENTITY_ID := -1
const ENTITY_ID_SLOT_BITS := 10
const ENTITY_ID_SLOT_MASK := (1 << ENTITY_ID_SLOT_BITS) - 1
const MAX_GENERATION := 2_097_151
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
var wander_target_x := PackedInt32Array()
var wander_target_z := PackedInt32Array()
var wander_has_target := PackedInt32Array()

func _init(initial_capacity: int) -> void:
	assert(initial_capacity >= 1 and initial_capacity <= 512)
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
	wander_target_x.resize(capacity)
	wander_target_z.resize(capacity)
	wander_has_target.resize(capacity)
	for slot in capacity:
		target_id[slot] = INVALID_ENTITY_ID

func spawn(spawn_x: int, spawn_z: int, initial_health: int, initial_rng_state: int) -> Dictionary:
	for slot in capacity:
		if alive[slot] != 0:
			continue
		if generation[slot] >= MAX_GENERATION:
			continue
		generation[slot] += 1
		alive[slot] = 1
		pos_x[slot] = spawn_x
		pos_z[slot] = spawn_z
		health[slot] = initial_health
		rng_state[slot] = initial_rng_state
		target_id[slot] = INVALID_ENTITY_ID
		return {"entity_id": entity_id_for_slot(slot), "generation": generation[slot], "slot": slot}
	return {}

func entity_id_for_slot(slot: int) -> int:
	return (generation[slot] << ENTITY_ID_SLOT_BITS) | slot if is_alive(slot) else INVALID_ENTITY_ID
```

`spawn()` 必须拒绝不在 `1..2147483646` 的 Park–Miller 种子。补齐 `despawn()`、`is_alive()`、`generation_for_slot()` 与 `slot_for_entity_id()`：slot 用 `entity_id & ENTITY_ID_SLOT_MASK` 解码，ID 中的 generation 用 `entity_id >> ENTITY_ID_SLOT_BITS` 解码；两者必须与 `expected_generation`、SoA generation、slot 范围及 alive 同时匹配，否则返回 `-1`。`despawn()` 成功后只保留该 slot 的 generation，`alive`、位置、速度、朝向、生命、状态、目标、冷却、RNG 和三个游荡字段全部归零（`target_id` 恢复 `INVALID_ENTITY_ID`），避免死亡历史或上一局状态泄漏到复用槽位；死亡位置必须由 Plan 5 在调用 `despawn()` 前复制进事件。`get_capacity_signature()` 按字段声明顺序返回 15 个 SoA 的 `.size()`，只用于验证且不得返回数组本身。

- [ ] **步骤 4：运行状态验证与 Headless 导入检查**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_state.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/export/export_zombie_sim_configs.gd -- --check
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

预期：三个命令均以 0 退出；exporter 的 `--check` 在内存重建三份 profile 并逐字段比较已提交资源，不写文件，输出 `zombie sim config export: CHECK PASS`。验证涵盖 easy/normal/hard 速度金样、重复 payload/Hash、非法 schema/数值上界、默认 256、512 压测档、首代 ID 命名空间、slot 复用 generation 递增、失效旧引用和容量耗尽。generation 达到 `2_097_151` 后该 slot 不得再复用，避免打包 ID 超出正 int32；不得回绕。

### Task 2：实现确定性目标、游荡、流场追击与局部分离

**文件：**

- 创建：`scripts/simulation/zombies/zombie_horde_system.gd`
- 创建：`scripts/simulation/events/sim_event_buffer.gd`
- 创建：`tools/validation/validate_frame_sync_zombie_horde.gd`
- 创建：`tools/validation/validate_frame_sync_zombie_integer_division.gd`

**接口：**

- 消费：Plan 2 的 `SimMapGrid.move_circle_x_then_z(x: int, z: int, radius: int, delta_x: int, delta_z: int) -> Vector2i`、`SimFlowFieldSet.field_for_slot(slot: int) -> SimFlowField`、`SimFlowField.is_reachable(x: int, z: int) -> bool`、`next_step(x: int, z: int) -> Vector2i`，以及 `SimSpatialHash.query_3x3_sorted(x: int, z: int) -> int`、`query_count() -> int`、`query_entity_id(index: int) -> int`。
- 消费：Plan 3 的 `SimPlayerState.is_alive(slot: int) -> bool`、`entity_id_for_slot(slot: int) -> int`、`pos_x[slot]`、`pos_z[slot]`，玩家槽位恒为 0～3。
- 产出：`ZombieHordeSystem.new(config: ZombieSimConfig, zombies: ZombieState)`、`spawn(spawn_x: int, spawn_z: int, rng_seed: int) -> Dictionary`、`step(tick: int, players: SimPlayerState, map_grid: SimMapGrid, flow_fields: SimFlowFieldSet, spatial_hash: SimSpatialHash, events: SimEventBuffer) -> bool`、`get_capacity_signature() -> PackedInt32Array`；任何固定容量缓冲写入失败时返回 `false`，由 `SimulationWorld.step()` 传播错误且不假装本 Tick 成功。
- 产出：`SimEventBuffer.new(zombie_attack_capacity: int)`、`begin_tick(tick: int) -> void`、`get_capacity_signature() -> PackedInt32Array` 和「供后续计划消费的接口」列出的五个攻击意图 append/getter 方法。

- [ ] **步骤 1：写失败的行为矩阵验证**

在 `validate_frame_sync_zombie_horde.gd` 使用 Plan 2 的真实 `SimMapGrid`/`SimFlowFieldSet` 构造 9×5 小地图：`cell_x = 4` 是没有缺口的整列静态墙，僵尸与两个初始玩家位于左侧连通区，右侧为不可达岛。初始僵尸在 `(768, 1280)`，slot 0/1 玩家分别在 `(1792, 768)` 与 `(1792, 1792)`，两者距离相同；验证只能调用公开的 `set_target_cell()`/`rebuild_dirty_atomic()` 改变流场，不给测试夹具添加生产接口不存在的可达性捷径：

```gdscript
players.pos_x[0] = 1792
players.pos_z[0] = 768
players.pos_x[1] = 1792
players.pos_z[1] = 1792
_assert(fields.set_target_cell(0, map_grid.world_to_cell_id(players.pos_x[0], players.pos_z[0])), "slot 0 初始目标必须可设置")
_assert(fields.set_target_cell(1, map_grid.world_to_cell_id(players.pos_x[1], players.pos_z[1])), "slot 1 初始目标必须可设置")
_assert(fields.rebuild_dirty_atomic(map_grid), "初始双玩家流场必须同步构建")

var zombie_ref := horde.spawn(768, 1280, 17)
_assert(not zombie_ref.is_empty(), "行为测试僵尸必须成功生成")
events.begin_tick(1)
_assert(horde.step(1, players, map_grid, fields, spatial_hash, events), "Tick 1 群体推进必须成功")
_assert(zombies.target_id[0] == players.entity_id_for_slot(0), "距离相同必须选较小玩家实体 ID")
_assert(zombies.state[0] == ZombieHordeSystem.State.CHASE, "可达且感知到玩家必须进入追击")

players.pos_x[0] = 3328
players.pos_z[0] = 768
_assert(fields.set_target_cell(0, map_grid.world_to_cell_id(players.pos_x[0], players.pos_z[0])), "slot 0 目标必须可移到不可达岛")
_assert(fields.rebuild_dirty_atomic(map_grid), "目标跨到不可达岛后必须原子重建")
var before := Vector2i(zombies.pos_x[0], zombies.pos_z[0])
events.begin_tick(2)
_assert(horde.step(2, players, map_grid, fields, spatial_hash, events), "无路径 Tick 仍必须确定性成功")
_assert(zombies.target_id[0] == players.entity_id_for_slot(1), "最近玩家不可达时必须改选仍可达的玩家")
_assert(Vector2i(zombies.pos_x[0], zombies.pos_z[0]) != before, "存在可达玩家时不得永久停在不可达目标上")

players.pos_x[1] = 3328
players.pos_z[1] = 1792
_assert(fields.set_target_cell(1, map_grid.world_to_cell_id(players.pos_x[1], players.pos_z[1])), "slot 1 目标也必须可移到不可达岛")
_assert(fields.rebuild_dirty_atomic(map_grid), "所有目标位于不可达岛时仍必须构建完整场")
before = Vector2i(zombies.pos_x[0], zombies.pos_z[0])
events.begin_tick(3)
_assert(horde.step(3, players, map_grid, fields, spatial_hash, events), "所有玩家不可达时仍必须确定性成功")
_assert(zombies.target_id[0] == ZombieState.INVALID_ENTITY_ID, "所有玩家不可达时必须清除追击目标")
_assert(zombies.state[0] == ZombieHordeSystem.State.WANDER, "所有玩家不可达时必须进入量化游荡")

players.pos_x[0] = zombies.pos_x[0] + 900
players.pos_z[0] = zombies.pos_z[0]
_assert(fields.set_target_cell(0, map_grid.world_to_cell_id(players.pos_x[0], players.pos_z[0])), "攻击玩家目标必须移回左侧连通区")
_assert(fields.rebuild_dirty_atomic(map_grid), "攻击前必须重建可达流场")
events.begin_tick(4)
_assert(horde.step(4, players, map_grid, fields, spatial_hash, events), "攻击意图 Tick 必须成功")
_assert(events.zombie_attack_intent_count() == 1, "一只就绪僵尸每 Tick 只能写入一个攻击意图")
_assert(events.zombie_attack_intent_source_id(0) == zombie_ref.entity_id, "攻击来源 ID 必须稳定")
_assert(events.zombie_attack_intent_source_generation(0) == zombie_ref.generation, "攻击来源 generation 必须稳定")
```

同一脚本必须另建 17 只同距离、同 cooldown 的僵尸并断言只写入来源实体 ID 最小的 16 条意图；再销毁并复用 slot 0，使其 ID 为 2048，同时保留 slot 1 首代 ID 1025，断言事件顺序为 1025 后 2048，证明 generation 复用后没有误用 slot 顺序。创建两只重叠僵尸并断言分离后的坐标不相同；再让空间哈希夹具以逆序插入相同实体，断言 `query_3x3_sorted()` 的候选 ID 和最终规范状态仍与正序插入一致。生成顺序本身会决定稳定 ID，不要求不同生成顺序产生相同状态。

- [ ] **步骤 2：运行验证并确认其因缺少群体系统失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde.gd
```

预期：进程非零退出，错误指向缺少 `ZombieHordeSystem`、`SimEventBuffer` 或其方法；未实现的流场夹具、攻击名额或分离断言不得被条件跳过。

- [ ] **步骤 3：写入固定状态机与目标选择**

在 `ZombieHordeSystem` 定义只含整数状态，并按僵尸 slot 升序选择感知范围内、当前位置在对应 Flow Field 可达的最近存活玩家；距离相同按玩家实体 ID 小者胜出。不可达玩家不进入候选，因此最近玩家隔绝时仍可改选其他可达玩家；没有可达候选时返回 `INVALID_ENTITY_ID`：

```gdscript
extends RefCounted
class_name ZombieHordeSystem

enum State { WANDER, CHASE, ATTACK }
const MAX_ATTACK_INTENTS_PER_PLAYER := 16

var config: ZombieSimConfig
var zombies: ZombieState
var _attack_slots := PackedInt32Array([0, 0, 0, 0])
var _tick_start_x := PackedInt32Array()
var _tick_start_z := PackedInt32Array()
var _separation_x := PackedInt32Array()
var _separation_z := PackedInt32Array()
var _attack_candidate_slots := PackedInt32Array()
var _attack_candidate_count := 0
var _wander_rng_scratch := ParkMillerRng.new(1)

func _init(initial_config: ZombieSimConfig, initial_zombies: ZombieState) -> void:
	config = initial_config
	zombies = initial_zombies
	_tick_start_x.resize(zombies.capacity)
	_tick_start_z.resize(zombies.capacity)
	_separation_x.resize(zombies.capacity)
	_separation_z.resize(zombies.capacity)
	_attack_candidate_slots.resize(zombies.capacity)

func _select_target(slot: int, players: SimPlayerState, fields: SimFlowFieldSet) -> int:
	var best_id := ZombieState.INVALID_ENTITY_ID
	var best_distance_sq := 0
	for player_slot in 4:
		if not players.is_alive(player_slot):
			continue
		var dx := players.pos_x[player_slot] - zombies.pos_x[slot]
		var dz := players.pos_z[player_slot] - zombies.pos_z[slot]
		var distance_sq := dx * dx + dz * dz
		if distance_sq > config.perception_range_units * config.perception_range_units:
			continue
		var field := fields.field_for_slot(player_slot)
		if field == null or not field.is_reachable(zombies.pos_x[slot], zombies.pos_z[slot]):
			continue
		var player_id := players.entity_id_for_slot(player_slot)
		if best_id == ZombieState.INVALID_ENTITY_ID or distance_sq < best_distance_sq or (distance_sq == best_distance_sq and player_id < best_id):
			best_id = player_id
			best_distance_sq = distance_sq
	return best_id
```

没有感知范围内的可达玩家时进入 `WANDER`，并把 `target_id` 设为 `INVALID_ENTITY_ID`；后续每 Tick 都重新调用 `_select_target()`，因此新路径出现或其他玩家进入可达范围后能退出游荡。进入游荡且 `wander_has_target == 0`，或当前位置到游荡目标的距离平方不大于 `wander_arrive_units²` 时，用 Park–Miller 同一乘数/模数直接推进该槽位的 `rng_state`，按 Plan 1 相同 rejection sampling 取 `1..16` heading；不得为每次重选临时 new RNG 对象。将 `wander_target_x/z` 设为当前位置加上由 `FixedMath.floor_div(FixedMath.heading_x/z(heading) * wander_radius_units, 1024)` 得到的整数偏移，并置 `wander_has_target = 1`；其余 Tick 不推进随机流。游荡移动只朝该量化目标调用 `move_circle_x_then_z()`，不得直线穿格；若 intended 非零但地图解析后的实际位移为零，当前 Tick 速度保持零并把 `wander_has_target` 清为 0，下一 Tick 才按 PRNG 重选，避免永久顶墙且不在同 Tick 形成无界重试。可达目标处于攻击范围时进入 `ATTACK`，否则进入 `CHASE`。所有比较使用距离平方。

`ZombieHordeSystem.spawn()` 在调用 `ZombieState.spawn()` 前验证 X/Z 均落在 `[-safe_limit, safe_limit]`，其中 `safe_limit = 2147483647 - config.wander_radius_units - config.separation_push_per_tick`；不得先对任意 int64 调 `abs()`，避免最小 int64 的绝对值本身溢出。越界时返回空字典，避免生成游荡目标时依赖 int32 回绕。

```gdscript
func spawn(spawn_x: int, spawn_z: int, rng_seed: int) -> Dictionary:
	var safe_limit := 2_147_483_647 - config.wander_radius_units - config.separation_push_per_tick
	if spawn_x < -safe_limit or spawn_x > safe_limit or spawn_z < -safe_limit or spawn_z > safe_limit:
		return {}
	return zombies.spawn(spawn_x, spawn_z, config.health, rng_seed)
```

```gdscript
func _next_wander_heading(slot: int) -> int:
	assert(_wander_rng_scratch.set_state(zombies.rng_state[slot]))
	var result := _wander_rng_scratch.next_inclusive(1, 16)
	zombies.rng_state[slot] = _wander_rng_scratch.get_state()
	return result

func _select_wander_target(slot: int) -> void:
	var wander_heading := _next_wander_heading(slot)
	zombies.wander_target_x[slot] = zombies.pos_x[slot] + FixedMath.floor_div(FixedMath.heading_x(wander_heading) * config.wander_radius_units, 1024)
	zombies.wander_target_z[slot] = zombies.pos_z[slot] + FixedMath.floor_div(FixedMath.heading_z(wander_heading) * config.wander_radius_units, 1024)
	zombies.wander_has_target[slot] = 1

func _wander_velocity(slot: int) -> Vector2i:
	var heading_index := _quantize_heading_16(
		zombies.wander_target_x[slot] - zombies.pos_x[slot],
		zombies.wander_target_z[slot] - zombies.pos_z[slot]
	)
	return Vector2i(
		FixedMath.floor_div(FixedMath.heading_x(heading_index) * config.wander_speed_per_tick, 1024),
		FixedMath.floor_div(FixedMath.heading_z(heading_index) * config.wander_speed_per_tick, 1024)
	)
```

目标 ID 解析为玩家槽位时固定扫描 slot 0～3，找到 `players.is_alive(slot)` 且 `entity_id_for_slot(slot) == target_id` 的首项；不存在则本 Tick 立即清空目标并进入 `WANDER`。验证必须固定一个游荡金样：seed 17 第一次选出的 heading、目标 X/Z 和推进后 RNG state 在两个独立世界完全相同，未抵达前连续 30 Tick 的 RNG state 不变。

另把该金样的首次游荡目标方向布置为静态墙：阻挡 Tick 的 RNG state 只包含本次选点推进，`wander_has_target` 在移动解析后变回 0；下一 Tick 恰好再推进一次 RNG 并选择不同量化目标。验证不得允许同 Tick 连续抽样直到找到可走方向。

- [ ] **步骤 4：以流场和地图格驱动移动，不给无路径目标直线回退**

实现移动意图时只读取目标玩家槽位对应流场：

```gdscript
func _flow_velocity(slot: int, player_slot: int, fields: SimFlowFieldSet) -> Vector2i:
	var field: SimFlowField = fields.field_for_slot(player_slot)
	if field == null or not field.is_reachable(zombies.pos_x[slot], zombies.pos_z[slot]):
		return Vector2i.ZERO
	var step := field.next_step(zombies.pos_x[slot], zombies.pos_z[slot])
	var heading_index := _quantize_heading_16(step.x, step.y)
	return Vector2i(
		FixedMath.floor_div(FixedMath.heading_x(heading_index) * config.move_speed_per_tick, 1024),
		FixedMath.floor_div(FixedMath.heading_z(heading_index) * config.move_speed_per_tick, 1024)
	)

func _move_with_map(slot: int, map_grid: SimMapGrid, intended: Vector2i) -> void:
	var resolved := map_grid.move_circle_x_then_z(
		zombies.pos_x[slot], zombies.pos_z[slot], config.radius_units, intended.x, intended.y
	)
	zombies.velocity_x[slot] = resolved.x - zombies.pos_x[slot]
	zombies.velocity_z[slot] = resolved.y - zombies.pos_z[slot]
	zombies.pos_x[slot] = resolved.x
	zombies.pos_z[slot] = resolved.y
```

`ATTACK` 状态的移动意图为零；`CHASE` 只消费 `_select_target()` 已确认可达的目标和对应 `_flow_velocity()`。若 field 在选择后变为 null 或报告不可达，必须在本 Tick 清空 `target_id`、切换为 `WANDER` 并使用量化游荡速度，不能保留永久 `CHASE`、不能改用玩家相对坐标。群体系统预分配 `tick_start_x/z`、`separation_x/z` 与 `attack_candidate_slots` 五个 scratch 数组；每 Tick 开始复制活体起点，完成地图移动与分离后才把 `velocity_x/z = final_position - tick_start_position`，再按最终速度更新 heading，没有位移时保留旧朝向。scratch 不进入规范状态，任何 Tick 都不得 resize。

- [ ] **步骤 5：构建空间哈希并施加一次确定性局部分离**

每 Tick 在所有目标/移动意图计算后调用 `spatial_hash.clear()`，再以 slot 升序插入所有活着的僵尸；任一 `insert(entity_id, x, z)` 返回 `false` 时整个 `step()` 返回 `false`。随后对每只僵尸调用 `query_3x3_sorted(pos_x, pos_z)`，要求返回值等于 `query_count()`。通过 `query_entity_id(index)` 升序读取候选 ID，从候选 ID 高位解码 `candidate_generation := candidate_id >> ZombieState.ENTITY_ID_SLOT_BITS`，再调用 `ZombieState.slot_for_entity_id(candidate_id, candidate_generation)` 解析当前槽位；无效或过期候选使 step 失败，不能静默跳过。只处理 `other_slot > slot`，把一对实体的反向等量修正累积进预分配的 `separation_x[]`、`separation_z[]`，最后统一应用：

```gdscript
func _accumulate_pair_separation(slot: int, other_slot: int, push_x: PackedInt32Array, push_z: PackedInt32Array) -> void:
	var dx := zombies.pos_x[other_slot] - zombies.pos_x[slot]
	var dz := zombies.pos_z[other_slot] - zombies.pos_z[slot]
	var distance_sq := dx * dx + dz * dz
	var limit_sq := config.separation_radius_units * config.separation_radius_units
	if distance_sq >= limit_sq:
		return
	var direction_index := _quantize_heading_16(dx, dz)
	if dx == 0 and dz == 0:
		direction_index = 1 if zombies.entity_id_for_slot(slot) < zombies.entity_id_for_slot(other_slot) else 9
	var push_dx := FixedMath.floor_div(FixedMath.heading_x(direction_index) * config.separation_push_per_tick, 1024)
	var push_dz := FixedMath.floor_div(FixedMath.heading_z(direction_index) * config.separation_push_per_tick, 1024)
	push_x[slot] -= push_dx
	push_z[slot] -= push_dz
	push_x[other_slot] += push_dx
	push_z[other_slot] += push_dz
```

`_quantize_heading_16(dx, dz)` 必须遍历 heading 1～16，计算 `dx * FixedMath.heading_x(heading) + dz * FixedMath.heading_z(heading)`，取点积最大者；同值取较小 heading。零距离 pair 根据两个实体 ID 选择 heading 1 或 9，使较小实体 ID 固定向 -X、较大实体向 +X 分离，绝不使用随机数。最终分离位移也调用 `move_circle_x_then_z()`，固定先 X 后 Z，不能穿过 `SimMapGrid` 阻挡格。

```gdscript
func _quantize_heading_16(dx: int, dz: int) -> int:
	if dx == 0 and dz == 0:
		return 1
	var best_heading := 1
	var best_dot := dx * FixedMath.heading_x(1) + dz * FixedMath.heading_z(1)
	for candidate in range(2, 17):
		var dot := dx * FixedMath.heading_x(candidate) + dz * FixedMath.heading_z(candidate)
		if dot > best_dot:
			best_dot = dot
			best_heading = candidate
	return best_heading
```

- [ ] **步骤 6：实现定长攻击意图缓冲、每玩家名额和冷却推进**

`SimEventBuffer` 构造时按 `zombie_attack_capacity` 一次性分配 source ID、source generation、target ID 三个 `PackedInt32Array`；`begin_tick()` 只记录 Tick 并将 count 重置为零，不 resize。`append_zombie_attack_intent(...) -> bool` 在写满时返回 `false`，成功时按当前 count 写入三列并递增；三个 getter 只接受 `[0, count)`，越界返回 `ZombieState.INVALID_ENTITY_ID`，测试环境对越界访问直接失败。

```gdscript
func _init(zombie_attack_capacity: int) -> void:
	assert(zombie_attack_capacity > 0)
	_zombie_attack_source_ids.resize(zombie_attack_capacity)
	_zombie_attack_source_generations.resize(zombie_attack_capacity)
	_zombie_attack_target_ids.resize(zombie_attack_capacity)

func begin_tick(tick: int) -> void:
	_current_tick = tick
	_zombie_attack_count = 0

func append_zombie_attack_intent(source_entity_id: int, source_generation: int, target_entity_id: int) -> bool:
	if _zombie_attack_count >= _zombie_attack_source_ids.size():
		return false
	_zombie_attack_source_ids[_zombie_attack_count] = source_entity_id
	_zombie_attack_source_generations[_zombie_attack_count] = source_generation
	_zombie_attack_target_ids[_zombie_attack_count] = target_entity_id
	_zombie_attack_count += 1
	return true

func zombie_attack_intent_source_generation(index: int) -> int:
	return _zombie_attack_source_generations[index] if index >= 0 and index < _zombie_attack_count else ZombieState.INVALID_ENTITY_ID
```

source ID 与 target ID getter 使用同一边界规则，`zombie_attack_intent_count()` 直接返回 `_zombie_attack_count`；`get_capacity_signature()` 返回三列数组长度。`ZombieHordeSystem.get_capacity_signature()` 返回 `tick_start_x/z`、`separation_x/z` 与 `attack_candidate_slots` 五个 scratch 长度。

`ZombieHordeSystem.step()` 必须先完成全部移动与分离，再开第二个 slot 升序循环收集攻击候选；开头把四个玩家名额重置为 0，并把 `_attack_candidate_count` 置 0。仅当僵尸最终位置仍在攻击范围、目标仍存活、目标槽位的流场把最终位置标记为可达且 `cooldown_tick[slot] <= tick` 时，把 slot 写入预分配 `_attack_candidate_slots`。收集结束后用插入排序按 `entity_id_for_slot(slot)`、generation、target ID 排序，再遍历候选；对应玩家名额已到 16 时跳过，否则调用：

```gdscript
func _attack_slot_less(left_slot: int, right_slot: int) -> bool:
	var left_id := zombies.entity_id_for_slot(left_slot)
	var right_id := zombies.entity_id_for_slot(right_slot)
	if left_id != right_id:
		return left_id < right_id
	if zombies.generation_for_slot(left_slot) != zombies.generation_for_slot(right_slot):
		return zombies.generation_for_slot(left_slot) < zombies.generation_for_slot(right_slot)
	return zombies.target_id[left_slot] < zombies.target_id[right_slot]

func _sort_attack_candidates() -> void:
	for index in range(1, _attack_candidate_count):
		var key_slot := _attack_candidate_slots[index]
		var cursor := index - 1
		while cursor >= 0 and _attack_slot_less(key_slot, _attack_candidate_slots[cursor]):
			_attack_candidate_slots[cursor + 1] = _attack_candidate_slots[cursor]
			cursor -= 1
		_attack_candidate_slots[cursor + 1] = key_slot
```

```gdscript
var appended := events.append_zombie_attack_intent(
	zombies.entity_id_for_slot(slot),
	zombies.generation_for_slot(slot),
	zombies.target_id[slot]
)
if not appended:
	return false
_attack_slots[player_slot] += 1
zombies.cooldown_tick[slot] = tick + config.attack_cooldown_ticks
```

未成功 append 时不得推进冷却或名额；本系统不得调用任何生命、伤害、死亡、FX 或玩家写接口。攻击意图只是 Plan 5 的候选输入，不代表命中；Plan 5 仍须用整数地图遮挡规则拒绝隔墙攻击。

- [ ] **步骤 7：运行行为验证与失败场景复查**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

整数除法扫描器复用 Plan 2 的做法：逐行移除注释和单双引号字符串，再检查 `scripts/simulation/zombies/*.gd` 与 `scripts/simulation/events/sim_event_buffer.gd` 的剩余源码；出现 `/` 即打印文件/行号并退出 1，离线 exporter、benchmark 和 DebugView 不在扫描范围。

预期：三个命令以 0 退出。验证必须在无流场、失效流场、地图阻挡、17 只同目标攻击、两个重叠僵尸、两个等距玩家及玩家死亡六个失败条件下完成；其中无流场断言位置不改变，不能接受任何直线移动；扫描器输出 `validate_frame_sync_zombie_integer_division: PASS`。

### Task 3：把僵尸群体接入 `SimulationWorld` 固定阶段与冻结规范 section

**文件：**

- 修改：`scripts/simulation/world/simulation_world.gd`
- 修改：`tools/validation/validate_frame_sync_zombie_horde.gd`

**接口：**

- 消费：Task 1 的 `ZombieState`，Task 2 的 `ZombieHordeSystem`/`SimEventBuffer`，Plan 1 的 `SimulationWorld.new(session)`/`step(...)->bool`/规范状态编码，Plan 2 的 `SimulationWorld.get_map_grid() -> SimMapGrid` 与 `get_flow_fields() -> SimFlowFieldSet`，Plan 3 的 `SimulationWorld.get_player_state() -> SimPlayerState`。
- 产出：`SimulationWorld.configure_zombie_horde(config: ZombieSimConfig) -> bool`、`spawn_zombie(spawn_x: int, spawn_z: int, rng_seed: int) -> Dictionary`、`get_zombie_state() -> ZombieState`、`get_zombie_capacity_signature() -> PackedInt32Array`，仅供旁路测试入口、容量验证和后续波次/战斗系统调用。
- 验证脚本本地 helper：`_probe_zombie_sections(bytes: PackedByteArray, expected_capacity: int) -> Dictionary`，固定返回 `config_bundle_marker`、`zombie_marker`、`zombie_schema`、`zombie_capacity`、`zombie_intent_marker`、`zombie_intent_schema`、`zombie_intent_capacity`、`zombie_intent_count`、`combat_pending_marker`、`world_command_marker` 与 `debug_last_event_count` 十一个整数；解析失败返回空 Dictionary。

- [ ] **步骤 1：先写失败的世界配置、阶段顺序和规范状态验证**

把下段测试加入群体验证；Task 2 完成后纯 `ZombieHordeSystem` 已能通过，但世界扩展尚不存在：

```gdscript
var world := SimulationWorld.new(session)
_assert(world.configure_map(map_asset), "必须先配置 Plan 2 地图")
_assert(world.configure_players(player_config), "必须配置 Plan 3 玩家")
_assert(world.configure_zombie_horde(zombie_config), "必须配置僵尸群体")
var without_zombie := world.encode_canonical_state()
var reference := world.spawn_zombie(-4096, 0, 17)
_assert(reference == {"entity_id": 1024, "generation": 1, "slot": 0}, "世界生成必须返回僵尸命名空间中的稳定引用")
var with_zombie := world.encode_canonical_state()
_assert(without_zombie != with_zombie, "生成后的完整 SoA 必须立即进入规范状态")
var canonical_probe := _probe_zombie_sections(without_zombie, zombie_config.capacity)
_assert(canonical_probe.config_bundle_marker == 0, "Plan 4 聚焦世界不得伪装成 Plan 6 完整 bundle 世界")
_assert(canonical_probe.zombie_marker == 1 and canonical_probe.zombie_schema == 1, "已配置未生成的世界也必须保留 zombie marker/schema")
_assert(canonical_probe.zombie_intent_marker == 1 and canonical_probe.zombie_intent_schema == 1, "已配置世界必须保留 pending/events 中的 zombie intent marker/schema")
_assert(canonical_probe.combat_pending_marker == 0 and canonical_probe.world_command_marker == 0, "Plan 4 不得提前填充 Plan 5/6 pending 子段")
var no_horde_world := SimulationWorld.new(session)
_assert(no_horde_world.configure_map(map_asset) and no_horde_world.configure_players(player_config), "未配置群体的 Plan 3 世界必须可创建")
var empty_probe := _probe_zombie_sections(no_horde_world.encode_canonical_state(), 0)
_assert(empty_probe.zombie_marker == 0 and empty_probe.zombie_intent_marker == 0, "未配置群体时必须保留 Plan 1 的两个零 marker")
var player_position := world.get_player_state().get_position_units(0)
var target_cell := world.get_map_grid().world_to_cell_id(player_position.x, player_position.y)
_assert(world.get_flow_fields().is_dirty(0), "配置僵尸时必须登记初始玩家目标并标记待重建")
_assert(world.step(0, tape.get_frame(0)), "Tick 0 必须成功推进")
_assert(world.get_flow_fields().field_for_slot(0).generation() == 1, "Tick 0 阶段 4 必须完成初始流场")
_assert(world.get_flow_fields().field_for_slot(0).target_cell_id() == target_cell, "Tick 0 原子换入后的流场目标必须等于初始玩家格")
_assert(world.get_zombie_state().target_id[0] == world.get_player_state().entity_id_for_slot(0), "僵尸阶段必须消费玩家阶段后的目标状态")
```

再断言：重复 `configure_zombie_horde()` 返回 `false`；缺地图、缺玩家或无效 config 时返回 `false` 且 `get_last_error()` 非空；未配置僵尸的 Plan 1～3 世界仍能按原金样推进。

- [ ] **步骤 2：运行失败验证**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde.gd
```

预期：进程非零退出，指出 `configure_zombie_horde()`、`spawn_zombie()` 或 `get_zombie_state()` 尚不存在；Task 2 的纯群体行为验证仍通过。

- [ ] **步骤 3：在世界固定阶段接入僵尸系统并扩展规范状态**

实现 `configure_zombie_horde()`：只允许在 `get_next_tick() == 0` 且尚未配置时调用；要求 `ZombieSimConfigCodec.validate_content_hash(config)`，并确认 Plan 2 的 `_map_asset`、`get_map_grid()`/`get_flow_fields()` 与 Plan 3 的 `get_player_state()` 均非空。保存 config 的深复制后，计算 `bucket_size_units := _map_asset.cell_size_units * 2`，并显式验证 `bucket_size_units >= config.separation_radius_units`，否则返回 `false` 和稳定错误 `zombie separation radius exceeds spatial bucket`；这满足 Plan 2 对 3×3 查询覆盖分离半径的调用方契约。随后以该 bucket size、config capacity 为 max entities 构造专属 `SimSpatialHash`，再创建 SoA、群体系统和事件缓冲。配置结束立即调用 `_sync_player_flow_targets()`，使 Tick 0 的 Plan 2 阶段 4 能构建初始场。任何前置条件失败都返回 `false` 且写入 `get_last_error()`。

每 Tick 仍保持 SPEC 阶段顺序：Plan 2 在阶段 3/4 提交地图变化并重建此前 dirty 的场；Plan 3 在阶段 5/6 完成玩家最终位置；随后 `_sync_player_flow_targets()` 只把本 Tick 跨格或死亡变化标 dirty，供下一 Tick 阶段 4 重建；最后阶段 7/8 才推进僵尸。每 Tick 只调用一次 `event_buffer.begin_tick(tick)`：

```gdscript
func _step_zombies(tick: int) -> bool:
	return zombie_horde_system.step(
		tick,
		get_player_state(),
		get_map_grid(),
		get_flow_fields(),
		zombie_spatial_hash,
		event_buffer
	)

func _sync_player_flow_targets() -> bool:
	var players := get_player_state()
	var fields := get_flow_fields()
	for slot in range(4):
		var field := fields.field_for_slot(slot)
		if players.is_alive(slot):
			var position := players.get_position_units(slot)
			var cell_id := get_map_grid().world_to_cell_id(position.x, position.y)
			if field.target_cell_id() != cell_id and not fields.set_target_cell(slot, cell_id):
				return false
		elif field.target_cell_id() != -1 and not fields.clear_target(slot):
			return false
	return true

func spawn_zombie(spawn_x: int, spawn_z: int, rng_seed: int) -> Dictionary:
	return zombie_horde_system.spawn(spawn_x, spawn_z, rng_seed)
```

保持 `SimulationWorld.new(session)` 和 `step(tick, frame) -> bool` 签名及其他阶段顺序。`_step_zombies()` 返回 `false` 时，`step()` 写入稳定错误并返回 `false`，不得增加 `next_tick`。未调用 `configure_zombie_horde()` 的 Plan 1～3 世界跳过僵尸阶段；已配置但没有 spawn 的旁路世界执行固定容量零实体遍历。`get_zombie_state()` 在未配置时返回 `null`；`spawn_zombie()` 在未配置、种子/坐标非法、出生圆被地图阻挡或容量耗尽时返回空字典并设置稳定错误；地图验证用 `move_circle_x_then_z(spawn_x, spawn_z, radius, 0, 0)`，结果必须与输入相同。旧 `DemoArena` 不实例化或绑定新系统。

`get_zombie_capacity_signature()` 依次拼接 `ZombieState.get_capacity_signature()`、`ZombieHordeSystem.get_capacity_signature()`、SimSpatialHash 构造时冻结的 `max_entities/query_capacity` 两个整数和 `SimEventBuffer.get_capacity_signature()`。未配置时返回空数组；该接口只暴露长度，不暴露可变内部数组。SimSpatialHash 自身不提供 resize API，其固定容量正确性继续由 Plan 2 验证。

规范状态只能实现 Plan 1 已冻结的两个 hook，不得在既有 bytes 末尾任意 append。整体编码顺序始终固定为：world header → players → zombies → other entities → dynamic map → PRNG → wave → pending/events。

`SimulationWorld._encode_zombie_section(writer)` 未配置时原样写 Plan 1 预留的 `zombie_marker:u8 = 0` 与 `zombie_slot_count:u16 = 0`；配置后写 `zombie_marker:u8 = 1`、`zombie_schema:u8 = 1`、`ZombieSimConfig.get_content_hash()` 的 32 bytes、`zombie_slot_count:u16 = capacity`，以及全部 slot 的 `alive/generation/pos_x/pos_z/velocity_x/velocity_z/heading/health/state/target_id/cooldown_tick/rng_state/wander_target_x/wander_target_z/wander_has_target`。实体 ID 可由 generation 与 slot 唯一恢复，不重复编码；全部使用 `LittleEndianWriter` 按 slot 升序编码。本 Tick 攻击意图不是实体持久状态，禁止写入此 section。

`SimulationWorld._encode_pending_event_section(writer)` 保持 Plan 1 冻结的精确子段顺序 `pending_event_count:u16 → zombie_intent_marker → combat_pending_marker → world_command_marker → last_event_count:u16`。本计划只填充第一项 marker：未配置时写 `zombie_intent_marker:u8 = 0`；配置后写 `zombie_intent_marker:u8 = 1`、`zombie_intent_schema:u8 = 1`、`attack_capacity:u16`、`attack_count:u16`，再按意图索引顺序把 source ID/source generation/target ID 各写为 `i32`；随后仍写 Plan 1 预留的 `combat_pending_marker:u8 = 0`、`world_command_marker:u8 = 0` 和 debug 输出事件。Plan 5 只把 `combat_pending_marker` 切为 1 并写 damage/death/presentation，不能复制攻击意图；Plan 6 只填 `world_command_marker`，也不得把攻击意图搬回 zombie section。验证解析完整 canonical bytes，必须证明 zombie marker 位于 players 后、other entities 前，zombie intent marker 位于 wave 后且严格早于 combat/world/debug 三个后续子段。

`_probe_zombie_sections()` 必须使用 Plan 1 `LittleEndianReader` 按冻结字段长度顺序读取 world header，并在 `next_tick:u32` 后显式读取 `config_bundle_marker:u8`；Plan 4 聚焦世界要求该值为 0。随后继续读取 Plan 3 player section、zombie section、other/map/PRNG/wave，再进入 pending/events；禁止用 `find()` 搜索 marker 字节，因为 SoA 或 Hash 中也可能出现 0/1。它在 zombie marker 为 1 时验证 32-byte config Hash、capacity 与每槽 15 个 `i32` 字段的精确长度；在 intent marker 为 1 时验证 capacity/count 上界并跳过每条 3 个 `i32`，随后依次读取 combat marker、world command marker 和 Plan 1 debug `last_event_count`。Plan 4 世界的后两个 marker 必须都是 0。reader error、提前 EOF、capacity 不符或末尾存在无法解释的字节时返回空 Dictionary。

- [ ] **步骤 4：验证意图、冷却、阶段顺序与世界接线**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

预期：17 只僵尸同 Tick 对一个玩家只保留来源 ID 最小的 16 个意图；同一只僵尸在 42 Tick 冷却结束前不重复写入；`SimulationWorld.spawn_zombie()` 产生的实体会在下一个 `step()` 由群体系统推进。玩家跨格的 Tick 只标 dirty，下一 Tick 阶段 4 才使对应 flow generation 增加；玩家 alive 变 0 后下一 Tick 得到合法空场。canonical probe 必须证明 SoA 只在 zombie section、攻击意图只在 pending/events section，未配置世界的两个 marker 都为 0。验证输出中不得出现玩家生命变化、`ZombieTarget`、Physics 或 NavigationServer 调用。

### Task 4：完成 150 只回放、只读调试视图、性能门槛与集成验收

#### 里程碑 A：150 只双实例回放与只读调试视图

**文件：**

- 创建：`scripts/simulation/view/zombie_debug_view.gd`
- 创建：`scenes/simulation/ZombieDebugView.tscn`
- 修改：`scripts/simulation/testing/first_divergence_harness.gd`
- 创建：`tools/validation/validate_frame_sync_zombie_horde_replay.gd`

**接口：**

- 消费：Task 1 的 `ZombieState`、Task 3 的 `SimulationWorld.get_zombie_state()`/`get_zombie_capacity_signature()`，Plan 1 的 `InputTape.get_frame(tick)`、`LocalFrameCommandCodec.encode/decode`、`StateHasher.hash_canonical/equal/to_hex` 与 `FirstDivergenceHarness`，Plan 2/3 的世界配置接口。
- 产出：`ZombieDebugView.bind_world(world: SimulationWorld) -> void`，只读取状态；`FirstDivergenceHarness.run_zombie_horde_replay(tape: InputTape, spawn_count: int, ticks: int) -> Dictionary`，成功结果为 `{ "ok": true, "ticks_checked": int, "first_divergence_tick": -1, "final_alive_count": int, "capacity": int, "unreachable_tick_count": int }`，失败结果保留 Plan 1 的 `tick/frame_hex/direct_hash/codec_hash/direct_state_hex/codec_state_hex` 并增加 `first_divergence_tick`。
- harness 私有 helper：`_queue_recorded_blockade_changes(tick: int, frame: LocalFrameCommandSet, world: SimulationWorld, branch_index: int) -> bool`、`_slot_zero_is_unreachable(world: SimulationWorld) -> bool`；CLAIM/RELEASE 所需 ring cell 列表必须为 direct/codec 两个分支各自保存，不共享可变数组。

- [ ] **步骤 1：写失败的 150 只双实例回放验证**

创建回放验证，固定 150 个按 slot 可重复生成的位置和种子，直接命令世界与编解码命令世界逐 Tick 比较：

```gdscript
var result := harness.run_zombie_horde_replay(tape, 150, 10_000)
_assert(result["first_divergence_tick"] == -1, "10,000 Tick 不得出现 Hash 分歧")
_assert(result["final_alive_count"] == 150, "Plan 4 不结算伤害，150 只僵尸应保持存活")
_assert(result["unreachable_tick_count"] == 256, "无路径窗口必须逐 Tick 被实际观察到")

result = harness.run_zombie_horde_replay(tape, 150, 100_000)
_assert(result["first_divergence_tick"] == -1, "100,000 Tick 不得出现 Hash 分歧")
_assert(result["capacity"] == 256, "150 只回放不得导致 SoA 扩容")
```

录像使用一名存活玩家的重复十六方向移动命令，周期性跨格使流场更新；slot 0 的 `PlayerFrameCommand.CONFIRM` 只在 Tick 4096 和 Tick 4352 置位，分别触发一组 Plan 2 动态占用 CLAIM 与对应 RELEASE，从而形成恰好 256 Tick 的无路径窗口。harness 必须从同一解码前/后帧派生同一组 `queue_map_change()`，禁止依赖 wall clock 或测试脚本在 step 后直接改地图。回放脚本必须将首个分歧的 Tick、22 bytes 输入帧、直接世界/编解码世界 Hash 与两份规范状态输出为 JSON，缺少 Plan 1 的 `tick/frame_hex/direct_hash/codec_hash/direct_state_hex/codec_state_hex` 任一字段视为失败。

`_queue_recorded_blockade_changes()` 预分配两份 branch-local `PackedInt32Array`。Tick 4096 且 slot 0 命令含约定 action bit 时，以该分支 zombie slot 0 当前 cell 为中心按 cell_id 升序收集八邻域中所有非静态阻挡格；中心格不 CLAIM，列表必须非空且不含玩家目标格。helper 把列表副本保存在对应 branch，创建 `SimDynamicOccupancyChange.new(4096, 1, 0, 9001, CLAIM, cells)` 并要求 `world.queue_map_change()` 成功。Tick 4352 的同一 action bit 使用该 branch 保存的完全相同列表创建 RELEASE；其他 Tick 不排变化并返回 true。两分支生成的 cell ID 值必须逐项相同，但 `PackedInt32Array` 实例不得共享；action bit 缺失、列表不一致、queue 失败或 RELEASE 前没有保存列表都返回 false。八邻格全被静态/动态阻挡后中心 cell 在 Flow Field 中不可达，RELEASE 后下一次阶段 4 原子重建恢复路径。

- [ ] **步骤 2：运行回放验证并确认其因 harness API 不存在失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde_replay.gd
```

预期：进程非零退出，指出 `run_zombie_horde_replay()` 未定义；不得把 100,000 Tick 缩短为抽样 Hash 或忽略无路径窗口。

- [ ] **步骤 3：扩展双实例 harness，并保持 Hash 编码完整**

在 harness 内按相同 `(slot, spawn_x, spawn_z, rng_seed)` 顺序给两个 `SimulationWorld` 调用 `spawn_zombie()`；每 Tick 对左世界提交原始 `LocalFrameCommandSet`，对右世界提交 `decode(encode(frame))` 的命令。每一步分别获得 Plan 1 的规范状态 Hash：

```gdscript
const HORDE_MAP: SimMapAsset = preload("res://resources/simulation/maps/demo_arena_map.tres")
const HORDE_PLAYER_CONFIG: PlayerSimConfig = preload("res://resources/simulation/players/demo_arena_player_sim_config.tres")

func run_zombie_horde_replay(tape: InputTape, spawn_count: int, ticks: int) -> Dictionary:
	var zombie_config := ZombieSimConfig.default_config()
	if tape == null or not _session.is_replay_compatible(tape.get_session()) or ticks < 1 or ticks > tape.get_frame_count() or spawn_count < 1 or spawn_count > zombie_config.capacity:
		return _horde_failure(-1, PackedByteArray(), null, null)
	var direct_world := _new_horde_world(tape.get_session(), HORDE_MAP, HORDE_PLAYER_CONFIG, zombie_config)
	var decoded_world := _new_horde_world(tape.get_session(), HORDE_MAP, HORDE_PLAYER_CONFIG, zombie_config)
	if direct_world == null or decoded_world == null:
		return _horde_failure(-1, PackedByteArray(), direct_world, decoded_world)
	if not _spawn_horde_pair(direct_world, decoded_world, spawn_count):
		return _horde_failure(-1, PackedByteArray(), direct_world, decoded_world)
	var direct_sizes := _horde_array_sizes(direct_world)
	var decoded_sizes := _horde_array_sizes(decoded_world)
	var unreachable_tick_count := 0
	for tick in ticks:
		var direct_frame := tape.get_frame(tick)
		var frame_bytes := LocalFrameCommandCodec.encode(direct_frame)
		var decoded_frame := LocalFrameCommandCodec.decode(frame_bytes)
		if decoded_frame == null or not decoded_frame.is_valid():
			return _horde_failure(tick, frame_bytes, direct_world, decoded_world)
		if not _queue_recorded_blockade_changes(tick, direct_frame, direct_world, 0):
			return _horde_failure(tick, frame_bytes, direct_world, decoded_world)
		if not _queue_recorded_blockade_changes(tick, decoded_frame, decoded_world, 1):
			return _horde_failure(tick, frame_bytes, direct_world, decoded_world)
		if not direct_world.step(tick, direct_frame) or not decoded_world.step(tick, decoded_frame):
			return _horde_failure(tick, frame_bytes, direct_world, decoded_world)
		var direct_unreachable := _slot_zero_is_unreachable(direct_world)
		var decoded_unreachable := _slot_zero_is_unreachable(decoded_world)
		if direct_unreachable != decoded_unreachable:
			return _horde_failure(tick, frame_bytes, direct_world, decoded_world)
		if tick >= 4096 and tick < 4352:
			if not direct_unreachable:
				return _horde_failure(tick, frame_bytes, direct_world, decoded_world)
			unreachable_tick_count += 1
		var direct_hash := StateHasher.hash_canonical(direct_world.encode_canonical_state())
		var decoded_hash := StateHasher.hash_canonical(decoded_world.encode_canonical_state())
		if not StateHasher.equal(direct_hash, decoded_hash):
			return _horde_failure(tick, frame_bytes, direct_world, decoded_world)
	if _horde_array_sizes(direct_world) != direct_sizes or _horde_array_sizes(decoded_world) != decoded_sizes:
		return _horde_failure(ticks, PackedByteArray(), direct_world, decoded_world)
	return {"ok": true, "ticks_checked": ticks, "first_divergence_tick": -1, "final_alive_count": _alive_count(direct_world.get_zombie_state()), "capacity": direct_world.get_zombie_state().capacity, "unreachable_tick_count": unreachable_tick_count}
```

`_new_horde_world(session, map_asset, player_config, zombie_config)` 必须依次调用 `SimulationWorld.new(session)`、Plan 2 的 `configure_map(map_asset)`、Plan 3 的 `configure_players(player_config)` 和 Task 3 的 `configure_zombie_horde(zombie_config)`，任一步失败立即收集 `get_last_error()`。`_spawn_horde_pair()` 必须逐个比较两个世界返回的 `{entity_id, generation, slot}`，任一不一致立即失败。`_alive_count()` 必须扫描全部 slot 统计 `is_alive()`，不能直接返回 spawn_count；`_horde_array_sizes(world)` 直接返回 `world.get_zombie_capacity_signature()`。该录像只有 player slot 0 启用；`_slot_zero_is_unreachable(world)` 取得活着的 zombie slot 0 当前 X/Z，并只返回 player slot 0 Flow Field 的 `not is_reachable(x, z)`，不读取僵尸已因不可达而清空的 `target_id`，也不得用速度为零冒充无路径。

失败统一由一个 helper 生成 Plan 1 诊断字段；world 为空时状态 bytes 为空，Hash 仍对空 bytes 计算，保证六个字符串始终存在：

```gdscript
func _horde_failure(tick: int, frame_bytes: PackedByteArray, direct_world: SimulationWorld, codec_world: SimulationWorld) -> Dictionary:
	var direct_state := direct_world.encode_canonical_state() if direct_world != null else PackedByteArray()
	var codec_state := codec_world.encode_canonical_state() if codec_world != null else PackedByteArray()
	return {
		"ok": false,
		"first_divergence_tick": tick,
		"tick": tick,
		"frame_hex": frame_bytes.hex_encode(),
		"direct_hash": StateHasher.to_hex(StateHasher.hash_canonical(direct_state)),
		"codec_hash": StateHasher.to_hex(StateHasher.hash_canonical(codec_state)),
		"direct_state_hex": direct_state.hex_encode(),
		"codec_state_hex": codec_state.hex_encode(),
	}
```

僵尸规范编码按 Task 3 固定顺序执行；调试视图不进入 Hash，不调用 `world.step()`，也不向事件缓冲写入。

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
	var zombies := _world.get_zombie_state()
	for slot in zombies.capacity:
		if not zombies.is_alive(slot):
			continue
		var x := float(zombies.pos_x[slot]) / 1024.0
		var z := float(zombies.pos_z[slot]) / 1024.0
		var heading_x := float(FixedMath.heading_x(zombies.heading[slot])) / 1024.0
		var heading_z := float(FixedMath.heading_z(zombies.heading[slot])) / 1024.0
		_mesh.surface_add_vertex(Vector3(x, 0.05, z))
		_mesh.surface_add_vertex(Vector3(x + heading_x * 0.4, 0.05, z + heading_z * 0.4))
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

#### 里程碑 B：100/150 性能硬门槛与 256/512 容量报告

**文件：**

- 创建：`scripts/simulation/testing/zombie_horde_benchmark.gd`
- 创建：`scripts/simulation/testing/zombie_horde_benchmark_runner.gd`
- 创建：`scenes/simulation/ZombieHordeBenchmark.tscn`
- 创建：`tools/validation/validate_frame_sync_zombie_horde_benchmark.gd`
- 修改：`tools/validation/validate_frame_sync_zombie_horde_replay.gd`

**接口：**

- 消费：Task 3 的 `SimulationWorld.spawn_zombie()`/`get_zombie_state()`、本 Task 里程碑 A 的 `FirstDivergenceHarness.run_zombie_horde_replay()`。
- 产出：`ZombieHordeBenchmark.run_all(session: LocalSimulationSession, map_asset: SimMapAsset, player_config: PlayerSimConfig) -> Array[Dictionary]`、`passed_hard_tiers(reports: Array[Dictionary]) -> bool`；CLI stdout 和目标设备控制台输出同一份包含 context 及 100、150、256、512 档 `sample_count`、P50、P95、P99、最大值和容量的 JSON Lines，进程/场景最终状态表达预算是否通过。

- [ ] **步骤 6：先写失败的预算断言和报告结构**

共享 benchmark 类预分配世界与 150 个僵尸，先运行 300 个预热 Tick，再采集 3,000 个 Tick 的单步耗时，单位统一为毫秒；Headless 验证和导出场景都必须以同一 session/map/player config 调用 `run_all()`：

```gdscript
var report := _benchmark_tier(150, 3_000)
_assert(report["sample_count"] == 3_000, "报告必须保留全部采样")
_assert(report["p95_ms"] < 8.0, "150 只僵尸 P95 必须小于 8 ms")
_assert(report["window_count"] == 91, "3000 样本按 300 Tick 窗口、30 Tick stride 必须产生 91 个窗口")
_assert(report["p99_sustained_ok"] == true, "持续 P99 判定必须通过")
_assert(report["max_consecutive_p99_over_16ms"] <= 2, "P99 超过 16 ms 不得连续出现 3 个窗口")
_assert(report["passed"] == true, "150 档必须通过组合门槛")
print(JSON.stringify(report))
```

基准一并执行 100、256、512 档并输出 JSON Lines；100 与 150 档是硬门槛，256/512 档只记录结果和 `capacity`，不隐藏任何超预算样本。

CLI 和导出 runner 都按同一代码创建基准 session：`SimulationManifest.new(1, 3, map_asset.map_id, player_config.combined_config_hash(map_asset.get_content_hash()))`，再用 seed `24681357`、mask `0b0001`、source keys `[&"benchmark", &"", &"", &""]`、heading offset `8` 创建 `LocalSimulationSession`。这是 Plan 4 旁路门槛的临时 manifest 形态；Zombie config 的 32-byte Hash 已进入规范世界状态，Plan 6 再由 `SimulationConfigBundle` 把它聚合进完整玩法 manifest。

- [ ] **步骤 7：运行预算验证并确认实现前失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde_benchmark.gd
```

预期：在 `_benchmark_tier()` 尚未实现时非零退出，或在 P95/持续 P99 门槛未满足时以非零退出并打印实际 P95、整体 P99 和每窗 P99；不得把失败改成警告或删去 150 档。

- [ ] **步骤 8：实现可复现的分位数报告**

每个档位从相同会话 seed、相同地图格、相同 30 Hz 指令循环和相同僵尸生成序列开始；采样时只包围 `world.step(tick, frame)`，不包含场景、日志、JSON 序列化或 DebugView。排序副本后采用向上取整的秩，避免不同实现取值不一致：

```gdscript
func _percentile(sorted_samples: Array[float], numerator: int, denominator: int) -> float:
	var rank := FixedMath.floor_div(sorted_samples.size() * numerator + denominator - 1, denominator)
	return sorted_samples[maxi(rank - 1, 0)]

func _window_p99_stats(samples: Array[float]) -> Dictionary:
	var window_p99: Array[float] = []
	var consecutive_over := 0
	var max_consecutive_over := 0
	for start in range(0, samples.size() - 300 + 1, 30):
		var window := samples.slice(start, start + 300)
		window.sort()
		var value := _percentile(window, 99, 100)
		window_p99.append(value)
		consecutive_over = consecutive_over + 1 if value > 16.0 else 0
		max_consecutive_over = maxi(max_consecutive_over, consecutive_over)
	return {"window_count": window_p99.size(), "window_p99_ms": window_p99, "max_consecutive_p99_over_16ms": max_consecutive_over, "p99_sustained_ok": max_consecutive_over <= 2}

func _benchmark_tier(count: int, sample_count: int) -> Dictionary:
	var world := _new_benchmark_world(count)
	var initial_sizes := world.get_zombie_capacity_signature()
	for warmup_tick in 300:
		_assert(world.step(warmup_tick, _benchmark_frame(warmup_tick)), world.get_last_error())
	var samples: Array[float] = []
	for tick in sample_count:
		var started := Time.get_ticks_usec()
		_assert(world.step(tick + 300, _benchmark_frame(tick + 300)), world.get_last_error())
		samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
	_assert(world.get_zombie_capacity_signature() == initial_sizes, "基准期间 SoA、scratch、空间哈希和事件缓冲不得增长")
	var sorted := samples.duplicate()
	sorted.sort()
	var windows := _window_p99_stats(samples)
	var p95_ms := _percentile(sorted, 95, 100)
	var hard_tier := count == 100 or count == 150
	var passed = p95_ms < 8.0 and windows.p99_sustained_ok if hard_tier else null
	return {"zombie_count": count, "capacity": world.get_zombie_state().capacity, "sample_count": sample_count, "p50_ms": _percentile(sorted, 50, 100), "p95_ms": p95_ms, "p99_ms": _percentile(sorted, 99, 100), "max_ms": sorted.back(), "window_count": windows.window_count, "window_p99_ms": windows.window_p99_ms, "max_consecutive_p99_over_16ms": windows.max_consecutive_p99_over_16ms, "p99_sustained_ok": windows.p99_sustained_ok, "passed": passed}
```

`_new_benchmark_world(count)` 对 `count <= 256` 使用 `ZombieSimConfig.default_config()`，对 `count > 256` 仅使用 `benchmark_config()`；逐个 spawn 必须成功且返回的 slot 等于生成序号。`get_zombie_capacity_signature()` 在预热前后和采样后必须逐项相同，以验证没有任何 resize。

```gdscript
func passed_hard_tiers(reports: Array[Dictionary]) -> bool:
	var passed_count := 0
	for report in reports:
		if report.zombie_count == 100 or report.zombie_count == 150:
			if report.p99_sustained_ok != true or report.max_consecutive_p99_over_16ms > 2:
				return false
			if report.p95_ms >= 8.0 or report.passed != true:
				return false
			passed_count += 1
	return passed_count == 2
```

在最低目标 Web 或移动设备运行导出了 `ZombieHordeBenchmark.tscn` 的专用测试构建并保存控制台 JSON Lines；不得把 benchmark 场景设为正常游戏 main scene。第一条必须是 `{ "type": "benchmark_context", "device_model": String, "os": String, "godot_version": String, "renderer": String, "command": String }`，字段分别来自目标设备运行环境和本次入口名称；随后四条 tier 记录包含 `zombie_count/capacity/sample_count/p50_ms/p95_ms/p99_ms/max_ms/window_count/window_p99_ms/max_consecutive_p99_over_16ms/p99_sustained_ok/passed`。100/150 的 `passed` 仅在 P95 `< 8.0` 且 `p99_sustained_ok == true` 时为 true；该布尔值等价于 `max_consecutive_p99_over_16ms <= 2`。256/512 的 `passed` 字段固定为 `null`，只报告性能与无增长。开发机 Headless 报告只能用于回归，不能替代最低目标设备结果。

人工目标设备验收：Web 构建打开 benchmark 专用 URL，移动构建直接启动 benchmark flavor；等待控制台输出四档完成标记，不进行游戏输入。用户保存 JSON Lines 或控制台截图并交回分析；不使用 CUA 自动操作浏览器或设备。

#### 里程碑 C：完整回归、旧路径隔离与交付复核

- [ ] **步骤 9：运行全部自动验证并检查旧路径未被修改**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_state.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/export/export_zombie_sim_configs.gd -- --check
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde_replay.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_zombie_horde_benchmark.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
! rg -n 'CharacterBody3D|PhysicsServer3D|NavigationAgent3D|NavigationServer3D|move_and_slide|intersect_' scripts/simulation/zombies scripts/simulation/events/sim_event_buffer.gd
! rg -n 'resources/difficulty|zombie_difficulty_profile' scripts/simulation scenes/simulation
git diff --check
git diff -- scripts/combat/zombie_target.gd scenes/targets/ZombieTarget.tscn scripts/gameplay/demo_arena.gd resources/difficulty/zombie_easy.tres resources/difficulty/zombie_normal.tres resources/difficulty/zombie_hard.tres
```

预期：七个验证/检查与 Headless 导入均为 0，两条禁止依赖扫描和最后一条旧路径 diff 没有输出。100 和 150 档报告在最低目标设备上都满足 P95 < 8 ms，且 300 Tick 窗口、30 Tick stride 下不得连续 3 个窗口 P99 > 16 ms；任何档位出现容量增长、Hash 分歧、无路径直线移动、超过 16 条攻击意图、运行时旧 difficulty 引用或旧路径 diff 时，本计划不得进入 Plan 5。

- [ ] **步骤 10：完成最终评审并把提交权交还用户**

确认本计划没有修改旧玩法文件，且计划实现涉及的路径与「文件结构与稳定接口」一致：

```bash
git status --short
git diff --check
git diff -- scripts/combat/zombie_target.gd scenes/targets/ZombieTarget.tscn scripts/gameplay/demo_arena.gd resources/difficulty/zombie_easy.tres resources/difficulty/zombie_normal.tres resources/difficulty/zombie_hard.tres
```

预期：`git diff --check` 成功，旧路径 diff 无输出；`git status --short` 只列出本计划声明的文件。agent 到此停止，不执行暂存或提交；用户审阅后自行提交。Plan 5 以本计划「供后续计划消费的接口」作为唯一僵尸战斗接缝。

## 规格覆盖复核

- 僵尸 SoA、默认 256、压测 512、稳定 ID/generation 与容量耗尽由 Task 1 覆盖。
- 旧 easy/normal/hard difficulty `.tres` 的离线整数转换、三份已提交 SimConfig Resource、重复 payload/Hash 与运行时禁读旧浮点资源由 Task 1 和 Task 4 里程碑 C 覆盖；32-byte zombie config Hash 交给 Plan 6 `SimulationConfigBundle` 聚合进最终 manifest。
- `SimPlayerState`、`SimMapGrid`、`SimFlowFieldSet`、`SimSpatialHash`、`SimEventBuffer` 与 `SimulationWorld` 的交界和调用顺序由 Task 2、3 覆盖。
- 目标选择、游荡、可达玩家改选、无可达目标后持续重评估、追击、攻击意图、每玩家 16 名额、局部分离及无路径不直线降级由 Task 2、3 的失败断言覆盖。
- 伤害、生命改写、死亡、命中和战斗表现明确留给 Plan 5；Plan 4 只生产攻击意图。
- 最小 `ZombieDebugView` 与旧 `ZombieTarget` 不改由 Task 4 的里程碑 A/C 覆盖。
- 150 只 10,000/100,000 Tick 双实例回放，以及 100/150 P95 < 8 ms、持续 P99（300 Tick 窗口、30 Tick stride、不得连续 3 窗 > 16 ms）的报告由 Task 4 的里程碑 A/B 覆盖。

## 占位符与类型一致性复核

- 本文没有未定实现项、空白步骤或省略的失败条件；每个新增 API 都在接口段或产生它的任务中给出准确名称和参数。
- `ZombieState` 统一使用 `(generation << 10) | slot`：玩家 ID 为 `1..4`，首代僵尸 ID 为 `1024..1535`；`ZombieHordeSystem`、事件缓冲和 Plan 5 消费方都携带同一 `(entity_id, generation)` 引用并执行 stale generation 校验。
- canonical marker 与 Plan 1 对齐：zombie section 使用 `zombie_marker`，pending/events section 使用 `zombie_intent_marker`；攻击意图不再混入 Zombie SoA，也不在 Plan 5 重复编码。
- 全文的回放入口统一为 `FirstDivergenceHarness.run_zombie_horde_replay(tape, spawn_count, ticks)`，验证脚本统一位于 `tools/validation/`，长期 harness 路径统一为 `scripts/simulation/testing/first_divergence_harness.gd`。

## 执行交接

实施前先询问用户是否创建隔离 worktree；按项目约定默认选择“不创建”，直接在当前工作区执行。若用户选择 worktree，先使用 `using-git-worktrees` 创建隔离目录，再开始 Task 1。

执行方式二选一：

1. **Subagent-Driven（推荐）**：使用 `subagent-driven-development`，每个顶层 Task 派发独立实现 subagent，并在 Task 间做规格与质量复核。
2. **Inline Execution**：使用 `executing-plans`，在当前会话按 Task 分批执行并设置检查点。

无论选择哪种方式，都不为单独 Task 创建提交，也不由 agent 执行最终 `git commit`；四个 Task 全部完成、自动验证与最低目标设备报告通过后，由用户自行审阅和提交。
