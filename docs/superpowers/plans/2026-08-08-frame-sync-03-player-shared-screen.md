# 帧同步 Plan 3：玩家整数模拟与共享屏幕 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不替换当前默认 `DemoArena` 的前提下，建立一个由 `LocalFrameCommandSet` 唯一驱动的旁路 1～4 玩家沙盒，完成整数移动、地图碰撞、世界坐标队伍范围、最小玩家表现和不回写模拟的共享镜头。

**Architecture:** `SimPlayerState` 用固定四槽位 SoA 保存玩家玩法状态，`PlayerMovementSystem` 先批量计算地图碰撞后的候选位置，再由 `PlayerSeparationSystem` 按 slot 和 X→Z 固定顺序消除玩家重叠，随后由 `TeamBoundsSystem` 依据前一 Tick 存活玩家包围盒中心统一裁剪，最后一次性提交。`PlayerSimulationSandbox` 只从现有 `GameSession` 和输入源构造 Plan 1 会话/帧缓冲/驱动器；`PlayerSimulationViewBridge` 把 Tick 快照推给最小 `PlayerView`，`SimulationFollowCamera` 只消费插值后的视图位置。旧 `PlayerController`、旧 `FollowCamera` 和 `DemoArena` 保持默认可玩路径，不参与新模拟判定。

**Tech Stack:** Godot 4.7.1、GDScript、30 Hz 整数 Tick、`PackedInt32Array`、Plan 1 的帧命令/录像/Hash、Plan 2 的 `SimMapAsset`/`SimMapGrid`、现有 `GameSession` 与本地输入源、Headless 验证脚本。

## Global Constraints

- 唯一需求准绳是 `docs/superpowers/specs/2026-08-08-local-deterministic-frame-sync-design.md`；若 Plan 1、Plan 2、Plan 4、旧代码或本文示例与 SPEC 冲突，必须以 SPEC 为准并先修正接口，禁止增加兼容分支掩盖冲突。
- Plan 1 的 100,000 Tick 门槛和 Plan 2 的地图资源可重复生成/Hash/碰撞门槛必须先通过；任一前置门槛失败时停止本计划实现。
- 保持 Plan 1 的 `SimulationWorld.new(session: LocalSimulationSession)`、`step(tick: int, frame: LocalFrameCommandSet) -> bool`、`encode_canonical_state() -> PackedByteArray` 和 `get_last_error() -> String`；本计划只增加显式玩家配置方法和玩家状态访问器。
- 玩家旁路会话先调用 Plan 2 的 `SimulationWorld.configure_map(map_asset: SimMapAsset, dynamic_owner_capacity := 256) -> bool`，再调用本计划的 `configure_players(config: PlayerSimConfig) -> bool`；`PlayerSimulationSandbox` 未完成两次配置时不得启动 driver。不得把玩家配置变成所有 `SimulationWorld.step()` 的全局前置条件，Plan 1 core-only 与 Plan 2 map-only replay 仍须保持可运行。
- 模拟频率固定为 30 Hz；1 Godot 世界单位等于 1024 模拟单位；位置、速度、半径、跨度、生命、硬直和 Tick 全部使用整数，乘法中间值使用 GDScript `int` 的 int64 语义。
- 玩家槽位固定为 `0..3`，有效掩码仅允许连续低位 `0b0001/0b0011/0b0111/0b1111`；`SimulationWorld.configure_players()` 必须把 Plan 1 世界已持有的 `_allocator: EntityIdAllocator` 注入 `SimPlayerState`，再按 active slot 升序分配，首局固定为 `entity_id = slot + 1`、generation 1。`SimPlayerState` 不得私建 allocator；Plan 4 僵尸继续使用独立的 `1024+` 命名空间，二者不得发生 ID 碰撞。
- 玩家移动只读取 `PlayerFrameCommand.move_heading`；静止 heading 0 不覆盖玩家最后有效朝向；模拟不读取 `Vector2`、Camera3D Basis、视口、分辨率、渲染 delta、`CharacterBody3D`、Jolt、Physics 查询或 NavigationServer。
- 输入采集继续使用 Plan 1 已冻结的 `LocalInputCollector.new(session, sources)` 和默认方向语义：`input_heading_offset = 0` 时设备 `(0, -1)` 量化为 local/world heading 5。本计划只在玩家配置与 `LocalSimulationSession` 中固定 `input_heading_offset = 8`，把 local heading 5 旋转到 DemoArena world heading 13；不得修改 collector 默认 API，不得读取正在平滑、缩放或震动的摄像机。同 Tick previous+next 归零继续由 Plan 1 collector 保证。
- 地图碰撞只消费 Plan 2 已提交的 `resources/simulation/maps/demo_arena_map.tres` 与 `SimMapGrid.move_circle_x_then_z(...)`；不得在运行时解析 `DemoArena.tscn`、静态碰撞体、NavMesh 或客户端当前场景。
- 单人只受地图阻挡和地图边界影响；`TeamBoundsSystem` 仅在 2～4 个激活槽位时启用，最大 X 跨度固定为 `24 * 1024 = 24576`，最大 Z 跨度固定为 `18 * 1024 = 18432`，两值进入玩家配置规范字节与玩法配置 Hash。
- 同 Tick 必须先计算全部存活玩家的地图碰撞候选，再由 `PlayerSeparationSystem` 批量解算玩家圆形重叠；不得在遍历某个 Player 节点时立即提交位置。重叠解算固定 slot 小者在前、先 X 后 Z、最多 4 个固定 pass，并使用确定性整数平方根，不调用浮点 `sqrt()`。
- 队伍范围只统计存活玩家；玩家重叠解算后，再以前一 Tick 存活玩家包围盒中点为中心，固定先 X 后 Z、slot 升序裁剪；倒地玩家不参与跨度。
- 摄像机、PlayerView、插值、窗口分辨率、宽高比、正交 size、平滑速度和镜头更新次数只属于表现层，不得进入规范状态或 Hash，不得回写位置、朝向、输入或攻击方向。
- Plan 3 只能扩展 Plan 1 固定位置的 `_encode_player_section(writer)`；Plan 1 已在四槽 last command 后预留 `player_sim_marker:u8 = 0`。玩家配置完成后把 marker 写为 1，再写独立 schema/config/state；不得把玩家数据追加到 Plan 2 地图段之后。最终规范顺序保持 `world header → players → zombies → other entities/allocator → dynamic map → PRNG → wave → pending/output events`，allocator 内部状态仍只编码一次。
- Plan 1 world header 已在 `next_tick:u32` 后冻结 `config_bundle_marker:u8 = 0`。Plan 3 legacy 旁路 world 必须继续写 0；只有 Plan 6 成功配置完整 `SimulationConfigBundle` 后才允许写 1 和 bundle payload，Plan 3 不得提前占用该 header marker。
- 玩家 component hash 固定为 `StateHasher.hash_canonical(config.encode_canonical())`。Plan 3 legacy session 的 manifest 仍保存 map+player combined hash，但 `configure_players()` 只能通过私有 `_validate_player_component_hash(config_hash, legacy_combined_hash)` 校验；Plan 6 配置 `SimulationConfigBundle` 后只扩展该 helper，改为比较 bundle 的 `PLAYER` component，不得重写调用点或把最终 bundle hash 与单个玩家 component 直接比较。
- 战斗中任一已绑定输入源离线时，`PlayerSimulationSandbox` 不调用 `LocalInputCollector.collect()`、不提交中性帧、不调用驱动器推进，并显示等待恢复层；仅相同 `GamepadInputSource.device_id` 恢复在线后继续下一个 Tick。
- `project.godot` 的主场景必须继续是 `res://scenes/menu/MainMenu.tscn`；`scripts/menu/main_menu.gd` 和 `scripts/menu/local_multiplayer_lobby.gd` 的默认 `game_scene_path` 必须继续指向 `res://scenes/gameplay/DemoArena.tscn`。旧 DemoArena、PlayerController、LocalPlayerSpawner、FollowCamera 也不修改；新功能仅从独立旁路场景运行。
- 不使用 CUA 自动操作 Godot 编辑器。自动验证使用 Headless 脚本；视觉结果由人工运行旁路场景并按本文步骤检查。
- Headless 导入为新增脚本/场景生成的关联 `.uid` 文件必须保留；不得纳入 `.godot/` 或 `build/` 生成内容。
- 本计划默认在当前工作区执行；开始实现前必须先询问用户是否改用独立 worktree，用户未明确选择时不得创建 worktree。
- 本计划不包含按 Task 提交、squash、`git add` 或 `git commit` 步骤；全部实现和验证完成后由用户自行审阅并提交。

---

## 文件结构与稳定边界

| 路径 | 职责 |
| --- | --- |
| `scripts/simulation/players/player_sim_config.gd` | DemoArena 玩家整数参数、出生点、固定 `input_heading_offset` 和规范配置 Hash。 |
| `resources/simulation/players/demo_arena_player_sim_config.tres` | 提交到仓库的玩家配置实例，不在运行时读取旧场景参数。 |
| `scripts/simulation/players/sim_player_state.gd` | 固定四槽位玩家 SoA、稳定实体引用与规范状态编码。 |
| `scripts/simulation/players/player_movement_system.gd` | heading 驱动的整数加减速、击退/硬直、地图碰撞和批量候选提交。 |
| `scripts/simulation/players/player_separation_system.gd` | 对全部地图候选执行固定 pass、slot 与 X→Z 顺序的玩家圆形重叠解算。 |
| `scripts/simulation/players/team_bounds_system.gd` | 以旧包围盒中心解析 2～4 人 X/Z 世界跨度。 |
| `scripts/simulation/world/simulation_world.gd` | 在固定系统顺序中配置并推进玩家系统，把玩家状态纳入 canonical bytes。 |
| `scripts/simulation/session/local_simulation_session_factory.gd` | 从现有 `GameSession` 生成连续 mask、四槽位 source key、输入源和不可变本局会话。 |
| `scripts/simulation/driver/player_simulation_sandbox.gd` | 旁路场景装配、设备离线暂停、60/30 Hz 驱动和表现更新。 |
| `scripts/simulation/view/player_view.gd` | 保存 previous/current Tick 表现样本并执行纯显示插值。 |
| `scripts/simulation/view/simulation_player_view_registry.gd` | 按 slot 注册、查询和稳定返回 `PlayerView`。 |
| `scripts/simulation/view/player_simulation_view_bridge.gd` | 每个成功 Tick 从 `SimPlayerState` 复制只读快照到对应 PlayerView。 |
| `scripts/simulation/view/simulation_follow_camera.gd` | 只读插值位置，计算中心、宽高比留白、正交 size、平滑和视觉震动。 |
| `scenes/simulation/PlayerView.tscn` | 无碰撞、无输入、无武器结算的最小玩家表现。 |
| `scenes/simulation/SimulationFollowCamera.tscn` | 旁路纯表现共享摄像机。 |
| `scenes/simulation/PlayerSimulationSandbox.tscn` | 独立 1～4 玩家旁路验收入口；不替换主场景。 |
| `scenes/simulation/PlayerSimulationLobby.tscn` | 复用现有本地多人大厅，仅把本实例的战斗目标改为旁路沙盒。 |
| `tools/validation/validate_frame_sync_player_movement.gd` | 玩家配置、槽位、整数运动、地图碰撞、击退和 canonical state 验证。 |
| `tools/validation/validate_frame_sync_player_integer_division.gd` | 去除字符串与注释后扫描 Plan 3 模拟 runtime，拒绝裸 `/` 运算符；不扫描 View/Camera。 |
| `tools/validation/validate_frame_sync_team_bounds.gd` | 单人绕过、2～4 人跨度、整体平移、倒地排除和 Tie-break 验证。 |
| `tools/validation/validate_frame_sync_player_sandbox.gd` | GameSession、固定方向基、设备断线暂停和旁路场景结构验证。 |
| `tools/validation/validate_frame_sync_player_view.gd` | PlayerView 插值、镜头纯表现、分辨率/节奏不改变 Hash 的验证。 |
| `scripts/simulation/testing/first_divergence_harness.gd` | 扩展 Plan 1 双世界 harness，执行玩家地图/队伍范围的直接与 codec 回放。 |

