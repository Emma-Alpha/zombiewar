# 枪械贴墙抬枪最终修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把现有枪械墙体净空实现修正为“顶墙直接举枪、举枪仍可射击、所有远程武器统一按步枪包络限制，枪身和伤害均不能穿墙”。

**Architecture:** `WeaponClearanceController` 集中持有唯一的步枪净空常量，并把 probe 预测变换与真实 `WeaponCollision` 本地姿态分离；状态、真实碰撞、视觉姿态与人物朝向只在目标姿态验证安全后原子提交。`EquipmentController` 在切枪可见性变更前调用同步守卫，`PlayerController` 在应用已接受 yaw 后从人物实际前向生成远程射击方向，`RangedWeapon` 强制把世界第 1 层纳入射线遮挡。

**Tech Stack:** Godot 4.7.1、GDScript、`CharacterBody3D`、`CollisionShape3D`、`ShapeCast3D`、仓库内 `RefCounted.run()` 测试框架。

## Global Constraints

- 所有远程武器统一使用胶囊总长 `1.55m`、半径 `0.12m`、玩家局部中心偏移 `Vector3(0, 1.12, -0.62)`、抬枪角 `65°`。
- `WeaponCollision` 必须保持为 `Player` 的直属 `CollisionShape3D`，远程武器激活时不得通过关闭该节点解决墙体阻挡。
- `NormalProbe`、`RaisedProbe` 与 `WeaponCollision` 使用三个独立 `CapsuleShape3D` 实例，但尺寸必须完全一致；probe 仅查询世界第 1 层、`collide_with_areas = false`，并排除玩家自身 RID。
- `NORMAL` 顶墙且 `RAISED` 安全时，在同一物理帧直接提交 `65°` 抬枪；物理和视觉不做 `0.15s` 插值。
- `RaisedProbe` 不安全时，状态、真实碰撞、视觉目标与人物 yaw 全部保留上一合法值。
- 放枪只保留 `0.15s` 正常净空稳定时间和沿目标前向 `0.08m` 的恢复查询余量；余量不修改真实胶囊尺寸或中心。
- 世界 yaw 仅由 `Player` 父变换继承一次；probe 可使用 `target_yaw - current_yaw` 做预测，真实 `WeaponCollision` 本地变换不得包含该 yaw 差值。
- `NORMAL`、`RAISED` 都允许按原射速射击；墙体净空逻辑不维护攻击释放门闩、不调用 `cancel_attack()`。
- 人物转向被拒时，远程射击方向必须使用应用后的实际人物前向，不能使用未采纳的 `aim_direction` 或 `target_yaw`。
- 所有远程射线必须包含世界第 1 层并排除玩家；墙位于射线起点与目标之间时，墙必须成为第一次命中且墙后目标不受伤。
- 切到匕首、卸下武器或死亡时才允许关闭枪械碰撞；远程武器互切不得中断真实碰撞。
- 所有生产改动执行严格 TDD：先写测试并运行确认按预期失败，再写最小实现使其通过。
- 不修改 `addons/`、`.godot/` 或 `build/`；GDScript 使用 tab 缩进，新脚本保留对应 `.uid`。

---

## 文件职责与改动边界

- `scripts/combat/weapons/ranged_weapon_definition.gd`：只保存射击定义；移除单枪墙体尺寸字段和校验函数。
- `scripts/player/weapon_clearance_state.gd`：只维护 `DISABLED/NORMAL/RAISED` 与 `0.15s` 恢复计时，不维护射击状态。
- `scripts/player/weapon_clearance_controller.gd`：统一净空常量、probe 预测、安全姿态提交、视觉直接切换、切枪预检与生命周期清理。
- `scripts/player/equipment_controller.gd`：在真正切换前调用同步 `Callable` 守卫，拒绝时保持当前武器和可见性。
- `scripts/player/player_controller.gd`：连接切枪守卫、应用允许 yaw、提供实际远程射击方向，不再由净空状态取消攻击。
- `scripts/combat/weapons/ranged_weapon.gd`：射线遮罩强制包含世界第 1 层。
- `resources/weapons/pistol.tres`、`resources/weapons/rifle.tres`：删除已失效的单枪墙体字段。
- `tests/unit/test_weapon_configuration.gd`：验证远程定义不再暴露单枪净空配置，原射击数据不变。
- `tests/unit/test_weapon_clearance_state.gd`：验证请求姿态、提交姿态和恢复计时。
- `tests/unit/test_weapon_clearance_controller.gd`：验证统一运行时胶囊、即时视觉、非法姿态不提交与生命周期恢复。
- `tests/unit/test_weapon_loadout.gd`：验证切枪守卫成功/失败事务。
- `tests/integration/test_weapon_wall_clearance.gd`：验证真实移动阻挡、单次 yaw、贴墙切枪、raised 射击、实际朝向和墙体伤害截断。

