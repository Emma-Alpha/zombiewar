# 玩家头顶通用血条 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为玩家新增始终可见、穿透场景遮挡的 3D 头顶血条，并移除旧的左上角血量文本。

**Architecture:** 新建只负责显示的 `HealthBar3D` 场景，用两个以着色器渲染的 `QuadMesh` 表示圆角背景和填充。组件不持有 `Health`；`PlayerController` 在已有生命变化路径中同步数值，`DemoArena` 删除旧 HUD 文本绑定。

**Tech Stack:** Godot 4.7.1、GDScript、`Node3D`、`MeshInstance3D`、`QuadMesh`、`ShaderMaterial`、现有 RefCounted 测试运行器。

## Global Constraints

- 只接入玩家；不改 `ZombieTarget`、僵尸 `HealthLabel`、AI、武器、伤害数值或死亡动画。
- 血条始终显示在玩家头顶，尺寸为 `1.1m × 0.10m`，局部位置为 `Vector3(0, 2.35, 0)`。
- 血条无数字、刻度、边框、受伤残影；深色半透明背景，填充左边缘固定且从左向右收缩。
- 比例 `> 0.60` 为绿色；`>= 0.30` 且 `<= 0.60` 为黄色；`< 0.30` 为红色。
- 首次同步无动画；后续变化使用 `0.20` 秒动画；新更新替换旧 Tween。
- 背景与填充必须透明、无光照、相机朝向且关闭深度检测，玩家被场景遮挡时仍可见。
- `current` 必须限制为 `[0.0, maximum]`；`maximum <= 0.0` 时显示空条且不能除零。
- 删除 `HUD/PlayerHealth` 和 `DemoArena` 对它的绑定；保留 `PlayerController.health_changed`、伤害闪红及 `PLAYER DOWN`。
- 只做核心 Smoke Test：组件数值/材质、玩家同步、Demo 死亡提示、无头导入和测试运行器。
- 每个任务在功能分支独立提交；全部任务与最终审查完成后，合并目标分支前压缩为一个计划提交。

---

## 文件结构

- 新建 `scripts/ui/health_bar_3d.gd`：比例、颜色、填充位置与 Tween。
- 新建 `scenes/ui/HealthBar3D.tscn`：`Background`、`Fill` 两个 `MeshInstance3D`。
- 修改 `scenes/player/Player.tscn` 和 `scripts/player/player_controller.gd`：接入和生命值同步。
- 修改 `scenes/gameplay/DemoArena.tscn` 和 `scripts/gameplay/demo_arena.gd`：移除旧文本 HUD。
- 新建 `tests/unit/test_health_bar_3d.gd`，修改 `tests/unit/test_player_damage.gd`、`tests/integration/test_demo_scene.gd`、`tests/test_runner.gd`：核心验证。

### Task 1: `HealthBar3D` 显示组件与组件 Smoke Test

**Files:**

