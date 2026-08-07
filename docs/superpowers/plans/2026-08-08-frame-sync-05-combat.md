# 帧同步 Plan 5：确定性战斗模拟 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Plan 1～4 的本地 30 Hz 确定性世界中加入只读整数战斗配置、玩家装备与弹药、手枪/冲锋枪/匕首命中、稳定伤害队列、死亡和稳定表现事件，并以双实例逐 Tick 一致作为 Plan 6 的进入门槛。

**Architecture:** 离线构建器读取当前 `pistol.tres`、`smg.tres`、`knife.tres` 及旧场景导出的玩家受击与僵尸攻击数值，生成运行时只含整数和 `PackedInt32Array` 的 `SimCombatConfig`；模拟运行时不再读取原始浮点资源。`SimEquipmentState` 保存四名玩家的装备、弹药、射击冷却、匕首待命中 Tick、散布累积量和独立 Park–Miller 状态；`SimCombatSystem` 只追加稳定 `SimDamageQueue` 项和整数表现候选，`SimDamageResolver` 在固定第 11 阶段统一排序、扣血、立即失效死亡实体，并由 `SimEventBuffer` 在第 14 阶段排序后分配稳定 `event_id`。

**Tech Stack:** Godot 4.7.1、GDScript、30 Hz 整数 Tick、`PackedInt32Array`、`PackedByteArray`、Plan 1 的 `FixedMath` / `ParkMillerRng` / `LittleEndianWriter` / `StateHasher` / `FirstDivergenceHarness`、Plan 2 的 `SimMapGrid`、Plan 3 的 `SimPlayerState`、Plan 4 的 `ZombieSimConfig` / `ZombieState` / `SimEventBuffer`。

## Global Constraints

- 唯一需求准绳是 `docs/superpowers/specs/2026-08-08-local-deterministic-frame-sync-design.md`；若本计划、Plan 1～4 示例或旧代码与 SPEC 冲突，必须先按 SPEC 修正文档和实现，不能用兼容分支掩盖冲突。
- SPEC 中的“步枪”功能槽位对应提交 `50daa0b` 纯重命名后的当前 `resources/weapons/smg.tres`、`scenes/weapons/Smg.tscn` 和稳定 `weapon_id = &"smg"`；本计划以 `WEAPON_SMG` 实现该槽位，不恢复已删除 rifle 资产、不更改当前冲锋枪数值。
- 前置门槛是 Plan 1、2、3、4 的聚焦验证、Headless 导入和双实例 Hash 验收全部通过；任一前置门槛失败时不得实施本计划，也不得把新模拟接入默认 `DemoArena`。
- 保持 Plan 1 的 `SimulationWorld.new(session: LocalSimulationSession)`、`step(tick: int, frame: LocalFrameCommandSet) -> bool`、`encode_canonical_state() -> PackedByteArray` 和 `get_last_error() -> String`；`step()` 不接收 `delta`。规范编码总顺序固定为 world header → players → zombies → other entities → dynamic map → PRNG → wave → pending/events，本计划只能填充 Plan 1 预留 section 的稳定子段，禁止在完整 bytes 尾部任意追加。
- `SimulationWorld`、战斗配置、装备状态、伤害队列、命中几何和 resolver 都不继承 `Node`，不引用场景节点，不调用 Godot Physics、Jolt、`CharacterBody3D`、`Area3D` 查询、RID、instance ID、`RandomNumberGenerator`、全局随机数、Timer、动画回调或运行时 NavMesh。
- 模拟只使用平坦 XZ 整数坐标；1 Godot 世界单位等于 1024 模拟单位；中间乘法使用 GDScript `int` 的 int64 范围，不依赖溢出、浮点、`sin`、`cos`、`tan`、`atan2`、`sqrt` 或容器迭代顺序。
- 原始 `.tres`、`.tscn` 和浮点导出属性只允许离线构建器读取；本局创建后只加载 `resources/simulation/combat/combat_config.tres`，模拟 Tick 中不得读取 `WeaponDefinition`、`RangedWeaponDefinition`、`MeleeWeaponDefinition`、`PlayerController` 或 `ZombieTarget`。
- 玩家槽位固定为 `0..3`，本局不复用；玩家 generation 固定为 1。僵尸实体引用必须同时携带 Plan 4 的 `entity_id` 与 `generation`，过期 generation 不得受伤、死亡或产生表现事件。
- 固定武器 ID 为 `WEAPON_PISTOL = 1`、`WEAPON_SMG = 2`、`WEAPON_KNIFE = 3`；初始拥有掩码只包含手枪和匕首，起始装备为手枪，冲锋枪初始未拥有且弹药为 0。
- 当前资源数值必须离线转换为整数：手枪伤害 35、射程 24576、冷却 10 Tick；冲锋枪伤害 25、射程 28672、冷却 8 Tick、弹药上限 360；匕首伤害 35、命中延迟 7 Tick、动作锁 17 Tick、攻击冷却 30 Tick；玩家受击硬直 8 Tick、攻击锁 36 Tick、击退速度 273 模拟单位/Tick。
- 冷却采用 `ceil(30 / attacks_per_second)`，秒数采用 `ceil(seconds * 30)`，世界单位采用 `round(value * 1024)`，伤害采用 `round(value)`；这些舍入规则只在离线构建器中执行并写入生成资源。
- 散布使用离线转换的整数横向偏移：`round(tan(deg_to_rad(degrees)) * 1024)`；运行时以 `spread_units_x30` 保存精度，每 Tick 只做整数恢复，每次射击只从该玩家独立 Park–Miller 流采样一次，不为穿透目标重新采样。
- 枪械命中使用整数线段与僵尸圆形投影；匕首使用整数前向矩形并扩张僵尸半径；候选按线段投影或距离平方、实体 ID、generation 排序，同值优先较小实体引用。
- 地图遮挡只能通过 Plan 2 的 `SimMapGrid.has_clear_line`、`first_blocked_cell_on_line` 和 `cell_id_to_center` 读取；不得复制第二套 DDA/supercover，不得回退到 Godot 射线、视觉碰撞体或旧 `RangedWeapon._intersect_shot()`。
- 装备切换在固定系统第 2 阶段执行；玩家/僵尸攻击在第 9 阶段只追加伤害；Plan 6 爆炸在第 10 阶段向同一队列追加；`SimDamageResolver` 只在第 11 阶段统一排序并应用一次；死亡记录必须留给第 12 阶段的 Plan 6 掉落、拾取和波次消费。
- 同一 Tick 的伤害排序键固定为 `(phase, source_entity_id, source_generation, local_sequence, target_entity_id, target_generation, target_kind)`；不得依赖 append 顺序、`Dictionary`、默认 `Array.sort()` 稳定性或节点树顺序。
- 战斗热路径的命中候选、伤害、事件与死亡记录都必须使用构造时预分配的定长数组；不得为每发射击创建 `Dictionary`、可增长 `Array` 或临时 Shape/Query 对象。
- 死亡在伤害阶段立即使玩法实体失效；尸体动画、音频长度和 FX 生命周期不影响存活数、后续命中、掉落或 Hash。
- 表现事件只包含整数数据，候选按 `(phase, source_entity_id, source_generation, local_sequence, target_entity_id, target_generation, event_type)` 稳定排序；`event_id = tick * 4096 + sorted_index + 1`，每 Tick 超过 4096 条时本 Tick确定性失败，不动态扩容。
- 表现事件、死亡记录、装备状态、弹药、冷却、待命中 Tick、散布和战斗 PRNG 全部进入规范状态与逐 Tick Hash；动画、音频、粒子、血迹、HUD、摄像机和节点 Transform 不进入 Hash。
- 保留 `scripts/combat/weapons/ranged_weapon.gd`、`melee_weapon.gd`、`equipment_controller.gd`、`scripts/combat/zombie_target.gd`、当前武器资源与 `DemoArena` 旧路径作为参考和默认回退；本计划不修改、不删除、不旁接这些旧玩法节点。
- 新模拟只存在于旁路验证世界；禁止同一局按玩家、武器或目标混用新旧伤害判定。Plan 7 完成表现桥之前，本计划不改变主菜单或 `DemoArena` 默认入口。
- 所有行为必须先写失败验证并确认 RED，再写最小实现并确认 GREEN；验证失败、容量耗尽、过期实体引用或双实例首个分歧都必须停止 Plan 6～8。
- 执行前必须询问用户是否使用 worktree，默认不使用；只有用户同意才按 `using-git-worktrees` 建立隔离目录。
- 本计划不包含 `git add`、`git commit`、`git reset`、`git rebase` 或 squash 步骤；全部实现与验证完成后由用户自行审阅并提交整个 Plan 的改动。

---

## 文件结构与稳定接口

