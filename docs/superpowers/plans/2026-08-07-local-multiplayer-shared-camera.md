# 本地多人共享镜头 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用有效玩家中心和屏幕边缘共同推动计算固定缩放共享镜头，并阻止在线存活玩家因移动或击退离开屏幕安全区域。

**Architecture:** `SharedCameraMath` 只接收不可变玩家样本并返回绝对目标，保证无累计漂移。`FollowCamera` 负责从 PlayerRegistry 构造样本、限制世界范围和执行平滑；武器冲击移动独立视觉子节点。`PlayerScreenBounds` 把计划世界位移投影到屏幕并裁剪到安全矩形。

**Tech Stack:** Godot 4.7.1、GDScript、正交 Camera3D、现有 FollowCamera/PlayerController、聚焦数学验证和人工手感验收。

## Global Constraints

- 前置计划：前三份本地多人计划必须完成。
- 设计规格：`docs/superpowers/specs/2026-08-07-local-multiplayer-input-shared-camera-design.md`。
- 摄像机只改变水平位置，不修改正交 size、旋转和高度。
- 有效玩家为实例有效、存活且输入在线的玩家。
- 离线或死亡玩家不参与中心、边缘推动和活动玩家安全约束。
- 目标公式为“有效玩家中心 + 限长共同移动方向偏移”，每帧从快照重新计算。
- 同向推动叠加，反向推动抵消；偏移有最大长度。
- 无有效玩家时保持镜头最后位置。
- 镜头只在本地计算，不写入 GameSession。
- 在线存活玩家的普通移动和击退不得越过屏幕安全边界。
- 不恢复 `tests/`；保留稳定数学和场景结构验证。
- 最终 squash 提交：`feat: add local multiplayer shared camera`。

---

### Task 1: 实现纯共享镜头目标数学

**Files:**
- Create: `scripts/camera/shared_camera_player_sample.gd`
- Create: `scripts/camera/shared_camera_math.gd`
- Create: `tools/validation/validate_shared_camera_math.gd`

**Interfaces:**
- Consumes: 玩家世界位置、屏幕位置、世界移动方向、屏幕移动方向和视口尺寸。
- Produces: `SharedCameraMath.player_center(samples: Array[SharedCameraPlayerSample]) -> Vector3`、`edge_push(samples, viewport_size, edge_start_ratio, max_offset) -> Vector3`、`desired_position(samples, viewport_size, edge_start_ratio, max_offset, fallback) -> Vector3`。

- [ ] **Step 1: 写失败的数学契约验证**

覆盖：

1. 两名玩家中心为位置平均值。
2. 屏幕中央玩家不产生推动。
3. 右边缘且向右移动的两名玩家产生正 X 推动。
4. 左右相反推动抵消。
5. 一名推动者在四人样本中只贡献四分之一权重。
6. 推动长度不超过最大偏移。
7. 相同样本连续调用得到完全相同目标。
8. 空样本返回调用者提供的 fallback。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_shared_camera_math.gd
```

Expected: FAIL，原因是镜头数学类不存在。

- [ ] **Step 2: 实现 SharedCameraPlayerSample**

```gdscript
extends RefCounted
class_name SharedCameraPlayerSample

var world_position := Vector3.ZERO
var screen_position := Vector2.ZERO
var world_move_direction := Vector3.ZERO
var screen_move_direction := Vector2.ZERO
```

样本只包含数学输入，不保存 PlayerController 引用。

- [ ] **Step 3: 实现边缘权重**

`edge_start_ratio` 默认 `0.72`。右边缘起点为 `width * 0.72`，左边缘终点为 `width * 0.28`；上下同理。单轴权重从临界线到屏幕边缘线性插值到 1，并乘以指向边缘外侧的输入分量。

```gdscript
static func edge_axis_weight(
	position: float,
	size: float,
	direction: float,
	start_ratio: float
) -> float:
	var start := clampf(start_ratio, 0.5, 0.95)
	if direction > 0.0 and position > size * start:
		return inverse_lerp(size * start, size, position) * direction
	if direction < 0.0 and position < size * (1.0 - start):
		return inverse_lerp(size * (1.0 - start), 0.0, position) * -direction
	return 0.0
```

- [ ] **Step 4: 实现无累计目标公式**

```gdscript
static func edge_push(
	samples: Array[SharedCameraPlayerSample],
	viewport_size: Vector2,
	edge_start_ratio: float,
	max_offset: float
) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for sample in samples:
		var x_weight := edge_axis_weight(
			sample.screen_position.x,
			viewport_size.x,
			sample.screen_move_direction.x,
			edge_start_ratio
		)
		var y_weight := edge_axis_weight(
			sample.screen_position.y,
			viewport_size.y,
			sample.screen_move_direction.y,
			edge_start_ratio
		)
		var weight := clampf(maxf(x_weight, y_weight), 0.0, 1.0)
		sum += sample.world_move_direction.limit_length(1.0) * weight
	return (sum / float(samples.size()) * maxf(max_offset, 0.0)).limit_length(
		maxf(max_offset, 0.0)
	)
