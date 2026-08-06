# 玩家血条屏幕平面缩减实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 让玩家头顶血条在任意转向时固定屏幕左端、从右端缩短，并将完整背景降为低对比的空血轨道。

**架构：** `HealthBar3D` 持有父 `Node3D` 作为跟随目标，但在进入树后成为 top-level 世界节点；每帧以目标头顶偏移定位，并把根节点 basis 对齐活动 `Camera3D`。`Background` 与 `Fill` 保持为同一根节点下的普通面片，因此 `Fill` 的局部 X 缩放和偏移始终位于相机平面内。

**技术栈：** Godot 4.7.1、GDScript、`MeshInstance3D`、ShaderMaterial、项目自定义无头测试运行器。

## 全局约束

- 只改 `HealthBar3D` 的坐标与图层组织；不得修改生命、伤害、死亡、攻击、AI、僵尸、武器、刀具配置或 HUD。
- 保持 `BAR_WIDTH = 1.10`、面片高度 `0.10`、`TRANSITION_DURATION = 0.20`、颜色阈值（`> 0.60` 绿、`0.30–0.60` 黄、`< 0.30` 红）和现有 `set_health(current, maximum, animate)` 接口。
- `Fill.scale.x = ratio` 且 `Fill.position.x = -0.55 + 0.55 * ratio`；`ratio == 0.0` 时仅隐藏 `Fill`，背景持续显示。
- `HealthBar3D` 必须保存父 `Node3D`，设置 `top_level = true`，进入树和每帧都用活动 `Camera3D` 同步 `global_position = follow_target.global_position + anchor_offset` 与 `global_basis = camera.global_basis`。
- 缺失父节点、父节点离树或没有活动相机时，保留最近有效 transform、每种情况最多 `push_warning()` 一次，并且不得中断伤害或死亡逻辑。
- 两个面片材质均无光照、透明、关闭深度测试、没有 `MODELVIEW_MATRIX` billboard 顶点逻辑；无局部 Z 偏移；`Fill` 的渲染优先级高于 `Background`；`Background.tint_color.a = 0.35`。
- 所有新行为必须先通过真实场景与节点的失败测试覆盖，再写生产代码；不使用 UI 自动化。新增和既有血条测试必须通过。
- 运行无头编辑器导入与 `./tests/run_tests.sh`。若完整测试仍出现现有 4 项刀具配置失败，必须逐项记录为既有、与本改动无关，不能改刀具或武器文件掩盖失败。

---

## 文件结构

- 修改 `scripts/ui/health_bar_3d.gd`：缓存跟随目标、维护只警告一次的容错状态，并把血条根节点同步到活动相机平面。
- 修改 `scenes/ui/HealthBar3D.tscn`：移除每个面片的 billboard 顶点矩阵，保持圆角透明材质，降低背景 alpha。
- 修改 `scenes/player/Player.tscn`：以 `anchor_offset` 配置玩家头顶偏移，而非根节点局部位置。
- 修改 `tests/unit/test_health_bar_3d.gd`：以真实 `Node3D`、`Camera3D` 和场景实例覆盖同步、朝向与左端锚定回归，同时保留生命比例、Tween、颜色和空血断言。

### Task 1: 将玩家头顶血条重构为统一相机平面

**文件：**

- 修改：`tests/unit/test_health_bar_3d.gd`
- 修改：`scripts/ui/health_bar_3d.gd`
- 修改：`scenes/ui/HealthBar3D.tscn`
- 修改：`scenes/player/Player.tscn`

**接口：**

- 使用：`HealthBar3D.set_health(current: float, maximum: float, animate: bool = true) -> void`、`HealthBar3D.get_target_ratio() -> float`。
- 新增：`@export var anchor_offset: Vector3 = Vector3.ZERO`。
- 新增：`HealthBar3D._sync_to_camera() -> void`，由 `_ready()` 和 `_process(_delta)` 调用；该方法不改变健康比例、颜色或 Tween 状态。
- 产出：血条根节点的 world transform 由父 `Node3D` 位置与活动 `Camera3D.global_basis` 决定，子 `Fill` 的局部 X 坐标永远是屏幕水平轴。

- [ ] **步骤 1：先写会捕获居中缩减回归的失败测试**

  在 `tests/unit/test_health_bar_3d.gd` 中，把血条作为一个真实 `Node3D` 跟随目标的子节点，另建真实 `Camera3D` 并 `make_current()`，两者都加入测试的 `SceneTree.root`。设置：

  ```gdscript
  var follow_target := Node3D.new()
  follow_target.global_position = Vector3(3.0, 1.0, -2.0)
  var camera := Camera3D.new()
  camera.global_position = Vector3(0.0, 4.0, 8.0)
  camera.rotation_degrees = Vector3(-15.0, 25.0, 0.0)
  scene_tree.root.add_child(follow_target)
  scene_tree.root.add_child(camera)
  camera.make_current()

  var health_bar := HEALTH_BAR_SCENE.instantiate() as HealthBar3D
  health_bar.anchor_offset = Vector3(0.0, 2.35, 0.0)
  follow_target.add_child(health_bar)
  health_bar._sync_to_camera()
  ```

  使用 `Assertions.expect_vector3_near` 断言 `health_bar.global_position` 是 `Vector3(3.0, 3.35, -2.0)`，并以 `health_bar.global_basis.x/y/z.dot(camera.global_basis.x/y/z) > 0.999` 断言三个轴与相机一致。调用 `health_bar.set_health(25.0, 100.0, false)`；计算局部左端：

  ```gdscript
  var fill_left_edge := health_bar.to_global(fill.position - Vector3.RIGHT * 0.55 * fill.scale.x)
  ```

  保存该坐标后将 `follow_target.rotation.y = PI`，再次 `_sync_to_camera()`，重新计算并断言两个左端世界坐标相等。这样在根节点仍继承玩家旋转或 Fill 居中缩放时会失败。同步测试结束后释放 `health_bar`、`camera` 和 `follow_target`。

  将材质断言改为可观察的运行行为：两者仍为无光照、关闭深度测试的 `ShaderMaterial`，但 shader 不含 `MODELVIEW_MATRIX`；`Fill` 优先级高于背景、两个本地 `position.z == 0.0`，背景 `tint_color` 的 alpha 为 `0.35`。保留 `set_health` 的比例、颜色、替换 Tween 与 0 血仅隐藏 Fill 断言。

