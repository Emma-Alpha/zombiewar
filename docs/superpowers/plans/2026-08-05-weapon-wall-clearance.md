# 枪械贴墙碰撞与自动抬枪 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为手枪和步枪增加贴合模型的墙体胶囊碰撞，在空间不足时绕现有左手挂点自动抬枪，并在抬枪期间可靠禁止射击。

**Architecture:** 用纯逻辑 `WeaponClearanceState` 管理 `DISABLED/NORMAL/RAISED`、恢复滞回和射击释放门闩；`WeaponClearanceController` 负责两个 `ShapeCast3D`、玩家直属 `CollisionShape3D` 和武器视觉插值。`PlayerController` 在应用转向、移动和攻击输入前调用控制器，现有 `EquipmentController`、命中射线、伤害与枪口反馈保持原职责。

**Tech Stack:** Godot 4.7.1、GDScript、Godot 3D Physics、Godot Scene (`.tscn`)、现有 `RefCounted.run() -> Array[String]` 自定义测试运行器。

## Global Constraints

- 规格依据：`docs/superpowers/specs/2026-08-05-weapon-wall-clearance-design.md`。
- 玩家主体胶囊继续使用半径 `0.45m`、总高 `1.8m`，不能为了枪械穿墙而扩大人物主体。
- 手枪胶囊总长 `0.94m`、半径 `0.10m`；步枪胶囊总长 `1.55m`、半径 `0.12m`。
- 枪械胶囊长度必须只比源 GLTF 网格主轴包围盒多 `0.05–0.10m`；中心偏移可在视觉验收中微调，半径不能明显扩大枪身宽度。
- 默认抬枪角 `65°`，视觉抬起和放下时间均为 `0.15s`。
- 正常姿态连续无碰撞 `0.15s` 后才放下，恢复检测向枪口方向增加 `0.08m` 余量。
- 手枪和步枪使用枪械墙体碰撞；匕首、卸下武器和玩家死亡时关闭枪械碰撞并恢复视觉局部变换。
- 枪械胶囊只碰撞世界第 1 层，不与僵尸、受弹 Area 或其他非墙体实体发生物理碰撞。
- 抬枪状态和视觉放下过渡期间禁止射击；抬枪时按住攻击键不能缓存，恢复后必须释放并重新按下。
- 保持现有射线命中、伤害、射速、枪口火焰、曳光弹、辅助瞄准和后坐逻辑不变。
- 不新增角色骨骼动画，不使用 IK；允许步枪抬起时右手短暂离开护木。
- 严格执行 TDD：每个生产改动前先写会因当前缺陷失败的测试，并实际确认 RED。
- 执行本计划前先检查工作区；本计划会修改共享的 `tests/test_runner.gd`，若主工作区存在 Cloudflare 或其他并行改动，优先创建隔离 worktree，不能覆盖、回退或误提交用户工作。
- 本计划共 3 个任务；每个任务结束时运行相关测试并创建一个 Conventional Commit。

---

## 文件职责与改动范围

- `scripts/combat/weapons/ranged_weapon_definition.gd`：定义远程武器墙体胶囊配置和有效性检查。
- `resources/weapons/pistol.tres`：提供手枪胶囊长度、半径、中心偏移和抬枪角。
- `resources/weapons/rifle.tres`：提供步枪胶囊长度、半径、中心偏移和抬枪角。
- `scripts/player/weapon_clearance_state.gd`：纯逻辑状态机；不访问场景树或物理服务器。
- `scripts/player/weapon_clearance_controller.gd`：空间检测、物理胶囊姿态、视觉挂点插值和射击门闩的场景适配层。
- `scenes/player/Player.tscn`：装配直属枪械碰撞体、控制器和两个查询节点。
- `scripts/player/player_controller.gd`：在转向、移动、射击、切枪和死亡流程中调用墙体空间控制器。
- `tests/unit/test_weapon_configuration.gd`：验证手枪和步枪墙体胶囊资源数据。
- `tests/unit/test_weapon_clearance_state.gd`：验证纯状态转换、滞回和射击释放门闩。
- `tests/unit/test_weapon_clearance_controller.gd`：验证场景绑定、胶囊装配、挂点旋转和近战/死亡重置。
- `tests/integration/test_weapon_wall_clearance.gd`：使用真实 `StaticBody3D` 墙体验证抬枪、转向、切枪与射击阻断。
- `tests/integration/test_demo_scene.gd`：补充 Demo 场景拥有墙体空间系统的契约，不改动其他断言。
- `tests/test_runner.gd`：注册两份新单元测试和一份新集成测试。

## 固定接口

后续任务统一使用以下接口名，实施时不要另造近义方法：

```gdscript
# scripts/player/weapon_clearance_state.gd
func configure(enabled: bool, normal_clear: bool, raised_clear: bool) -> void
func update(delta: float, normal_clear: bool, raised_clear: bool) -> bool
func observe_trigger(trigger_pressed: bool) -> void
func can_fire(visual_settled: bool) -> bool
func reset() -> void

# scripts/player/weapon_clearance_controller.gd
func setup(value_wielder: CharacterBody3D) -> void
func bind_weapon(weapon: WeaponBase) -> void
func resolve_facing_yaw(
	delta: float,
	desired_motion: Vector3,
	target_yaw: float
) -> float
func observe_trigger(trigger_pressed: bool) -> void
func can_fire() -> bool
func is_raised() -> bool
func reset() -> void
```

