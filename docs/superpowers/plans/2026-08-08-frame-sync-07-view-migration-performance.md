# 帧同步表现迁移与 100+ 渲染优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Plan 1～6 的完整确定性玩法接入可重建、可池化、可限流的 Godot 表现层，提供单人和本地 2～4 人均可选择的完整帧同步战斗路径，同时保持旧 `DemoArena` 为默认回退，并为 100～150 只僵尸建立稳定的渲染性能边界。

**Architecture:** 新路径使用独立的 `FrameSyncDemoArena` 会话根，整局只创建一套 `SimulationWorld`、`LocalFrameSyncDriver` 与 `SimulationViewBridge`；旧 `PlayerController`、`ZombieTarget`、Jolt 和 Navigation 节点不会进入该场景。桥在每个成功模拟 Tick 后抓取 previous/current 只读样本并消费稳定表现事件，在任意渲染节奏下只做插值、动画、音频、FX 和 HUD；玩家、僵尸、尸体和世界实体均使用固定容量池，节点丢失时按当前模拟状态重建而不重播已消费的一次性事件。

**Tech Stack:** Godot 4.7.1、GDScript、Plan 1～6 的整数 `SimulationWorld`/帧命令/表现事件、Plan 3 的 `PlayerView`/`SimulationFollowCamera`、`AnimationPlayer`、`PackedScene` 固定池、`CombatFxPrewarmer`、`GroundBloodManager`、`SpatialSfxPool`、headless 场景结构验证与实机渲染采样。

## Global Constraints

- 唯一规格来源是 `docs/superpowers/specs/2026-08-08-local-deterministic-frame-sync-design.md`；前序计划或现有代码与规格冲突时，以规格为准。
- 本计划只能在 Plan 1～6 各自的自动验证、Headless 导入和人工门槛全部通过后执行；任一门槛失败时不得接入本计划的新战斗入口。
- `res://scenes/gameplay/DemoArena.tscn` 必须继续作为默认战斗路径；本计划只把 `res://scenes/gameplay/FrameSyncDemoArena.tscn` 建成显式可选且完整可玩的旁路，默认切换留给 Plan 8。
- 整局玩法判定只能是 `LEGACY_DEMO` 或 `FRAME_SYNC` 之一；不得按玩家、武器、僵尸、爆炸、拾取、放置或波次混用新旧判定，也不得在战斗开始后切换 runtime。
- 新路径不得实例化或调用 `PlayerController`、`ZombieTarget`、`ExplosiveBarrel`、`PickupChest`、`PlaceItemService`、`CharacterBody3D`、`NavigationAgent3D`、`NavigationServer3D` 或 Godot Physics 查询来决定玩法结果。
- `SimulationViewBridge`、所有 View、动画、摄像机、FX、音频和 HUD 只能读取模拟状态与 `SimPresentationEvent`；不得调用 `SimulationWorld.step()`、写模拟数组、生成帧命令、改写随机流或参与 Hash。
- 模拟固定 30 Hz、Godot physics 固定 60 Hz、输入延迟固定 0 Tick；表现层使用浮点和渲染 delta 只允许改变视觉插值，不得改变模拟 Tick、命令或规范状态 Hash。
- 表现事件使用 Plan 5 的 `SimPresentationEvent`：`tick/event_id/event_type/source_entity_id/source_generation/target_entity_id/target_generation/origin_x/origin_z/position_x/position_z/heading/value/aux`；视图绑定和池复用必须同时匹配 ID 与 generation。
- `event_id` 是 int64，公式为 `tick * 4096 + sorted_index + 1`；同一事件即使重复暴露、同 Tick 重抓或 View 重建，也只能触发一次音频、FX、动画和 HUD one-shot。
- 玩家视图继续扩展 Plan 3 的 `PlayerView.bind_player_slot()`、`push_simulation_sample()`、`render_interpolated()`、`get_render_position()` 和 `is_player_visible()`；不得另造相冲突的玩家视图或相机接口。
- 完整表现装配只能通过 `FrameSyncPresentationRoot.bind_bridge(bridge, render_camera)`；Plan 8 cadence 复用同一入口后仍只调用单参数 `SimulationViewBridge.render_interpolated(alpha)`，绑定的 `Camera3D` 仅用于可见性和距离分级，不参与模拟或 Hash。
- 设备断开时只暂停模拟 Tick并显示等待相同设备恢复的 UI；暂停期间不采集中性命令、不推进冷却/波次/受伤，且不允许其他设备接管该槽位。
- 新运行时战斗 FX 仍位于 `scenes/fx/`；使用 mesh、shader、粒子或首播动画的效果根必须实现 `warmup_for_render(context)` 与 `finish_render_warmup()`，预热不得播放音频或产生玩法副作用。
- 100～150 只活跃僵尸是本计划硬场景；玩家池、僵尸池、尸体池、世界实体池、事件去重表、FX 池、音频池和材质实例数量在预热完成后不得持续增长。
- 普通 `FrameSyncDemoArena` 必须使用 Plan 6 提交配置的 `maximum_active_zombies = 24`；100/150 渲染档只使用 Task 3 有界 View 夹具和 Plan 8 performance fixture，不得改写 `demo_arena_world_gameplay.tres` 或普通玩法 manifest。
- 最低目标 Web 或移动设备最终预算仍是 100～150 只、30 Hz 模拟 P95 小于 8 ms、P99 不持续超过 16 ms；本计划必须产出包含渲染帧 P95/P99 与池增长的报告，最终跨平台资格判定由 Plan 8 完成。
- 自动验证不得使用 CUA；视觉与交互结果使用文末精确人工步骤并由用户提供截图或性能报告复核。
- 按仓库约定，本计划执行期间不创建 task 级提交；全部任务完成后由用户自行提交。

---

## 文件结构与稳定边界

| 路径 | 职责 |
| --- | --- |
| `scripts/gameplay/battle_runtime_selector.gd` | 定义整局 runtime 枚举、合法性和唯一场景路径；旧路径默认。 |
| `scripts/gameplay/game_session.gd` | 在进入战斗前冻结 runtime、玩家槽位与设备描述；战斗中拒绝改写。 |
| `scripts/input/local_player_descriptor.gd` | 提供深拷贝，使 GameSession 锁定后不暴露可改写的 source key 引用。 |
| `scripts/menu/main_menu.gd`、`scenes/menu/MainMenu.tscn` | 提供默认关闭的“实验帧同步”整局开关，并把同一选择传给单人或大厅。 |
| `scripts/menu/local_multiplayer_lobby.gd` | 保留大厅设备加入体验，并使用进入大厅前已冻结的 runtime 启动对应场景。 |
| `scripts/simulation/input/frame_sync_ui_input_source.gd` | 将新路径 HUD 的重新开始确认收束为 P1 下一 Tick 的 `CONFIRM` 命令。 |
| `scripts/simulation/driver/local_device_pause_controller.gd` | 检查启用槽位输入源在线状态，暂停/恢复 driver，禁止设备替代。 |
| `scripts/simulation/driver/local_frame_sync_driver.gd` | 增加显式模拟暂停接口；暂停时不改变二分频相位和 next Tick。 |
| `scripts/ui/device_reconnect_overlay.gd`、`scenes/ui/DeviceReconnectOverlay.tscn` | 显示离线玩家槽位和原设备名称，恢复后自动隐藏。 |
| `scripts/simulation/driver/frame_sync_demo_arena.gd` | 创建新会话、世界、输入、driver、桥、表现根和完整重开流程。 |
| `scenes/gameplay/FrameSyncArenaWorld.tscn` | 只含 DemoArena 静态视觉环境，不含碰撞、导航或旧玩法脚本。 |
| `scenes/gameplay/FrameSyncDemoArena.tscn` | 可选的完整新路径入口；组合静态世界、模拟 host、表现根、相机、HUD、触控和预热。 |
| `scripts/simulation/view/presentation_event_ledger.gd` | 固定容量 event_id 环形去重，重建时保留已消费记录。 |
| `scripts/simulation/view/player_view_pool.gd` | 固定四个玩家 View，按 slot + ID + generation 绑定和释放。 |
| `scripts/simulation/view/simulation_view_bridge.gd` | Tick 抓样、事件消费、状态重建、单参数渲染插值和只读 Camera3D 表现分级的唯一接缝。 |
| `scripts/simulation/view/frame_sync_hud.gd`、`scenes/simulation/FrameSyncHud.tscn` | 只读显示玩家生命/装备、波次、存活数、命中、失败和重开提示。 |
| `scripts/simulation/view/zombie_view.gd`、`scenes/simulation/ZombieView.tscn` | 无碰撞/导航/玩法脚本的僵尸模型、动画和可分级显示组件。 |
| `scripts/simulation/view/zombie_view_pool.gd` | 固定 160 个活体 View 与 32 个尸体槽，按 ID + generation 管理。 |
| `scripts/simulation/view/sim_world_entity_view.gd`、`scenes/simulation/SimWorldEntityView.tscn` | 只显示油桶、放置物和拾取物的量化状态。 |
| `scripts/simulation/view/world_entity_view_pool.gd` | 固定容量世界实体 View，不以 Node 生命周期决定玩法存在性。 |
| `scripts/simulation/view/view_performance_profile.gd` | 固定近/中/远距离、每帧更新频率和声音/FX 预算。 |
| `scripts/simulation/view/presentation_audio_router.gd` | 用一个固定 `SpatialSfxPool` 做距离分级、并发限制和稳定事件路由。 |
| `scripts/simulation/view/presentation_fx_router.gd` | 固定 tracer/impact/explosion 池、血迹请求预算和按稳定 event_id 首到先得的分类限流。 |
| `scripts/simulation/view/frame_sync_presentation_root.gd`、`scenes/simulation/FrameSyncPresentationRoot.tscn` | 聚合 View 池、registry、路由器、HUD 与 Camera3D，并按唯一固定顺序装配桥；整根或相机丢失后可重绑重建。 |
| `scripts/fx/barrel_explosion.gd` | 增加池化停用语义，保留已有 warmup 契约。 |
| `scripts/simulation/testing/view_performance_benchmark.gd` | 采集实际渲染帧、池容量、材质数和增长次数，输出 Plan 8 可复用报告。 |
| `tools/validation/validate_frame_sync_runtime_switch.gd` | 验证旧默认、新可选、整局冻结、场景隔离和断线暂停。 |
| `tools/validation/validate_simulation_view_bridge.gd` | 验证 Tick 样本、事件去重、generation、节点丢失重建和 Hash 不变。 |
| `tools/validation/validate_frame_sync_view_pools.gd` | 验证 150 只分级、固定池、FX/音频限流、warmup 和无增长。 |
| `tools/validation/validate_frame_sync_playable_path.gd` | 验证 Plan 6 完整循环在新场景的只读表现接线与旧路径未混入。 |

### Task 1：冻结整局 runtime，建立独立新场景与设备断线暂停

**Files:**