## 供 Plan 4～7 消费的冻结接口

```gdscript
# scripts/simulation/players/player_sim_config.gd
class_name PlayerSimConfig

var radius_units: int
var max_speed_per_tick: int
var acceleration_per_tick: int
var deceleration_per_tick: int
var knockback_deceleration_per_tick: int
var initial_health: int
var max_team_span_x_units: int
var max_team_span_z_units: int
var input_heading_offset: int
var spawn_x: PackedInt32Array
var spawn_z: PackedInt32Array

func validate(map_grid: SimMapGrid, active_player_mask: int) -> Error
func encode_canonical() -> PackedByteArray
func combined_config_hash(map_content_hash: PackedByteArray) -> PackedByteArray

# scripts/simulation/players/sim_player_state.gd
class_name SimPlayerState

var active: PackedInt32Array
var alive: PackedInt32Array
var generation: PackedInt32Array
var pos_x: PackedInt32Array
var pos_z: PackedInt32Array
var velocity_x: PackedInt32Array
var velocity_z: PackedInt32Array
var heading: PackedInt32Array
var health: PackedInt32Array
var knockback_velocity_x: PackedInt32Array
var knockback_velocity_z: PackedInt32Array
var hit_stun_ticks_remaining: PackedInt32Array

func configure(
	active_player_mask: int,
	config: PlayerSimConfig,
	map_grid: SimMapGrid,
	allocator: EntityIdAllocator
) -> Error
func is_active(slot: int) -> bool
func is_alive(slot: int) -> bool
func entity_id_for_slot(slot: int) -> int
func generation_for_slot(slot: int) -> int
func slot_for_entity_id(entity_id: int, expected_generation: int) -> int
func get_position_units(slot: int) -> Vector2i
func encode_canonical(writer: LittleEndianWriter) -> void

# scripts/simulation/players/player_movement_system.gd
func _init(players: SimPlayerState) -> void
func step(
	frame: LocalFrameCommandSet,
	players: SimPlayerState,
	map_grid: SimMapGrid,
	config: PlayerSimConfig,
	separation: PlayerSeparationSystem,
	team_bounds: TeamBoundsSystem
) -> bool
func get_last_error() -> String
func apply_knockback(
	player_slot: int,
	heading: int,
	speed_per_tick: int,
	hit_stun_ticks: int
) -> bool

# scripts/simulation/players/player_separation_system.gd
func resolve(
	players: SimPlayerState,
	candidate_x: PackedInt32Array,
	candidate_z: PackedInt32Array,
	map_grid: SimMapGrid,
	radius_units: int
) -> bool
func has_overlap(
	players: SimPlayerState,
	candidate_x: PackedInt32Array,
	candidate_z: PackedInt32Array,
	radius_units: int
) -> bool

# scripts/simulation/players/team_bounds_system.gd
func resolve(
	players: SimPlayerState,
	candidate_x: PackedInt32Array,
	candidate_z: PackedInt32Array,
	max_span_x_units: int,
	max_span_z_units: int
) -> void
func is_within_limits(
	players: SimPlayerState,
	candidate_x: PackedInt32Array,
	candidate_z: PackedInt32Array,
	max_span_x_units: int,
	max_span_z_units: int
) -> bool

# scripts/simulation/world/simulation_world.gd additions
func configure_players(config: PlayerSimConfig) -> bool
func get_player_state() -> SimPlayerState
func get_player_config() -> PlayerSimConfig
```

Plan 5/6 不得把装备或库存塞回 `PlayerFrameCommand`；它们以同一固定 slot 和 `entity_id_for_slot()` 关联各自的整数 SoA。Plan 7 只能通过下列纯表现接口替换或扩展玩家视图：

```gdscript
# scripts/simulation/view/player_view.gd
func bind_player_slot(slot: int) -> void
func push_simulation_sample(
	tick: int,
	position_units: Vector2i,
	heading: int,
	alive: bool,
	health: int
) -> void
func render_interpolated(alpha: float) -> void
func get_render_position() -> Vector3
func get_render_motion_direction() -> Vector3
func is_player_visible() -> bool
func get_player_slot() -> int

# scripts/simulation/view/simulation_player_view_registry.gd
func register_view(view: PlayerView) -> void
func unregister_view(view: PlayerView) -> void
func get_views() -> Array[PlayerView]
func get_visible_views() -> Array[PlayerView]
func view_for_slot(slot: int) -> PlayerView

# scripts/simulation/view/simulation_follow_camera.gd
func set_player_view_registry(registry: SimulationPlayerViewRegistry) -> void
func set_world_bounds_units(bounds: Rect2i) -> void
func render_camera(delta: float, viewport_size: Vector2) -> void
func add_shot_impulse(direction: Vector3, strength: float) -> void
func get_anchor_position() -> Vector3
func get_camera() -> Camera3D
```

### Task 1：建立四槽位玩家状态、整数移动和地图碰撞

**Files:**

- Create: `scripts/simulation/players/player_sim_config.gd`
- Create: `resources/simulation/players/demo_arena_player_sim_config.tres`
- Create: `scripts/simulation/players/sim_player_state.gd`
- Create: `scripts/simulation/players/player_movement_system.gd`
- Create: `scripts/simulation/players/player_separation_system.gd`
- Modify: `scripts/simulation/world/simulation_world.gd`
- Create: `tools/validation/validate_frame_sync_player_movement.gd`
- Create: `tools/validation/validate_frame_sync_player_integer_division.gd`

**Interfaces:**

- Consumes: Plan 1 `FixedMath.heading_x()`、`heading_z()`、`floor_div()`、`EntityIdAllocator`、`LittleEndianWriter`、`LocalFrameCommandSet`、`StateHasher`。
- Consumes: Plan 2 `SimMapAsset.get_content_hash()`、`SimMapGrid.new(asset, dynamic_owner_capacity)`、`move_circle_x_then_z(x, z, radius, delta_x, delta_z) -> Vector2i`、地图边界与阻挡格。
- Produces: 本文冻结的 `PlayerSimConfig`、`SimPlayerState`、`PlayerMovementSystem`、`PlayerSeparationSystem` 与 `SimulationWorld.configure_players()` 接口，以及仅扫描模拟 runtime 的裸除法验证入口。

- [ ] **Step 1：先写配置、槽位和地图碰撞的失败验证**

创建 `validate_frame_sync_player_movement.gd`，预加载尚不存在的四个玩家脚本、Plan 2 地图资源和 Plan 1 世界。测试至少包含 mask 1/3/7/15、固定出生点、heading 保留和墙体碰撞：

```gdscript
extends SceneTree

const PlayerSimConfig = preload("res://scripts/simulation/players/player_sim_config.gd")
const SimPlayerState = preload("res://scripts/simulation/players/sim_player_state.gd")
const PlayerMovementSystem = preload("res://scripts/simulation/players/player_movement_system.gd")
const PlayerSeparationSystem = preload("res://scripts/simulation/players/player_separation_system.gd")
const MAP_ASSET = preload("res://resources/simulation/maps/demo_arena_map.tres")
const PLAYER_CONFIG = preload(
	"res://resources/simulation/players/demo_arena_player_sim_config.tres"
)

func _init() -> void:
	var failures: Array[String] = []
	var grid := SimMapGrid.new(MAP_ASSET)
	for mask in [0b0001, 0b0011, 0b0111, 0b1111]:
		var players := SimPlayerState.new()
		var allocator := EntityIdAllocator.new(256)
		_expect(players.configure(mask, PLAYER_CONFIG, grid, allocator) == OK, "mask %d must configure" % mask, failures)
		for slot in range(4):
			_expect(players.is_active(slot) == ((mask & (1 << slot)) != 0), "active slot mismatch", failures)
			if players.is_active(slot):
				_expect(players.entity_id_for_slot(slot) == slot + 1, "player ID must follow active slot order", failures)
				_expect(players.generation_for_slot(slot) == 1, "first player generation must be 1", failures)
	_expect(PLAYER_CONFIG.radius_units == 461, "player radius must be 0.45 world units", failures)
	_expect(PLAYER_CONFIG.max_team_span_x_units == 24576, "X team span must be 24 units", failures)
	_expect(PLAYER_CONFIG.max_team_span_z_units == 18432, "Z team span must be 18 units", failures)
	_finish(failures)
```

在同一脚本用 Plan 1 合法 frame 夹具推进 30 Tick `heading = 1`，断言 X 增长、Z 不变；随后提交 `heading = 0`，断言位置减速但 `players.heading[0]` 保持 1。把玩家放到 Plan 2 阻挡格左侧再向右推进，断言圆心没有进入阻挡格。最后让两名玩家产生相同候选点，断言解算后距离平方不小于 `(radius_units * 2)²`，且交换测试夹具写入 candidate 的顺序不会改变 slot 0/1 结果。

断言 `StateHasher.hash_canonical(PLAYER_CONFIG.encode_canonical())` 恰好 32 bytes、重复计算相同，且在 `PLAYER_CONFIG.duplicate(true)` 深复制夹具上改变任一玩家配置字段都会改变 component hash，不得改写 preload 的共享资源。另建 manifest legacy combined hash 与资源一致、但 `LocalSimulationSession.input_heading_offset = 0` 的 world；`configure_map()` 成功后，`configure_players(PLAYER_CONFIG)` 必须失败并包含 `input heading offset mismatch`，且 allocator canonical bytes、world canonical bytes 和 next tick 均保持不变。offset 改为 8 的同配置 world 才允许成功；manifest legacy combined hash 改错时必须由 `_validate_player_component_hash()` 拒绝。

玩家 canonical 金样/probe 必须按 Plan 1 header 解码并明确断言 `config_bundle_marker == 0`，再在固定 player section 断言 `player_sim_marker == 1`、`player_sim_schema == 1`；另建未调用 `configure_players()` 的 map-only world，断言其 player marker 为 0 且后续 zombie/allocator/dynamic map/PRNG/event 段偏移与 Plan 2 金样相同。

- [ ] **Step 2：运行验证并确认缺少玩家实现时失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_movement.gd
```

Expected: 非零退出，错误明确指向玩家配置资源或 `player_sim_config.gd`、`sim_player_state.gd`、`player_movement_system.gd`、`player_separation_system.gd` 之一不存在；不得捕获预加载错误后跳过断言。

- [ ] **Step 3：创建整数玩家配置和已提交资源实例**

`PlayerSimConfig` 继承 `Resource`，所有字段均为整数或 `PackedInt32Array`。默认 DemoArena 参数固定如下，秒值已经在进入本局前换算为 30 Hz Tick 值：

```gdscript
extends Resource
class_name PlayerSimConfig

const MAX_RADIUS_UNITS := 1 << 20
const MAX_VELOCITY_PER_TICK := 1 << 20
const MAX_HEALTH := 1 << 30
const MAX_TEAM_SPAN_UNITS := 1 << 30

@export var radius_units := 461
@export var max_speed_per_tick := 171
@export var acceleration_per_tick := 34
@export var deceleration_per_tick := 48
@export var knockback_deceleration_per_tick := 20
@export var initial_health := 100
@export var max_team_span_x_units := 24576
@export var max_team_span_z_units := 18432
@export var input_heading_offset := 8
@export var spawn_x := PackedInt32Array([-1229, 1229, -1229, 1229])
@export var spawn_z := PackedInt32Array([6349, 6349, 4301, 4301])