---

### Task 1: 增加武器净空配置与纯状态机

**Files:**
- Modify: `scripts/combat/weapons/ranged_weapon_definition.gd`
- Modify: `resources/weapons/pistol.tres`
- Modify: `resources/weapons/rifle.tres`
- Create: `scripts/player/weapon_clearance_state.gd`
- Create: `tests/unit/test_weapon_clearance_state.gd`
- Modify: `tests/unit/test_weapon_configuration.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: 现有 `RangedWeaponDefinition`、手枪/步枪 `.tres` 和 `Assertions`。
- Produces: `RangedWeaponDefinition.has_wall_clearance_profile() -> bool`；`WeaponClearanceState` 及固定接口中的五个方法；Task 2 依赖的四个资源字段。

- [ ] **Step 1: 在武器配置测试中定义胶囊资源契约**

在 `tests/unit/test_weapon_configuration.gd` 加载手枪和步枪后添加以下断言：

```gdscript
_append(failures, Assertions.expect_float_near(
	pistol.wall_capsule_length,
	0.94,
	0.0001,
	"Pistol wall capsule length follows its visible model"
))
_append(failures, Assertions.expect_float_near(
	pistol.wall_capsule_radius,
	0.10,
	0.0001,
	"Pistol wall capsule stays narrow"
))
_append(failures, Assertions.expect_float_near(
	rifle.wall_capsule_length,
	1.55,
	0.0001,
	"Rifle wall capsule length follows its visible model"
))
_append(failures, Assertions.expect_float_near(
	rifle.wall_capsule_radius,
	0.12,
	0.0001,
	"Rifle wall capsule stays narrow"
))
_append(failures, Assertions.expect_true(
	pistol.has_wall_clearance_profile() and
	rifle.has_wall_clearance_profile(),
	"Ranged weapons expose valid wall-clearance profiles"
))
_append(failures, Assertions.expect_true(
	pistol.wall_capsule_offset != rifle.wall_capsule_offset,
	"Each firearm owns its fitted capsule center"
))
```

- [ ] **Step 2: 新建状态机测试并注册测试路径**

创建 `tests/unit/test_weapon_clearance_state.gd`，完整覆盖以下顺序：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const WeaponClearanceState = preload(
	"res://scripts/player/weapon_clearance_state.gd"
)

func run() -> Array[String]:
	var failures: Array[String] = []
	var state := WeaponClearanceState.new(0.15)

	state.configure(true, true, true)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.NORMAL,
		"Clear firearm starts in the normal pose"
	))

	var changed := state.update(0.016, false, true)
	_append(failures, Assertions.expect_true(
		changed and state.pose == WeaponClearanceState.Pose.RAISED,
		"Blocked normal pose raises when raised space is clear"
	))
	_append(failures, Assertions.expect_true(
		not state.can_fire(true),
		"Raised pose blocks firing"
	))

	state.observe_trigger(true)
	state.update(0.14, true, true)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.RAISED,
		"Normal space must remain clear for the full restore delay"
	))
	state.update(0.01, true, true)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.NORMAL,
		"Normal pose restores after the full clear delay"
	))
	_append(failures, Assertions.expect_true(
		not state.can_fire(true),
		"Held trigger remains latched after lowering"
	))
	state.observe_trigger(false)
	_append(failures, Assertions.expect_true(
		state.can_fire(true),
		"Trigger release unlocks firing after lowering"
	))

	state.update(0.016, false, false)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.NORMAL,
		"State keeps the last legal pose when neither target pose is clear"
	))
	state.configure(false, false, false)
	_append(failures, Assertions.expect_equal(
		state.pose,
		WeaponClearanceState.Pose.DISABLED,
		"Melee weapon disables firearm clearance"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在 `tests/test_runner.gd` 的武器配置测试之后注册：

```gdscript
"res://tests/unit/test_weapon_clearance_state.gd",
```

- [ ] **Step 3: 运行全量测试并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/yewei/yyw/project/zombiewar --script res://tests/test_runner.gd
```

Expected: FAIL；至少包含 `wall_capsule_length`/`has_wall_clearance_profile` 未定义或 `weapon_clearance_state.gd` 无法加载。若隔离 worktree 中仍有任务开始前的失败，记录完整基线，但本步骤必须确认新增测试确实因缺少本任务行为而失败。

- [ ] **Step 4: 为远程武器定义增加净空配置**

在 `scripts/combat/weapons/ranged_weapon_definition.gd` 现有字段后添加：

```gdscript
@export_group("Wall Clearance")
@export_range(0.0, 3.0, 0.01) var wall_capsule_length := 0.0
@export_range(0.0, 0.5, 0.01) var wall_capsule_radius := 0.0
@export var wall_capsule_offset := Vector3.ZERO
@export_range(0.0, 90.0, 1.0) var wall_raise_angle_degrees := 65.0

func has_wall_clearance_profile() -> bool:
	return (
		is_finite(wall_capsule_length) and
		is_finite(wall_capsule_radius) and
		is_finite(wall_capsule_offset.x) and
		is_finite(wall_capsule_offset.y) and
		is_finite(wall_capsule_offset.z) and
		wall_capsule_radius > 0.0 and
		wall_capsule_length >= wall_capsule_radius * 2.0
	)
```

