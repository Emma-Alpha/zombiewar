# Demo 跨端波次控制与自动刷新 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 DemoArena 增加桌面与移动 H5 共用的「刷新僵尸」「重新开始」按钮，并在清场 1.5 秒后自动从四个角落刷新下一波。

**Architecture:** 两个跨端按钮直接属于 `DemoArena/HUD`，使用 Godot `Button.pressed` 同时承接鼠标与触摸，现有 T/R 快捷键继续保留。按钮和快捷键统一调用 `DemoArena.request_spawn_wave() -> int` 与 `DemoArena.request_restart() -> void`；清场逻辑由一次性 `AutoWaveTimer` 调用同一波次入口，避免平台分支和重复刷新。

**Tech Stack:** Godot 4.7.1、GDScript、Godot Control/Button/Timer、现有 RefCounted 自定义 headless 测试运行器。

## Global Constraints

- 在隔离 worktree 中执行本计划。
- 本计划共 2 个 task；按用户要求，每个 task 完成测试和审查后单独提交。
- 使用 TDD：先写断言并确认 RED，再实现最小代码并确认 GREEN。
- `SpawnWaveButton` 与 `RestartButton` 属于公共 `HUD`，桌面和移动端位置一致，不放入会在桌面隐藏的 `MobileControls`。
- `SpawnWaveButton` 位于右上角波次信息下方，最小尺寸 176×56 像素；玩家存活时显示，死亡后隐藏。
- `RestartButton` 位于中央死亡信息下方，最小尺寸 240×72 像素；玩家存活时隐藏，死亡后显示。
- 鼠标点击与移动触摸使用 Godot `Button.pressed`，不建设平台判断分支。
- T 与刷新按钮统一调用 `request_spawn_wave() -> int`；R 与重开按钮统一调用 `request_restart() -> void`。
- 玩家存活时 R/重开无效；玩家死亡时 T/刷新无效。
- 僵尸清空后等待 1.5 秒自动刷新；等待期间手动刷新会取消计时并只生成一波。
- 手动和自动波次都继续使用现有四角每角随机 1～2 只、最小间距 1.1 米、感知范围 60 米和场上最多 24 只的规则。
- 不新增波次难度成长、倒计时数字、奖励、胜利条件、通用 WaveManager 或对象池。
- 使用 GDScript tab 缩进，保持 `.tscn` 与现有 Godot 文本场景格式一致。

---

## 文件职责映射

- `scripts/gameplay/demo_arena.gd`：统一按钮/快捷键命令入口，维护按钮可见性、重开防重状态和自动波次计时状态。
- `scenes/gameplay/DemoArena.tscn`：增加跨端 Button、中文字体和 `AutoWaveTimer`，定义固定锚点与触控尺寸。
- `tests/integration/test_demo_scene.gd`：锁定公共 HUD 节点、尺寸、字体、初始状态及移动控制层隔离契约。
- `tests/integration/test_demo_wave_controls.gd`：验证快捷键、按钮、死亡状态门槛、自动刷新、手动抢先刷新及死亡取消计时。

---

### Task 1: 跨端 HUD 按钮与统一命令入口

**Files:**

- Modify: `scripts/gameplay/demo_arena.gd:26-101,169-177`
- Modify: `scenes/gameplay/DemoArena.tscn:1-20,199-311`
- Modify: `tests/integration/test_demo_scene.gd:20-57,155-220,240-257`
- Modify: `tests/integration/test_demo_wave_controls.gd:15-101`

**Interfaces:**

- Consumes: 现有 `spawn_wave() -> int`、`restart_requested`、`_reload_current_scene()`、InputMap `spawn_wave`/`restart_demo`。
- Produces: `request_spawn_wave() -> int`、`request_restart() -> void`、`restart_pending: bool`、`_sync_command_controls() -> void`。
- Produces scene nodes: `HUD/SpawnWaveButton: Button`、`HUD/RestartButton: Button`。
- Task 2 将扩展 `request_spawn_wave()` 以取消待执行自动波次，并让 `_on_player_died()` 同步取消计时。

