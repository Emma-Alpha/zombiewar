# 本地确定性帧同步最终资格验证 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用固定单人、2 人、4 人各 100,000 Tick 的资格录像完成长期、跨平台、不同渲染节奏与最低目标设备性能门禁；只有全部门禁通过后才把帧同步整局路径设为默认，同时保留旧 DemoArena 一个稳定发布周期作为显式回退。

**Architecture:** Plan 8 不新增玩法系统，而是在 Plan 1～7 已冻结的 `SimulationWorld`、`InputTape`、`StateHasher`、完整游戏循环 fixture、`SimulationViewBridge` 和整局运行时选择器之上增加只读资格工具。三条版本化二进制录像在同平台逐 Tick 做直接命令/编解码命令双世界比较，并每 1,000 Tick 输出 SHA-256 checkpoint；macOS、Windows、Web/WASM 与 Android ARM64 产出同一 JSON 诊断 schema，由离线 gate 聚合比较。性能门禁独立记录模拟 Tick 与表现池指标；聚合 gate 未通过时不得修改默认路径，未来网络接缝仍只是把解码后的同格式 `LocalFrameCommandSet` 提交给 `LocalFrameInputBuffer.submit()`，本计划不实现 Transport 或网络。

**Tech Stack:** Godot 4.7.1、GDScript、`PackedByteArray`、SHA-256、JSON Schema Draft 2020-12（只用于非玩法诊断 artifact）、Godot macOS/Windows/Web/Android ARM64 导出物、现有 Headless 验证脚本。

## Global Constraints

- 唯一规格来源是 `docs/superpowers/specs/2026-08-08-local-deterministic-frame-sync-design.md`；既有计划接口与其冲突时以该 SPEC 为准。
- 前置门槛：Plan 1～7 各自自动验证、Headless 导入检查和人工验收全部通过；任一前置门槛未通过时只允许完善资格工具，不得切换默认路径。
- 资格录像固定为单人 `active_player_mask = 0b0001`、2 人 `0b0011`、4 人 `0b1111` 三条，每条恰好 100,000 Tick；不以 3 人录像替代任一门禁。
- 每条录像在单个平台内必须每 Tick 比较“直接命令世界”与“命令编码再解码世界”的规范状态 SHA-256；首个分歧立即失败并导出 Tick、输入帧、两侧 Hash、规范状态和首个差异字节。
- 跨平台必须覆盖 macOS、Windows、Web/WASM 和至少一个移动 ARM64；本计划选 Android ARM64 作为可重复导出路径，但 SPEC 未指定具体最低设备型号，报告必须记录实际型号并显式标记哪一台是最低目标设备。
- 跨平台 checkpoint 固定在完成 Tick `999, 1999, ..., 99999` 后，共 100 个；四个平台的三条录像必须逐 checkpoint Hash 相同，不能只比较最终 Hash。
- 渲染节奏固定覆盖 Headless 无渲染、30 FPS、60 FPS、120 FPS 和可重复 jitter/drop 模式；所有模式消费同一录像并得到同一组 checkpoint Hash。
- 固定模拟频率仍为 30 Hz、`input_delay = 0`；渲染 delta、物理 delta、刷新率、掉帧和窗口尺寸不得传入 `SimulationWorld.step(tick, frame)`。
- 性能档位固定为 100、150、256、512 只僵尸；最低目标 Web 或移动设备上 100 与 150 档的 30 Hz 模拟 Tick 必须满足 P95 `< 8 ms`，并且滚动 P99 不得持续超过 `16 ms`。
- “P99 不持续超过 16 ms”在本计划中固定为：窗口长度为 300 个采样 Tick、每 30 Tick 向前滑动一次并计算 P99；不允许连续 3 个重叠窗口的 P99 大于 `16 ms`。30 Tick 的固定步长能够覆盖跨越任意 300 Tick 分段边界的持续尖峰；此定义只细化测试判定，不放宽 SPEC 门槛。
- 性能采样先预热 300 Tick，再采样 10,000 Tick；模拟数组容量、事件队列容量、视图池数量和材质实例数在预热后不得持续增长。
- JSON 只用于资格报告和诊断 artifact，不进入 `InputTape`、命令、规范状态或玩法配置；玩法确定性数据仍使用显式 little-endian 固定格式。
- 资格入口只允许通过导出 feature `frame_sync_qualification` 启动，不改变普通构建的主菜单；普通构建不得加载或执行资格 runner。
- 默认切换是整局切换：新会话只使用 `res://scenes/gameplay/FrameSyncDemoArena.tscn`，旧回退只使用 `res://scenes/gameplay/DemoArena.tscn`，禁止按玩家、武器或子系统混用新旧判定。
- 旧 DemoArena 在新路径成为默认后至少保留一个稳定发布周期；删除旧玩法另开清理计划，不在 Plan 8 中执行。
- 不创建 `Transport`、Socket、WebSocket、ENet、WebRTC、RPC、`MultiplayerSynchronizer`、延迟/丢包模拟、状态纠正或回滚代码。
- 执行前必须询问用户是否使用 worktree，默认不使用；只有用户明确同意时才按 `using-git-worktrees` 建立隔离目录。执行 agent 不运行 `git add` 或 `git commit`，全部任务完成后由用户自行审阅和提交。

---

## 文件结构与稳定边界

| 路径 | 职责 |
| --- | --- |
| `scripts/simulation/testing/qualification_profile.gd` | 冻结三条录像的 ID、mask、seed、100,000 Tick 和 1,000 Tick checkpoint 间隔。 |
| `scripts/simulation/testing/qualification_tape_builder.gd` | 调用 Plan 6 fixture 生成并校验固定二进制 `InputTape`。 |
| `scripts/simulation/testing/canonical_state_diff.gd` | 在 Hash 分歧时定位首个不同字节并输出有界上下文。 |
| `scripts/simulation/testing/first_divergence_harness.gd` | 扩展前序唯一双世界 harness，支持完整世界工厂、checkpoint 和只读 Tick observer。 |
| `scripts/simulation/testing/determinism_qualification_runner.gd` | 编排三条固定录像和资格 artifact，不复制双世界比较循环。 |
| `resources/simulation/qualification/single_100k.fstape` | 单人固定资格录像。 |
| `resources/simulation/qualification/local_2p_100k.fstape` | 2 人固定资格录像。 |
| `resources/simulation/qualification/local_4p_100k.fstape` | 4 人固定资格录像。 |
| `docs/superpowers/schemas/frame-sync-qualification-report.schema.json` | 跨平台成功报告 schema。 |
| `docs/superpowers/schemas/frame-sync-divergence.schema.json` | 首分歧诊断 artifact schema。 |
| `docs/superpowers/qualification/2026-08-08/{macos,windows,web-wasm,android-arm64}.json` | 四个平台由资格导出物生成的可审计报告。 |
| `scripts/simulation/testing/render_cadence_qualification.gd` | Headless、30/60/120 FPS 与固定 jitter/drop 的整数调度。 |
| `scripts/simulation/testing/qualification_entry.gd` | 导出物资格入口，写 `user://`、stdout，并在 Web 提供报告下载。 |
| `scenes/simulation/FrameSyncQualification.tscn` | 只在 `frame_sync_qualification` feature 下运行的无玩法 UI 资格场景。 |
| `tools/validation/validate_frame_sync_qualification.gd` | 本机短测、100,000 Tick 长测和 artifact schema 聚焦验证。 |
| `tools/qualification/compare_qualification_reports.gd` | 聚合 macOS/Windows/Web-WASM/Android-ARM64 报告并逐 checkpoint 比较。 |
| `export_presets.cfg` | 增加四个带 `frame_sync_qualification` feature 的独立资格导出 preset。 |
| `scripts/simulation/testing/performance_qualification_runner.gd` | 100/150/256/512 模拟与表现压力档、滚动 P99 和容量增长判定。 |
| `scripts/simulation/testing/world_game_loop_fixture.gd` | 增加仅供性能资格使用的固定容量完整世界与压力 tape 工厂。 |
| `scripts/simulation/world/simulation_world.gd` | 增加只读容量诊断快照，不改变规范状态或玩法接口。 |
| `docs/superpowers/schemas/frame-sync-performance-report.schema.json` | 最低目标设备性能与设备身份 schema。 |
| `docs/superpowers/qualification/2026-08-08/minimum-target-performance.json` | 实际最低目标 Web 或移动设备的性能报告。 |
| `tools/validation/validate_frame_sync_performance_gate.gd` | 性能判定算法与报告字段验证。 |
| `tools/qualification/verify_frame_sync_release_gate.gd` | 汇总确定性、跨平台、cadence 和最低设备性能报告，输出唯一 release gate 结论。 |
| `scripts/gameplay/battle_runtime_selector.gd` | 资格通过后把新路径设为普通会话默认，并保留 `--legacy-demo` 回退。 |
| `scripts/gameplay/game_session.gd` | 资格通过后将无参数单人/本地会话默认冻结到 `FRAME_SYNC`。 |
| `scripts/menu/main_menu.gd` | 单人入口使用整局 runtime selector，不硬编码场景路径。 |
| `scripts/menu/local_multiplayer_lobby.gd` | 2～4 人入口使用同一 runtime selector，不在战斗中切换。 |
| `docs/frame-sync-release-qualification.md` | 记录报告收集命令、门禁结果、旧路径保留周期与未来命令注入接缝。 |
| `docs/superpowers/qualification/2026-08-08/release-gate.json` | release gate 对上述报告的机器可读最终结论。 |

