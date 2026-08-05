# 武器转身解耦与胶囊枪口弹道 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让人物在任何枪械净空状态下都能转身，并把真实枪械胶囊末端统一为喷火、伤害射线、曳光弹和攻击反馈的起点。

**Architecture:** `WeaponClearanceState` 增加 `TUCKED` 并只负责纯状态转换；`WeaponClearanceController` 使用两个现有 probe 选择 `NORMAL/RAISED/TUCKED`、提交真实碰撞与视觉姿态，并提供胶囊枪口世界端点。`PlayerController` 永远采用目标 yaw，`RangedWeapon` 从控制器取得唯一射击起点，`ShotTracer` 使用 Shader 实现枪口端到命中端的纵向透明度渐变和整体生命周期淡出。

**Tech Stack:** Godot 4.7.1、GDScript、`CharacterBody3D`、`ShapeCast3D`、`CapsuleShape3D`、Godot spatial Shader、自定义 `RefCounted` 测试运行器。

## Global Constraints

- 实施规格：`docs/superpowers/specs/2026-08-05-weapon-turn-ballistics-design.md`。
- 所有远程武器胶囊总高度固定为 `1.55m`，半径固定为 `0.12m`。
- `NORMAL` 中心偏移固定为 `Vector3(0.0, 1.12, -0.62)`，`RAISED` 固定为 `65°`，`TUCKED` 中心固定为 `Vector3(0.0, 0.9, 0.0)` 且绕 X 轴 `180°`。
- `NORMAL` 恢复延迟保持 `0.15s`，恢复查询余量保持 `0.08m`。
- 人物 yaw 永远采用输入计算出的 `target_yaw`；枪械净空不得拒绝人物转向。
- `NORMAL`、`RAISED`、`TUCKED` 都允许按原射速射击，射击方向始终为人物实际前方 `-global_basis.z`。
- 枪口喷火、功能射线、曳光弹和 `attack_resolved.origin` 必须使用同一个真实胶囊枪口端点。
- 射线必须包含世界第 1 层并排除玩家自身；墙体是第一次命中时，墙后目标不得受伤。
- 有效远程武器装备期间不得关闭 `WeaponCollision`。
- 不修改伤害、射程、射速、声音、后坐力、相机冲击、近战逻辑或 `addons/`。
- 所有代码使用 tab 缩进；新增行为必须先得到有效 RED，再写生产代码。

---

## 文件结构

- `scripts/player/weapon_clearance_state.gd`：四态净空状态机和恢复计时。
- `scripts/player/weapon_clearance_controller.gd`：姿态查询、物理/视觉提交、胶囊枪口端点。
- `scripts/player/player_controller.gd`：无条件应用目标 yaw，并从人物前方生成远程射击方向。
- `scripts/player/equipment_controller.gd`：让双姿态受阻的远程武器以 `TUCKED` 完成事务装备。
- `scripts/combat/weapons/ranged_weapon.gd`：统一胶囊枪口射线、喷火、曳光弹和反馈起点。
- `scripts/combat/weapons/ranged_weapon_definition.gd`：移除重复的 `muzzle_anchor_offset`。
- `resources/weapons/pistol.tres`、`resources/weapons/rifle.tres`：移除局部枪口偏移数据。
- `scripts/fx/shot_tracer.gd`：设置和推进每个 tracer 的整体生命周期 alpha。
- `scenes/fx/ShotTracer.tscn`：纵向渐变 Shader。
- `tests/unit/test_weapon_clearance_state.gd`：四态状态转换。
- `tests/unit/test_weapon_clearance_controller.gd`：转身、收枪包含关系、枪口端点和装备失败关闭。
- `tests/unit/test_weapon_configuration.gd`：资源配置迁移。
- `tests/unit/test_weapon_feedback.gd`：统一起点、墙体命中和 tracer 生命周期。
- `tests/integration/test_weapon_wall_clearance.gd`：真实 90° 转身、三姿态射击、恢复和墙体截断。

---

### Task 1: 增加 `TUCKED` 纯状态转换