- Create: `scripts/gameplay/battle_runtime_selector.gd`
- Modify: `scripts/gameplay/game_session.gd`
- Modify: `scripts/input/local_player_descriptor.gd`
- Modify: `scripts/menu/main_menu.gd`
- Modify: `scenes/menu/MainMenu.tscn`
- Modify: `scripts/menu/local_multiplayer_lobby.gd`
- Create: `scripts/simulation/input/frame_sync_ui_input_source.gd`
- Create: `scripts/simulation/driver/local_device_pause_controller.gd`
- Modify: `scripts/simulation/driver/local_frame_sync_driver.gd`
- Create: `scripts/ui/device_reconnect_overlay.gd`
- Create: `scenes/ui/DeviceReconnectOverlay.tscn`
- Create: `scripts/simulation/driver/frame_sync_demo_arena.gd`
- Create: `scenes/gameplay/FrameSyncArenaWorld.tscn`
- Create: `scenes/gameplay/FrameSyncDemoArena.tscn`
- Create: `tools/validation/validate_frame_sync_runtime_switch.gd`

**Interfaces:**

- Consumes: Plan 1 的 `LocalSimulationSession.get_active_player_mask() -> int`、`get_slot_source_key(slot: int) -> StringName`、`LocalInputCollector`、`LocalFrameInputBuffer`、`LocalFrameSyncDriver`；现有 `PlayerInputSource.sample() -> PlayerInputState`、`is_online() -> bool`、`get_source_key() -> StringName`、`reset_edges() -> void`、`GameSession.local_players`、`LocalPlayerDescriptor.source_key()`、`create_input_source()`、`MobileControls.get_input_source()`。
- Produces: `BattleRuntimeSelector.LEGACY_DEMO`、`FRAME_SYNC`、`is_valid(runtime: int) -> bool`、`scene_path_for(runtime: int) -> String`。
- Extends: `LocalPlayerDescriptor.copy() -> LocalPlayerDescriptor`，复制 player index、source kind、gamepad device ID 和 online 状态；GameSession 不保存大厅仍可改写的 descriptor 引用。
- Produces: `GameSessionState.configure_single(battle_runtime: int = BattleRuntimeSelector.LEGACY_DEMO) -> bool`、`prepare_local(battle_runtime: int = BattleRuntimeSelector.LEGACY_DEMO) -> bool`、`configure_local(players: Array) -> bool`、`clear() -> bool`、`get_battle_runtime() -> int`、`get_battle_scene_path() -> String`、`get_active_player_mask() -> int`、`get_locked_source_keys() -> Array[StringName]`、`lock_for_battle() -> void`、`end_battle() -> void`、`is_battle_locked() -> bool`。`local_players` 改为只读深拷贝 getter，外部清空或改 descriptor 不得改变内部映射；`end_battle()` 只由战斗 scene teardown 调用以结束锁生命周期，不是局中退出槽位接口。
- Produces: `FrameSyncUiInputSource.new(base_source: PlayerInputSource, stable_source_key: StringName)`、`request_confirm() -> void`、`sample() -> PlayerInputState`、`is_online() -> bool`、`get_source_key() -> StringName`、`reset_edges() -> void`；其余采样委托给原 source，下一次 `sample()` 仅额外产生一次 `confirm_just_pressed`，在线状态与 source key 保持原会话绑定。
- Produces: `LocalFrameSyncDriver.set_simulation_paused(paused: bool, reason: StringName = &"") -> void`、`is_simulation_paused() -> bool`、`get_pause_reason() -> StringName`。
- Produces: `LocalDevicePauseController.bind(driver: LocalFrameSyncDriver, sources: Array, active_player_mask: int, source_labels: Array[String]) -> Error`、`refresh() -> void`；信号 `waiting_changed(waiting: bool, offline_slots: PackedInt32Array, labels: Array[String])`。
- Produces: `DeviceReconnectOverlay.show_waiting(offline_slots: PackedInt32Array, labels: Array[String]) -> void`、`hide_waiting() -> void`。
- Produces: `FrameSyncDemoArena.initialize_from_game_session() -> Error`、`request_restart_confirm() -> void`、`get_world() -> SimulationWorld`、`get_driver() -> LocalFrameSyncDriver`。
- Validation helpers: `_validate_new_scene_has_no_legacy_gameplay() -> void` 递归扫描新场景的节点类型与脚本路径；`_validate_disconnect_stops_next_tick_without_neutral_frame() -> void` 使用两个固定 source key 的可切换假输入源验证离线前后 Tick、buffer 和二分频相位；`_validate_locked_session_rejects_player_and_source_changes() -> void` 自行构造两人会话并尝试 hot join、退出、再次 configure、clear 和修改 getter 返回值。

- [ ] **Step 1：先写旧默认、整局冻结、断线暂停和场景隔离的失败验证**

创建 `validate_frame_sync_runtime_switch.gd`，预加载尚不存在的 selector、pause controller 与新场景，固定以下契约：

```gdscript
extends SceneTree

const BattleRuntimeSelector = preload("res://scripts/gameplay/battle_runtime_selector.gd")
const GameSessionState = preload("res://scripts/gameplay/game_session.gd")
const LocalDevicePauseController = preload("res://scripts/simulation/driver/local_device_pause_controller.gd")

func _init() -> void:
	var session := GameSessionState.new()
	_assert(session.get_battle_runtime() == BattleRuntimeSelector.LEGACY_DEMO, "旧 DemoArena 必须是默认 runtime")
	_assert(session.configure_single(BattleRuntimeSelector.FRAME_SYNC), "单人必须可显式选择新 runtime")
	_assert(session.get_battle_scene_path() == "res://scenes/gameplay/FrameSyncDemoArena.tscn", "新 runtime 必须解析到独立场景")
	session.lock_for_battle()
	_assert(not session.configure_single(BattleRuntimeSelector.LEGACY_DEMO), "战斗锁定后不得切换 runtime")
	_validate_locked_session_rejects_player_and_source_changes()
	_assert(load("res://scenes/gameplay/DemoArena.tscn") != null, "旧场景必须继续存在")
	_assert(load("res://scenes/gameplay/FrameSyncDemoArena.tscn") != null, "新场景必须可加载")
	_validate_new_scene_has_no_legacy_gameplay()
	_validate_disconnect_stops_next_tick_without_neutral_frame()
	print("validate_frame_sync_runtime_switch: PASS")
	quit()
```

`_validate_new_scene_has_no_legacy_gameplay()` 实例化新场景并递归断言没有 `CharacterBody3D`、`NavigationAgent3D`，也没有脚本路径 `player_controller.gd`、`zombie_target.gd`、`explosive_barrel.gd`、`pickup_chest.gd` 或 `place_item_service.gd`。断线夹具使用两个可切换 `is_online()` 的假输入源：slot 1 离线后连续四次 physics callback 都不得改变 `world.get_next_tick()` 或向 buffer 提交 Tick；恢复同一个 source key 后，下一完整二分频才推进原 next Tick。

- [ ] **Step 2：运行验证并确认因新 runtime 接口和场景缺失而失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_runtime_switch.gd
```

Expected: 非零退出，首个错误指向 `battle_runtime_selector.gd`、`local_device_pause_controller.gd` 或 `FrameSyncDemoArena.tscn` 不存在；不得改为跳过场景扫描或断线断言。

- [ ] **Step 3：实现默认旧路径、显式实验开关与大厅传递**

`BattleRuntimeSelector` 只维护两个整局值和两个固定场景：

```gdscript
extends RefCounted
class_name BattleRuntimeSelector

const LEGACY_DEMO := 0
const FRAME_SYNC := 1
const LEGACY_SCENE := "res://scenes/gameplay/DemoArena.tscn"
const FRAME_SYNC_SCENE := "res://scenes/gameplay/FrameSyncDemoArena.tscn"

static func is_valid(runtime: int) -> bool:
	return runtime == LEGACY_DEMO or runtime == FRAME_SYNC

static func scene_path_for(runtime: int) -> String:
	return FRAME_SYNC_SCENE if runtime == FRAME_SYNC else LEGACY_SCENE
```

`GameSessionState` 默认 `_battle_runtime = LEGACY_DEMO`、`_battle_locked = false`。`configure_single()` 与 `prepare_local()` 必须先验证 runtime 且未锁定；`configure_local(players)` 只写玩家描述的深拷贝，沿用 `prepare_local()` 保存的 runtime，不接受第二个可能冲突的 runtime。`lock_for_battle()` 原子保存连续 active slots 的 `source_key` 数组；锁定后 `configure_single()`、`prepare_local()`、`configure_local()` 和 `clear()` 都返回 `false`，getter 返回值的修改也只作用于副本，因此 hot join、退出槽位、替换设备和 runtime 改写均不会改变内部状态。战斗 Scene 真正退出时才调用 `end_battle()` 释放生命周期锁，之后菜单可正常 `clear()` 并恢复旧 runtime 默认。

`_validate_locked_session_rejects_player_and_source_changes()` 构造已锁定的两人会话和最小 world，保存 `get_locked_source_keys()`、`world.get_next_tick()` 与 canonical Hash；随后分别传入一人、三人、相同人数但替换 P2 source key 的数组再次 `configure_local()`，调用 `clear()`，并清空/改写 `session.local_players` getter 返回的副本。所有操作必须被拒绝或只改副本，锁定 source keys、Tick 和 Hash 必须逐项保持不变；不得通过调用 `end_battle()` 让该测试通过。

在 `MainMenu.tscn` 的 `LocalMultiplayerButton` 与 `QuitButton` 之间新增默认 `button_pressed = false` 的 `%FrameSyncToggle: CheckButton`，文案固定为 `实验：本地帧同步玩法`。主菜单按下单人时调用：

```gdscript
var runtime := (
	BattleRuntimeSelector.FRAME_SYNC
	if frame_sync_toggle.button_pressed
	else BattleRuntimeSelector.LEGACY_DEMO
)
if GameSession.configure_single(runtime):
	_start_transition(GameSession.get_battle_scene_path())
```

进入大厅时调用 `GameSession.prepare_local(runtime)` 后仍加载原大厅；大厅 `_start_local_game()` 只调用 `GameSession.configure_local(join_state.players)` 和 `GameSession.get_battle_scene_path()`。这样单人和本地多人共用同一个开关，默认关闭时现有路径完全不变。

- [ ] **Step 4：实现 UI 确认输入和“不生成中性帧”的断线暂停**

`FrameSyncUiInputSource` 继承 `PlayerInputSource`，包装 P1 已绑定 source；按钮只排队一次确认并通过正常采集进入录像，不改变大厅绑定的设备 key：

```gdscript
var _base_source: PlayerInputSource
var _stable_source_key: StringName
var _confirm_pending := false

func _init(base_source: PlayerInputSource, stable_source_key: StringName) -> void:
	_base_source = base_source
	_stable_source_key = stable_source_key

func request_confirm() -> void:
	_confirm_pending = true

func sample() -> PlayerInputState:
	var state = _base_source.sample()
	var pending := _confirm_pending
	_confirm_pending = false
	state.confirm_just_pressed = state.confirm_just_pressed or pending
	return state

func is_online() -> bool:
	return _base_source != null and _base_source.is_online()