func validate(map_grid: SimMapGrid, active_player_mask: int) -> Error:
	if map_grid == null or not LocalFrameCommandSet.is_contiguous_active_mask(active_player_mask):
		return ERR_INVALID_PARAMETER
	if radius_units < 1 or radius_units > MAX_RADIUS_UNITS:
		return ERR_INVALID_PARAMETER
	if max_speed_per_tick < 0 or max_speed_per_tick > MAX_VELOCITY_PER_TICK:
		return ERR_INVALID_PARAMETER
	if acceleration_per_tick < 1 or acceleration_per_tick > MAX_VELOCITY_PER_TICK:
		return ERR_INVALID_PARAMETER
	if deceleration_per_tick < 1 or deceleration_per_tick > MAX_VELOCITY_PER_TICK:
		return ERR_INVALID_PARAMETER
	if knockback_deceleration_per_tick < 1 or knockback_deceleration_per_tick > MAX_VELOCITY_PER_TICK:
		return ERR_INVALID_PARAMETER
	if initial_health < 1 or initial_health > MAX_HEALTH:
		return ERR_INVALID_PARAMETER
	if max_team_span_x_units < radius_units * 2 or max_team_span_z_units < radius_units * 2:
		return ERR_INVALID_PARAMETER
	if max_team_span_x_units > MAX_TEAM_SPAN_UNITS or max_team_span_z_units > MAX_TEAM_SPAN_UNITS:
		return ERR_INVALID_PARAMETER
	if input_heading_offset < 0 or input_heading_offset > 15:
		return ERR_INVALID_PARAMETER
	if spawn_x.size() != 4 or spawn_z.size() != 4:
		return ERR_INVALID_PARAMETER
	for slot in range(4):
		if (active_player_mask & (1 << slot)) == 0:
			continue
		var spawn := Vector2i(spawn_x[slot], spawn_z[slot])
		if map_grid.move_circle_x_then_z(spawn.x, spawn.y, radius_units, 0, 0) != spawn:
			return ERR_INVALID_DATA
	return OK
```

`encode_canonical()` 固定写 `schema:u8 = 1`，随后依次把 `radius_units/max_speed_per_tick/acceleration_per_tick/deceleration_per_tick/knockback_deceleration_per_tick/initial_health/max_team_span_x_units/max_team_span_z_units` 写为 `i32-le`，把 `input_heading_offset` 写为 `u8`，最后写四个 `spawn_x:i32-le` 和四个 `spawn_z:i32-le`。`combined_config_hash()` 要求地图 Hash 恰好 32 bytes，并对 `schema:u8 + map_hash:32 bytes + player_config_length:u16 + player_config_bytes` 计算 SHA-256。`.tres` 显式写入同一组数值，不引用 `DemoArena.tscn`。

- [ ] **Step 4：实现固定四槽位 `SimPlayerState`**

构造时一次性把所有数组 resize 为 4；`configure()` 清零全部槽位，要求调用者注入 `SimulationWorld` 已持有且尚未用于本局实体的 Plan 1 allocator，再按 active slot 升序分配启用玩家。状态只保存返回的 `entity_id/generation`，不保存 allocator 引用，也不创建第二个 allocator：

```gdscript
extends RefCounted
class_name SimPlayerState

const SLOT_COUNT := 4
const INVALID_ENTITY_ID := -1

var active := PackedInt32Array()
var alive := PackedInt32Array()
var generation := PackedInt32Array()
var pos_x := PackedInt32Array()
var pos_z := PackedInt32Array()
var velocity_x := PackedInt32Array()
var velocity_z := PackedInt32Array()
var heading := PackedInt32Array()
var health := PackedInt32Array()
var knockback_velocity_x := PackedInt32Array()
var knockback_velocity_z := PackedInt32Array()
var hit_stun_ticks_remaining := PackedInt32Array()
var _entity_id := PackedInt32Array()
var _configured := false

func _init() -> void:
	active.resize(SLOT_COUNT)
	alive.resize(SLOT_COUNT)
	generation.resize(SLOT_COUNT)
	pos_x.resize(SLOT_COUNT)
	pos_z.resize(SLOT_COUNT)
	velocity_x.resize(SLOT_COUNT)
	velocity_z.resize(SLOT_COUNT)
	heading.resize(SLOT_COUNT)
	health.resize(SLOT_COUNT)
	knockback_velocity_x.resize(SLOT_COUNT)
	knockback_velocity_z.resize(SLOT_COUNT)
	hit_stun_ticks_remaining.resize(SLOT_COUNT)
	_entity_id.resize(SLOT_COUNT)
	_reset_arrays()

func _reset_arrays() -> void:
	active.fill(0)
	alive.fill(0)
	generation.fill(0)
	pos_x.fill(0)
	pos_z.fill(0)
	velocity_x.fill(0)
	velocity_z.fill(0)
	heading.fill(0)
	health.fill(0)
	knockback_velocity_x.fill(0)
	knockback_velocity_z.fill(0)
	hit_stun_ticks_remaining.fill(0)
	_entity_id.fill(0)

func configure(
	active_player_mask: int,
	config: PlayerSimConfig,
	map_grid: SimMapGrid,
	allocator: EntityIdAllocator
) -> Error:
	if _configured:
		return ERR_ALREADY_IN_USE
	if config.validate(map_grid, active_player_mask) != OK:
		return ERR_INVALID_DATA
	if allocator == null:
		return ERR_INVALID_PARAMETER
	_reset_arrays()
	for slot in range(SLOT_COUNT):
		if (active_player_mask & (1 << slot)) == 0:
			continue
		var reference := allocator.allocate()
		if reference.is_empty() or reference.entity_id != slot + 1 or reference.generation != 1:
			_reset_arrays()
			return ERR_CANT_CREATE
		active[slot] = 1
		alive[slot] = 1
		_entity_id[slot] = reference.entity_id
		generation[slot] = reference.generation
		pos_x[slot] = config.spawn_x[slot]
		pos_z[slot] = config.spawn_z[slot]
		heading[slot] = 1 + FixedMath.euclidean_mod(4 + config.input_heading_offset, 16)
		health[slot] = config.initial_health
	_configured = true
	return OK

func entity_id_for_slot(slot: int) -> int:
	return _entity_id[slot] if is_active(slot) else INVALID_ENTITY_ID

func is_active(slot: int) -> bool:
	return slot >= 0 and slot < SLOT_COUNT and active[slot] != 0

func is_alive(slot: int) -> bool:
	return is_active(slot) and alive[slot] != 0

func generation_for_slot(slot: int) -> int:
	return generation[slot] if is_active(slot) else 0

func get_position_units(slot: int) -> Vector2i:
	return Vector2i(pos_x[slot], pos_z[slot]) if is_active(slot) else Vector2i.ZERO

func slot_for_entity_id(entity_id: int, expected_generation: int) -> int:
	var slot := entity_id - 1
	if slot < 0 or slot >= SLOT_COUNT:
		return -1
	if not is_active(slot):
		return -1
	return slot if _entity_id[slot] == entity_id and generation[slot] == expected_generation else -1

func encode_canonical(writer: LittleEndianWriter) -> void:
	writer.write_u8(SLOT_COUNT)
	for slot in range(SLOT_COUNT):
		writer.write_u8(active[slot])
		writer.write_u8(alive[slot])
		writer.write_i32(_entity_id[slot])
		writer.write_i32(generation[slot])
		writer.write_i32(pos_x[slot])
		writer.write_i32(pos_z[slot])
		writer.write_i32(velocity_x[slot])
		writer.write_i32(velocity_z[slot])
		writer.write_i32(heading[slot])
		writer.write_i32(health[slot])
		writer.write_i32(knockback_velocity_x[slot])
		writer.write_i32(knockback_velocity_z[slot])
		writer.write_i32(hit_stun_ticks_remaining[slot])
```

`encode_canonical(writer)` 固定先写 `slot_count:u8 = 4`，再按 slot 0～3 把 `active/alive` 写为 `u8`，把 `entity_id/generation/pos_x/pos_z/velocity_x/velocity_z/heading/health/knockback_velocity_x/knockback_velocity_z/hit_stun_ticks_remaining` 写为 `i32-le`；未启用槽位也写全零，禁止省略。验证必须断言相同 world allocator 分配历史产生相同 entity/generation bytes，且 allocator 本身仍只由 `SimulationWorld.encode_canonical_state()` 的 Plan 1 段编码一次，玩家段不得重复编码 allocator 内部数组。

- [ ] **Step 5：实现 heading 驱动的整数加减速、击退和地图碰撞**

`PlayerMovementSystem` 预分配四项 candidate X/Z，以及 next velocity、knockback、heading、hit-stun 数组。每 Tick 先把当前状态复制到 next 数组，再为每名激活且存活玩家计算地图碰撞结果；任何约束失败时丢弃 next 数组，不让半个 Tick 写入世界：

```gdscript
var _players: SimPlayerState
var _candidate_x := PackedInt32Array()
var _candidate_z := PackedInt32Array()
var _next_velocity_x := PackedInt32Array()
var _next_velocity_z := PackedInt32Array()
var _next_knockback_x := PackedInt32Array()
var _next_knockback_z := PackedInt32Array()
var _next_heading := PackedInt32Array()
var _next_hit_stun := PackedInt32Array()
var _last_error := ""

func _init(players: SimPlayerState) -> void:
	assert(players != null)
	_players = players
	_candidate_x.resize(4)
	_candidate_z.resize(4)
	_next_velocity_x.resize(4)
	_next_velocity_z.resize(4)
	_next_knockback_x.resize(4)
	_next_knockback_z.resize(4)
	_next_heading.resize(4)
	_next_hit_stun.resize(4)

func _copy_current_to_scratch(players: SimPlayerState) -> void:
	for slot in range(4):
		_candidate_x[slot] = players.pos_x[slot]
		_candidate_z[slot] = players.pos_z[slot]
		_next_velocity_x[slot] = players.velocity_x[slot]
		_next_velocity_z[slot] = players.velocity_z[slot]
		_next_knockback_x[slot] = players.knockback_velocity_x[slot]
		_next_knockback_z[slot] = players.knockback_velocity_z[slot]
		_next_heading[slot] = players.heading[slot]
		_next_hit_stun[slot] = players.hit_stun_ticks_remaining[slot]

func get_last_error() -> String:
	return _last_error

func _approach(current: int, target: int, amount: int) -> int:
	if current < target:
		return mini(current + amount, target)
	if current > target:
		return maxi(current - amount, target)
	return current

func _command_velocity(command_heading: int, config: PlayerSimConfig) -> Vector2i:
	if command_heading == 0:
		return Vector2i.ZERO
	return Vector2i(
		FixedMath.floor_div(FixedMath.heading_x(command_heading) * config.max_speed_per_tick, 1024),
		FixedMath.floor_div(FixedMath.heading_z(command_heading) * config.max_speed_per_tick, 1024)
	)

func _candidate_for_slot(
	slot: int,
	command: PlayerFrameCommand,
	players: SimPlayerState,
	map_grid: SimMapGrid,
	config: PlayerSimConfig
) -> Vector2i:
	var target := Vector2i.ZERO
	var rate := config.deceleration_per_tick
	if players.hit_stun_ticks_remaining[slot] > 0:
		target = Vector2i.ZERO
		_next_velocity_x[slot] = players.knockback_velocity_x[slot]
		_next_velocity_z[slot] = players.knockback_velocity_z[slot]
		_next_knockback_x[slot] = _approach(players.knockback_velocity_x[slot], 0, config.knockback_deceleration_per_tick)
		_next_knockback_z[slot] = _approach(players.knockback_velocity_z[slot], 0, config.knockback_deceleration_per_tick)
		_next_hit_stun[slot] = players.hit_stun_ticks_remaining[slot] - 1
	else:
		target = _command_velocity(command.move_heading, config)
		rate = config.acceleration_per_tick if command.move_heading != 0 else config.deceleration_per_tick
		_next_velocity_x[slot] = _approach(players.velocity_x[slot], target.x, rate)
		_next_velocity_z[slot] = _approach(players.velocity_z[slot], target.y, rate)
		if command.move_heading != 0:
			_next_heading[slot] = command.move_heading
	return map_grid.move_circle_x_then_z(
		players.pos_x[slot], players.pos_z[slot], config.radius_units,
		_next_velocity_x[slot], _next_velocity_z[slot]
	)
