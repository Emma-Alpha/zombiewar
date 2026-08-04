# 枪口、辅助瞄准线与弹道线修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让常驻辅助瞄准线与瞬时射击弹道清晰区分，并让枪口火焰、辅助线和弹道都从 Rifle 的真实枪管尖端出现。

**Architecture:** `PlayerWeapon` 继续分离稳定的功能射线原点与实时视觉枪口：命中判定使用 `FunctionalRayOrigin`，视觉反馈使用跟随 Rifle 动画的 `Muzzle`。`AimIndicator` 改为五段青色半透明虚线，由武器每帧对齐实时枪口和实际瞄准方向；`ShotTracer` 保持池化，只把视觉起点改为枪口。

**Tech Stack:** Godot 4.7.1、GDScript、Godot Scene (`.tscn`)、现有自定义无框架测试运行器。

## Global Constraints

- 辅助瞄准线必须常驻显示，使用五段短、细、半透明的青色虚线，总长度约 `2.4` 米。
- 射击弹道必须使用明亮橙黄色实线，从枪口延伸到命中点或最大射程，并在约 `0.08` 秒内消失。
- Rifle 局部枪口偏移使用 `Vector3(0.84, 0.31, 0.61)`。
- 枪口火焰、辅助瞄准线和射击弹道必须共享实时 `Muzzle.global_position` 作为视觉起点。
- 物理射线、辅助瞄准选择和伤害判定继续使用稳定的 `FunctionalRayOrigin.global_position`。
- 不改变射速、伤害、最大射程、辅助瞄准规则、相机后坐或弹道对象池容量。
- 玩家死亡后隐藏辅助瞄准线；已显示弹道按自身生命周期结束。
- 严格执行 TDD：每个生产代码改动前先添加能因当前缺陷正确失败的测试，并实际运行确认 RED。
- 当前工作区已有大量属于用户的相关未提交改动；只修改本计划明确列出的文件，不覆盖或回退其他改动。
- 按项目约定，任务代理和主代理都不创建提交；整套计划完成后由用户自行提交。

---

## 文件职责与改动范围

- `scenes/player/Player.tscn`：装配枪口、五段辅助瞄准虚线、枪口火焰和射击音效。
- `scripts/combat/player_weapon.gd`：绑定 Rifle 枪口、同步辅助线空间变换、区分功能射线起点与视觉弹道起点。
- `scripts/player/player_controller.gd`：玩家死亡时通过武器接口隐藏辅助瞄准线。
- `tests/unit/test_weapon_feedback.gd`：验证真实枪口位置、辅助线结构/材质/方向、后坐跟随和功能射线稳定性。
- `tests/unit/test_player_damage.gd`：验证玩家死亡会隐藏辅助瞄准线。
- `tests/unit/test_tracer_pool.gd`：验证实际开枪时弹道近端来自实时枪口、弹道按时停用且对象池继续复用。

### Task 1: 修正 Rifle 枪口并实现青色虚线辅助瞄准

**Files:**
- Modify: `scenes/player/Player.tscn`
- Modify: `scripts/combat/player_weapon.gd`
- Modify: `scripts/player/player_controller.gd`
- Modify: `tests/unit/test_weapon_feedback.gd`
- Modify: `tests/unit/test_player_damage.gd`
- Modify: `tests/integration/test_demo_scene.gd`

**Interfaces:**
- Consumes: `PlayerWeapon.bind_visual_anchor(anchor: Node3D)`, `PlayerWeapon.set_combat_input(bool, bool, Vector3)`、现有 `Muzzle`、Rifle 动画节点和 `WeaponMath.flat_direction(Vector3)`。
- Produces: `PlayerWeapon.set_aim_indicator_visible(value: bool) -> void`；`Weapon/AimIndicator` 顶层视觉根节点；`PlayerWeapon.muzzle_anchor_offset = Vector3(0.84, 0.31, 0.61)`。

- [ ] **Step 1: 在武器反馈测试中定义枪口和辅助瞄准行为**

在 `tests/unit/test_weapon_feedback.gd` 中取得新的节点路径并添加以下真实场景断言。测试要捕获的生产缺陷是：枪口仍沿局部 `-Z`、辅助线仍是玩家脚下的橙色连续线，或辅助线没有跟随实时枪口和实际瞄准方向。