资源中的 `wall_capsule_offset` 定义为玩家局部空间的正常持枪胶囊中心；`-Z` 是玩家枪口前方。把以下值加入对应资源：

```text
# resources/weapons/pistol.tres
wall_capsule_length = 0.94
wall_capsule_radius = 0.10
wall_capsule_offset = Vector3(0, 1.12, -0.42)
wall_raise_angle_degrees = 65.0

# resources/weapons/rifle.tres
wall_capsule_length = 1.55
wall_capsule_radius = 0.12
wall_capsule_offset = Vector3(0, 1.12, -0.62)
wall_raise_angle_degrees = 65.0
```

- [ ] **Step 5: 实现不依赖场景树的状态机**

创建 `scripts/player/weapon_clearance_state.gd`：

```gdscript
extends RefCounted
class_name WeaponClearanceState

enum Pose {
	DISABLED,
	NORMAL,
	RAISED,
}

var pose := Pose.DISABLED
var restore_delay: float
var restore_elapsed := 0.0
var fire_release_required := false

func _init(value_restore_delay := 0.15) -> void:
	restore_delay = maxf(value_restore_delay, 0.0)

func configure(enabled: bool, normal_clear: bool, raised_clear: bool) -> void:
	reset()
	if not enabled:
		return
	if normal_clear:
		pose = Pose.NORMAL
	elif raised_clear:
		_enter_raised()
	else:
		pose = Pose.NORMAL

func update(delta: float, normal_clear: bool, raised_clear: bool) -> bool:
	var previous_pose := pose
	match pose:
		Pose.NORMAL:
			if not normal_clear and raised_clear:
				_enter_raised()
		Pose.RAISED:
			if normal_clear:
				restore_elapsed += maxf(delta, 0.0)
				if restore_elapsed >= restore_delay:
					pose = Pose.NORMAL
					restore_elapsed = 0.0
			else:
				restore_elapsed = 0.0
	return pose != previous_pose

func observe_trigger(trigger_pressed: bool) -> void:
	if not trigger_pressed:
		fire_release_required = false

func can_fire(visual_settled: bool) -> bool:
	return (
		pose == Pose.NORMAL and
		visual_settled and
		not fire_release_required
	)

func reset() -> void:
	pose = Pose.DISABLED
	restore_elapsed = 0.0
	fire_release_required = false

func _enter_raised() -> void:
	pose = Pose.RAISED
	restore_elapsed = 0.0
	fire_release_required = true
```

- [ ] **Step 6: 运行测试并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/yewei/yyw/project/zombiewar --script res://tests/test_runner.gd
```

Expected: `test_weapon_configuration.gd` 和 `test_weapon_clearance_state.gd` 通过；不存在新增解析错误。

- [ ] **Step 7: 导入 `.uid`、检查差异并提交**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path /Users/yewei/yyw/project/zombiewar --quit
git diff --check
git status --short
```

确认 `scripts/player/weapon_clearance_state.gd.uid` 随 Godot 导入生成，只暂存本任务列出的文件，然后提交：

```bash
git add scripts/combat/weapons/ranged_weapon_definition.gd \
  resources/weapons/pistol.tres \
  resources/weapons/rifle.tres \
  scripts/player/weapon_clearance_state.gd \
  scripts/player/weapon_clearance_state.gd.uid \
  tests/unit/test_weapon_configuration.gd \
  tests/unit/test_weapon_clearance_state.gd \
  tests/test_runner.gd
git commit -m "feat: add weapon clearance profiles"
```

---

### Task 2: 装配墙体净空控制器并驱动挂点抬枪

**Files:**
- Create: `scripts/player/weapon_clearance_controller.gd`
- Modify: `scenes/player/Player.tscn`
- Modify: `scripts/player/player_controller.gd`
- Create: `tests/unit/test_weapon_clearance_controller.gd`
- Modify: `tests/unit/test_player_damage.gd`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: Task 1 的 `RangedWeaponDefinition.has_wall_clearance_profile()`、四个墙体配置字段、`WeaponClearanceState`，以及现有 `EquipmentController.get_current_weapon() -> WeaponBase`、`WeaponBase.visual_anchor`、`EquipmentController.cancel_attack()`。
- Produces: 固定接口中的 `WeaponClearanceController`；场景节点 `Player/WeaponCollision`、`Player/WeaponClearanceController/NormalProbe`、`RaisedProbe`；Task 3 使用的真实空间查询和 `is_raised()`。

- [ ] **Step 1: 添加玩家场景和控制器绑定的失败测试**