```

补齐中心和目标函数：

```gdscript
static func player_center(samples: Array[SharedCameraPlayerSample]) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for sample in samples:
		sum += sample.world_position
	return sum / float(samples.size())

static func desired_position(
	samples: Array[SharedCameraPlayerSample],
	viewport_size: Vector2,
	edge_start_ratio: float,
	max_offset: float,
	fallback: Vector3
) -> Vector3:
	if samples.is_empty():
		return fallback
	var desired := player_center(samples) + edge_push(
		samples,
		viewport_size,
		edge_start_ratio,
		max_offset
	)
	desired.y = fallback.y
	return desired
```

- [ ] **Step 5: 运行数学验证**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_shared_camera_math.gd
```

Expected: PASS，重复求解无状态差异。

- [ ] **Step 6: 提交检查点**

```bash
git add scripts/camera/shared_camera_player_sample.gd scripts/camera/shared_camera_math.gd tools/validation/validate_shared_camera_math.gd
git commit -m "feat: add shared camera target math"
```

---

### Task 2: 将 FollowCamera 改为多人中心和独立视觉冲击

**Files:**
- Modify: `scripts/camera/follow_camera.gd`
- Modify: `scenes/camera/FollowCamera.tscn`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Create: `tools/validation/validate_shared_camera_scene.gd`

**Interfaces:**
- Consumes: `PlayerRegistry.get_players()`、`PlayerController.get_last_input_state()`、`is_input_online()`、`SharedCameraMath.desired_position(...)`。
- Produces: `FollowCamera.set_player_registry(registry)`、`set_world_bounds(bounds: Rect2)`、`get_anchor_position() -> Vector3`。

- [ ] **Step 1: 写失败的镜头场景契约验证**

要求 FollowCamera 场景结构为：

```text
FollowCamera
└── VisualOffset
    └── Camera3D
```

并断言 `Camera3D.projection`、`size = 15.0`、旋转和局部高度与当前场景一致。

- [ ] **Step 2: 把视觉冲击移到 VisualOffset**

FollowCamera 根节点只保存共享锚点。`_ready()` 把场景初始值保存为 `visual_offset_base_position`。`add_shot_impulse()` 更新 `shot_impulse_offset`，每帧设置 `VisualOffset.position = visual_offset_base_position + shot_impulse_offset`；根节点目标位置不加该偏移。

- [ ] **Step 3: 从 PlayerRegistry 构造有效样本**

过滤条件：实例有效、`is_alive()`、`is_input_online()`。对每名玩家：

屏幕位置与屏幕移动方向必须使用未叠加镜头冲击的共享锚点相机变换计算。构造所有样本前保存 `VisualOffset.position`，临时设置为 `visual_offset_base_position`，完成投影后立即恢复；不得让 `shot_impulse_offset` 改变边缘接近程度、共同推动方向或 `SharedCameraMath` 输入。

```gdscript
var saved_visual_offset := visual_offset.position
visual_offset.position = visual_offset_base_position

var screen_position := camera.unproject_position(player.global_position)
var move_world := PlayerMotion.world_direction(
	player.get_last_input_state().move_vector,
	camera.global_basis
)
var screen_move := (
	camera.unproject_position(player.global_position + move_world) -
	screen_position
).normalized()

visual_offset.position = saved_visual_offset
```

实际循环要在全部玩家样本完成后再统一恢复 `VisualOffset.position`，不能在玩家之间恢复，以免同一帧使用不同投影锚点。

如果无有效样本，保持锚点不动。

- [ ] **Step 4: 求解、限制世界范围并平滑**

```gdscript
var desired := SharedCameraMath.desired_position(
	samples,
	get_viewport().get_visible_rect().size,
	edge_start_ratio,
	max_direction_offset,
	global_position
)
desired.x = clampf(desired.x, world_bounds.position.x, world_bounds.end.x)
desired.z = clampf(desired.z, world_bounds.position.y, world_bounds.end.y)
desired.y = global_position.y
global_position = global_position.lerp(
	desired,
	smoothing_weight(follow_speed, delta)
)
```

不得设置 `Camera3D.size`、rotation 或 Y。

- [ ] **Step 5: 更新 DemoArena 接线**

删除 `follow_camera.set_target(player)`。玩家生成并注册后调用 `follow_camera.set_player_registry(player_registry)`。世界范围使用竞技场边界减去相机安全余量后的 Rect2。

- [ ] **Step 6: 运行场景验证和导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_shared_camera_scene.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 7: 提交检查点**

```bash
git add scripts/camera/follow_camera.gd scenes/camera/FollowCamera.tscn scripts/gameplay/demo_arena.gd scenes/gameplay/DemoArena.tscn tools/validation/validate_shared_camera_scene.gd
git commit -m "feat: follow local player group"
```

---

### Task 3: 限制玩家普通移动和击退到屏幕安全区域

**Files:**
- Create: `scripts/camera/player_screen_bounds.gd`
- Modify: `scripts/player/player_controller.gd`
- Modify: `scripts/gameplay/local_player_spawner.gd`
- Create: `tools/validation/validate_player_screen_bounds.gd`