```gdscript
var aim_indicator := weapon.get_node_or_null("AimIndicator") as Node3D
_append(failures, Assertions.expect_vector3_near(
	weapon.muzzle.position,
	Vector3(0.84, 0.31, 0.61),
	0.0001,
	"Visual muzzle uses the Rifle local barrel-tip offset"
))
_append(failures, Assertions.expect_true(
	aim_indicator != null and aim_indicator.visible,
	"Weapon has a visible persistent aim guide"
))

var aim_segments: Array[MeshInstance3D] = []
if aim_indicator != null:
	for child in aim_indicator.get_children():
		if child is MeshInstance3D:
			aim_segments.append(child as MeshInstance3D)
_append(failures, Assertions.expect_equal(
	aim_segments.size(),
	5,
	"Aim guide uses five separated segments"
))
if not aim_segments.is_empty():
	var segment_mesh := aim_segments[0].mesh as BoxMesh
	var segment_material: StandardMaterial3D
	if segment_mesh != null:
		segment_material = segment_mesh.material as StandardMaterial3D
	_append(failures, Assertions.expect_true(
		segment_material != null and
		segment_material.albedo_color.b > segment_material.albedo_color.r and
		segment_material.albedo_color.a < 0.6,
		"Aim guide is translucent and cyan rather than tracer orange"
	))
```

在玩家进入测试树后注入 `Vector3.RIGHT`，调用真实武器更新并检查空间结果：

```gdscript
weapon.set_combat_input(false, false, Vector3.RIGHT)
weapon._process(0.0)
_append(failures, Assertions.expect_vector3_near(
	aim_indicator.global_position,
	weapon.muzzle.global_position,
	0.0001,
	"Aim guide starts at the live visual muzzle"
))
_append(failures, Assertions.expect_vector3_near(
	-aim_indicator.global_basis.z,
	Vector3.RIGHT,
	0.0001,
	"Aim guide points along the actual aim direction"
))
```

扩展现有视觉后坐断言：在移动 `VisualRoot` 并调用 `weapon._process(0.0)` 后，辅助线世界位置必须继续与新枪口位置重合，而现有 `FunctionalRayOrigin` 稳定性断言保持通过。

- [ ] **Step 2: 在玩家伤害测试中定义死亡隐藏行为**

在 `tests/unit/test_player_damage.gd` 中于致命伤害前取得 `Player/Weapon/AimIndicator`，致命伤害后添加：

```gdscript
var aim_indicator := player.get_node("Weapon/AimIndicator") as Node3D
# ...现有致命伤害调用与存活断言...
_append(failures, Assertions.expect_true(
	not aim_indicator.visible,
	"Player death hides the persistent aim guide"
))
```

该断言必须通过真实 `PlayerController._on_depleted()` 路径触发，不直接调用武器隐藏方法。

- [ ] **Step 3: 迁移 Demo 集成测试到新的辅助线节点路径**

在 `tests/integration/test_demo_scene.gd` 中把对旧玩家根节点的查找改为新的武器子节点，并保留它默认可见的集成契约：

```gdscript
var aim_indicator := arena.get_node_or_null("Player/Weapon/AimIndicator") as Node3D
_append(failures, Assertions.expect_true(
	aim_indicator != null and aim_indicator.visible,
	"Player has a visible keyboard aim indicator"
))
```

该变更是场景节点从 `Player/AimIndicator` 移到 `Weapon/AimIndicator` 的必要测试迁移；不修改其他 Demo 场景契约。