- [ ] **Step 1: 写公共 HUD 按钮的失败场景断言**

在 `tests/integration/test_demo_scene.gd` 的节点读取区加入：

```gdscript
	var spawn_wave_button := arena.get_node_or_null("HUD/SpawnWaveButton") as Button
	var restart_button := arena.get_node_or_null("HUD/RestartButton") as Button
```

在移动控制断言之后加入公共 HUD 契约：

```gdscript
	_append(failures, Assertions.expect_true(
		spawn_wave_button != null and
		spawn_wave_button.get_parent() == arena.get_node_or_null("HUD") and
		spawn_wave_button.size.x >= 176.0 and
		spawn_wave_button.size.y >= 56.0 and
		spawn_wave_button.visible,
		"Demo exposes a live cross-platform spawn-wave button"
	))
	_append(failures, Assertions.expect_true(
		restart_button != null and
		restart_button.get_parent() == arena.get_node_or_null("HUD") and
		restart_button.size.x >= 240.0 and
		restart_button.size.y >= 72.0 and
		not restart_button.visible,
		"Demo keeps the centered restart button hidden while alive"
	))
	for command_button in [spawn_wave_button, restart_button]:
		var button := command_button as Button
		_append(failures, Assertions.expect_true(
			button != null and button.get_theme_font(&"font") != null,
			"Cross-platform command button has the Chinese UI font"
		))
		if button == null or button.get_theme_font(&"font") == null:
			continue
		for glyph in button.text:
			_append(failures, Assertions.expect_true(
				button.get_theme_font(&"font").has_char(glyph.unicode_at(0)),
				"Command button font includes glyph %s" % glyph
			))
```

这组断言必须验证按钮在桌面环境下仍存在并按玩家状态显示，不能读取 `MobileControls.visible` 作为按钮可见条件。

- [ ] **Step 2: 写按钮与快捷键共用状态门槛的失败测试**

在 `tests/integration/test_demo_wave_controls.gd` 获取按钮：

```gdscript
	var spawn_wave_button := arena.get_node_or_null("HUD/SpawnWaveButton") as Button
	var restart_button := arena.get_node_or_null("HUD/RestartButton") as Button
```

把现有 T 追加波次断言扩展为先测按钮、再测快捷键：

```gdscript
	var before_button := int(arena.call("get_active_zombie_count"))
	if spawn_wave_button != null:
		spawn_wave_button.pressed.emit()
	var after_button := int(arena.call("get_active_zombie_count"))
	_append(failures, Assertions.expect_true(
		after_button > before_button,
		"Spawn-wave button appends a wave while alive"
	))

	var before_t := after_button
	arena.call("_unhandled_input", _pressed_action(&"spawn_wave"))
	_append(failures, Assertions.expect_true(
		int(arena.call("get_active_zombie_count")) > before_t,
		"T uses the same live wave request"
	))
```

玩家死亡后增加按钮状态与重开测试：

```gdscript
	_append(failures, Assertions.expect_true(
		spawn_wave_button != null and not spawn_wave_button.visible and
		restart_button != null and restart_button.visible,
		"Death swaps the spawn command for the centered restart command"
	))

	var defeated_count := int(arena.call("get_active_zombie_count"))
	if spawn_wave_button != null:
		spawn_wave_button.pressed.emit()
	_append(failures, Assertions.expect_equal(
		int(arena.call("get_active_zombie_count")),
		defeated_count,
		"Spawn-wave button is ignored after player death"
	))

	if restart_button != null:
		restart_button.pressed.emit()
	_append(failures, Assertions.expect_equal(
		restart_emissions[0],
		1,
		"Dead-player restart button requests one scene reload"
	))
	arena.call("_unhandled_input", _pressed_action(&"restart_demo"))
	_append(failures, Assertions.expect_equal(
		restart_emissions[0],
		1,
		"Restart pending blocks duplicate button or R requests"
	))
```