---

### Task 1: 统一步枪包络与纯净空状态机

**Files:**
- Modify: `scripts/combat/weapons/ranged_weapon_definition.gd`
- Modify: `resources/weapons/pistol.tres`
- Modify: `resources/weapons/rifle.tres`
- Modify: `scripts/player/weapon_clearance_state.gd`
- Modify: `scripts/player/weapon_clearance_controller.gd`
- Modify: `scripts/player/player_controller.gd`
- Modify: `tests/unit/test_weapon_configuration.gd`
- Modify: `tests/unit/test_weapon_clearance_state.gd`
- Modify: `tests/unit/test_weapon_clearance_controller.gd`
- Modify: `tests/integration/test_weapon_wall_clearance.gd`

**Interfaces:**
- Consumes: `WeaponBase.definition`、`WeaponBase.visual_anchor`、`WeaponCollision`、`NormalProbe`、`RaisedProbe`。
- Produces: `WeaponClearanceState.configure(initial_pose: int) -> void`、`request_pose(delta: float, normal_clear: bool) -> int`、`commit_pose(requested_pose: int) -> bool`、`reset() -> void`；控制器常量 `WALL_CAPSULE_LENGTH`、`WALL_CAPSULE_RADIUS`、`WALL_CAPSULE_OFFSET`、`WALL_RAISE_ANGLE_DEGREES`。

- [ ] **Step 1: 把配置与状态机期望写成失败测试**

在 `tests/unit/test_weapon_configuration.gd` 删除对 `wall_capsule_*` 和 `has_wall_clearance_profile()` 的旧断言，改成：

```gdscript
_append(failures, Assertions.expect_true(
	not _has_property(pistol, &"wall_capsule_length") and
	not _has_property(pistol, &"wall_capsule_radius") and
	not _has_property(pistol, &"wall_capsule_offset") and
	not _has_property(pistol, &"wall_raise_angle_degrees"),
	"Ranged definitions do not expose per-weapon wall-clearance overrides"
))
_append(failures, Assertions.expect_equal(
	pistol.hit_collision_mask & 1,
	1,
	"Pistol hit mask includes solid world layer one"
))
_append(failures, Assertions.expect_equal(
	rifle.hit_collision_mask & 1,
	1,
	"Rifle hit mask includes solid world layer one"
))
```

在同一测试文件增加精确属性查询 helper：

```gdscript
func _has_property(value: Object, property_name: StringName) -> bool:
	for property: Dictionary in value.get_property_list():
		if StringName(property.get("name", "")) == property_name:
			return true
	return false
```

在 `tests/unit/test_weapon_clearance_state.gd` 用以下序列替换攻击门闩断言：

```gdscript
if not state.has_method("request_pose") or not state.has_method("commit_pose"):
	_append(failures, Assertions.expect_true(
		false,
		"Clearance state exposes separate request and commit APIs"
	))
	return failures
state.configure(WeaponClearanceState.Pose.NORMAL)
var requested := int(state.call("request_pose", 0.016, false))
_append(failures, Assertions.expect_equal(
	requested,
	WeaponClearanceState.Pose.RAISED,
	"Blocked normal pose requests raised without mutating committed pose"
))
_append(failures, Assertions.expect_equal(
	state.pose,
	WeaponClearanceState.Pose.NORMAL,
	"Requested pose stays separate from committed pose"
))
_append(failures, Assertions.expect_true(
	bool(state.call("commit_pose", requested)) and state.pose == WeaponClearanceState.Pose.RAISED,
	"Safe requested pose becomes the committed raised pose"
))
_append(failures, Assertions.expect_equal(
	int(state.call("request_pose", 0.14, true)),
	WeaponClearanceState.Pose.RAISED,
	"Raised pose waits for the full restore delay"
))
_append(failures, Assertions.expect_equal(
	int(state.call("request_pose", 0.016, true)),
	WeaponClearanceState.Pose.NORMAL,
	"Raised pose requests normal after 0.15 seconds of clearance"
))
```

在 `tests/integration/test_weapon_wall_clearance.gd` 把 raised 禁火断言改为 raised 仍能射击：

```gdscript
var cursor_before := rifle.tracer_pool_cursor
Input.action_press(player.primary_attack_action)
player._physics_process(0.016)
rifle._physics_process(0.20)
_append(failures, Assertions.expect_true(
	clearance.is_raised() and rifle.tracer_pool_cursor != cursor_before,
	"Raised rifle keeps firing at the existing cadence"
))
Input.action_release(player.primary_attack_action)
```