创建 `tests/unit/test_weapon_clearance_controller.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const WeaponClearanceState = preload(
	"res://scripts/player/weapon_clearance_state.gd"
)

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)

	var controller := player.get_node_or_null(
		"WeaponClearanceController"
	) as WeaponClearanceController
	var weapon_collision := player.get_node_or_null(
		"WeaponCollision"
	) as CollisionShape3D
	_append(failures, Assertions.expect_true(
		controller != null,
		"Player owns a weapon-clearance controller"
	))
	_append(failures, Assertions.expect_true(
		weapon_collision != null and weapon_collision.get_parent() == player,
		"Weapon collision is a direct CharacterBody child"
	))
	if controller == null or weapon_collision == null:
		player.free()
		return failures

	var rifle_shape := weapon_collision.shape as CapsuleShape3D
	_append(failures, Assertions.expect_true(
		not weapon_collision.disabled and rifle_shape != null,
		"Starting rifle enables a capsule collision"
	))
	if rifle_shape != null:
		_append(failures, Assertions.expect_float_near(
			rifle_shape.height,
			1.55,
			0.0001,
			"Starting rifle applies its fitted capsule length"
		))
		_append(failures, Assertions.expect_float_near(
			rifle_shape.radius,
			0.12,
			0.0001,
			"Starting rifle applies its fitted capsule radius"
		))

	var rifle := player.equipment.get_current_weapon()
	var rifle_visual := rifle.visual_anchor
	var rest_transform := rifle_visual.transform
	controller.call("_apply_pose", WeaponClearanceState.Pose.RAISED)
	controller._process(controller.transition_duration)
	_append(failures, Assertions.expect_true(
		rifle_visual.transform != rest_transform,
		"Raised pose rotates the existing hand-mounted rifle"
	))
	var saved_anchor := rifle.visual_anchor
	rifle.visual_anchor = null
	controller.bind_weapon(rifle)
	_append(failures, Assertions.expect_true(
		weapon_collision.disabled,
		"Missing visual anchor safely disables weapon clearance"
	))
	rifle.visual_anchor = saved_anchor
	controller.bind_weapon(rifle)

	player.equipment.equip_slot(2)
	_append(failures, Assertions.expect_true(
		weapon_collision.disabled,
		"Knife disables firearm wall collision"
	))
	_append(failures, Assertions.expect_true(
		rifle_visual.transform == rest_transform,
		"Unequipping restores the rifle local transform"
	))
	player.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在 `tests/unit/test_player_damage.gd` 的致命伤害路径中取得新碰撞节点，并在死亡断言后添加：

```gdscript
var weapon_collision := player.get_node("WeaponCollision") as CollisionShape3D
# 保留现有致命伤害调用
_append(failures, Assertions.expect_true(
	weapon_collision.disabled,
	"Player death disables firearm wall collision"
))
```

在 `tests/integration/test_demo_scene.gd` 的玩家契约附近添加：

```gdscript
var weapon_collision := arena.get_node_or_null(
	"Player/WeaponCollision"
) as CollisionShape3D
var weapon_clearance := arena.get_node_or_null(
	"Player/WeaponClearanceController"
)
_append(failures, Assertions.expect_true(
	weapon_collision != null and weapon_clearance != null,
	"Demo player owns fitted weapon wall clearance"
))
```

在 `tests/test_runner.gd` 注册：

```gdscript
"res://tests/unit/test_weapon_clearance_controller.gd",
```

- [ ] **Step 2: 运行全量测试并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/yewei/yyw/project/zombiewar --script res://tests/test_runner.gd
```

Expected: FAIL；`WeaponClearanceController` 类型或玩家节点不存在。失败不能来自覆盖并行修改造成的语法错误。

- [ ] **Step 3: 在玩家场景中装配碰撞体和两个查询节点**

修改 `scenes/player/Player.tscn`：

1. 增加控制器脚本外部资源。
2. 增加三个独立 `CapsuleShape3D` 子资源：真实碰撞、正常探测、抬枪探测。它们的初始尺寸使用步枪值，但运行时会由控制器覆盖；不要让三个节点共享同一个可变 Shape 资源。
3. 在人物主体 `CollisionShape3D` 后装配：

```text
[node name="WeaponCollision" type="CollisionShape3D" parent="."]
position = Vector3(0, 1.12, -0.62)
rotation_degrees = Vector3(90, 0, 0)
shape = SubResource("CapsuleShape3D_weapon_collision")

[node name="WeaponClearanceController" type="Node3D" parent="."]
script = ExtResource("10_weapon_clearance")

[node name="NormalProbe" type="ShapeCast3D" parent="WeaponClearanceController"]
collision_mask = 1
collide_with_areas = false
shape = SubResource("CapsuleShape3D_weapon_normal_probe")

[node name="RaisedProbe" type="ShapeCast3D" parent="WeaponClearanceController"]
collision_mask = 1
collide_with_areas = false
shape = SubResource("CapsuleShape3D_weapon_raised_probe")
```

`WeaponCollision` 必须保持 `Player` 的直接子节点；两个 `ShapeCast3D` 只查询第 1 层，不能查询 Area。

- [ ] **Step 4: 实现控制器的绑定、姿态和视觉插值骨架**

创建 `scripts/player/weapon_clearance_controller.gd`，先实现以下字段与固定接口。空间查询细节在 Step 5 补齐：

