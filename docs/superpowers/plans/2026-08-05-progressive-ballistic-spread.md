# 连射递增随机弹道散布 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为手枪和步枪增加只在水平面生效、随连续射击扩大并随时间恢复的随机弹道散布，同时保证物理命中、伤害方向、曳光弹和反馈信号使用同一最终方向。

**Architecture:** 新增纯 `RefCounted` 状态对象 `WeaponSpreadState`，集中处理散布角归一化、单发累积、时间恢复和确定性角度解析；`RangedWeapon` 只负责提供随机样本并把解析后的方向传入现有射线流程。散布参数继续由 `RangedWeaponDefinition` 和每把武器的 `.tres` 资源驱动，不引入自动吸附、垂直弹道或新的场景节点。

**Tech Stack:** Godot 4.7.1、GDScript、`RandomNumberGenerator`、现有 `RefCounted.run() -> Array[String]` 自定义测试框架、Godot 无头测试与编辑器导入检查。

## Global Constraints

- 只实现水平 XZ 平面的随机散布；最终方向必须经过 `WeaponMath.flat_direction()`，不得增加俯仰、弹道下坠、飞行时间或实体子弹。
- 当前代码没有自动吸附，本计划不得恢复 `AimAssistMath`、目标搜索或方向吸附。
- 未来组合顺序固定为“玩家基础方向 → 自动吸附中心方向 → 随机散布 → 物理射线”；随机散布之后不得再次吸附。
- 手枪参数固定为基础 `0.35°`、最大 `3.0°`、每发增加 `0.8°`、每秒恢复 `1.8°`。
- 步枪参数固定为基础 `0.5°`、最大 `5.0°`、每发增加 `0.65°`、每秒恢复 `1.5°`。
- 每发先使用当前散布角计算方向，再累积下一发散布；未通过 `WeaponTrigger` 射速门的输入不得增加散布。
- 武器卸下时重置到基础散布；松开扳机、受伤或临时取消攻击只停止射击，散布继续按时间恢复。
- 射线终点、`apply_hit()` 方向、`attack_resolved` 方向和曳光弹必须来自同一个最终随机方向。
- 保持现有射速、伤害、射程、枪口位置、墙体首次阻挡、视觉后坐、镜头冲击、声音和弹道对象池行为。
- 不修改 `addons/`、不使用 CUA/UI 自动化验证、不提交 `.godot/` 或 `build/`。
- 工作区现有 `AGENTS.md`、`project.godot`、`resources/weapons/knife.tres`、`scenes/weapons/Knife.tscn` 修改不属于本功能；所有 `git add` 必须列出精确文件，禁止把这些修改带入任务提交。

---

## 文件结构

- 新建 `scripts/combat/weapons/weapon_spread_state.gd`：纯散布状态与方向数学，不访问场景树、物理查询、输入或目标。
- 新建 `tests/unit/test_weapon_spread_state.gd`：验证散布边界、累积、恢复、重置和非法输入归一化。
- 修改 `tests/test_runner.gd`：注册新的散布状态单元测试。
- 修改 `scripts/combat/weapons/ranged_weapon_definition.gd`：声明四个可配置散布字段。
- 修改 `resources/weapons/pistol.tres`、`resources/weapons/rifle.tres`：写入已确认的手枪和步枪数值。
- 修改 `tests/unit/test_weapon_configuration.gd`：锁定资源字段和值。
- 修改 `scripts/combat/weapons/ranged_weapon.gd`：创建状态、推进恢复、采样随机偏移、应用最终方向并处理卸下重置。
- 修改 `tests/unit/test_weapon_feedback.gd`：验证最终方向范围、曳光弹一致性、受击方向、恢复、切枪重置和无自动吸附。
- 修改 `tests/integration/test_weapon_wall_clearance.gd`：为与散布无关的枪口/姿态契约注入真实的零散布状态，避免旧测试依赖随机结果；墙体随机弹道阻挡仍由 `test_weapon_feedback.gd` 覆盖。

---

### Task 1: 建立可独立测试的连续散布状态

**Files:**
- Create: `scripts/combat/weapons/weapon_spread_state.gd`
- Create after Godot import: `scripts/combat/weapons/weapon_spread_state.gd.uid`
- Create: `tests/unit/test_weapon_spread_state.gd`
- Create after Godot import: `tests/unit/test_weapon_spread_state.gd.uid`
- Modify: `tests/test_runner.gd:3-38`