| 路径 | 职责 |
| --- | --- |
| `scripts/simulation/combat/sim_combat_config.gd` | 运行时只含整数/PackedInt32Array 的三武器、僵尸攻击伤害、玩家受击战斗参数和容量配置，以及规范编码；玩家初始生命继续由 Plan 3 `PlayerSimConfig` 唯一拥有。 |
| `tools/simulation/build_sim_combat_config.gd` | 离线读取当前浮点武器资源和旧场景导出值，按唯一舍入规则生成整数配置。 |
| `resources/simulation/combat/combat_config.tres` | 提交到项目的生成配置；运行时战斗只加载此资源。 |
| `scripts/simulation/combat/sim_equipment_state.gd` | 四玩家装备拥有、已装备武器、弹药、冷却、匕首待命中、散布与独立 PRNG SoA。 |
| `scripts/simulation/combat/sim_hit_candidate_buffer.gd` | 固定容量命中候选 SoA，保存投影/距离、目标 ID+generation 和量化命中点。 |
| `scripts/simulation/combat/sim_combat_geometry.gd` | 消费 Plan 2 supercover 的世界遮挡结果，执行整数线段/圆命中、穿透候选排序与匕首矩形命中。 |
| `scripts/simulation/combat/sim_damage_queue.gd` | 固定容量伤害 SoA、ID+generation 字段、稳定插入排序和只读 getter。 |
| `scripts/simulation/combat/sim_combat_system.gd` | 第 2 阶段装备切换、第 9 阶段枪械/匕首/僵尸意图解析，只追加伤害和表现候选。 |
| `scripts/simulation/combat/sim_damage_resolver.gd` | 第 11 阶段统一扣血、死亡失效、死亡记录和伤害/死亡表现候选。 |
| `scripts/simulation/events/sim_presentation_event.gd` | Plan 7 消费的不可变整数表现事件记录和事件类型常量。 |
| `scripts/simulation/events/sim_event_buffer.gd` | 保留 Plan 4 攻击意图，并增加固定容量表现候选、死亡记录、稳定排序和 event_id 分配。 |
| `scripts/simulation/players/sim_player_state.gd` | 保留 Plan 3 四槽 SoA，增加 generation 查询、实体匹配、整数伤害和倒地写接口。 |
| `scripts/simulation/world/simulation_world.gd` | 配置战斗依赖、执行固定阶段、暴露 Plan 6/7 只读接缝并扩展规范状态。 |
| `scripts/simulation/testing/first_divergence_harness.gd` | 增加手枪/冲锋枪/匕首双实例直接命令与 codec 命令逐 Tick 比较。 |
| `tools/validation/validate_frame_sync_combat_config.gd` | 验证离线转换、整数资源、重复构建和当前 SMG 兼容映射。 |
| `tools/validation/validate_frame_sync_combat_actions.gd` | 验证装备、弹药、射速、散布 PRNG、枪械穿透、遮挡和匕首命中。 |
| `tools/validation/validate_frame_sync_combat_resolution.gd` | 验证稳定伤害顺序、玩家/僵尸死亡、死亡记录和稳定表现事件。 |
| `tools/validation/validate_frame_sync_combat_replay.gd` | 验证双实例中三武器命中、弹药、死亡、event_id 和 Hash 逐 Tick 相同。 |

#### 供 Plan 6 消费的接口

```gdscript
# scripts/simulation/combat/sim_damage_queue.gd
enum TargetKind { PLAYER = 1, ZOMBIE = 2 }
enum DamageKind { RANGED = 1, MELEE = 2, ZOMBIE_MELEE = 3, EXPLOSION = 4 }
const PHASE_COMBAT := 9
const PHASE_EXPLOSION := 10

func append(
	phase: int,
	source_entity_id: int,
	source_generation: int,
	local_sequence: int,
	target_kind: int,
	target_entity_id: int,
	target_generation: int,
	amount: int,
	origin_x: int,
	origin_z: int,
	hit_x: int,
	hit_z: int,
	damage_kind: int
) -> bool
func sort_canonical() -> void
func count() -> int
func phase_at(index: int) -> int
func source_entity_id_at(index: int) -> int
func source_generation_at(index: int) -> int
func local_sequence_at(index: int) -> int
func target_kind_at(index: int) -> int
func target_entity_id_at(index: int) -> int
func target_generation_at(index: int) -> int
func amount_at(index: int) -> int
func origin_x_at(index: int) -> int
func origin_z_at(index: int) -> int
func hit_x_at(index: int) -> int
func hit_z_at(index: int) -> int
func damage_kind_at(index: int) -> int
```

Plan 6 的爆炸只能在固定第 10 阶段用 `DamageKind.EXPLOSION` 向上述队列追加，不得建立第二条扣血链。世界公开 `get_damage_queue() -> SimDamageQueue`，但只有第 11 阶段的 `SimDamageResolver.apply_all` 能清空并应用它。

```gdscript
# scripts/simulation/combat/sim_equipment_state.gd
func owns_weapon(player_slot: int, weapon_id: int) -> bool
func get_equipped_weapon(player_slot: int) -> int
func get_ammo(player_slot: int, weapon_id: int) -> int
func grant_weapon(player_slot: int, weapon_id: int, ammo: int) -> bool
func add_ammo(player_slot: int, weapon_id: int, amount: int) -> int
func equip_weapon(player_slot: int, weapon_id: int, tick: int) -> bool
func cycle(player_slot: int, delta: int, tick: int) -> int
func apply_hit_lock(player_slot: int, until_tick: int) -> void
func cancel_pending_melee(player_slot: int) -> void
```

此状态只管理手枪、冲锋枪和匕首；Plan 6 的油桶、放置物和通用库存必须建立独立 SoA。`grant_weapon()` 只授予所有权/加弹，不隐式装备；`smg_pickup.auto_equip = true` 时 Plan 6 必须在 grant 成功后显式调用 `equip_weapon(player_slot, weapon_id, current_tick)`。重开通过新建 `SimulationWorld`/`SimEquipmentState` 复位，不提供热 reset 让上一局 PRNG、冷却或待命中状态泄漏。

```gdscript
# scripts/simulation/events/sim_event_buffer.gd
func death_record_count() -> int
func death_victim_kind(index: int) -> int
func death_victim_id(index: int) -> int
func death_victim_generation(index: int) -> int
func death_killer_id(index: int) -> int
func death_killer_generation(index: int) -> int
func death_pos_x(index: int) -> int
func death_pos_z(index: int) -> int
```

死亡记录只在本 Tick 第 12 阶段读取；下一个 Tick 的 `begin_tick()` 才清零。Plan 6 的掉落归属必须同时校验 ID 与 generation。

#### 供 Plan 7 消费的接口

`scripts/simulation/events/sim_presentation_event.gd` 定义以下整数事件类型：

```gdscript
const WEAPON_FIRED := 1
const MELEE_STARTED := 2
const DAMAGE_APPLIED := 3
const ENTITY_DIED := 4
const EQUIPMENT_CHANGED := 5
const AMMO_CHANGED := 6
const WORLD_IMPACT := 7

var tick: int
var event_id: int
var event_type: int
var source_entity_id: int
var source_generation: int
var target_entity_id: int
var target_generation: int
var origin_x: int
var origin_z: int
var position_x: int
var position_z: int
var heading: int
var value: int
var aux: int
```

- `WEAPON_FIRED`：`origin` 为模拟枪口/玩家点，`position` 为精确整数散布射线终点，`heading` 为把 `shot_dx/shot_dz` 按最大点积、同值较小 heading 量化到 1～16 的表现方向，`value` 为 weapon ID，`aux` 为剩余弹药或 `-1`。
- `MELEE_STARTED`：`value` 为 weapon ID，`aux` 为命中延迟 Tick。
- `DAMAGE_APPLIED`：`origin` 为来源位置，`position` 为命中位置，`value` 为实际伤害，`aux` 为 `DamageKind`。
- `ENTITY_DIED`：`position` 为死亡位置，`value` 为 `TargetKind`。
- `EQUIPMENT_CHANGED` / `AMMO_CHANGED`：`value` 为 weapon ID，`aux` 为当前弹药或 `-1`。
- `WORLD_IMPACT`：`position` 为首次阻挡格采样点，`value` 为 weapon ID。

`SimEventBuffer.presentation_event_count() -> int`、`presentation_event_at(index: int) -> SimPresentationEvent` 提供只读索引；`presentation_event_at()` 每次返回字段副本而不是内部候选对象。`SimulationWorld.get_last_presentation_events() -> Array[SimPresentationEvent]` 在 `step()` 成功后返回不可回写模拟的副本数组。

### Task 1：离线生成并锁定整数 `SimCombatConfig`

**Files:**

- Create: `scripts/simulation/combat/sim_combat_config.gd`
- Create: `tools/simulation/build_sim_combat_config.gd`
- Create: `resources/simulation/combat/combat_config.tres`
- Create: `tools/validation/validate_frame_sync_combat_config.gd`

**Interfaces:**