**Files:**
- Modify: `tests/unit/test_weapon_clearance_state.gd`
- Modify: `scripts/player/weapon_clearance_state.gd`

**Interfaces:**
- Consumes: 现有 `configure(initial_pose: int)`、`commit_pose(requested_pose: int) -> bool`、`reset()`。
- Produces: `enum Pose { DISABLED, NORMAL, RAISED, TUCKED }`；`request_pose(delta: float, normal_clear: bool, raised_clear := true) -> int`。第三个参数在 Task 1 暂时提供默认值以保持现有控制器可编译，Task 2 必须改为显式传入真实 `raised_clear`。

- [ ] **Step 1: 写四态转换失败测试**

在 `tests/unit/test_weapon_clearance_state.gd` 把所有旧 `request_pose()` 调用补上 `raised_clear`，并加入以下完整转换断言：

```gdscript
state.configure(WeaponClearanceState.Pose.NORMAL)
var tucked_request := state.request_pose(0.016, false, false)
_append(failures, Assertions.expect_equal(
	tucked_request,
	WeaponClearanceState.Pose.TUCKED,
	"Blocked normal and raised poses request tucked without mutating committed pose"
))
_append(failures, Assertions.expect_equal(
	state.pose,
	WeaponClearanceState.Pose.NORMAL,
	"Tucked request stays separate from the committed normal pose"
))
state.commit_pose(tucked_request)
_append(failures, Assertions.expect_equal(
	state.request_pose(0.016, true, false),
	WeaponClearanceState.Pose.TUCKED,
	"Tucked pose stays committed until raised clearance is available"
))
var raised_request := state.request_pose(0.016, true, true)
_append(failures, Assertions.expect_equal(
	raised_request,
	WeaponClearanceState.Pose.RAISED,
	"Tucked pose restores to raised before starting normal restore timing"
))
state.commit_pose(raised_request)
_append(failures, Assertions.expect_equal(
	state.request_pose(0.10, true, true),
	WeaponClearanceState.Pose.RAISED,
	"Raised pose waits for the full normal restore delay"
))
_append(failures, Assertions.expect_equal(
	state.request_pose(0.05, true, true),
	WeaponClearanceState.Pose.NORMAL,
	"Raised pose requests normal after 0.15 seconds of clearance"
))
```

再覆盖 `RAISED` 当前姿态失去 raised clearance 时请求 `TUCKED`：

```gdscript
state.configure(WeaponClearanceState.Pose.RAISED)
_append(failures, Assertions.expect_equal(
	state.request_pose(0.016, true, false),
	WeaponClearanceState.Pose.TUCKED,
	"Raised pose requests tucked when its committed volume becomes blocked"
))
```

- [ ] **Step 2: 运行完整测试确认有效 RED**

Run:

```bash
./tests/run_tests.sh
```

Expected: exit `1`；`test_weapon_clearance_state.gd` 因 `Pose.TUCKED` 不存在或 `request_pose()` 参数数量不匹配而失败。若出现脚本拼写或测试夹具错误，先修正测试并重跑，直到只因新四态行为缺失而失败。

- [ ] **Step 3: 实现最小四态状态机**

把 `scripts/player/weapon_clearance_state.gd` 的枚举和 `request_pose()` 改为：

```gdscript
enum Pose { DISABLED, NORMAL, RAISED, TUCKED }

func request_pose(
	delta: float,
	normal_clear: bool,
	raised_clear := true
) -> int:
	if pose == Pose.DISABLED:
		return Pose.DISABLED
	if pose == Pose.NORMAL:
		restore_elapsed = 0.0
		if normal_clear:
			return Pose.NORMAL
		return Pose.RAISED if raised_clear else Pose.TUCKED
	if pose == Pose.TUCKED:
		restore_elapsed = 0.0
		return Pose.RAISED if raised_clear else Pose.TUCKED
	if not raised_clear:
		restore_elapsed = 0.0
		return Pose.TUCKED
	if not normal_clear:
		restore_elapsed = 0.0
		return Pose.RAISED
	restore_elapsed += maxf(delta, 0.0)
	return Pose.NORMAL if restore_elapsed >= restore_delay else Pose.RAISED
```