```gdscript
extends Node3D
class_name WeaponClearanceController

const WeaponClearanceState = preload(
	"res://scripts/player/weapon_clearance_state.gd"
)

@export var transition_duration := 0.15
@export var restore_delay := 0.15
@export var restore_margin := 0.08

@onready var weapon_collision: CollisionShape3D = $"../WeaponCollision"
@onready var normal_probe: ShapeCast3D = $NormalProbe
@onready var raised_probe: ShapeCast3D = $RaisedProbe

var wielder: CharacterBody3D
var current_weapon: WeaponBase
var current_definition: RangedWeaponDefinition
var current_visual: Node3D
var visual_rest_transform := Transform3D.IDENTITY
var visual_from_transform := Transform3D.IDENTITY
var visual_target_transform := Transform3D.IDENTITY
var visual_elapsed := 0.0
var visual_transitioning := false
var state: WeaponClearanceState

func _ready() -> void:
	state = WeaponClearanceState.new(restore_delay)
	set_process(false)

func setup(value_wielder: CharacterBody3D) -> void:
	wielder = value_wielder
	normal_probe.add_exception(wielder)
	raised_probe.add_exception(wielder)

func bind_weapon(weapon: WeaponBase) -> void:
	_restore_visual_immediately()
	current_weapon = weapon
	current_definition = null
	current_visual = null
	if weapon == null or not weapon.definition is RangedWeaponDefinition:
		_disable_clearance()
		return
	var ranged := weapon.definition as RangedWeaponDefinition
	if not ranged.has_wall_clearance_profile() or weapon.visual_anchor == null:
		push_warning(
			"Weapon %s has no valid wall-clearance profile or visual anchor" %
			String(ranged.weapon_id)
		)
		_disable_clearance()
		return
	current_definition = ranged
	current_visual = weapon.visual_anchor
	visual_rest_transform = current_visual.transform
	_configure_shapes(ranged)
	state.reset()
	var normal_clear := _probe_pose(normal_probe, false, Vector3.ZERO, wielder.rotation.y)
	var raised_clear := _probe_pose(raised_probe, true, Vector3.ZERO, wielder.rotation.y)
	if not normal_clear and not raised_clear:
		push_warning(
			"Weapon %s has no safe normal or raised pose" %
			String(ranged.weapon_id)
		)
		_disable_clearance()
		return
	state.configure(true, normal_clear, raised_clear)
	_apply_pose(state.pose)

func observe_trigger(trigger_pressed: bool) -> void:
	state.observe_trigger(trigger_pressed)

func can_fire() -> bool:
	return state.can_fire(not visual_transitioning)

func is_raised() -> bool:
	return state.pose == WeaponClearanceState.Pose.RAISED

func reset() -> void:
	_restore_visual_immediately()
	_disable_clearance()
```

实现形状配置和视觉目标：

```gdscript
func _configure_shapes(definition: RangedWeaponDefinition) -> void:
	var collision_capsule := weapon_collision.shape as CapsuleShape3D
	var normal_capsule := normal_probe.shape as CapsuleShape3D
	var raised_capsule := raised_probe.shape as CapsuleShape3D
	for capsule in [collision_capsule, normal_capsule, raised_capsule]:
		capsule.height = definition.wall_capsule_length
		capsule.radius = definition.wall_capsule_radius
	weapon_collision.disabled = false
	normal_probe.enabled = true
	raised_probe.enabled = true

func _apply_pose(pose: int) -> void:
	if current_definition == null:
		return
	var raised := pose == WeaponClearanceState.Pose.RAISED
	weapon_collision.transform = _pose_transform(raised, wielder.rotation.y)
	var target := visual_rest_transform
	if raised:
		target.basis = target.basis * Basis(
			Vector3.RIGHT,
			deg_to_rad(current_definition.wall_raise_angle_degrees)
		)
	_begin_visual_transition(target)

func _begin_visual_transition(target: Transform3D) -> void:
	if current_visual == null:
		return
	if current_visual.transform.is_equal_approx(target):
		current_visual.transform = target
		visual_transitioning = false
		set_process(false)
		return
	visual_from_transform = current_visual.transform
	visual_target_transform = target
	visual_elapsed = 0.0
	visual_transitioning = true
	set_process(true)

func _process(delta: float) -> void:
	if not visual_transitioning or current_visual == null:
		set_process(false)
		return
	visual_elapsed += maxf(delta, 0.0)
	var weight := minf(visual_elapsed / maxf(transition_duration, 0.001), 1.0)
	var eased := smoothstep(0.0, 1.0, weight)
	current_visual.transform = visual_from_transform.interpolate_with(
		visual_target_transform,
		eased
	)
	if weight >= 1.0:
		current_visual.transform = visual_target_transform
		visual_transitioning = false
		set_process(false)
```

用以下实现完成恢复和禁用，确保切到匕首、死亡或无效配置时立即生效：

```gdscript
func _restore_visual_immediately() -> void:
	if current_visual != null and is_instance_valid(current_visual):
		current_visual.transform = visual_rest_transform
	visual_transitioning = false
	visual_elapsed = 0.0
	set_process(false)

func _disable_clearance() -> void:
	if state != null:
		state.reset()
	weapon_collision.disabled = true
	normal_probe.enabled = false
	raised_probe.enabled = false
	current_definition = null
	current_weapon = null
	current_visual = null
```

- [ ] **Step 5: 实现稳定的正常/抬枪空间查询与转向解析**

胶囊轴在 Godot 中沿局部 `Y`。正常姿态用 `X = 90°` 让胶囊沿玩家前后方向；抬枪姿态从该角度减去武器的抬枪角。胶囊中心围绕同高、`z = 0` 的近似握把点旋转：

