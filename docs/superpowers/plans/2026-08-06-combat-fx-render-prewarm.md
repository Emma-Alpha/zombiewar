# 战斗特效渲染预热 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 在战斗加载遮罩后方自动发现并真实绘制预热战斗特效，使第一发空枪和首次命中不再承担 Shader 与 GPU 粒子首次编译卡顿。

**Architecture:** 新增独立的 `CombatFxPrewarmer`，递归扫描 `res://scenes/fx/` 并只实例化实现统一预热协议的场景。`DemoArena` 先呈现高层加载遮罩，再使用 `RenderingServer.force_draw(false)` 在不交换前台缓冲的情况下提交主世界真实渲染并同步 GPU，随后清理实例、恢复输入、生成首波并淡出遮罩。

**Tech Stack:** Godot 4.7.1、GDScript、GL Compatibility、项目自定义 `RefCounted.run()` 测试框架。

## Global Constraints

- 使用中文计划和项目现有 Godot/GDScript 风格，缩进使用 Tab。
- 只修改 `scripts/`、`scenes/`、`tests/`、`docs/` 与根目录 `AGENTS.md`；不修改 `addons/`。
- 新增特效通过放入 `res://scenes/fx/` 并实现 `warmup_for_render(context)` 与 `finish_render_warmup()` 自动参与预热。
- 预热不得播放音频、发出攻击信号、修改生命值、弹道散布、存档或波次状态。
- TDD 只实现覆盖核心路径的 Smoke Test，不追求覆盖率或为 GPU 时序编写固定毫秒断言。
- GPU 卡顿采用冷启动人工验收，不使用 CUA 自动控制游戏。
- 所有任务和最终 Review 完成后，将本分支提交整理为一个 Conventional Commit。

---

## 文件结构

- Create: `scripts/fx/fx_warmup_context.gd` — 计算活动相机前方的安全预热坐标。
- Create: `scripts/fx/combat_fx_prewarmer.gd` — 自动发现、实例化、绘制等待和清理可预热特效。
- Modify: `scripts/fx/shot_tracer.gd` — 实现曳光预热协议。
- Modify: `scripts/fx/muzzle_flash.gd` — 实现枪口火焰预热协议。
- Modify: `scripts/fx/blood_impact.gd` — 实现血液 Sprite 与 GPU 粒子预热协议。
- Modify: `scripts/fx/ground_blood_splat.gd` — 实现受光地面血迹材质预热协议。
- Modify: `scripts/gameplay/demo_arena.gd` — 增加加载阶段、输入门禁和首波延后逻辑。
- Modify: `scenes/gameplay/DemoArena.tscn` — 挂载预热器并增加默认可见的高层加载遮罩。
- Create: `tests/integration/test_combat_fx_prewarm.gd` — 单一核心 Smoke Test。
- Modify: `tests/test_runner.gd` — 注册 Smoke Test。
- Modify: `AGENTS.md` — 记录后续战斗特效预热约定。

### Task 1: 建立失败的预热 Smoke Test