保留 `configure()`、`commit_pose()` 和 `reset()` 的“请求不直接修改已提交状态”契约。

- [ ] **Step 4: 运行完整测试确认 GREEN**

Run:

```bash
./tests/run_tests.sh
```

Expected: 完整测试通过。旧控制器的两参数调用通过临时默认值保持兼容；Task 2 会改为显式传入真实 `raised_clear`，不得长期依赖默认值。

- [ ] **Step 5: 提交状态机**

```bash
git add scripts/player/weapon_clearance_state.gd tests/unit/test_weapon_clearance_state.gd
git commit -m "feat: add tucked weapon clearance state"
```

---

### Task 2: 解耦人物 yaw 并提交安全收枪姿态

**Files:**
- Modify: `tests/unit/test_weapon_clearance_controller.gd`
- Modify: `tests/integration/test_weapon_wall_clearance.gd`
- Modify: `scripts/player/weapon_clearance_controller.gd`
- Modify: `scripts/player/player_controller.gd`

**Interfaces:**
- Consumes: Task 1 的 `request_pose(delta, normal_clear, raised_clear) -> int` 和 `Pose.TUCKED`。
- Produces: `update_clearance(delta: float, desired_motion: Vector3, target_yaw: float) -> void`；`get_weapon_muzzle_origin(fallback: Vector3) -> Vector3`；所有有效远程装备始终拥有 `NORMAL/RAISED/TUCKED` 之一。

- [ ] **Step 1: 写转身、TUCKED 和装备契约失败测试**

在 `tests/unit/test_weapon_clearance_controller.gd` 把原“双阻挡拒绝 yaw”断言替换为：

```gdscript
var target_yaw := PI * 0.5
controller.update_clearance(0.016, Vector3.ZERO, target_yaw)
player.rotation.y = target_yaw
_append(failures, Assertions.expect_true(
	controller.state.pose == WeaponClearanceState.Pose.TUCKED and
		is_equal_approx(player.rotation.y, target_yaw),
	"Blocked normal and raised poses tuck the rifle without rejecting player yaw"
))
var tucked_capsule := weapon_collision.shape as CapsuleShape3D
_append(failures, Assertions.expect_vector3_near(
	weapon_collision.position,
	Vector3(0.0, 0.9, 0.0),
	0.0001,
	"Tucked rifle capsule shares the player capsule center"
))
_append(failures, Assertions.expect_true(
	tucked_capsule != null and
		is_equal_approx(tucked_capsule.height, 1.55) and
		is_equal_approx(tucked_capsule.radius, 0.12) and
		absf(weapon_collision.basis.y.normalized().dot(Vector3.DOWN)) > 0.999,
	"Tucked rifle keeps the shared envelope with its muzzle end pointing upward"
))
```

加入包含关系断言，使用人物胶囊的实际尺寸：

```gdscript
var player_collision := player.get_node("CollisionShape3D") as CollisionShape3D
var player_capsule := player_collision.shape as CapsuleShape3D
_append(failures, Assertions.expect_true(
	player_capsule != null and tucked_capsule != null and
		tucked_capsule.height < player_capsule.height and
		tucked_capsule.radius < player_capsule.radius and
		weapon_collision.position.is_equal_approx(player_collision.position),
	"Tucked rifle capsule is fully contained by the player capsule"
))
```

把原“近战切远程双姿态受阻返回 false”断言改为：

```gdscript
_append(failures, Assertions.expect_true(
	player.equipment.equip_slot(1) and
		controller.state.pose == WeaponClearanceState.Pose.TUCKED and
		not weapon_collision.disabled,
	"Blocked ranged equip succeeds transactionally in tucked pose"
))
```

保留无效或已释放 `visual_anchor` 返回 `false`、当前装备和 probes 不变的失败关闭测试。