**Interfaces:**
- Consumes: `WeaponMath.flat_direction(direction: Vector3) -> Vector3`。
- Produces: `WeaponSpreadState.new(base, maximum, increase, recovery)`、`tick(delta: float) -> void`、`resolve_shot_direction(base_direction: Vector3, normalized_random_offset: float) -> Vector3`、`reset() -> void`、只读测试所需的公开状态字段 `current_spread_degrees: float`。
- Preserves: 输入零向量时沿用 `WeaponMath.flat_direction()` 的 `Vector3.FORWARD` 回退；任何输出方向的 `y` 均为零且长度为一。

- [ ] **Step 1: 验证实施前测试基线并记录非本功能失败**

Run:

```bash
./tests/run_tests.sh
```

Expected: 当前主线测试通过。如果因工作区已有的 `project.godot` 或刀资源修改失败，只记录精确失败，不修复、不暂存、不回滚这些用户修改；后续 RED 必须能明确区分为新增散布测试失败。

- [ ] **Step 2: 先注册并编写失败的散布状态测试**

在 `tests/test_runner.gd` 的 `test_directional_fire.gd` 后加入：

```gdscript
	"res://tests/unit/test_weapon_spread_state.gd",
```

创建 `tests/unit/test_weapon_spread_state.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const WeaponSpreadState = preload(
	"res://scripts/combat/weapons/weapon_spread_state.gd"
)

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_direction_and_single_shot_growth(failures)
	_test_maximum_and_recovery(failures)
	_test_reset(failures)
	_test_invalid_inputs_are_clamped(failures)
	return failures

func _test_direction_and_single_shot_growth(failures: Array[String]) -> void:
	var spread := WeaponSpreadState.new(0.5, 2.0, 0.75, 1.0)
	var centered := spread.resolve_shot_direction(Vector3.FORWARD, 0.0)
	_append(failures, Assertions.expect_vector3_near(
		centered,
		Vector3.FORWARD,
		0.0001,
		"Zero spread sample keeps the base direction"
	))
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		1.25,
		0.0001,
		"A resolved shot grows the next-shot spread"
	))

	spread.reset()
	var negative_edge := spread.resolve_shot_direction(Vector3.FORWARD, -1.0)
	spread.reset()
	var positive_edge := spread.resolve_shot_direction(Vector3.FORWARD, 1.0)
	_append(failures, Assertions.expect_float_near(
		Vector3.FORWARD.angle_to(negative_edge),
		deg_to_rad(0.5),
		0.0001,
		"Negative edge uses the full current spread angle"
	))
	_append(failures, Assertions.expect_float_near(
		Vector3.FORWARD.angle_to(positive_edge),
		deg_to_rad(0.5),
		0.0001,
		"Positive edge uses the full current spread angle"
	))
	_append(failures, Assertions.expect_true(
		negative_edge.x * positive_edge.x < 0.0 and
			is_equal_approx(negative_edge.y, 0.0) and
			is_equal_approx(positive_edge.y, 0.0),
		"Spread edges stay horizontal and land on opposite sides"
	))

func _test_maximum_and_recovery(failures: Array[String]) -> void:
	var spread := WeaponSpreadState.new(0.5, 2.0, 0.75, 1.0)
	for _shot_index in range(8):
		spread.resolve_shot_direction(Vector3.FORWARD, 0.0)
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		2.0,
		0.0001,
		"Repeated shots clamp at maximum spread"
	))
	spread.tick(0.5)
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		1.5,
		0.0001,
		"Spread recovers by degrees per second"
	))
	spread.tick(10.0)
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		0.5,
		0.0001,
		"Spread recovery never drops below base spread"
	))

func _test_reset(failures: Array[String]) -> void:
	var spread := WeaponSpreadState.new(0.35, 3.0, 0.8, 1.8)
	spread.resolve_shot_direction(Vector3.RIGHT, 1.0)
	spread.resolve_shot_direction(Vector3.RIGHT, 1.0)
	spread.reset()
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		0.35,
		0.0001,
		"Reset restores base spread immediately"
	))

func _test_invalid_inputs_are_clamped(failures: Array[String]) -> void:
	var spread := WeaponSpreadState.new(-1.0, -2.0, -3.0, -4.0)
	var direction := spread.resolve_shot_direction(Vector3.RIGHT, 2.0)
	_append(failures, Assertions.expect_vector3_near(
		direction,
		Vector3.RIGHT,
		0.0001,
		"Invalid negative configuration resolves to zero spread"
	))
	_append(failures, Assertions.expect_float_near(
		spread.current_spread_degrees,
		0.0,
		0.0001,
		"Negative configuration cannot corrupt state"
	))

	var bounded := WeaponSpreadState.new(1.0, 0.5, 1.0, 1.0)
	var clamped_edge := bounded.resolve_shot_direction(Vector3.FORWARD, 2.0)
	var spread_after_shot := bounded.current_spread_degrees
	bounded.tick(-10.0)
	_append(failures, Assertions.expect_float_near(
		Vector3.FORWARD.angle_to(clamped_edge),
		deg_to_rad(1.0),
		0.0001,
		"Random offset clamps to one and maximum clamps to base"
	))
	_append(failures, Assertions.expect_float_near(
		bounded.current_spread_degrees,
		spread_after_shot,
		0.0001,
		"Negative delta cannot recover or corrupt spread"
	))

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

- [ ] **Step 3: 运行测试并确认 RED 来自缺少状态实现**

Run:

```bash
./tests/run_tests.sh
```

Expected: FAIL，Godot 无法加载 `res://scripts/combat/weapons/weapon_spread_state.gd`；失败原因是生产类尚不存在，而不是测试语法或已有用户修改。