- Create: `scripts/ui/health_bar_3d.gd`
- Create: `scripts/ui/health_bar_3d.gd.uid`
- Create: `scenes/ui/HealthBar3D.tscn`
- Create: `tests/unit/test_health_bar_3d.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**

- Produces: `class_name HealthBar3D`，提供 `set_health(current: float, maximum: float, animate: bool = true) -> void`、`get_target_ratio() -> float`、`static health_ratio(current: float, maximum: float) -> float`、`static color_for_ratio(ratio: float) -> Color`。
- Produces: `HealthBar3D.tscn` 的 `Background`、`Fill` 两个 `MeshInstance3D` 子节点。

- [ ] **Step 1: 写出会失败的组件 Smoke Test**

新建 `tests/unit/test_health_bar_3d.gd`，加载 `HealthBar3D.tscn` 和脚本，使用现有 `Assertions` 写入以下边界断言：

```gdscript
_append(failures, Assertions.expect_float_near(
	HealthBar3D.health_ratio(90.0, 100.0), 0.9, 0.0001,
	"Health bar normalizes health"
))
_append(failures, Assertions.expect_float_near(
	HealthBar3D.health_ratio(-5.0, 100.0), 0.0, 0.0001,
	"Health bar clamps negative health"
))
_append(failures, Assertions.expect_float_near(
	HealthBar3D.health_ratio(200.0, 100.0), 1.0, 0.0001,
	"Health bar clamps health above maximum"
))
_append(failures, Assertions.expect_float_near(
	HealthBar3D.health_ratio(1.0, 0.0), 0.0, 0.0001,
	"Health bar handles invalid maximum"
))
_append(failures, Assertions.expect_equal(
	HealthBar3D.color_for_ratio(0.6001), HealthBar3D.HIGH_HEALTH_COLOR,
	"Health above 60 percent is green"
))
_append(failures, Assertions.expect_equal(
	HealthBar3D.color_for_ratio(0.60), HealthBar3D.MEDIUM_HEALTH_COLOR,
	"Health at 60 percent is yellow"
))
_append(failures, Assertions.expect_equal(
	HealthBar3D.color_for_ratio(0.30), HealthBar3D.MEDIUM_HEALTH_COLOR,
	"Health at 30 percent is yellow"
))
_append(failures, Assertions.expect_equal(
	HealthBar3D.color_for_ratio(0.2999), HealthBar3D.LOW_HEALTH_COLOR,
	"Health below 30 percent is red"
))
```

实例化场景，断言 `Background`、`Fill` 都是 `MeshInstance3D`、没有 `Label`，两份 `material_override` 都是 `ShaderMaterial`，且 shader 代码都包含 `unshaded`、`depth_test_disabled`、`MODELVIEW_MATRIX`。

- [ ] **Step 2: 注册并确认测试失败**

将 `"res://tests/unit/test_health_bar_3d.gd",` 加入 `tests/test_runner.gd` 的 `TEST_PATHS`，然后运行：

```bash
./tests/run_tests.sh
```

预期：因缺少血条场景或脚本失败。

- [ ] **Step 3: 实现组件和血条场景**

创建 `health_bar_3d.gd`，使用下列固定接口和值：

```gdscript
extends Node3D
class_name HealthBar3D

const BAR_WIDTH := 1.10
const TRANSITION_DURATION := 0.20
const HIGH_HEALTH_COLOR := Color("43cf66")
const MEDIUM_HEALTH_COLOR := Color("e5c642")
const LOW_HEALTH_COLOR := Color("e44b46")

@onready var fill: MeshInstance3D = $Fill
var target_ratio := 1.0
var displayed_ratio := 1.0
var fill_tween: Tween

static func health_ratio(current: float, maximum: float) -> float:
	return 0.0 if maximum <= 0.0 else clampf(current / maximum, 0.0, 1.0)

static func color_for_ratio(ratio: float) -> Color:
	if ratio > 0.60:
		return HIGH_HEALTH_COLOR
	if ratio >= 0.30:
		return MEDIUM_HEALTH_COLOR
	return LOW_HEALTH_COLOR
```

实现 `set_health()`：立即以 `health_ratio()` 更新 `target_ratio` 与独立材质的 `tint_color` 参数；若旧 Tween 有效则停止它；无动画时立即执行私有 `_set_displayed_ratio()`，否则以 `tween_method(_set_displayed_ratio, displayed_ratio, target_ratio, TRANSITION_DURATION)` 过渡。私有方法必须设置 `fill.scale.x = ratio`、`fill.position.x = -BAR_WIDTH * 0.5 + BAR_WIDTH * ratio * 0.5`，并在零比例隐藏 `Fill`，保持左边缘固定。

创建 `HealthBar3D.tscn`：根节点挂载脚本；两个 `QuadMesh` 尺寸均为 `Vector2(1.1, 0.10)`；两个节点拥有各自的 `ShaderMaterial`，材质含有深色背景/绿色默认填充的 `tint_color` 和圆角 alpha。每份 shader 至少含有：

```glsl
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled;
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2], MODEL_MATRIX[3]
	);
}
```

`Fill` 在本地 Z 轴前移 `0.001`。不得引入 `Label`、`Control`、`SubViewport`、文本或边框节点。

- [ ] **Step 4: 运行组件 Smoke Test**

运行 `./tests/run_tests.sh`；预期测试运行器输出 `PASS`，新增测试验证数值和材质契约。

- [ ] **Step 5: 自审并提交组件**

运行 `git diff --check`，确认组件不持有或修改 `Health`、填充仅以位置和宽度实现。然后执行：

```bash
git add scripts/ui/health_bar_3d.gd scripts/ui/health_bar_3d.gd.uid scenes/ui/HealthBar3D.tscn tests/unit/test_health_bar_3d.gd tests/test_runner.gd
git commit -m "feat: add reusable 3d health bar"
```

### Task 2: 玩家接入、旧 HUD 清理与端到端 Smoke Test

**Files:**

- Modify: `scenes/player/Player.tscn`
- Modify: `scripts/player/player_controller.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `tests/unit/test_player_damage.gd`
- Modify: `tests/integration/test_demo_scene.gd`