在 `tests/integration/test_weapon_wall_clearance.gd` 把原 rejected-turn 场景改为真实 `90°` 转身夹具：双阻挡存在时调用 `update_clearance()`，应用 `player.rotation.y = target_yaw`，断言世界 yaw 为 `90°`、姿态为 `TUCKED`、后退和侧移均可执行完整请求。

- [ ] **Step 2: 运行完整测试确认有效 RED**

Run:

```bash
./tests/run_tests.sh
```

Expected: exit `1`；失败集中在 `update_clearance()` 不存在、`TUCKED` 物理/视觉变换尚未提交、双阻挡装备仍被拒绝。现有墙体射击和真实运动测试应继续加载，不得出现夹具解析错误。

- [ ] **Step 3: 实现控制器姿态解析和枪口端点**

在 `scripts/player/weapon_clearance_controller.gd` 新增：

```gdscript
const TUCKED_CAPSULE_OFFSET := Vector3(0.0, 0.9, 0.0)
const TUCKED_ANGLE_DEGREES := 90.0

func update_clearance(
	delta: float,
	desired_motion: Vector3,
	target_yaw: float
) -> void:
	if current_definition == null or state.pose == WeaponClearanceState.Pose.DISABLED:
		return
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
	var requested_pose := state.request_pose(
		delta,
		normal_clear,
		raised_clear
	)
	if requested_pose != state.pose:
		_commit_pose(requested_pose)

func get_weapon_muzzle_origin(fallback: Vector3) -> Vector3:
	var capsule := weapon_collision.shape as CapsuleShape3D
	if capsule == null:
		push_warning("WeaponCollision requires CapsuleShape3D")
		return fallback
	var barrel_direction := -weapon_collision.global_basis.y.normalized()
	return weapon_collision.global_position + barrel_direction * capsule.height * 0.5
```

把 `_local_pose_transform(raised: bool)` 改为 `_local_pose_transform(pose: int)`：

```gdscript
func _local_pose_transform(pose: int) -> Transform3D:
	if pose == WeaponClearanceState.Pose.TUCKED:
		return Transform3D(
			Basis(Vector3.RIGHT, PI),
			TUCKED_CAPSULE_OFFSET
		)
	var raised := pose == WeaponClearanceState.Pose.RAISED
	var raise_radians := deg_to_rad(WALL_RAISE_ANGLE_DEGREES) if raised else 0.0
	var pivot := Vector3(WALL_CAPSULE_OFFSET.x, WALL_CAPSULE_OFFSET.y, 0.0)
	var raise_basis := Basis(Vector3.RIGHT, raise_radians)
	var center := pivot + raise_basis * (WALL_CAPSULE_OFFSET - pivot)
	return Transform3D(
		Basis(Vector3.RIGHT, PI * 0.5 + raise_radians),
		center
	)
```

`_commit_pose()` 使用当前 pose 选择视觉角度：

```gdscript
func _commit_pose(requested_pose: int) -> void:
	state.commit_pose(requested_pose)
	weapon_collision.transform = _local_pose_transform(state.pose)
	var visual_angle := 0.0
	if state.pose == WeaponClearanceState.Pose.RAISED:
		visual_angle = WALL_RAISE_ANGLE_DEGREES
	elif state.pose == WeaponClearanceState.Pose.TUCKED:
		visual_angle = TUCKED_ANGLE_DEGREES
	var target := visual_rest_transform
	if visual_angle > 0.0:
		target.basis = target.basis * Basis(
			Vector3.UP,
			-deg_to_rad(visual_angle)
		)
	current_visual.transform = target
```

`_probe_pose_transform()` 继续只生成 `NORMAL/RAISED` 预测变换，并调用 `_local_pose_transform(Pose.RAISED if raised else Pose.NORMAL)`。`_current_pose_is_clear()` 对 `TUCKED` 直接返回 `true`。

`try_bind_weapon()` 初次绑定时使用：

```gdscript
var initial_pose := WeaponClearanceState.Pose.TUCKED
if normal_clear:
	initial_pose = WeaponClearanceState.Pose.NORMAL
elif raised_clear:
	initial_pose = WeaponClearanceState.Pose.RAISED
state.configure(initial_pose)
weapon_collision.disabled = false
_commit_pose(initial_pose)
return true
```

