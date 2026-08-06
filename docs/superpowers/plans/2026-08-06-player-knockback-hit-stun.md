# 玩家击退硬直 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 僵尸命中玩家后产生约两步、可被墙体截停的物理滑退，并在受击后锁定武器攻击 1.2 秒。

**Architecture:** 在 `PlayerMotion` 中增加无场景依赖的击退方向与速度衰减纯函数，由 `PlayerController` 保存击退速度和武器锁定计时。玩家物理帧在击退未结束时用击退速度覆盖主动移动，再通过现有 `move_and_slide()` 处理墙体碰撞；攻击输入则在锁定期内被持续清空。

**Tech Stack:** Godot 4.7.1、GDScript、项目自定义 `RefCounted.run()` 测试框架。

## Global Constraints

- 默认初始击退速度为 `8.0 m/s`，水平衰减为 `18.0 m/s²`，无遮挡理论距离约 `1.78 m`。
- 武器攻击锁定时间为 `1.2 秒`；滑退结束可立即恢复移动。
- 击退必须使用 `CharacterBody3D.move_and_slide()`，不可直接改位置或使用 Tween。
- 受击期间允许换枪和放置物品。
- 连续受击刷新击退方向和完整武器锁定时间。
- 玩家死亡清除击退、受击动画计时和武器锁定。
- 只运行本功能相关定向测试，不运行全量测试。
- 不修改 `addons/`；首次编辑器导入中既有的 Phantom Camera 更新器类型错误不属于本任务范围。

---

### Task 1: 击退方向与速度衰减纯函数

**Files:**
- Modify: `tests/unit/test_player_motion.gd`
- Modify: `scripts/player/player_motion.gd`

**Interfaces:**
- Consumes: `Vector3` 玩家位置、攻击来源位置、玩家正面方向、当前击退速度，以及 `float` 衰减和帧时间。
- Produces: `PlayerMotion.knockback_direction(player_position: Vector3, source_position: Vector3, facing_direction: Vector3) -> Vector3` 与 `PlayerMotion.next_knockback_velocity(current_velocity: Vector3, deceleration: float, delta: float) -> Vector3`。

- [x] **Step 1: 写入会失败的方向和衰减测试**

在 `tests/unit/test_player_motion.gd` 的 `run()` 末尾、`return failures` 之前加入：

```gdscript
	_append(failures, Assertions.expect_vector3_near(
		player_motion.knockback_direction(
			Vector3.ZERO,
			Vector3.RIGHT,
			Vector3.FORWARD
		),
		Vector3.LEFT,
		0.0001,
		"A hit from the right knocks the player left"
	))
	_append(failures, Assertions.expect_vector3_near(
		player_motion.knockback_direction(
			Vector3.ZERO,
			Vector3.ZERO,
			Vector3.FORWARD
		),
		Vector3.BACK,
		0.0001,
		"An overlapping source knocks opposite the player facing"
	))
	_append(failures, Assertions.expect_vector3_near(
		player_motion.next_knockback_velocity(
			Vector3.LEFT * 8.0,
			18.0,
			0.25
		),
		Vector3.LEFT * 3.5,
		0.0001,
		"Knockback velocity decays without changing direction"
	))
	_append(failures, Assertions.expect_vector3_near(
		player_motion.next_knockback_velocity(
			Vector3.LEFT,
			18.0,
			0.25
		),
		Vector3.ZERO,
		0.0001,
		"Knockback decay stops at zero instead of reversing"
	))
```

该测试防止的生产缺陷：击退朝攻击来源移动、重合来源产生零方向、衰减改变方向或越过零点反向。

- [x] **Step 2: 运行测试并确认 RED**

Run:

```bash
./tests/run_tests.sh tests/unit/test_player_motion.gd
```

Expected: FAIL，提示 `knockback_direction` 或 `next_knockback_velocity` 不存在。

- [x] **Step 3: 写入最小纯函数实现**

