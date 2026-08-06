# 玩家血条左锚裁剪与阴影修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 让玩家头顶血条的彩色 Fill 始终与背景轨道左端重合、只从右侧缩短，并彻底移除血条 Quad 在地面的黑色投影。

**架构：** `Background` 与 `Fill` 保持完全相同的局部位置、单位缩放和完整 Quad 尺寸；Fill shader 通过 `[0, 1]` 的 `fill_ratio` uniform 从右侧裁剪可见像素，并在可见区域内重新归一化 UV 以保留圆角。两个 `MeshInstance3D` 都关闭 `cast_shadow`，现有相机平面根节点、生命接口、颜色和 Tween 逻辑保持不变。

**技术栈：** Godot 4.7.1、GDScript、Godot spatial shader、`MeshInstance3D`、`ShaderMaterial`、项目自定义无头测试运行器。

## 全局约束

- 只修改 `HealthBar3D` 的 Fill 裁剪、两个 Quad 的阴影属性和对应回归测试；不得修改玩家生命、伤害、死亡、相机、僵尸、武器、血迹、灯光或全局阴影设置。
- 保持公开接口 `set_health(current: float, maximum: float, animate: bool = true) -> void`、`BAR_WIDTH = 1.10`、面片高度 `0.10`、`TRANSITION_DURATION = 0.20` 和现有颜色阈值不变。
- `Background` 与 `Fill` 必须保持 `position = Vector3.ZERO`、`scale = Vector3.ONE`、无局部 Z 偏移；比例不得再通过 Fill 节点位移或缩放表达。
- Fill shader 必须提供 `fill_ratio`，默认 `1.0`，范围 `[0.0, 1.0]`；`UV.x <= fill_ratio` 显示，右侧区域透明，可见区域横向 UV 按 `UV.x / fill_ratio` 归一化后继续使用现有圆角计算。
- `_set_displayed_ratio()` 必须写入 Fill 材质的 `fill_ratio`；0 血时 `fill_ratio == 0.0` 且仅隐藏 Fill，Background 继续显示。
- `Background` 与 `Fill` 都必须设置 `cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF`（场景序列化值 `0`）。
- 两个材质继续使用 `unshaded`、`cull_disabled`、`depth_draw_never`、`depth_test_disabled`；Fill 的 `render_priority` 高于 Background，背景 alpha 保持 `0.35`。
- 保持现有 top-level 相机同步、`anchor_offset`、父节点/相机失效的一次性警告与最近有效 transform 容错。
- 严格执行 TDD：先让真实场景测试因仍在缩放/位移、缺少 `fill_ratio` 和阴影未关闭而失败，再修改生产代码。
- 不使用 UI/浏览器自动化验证。无头导入必须通过；新增和既有血条测试不得失败。最终像素效果由用户按固定伤害比例和转向截图验收。

---

## 文件结构

- 修改 `tests/unit/test_health_bar_3d.gd`：用真实 `HealthBar3D` 场景验证阴影关闭、Fill 完整变换、`fill_ratio` 更新、0 血行为及既有相机/Tween/颜色契约。
- 修改 `scenes/ui/HealthBar3D.tscn`：为两个 Quad 关闭投影，并让 Fill shader 从右侧裁剪完整面片。
- 修改 `scripts/ui/health_bar_3d.gd`：将 `_set_displayed_ratio()` 从节点变换改为写入 shader uniform。

### Task 1: 使用 shader 左锚裁剪 Fill 并关闭血条投影

**文件：**

- 修改：`tests/unit/test_health_bar_3d.gd`
- 修改：`scenes/ui/HealthBar3D.tscn`
- 修改：`scripts/ui/health_bar_3d.gd`

**接口：**