从 `tests/unit/test_weapon_clearance_controller.gd` 和 `tests/integration/test_weapon_wall_clearance.gd` 删除全部 `controller.can_fire()`、`clearance.can_fire()`、`observe_trigger()` 断言。放枪覆盖只保留 `0.15s` 状态恢复与最终视觉复原；完成测试编辑后运行：

Run: `rg -n "can_fire|observe_trigger" tests/unit/test_weapon_clearance_controller.gd tests/integration/test_weapon_wall_clearance.gd`

Expected: 无输出。

同时删除旧视觉插值驱动调用：

Run: `rg -n "controller\._process|clearance\._process|transition_duration" tests/unit/test_weapon_clearance_controller.gd tests/integration/test_weapon_wall_clearance.gd`

Expected: 无输出。

在 `tests/unit/test_weapon_clearance_controller.gd` 把三个 capsule 的断言统一为：

```gdscript
for capsule in [rifle_shape, normal_shape, raised_shape]:
	_append(failures, Assertions.expect_float_near(
		capsule.height, 1.55, 0.0001, "Every runtime clearance capsule uses rifle length"
	))
	_append(failures, Assertions.expect_float_near(
		capsule.radius, 0.12, 0.0001, "Every runtime clearance capsule uses rifle radius"
	))
```

同一 controller 测试先写以下 RED 覆盖：正常前墙触发后，`resolve_facing_yaw()` 返回的同一帧视觉 transform 已离开 rest transform；前墙 `Vector3(0.0, 1.12, -1.1)`/`Vector3(3.0, 0.3, 0.2)` 与低顶 `Vector3(0.0, 2.25, -0.25)`/`Vector3(3.0, 0.2, 2.0)` 同时存在时，保存的 pose、碰撞 transform、视觉 transform 和 yaw 全部不变。

```gdscript
var rest_transform := rifle.visual_anchor.transform
var accepted_yaw := controller.resolve_facing_yaw(0.016, Vector3(0.0, 0.0, -0.15), 0.0)
_append(failures, Assertions.expect_true(
	controller.is_raised() and accepted_yaw == 0.0 and
	not rifle.visual_anchor.transform.is_equal_approx(rest_transform),
	"Safe raised request snaps physical and visual pose in the obstruction frame"
))
var previous_pose := controller.state.pose
var previous_collision := weapon_collision.transform
var previous_visual := rifle.visual_anchor.transform
var previous_yaw := player.rotation.y
_append(failures, Assertions.expect_equal(
	controller.resolve_facing_yaw(0.016, Vector3.ZERO, PI * 0.5),
	previous_yaw,
	"Blocked normal and raised requests reject the target yaw"
))
_append(failures, Assertions.expect_true(
	controller.state.pose == previous_pose and
	weapon_collision.transform.is_equal_approx(previous_collision) and
	rifle.visual_anchor.transform.is_equal_approx(previous_visual),
	"Rejected pose preserves committed state, collision, and visual"
))
```

在集成测试增加真实移动与单次 yaw：

```gdscript
var start_position := player.global_position
var collision := player.move_and_collide(Vector3(0.0, 0.0, -0.80), true)
_append(failures, Assertions.expect_true(
	collision != null and player.global_position.is_equal_approx(start_position),
	"Direct WeaponCollision blocks forward motion before the body capsule reaches the wall"
))
_append(failures, Assertions.expect_true(
	player.move_and_collide(Vector3(0.0, 0.0, 0.20), true) == null,
	"Player can test a backward escape motion away from the wall"
))
var accepted_yaw := clearance.resolve_facing_yaw(0.016, Vector3.ZERO, PI * 0.5)
player.rotation.y = accepted_yaw
var expected_axis := Basis(Vector3.UP, accepted_yaw) * Vector3.BACK
var actual_axis := weapon_collision.global_basis.y.normalized()
_append(failures, Assertions.expect_true(
	absf(actual_axis.dot(expected_axis.normalized())) > 0.999,
	"WeaponCollision inherits accepted player yaw exactly once"
))
```

再覆盖 `RAISED + normal_clear + raised_blocked`：先用前墙进入 `RAISED`，保存碰撞、视觉和 yaw；把前墙移到 `z = -4.0`，保留低顶，调用 `resolve_facing_yaw(0.10, Vector3.ZERO, PI * 0.5)`，断言仍保持保存值；再调用 `resolve_facing_yaw(0.05, Vector3.ZERO, PI * 0.5)`，只有完整 `0.15s` 正常净空后才允许原子提交 `NORMAL`。

- [ ] **Step 2: 运行完整测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: 至少因远程定义仍含 `wall_capsule_*`、状态机没有 `request_pose/commit_pose` 而失败；失败原因不得是 GDScript 拼写或解析错误。

- [ ] **Step 3: 移除单枪净空字段并写入统一常量**