```

`apply_knockback()` 只接受 active/alive 槽位、heading 1..16、`0..PlayerSimConfig.MAX_VELOCITY_PER_TICK` 的速度和 `0..1_048_576` 的硬直 Tick；用方向表换算 X/Z，写入 knockback velocity，并取现有硬直与新硬直的较大值。地图碰撞后的实际位移在最终提交时回写 `velocity_x/z = candidate - old_position`，因此撞墙不会保留穿墙速度：

```gdscript
func apply_knockback(
	player_slot: int,
	heading: int,
	speed_per_tick: int,
	hit_stun_ticks: int
) -> bool:
	if not _players.is_alive(player_slot):
		return false
	if heading < 1 or heading > 16:
		return false
	if speed_per_tick < 0 or speed_per_tick > PlayerSimConfig.MAX_VELOCITY_PER_TICK:
		return false
	if hit_stun_ticks < 0 or hit_stun_ticks > 1_048_576:
		return false
	_players.knockback_velocity_x[player_slot] = FixedMath.floor_div(
		FixedMath.heading_x(heading) * speed_per_tick, 1024
	)
	_players.knockback_velocity_z[player_slot] = FixedMath.floor_div(
		FixedMath.heading_z(heading) * speed_per_tick, 1024
	)
	_players.hit_stun_ticks_remaining[player_slot] = maxi(
		_players.hit_stun_ticks_remaining[player_slot], hit_stun_ticks
	)
	return true
```

- [ ] **Step 6：实现玩家候选之间的固定圆形重叠解算**

`PlayerSeparationSystem` 使用整数二分搜索计算向上取整平方根；每个 pass 先对 slot 对 `(0,1)..(2,3)` 依序尝试 X 分离，再按同一 pair 顺序尝试 Z 分离。每次位移都通过 `SimMapGrid.move_circle_x_then_z()`，因此不能把玩家推出地图或穿入阻挡格：

```gdscript
extends RefCounted
class_name PlayerSeparationSystem

const MAX_PASSES := 4

func _ceil_isqrt(value: int) -> int:
	if value <= 0:
		return 0
	var low := 1
	var high := mini(value, PlayerSimConfig.MAX_RADIUS_UNITS * 2)
	assert(value <= high * high)
	while low < high:
		var middle := low + FixedMath.floor_div(high - low, 2)
		if middle * middle >= value:
			high = middle
		else:
			low = middle + 1
	return low

func _split_correction(amount: int) -> Vector2i:
	var lower_amount := FixedMath.floor_div(amount, 2)
	var upper_amount := amount - lower_amount
	return Vector2i(lower_amount, upper_amount)

func _overlaps(
	left_slot: int,
	right_slot: int,
	x: PackedInt32Array,
	z: PackedInt32Array,
	diameter: int
) -> bool:
	var dx := x[right_slot] - x[left_slot]
	var dz := z[right_slot] - z[left_slot]
	return dx * dx + dz * dz < diameter * diameter

func _resolve_pair_axis(
	left_slot: int,
	right_slot: int,
	axis: int,
	x: PackedInt32Array,
	z: PackedInt32Array,
	map_grid: SimMapGrid,
	radius_units: int,
	diameter: int
) -> void:
	var dx := x[right_slot] - x[left_slot]
	var dz := z[right_slot] - z[left_slot]
	if dx * dx + dz * dz >= diameter * diameter:
		return
	var component := dx if axis == 0 else dz
	var perpendicular := dz if axis == 0 else dx
	var required_squared := diameter * diameter - perpendicular * perpendicular
	if required_squared <= 0:
		return
	var required_abs := _ceil_isqrt(required_squared)
	var current_abs := absi(component)
	if current_abs >= required_abs:
		return
	var split := _split_correction(required_abs - current_abs)
	var direction := 1 if component >= 0 else -1
	var left_delta := -direction * split.x
	var right_delta := direction * split.y
	var left_resolved := map_grid.move_circle_x_then_z(
		x[left_slot], z[left_slot], radius_units,
		left_delta if axis == 0 else 0,
		left_delta if axis == 1 else 0
	)
	x[left_slot] = left_resolved.x
	z[left_slot] = left_resolved.y
	var right_resolved := map_grid.move_circle_x_then_z(
		x[right_slot], z[right_slot], radius_units,
		right_delta if axis == 0 else 0,
		right_delta if axis == 1 else 0
	)
	x[right_slot] = right_resolved.x
	z[right_slot] = right_resolved.y
```

X 阶段以当前 `dz` 算 `required_abs_dx = ceil_isqrt(diameter² - dz²)`；不足量按两名玩家分摊，奇数余量固定给较大 slot。`dx == 0` 时较小 slot 向负 X、较大 slot 向正 X。X 被地图完全阻挡且仍重叠时，Z 阶段用同一规则处理；`dz == 0` 时较小 slot 向负 Z。固定 4 pass 后仍有任一存活 pair 重叠时返回 `false`，世界以 `player separation unresolved` 拒绝该 Tick，不按节点顺序接受穿透状态。

```gdscript
func resolve(
	players: SimPlayerState,
	candidate_x: PackedInt32Array,
	candidate_z: PackedInt32Array,
	map_grid: SimMapGrid,
	radius_units: int
) -> bool:
	var diameter := radius_units * 2
	for _pass_index in range(MAX_PASSES):
		for axis in [0, 1]:
			for left_slot in range(4):
				if not players.is_alive(left_slot):
					continue
				for right_slot in range(left_slot + 1, 4):
					if not players.is_alive(right_slot):
						continue
					_resolve_pair_axis(
						left_slot, right_slot, axis,
						candidate_x, candidate_z, map_grid, radius_units, diameter
					)
	for left_slot in range(4):
		for right_slot in range(left_slot + 1, 4):
			if players.is_alive(left_slot) and players.is_alive(right_slot) and _overlaps(left_slot, right_slot, candidate_x, candidate_z, diameter):
				return false
	return true

func has_overlap(
	players: SimPlayerState,
	candidate_x: PackedInt32Array,
	candidate_z: PackedInt32Array,
	radius_units: int
) -> bool:
	var diameter := radius_units * 2
	for left_slot in range(4):
		if not players.is_alive(left_slot):
			continue
		for right_slot in range(left_slot + 1, 4):
			if players.is_alive(right_slot) and _overlaps(
				left_slot, right_slot, candidate_x, candidate_z, diameter
			):
				return true
	return false
```

- [ ] **Step 7：增加玩家模拟 runtime 的裸整数除法门槛**

创建 `validate_frame_sync_player_integer_division.gd`，只扫描模拟配置、状态、移动、分离和 world，不扫描允许浮点表现计算的 `scripts/simulation/view/`。逐行去掉 `#` 注释和单双引号字符串后，剩余源码出现 `/` 即失败；运行时文件禁止三引号字符串，失败信息必须带路径和 1-based 行号：

```gdscript
extends SceneTree

const RUNTIME_PATHS := PackedStringArray([
	"res://scripts/simulation/players/player_sim_config.gd",
	"res://scripts/simulation/players/sim_player_state.gd",
	"res://scripts/simulation/players/player_movement_system.gd",
	"res://scripts/simulation/players/player_separation_system.gd",
	"res://scripts/simulation/world/simulation_world.gd",
])

func _code_without_strings_or_comment(line: String) -> String:
	var result := ""
	var quote := ""
	var escaped := false
	for index in range(line.length()):
		var character := line.substr(index, 1)
		if not quote.is_empty():
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == quote:
				quote = ""
			continue
		if character == "#":
			break
		if character == "\"" or character == "'":
			quote = character
			continue
		result += character
	return result

func _init() -> void:
	var failures := PackedStringArray()
	for path in RUNTIME_PATHS:
		if not FileAccess.file_exists(path):
			failures.append("missing player runtime source: %s" % path)
			continue
		var source := FileAccess.get_file_as_string(path)
		if source.contains("\"\"\"") or source.contains("'''"):
			failures.append("triple-quoted string forbidden in player runtime: %s" % path)
			continue
		var lines := source.split("\n")
		for line_index in range(lines.size()):
			if _code_without_strings_or_comment(lines[line_index]).contains("/"):
				failures.append("raw division operator: %s:%d" % [path, line_index + 1])
	if failures.is_empty():
		print("validate_frame_sync_player_integer_division: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
```

所有玩家模拟整数商都调用 `FixedMath.floor_div()`；`PlayerView` 和 `SimulationFollowCamera` 的浮点 `/`、`atan2()`、`normalized()`、插值和平滑明确不加入扫描清单。

- [ ] **Step 8：把玩家阶段接入 `SimulationWorld` 并扩展规范状态**

`configure_players()` 必须在地图已配置后执行，验证 `session.active_player_mask`、玩家配置和 `manifest.config_hash`。世界 `step()` 的玩家阶段保持 SPEC 顺序：验证帧后生成玩家地图候选、Task 2 解析队伍范围、统一提交，再进入后续僵尸/战斗阶段：

```gdscript
func configure_players(config: PlayerSimConfig) -> bool:
	if _next_tick != 0 or _sim_players != null:
		return _fail("players must be configured exactly once before tick 0")
	if _map_grid == null or config == null:
		return _fail("map must be configured before players")
	if config.input_heading_offset != _session.get_input_heading_offset():
		return _fail("player input heading offset mismatch")
	if config.validate(_map_grid, _session.get_active_player_mask()) != OK:
		return _fail("player configuration rejected")
	var config_hash := StateHasher.hash_canonical(config.encode_canonical())
	var legacy_combined_hash := config.combined_config_hash(_map_asset.get_content_hash())
	if not _validate_player_component_hash(config_hash, legacy_combined_hash):
		return _fail("player component hash mismatch")
	var config_snapshot := config.duplicate(true) as PlayerSimConfig
	if config_snapshot == null:
		return _fail("player configuration copy failed")
	_sim_players = SimPlayerState.new()
	if _sim_players.configure(
		_session.get_active_player_mask(), config_snapshot, _map_grid, _allocator
	) != OK:
		_sim_players = null
		return _fail("player configuration rejected")
	_player_config = config_snapshot
	_player_movement_system = PlayerMovementSystem.new(_sim_players)
	_player_separation_system = PlayerSeparationSystem.new()
	_team_bounds_system = TeamBoundsSystem.new()
	return true

func _validate_player_component_hash(
	config_hash: PackedByteArray,
	legacy_combined_hash: PackedByteArray
) -> bool:
	if config_hash.size() != 32 or legacy_combined_hash.size() != 32:
		return false
	return StateHasher.equal(
		legacy_combined_hash,
		_session.get_manifest().config_hash
	)

func _step_players(frame: LocalFrameCommandSet) -> bool:
	if _sim_players == null:
		return true
	if not _player_movement_system.step(
		frame, _sim_players, _map_grid, _player_config,
		_player_separation_system, _team_bounds_system
	):
		return _fail(_player_movement_system.get_last_error())
	return true

func get_player_state() -> SimPlayerState:
	return _sim_players

func get_player_config() -> PlayerSimConfig:
	if _player_config == null:
		return null
	return _player_config.duplicate(true) as PlayerSimConfig
```

这个空状态早退仅用于保留 Plan 1 core-only 和 Plan 2 map-only 验证；玩家旁路不能依赖该分支，`PlayerSimulationSandbox._build_runtime()` 必须在创建 driver 前确认 `configure_map()` 与 `configure_players()` 都成功。

Plan 6 引入并成功配置 `_config_bundle: SimulationConfigBundle` 后，只在 `_validate_player_component_hash()` 最前面增加以下分支，原 legacy fallback 保留给 Plan 3～5 的聚焦 fixture：

```gdscript
if _config_bundle != null:
	return StateHasher.equal(
		config_hash,
		_config_bundle.get_component_hash(SimulationConfigBundle.PLAYER)
	)
```

该分支比较的是纯玩家 component hash；不得拿 `_session.get_manifest().config_hash`（完整 bundle hash）与 `config_hash` 比较，也不得再次混入 map hash。

扩展 Plan 1 已固定的 `_encode_player_section(writer)`：四槽 `last command` 的字节子序保持不变；未配置玩家时继续写 Plan 1 预留的 `player_sim_marker:u8 = 0`，配置后写 marker 1、独立 schema、配置和状态。这样 Plan 1 core-only 与 Plan 2 map-only canonical bytes 保持各自冻结金样；不得在 Plan 2 地图尾部另加玩家段：

```gdscript
func _encode_player_section(writer: LittleEndianWriter) -> void:
	writer.write_u8(4)
	for command in _last_commands:
		writer.write_u8(command.move_heading)
		writer.write_u8(command.action_bits)
		writer.write_i8(command.equipment_delta)
		writer.write_u8(command.placement_heading)
	if _sim_players == null:
		writer.write_u8(0)
		return
	writer.write_u8(1) # player simulation marker
	writer.write_u8(1) # player simulation schema
	var config_bytes := _player_config.encode_canonical()
	writer.write_u16(config_bytes.size())
	writer.write_bytes(config_bytes)
	_sim_players.encode_canonical(writer)
```