- [ ] **Step 4: 写入满足测试的最小散布状态实现**

创建 `scripts/combat/weapons/weapon_spread_state.gd`：

```gdscript
extends RefCounted
class_name WeaponSpreadState

const WeaponMath = preload("res://scripts/combat/weapon_math.gd")

var base_spread_degrees: float
var max_spread_degrees: float
var spread_increase_per_shot_degrees: float
var spread_recovery_degrees_per_second: float
var current_spread_degrees: float

func _init(
	value_base_spread_degrees: float,
	value_max_spread_degrees: float,
	value_spread_increase_per_shot_degrees: float,
	value_spread_recovery_degrees_per_second: float
) -> void:
	base_spread_degrees = maxf(value_base_spread_degrees, 0.0)
	max_spread_degrees = maxf(
		value_max_spread_degrees,
		base_spread_degrees
	)
	spread_increase_per_shot_degrees = maxf(
		value_spread_increase_per_shot_degrees,
		0.0
	)
	spread_recovery_degrees_per_second = maxf(
		value_spread_recovery_degrees_per_second,
		0.0
	)
	current_spread_degrees = base_spread_degrees

func tick(delta: float) -> void:
	current_spread_degrees = move_toward(
		current_spread_degrees,
		base_spread_degrees,
		spread_recovery_degrees_per_second * maxf(delta, 0.0)
	)

func resolve_shot_direction(
	base_direction: Vector3,
	normalized_random_offset: float
) -> Vector3:
	var resolved_base := WeaponMath.flat_direction(base_direction)
	var offset := clampf(normalized_random_offset, -1.0, 1.0)
	var angle := deg_to_rad(current_spread_degrees * offset)
	var resolved_direction := WeaponMath.flat_direction(
		resolved_base.rotated(Vector3.UP, angle)
	)
	current_spread_degrees = minf(
		current_spread_degrees + spread_increase_per_shot_degrees,
		max_spread_degrees
	)
	return resolved_direction

func reset() -> void:
	current_spread_degrees = base_spread_degrees
```

- [ ] **Step 5: 导入新脚本并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh
```

Expected: Godot 为两个新 `.gd` 文件生成对应 `.uid`；新增状态测试通过，输出中没有 `SCRIPT ERROR`、`Parse Error` 或 `ERROR:`。如果基线已有用户修改造成独立失败，该失败内容必须与 Step 1 相同。

- [ ] **Step 6: 提交散布状态任务**

```bash
git add \
	scripts/combat/weapons/weapon_spread_state.gd \
	scripts/combat/weapons/weapon_spread_state.gd.uid \
	tests/unit/test_weapon_spread_state.gd \
	tests/unit/test_weapon_spread_state.gd.uid \
	tests/test_runner.gd