更新死亡文案断言为 `game_over.text == "PLAYER DOWN"`，因为跨端按钮承担主要重开提示。

- [ ] **Step 3: 运行完整测试确认新 UI 和接口尚不存在**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: FAIL；`test_demo_scene.gd` 报告缺少两个公共 HUD 按钮，`test_demo_wave_controls.gd` 报告按钮无法追加波次及死亡状态未切换按钮。不得出现 GDScript 解析错误。

- [ ] **Step 4: 在 DemoArena 场景增加跨端按钮**

在 `scenes/gameplay/DemoArena.tscn` 增加中文字体和三种共享按钮样式：

```ini
[ext_resource type="FontFile" path="res://assets/fonts/NotoSansSC-UI.ttf" id="10_cjk_font"]

[sub_resource type="StyleBoxFlat" id="StyleBoxFlat_command_normal"]
bg_color = Color(0.0627451, 0.0784314, 0.0980392, 0.9)
border_width_left = 2
border_width_top = 2
border_width_right = 2
border_width_bottom = 2
border_color = Color(1, 0.72, 0.12, 0.9)
corner_radius_top_left = 10
corner_radius_top_right = 10
corner_radius_bottom_right = 10
corner_radius_bottom_left = 10

[sub_resource type="StyleBoxFlat" id="StyleBoxFlat_command_hover"]
bg_color = Color(0.22, 0.14, 0.06, 0.96)
border_width_left = 2
border_width_top = 2
border_width_right = 2
border_width_bottom = 2
border_color = Color(1, 0.82, 0.34, 1)
corner_radius_top_left = 10
corner_radius_top_right = 10
corner_radius_bottom_right = 10
corner_radius_bottom_left = 10

[sub_resource type="StyleBoxFlat" id="StyleBoxFlat_command_pressed"]
bg_color = Color(0.72, 0.18, 0.08, 0.98)
border_width_left = 2
border_width_top = 2
border_width_right = 2
border_width_bottom = 2
border_color = Color(1, 0.9, 0.55, 1)
corner_radius_top_left = 10
corner_radius_top_right = 10
corner_radius_bottom_right = 10
corner_radius_bottom_left = 10
```

按钮使用以下节点契约：

```ini
[node name="SpawnWaveButton" type="Button" parent="HUD"]
anchors_preset = 1
anchor_left = 1.0
anchor_right = 1.0
offset_left = -200.0
offset_top = 92.0
offset_right = -24.0
offset_bottom = 148.0
grow_horizontal = 0
theme_override_fonts/font = ExtResource("10_cjk_font")
theme_override_font_sizes/font_size = 20
theme_override_styles/normal = SubResource("StyleBoxFlat_command_normal")
theme_override_styles/hover = SubResource("StyleBoxFlat_command_hover")
theme_override_styles/pressed = SubResource("StyleBoxFlat_command_pressed")
text = "刷新僵尸"

[node name="RestartButton" type="Button" parent="HUD"]
visible = false
anchors_preset = 8
anchor_left = 0.5
anchor_top = 0.5
anchor_right = 0.5
anchor_bottom = 0.5
offset_left = -120.0
offset_top = 84.0
offset_right = 120.0
offset_bottom = 156.0
grow_horizontal = 2
grow_vertical = 2
theme_override_fonts/font = ExtResource("10_cjk_font")
theme_override_font_sizes/font_size = 24
theme_override_colors/font_color = Color(1, 0.92, 0.72, 1)
theme_override_styles/normal = SubResource("StyleBoxFlat_command_normal")
theme_override_styles/hover = SubResource("StyleBoxFlat_command_hover")
theme_override_styles/pressed = SubResource("StyleBoxFlat_command_pressed")
text = "重新开始"
```

不要把按钮放到 `MobileControls.tscn`。把 `GameOver.text` 改为 `PLAYER DOWN`，并保留其中央锚点。