- Consumes: `resources/weapons/pistol.tres`、`resources/weapons/smg.tres`、`resources/weapons/knife.tres`、`scenes/weapons/Pistol.tscn`、`scenes/weapons/Smg.tscn`、`scenes/weapons/Knife.tscn`、`scenes/player/Player.tscn`、`scenes/targets/ZombieTarget.tscn`；玩家初始生命继续消费 Plan 3 的 `PlayerSimConfig.initial_health`，combat config 只转换 `Player.tscn` 的受击硬直/攻击锁/击退速度。
- Produces: `SimCombatConfig.WEAPON_PISTOL/WEAPON_SMG/WEAPON_KNIFE`、`validate() -> Error`、`encode_hash_payload() -> PackedByteArray`、`get_content_hash() -> PackedByteArray`、`validate_content_hash() -> bool`、全部整数数组 getter；`BuildSimCombatConfig.build() -> SimCombatConfig`、`save_to(path: String) -> Error`。

- [ ] **Step 1：先写缺少整数配置和构建器的失败验证**

创建验证脚本，预加载尚不存在的两个脚本，并固定三武器身份、当前 SMG 映射和关键整数值：

```gdscript
extends SceneTree

const SimCombatConfig = preload("res://scripts/simulation/combat/sim_combat_config.gd")
const BuildSimCombatConfig = preload("res://tools/simulation/build_sim_combat_config.gd")

func _init() -> void:
	var failures: Array[String] = []
	var config := BuildSimCombatConfig.build()
	_expect(config.validate() == OK, "生成配置必须通过整数上界验证", failures)
	_expect(config.weapon_damage[SimCombatConfig.WEAPON_PISTOL] == 35, "手枪伤害必须转换为 35", failures)
	_expect(config.weapon_cooldown_ticks[SimCombatConfig.WEAPON_PISTOL] == 10, "手枪冷却必须是 10 Tick", failures)
	_expect(config.weapon_damage[SimCombatConfig.WEAPON_SMG] == 25, "SPEC 步枪槽位必须映射到当前 SMG 的 25 伤害", failures)
	_expect(config.weapon_max_ammo[SimCombatConfig.WEAPON_SMG] == 360, "SMG 弹药上限必须是 360", failures)
	_expect(config.weapon_damage[SimCombatConfig.WEAPON_KNIFE] == 35, "匕首伤害必须转换为 35", failures)
	_expect(config.melee_impact_delay_ticks[SimCombatConfig.WEAPON_KNIFE] == 7, "0.22 秒必须向上转换为 7 Tick", failures)
	_expect(config.player_hit_stun_ticks == 8, "0.24 秒受击硬直必须转换为 8 Tick", failures)
	_expect(config.player_attack_lock_ticks == 36, "1.2 秒攻击锁必须转换为 36 Tick", failures)
	_expect(config.player_knockback_speed_per_tick == 273, "8 world units/s 必须转换为 273 模拟单位/Tick", failures)
	_finish(failures)
```

- [ ] **Step 2：运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_config.gd
```

Expected: 非零退出，错误指向缺少 `sim_combat_config.gd` 或 `build_sim_combat_config.gd`；不得临时读取旧节点后跳过配置断言。

- [ ] **Step 3：实现只含整数的配置资源和规范编码**

`SimCombatConfig` 必须 `extends Resource`，导出字段只能是 `int`、`PackedInt32Array` 或由整数构成的 `PackedByteArray`。武器数组长度固定为 4，索引 0 保留，1～3 分别是手枪、SMG、匕首：

```gdscript
extends Resource
class_name SimCombatConfig

const SCHEMA_VERSION := 1
const WEAPON_PISTOL := 1
const WEAPON_SMG := 2
const WEAPON_KNIFE := 3
const WEAPON_ARRAY_SIZE := 4
const KIND_RANGED := 1
const KIND_MELEE := 2
const TRIGGER_PRESS := 0
const TRIGGER_HOLD := 1

@export var schema_version := SCHEMA_VERSION
@export var weapon_kind := PackedInt32Array()
@export var trigger_mode := PackedInt32Array()
@export var weapon_damage := PackedInt32Array()
@export var weapon_cooldown_ticks := PackedInt32Array()
@export var weapon_range_units := PackedInt32Array()
@export var weapon_uses_ammo := PackedInt32Array()
@export var weapon_max_ammo := PackedInt32Array()
@export var penetration_per_mille := PackedInt32Array()
@export var max_penetration_count := PackedInt32Array()
@export var spread_base_units_x30 := PackedInt32Array()
@export var spread_max_units_x30 := PackedInt32Array()
@export var spread_increase_units_x30 := PackedInt32Array()
@export var spread_recovery_units_per_second := PackedInt32Array()
@export var melee_impact_delay_ticks := PackedInt32Array()
@export var melee_lock_ticks := PackedInt32Array()
@export var melee_half_width_units := PackedInt32Array()
@export var melee_forward_reach_units := PackedInt32Array()
@export var initial_owned_mask := 0
@export var starting_weapon_id := 0
@export var zombie_attack_damage := 0
@export var player_hit_stun_ticks := 0
@export var player_attack_lock_ticks := 0
@export var player_knockback_speed_per_tick := 0
@export var damage_capacity := 1024
@export var presentation_event_capacity := 4096
@export var content_hash := PackedByteArray()
```

`validate()` 必须检查 schema、所有数组长度、ID 0 全零、三武器 kind/trigger 合法、伤害/冷却/范围/弹药/穿透/散布/近战数值上界、`initial_owned_mask == 10`、`starting_weapon_id == 1`、`zombie_attack_damage == 10`、`player_hit_stun_ticks == 8`、`player_attack_lock_ticks == 36`、`player_knockback_speed_per_tick == 273`、容量不超过规范状态可编码范围，以及 `content_hash.size() == 32`。`encode_hash_payload()` 以 ASCII `SCOM`、schema 和上述字段声明顺序逐 int 写入 `LittleEndianWriter`，明确排除 `content_hash` 自身，不序列化 Resource 路径或 StringName。`get_content_hash()` 返回副本；`validate_content_hash()` 比较 `StateHasher.hash_canonical(encode_hash_payload())` 与字段值。

- [ ] **Step 4：实现离线唯一转换规则并生成资源**

构建器使用浮点仅限离线进程，先验证三个源资源的稳定 ID 恰为 `pistol/smg/knife`，再执行以下转换：

```gdscript
const TICKS_PER_SECOND := 30
const UNITS_PER_WORLD_UNIT := 1024

static func _seconds_to_ticks(seconds: float) -> int:
	return ceili(seconds * TICKS_PER_SECOND)

static func _attacks_per_second_to_ticks(attacks_per_second: float) -> int:
	return ceili(float(TICKS_PER_SECOND) / attacks_per_second)

static func _world_units(value: float) -> int:
	return roundi(value * UNITS_PER_WORLD_UNIT)

static func _world_speed_per_tick(value_per_second: float) -> int:
	return roundi(value_per_second * UNITS_PER_WORLD_UNIT / TICKS_PER_SECOND)

static func _spread_offset_units(degrees: float) -> int:
	return roundi(tan(deg_to_rad(degrees)) * UNITS_PER_WORLD_UNIT)

static func _per_mille(value: float) -> int:
	return roundi(value * 1000.0)
```

生成数组的精确值必须为：

```gdscript
config.weapon_kind = PackedInt32Array([0, 1, 1, 2])
config.trigger_mode = PackedInt32Array([0, 0, 1, 0])
config.weapon_damage = PackedInt32Array([0, 35, 25, 35])
config.weapon_cooldown_ticks = PackedInt32Array([0, 10, 8, 30])
config.weapon_range_units = PackedInt32Array([0, 24576, 28672, 0])
config.weapon_uses_ammo = PackedInt32Array([0, 0, 1, 0])
config.weapon_max_ammo = PackedInt32Array([0, 0, 360, 0])
config.penetration_per_mille = PackedInt32Array([0, 0, 0, 0])
config.max_penetration_count = PackedInt32Array([0, 0, 0, 0])
config.spread_base_units_x30 = PackedInt32Array([0, 180, 270, 0])
config.spread_max_units_x30 = PackedInt32Array([0, 1620, 2700, 0])
config.spread_increase_units_x30 = PackedInt32Array([0, 420, 360, 0])
config.spread_recovery_units_per_second = PackedInt32Array([0, 32, 27, 0])
config.melee_impact_delay_ticks = PackedInt32Array([0, 0, 0, 7])
config.melee_lock_ticks = PackedInt32Array([0, 0, 0, 17])
config.melee_half_width_units = PackedInt32Array([0, 0, 0, 768])
config.melee_forward_reach_units = PackedInt32Array([0, 0, 0, 2048])
config.initial_owned_mask = 10
config.starting_weapon_id = 1
config.zombie_attack_damage = 10
config.player_hit_stun_ticks = 8
config.player_attack_lock_ticks = 36
config.player_knockback_speed_per_tick = 273
config.content_hash = StateHasher.hash_canonical(config.encode_hash_payload())
```

匕首前向 2048 来自当前旧命中语义 `-offset.z + size.z / 2 + 0.45`；0.45 只在构建器作为旧配置迁移常量使用，运行时资源只保存结果 2048。执行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/simulation/build_sim_combat_config.gd -- --output res://resources/simulation/combat/combat_config.tres
```