func get_source_key() -> StringName:
	return _stable_source_key

func reset_edges() -> void:
	_confirm_pending = false
	_base_source.reset_edges()
```

在 `LocalFrameSyncDriver.advance_physics_callback()` 最前面增加暂停短路，暂停时不得增加 `_physics_callback_count`：

```gdscript
func advance_physics_callback() -> bool:
	if _simulation_paused:
		return false
	_physics_callback_count += 1
	if Engine.physics_ticks_per_second != 60:
		return _fail("physics tick rate must be 60 Hz")
	if (_physics_callback_count & 1) != 0:
		return false
	var tick := _world.get_next_tick()
	var frame := _collector.collect(tick)
	if frame == null:
		return _fail(_collector.get_error_message())
	if not _buffer.submit(frame) or not _buffer.has_complete_frame(tick):
		return _fail(_buffer.get_error_message())
	var accepted := _world.step(tick, _buffer.take(tick))
	if accepted:
		_simulation_step_count += 1
		var diagnostic_hash := PackedByteArray()
		if FixedMath.euclidean_mod(tick + 1, _diagnostic_hash_interval) == 0:
			diagnostic_hash = StateHasher.hash_canonical(_world.encode_canonical_state())
		simulation_advanced.emit(tick, diagnostic_hash)
	return accepted
```

除新增暂停短路外必须保留 Plan 1 的 `set_diagnostic_hash_interval()` 契约：正常本地会话 interval 仍为 30，非诊断 Tick 信号携带空 Hash；逐 Tick资格由 harness 直接计算，不能为了表现抓样把 driver 改回每 Tick Hash。暂停前后 interval 与二分频相位都不变。

`LocalDevicePauseController.refresh()` 每个 physics callback 前按 slot `0..3` 检查启用源；任何源离线就 `driver.set_simulation_paused(true, &"device_disconnected")` 并发出完整离线槽位，全部原 source key 恢复后对这些源调用 `reset_edges()`、隐藏 overlay，再解除暂停。不得搜索或绑定其他已连接 gamepad。

`DeviceReconnectOverlay.tscn` 根为 `CanvasLayer(process_mode = PROCESS_MODE_ALWAYS, layer = 110)`，包含全屏半透明背景和居中 Label；文本格式固定为：

```gdscript
func show_waiting(offline_slots: PackedInt32Array, labels: Array[String]) -> void:
	var lines: Array[String] = ["游戏已暂停 · 等待设备恢复"]
	for index in offline_slots.size():
		lines.append("P%d · %s" % [offline_slots[index] + 1, labels[index]])
	$Overlay/Message.text = "\n".join(lines)
	visible = true
```

- [ ] **Step 5：创建只含静态视觉的新 Arena shell 并运行验证**

`FrameSyncArenaWorld.tscn` 从 `DemoArena.tscn` 复用相同环境、模型与摆放，但节点类型只允许 `Node3D`、`WorldEnvironment`、Light、`MeshInstance3D`、`Label3D` 和 `Marker3D`。精确根结构为：

```text
FrameSyncArenaWorld
├── WorldEnvironment
├── Sun
├── GroundVisual
├── BoundaryVisuals
├── CheckpointVisuals
├── IncidentVisuals
├── HazardZoneVisuals
├── SupplyPointVisuals
├── RoadDetails
├── ZombieSpawnPoints/NorthWest|NorthEast|SouthWest|SouthEast
└── PlayerSpawnPoints/P1|P2|P3|P4
```

复制 `DemoArena` 对应 Mesh/模型 transform；删除所有 `StaticBody3D`、`CollisionShape3D`、`Area3D`、Navigation、旧 Targets、旧 Players、旧 Props 脚本和 Timer。`FrameSyncDemoArena.tscn` 此时创建以下稳定骨架，后续任务填入表现根：

```text
FrameSyncDemoArena (frame_sync_demo_arena.gd)
├── FrameSyncArenaWorld
├── SimulationHost
├── PresentationMount
├── SimulationFollowCamera
├── MobileControls
├── MobileOrientationGuard
├── DeviceReconnectOverlay
├── CombatFxPrewarmer
└── WarmupLayer
```

`FrameSyncDemoArena.initialize_from_game_session()` 必须先确认 `GameSession.get_battle_runtime() == FRAME_SYNC`，再锁定会话；初始化错误写入 `GameSession.last_error` 并返回菜单，禁止降级为在新场景里启动旧节点。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_runtime_switch.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两条命令退出 0；默认 session 指向旧 `DemoArena`，显式新 runtime 指向独立场景，断线期间 Tick/二分频/帧缓冲均不前进，新场景扫描不到任何旧玩法节点。

### Task 2：实现 Tick 抓样、事件去重、玩家表现、HUD 与丢失节点重建

**Files:**

- Create: `scripts/simulation/view/presentation_event_ledger.gd`
- Create: `scripts/simulation/view/player_view_pool.gd`
- Modify: `scripts/simulation/view/player_view.gd`
- Modify: `scenes/simulation/PlayerView.tscn`
- Create: `scripts/simulation/view/frame_sync_hud.gd`
- Create: `scenes/simulation/FrameSyncHud.tscn`
- Create: `scripts/simulation/view/simulation_view_bridge.gd`
- Modify: `scripts/simulation/view/simulation_player_view_registry.gd`
- Modify: `scripts/simulation/driver/frame_sync_demo_arena.gd`
- Create: `tools/validation/validate_simulation_view_bridge.gd`

**Interfaces:**

- Consumes: Plan 3 的 `SimulationWorld.get_player_state() -> SimPlayerState` 与 `PlayerView`/`SimulationPlayerViewRegistry`/`SimulationFollowCamera` 冻结接口；Plan 5/6 的 `SimulationWorld.get_last_presentation_events() -> Array[SimPresentationEvent]` 和事件类型 `WEAPON_FIRED=1`、`MELEE_STARTED=2`、`DAMAGE_APPLIED=3`、`ENTITY_DIED=4`、`EQUIPMENT_CHANGED=5`、`AMMO_CHANGED=6`、`WORLD_IMPACT=7`。
- Produces: `PresentationEventLedger.new(capacity: int = 4096)`、`accept(event_id: int) -> bool`、`contains(event_id: int) -> bool`、`clear() -> void`、`size() -> int`、`get_overwrite_count() -> int`。
- Produces: `PlayerView.bind_sim_entity(entity_id: int, generation: int) -> void`、`get_entity_id() -> int`、`get_generation() -> int`、`apply_equipment_state(weapon_id: int, ammo: int) -> void`、`play_presentation_event(event: SimPresentationEvent) -> void`、`reset_for_pool() -> void`；保留 Plan 3 已冻结的全部方法和签名。
- Produces: `PlayerViewPool.prepare(parent: Node3D, player_scene: PackedScene, registry: SimulationPlayerViewRegistry) -> Error`、`acquire(slot: int, entity_id: int, generation: int) -> PlayerView`、`view_for_slot(slot: int) -> PlayerView`、`release_all() -> void`、`get_created_count() -> int`、`get_active_count() -> int`，容量恒为 4。
- Produces: `FrameSyncHud.capture_world_state(world: SimulationWorld) -> void`、`apply_presentation_event(event: SimPresentationEvent) -> void`、`set_restart_callback(callback: Callable) -> void`、`reset_session() -> void`。
- Produces: `SimulationViewBridge.bind_world(world: SimulationWorld, active_player_mask: int) -> Error`、`bind_player_views(pool: PlayerViewPool, registry: SimulationPlayerViewRegistry) -> Error`、`bind_hud(hud: FrameSyncHud) -> Error`、`capture_simulation_tick(tick: int) -> void`、`render_interpolated(interpolation_alpha: float) -> void`、`rebuild_from_current_state() -> void`、`collect_view_metrics() -> Dictionary`、`get_last_captured_tick() -> int`、`get_duplicate_event_count() -> int`、`get_rebuild_count() -> int`；信号 `presentation_event_dispatched(event: SimPresentationEvent)`。
- Private helpers: `SimulationViewBridge._capture_player_samples(tick: int) -> void`、`_dispatch_presentation_event(event: SimPresentationEvent) -> void`；`PlayerView._weapon_node_for_id(weapon_id: int) -> Node3D`、`_weapon_display_name(weapon_id: int) -> String`、`_set_weapon_visual(active_node: Node3D) -> void`、`_play_attack_animation(weapon_id: int) -> void`。这些 helper 只路由纯表现状态，不读取输入或写回 world。

- [ ] **Step 1：先写同 Tick 重抓、玩家固定 generation、插值和节点丢失的失败验证**

创建 `validate_simulation_view_bridge.gd`。夹具世界启用 slot 0/1，Tick 10 的 previous/current 位置分别为 `(0,0)/(1024,0)` 与 `(0,0)/(0,2048)`，并返回一个 `WEAPON_FIRED` 和一个 `EQUIPMENT_CHANGED` 事件。验证：

```gdscript
bridge.capture_simulation_tick(10)
bridge.capture_simulation_tick(10)
_assert(bridge.get_duplicate_event_count() == 2, "同一 Tick 重抓的两个事件必须被去重")
bridge.render_interpolated(0.5)
_assert(player_pool.view_for_slot(0).get_render_position().is_equal_approx(Vector3(0.5, 0.0, 0.0)), "玩家必须在 previous/current 间插值")
_assert(dispatched_event_ids.count(10 * 4096 + 1) == 1, "重复 WEAPON_FIRED 只能分发一次")

var old_view := player_pool.view_for_slot(0)
old_view.queue_free()
await process_frame
bridge.rebuild_from_current_state()
var rebuilt := player_pool.view_for_slot(0)
_assert(rebuilt != null and rebuilt != old_view, "丢失玩家节点必须按当前状态重建")
_assert(dispatched_event_ids.count(10 * 4096 + 1) == 1, "重建不得重播已消费事件")

bridge.capture_simulation_tick(11)
_assert(rebuilt.get_generation() == 1, "Plan 3/5 玩家 generation 固定为 1，不得由表现测试篡改")
```

验证开始前保存 `StateHasher.hash_canonical(world.encode_canonical_state())`，执行两次不同 alpha 渲染、释放/重建 View 和 HUD 动画后再次取 Hash，必须完全相同。ID 槽复用与 generation 变化不得通过修改玩家 SoA 制造；它们在 Task 3 的 Zombie pool 和 Task 4 的 Barrel/Pickup pool 使用真实 allocator 生命周期验证。

- [ ] **Step 2：运行验证并确认桥、ledger 和玩家池尚不存在**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_view_bridge.gd
```

Expected: 非零退出，错误指向 `presentation_event_ledger.gd`、`player_view_pool.gd` 或 `simulation_view_bridge.gd` 缺失；不得删掉重复事件或重建断言。

- [ ] **Step 3：实现固定容量 event_id 环形 ledger**

ledger 使用预分配 `PackedInt64Array` 加仅供表现查询的 Dictionary；Dictionary 不进入模拟和 Hash。覆盖最旧 ID 时同步从 lookup 删除，容量不增长：