**Files:**
- Create: `tests/integration/test_combat_fx_prewarm.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: 项目现有 `Assertions` 与 `RefCounted.run() -> Array[String]` 测试契约。
- Produces: 对 `CombatFxPrewarmer.discover_warmup_scene_paths()`、特效预热协议和 `DemoArena` 加载节点的核心约束。

- [x] **Step 1: 写入失败的 Smoke Test**

创建测试，使用动态 `load()`，保证生产脚本尚不存在时测试以断言失败而不是解析失败：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PREWARMER_PATH := "res://scripts/fx/combat_fx_prewarmer.gd"
const ARENA_PATH := "res://scenes/gameplay/DemoArena.tscn"
const EXPECTED_FX_PATHS: Array[String] = [
	"res://scenes/fx/BloodImpact.tscn",
	"res://scenes/fx/GroundBloodSplat.tscn",
	"res://scenes/fx/MuzzleFlash.tscn",
	"res://scenes/fx/ShotTracer.tscn",
]

func run() -> Array[String]:
	var failures: Array[String] = []
	var prewarmer_script := load(PREWARMER_PATH) as Script
	_append(failures, Assertions.expect_true(
		prewarmer_script != null,
		"Combat FX prewarmer script loads"
	))
	if prewarmer_script == null:
		return failures

	var prewarmer := prewarmer_script.new()
	var discovered: Array[String] = prewarmer.discover_warmup_scene_paths()
	for expected_path in EXPECTED_FX_PATHS:
		_append(failures, Assertions.expect_true(
			expected_path in discovered,
			"Combat FX prewarmer discovers %s" % expected_path
		))
		var packed := load(expected_path) as PackedScene
		var effect := packed.instantiate() if packed != null else null
		_append(failures, Assertions.expect_true(
			effect != null and
				effect.has_method("warmup_for_render") and
				effect.has_method("finish_render_warmup"),
			"Warmable FX exposes the shared lifecycle: %s" % expected_path
		))
		if effect != null:
			effect.free()
	prewarmer.free()

	var arena_packed := load(ARENA_PATH) as PackedScene
	var arena := arena_packed.instantiate() if arena_packed != null else null
	_append(failures, Assertions.expect_true(
		arena != null and
			arena.get_node_or_null("CombatFxPrewarmer") != null and
			arena.get_node_or_null("WarmupLayer/Overlay") is ColorRect,
		"Demo arena owns the combat FX prewarmer and loading overlay"
	))
	if arena != null:
		var layer := arena.get_node_or_null("WarmupLayer") as CanvasLayer
		var overlay := arena.get_node_or_null("WarmupLayer/Overlay") as ColorRect
		_append(failures, Assertions.expect_true(
			layer != null and layer.layer >= 100 and
				overlay != null and overlay.visible and overlay.color.a >= 0.99,
			"Warmup overlay is opaque and above gameplay UI by default"
		))
		arena.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

将 `res://tests/integration/test_combat_fx_prewarm.gd` 注册到 `TEST_PATHS`。

- [x] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，至少包含 `Combat FX prewarmer script loads`；失败原因必须是预热功能尚不存在，而不是测试语法错误。

- [x] **Step 3: 保存 RED 检查点**

Run: `git diff --check && git status --short`

Expected: 只有 Smoke Test 与 `tests/test_runner.gd` 的预期修改，无格式错误。

### Task 2: 实现自动发现器与统一预热协议

**Files:**
- Create: `scripts/fx/fx_warmup_context.gd`
- Create: `scripts/fx/combat_fx_prewarmer.gd`
- Modify: `scripts/fx/shot_tracer.gd`
- Modify: `scripts/fx/muzzle_flash.gd`
- Modify: `scripts/fx/blood_impact.gd`
- Modify: `scripts/fx/ground_blood_splat.gd`

**Interfaces:**
- Consumes: `Camera3D.global_basis`、`DirAccess`、`PackedScene`、`RenderingServer.force_draw(false)` 和 `RenderingServer.force_sync()`。
- Produces:
  - `FxWarmupContext.new(camera: Camera3D, host: Node3D)`
  - `FxWarmupContext.position_in_view(distance: float, offset: Vector2 = Vector2.ZERO) -> Vector3`
  - `CombatFxPrewarmer.discover_warmup_scene_paths(root_path: String = "res://scenes/fx") -> Array[String]`
  - `CombatFxPrewarmer.prewarm(camera: Camera3D) -> void`
  - 特效方法 `warmup_for_render(context: FxWarmupContext) -> void`
  - 特效方法 `finish_render_warmup() -> void`

- [x] **Step 1: 实现预热上下文**

```gdscript
extends RefCounted
class_name FxWarmupContext

var camera: Camera3D
var host: Node3D

func _init(value_camera: Camera3D, value_host: Node3D) -> void:
	camera = value_camera
	host = value_host

func position_in_view(
	distance: float,
	offset: Vector2 = Vector2.ZERO
) -> Vector3:
	var forward := -camera.global_basis.z.normalized()
	var right := camera.global_basis.x.normalized()
	var up := camera.global_basis.y.normalized()
	return (
		camera.global_position +
		forward * maxf(distance, 0.1) +
		right * offset.x +
		up * offset.y
	)
```

- [x] **Step 2: 实现自动发现与渲染等待**

`CombatFxPrewarmer` 使用 `DEFAULT_FX_ROOT := "res://scenes/fx"` 递归枚举 `.tscn`。每个候选场景在离树状态实例化，只有同时实现两个协议方法才返回；结果排序，保证测试和日志稳定。

预热流程：