`encode_canonical_state()` 只在原 Plan 1 player slot 位置调用 `_encode_player_section(writer)`，随后继续既有 zombie、allocator/other entities、Plan 2 dynamic map、PRNG、wave 和 event 段。验证必须同时锁定：world header 的 `config_bundle_marker` 在 Plan 3 旁路始终为 0；未配置玩家时 `player_sim_marker` 为 0 且 Plan 1/2 冻结字节不变；配置玩家后 `player_sim_marker` 为 1、schema 为 1 且位于 zombie 段之前；allocator canonical 仍只出现一次。不得写 PlayerView、摄像机、场景 Transform 或 viewport。

- [ ] **Step 9：运行玩家移动、裸除法、Plan 1/2 回归和导入检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_movement.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_asset.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_replay.gd -- --ticks=300
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 六条命令全部退出 0；Plan 2 map-only 300 Tick replay 的 canonical bytes/Hash 不因 player section 扩展而改变；裸除法扫描输出 `validate_frame_sync_player_integer_division: PASS`；玩家验证明确覆盖 1/2/3/4 人初始化、静止保留朝向、加速、减速、击退硬直、地图边界、阻挡格、两人/四人重叠、墙边分离、slot Tie-break、offset 不匹配 fail-fast 和相同输入的相同 canonical bytes。

### Task 2：实现批量 `TeamBoundsSystem` 与 1～4 人确定性门槛

**Files:**

- Create: `scripts/simulation/players/team_bounds_system.gd`
- Modify: `scripts/simulation/players/player_movement_system.gd`
- Modify: `scripts/simulation/world/simulation_world.gd`
- Create: `tools/validation/validate_frame_sync_team_bounds.gd`
- Modify: `tools/validation/validate_frame_sync_player_integer_division.gd`
- Modify: `scripts/simulation/testing/first_divergence_harness.gd`

**Interfaces:**

- Consumes: Task 1 已完成地图碰撞和 `PlayerSeparationSystem` 的 `SimPlayerState` 候选位置、Plan 1 `FixedMath.floor_div()`、`InputTape`、codec 双世界 harness。
- Produces: 冻结的 `TeamBoundsSystem.resolve(...)`；最终接口 `FirstDivergenceHarness.run_player_replay(tape, map_asset, player_config, tick_limit, render_probe := Callable()) -> Dictionary`，Task 2 不调用无效 probe，Task 4 增加纯表现检查。

- [ ] **Step 1：先写 X/Z 跨度、整体平移和倒地排除的失败验证**

创建 `validate_frame_sync_team_bounds.gd`，用直接整数位置验证以下矩阵：

```gdscript
var players := _make_players(0b1111)
var candidates_x := PackedInt32Array([-13000, 13000, -12000, 12000])
var candidates_z := PackedInt32Array([-9500, -9500, 9500, 9500])
var bounds := TeamBoundsSystem.new()
bounds.resolve(players, candidates_x, candidates_z, 24576, 18432)
_expect(_span(candidates_x, players) <= 24576, "X span must be capped", failures)
_expect(_span(candidates_z, players) <= 18432, "Z span must be capped", failures)

players.alive[3] = 0
candidates_x[3] = 200000
bounds.resolve(players, candidates_x, candidates_z, 24576, 18432)
_expect(candidates_x[3] == 200000, "downed player must not constrain survivors", failures)
```

另建：单人候选不裁剪；四人整体 `+1024 X` 且跨度未变时全部接受；两名玩家同时向相反方向越界时以旧中心对称裁剪；奇数上限时低侧取得 `floor_div(max_span, 2)`、高侧取得剩余 1 单位；相同候选值按 slot 升序遍历但结果不依赖输入数组构造顺序。

- [ ] **Step 2：运行验证并确认 TeamBounds 缺失时失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_team_bounds.gd
```

Expected: 非零退出，预加载 `team_bounds_system.gd` 失败或 `resolve()` 不存在。

- [ ] **Step 3：实现以前一 Tick 包围盒中心为基准的轴裁剪**

`resolve()` 先收集 slot 升序的存活玩家。少于 2 人直接返回。每个轴用旧位置算中心、候选位置算跨度；不超限时保持所有候选不变，超限时只把存活玩家候选裁到固定窗口：

```gdscript
extends RefCounted
class_name TeamBoundsSystem

func resolve(
	players: SimPlayerState,
	candidate_x: PackedInt32Array,
	candidate_z: PackedInt32Array,
	max_span_x_units: int,
	max_span_z_units: int
) -> void:
	var live_slots := PackedInt32Array()
	for slot in range(4):
		if players.is_alive(slot):
			live_slots.append(slot)
	if live_slots.size() < 2:
		return
	_resolve_axis(players.pos_x, candidate_x, live_slots, max_span_x_units)
	_resolve_axis(players.pos_z, candidate_z, live_slots, max_span_z_units)

func _resolve_axis(
	previous: PackedInt32Array,
	candidates: PackedInt32Array,
	live_slots: PackedInt32Array,
	maximum_span: int
) -> void:
	var previous_min := previous[live_slots[0]]
	var previous_max := previous_min
	var candidate_min := candidates[live_slots[0]]
	var candidate_max := candidate_min
	for index in range(1, live_slots.size()):
		var slot := live_slots[index]
		previous_min = mini(previous_min, previous[slot])
		previous_max = maxi(previous_max, previous[slot])
		candidate_min = mini(candidate_min, candidates[slot])
		candidate_max = maxi(candidate_max, candidates[slot])
	if candidate_max - candidate_min <= maximum_span:
		return
	var center := FixedMath.floor_div(previous_min + previous_max, 2)
	var low := center - FixedMath.floor_div(maximum_span, 2)
	var high := low + maximum_span
	for slot in live_slots:
		candidates[slot] = clampi(candidates[slot], low, high)
```

`is_within_limits()` 复用同一 slot 升序存活过滤，分别计算 candidate X/Z 的 min/max；少于 2 名存活玩家返回 true，否则同时要求 X span ≤ `max_span_x_units` 且 Z span ≤ `max_span_z_units`。它只做验证，不二次修改数组。

固定先调用 X、再调用 Z；不读取摄像机、视口或输入在线状态。设备离线由 Task 3 暂停整个 Tick，而不是把玩家排除出队伍范围。

同时把 `res://scripts/simulation/players/team_bounds_system.gd` 加入 `validate_frame_sync_player_integer_division.gd` 的 `RUNTIME_PATHS`，保持 View/Camera 不在扫描清单中。

- [ ] **Step 4：在地图候选完成后、位置提交前调用 TeamBounds**

`PlayerMovementSystem.step()` 的完整批量顺序固定为：复制当前状态到 next 数组；slot 升序生成地图碰撞候选；调用一次内部含 4 个固定 pass 的 `PlayerSeparationSystem.resolve()`；调用一次 `TeamBoundsSystem.resolve()`；验证最终无重叠、跨度合法且地图位置 clear；slot 升序一次性提交位置和全部 next 状态：

```gdscript
func step(
	frame: LocalFrameCommandSet,
	players: SimPlayerState,
	map_grid: SimMapGrid,
	config: PlayerSimConfig,
	separation: PlayerSeparationSystem,
	team_bounds: TeamBoundsSystem
) -> bool:
	_last_error = ""
	if frame == null or not frame.is_valid() or players != _players:
		_last_error = "invalid player movement input"
		return false
	if map_grid == null or config == null or separation == null or team_bounds == null:
		_last_error = "player movement dependency unavailable"
		return false
	for slot in range(4):
		if players.is_active(slot) != ((frame.active_player_mask & (1 << slot)) != 0):
			_last_error = "player movement active mask mismatch"
			return false

	_copy_current_to_scratch(players)
	for slot in range(4):
		if not players.is_alive(slot):
			continue
		var candidate := _candidate_for_slot(
			slot, frame.player_commands[slot], players, map_grid, config
		)
		_candidate_x[slot] = candidate.x
		_candidate_z[slot] = candidate.y

	if not separation.resolve(players, _candidate_x, _candidate_z, map_grid, config.radius_units):
		_last_error = "player separation unresolved"
		return false
	team_bounds.resolve(
		players, _candidate_x, _candidate_z,
		config.max_team_span_x_units, config.max_team_span_z_units
	)

	if separation.has_overlap(players, _candidate_x, _candidate_z, config.radius_units):
		_last_error = "team bounds and separation constraints conflict"
		return false
	if not team_bounds.is_within_limits(
		players, _candidate_x, _candidate_z,
		config.max_team_span_x_units, config.max_team_span_z_units
	):
		_last_error = "team bounds limit unresolved"
		return false

	for slot in range(4):
		if not players.is_alive(slot):
			continue
		var final_position := Vector2i(_candidate_x[slot], _candidate_z[slot])
		if map_grid.move_circle_x_then_z(
			final_position.x, final_position.y, config.radius_units, 0, 0
		) != final_position:
			_last_error = "player constraint result overlaps map"
			return false

	for slot in range(4):
		if not players.is_alive(slot):
			continue
		players.velocity_x[slot] = _candidate_x[slot] - players.pos_x[slot]
		players.velocity_z[slot] = _candidate_z[slot] - players.pos_z[slot]
		players.pos_x[slot] = _candidate_x[slot]
		players.pos_z[slot] = _candidate_z[slot]
		players.heading[slot] = _next_heading[slot]
		players.knockback_velocity_x[slot] = _next_knockback_x[slot]
		players.knockback_velocity_z[slot] = _next_knockback_z[slot]
		players.hit_stun_ticks_remaining[slot] = _next_hit_stun[slot]
	return true
```

TeamBounds 裁剪点位处于旧点位与已通过地图碰撞的候选之间；验证必须检查裁剪后圆仍为 clear。若 Plan 2 网格报告不 clear，世界返回确定性错误并停止该 Tick，禁止用 Godot Physics 修正。

- [ ] **Step 5：扩展双世界玩家回放 harness**

`run_player_replay()` 为两个世界按相同顺序调用 `configure_map()` 和 `configure_players()`。左世界接收录像原始 frame，右世界接收 `decode(encode(frame))`；每 Tick 比较 Hash，并在首次差异返回 Plan 1 既有诊断字段：

```gdscript
func run_player_replay(
	tape: InputTape,
	map_asset: SimMapAsset,
	player_config: PlayerSimConfig,
	tick_limit: int,
	render_probe: Callable = Callable()
) -> Dictionary:
	var direct_world := SimulationWorld.new(tape.get_session())
	var codec_world := SimulationWorld.new(tape.get_session())
	for world in [direct_world, codec_world]:
		if not world.configure_map(map_asset) or not world.configure_players(player_config):
			return {"ok": false, "tick": -1, "error": world.get_last_error()}
	for tick in range(tick_limit):
		var direct_frame := tape.get_frame(tick)
		var encoded := LocalFrameCommandCodec.encode(direct_frame)
		var codec_frame := LocalFrameCommandCodec.decode(encoded)
		if not direct_world.step(tick, direct_frame) or not codec_world.step(tick, codec_frame):
			return _failure(tick, encoded, direct_world, codec_world)
		if not StateHasher.equal(_hash(direct_world), _hash(codec_world)):
			return _failure(tick, encoded, direct_world, codec_world)
	return {"ok": true, "ticks_checked": tick_limit}
```

验证脚本为 mask 1/3/7/15 各生成包含静止、同向移动、反向分散、两人迎面、四人汇聚、墙边拥挤、撞墙和队伍边缘的 10,000 Tick 固定录像，并断言逐 Tick无分歧且每 Tick 任意存活玩家 pair 均不重叠。

- [ ] **Step 6：运行 TeamBounds、10,000 Tick 回放和导入检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_team_bounds.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_movement.gd -- --replay-ticks=10000
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 四条命令退出 0；裸除法扫描包含 `team_bounds_system.gd` 并输出 PASS；1 人没有队伍裁剪，2/3/4 人均不超过 X/Z 上限且没有玩家重叠，整体移动不受阻，倒地玩家排除，直接与 codec 世界 10,000 Tick 每 Tick Hash 相同。