删除“`normal_clear` 和 `raised_clear` 都为 false 时返回 false”的空间拒绝路径；无效 `visual_anchor` 路径保持不变。

- [ ] **Step 4: 让 Player 永远采用目标 yaw**

在 `scripts/player/player_controller.gd` 把：

```gdscript
rotation.y = weapon_clearance.resolve_facing_yaw(
	delta,
	desired_motion,
	target_yaw
)
```

替换为：

```gdscript
weapon_clearance.update_clearance(
	delta,
	desired_motion,
	target_yaw
)
rotation.y = target_yaw
```

保留 `_actual_ranged_attack_direction()`：

```gdscript
func _actual_ranged_attack_direction() -> Vector3:
	return WeaponMath.flat_direction(-global_basis.z)
```

不得让枪械姿态覆盖 `aim_direction` 或重新拒绝人物 yaw。

- [ ] **Step 5: 运行完整测试确认 GREEN**

Run:

```bash
./tests/run_tests.sh
```

Expected: 所有净空状态、装备和真实转身测试通过；远程射击旧用例仍可运行。若后续 Task 3 的旧枪口偏移断言仍失败，记录其精确断言并继续 Task 3，不修改新转身契约。

- [ ] **Step 6: 提交转身解耦**

```bash
git add scripts/player/weapon_clearance_controller.gd scripts/player/player_controller.gd tests/unit/test_weapon_clearance_controller.gd tests/integration/test_weapon_wall_clearance.gd
git commit -m "feat: decouple player turning from weapon clearance"
```

---

### Task 3: 统一胶囊枪口、喷火、射线和攻击反馈

**Files:**
- Modify: `tests/unit/test_weapon_configuration.gd`
- Modify: `tests/unit/test_weapon_feedback.gd`
- Modify: `tests/integration/test_weapon_wall_clearance.gd`
- Modify: `scripts/combat/weapons/ranged_weapon_definition.gd`
- Modify: `scripts/combat/weapons/ranged_weapon.gd`
- Modify: `resources/weapons/pistol.tres`
- Modify: `resources/weapons/rifle.tres`

**Interfaces:**
- Consumes: Task 2 的 `WeaponClearanceController.get_weapon_muzzle_origin(fallback: Vector3) -> Vector3` 和人物实际前向射击方向。
- Produces: `RangedWeapon.get_ray_origin() -> Vector3` 返回胶囊端点；喷火、射线、tracer、`attack_resolved.origin` 使用同一值；远程定义不再包含 `muzzle_anchor_offset`。

- [ ] **Step 1: 写统一枪口起点失败测试**

在 `tests/unit/test_weapon_configuration.gd` 删除旧偏移值断言，加入：

```gdscript
for definition: RangedWeaponDefinition in [pistol, rifle]:
	var exposes_muzzle_offset := false
	for property: Dictionary in definition.get_property_list():
		if StringName(property.get("name", &"")) == &"muzzle_anchor_offset":
			exposes_muzzle_offset = true
			break
	_append(failures, Assertions.expect_true(
		not exposes_muzzle_offset,
		"Ranged definitions do not duplicate the shared capsule muzzle origin"
	))
```

在 `tests/unit/test_weapon_feedback.gd` 移除 `weapon.muzzle.position == Vector3(0.0, 0.0, -0.55)`，改为捕获同一次开火的四个起点：