## 前置接口

本计划按以下已冻结接口消费前七个计划；若实现仓库中的路径已在前序计划统一过，以实现后的同名 class/API 为准，不复制第二套世界或缓冲：

```gdscript
# Plan 1
InputTape.decode(bytes: PackedByteArray) -> bool
InputTape.get_frame(tick: int) -> LocalFrameCommandSet
InputTape.get_frame_count() -> int
LocalFrameCommandCodec.encode(frame: LocalFrameCommandSet) -> PackedByteArray
LocalFrameCommandCodec.decode(bytes: PackedByteArray) -> LocalFrameCommandSet
LocalFrameInputBuffer.submit(frame: LocalFrameCommandSet) -> bool
LocalFrameInputBuffer.has_complete_frame(tick: int) -> bool
LocalFrameInputBuffer.take(tick: int) -> LocalFrameCommandSet
SimulationWorld.step(tick: int, frame: LocalFrameCommandSet) -> bool
SimulationWorld.encode_canonical_state() -> PackedByteArray
StateHasher.hash_canonical(bytes: PackedByteArray) -> PackedByteArray
StateHasher.to_hex(value: PackedByteArray) -> String

# Plan 6
WorldGameLoopFixture.create_world(session_seed: int, active_player_mask: int) -> SimulationWorld
WorldGameLoopFixture.create_session(session_seed: int, active_player_mask: int) -> LocalSimulationSession
WorldGameLoopFixture.build_qualification_tape(active_player_mask: int, ticks: int) -> InputTape

# Plan 7
BattleRuntimeSelector.scene_path_for(runtime: int) -> String
BattleRuntimeSelector.is_valid(runtime: int) -> bool
SimulationViewBridge.bind_world(world: SimulationWorld, active_player_mask: int) -> Error
SimulationViewBridge.capture_simulation_tick(tick: int) -> void
SimulationViewBridge.render_interpolated(interpolation_alpha: float) -> void
ViewPerformanceBenchmark.begin(world: SimulationWorld, bridge: SimulationViewBridge, zombie_count: int, sample_frames: int) -> void
signal ViewPerformanceBenchmark.completed(report: Dictionary)
```

cadence runner 只按整数 Tick 和固定渲染调用表推进，不用 `/` 推导模拟调度；表内预写的浮点 alpha 只传给 Plan 7 的 `render_interpolated()`。该浮点只能影响 Transform/动画/HUD，不得写回模拟；每次成功 `world.step()` 后必须调用一次 `capture_simulation_tick(tick)`，one-shot 事件不得因一个 Tick 内多次渲染而重复消费。

### Task 1：冻结三条 100,000 Tick 录像并建立逐 Tick 资格 runner

**Files:**

- 创建：`scripts/simulation/testing/qualification_profile.gd`
- 创建：`scripts/simulation/testing/qualification_tape_builder.gd`
- 修改：`scripts/simulation/testing/world_game_loop_fixture.gd`
- 创建：`scripts/simulation/testing/canonical_state_diff.gd`
- 创建：`scripts/simulation/testing/determinism_qualification_runner.gd`
- 修改：`scripts/simulation/testing/first_divergence_harness.gd`
- 创建：`resources/simulation/qualification/single_100k.fstape`
- 创建：`resources/simulation/qualification/local_2p_100k.fstape`
- 创建：`resources/simulation/qualification/local_4p_100k.fstape`
- 创建：`docs/superpowers/schemas/frame-sync-qualification-report.schema.json`
- 创建：`docs/superpowers/schemas/frame-sync-divergence.schema.json`
- 创建：`tools/validation/validate_frame_sync_qualification.gd`

**Interfaces:**

- 消费：`WorldGameLoopFixture.create_world(session_seed: int, active_player_mask: int) -> SimulationWorld`、`build_qualification_tape(active_player_mask: int, ticks: int) -> InputTape`、`InputTape`、`LocalFrameCommandCodec`、`SimulationWorld`、`StateHasher`、前序计划统一扩展的 `FirstDivergenceHarness`；fixture 内部必须执行 Plan 6 冻结的 `new → bundle → map → players → zombie → combat → world_gameplay` 完整顺序。
- 保持：Plan 6 的 `WorldGameLoopFixture.QUALIFICATION_SEED = 24681357`，三条 tape 都用该 seed 与各自 mask 调用 `create_session()`；正数 ticks 的既有 `build_qualification_tape()` 语义不变。
- 产出：`QualificationProfile.all() -> Array[QualificationProfile]`、`tape_path() -> String`。
- 产出：`QualificationTapeBuilder.write_all() -> Error`、`validate(profile: QualificationProfile, bytes: PackedByteArray) -> Dictionary`。
- 产出：`CanonicalStateDiff.compare(left: PackedByteArray, right: PackedByteArray) -> Dictionary`。
- 产出：`FirstDivergenceHarness.run_with_world_factory(tape: InputTape, tick_limit: int, world_factory: Callable, checkpoint_interval: int, after_equal_tick: Callable = Callable(), codec_frame_transform: Callable = Callable()) -> Dictionary`；observer 返回 `null` 或 `OK` 表示成功，返回其他 `Error` 时 harness 立即产出 `kind="observer_failure"`；最后一个参数只供验证脚本向 codec 一侧注入受控故障，生产资格运行始终传空 `Callable()`。
- 产出：`DeterminismQualificationRunner.run_profile(profile: QualificationProfile, tape_bytes: PackedByteArray, platform_id: String, cadence_id: String, after_equal_tick: Callable = Callable()) -> Dictionary`；成功报告含 100 个 checkpoint，失败报告符合 divergence schema。

- [ ] **Step 1：先写失败的资格 profile 与固定录像验证**

在 `validate_frame_sync_qualification.gd` 断言只有 1/2/4 人三条 profile、每条 100,000 Tick、间隔 1,000，且文件必须存在并能由 `InputTape.decode()` 读取：

```gdscript
extends SceneTree

const QualificationProfile = preload("res://scripts/simulation/testing/qualification_profile.gd")
const InputTape = preload("res://scripts/simulation/replay/input_tape.gd")
const WorldGameLoopFixture = preload("res://scripts/simulation/testing/world_game_loop_fixture.gd")

func _init() -> void:
	var profiles := QualificationProfile.all()
	_assert(profiles.size() == 3, "资格集必须恰好包含单人、2 人、4 人")
	_assert(profiles[0].active_player_mask == 0b0001, "single mask 必须为 0001")
	_assert(profiles[1].active_player_mask == 0b0011, "local_2p mask 必须为 0011")
	_assert(profiles[2].active_player_mask == 0b1111, "local_4p mask 必须为 1111")
	for profile in profiles:
		_assert(profile.tick_count == 100_000, "每条资格录像必须为 100000 Tick")
		_assert(profile.checkpoint_interval == 1_000, "checkpoint 间隔必须为 1000")
		_assert(FileAccess.file_exists(profile.tape_path()), "固定资格录像必须提交到仓库")
		var expected_session = WorldGameLoopFixture.create_session(profile.session_seed, profile.active_player_mask)
		var tape := InputTape.new(expected_session)
		_assert(tape.decode(FileAccess.get_file_as_bytes(profile.tape_path())), "录像必须通过最终 manifest 的严格二进制解码")
		_assert(tape.get_frame_count() == 100_000, "录像帧数必须精确")
	print("validate_frame_sync_qualification: PROFILE PASS")
	quit(0)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		quit(1)
```

- [ ] **Step 2：运行测试并确认缺少 profile/录像时失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_qualification.gd
```

预期：非零退出，错误明确指向缺少 `qualification_profile.gd` 或任一 `.fstape`；不得自动跳过缺失录像。

- [ ] **Step 3：实现不可变资格 profile**

`qualification_profile.gd` 只返回新实例；录像内的 session seed 与最终 manifest 由 Plan 6 fixture 和 `InputTape` 自身冻结，Plan 8 不另造第二份会话元数据：

```gdscript
extends RefCounted
class_name QualificationProfile

const TICK_COUNT := 100_000
const CHECKPOINT_INTERVAL := 1_000

var tape_id: String
var active_player_mask: int
var session_seed := 24_681_357
var file_name: String
var tick_count := TICK_COUNT
var checkpoint_interval := CHECKPOINT_INTERVAL

func _init(id: String, mask: int, path_name: String) -> void:
	tape_id = id
	active_player_mask = mask
	file_name = path_name

func tape_path() -> String:
	return "res://resources/simulation/qualification/%s" % file_name