### Task 3：从现有 GameSession 装配旁路 1～4 玩家会话并处理设备断线

**Files:**

- Create: `scripts/simulation/session/local_simulation_session_factory.gd`
- Create: `scripts/simulation/driver/player_simulation_sandbox.gd`
- Create: `scenes/simulation/PlayerSimulationSandbox.tscn`
- Create: `scenes/simulation/PlayerSimulationLobby.tscn`
- Create: `tools/validation/validate_frame_sync_player_sandbox.gd`
- Modify: `tools/validation/validate_frame_sync_player_integer_division.gd`

**Interfaces:**

- Consumes: 现有 `GameSessionState.mode/local_players/last_error`、`LocalPlayerDescriptor.source_key()/create_input_source()`、`SinglePlayerInputSource`、Plan 1 `SimulationManifest`/`LocalSimulationSession`/collector/buffer/driver。
- Produces: `LocalSimulationSessionFactory.create(game_session, manifest, single_player_source, session_seed, input_heading_offset) -> Dictionary`；`PlayerSimulationSandbox.is_waiting_for_device() -> bool`、`get_world() -> SimulationWorld`、`has_buffered_frame(tick: int) -> bool`、`advance_physics_callback() -> bool`。

- [ ] **Step 1：先写固定方向基、双装备边沿和会话映射失败验证**

创建 `validate_frame_sync_player_sandbox.gd`。用不读取全局 Input 的固定输入源返回 `Vector2(0, -1)`：先构造 `input_heading_offset = 0` 的 Plan 1 session/collector，断言 heading 为 5；再构造 offset 8 的 session/collector，断言同一输入得到 heading 13。把一个完全无关的视觉 Camera3D 旋转 90° 后重新采集，两个 session 的命令 bytes 都不改变。固定输入源同时设置 previous/next，继续断言 Plan 1 collector 产出 `equipment_delta == 0`。

再分别构造：单人 `GameSession`；含 2 个连续 descriptor 的本地多人；空本地名单；5 人名单；descriptor `player_index` 与 slot 不同；重复 source key；离线手柄。断言前两者成功，其余情况返回明确错误且不创建 session/runtime 结果。

- [ ] **Step 2：运行验证并确认 factory/旁路场景缺失时失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_sandbox.gd
```

Expected: 非零退出，原因是 `local_simulation_session_factory.gd` 尚不存在；Plan 1 collector 的 offset 0/8 断言本身必须通过，不得要求新的 collector 构造参数或读取 Camera3D Basis。

- [ ] **Step 3：锁定 Plan 1 collector 默认语义且不修改其文件**

验证只使用 Plan 1 冻结接口 `LocalInputCollector.new(session, sources)`。本地 heading 由 Plan 1 先量化，世界 heading 只由 session offset 旋转：

```gdscript
var default_session := LocalSimulationSession.new(
	manifest, 17, 0b0001, [&"fixed", &"", &"", &""], 0
)
var arena_session := LocalSimulationSession.new(
	manifest, 17, 0b0001, [&"fixed", &"", &"", &""], 8
)
var default_frame := LocalInputCollector.new(
	default_session, [fixed_source, null, null, null]
).collect(0)
fixed_source.reset_edges()
var arena_frame := LocalInputCollector.new(
	arena_session, [fixed_source, null, null, null]
).collect(0)
_expect(default_frame.player_commands[0].move_heading == 5, "offset 0 must preserve Plan 1 screen-up heading", failures)
_expect(arena_frame.player_commands[0].move_heading == 13, "offset 8 must rotate screen-up into DemoArena world forward", failures)
```

本计划不得修改 `scripts/simulation/input/local_input_collector.gd`。若上述默认 offset 0 断言失败，先停止 Plan 3 并修复 Plan 1；不得在 Plan 3 增加方向基参数。previous/next 异或归零和 22 bytes 帧格式同样只复用 Plan 1 冻结行为。

- [ ] **Step 4：实现 `LocalSimulationSessionFactory`**

factory 不继承 Node，不保存 GameSession 引用。返回成功字典包含 `session`、恰好四项 `sources` 和 `active_player_mask`；失败包含 `error`：

```gdscript
static func create(
	game_session: GameSessionState,
	manifest: SimulationManifest,
	single_player_source: PlayerInputSource,
	session_seed: int,
	input_heading_offset: int
) -> Dictionary:
	if game_session == null or manifest == null:
		return {"error": "session dependencies unavailable"}
	if session_seed < 1 or session_seed > 2147483646:
		return {"error": "session seed out of range"}
	if input_heading_offset < 0 or input_heading_offset > 15:
		return {"error": "input heading offset out of range"}
	var sources: Array = [null, null, null, null]
	var keys: Array[StringName] = [&"", &"", &"", &""]
	var mask := 0b0001
	if game_session.mode == GameSessionState.Mode.SINGLE:
		if single_player_source == null:
			return {"error": "single-player input source unavailable"}
		var single_key := single_player_source.get_source_key()
		if single_key.is_empty():
			return {"error": "single-player input source key unavailable"}
		sources[0] = single_player_source
		keys[0] = single_key
	elif game_session.mode == GameSessionState.Mode.LOCAL_MULTIPLAYER:
		var descriptors: Array = game_session.local_players
		if descriptors.is_empty() or descriptors.size() > 4:
			return {"error": "local player count must be 1..4"}
		mask = (1 << descriptors.size()) - 1
		var used_keys: Dictionary = {}
		for slot in range(descriptors.size()):
			var descriptor = descriptors[slot]
			if descriptor == null or descriptor.player_index != slot:
				return {"error": "local player slots must be contiguous"}
			if not descriptor.online:
				return {"error": "local player device is offline"}
			var source = descriptor.create_input_source()
			var source_key := descriptor.source_key()
			if source == null or source_key.is_empty() or source.get_source_key() != source_key:
				return {"error": "local player input source mismatch"}
			if used_keys.has(source_key):
				return {"error": "local player input sources must be unique"}
			used_keys[source_key] = true
			sources[slot] = source
			keys[slot] = source_key
	else:
		return {"error": "unsupported game session mode"}
	var session := LocalSimulationSession.new(
		manifest, session_seed, mask, keys, input_heading_offset
	)
	if not session.is_valid():
		return {"error": "local simulation session rejected"}
	return {"session": session, "sources": sources, "active_player_mask": mask}
```

旁路场景导出 `@export_range(1, 2147483646, 1) var session_seed := 1`，测试夹具显式传入固定 seed；不得使用 `randomize()`。

- [ ] **Step 5：创建旁路场景装配器和设备等待状态**

`PlayerSimulationSandbox.tscn` 在 Task 3 根为 `Node3D`，只包含空的 `Players` 容器和 `CanvasLayer/DeviceWaitOverlay`；此任务不得预放、预加载或调用 Task 4 尚未创建的 `PlayerViewRegistry`、`ViewBridge`、`PlayerView` 或 `SimulationFollowCamera`。同时不实例化 `Player.tscn`、`DemoArena.tscn`、`CharacterBody3D`、`NavigationAgent3D` 或旧 `FollowCamera.tscn`。

`PlayerSimulationLobby.tscn` 以现有 `LocalMultiplayerLobby.tscn` 为唯一场景实例，只覆盖该实例的 `game_scene_path = "res://scenes/simulation/PlayerSimulationSandbox.tscn"`；不复制或修改大厅脚本、加入规则、预览模型和默认大厅资源。这样旁路多人可从既有大厅生成同一 `GameSession.local_players`，而默认菜单仍进入旧大厅/旧 DemoArena。

```ini
[gd_scene load_steps=2 format=3]

[ext_resource type="PackedScene" path="res://scenes/menu/LocalMultiplayerLobby.tscn" id="1_lobby"]

[node name="PlayerSimulationLobby" instance=ExtResource("1_lobby")]
game_scene_path = "res://scenes/simulation/PlayerSimulationSandbox.tscn"
```

根脚本在 `_ready()` 依次加载 `demo_arena_map.tres`、玩家 config、构造 combined config hash/manifest、调用 factory、创建 world、`configure_map()`、`configure_players()`、collector、buffer、driver。物理推进前检查所有启用 source：

```gdscript
const MAP_ASSET: SimMapAsset = preload(
	"res://resources/simulation/maps/demo_arena_map.tres"
)
const PLAYER_CONFIG: PlayerSimConfig = preload(
	"res://resources/simulation/players/demo_arena_player_sim_config.tres"
)

var _single_player_source: PlayerInputSource = SinglePlayerInputSource.new()
var _frame_buffer: LocalFrameInputBuffer

func _build_runtime() -> bool:
	var legacy_combined_hash := PLAYER_CONFIG.combined_config_hash(
		MAP_ASSET.get_content_hash()
	)
	var manifest := SimulationManifest.new(
		1, 3, MAP_ASSET.map_id, legacy_combined_hash
	)
	var result := LocalSimulationSessionFactory.create(
		GameSession, manifest, _single_player_source, session_seed,
		PLAYER_CONFIG.input_heading_offset
	)
	if result.has("error"):
		GameSession.last_error = result.error
		return false
	_session = result.session
	_sources = result.sources
	_world = SimulationWorld.new(_session)
	if not _world.configure_map(MAP_ASSET) or not _world.configure_players(PLAYER_CONFIG):
		GameSession.last_error = _world.get_last_error()
		return false
	var collector := LocalInputCollector.new(_session, _sources)
	_frame_buffer = LocalFrameInputBuffer.new()
	_driver = LocalFrameSyncDriver.new(
		_world, collector, _frame_buffer
	)
	return true

func is_waiting_for_device() -> bool:
	return _waiting_for_device

func get_world() -> SimulationWorld:
	return _world

func has_buffered_frame(tick: int) -> bool:
	return _frame_buffer != null and _frame_buffer.has_complete_frame(tick)

func _physics_process(_delta: float) -> void:
	advance_physics_callback()

func advance_physics_callback() -> bool:
	if _world == null or _driver == null:
		return false
	_waiting_for_device = false
	for slot in range(4):
		if (_session.get_active_player_mask() & (1 << slot)) == 0:
			continue
		if _sources[slot] == null or not _sources[slot].is_online():
			_waiting_for_device = true
			break
	$CanvasLayer/DeviceWaitOverlay.visible = _waiting_for_device
	if _waiting_for_device:
		return false
	return _driver.advance_physics_callback()