```gdscript
var clearance := player.get_node("WeaponClearanceController") as WeaponClearanceController
var fallback := player.get_node("FunctionalRayOrigin") as Marker3D
var expected_origin := clearance.get_weapon_muzzle_origin(fallback.global_position)
var feedback_origins: Array[Vector3] = []
weapon.attack_resolved.connect(func(
	origin: Vector3,
	_direction: Vector3,
	_result: HitResult,
	_visual_recoil_kick: float,
	_camera_impulse_strength: float
) -> void:
	feedback_origins.append(origin)
)
var tracer_index := weapon.tracer_pool_cursor
weapon._fire(-player.global_basis.z)
var tracer := weapon.tracer_pool[tracer_index] as ShotTracer
_append(failures, Assertions.expect_vector3_near(
	weapon.muzzle.global_position,
	expected_origin,
	0.001,
	"Muzzle flash anchor uses the weapon capsule end"
))
_append(failures, Assertions.expect_vector3_near(
	weapon.get_ray_origin(),
	expected_origin,
	0.001,
	"Functional ray starts at the weapon capsule end"
))
_append(failures, Assertions.expect_vector3_near(
	_tracer_start(tracer),
	expected_origin,
	0.001,
	"Tracer starts at the weapon capsule end"
))
_append(failures, Assertions.expect_vector3_near(
	feedback_origins.back(),
	expected_origin,
	0.001,
	"Attack feedback origin uses the weapon capsule end"
))
```

在 integration 测试分别提交 `NORMAL`、`RAISED`、`TUCKED`，每种姿态都用控制器公式计算 expected origin，并断言射击方向等于人物 `-global_basis.z`。`TUCKED` 用例设置人物 yaw 为 `PI * 0.5`，断言方向为世界 `Vector3.LEFT` 或由实际 basis 推导的等价值，不硬编码未应用的输入方向。

- [ ] **Step 2: 运行完整测试确认有效 RED**

Run:

```bash
./tests/run_tests.sh
```

Expected: exit `1`；旧 `muzzle_anchor_offset` 仍存在，`get_ray_origin()` 仍返回人物功能射线点，muzzle/tracer 仍使用模型 Marker 偏移。转身和 `TUCKED` 状态测试保持通过。

- [ ] **Step 3: 删除每枪枪口偏移配置**

从 `scripts/combat/weapons/ranged_weapon_definition.gd` 删除：

```gdscript
@export var muzzle_anchor_offset := Vector3(0.0, 0.0, -0.55)
```

从 `resources/weapons/pistol.tres` 和 `resources/weapons/rifle.tres` 删除各自的 `muzzle_anchor_offset = ...` 行。不得修改其他资源字段。

- [ ] **Step 4: 让 RangedWeapon 使用胶囊端点**

在 `scripts/combat/weapons/ranged_weapon.gd` 的 `bind_context()` 中删除资源偏移赋值。保留 `Muzzle` 为武器子节点，让它继续继承装备可见性：

```gdscript
func bind_context(
	value_wielder: CharacterBody3D,
	value_visual_root: Node3D,
	value_functional_ray_origin: Marker3D
) -> void:
	super.bind_context(
		value_wielder,
		value_visual_root,
		value_functional_ray_origin
	)
	if visual_anchor != null:
		top_level = true
		_sync_to_visual_anchor()
```

把 `get_ray_origin()` 改为：

```gdscript
func get_ray_origin() -> Vector3:
	var fallback := global_position
	if functional_ray_origin != null and is_instance_valid(functional_ray_origin):
		fallback = functional_ray_origin.global_position
	elif wielder != null:
		fallback = wielder.global_position
	if wielder != null:
		var clearance := wielder.get_node_or_null(
			"WeaponClearanceController"
		) as WeaponClearanceController
		if clearance != null:
			return clearance.get_weapon_muzzle_origin(fallback)
	return fallback
```

新增统一同步入口，让枪口喷火在其 `0.05s` 生命周期内持续贴合胶囊端点：

```gdscript
func _sync_muzzle_to_capsule() -> Vector3:
	var origin := get_ray_origin()
	muzzle.global_position = origin
	return origin
```

`_process()` 先同步武器，再同步枪口：

```gdscript
func _process(_delta: float) -> void:
	_sync_to_visual_anchor()
	_sync_muzzle_to_capsule()
```

在 `_fire()` 中只计算一次统一起点：