```gdscript
func prewarm(camera: Camera3D) -> void:
	if camera == null:
		push_warning("Combat FX prewarm skipped: active camera missing")
		return
	var host := Node3D.new()
	host.name = "ActiveWarmupFx"
	add_child(host)
	var context := FxWarmupContext.new(camera, host)
	var active: Array[Node] = []
	for scene_path in discover_warmup_scene_paths():
		var packed := load(scene_path) as PackedScene
		if packed == null:
			push_warning("Unable to load warmup FX: %s" % scene_path)
			continue
		var effect := packed.instantiate()
		host.add_child(effect)
		effect.call("warmup_for_render", context)
		active.append(effect)
	RenderingServer.force_draw(false, 0.0)
	RenderingServer.force_sync()
	for effect in active:
		if is_instance_valid(effect):
			effect.call("finish_render_warmup")
	host.free()
```

- [x] **Step 3: 为现有四个特效实现协议**

`ShotTracer`：使用上下文中两段相机前方坐标调用真实 `setup()`，结束时调用 `deactivate()`。

`MuzzleFlash`：移动到相机前方后调用真实 `flash()`，结束时强制隐藏并停止处理。

`BloodImpact`：在相机前方调用真实 `setup()` 启动 Sprite 与 `GPUParticles3D`，预热期间停止生命周期倒计时，结束时停止粒子、隐藏节点并停止处理。

`GroundBloodSplat`：复用场景默认纹理调用真实 `setup()`，在主世界光照条件下编译与实战一致的 StandardMaterial3D 变体，结束时隐藏节点。

- [x] **Step 4: 运行 Smoke Test 检查核心协议已 GREEN**

Run: `./tests/run_tests.sh`

Expected: 原先关于脚本加载、自动发现和四个特效协议的失败消失；测试仍可能只因 `DemoArena` 尚未增加预热节点和遮罩而失败。

- [x] **Step 5: 运行解析检查**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`

Expected: exit 0，无新增脚本解析错误。

### Task 3: 接入战斗加载流程与遮罩

**Files:**
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`

**Interfaces:**
- Consumes:
  - `CombatFxPrewarmer.prewarm(camera: Camera3D) -> void`
  - `MobileControls.cancel_all_input() -> void`
- Produces:
  - `startup_pending: bool`
  - `_run_combat_startup() -> void`
  - `_complete_combat_startup() -> void`

- [x] **Step 1: 在场景中挂载预热器和默认可见遮罩**

在 `DemoArena.tscn` 增加预热器脚本外部资源和节点：

```text
[node name="CombatFxPrewarmer" type="Node3D" parent="."]
script = ExtResource("combat_fx_prewarmer")

[node name="WarmupLayer" type="CanvasLayer" parent="."]
layer = 100

[node name="Overlay" type="ColorRect" parent="WarmupLayer"]
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
mouse_filter = 0
color = Color(0.025, 0.031, 0.04, 1)

[node name="Label" type="Label" parent="WarmupLayer/Overlay"]
anchors_preset = 8
anchor_left = 0.5
anchor_top = 0.5
anchor_right = 0.5
anchor_bottom = 0.5
offset_left = -180.0
offset_top = -24.0
offset_right = 180.0
offset_bottom = 24.0
theme_override_fonts/font = ExtResource("10_cjk_font")
theme_override_font_sizes/font_size = 24
text = "正在准备战斗…"
horizontal_alignment = 1
vertical_alignment = 1
```

- [x] **Step 2: 将立即刷怪改为受控启动流程**

`_ready()` 只初始化随机数和启动状态。图形环境中暂停玩家物理处理，延迟调用 `_run_combat_startup()`；Headless 环境直接调用 `_complete_combat_startup()`，保持现有同步场景测试稳定。

```gdscript
func _ready() -> void:
	_initialize_wave_rng()
	startup_pending = true
	if DisplayServer.get_name() == "headless":
		_complete_combat_startup()
		return
	var player := get_node_or_null("Player") as PlayerController
	if player != null:
		player.set_physics_process(false)
	call_deferred("_run_combat_startup")
```

`_run_combat_startup()` 先等待两个进程帧让遮罩呈现，再临时隐藏遮罩节点，执行不交换前台缓冲的同步预热，并在下一次正常绘制前恢复遮罩；无论预热器或相机缺失，都调用完成入口：

```gdscript
func _run_combat_startup() -> void:
	var prewarmer := get_node_or_null("CombatFxPrewarmer") as CombatFxPrewarmer
	var camera := get_node_or_null("FollowCamera/Camera3D") as Camera3D
	var warmup_layer := get_node_or_null("WarmupLayer") as CanvasLayer
	if prewarmer != null:
		await get_tree().process_frame
		await get_tree().process_frame
		if warmup_layer != null:
			warmup_layer.hide()
		prewarmer.prewarm(camera)
		if warmup_layer != null:
			warmup_layer.show()
	_complete_combat_startup()
```