把 `scripts/combat/weapons/ranged_weapon_definition.gd` 的 `Wall Clearance` export 组和 `has_wall_clearance_profile()` 整段删除；从 `pistol.tres`、`rifle.tres` 删除四个 `wall_*` 属性。

在 `WeaponClearanceController` 顶部加入：

```gdscript
const WALL_CAPSULE_LENGTH := 1.55
const WALL_CAPSULE_RADIUS := 0.12
const WALL_CAPSULE_OFFSET := Vector3(0.0, 1.12, -0.62)
const WALL_RAISE_ANGLE_DEGREES := 65.0
```

把 `_configure_shapes()` 改成无参数方法，并让三个独立 capsule 都读取上述常量：

```gdscript
func _configure_shapes() -> void:
	var capsules: Array[CapsuleShape3D] = [
		weapon_collision.shape as CapsuleShape3D,
		normal_probe.shape as CapsuleShape3D,
		raised_probe.shape as CapsuleShape3D,
	]
	for capsule: CapsuleShape3D in capsules:
		capsule.height = WALL_CAPSULE_LENGTH
		capsule.radius = WALL_CAPSULE_RADIUS
```

- [ ] **Step 4: 用请求/提交接口重写状态机**

`scripts/player/weapon_clearance_state.gd` 的生产实现使用：

```gdscript
extends RefCounted
class_name WeaponClearanceState

enum Pose { DISABLED, NORMAL, RAISED }

var pose := Pose.DISABLED
var restore_delay: float
var restore_elapsed := 0.0

func _init(value_restore_delay := 0.15) -> void:
	restore_delay = maxf(value_restore_delay, 0.0)

func configure(initial_pose: int) -> void:
	pose = initial_pose
	restore_elapsed = 0.0

func request_pose(delta: float, normal_clear: bool) -> int:
	if pose == Pose.DISABLED:
		return Pose.DISABLED
	if pose == Pose.NORMAL:
		return Pose.NORMAL if normal_clear else Pose.RAISED
	if not normal_clear:
		restore_elapsed = 0.0
		return Pose.RAISED
	restore_elapsed += maxf(delta, 0.0)
	return Pose.NORMAL if restore_elapsed >= restore_delay else Pose.RAISED

func commit_pose(requested_pose: int) -> bool:
	var changed := pose != requested_pose
	pose = requested_pose
	if changed:
		restore_elapsed = 0.0
	return changed

func reset() -> void:
	pose = Pose.DISABLED
	restore_elapsed = 0.0
```

- [ ] **Step 5: 分离预测变换、原子提交姿态并移除攻击门闩**

删除控制器对 `current_definition.wall_*` 的读取；`bind_weapon()` 对有效远程武器只检查 `visual_anchor != null` 并调用 `_configure_shapes()`。实现最终本地姿态与 probe 预测姿态：

```gdscript
func _local_pose_transform(raised: bool) -> Transform3D:
	var raise_radians := deg_to_rad(WALL_RAISE_ANGLE_DEGREES) if raised else 0.0
	var pivot := Vector3(WALL_CAPSULE_OFFSET.x, WALL_CAPSULE_OFFSET.y, 0.0)
	var raise_basis := Basis(Vector3.RIGHT, raise_radians)
	var center := pivot + raise_basis * (WALL_CAPSULE_OFFSET - pivot)
	return Transform3D(
		Basis(Vector3.RIGHT, PI * 0.5 + raise_radians),
		center
	)

func _probe_pose_transform(raised: bool, target_yaw: float) -> Transform3D:
	var local_pose := _local_pose_transform(raised)
	var facing_delta := wrapf(target_yaw - wielder.rotation.y, -PI, PI)
	var facing_basis := Basis(Vector3.UP, facing_delta)
	return Transform3D(facing_basis * local_pose.basis, facing_basis * local_pose.origin)
```

删除 `transition_duration`、全部 `visual_*transition*` 字段、`_begin_visual_transition()` 与 `_process()`。新增原子提交：

```gdscript
func _commit_pose(requested_pose: int) -> void:
	state.commit_pose(requested_pose)
	var raised := state.pose == WeaponClearanceState.Pose.RAISED
	weapon_collision.transform = _local_pose_transform(raised)
	var target := visual_rest_transform
	if raised:
		target.basis = target.basis * Basis(
			Vector3.UP,
			-deg_to_rad(WALL_RAISE_ANGLE_DEGREES)
		)
	current_visual.transform = target
```

probe 只使用 `_probe_pose_transform()`；真实碰撞只使用 `_local_pose_transform()`。`resolve_facing_yaw()` 使用：