Expected: 退出码 0，生成资源加载为 `SimCombatConfig`，资源正文没有浮点数组、Vector、StringName weapon ID 或旧场景引用。

- [ ] **Step 5：验证重复构建、规范字节和 Headless 导入**

验证脚本连续调用两次 `BuildSimCombatConfig.build()`，断言 `encode_hash_payload()` 字节完全相同、`content_hash` 完全相同且双方 `validate_content_hash()` 为 true；另断言源 `smg.tres` 的 `weapon_id == &"smg"`，并断言项目中不存在 `resources/weapons/rifle.tres` 或 `scenes/weapons/Rifle.tscn`。Plan 6 的 `SimulationConfigBundle` 将以固定组件顺序聚合这个 32-byte hash；Plan 5 不另造最终 manifest hash。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_config.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 第一条打印 `validate_frame_sync_combat_config: PASS`；两条命令均退出 0。Task 1 可独立验收；不提交。

### Task 2：实现装备、弹药、散布、枪械穿透和匕首命中

**Files:**

- Create: `scripts/simulation/combat/sim_equipment_state.gd`
- Create: `scripts/simulation/combat/sim_hit_candidate_buffer.gd`
- Create: `scripts/simulation/combat/sim_combat_geometry.gd`
- Create: `scripts/simulation/combat/sim_damage_queue.gd`
- Create: `scripts/simulation/combat/sim_combat_system.gd`
- Create: `scripts/simulation/events/sim_presentation_event.gd`
- Modify: `scripts/simulation/events/sim_event_buffer.gd`
- Create: `tools/validation/validate_frame_sync_combat_actions.gd`

**Interfaces:**

- Consumes: `SimCombatConfig`、`PlayerFrameCommand`、`SimPlayerState.is_active/is_alive/entity_id_for_slot/generation_for_slot/get_position_units`、`ZombieState` 全部只读 SoA 与 ID+generation 查询、Plan 4 `ZombieSimConfig.radius_units`、`SimMapGrid.has_clear_line/first_blocked_cell_on_line/cell_id_to_center`、Plan 4 的僵尸攻击意图 getter。
- Produces: `SimEquipmentState.new(config: SimCombatConfig, session_seed: int)`、本计划“供 Plan 6 消费的接口”、`encode_canonical(writer: LittleEndianWriter) -> void`。
- Produces: `SimHitCandidateBuffer.new(capacity: int)`、`clear() -> void`、`append(sort_value: int, target_id: int, target_generation: int, hit_x: int, hit_z: int) -> bool`、`sort_canonical() -> void`、`count() -> int`、`sort_value_at/target_entity_id_at/target_generation_at/hit_x_at/hit_z_at(index: int) -> int`。
- Produces: `SimCombatGeometry.collect_ranged_candidates(origin_x: int, origin_z: int, end_x: int, end_z: int, zombie_radius_units: int, zombies: ZombieState, map_grid: SimMapGrid, out_candidates: SimHitCandidateBuffer) -> bool`；`select_melee_target(origin_x: int, origin_z: int, heading: int, half_width_units: int, forward_reach_units: int, zombie_radius_units: int, zombies: ZombieState, map_grid: SimMapGrid, out_candidate: SimHitCandidateBuffer) -> bool`。
- Produces: `SimDamageQueue.new(capacity: int)`、本计划稳定 append/sort/count 接口及逐字段 getter、`clear() -> void`、`encode_canonical(writer) -> void`。
- Produces: `SimCombatSystem.new(config: SimCombatConfig, zombie_radius_units: int, zombie_capacity: int)`、`begin_tick(tick: int) -> void`、`apply_equipment_phase(tick: int, frame: LocalFrameCommandSet, players: SimPlayerState, equipment: SimEquipmentState, events: SimEventBuffer) -> bool`、`resolve_attack_phase(tick: int, frame: LocalFrameCommandSet, players: SimPlayerState, zombies: ZombieState, map_grid: SimMapGrid, equipment: SimEquipmentState, queue: SimDamageQueue, events: SimEventBuffer) -> bool`、`queue_zombie_attack_intents(tick: int, players: SimPlayerState, zombies: ZombieState, map_grid: SimMapGrid, events: SimEventBuffer, queue: SimDamageQueue) -> bool`。
- Produces: `SimEventBuffer.configure_combat_capacities(presentation_capacity: int, death_capacity: int) -> bool`、Step 4 定义完整签名的 `append_presentation_candidate` / `append_death_record`、`finalize_presentation_events(tick: int) -> bool`、`encode_combat_pending(writer: LittleEndianWriter) -> void`、表现事件与死亡记录 getter；`SimPresentationEvent` 的 1～7 号类型和整数记录字段。

- [ ] **Step 1：写装备、射速、散布、穿透、遮挡和匕首的失败验证**

验证脚本创建 slot 0 玩家 `(0, 0)`、heading 1；枪械目标固定为 `(4096, 0)` 与 `(7168, 0)`，墙体夹具把两者之间的 cell 标为阻挡；匕首目标固定为 `(1536, -256)` 与 `(1536, 256)`，两者距离相同且前者实体 ID 较小。帧 helper 完整定义为：

```gdscript
func _frame(tick: int, action_bits: int, equipment_delta: int = 0) -> LocalFrameCommandSet:
	var commands: Array[PlayerFrameCommand] = [
		PlayerFrameCommand.new(1, action_bits, equipment_delta, 0),
		PlayerFrameCommand.neutral(),
		PlayerFrameCommand.neutral(),
		PlayerFrameCommand.neutral(),
	]
	return LocalFrameCommandSet.new(tick, 0b0001, commands)
```

夹具创建 Plan 4 `SimEventBuffer` 后必须先断言 `events.configure_combat_capacities(config.presentation_event_capacity, zombies.capacity + 4)` 为 true；此调用发生在首个 `events.begin_tick()` 之前。所有片段都按世界顺序先调用 `events.begin_tick(tick)`，再调用 `combat.begin_tick(tick)`。

先固定以下契约：

```gdscript
var equipment := SimEquipmentState.new(config, 1)
_expect(equipment.get_equipped_weapon(0) == SimCombatConfig.WEAPON_PISTOL, "玩家必须从手枪开始", failures)
_expect(not equipment.owns_weapon(0, SimCombatConfig.WEAPON_SMG), "SMG 必须初始未拥有", failures)
_expect(equipment.cycle(0, 1, 0) == SimCombatConfig.WEAPON_KNIFE, "切换必须跳过未拥有 SMG", failures)
_expect(equipment.grant_weapon(0, SimCombatConfig.WEAPON_SMG, 3), "授予 SMG 必须同时加入弹药", failures)
_expect(equipment.get_ammo(0, SimCombatConfig.WEAPON_SMG) == 3, "SMG 必须保存整数弹药", failures)
_expect(equipment.equip_weapon(0, SimCombatConfig.WEAPON_SMG, 0), "首次拾取 auto_equip 必须能显式装备 SMG", failures)
_expect(equipment.equip_weapon(0, SimCombatConfig.WEAPON_PISTOL, 0), "枪械验证前必须显式切回手枪", failures)

var pistol_pressed_frame := _frame(0, PlayerFrameCommand.USE_PRESSED)
var pistol_held_only_frame := _frame(1, PlayerFrameCommand.USE_HELD)
events.begin_tick(0)
combat.begin_tick(0)
combat.resolve_attack_phase(0, pistol_pressed_frame, players, zombies, map_grid, equipment, queue, events)
_expect(queue.count() == 1, "手枪按下边沿必须产生一条命中伤害", failures)
_expect(events.finalize_presentation_events(0), "手枪事件必须成功 finalized", failures)
var pistol_fire := events.presentation_event_at(0)
_expect(pistol_fire.event_type == SimPresentationEvent.WEAPON_FIRED, "手枪必须只产生一次开火事件", failures)
_expect(pistol_fire.position_x == queue.hit_x_at(0) and pistol_fire.position_z == queue.hit_z_at(0), "当前 0/0 穿透配置必须把 tracer 截止在首个僵尸命中点", failures)
events.begin_tick(1)
combat.begin_tick(1)
combat.resolve_attack_phase(1, pistol_held_only_frame, players, zombies, map_grid, equipment, queue, events)
_expect(queue.count() == 1, "手枪只有 held 不得再次开火", failures)
```

同一脚本用真实 Tick 循环固定 SMG 射速与弹药：

```gdscript
queue.clear()
equipment.equip_weapon(0, SimCombatConfig.WEAPON_SMG, 0)
for tick in range(9):
	events.begin_tick(tick)
	combat.begin_tick(tick)
	combat.resolve_attack_phase(
		tick,
		_frame(tick, PlayerFrameCommand.USE_HELD),
		players, zombies, map_grid, equipment, queue, events
	)
	if tick == 0:
		_expect(queue.count() == 1 and equipment.get_ammo(0, SimCombatConfig.WEAPON_SMG) == 2, "SMG tick 0 必须开火并消耗一发", failures)
	elif tick < 8:
		_expect(queue.count() == 1, "SMG tick 1..7 必须保持冷却", failures)
_expect(queue.count() == 2, "SMG tick 8 必须产生第二发", failures)
_expect(equipment.get_ammo(0, SimCombatConfig.WEAPON_SMG) == 1, "SMG 两发后必须剩 1 发", failures)
```

