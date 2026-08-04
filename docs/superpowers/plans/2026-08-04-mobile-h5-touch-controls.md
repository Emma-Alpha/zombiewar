# 移动 H5 触控操作 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Zombie War 的 Godot 4.7.1 Web 版本提供与既有键盘 InputMap 共用的移动端触控移动、跳跃和持续开火操作。

**Architecture:** `MobileControls.tscn` 采用 Godot 4.7.1 官方原生 `VirtualJoystick`，直接驱动四个既有移动动作；项目自有 `MobileActionButton` 分别管理 `fire` 和 `jump` 的 touch ID。`MobileControls` 只负责物理触屏可用性、显示切换、桌面帮助提示和取消输入，`PlayerController` 与武器系统继续仅消费 InputMap。

**Tech Stack:** Godot 4.7.1、GDScript、Godot InputMap、原生 `VirtualJoystick`、`InputEventScreenTouch` / `InputEventScreenDrag`、Godot Web 导出。

## Global Constraints

- 保持 Godot 4.7.1、GL Compatibility、1280×720 逻辑视口、`canvas_items` 与 `aspect="expand"`。
- 保持动作名 `move_left`、`move_right`、`move_forward`、`move_back`、`jump`、`fire`；W/A/S/D、Space、J 继续可用。
- 保留 `project.godot` 的 `input_devices/pointing/emulate_touch_from_mouse=true` 供编辑器调试；物理探测只临时关闭项目设置和运行时模拟，并分别恢复原值。
- 移动必须使用官方 `VirtualJoystick`；项目只拥有 `MobileActionButton` 和 `MobileControls` 两类触控脚本，不新增第三方依赖或第二套移动/战斗逻辑。
- 中文动作按钮使用 `assets/fonts/NotoSansSC-UI.ttf`，不依赖系统字体回退。
- 只通过实际导出的 `build/web/index.html` 验证 Web 防手势 CSS；不以导出配置文本代替产物验证。
- 不修改或 reload Nginx，不创建 worktree；共享脏工作区只允许逐 hunk/patch 暂存，暂存后必须审查 `git diff --cached`。
- 不修改 `tests/integration/test_demo_scene.gd` 中 `Player/Weapon/AimIndicator` 的武器任务内容。

---

## 文件结构

- `scenes/ui/MobileControls.tscn`：触控层布局、官方摇杆、两个动作按钮及嵌入中文字体。
- `scripts/ui/mobile_action_button.gd`：一个按钮对应一个 action 和一个活动 touch ID。
- `scripts/ui/mobile_controls.gd`：物理触屏探测、触控模式、桌面帮助切换及失焦取消。
- `scenes/gameplay/DemoArena.tscn`：将触控层接入实际游戏场景，并将桌面帮助路径传给协调器。
- `tests/unit/test_mobile_touch_controls.gd`：输入动作、真实场景、原始触控事件、状态恢复和取消行为回归。
- `tests/integration/test_demo_scene.gd`：验证实际场景的官方摇杆映射、按钮尺寸、字体和帮助面板关联。
- `project.godot` / `export_presets.cfg`：鼠标模拟触控和 Web 页面头部 CSS。
- `docs/superpowers/plans/2026-08-04-mobile-h5-touch-controls.md`：本计划；`.superpowers/sdd/2026-08-04-mobile-h5-touch-controls/final-fix-report.md`：实测报告。

### Task 1: 官方摇杆、InputMap 与场景布局

**Files:**

- Modify: `scenes/ui/MobileControls.tscn`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `scripts/player/player_controller.gd`
- Modify: `project.godot`
- Test: `tests/unit/test_mobile_touch_controls.gd`
- Test: `tests/integration/test_demo_scene.gd`

**Interfaces:**

- Consumes: `VirtualJoystick.action_left`、`action_right`、`action_up`、`action_down`、`deadzone_ratio` 和既有六个 InputMap 动作。
- Produces: `MobileControls/Layout/VirtualJoystick`，其中 `move_left`、`move_right`、`move_forward`、`move_back` 分别映射到左、右、上、下。
- Produces: `PlayerController.get_move_input_vector() -> Vector2`，以 `move_input_deadzone = 0.0` 读取已经由官方摇杆处理死区的模拟量。