static func all() -> Array[QualificationProfile]:
	return [
		QualificationProfile.new("single_100k", 0b0001, "single_100k.fstape"),
		QualificationProfile.new("local_2p_100k", 0b0011, "local_2p_100k.fstape"),
		QualificationProfile.new("local_4p_100k", 0b1111, "local_4p_100k.fstape"),
	]
```

每条报告必须同时记录 `tape_sha256` 与 `manifest_sha256 = SHA256(InputTape.get_session().get_manifest().encode())`。最终 manifest 由 Plan 6 fixture/session 的完整 `SimulationConfigBundle` 生成，覆盖 map、player、zombie、combat、world/pickup 配置及 Plan 2 地图 `content_hash`；资格层只引用该最终 `config_hash`，不把 Plan 3 的中间合并 Hash 当成最终值，也不定义新的确定性序列化格式。

- [ ] **Step 4：实现录像 builder 并生成三条固定二进制资产**

在 Plan 6 的固定开局→战斗→爆炸/放置→掉落/拾取→波次→失败→重开脚本中，仅对不破坏关键交互的自由移动/攻击窗口加入每槽独立 Park–Miller 合法命令变化；种子从最终 session seed 与 slot 常量确定性派生。三条 tape 合计必须覆盖 heading 1～16、三个 action bit、`equipment_delta=-1/0/1`、放置、同时争抢、死亡、动态障碍和重开；未启用槽始终全零。builder 必须统计这些覆盖项，并验证 fixture 生成的 session、mask、连续 Tick；写文件只能由显式 `--write` 参数触发，普通测试绝不重写 golden tape：

```gdscript
static func _randomize_free_window(command: PlayerFrameCommand, rng: ParkMillerRng, tick: int) -> void:
	command.move_heading = rng.next_inclusive(1, 16)
	if tick % 11 == 0:
		command.action_bits |= PlayerFrameCommand.USE_HELD
	if tick % 37 == 0:
		command.equipment_delta = rng.next_inclusive(-1, 1)
	if tick % 53 == 0:
		command.placement_heading = rng.next_inclusive(1, 16)
```

该函数只由 fixture 标记为自由窗口的 Tick 调用；关键 scripted Tick 的命令逐字段保持 Plan 6 预期，避免随机变化绕过必须发生的爆炸、拾取、失败或重开。builder 入口为：

```gdscript
extends SceneTree

const QualificationProfile = preload("res://scripts/simulation/testing/qualification_profile.gd")
const WorldGameLoopFixture = preload("res://scripts/simulation/testing/world_game_loop_fixture.gd")

func _init() -> void:
	if not "--write" in OS.get_cmdline_user_args():
		push_error("qualification tape write requires --write")
		quit(2)
	for profile in QualificationProfile.all():
		var tape = WorldGameLoopFixture.build_qualification_tape(
			profile.active_player_mask,
			profile.tick_count
		)
		var bytes: PackedByteArray = tape.encode()
		var file := FileAccess.open(profile.tape_path(), FileAccess.WRITE)
		if file == null:
			push_error("cannot write %s" % profile.tape_path())
			quit(3)
		file.store_buffer(bytes)
		file.close()
	print("qualification_tape_builder: PASS 3 tapes x 100000 ticks")
	quit(0)
```

运行一次：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://scripts/simulation/testing/qualification_tape_builder.gd -- --write
```

预期：生成三个非空 `.fstape`，打印 `PASS 3 tapes x 100000 ticks`；再次生成时三个文件的 SHA-256 必须保持不变，可用以下命令复核：

```bash
shasum -a 256 resources/simulation/qualification/single_100k.fstape resources/simulation/qualification/local_2p_100k.fstape resources/simulation/qualification/local_4p_100k.fstape
```

- [ ] **Step 5：先写首分歧 artifact 的失败断言**

向验证脚本加入两段规范状态的 byte 17 扰动，并固定差异结构：

```gdscript
const CanonicalStateDiff = preload("res://scripts/simulation/testing/canonical_state_diff.gd")

var left := PackedByteArray()
left.resize(64)
var right := left.duplicate()
right[17] = 0x7f
var diff := CanonicalStateDiff.compare(left, right)
_assert(not diff.ok, "不同状态必须失败")
_assert(diff.first_byte_offset == 17, "必须报告首个差异字节")
_assert(diff.left_size == 64 and diff.right_size == 64, "必须记录两侧长度")
_assert(diff.left_window_hex.length() == diff.right_window_hex.length(), "窗口必须可直接比较")
```

运行同一验证命令，预期因 `canonical_state_diff.gd` 尚不存在而非零退出。

- [ ] **Step 6：实现有界规范状态差异与两个 JSON Schema**

差异窗口固定取首差异前后各 32 bytes，避免分歧时无界扩大日志；完全相同返回 `{ "ok": true }`：

```gdscript
extends RefCounted
class_name CanonicalStateDiff

static func compare(left: PackedByteArray, right: PackedByteArray) -> Dictionary:
	var common := mini(left.size(), right.size())
	var offset := 0
	while offset < common and left[offset] == right[offset]:
		offset += 1
	if offset == common and left.size() == right.size():
		return {"ok": true}
	var start := maxi(0, offset - 32)
	var end := mini(maxi(left.size(), right.size()), offset + 33)
	return {
		"ok": false,
		"first_byte_offset": offset,
		"left_size": left.size(),
		"right_size": right.size(),
		"left_window_hex": left.slice(start, mini(end, left.size())).hex_encode(),
		"right_window_hex": right.slice(start, mini(end, right.size())).hex_encode(),
	}
```

`frame-sync-qualification-report.schema.json` 必须要求 `schema_version = 1`、`platform_id`、`architecture`、`godot_version` 和固定 15 个 run（五种 cadence × 三条 tape）；每个 run 要求 `cadence_id/tape_id/tape_sha256/manifest_sha256/tick_count=100000/checkpoints=100/final_hash/ok=true`。`frame-sync-divergence.schema.json` 必须要求 `tape_id/tick/frame_hex/direct_hash/codec_hash/direct_state_hex/codec_state_hex/first_byte_offset/left_window_hex/right_window_hex`。JSON schema 只验证 artifact 形状，不参与模拟 Hash。

- [ ] **Step 7：扩展唯一 FirstDivergenceHarness 并实现资格 runner**

在 `first_divergence_harness.gd` 增加完整世界工厂入口；每个 Tick 仍由这一处取同一个固定 frame，直接世界消费原对象，codec 世界消费 22-byte 编解码后的新对象。Hash 每 Tick 比较；`after_equal_tick` 只能在两侧 Hash 已相同后观察直接世界，调用后 harness 必须再次 Hash 并拒绝表现层写回：

```gdscript
func run_with_world_factory(tape: InputTape, tick_limit: int, world_factory: Callable, checkpoint_interval: int, after_equal_tick: Callable = Callable(), codec_frame_transform: Callable = Callable()) -> Dictionary:
	if tick_limit <= 0:
		return {"ok": false, "kind": "invalid_tick_limit", "tick_limit": tick_limit}
	var direct_world: SimulationWorld = world_factory.call()
	var codec_world: SimulationWorld = world_factory.call()
	var checkpoints: Array[Dictionary] = []
	var last_direct_hash := PackedByteArray()
	for tick in tick_limit:
		var frame = tape.get_frame(tick)
		var frame_bytes: PackedByteArray = LocalFrameCommandCodec.encode(frame)
		var decoded = LocalFrameCommandCodec.decode(frame_bytes)
		if codec_frame_transform.is_valid():
			decoded = codec_frame_transform.call(tick, decoded)
			if decoded == null or not decoded.is_valid():
				return {"ok": false, "kind": "invalid_injected_frame", "tick": tick}
		if not direct_world.step(tick, frame) or not codec_world.step(tick, decoded):
			return _step_failure(tick, frame_bytes, direct_world, codec_world)
		var direct_state: PackedByteArray = direct_world.encode_canonical_state()
		var codec_state: PackedByteArray = codec_world.encode_canonical_state()
		var direct_hash: PackedByteArray = StateHasher.hash_canonical(direct_state)
		var codec_hash: PackedByteArray = StateHasher.hash_canonical(codec_state)
		last_direct_hash = direct_hash
		if not StateHasher.equal(direct_hash, codec_hash):
			return _divergence(tick, frame_bytes, direct_state, codec_state, direct_hash, codec_hash)
		if after_equal_tick.is_valid():
			var observer_result = after_equal_tick.call(tick, direct_world, direct_hash)
			if typeof(observer_result) == TYPE_INT and int(observer_result) != OK:
				return {
					"ok": false,
					"kind": "observer_failure",
					"tick": tick,
					"error_code": observer_result,
				}
			var observed_hash := StateHasher.hash_canonical(direct_world.encode_canonical_state())
			if not StateHasher.equal(direct_hash, observed_hash):
				return _presentation_mutation(tick, direct_hash, observed_hash)
		if checkpoint_interval > 0 and FixedMath.euclidean_mod(tick + 1, checkpoint_interval) == 0:
			checkpoints.append({"tick": tick, "state_hash": StateHasher.to_hex(direct_hash)})
	return {
		"ok": true,
		"ticks_checked": tick_limit,
		"checkpoints": checkpoints,
		"final_hash": StateHasher.to_hex(last_direct_hash),
	}
```