git commit -m "feat: add progressive weapon spread state"
```

---

### Task 2: 为手枪与步枪配置独立散布参数

**Files:**
- Modify: `scripts/combat/weapons/ranged_weapon_definition.gd:4-6`
- Modify: `resources/weapons/pistol.tres:20-22`
- Modify: `resources/weapons/rifle.tres:20-22`
- Modify: `tests/unit/test_weapon_configuration.gd:41-70`

**Interfaces:**
- Consumes: `RangedWeaponDefinition` 的现有射程、碰撞掩码和弹道池字段。
- Produces: `base_spread_degrees: float`、`max_spread_degrees: float`、`spread_increase_per_shot_degrees: float`、`spread_recovery_degrees_per_second: float`。
- Preserves: 现有手枪/步枪 `trigger_mode`、`attacks_per_second`、`damage`、`attack_range`、`hit_collision_mask` 和 `tracer_pool_size` 数值。

- [ ] **Step 1: 先添加失败的武器资源契约测试**

在 `tests/unit/test_weapon_configuration.gd` 的碰撞掩码断言之后加入：

```gdscript
	_append(failures, Assertions.expect_float_near(
		pistol.base_spread_degrees,
		0.35,
		0.0001,
		"Pistol base spread"
	))
	_append(failures, Assertions.expect_float_near(
		pistol.max_spread_degrees,
		3.0,
		0.0001,
		"Pistol maximum spread"
	))
	_append(failures, Assertions.expect_float_near(
		pistol.spread_increase_per_shot_degrees,
		0.8,
		0.0001,
		"Pistol spread growth per shot"
	))
	_append(failures, Assertions.expect_float_near(
		pistol.spread_recovery_degrees_per_second,
		1.8,
		0.0001,
		"Pistol spread recovery per second"
	))
	_append(failures, Assertions.expect_float_near(
		rifle.base_spread_degrees,
		0.5,
		0.0001,
		"Rifle base spread"
	))
	_append(failures, Assertions.expect_float_near(
		rifle.max_spread_degrees,
		5.0,
		0.0001,
		"Rifle maximum spread"
	))
	_append(failures, Assertions.expect_float_near(
		rifle.spread_increase_per_shot_degrees,
		0.65,
		0.0001,
		"Rifle spread growth per shot"
	))
	_append(failures, Assertions.expect_float_near(
		rifle.spread_recovery_degrees_per_second,
		1.5,
		0.0001,
		"Rifle spread recovery per second"
	))
```

- [ ] **Step 2: 运行测试并确认 RED 来自缺少资源字段**

Run:

```bash
./tests/run_tests.sh
```

Expected: FAIL，`RangedWeaponDefinition` 不存在四个散布属性，或资源仍返回未配置的默认值。

- [ ] **Step 3: 增加定义字段并写入精确资源参数**

在 `scripts/combat/weapons/ranged_weapon_definition.gd` 的 `tracer_pool_size` 后加入：

```gdscript
@export_group("Ballistic Spread")
@export_range(0.0, 12.0, 0.05) var base_spread_degrees := 0.5
@export_range(0.0, 12.0, 0.05) var max_spread_degrees := 5.0
@export_range(0.0, 12.0, 0.05) var spread_increase_per_shot_degrees := 0.65
@export_range(0.0, 20.0, 0.05) var spread_recovery_degrees_per_second := 1.5
```

在 `resources/weapons/pistol.tres` 的 `tracer_pool_size = 6` 后加入：

```text
base_spread_degrees = 0.35
max_spread_degrees = 3.0
spread_increase_per_shot_degrees = 0.8
spread_recovery_degrees_per_second = 1.8
```

在 `resources/weapons/rifle.tres` 的 `tracer_pool_size = 8` 后加入：

```text
base_spread_degrees = 0.5
max_spread_degrees = 5.0
spread_increase_per_shot_degrees = 0.65
spread_recovery_degrees_per_second = 1.5
```

- [ ] **Step 4: 运行配置测试并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh
```

Expected: 八个散布配置断言通过；既有手枪、步枪和刀配置断言保持不变。

- [ ] **Step 5: 提交武器配置任务**

```bash
git add \
	scripts/combat/weapons/ranged_weapon_definition.gd \
	resources/weapons/pistol.tres \
	resources/weapons/rifle.tres \
	tests/unit/test_weapon_configuration.gd
git commit -m "feat: configure ranged weapon spread"
```

---

### Task 3: 将连续散布接入真实射线、伤害与反馈