用两个 `SimEquipmentState.new(config, 1)` 执行相同射击 Tick，逐次断言 `rng_state[0]`、`spread_units_x30`、`WEAPON_FIRED.position_x/z` 完全相同。穿透使用验证专用配置副本，只修改整数数组：

```gdscript
var penetration_config := config.duplicate(true) as SimCombatConfig
penetration_config.penetration_per_mille[SimCombatConfig.WEAPON_PISTOL] = 500
penetration_config.max_penetration_count[SimCombatConfig.WEAPON_PISTOL] = 1
penetration_config.content_hash = StateHasher.hash_canonical(penetration_config.encode_hash_payload())
var penetration_combat := SimCombatSystem.new(penetration_config, zombie_config.radius_units, 512)
queue.clear()
equipment.equip_weapon(0, SimCombatConfig.WEAPON_PISTOL, 20)
events.begin_tick(20)
penetration_combat.begin_tick(20)
penetration_combat.resolve_attack_phase(
	20, _frame(20, PlayerFrameCommand.USE_PRESSED),
	players, two_aligned_zombies, clear_map_grid, equipment, queue, events
)
queue.sort_canonical()
_expect(queue.count() == 2, "一额外穿透必须产生两条伤害", failures)
_expect(queue.amount_at(0) == 35 and queue.amount_at(1) == 17, "穿透伤害必须按 500‰ floor 衰减", failures)
```

在两只僵尸之间放置阻挡格后重跑，断言后方 ID 不在 queue。匕首使用明确 Tick：

```gdscript
queue.clear()
equipment.equip_weapon(0, SimCombatConfig.WEAPON_KNIFE, 100)
events.begin_tick(100)
combat.begin_tick(100)
combat.resolve_attack_phase(
	100, _frame(100, PlayerFrameCommand.USE_PRESSED),
	players, melee_zombies, map_grid, equipment, queue, events
)
_expect(queue.count() == 0, "匕首启动 Tick 不得提前伤害", failures)
for tick in range(101, 108):
	events.begin_tick(tick)
	combat.begin_tick(tick)
	combat.resolve_attack_phase(
		tick, _frame(tick, 0), players, melee_zombies,
		map_grid, equipment, queue, events
	)
_expect(queue.count() == 1, "匕首第 7 Tick 只能命中一个目标", failures)
_expect(queue.target_entity_id_at(0) == smaller_nearest_id, "匕首等距必须选较小实体 ID", failures)
```

- [ ] **Step 2：运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_actions.gd
```

Expected: 非零退出，首先报告缺少 `SimEquipmentState`、`SimCombatGeometry`、`SimDamageQueue` 或 `SimCombatSystem`；不得用旧武器节点代替测试夹具。

- [ ] **Step 3：实现固定四槽装备 SoA 与独立战斗 PRNG**

预分配以下数组，不为未启用槽位动态删减：

```gdscript
var equipped_weapon := PackedInt32Array()       # 4
var owned_mask := PackedInt32Array()            # 4
var ammo := PackedInt32Array()                  # 4 * 4
var next_attack_tick := PackedInt32Array()      # 4
var attack_lock_until_tick := PackedInt32Array() # 4
var melee_impact_tick := PackedInt32Array()     # 4, -1 表示无待结算
var melee_weapon_id := PackedInt32Array()       # 4
var spread_units_x30 := PackedInt32Array()      # 4 * 4
var rng_state := PackedInt32Array()              # 4
```

每个玩家流的初始种子固定为：

```gdscript
var seed := FixedMath.euclidean_mod(
	session_seed + (player_slot + 1) * 104729 - 1,
	2147483646
) + 1
```

`equip_weapon(player_slot, weapon_id, tick)` 只接受已拥有武器；切换成功时取消该玩家待结算匕首、把离开的远程武器散布重置为 base、令 `next_attack_tick[player_slot] = tick`，但不得缩短 `attack_lock_until_tick`。`cycle(player_slot, delta, tick)` 最多检查三件武器，按 ID 1→2→3→1 或反向循环，跳过未拥有项并复用 `equip_weapon()`。`grant_weapon()` 只置拥有 bit 并用 `add_ammo()` 限制到配置上限，不自动装备；无限弹药武器的 `get_ammo()` 返回 `-1`。

- [ ] **Step 4：实现固定容量伤害队列和整数命中几何**

`SimHitCandidateBuffer` 与 `SimDamageQueue` 都为每个字段预分配同长 `PackedInt32Array`，append 越界返回 `false`。候选 buffer 保存 `sort_value/target_entity_id/target_generation/hit_x/hit_z`，枪械的 `sort_value` 是 projection，匕首是距离平方；两者都按 sort value、target ID、generation 插入排序。伤害队列逐字段比较，不使用默认不稳定排序：

```gdscript
static func _less(left: int, right: int, queue: SimDamageQueue) -> bool:
	if queue.phase[left] != queue.phase[right]: return queue.phase[left] < queue.phase[right]
	if queue.source_entity_id[left] != queue.source_entity_id[right]: return queue.source_entity_id[left] < queue.source_entity_id[right]
	if queue.source_generation[left] != queue.source_generation[right]: return queue.source_generation[left] < queue.source_generation[right]
	if queue.local_sequence[left] != queue.local_sequence[right]: return queue.local_sequence[left] < queue.local_sequence[right]
	if queue.target_entity_id[left] != queue.target_entity_id[right]: return queue.target_entity_id[left] < queue.target_entity_id[right]
	if queue.target_generation[left] != queue.target_generation[right]: return queue.target_generation[left] < queue.target_generation[right]
	return queue.target_kind[left] < queue.target_kind[right]
```

地图阻挡必须复用 Plan 2 的整数 supercover。`first_blocked_cell_on_line()` 返回 `SimMapGrid.NO_BLOCKED_CELL_ID (-1)` 表示无遮挡、`SimMapGrid.OUT_OF_BOUNDS_CELL_ID (-2)` 表示端点非法/越界、其他非负值为首阻挡 cell ID；不得在战斗模块内复制 DDA：

```gdscript
var blocked_cell := map_grid.first_blocked_cell_on_line(origin_x, origin_z, end_x, end_z)
if blocked_cell == SimMapGrid.OUT_OF_BOUNDS_CELL_ID:
	return _fail("combat ray endpoint is outside the configured map")
var tracer_end := Vector2i(end_x, end_z)
if blocked_cell >= 0:
	tracer_end = map_grid.cell_id_to_center(blocked_cell)
```

`collect_ranged_candidates()` 先要求 `line_sq > 0`，否则返回 `false`。每个线段/圆候选再要求 `0 <= projection <= line_sq`，并用 `rel_sq * line_sq - projection * projection <= radius_sq * line_sq` 判断相交，禁止开根号。量化命中点固定为线段上离圆心最近的点：`hit_x = origin_x + FixedMath.floor_div(dx * projection, line_sq)`、`hit_z = origin_z + FixedMath.floor_div(dz * projection, line_sq)`；然后调用 `map_grid.has_clear_line(origin_x, origin_z, hit_x, hit_z)`，false 的候选在进入穿透排序前剔除。候选按 projection、entity ID、generation 插入排序。匕首候选使用面对方向的前向/侧向 dot，范围分别扩张僵尸半径，且对玩家点到目标点调用同一 `has_clear_line()`；无遮挡候选按距离平方、entity ID、generation 只选一个。

`SimCombatSystem` 构造时按 `zombie_capacity` 预分配一个可复用 ranged candidate buffer 和一个单项 melee candidate buffer，并预分配长度 4 的 `_player_local_sequence`；每发/每次近战只 `clear()` 后复用，不在 Tick 内 new 或 resize。`_player_local_sequence` 每 Tick 重置，其产生的 sequence 已进入 queue/event 记录，因此它本身属于 Tick scratch，不重复写入 canonical state。

同一 Task 内先扩展 Plan 4 的 `SimEventBuffer`，再让 `SimCombatSystem` 引用它。`configure_combat_capacities()` 只能在首个 `begin_tick()` 前成功一次，按参数预分配表现候选、finalized 事件和死亡记录；不得改变 Plan 4 已存在的僵尸攻击意图容量。候选和死亡记录的完整签名固定为：

```gdscript
func append_presentation_candidate(
	phase: int,
	source_entity_id: int,
	source_generation: int,
	local_sequence: int,
	target_entity_id: int,
	target_generation: int,
	event_type: int,
	origin_x: int,
	origin_z: int,
	position_x: int,
	position_z: int,
	heading: int,
	value: int,
	aux: int
) -> bool