`DeterminismQualificationRunner.run_profile()` 先以 `WorldGameLoopFixture.create_session(profile.session_seed, profile.active_player_mask)` 构造 expected session，再严格 decode 固定 tape；随后以 tape 恢复出的 session seed 构造 `world_factory`、调用上面的唯一 harness，并把结果的 `final_hash` 原样写入带 `tape_sha256/manifest_sha256/platform_id/cadence_id` 的 schema：

```gdscript
var session_seed: int = tape.get_session().get_session_seed()
var world_factory := func() -> SimulationWorld:
	return WorldGameLoopFixture.create_world(session_seed, profile.active_player_mask)
var harness := FirstDivergenceHarness.new(tape.get_session())
var result := harness.run_with_world_factory(
	tape,
	profile.tick_count,
	world_factory,
	profile.checkpoint_interval,
	after_equal_tick
)
```

`_divergence()` 必须把 `CanonicalStateDiff.compare()` 的字段与两侧完整 state hex 合并后立即返回；runner 不允许继续到第二个分歧，也不得另写第二套 codec/world 循环。

runner 的 `_sha256_hex(bytes)` 固定实现为 `StateHasher.to_hex(StateHasher.hash_canonical(bytes))`；无效 tape 报告固定含 `ok=false/kind="invalid_tape"/tape_id/platform_id/cadence_id` 和 `InputTape.get_error_message()`。

`_step_failure()` 固定返回 `kind="step_failure"`、tick、frame hex、两侧 `get_last_error()`、两侧 canonical state/hash；`_presentation_mutation()` 固定返回 `kind="presentation_mutation"`、tick、observer 前后 Hash；`_divergence()` 固定返回 divergence schema 的全部字段。三者都含 `ok=false`，不得只打印日志后继续。

- [ ] **Step 8：只向 codec 世界注入短故障，再运行三条长测与 Headless 导入检查**

验证脚本先生成 200 Tick 临时录像，但不修改录像本身；调用 `run_with_world_factory()` 时传入下面的测试专用 transform，只在 tick 17 修改 codec 解码侧 slot 0 的合法 heading。断言 direct 世界仍消费原帧、codec 世界消费变换帧，失败 artifact 的 `kind == "divergence"`、`tick == 17` 且 `first_byte_offset >= 0`。生产 `DeterminismQualificationRunner` 永远不传该 transform。再对仓库三条录像各执行完整 100,000 Tick，并断言每条成功结果的 `final_hash` 为 64 个十六进制字符：

```gdscript
var inject_codec_heading := func(tick: int, decoded: LocalFrameCommandSet) -> LocalFrameCommandSet:
	if tick != 17:
		return decoded
	var changed := decoded.copy()
	var current := changed.player_commands[0].move_heading
	changed.player_commands[0].move_heading = 1 if current != 1 else 2
	return changed

var injected := FirstDivergenceHarness.new(short_tape.get_session()).run_with_world_factory(
	short_tape,
	200,
	short_world_factory,
	100,
	Callable(),
	inject_codec_heading
)
_assert(not injected.ok and injected.kind == "divergence", "故障必须只让 codec 世界分歧")
_assert(injected.tick == 17 and injected.first_byte_offset >= 0, "必须定位 tick 17 首差异")
```

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_qualification.gd -- --full
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

预期：打印 `single_100k PASS 100000`、`local_2p_100k PASS 100000`、`local_4p_100k PASS 100000` 和 `300 checkpoints`，两个进程均以 0 退出；任一首分歧都必须以非零退出并写入 `user://frame_sync_qualification/divergence.json`。

### Task 2：验证渲染节奏、Headless 与四平台 checkpoint，并统一诊断 artifact

**Files:**

- 创建：`scripts/simulation/testing/render_cadence_qualification.gd`
- 创建：`scripts/simulation/testing/frame_sync_qualification_view_fixture.gd`
- 创建：`scripts/simulation/testing/qualification_entry.gd`
- 创建：`scenes/simulation/FrameSyncQualification.tscn`
- 创建：`tools/qualification/compare_qualification_reports.gd`
- 创建（由导出物生成）：`docs/superpowers/qualification/2026-08-08/macos.json`
- 创建（由导出物生成）：`docs/superpowers/qualification/2026-08-08/windows.json`
- 创建（由导出物生成）：`docs/superpowers/qualification/2026-08-08/web-wasm.json`
- 创建（由导出物生成）：`docs/superpowers/qualification/2026-08-08/android-arm64.json`
- 修改：`tools/validation/validate_frame_sync_qualification.gd`
- 修改：`scripts/menu/main_menu.gd`
- 修改：`export_presets.cfg`

**Interfaces:**

- 消费：Task 1 的 runner/report schema、Plan 7 的 `FrameSyncPresentationRoot.prepare()` / `bind_bridge()`、`SimulationViewBridge.bind_world()` / `render_interpolated()` 和 `res://scenes/simulation/FrameSyncPresentationRoot.tscn`；资格夹具不得逐个调用 root 内部 bind API。
- 产出：`FrameSyncQualificationViewFixture.create(host: Node, world: SimulationWorld, active_player_mask: int) -> FrameSyncQualificationViewFixture`、`get_bridge() -> SimulationViewBridge`、`dispose() -> void`。
- 产出：`RenderCadenceQualification.alphas_for_tick(cadence_id: String, tick: int) -> PackedFloat32Array`、`run(profile, tape_bytes, cadence_id, platform_id, presentation_host: Node = null) -> Dictionary`；非 Headless cadence 要求非空 host。
- 产出：`QualificationEntry.run_all() -> Dictionary`，按固定 cadence 外层、tape 内层顺序生成 15 个 run，并写 `user://frame_sync_qualification/<platform_id>.json`。
- 产出：`compare_qualification_reports.gd -- <macos.json> <windows.json> <web-wasm.json> <android-arm64.json>`；成功打印 `CROSS_PLATFORM PASS 4 platforms 5 cadences 3 tapes 1500 checkpoint values per platform`。

- [ ] **Step 1：先写五种 cadence 必须 Hash 相同的失败验证**

对单人录像的前 3,000 Tick 运行五种 cadence，固定模式和期望的三个 checkpoint：

```gdscript
const RenderCadenceQualification = preload("res://scripts/simulation/testing/render_cadence_qualification.gd")

var cadence_ids := ["headless", "render_30", "render_60", "render_120", "render_jitter_drop"]
var baseline: Array = []
var presentation_host := Node.new()
get_root().add_child(presentation_host)
for cadence_id in cadence_ids:
	var report := RenderCadenceQualification.run(short_profile, short_tape_bytes, cadence_id, "macos", presentation_host)
	_assert(report.ok, "%s cadence 必须通过" % cadence_id)
	_assert(report.checkpoints.size() == 3, "%s 必须输出三个 checkpoint" % cadence_id)
	if baseline.is_empty():
		baseline = report.checkpoints
	else:
		_assert(report.checkpoints == baseline, "%s 不得改变模拟 Hash" % cadence_id)
```

运行验证，预期因 cadence runner 尚不存在而非零退出。

- [ ] **Step 2：实现完全可重复的渲染节奏调度**

每个模拟 Tick 的渲染调用次数固定代表 30/60/120 FPS；jitter/drop 以 8 Tick 周期包含零渲染帧和补偿 burst，不读取系统刷新率。浮点 alpha 只传给表现桥：

```gdscript
static func alphas_for_tick(cadence_id: String, tick: int) -> PackedFloat32Array:
	match cadence_id:
		"headless":
			return PackedFloat32Array()
		"render_30":
			return PackedFloat32Array([0.0])
		"render_60":
			return PackedFloat32Array([0.0, 0.5])
		"render_120":
			return PackedFloat32Array([0.0, 0.25, 0.5, 0.75])
		"render_jitter_drop":
			var cycle := [
				PackedFloat32Array(),
				PackedFloat32Array([0.15]),
				PackedFloat32Array([0.05, 0.40, 0.80]),
				PackedFloat32Array(),
				PackedFloat32Array([0.70]),
				PackedFloat32Array([0.10, 0.20, 0.90]),
				PackedFloat32Array([0.50]),
				PackedFloat32Array(),
			]
			return cycle[tick % cycle.size()]
		_:
			return PackedFloat32Array()
```

`FrameSyncQualificationViewFixture.create()` 只为资格进程创建表现对象：在传入 host 下实例化一份全新的 `FrameSyncPresentationRoot.tscn` 和固定正交 `Camera3D`，camera transform/size/cull mask 使用代码常量；依次调用 `root.prepare(ViewPerformanceProfile.default_profile())`、`bridge.bind_world(world, active_player_mask)`、`root.bind_bridge(bridge, camera)`。任一步非 `OK` 都同步移除并 `free()` 已创建节点后返回 `null`；严禁跳过玩家池、registry、HUD、僵尸池、routers 或世界实体池。`dispose()` 先调用 `root.finish_render_warmup()`，再从 host 同步移除并 `free()` root/camera，确保下一 run 开始前没有上一 run 的 View、ledger、音频或 FX 节点残留，并且不得访问或修改 world。