- 使用：`HealthBar3D.set_health(current: float, maximum: float, animate: bool = true) -> void`。
- 使用：Fill 的 `ShaderMaterial.set_shader_parameter(&"fill_ratio", ratio)`。
- 产出：`fill_ratio: float` 作为 Fill 的唯一可见比例状态；Fill 节点本身始终保持完整位置和尺寸。
- 保持：`HealthBar3D._sync_to_camera() -> void`、`anchor_offset: Vector3`、`get_target_ratio() -> float` 的现有行为与签名。

- [ ] **步骤 1：先写能够捕获两个截图问题的失败测试**

  修改 `tests/unit/test_health_bar_3d.gd`。在取得真实场景的 `background`、`fill` 和材质后，新增以下行为断言：

  ```gdscript
  _append(failures, Assertions.expect_equal(
      background.cast_shadow,
      GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
      "Background does not cast a second black bar onto the ground"
  ))
  _append(failures, Assertions.expect_equal(
      fill.cast_shadow,
      GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
      "Fill does not cast a second black bar onto the ground"
  ))
  ```

  调用 `health_bar.set_health(25.0, 100.0, false)` 后，不再断言 `fill.scale.x == 0.25` 和 `fill.position.x == -0.4125`，改为验证完整面片与材质比例：

  ```gdscript
  var fill_ratio: Variant = fill_material.get_shader_parameter(&"fill_ratio")
  _append(failures, Assertions.expect_true(fill_ratio is float, "Fill exposes its visible ratio at runtime"))
  if fill_ratio is float:
      _append(failures, Assertions.expect_float_near(
          fill_ratio,
          0.25,
          0.0001,
          "Fill clips to the requested health ratio"
      ))
  _append(failures, Assertions.expect_vector3_near(
      fill.position,
      Vector3.ZERO,
      0.0001,
      "Fill keeps the same origin as Background while clipping"
  ))
  _append(failures, Assertions.expect_vector3_near(
      fill.scale,
      Vector3.ONE,
      0.0001,
      "Fill keeps its full quad size while clipping"
  ))
  ```

  删除基于缩放后世界左边缘的 `fill_left_edge` / `rotated_fill_left_edge` 断言；继续保留根节点跟随位置和三个相机 basis 轴断言，因为转向隔离仍由相机平面根节点负责。

  在 0 血断言中验证材质比例和背景仍显示：

  ```gdscript
  var empty_fill_ratio: Variant = fill_material.get_shader_parameter(&"fill_ratio")
  if empty_fill_ratio is float:
      _append(failures, Assertions.expect_float_near(
          empty_fill_ratio,
          0.0,
          0.0001,
          "Empty health clips the whole Fill"
      ))
  _append(failures, Assertions.expect_true(not fill.visible, "Empty health hides Fill"))
  _append(failures, Assertions.expect_true(background.visible, "Empty health keeps the track visible"))
  ```

  保留比例归一化、颜色阈值、材质渲染规则、背景 alpha、Tween 替换和相机同步的既有测试。