- [ ] **Step 5: 实现统一按钮/快捷键命令入口**

在 `scripts/gameplay/demo_arena.gd` 增加重开防重状态：

```gdscript
var restart_pending := false
```

让 `_unhandled_input()` 只转发到统一方法：

```gdscript
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).echo:
		return
	if event.is_action_pressed(&"spawn_wave"):
		request_spawn_wave()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"restart_demo"):
		request_restart()
		get_viewport().set_input_as_handled()

func request_spawn_wave() -> int:
	if player_defeated:
		return 0
	return spawn_wave()

func request_restart() -> void:
	if not player_defeated or restart_pending:
		return
	restart_pending = true
	restart_requested.emit()
	call_deferred("_reload_current_scene")
```

在 `_wire_dependencies()` 连接两个 `Button.pressed`，连接前使用 `is_connected()` 防止 `_notification()` 与 `_enter_tree()` 重复接线：

```gdscript
	var spawn_button := get_node_or_null("HUD/SpawnWaveButton") as Button
	if spawn_button != null and not spawn_button.pressed.is_connected(request_spawn_wave):
		spawn_button.pressed.connect(request_spawn_wave)
	var restart_button := get_node_or_null("HUD/RestartButton") as Button
	if restart_button != null and not restart_button.pressed.is_connected(request_restart):
		restart_button.pressed.connect(request_restart)
```

增加统一状态同步并在接线完成、玩家死亡时调用：

```gdscript
func _sync_command_controls() -> void:
	var spawn_button := get_node_or_null("HUD/SpawnWaveButton") as Button
	if spawn_button != null:
		spawn_button.visible = not player_defeated
	var restart_button := get_node_or_null("HUD/RestartButton") as Button
	if restart_button != null:
		restart_button.visible = player_defeated
```

`_on_player_died()` 将中央文案设置为 `PLAYER DOWN`，然后调用 `_sync_command_controls()` 和 `_update_wave_hud()`。

- [ ] **Step 6: 运行解析检查和完整测试确认按钮逻辑 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: exit 0；场景和脚本无解析错误。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: `PASS: 28 test file(s)`。

- [ ] **Step 7: 提交 Task 1**

```bash
git add scripts/gameplay/demo_arena.gd scenes/gameplay/DemoArena.tscn tests/integration/test_demo_scene.gd tests/integration/test_demo_wave_controls.gd
git commit -m "feat: add cross-platform wave controls"
```

---

### Task 2: 清场延迟自动刷新与计时取消

**Files:**

- Modify: `scripts/gameplay/demo_arena.gd:5-13,63-101,169-179,292-329`
- Modify: `scenes/gameplay/DemoArena.tscn:309-311`
- Modify: `tests/integration/test_demo_scene.gd:38-40,248-257`
- Modify: `tests/integration/test_demo_wave_controls.gd:20-101`

**Interfaces:**

- Consumes: Task 1 的 `request_spawn_wave() -> int`、`_sync_command_controls() -> void` 和公共 HUD 按钮。
- Produces: `AUTO_WAVE_STATUS: String`、`_refresh_wave_state_after_target_exit() -> void`、`_schedule_auto_wave_if_empty() -> bool`、`_cancel_auto_wave() -> void`、`_on_auto_wave_timeout() -> void`。
- Produces scene node: `AutoWaveTimer: Timer`，`wait_time = 1.5`、`one_shot = true`。

- [ ] **Step 1: 写自动波次节点和初始状态的失败断言**

在 `tests/integration/test_demo_scene.gd` 获取并断言计时器：

```gdscript
	var auto_wave_timer := arena.get_node_or_null("AutoWaveTimer") as Timer
	_append(failures, Assertions.expect_true(
		auto_wave_timer != null and
		auto_wave_timer.one_shot and
		absf(auto_wave_timer.wait_time - 1.5) <= 0.0001 and
		auto_wave_timer.is_stopped(),
		"Demo owns a stopped 1.5-second one-shot auto-wave timer"
	))
```