```gdscript
var normal_clear := _probe_pose(normal_probe, false, desired_motion, target_yaw)
var raised_clear := _probe_pose(raised_probe, true, desired_motion, target_yaw)
var requested_pose := state.request_pose(delta, normal_clear)
var requested_clear := normal_clear if requested_pose == WeaponClearanceState.Pose.NORMAL else raised_clear
if not requested_clear:
	return wielder.rotation.y
if requested_pose != state.pose:
	_commit_pose(requested_pose)
return target_yaw
```

删除控制器的 `observe_trigger()` 和 `can_fire()`；当前 pose 未变化时不得把 probe 的 yaw 差值写入真实碰撞。

`_probe_pose()` 必须把 probe transform 设置为 `_probe_pose_transform(raised, target_yaw)`；仅在当前已提交状态为 `RAISED` 且正在查询 `NORMAL` 时，给 `desired_motion` 加上 `Basis(Vector3.UP, target_yaw) * Vector3.FORWARD * restore_margin`。`restore_margin` 保持 `0.08`。

有效远程武器初始绑定取得至少一个安全 probe 结果后，使用：

```gdscript
normal_probe.enabled = true
raised_probe.enabled = true
var normal_clear := _probe_pose(normal_probe, false, Vector3.ZERO, wielder.rotation.y)
var raised_clear := _probe_pose(raised_probe, true, Vector3.ZERO, wielder.rotation.y)
var initial_pose := (
	WeaponClearanceState.Pose.NORMAL
	if normal_clear
	else WeaponClearanceState.Pose.RAISED
)
state.configure(initial_pose)
weapon_collision.disabled = false
_commit_pose(initial_pose)
```

把 `_restore_visual_immediately()` 收敛为只在 `current_visual` 有效时恢复 `visual_rest_transform`；删除所有插值计时和 `set_process()` 操作。

在 `PlayerController._physics_process()` 删除 `weapon_clearance.observe_trigger(trigger_pressed)`，并把攻击取消条件改为只受硬直约束：

```gdscript
if hit_reaction_remaining > 0.0:
	trigger_pressed = false
	trigger_just_pressed = false
	equipment.cancel_attack()
```

- [ ] **Step 6: 运行完整测试并确认 GREEN**

Run: `./tests/run_tests.sh`

Expected: `PASS: 33 test file(s)`，测试输出没有 `SCRIPT ERROR`、`ERROR:` 或新增 warning。

- [ ] **Step 7: 运行 Godot 导入与静态差异检查**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`

Expected: exit code `0`，无场景或脚本解析错误。

Run: `git diff --check`

Expected: 无输出。

- [ ] **Step 8: 提交任务**

```bash
git add scripts/combat/weapons/ranged_weapon_definition.gd \
	resources/weapons/pistol.tres resources/weapons/rifle.tres \
	scripts/player/weapon_clearance_state.gd scripts/player/weapon_clearance_controller.gd \
	scripts/player/player_controller.gd \
	tests/unit/test_weapon_configuration.gd tests/unit/test_weapon_clearance_state.gd \
	tests/unit/test_weapon_clearance_controller.gd tests/integration/test_weapon_wall_clearance.gd
git commit -m "fix: unify and safely commit weapon clearance poses"
```

---

### Task 2: 事务切枪与失败关闭

**Files:**
- Modify: `scripts/player/weapon_clearance_controller.gd`
- Modify: `scripts/player/equipment_controller.gd`
- Modify: `scripts/player/player_controller.gd`
- Modify: `tests/unit/test_weapon_clearance_controller.gd`
- Modify: `tests/unit/test_weapon_loadout.gd`
- Modify: `tests/integration/test_weapon_wall_clearance.gd`

**Interfaces:**
- Consumes: Task 1 已完成的统一包络、原子姿态提交和单次 yaw 控制器。
- Produces: `WeaponClearanceController.try_bind_weapon(weapon: WeaponBase) -> bool`、`EquipmentController.set_switch_guard(value: Callable) -> void`、`EquipmentController.setup(..., value_switch_guard: Callable = Callable()) -> void`；守卫签名为 `(candidate: WeaponBase) -> bool`。

- [ ] **Step 1: 写切枪事务与失败关闭的失败测试**

在 `tests/unit/test_weapon_loadout.gd` 先验证守卫 setter 存在，再设置拒绝守卫并断言事务不变：

```gdscript
if not equipment.has_method("set_switch_guard"):
	_append(failures, Assertions.expect_true(false, "Equipment exposes a switch guard setter"))
	player.free()
	return failures