```gdscript
func _pose_transform(raised: bool, target_yaw: float) -> Transform3D:
	var offset := current_definition.wall_capsule_offset
	var raise_radians := (
		deg_to_rad(current_definition.wall_raise_angle_degrees)
		if raised else 0.0
	)
	var pivot := Vector3(offset.x, offset.y, 0.0)
	var raise_basis := Basis(Vector3.RIGHT, raise_radians)
	var center := pivot + raise_basis * (offset - pivot)
	var facing_delta := wrapf(target_yaw - wielder.rotation.y, -PI, PI)
	var facing_basis := Basis(Vector3.UP, facing_delta)
	var capsule_basis := facing_basis * Basis(
		Vector3.RIGHT,
		PI * 0.5 + raise_radians
	)
	return Transform3D(capsule_basis, facing_basis * center)
```

用 `ShapeCast3D` 在目标朝向和期望位移上执行查询：

```gdscript
func _probe_pose(
	probe: ShapeCast3D,
	raised: bool,
	desired_motion: Vector3,
	target_yaw: float
) -> bool:
	probe.transform = _pose_transform(raised, target_yaw)
	var cast_motion := desired_motion
	if not raised and state.pose == WeaponClearanceState.Pose.RAISED:
		cast_motion += Vector3(
			sin(target_yaw),
			0.0,
			-cos(target_yaw)
		) * restore_margin
	probe.target_position = probe.global_basis.inverse() * cast_motion
	probe.force_shapecast_update()
	return not probe.is_colliding()

func resolve_facing_yaw(
	delta: float,
	desired_motion: Vector3,
	target_yaw: float
) -> float:
	if current_definition == null or state.pose == WeaponClearanceState.Pose.DISABLED:
		return target_yaw
	var normal_clear := _probe_pose(
		normal_probe,
		false,
		desired_motion,
		target_yaw
	)
	var raised_clear := _probe_pose(
		raised_probe,
		true,
		desired_motion,
		target_yaw
	)
	var changed := state.update(delta, normal_clear, raised_clear)
	if changed:
		_apply_pose(state.pose)
	if not normal_clear and not raised_clear:
		return wielder.rotation.y
	weapon_collision.transform = _pose_transform(is_raised(), target_yaw)
	return target_yaw
```

当 `NORMAL` 阻挡但 `RAISED` 可用时，状态机先切换物理形状，再允许人物应用目标朝向。两种姿态都不可用时返回当前朝向，移动仍由当前合法 `WeaponCollision` 和人物主体碰撞共同求解。

- [ ] **Step 6: 把玩家物理帧接入控制器和射击门闩**

在 `scripts/player/player_controller.gd` 增加：

```gdscript
@onready var weapon_clearance: WeaponClearanceController = $WeaponClearanceController
```

在 `_ready()` 中先 setup，再让装备系统触发起始武器事件：

```gdscript
weapon_clearance.setup(self)
equipment.attack_started.connect(_on_weapon_attack_started)
equipment.attack_resolved.connect(_on_weapon_attack_resolved)
equipment.weapon_changed.connect(_on_weapon_changed)
equipment.setup(self, visual_root, functional_ray_origin)
```

把 `_on_weapon_changed()` 改为：

```gdscript
func _on_weapon_changed(_definition: WeaponDefinition) -> void:
	attack_animation_remaining = 0.0
	weapon_clearance.bind_weapon(equipment.get_current_weapon())
	_update_animation(Vector2(velocity.x, velocity.z).length())
```

在 `_physics_process()` 中不要立即写入 `rotation.y`。先计算 `target_yaw`，完成切枪和速度计算，再解析枪械空间：

```gdscript
var target_yaw := PlayerMotion.next_facing_yaw(aim_direction, rotation.y)
# 保留现有切枪分支和速度计算
var desired_motion := Vector3(velocity.x, 0.0, velocity.z) * delta
rotation.y = weapon_clearance.resolve_facing_yaw(
	delta,
	desired_motion,
	target_yaw
)
```

随后读取原始攻击输入并应用门闩：

```gdscript
var trigger_pressed := Input.is_action_pressed(primary_attack_action)
var trigger_just_pressed := Input.is_action_just_pressed(primary_attack_action)
weapon_clearance.observe_trigger(trigger_pressed)
if hit_reaction_remaining > 0.0 or not weapon_clearance.can_fire():
	trigger_pressed = false
	trigger_just_pressed = false
	equipment.cancel_attack()
equipment.set_attack_input(trigger_pressed, trigger_just_pressed, aim_direction)
```

确保该段位于 `weapon_clearance.resolve_facing_yaw()` 之后、`move_and_slide()` 之前。删除原来更早提交攻击输入的代码，避免同一物理帧重复调用。

在 `_on_depleted()` 的 `equipment.cancel_attack()` 后添加：

```gdscript
weapon_clearance.reset()
```

- [ ] **Step 7: 运行测试并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/yewei/yyw/project/zombiewar --script res://tests/test_runner.gd
```

Expected: 新控制器测试和 Demo 契约通过，原有武器反馈、移动、伤害和场景测试无新增失败。

- [ ] **Step 8: 检查导入、场景解析和提交**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path /Users/yewei/yyw/project/zombiewar --quit
git diff --check
git status --short
```

