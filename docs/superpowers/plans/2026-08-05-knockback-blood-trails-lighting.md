# 击退血液拖痕与受光材质实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 让每次射击命中在真实命中点正下方形成大面积持久血斑，并沿僵尸实际击退路径留下有限叠加的受光拖痕，使模型动态阴影能够自然覆盖血迹。

**架构：** 新增独立的击退拖痕状态对象，负责在固定时间、数量与距离预算内把真实位移段转换为确定性采样点；`ZombieTarget` 只开启会话并在碰撞移动后发出采样结果。`GroundBloodManager` 负责地面投影、血迹造型、空间格两层上限和 FIFO 复用，`GroundBloodSplat` 改为使用受光 `MeshInstance3D` 的持久薄网格。

**技术栈：** Godot 4.7.1、GDScript、GL Compatibility、Jolt Physics、Kenney Splat Pack 1.0（CC0）、项目自定义 `RefCounted.run()` 测试框架。

## 全局约束

- 实施依据：`docs/superpowers/specs/2026-08-05-knockback-blood-trails-lighting-design.md`。
- 使用隔离 worktree 和分支 `codex/knockback-blood-trails-lighting`，不在 `main` 工作区编写生产代码。
- 本轮最多 3 个任务，使用 subagent-driven-development 串行实现；每个任务完成实现、测试、提交和双阶段任务审查后才能进入下一任务。
- 所有生产行为修改遵循 TDD：先写测试并确认因目标行为缺失而失败，再写最小实现。
- 保持 Godot 4.7.1、GL Compatibility 和现有 Web/移动端渲染路径，不切换 Forward+，不引入 `Decal3D`。
- 持久血迹只投影到 `blood_surface`；不新增墙面、角色表面或道具表面血迹。
- 每次拖痕会话最多 `0.75` 秒、最多 `8` 个印记，基础采样间距固定为 `0.36` 米。
- 同一 `0.45` 米空间格最多两个血迹实例；第三次及后续请求只有限扩大或加深已有血迹，不增加实例数。
- 全局持久血迹实例上限保持 `192`，达到上限后 FIFO 复用。
- 持久血迹使用受光薄网格：不启用 unshaded、不投射自身阴影，但必须接收当前 3D 光照与模型动态阴影。
- 素材只新增 Kenney Splat Pack 256px 的 `splat20.png`、`splat26.png`、`splat34.png`，保留现有 `splat29.png`；许可证为 CC0。
- 本轮不增加血迹清理输入、按钮、HUD 文案或自动清理逻辑。

---

## 文件结构

- 新建 `scripts/fx/blood_trail_state.gd`：维护单只僵尸一次击退拖痕会话，把真实移动转换为有序采样点。
- 新建 `tests/unit/test_blood_trail_state.gd`：覆盖间距累积、低帧率补点、方向、停止阈值与八段上限。
- 修改 `scripts/fx/ground_blood_splat.gd` 与 `scenes/fx/GroundBloodSplat.tscn`：将持久血迹从 `Sprite3D` 改为受光 `MeshInstance3D`。
- 修改 `scripts/fx/ground_blood_manager.gd`：实现真实命中投影、主血斑、拖痕造型、空间格两层与 FIFO 索引维护。
- 新增 `assets/fx/blood/kenney_splat20.png`、`kenney_splat26.png`、`kenney_splat34.png` 及 Godot 导入文件；更新 `assets/fx/blood/License.txt` 和素材记录。
- 修改 `scripts/combat/zombie_target.gd` 与 `scripts/gameplay/demo_arena.gd`：开启拖痕会话、报告实际移动、接线到唯一管理器。
- 修改 `tests/unit/test_ground_blood_manager.gd`、`tests/unit/test_blood_impact.gd`、`tests/integration/test_demo_scene.gd` 与 `tests/test_runner.gd`：覆盖新契约。

### Task 1：确定性击退拖痕状态

**文件：**

- 新建：`scripts/fx/blood_trail_state.gd`
- 新建：`scripts/fx/blood_trail_state.gd.uid`
- 新建：`tests/unit/test_blood_trail_state.gd`
- 新建：`tests/unit/test_blood_trail_state.gd.uid`
- 修改：`tests/test_runner.gd:17-20`

**接口：**