- [x] **Step 3: 恢复玩法并淡出遮罩**

完成入口必须幂等：取消移动端残留输入，释放移动、跳跃、开火和换武器 InputMap 状态，恢复玩家物理处理，生成第一波，将 `startup_pending` 设为 `false`，最后淡出遮罩。

`_unhandled_input()` 和 `request_spawn_wave()` 在 `startup_pending` 时直接返回，阻止加载阶段手动刷怪或重启。

- [x] **Step 4: 运行 Smoke Test 并确认完整 GREEN**

Run: `./tests/run_tests.sh`

Expected: PASS，包含新注册的预热 Smoke Test，现有 DemoArena 波次测试继续通过。

- [x] **Step 5: 运行 Headless Editor 检查**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`

Expected: exit 0，无场景资源或脚本解析错误。

### Task 4: 更新后续特效开发约定

**Files:**
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: Task 2 实现的预热协议和自动扫描目录。
- Produces: 后续 Codex 开发战斗特效时可见的仓库级约束。

- [x] **Step 1: 增加战斗特效预热章节**

在测试章节前加入：

```markdown
## Combat FX Render Warmup

Place new runtime combat VFX scenes that use meshes, custom shaders, GPU particles, or first-use animations under `scenes/fx/`. If the effect can appear during gameplay, its root script must implement `warmup_for_render(context)` and `finish_render_warmup()` so `CombatFxPrewarmer` discovers it automatically.

Warmup methods may only activate visual rendering. They must not play audio, deal damage, emit gameplay attack signals, consume input, mutate weapon spread, write saves, or depend on a live target. `finish_render_warmup()` must be safe to call during cleanup and restore the effect to an inactive state. Add or update the combat FX smoke test when introducing a new warmable effect.
```

- [x] **Step 2: 运行文档和差异检查**

Run: `git diff --check && rg -n "warmup_for_render|finish_render_warmup|CombatFxPrewarmer" AGENTS.md scripts/fx tests/integration/test_combat_fx_prewarm.gd`

Expected: 无空白错误，约定、实现与测试使用完全一致的方法名。

### Task 5: Review、冷启动验证与单一提交

**Files:**
- Review: 本计划列出的全部修改文件。
- Update if needed: 只修复 Review 或验证发现的同范围问题。

**Interfaces:**
- Consumes: 完整预热启动流程。
- Produces: 通过自动验证、待用户完成视觉验收的单一计划 Commit。

- [x] **Step 1: 运行完整自动验证**

Run: `./tests/run_tests.sh`

Expected: PASS，Godot 输出无新增 ERROR 或脚本 WARNING。

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`

Expected: exit 0。

- [x] **Step 2: 源码 Review**

检查以下事项：

- 扫描器只遍历 `res://scenes/fx/`，结果稳定排序。
- 未实现协议的场景不会进入场景树。
- 预热实例始终清理，强制绘制使用 `swap_buffers=false`。
- 加载遮罩先呈现，预热期间前台始终保留不透明加载画面。
- Headless 测试路径不会异步悬挂。
- 预热未调用武器 `_fire()`、僵尸 `apply_hit()` 或音频 `play()`。
- `AGENTS.md` 与实现接口名称一致。

- [x] **Step 3: 执行冷启动人工验收准备**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --path .`

人工操作：从主菜单进入战斗，等待“正在准备战斗…”消失后立即空枪开火，再首次命中僵尸。确认两个动作都没有整画面冻结。若需要客观数据，使用此前同类冷启动探针记录首发渲染同步耗时，但不将探针提交到仓库。

- [x] **Step 4: 整理为一个计划 Commit**

先确认目标基线：

Run: `git merge-base main HEAD && git log --oneline main..HEAD && git status --short`

在所有修改已验证且仅包含本功能时，将设计、计划、测试、实现和 `AGENTS.md` 整理为相对 `main` 的单一提交，提交信息：

```text
feat: prewarm combat fx rendering
```

- [x] **Step 5: 最终状态检查**

Run: `git status --short && git log --oneline main..HEAD`

Expected: 工作区干净，`main..HEAD` 只有一个 `feat: prewarm combat fx rendering` 提交。