**Files:**
- Modify: `scripts/combat/weapons/ranged_weapon.gd:4-110`
- Modify: `tests/unit/test_weapon_feedback.gd:3-220`
- Modify: `tests/integration/test_weapon_wall_clearance.gd:1-565` 中取得 `RangedWeapon` 并依赖精确直线方向的测试位置

**Interfaces:**
- Consumes: Task 1 的 `WeaponSpreadState` 全部公开接口；Task 2 的四个 `RangedWeaponDefinition` 字段；现有 `WeaponTrigger.try_attack()`、`WeaponMath.ray_end_from_direction()`、`RangedWeapon.attack_resolved`。
- Produces: `RangedWeapon.spread_state: WeaponSpreadState`、`RangedWeapon.spread_rng: RandomNumberGenerator`；每次 `_fire()` 发出的信号方向为本发最终随机方向。
- Preserves: `_fire(shot_direction: Vector3) -> void`、`_intersect_shot(from: Vector3, to: Vector3) -> Dictionary`、弹道对象池和现有信号签名不变。

- [ ] **Step 1: 先扩展真实武器反馈测试，使其要求散布接入**

在 `tests/unit/test_weapon_feedback.gd` 顶部加入：

```gdscript
const WeaponMath = preload("res://scripts/combat/weapon_math.gd")
```

把现有 `feedback_origins` 连接扩展为同时记录方向：

```gdscript
	var feedback_origins: Array[Vector3] = []
	var feedback_directions: Array[Vector3] = []
	weapon.attack_resolved.connect(func(
		origin: Vector3,
		direction: Vector3,
		_result: HitResult,
		_visual_recoil_kick: float,
		_camera_impulse_strength: float
	) -> void:
		feedback_origins.append(origin)
		feedback_directions.append(direction)
	)
```

在第一次 `weapon._fire(-player.global_basis.z)` 后加入：

```gdscript
	var ranged_definition := weapon.definition as RangedWeaponDefinition
	var base_direction := WeaponMath.flat_direction(-player.global_basis.z)
	var resolved_direction := feedback_directions.back()
	var tracer_direction := WeaponMath.flat_direction(
		_tracer_end(tracer) - _tracer_start(tracer)
	)
	_append(failures, Assertions.expect_true(
		is_equal_approx(resolved_direction.y, 0.0) and
			base_direction.angle_to(resolved_direction) <=
				deg_to_rad(ranged_definition.base_spread_degrees) + 0.0001,
		"Initial ranged shot stays inside base horizontal spread"
	))
	_append(failures, Assertions.expect_true(
		tracer_direction.dot(resolved_direction) > 0.9999,
		"Tracer follows the same resolved spread direction as feedback"
	))
	_append(failures, Assertions.expect_float_near(
		weapon.spread_state.current_spread_degrees,
		ranged_definition.base_spread_degrees +
			ranged_definition.spread_increase_per_shot_degrees,
		0.0001,
		"A real fired shot grows the next-shot spread"
	))
```

`tests/unit/test_weapon_feedback.gd` 后面原有墙体测试前已经声明过一次 `var ranged_definition := ...`；将原位置的重复声明删除并复用这里提前声明的变量，避免同一函数作用域重名。

紧接上述断言，加入射速门和临时取消不会错误累积或清零散布的测试：

```gdscript
	weapon.spread_state.reset()
	weapon.set_attack_input(true, true, base_direction)
	weapon._physics_process(0.0)
	var spread_after_gate_shot := weapon.spread_state.current_spread_degrees
	weapon.set_attack_input(true, false, base_direction)
	weapon._physics_process(0.0)
	_append(failures, Assertions.expect_float_near(
		weapon.spread_state.current_spread_degrees,
		spread_after_gate_shot,
		0.0001,
		"A held input blocked by fire cadence does not grow spread"
	))
	weapon.cancel_attack()
	_append(failures, Assertions.expect_float_near(
		weapon.spread_state.current_spread_degrees,
		spread_after_gate_shot,
		0.0001,
		"Temporary attack cancellation does not instantly reset spread"
	))
```

保留后续墙体测试，并在墙移除后的命中射击后验证僵尸的水平击退方向与最后一次反馈方向一致：

```gdscript
	var target_knockback_direction := WeaponMath.flat_direction(target.velocity)
	_append(failures, Assertions.expect_true(
		target_knockback_direction.dot(feedback_directions.back()) > 0.999,
		"Damage target receives the same resolved direction as attack feedback"
	))
```

在释放该目标之后加入恢复与切枪重置断言：