**Interfaces:**
- Consumes: 当前 Camera3D、玩家世界位置、计划平面位移。
- Produces: `PlayerScreenBounds.limit_motion(...) -> Vector3`、`PlayerController.set_screen_camera(camera)`。

- [ ] **Step 1: 写失败的屏幕边界验证**

建立正交 Camera3D，验证：屏幕中央位移不变；向右越界被裁剪；沿右边界纵向移动保留；向内移动保留；击退使用同一函数。

- [ ] **Step 2: 实现屏幕点到玩家高度平面的转换**

```gdscript
static func screen_to_plane(
	camera: Camera3D,
	screen_point: Vector2,
	plane_y: float
) -> Vector3:
	var origin := camera.project_ray_origin(screen_point)
	var direction := camera.project_ray_normal(screen_point)
	if absf(direction.y) <= 0.000001:
		return origin
	var distance := (plane_y - origin.y) / direction.y
	return origin + direction * distance
```

- [ ] **Step 3: 实现位移裁剪**

```gdscript
static func limit_motion(
	camera: Camera3D,
	world_position: Vector3,
	desired_motion: Vector3,
	safe_margin_ratio: float
) -> Vector3:
	var viewport_size := camera.get_viewport().get_visible_rect().size
	var margin := viewport_size * clampf(safe_margin_ratio, 0.0, 0.25)
	var safe_rect := Rect2(margin, viewport_size - margin * 2.0)
	var desired_world := world_position + desired_motion
	var desired_screen := camera.unproject_position(desired_world)
	var clamped_screen := Vector2(
		clampf(desired_screen.x, safe_rect.position.x, safe_rect.end.x),
		clampf(desired_screen.y, safe_rect.position.y, safe_rect.end.y)
	)
	if desired_screen.is_equal_approx(clamped_screen):
		return desired_motion
	var clamped_world := screen_to_plane(camera, clamped_screen, world_position.y)
	var limited := clamped_world - world_position
	limited.y = desired_motion.y
	return limited
```

- [ ] **Step 4: 在 PlayerController 统一限制普通移动和击退**

只对存活且输入在线玩家启用。把限制应用在 `weapon_clearance.update_clearance(...)` 和 `move_and_slide()` 之前，使普通速度和 `knockback_velocity` 最终产生的计划位移都经过同一裁剪。根据裁剪后的位移反推本帧平面速度。

- [ ] **Step 5: 确保出生点位于安全区域**

`LocalPlayerSpawner` 生成前使用同一 Camera3D 投影检查四个出生标记。任何标记落在安全矩形外都视为无效出生点。

- [ ] **Step 6: 运行边界验证与导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_player_screen_bounds.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 7: 提交检查点**

```bash
git add scripts/camera/player_screen_bounds.gd scripts/player/player_controller.gd scripts/gameplay/local_player_spawner.gd tools/validation/validate_player_screen_bounds.gd
git commit -m "feat: keep local players inside shared view"
```

---

### Task 4: 完成镜头调参与人工手感验收

**Files:**
- Modify: `scripts/camera/follow_camera.gd`
- Modify: `scenes/camera/FollowCamera.tscn`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Verify: `scripts/camera/shared_camera_math.gd`
- Verify: `scripts/camera/player_screen_bounds.gd`

**Interfaces:**
- Consumes: 本计划全部镜头和安全边界接口。
- Produces: 固定缩放、平滑、无累计漂移的本地共享镜头。

- [ ] **Step 1: 设置首轮可调参数**

在 FollowCamera 导出：

```gdscript
@export_range(0.5, 20.0, 0.1) var follow_speed := 6.0
@export_range(0.5, 0.95, 0.01) var edge_start_ratio := 0.72
@export_range(0.0, 8.0, 0.1) var max_direction_offset := 3.0
@export_range(0.0, 0.25, 0.01) var safe_margin_ratio := 0.08
```

这些是首轮验收值，不写入镜头数学常量，允许在场景中调整。

- [ ] **Step 2: 运行全部聚焦验证和 headless 导入**

分别运行 `validate_shared_camera_math.gd`、`validate_shared_camera_scene.gd`、`validate_player_screen_bounds.gd`，然后运行 headless editor 导入。全部必须退出码 0。

- [ ] **Step 3: 执行双人和四人镜头验收**

1. 玩家静止分散时镜头平滑跟随中心。
2. 一名玩家靠右并继续向右时产生有限偏移。
3. 多人同向时偏移更明显。
4. 玩家相反移动时推动抵消且无来回抖动。
5. 断线或倒地玩家不再影响镜头。
6. 无有效玩家时镜头停在最后位置。
7. 普通移动和击退不能把在线存活玩家推出安全区。
8. 镜头 size、rotation 和 Y 全程不变。

- [ ] **Step 4: 检查目标求解无累计状态**

```bash
rg -n "edge_push.*\+=|direction_offset.*\+=|target_offset.*\+=" scripts/camera
```

Expected: 共同推动和目标偏移没有跨帧累加；允许视觉后坐力使用独立恢复状态。

- [ ] **Step 5: squash 检查点提交**

将本计划检查点提交 squash 为：

```text
feat: add local multiplayer shared camera
```

确认工作树干净并记录最终提交哈希。