```gdscript
var ray_origin := _sync_muzzle_to_capsule()
var ray_direction := WeaponMath.flat_direction(shot_direction)
var ray_end := WeaponMath.ray_end_from_direction(
	ray_origin,
	ray_direction,
	ranged_definition.attack_range
)
var result := _intersect_shot(ray_origin, ray_end)
var hit_position: Vector3 = result.get("position", ray_end)

var tracer := _acquire_tracer()
tracer.setup(ray_origin, hit_position)
muzzle_flash.flash()
```

现有 `attack_resolved.emit()` 的第一个参数继续使用 `ray_origin`。`_intersect_shot()` 增加：

```gdscript
query.hit_from_inside = true
```

保留 `query.collide_with_areas = true`、`hit_collision_mask | 1` 和玩家 RID 排除。

- [ ] **Step 5: 运行完整测试确认 GREEN**

Run:

```bash
./tests/run_tests.sh
```

Expected: 统一起点断言通过；三种姿态的射击方向均为人物实际前方；墙位于胶囊端点和目标之间时仍首先命中墙，目标生命不变。

- [ ] **Step 6: 提交统一枪口逻辑**

```bash
git add scripts/combat/weapons/ranged_weapon_definition.gd scripts/combat/weapons/ranged_weapon.gd resources/weapons/pistol.tres resources/weapons/rifle.tres tests/unit/test_weapon_configuration.gd tests/unit/test_weapon_feedback.gd tests/integration/test_weapon_wall_clearance.gd
git commit -m "feat: fire ranged weapons from capsule muzzle"
```

---

### Task 4: 实现曳光弹纵向渐变和整体淡出

**Files:**
- Modify: `tests/unit/test_weapon_feedback.gd`
- Modify: `scripts/fx/shot_tracer.gd`
- Modify: `scenes/fx/ShotTracer.tscn`

**Interfaces:**
- Consumes: Task 3 传入的 `ShotTracer.setup(capsule_origin, first_hit_position)`。
- Produces: Shader instance 参数 `lifetime_alpha: float`；枪口端局部进度 `0.0`、命中端局部进度 `1.0`；约 `0.08s` 整体淡出。

- [ ] **Step 1: 写 Shader 和生命周期失败测试**

在 `tests/unit/test_weapon_feedback.gd` 取得 tracer 场景材质并加入：

```gdscript
var material := tracer.material_override as ShaderMaterial
var uniform_names: Array[StringName] = []
if material != null and material.shader != null:
	for uniform: Dictionary in material.shader.get_shader_uniform_list():
		uniform_names.append(StringName(uniform.get("name", &"")))
_append(failures, Assertions.expect_true(
	material != null and
		&"lifetime_alpha" in uniform_names and
		&"muzzle_alpha" in uniform_names and
		&"hit_alpha" in uniform_names and
		is_equal_approx(float(material.get_shader_parameter("muzzle_alpha")), 0.0) and
		is_equal_approx(float(material.get_shader_parameter("hit_alpha")), 1.0),
	"Tracer material exposes transparent muzzle and opaque hit endpoint contracts"
))
```

加入整体 alpha 生命周期断言：

```gdscript
tracer.setup(Vector3.ZERO, Vector3(0.0, 0.0, -4.0))
var start_alpha := float(tracer.get_instance_shader_parameter("lifetime_alpha"))
tracer._process(tracer.lifetime * 0.5)
var middle_alpha := float(tracer.get_instance_shader_parameter("lifetime_alpha"))
tracer._process(tracer.lifetime * 0.5)
_append(failures, Assertions.expect_true(
	is_equal_approx(start_alpha, 1.0) and
		middle_alpha < start_alpha and middle_alpha > 0.0 and
		not tracer.visible,
	"Tracer keeps its full line and fades its shared lifetime alpha to zero"
))
```

保留 `_tracer_start()`/`_tracer_end()` 的几何端点断言和零长度不显示断言。

- [ ] **Step 2: 运行完整测试确认有效 RED**

Run:

```bash
./tests/run_tests.sh
```

Expected: exit `1`；当前材质仍是 `StandardMaterial3D`，没有 `lifetime_alpha` 或纵向渐变 Shader。Task 1–3 的状态、转身、统一枪口和墙体截断测试保持通过。