`run()` 对 `headless` 不创建 fixture；其余模式在进入 harness 前若 `presentation_host == null`，立即返回 `{ "ok": false, "kind": "missing_presentation_host", "cadence_id": cadence_id }`。有效模式在 observer 第一次收到 direct world 时通过上述唯一工厂完整装配。它把以下 `after_equal_tick` 传给 Task 1 的唯一 harness，在返回结果前无论成功或失败都调用 `fixture.dispose()`：

```gdscript
var fixture: FrameSyncQualificationViewFixture = null
var observer := func(tick: int, world: SimulationWorld, _state_hash: PackedByteArray) -> int:
	if cadence_id == "headless":
		return OK
	if fixture == null:
		fixture = FrameSyncQualificationViewFixture.create(
			presentation_host,
			world,
			profile.active_player_mask
		)
		if fixture == null:
			return ERR_CANT_CREATE
	var bridge := fixture.get_bridge()
	bridge.capture_simulation_tick(tick)
	for alpha in alphas_for_tick(cadence_id, tick):
		bridge.render_interpolated(alpha)
	return OK

var result := DeterminismQualificationRunner.run_profile(
	profile,
	tape_bytes,
	platform_id,
	cadence_id,
	observer
)
if fixture != null:
	fixture.dispose()
return result
```

observer 每 Tick 捕获一次模拟样本，再调用零次、一次、两次、四次或 jitter burst 的渲染插值。模拟永远由 harness 连续推进 100,000 Tick，不因零渲染帧跳 Tick；observer 前后的规范状态 Hash 必须相同。每个 cadence/tape run 使用独立 fixture，禁止跨 run 复用 event ledger、View 或 router 计数；camera 只供表现可见性/距离分级，不进入 canonical state 或 Hash。

- [ ] **Step 3：实现只在资格 export feature 下启动的入口与场景**

`main_menu.gd` 在 `_ready()` 的第一条分支检查 feature；普通构建继续显示菜单，资格构建立即切场景：

```gdscript
func _ready() -> void:
	if OS.has_feature("frame_sync_qualification"):
		get_tree().change_scene_to_file("res://scenes/simulation/FrameSyncQualification.tscn")
		return
	single_player_button.grab_focus()
```

`qualification_entry.gd` 对五种 cadence 分别运行三条 tape，平台 ID 只允许 `macos/windows/web-wasm/android-arm64`，成功或失败都写完整 JSON。固定聚合代码为：

```gdscript
const CADENCES := ["headless", "render_30", "render_60", "render_120", "render_jitter_drop"]

func run_all() -> Dictionary:
	var runs: Array[Dictionary] = []
	for cadence_id in CADENCES:
		for profile in QualificationProfile.all():
			var run := RenderCadenceQualification.run(
				profile,
				FileAccess.get_file_as_bytes(profile.tape_path()),
				cadence_id,
				_platform_id(),
				self
			)
			runs.append(run)
			if not run.ok:
				return _platform_report(runs, false)
	return _platform_report(runs, runs.size() == 15)

func _platform_report(runs: Array[Dictionary], ok: bool) -> Dictionary:
	return {
		"schema_version": 1,
		"ok": ok,
		"platform_id": _platform_id(),
		"architecture": Engine.get_architecture_name(),
		"godot_version": Engine.get_version_info().string,
		"runs": runs,
	}

func _platform_id() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--platform-id="):
			var value := argument.trim_prefix("--platform-id=")
			if value in ["macos", "windows", "web-wasm", "android-arm64"]:
				return value
	return "web-wasm" if OS.has_feature("web") else "android-arm64" if OS.has_feature("android") else "windows" if OS.has_feature("windows") else "macos"
```

成功或失败都写完整 JSON：

```gdscript
func _write_report(report: Dictionary) -> void:
	var json_text := JSON.stringify(report)
	var user_dir := DirAccess.open("user://")
	user_dir.make_dir_recursive("frame_sync_qualification")
	var path := "user://frame_sync_qualification/%s.json" % report.platform_id
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(json_text)
	file.close()
	print("FRAME_SYNC_QUALIFICATION_JSON=" + json_text)
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(
			json_text.to_utf8_buffer(),
			"frame-sync-%s.json" % report.platform_id,
			"application/json"
		)
```

场景只包含 `Node` root、状态 `Label` 与入口脚本；不得实例化旧 DemoArena、输入设备或网络节点。失败时 Label 显示首分歧 cadence/tape/tick，成功时显示五种 cadence、三条录像与每平台 1,500 个 checkpoint 值通过。

- [ ] **Step 4：增加四个隔离资格导出 preset**

在 `export_presets.cfg` 增加 `macOS Qualification`、`Windows Qualification`、`Web Qualification`、`Android ARM64 Qualification`，共同设置：

```ini
custom_features="frame_sync_qualification"
export_filter="all_resources"
exclude_filter="build/*,build/**,docs/*,docs/**,.godot/*,.godot/**"
```

Android preset 只启用 `arm64-v8a`，包名固定为 `com.yewei.zombiewar.qualification`；Web preset 保持 WASM 和单线程兼容设置，不启用扩展或线程。资格 preset 与现有普通 `Web` preset 分离，不能给普通构建添加 `frame_sync_qualification` feature。

- [ ] **Step 5：实现四平台报告聚合比较器**

比较器拒绝缺平台、重复平台、非 100,000 Tick、非 100 checkpoint、tape SHA 不同或任一 checkpoint 不同；第一处跨平台分歧输出 tape/tick/基准平台/候选平台/两侧 Hash：

```gdscript
const REQUIRED_PLATFORMS := ["macos", "windows", "web-wasm", "android-arm64"]
const REQUIRED_TAPES := ["single_100k", "local_2p_100k", "local_4p_100k"]

func _compare_tape(baseline: Dictionary, candidate: Dictionary, candidate_platform: String) -> bool:
	if baseline.tape_sha256 != candidate.tape_sha256:
		return _fail("tape_sha256", baseline.tape_id, -1, "macos", candidate_platform)
	if baseline.manifest_sha256 != candidate.manifest_sha256:
		return _fail("manifest_sha256", baseline.tape_id, -1, "macos", candidate_platform)
	for index in 100:
		var left: Dictionary = baseline.checkpoints[index]
		var right: Dictionary = candidate.checkpoints[index]
		if left.tick != right.tick or left.state_hash != right.state_hash:
			return _fail("checkpoint", baseline.tape_id, left.tick, "macos", candidate_platform)
	return baseline.final_hash == candidate.final_hash
```

报告 schema 验证必须先于内容比较；诊断 JSON 可以使用 Dictionary 遍历，因为它不进入模拟，但比较必须按 `REQUIRED_PLATFORMS`、五种 cadence、`REQUIRED_TAPES` 固定顺序，从每份报告精确取同 cadence + tape 的 run。跨 cadence 先在各平台内部与该平台 `headless` run 比较，再对四个平台的同一 cadence 逐 checkpoint 比较。

- [ ] **Step 6：本机验证 Headless 与正常启动 cadence 一致**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_qualification.gd -- --cadence-full
/Applications/Godot.app/Contents/MacOS/Godot --path . --editor --quit-after 1
```

预期：五种 cadence 的三条完整录像各输出 100 checkpoints，共 1,500 个值且同 tape 跨 cadence 一致；正常启动不带 feature 时仍进入主菜单，Headless 不创建表现节点。第二条命令只做普通启动烟测，不替代三条长测。

- [ ] **Step 7：分别生成四个平台 artifact**

使用同一提交和同三条 `.fstape` 执行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release "macOS Qualification" build/qualification/macos/ZombieWarQualification.app
build/qualification/macos/ZombieWarQualification.app/Contents/MacOS/ZombieWarQualification -- --platform-id=macos
```

Windows 主机执行：

```powershell
Godot_v4.7.1-stable_win64.exe --headless --path . --export-release "Windows Qualification" build/qualification/windows/ZombieWarQualification.exe
build/qualification/windows/ZombieWarQualification.exe -- --platform-id=windows
```

Web 导出并人工打开页面，点击资格场景自动生成的 JSON 下载；禁止用 CUA 自动验证：

```bash
mkdir -p build/qualification/web
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release "Web Qualification" build/qualification/web/index.html
```

Android ARM64 导出、安装并从 logcat 保存 `FRAME_SYNC_QUALIFICATION_JSON=` 后的 JSON：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release "Android ARM64 Qualification" build/qualification/android/ZombieWarQualification.apk
adb install -r build/qualification/android/ZombieWarQualification.apk
adb shell monkey -p com.yewei.zombiewar.qualification 1
adb logcat -d -s godot | rg "FRAME_SYNC_QUALIFICATION_JSON="
```

预期：四个平台各有一个 schema-valid 报告；Android 报告 `architecture = arm64`，Web 报告 `platform_id = web-wasm`。

把 native `user://` 文件、Web 下载文件与 Android logcat 中的 JSON 原样保存到本 Task 列出的四个 `docs/superpowers/qualification/2026-08-08/*.json` 路径；只允许规范化末尾换行，不允许编辑 Hash、Tick、设备或通过字段。