- [ ] **Step 4: 运行测试并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/yewei/yyw/project/zombiewar --script res://tests/test_runner.gd
```

Expected: FAIL，至少包含枪口偏移不等于 `Vector3(0.84, 0.31, 0.61)`、`Weapon/AimIndicator` 不存在或死亡后辅助线未隐藏；失败来自当前行为而不是解析错误。

- [ ] **Step 5: 用五段共享网格实现辅助瞄准视觉**

修改 `scenes/player/Player.tscn`：

1. 删除玩家根节点下现有单根 `AimIndicator`。
2. 把辅助线材质改为以下共享资源：

```text
[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_aim_indicator"]
transparency = 1
shading_mode = 0
albedo_color = Color(0.2, 0.85, 1, 0.42)
emission_enabled = true
emission = Color(0.15, 0.75, 1, 1)
emission_energy_multiplier = 1.4

[sub_resource type="BoxMesh" id="BoxMesh_aim_indicator"]
material = SubResource("StandardMaterial3D_aim_indicator")
size = Vector3(0.025, 0.012, 0.3)
```

3. 在 `Weapon` 下新增根节点和五个共享同一 `BoxMesh` 的段：

```text
[node name="AimIndicator" type="Node3D" parent="Weapon"]

[node name="Segment1" type="MeshInstance3D" parent="Weapon/AimIndicator"]
position = Vector3(0, 0, -0.24)
cast_shadow = 0
mesh = SubResource("BoxMesh_aim_indicator")

[node name="Segment2" type="MeshInstance3D" parent="Weapon/AimIndicator"]
position = Vector3(0, 0, -0.72)
cast_shadow = 0
mesh = SubResource("BoxMesh_aim_indicator")

[node name="Segment3" type="MeshInstance3D" parent="Weapon/AimIndicator"]
position = Vector3(0, 0, -1.2)
cast_shadow = 0
mesh = SubResource("BoxMesh_aim_indicator")

[node name="Segment4" type="MeshInstance3D" parent="Weapon/AimIndicator"]
position = Vector3(0, 0, -1.68)
cast_shadow = 0
mesh = SubResource("BoxMesh_aim_indicator")

[node name="Segment5" type="MeshInstance3D" parent="Weapon/AimIndicator"]
position = Vector3(0, 0, -2.16)
cast_shadow = 0
mesh = SubResource("BoxMesh_aim_indicator")
```

- [ ] **Step 6: 让武器同步枪口和辅助线**

在 `scripts/combat/player_weapon.gd` 中将导出默认值改为：

```gdscript
@export var muzzle_anchor_offset := Vector3(0.84, 0.31, 0.61)
```

新增节点引用：

```gdscript
@onready var aim_indicator: Node3D = $AimIndicator
```

在 `_ready()` 中让辅助线脱离 Rifle 局部旋转继承，同时保持池预热：

```gdscript
func _ready() -> void:
	fire_gate = FireGate.new(1.0 / shots_per_second)
	aim_indicator.top_level = true
	_prewarm_tracers()
```

在 `_process()` 同步 Rifle 后调用辅助线更新：

```gdscript
func _process(_delta: float) -> void:
	if visual_anchor != null and is_instance_valid(visual_anchor):
		global_transform = visual_anchor.global_transform
	_update_aim_indicator()

func _update_aim_indicator() -> void:
	if aim_indicator == null or not is_instance_valid(aim_indicator):
		return
	var direction := WeaponMath.flat_direction(aim_direction)
	aim_indicator.global_position = muzzle.global_position
	aim_indicator.look_at(aim_indicator.global_position + direction, Vector3.UP)

func set_aim_indicator_visible(value: bool) -> void:
	if aim_indicator != null and is_instance_valid(aim_indicator):
		aim_indicator.visible = value
```

`bind_visual_anchor()` 继续执行 `muzzle.position = muzzle_anchor_offset`，从而把新偏移应用到 Rifle 局部空间。

- [ ] **Step 7: 通过武器接口隐藏死亡玩家的辅助线**

在 `scripts/player/player_controller.gd::_on_depleted()` 中用以下调用替换旧的玩家根节点查找逻辑：

```gdscript
weapon.set_aim_indicator_visible(false)
```

不要保留对旧路径 `get_node_or_null("AimIndicator")` 的访问。

- [ ] **Step 8: 运行测试并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/yewei/yyw/project/zombiewar --script res://tests/test_runner.gd
```

Expected: 本计划涉及的测试均通过，输出无解析错误。若全量运行仍只保留任务开始前已存在的中文字体失败，记录其完整输出并确认没有本计划新增失败。

- [ ] **Step 9: 自审并写任务报告，不提交**

检查五个线段共享同一 `BoxMesh`/材质、辅助线没有被 Rifle 局部旋转带偏、只改动列出的文件。把测试命令、RED 失败摘要、GREEN 输出和自审结果写入 SDD 任务报告；不要运行 `git commit`。

### Task 2: 让池化弹道从实时枪口发出并验证生命周期

**Files:**
- Modify: `scripts/combat/player_weapon.gd`
- Modify: `tests/unit/test_tracer_pool.gd`

**Interfaces:**
- Consumes: Task 1 产生的实时 `PlayerWeapon.muzzle.global_position`、现有 `_acquire_tracer() -> ShotTracer`、`ShotTracer.setup(from: Vector3, to: Vector3)` 和稳定 `get_ray_origin() -> Vector3`。
- Produces: `_fire()` 使用功能起点进行命中判定、使用视觉枪口进行弹道绘制的双起点行为。

- [ ] **Step 1: 用真实开枪路径添加弹道起点回归测试**

修改 `tests/unit/test_tracer_pool.gd`，让实例化玩家进入真实 `SceneTree`，不要手动调用 `weapon._ready()`：

```gdscript
var player := PLAYER_SCENE.instantiate() as PlayerController
var tree := Engine.get_main_loop() as SceneTree
tree.root.add_child(player)
var weapon := player.get_node("Weapon") as PlayerWeapon
```

在任何会移动 `tracer_pool_cursor` 的循环之前，刻意让功能起点与视觉枪口不同，再走真实 `_fire()`：

```gdscript
var functional_origin := player.get_node("FunctionalRayOrigin") as Marker3D
functional_origin.global_position += Vector3(0.4, 0.0, 0.0)
var visual_origin := weapon.muzzle.global_position
weapon.call("_fire", player, Vector3.FORWARD)

var fired_tracer := tracers[0] as ShotTracer
var tracer_near_end := fired_tracer.to_global(Vector3(0.0, 0.0, 0.5))
_append(failures, Assertions.expect_vector3_near(
	tracer_near_end,
	visual_origin,
	0.001,
	"Fired tracer starts at the live visual muzzle"
))
```

该测试要捕获的生产缺陷是 `_fire()` 仍把稳定功能射线原点传给 `tracer.setup()`。预期值直接来自开枪前的真实 `Muzzle.global_position`，不复用生产代码的起点选择逻辑。

- [ ] **Step 2: 添加弹道生命周期的真实状态断言**

紧接真实开枪断言，推进超过生命周期并验证视觉和处理状态：

```gdscript
_append(failures, Assertions.expect_true(
	fired_tracer.visible and fired_tracer.is_processing(),
	"Fired tracer becomes visible and active"
))
fired_tracer._process(fired_tracer.lifetime + 0.001)
_append(failures, Assertions.expect_true(
	not fired_tracer.visible and not fired_tracer.is_processing(),
	"Fired tracer deactivates after its lifetime"
))
```

保留现有对象池数量、共享网格/材质、物理插值关闭和循环复用断言。

- [ ] **Step 3: 运行测试并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/yewei/yyw/project/zombiewar --script res://tests/test_runner.gd
```

Expected: FAIL，`Fired tracer starts at the live visual muzzle` 显示约 `0.4` 米偏差；生命周期和原有池测试不应出现解析错误。

- [ ] **Step 4: 将视觉弹道起点切换到实时枪口**

在 `scripts/combat/player_weapon.gd::_fire()` 中保留 `ray_origin` 用于 `direct_end`、物理射线、辅助瞄准和 `shot_fired` 信号，只修改弹道设置调用：

```gdscript
var tracer := _acquire_tracer()
tracer.setup(muzzle.global_position, hit_position)
muzzle_flash.flash()
```

不要把物理射线改为从 `muzzle.global_position` 发出，也不要改变 `shot_fired.emit(ray_origin, ray_direction, hit_result)` 的现有信号语义。

- [ ] **Step 5: 运行测试并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/yewei/yyw/project/zombiewar --script res://tests/test_runner.gd
```

Expected: `PASS: 23 test file(s)`；弹道起点、生命周期、对象池复用以及全部既有测试通过。

- [ ] **Step 6: 执行静态检查和变更范围检查**

Run:

```bash
git diff --check
git status --short
```

Expected: `git diff --check` 无输出；本计划只新增/修改以下目标文件中的计划内差异：

```text
scenes/player/Player.tscn
scripts/combat/player_weapon.gd
scripts/player/player_controller.gd
tests/unit/test_weapon_feedback.gd
tests/unit/test_player_damage.gd
tests/integration/test_demo_scene.gd
tests/unit/test_tracer_pool.gd
```

工作区中原有其他未提交文件保持不变。

- [ ] **Step 7: 手动视觉验收**

运行项目进入 Demo：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path /Users/yewei/yyw/project/zombiewar
```

验证：未开枪时只常驻五段短青色虚线；辅助线从枪管尖端开始；按 `J` 后橙黄色弹道从同一尖端出现并约 `0.08` 秒后消失；连续射击、移动、转向和后坐时没有橙色残留线，命中行为不变。

- [ ] **Step 8: 自审并写任务报告，不提交**

把测试命令、RED 失败摘要、GREEN 输出、静态检查和手动验收结果写入 SDD 任务报告。确认没有改变功能射线语义、弹道池容量或其他用户改动；不要运行 `git commit`。

## 完成条件

- Task 1 和 Task 2 都完成各自 RED → GREEN 循环。
- 每个任务分别通过规格符合性和代码质量审查，重要问题完成修复与复审。
- 最终全量代码审查无未解决的关键或重要问题。
- 本计划涉及的测试文件通过；全量运行除任务开始前存在的独立中文字体失败外不得新增失败，且 `git diff --check` 无输出。
- 手动视觉验收满足辅助瞄准线与射击弹道的区分、真实枪口起点和弹道自动消失要求。
- 不创建代理提交；最终变更保留在工作区供用户检查和提交。