```gdscript
extends RefCounted
class_name PresentationEventLedger

var _ids := PackedInt64Array()
var _lookup: Dictionary = {}
var _cursor := 0
var _size := 0
var _overwrite_count := 0

func _init(capacity: int = 4096) -> void:
	_ids.resize(maxi(capacity, 1))

func accept(event_id: int) -> bool:
	if event_id <= 0 or _lookup.has(event_id):
		return false
	if _size == _ids.size():
		_lookup.erase(_ids[_cursor])
		_overwrite_count += 1
	else:
		_size += 1
	_ids[_cursor] = event_id
	_lookup[event_id] = true
	_cursor = (_cursor + 1) % _ids.size()
	return true
```

`clear()` 只在创建全新的本地会话或销毁旧会话后调用；Plan 6 的 `MATCH_RESTARTED` 属于同一会话内 Tick 连续的原子重开，必须保留 ledger。普通 View 丢失、表现根重建或同 Tick 重抓同样不得清空 ledger。

- [ ] **Step 4：把 Plan 3 的 PlayerView 扩展为固定池可复用的完整视觉节点**

`PlayerView.tscn` 保持根为 `Node3D`，继续使用当前玩家模型、`HealthBar3D`、`PlayerEquipmentLabel`、四种装备模型和本地 `AnimationPlayer`，但不得加入碰撞、武器玩法脚本或输入脚本。`PlayerView` 保存 entity ID/generation、装备显示和纯表现动画：

```gdscript
func bind_sim_entity(entity_id: int, generation: int) -> void:
	_entity_id = entity_id
	_generation = generation

func apply_equipment_state(weapon_id: int, ammo: int) -> void:
	_current_weapon_id = weapon_id
	_current_ammo = ammo
	_set_weapon_visual(_weapon_node_for_id(weapon_id))
	$PlayerEquipmentLabel.set_status(
		get_player_slot(),
		_weapon_display_name(weapon_id),
		"∞" if ammo < 0 else str(ammo)
	)

func play_presentation_event(event: SimPresentationEvent) -> void:
	if event.source_entity_id != _entity_id or event.source_generation != _generation:
		return
	match event.event_type:
		SimPresentationEvent.WEAPON_FIRED:
			_play_attack_animation(event.value)
		SimPresentationEvent.MELEE_STARTED:
			_play_attack_animation(event.value)
		SimPresentationEvent.EQUIPMENT_CHANGED, SimPresentationEvent.AMMO_CHANGED:
			apply_equipment_state(event.value, event.aux)
```

`reset_for_pool()` 停止动画、Tween 和嵌入音频，隐藏根节点，清空 entity ID/generation 和 previous/current 样本。`PlayerViewPool.prepare()` 一次实例化恰好四个 live View 并注册；`acquire()` 若 slot 当前 View 的 ID 或 generation 不同，先 `reset_for_pool()` 再绑定。只有该固定槽节点被外部释放时才允许在同一槽创建一个 replacement；live capacity 仍为 4，replacement 计入 bridge rebuild 诊断而不计为 pool capacity growth。

- [ ] **Step 5：实现桥的抓样、只读事件分发与重建**

桥只在 driver 成功推进后调用，且 `_last_captured_tick` 初始为 `-1`。倒退 Tick 直接忽略；重复 Tick 不再推送状态样本或 HUD 快照，但仍重新遍历 world 暴露的同一批事件并统计 ledger 拒绝数；新 Tick 按 slot 升序把整数状态推给 View：

```gdscript
func capture_simulation_tick(tick: int) -> void:
	if _world == null or tick < _last_captured_tick:
		return
	var is_new_tick := tick > _last_captured_tick
	if is_new_tick:
		_capture_player_samples(tick)
	for event: SimPresentationEvent in _world.get_last_presentation_events():
		if not _event_ledger.accept(event.event_id):
			_duplicate_event_count += 1
			continue
		_dispatch_presentation_event(event)
		presentation_event_dispatched.emit(event)
	if is_new_tick:
		_hud.capture_world_state(_world)
		_last_captured_tick = tick

func _capture_player_samples(tick: int) -> void:
	for slot in range(4):
		if (_active_player_mask & (1 << slot)) == 0:
			continue
		var players = _world.get_player_state()
		var view := _player_pool.acquire(slot, players.entity_id_for_slot(slot), players.generation[slot])
		view.push_simulation_sample(
			tick,
			players.get_position_units(slot),
			players.get_heading(slot),
			players.is_alive(slot),
			players.get_health(slot)
		)
```

本 Task 的 `render_interpolated(alpha)` 先只 clamp alpha 并按 slot 调 `PlayerView.render_interpolated(alpha)`；不得读取 world、消费新事件或调用相机。Task 3 会在不改变单参数签名的前提下加入已绑定 Camera3D 的僵尸表现分级；`FrameSyncDemoArena._process(delta)` 仍分别调用 bridge 和 Plan 3 的 `SimulationFollowCamera.render_camera(delta, viewport_size)`，使 Plan 8 可以独立用 30/60/120/jitter cadence 调桥而不推进模拟。

`rebuild_from_current_state()` 检查四个启用 slot 的 View 是否仍有效；缺失时从固定池重新 acquire，以 current 样本同时填 previous/current，恢复装备/生命/倒地 pose，并增加 `_rebuild_count`。它不得清空 ledger，也不得遍历旧事件。

`collect_view_metrics()` 只为性能诊断递归读取已绑定表现根，返回 `active_player_views/active_zombie_views/pooled_zombie_views/active_fx/pool_growth_count/material_instance_count` 六个整数。`pooled_zombie_views` 固定等于已预建 active 与 corpse View 总数（默认 `160 + 32 = 192`，含正在使用的实例）；`pool_growth_count` 只汇总超过声明容量的实例数，合法同槽 replacement 不计入 growth。材质计数按该 root 下当前 `Material` resource instance ID 去重；该 ID 不写入模拟、InputTape、事件或 Hash。

- [ ] **Step 6：实现只读 HUD 并通过桥验证**

`FrameSyncHud.tscn` 提供 `PlayerRows/P1..P4`、`Objective`、`WaveStatus`、`HitConfirm`、`DamageFlash`、`GameOver`、`RestartButton`。`capture_world_state()` 只读取 Plan 6 的波次/失败摘要和玩家 SoA；`apply_presentation_event()` 只处理已被 ledger 接受的事件：玩家造成伤害时闪 `HIT/KILL`，玩家受伤时闪红，装备/弹药事件更新对应行，失败状态显示 `全员倒地`。RestartButton 只调用 Task 1 注入的 callback，callback 最终调用 `FrameSyncUiInputSource.request_confirm()`，不得直接 reset world。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_view_bridge.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两条命令退出 0；同一 event_id 只表现一次，玩家 slot 绑定与固定 generation=1 正确，节点重建不重播 one-shot，不同插值次数和 alpha 不改变模拟 Hash；真实 generation 复用留给后续实体池验证。

### Task 3：建立 150 只僵尸视图池、表现分级、音频/FX 限流与渲染预热

**Files:**

- Create: `scripts/simulation/view/view_performance_profile.gd`
- Create: `scripts/simulation/view/zombie_view.gd`
- Create: `scenes/simulation/ZombieView.tscn`
- Create: `scripts/simulation/view/zombie_view_pool.gd`
- Create: `scripts/simulation/view/presentation_audio_router.gd`
- Create: `scripts/simulation/view/presentation_fx_router.gd`
- Create: `scripts/simulation/view/frame_sync_presentation_root.gd`
- Create: `scenes/simulation/FrameSyncPresentationRoot.tscn`
- Modify: `scripts/simulation/view/simulation_view_bridge.gd`
- Modify: `scripts/fx/barrel_explosion.gd`
- Modify: `scripts/fx/spatial_sfx_pool.gd`
- Modify: `scripts/fx/ground_blood_manager.gd`
- Modify: `scripts/simulation/driver/frame_sync_demo_arena.gd`
- Modify: `scenes/gameplay/FrameSyncDemoArena.tscn`
- Create: `tools/validation/validate_frame_sync_view_pools.gd`

**Interfaces:**

- Consumes: Plan 4 的 `SimulationWorld.get_zombie_state() -> ZombieState` 与 ID/generation 规则；Plan 5 的七类表现事件及 Plan 6 的 `BARREL_EXPLODED=9`；Task 2 的 `PresentationEventLedger` 与 `SimulationViewBridge`；现有 `CombatFxPrewarmer`、`BloodImpact`、`GroundBloodManager`、`ShotTracer`、`BarrelDamageSmoke`、`BarrelExplosion`、`SpatialSfxPool`。
- Produces: `ViewPerformanceProfile.default_profile() -> ViewPerformanceProfile`、`validate() -> Error`，固定字段 `active_zombie_view_capacity=160`、`corpse_view_capacity=32`、`near_distance_units=10240`、`mid_distance_units=22528`、`far_distance_units=36864`、`near_animation_budget=32`、`mid_animation_budget=64`、`max_audio_events_per_tick=4`、`max_impact_fx_per_tick=6`、`max_explosion_fx_per_tick=4`、`max_ground_blood_requests_per_tick=4`。
- Produces: `ZombieView.bind_sim_entity(entity_id: int, generation: int) -> void`、`get_entity_id() -> int`、`get_generation() -> int`、`push_simulation_sample(tick: int, position_units: Vector2i, heading: int, alive: bool, health: int, state: int) -> void`、`render_interpolated(alpha: float, tier: int, render_frame_index: int) -> void`、`play_presentation_event(event: SimPresentationEvent) -> void`、`start_corpse_from(position: Vector3, heading: int) -> void`、`reset_for_pool() -> void`、`get_render_position() -> Vector3`。
- Produces: `ZombieViewPool.prepare(parent: Node3D, zombie_scene: PackedScene, profile: ViewPerformanceProfile) -> Error`、`capture_state(tick: int, zombies: ZombieState) -> void`、`apply_event(event: SimPresentationEvent) -> void`、`render_interpolated(alpha: float, camera: Camera3D) -> void`、`rebuild_from_state(zombies: ZombieState) -> void`、`view_for_entity(entity_id: int, generation: int) -> ZombieView`、`get_active_count() -> int`、`get_created_active_count() -> int`、`get_created_corpse_count() -> int`、`get_replacement_count() -> int`、`get_pool_growth_count() -> int`、`get_tier_counts() -> PackedInt32Array`。
- Extends: `SpatialSfxPool.get_created_player_count() -> int`；固定 capacity 在 `_ready()` 后不得增加 player。
- Produces: `PresentationAudioRouter.prepare(pool: SpatialSfxPool, profile: ViewPerformanceProfile) -> Error`、`begin_tick(tick: int, camera_position: Vector3) -> void`、`route(event: SimPresentationEvent) -> bool`、`finish_tick() -> void`、`get_played_count() -> int`、`get_played_count_for_tick() -> int`、`get_dropped_count() -> int`。
- Produces: `PresentationFxRouter.prepare(parent: Node3D, ground_blood: GroundBloodManager, profile: ViewPerformanceProfile) -> Error`、`begin_tick(tick: int, camera_position: Vector3) -> void`、`route(event: SimPresentationEvent) -> bool`、`get_active_fx_count() -> int`、`get_impact_count_for_tick() -> int`、`get_explosion_count_for_tick() -> int`、`get_pool_growth_count() -> int`、`get_dropped_count() -> int`。
- Extends: `GroundBloodManager.configure_flat_surface(enabled: bool, surface_y: float = 0.02) -> void`、`get_dropped_request_count() -> int`；新路径不需要物理射线即可把纯表现血迹投到 DemoArena 平面，旧路径默认仍使用原有 surface query。
- Produces: `FrameSyncPresentationRoot.prepare(profile: ViewPerformanceProfile) -> Error`、`bind_bridge(bridge: SimulationViewBridge, render_camera: Camera3D) -> Error`、`get_player_pool() -> PlayerViewPool`、`get_zombie_pool() -> ZombieViewPool`、`get_audio_router() -> PresentationAudioRouter`、`get_fx_router() -> PresentationFxRouter`、`get_hud() -> FrameSyncHud`、`total_pool_growth_count() -> int`、`finish_render_warmup() -> void`。
- Extends: `SimulationViewBridge.bind_presentation_root(root: FrameSyncPresentationRoot) -> Error`、`bind_render_camera(camera: Camera3D) -> Error`、`bind_zombie_views(pool: ZombieViewPool) -> Error`、`bind_routers(audio_router: PresentationAudioRouter, fx_router: PresentationFxRouter) -> Error`；材质与池指标只遍历该 root，不扫描整个 SceneTree，render camera 只供 zombie pool 读取 frustum 与距离。
- Private helpers: `ZombieView._heading_yaw(heading: int) -> float`；`PresentationFxRouter._show_tracer_and_muzzle(event: SimPresentationEvent) -> bool`、`_show_blood_impact(event: SimPresentationEvent) -> bool`、`_show_world_impact(event: SimPresentationEvent) -> bool`、`_show_barrel_explosion(event: SimPresentationEvent) -> bool`。所有 helper 仅使用事件量化坐标和预建池。