- [ ] **步骤 2：运行测试并确认 RED**

  运行：

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
  ```

  预期：`test_health_bar_3d.gd` 至少因根节点未对齐活动相机、仍有 `MODELVIEW_MATRIX` 或背景 alpha 非 `0.35` 失败；失败信息必须指向这次新增的屏幕平面要求，而不是解析错误或测试拼写错误。记录失败输出。

- [ ] **步骤 3：实现最小的相机平面跟随和渲染配置**

  在 `scripts/ui/health_bar_3d.gd` 中新增并使用以下状态和逻辑：

  ```gdscript
  @export var anchor_offset := Vector3.ZERO

  var follow_target: Node3D
  var missing_follow_target_warned := false
  var missing_camera_warned := false

  func _ready() -> void:
      follow_target = get_parent() as Node3D
      top_level = true
      _sync_to_camera()
      _set_displayed_ratio(displayed_ratio)

  func _process(_delta: float) -> void:
      _sync_to_camera()

  func _sync_to_camera() -> void:
      if not is_instance_valid(follow_target) or not follow_target.is_inside_tree():
          if not missing_follow_target_warned:
              push_warning("HealthBar3D requires an in-tree Node3D follow target.")
              missing_follow_target_warned = true
          return
      var camera := get_viewport().get_camera_3d()
      if camera == null:
          if not missing_camera_warned:
              push_warning("HealthBar3D requires an active Camera3D.")
              missing_camera_warned = true
          return
      global_position = follow_target.global_position + anchor_offset
      global_basis = camera.global_basis
  ```

  使用制表符缩进，并把 `top_level` 赋值的实际 API 形式调整为 Godot 4.7 可解析的写法（若 API 要求 `set_as_top_level(true)`，使用该调用）。不得改变 `set_health`、颜色阈值或 Tween 替换逻辑。

  在 `scenes/ui/HealthBar3D.tscn` 中删除两个 shader 的 `void vertex()` billboard 矩阵代码，保留圆角 `fragment()`、`unshaded`、`cull_disabled`、`depth_draw_never` 和 `depth_test_disabled`。把背景 `tint_color` 默认值设为 `vec4(0.06, 0.08, 0.10, 0.35)`；保持 Fill `render_priority = 1`、两个节点无局部 Z 偏移。

  在 `scenes/player/Player.tscn` 中，把实例节点原有的：

  ```ini
  position = Vector3(0, 2.35, 0)
  ```

  改为：

  ```ini
  anchor_offset = Vector3(0, 2.35, 0)
  ```

- [ ] **步骤 4：运行聚焦测试确认 GREEN，并执行基础 Smoke Test**

  先运行：

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
  ```

  预期：`test_health_bar_3d.gd` 的所有断言通过，不能有脚本、解析或运行时错误。接着运行：

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
  ./tests/run_tests.sh
  ```

  无头导入必须通过。完整测试若仍失败，只接受并逐项记录以下既有刀具配置失败：`Knife exposes slash locomotion animation — expected Run_Slash, got Run`、`Knife can restart when its cooldown finishes — expected 2, got 1`、`A new player attack works after damage clears the old buffer`、`A new attack works after weapon switching clears the old buffer`；血条测试不得在失败列表中。

- [ ] **步骤 5：自审、提交任务实现**

  自审确认：根节点而非单个面片负责相机对齐；Fill 左端在 `0°` 与 `180°` 的回归测试中相同；背景只是 `0.35` alpha 的轨道；找不到跟随目标或相机不会重置最近有效 transform；未修改任务外系统。提交：

  ```bash
  git add scripts/ui/health_bar_3d.gd scenes/ui/HealthBar3D.tscn scenes/player/Player.tscn tests/unit/test_health_bar_3d.gd
  git commit -m "fix: anchor player health bar to screen plane"
  ```

## 计划自审

- 规格覆盖：Task 1 覆盖统一相机平面、左端缩减、背景弱化、材质层级、容错、原有生命/Tween 逻辑不变、无头检查、血条回归与完整测试已知失败记录；非目标明确禁止任务外改动。
- 占位符扫描：已逐段检查，无 `TODO`、`TBD`、`implement later`、泛化的“适当处理”或未给出可执行内容的测试步骤。
- 类型一致性：`anchor_offset: Vector3`、`follow_target: Node3D` 与 `_sync_to_camera() -> void` 在接口、测试与实现步骤中命名一致；`set_health` 和 `get_target_ratio` 保持现有签名。