func append_death_record(
	victim_kind: int,
	victim_id: int,
	victim_generation: int,
	killer_id: int,
	killer_generation: int,
	position_x: int,
	position_z: int
) -> bool
```

`SimPresentationEvent` 在本 Task 创建并定义本计划“供 Plan 7 消费的接口”中的 1～7 号类型与全部整数字段。`begin_tick(tick)` 同时清零攻击意图、表现候选、finalized 事件和死亡记录 count，但不 resize；`finalize_presentation_events(tick)` 按全局约束的候选键显式插入排序，分配 `event_id = tick * 4096 + sorted_index + 1`。`encode_combat_pending(writer)` 固定按 candidate → death record → finalized event 编码各自 capacity/count 和当前 count 内全部字段，不编码 Plan 4 攻击意图。`presentation_event_at()` 返回字段副本；候选超过 4096、字段越界或未配置容量时返回 `false`。Task 2 的射击验证必须在目标 Tick 调用 finalize 后读取 `WEAPON_FIRED`，并比较两个独立 buffer 返回副本的 `position_x/z`。

```gdscript
const PHASE_EQUIPMENT := 2
const PHASE_COMBAT := 9
const PHASE_DAMAGE := 11
const PHASE_DEATH := 12
```

- [ ] **Step 5：实现装备阶段和攻击阶段**

`begin_tick(tick)` 把四名玩家的 source-local sequence 重置为 0；同一来源在装备阶段、开火、命中和弹药事件中每 append 一项就递增，穿透命中按候选顺序占用连续 sequence。`apply_equipment_phase()` 严格按 player slot `0..3` 读取 `equipment_delta`，只处理 active/alive 玩家；无变化不产生事件，成功切换追加 `EQUIPMENT_CHANGED` 候选。`resolve_attack_phase()` 对每个 active/alive 玩家先恢复当前远程武器散布；倒地或 `hit_stun_ticks_remaining > 0` 才取消待命中匕首并跳过。仍有效的待命中匕首必须在检查 `attack_lock_until_tick` 之前于精确 impact Tick 结算，因为匕首自己的 17 Tick 动作锁不得取消第 7 Tick 命中；待命中处理后，`tick < attack_lock_until_tick` 只阻止启动新攻击。最后再按 trigger/cooldown/ammo 判断：

```gdscript
var spread := FixedMath.floor_div(equipment.spread_units_x30[index], 30)
var rng := ParkMillerRng.new(equipment.rng_state[player_slot])
var lateral := rng.next_inclusive(-spread, spread)
equipment.rng_state[player_slot] = rng.get_state()
var forward_x := FixedMath.heading_x(players.heading[player_slot])
var forward_z := FixedMath.heading_z(players.heading[player_slot])
var shot_dx := forward_x * 1024 - forward_z * lateral
var shot_dz := forward_z * 1024 + forward_x * lateral
var end_x := origin_x + FixedMath.floor_div(shot_dx * config.weapon_range_units[weapon_id], 1024 * 1024)
var end_z := origin_z + FixedMath.floor_div(shot_dz * config.weapon_range_units[weapon_id], 1024 * 1024)
```

远程武器每 Tick 的恢复公式固定为 `spread_units_x30[index] = maxi(config.spread_base_units_x30[weapon_id], spread_units_x30[index] - config.spread_recovery_units_per_second[weapon_id])`；成功开火后再加 `spread_increase_units_x30` 并截到 max。冷却、空弹或 trigger 不满足时不得消耗弹药、推进 RNG 或增加散布；成功开火才令 `next_attack_tick = tick + weapon_cooldown_ticks[weapon_id]`。每发只更新一次 RNG；穿透伤害依次使用 `next_damage = FixedMath.floor_div(current_damage * coefficient, 1000)`。处理每个排序候选后，若已达到 `max_penetration_count + 1` 或 coefficient 为 0，立即把 tracer 终点设为该目标量化命中点并停止；这保证当前手枪/SMG 的 `0/0` 配置只伤害首个僵尸且弹道不穿过它。若允许继续穿透，则处理后续 clear-line 候选；所有候选处理完仍未停止时，tracer 才结束于首阻挡 cell 中心或最大射程点。每个命中 append 一条 `DamageKind.RANGED`，每发只 append 一个 `WEAPON_FIRED`；有限弹药成功扣减后紧接着 append 一个 `AMMO_CHANGED`，其 `aux` 是剩余弹药。只有射线未被目标截断且 `blocked_cell >= 0` 时才追加 `WORLD_IMPACT`。`blocked_cell == SimMapGrid.OUT_OF_BOUNDS_CELL_ID` 时本 Tick 失败。

匕首按下时记录 `melee_impact_tick = tick + 7`、`next_attack_tick = tick + 30`，令 `attack_lock_until_tick = maxi(attack_lock_until_tick, tick + 17)` 并追加 `MELEE_STARTED`；命中 Tick 仅在玩家仍存活、仍装备同一匕首且待命中未被切换或受击取消时查找一次最近目标并 append `DamageKind.MELEE`，随后无论命中与否都把 pending impact 清为 `-1`。Plan 4 攻击意图按索引读取，先验证 zombie ID+generation 和玩家 ID+固定 generation 1，再取得双方整数位置；只有 `map_grid.has_clear_line(zombie_x, zombie_z, player_x, player_z)` 为 true 才以 `config.zombie_attack_damage` append `DamageKind.ZOMBIE_MELEE`，隔墙意图静默失效且不得改写 Plan 4 已推进的冷却。验证夹具必须分别断言无遮挡意图产生一条伤害、同样位置关系加入阻挡格后产生零条伤害。

- [ ] **Step 6：运行 GREEN、重复顺序和 Headless 导入验证**

将同一批枪械候选和匕首候选以正序、逆序放入夹具，断言排序后 target ID/generation、伤害和命中位置逐项相同。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_actions.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 第一条打印 `validate_frame_sync_combat_actions: PASS`；两条命令均退出 0。Task 2 可独立验收；不提交。

### Task 3：统一应用伤害、死亡和稳定表现事件并接入世界

**Files:**

- Create: `scripts/simulation/combat/sim_damage_resolver.gd`
- Modify: `scripts/simulation/players/sim_player_state.gd`
- Modify: `scripts/simulation/world/simulation_world.gd`
- Create: `tools/validation/validate_frame_sync_combat_resolution.gd`

**Interfaces:**

- Consumes: Task 2 的 queue/equipment/combat system、Plan 3 玩家 SoA、Plan 4 僵尸 SoA 和攻击意图缓冲。
- Produces: `SimPlayerState.matches_entity(entity_id: int, generation: int) -> bool`、`apply_damage(entity_id: int, generation: int, amount: int) -> int`、`defeat(entity_id: int, generation: int) -> bool`；沿用 Plan 3 已有 `generation_for_slot(slot: int) -> int`。
- Produces: `SimDamageResolver.new(config: SimCombatConfig, player_movement: PlayerMovementSystem)`；`apply_all(tick: int, queue: SimDamageQueue, players: SimPlayerState, zombies: ZombieState, equipment: SimEquipmentState, events: SimEventBuffer) -> bool`。
- Consumes: Task 2 Step 4 完整签名的 `SimEventBuffer.append_presentation_candidate` / `append_death_record`、`finalize_presentation_events(tick: int) -> bool`、`encode_combat_pending(writer: LittleEndianWriter) -> void`、表现事件 getter 和死亡记录 getter。
- Produces: `SimulationWorld.configure_combat(config: SimCombatConfig) -> bool`、`get_equipment_state() -> SimEquipmentState`、`get_damage_queue() -> SimDamageQueue`、`get_event_buffer() -> SimEventBuffer`、`get_last_presentation_events() -> Array[SimPresentationEvent]`。
- Implements: Plan 1 冻结的 `SimulationWorld._encode_other_entity_section(writer: LittleEndianWriter) -> void` 与 `_encode_pending_event_section(writer: LittleEndianWriter) -> void` 中预留的 combat 子段，不改变两个 helper 在整体 canonical 顺序中的位置。

- [ ] **Step 1：写乱序伤害、过期引用、死亡一次和 event_id 的失败验证**

验证脚本构造相同伤害集合的正序与逆序队列：来源 11 对 50 HP 僵尸造成 20，来源 12 造成 35；固定排序后实际伤害必须是 20、30，死亡一次且 killer 为 12。另加入过期 zombie generation、17 条同时致死伤害、僵尸意图伤害玩家和玩家倒地：

```gdscript
_expect(resolver.apply_all(40, queue, players, zombies, equipment, events), "resolver 必须完整应用固定容量队列", failures)
_expect(events.finalize_presentation_events(40), "表现候选必须成功排序并分配 event_id", failures)
_expect(zombies.slot_for_entity_id(zombie_id, zombie_generation) == -1, "死亡僵尸必须立即失效", failures)
_expect(events.death_record_count() == 1, "同一实体同 Tick 只能记录一次死亡", failures)
_expect(events.death_killer_id(0) == 12, "稳定排序后的最后有效来源必须成为 killer", failures)
_expect(events.presentation_event_at(0).event_id == 40 * 4096 + 1, "首个 event_id 必须由 Tick 和排序索引派生", failures)
```

对玩家追加一条来源位置在其左侧的 10 点僵尸近战，断言 `health` 从 100 变 90、`hit_stun_ticks_remaining == 8`、`equipment.attack_lock_until_tick == tick + 36`、击退 X 为正且绝对速度为 273。两份队列应用后必须逐项比较玩家 health/alive/knockback/hit-stun、装备攻击锁、僵尸 alive/health、死亡记录、表现事件全部字段和规范字节。

- [ ] **Step 2：运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_resolution.gd
```