```

离线期间 world next tick、冷却、硬直、位置和 Hash 全部不变，也不调用 `sample()`。恢复时继续原 source 对象；`GamepadInputSource.get_device_id()` 必须与会话 source key 中的设备 ID 一致，不创建替代设备。验证用固定 source 暴露只读 `sample_count`，证明等待期间 collector 从未采样；沙盒无需新增未被 Plan 1 driver 消费的第二份 `InputTape`。

把 `local_simulation_session_factory.gd` 与 `player_simulation_sandbox.gd` 加入玩家裸除法扫描清单；允许浮点除法的 `scripts/simulation/view/` 仍不加入。Task 3 完成后的清单必须精确为：

```gdscript
const RUNTIME_PATHS := PackedStringArray([
	"res://scripts/simulation/players/player_sim_config.gd",
	"res://scripts/simulation/players/sim_player_state.gd",
	"res://scripts/simulation/players/player_movement_system.gd",
	"res://scripts/simulation/players/player_separation_system.gd",
	"res://scripts/simulation/players/team_bounds_system.gd",
	"res://scripts/simulation/session/local_simulation_session_factory.gd",
	"res://scripts/simulation/driver/player_simulation_sandbox.gd",
	"res://scripts/simulation/world/simulation_world.gd",
])
```

- [ ] **Step 6：验证断线暂停、Plan 1 collector 回归和默认菜单路径未变**

测试夹具用可切换 online 且记录 `sample_count` 的固定 source：推进到 tick 5，保存 world canonical bytes、Hash、driver simulation step count、source sample count，并断言 `has_buffered_frame(5) == false`；设 offline 后调用 120 次物理 callback，断言四者与 next tick 均不变且 buffer 仍无 tick 5。恢复同一对象后第 1 个 callback 仍不采样、不缓存帧，第 2 个 callback 采样一次并推进 tick 5，成功帧被 driver 立即 take 后 buffer 仍为空。验证脚本同时断言 `ProjectSettings.get_setting("application/run/main_scene") == "res://scenes/menu/MainMenu.tscn"`，并读取 `scripts/menu/main_menu.gd`、`scripts/menu/local_multiplayer_lobby.gd`，确认两者默认 `game_scene_path` 文本仍为 `res://scenes/gameplay/DemoArena.tscn`。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_sandbox.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --quit-after 5 res://scenes/simulation/PlayerSimulationSandbox.tscn
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --quit-after 5 res://scenes/simulation/PlayerSimulationLobby.tscn
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
git diff -- project.godot scripts/menu/main_menu.gd scripts/menu/local_multiplayer_lobby.gd scenes/gameplay/DemoArena.tscn scripts/gameplay/demo_arena.gd scripts/player/player_controller.gd scripts/camera/follow_camera.gd scripts/simulation/input/local_input_collector.gd
```

Expected: 六条 Godot 命令退出 0；玩家 runtime 裸除法扫描通过；Plan 1 collector 的 offset 0、装备边沿与 codec 回归通过；Task 3 sandbox 在完全没有 Task 4 脚本/场景时也能装配 world/driver 并 Headless 退出；最后一条 diff 无输出；主场景仍为 MainMenu，默认菜单/大厅仍进入旧 DemoArena，旁路大厅只覆盖自身实例的目标，断线没有中性帧、Tick 推进或 source 替换。

### Task 4：添加最小 PlayerView、纯表现共享镜头与分辨率无关 Hash 门槛

**Files:**

- Create: `scripts/simulation/view/player_view.gd`
- Create: `scripts/simulation/view/simulation_player_view_registry.gd`
- Create: `scripts/simulation/view/player_simulation_view_bridge.gd`
- Create: `scripts/simulation/view/simulation_follow_camera.gd`
- Create: `scenes/simulation/PlayerView.tscn`
- Create: `scenes/simulation/SimulationFollowCamera.tscn`
- Modify: `scripts/simulation/driver/player_simulation_sandbox.gd`
- Modify: `scenes/simulation/PlayerSimulationSandbox.tscn`
- Modify: `scripts/simulation/testing/first_divergence_harness.gd`
- Create: `tools/validation/validate_frame_sync_player_view.gd`

**Interfaces:**

- Consumes: `SimulationWorld.get_player_state()`、driver 的成功 Tick 信号、Task 1/2 双实例回放。
- Produces: 本文冻结的 PlayerView、registry、`SimulationFollowCamera` 接口；`PlayerSimulationViewBridge.bind_world(world: SimulationWorld, registry: SimulationPlayerViewRegistry) -> void`、`capture_tick(tick: int) -> void`、`render_interpolated(alpha: float) -> void`。

- [ ] **Step 1：先写 PlayerView 插值和镜头不改 Hash 的失败验证**

创建 `validate_frame_sync_player_view.gd`。先单独验证一个 PlayerView：push 初始 tick -1 `(0, 0)`、tick 0 `(1024, 2048)`，alpha 0/0.5/1 的渲染位置分别为 `(0,0,0)`、`(0.5,0,1)`、`(1,0,2)`；再次提交 tick 0 或更旧样本必须被忽略。heading 1 的视觉 yaw 固定为 `-PI / 2.0`，alive false 时 `is_player_visible()` 为 false。再在 world 已推进后销毁 slot 1 View、注册一个同 slot 新 View，并用当前已完成 tick 再次调用 bridge capture；新 View 必须立即得到当前状态，world bytes/Hash 不变。

再创建两个同 session/map/config 世界，使用同一 4 人录像：A 不创建任何 View；B 每 Tick 后把快照推入 View，并按 `[640×360, 1280×720, 1024×1024, 2532×1170]` 循环分辨率，以 `[0.0, 0.17, 0.5, 0.83, 1.0]` alpha 和 `[0.0, 1.0 / 240.0, 1.0 / 30.0, 0.2]` camera delta 任意调用表现。每 Tick 断言 A/B Hash 相同。

- [ ] **Step 2：运行验证并确认 view/camera 缺失时失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_view.gd
```

Expected: 非零退出，缺少 PlayerView、registry、bridge 或 `SimulationFollowCamera`；不得把表现验证改成只比较最终 Transform。

- [ ] **Step 3：实现 previous/current 样本和最小 PlayerView**

`PlayerView.tscn` 根为 `Node3D`，子节点仅含一个 `MeshInstance3D` 胶囊/圆柱占位和 `Label3D` 玩家编号；无碰撞、Area、输入、武器、血条逻辑、音频和模拟引用。脚本只保存表现副本：

```gdscript
extends Node3D
class_name PlayerView

const UNITS_PER_WORLD_UNIT := 1024.0

var _player_slot := -1
var _has_sample := false
var _previous_tick := -1
var _current_tick := -1
var _previous_position := Vector2i.ZERO
var _current_position := Vector2i.ZERO
var _current_heading := 13
var _alive := false
var _health := 0

func bind_player_slot(slot: int) -> void:
	assert(slot >= 0 and slot < 4)
	_player_slot = slot
	$Label3D.text = "P%d" % (slot + 1)

func get_player_slot() -> int:
	return _player_slot

func get_render_position() -> Vector3:
	return global_position

func get_render_motion_direction() -> Vector3:
	var delta := _current_position - _previous_position
	var motion := Vector3(float(delta.x), 0.0, float(delta.y))
	return motion.normalized() if motion.length_squared() > 0.0 else Vector3.ZERO

func is_player_visible() -> bool:
	return _alive

func push_simulation_sample(
	tick: int,
	position_units: Vector2i,
	heading: int,
	alive: bool,
	health: int
) -> void:
	if _has_sample and tick <= _current_tick:
		return
	if not _has_sample:
		_previous_position = position_units
		_previous_tick = tick
		_has_sample = true
	else:
		_previous_position = _current_position
		_previous_tick = _current_tick
	_current_position = position_units
	_current_tick = tick
	_current_heading = heading
	_alive = alive
	_health = health

func render_interpolated(alpha: float) -> void:
	var weight := clampf(alpha, 0.0, 1.0)
	var x := lerpf(float(_previous_position.x), float(_current_position.x), weight) / UNITS_PER_WORLD_UNIT
	var z := lerpf(float(_previous_position.y), float(_current_position.y), weight) / UNITS_PER_WORLD_UNIT
	position = Vector3(x, 0.0, z)
	if _current_heading >= 1 and _current_heading <= 16:
		var facing_x := float(FixedMath.heading_x(_current_heading))
		var facing_z := float(FixedMath.heading_z(_current_heading))
		rotation.y = atan2(-facing_x, -facing_z)
	visible = _alive
```

`_has_sample` 必须独立于 tick 值，确保 `capture_tick(-1)` 真正成为初始样本而不是“尚未初始化”哨兵。视觉 yaw 通过 heading 整数表换算后使用 `atan2()`，只发生在表现层；任何浮点误差不进入 world。

- [ ] **Step 4：实现按 slot 稳定注册的 registry 和只读 bridge**

registry 内部固定四项数组，不依赖子节点遍历顺序；重复 slot 或越界注册报错并拒绝。`get_views()` 始终按 slot 升序返回已注册项，`get_visible_views()` 只过滤 `is_player_visible()`：

```gdscript
extends Node
class_name SimulationPlayerViewRegistry

var _views: Array[PlayerView] = [null, null, null, null]

func register_view(view: PlayerView) -> void:
	var slot := view.get_player_slot() if is_instance_valid(view) else -1
	if slot < 0 or slot >= 4:
		push_error("invalid player view slot")
		return
	if _views[slot] != null and not is_instance_valid(_views[slot]):
		_views[slot] = null
	if _views[slot] != null:
		push_error("invalid or duplicate player view slot")
		return
	_views[slot] = view

func unregister_view(view: PlayerView) -> void:
	if not is_instance_valid(view):
		return
	var slot := view.get_player_slot()
	if slot >= 0 and slot < 4 and _views[slot] == view:
		_views[slot] = null

func view_for_slot(slot: int) -> PlayerView:
	if slot < 0 or slot >= 4:
		return null
	if _views[slot] != null and not is_instance_valid(_views[slot]):
		_views[slot] = null
	return _views[slot]

func get_views() -> Array[PlayerView]:
	var result: Array[PlayerView] = []
	for slot in range(4):
		if _views[slot] != null and not is_instance_valid(_views[slot]):
			_views[slot] = null
		if _views[slot] == null:
			continue
		result.append(_views[slot])
	return result

func get_visible_views() -> Array[PlayerView]:
	var result: Array[PlayerView] = []
	for view in get_views():
		if view.is_player_visible():
			result.append(view)
	return result
```

bridge 显式绑定 world/registry，每个成功 Tick 只复制值：

```gdscript
extends Node
class_name PlayerSimulationViewBridge

var _world: SimulationWorld
var _registry: SimulationPlayerViewRegistry

func bind_world(
	world: SimulationWorld,
	registry: SimulationPlayerViewRegistry
) -> void:
	assert(world != null and registry != null)
	_world = world
	_registry = registry

func capture_tick(tick: int) -> void:
	if _world == null or _registry == null or tick < -1:
		return
	var players := _world.get_player_state()
	if players == null:
		return
	for slot in range(4):
		var view := _registry.view_for_slot(slot)
		if view == null or not players.is_active(slot):
			continue
		view.push_simulation_sample(
			tick,
			players.get_position_units(slot),
			players.heading[slot],
			players.is_alive(slot),
			players.health[slot]
		)

func render_interpolated(alpha: float) -> void:
	if _registry == null:
		return
	for view in _registry.get_views():
		view.render_interpolated(alpha)
```

bridge 不保存可写 `SimPlayerState` 到 PlayerView，不调用 world.step，不发送 gameplay event。它不维护全局“最后捕获 Tick”闸门：各 `PlayerView` 自己拒绝旧样本，因此同一当前 Tick 可以重发给刚重建的 View，而已有 View 会忽略重复样本。

- [ ] **Step 5：实现纯表现共享镜头中心和宽高比适配**

`SimulationFollowCamera.tscn` 复制旧 `FollowCamera.tscn` 的 Camera3D 固定 transform `Transform3D(1,0,0, 0,0.7626684,0.6467897, 0,-0.6467897,0.7626684, 0,12,14.142136)`、orthogonal projection、near `0.1` 和 far `120.0`；根只移动 X/Z，`VisualOffset/Camera3D` 保存视觉冲击。摄像机按可见 PlayerView 的插值位置求包围盒中心；正交 size 同时满足 Z 跨度和按 viewport aspect 换算的 X 跨度，加入固定 `padding_world_units = 2.0`，再限制 `min_orthographic_size = 12.0`、`max_orthographic_size = 32.0`，足以在方形视口容纳 24 单位 X 跨度和两侧留白：

```gdscript
func _desired_camera(views: Array[PlayerView], viewport_size: Vector2) -> Dictionary:
	var first := views[0].get_render_position()
	var min_x := first.x
	var max_x := first.x
	var min_z := first.z
	var max_z := first.z
	for index in range(1, views.size()):
		var point := views[index].get_render_position()
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		min_z = minf(min_z, point.z)
		max_z = maxf(max_z, point.z)
	var center := Vector3((min_x + max_x) * 0.5, global_position.y, (min_z + max_z) * 0.5)
	var movement_sum := Vector3.ZERO
	for view in views:
		movement_sum += view.get_render_motion_direction()
	var movement_push := (
		movement_sum / float(views.size()) * max_direction_offset
	).limit_length(max_direction_offset)
	center += movement_push
	var aspect := maxf(viewport_size.x / maxf(viewport_size.y, 1.0), 0.01)
	var required_z := (max_z - min_z) + padding_world_units * 2.0
	var required_x_as_height := ((max_x - min_x) + padding_world_units * 2.0) / aspect
	var size := clampf(maxf(required_z, required_x_as_height), min_orthographic_size, max_orthographic_size)
	return {"center": center, "size": size}
```