- [ ] **步骤 2：运行测试并确认 RED 原因正确**

  运行：

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
  ```

  预期：血条测试明确报告 Background/Fill 仍会投影、Fill 没有 `fill_ratio`，或 Fill 仍使用缩放与位移；不得把解析错误、测试拼写错误或既有刀具失败当作本任务 RED 证据。记录血条相关失败输出。

- [ ] **步骤 3：为两个 Quad 关闭投影并实现 Fill shader 裁剪**

  在 `scenes/ui/HealthBar3D.tscn` 的 `Background` 与 `Fill` 节点分别新增：

  ```ini
  cast_shadow = 0
  ```

  在 Fill shader 的 `tint_color` 后新增：

  ```glsl
  uniform float fill_ratio : hint_range(0.0, 1.0) = 1.0;
  ```

  将 Fill shader 的 `fragment()` 改为：

  ```glsl
  void fragment() {
      float safe_ratio = max(fill_ratio, 0.0001);
      vec2 fill_uv = vec2(UV.x / safe_ratio, UV.y);
      vec2 centered_uv = abs(fill_uv - vec2(0.5)) - vec2(0.42, 0.42);
      float corner_distance = length(max(centered_uv, vec2(0.0)));
      float rounded_alpha = 1.0 - smoothstep(0.07, 0.09, corner_distance);
      float visible_alpha = 1.0 - step(fill_ratio, UV.x);
      ALBEDO = tint_color.rgb;
      ALPHA = tint_color.a * rounded_alpha * visible_alpha;
  }
  ```

  Background shader 不增加 `fill_ratio`，继续显示 alpha 为 `0.35` 的完整轨道。两个节点保持默认 `position = Vector3.ZERO` 和 `scale = Vector3.ONE`，不得新增局部 Z 偏移。

- [ ] **步骤 4：把显示比例从节点变换迁移到 shader uniform**

  在 `scripts/ui/health_bar_3d.gd` 中将 `_set_displayed_ratio()` 改为：

  ```gdscript
  func _set_displayed_ratio(ratio: float) -> void:
      displayed_ratio = clampf(ratio, 0.0, 1.0)
      var fill_material := fill.material_override as ShaderMaterial
      fill_material.set_shader_parameter(&"fill_ratio", displayed_ratio)
      fill.position = Vector3.ZERO
      fill.scale = Vector3.ONE
      fill.visible = displayed_ratio > 0.0
  ```

  不修改 `set_health()` 的目标比例、颜色更新、旧 Tween kill、新 Tween 创建或时长。因为材质 `resource_local_to_scene = true`，每个血条实例继续持有独立的 `fill_ratio`。

- [ ] **步骤 5：运行 GREEN、无头导入与基础 Smoke Test**

  先运行：

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
  ```

  预期：`test_health_bar_3d.gd` 不出现在失败列表中；阴影、完整 Fill 变换、`fill_ratio`、0 血、颜色、Tween 和相机同步断言全部通过。

  再运行：

  ```bash
  /Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
  ./tests/run_tests.sh
  git diff --check
  ```

  无头导入必须通过。完整测试若仍有现有刀具配置失败，逐项记录并确认血条测试没有失败；不得修改刀具或武器文件。第三方 Phantom Camera 编辑器启动错误若仍存在，记录为既有插件问题，不得在本任务扩大修复范围。

- [ ] **步骤 6：自审并提交任务实现**

  自审必须确认：

  - 忘记任一节点的 `cast_shadow = 0` 会被测试捕获。
  - `_set_displayed_ratio()` 若恢复修改 Fill 的缩放或位置，会被完整变换断言捕获。
  - Fill shader 的 `fill_ratio` 若没有随 25% 和 0% 更新，会被运行时材质参数断言捕获。
  - 变更只涉及计划列出的三个文件，没有修改全局阴影、灯光或任务外系统。

  提交：

  ```bash
  git add tests/unit/test_health_bar_3d.gd scenes/ui/HealthBar3D.tscn scripts/ui/health_bar_3d.gd
  git commit -m "fix: clip health bar fill from the left edge"
  ```

## 人工验收

实现与 Review 通过后，由用户在 Demo 中让玩家分别降至约 `25%`、`50%`、`75%` 血量，并在 `0°`、`90°`、`180°` 朝向截图：彩色 Fill 左端必须始终与淡色背景轨道左端重合，只有右端移动；血条下方和地面不得出现横向黑色投影。

## 计划自审

- 规格覆盖：Task 1 覆盖 shader 左锚裁剪、完整 Fill 变换、两个 Quad 禁止投影、背景轨道、0 血、颜色/Tween/相机逻辑不变、无头检查和人工截图验收。
- 占位符扫描：计划不包含未定义实现、泛化错误处理、未给出断言的测试步骤或跨任务隐含接口。
- 类型一致性：`fill_ratio` 在 shader、GDScript 和测试中均为 `[0.0, 1.0]` 的浮点值；`set_health()`、`_set_displayed_ratio()`、`anchor_offset` 与现有签名一致。