```gdscript
	var spread_before_recovery := weapon.spread_state.current_spread_degrees
	weapon._physics_process(0.5)
	_append(failures, Assertions.expect_float_near(
		weapon.spread_state.current_spread_degrees,
		maxf(
			ranged_definition.base_spread_degrees,
			spread_before_recovery -
				ranged_definition.spread_recovery_degrees_per_second * 0.5
		),
		0.0001,
		"Equipped weapon spread recovers over physics time"
	))
	weapon._fire(Vector3.FORWARD)
	_append(failures, Assertions.expect_true(
		weapon.spread_state.current_spread_degrees >
			ranged_definition.base_spread_degrees,
		"Additional shot expands rifle spread before switching"
	))
	equipment.equip_slot(0)
	_append(failures, Assertions.expect_float_near(
		weapon.spread_state.current_spread_degrees,
		ranged_definition.base_spread_degrees,
		0.0001,
		"Unequipping a ranged weapon resets spread to base"
	))
	equipment.equip_slot(1)
```

在原有离轴目标测试发射前加入：

```gdscript
	weapon.spread_state.reset()
```

这保证该断言继续测试“没有自动吸附”，而不是偶然使用已经扩大的散布击中离轴目标。

- [ ] **Step 2: 让墙体净空测试对与散布无关的契约使用真实零散布状态**

在 `tests/integration/test_weapon_wall_clearance.gd` 顶部加入：

```gdscript
const WeaponSpreadState = preload(
	"res://scripts/combat/weapons/weapon_spread_state.gd"
)
```

在测试文件末尾加入测试辅助函数：

```gdscript
func _use_zero_spread(weapon: RangedWeapon) -> void:
	weapon.spread_state = WeaponSpreadState.new(0.0, 0.0, 0.0, 0.0)
```

在以下四个精确位置取得 `RangedWeapon` 后立即调用 `_use_zero_spread(rifle)`：

- `run()` 中取得初始步枪后；该实例随后验证贴墙举枪时仍按原射速发射。
- `_test_raised_shot_obstruction_and_feedback()` 中取得步枪后；该实例随后传入 `_assert_raised_blocker_pair()`。
- `_assert_capsule_shot_contract()` 中取得步枪后；该实例随后验证枪口、曳光弹与严格方向契约。
- `_test_tucked_turn_uses_body_facing()` 中取得步枪后；该实例随后通过 `_physics_process()` 发射。

四处都写入：

```gdscript
	var rifle := player.equipment.get_current_weapon() as RangedWeapon
	_use_zero_spread(rifle)
```

这样现有以下契约仍使用真实 `WeaponSpreadState`，但归零随机影响：

- 枪口端点的手工坐标断言。
- 直线射线预计算命中点与曳光弹终点断言。
- 人物实际朝向与攻击方向的严格相等断言。
- 抬枪、收枪、墙体和 Area 首次阻挡断言。

不要把零散布写回生产资源；真实随机墙体阻挡由 `test_weapon_feedback.gd` 中宽墙后的目标不受伤断言继续覆盖。

- [ ] **Step 3: 运行测试并确认 RED 来自 `RangedWeapon` 尚未暴露散布状态**

Run:

```bash
./tests/run_tests.sh
```

Expected: FAIL，`RangedWeapon` 尚无 `spread_state`，真实射击不会累积或恢复散布；失败不是来自墙体净空测试的随机波动。

- [ ] **Step 4: 在 `RangedWeapon` 中创建并推进散布状态**

在 `scripts/combat/weapons/ranged_weapon.gd` 的常量区加入：

```gdscript
const WeaponSpreadState = preload(
	"res://scripts/combat/weapons/weapon_spread_state.gd"
)
```

在运行时字段区加入：

```gdscript
var spread_state: WeaponSpreadState
var spread_rng := RandomNumberGenerator.new()
```

把 `_ready()` 改为：

```gdscript
func _ready() -> void:
	var ranged_definition := definition as RangedWeaponDefinition
	weapon_trigger = WeaponTrigger.new(
		ranged_definition.trigger_mode,
		ranged_definition.attacks_per_second
	)
	spread_state = WeaponSpreadState.new(
		ranged_definition.base_spread_degrees,
		ranged_definition.max_spread_degrees,
		ranged_definition.spread_increase_per_shot_degrees,
		ranged_definition.spread_recovery_degrees_per_second
	)
	spread_rng.randomize()
	_prewarm_tracers()
```