`render_camera(delta, viewport_size)` 在 `registry.get_visible_views()` 为空时保持最后锚点和 size；否则只用 `smoothing_weight = 1 - exp(-follow_speed * delta)` 平滑根位置和 Camera3D.size，并把中心限制到从 `Rect2i` 换算的地图范围；不同分辨率只改变 size/留白。`max_direction_offset = 3.0` 的共同移动推动每帧从 previous/current 样本重新计算，不跨帧累加。`add_shot_impulse()` 只把归一化方向乘 strength 累加到有上限且自动恢复的 `VisualOffset.position`；根锚点、size、View 样本和 world 均不改变。

- [ ] **Step 6：在 Task 4 才向旁路沙盒挂接 View、bridge 和共享镜头**

修改 `PlayerSimulationSandbox.tscn`，在 Task 3 已有 `Players`/`CanvasLayer` 之外新增 `PlayerViewRegistry`、`ViewBridge` 和 `SimulationFollowCamera.tscn` 实例；Task 4 才允许根脚本 preload 这些类型。沙盒按 active mask 实例化 `PlayerView.tscn`，slot 升序注册；成功完成一个模拟 Tick 后调用 `bridge.capture_tick(completed_tick)`，并在装配表现时设置地图整数边界：

```gdscript
func _build_views() -> void:
	_view_registry = $PlayerViewRegistry
	_view_bridge = $ViewBridge
	_follow_camera = $SimulationFollowCamera
	_view_bridge.bind_world(_world, _view_registry)
	_follow_camera.set_player_view_registry(_view_registry)
	_follow_camera.set_world_bounds_units(Rect2i(
		MAP_ASSET.origin_x_units,
		MAP_ASSET.origin_z_units,
		MAP_ASSET.width * MAP_ASSET.cell_size_units,
		MAP_ASSET.height * MAP_ASSET.cell_size_units
	))
	for slot in range(4):
		if (_session.get_active_player_mask() & (1 << slot)) == 0:
			continue
		var view := PLAYER_VIEW_SCENE.instantiate() as PlayerView
		view.bind_player_slot(slot)
		$Players.add_child(view)
		_view_registry.register_view(view)
	if not _driver.simulation_advanced.is_connected(_on_simulation_advanced):
		_driver.simulation_advanced.connect(_on_simulation_advanced)
	_view_bridge.capture_tick(-1)

func _on_simulation_advanced(tick: int, _diagnostic_hash: PackedByteArray) -> void:
	_view_bridge.capture_tick(tick)
```

`capture_tick(-1)` 作为初始表现样本时，bridge 必须显式读取当前出生位置并传给 View，不能调用 world.step；后续只接受成功完成的非负 Tick。`_process(delta)` 计算纯表现 alpha 并更新 bridge/camera：

```gdscript
func _process(delta: float) -> void:
	if _view_bridge == null or _follow_camera == null:
		return
	var phase := float(_driver.get_physics_callback_count() & 1)
	var alpha := clampf((phase + Engine.get_physics_interpolation_fraction()) * 0.5, 0.0, 1.0)
	_view_bridge.render_interpolated(alpha)
	_follow_camera.render_camera(delta, get_viewport().get_visible_rect().size)
```

表现节点丢失或重建时，先从 registry 注销旧实例，再按相同 slot 注册新实例，并立即调用 `_view_bridge.capture_tick(maxi(_world.get_next_tick() - 1, -1))`。该重复 current-tick capture 只初始化新 View，已有 View 自己拒绝重复样本；不得为重建 View 调用 `world.step()`、补帧或修改 Hash。

只消费 Plan 1 已冻结的 `simulation_advanced(tick, diagnostic_hash)` 信号；正常本地 driver 只有每 30 Tick 携带 Hash，但信号每个成功 Tick 都发出，因此表现只使用 tick、不依赖 Hash 是否为空。不为表现修改 driver 的模拟推进逻辑，也不从 `_process()` 猜测是否完成了 Tick。

- [ ] **Step 7：扩展回放验证分辨率和相机节奏不进入 Hash**

在 `first_divergence_harness.gd` 的玩家回放中增加可选 `render_probe: Callable`，只在两边 Hash 比较后调用；probe 对 codec 世界的只读快照执行任意数量的 View/Camera 更新，再重新计算 codec world Hash，必须与调用前相同：

```gdscript
var before_render := _hash(codec_world)
if render_probe.is_valid():
	render_probe.call(tick, codec_world)
var after_render := _hash(codec_world)
if not StateHasher.equal(before_render, after_render):
	return {
		"ok": false,
		"tick": tick,
		"error": "presentation mutated canonical simulation state"
	}
```

用 mask 1、3、7、15 各运行 100,000 Tick；每 Tick 原始/codec Hash 相同，且每 30 Tick 更换 viewport、follow speed、camera delta、render 调用次数和 `add_shot_impulse()` 序列后 Hash 仍不变。

- [ ] **Step 8：运行最终自动门槛与范围审查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_movement.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_team_bounds.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_sandbox.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_player_view.gd -- --ticks=100000
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_replay.gd -- --ticks=300
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
git diff --check
git diff -- project.godot scripts/menu/main_menu.gd scripts/menu/local_multiplayer_lobby.gd scenes/gameplay/DemoArena.tscn scripts/gameplay/demo_arena.gd scripts/player/player_controller.gd scripts/gameplay/local_player_spawner.gd scripts/camera/follow_camera.gd scenes/camera/FollowCamera.tscn scripts/simulation/input/local_input_collector.gd
```

Expected: 八条 Godot 命令和 `git diff --check` 退出 0；Plan 2 map-only canonical regression 通过；最后一条 diff 无输出；主场景/默认战斗入口未变，单人、2 人、3 人、4 人 100,000 Tick 逐 Tick 零分歧，分辨率/镜头节奏 probe 前后 Hash 不变。

- [ ] **Step 9：执行旁路人工验收**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . res://scenes/simulation/PlayerSimulationLobby.tscn
```

按以下顺序验收，不使用自动 UI 控制：

1. 单人验收直接运行 `PlayerSimulationSandbox.tscn`，使用 WASD、方向键或已连接手柄移动；角色只由 30 Hz 帧命令推进，改变窗口大小、拖动成长宽屏或方屏时玩家世界位置不跳变。
2. 多人验收运行 `PlayerSimulationLobby.tscn`，按现有大厅规则加入 2～4 名玩家并开始；所有玩家可同时朝不同方向移动，接近 24×18 世界跨度时只阻止继续分散，保持跨度内的整体同向移动。
3. 断开一个已绑定手柄，等待层出现，所有玩家、硬直和 Tick 完全暂停；连接回相同设备 ID 后继续下一 Tick，其他手柄不能接管。
4. 摄像机保持存活玩家可见；正交 size 可随宽高比/玩家跨度变化，镜头平滑和视觉震动不改变玩家位置、朝向或最终回放 Hash。

Plan 3 尚无合法 gameplay 命令可让玩家倒地，因此不得为人工验收增加绕过帧命令的 debug 写状态入口；倒地玩家排除、View 隐藏和重建由 `validate_frame_sync_team_bounds.gd` 与 `validate_frame_sync_player_view.gd` 的直接状态夹具覆盖，待 Plan 5/6 接入伤害/倒地命令后再加入整局人工流程。

## 规格覆盖复核

- Task 1 覆盖固定四槽位、稳定实体 ID、整数参数、1～4 玩家初始化、加减速、静止朝向、击退/硬直、地图边界/阻挡格、同 Tick 批量玩家重叠解算和玩家 canonical state。
- Task 2 覆盖地图碰撞/玩家分离后的批量候选、单人绕过、2～4 人 24×18 世界跨度、旧包围盒中心、X 后 Z、slot Tie-break、整体移动、倒地排除和双实例回放。
- Task 3 覆盖现有 GameSession/LocalPlayerDescriptor/输入源接缝、固定镜头方向配置、0 Tick 输入延迟、双装备边沿归零、设备断线暂停/同设备恢复，以及复用现有大厅规则的独立旁路入口。
- Task 4 覆盖 previous/current Tick 最小 PlayerView、稳定 registry、只读桥、共享中心/宽高比/正交 size/平滑、分辨率和相机节奏不进入 Hash、1/2/3/4 人 100,000 Tick 门槛。
- MainMenu 主场景、菜单/大厅默认 DemoArena 战斗入口、旧 PlayerController、旧 FollowCamera、Jolt、NavigationServer 和运行时 NavMesh 均由全局约束与最终 diff 审查明确保持不变。

## 占位符与类型一致性复核

- 本计划没有未定义的实现阶段、空测试步骤或省略的错误路径；所有新增公开 API 均在文件结构、冻结接口或对应 Task 中定义。
- `PlayerSimConfig.max_team_span_x_units/z_units` 在资源、TeamBounds、canonical bytes 和 Hash 中统一为 24576/18432；`SimPlayerState` 和 Plan 4～7 均统一使用 slot 0～3 与正实体 ID。
- 玩家配置与 session 的 `input_heading_offset` 必须同为 8；不匹配在 allocator 分配前 fail-fast。纯玩家 component hash、legacy map+player combined hash 与 Plan 6 bundle PLAYER component 的职责分离，唯一切换点是 `_validate_player_component_hash()`。Plan 3 的 world header `config_bundle_marker` 保持 0；player canonical 只占用 Plan 1 预留 marker 的固定 section，marker 0/1 与 schema 1 明确，不在地图尾部重复追加。
- 地图入口统一为 `resources/simulation/maps/demo_arena_map.tres` 的 `SimMapAsset`，碰撞统一调用 `SimMapGrid.move_circle_x_then_z()`；没有第二套运行时导图或 Physics fallback。
- 玩家彼此碰撞统一由 `PlayerSeparationSystem.resolve()` 处理，地图候选、X→Z 固定 pass、TeamBounds 和最终提交之间没有单节点即时移动分支。
- `validate_frame_sync_player_integer_division.gd` 扫描全部 Plan 3 非 View runtime；表现层浮点除法不进入扫描，模拟层所有整数商统一使用 `FixedMath.floor_div()`。
- 世界路径统一为 `scripts/simulation/world/simulation_world.gd`，长期回放统一扩展 `scripts/simulation/testing/first_divergence_harness.gd`，旁路场景统一为 `scenes/simulation/PlayerSimulationSandbox.tscn`。
- PlayerView previous/current 样本只存在表现层；规范状态只编码 `SimPlayerState` 当前整数状态，因此 Task 4 的任意渲染节奏不会改变 Hash。

## 交付判定

- [ ] 单人和本地 2～4 人旁路沙盒都只由 `LocalFrameCommandSet`、`LocalFrameInputBuffer` 和 `SimulationWorld.step()` 推进。
- [ ] 玩家移动、击退、硬直、地图碰撞、玩家彼此分离和队伍跨度均为整数规则，不读取 Godot Physics、Camera3D、视口或 delta。
- [ ] 单人不受屏幕边缘或 TeamBounds 影响；多人最大跨度为 X 24576、Z 18432，倒地玩家不参与。
- [ ] 设备离线期间不采样、不生成中性帧、不推进 Tick；只允许原设备恢复。
- [ ] 最小 PlayerView 和共享镜头可销毁/重建而不影响世界；分辨率、宽高比、camera delta、follow speed 和更新次数均不改变 Hash。
- [ ] mask 1、3、7、15 的玩家录像各 100,000 Tick 无首分歧；Plan 1/2 回归和 Headless 导入通过。
- [ ] `project.godot` 仍以 MainMenu 为主场景，默认单人/本地多人战斗仍进入旧 DemoArena，旧玩家和旧镜头文件没有 diff；达到 Plan 7/8 门槛前不切换默认战斗路径。

## 执行交接

开始实现前先询问用户是否使用独立 worktree；默认选择当前工作区，不主动创建 worktree。随后由用户在以下方式中选择：

1. **Subagent-Driven（推荐）**：使用 `subagent-driven-development`，按 Task 1～4 逐项派发新 subagent，并在每个 Task 后做规格与代码质量复核。
2. **Inline Execution**：使用 `executing-plans`，在当前会话按批次执行 Task 1～4，并在批次间设置检查点。

两种方式都不为单独 Task 创建提交，也不在计划结束时自动执行 `git add`、`git commit` 或 squash；全部实现与验证完成后，由用户自行审阅并提交整个计划的改动。