Expected: 非零退出，指出 resolver、玩家伤害写接口或世界战斗配置接口缺失；Task 2 的表现事件类型和 buffer API 已存在，不得在本 Task 重建第二份。

- [ ] **Step 3：给玩家状态增加 ID 校验后的整数伤害和倒地接口**

Plan 3 玩家 generation 固定为 1，不改变槽位分配，也不重复定义 Plan 3 已有的 `generation_for_slot()`：

```gdscript
func matches_entity(value_entity_id: int, value_generation: int) -> bool:
	return slot_for_entity_id(value_entity_id, value_generation) >= 0

func apply_damage(value_entity_id: int, value_generation: int, amount: int) -> int:
	var slot := slot_for_entity_id(value_entity_id, value_generation)
	if slot < 0 or not is_alive(slot) or amount <= 0:
		return 0
	var applied := mini(amount, health[slot])
	health[slot] -= applied
	return applied

func defeat(value_entity_id: int, value_generation: int) -> bool:
	var slot := slot_for_entity_id(value_entity_id, value_generation)
	if slot < 0 or alive[slot] == 0 or health[slot] > 0:
		return false
	alive[slot] = 0
	return true
```

玩家倒地后保留位置供表现读取，但不再接受攻击、装备输入或参与 Plan 3 TeamBounds。

- [ ] **Step 4：实现 resolver 的实际伤害、立即死亡和记录规则**

事件阶段常量沿用 Task 2 在同一 buffer 中的定义，避免各系统使用裸数字：

```gdscript
const PHASE_EQUIPMENT := 2
const PHASE_COMBAT := 9
const PHASE_DAMAGE := 11
const PHASE_DEATH := 12
```

`apply_all()` 先 `queue.sort_canonical()`，再逐项校验 target ID+generation。玩家调用 `apply_damage(entity_id, generation, amount)`；实际伤害大于 0 时，根据 `player_position - origin` 遍历 heading 1～16、比较整数点积并取同值较小 heading，再调用 Plan 3 `PlayerMovementSystem.apply_knockback(slot, heading, 273, 8)`，同时 `equipment.apply_hit_lock(slot, tick + 36)` 和 `equipment.cancel_pending_melee(slot)`；归零后调用 `defeat(entity_id, generation)`。僵尸先取得 slot/位置，再从 `health[slot]` 扣实际伤害，归零后调用 `despawn(entity_id, generation)`。每个实际伤害大于 0 的条目追加 `DAMAGE_APPLIED`，每个首次死亡追加一条 death record 和 `ENTITY_DIED`：

```gdscript
var applied := mini(queue.amount[index], zombies.health[slot])
zombies.health[slot] -= applied
events.append_presentation_candidate(
	SimEventBuffer.PHASE_DAMAGE,
	queue.source_entity_id[index],
	queue.source_generation[index],
	queue.local_sequence[index],
	queue.target_entity_id[index],
	queue.target_generation[index],
	SimPresentationEvent.DAMAGE_APPLIED,
	queue.origin_x[index], queue.origin_z[index],
	queue.hit_x[index], queue.hit_z[index],
	0, applied, queue.damage_kind[index]
)
if zombies.health[slot] == 0:
	events.append_death_record(
	SimDamageQueue.TargetKind.ZOMBIE,
	queue.target_entity_id[index], queue.target_generation[index],
	queue.source_entity_id[index], queue.source_generation[index],
	zombie_x, zombie_z
	)
	zombies.despawn(queue.target_entity_id[index], queue.target_generation[index])
```

过期引用、已死亡目标和 0 伤害不生成 `DAMAGE_APPLIED`；同 Tick 排在死亡后的其他伤害因 generation/alive 校验失败而静默无效，不重复 death record。队列在全部应用后清 count。

- [ ] **Step 5：按 SPEC 固定阶段接入 `SimulationWorld.step()` 并扩展 Hash**

`configure_combat()` 只能调用一次，要求 player/map/zombie 前置依赖已配置、`config.validate() == OK` 且 `config.validate_content_hash()` 为 true；先保存 `duplicate(true)` 后再次验证副本 Hash，后续不暴露可写 config 引用。随后调用 `event_buffer.configure_combat_capacities(config.presentation_event_capacity, zombie_state.capacity + 4)`，并以 `SimCombatSystem.new(config, zombie_config.radius_units, zombie_state.capacity)` 创建 combat system，再创建 equipment、queue 和 resolver。世界阶段必须保持：

```gdscript
event_buffer.begin_tick(tick)
damage_queue.clear()
combat_system.begin_tick(tick)
_apply_player_commands(frame)
combat_system.apply_equipment_phase(tick, frame, player_state, equipment_state, event_buffer)
_step_dynamic_obstacles_and_flow_fields(tick)
_step_players_and_team_bounds(tick)
_step_zombies(tick)
combat_system.resolve_attack_phase(tick, frame, player_state, zombie_state, map_grid, equipment_state, damage_queue, event_buffer)
combat_system.queue_zombie_attack_intents(tick, player_state, zombie_state, map_grid, event_buffer, damage_queue)
_step_explosions_for_plan_6(tick, damage_queue)
damage_resolver.apply_all(tick, damage_queue, player_state, zombie_state, equipment_state, event_buffer)
_step_death_drop_pickup_wave_for_plan_6(tick, event_buffer)
event_buffer.finalize_presentation_events(tick)
_encode_and_hash()
```

其中 Plan 6 两个 hook 在本计划为空实现且不读节点。任一 append/finalize/apply 返回失败时 `step()` 返回 `false`、写入稳定错误且不增加 next tick。

规范状态不得在 Plan 4 字节之后顺序追加。Plan 5 聚焦世界的 Plan 1 `config_bundle_marker` 继续为 0；玩家与僵尸的实际 `health/alive` 继续只由各自冻结 section 编码，不在战斗段重复。`SimulationWorld._encode_other_entity_section(writer: LittleEndianWriter) -> void` 保持 Plan 1 已冻结的精确子序 `allocator → combat_state_marker → world_entity_marker`，并填充 combat 子段：未配置战斗时写 `combat_state_marker:u8 = 0`；已配置时写 `combat_state_marker:u8 = 1`、`combat_state_schema:u8 = 1`、combat config schema、32-byte `content_hash`，再由 `SimEquipmentState.encode_canonical(writer)` 按 player slot → weapon ID 编码拥有、装备、弹药、冷却、动作锁、待命中匕首、散布和四条战斗 PRNG。combat 子段结束后必须继续写 Plan 1 预留的 `world_entity_marker:u8 = 0`；命中候选 scratch、geometry scratch、resolver 实例和错误文本不编码。

`SimulationWorld._encode_pending_event_section(writer: LittleEndianWriter) -> void` 保持 Plan 1 预留 pending/events 位置与精确子序 `pending_event_count → zombie_intent → combat_pending → world_command → last_event_count`，并只填充 combat pending 子段：未配置战斗时写 `combat_pending_marker:u8 = 0`；已配置时写 `combat_pending_marker:u8 = 1`、`combat_pending_schema:u8 = 1`、待执行 `SimDamageQueue` count/逐字段、表现候选 count/逐字段、死亡记录 count/逐字段、finalized `SimPresentationEvent` count/全部整数字段。Plan 4 已冻结的僵尸攻击意图仍留在其既定子段，不在这里重复编码；combat 子段结束后必须继续写 Plan 1 预留的 `world_command_marker:u8 = 0`，再把 debug `last_event_count` 在配置战斗的世界固定写 0。`get_last_presentation_events()` 只复制 combat pending 子段中已 finalized 的记录，不得把同一表现事件再编码一份。

Plan 1 顶层 `canonical_schema` 只有在预留 hook 的字节布局本身改变时才递增；从 marker 0 切为 marker 1 只是同一 schema 下的配置状态变化，不得擅自改版本。若执行时发现 Plan 1 实现尚未包含上述 marker/hook，必须先在 Plan 1 统一补齐 hook、递增顶层 schema 并重锁 Plan 1～4 金样，再继续本 Task，禁止用尾部 append 兼容。Plan 6 的 `SimulationConfigBundle` 负责把 map/player/zombie/combat 组件 hash 聚合为最终 `SimulationManifest.config_hash`；本计划的 `configure_combat()` 只验证 combat 自身 hash，不能提前发明另一种 bundle 顺序。