- [x] **Step 1: 写入官方摇杆与玩家模拟量的回归断言**

  在 `tests/unit/test_mobile_touch_controls.gd` 以真实 `Input` 断言 0.75 右、0.40 前进能原样传给玩家：

  ```gdscript
  Input.action_press(&"move_right", 0.75)
  Input.action_press(&"move_forward", 0.40)
  var resolved_input: Vector2 = player.get_move_input_vector()
  _append(failures, Assertions.expect_true(
      resolved_input.distance_to(Vector2(0.75, -0.40)) <= 0.0001,
      "Player does not apply the InputMap 0.5 deadzone twice"
  ))
  ```

  在 `tests/integration/test_demo_scene.gd` 断言摇杆类、节点路径、四个动作映射、`joystick_size >= 144.0` 和 `deadzone_ratio == 0.15`。

- [x] **Step 2: 运行回归以确认断言能加载实际场景**

  Run:

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
  ```

  Expected: `PASS: 23 test file(s)`；实施前若官方节点或映射缺失，测试报告对应的场景断言失败。

- [x] **Step 3: 在场景中配置官方 `VirtualJoystick`**

  `MobileControls.tscn` 的摇杆节点使用下列配置，并由现有玩家 InputMap 消费其输出：

  ```gdscript
  [node name="VirtualJoystick" type="VirtualJoystick" parent="Layout"]
  joystick_size = 164.0
  deadzone_ratio = 0.15
  clampzone_ratio = 1.0
  action_left = &"move_left"
  action_right = &"move_right"
  action_up = &"move_forward"
  action_down = &"move_back"
  ```

  `project.godot` 保留：

  ```ini
  [input_devices]

  pointing/emulate_touch_from_mouse=true
  ```

- [x] **Step 4: 运行全量测试确认键盘与触控共用 InputMap**

  Run:

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
  ```

  Expected: `PASS: 23 test file(s)`。

### Task 2: 动作按钮、多点触控与协调器取消

**Files:**

- Modify: `scripts/ui/mobile_action_button.gd`
- Modify: `scripts/ui/mobile_controls.gd`
- Modify: `scenes/ui/MobileControls.tscn`
- Test: `tests/unit/test_mobile_touch_controls.gd`

**Interfaces:**

- Consumes: `InputEventScreenTouch.index`、`InputEventScreenTouch.position`、`InputEventScreenDrag.index` 和 `Control.get_global_rect()`。
- Produces: `MobileActionButton.action: StringName`、`active_touch_id: int`、`pressed: bool`、`cancel() -> void`。
- Produces: `MobileControls._cancel_all_input() -> void`，释放四个移动动作、`fire` 与 `jump`，并调用两个按钮的 `cancel()`。

- [x] **Step 1: 写入真实原始触摸事件测试**

  实例化 `MobileControls.tscn` 后加入 `SceneTree`，使用可见按钮真实矩形的中心创建事件；不得以 `set_pressed()` 代替事件覆盖：

  ```gdscript
  var fire_center := fire_button.get_global_rect().get_center()
  fire_button._input(_screen_touch(11, true, fire_center))
  _append(failures, Assertions.expect_true(
      fire_button.pressed and Input.is_action_pressed(&"fire"),
      "Raw fire touch presses its action"
  ))
  fire_button._input(_screen_touch(11, false, fire_center))
  _append(failures, Assertions.expect_true(
      not fire_button.pressed and not Input.is_action_pressed(&"fire"),
      "Raw fire touch release releases its action"
  ))
  ```

  同一测试覆盖错误 touch ID 释放、`_screen_drag()` 后的外部释放、ID 14/15 的 `fire`/`jump` 并按，以及 `Node.NOTIFICATION_APPLICATION_FOCUS_OUT` 后的全部动作和触点清空。