**Interfaces:**

- Consumes: `HealthBar3D.set_health(current, maximum, animate)` 和 `get_target_ratio()`。
- Produces: `Player/HealthBar3D`；Demo 不再有 `HUD/PlayerHealth`；`HUD/GameOver` 保持可用。

- [ ] **Step 1: 写出会失败的接入断言**

在 `test_player_damage.gd` 的玩家加入树后取得 `HealthBar3D`，断言存在和初始 `get_target_ratio() == 1.0`；在现有 10 点伤害后断言目标比例为 `0.9`，致命伤害后为 `0.0`。

在 `test_demo_scene.gd` 将旧 `health_label` 改为 `legacy_health_label` 并断言其为 `null`；取得 `Player/HealthBar3D` 并断言存在；将 `HP 90 / 100` 断言替换为受伤后目标 `0.9`，再断言致命伤害后 `GameOver.visible` 和文字 `PLAYER DOWN` 均保持正确。

- [ ] **Step 2: 运行并确认接入测试失败**

运行 `./tests/run_tests.sh`；预期仅因缺少 `Player/HealthBar3D` 和旧 `HUD/PlayerHealth` 仍存在而失败。

- [ ] **Step 3: 接入玩家并移除 HUD**

在 `Player.tscn` 实例化 `HealthBar3D`：

```ini
[node name="HealthBar3D" parent="." instance=ExtResource("health_bar")]
position = Vector3(0, 2.35, 0)
```

在 `PlayerController` 加入下列状态和函数：

```gdscript
@onready var health_bar: HealthBar3D = get_node_or_null("HealthBar3D") as HealthBar3D
var health_bar_initialized := false
var missing_health_bar_warned := false

func _sync_health_bar(animate: bool) -> void:
	if health_bar == null:
		if not missing_health_bar_warned:
			push_warning("Player is missing HealthBar3D")
			missing_health_bar_warned = true
		return
	if health != null:
		health_bar.set_health(health.current, health.maximum, animate)
```

在 `_ready()` 中紧接 `_ensure_health_initialized()` 后调用 `_sync_health_bar(false)`，再把 `health_bar_initialized` 设为 `true`。在 `_on_health_changed(current, maximum)` 里先保留 `health_changed.emit(current, maximum)`，再调用 `_sync_health_bar(health_bar_initialized)`。不要更改 `apply_damage()`、`_on_depleted()` 或信号签名。

删除 `DemoArena.tscn` 的完整 `HUD/PlayerHealth` 节点；在 `demo_arena.gd` 移除 `health_changed` 连接、初始血量同步和 `_on_player_health_changed()`，保留 `damaged` 闪红和 `died` 游戏结束绑定。

- [ ] **Step 4: 运行核心 Smoke Test**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh
```

预期：无场景/脚本解析错误，测试运行器输出 `PASS`。若无关的既有变更导致失败，只记录失败测试；血条单元与 Demo 集成断言必须通过。

- [ ] **Step 5: 自审并提交接入**

运行 `git diff --check`，确认无僵尸文件变更、`HUD/PlayerHealth` 完全不存在、玩家仍发出生命信号。然后执行：

```bash
git add scenes/player/Player.tscn scripts/player/player_controller.gd scenes/gameplay/DemoArena.tscn scripts/gameplay/demo_arena.gd tests/unit/test_player_damage.gd tests/integration/test_demo_scene.gd
git commit -m "feat: show player health above character"
```

## 最终轻量审查与交付

- [ ] 对分支 diff 仅按 Global Constraints 做审查：组件可复用、只接入玩家、阈值和 `0.20` 秒动画、无深度检测、旧 HUD 删除、伤害/死亡不回归。
- [ ] 重跑无头编辑器导入检查和 `./tests/run_tests.sh`，记录结果。
- [ ] 不做 UI 自动化。人工验证：血条常显、无数字、三段颜色、`0.20` 秒缩短、遮挡穿透、死亡归零且 `PLAYER DOWN` 正常。
- [ ] 合并目标分支前，把本计划实现提交压缩为一个 Conventional Commit；不合并或改写用户其他未提交工作。