- [ ] **Step 6：运行稳定顺序、世界阶段与 Headless 验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_resolution.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 第一条打印 `validate_frame_sync_combat_resolution: PASS`；乱序队列得到相同实际伤害、死亡 killer、death record、事件顺序和 event_id；验证同时解析 canonical bytes，断言整体 section 顺序未变、未配置战斗时两个 marker 均为 0、配置后 marker/schema 为 `1/1`，且 combat 状态只出现在 other section，queue/candidate/death/finalized presentation 只出现在 combat pending 子段，随后 Plan 1 debug 输出事件 count 为 0。两条命令均退出 0。Task 3 可独立验收；不提交。

### Task 4：完成三武器双实例资格回放和范围审查

**Files:**

- Modify: `scripts/simulation/testing/first_divergence_harness.gd`
- Create: `tools/validation/validate_frame_sync_combat_replay.gd`

**Interfaces:**

- Consumes: Plan 1 的直接命令/codec 命令双世界、Task 1～3 的配置、装备、命中、伤害、死亡、事件和规范状态。
- Produces: `FirstDivergenceHarness.run_combat_replay(tape: InputTape, ticks: int) -> Dictionary`；成功结果含 `first_divergence_tick = -1`、`ticks_checked`、`pistol_hit_count`、`smg_hit_count`、`knife_hit_count`、`final_smg_ammo`、`death_count`、`last_event_id`。

- [ ] **Step 1：写 10,000/100,000 Tick 三武器失败回放**

验证脚本建立相同 map/player/zombie/combat 配置的两个世界，断言 combat `content_hash` 相同，固定给 slot 0 授予 360 发 SMG并显式装备/切回手枪，按同一 `(spawn_x, spawn_z, health, rng_seed)` 顺序生成 150 只僵尸。录像前 10,000 Tick 循环以下命令，之后到 100,000 Tick 使用中性命令继续验证长期状态：

```gdscript
match tick % 90:
	0:
		command = PlayerFrameCommand.new(1, PlayerFrameCommand.USE_PRESSED, 0, 0) # 手枪
	1:
		command = PlayerFrameCommand.new(1, 0, 1, 0) # 切到 SMG
	2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18:
		command = PlayerFrameCommand.new(1, PlayerFrameCommand.USE_HELD, 0, 0)
	19:
		command = PlayerFrameCommand.new(1, 0, 1, 0) # 切到匕首
	20:
		command = PlayerFrameCommand.new(1, PlayerFrameCommand.USE_PRESSED, 0, 0)
	40:
		command = PlayerFrameCommand.new(1, 0, 1, 0) # 回到手枪
	_:
		command = PlayerFrameCommand.neutral()
```

夹具必须把一部分僵尸放在枪线、穿透线、墙后和匕首矩形边缘，确保三个 `hit_count > 0`、至少一个玩家或僵尸死亡、SMG 弹药确实减少；不得仅比较一个最终 Hash。

- [ ] **Step 2：运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_replay.gd
```

Expected: 非零退出，指出 `run_combat_replay()` 尚不存在；不得缩短为只比较检查点 Hash。

- [ ] **Step 3：扩展 harness 为逐 Tick Hash、状态和事件比较**

左世界直接接收 tape frame，右世界每 Tick 必须走 `LocalFrameCommandCodec.decode(LocalFrameCommandCodec.encode(frame))`。每次成功 step 后先比较 SHA-256，再逐项比较下列战斗观察值，以便 Hash 分歧前也能给出可读诊断：

```gdscript
func _combat_snapshot(world: SimulationWorld) -> Dictionary:
	var events := world.get_last_presentation_events()
	return {
		"player_health": world.get_player_state().health.duplicate(),
		"equipped_weapon": world.get_equipment_state().equipped_weapon.duplicate(),
		"ammo": world.get_equipment_state().ammo.duplicate(),
		"zombie_alive": world.get_zombie_state().alive.duplicate(),
		"zombie_health": world.get_zombie_state().health.duplicate(),
		"event_ids": events.map(func(event: SimPresentationEvent) -> int: return event.event_id),
		"event_types": events.map(func(event: SimPresentationEvent) -> int: return event.event_type),
		"event_targets": events.map(func(event: SimPresentationEvent) -> int: return event.target_entity_id),
	}
```

首个差异立即返回 tick、22 bytes frame hex、双方 Hash、双方 canonical state hex、双方 snapshot；成功才累积三武器命中、弹药、死亡和 last event ID。event ID 还必须严格递增，且每个事件满足公式 `tick * 4096 + index + 1`。

- [ ] **Step 4：运行全部 Plan 5 自动门槛**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_config.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_actions.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_resolution.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_combat_replay.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 五条命令均退出 0；回放先报告 10,000 Tick，再报告 100,000 Tick，两个时长都满足 `first_divergence_tick = -1`，且手枪、SMG、匕首命中计数均大于 0、SMG 弹药小于 360、死亡数大于 0、每 Tick event_id 公式成立。

- [ ] **Step 5：审查禁止依赖和旧默认路径未变**

Run:

```bash
if rg -n "CharacterBody3D|PhysicsRayQueryParameters3D|PhysicsShapeQueryParameters3D|direct_space_state|NavigationAgent3D|NavigationServer3D|RandomNumberGenerator|randf|randi|Timer|create_timer|instance_id|RID" scripts/simulation/combat scripts/simulation/events/sim_presentation_event.gd scripts/simulation/events/sim_event_buffer.gd; then
	exit 1
else
	echo "forbidden dependency scan: PASS"
fi
git diff --check
git diff -- scripts/combat/weapons/ranged_weapon.gd scripts/combat/weapons/melee_weapon.gd scripts/player/equipment_controller.gd scripts/combat/zombie_target.gd scenes/gameplay/DemoArena.tscn resources/weapons/pistol.tres resources/weapons/smg.tres resources/weapons/knife.tres
```

Expected: 第一段打印 `forbidden dependency scan: PASS`；`git diff --check` 无输出；最后一条无输出，证明旧战斗节点、源武器资源和默认 `DemoArena` 均未修改。

- [ ] **Step 6：记录 Plan 6 进入门槛并停止**

只有 Task 4 五条自动命令、逐 Tick snapshot/Hash、旧路径 diff 和规格复核全部通过，Plan 5 才可标记完成。任一分歧必须保存 harness 的首个 tick、frame、双方 canonical state 和战斗 snapshot，并停止 Plan 6～8。agent 到此停止，不暂存、不提交、不 squash；由用户自行审阅并提交整个 Plan。

## 规格覆盖复核

- [ ] Task 1 覆盖整数 `SimCombatConfig`、离线转换、当前 pistol/SMG/knife 数值、SMG 对 SPEC 步枪槽位的兼容映射、重复构建和供 Plan 6 bundle 聚合的 32-byte `content_hash`。
- [ ] Task 2 覆盖装备切换、初始所有权、SMG 弹药、PRESS/HOLD 射速、整数散布、独立 Park–Miller、枪械穿透、地图阻挡、匕首延迟与稳定最近目标。
- [ ] Task 3 覆盖 Plan 4 僵尸攻击意图、玩家/僵尸整数生命、统一稳定伤害队列、过期 generation、立即死亡、death record、表现事件排序和稳定 event_id。
- [ ] Task 4 覆盖直接命令与 codec 命令双实例中手枪、SMG、匕首的命中、弹药、死亡、事件 ID 和每 Tick Hash 一致，并确保旧 `DemoArena` 默认不变。
- [ ] Plan 6 已获得唯一伤害队列、武器所有权/弹药和死亡记录接口；Plan 7 已获得只读 `SimPresentationEvent` 字段、类型、event_id 规则和世界读取 API。

## 占位符与类型一致性复核

- [ ] 全文不存在未定义实现项、模糊错误处理或空白测试；每个新增类型、路径、方法参数和返回类型都在文件结构、接口或产生它的 Task 中定义。
- [ ] 玩家 generation 全文固定为 1；僵尸 damage/death/event 全文使用 Plan 4 的 ID+generation；伤害排序、死亡记录和表现事件字段命名一致。
- [ ] `SimulationWorld` 路径统一为 Plan 1 的 `scripts/simulation/world/simulation_world.gd`，harness 路径统一为 `scripts/simulation/testing/first_divergence_harness.gd`，事件缓冲路径统一为 `scripts/simulation/events/sim_event_buffer.gd`。
- [ ] agent 未执行任何暂存、提交、reset、rebase 或 squash；整个 Plan 的提交由用户完成。

## 执行交接

执行本计划前先询问用户是否使用 worktree，默认选择“不使用”；只有用户明确同意隔离执行时，才调用 `using-git-worktrees` 创建工作目录。

1. **Subagent-Driven（推荐）**：使用 `subagent-driven-development`，按 Task 1～4 逐个派发新 subagent，并在每个 Task 后执行规格与质量复核；各 Task 不独立提交，全部完成后由用户自行提交整个 Plan。
2. **Inline Execution**：使用 `executing-plans` 在当前会话按 Task 顺序批量执行，在 Task 边界停下复核；不暂存、不提交，由用户自行提交整个 Plan。

开始执行时，请用户先选择是否启用 worktree，再从上述两种执行方式中选择一种。