- [x] **Step 2: 运行事件回归验证**

  Run:

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
  ```

  Expected: `PASS: 23 test file(s)`；若按钮将不同 touch ID 当作活动手指，或取消遗漏动作，测试失败。

- [x] **Step 3: 实现每按钮一个触点和 Input 动作状态**

  `MobileActionButton._input()` 只在未占用且事件落在自身矩形内时接受按下；只在事件 index 等于 `active_touch_id` 时释放：

  ```gdscript
  if touch.pressed and active_touch_id == -1 and get_global_rect().has_point(touch.position):
      active_touch_id = touch.index
      set_pressed(true)
  elif not touch.pressed and touch.index == active_touch_id:
      cancel()
  ```

  `MobileControls._cancel_all_input()` 使用：

  ```gdscript
  for action in [&"move_left", &"move_right", &"move_forward", &"move_back"]:
      Input.action_release(action)
  fire_button.cancel()
  jump_button.cancel()
  ```

- [x] **Step 4: 清理测试输入并重跑全量回归**

  每个测试结束时执行：

  ```gdscript
  for action in [&"move_left", &"move_right", &"move_forward", &"move_back", &"jump", &"fire"]:
      Input.action_release(action)
  ```

  Run:

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
  ```

  Expected: `PASS: 23 test file(s)`，后续战斗测试不继承触控输入。

### Task 3: 物理触屏探测、桌面提示与状态恢复

**Files:**

- Modify: `scripts/ui/mobile_controls.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Test: `tests/unit/test_mobile_touch_controls.gd`

**Interfaces:**

- Consumes: `ProjectSettings.get_setting()`、`ProjectSettings.set_setting()`、`Input.is_emulating_touch_from_mouse()`、`Input.set_emulate_touch_from_mouse()`、`DisplayServer.is_touchscreen_available()`。
- Produces: `MobileControls._is_physical_touchscreen_available() -> bool`，且不持久化改变项目设置或运行时触控模拟状态。
- Produces: `should_show_controls(touchscreen_available: bool, force_controls_visible: bool) -> bool`、`set_touch_mode(enabled: bool) -> void`、`is_touch_mode() -> bool`。

- [x] **Step 1: 写入实际场景的桌面误判 RED 测试**

  实例化 `DemoArena.tscn` 并进入 `SceneTree`，断言默认 `force_visible=false` 时触控层隐藏而桌面帮助显示：

  ```gdscript
  var controls := arena.get_node_or_null("MobileControls") as MobileControls
  var desktop_help := arena.get_node_or_null("HUD/ControlsPanel") as CanvasItem
  _append(failures, Assertions.expect_true(
      controls != null and not controls.force_visible and
      not controls.visible and not controls.is_touch_mode(),
      "Desktop scene hides mobile controls despite mouse touch emulation"
  ))
  _append(failures, Assertions.expect_true(
      desktop_help != null and desktop_help.visible,
      "Desktop scene keeps keyboard controls help visible"
  ))
  ```

- [x] **Step 2: 运行 RED 并确认失败原因是模拟触控误判**

  Run:

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
  ```

  Expected before implementation:

  ```text
  ERROR: ... Desktop scene hides mobile controls despite mouse touch emulation
  ERROR: ... Desktop scene keeps keyboard controls help visible
  FAIL: 2 failure(s)
  ```