- [ ] **Step 1：先写 150 只固定池、稳定分级、限流与无增长的失败验证**

创建 `validate_frame_sync_view_pools.gd`，预热后生成 150 只模拟僵尸和固定事件突发：64 个命中、12 个世界碰撞、8 个爆炸夹具。固定摄像机位置后执行 240 个渲染帧，断言：

```gdscript
_assert(
	presentation_root.bind_bridge(bridge, null) == ERR_INVALID_PARAMETER,
	"完整表现根必须拒绝缺失 render camera"
)
var render_camera := Camera3D.new()
camera_mount.add_child(render_camera)
_assert(
	presentation_root.bind_bridge(bridge, render_camera) == OK,
	"prepared 表现根必须通过单一接口完成 bridge 装配"
)
_assert(pool.get_created_active_count() == 160, "活体僵尸池必须预建 160 个且不懒增长")
_assert(pool.get_created_corpse_count() == 32, "尸体池必须预建 32 个")
_assert(pool.get_active_count() == 150, "150 个模拟活体必须都有绑定 View")
var tiers := pool.get_tier_counts()
_assert(tiers[ZombieView.Tier.NEAR] <= 32, "近距离全动画不得超过 32")
_assert(tiers[ZombieView.Tier.MID] <= 64, "中距离降频动画不得超过 64")
_assert(audio_router.get_played_count_for_tick() <= 4, "单 Tick 空间音频不得超过 4")
_assert(fx_router.get_impact_count_for_tick() <= 6, "单 Tick 命中 FX 不得超过 6")
_assert(fx_router.get_explosion_count_for_tick() <= 4, "单 Tick 爆炸 FX 不得超过 4")
_assert(audio_router.get_dropped_count() > 0, "音频突发必须实际触发限流而不是零事件假通过")
_assert(fx_router.get_dropped_count() > 0, "FX 突发必须实际触发限流而不是零事件假通过")
_assert(pool.get_pool_growth_count() == 0 and fx_router.get_pool_growth_count() == 0, "预热后所有池不得增长")
```

再交换僵尸生成顺序但保持相同 ID/generation/位置集合，断言按 `(distance_squared, entity_id, generation)` 排序得到完全相同的 tier 清单；将一个 View `queue_free()` 后调用 bridge rebuild，active 数恢复 150、事件计数不增加。

generation 复用使用两个有界 `ZombieState` 夹具快照：第二个快照让同一 allocator slot 的旧实体死亡，并以相同 entity ID、`old_generation + 1` 重新存活；不得修改已绑定 world 的玩家或 canonical state。再次 `capture_state()` 后，`view_for_entity(id, old_generation)` 必须为空、`view_for_entity(id, new_generation).get_generation()` 必须等于新值，携带旧 generation 的受击/死亡事件不得触发动画或尸体。

随后保存 world Hash、tier 清单和已分发 event_id 数量，释放已绑定 camera 后调用 `bridge.render_interpolated(0.5)`：模拟 Hash 必须不变，玩家仍可插值，僵尸保持最后一次 tier/Transform 且不得访问失效实例。创建 replacement `Camera3D` 并再次调用 `presentation_root.bind_bridge(bridge, replacement_camera)` 后，下一帧必须恢复僵尸分级；该重绑会从 current state 重建缺失 View，但不得清 ledger、重播 one-shot 或增加池容量。Task 4 加入世界实体后重复验证其在 camera 丢失期间仍可插值。Plan 8 cadence fixture 必须复用同一 `prepare -> bridge.bind_world -> bind_bridge` 顺序，不得逐个调用桥的内部 bind 方法。

- [ ] **Step 2：运行验证并确认僵尸 View、profile 和路由器缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_view_pools.gd
```

Expected: 非零退出，错误指向 `view_performance_profile.gd`、`zombie_view_pool.gd` 或表现路由器不存在。

- [ ] **Step 3：实现无碰撞僵尸 View 和稳定距离分级**

先创建不可变使用约定的默认 profile；`validate()` 拒绝 active pool 小于 150、corpse pool 小于 1、距离非递增、动画预算超过 active pool 或任一每 Tick 预算小于 1：

```gdscript
extends RefCounted
class_name ViewPerformanceProfile

var active_zombie_view_capacity := 160
var corpse_view_capacity := 32
var near_distance_units := 10240
var mid_distance_units := 22528
var far_distance_units := 36864
var near_animation_budget := 32
var mid_animation_budget := 64
var max_audio_events_per_tick := 4
var max_impact_fx_per_tick := 6
var max_explosion_fx_per_tick := 4
var max_ground_blood_requests_per_tick := 4

static func default_profile() -> ViewPerformanceProfile:
	return ViewPerformanceProfile.new()

func validate() -> Error:
	if active_zombie_view_capacity < 150 or corpse_view_capacity < 1:
		return ERR_INVALID_PARAMETER
	if not (near_distance_units < mid_distance_units and mid_distance_units < far_distance_units):
		return ERR_INVALID_PARAMETER
	if near_animation_budget < 1 or mid_animation_budget < 1:
		return ERR_INVALID_PARAMETER
	if near_animation_budget + mid_animation_budget > active_zombie_view_capacity:
		return ERR_INVALID_PARAMETER
	if [max_audio_events_per_tick, max_impact_fx_per_tick, max_explosion_fx_per_tick, max_ground_blood_requests_per_tick].min() < 1:
		return ERR_INVALID_PARAMETER
	return OK
```

`ZombieView.tscn` 根为 `Node3D`，只实例化当前 `Zombie_Basic.gltf` 模型、一个默认隐藏的 `Label3D` 血条文本和表现脚本；不得包含 `CharacterBody3D`、Collision、Navigation、Area、AudioStreamPlayer 或 `ZombieTarget`。View 的 tier 固定为：

```gdscript
enum Tier { NEAR, MID, FAR, HIDDEN }

func render_interpolated(alpha: float, tier: int, render_frame_index: int) -> void:
	if tier == Tier.HIDDEN:
		visible = false
		return
	visible = true
	var update_divisor := 1 if tier == Tier.NEAR else (2 if tier == Tier.MID else 4)
	if render_frame_index % update_divisor == 0:
		global_position = _previous_position.lerp(_current_position, clampf(alpha, 0.0, 1.0))
		rotation.y = _heading_yaw(_current_heading)
	_animation_player.active = tier != Tier.FAR
	$HealthLabel.visible = tier == Tier.NEAR and _current_health > 0 and _current_health < _maximum_health
```

近档每帧更新且动画正常；中档每两帧更新并只在 `Idle/Walk/Attack/HitReact/Death` 状态变化时切动画；远档每四帧更新、冻结当前骨骼 pose、隐藏血条。所有随机音高、动画变体和血迹外观只能由表现 router 自己的非玩法随机源决定，不得读取或推进模拟 RNG。

`ZombieViewPool` 在 `prepare()` 中一次实例化 160 个 active + 32 个 corpse，预热后 live capacity 不再变化。`capture_state()` 按 zombie slot 升序同步 ID/generation；死亡事件先从 corpse 池取得一个空闲 View 播放纯表现 Death，再立即把 active View 归还。尸体池满时按最早启动序号复用最旧尸体，只影响视觉时长，不改变模拟死亡和掉落。若固定槽节点被外部释放，`rebuild_from_state()` 可在同一槽实例化 replacement 并增加 `replacement_count`；`pool_growth_count` 只统计 live capacity 超过 160/32 的错误，replacement 不算扩容。

分级先过滤 camera frustum，再按 camera XZ 距离平方、entity_id、generation 稳定插入排序；前 32 个为 NEAR、接着 64 个为 MID，其余可见 active 为 FAR，frustum 外为 HIDDEN。不得依赖 Dictionary 遍历顺序或实例 ID。

- [ ] **Step 4：实现固定空间音频与 FX 事件路由**

`SpatialSfxPool` 保持固定 capacity，并新增只读 `get_created_player_count()`；`PresentationAudioRouter` 不给每只僵尸挂音频节点，而是把已接受事件映射到现有资源：玩家武器、僵尸攻击/受击/死亡、世界碰撞、拾取、放置、爆炸。`begin_tick()` 清空一个固定四槽候选表；每次 `route()` 以 `(priority, distance_squared, event_id)` 与当前最差候选比较，只保留本地玩家武器、全员失败和最近事件中的最佳四个，不立即播放；`finish_tick()` 才按该稳定顺序调用 pool。未入选四槽及被替换的候选计入 dropped 且永不补播，因此不会为了排序建立无界 Array。

`PresentationFxRouter.prepare()` 固定创建 32 个 `ShotTracer`、复用 `GroundBloodManager` 的 24 个 `BloodImpact`、固定创建 8 个 `BarrelExplosion`。事件路由的核心限制固定如下：

```gdscript
func route(event: SimPresentationEvent) -> bool:
	match event.event_type:
		SimPresentationEvent.WEAPON_FIRED:
			return _show_tracer_and_muzzle(event)
		SimPresentationEvent.DAMAGE_APPLIED, SimPresentationEvent.WORLD_IMPACT:
			if _impact_count >= _profile.max_impact_fx_per_tick:
				_dropped_count += 1
				return false
			_impact_count += 1
			return (
				_show_blood_impact(event)
				if event.event_type == SimPresentationEvent.DAMAGE_APPLIED
				else _show_world_impact(event)
			)
		SimPresentationEvent.BARREL_EXPLODED:
			if _explosion_count >= _profile.max_explosion_fx_per_tick:
				_dropped_count += 1
				return false
			_explosion_count += 1
			return _show_barrel_explosion(event)
		_:
			return false