- [ ] **Step 3: 把 ShotTracer 材质改为纵向渐变 Shader**

在 `scenes/fx/ShotTracer.tscn` 用以下 Shader 替换 `StandardMaterial3D`：

```glsl
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

instance uniform float lifetime_alpha : hint_range(0.0, 1.0) = 1.0;
uniform float muzzle_alpha : hint_range(0.0, 1.0) = 0.0;
uniform float hit_alpha : hint_range(0.0, 1.0) = 1.0;
varying float tracer_progress;

void vertex() {
	tracer_progress = clamp(0.5 - VERTEX.z, 0.0, 1.0);
}

void fragment() {
	float longitudinal_alpha = mix(
		muzzle_alpha,
		hit_alpha,
		smoothstep(0.0, 1.0, tracer_progress)
	);
	vec3 tracer_color = mix(
		vec3(1.0, 0.45, 0.05),
		vec3(1.0, 0.78, 0.18),
		tracer_progress
	);
	ALBEDO = tracer_color;
	EMISSION = tracer_color * 3.0;
	ALPHA = longitudinal_alpha * lifetime_alpha;
}
```

`BoxMesh` 尺寸保持 `Vector3(0.035, 0.035, 1)`，节点继续不投射阴影。

- [ ] **Step 4: 用 instance shader 参数推进整体淡出**

把 `scripts/fx/shot_tracer.gd` 中对 `transparency` 的写入替换为：

```gdscript
func setup(from: Vector3, to: Vector3) -> void:
	var distance := from.distance_to(to)
	if distance <= 0.001:
		deactivate()
		return
	remaining = maxf(lifetime, 0.001)
	global_position = (from + to) * 0.5
	scale = Vector3.ONE
	look_at(to, Vector3.UP)
	scale.z = distance
	set_instance_shader_parameter("lifetime_alpha", 1.0)
	visible = true
	set_process(true)

func deactivate() -> void:
	remaining = 0.0
	set_instance_shader_parameter("lifetime_alpha", 0.0)
	visible = false
	set_process(false)

func _process(delta: float) -> void:
	remaining -= delta
	var alpha := clampf(
		remaining / maxf(lifetime, 0.001),
		0.0,
		1.0
	)
	set_instance_shader_parameter("lifetime_alpha", alpha)
	if remaining <= 0.0:
		deactivate()
```

不得创建每枪新材质或新 tracer；继续复用现有对象池和共享 ShaderMaterial。

- [ ] **Step 5: 运行完整自动化验证**

Run:

```bash
./tests/run_tests.sh
```

Expected: `PASS`，所有测试文件通过；无 `SCRIPT ERROR`、`Parse Error` 或非预期 `ERROR:`。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: exit `0`；新增全局类、场景和 Shader 均可导入解析。

Run:

```bash
git diff --check
```

Expected: exit `0`，无输出。

- [ ] **Step 6: 提交曳光弹效果**

```bash
git add scripts/fx/shot_tracer.gd scenes/fx/ShotTracer.tscn tests/unit/test_weapon_feedback.gd
git commit -m "feat: fade tracers from capsule muzzle"
```

---

## 最终代码级验收

- [ ] 人物在 `NORMAL/RAISED` 双阻挡场景中采用目标 yaw 并进入 `TUCKED`。
- [ ] `TUCKED` 胶囊保持统一步枪长度和半径，完整包含在人物胶囊内。
- [ ] 有效远程装备不会因空间不足失败，也不会关闭真实枪械碰撞。
- [ ] `NORMAL/RAISED/TUCKED` 都允许射击且方向始终为人物实际前方。
- [ ] 喷火、射线、tracer、`attack_resolved.origin` 使用同一个胶囊枪口端点。
- [ ] 墙体截断伤害和 tracer，墙后目标不受伤。
- [ ] tracer 在射击帧整段出现，枪口端低透明、命中端高透明，并在约 `0.08s` 内整体淡出。
- [ ] `./tests/run_tests.sh` 全部通过。
- [ ] Godot headless editor exit `0`。
- [ ] `git diff --check` clean。