- [ ] **Step 2: 写清场、手动抢先与死亡取消的失败测试**

在 `tests/integration/test_demo_wave_controls.gd` 增加独立自动波次测试函数，并由 `run()` 追加其失败结果：

```gdscript
func _append_auto_wave_failures(
	failures: Array[String],
	packed: PackedScene,
	tree: SceneTree
) -> void:
	var arena := packed.instantiate()
	arena.set("random_seed", 20260805)
	tree.root.add_child(arena)
	var timer := arena.get_node_or_null("AutoWaveTimer") as Timer
	var wave_status := arena.get_node_or_null("HUD/WaveStatus") as Label
	var player := arena.get_node_or_null("Player") as PlayerController

	_clear_zombies(arena)
	arena.call("_refresh_wave_state_after_target_exit")
	_append(failures, Assertions.expect_true(
		timer != null and not timer.is_stopped() and
		wave_status != null and wave_status.visible and
		wave_status.text == "下一波即将到来",
		"Clearing the arena schedules one delayed wave"
	))
	_append(failures, Assertions.expect_true(
		not bool(arena.call("_schedule_auto_wave_if_empty")),
		"A running auto-wave timer cannot be scheduled twice"
	))

	var wave_before_manual := int(arena.get("wave_number"))
	arena.call("request_spawn_wave")
	_append(failures, Assertions.expect_true(
		timer != null and timer.is_stopped() and
		wave_status != null and not wave_status.visible and
		int(arena.get("wave_number")) == wave_before_manual + 1,
		"Manual wave skips the delay without leaving a second wave pending"
	))

	_clear_zombies(arena)
	arena.call("_schedule_auto_wave_if_empty")
	if timer != null:
		timer.stop()
	var wave_before_auto := int(arena.get("wave_number"))
	arena.call("_on_auto_wave_timeout")
	_append(failures, Assertions.expect_true(
		int(arena.get("wave_number")) == wave_before_auto + 1 and
		int(arena.call("get_active_zombie_count")) >= 4,
		"Auto-wave timeout creates the next four-corner wave"
	))

	_clear_zombies(arena)
	arena.call("_schedule_auto_wave_if_empty")
	if player != null:
		player.apply_damage(1000.0, Vector3.ZERO)
	var defeated_wave := int(arena.get("wave_number"))
	arena.call("_on_auto_wave_timeout")
	_append(failures, Assertions.expect_true(
		timer != null and timer.is_stopped() and
		int(arena.get("wave_number")) == defeated_wave and
		int(arena.call("get_active_zombie_count")) == 0,
		"Player death cancels and blocks the pending automatic wave"
	))
	arena.free()

func _clear_zombies(arena: Node) -> void:
	var targets := arena.get_node_or_null("World/Targets")
	if targets == null:
		return
	for child in targets.get_children():
		if child is ZombieTarget:
			targets.remove_child(child)
			child.free()
```

在 `run()` 返回前调用：

```gdscript
	_append_auto_wave_failures(failures, packed, tree)
```

- [ ] **Step 3: 运行完整测试确认自动波次尚未实现**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: FAIL；报告缺少 `AutoWaveTimer`、`_schedule_auto_wave_if_empty()` 或清场后未进入等待状态。Task 1 的跨端按钮测试继续通过。

- [ ] **Step 4: 增加 AutoWaveTimer 并连接超时事件**

在 `scenes/gameplay/DemoArena.tscn` 根节点计时器区域加入：

```ini
[node name="AutoWaveTimer" type="Timer" parent="."]
wait_time = 1.5
one_shot = true
```

在 `DemoArena._wire_dependencies()` 中防重复连接：

```gdscript
	var auto_wave_timer := get_node_or_null("AutoWaveTimer") as Timer
	if (
		auto_wave_timer != null and
		not auto_wave_timer.timeout.is_connected(_on_auto_wave_timeout)
	):
		auto_wave_timer.timeout.connect(_on_auto_wave_timeout)
```