- [ ] **Step 8：执行跨平台逐 checkpoint 门禁**

将四份报告保存为 `docs/superpowers/qualification/2026-08-08/{macos,windows,web-wasm,android-arm64}.json` 后运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/qualification/compare_qualification_reports.gd -- docs/superpowers/qualification/2026-08-08/macos.json docs/superpowers/qualification/2026-08-08/windows.json docs/superpowers/qualification/2026-08-08/web-wasm.json docs/superpowers/qualification/2026-08-08/android-arm64.json
```

预期：打印 `CROSS_PLATFORM PASS 4 platforms 5 cadences 3 tapes 1500 checkpoints` 并以 0 退出；任何不同都打印首个平台间分歧并以非零退出。通过前只能称“本地确定性”，不得称“跨平台帧同步就绪”。

### Task 3：建立 100/150/256/512 性能档与最低目标设备硬门槛

**Files:**

- 创建：`scripts/simulation/testing/performance_qualification_runner.gd`
- 修改：`scripts/simulation/testing/world_game_loop_fixture.gd`
- 修改：`scripts/simulation/world/simulation_world.gd`
- 创建：`docs/superpowers/schemas/frame-sync-performance-report.schema.json`
- 创建：`tools/validation/validate_frame_sync_performance_gate.gd`
- 创建（由最低目标设备生成）：`docs/superpowers/qualification/2026-08-08/minimum-target-performance.json`
- 修改：`scripts/simulation/testing/qualification_entry.gd`
- 修改：`scenes/simulation/FrameSyncQualification.tscn`

**Interfaces:**

- 消费：Plan 1 的 `FixedMath.floor_div()`、Plan 4 的 `ZombieSimConfig.default_config()/benchmark_config()` 与 `SimulationWorld.spawn_zombie()`、Plan 6 的完整 `WorldGameLoopFixture`、Plan 7 的 `ViewPerformanceBenchmark.completed(report)`。
- 产出：`WorldGameLoopFixture.create_performance_world(session_seed: int, active_player_mask: int, zombie_capacity: int, initial_zombie_count: int) -> Dictionary`，成功为 `{ "world": SimulationWorld, "tape": InputTape }`，失败为 `{ "error": String }`。
- 产出：`SimulationWorld.get_diagnostic_capacity_snapshot() -> Dictionary`，只读返回固定 capacity/array-size 字段，不进入 canonical state。
- 产出：`PerformanceQualificationRunner.evaluate_tick_samples(samples_us: PackedInt64Array) -> Dictionary`。
- 产出：`run_simulation_tier(zombie_count: int, sample_ticks: int) -> Dictionary`、`run_rendered_tier(zombie_count: int, sample_frames: int) -> Dictionary`。
- 产出：性能报告含设备身份、100/150/256/512 tier、P50/P95/P99、滚动 P99、连续超限窗口数、预热后容量/池/材质增长和 gate 结论。

- [ ] **Step 1：先写 percentile 与持续超限的失败测试**

构造两个跨固定分段边界的样本：四个高耗时 Tick 位于索引 60～63 时会落入起点 0/30/60 的三个重叠窗口并失败；位于索引 30～33 时只落入起点 0/30 的两个连续窗口并通过边界判定：

```gdscript
const PerformanceQualificationRunner = preload("res://scripts/simulation/testing/performance_qualification_runner.gd")

var sustained := PackedInt64Array()
for index in 360:
	sustained.append(7_000)
for index in range(60, 64):
	sustained[index] = 17_000
var sustained_report := PerformanceQualificationRunner.evaluate_tick_samples(sustained)
_assert(sustained_report.max_consecutive_p99_over_16ms == 3, "三个连续窗口必须被识别")
_assert(not sustained_report.p99_sustained_ok, "连续三个窗口超过 16ms 必须失败")

var boundary := PackedInt64Array()
for index in 360:
	boundary.append(7_000)
for index in range(30, 34):
	boundary[index] = 17_000
var boundary_report := PerformanceQualificationRunner.evaluate_tick_samples(boundary)
_assert(boundary_report.max_consecutive_p99_over_16ms == 2, "两个连续窗口必须被记录")
_assert(boundary_report.p99_sustained_ok, "两个窗口不构成持续三窗口失败")
```

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_performance_gate.gd
```

预期：因 runner 尚不存在而非零退出。

- [ ] **Step 2：实现整数 percentile 与滚动 P99 判定**

排序副本，不改变原始采样顺序；percentile 索引使用 ceiling rank：

```gdscript
const WINDOW_TICKS := 300
const WINDOW_STRIDE_TICKS := 30
const P95_LIMIT_US := 8_000
const P99_LIMIT_US := 16_000
const MAX_CONSECUTIVE_OVER_LIMIT_WINDOWS := 2

static func _percentile(sorted_samples: PackedInt64Array, numerator: int, denominator: int) -> int:
	var rank := FixedMath.floor_div(sorted_samples.size() * numerator + denominator - 1, denominator)
	return sorted_samples[clampi(rank - 1, 0, sorted_samples.size() - 1)]

static func evaluate_tick_samples(samples_us: PackedInt64Array) -> Dictionary:
	var sorted := samples_us.duplicate()
	sorted.sort()
	var current_over := 0
	var max_over := 0
	var rolling: Array[int] = []
	for start in range(0, samples_us.size() - WINDOW_TICKS + 1, WINDOW_STRIDE_TICKS):
		var window := samples_us.slice(start, start + WINDOW_TICKS)
		window.sort()
		var value := _percentile(window, 99, 100)
		rolling.append(value)
		current_over = current_over + 1 if value > P99_LIMIT_US else 0
		max_over = maxi(max_over, current_over)
	return {
		"p50_us": _percentile(sorted, 50, 100),
		"p95_us": _percentile(sorted, 95, 100),
		"p99_us": _percentile(sorted, 99, 100),
		"rolling_p99_us": rolling,
		"max_consecutive_p99_over_16ms": max_over,
		"p99_sustained_ok": max_over <= MAX_CONSECUTIVE_OVER_LIMIT_WINDOWS,
	}
```

- [ ] **Step 3：实现四档 Headless 模拟采样与增长检测**

先扩展 Plan 6 fixture：100/150/256 档使用容量 256，512 档使用 Plan 4 的 benchmark 容量 512；在 Tick 0 前按稳定 spawn slot 填到指定数量，并生成 10,300 Tick 压力 tape，覆盖玩家聚集、追击、射击、爆炸链、动态障碍和死亡。fixture 不允许在 Tick 运行中扩容或直接结算伤害。每档预热 300 Tick 后采样 10,000 Tick；`Time.get_ticks_usec()` 只用于性能报告，不进入世界状态或 Hash：

```gdscript
func run_simulation_tier(zombie_count: int, sample_ticks: int = 10_000) -> Dictionary:
	var capacity := 512 if zombie_count == 512 else 256
	var fixture := WorldGameLoopFixture.create_performance_world(196_613, 0b1111, capacity, zombie_count)
	if fixture.has("error"):
		return {"ok": false, "error": fixture.error, "zombie_count": zombie_count}
	var world: SimulationWorld = fixture.world
	var tape: InputTape = fixture.tape
	for tick in 300:
		world.step(tick, tape.get_frame(tick))
	var before := world.get_diagnostic_capacity_snapshot()
	var samples := PackedInt64Array()
	for sample_index in sample_ticks:
		var tick := sample_index + 300
		var started := Time.get_ticks_usec()
		world.step(tick, tape.get_frame(tick))
		samples.append(Time.get_ticks_usec() - started)
	var after := world.get_diagnostic_capacity_snapshot()
	var stats := evaluate_tick_samples(samples)
	stats.merge({
		"zombie_count": zombie_count,
		"sample_ticks": sample_ticks,
		"capacity_before": before,
		"capacity_after": after,
		"capacity_growth_count": _positive_growth_count(before, after),
	})
	return stats
```

`SimulationWorld.get_diagnostic_capacity_snapshot()` 直接读取既有固定数组和配置容量；它不缓存 Dictionary、不参与世界 step 或 canonical state：

```gdscript
func get_diagnostic_capacity_snapshot() -> Dictionary:
	return {
		"zombie_alive_size": _zombie_state.alive.size(),
		"zombie_pos_x_size": _zombie_state.pos_x.size(),
		"zombie_pos_z_size": _zombie_state.pos_z.size(),
		"barrel_alive_size": _barrel_state.alive.size(),
		"pickup_alive_size": _pickup_state.alive.size(),
		"damage_queue_capacity": _combat_config.damage_capacity,
		"presentation_event_capacity": _combat_config.presentation_event_capacity,
	}
```

`_positive_growth_count()` 只按固定 key 列表比较预热前后 capacity，不比较会正常变化的活跃数量：