在 `scripts/player/player_motion.gd` 的 `next_planar_velocity()` 之前加入：

```gdscript
static func knockback_direction(
	player_position: Vector3,
	source_position: Vector3,
	facing_direction: Vector3
) -> Vector3:
	var away := player_position - source_position
	away.y = 0.0
	if away.length_squared() > 0.000001:
		return away.normalized()
	var flat_facing := Vector3(facing_direction.x, 0.0, facing_direction.z)
	if flat_facing.length_squared() <= 0.000001:
		flat_facing = Vector3.FORWARD
	return -flat_facing.normalized()

static func next_knockback_velocity(
	current_velocity: Vector3,
	deceleration: float,
	delta: float
) -> Vector3:
	var planar := Vector3(current_velocity.x, 0.0, current_velocity.z)
	return planar.move_toward(
		Vector3.ZERO,
		maxf(deceleration, 0.0) * maxf(delta, 0.0)
	)
```

- [x] **Step 4: 运行测试并确认 GREEN**

Run:

```bash
./tests/run_tests.sh tests/unit/test_player_motion.gd
```

Expected: PASS，1 个测试文件、0 个失败。

- [x] **Step 5: 提交纯函数任务**

```bash
git add scripts/player/player_motion.gd tests/unit/test_player_motion.gd
git commit -m "feat: add player knockback motion math"
```

---

### Task 2: 玩家受击状态、滑退控制与武器锁定

**Files:**
- Modify: `tests/unit/test_player_damage.gd`
- Create: `tests/integration/test_player_knockback.gd`
- Create: `tests/integration/test_player_knockback.gd.uid`
- Modify: `tests/test_runner.gd`
- Modify: `scripts/player/player_controller.gd`

**Interfaces:**
- Consumes: Task 1 的 `PlayerMotion.knockback_direction(...)` 和 `PlayerMotion.next_knockback_velocity(...)`。
- Produces: 导出参数 `hit_attack_lock_duration: float`、`hit_knockback_speed: float`、`hit_knockback_deceleration: float`；运行状态 `hit_attack_lock_remaining: float` 与 `knockback_velocity: Vector3`；已注册的真实墙体碰撞测试 `res://tests/integration/test_player_knockback.gd`。

- [x] **Step 1: 写入会失败的受击状态和攻击锁测试**

在 `tests/unit/test_player_damage.gd` 第一次非致命 `apply_damage()` 后加入以下断言；测试预期值使用手算字面量，不调用生产击退函数构造期望值：

```gdscript
	var has_hit_lock := _has_property(player, &"hit_attack_lock_remaining")
	var has_knockback := _has_property(player, &"knockback_velocity")
	_append(failures, Assertions.expect_true(
		has_hit_lock and has_knockback,
		"Player exposes hit lock and knockback runtime state"
	))
	if has_hit_lock and has_knockback:
		var current_knockback: Vector3 = player.get("knockback_velocity")
		_append(failures, Assertions.expect_float_near(
			float(player.get("hit_attack_lock_remaining")),
			1.2,
			0.0001,
			"A successful hit starts the full weapon lock"
		))
		_append(failures, Assertions.expect_vector3_near(
			current_knockback,
			Vector3.LEFT * 8.0,
			0.0001,
			"A hit from the right starts leftward knockback"
		))
		Input.action_press(player.primary_attack_action)
		player._physics_process(0.016)
		_append(failures, Assertions.expect_true(
			weapon != null and not weapon.trigger_pressed and not weapon.trigger_just_pressed,
			"Weapon input stays cancelled during the hit lock"
		))
		player._process(1.2)
		player._physics_process(0.016)
		_append(failures, Assertions.expect_true(
			weapon != null and weapon.trigger_pressed,
			"Weapon input resumes after the hit lock expires"
		))
		Input.action_release(player.primary_attack_action)
```

在致命伤害断言附近加入：