- [ ] **Step 5: 实现清场调度、提示和超时刷新**

在 `scripts/gameplay/demo_arena.gd` 增加常量和状态方法：

```gdscript
const AUTO_WAVE_STATUS := "下一波即将到来"

func _on_target_exiting_tree(target: Node) -> void:
	if target is ZombieTarget:
		call_deferred("_refresh_wave_state_after_target_exit")

func _refresh_wave_state_after_target_exit() -> void:
	_update_wave_hud()
	_schedule_auto_wave_if_empty()

func _schedule_auto_wave_if_empty() -> bool:
	if player_defeated or get_active_zombie_count() != 0:
		return false
	var timer := get_node_or_null("AutoWaveTimer") as Timer
	if timer == null or not timer.is_stopped():
		return false
	var status_timer := get_node_or_null("WaveStatusTimer") as Timer
	if status_timer != null:
		status_timer.stop()
	var status := get_node_or_null("HUD/WaveStatus") as Label
	if status != null:
		status.text = AUTO_WAVE_STATUS
		status.visible = true
	timer.start()
	return true

func _on_auto_wave_timeout() -> void:
	if player_defeated or get_active_zombie_count() != 0:
		return
	_hide_wave_status()
	spawn_wave()
```

调度只由目标真正移除后的延迟回调触发；不要在 `_process()` 中轮询活动数量。

- [ ] **Step 6: 让手动刷新和玩家死亡取消待执行自动波次**

把 Task 1 的 `request_spawn_wave()` 扩展为：

```gdscript
func request_spawn_wave() -> int:
	if player_defeated:
		return 0
	_cancel_auto_wave()
	return spawn_wave()
```

新增取消方法，只隐藏属于自动等待的状态文本，不清除 `MAX ZOMBIES` 或配置错误提示：

```gdscript
func _cancel_auto_wave() -> void:
	var timer := get_node_or_null("AutoWaveTimer") as Timer
	if timer != null:
		timer.stop()
	var status := get_node_or_null("HUD/WaveStatus") as Label
	if status != null and status.text == AUTO_WAVE_STATUS:
		status.visible = false
```

在 `_on_player_died()` 设置 `player_defeated = true` 后立即调用 `_cancel_auto_wave()`，再同步按钮和死亡 HUD。这样最后一只僵尸退出与玩家死亡接近同帧时，`player_defeated` 会阻止新的自动计时。

- [ ] **Step 7: 运行解析检查和完整测试确认自动波次 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: exit 0；无场景或脚本解析错误。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: `PASS: 28 test file(s)`。

- [ ] **Step 8: 导出 Web 包验证 H5 资源契约**

Run:

```bash
mkdir -p build/web
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release Web build/web/index.html
```

Expected: exit 0；`build/web/index.html`、`build/web/index.js`、`build/web/index.pck`、`build/web/index.wasm` 均存在，导出日志无 GDScript 解析错误。`build/` 保持 ignored，不加入提交。

- [ ] **Step 9: 提交 Task 2**

```bash
git add scripts/gameplay/demo_arena.gd scenes/gameplay/DemoArena.tscn tests/integration/test_demo_scene.gd tests/integration/test_demo_wave_controls.gd
git commit -m "feat: add delayed automatic zombie waves"
```

---

## 计划完成后的整体审查

- 对 Task 1 与 Task 2 的提交分别执行规格符合性审查和代码质量审查。
- 运行 `git status --short --branch`，确认 worktree 只包含计划勾选或审查修正；审查修正归入对应 task 提交，不创建混合提交。
- 再运行一次 Godot headless 编辑器检查与完整测试套件。
- 检查 `git log --oneline -3`，确认计划提交之后存在两个独立功能提交。
- 由主代理把 worktree 分支合并回 `main`；除非用户再次要求，本计划不自动推送或部署 Cloudflare。
