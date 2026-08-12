# 修复 VirtualJoystick 原生类名冲突 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除项目 `VirtualJoystick` 全局类名与 Godot 4.7.1 原生类的冲突，同时保持现有移动控制行为与场景绑定不变。

**Architecture:** 项目摇杆继续由 `virtual_joystick.gd` 实现，但只通过 `preload` 和场景脚本资源路径引用，不再注册同名全局类。聚焦验证真实加载脚本并实例化 `MobileControls.tscn`，防止脚本再次变成不可实例化资源或占位节点。

**Tech Stack:** Godot 4.7.1、GDScript、无头 Godot 验证脚本。

## Global Constraints

- 不改变摇杆输入算法、导出属性、动作名、节点名或场景布局。
- 不新增新的全局类名；`mobile_controls.gd` 继续使用 `VirtualJoystickScript` preload 类型。
- 不实现或消费 `map_completed`。
- 只提交本计划直接涉及的文档、验证器和摇杆脚本，不纳入 `.import` 生成差异。

---

### Task 1: 移除原生类名冲突并锁定真实加载合同

**Files:**
- Modify: `scripts/ui/virtual_joystick.gd:1-8`
- Modify: `tools/validation/validate_mobile_equipment_controls.gd`
- Test: `tools/validation/validate_mobile_equipment_controls.gd`

**Interfaces:**
- Consumes: `scripts/ui/mobile_controls.gd` 的 `VirtualJoystickScript = preload(...)` 与 `scenes/ui/MobileControls.tscn` 的脚本路径绑定。
- Produces: 可被 Godot 4.7.1 正常加载、实例化的项目摇杆脚本；不注册 `VirtualJoystick` 全局类名。

- [ ] **Step 1: 写入真实加载失败回归**

扩展 `validate_mobile_equipment_controls.gd`：使用 `load()` 取得项目摇杆脚本并断言
`can_instantiate()`；加载并实例化 `MobileControls.tscn`，断言
`Layout/VirtualJoystick` 存在且 `get_script()` 等于已加载脚本资源。失败时保持仓库统一的
`quit(1)`，通过时打印原有 PASS。

- [ ] **Step 2: 运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_mobile_equipment_controls.gd
```

Expected: 验证失败，输出包含
`Class "VirtualJoystick" hides a native class`、脚本不可实例化或场景脚本绑定失败。

- [ ] **Step 3: 最小修复生产脚本**

从 `scripts/ui/virtual_joystick.gd` 删除：

```gdscript
class_name VirtualJoystick
```

更新文件头注释，说明脚本通过 `MobileControls` preload 与场景资源路径使用；不得修改其他
生产逻辑。

- [ ] **Step 4: 运行聚焦验证并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_mobile_equipment_controls.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_demo_map_data_driven.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --scene res://scenes/maps/demo/DemoMap.tscn --quit-after 3
```

Expected: 全部退出码为 `0`；输出没有 `VirtualJoystick` 原生类冲突、脚本解析错误或场景脚本绑定失败。editor import 可保留项目既有三条 `rp_font is null`。

- [ ] **Step 5: 提交修复**

```bash
git add \
  docs/superpowers/specs/2026-08-12-virtual-joystick-native-class-conflict-design.md \
  docs/superpowers/plans/2026-08-12-fix-virtual-joystick-native-class-conflict.md \
  scripts/ui/virtual_joystick.gd \
  tools/validation/validate_mobile_equipment_controls.gd
git commit -m "fix: avoid VirtualJoystick native class conflict"
```