- [x] **Step 3: 写入项目设置与运行时状态不一致的 RED 回归**

  在调用探测前使两种状态不同，调用后分别断言原值，并在测试末尾恢复环境：

  ```gdscript
  ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, true)
  Input.set_emulate_touch_from_mouse(false)
  controls._is_physical_touchscreen_available()
  _append(failures, Assertions.expect_true(
      bool(ProjectSettings.get_setting(EMULATE_TOUCH_SETTING, false)),
      "Physical touchscreen detection restores an independent project setting"
  ))
  _append(failures, Assertions.expect_true(
      not Input.is_emulating_touch_from_mouse(),
      "Physical touchscreen detection restores an independent runtime emulation state"
  ))
  ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, project_setting_before)
  Input.set_emulate_touch_from_mouse(runtime_emulation_before)
  ```

  Run:

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
  ```

  Expected before the independent restoration implementation:

  ```text
  ERROR: ... Physical touchscreen detection restores an independent runtime emulation state
  FAIL: 1 failure(s)
  ```

- [x] **Step 4: 分别保存、临时关闭并恢复两个状态**

  实现应保持公共契约不变，并使用下列顺序：

  ```gdscript
  var project_emulate_touch_from_mouse := bool(ProjectSettings.get_setting(
      EMULATE_TOUCH_SETTING, false
  ))
  var runtime_emulate_touch_from_mouse := Input.is_emulating_touch_from_mouse()
  ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, false)
  Input.set_emulate_touch_from_mouse(false)
  var touchscreen_available := DisplayServer.is_touchscreen_available()
  Input.set_emulate_touch_from_mouse(runtime_emulate_touch_from_mouse)
  ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, project_emulate_touch_from_mouse)
  return touchscreen_available
  ```

- [x] **Step 5: 运行 GREEN 并验证状态无污染**

  Run:

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
  ```

  Expected: `PASS: 23 test file(s)`；场景测试和“不一致初始状态”测试均通过。

### Task 4: 实际 Web 产物、文档、部署交接与最终回归

**Files:**

- Modify: `export_presets.cfg`
- Modify: `docs/superpowers/plans/2026-08-04-mobile-h5-touch-controls.md`
- Create: `.superpowers/sdd/2026-08-04-mobile-h5-touch-controls/final-fix-report.md`
- Output: `build/web/index.html`

**Interfaces:**

- Consumes: Web 导出预设的 HTML 头部内容。
- Produces: 包含 `touch-action:none`、`overscroll-behavior:none`、`-webkit-user-select:none` 的实际 `build/web/index.html`。
- Produces: 记录 RED/GREEN、验证输出、真机状态和 Git 限制的最终修复报告。

- [x] **Step 1: 导出实际 Web 页面并检查产物**

  Run:

  ```bash
  mkdir -p build/web
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release Web build/web/index.html
  rg -n "touch-action:none|overscroll-behavior:none|-webkit-user-select:none" build/web/index.html
  ```

  Expected: 导出退出码 `0`，且 `build/web/index.html` 命中：

  ```text
  ...overscroll-behavior:none;...touch-action:none;-webkit-user-select:none;...
  ```

- [x] **Step 2: 运行编辑器加载和格式检查**

  Run:

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
  git diff --check
  ```

  Expected: 两个命令退出码 `0`；编辑器可以完成扫描和全局类注册，`git diff --check` 无输出。

- [x] **Step 3: 记录自动化与产物状态**

  在最终修复报告中记录两轮 RED 的关键输出、GREEN 的 `PASS: 23 test file(s)`、编辑器加载、Web 导出和实际 HTML 检查。报告明确声明未暂存、未提交、未部署、未改动 Nginx。

- [x] **Step 4: 由主 agent 完成部署和单次提交**

  部署沿用既有 Nginx 配置，不修改或 reload Nginx。主 agent 需要暂存时只运行：

  ```bash
  git add -p
  git diff --cached
  ```

  暂存差异经独立复审确认只属于本计划后，主 agent 已完成部署和一次最终提交。

## 执行与验收状态

- [x] 自动化回归：`PASS: 23 test file(s)`。
- [x] Godot 编辑器加载：退出码 `0`。
- [x] Web 导出及实际 HTML 防手势验证：退出码 `0` 且三项 CSS 已命中。
- [x] 既有 Nginx 部署：`rsync -a` 完成，HTML/WASM 均返回 200、禁缓存响应头正确，未修改或 reload Nginx。
- [ ] iOS Safari 真机验收：**PENDING**。
- [ ] Android Chrome 真机验收：**PENDING**。
- [x] 最终提交：已完成一次移动 H5 触控提交。