```

Task 4 再把放置、拾取、波次和比赛状态事件接到同一组 router/HUD/world pool；爆炸 FX 和音频限流必须已在本 Task 通过突发验证。量化坐标统一用 `Vector3(float(x) / 1024.0, presentation_height, float(z) / 1024.0)`；视觉高度仅来自固定 View 配置，不进入模拟。

修改 `BarrelExplosion` 增加 `set_pooled(value: bool)`、`is_active()`、`deactivate()`；池化实例寿命结束调用 `deactivate()`，非池化旧路径仍 `queue_free()`。`warmup_for_render()` 继续以 `play_audio=false` 激活粒子，`finish_render_warmup()` 必须安全停用。

`GroundBloodManager` 增加固定 pending request 上限 256；满时丢弃新请求并计数，不得让 Array 无界增长。新路径调用 `configure_flat_surface(true, 0.02)`，其 `_find_blood_surface()` 使用以下纯表现平面，旧 `DemoArena` 默认 `false` 时保留原 Physics surface query：

```gdscript
if _flat_surface_enabled:
	return {
		"position": Vector3(world_position.x, _flat_surface_y, world_position.z),
		"normal": Vector3.UP,
	}
```

- [ ] **Step 5：组合表现根、接入桥并验证 warmup 清理**

`FrameSyncPresentationRoot.tscn` 精确包含：

```text
FrameSyncPresentationRoot
├── PlayerViews
├── ZombieViews
├── CorpseViews
├── WorldEntityViews
├── FxRoot
├── GroundBloodManager
├── SpatialSfxPool (capacity=32)
└── FrameSyncHud
```

`prepare(profile)` 依次准备玩家池、僵尸池、FX 池和音频池；Arena 在 warmup overlay 下先实例化表现根，把各一个玩家/僵尸代表 View 放到相机前且只显示一帧，调用 `RenderingServer.force_draw(false, 0.0)` 与 `force_sync()` 后立即 `reset_for_pool()`，再调用现有 `CombatFxPrewarmer.prewarm(camera)`。代表 View 预热不得播放动画事件或音频。最后调用 `finish_render_warmup()`，确认所有池实例 inactive、音频全部 stopped、事件计数为 0，才开始 Tick。Task 4 加入世界实体池后，以同一规则额外预热各一个油桶和拾取代表 View。

`bind_bridge()` 是 Arena 与 Plan 8 cadence 唯一允许使用的完整表现装配入口；各组件 bind 方法保留为 root 内部接缝。固定顺序为指标 root、render camera、玩家 pool/registry、HUD、僵尸 pool、routers，Task 4 创建世界实体池后再把它作为最后一步：

```gdscript
func bind_bridge(bridge: SimulationViewBridge, render_camera: Camera3D) -> Error:
	if not _prepared or bridge == null:
		return ERR_UNCONFIGURED
	if render_camera == null or not is_instance_valid(render_camera):
		return ERR_INVALID_PARAMETER
	var result := bridge.bind_presentation_root(self)
	if result != OK:
		return result
	result = bridge.bind_render_camera(render_camera)
	if result != OK:
		return result
	result = bridge.bind_player_views(_player_pool, _player_registry)
	if result != OK:
		return result
	result = bridge.bind_hud(_hud)
	if result != OK:
		return result
	result = bridge.bind_zombie_views(_zombie_pool)
	if result != OK:
		return result
	result = bridge.bind_routers(_audio_router, _fx_router)
	if result != OK:
		return result
	bridge.rebuild_from_current_state()
	return OK
```

`SimulationViewBridge.bind_render_camera()` 只保存弱生命周期语义的表现引用，不设置 `current`、不移动 camera、不连接输入，也不写 world。最终 `render_interpolated(alpha)` 先插值玩家与世界实体；只有 `_render_camera` 仍有效时才调用 `zombie_pool.render_interpolated(alpha, _render_camera)`。camera 意外释放时僵尸保持最后一次 Transform/tier，模拟、玩家、HUD 和事件消费继续；重新通过 root 完整绑定 replacement camera 后按 current state 重建，ledger 保持不变。

Task 3 的 bridge render 核心固定为：

```gdscript
func render_interpolated(interpolation_alpha: float) -> void:
	var alpha := clampf(interpolation_alpha, 0.0, 1.0)
	for slot in range(4):
		var player_view := _player_pool.view_for_slot(slot)
		if player_view != null:
			player_view.render_interpolated(alpha)
	if _zombie_pool != null and is_instance_valid(_render_camera):
		_zombie_pool.render_interpolated(alpha, _render_camera)
```

Task 4 只在玩家之后、僵尸之前或之后增加与 camera 无关的 `world_entity_pool.render_interpolated(alpha)`；Plan 8 不得给该方法增加第二个参数。

油桶受损烟雾直接实例化现有 `res://scenes/fx/BarrelDamageSmoke.tscn`，不得在 `SimWorldEntityView.tscn` 内重新定义粒子资源；其现有 `warmup_for_render(context)` / `finish_render_warmup()` 契约继续由 `CombatFxPrewarmer` 发现和清理。

Bridge 在正常 Tick 中先 `zombie_pool.capture_state(tick, world.get_zombie_state())`，再为 router `begin_tick()`，最后按稳定 event_id 顺序把一次事件同时发给相关 Player/Zombie View、HUD、audio 和 FX；事件循环结束后调用一次 `audio_router.finish_tick()`。`render_interpolated(alpha)` 只把已绑定 camera 作为 zombie pool 的只读分级参数，绝不调用相机方法或模拟。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_view_pools.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
if rg -n "CharacterBody3D|NavigationAgent3D|NavigationServer3D|direct_space_state|move_and_slide" scripts/simulation/view scenes/simulation; then exit 1; fi
```

Expected: 前两条命令退出 0；搜索不得在 `ZombieView`、View pool、bridge、audio/FX router 中命中玩法物理或导航 API；150 active + 32 corpse 的池、事件预算和 warmup 清理全部通过，预热后增长计数为 0。

### Task 4：接入世界实体与完整玩法循环，建立可玩门槛和 100+ 渲染报告

**Files:**

- Create: `scripts/simulation/view/sim_world_entity_view.gd`
- Create: `scenes/simulation/SimWorldEntityView.tscn`
- Create: `scripts/simulation/view/world_entity_view_pool.gd`
- Modify: `scripts/simulation/view/simulation_view_bridge.gd`
- Modify: `scripts/simulation/view/frame_sync_hud.gd`
- Modify: `scripts/simulation/view/presentation_audio_router.gd`
- Modify: `scripts/simulation/view/presentation_fx_router.gd`
- Modify: `scripts/simulation/view/frame_sync_presentation_root.gd`
- Modify: `scenes/simulation/FrameSyncPresentationRoot.tscn`
- Modify: `scripts/simulation/driver/frame_sync_demo_arena.gd`
- Modify: `scenes/gameplay/FrameSyncDemoArena.tscn`
- Create: `scripts/simulation/testing/view_performance_benchmark.gd`
- Create: `tools/validation/validate_frame_sync_playable_path.gd`

**Interfaces:**

- Consumes: Plan 6 的 `SimulationWorld.get_barrel_state() -> BarrelState`、`get_pickup_state() -> PickupState`、`get_player_inventory_state() -> PlayerInventoryState`、`get_match_loop_state() -> MatchLoopState`、`get_match_state() -> int`、`get_match_generation() -> int`，以及 `BARREL_DAMAGED=8`、`BARREL_EXPLODED=9`、`PLACEMENT_ACCEPTED=10`、`PLACEMENT_REJECTED=11`、`PICKUP_SPAWNED=12`、`PICKUP_COLLECTED=13`、`WAVE_STARTED=14`、`MATCH_DEFEATED=15`、`MATCH_RESTARTED=16`、`CAPACITY_REJECTED=17`。
- Produces: `SimWorldEntityView.bind_sim_entity(kind: int, entity_id: int, generation: int) -> void`、`get_entity_id() -> int`、`get_generation() -> int`、`push_simulation_sample(tick: int, position_units: Vector2i, heading: int, visual_state: int, value: int) -> void`、`render_interpolated(alpha: float) -> void`、`play_presentation_event(event: SimPresentationEvent) -> void`、`reset_for_pool() -> void`。
- Produces: `WorldEntityViewPool.prepare(parent: Node3D, scene: PackedScene, barrel_capacity: int = 128, pickup_capacity: int = 128) -> Error`、`capture_state(tick: int, barrels: BarrelState, pickups: PickupState) -> void`、`apply_event(event: SimPresentationEvent) -> void`、`render_interpolated(alpha: float) -> void`、`rebuild_from_state(barrels: BarrelState, pickups: PickupState) -> void`、`view_for_entity(kind: int, entity_id: int, generation: int) -> SimWorldEntityView`、`get_active_barrel_count() -> int`、`get_active_pickup_count() -> int`、`get_pool_growth_count() -> int`。
- Extends: `SimulationViewBridge.bind_world_entity_views(pool: WorldEntityViewPool) -> Error`；`rebuild_from_current_state()` 同时重建玩家、僵尸、油桶和拾取 View。
- Extends: `FrameSyncPresentationRoot.get_world_entity_pool() -> WorldEntityViewPool`，并让 `total_pool_growth_count()` 汇总玩家、僵尸、尸体、世界实体、FX 和音频固定池；Task 4 完成后 `bind_bridge()` 必须把非空 world entity pool 作为固定顺序最后一步，缺失时返回 `ERR_UNCONFIGURED`，从而给 Plan 8 提供完整且不可拆分的表现根接缝。
- Produces: `ViewPerformanceBenchmark.begin(world: SimulationWorld, bridge: SimulationViewBridge, zombie_count: int, sample_frames: int) -> void`、`record_render_frame(delta_seconds: float) -> bool`、`finish() -> Dictionary`；信号 `completed(report: Dictionary)`。
- Arena private helpers: `_load_and_validate_runtime_configs() -> Error`、`_build_local_simulation_session() -> Error`、`_create_complete_demo_world() -> SimulationWorld`、`_create_and_prepare_presentation_root() -> FrameSyncPresentationRoot`、`_bind_all_view_pools_and_routers() -> Error`、`_session_matches_locked_mapping() -> bool`、`_on_simulation_advanced(tick: int, diagnostic_hash: PackedByteArray) -> void`。每个 helper 失败都设置 `GameSession.last_error` 并让初始化返回非 `OK`，不得创建旧玩法节点兜底。
- Validation helper: `_record_world_events(world: SimulationWorld, observed: Dictionary) -> void` 只读取 `get_last_presentation_events()`，按事件类型把八个固定 key 设为 `true`。
- Performance report 固定包含：`zombie_count:int`、`frame_count:int`、`frame_time_p95_ms:float`、`frame_time_p99_ms:float`、`active_player_views:int`、`active_zombie_views:int`、`pooled_zombie_views:int`、`active_fx:int`、`pool_growth_count:int`、`material_instance_count_after_warmup:int`、`material_instance_count_at_end:int`、`material_growth_count:int`。

- [ ] **Step 1：先写完整循环只读表现、重开重建和性能报告结构的失败验证**

创建 `validate_frame_sync_playable_path.gd`，使用 Plan 6 冻结的 `WorldGameLoopFixture.create_world(session_seed: int, active_player_mask: int)` 与 `build_qualification_tape(active_player_mask: int, ticks: int)`，不直接调用伤害、生成、拾取或 restart API。逐 Tick 交给 world 后调用 bridge 抓样，并记录是否观察到完整生命周期的八类关键世界事件；`PLACEMENT_REJECTED` 与 `CAPACITY_REJECTED` 由 Plan 6 聚焦验证和本 Task 的 HUD/不扩池断言覆盖：

```gdscript
var tape := WorldGameLoopFixture.build_qualification_tape(0b0001, 10_000)
var session := tape.get_session()
var world := WorldGameLoopFixture.create_world(
	session.get_session_seed(),
	session.get_active_player_mask()
)
var observed := {
	"barrel_damaged": false,
	"barrel_exploded": false,
	"placement": false,
	"pickup_spawned": false,
	"pickup_collected": false,
	"wave_started": false,
	"defeated": false,
	"restarted": false,
}
for tick in 10_000:
	var frame := tape.get_frame(tick)
	_assert(world.step(tick, frame), "qualification frame must advance")
	bridge.capture_simulation_tick(tick)
	bridge.render_interpolated(0.0)
	bridge.render_interpolated(0.5)
	bridge.render_interpolated(1.0)
	_record_world_events(world, observed)