```gdscript
	if has_hit_lock and has_knockback:
		var death_knockback: Vector3 = player.get("knockback_velocity")
		_append(failures, Assertions.expect_float_near(
			float(player.get("hit_attack_lock_remaining")),
			0.0,
			0.0001,
			"Death clears the weapon hit lock"
		))
		_append(failures, Assertions.expect_vector3_near(
			death_knockback,
			Vector3.ZERO,
			0.0001,
			"Death clears knockback velocity"
		))
```

并在测试文件末尾加入属性探测辅助函数，确保 RED 阶段以行为失败而不是访问缺失属性时报错：

```gdscript
func _has_property(instance: Object, property_name: StringName) -> bool:
	for property: Dictionary in instance.get_property_list():
		if StringName(property.get("name", "")) == property_name:
			return true
	return false
```

该测试防止的生产缺陷：成功受击未设置击退、攻击锁时长错误、锁定期间仍能把输入传给武器、锁定结束后无法恢复、死亡保留击退或锁定。

- [x] **Step 2: 写入真实滑退墙体测试并注册**

创建 `tests/integration/test_player_knockback.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var wall := _make_wall(
		Vector3(-1.0, 1.0, 0.0),
		Vector3(0.2, 2.0, 3.0)
	)
	Input.action_release(player.primary_attack_action)
	tree.root.add_child(player)
	tree.root.add_child(wall)
	wall.force_update_transform()
	var start := player.global_position
	player.apply_damage(10.0, Vector3.RIGHT)
	for _frame in range(40):
		player._physics_process(1.0 / 60.0)
	var travel := player.global_position - start
	_append(failures, Assertions.expect_true(
		travel.x < -0.1,
		"Real knockback moves away from a right-side attacker"
	))
	_append(failures, Assertions.expect_true(
		player.global_position.x >= -0.46,
		"The player body stops at the wall instead of crossing it"
	))
	Input.action_release(player.primary_attack_action)
	wall.free()
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

将 `res://tests/integration/test_player_knockback.gd` 加入 `tests/test_runner.gd` 的 `TEST_PATHS`，并把物理测试准备条件改为：

```gdscript
		if test_path in [
			"res://tests/integration/test_weapon_wall_clearance.gd",
			"res://tests/integration/test_player_knockback.gd",
		]:
			_release_player_input()
			await physics_frame
```

该测试防止的生产缺陷：击退状态只改变变量却没有产生真实移动，或移动绕过 Godot 碰撞直接穿墙。

- [x] **Step 3: 运行全部新增测试并确认 RED**

Run:

```bash
./tests/run_tests.sh \
  tests/unit/test_player_damage.gd \
  tests/integration/test_player_knockback.gd
```

Expected: FAIL，单元测试提示新增属性不存在或状态不符合期望，集成测试提示玩家没有真实向左滑退。所有失败都应由尚未实现的受击功能导致，而不是测试语法错误。

- [x] **Step 4: 增加导出参数、状态计时与受击初始化**

在 `scripts/player/player_controller.gd` 的 Survivability 导出组和运行状态中加入：

```gdscript
@export var hit_attack_lock_duration := 1.2
@export var hit_knockback_speed := 8.0
@export var hit_knockback_deceleration := 18.0

var hit_attack_lock_remaining := 0.0
var knockback_velocity := Vector3.ZERO
```

在 `_process(delta)` 中衰减武器锁：

```gdscript
	hit_attack_lock_remaining = maxf(hit_attack_lock_remaining - delta, 0.0)
```

把 `apply_damage()` 的来源参数改名为 `source_position`，并在非致命成功伤害分支加入：

```gdscript
		hit_reaction_remaining = maxf(hit_reaction_duration, 0.0)
		hit_attack_lock_remaining = maxf(hit_attack_lock_duration, 0.0)
		var facing_direction := -global_basis.z
		knockback_velocity = PlayerMotion.knockback_direction(
			global_position,
			source_position,
			facing_direction
		) * maxf(hit_knockback_speed, 0.0)
```