equipment.call("set_switch_guard", func(candidate: WeaponBase) -> bool:
	return candidate.definition.weapon_id != &"pistol"
)
var before_weapon := equipment.get_current_weapon()
var before_slot := equipment.current_slot
var before_trigger_pressed := before_weapon.trigger_pressed
var before_trigger_just_pressed := before_weapon.trigger_just_pressed
_append(failures, Assertions.expect_true(
	not equipment.equip_slot(0),
	"Rejected switch guard returns false"
))
_append(failures, Assertions.expect_true(
	equipment.get_current_weapon() == before_weapon and
	equipment.current_slot == before_slot and
	before_weapon.visible and
	before_weapon.trigger_pressed == before_trigger_pressed and
	before_weapon.trigger_just_pressed == before_trigger_just_pressed,
	"Rejected switch keeps weapon identity, slot, attack state, and visibility"
))
equipment.call("set_switch_guard", Callable())
```

在同一集成测试加入三组切枪契约。先创建前墙 `position = Vector3(0.0, 1.12, -1.1)`、`size = Vector3(3.0, 0.3, 0.2)` 并调用一次 `resolve_facing_yaw()` 进入 `RAISED`；远程互切和缺少挂点用例结束后，再创建低顶 `position = Vector3(0.0, 2.25, -0.25)`、`size = Vector3(3.0, 0.2, 2.0)` 执行匕首双阻挡用例：

```gdscript
var normal_probe := player.get_node("WeaponClearanceController/NormalProbe") as ShapeCast3D
var raised_probe := player.get_node("WeaponClearanceController/RaisedProbe") as ShapeCast3D
# 已抬枪的远程互切继承合法姿态，三个胶囊尺寸不变，真实碰撞不中断。
_append(failures, Assertions.expect_true(
	player.equipment.equip_slot(0) and clearance.is_raised() and not weapon_collision.disabled,
	"Ranged switch inherits the committed raised collision"
))
var runtime_capsules: Array[CapsuleShape3D] = [
	weapon_collision.shape as CapsuleShape3D,
	normal_probe.shape as CapsuleShape3D,
	raised_probe.shape as CapsuleShape3D,
]
for capsule: CapsuleShape3D in runtime_capsules:
	_append(failures, Assertions.expect_true(
		is_equal_approx(capsule.height, 1.55) and is_equal_approx(capsule.radius, 0.12),
		"Ranged switch preserves the unified runtime envelope"
	))

# 候选远程武器缺少 visual_anchor 时，拒绝切换并保留当前远程碰撞。
var rifle_candidate := player.equipment.weapons[1]
var saved_anchor := rifle_candidate.visual_anchor
rifle_candidate.visual_anchor = null
var before_weapon := player.equipment.get_current_weapon()
_append(failures, Assertions.expect_true(
	not player.equipment.equip_slot(1) and
	player.equipment.get_current_weapon() == before_weapon and
	not weapon_collision.disabled,
	"Missing ranged visual rejects the switch without disabling current collision"
))
rifle_candidate.visual_anchor = saved_anchor

# 匕首切远程时前墙和低顶同时阻挡，切换失败并保持匕首。
player.equipment.equip_slot(2)
_append(failures, Assertions.expect_true(
	not player.equipment.equip_slot(1) and
	player.equipment.get_current_definition().weapon_id == &"knife" and
	not player.equipment.weapons[1].visible,
	"Melee-to-ranged switch fails closed when neither initial pose is safe"
))
```

执行缺少挂点用例时当前武器为手枪、候选武器为步枪；执行匕首双阻挡用例时前墙和低顶必须同时存在。

最后在 controller 单元测试中于 raised 状态保存视觉 rest transform，调用 `_exit_tree()`，断言可见枪恢复保存的本地 transform。

- [ ] **Step 2: 运行完整测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: 守卫 setter、缺少挂点拒绝、远程姿态继承或匕首双阻挡拒绝至少一项失败；失败必须复现现有切枪事务缺陷。

- [ ] **Step 3: 实现远程绑定预检与继承合法姿态**

把 `bind_weapon()` 替换成返回布尔值的 `try_bind_weapon()`：

```gdscript
func try_bind_weapon(weapon: WeaponBase) -> bool:
	if weapon == null or not weapon.definition is RangedWeaponDefinition:
		_restore_visual_immediately()
		_disable_clearance()
		return true
	if weapon.visual_anchor == null:
		push_warning("Weapon %s has no visual anchor" % String(weapon.definition.weapon_id))
		return false
	if current_definition != null and state.pose != WeaponClearanceState.Pose.DISABLED:
		_restore_visual_immediately()
		current_weapon = weapon
		current_definition = weapon.definition as RangedWeaponDefinition
		current_visual = weapon.visual_anchor
		visual_rest_transform = current_visual.transform
		_configure_shapes()
		weapon_collision.disabled = false
		_commit_pose(state.pose)
		return true
	_configure_shapes()
	normal_probe.enabled = true
	raised_probe.enabled = true
	var normal_clear := _probe_pose(normal_probe, false, Vector3.ZERO, wielder.rotation.y)
	var raised_clear := _probe_pose(raised_probe, true, Vector3.ZERO, wielder.rotation.y)
	if not normal_clear and not raised_clear:
		normal_probe.enabled = false
		raised_probe.enabled = false
		return false
	current_weapon = weapon
	current_definition = weapon.definition as RangedWeaponDefinition
	current_visual = weapon.visual_anchor
	visual_rest_transform = current_visual.transform
	state.configure(WeaponClearanceState.Pose.NORMAL if normal_clear else WeaponClearanceState.Pose.RAISED)
	weapon_collision.disabled = false
	_commit_pose(state.pose)
	return true