_assert(observed.values().all(func(value): return value), "new path must present the complete Plan 6 lifecycle")
_assert(world_pool.get_pool_growth_count() == 0, "world entity pools must not grow after warmup")
```

`_record_world_events()` 固定实现为：

```gdscript
func _record_world_events(world: SimulationWorld, observed: Dictionary) -> void:
	for event: SimPresentationEvent in world.get_last_presentation_events():
		match event.event_type:
			SimPresentationEvent.BARREL_DAMAGED: observed["barrel_damaged"] = true
			SimPresentationEvent.BARREL_EXPLODED: observed["barrel_exploded"] = true
			SimPresentationEvent.PLACEMENT_ACCEPTED: observed["placement"] = true
			SimPresentationEvent.PICKUP_SPAWNED: observed["pickup_spawned"] = true
			SimPresentationEvent.PICKUP_COLLECTED: observed["pickup_collected"] = true
			SimPresentationEvent.WAVE_STARTED: observed["wave_started"] = true
			SimPresentationEvent.MATCH_DEFEATED: observed["defeated"] = true
			SimPresentationEvent.MATCH_RESTARTED: observed["restarted"] = true
```

在 `MATCH_RESTARTED` 前保存旧 match generation、一个旧油桶 ID/generation 和表现计数；重开后断言 `match_generation + 1`、Tick 连续、`view_for_entity(kind, old_id, old_generation) == null`、新 generation 状态已重建，携带旧 generation 的 explosion/pickup 事件不重播。另用 Plan 6 正常死亡/收集/重生生命周期分别覆盖 Barrel 与 Pickup 的同 ID generation 递增，不得直接改 SoA。验证还必须先让未创建 world entity pool 的最终 root 绑定失败，再完成 `prepare()` 后通过 `root.bind_bridge(bridge, camera)` 一次绑定全部组件；释放并替换 camera 后再次调用同一入口，世界实体绑定和指标边界不得丢失。性能报告结构验证固定：

```gdscript
benchmark.begin(world, bridge, 24, 240)
for _frame in 240:
	benchmark.record_render_frame(1.0 / 60.0)
var report := benchmark.finish()
for key in [
	"zombie_count", "frame_count", "frame_time_p95_ms", "frame_time_p99_ms",
	"active_player_views", "active_zombie_views", "pooled_zombie_views", "active_fx",
	"pool_growth_count", "material_instance_count_after_warmup",
	"material_instance_count_at_end", "material_growth_count",
]:
	_assert(report.has(key), "performance report missing %s" % key)
_assert(report.pool_growth_count == 0, "pool growth after warmup must fail")
_assert(report.material_growth_count == 0, "material growth after warmup must fail")
```

- [ ] **Step 2：运行验证并确认世界实体池和 benchmark 尚不存在**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_playable_path.gd
```

Expected: 非零退出，错误指向 `world_entity_view_pool.gd` 或 `view_performance_benchmark.gd` 缺失；不得用旧 `ExplosiveBarrel`/`PickupChest` 场景通过测试。

- [ ] **Step 3：实现固定油桶/拾取 View 池和 Plan 6 事件表现**

`SimWorldEntityView.tscn` 根为 `Node3D`，内含两个纯视觉子根：复用 `Barrel.gltf` 与 `Chest.gltf`，并实例化默认停用的现有 `res://scenes/fx/BarrelDamageSmoke.tscn`，另带拾取 ring/beacon 和 Label3D；不得内嵌新的粒子资源，也不得包含 StaticBody、Collision、Area 或旧玩法脚本。kind 固定为：

```gdscript
enum Kind { BARREL = 1, PICKUP = 2 }

func bind_sim_entity(kind: int, entity_id: int, generation: int) -> void:
	_kind = kind
	_entity_id = entity_id
	_generation = generation
	$BarrelVisual.visible = kind == Kind.BARREL
	$PickupVisual.visible = kind == Kind.PICKUP
```

`WorldEntityViewPool.prepare()` 一次创建 128 个 barrel View 和 128 个 pickup View；`capture_state()` 分别按 slot 升序读取 `alive/generation/pos_x/pos_z`，油桶还读取 `heading/state/firearm_hit_count`，拾取读取 `kind/amount/respawn_tick`。相同 ID 不同 generation 必须 reset/rebind；死亡或收集只以 SoA `alive == 0` 释放，不以动画结束决定玩法存在。

本 Task 将 `FrameSyncPresentationRoot.bind_bridge()` 在 Task 3 的可选尾部收紧为完整路径硬要求：`_world_entity_pool == null` 立即返回 `ERR_UNCONFIGURED`，否则在 routers 之后调用 `bridge.bind_world_entity_views(_world_entity_pool)`，成功后才执行 `bridge.rebuild_from_current_state()`。Arena 与 Plan 8 均不得通过跳过此尾部获得部分绑定的 `OK`。

Task 4 的最终函数必须完整冻结为：

```gdscript
func bind_bridge(bridge: SimulationViewBridge, render_camera: Camera3D) -> Error:
	if not _prepared or _world_entity_pool == null or bridge == null:
		return ERR_UNCONFIGURED
	if render_camera == null or not is_instance_valid(render_camera):
		return ERR_INVALID_PARAMETER
	var result := bridge.bind_presentation_root(self)
	if result != OK:
		return result
	result = bridge.bind_render_camera(render_camera)
	if result != OK:
		return result
	result = bridge.bind_player_views(_player_pool, _player_registry)
	if result != OK:
		return result
	result = bridge.bind_hud(_hud)
	if result != OK:
		return result
	result = bridge.bind_zombie_views(_zombie_pool)
	if result != OK:
		return result
	result = bridge.bind_routers(_audio_router, _fx_router)
	if result != OK:
		return result
	result = bridge.bind_world_entity_views(_world_entity_pool)
	if result != OK:
		return result
	bridge.rebuild_from_current_state()
	return OK
```

bridge 对事件 8～17 的分发固定为：

- `BARREL_DAMAGED`：匹配 ID/generation 的 View 开启 damage smoke。
- `BARREL_EXPLODED`：FX router 使用固定爆炸池，audio router 播放一次爆炸，world pool 释放对应 active View。
- `PLACEMENT_ACCEPTED`：world pool 在状态抓样后显示新油桶，audio router 播放放置声。
- `PLACEMENT_REJECTED`：HUD 显示事件 `aux` 对应的拒绝原因 0.8 秒，不生成 View/FX。
- `PICKUP_SPAWNED`：显示 pickup View；`PICKUP_COLLECTED`：播放拾取声并释放对应 generation。
- `WAVE_STARTED`：HUD 更新 wave number 和 alive count。
- `MATCH_DEFEATED`：HUD 显示全员倒地，播放一次 game-over audio，并启用 slot 0 confirm 重开提示。
- `MATCH_RESTARTED`：保持 ledger，不清 Tick；清理所有纯表现 transient，随后从新 match state 调 `rebuild_from_current_state()`。
- `CAPACITY_REJECTED`：只显示诊断文本，不动态扩池。

- [ ] **Step 4：完成 Arena 的单人/2～4 人初始化和完整驱动**

`FrameSyncDemoArena.initialize_from_game_session()` 按以下顺序执行，任何一步失败都停止并返回菜单错误，不启动旧玩法：

```gdscript
func initialize_from_game_session() -> Error:
	var config_result := _load_and_validate_runtime_configs()
	if config_result != OK:
		return config_result
	var session_result := _build_local_simulation_session()
	if session_result != OK:
		return session_result
	_world = _create_complete_demo_world()
	if _world == null:
		return ERR_CANT_CREATE
	_presentation_root = _create_and_prepare_presentation_root()
	if _presentation_root == null:
		return ERR_CANT_CREATE
	_bridge = SimulationViewBridge.new()
	var world_bind_result := _bridge.bind_world(_world, _session.get_active_player_mask())
	if world_bind_result != OK:
		return world_bind_result
	var view_bind_result := _bind_all_view_pools_and_routers()
	if view_bind_result != OK:
		return view_bind_result
	_driver = LocalFrameSyncDriver.new(_world, _collector, _buffer)
	_driver.simulation_advanced.connect(_on_simulation_advanced)
	var pause_bind_result := _pause_controller.bind(
		_driver,
		_sources,
		_session.get_active_player_mask(),
		_source_labels
	)
	if pause_bind_result != OK:
		return pause_bind_result
	GameSession.lock_for_battle()
	if not _session_matches_locked_mapping():
		GameSession.end_battle()
		return ERR_INVALID_DATA
	return OK
```

`_load_and_validate_runtime_configs()` 只加载五份已提交整数资源：

```gdscript
const MAP_PATH := "res://resources/simulation/maps/demo_arena_map.tres"
const PLAYER_PATH := "res://resources/simulation/players/demo_arena_player_sim_config.tres"
const ZOMBIE_PATH := "res://resources/simulation/zombies/zombie_normal_sim.tres"
const COMBAT_PATH := "res://resources/simulation/combat/combat_config.tres"
const WORLD_PATH := "res://resources/simulation/demo_arena_world_gameplay.tres"
```