- [x] **Step 5: 让物理帧使用真实碰撞滑退并抑制攻击输入**

在 `_physics_process(delta)` 中先判断 `knockback_velocity.length_squared() > 0.000001`。击退有效时把 `move_direction` 设为零，水平速度直接使用 `knockback_velocity`；否则保持现有 `next_planar_velocity()` 路径。`move_and_slide()` 后，用实际碰撞裁剪后的水平 `velocity` 调用：

```gdscript
	knockback_velocity = PlayerMotion.next_knockback_velocity(
		Vector3(velocity.x, 0.0, velocity.z),
		hit_knockback_deceleration,
		delta
	)
```

并将攻击抑制条件统一为：

```gdscript
	var attack_locked := (
		hit_reaction_remaining > 0.0 or
		hit_attack_lock_remaining > 0.0
	)
	if attack_locked:
		trigger_pressed = false
		trigger_just_pressed = false
		equipment.cancel_attack()
```

`_on_weapon_attack_started()` 使用同一个锁定条件拒绝攻击。`_on_depleted()` 加入：

```gdscript
	hit_attack_lock_remaining = 0.0
	knockback_velocity = Vector3.ZERO
```

- [x] **Step 6: 运行核心单元和碰撞测试并确认 GREEN**

Run:

```bash
./tests/run_tests.sh \
  tests/unit/test_player_motion.gd \
  tests/unit/test_player_damage.gd \
  tests/integration/test_player_knockback.gd
```

Expected: PASS，3 个测试文件、0 个失败。

- [x] **Step 7: 对真实碰撞测试执行 mutation check**

临时把玩家物理帧中的 `move_and_slide()` 注释掉，重新运行：

```bash
./tests/run_tests.sh tests/integration/test_player_knockback.gd
```

Expected: FAIL，提示玩家没有真实移动。确认后立即恢复 `move_and_slide()`，再次运行同一命令并确认 PASS。临时破坏不提交。

- [x] **Step 8: 提交完整玩家受击任务**

```bash
git add \
  scripts/player/player_controller.gd \
  tests/unit/test_player_damage.gd \
  tests/integration/test_player_knockback.gd \
  tests/integration/test_player_knockback.gd.uid \
  tests/test_runner.gd
git commit -m "feat: add player knockback hit stun"
```

---

### Task 3: 定向验收与计划提交整理

**Files:**
- Modify: `docs/superpowers/plans/2026-08-06-player-knockback-hit-stun.md`

**Interfaces:**
- Consumes: Task 1 和 Task 2 已通过的生产代码与三个定向测试文件。
- Produces: 一个包含计划、实现和测试的 `feat: add player knockback hit stun` 计划提交。

- [x] **Step 1: 执行最终定向验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh \
  tests/unit/test_player_motion.gd \
  tests/unit/test_player_damage.gd \
  tests/integration/test_player_knockback.gd
git diff --check
```

Expected: 三个定向测试文件全部 PASS，`git diff --check` 无输出。编辑器命令可能继续输出既有的 Phantom Camera 更新器错误，但不得出现指向本任务脚本或测试的新解析错误。

- [x] **Step 2: 把已完成勾选状态提交到任务历史**

```bash
git add docs/superpowers/plans/2026-08-06-player-knockback-hit-stun.md
git commit -m "docs: record player knockback implementation plan"
```

- [x] **Step 3: 按仓库约定压缩为一个计划提交**

确认 `git status --short` 只包含本计划文件和本功能修改后，将 Task 1 至 Task 3 的提交压缩为一个提交：

```bash
git reset --soft deca585
git commit -m "feat: add player knockback hit stun"
```

Expected: `deca585` 之后只有一个 `feat: add player knockback hit stun` 提交，且包含计划、生产代码和定向测试。