```

失败路径不得先恢复旧视觉、清空 `current_definition` 或关闭现有远程碰撞。新增 `_exit_tree()`：若当前视觉仍有效则恢复保存变换，并调用 `state.reset()` 清理已提交状态；不得访问已失效节点。

- [ ] **Step 4: 在装备控制器接入同步切枪守卫**

在 `EquipmentController` 增加：

```gdscript
var switch_guard := Callable()

func set_switch_guard(value: Callable) -> void:
	switch_guard = value
```

把 `setup()` 扩展为最后一个可选参数 `value_switch_guard: Callable = Callable()` 并保存；`equip_slot()` 在修改旧武器前执行：

```gdscript
var candidate := weapons[slot_index]
if switch_guard.is_valid() and not bool(switch_guard.call(candidate)):
	return false
```

通过后才执行旧武器隐藏、`current_slot/current_weapon` 更新、`weapon_changed.emit()` 与新武器显示。

`PlayerController._ready()` 调用：

```gdscript
equipment.setup(
	self,
	visual_root,
	functional_ray_origin,
	Callable(weapon_clearance, "try_bind_weapon")
)
```

`_on_weapon_changed()` 删除重复的 `weapon_clearance.bind_weapon()` 调用，只保留动画刷新。

- [ ] **Step 5: 运行完整测试、Godot 导入和差异检查**

Run: `./tests/run_tests.sh`

Expected: `PASS: 33 test file(s)`；事务拒绝、远程姿态继承、缺少挂点和匕首双阻挡断言均通过。

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`

Expected: exit code `0`，无场景或脚本解析错误。

Run: `git diff --check`

Expected: 无输出。

- [ ] **Step 6: 提交任务**

```bash
git add scripts/player/weapon_clearance_controller.gd \
	scripts/player/equipment_controller.gd scripts/player/player_controller.gd \
	tests/unit/test_weapon_clearance_controller.gd tests/unit/test_weapon_loadout.gd \
	tests/integration/test_weapon_wall_clearance.gd
git commit -m "fix: make weapon switching transactional"
```

---

### Task 3: 抬枪射击、实际朝向与墙体伤害截断

**Files:**
- Modify: `scripts/player/player_controller.gd`
- Modify: `scripts/combat/weapons/ranged_weapon.gd`
- Modify: `tests/unit/test_weapon_feedback.gd`
- Modify: `tests/integration/test_weapon_wall_clearance.gd`

**Interfaces:**
- Consumes: Task 1 的 `resolve_facing_yaw()` 返回值和 Task 2 的事务切枪接口。
- Produces: `PlayerController._actual_ranged_attack_direction() -> Vector3`；`RangedWeapon._intersect_shot()` 使用 `definition.hit_collision_mask | 1`。

- [ ] **Step 1: 写实际朝向和墙体首命中的失败测试**

在 `tests/unit/test_weapon_feedback.gd` 增加世界墙体遮挡夹具：墙放在 `Vector3(0, 1.1, -2.0)`，尺寸 `Vector3(2.0, 2.0, 0.2)`，目标放在 `Vector3(0, 0, -4.0)`。先临时从定义 mask 清除世界第 1 层，以证明生产代码会强制补回该层；保留墙调用 `weapon._fire(Vector3.FORWARD)`，再移除墙以同一方向再次射击，最后恢复资源值：

```gdscript
var ranged_definition := weapon.definition
var original_hit_mask := ranged_definition.hit_collision_mask
ranged_definition.hit_collision_mask = original_hit_mask & ~1
wall.force_update_transform()
var ray_origin := weapon.get_ray_origin()
var ray_result: Dictionary = weapon.call(
	"_intersect_shot",
	ray_origin,
	ray_origin + Vector3.FORWARD * ranged_definition.attack_range
)
_append(failures, Assertions.expect_true(
	ray_result.get("collider", null) == wall,
	"Layer-one wall is the first functional ray hit even when the resource mask omits it"
))
var health_before := target.health.current
weapon.call("_fire", Vector3.FORWARD)
_append(failures, Assertions.expect_float_near(
	target.health.current,
	health_before,
	0.0001,
	"Layer-one wall prevents damage to the target behind it"
))
wall.free()
weapon.call("_fire", Vector3.FORWARD)
_append(failures, Assertions.expect_true(
	target.health.current < health_before,
	"The same unobstructed shot still damages the target"
))
ranged_definition.hit_collision_mask = original_hit_mask
```