loader 必须验证五段 canonical/content hash，使用 `SimulationConfigBundle.build(map_hash, StateHasher.hash_canonical(player_config.encode_canonical()), zombie_hash, combat_hash, world_hash)` 得到最终 config hash，并要求普通 world config 的 `maximum_active_zombies == 24`。`_build_local_simulation_session()` 只能用该最终 hash和 GameSession 深拷贝快照创建 manifest/session，并逐项验证 manifest 的 schema/rules version、DemoArena map ID 与 32-byte config hash；全部组件初始化成功后立刻 `lock_for_battle()`，再由 `_session_matches_locked_mapping()` 比较 active mask 和每个启用 slot 的 source key。若快照与锁定映射不同，必须在第一个 Tick 前释放锁并使初始化失败。`_create_complete_demo_world()` 必须复用已验证对象并严格执行以下顺序，任一步失败返回 `null`：

```gdscript
func _create_complete_demo_world() -> SimulationWorld:
	if _session.get_manifest().config_hash != _config_bundle.get_config_hash():
		return null
	var world := SimulationWorld.new(_session)
	if not world.configure_config_bundle(_config_bundle):
		return null
	if not world.configure_map(_map_asset):
		return null
	if not world.configure_players(_player_config):
		return null
	if not world.configure_zombie_horde(_zombie_config):
		return null
	if not world.configure_combat(_combat_config):
		return null
	if not world.configure_world_gameplay(_world_config):
		return null
	return world
```

不得改用 `SimulationWorld.new(session)` 后漏配组件、运行时读取旧 `.tscn/.tres` 编辑源，或为了 150 只压力档修改普通配置。Plan 7 的 150 View 验证使用 Task 3 的固定 `ZombieState` 夹具；完整 100/150 压力 world 由 Plan 8 performance fixture 使用专用 benchmark/qualification config 创建。

`_bind_all_view_pools_and_routers()` 不得再逐项调用 bridge；它只取得 Plan 3 相机节点并委托表现根的单一接口：

```gdscript
func _bind_all_view_pools_and_routers() -> Error:
	var render_camera := $SimulationFollowCamera.get_camera()
	return _presentation_root.bind_bridge(_bridge, render_camera)
```

单人继续把键盘 WASD、方向键、全部已连接手柄、触控和 P1 UI confirm 合并到 slot 0；本地多人严格使用大厅中每槽独占 source，只有 P1 额外接收 restart confirm。`_physics_process(_delta)` 先 `pause_controller.refresh()`，未暂停才调用 driver；`_on_simulation_advanced(tick, _diagnostic_hash)` 只调用 `bridge.capture_simulation_tick(tick)`，不要求 Hash 非空。`_process(delta)` 只渲染 bridge、相机和 benchmark；bridge 使用绑定 camera 的上一可用表现 Transform 做距离/frustum 分级，这个最多一渲染帧的滞后不进入模拟。设备 overlay、竖屏 guard、warmup overlay 都保持可工作。

战斗期间任何 UI、设备回调或大厅对象都不得调用 `GameSession.end_battle()`；只有 `FrameSyncDemoArena._exit_tree()` 确认自身正在离开战斗 Scene 时释放锁。这样局中 `clear()` 仍严格失败，而真正返回菜单后可以创建下一局。

重开只能由 Plan 6 在失败状态消费 slot 0 `CONFIRM`；Arena 不 reload scene，不直接调用 world reset。这样 InputTape 能记录同一局从开局到重开，match generation 变化但模拟 Tick 连续。

- [ ] **Step 5：实现可由 Plan 8 复用的渲染采样与无增长检查**

`ViewPerformanceBenchmark.begin()` 要求表现根已完成预热，且已按 `bridge.bind_world -> presentation_root.bind_bridge(bridge, render_camera)` 成功完整装配；未绑定 camera 或 world entity pool 时不得开始采样。begin 立即记录 unique material resource instance IDs 数量；该 instance ID 只用于非确定性性能诊断，不进入 world/Hash。每个真实 `_process(delta)` 调 `record_render_frame(delta)`，恰好保存 `sample_frames` 个毫秒样本到预分配 Array；仅在加入最后一个样本时返回 `true` 并发出一次 `completed(finish())`，之后调用保持 `false` 且不再增长样本。`finish()` 只能在采满后调用，并使用向上取整 rank：

```gdscript
func _percentile(sorted_samples: Array[float], numerator: int) -> float:
	var rank := ceili(float(sorted_samples.size() * numerator) / 100.0)
	return sorted_samples[maxi(rank - 1, 0)]

func finish() -> Dictionary:
	var sorted := _samples.duplicate()
	sorted.sort()
	var metrics := _bridge.collect_view_metrics()
	var material_end: int = metrics["material_instance_count"]
	return {
		"zombie_count": _zombie_count,
		"frame_count": _samples.size(),
		"frame_time_p95_ms": _percentile(sorted, 95),
		"frame_time_p99_ms": _percentile(sorted, 99),
		"active_player_views": metrics["active_player_views"],
		"active_zombie_views": metrics["active_zombie_views"],
		"pooled_zombie_views": metrics["pooled_zombie_views"],
		"active_fx": metrics["active_fx"],
		"pool_growth_count": metrics["pool_growth_count"],
		"material_instance_count_after_warmup": _material_count_after_warmup,
		"material_instance_count_at_end": material_end,
		"material_growth_count": material_end - _material_count_after_warmup,
	}
```

Plan 7 自动验证用 Task 3 的固定 150 View 快照与合成 delta 检查报告结构、camera 接缝和无增长，绝不把普通 24 上限 world 改成压力配置。真实性能结论由 Plan 8 performance fixture 在最低目标 Web 或移动导出物中采样至少 3,000 帧，使用专用 100/150 benchmark/qualification config 同时制造玩家聚集、连续射击、爆炸链、动态障碍和大量死亡；`pool_growth_count != 0` 或 `material_growth_count != 0` 直接判失败。

- [ ] **Step 6：运行完整自动门槛与旧路径隔离检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_runtime_switch.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_view_bridge.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_view_pools.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_playable_path.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://scripts/simulation/testing/determinism_test_runner.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
git diff --check
git diff --exit-code -- scenes/gameplay/DemoArena.tscn scripts/gameplay/demo_arena.gd scenes/player/Player.tscn scripts/player/player_controller.gd scenes/targets/ZombieTarget.tscn scripts/combat/zombie_target.gd
if rg -n "PlayerController|ZombieTarget|ExplosiveBarrel|PickupChest|PlaceItemService|CharacterBody3D|NavigationAgent3D|NavigationServer3D|direct_space_state|move_and_slide" scripts/simulation/view scripts/simulation/driver/frame_sync_demo_arena.gd scenes/gameplay/FrameSyncDemoArena.tscn scenes/simulation; then exit 1; fi
```

Expected: 六条 Godot 命令与 `git diff --check` 均退出 0；旧战斗/玩家/僵尸文件 diff 无输出；最终搜索只允许在验证中的禁止清单字符串命中，运行时 View/bridge/Arena 不得引用旧玩法类型或物理/导航判定。新入口若任何完整循环事件缺失、View/材质增长、重复 event_id 表现或 Hash 改变，本计划不得交给 Plan 8。

- [ ] **Step 7：执行精确人工验收并冻结最低目标设备报告交接**

不使用 CUA，按以下步骤人工操作：

1. 主菜单保持“实验：本地帧同步玩法”关闭，单人进入后确认仍是旧 `DemoArena`；返回菜单。
2. 打开实验开关，单人进入新场景；用键盘、手柄和触控分别完成移动、装备切换、手枪/SMG/匕首攻击、拾取、油桶放置、爆炸、下一波、全员失败和确认重开。
3. 返回菜单，保持实验开关打开进入本地多人大厅，加入 2 人和 4 人；确认共享屏幕、队伍范围、玩家倒地排除和各自装备 HUD 正常。
4. 本地多人战斗中拔掉 P2 手柄；截图必须显示 `P2` 与原设备，观察角色/僵尸/冷却/波次完全静止；插回同一手柄后从下一 Tick 继续。插入另一只手柄不得解除等待。
5. 在 Plan 7 内运行固定 150 View 诊断夹具，确认 camera 分级、池容量和材质无增长；Plan 8 performance fixture 完成后再用其专用 150 world 持续连续射击、爆炸链和大量死亡至少 3,000 渲染帧，保存报告 JSON 和包含 `150 alive / pool growth 0 / material growth 0` 的截图。不得在普通 `FrameSyncDemoArena` 把波次上限从 24 改到 150。
6. 将窗口切换 16:9、4:3 和超宽比例；截图对比玩家模拟世界位置不变，相机只改变留白/size，队伍范围仍按世界坐标生效。

Plan 8 生成的最低目标设备报告必须写明设备型号、系统、导出平台、Godot 版本、渲染后端、僵尸数、采样帧数、P95/P99、池增长、材质增长和通过/失败；Plan 7 冻结并验证其 benchmark 字段与 root/camera 接缝。Plan 7 的完成门槛是普通 24 上限新路径可选且完整可玩、150 View 夹具无增长、旧路径仍默认；不得在本计划把实验开关默认打开。

## 自检结论

- SPEC 覆盖：Task 1 覆盖整局开关、旧默认、runtime/slot/source key 整体锁定、新旧不混用和设备断线暂停；Task 2 覆盖桥、玩家/HUD、事件去重和节点重建；Task 3 覆盖 Zombie generation 复用、僵尸池、Camera3D 分级接缝、音频/FX 限流和 warmup；Task 4 覆盖 Barrel/Pickup generation、完整玩法循环、普通 24 上限与 Plan 8 的 100～150 渲染报告接缝。
- 非目标隔离：计划没有网络、服务器、WS/ENet、回滚、状态纠正、运行时 NavMesh 或旧节点玩法降级；默认切换和跨平台最终资格明确留给 Plan 8。
- 接口一致性：玩家 View/相机沿用 Plan 3 签名且玩家 generation 固定为 1；完整表现装配统一使用 `FrameSyncPresentationRoot.bind_bridge(bridge, render_camera)`，Plan 8 继续调用单参数 bridge render；事件统一使用 Plan 5/6 的 `SimPresentationEvent`、ID + generation 与 `get_last_presentation_events()`；世界实体、配置 bundle 和 match 状态统一使用 Plan 6 冻结接口。
- 提交约束：四个顶层 Task 均以失败验证开始并以独立验收结束，计划中没有 task 级 commit，最终提交由用户执行。

## 执行交接

计划完成后，执行前有两个选择：

1. **Subagent-Driven（推荐）**：在当前会话使用 `subagent-driven-development`，每个 Task 由新 subagent 实现并进行两阶段审查；按项目约定不做 task 级提交。
2. **Inline Execution**：在单独会话使用 `executing-plans`，按 Task 批量执行并在检查点复核；按项目约定不做 task 级提交。

执行前必须询问用户是否需要隔离 worktree；本计划修改跨菜单、会话、场景和表现系统，建议使用隔离 worktree，但默认仍按用户约定在当前工作区执行。