```gdscript
const CAPACITY_KEYS := [
	"zombie_alive_size",
	"zombie_pos_x_size",
	"zombie_pos_z_size",
	"barrel_alive_size",
	"pickup_alive_size",
	"damage_queue_capacity",
	"presentation_event_capacity",
]

static func _positive_growth_count(before: Dictionary, after: Dictionary) -> int:
	var growth := 0
	for key in CAPACITY_KEYS:
		if int(after[key]) > int(before[key]):
			growth += 1
	return growth
```

压力输入必须同时覆盖玩家聚集、群体追击、连续射击、爆炸链、动态障碍和大量死亡；只使用 fixture 生成的固定 tape，不另外读取随机设备输入。

- [ ] **Step 4：接入 Plan 7 表现 benchmark 并固定无增长条件**

100 与 150 档额外运行 rendered benchmark，报告字段必须原样保留并加 gate：

```gdscript
func _evaluate_view_report(report: Dictionary) -> Dictionary:
	var growth_ok := (
		report.pool_growth_count == 0 and
		report.material_growth_count == 0 and
		report.active_player_views <= 4 and
		report.active_zombie_views <= report.zombie_count and
		report.pooled_zombie_views <= 512 and
		report.material_instance_count_at_end == report.material_instance_count_after_warmup
	)
	report["growth_ok"] = growth_ok
	return report
```

直接消费 Plan 7 冻结的 `material_instance_count_after_warmup`、`material_instance_count_at_end`、`material_growth_count` 与 `pool_growth_count`；不得用最后一帧材质数自行冒充预热基线。

- [ ] **Step 5：实现性能 artifact schema 和最低目标身份校验**

schema 必须要求：

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["schema_version", "platform_id", "device", "simulation_tiers", "rendered_tiers", "ok"],
  "properties": {
    "schema_version": {"const": 1},
    "platform_id": {"enum": ["web-wasm", "android-arm64"]},
    "device": {
      "type": "object",
      "required": ["model", "os_version", "architecture", "renderer", "is_minimum_target"]
    },
    "simulation_tiers": {"type": "array", "minItems": 4, "maxItems": 4},
    "rendered_tiers": {"type": "array", "minItems": 2, "maxItems": 2},
    "ok": {"type": "boolean"}
  }
}
```

每个 `simulation_tiers` 元素还必须要求 `zombie_count/sample_ticks/p50_us/p95_us/p99_us/rolling_p99_us/max_consecutive_p99_over_16ms/capacity_growth_count`，顺序固定为 100、150、256、512；每个 `rendered_tiers` 元素要求 Plan 7 的全部 report 字段，顺序固定为 100、150。入口必须从 `OS.get_model_name()`、`OS.get_version()`、`Engine.get_version_info()` 和渲染器 API 采集真实值。若型号为空、架构不是 `arm64` 且平台也不是 `web-wasm`、或 `is_minimum_target` 未显式为 true，release gate 拒绝报告。SPEC 未指定具体机型，因此计划不虚构硬件型号。

- [ ] **Step 6：运行开发机回归与最低目标设备采样**

开发机先验证算法和四档可完成性：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_performance_gate.gd -- --all-tiers
```

预期：100/150/256/512 都完成 300 预热 + 10,000 采样且容量增长为 0；开发机结果只作回归，不替代最低目标设备。

在实际最低目标 Web 或 Android ARM64 设备启动资格导出物，传入 `--minimum-target`；保存生成的 `docs/superpowers/qualification/2026-08-08/minimum-target-performance.json`。100 与 150 档必须同时满足 `p95_us < 8000`、`max_consecutive_p99_over_16ms <= 2`、`capacity_growth_count == 0`、`growth_ok == true`。256/512 档必须完成且无容量增长，但 SPEC 未给这两档时延门槛，不能擅自用 8/16ms 阻止发布或伪称其已达到相同性能目标。

### Task 4：聚合最终 release gate，资格通过后切换默认并冻结未来 Transport 接缝

**Files:**

- 创建：`tools/qualification/verify_frame_sync_release_gate.gd`
- 创建（由 gate 生成）：`docs/superpowers/qualification/2026-08-08/release-gate.json`
- 修改：`scripts/gameplay/battle_runtime_selector.gd`
- 修改：`scripts/gameplay/game_session.gd`
- 修改：`scripts/menu/main_menu.gd`
- 修改：`scenes/menu/MainMenu.tscn`
- 修改：`scripts/menu/local_multiplayer_lobby.gd`
- 修改：`tools/validation/validate_frame_sync_qualification.gd`
- 创建：`docs/frame-sync-release-qualification.md`

**Interfaces:**

- 消费：四平台 deterministic reports、最低目标 performance report、Plan 7 的 `BattleRuntimeSelector`、Plan 1 的 `LocalFrameInputBuffer.submit(frame: LocalFrameCommandSet) -> bool`。
- 产出：`ReleaseGateVerifier.verify(determinism_reports: Dictionary, performance_report: Dictionary) -> Dictionary`，始终返回 `{ "ok": bool, "failures": Array[String], "missing_platforms": Array[String], "missing_minimum_target_performance": bool }`；后两个字段既供测试精确断言，也进入失败 artifact。
- 产出：`verify_frame_sync_release_gate.gd -- <report-dir> -> exit code`；成功打印 `FRAME_SYNC_RELEASE_GATE PASS`，失败打印所有缺失门禁并非零退出。
- 产出：`BattleRuntimeSelector.default_runtime(user_args: PackedStringArray = OS.get_cmdline_user_args()) -> int`；普通路径返回 `FRAME_SYNC`，`--legacy-demo` 返回 `LEGACY_DEMO`。
- 产出：`GameSessionState.configure_single(battle_runtime: int = BattleRuntimeSelector.FRAME_SYNC) -> bool`、`prepare_local(battle_runtime: int = BattleRuntimeSelector.FRAME_SYNC) -> bool`、`configure_local(players: Array) -> bool`；战斗开始后 runtime 不可变。

- [ ] **Step 1：先写 release gate 缺报告必败验证**

创建临时目录只放 macOS report，断言 gate 列出其余三个平台与最低目标性能报告：

```gdscript
var incomplete_reports := {
	"macos": _valid_determinism_report("macos"),
}
var result := ReleaseGateVerifier.verify(incomplete_reports, {})
_assert(not result.ok, "缺少平台报告时 release gate 必须失败")
_assert("windows" in result.missing_platforms, "必须报告缺 Windows")
_assert("web-wasm" in result.missing_platforms, "必须报告缺 Web/WASM")
_assert("android-arm64" in result.missing_platforms, "必须报告缺移动 ARM64")
_assert(result.missing_minimum_target_performance, "必须报告缺最低目标性能")
```

运行资格验证，预期因 verifier 尚不存在而非零退出。

- [ ] **Step 2：实现一次性汇总 gate，禁止部分通过**

release 门禁执行顺序固定为先运行 Headless 导入命令，再由 gate 脚本检查并收集全部报告失败项：schema、每平台 15 个 100,000 Tick run、五种 cadence、四平台每平台 1,500 个 checkpoint 值、Android ARM64、最低目标 100/150 性能和四档无增长：

```gdscript
const REQUIRED_CADENCES := ["headless", "render_30", "render_60", "render_120", "render_jitter_drop"]
const REQUIRED_PLATFORMS := ["macos", "windows", "web-wasm", "android-arm64"]

static func verify(determinism_reports: Dictionary, performance_report: Dictionary) -> Dictionary:
	var failures: Array[String] = []
	var missing_platforms: Array[String] = []
	for platform_id in REQUIRED_PLATFORMS:
		if not determinism_reports.has(platform_id):
			missing_platforms.append(platform_id)
			failures.append("missing determinism report: %s" % platform_id)
	var missing_minimum_target_performance := performance_report.is_empty()
	_check_tapes_and_checkpoints(determinism_reports, failures)
	_check_cadences(determinism_reports, REQUIRED_CADENCES, failures)
	_check_mobile_arm64(determinism_reports, failures)
	if not missing_minimum_target_performance:
		_check_minimum_target_performance(performance_report, failures)
		_check_no_growth(performance_report, failures)
	else:
		failures.append("missing minimum-target performance report")
	return {
		"ok": failures.is_empty(),
		"failures": failures,
		"missing_platforms": missing_platforms,
		"missing_minimum_target_performance": missing_minimum_target_performance,
	}
```

脚本只读 `docs/superpowers/qualification/2026-08-08/`，把结论写到同目录 `release-gate.json`，不修改源码或 feature flag；未通过时必须保持 Plan 7 的 `LEGACY_DEMO` 默认。