保留 Task 1 已建立的“`RAISED` 会推进 tracer cursor”回归断言，不重复创建第二份。再制造目标 yaw 被双阻挡拒绝的场景：将玩家 `aim_direction` 设为 `Vector3.RIGHT`，把低位侧挡块放在 `position = Vector3(1.1, 0.98, 0.0)`、`size = Vector3(0.2, 0.14, 1.2)`，把低顶放在 `position = Vector3(0.6, 2.25, 0.0)`、`size = Vector3(2.0, 0.2, 2.0)`；功能射线高度 `1.1m` 高于侧挡块顶部 `1.05m`。把只位于目标 yaw 方向的僵尸放在 `Vector3(4.0, 0.0, 0.0)`，连接 `player.attack_resolved` 捕获 `direction`，开火后断言：

```gdscript
var resolved_direction := Vector3.ZERO
player.attack_resolved.connect(func(direction: Vector3, _result, _strength: float) -> void:
	resolved_direction = direction
)
var actual_forward := -player.global_basis.z.normalized()
_append(failures, Assertions.expect_true(
	resolved_direction.dot(actual_forward) > 0.999,
	"Rejected turn fires along the player's accepted facing"
))
_append(failures, Assertions.expect_float_near(
	right_side_target.health.current,
	right_side_target.health.maximum,
	0.0001,
	"Rejected target yaw cannot damage a target only in that direction"
))
```

- [ ] **Step 2: 运行完整测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: 被拒绝转向仍使用旧 `aim_direction`，且临时移除资源层位后旧射线会穿过墙；两个断言按目标缺陷失败。

- [ ] **Step 3: 保持 raised 可射击并改用实际人物前向**

保留 Task 1 已完成的“净空状态不取消攻击”逻辑，不重新引入 `observe_trigger()` 或 `can_fire()`。

在应用 `rotation.y = weapon_clearance.resolve_facing_yaw(...)` 后新增：

```gdscript
func _actual_ranged_attack_direction() -> Vector3:
	return WeaponMath.flat_direction(-global_basis.z)
```

若 `PlayerController` 当前未 preload `WeaponMath`，在顶部加入：

```gdscript
const WeaponMath = preload("res://scripts/combat/weapon_math.gd")
```

提交攻击输入时使用：

```gdscript
var attack_direction := aim_direction
if equipment.get_current_definition() is RangedWeaponDefinition:
	attack_direction = _actual_ranged_attack_direction()
equipment.set_attack_input(trigger_pressed, trigger_just_pressed, attack_direction)
```

并 preload `RangedWeaponDefinition`，近战继续使用原 `aim_direction`。

- [ ] **Step 4: 强制远程射线包含墙体层**

在 `RangedWeapon._intersect_shot()` 中把查询 mask 改为：

```gdscript
var hit_mask := ranged_definition.hit_collision_mask | 1
var query := PhysicsRayQueryParameters3D.create(
	from,
	to,
	hit_mask,
	[wielder.get_rid()]
)
```

保持 `collide_with_areas = true`，不改变伤害、射速、射程或反馈路径。

- [ ] **Step 5: 运行完整测试、Godot 导入和差异检查**

Run: `./tests/run_tests.sh`

Expected: `PASS: 33 test file(s)`；raised 射击生成 tracer，墙后目标不掉血，移除墙后同一射击能造成伤害，被拒绝转向沿实际人物前向射击。

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`

Expected: exit code `0`，无场景或脚本解析错误。

Run: `git diff --check`

Expected: 无输出。

- [ ] **Step 6: 提交任务**

```bash
git add scripts/player/player_controller.gd scripts/combat/weapons/ranged_weapon.gd \
	tests/unit/test_weapon_feedback.gd tests/integration/test_weapon_wall_clearance.gd
git commit -m "fix: block raised shots at world walls"
```

---

## 最终验证

- [ ] 运行 `./tests/run_tests.sh`，预期 `PASS: 33 test file(s)`。
- [ ] 运行 `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`，预期 exit code `0` 且无解析错误。
- [ ] 运行 `git diff --check`，预期无输出。
- [ ] 在 Godot 4.7.1 的 DemoArena 检查手枪与步枪：正面顶墙即时抬枪、斜角、窄门、贴墙互切、匕首切枪双阻挡拒绝、后退恢复、raised 射击、墙后目标不受伤。
- [ ] 保存运行时截图或短视频到评审证据目录，并在最终审查报告中列出绝对路径。
- [ ] 对本计划分支执行一次整分支代码审查；若有发现，只允许一个集中修复波次和一次 scoped re-review。