确认生成 `scripts/player/weapon_clearance_controller.gd.uid`，只暂存本任务文件并提交：

```bash
git add scripts/player/weapon_clearance_controller.gd \
  scripts/player/weapon_clearance_controller.gd.uid \
  scenes/player/Player.tscn \
  scripts/player/player_controller.gd \
  tests/unit/test_weapon_clearance_controller.gd \
  tests/unit/test_player_damage.gd \
  tests/integration/test_demo_scene.gd \
  tests/test_runner.gd
git commit -m "feat: add automatic weapon wall clearance"
```

---

### Task 3: 验证真实墙体、切枪与抬枪射击阻断

**Files:**
- Create: `tests/integration/test_weapon_wall_clearance.gd`
- Modify: `tests/test_runner.gd`
- Modify only if a failing integration test proves necessary: `scripts/player/weapon_clearance_controller.gd`
- Modify only if a failing integration test proves necessary: `scripts/player/player_controller.gd`
- Modify only if a failing switch-frame test proves necessary: `scripts/player/equipment_controller.gd`
- Modify only for fitted center-offset calibration: `resources/weapons/pistol.tres`
- Modify only for fitted center-offset calibration: `resources/weapons/rifle.tres`

**Interfaces:**
- Consumes: Task 2 的完整 `WeaponClearanceController`、真实玩家场景、`EquipmentController`、`RangedWeapon.tracer_pool_cursor` 和世界第 1 层物理约定。
- Produces: 可重复的真实墙体集成测试、手枪/步枪视觉校准数据和最终 Godot 运行时验证证据。

- [ ] **Step 1: 写真实墙体集成测试并注册**

创建 `tests/integration/test_weapon_wall_clearance.gd`。测试创建第 1 层 `StaticBody3D` 墙体，调用真实玩家、真实控制器和真实武器，不伪造控制器返回值：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	tree.root.add_child(player)
	var wall := _make_wall(Vector3(0.0, 1.0, -1.60), Vector3(3.0, 2.0, 0.20))
	tree.root.add_child(wall)

	var clearance := player.get_node(
		"WeaponClearanceController"
	) as WeaponClearanceController
	var weapon_collision := player.get_node(
		"WeaponCollision"
	) as CollisionShape3D
	var rifle := player.equipment.get_current_weapon() as RangedWeapon

	clearance.resolve_facing_yaw(
		0.016,
		Vector3(0.0, 0.0, -0.15),
		0.0
	)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Approaching a rifle-length wall clearance raises the rifle"
	))
	var raised_axis := weapon_collision.transform.basis.y.normalized()
	_append(failures, Assertions.expect_true(
		not weapon_collision.disabled and absf(raised_axis.y) > 0.85,
		"Raised rifle keeps an active capsule aimed upward"
	))

	clearance.observe_trigger(true)
	_append(failures, Assertions.expect_true(
		not clearance.can_fire(),
		"Held trigger cannot fire while the rifle is raised"
	))
	var cursor_before := rifle.tracer_pool_cursor
	Input.action_press(player.primary_attack_action)
	player._physics_process(0.016)
	rifle._physics_process(0.20)
	_append(failures, Assertions.expect_equal(
		rifle.tracer_pool_cursor,
		cursor_before,
		"Held fire input does not create a tracer while raised"
	))

	wall.position.z = -4.0
	wall.force_update_transform()
	clearance.resolve_facing_yaw(0.15, Vector3.ZERO, 0.0)
	clearance._process(clearance.transition_duration)
	_append(failures, Assertions.expect_true(
		not clearance.is_raised() and not clearance.can_fire(),
		"Lowered rifle still requires trigger release"
	))
	Input.action_release(player.primary_attack_action)
	player._physics_process(0.016)
	_append(failures, Assertions.expect_true(
		clearance.can_fire(),
		"Trigger release re-enables the lowered rifle"
	))
	Input.action_press(player.primary_attack_action)
	player._physics_process(0.016)
	rifle._physics_process(0.20)
	_append(failures, Assertions.expect_true(
		rifle.tracer_pool_cursor != cursor_before,
		"A fresh press fires after clearance is restored"
	))
	Input.action_release(player.primary_attack_action)

	wall.position.z = -0.95
	wall.force_update_transform()
	player.equipment.equip_slot(0)
	_append(failures, Assertions.expect_true(
		clearance.is_raised(),
		"Wall-side pistol switch chooses the raised pose immediately"
	))

	player.equipment.equip_slot(2)
	_append(failures, Assertions.expect_true(
		weapon_collision.disabled,
		"Knife keeps only the player body capsule"
	))

	wall.free()
	var zombie := ZOMBIE_SCENE.instantiate() as ZombieTarget
	zombie.position = Vector3(0.0, 0.0, -1.0)
	zombie.set_physics_process(false)
	tree.root.add_child(zombie)
	player.equipment.equip_slot(1)
	clearance.resolve_facing_yaw(0.016, Vector3.ZERO, 0.0)
	_append(failures, Assertions.expect_true(
		not clearance.is_raised(),
		"Zombie bodies and hit areas do not trigger firearm clearance"
	))
	zombie.free()
	player.free()
	return failures