把 `_physics_process(delta)` 改为先恢复、再判断是否真正发射：

```gdscript
func _physics_process(delta: float) -> void:
	spread_state.tick(delta)
	weapon_trigger.tick(delta)
	if weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed):
		_fire(aim_direction)
	trigger_just_pressed = false
```

新增卸下重置，保留 `WeaponBase.set_equipped()` 对可见性和处理开关的控制：

```gdscript
func set_equipped(value: bool) -> void:
	super.set_equipped(value)
	if not value and spread_state != null:
		spread_state.reset()
```

- [ ] **Step 5: 让 `_fire()` 的所有消费者共用最终随机方向**

把 `_fire()` 中现有：

```gdscript
	var ray_direction := WeaponMath.flat_direction(shot_direction)
```

替换为：

```gdscript
	var ray_direction := spread_state.resolve_shot_direction(
		shot_direction,
		spread_rng.randf_range(-1.0, 1.0)
	)
```

保持后续代码只使用 `ray_direction`：

```gdscript
	var ray_end := WeaponMath.ray_end_from_direction(
		ray_origin,
		ray_direction,
		ranged_definition.attack_range
	)
```

以下现有调用不得改回原始 `shot_direction`：

```gdscript
	collider.call(
		"apply_hit",
		ranged_definition.damage,
		hit_position,
		ray_direction
	)

	tracer.setup(ray_origin, hit_position)

	attack_resolved.emit(
		ray_origin,
		ray_direction,
		hit_result,
		ranged_definition.visual_recoil_kick,
		ranged_definition.camera_impulse_strength
	)
```

`apply_damage(amount, hit_position)` 的旧兼容分支没有方向参数，保持原签名不变。

- [ ] **Step 6: 运行相关测试并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh
```

Expected:

- `test_weapon_spread_state.gd`：散布数学、上限、恢复和重置通过。
- `test_weapon_configuration.gd`：手枪和步枪精确参数通过。
- `test_weapon_feedback.gd`：最终方向位于基础范围、曳光弹一致、目标击退一致、恢复、切枪重置和无自动吸附通过。
- `test_weapon_wall_clearance.gd`：与随机无关的胶囊枪口、姿态和阻挡契约继续稳定通过。
- 完整输出没有 `SCRIPT ERROR`、`Parse Error` 或 `ERROR:`。

- [ ] **Step 7: 做最终静态检查和完整回归验证**

Run:

```bash
rg -n "AimAssistMath|aim_assist|_find_assisted_target" scripts tests resources
rg -n "base_spread_degrees|max_spread_degrees|spread_increase_per_shot_degrees|spread_recovery_degrees_per_second" scripts resources tests
git diff --check
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh
```

Expected:

- 第一条搜索无输出，证明没有恢复自动吸附。
- 第二条搜索只显示定义、两把远程武器资源、状态接线和相关测试。
- `git diff --check` 无空白错误。
- Godot 导入与完整测试全部通过；不得出现运行时警告或解析错误。

- [ ] **Step 8: 提交真实射击接入任务**

```bash
git add \
	scripts/combat/weapons/ranged_weapon.gd \
	tests/unit/test_weapon_feedback.gd \
	tests/integration/test_weapon_wall_clearance.gd
git commit -m "feat: apply progressive spread to ranged fire"
```

提交后运行：

```bash
git status --short
git log -4 --oneline
```

Expected: 只剩用户原有的非本功能工作区修改；最近三个功能提交依次覆盖散布状态、武器配置和真实射击接入。

---

## 最终人工验收建议

源码层验证全部通过后，由用户在游戏中完成以下短流程；不要使用 CUA 自动操作：

1. 装备步枪，对着远处墙面短点一发，观察首发仅有轻微左右偏转。
2. 按住射击约两秒，观察曳光弹落点逐步扩大，但始终围绕人物朝向中心分布。
3. 松开射击约三秒，再次点射，观察散布明显恢复。
4. 连射期间切换手枪再切回步枪，确认步枪从基础散布重新开始。
5. 在僵尸与玩家之间放置墙体或利用现有关卡障碍，确认偏转弹道命中墙体时僵尸不受伤。
6. 截取一张步枪持续射击的弹道截图；如果视觉结果与预期不符，再基于截图调整四个资源数值，不修改散布架构。
