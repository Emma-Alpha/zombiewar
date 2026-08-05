# 移动端控件视口比例缩放 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: 使用 `superpowers:executing-plans` 按步骤实施；用户已明确跳过 SDD，本次由当前会话直接执行。

**Goal:** 让移动端摇杆与开火键按运行时视口高度缩放，摇杆始终占屏高 `45%`，并保持现有触控行为。

**Architecture:** `MobileControls` 作为唯一布局协调者，在节点就绪和视口尺寸变化时计算三个触控控件的矩形与视觉参数。`MobileActionButton` 只增加可配置的圆形内缩与轮廓宽度，不承担视口布局职责。

**Tech Stack:** Godot 4.7.1、GDScript、原生 `VirtualJoystick`、现有自定义 headless 测试运行器。

## Global Constraints

- 摇杆宽高严格等于可见视口高度的 `45%`。
- 开火键保持当前 `160:252` 的摇杆尺寸比例。
- 摇杆死区保持 `0.12`，动作映射和触控 ID 逻辑不变。
- 跳跃键保持 `120×120`，只调整位置避让。
- 不修改用户当前工作区中的武器扩散相关改动。
- 使用 TDD：先写断言并确认因固定尺寸失败，再修改生产代码。

---

### Task 1: 响应式移动控件布局

**Files:**
- Modify: `docs/superpowers/specs/2026-08-05-mobile-controls-viewport-scaling-design.md`
- Modify: `scripts/ui/mobile_controls.gd`
- Modify: `scripts/ui/mobile_action_button.gd`
- Modify: `tests/unit/test_mobile_touch_controls.gd`
- Modify: `tests/integration/test_demo_scene.gd`

**Interfaces:**
- Consumes: `Viewport.size_changed`、`Viewport.get_visible_rect()`、现有 `VirtualJoystick` 与 `MobileActionButton` 节点。
- Produces: `MobileControls` 初始化及视口变化后的响应式控件矩形；`MobileActionButton.outline_inset: float` 与 `outline_width: float`。

- [ ] **Step 1: 写入会因固定尺寸实现而失败的测试**

在 `tests/unit/test_mobile_touch_controls.gd` 的真实 `SubViewport` 场景测试中，使用手工推导的字面量断言：

```gdscript
virtual_joystick.size.is_equal_approx(Vector2(324.0, 324.0))
is_equal_approx(virtual_joystick.joystick_size, 262.285714)
is_equal_approx(virtual_joystick.tip_size, 113.142857)
fire_button.size.is_equal_approx(Vector2(205.714286, 205.714286))
jump_button.size.is_equal_approx(Vector2(120.0, 120.0))
```

把子视口改为 `Vector2i(1600, 800)` 后，断言摇杆更新为 `360×360`、开火键约为 `228.571429×228.571429`，并断言三个矩形互不重叠。

同步更新 `tests/integration/test_demo_scene.gd` 的 Demo 契约，断言基准 `1280×720` 下的响应式尺寸。

- [ ] **Step 2: 运行完整测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，失败信息指向摇杆仍为 `252×252` 或开火键仍为 `160×160`；不得是脚本解析错误。

- [ ] **Step 3: 为动作按钮开放视觉尺寸参数**

在 `scripts/ui/mobile_action_button.gd` 增加：

```gdscript
@export var outline_inset := 4.0
@export var outline_width := 4.0
```

`_draw()` 使用这两个属性计算半径和 `draw_arc()` 宽度，默认值保持跳跃键现状。

- [ ] **Step 4: 实现视口高度驱动的布局**

在 `scripts/ui/mobile_controls.gd` 中定义比例常量，并实现 `_apply_responsive_layout()`：

```gdscript
var viewport_height := get_viewport().get_visible_rect().size.y
var joystick_control_size := viewport_height * 0.45
var scale_factor := joystick_control_size / 252.0
var fire_button_size := 160.0 * scale_factor
var screen_margin := 40.0 * scale_factor
```

用锚点偏移设置左下摇杆、右下开火键，以及与开火键保持同比水平和垂直安全间距的固定 `120×120` 跳跃键；同步更新 `joystick_size`、`tip_size`、开火标签字号、`outline_inset` 与 `outline_width`。在 `_ready()` 连接 `get_viewport().size_changed` 后立即调用，并在退出树时安全断开。

- [ ] **Step 5: 运行测试并确认 GREEN**

Run: `./tests/run_tests.sh`

Expected: PASS，输出无新增 Godot error 或 warning。

- [ ] **Step 6: 执行 Godot 解析检查**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`

Expected: exit code `0`，无场景或脚本解析错误。

- [ ] **Step 7: 仅提交本需求文件**

```bash
git commit --only -m "feat: scale mobile controls with viewport height" -- \
  docs/superpowers/specs/2026-08-05-mobile-controls-viewport-scaling-design.md \
  docs/superpowers/plans/2026-08-05-mobile-controls-viewport-scaling.md \
  scripts/ui/mobile_controls.gd \
  scripts/ui/mobile_action_button.gd \
  tests/unit/test_mobile_touch_controls.gd \
  tests/integration/test_demo_scene.gd
```

Expected: 用户已暂存或未暂存的武器扩散文件不进入提交。
