# Demo 场景轴对齐相机实现计划

> **供代理执行：** 必需子技能：使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 按任务逐项执行。本次用户已确认采用当前会话内联执行，不创建子代理或独立 worktree。

**目标：** 将 Demo 游戏内正交跟随相机从水平偏航 `45°` 调整为轴对齐的 `0°`，同时保持现有俯角、观察距离、画面尺度和相机行为。

**架构：** 只改变 `FollowCamera.tscn` 中 `Camera3D` 的静态局部变换；跟随、平滑、射击后坐、玩家移动和射击数据流全部沿用现有实现。使用 Demo 场景集成测试锁定局部变换与平面方向，防止未来重新引入斜向偏航。

**技术栈：** Godot 4.7.1、GDScript、Godot `.tscn` 场景、项目自带无头测试运行器。

## 全局约束

- 仅改变 Demo 游戏内相机；`MenuBackdrop` 和其他场景保持不变。
- 相机位置从 `(10, 12, 10)` 改为 `(0, 12, sqrt(200))`，场景文件中使用约 `14.142136`。
- 相机旋转从 `(-40.3°, 45°, 0°)` 改为 `(-40.3°, 0°, 0°)`。
- 保留正交投影、`size = 18`、`near = 0.1`、`far = 120`。
- 不修改 `follow_camera.gd`、玩家控制、射击逻辑或关卡物体布局。
- 采用测试驱动顺序：先增加会失败的场景契约，再修改相机配置。
- 不创建独立 worktree，不使用子代理。
- 实现代码不提交，由用户在整个计划完成后统一提交。
- 设计依据：`docs/superpowers/specs/2026-08-04-demo-axis-aligned-camera-design.md`。

---

## 文件结构

- 修改 `tests/integration/test_demo_scene.gd`：验证 Demo 相机位置、俯角、零偏航和屏幕轴对应的世界平面方向。
- 修改 `scenes/camera/FollowCamera.tscn`：保存轴对齐斜俯视的固定相机变换。
- 不修改 `tests/unit/test_player_motion.gd`：其职责仍是验证移动算法支持任意相机基向量，不应被 Demo 的固定视角限制。
- 不修改 `scenes/menu/MenuBackdrop.tscn`：主菜单背景明确不在本次范围内。

### Task 1：锁定并调整 Demo 轴对齐相机

**文件：**

- 修改：`tests/integration/test_demo_scene.gd:64-68`
- 修改：`scenes/camera/FollowCamera.tscn:12-18`

**接口：**

- 输入：`DemoArena.tscn` 实例中的 `FollowCamera/Camera3D`。
- 产出：局部位置约为 `Vector3(0.0, 12.0, 14.142136)`、局部旋转角为 `Vector3(-40.3, 0.0, 0.0)` 的正交相机。
- 不新增函数、信号、导出属性或运行时分支。

- [ ] **Step 1：编写会失败的 Demo 相机方向测试**

在 `tests/integration/test_demo_scene.gd` 现有 `if camera != null:` 块中，保留投影和尺寸断言，并追加以下代码：

```gdscript
		_append(failures, Assertions.expect_vector3_near(
			camera.position,
			Vector3(0.0, 12.0, sqrt(200.0)),
			0.001,
			"Camera preserves distance while moving onto the world Z axis"
		))
		_append(failures, Assertions.expect_float_near(
			camera.rotation_degrees.x,
			-40.3,
			0.0001,
			"Camera preserves the oblique pitch"
		))
		_append(failures, Assertions.expect_float_near(
			camera.rotation_degrees.y,
			0.0,
			0.0001,
			"Camera removes the 45 degree yaw"
		))
		var planar_right := camera.basis.x
		planar_right.y = 0.0
		planar_right = planar_right.normalized()
		var planar_forward := -camera.basis.z
		planar_forward.y = 0.0
		planar_forward = planar_forward.normalized()
		_append(failures, Assertions.expect_vector3_near(
			planar_right,
			Vector3.RIGHT,
			0.0001,
			"Camera right aligns with world positive X"
		))
		_append(failures, Assertions.expect_vector3_near(
			planar_forward,
			Vector3.FORWARD,
			0.0001,
			"Camera forward aligns with world negative Z"
		))
```

- [ ] **Step 2：运行完整测试并确认新契约失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

预期：退出码为 `1`，至少出现以下失败信息：

- `Camera preserves distance while moving onto the world Z axis`
- `Camera removes the 45 degree yaw`
- `Camera right aligns with world positive X` 或 `Camera forward aligns with world negative Z`

已有投影、正交尺寸和其他测试应继续通过。

- [ ] **Step 3：最小化修改相机场景变换**

将 `scenes/camera/FollowCamera.tscn` 的相机节点改为：

```ini
[node name="Camera3D" type="Camera3D" parent="."]
position = Vector3(0, 12, 14.142136)
rotation_degrees = Vector3(-40.3, 0, 0)
projection = 1
size = 18.0
near = 0.1
far = 120.0
current = true
```

不要修改 `FollowCamera` 根节点的跟随与射击后坐参数，也不要修改任何脚本。

- [ ] **Step 4：运行完整测试并确认通过**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

预期：退出码为 `0`，输出 `PASS: 22 test file(s)`。

- [ ] **Step 5：执行场景和范围回归检查**

检查实际差异：

```bash
git diff --check -- scenes/camera/FollowCamera.tscn tests/integration/test_demo_scene.gd
git diff -- scenes/camera/FollowCamera.tscn tests/integration/test_demo_scene.gd
```

预期：

- 相机场景只改变 `position` 和 `rotation_degrees` 两行。
- 集成测试只增加相机固定变换与平面方向断言。
- `scenes/menu/MenuBackdrop.tscn`、`scripts/menu/menu_backdrop.gd` 和运行时相机脚本没有变化。
- 工作区保留未提交状态，不执行 `git commit`。

- [ ] **Step 6：手动视觉验收**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

从主菜单进入 Demo，确认：

- 画面仍为约 `40.3°` 的斜俯视，不是垂直俯视。
- 地图不再以 `45°` 菱形方向显示。
- `W/S` 对应屏幕上/下，`A/D` 对应屏幕左/右。
- 初始玩家、僵尸和主要场景物体没有明显被裁切。
- 相机跟随、平滑和射击后坐仍正常。
- 返回主菜单后，背景构图和轻微动态摆动没有变化。

完成后停止测试游戏进程，保留实现改动供用户统一提交。