- 产出：`BloodTrailState.start(world_position: Vector3, intensity: float) -> void`
- 产出：`BloodTrailState.advance(current_position: Vector3, delta: float, planar_speed: float, normal_move_speed: float) -> Array[Dictionary]`
- 每个返回字典固定包含 `position: Vector3`、`direction: Vector3`、`progress: float`、`intensity: float`。
- 产出只描述实际移动采样，不访问场景树、物理空间或血迹节点。

- [ ] **Step 1：先写失败测试并注册测试文件**

在 `tests/test_runner.gd` 的血液测试附近加入：

```gdscript
"res://tests/unit/test_blood_trail_state.gd",
```

创建 `tests/unit/test_blood_trail_state.gd`，用手工推导的字面量验证以下行为：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const BloodTrailState = preload("res://scripts/fx/blood_trail_state.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var state := BloodTrailState.new()

	_append(failures, Assertions.expect_equal(
		state.advance(Vector3(1, 0, 0), 0.1, 6.0, 1.3).size(),
		0,
		"Normal movement cannot emit blood before a knockback trail starts"
	))

	state.start(Vector3.ZERO, 1.2)
	var long_frame := state.advance(Vector3(1.0, 0, 0), 0.1, 5.0, 1.3)
	_append(failures, Assertions.expect_equal(
		long_frame.size(),
		2,
		"A one-meter low-frame-rate move fills every 0.36-meter sample"
	))
	if long_frame.size() == 2:
		_append(failures, Assertions.expect_vector3_near(
			long_frame[0]["position"], Vector3(0.36, 0, 0), 0.0001,
			"First interpolated trail point uses the fixed spacing"
		))
		_append(failures, Assertions.expect_vector3_near(
			long_frame[1]["position"], Vector3(0.72, 0, 0), 0.0001,
			"Second interpolated trail point stays ordered on the real segment"
		))
		_append(failures, Assertions.expect_vector3_near(
			long_frame[0]["direction"], Vector3.RIGHT, 0.0001,
			"Trail direction follows real displacement"
		))
		_append(failures, Assertions.expect_float_near(
			float(long_frame[0]["intensity"]), 1.2, 0.0001,
			"Trail samples preserve the hit intensity"
		))

	var accumulated := BloodTrailState.new()
	accumulated.start(Vector3.ZERO, 1.0)
	_append(failures, Assertions.expect_equal(
		accumulated.advance(Vector3(0.2, 0, 0), 0.05, 4.0, 1.3).size(), 0,
		"Sub-spacing movement waits for more distance"
	))
	var carried := accumulated.advance(Vector3(0.4, 0, 0), 0.05, 4.0, 1.3)
	_append(failures, Assertions.expect_equal(
		carried.size(), 1,
		"Distance carries across physics frames"
	))
	if carried.size() == 1:
		_append(failures, Assertions.expect_vector3_near(
			carried[0]["position"], Vector3(0.36, 0, 0), 0.0001,
			"Carried distance interpolates on the current segment"
		))

	var capped := BloodTrailState.new()
	capped.start(Vector3.ZERO, 1.0)
	var capped_points := capped.advance(Vector3(10, 0, 0), 0.1, 8.0, 1.3)
	_append(failures, Assertions.expect_equal(
		capped_points.size(), 8,
		"One knockback session cannot emit more than eight marks"
	))
	_append(failures, Assertions.expect_true(
		not capped.active,
		"Reaching the mark cap closes the trail session"
	))

	var slowed := BloodTrailState.new()
	slowed.start(Vector3.ZERO, 1.0)
	slowed.advance(Vector3(0.4, 0, 0), 0.05, 4.0, 1.3)
	slowed.advance(Vector3(0.45, 0, 0), 0.05, 1.5, 1.3)
	_append(failures, Assertions.expect_true(
		not slowed.active,
		"Trail stops after a mark when speed returns near normal movement"
	))

	var expired := BloodTrailState.new()
	expired.start(Vector3.ZERO, 1.0)
	expired.advance(Vector3(0.1, 0, 0), 0.76, 4.0, 1.3)
	_append(failures, Assertions.expect_true(
		not expired.active,
		"Trail session expires after 0.75 seconds"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

- [ ] **Step 2：运行测试，确认因脚本不存在而失败**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

预期：失败信息指向 `res://scripts/fx/blood_trail_state.gd` 无法加载；不是测试语法或测试注册错误。

- [ ] **Step 3：实现最小状态对象**

创建 `scripts/fx/blood_trail_state.gd`，核心实现使用以下固定契约：

```gdscript
extends RefCounted
class_name BloodTrailState

const SAMPLE_SPACING := 0.36
const MAX_DURATION := 0.75
const MAX_MARKS := 8
const STOP_SPEED_MARGIN := 0.25

var active := false
var previous_position := Vector3.ZERO
var distance_to_next := SAMPLE_SPACING
var elapsed := 0.0
var marks_emitted := 0
var intensity := 1.0

func start(world_position: Vector3, hit_intensity: float) -> void:
	active = true
	previous_position = world_position
	distance_to_next = SAMPLE_SPACING
	elapsed = 0.0
	marks_emitted = 0
	intensity = clampf(hit_intensity, 0.75, 1.35)

func advance(
	current_position: Vector3,
	delta: float,
	planar_speed: float,
	normal_move_speed: float
) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	if not active:
		return samples
	elapsed += maxf(delta, 0.0)
	var start := Vector3(previous_position.x, current_position.y, previous_position.z)
	var finish := Vector3(current_position.x, current_position.y, current_position.z)
	var segment := finish - start
	var segment_length := segment.length()
	if segment_length > 0.000001:
		var direction := segment / segment_length
		var travelled := 0.0
		while (
			segment_length - travelled + 0.000001 >= distance_to_next and
			marks_emitted < MAX_MARKS
		):
			travelled += distance_to_next
			marks_emitted += 1
			samples.append({
				"position": start + direction * travelled,
				"direction": direction,
				"progress": float(marks_emitted) / float(MAX_MARKS),
				"intensity": intensity,
			})
			distance_to_next = SAMPLE_SPACING
		distance_to_next -= maxf(segment_length - travelled, 0.0)
	previous_position = current_position
	if (
		elapsed >= MAX_DURATION or
		marks_emitted >= MAX_MARKS or
		(marks_emitted > 0 and planar_speed <= normal_move_speed + STOP_SPEED_MARGIN)
	):
		active = false
	return samples
```

为新 `.gd` 文件保留 Godot 生成的 `.uid` 文件。

- [ ] **Step 4：运行测试确认通过，并执行变异检查**

运行完整测试套件。然后暂时把 `SAMPLE_SPACING` 改为 `0.5`，确认字面量位置断言失败，再恢复 `0.36` 并重新运行通过；这证明测试能捕获真实采样回归。

- [ ] **Step 5：提交 Task 1**

```bash
git add scripts/fx/blood_trail_state.gd scripts/fx/blood_trail_state.gd.uid tests/unit/test_blood_trail_state.gd tests/unit/test_blood_trail_state.gd.uid tests/test_runner.gd
git commit -m "feat: add knockback blood trail sampling"
```

### Task 2：受光血迹网格、素材变体与有限叠加管理

**文件：**

- 新增：`assets/fx/blood/kenney_splat20.png`
- 新增：`assets/fx/blood/kenney_splat20.png.import`
- 新增：`assets/fx/blood/kenney_splat26.png`
- 新增：`assets/fx/blood/kenney_splat26.png.import`
- 新增：`assets/fx/blood/kenney_splat34.png`
- 新增：`assets/fx/blood/kenney_splat34.png.import`
- 修改：`assets/fx/blood/License.txt`
- 修改：`docs/assets/shooting-impact-assets.md`
- 修改：`scripts/fx/ground_blood_splat.gd`
- 修改：`scenes/fx/GroundBloodSplat.tscn`
- 修改：`scripts/fx/ground_blood_manager.gd`
- 修改：`scenes/gameplay/DemoArena.tscn:190-194`
- 修改：`tests/unit/test_ground_blood_manager.gd`

**接口：**

- 消费：Task 1 的拖痕采样字典；本任务不直接持有 `BloodTrailState`。
- 产出：`GroundBloodSplat.setup(surface_position: Vector3, surface_normal: Vector3, size: Vector2, rotation_radians: float, tint: Color, texture: Texture2D, roughness: float) -> void`
- 产出：`GroundBloodSplat.merge_limited(size_growth: float, darken_amount: float) -> void`
- 产出：`GroundBloodManager.spawn_hit_splat(hit_position: Vector3, shot_direction: Vector3, intensity: float = 1.0) -> GroundBloodSplat`
- 产出：`GroundBloodManager.spawn_trail_splat(world_position: Vector3, move_direction: Vector3, intensity: float, progress: float) -> GroundBloodSplat`
- 保留：`GroundBloodManager.spawn_death_pool(world_position: Vector3, intensity: float = 1.0) -> GroundBloodSplat`

- [ ] **Step 1：先改写管理器与材质契约测试，使现状失败**

重写 `tests/unit/test_ground_blood_manager.gd` 的调用为 `Vector2` 尺寸，并增加三个独立行为段：

```gdscript
var first := manager.call(
	"place_splat", Vector3.ZERO, Vector3.UP, Vector2(0.9, 1.1), 0.0,
	Color(0.42, 0.008, 0.015, 0.92), load("res://assets/fx/blood/kenney_splat29.png"), 0.38
) as GroundBloodSplat
```

材质与几何断言：

```gdscript
_append(failures, Assertions.expect_true(
	first is MeshInstance3D,
	"Persistent blood uses a lit mesh instance"
))
var material := first.material_override as StandardMaterial3D
_append(failures, Assertions.expect_true(
	material != null and material.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED,
	"Persistent blood keeps standard 3D lighting enabled"
))
_append(failures, Assertions.expect_true(
	material != null and
	material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR and
	material.cull_mode == BaseMaterial3D.CULL_DISABLED,
	"Blood uses alpha-scissored double-sided depth handling"
))
_append(failures, Assertions.expect_equal(
	first.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
	"Blood receives scene shadows without casting a floating plane shadow"
))
_append(failures, Assertions.expect_vector3_near(
	first.basis.z.normalized(), Vector3.UP, 0.0001,
	"Blood mesh normal aligns to the hit surface"
))
```

同格两层与第三次合并断言使用一个新管理器：前两次都放在 `Vector3(0.1, 0, 0.1)` 附近，确认子节点数为 `2`；第三次请求同格后确认子节点数仍为 `2`，返回实例 ID 属于前两个之一。再连续请求同一格十次，确认实例数仍为 `2`，且被合并实例的 `current_size` 任一轴不超过该实例 `base_size` 的 `1.15` 倍。

FIFO 断言继续使用相距大于 `0.45` 米的位置和 `max_splats = 3`，确认第四个不同格请求复用第一个实例，同时旧格索引不再包含该实例。

命中位置断言通过一个加入测试场景树的平面 `blood_surface` 调用 `spawn_hit_splat(Vector3(0.25, 1.2, -0.4), Vector3.RIGHT, 1.0)`，确认返回血迹的水平坐标为 `(0.25, -0.4)`，没有沿射击方向随机偏移。

- [ ] **Step 2：运行测试确认旧 Sprite3D/旧签名/随机偏移导致失败**

运行完整测试套件。预期失败至少包含：`place_splat` 参数数量不匹配、持久血迹不是 `MeshInstance3D`、第三次同格请求仍创建实例或没有合并接口。确认不是测试场景缺少主循环。

- [ ] **Step 3：下载并导入三个已确认的 CC0 纹理**

使用已核实的官方包：

```text
https://kenney.nl/media/pages/assets/splat-pack/1070534984-1677495350/kenney_splat-pack.zip
```

从压缩包的 `PNG/Default (256px)/` 提取 `splat20.png`、`splat26.png`、`splat34.png`，分别重命名为：

```text
assets/fx/blood/kenney_splat20.png
assets/fx/blood/kenney_splat26.png
assets/fx/blood/kenney_splat34.png
```

更新 `License.txt` 的 `Selected files` 为 `splat20.png, splat26.png, splat29.png, splat34.png`，并在 `docs/assets/shooting-impact-assets.md` 记录：主血斑使用 `26/29/34`，定向拖痕使用 `20/29`。运行 Godot headless editor 导入，保留三个 `.png.import` 文件。

- [ ] **Step 4：把持久血迹实现为受光 MeshInstance3D**

将 `GroundBloodSplat` 根类型改为 `MeshInstance3D`，使用单位 `QuadMesh`、透明 `StandardMaterial3D` 和现有 `surface_basis()`。实现必须保存以下可测试状态：

```gdscript
var base_size := Vector2.ONE
var current_size := Vector2.ONE
var current_tint := Color.WHITE
var current_surface_normal := Vector3.UP
var current_rotation := 0.0

func setup(
	surface_position: Vector3,
	surface_normal: Vector3,
	size: Vector2,
	random_rotation: float,
	tint: Color,
	texture: Texture2D,
	roughness: float
) -> void:
	var normal := surface_normal.normalized()
	if normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	base_size = Vector2(maxf(size.x, 0.05), maxf(size.y, 0.05))
	current_size = base_size
	current_tint = tint
	current_surface_normal = normal
	current_rotation = random_rotation
	var resolved_position := surface_position + normal * surface_offset
	if is_inside_tree():
		global_position = resolved_position
	else:
		position = resolved_position
	_apply_size_basis()
	var material := material_override as StandardMaterial3D
	material = material.duplicate() as StandardMaterial3D
	material.albedo_texture = texture
	material.albedo_color = tint
	material.roughness = clampf(roughness, 0.2, 0.8)
	material_override = material
	visible = true

func merge_limited(size_growth: float, darken_amount: float) -> void:
	var maximum_size := base_size * clampf(size_growth, 1.0, 1.15)
	current_size = Vector2(
		minf(current_size.x * 1.03, maximum_size.x),
		minf(current_size.y * 1.03, maximum_size.y)
	)
	current_tint = Color(
		maxf(current_tint.r - maxf(darken_amount, 0.0), 0.24),
		maxf(current_tint.g - maxf(darken_amount, 0.0) * 0.08, 0.002),
		maxf(current_tint.b - maxf(darken_amount, 0.0) * 0.08, 0.006),
		minf(current_tint.a + 0.02, 0.96)
	)
	_apply_size_basis()
	var material := material_override as StandardMaterial3D
	material.albedo_color = current_tint

func _apply_size_basis() -> void:
	var resolved_basis := surface_basis(
		current_surface_normal,
		current_rotation
	).scaled(Vector3(current_size.x, current_size.y, 1.0))
	if is_inside_tree():
		global_basis = resolved_basis
	else:
		basis = resolved_basis
```

场景使用单位 `QuadMesh(size = Vector2(1, 1))`。`StandardMaterial3D` 的固定初值为 `transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR`、`alpha_scissor_threshold = 0.25`、`cull_mode = BaseMaterial3D.CULL_DISABLED`、`shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL`、`metallic = 0.0`、`roughness = 0.4`；根节点 `cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF`。不要设置 unshaded。

- [ ] **Step 5：实现真实命中、拖痕造型、空间格和 FIFO 索引**

在 `GroundBloodManager` 中删除 `hit_splat_probability`，并从 `DemoArena.tscn` 删除对应覆盖值。加入固定资源与索引：

```gdscript
const HIT_TEXTURES: Array[Texture2D] = [
	preload("res://assets/fx/blood/kenney_splat26.png"),
	preload("res://assets/fx/blood/kenney_splat29.png"),
	preload("res://assets/fx/blood/kenney_splat34.png"),
]
const TRAIL_TEXTURES: Array[Texture2D] = [
	preload("res://assets/fx/blood/kenney_splat20.png"),
	preload("res://assets/fx/blood/kenney_splat29.png"),
]

@export var spatial_cell_size := 0.45
@export_range(1, 2, 1) var max_layers_per_cell := 2
var cell_splats: Dictionary = {}
var splat_cells: Dictionary = {}
```

`place_splat(...)` 先计算 `Vector2i(floor(position.x / 0.45), floor(position.z / 0.45))`。格子已有两层时调用其中一个实例的 `merge_limited(1.15, 0.015)` 并直接返回；否则 `_acquire_splat()`，先解除旧格注册，再 setup 并注册新格。

`spawn_hit_splat()` 必须直接执行 `_find_blood_surface(hit_position)`；尺寸范围为 `0.9～1.25` 米乘夹紧后的强度，高倍率总尺寸封顶 `1.4` 米，粗糙度 `0.32～0.42`。只允许旋转和纹理随机，不允许修改水平落点。

`spawn_trail_splat()` 直接投影采样点，使用 `Vector2(width, length)`：宽度从 `0.45` 向 `0.28` 插值，长度从 `0.8` 向 `0.5` 插值，粗糙度从 `0.45` 向 `0.6` 插值；方向角由 `atan2(move_direction.x, move_direction.z)` 得出，再加不超过 `±0.12` 弧度的小偏差。

`spawn_death_pool()` 使用 `1.15～1.4` 米的近方形尺寸和主血斑纹理，继续走空间格与全局上限。

- [ ] **Step 6：运行单元测试和导入检查**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

预期：新纹理全部导入，管理器测试通过；无脚本解析错误、无缺失资源、无透明材质警告。

- [ ] **Step 7：提交 Task 2**

```bash
git add assets/fx/blood docs/assets/shooting-impact-assets.md scripts/fx/ground_blood_splat.gd scenes/fx/GroundBloodSplat.tscn scripts/fx/ground_blood_manager.gd scenes/gameplay/DemoArena.tscn tests/unit/test_ground_blood_manager.gd
git commit -m "feat: add lit persistent blood splats"
```

### Task 3：僵尸实际击退接线、场景契约与完整验证

**文件：**

- 修改：`scripts/combat/zombie_target.gd:4-16,50-65,110-156,158-235,340-356`
- 修改：`scripts/gameplay/demo_arena.gd:130-160`
- 修改：`tests/unit/test_blood_impact.gd`
- 修改：`tests/integration/test_demo_scene.gd:273-279,313-375`
- 修改：`docs/superpowers/specs/2026-08-05-knockback-blood-trails-lighting-design.md`（仅在实现发现明确不一致时同步修正，不扩大范围）

**接口：**

- 消费：`BloodTrailState.start(...)`、`advance(...)`。
- 消费：`GroundBloodManager.spawn_hit_splat(...)`、`spawn_trail_splat(...)`、`spawn_death_pool(...)`。
- 新信号：`ZombieTarget.ground_blood_trail_requested(position: Vector3, direction: Vector3, intensity: float, progress: float)`。
- 保留并调整：`ground_blood_requested(origin: Vector3, direction: Vector3, intensity: float, death_pool: bool)`；每次有效命中都先用真实 `hit_position` 发普通主血斑请求，击杀时额外在僵尸位置发死亡血池请求。

- [ ] **Step 1：先补失败的信号和场景接线测试**

在 `tests/unit/test_blood_impact.gd` 中连接两个信号并调用一次非致死 `apply_hit()`：

```gdscript
var hit_requests: Array[Dictionary] = []
var trail_requests: Array[Dictionary] = []
target.ground_blood_requested.connect(func(
	origin: Vector3, direction: Vector3, intensity: float, death_pool: bool
) -> void:
	hit_requests.append({
		"origin": origin,
		"direction": direction,
		"intensity": intensity,
		"death_pool": death_pool,
	})
)
target.ground_blood_trail_requested.connect(func(
	position: Vector3, direction: Vector3, intensity: float, progress: float
) -> void:
	trail_requests.append({
		"position": position,
		"direction": direction,
		"intensity": intensity,
		"progress": progress,
	})
)
```

断言命中请求恰好一次、`origin == hit_position`、`death_pool == false`，并断言 target 内部的 `blood_trail_state.active == true`。在未调用 `apply_hit()` 的新 target 上直接执行一次正常移动更新，断言不会发出拖痕请求。

在 `tests/integration/test_demo_scene.gd` 的每只僵尸循环中新增：

```gdscript
_append(failures, Assertions.expect_true(
	target.ground_blood_trail_requested.is_connected(
		Callable(arena, "_on_ground_blood_trail_requested")
	),
	"Every arena target forwards real knockback movement to the blood manager"
))
```

- [ ] **Step 2：运行测试确认缺少新信号和状态接线**

运行完整测试套件。预期失败信息为 `ground_blood_trail_requested` 或 `blood_trail_state` 不存在，以及 Demo 没有 `_on_ground_blood_trail_requested`；已有瞬时 `BloodImpact` 测试仍应通过。

- [ ] **Step 3：在 ZombieTarget 中开启并推进拖痕会话**

加入：

```gdscript
const BloodTrailState = preload("res://scripts/fx/blood_trail_state.gd")

signal ground_blood_trail_requested(
	position: Vector3,
	direction: Vector3,
	intensity: float,
	progress: float
)

var blood_trail_state := BloodTrailState.new()
```

在有效命中且击退速度写入后：

```gdscript
blood_trail_state.start(global_position, knockback_multiplier)
ground_blood_requested.emit(hit_position, shot_direction, knockback_multiplier, false)
if killed:
	ground_blood_requested.emit(global_position, shot_direction, 1.25, true)
```

删除旧的“击杀时用 global_position 替代真实 hit_position”的单次 emit 分支。

在 `_physics_process()` 中调用 `move_and_slide()` 后：

```gdscript
var trail_samples := blood_trail_state.advance(
	global_position,
	delta,
	Vector2(velocity.x, velocity.z).length(),
	perception_move_speed
)
for sample in trail_samples:
	ground_blood_trail_requested.emit(
		sample["position"],
		sample["direction"],
		sample["intensity"],
		sample["progress"]
	)
```

`_on_depleted()` 不创建额外计时器；现有 `0.65` 秒死亡动画期间仍可报告真实移动，节点离树后状态自然销毁。新的命中通过 `start()` 重置旧会话。

- [ ] **Step 4：在 DemoArena 接线拖痕管理器**

扩展 `_wire_target_blood()`：

```gdscript
if not zombie.ground_blood_trail_requested.is_connected(
	_on_ground_blood_trail_requested
):
	zombie.ground_blood_trail_requested.connect(_on_ground_blood_trail_requested)
```

新增：

```gdscript
func _on_ground_blood_trail_requested(
	position: Vector3,
	direction: Vector3,
	intensity: float,
	progress: float
) -> void:
	var manager := get_node("GroundBloodManager") as GroundBloodManager
	manager.spawn_trail_splat(position, direction, intensity, progress)
```

保留 `_on_ground_blood_requested()` 对普通主血斑和死亡血池的分派，不新增清理输入。

- [ ] **Step 5：运行完整自动验证**

依次运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
mkdir -p build/web
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release Web build/web/index.html
```

预期：编辑器导入无解析错误；完整测试全部通过；Web 导出成功。`build/` 仍受忽略，不加入提交。

- [ ] **Step 6：运行 Demo 人工视觉验收**

启动：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

验收以下具体场景：

1. 从正面和斜侧面各射击一只僵尸，确认大血斑位于真实命中坐标正下方。
2. 让僵尸向空地后退，确认拖痕沿真实路径出现且正常追击后停止。
3. 把僵尸击退到边界或道具旁，确认拖痕跟随碰撞后的滑动方向，不穿过障碍直线绘制。
4. 连续射击同一小区域，确认最多两层可见面片，后续只有限扩大或加深。
5. 观察僵尸、玩家或场景道具阴影经过血迹，确认血迹与周围地面一起变暗；阴影移开后恢复。
6. 确认没有血迹投射出的矩形悬浮阴影、明显 Z-fighting、透明排序闪烁或正常行走持续流血。

- [ ] **Step 7：提交 Task 3**

```bash
git add scripts/combat/zombie_target.gd scripts/gameplay/demo_arena.gd tests/unit/test_blood_impact.gd tests/integration/test_demo_scene.gd docs/superpowers/specs/2026-08-05-knockback-blood-trails-lighting-design.md
git commit -m "feat: trace blood along zombie knockback"
```

## 计划自审

- 规格覆盖：Task 1 覆盖真实位移采样和停止边界；Task 2 覆盖大血斑、拖痕造型、素材、光照阴影、两层叠加与 192 上限；Task 3 覆盖 Zombie/Demo 数据流和完整验证。
- 范围控制：没有清理 UI、Forward+、Decal3D、墙面血迹、角色表面伤口或伤害/AI 调整。
- 类型一致：Task 1 返回字典字段与 Task 3 的信号参数一致；Task 2 的 `spawn_trail_splat()` 参数与 Demo handler 一致；持久血迹尺寸统一使用 `Vector2`。
- TDD 顺序：三个任务均先写可观察行为测试并运行失败，再实现生产代码；素材与场景修改包含在 Task 2 的失败契约之后。
- 工作量：共 3 个可独立审查任务，符合 AGENTS.md 的不超过 4 个任务约束。