- [ ] **Step 3：运行最终 gate，未通过则停止默认切换**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/qualification/verify_frame_sync_release_gate.gd -- docs/superpowers/qualification/2026-08-08
```

预期：Headless 导入先以 0 退出；只有四平台、五 cadence、三条 tape、最低目标性能和增长检查全部通过才打印 `FRAME_SYNC_RELEASE_GATE PASS`。任一命令退出码非 0 都停止本 Task 后续步骤，`DemoArena` 继续默认；不得通过修改报告、删除档位或降低阈值绕过。

- [ ] **Step 4：先写默认路径与显式旧路径回退测试**

资格 gate 已通过后，加入 selector/session 断言：

```gdscript
_assert(BattleRuntimeSelector.default_runtime(PackedStringArray()) == BattleRuntimeSelector.FRAME_SYNC, "资格通过后普通会话必须默认新路径")
_assert(BattleRuntimeSelector.default_runtime(PackedStringArray(["--legacy-demo"])) == BattleRuntimeSelector.LEGACY_DEMO, "稳定周期内必须保留显式旧路径")
_assert(BattleRuntimeSelector.scene_path_for(BattleRuntimeSelector.FRAME_SYNC) == "res://scenes/gameplay/FrameSyncDemoArena.tscn", "新路径必须是整局帧同步场景")
_assert(BattleRuntimeSelector.scene_path_for(BattleRuntimeSelector.LEGACY_DEMO) == "res://scenes/gameplay/DemoArena.tscn", "旧路径必须仍可回退")

var session := GameSessionState.new()
session.configure_single()
_assert(session.get_battle_runtime() == BattleRuntimeSelector.FRAME_SYNC, "无参数单人会话必须冻结新路径")
session.clear()
session.prepare_local()
session.configure_local([_player(0), _player(1)])
_assert(session.get_battle_runtime() == BattleRuntimeSelector.FRAME_SYNC, "无参数本地多人必须冻结新路径")
```

运行验证，预期在默认值尚为 `LEGACY_DEMO` 时失败，证明测试真实约束切换。

- [ ] **Step 5：把新路径设为默认，同时保留一个稳定周期回退**

修改 selector：

```gdscript
const LEGACY_DEMO := 0
const FRAME_SYNC := 1
const LEGACY_RETENTION_STABLE_RELEASES := 1

static func default_runtime(user_args: PackedStringArray = OS.get_cmdline_user_args()) -> int:
	if "--legacy-demo" in user_args:
		return LEGACY_DEMO
	return FRAME_SYNC
```

`GameSessionState` 的初始 `_battle_runtime`、`clear()` 重置值、`configure_single()` 与 `prepare_local()` 默认参数全部改为 `FRAME_SYNC`，保存到私有 `_battle_runtime` 后不再提供战斗中 setter；`configure_local(players)` 只写玩家描述并沿用进入大厅前冻结的 runtime。把 Plan 7 的 `%FrameSyncToggle` 改名为 `%LegacyDemoToggle`，文案改为 `使用旧版 Demo（临时回退）`，`button_pressed = false`；它至少保留一个稳定发布周期。主菜单先解析 CLI，再允许显式 UI 回退：

```gdscript
var runtime := BattleRuntimeSelector.default_runtime()
if legacy_demo_toggle.button_pressed:
	runtime = BattleRuntimeSelector.LEGACY_DEMO
GameSession.configure_single(runtime)
_start_transition(GameSession.get_battle_scene_path())
```

主菜单进入大厅前执行：

```gdscript
var runtime := BattleRuntimeSelector.default_runtime()
if legacy_demo_toggle.button_pressed:
	runtime = BattleRuntimeSelector.LEGACY_DEMO
GameSession.prepare_local(runtime)
_start_transition(local_lobby_scene_path)
```

大厅开始战斗时只消费已冻结 runtime：

```gdscript
GameSession.configure_local(join_state.players)
get_tree().change_scene_to_file(GameSession.get_battle_scene_path())
```

旧 DemoArena 文件、旧脚本和资源不删除；稳定周期内 QA 可用 `--legacy-demo` 启动同一主菜单并进入旧整局路径。

- [ ] **Step 6：验证未来命令注入接缝但不实现 Transport**

在资格验证中创建一个合法 frame，经过 codec 解码后直接提交现有 buffer，再由世界消费，证明未来远端解码器只需复用该边界：

```gdscript
var encoded: PackedByteArray = LocalFrameCommandCodec.encode(frame)
var decoded: LocalFrameCommandSet = LocalFrameCommandCodec.decode(encoded)
var buffer := LocalFrameInputBuffer.new()
_assert(buffer.submit(decoded), "同格式解码命令必须可提交 LocalFrameInputBuffer")
_assert(buffer.has_complete_frame(decoded.tick), "完整启用槽位命令必须放行")
_assert(world.step(decoded.tick, buffer.take(decoded.tick)), "SimulationWorld 只消费缓冲输出")
```

再执行源码边界扫描：

```bash
if rg -n "WebSocket|ENet|WebRTC|MultiplayerSynchronizer|PacketPeer|StreamPeer|Transport|rollback|prediction" scripts/simulation scripts/gameplay tools/qualification; then
  echo "unexpected network or transport implementation"
  exit 1
fi
```

预期：`rg` 没有输出，`if` 条件因无匹配返回 false，整个命令块以 0 退出；任何命中都会显式 `exit 1`。文档中的“未来 Transport”文字不参与该源码目录扫描。`SimulationWorld`、表现桥和 frame codec 不因未来接缝增加参数。

- [ ] **Step 7：写发布资格记录与稳定周期规则**

`docs/frame-sync-release-qualification.md` 必须记录以下固定内容与实际报告路径：

```markdown
# Frame Sync Release Qualification

- Qualification tapes: single_100k, local_2p_100k, local_4p_100k
- Tick count: 100000 each
- Checkpoints: 100 each, ticks 999 through 99999
- Platforms: macOS, Windows, Web/WASM, Android ARM64
- Cadences: headless, 30, 60, 120, jitter/drop
- Minimum-target gate: 100 and 150 zombies, P95 < 8 ms, no 3 consecutive 300-tick P99 windows > 16 ms
- Default runtime after gate: FRAME_SYNC
- Legacy fallback: --legacy-demo
- Legacy retention: at least one stable release after the default switch
- Future transport seam: decode LocalFrameCommandSet, then call LocalFrameInputBuffer.submit(); no transport is implemented here
```

同文档附上四份 deterministic report、最低目标 performance report 和 release gate stdout 的实际相对路径；不得复制完整 JSON 到文档造成双重事实来源。

- [ ] **Step 8：执行最终回归与人工验收**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://scripts/simulation/testing/determinism_test_runner.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_qualification.gd -- --full --cadence-full
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_performance_gate.gd -- --all-tiers
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/qualification/verify_frame_sync_release_gate.gd -- docs/superpowers/qualification/2026-08-08
```

预期：全部以 0 退出。随后人工执行：

1. 普通构建从主菜单进入单人，确认进入 `FrameSyncDemoArena`，键盘、手柄、触控均可用。
2. 本地大厅加入 2 人和 4 人，确认共享屏幕、设备断开暂停/恢复、队伍范围、倒地排除均正常。
3. 在 100～150 只僵尸压力场景确认移动、攻击、死亡、拾取、放置、爆炸链、波次、失败和重开完整可玩。
4. 用 `--legacy-demo` 启动，确认旧 DemoArena 仍可进入且与新路径不混用玩法判定。
5. 改变窗口尺寸、刷新率和渲染限制，确认玩家世界位置与最终录像 Hash 不改变。

人工验收需要截图或短视频时由用户操作并提供，不使用 CUA 做全自动验证。

## 自检

- [ ] SPEC coverage：Task 1 覆盖固定单人/2 人/4 人各 100,000 Tick、逐 Tick双实例、输入录像、SHA-256、首分歧 artifact；Task 2 覆盖 Headless/渲染节奏和 macOS/Windows/Web-WASM/Android ARM64 checkpoint；Task 3 覆盖 100/150/256/512 档和最低目标门槛；Task 4 覆盖资格后默认切换、旧路径稳定周期与未来 buffer 注入接缝。
- [ ] Placeholder scan：全文不含待定实现、模糊“补错误处理”、无代码的“写测试”或引用未定义 API；SPEC 未指定的真实最低设备型号通过 artifact 强制记录，不虚构型号。
- [ ] Type consistency：统一使用 `QualificationProfile`、`DeterminismQualificationRunner.run_profile()`、`LocalFrameInputBuffer.submit()`、`SimulationWorld.step()`、`StateHasher.hash_canonical()`、`BattleRuntimeSelector.default_runtime()`；checkpoint tick 固定为 999～99999。
- [ ] Integer primitive scan：资格 GDScript 的模拟/调度整数计算不直接使用 `/`；percentile rank 使用 `FixedMath.floor_div()`，渲染 cadence 使用预写 alpha 表且不参与模拟 Tick 计算。
- [ ] Negative search scan：所有“期望无匹配”的 `rg` 命令都用 shell `if rg ...; then exit 1; fi` 显式反转退出语义；用于提取 Android JSON 的正向 `rg` 仍要求必须匹配。
- [ ] Scope：只做资格、诊断、性能和整局默认切换；没有网络、Transport、回滚、权限或状态纠正实现，没有删除旧 DemoArena。
- [ ] 提交边界：计划中没有暂存或提交执行命令；最终由用户自行提交。
