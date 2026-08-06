# 玩家血条左锚裁剪与阴影修复设计

## 背景与目标

玩家血条采用相机平面根节点后，角色转向已不再旋转血条坐标系，但实际画面仍存在两个问题：彩色 Fill 没有呈现为明确的左端固定缩减；血条下方出现一条与血条分离的黑色横条。

本轮目标是让 `HealthBar3D` 的最终可见像素满足以下规则：

- 彩色 Fill 与背景轨道使用完全相同的位置和完整尺寸，左边缘始终重合。
- 血量降低时只从右侧裁掉 Fill，不再通过节点缩放和位移表达比例。
- 血条面片不参与场景阴影，地面上不得出现血条形状的黑色投影。
- 保留现有相机平面跟随、颜色阈值、`0.20` 秒 Tween、背景轨道和 0 血隐藏逻辑。

## 问题根因

### 黑色横条

`Background` 与 `Fill` 都是 `MeshInstance3D`。虽然材质使用 `unshaded`、关闭深度测试并且不写入深度，但场景节点没有关闭 `cast_shadow`，因此两个 Quad 仍会被方向光当作普通几何体投射到地面。相机和灯光角度会让这道阴影显示在血条下方，视觉上像第二根黑色血条。

### 左端缩减观感

当前 Fill 通过以下节点变换表达血量：

```gdscript
fill.scale.x = ratio
fill.position.x = -BAR_WIDTH * 0.5 + BAR_WIDTH * ratio * 0.5
```

数学上该公式将网格左边缘固定在 `-0.55`，但最终画面仍依赖子节点缩放、位置、透明排序和投影结果。现有自动测试只验证了变换坐标，没有验证 shader 最终覆盖的像素；同时地面阴影又提供了一条错位的完整宽度参照，使缩减结果被感知为居中。

本轮不继续修补节点变换，而是让 Fill 保持与 Background 完全重合，通过材质可见区域直接表达比例。

## 方案选择

采用“完整面片 + shader 从右裁剪”方案。

`Background` 和 `Fill` 的 Quad 都保持宽 `1.10m`、高 `0.10m`，局部 `position = Vector3.ZERO`、`scale = Vector3.ONE`。Fill shader 新增 `fill_ratio` uniform，取值范围为 `[0.0, 1.0]`：

- `UV.x <= fill_ratio` 的区域显示彩色 Fill。
- `UV.x > fill_ratio` 的区域透明，露出下方背景轨道。
- 可见区域的横向 UV 使用 `UV.x / fill_ratio` 重新归一化，再执行现有圆角计算，使任意血量下的左右端仍保持圆角。
- `fill_ratio == 0.0` 时脚本隐藏 Fill，避免 shader 除零和残留像素。

该方案把“左端固定”变成材质坐标的直接约束：Fill 的左端始终是 `UV.x == 0.0`，只有右边界随 `fill_ratio` 变化，不再依赖 MeshInstance 的位移补偿。

备选方案未采用：

- 增加左侧 Pivot 节点后缩放 Fill：可以实现左锚缩放，但增加节点层级，仍依赖节点变换表达可见边界。
- 仅关闭阴影并保留现有公式：改动最小，但无法给最终像素的左端裁剪提供更强约束。

## 组件与数据流

公开接口保持不变：

```gdscript
set_health(current: float, maximum: float, animate: bool = true) -> void
```

数据流调整为：

1. `set_health()` 继续计算并保存 `target_ratio`，立即按真实目标比例更新绿、黄、红颜色。
2. 非动画更新直接调用 `_set_displayed_ratio(target_ratio)`；动画更新继续用 `Tween.tween_method()` 在 `0.20` 秒内更新 `displayed_ratio`。
3. `_set_displayed_ratio()` 不再修改 `Fill.scale.x` 或 `Fill.position.x`，而是把显示比例写入 Fill 材质的 `fill_ratio`。
4. 比例大于 `0.0` 时显示 Fill；比例为 `0.0` 时隐藏 Fill。Background 始终显示完整空血轨道。

`HealthBar3D` 的 top-level 相机同步、`anchor_offset`、父节点/相机失效容错均保持原样。

## 渲染规则

- `Background` 和 `Fill` 节点都明确设置 `cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF`（场景序列化值 `0`）。
- 两个面片继续使用 `unshaded`、`cull_disabled`、`depth_draw_never`、`depth_test_disabled`。
- 两个面片保持同一局部原点和单位缩放，不增加局部 Z 偏移。
- Fill 的 `render_priority` 继续高于 Background，透明区域露出 alpha 为 `0.35` 的背景轨道。
- Fill shader 的 `fill_ratio` 默认值为 `1.0`；初始满血无需等待第一帧健康信号即可正确显示。
- 不增加残血延迟层、描边、刻度、数字或新的 HUD。

## 边界与容错

- `health_ratio()` 继续把比例限制在 `[0.0, 1.0]`；写入 shader 的 `fill_ratio` 使用相同边界。
- 最大生命值小于等于 `0.0` 时比例仍为 `0.0`，仅隐藏 Fill，不隐藏 Background。
- 连续调用 `set_health()` 时仍杀死旧 Tween，只保留最新动画。
- 找不到活动相机或跟随目标时只影响根节点 transform 同步，不影响 Fill 比例、颜色或 Tween。
- 阴影关闭仅作用于血条的两个 Quad，不改变玩家、僵尸、武器、血迹或场景灯光的阴影。

## 测试与验收

调整 `tests/unit/test_health_bar_3d.gd`，核心回归覆盖：

- `Background.cast_shadow` 与 `Fill.cast_shadow` 都是 `SHADOW_CASTING_SETTING_OFF`。
- 设置 `25/100` 后，Fill 材质的 `fill_ratio == 0.25`。
- 设置不同血量后，Fill 始终保持 `position == Vector3.ZERO` 与 `scale == Vector3.ONE`，证明比例不再通过居中缩放或位移表达。
- 0 血时 `fill_ratio == 0.0` 且仅隐藏 Fill；Background 继续可见。
- 现有颜色阈值、Tween 替换、相机 basis 和玩家 `0°/180°` 转向测试继续通过。

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh
```

最终像素裁剪和阴影需要人工验收：启动 Demo，让玩家受伤到约 `25%`、`50%`、`75%`，分别观察玩家朝向 `0°`、`90°`、`180°`。每个比例下，彩色 Fill 的左端必须与淡色背景轨道左端重合，只有右端移动；地面及血条下方不得出现黑色横条。由用户提供截图时，再按截图检查最终渲染结果。

## 非目标

- 不修改血条世界尺寸、头顶高度、相机跟随方式或玩家生命逻辑。
- 不接入僵尸血条。
- 不修改全局灯光、阴影质量或其他 MeshInstance 的投影设置。
- 不通过屏幕 HUD、SubViewport 或 Control 节点重做血条。