func _make_wall(position: Vector3, size: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.position = position
	wall.collision_layer = 1
	wall.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	wall.add_child(collision)
	return wall

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在 `tests/test_runner.gd` 的 Demo 集成测试前注册：

```gdscript
"res://tests/integration/test_weapon_wall_clearance.gd",
```

- [ ] **Step 2: 运行全量测试并确认 RED 或确认真实集成已满足**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/yewei/yyw/project/zombiewar --script res://tests/test_runner.gd
```

Expected: 若 Task 2 的第一版存在真实物理时序、姿态角或切枪首帧问题，本测试必须以对应断言失败；如果直接通过，保留完整输出作为真实集成证据，不能人为制造生产缺陷。

- [ ] **Step 3: 只修复测试揭示的物理集成差异**

按失败类型使用以下限定修复，不能扩大范围：

- 如果 `ShapeCast3D` 未在绑定首帧更新：在 `bind_weapon()` 配置 shape 并设置 `enabled = true` 后调用一次 `force_shapecast_update()`，再读取结果。
- 如果抬枪胶囊没有明显朝上：检查 `_pose_transform()` 是否使用 `PI * 0.5 + raise_radians`，并确认旋转后的 `basis.y` 垂直分量绝对值大于 `0.85`；不修改 `65°` 规格值。
- 如果贴墙切枪先显示正常姿态：在 `bind_weapon()` 完成 `state.configure()` 和 `_apply_pose()` 后，才允许新 `visual_anchor.visible = true`；为此把 `EquipmentController.equip_slot()` 的显示顺序改为“绑定完成后显示”时，必须同步增加一条切枪首帧测试，不能用一帧延迟掩盖。
- 如果抬枪后放下立即自动射击：确认 `WeaponClearanceState._enter_raised()` 设置 `fire_release_required = true`，且玩家每帧先 `observe_trigger(raw_pressed)`、再查询 `can_fire()`，不可缓存 `trigger_just_pressed`。
- 如果查询撞到玩家自身：确认两个 probe 都执行 `add_exception(wielder)`，并保持碰撞遮罩为 `1`。

修复后重复运行全量测试，Expected: 所有测试通过。

- [ ] **Step 4: 使用 Godot 4.7.1 做视口与运行时校准**

先检查导入和脚本：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path /Users/yewei/yyw/project/zombiewar --quit
```

再通过 Godot MCP 打开并运行 `res://scenes/gameplay/DemoArena.tscn`，依次验证：

1. 步枪正面靠墙：枪身不穿墙，接近临界点后抬到约 `65°`。
2. 步枪斜向墙角：不会在 `NORMAL/RAISED` 间连续抖动。
3. 窄门转身：空间不足时先抬枪，人物仍可后退和侧移脱离。
4. 贴墙切换手枪、步枪、匕首：远程武器首帧姿态合法，匕首关闭枪械胶囊。
5. 抬枪时持续按住开火键：没有枪口火焰、声音、曳光弹或伤害；离墙放下后仍不补射，释放并重新按下才开火。
6. 手枪和步枪胶囊可视调试轮廓：总长分别保持 `0.94m`、`1.55m`，半径分别保持 `0.10m`、`0.12m`；只允许微调 `wall_capsule_offset`。

保存至少一张步枪正常/抬枪对比截图和一张手枪贴墙截图，任务报告记录截图绝对路径。

- [ ] **Step 5: 最终回归、差异检查和提交**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/yewei/yyw/project/zombiewar --script res://tests/test_runner.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path /Users/yewei/yyw/project/zombiewar --quit
git diff --check
git status --short
```

Expected: 全量测试输出 `PASS`，Godot 无场景或脚本解析错误，`git diff --check` 无输出。只暂存本任务实际改动并提交：

```bash
git add tests/integration/test_weapon_wall_clearance.gd \
  tests/integration/test_weapon_wall_clearance.gd.uid \
  tests/test_runner.gd
git add scripts/player/weapon_clearance_controller.gd \
  scripts/player/player_controller.gd \
  scripts/player/equipment_controller.gd \
  resources/weapons/pistol.tres \
  resources/weapons/rifle.tres
git commit -m "test: verify weapon wall clearance"
```

提交前用 `git diff --cached --name-only` 删除未实际修改文件的暂存项，禁止把并行 Cloudflare、击退、血迹、灯光或其他用户改动带入本提交。

---

## 完成后的审查清单

- 手枪和步枪胶囊尺寸满足规格，匕首不启用枪械胶囊。
- `WeaponCollision` 是 `Player` 的直接子节点，真实阻挡来自它而不是只靠射线或视觉隐藏。
- 正常和抬枪 probe 使用独立可变 Shape 资源、只查询第 1 层并排除玩家自身。
- 抬枪碰撞仍启用；没有通过关闭长枪碰撞来掩盖穿墙。
- 抬枪视觉只叠加在现有 `Middle1_L` 挂点下的武器网格局部变换，卸下/死亡后精确恢复。
- `RangedWeapon` 的功能射线和实时枪口跟随逻辑未改变。
- 自动步枪在抬枪期间不会积累或补发射击。
- 后退、远离墙体侧移、墙角转身、窄门和贴墙切枪均有测试或运行时证据。
- 三个任务各自有 RED/GREEN 记录、审查结论和独立提交。
