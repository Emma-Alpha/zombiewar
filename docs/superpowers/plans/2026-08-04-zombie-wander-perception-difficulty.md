# 僵尸游荡、感知接近与难度速度 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将僵尸行为改为“范围外随机游荡、感知范围内缓慢接近、只有进入攻击范围才攻击”，并让难度只改变感知状态下的移动速度。

**Architecture:** 使用轻量三状态有限状态机 `WANDER -> AWARE_APPROACH -> ATTACK`，状态判断与移动向量计算放进可独立测试的 `ZombieBehaviorMath`，`ZombieTarget` 只负责保存运行时状态、驱动物理和动画。难度使用只包含 `perception_move_speed` 的 `ZombieDifficultyProfile` Resource，由 `DemoArena` 注入每只僵尸，避免难度改变感知半径、攻击频率、攻击伤害或游荡速度。

**Tech Stack:** Godot 4.7.1、GDScript、Godot Resource、现有自定义 headless 测试运行器。

## Global Constraints

- 僵尸不主动追击并攻击玩家；只有玩家真正进入 `attack_range` 后才允许启动攻击前摇。
- 玩家位于 `perception_range` 外时，僵尸只能围绕出生点随机游荡，不能使用玩家位置决定游荡目标。
- 玩家位于感知范围内、攻击范围外时，僵尸可以朝玩家缓慢接近，但不能启动 `MeleeAttackCycle`。
- 难度只改变 `perception_move_speed`；`perception_range`、`wander_speed`、`attack_range`、`attack_damage`、`attack_windup` 和 `attack_cooldown` 在所有难度下保持一致。
- 固定参数基线：`perception_range = 7.0`、`perception_exit_margin = 1.0`、`wander_speed = 0.55`、`wander_radius = 3.5`、`attack_range = 1.45`、`attack_windup = 0.50`、`attack_cooldown = 1.40`、`attack_damage = 10.0`。
- 难度速度固定为：简单 `0.90`、普通 `1.30`、困难 `1.80`；Demo 默认普通难度。
- 感知退出使用 `1.0` 米滞后区：已经感知玩家的僵尸要等玩家距离大于 `perception_range + perception_exit_margin` 才恢复游荡，防止状态在边界抖动。
- 不在本次引入 NavMesh、行为树、围攻槽位、攻击名额或动态伤害缩放。
- 保留现有受击打断、击退、死亡、血迹、HUD 和玩家死亡逻辑。
- 按工作约定，各 Task 不单独提交；整个计划完成并验收后由用户自行提交。
- 本计划依赖当前工作区尚未提交的攻击系统，默认在当前工作区执行，不创建隔离 worktree。

---

## 文件结构

- Create: `scripts/combat/zombie_behavior_math.gd` — 三状态判定、游荡点和到达减速速度的纯函数。
- Create: `scripts/gameplay/zombie_difficulty_profile.gd` — 只承载感知状态移动速度的难度 Resource。
- Create: `resources/difficulty/zombie_easy.tres` — 简单难度，感知速度 `0.90`。
- Create: `resources/difficulty/zombie_normal.tres` — 普通难度，感知速度 `1.30`。
- Create: `resources/difficulty/zombie_hard.tres` — 困难难度，感知速度 `1.80`。
- Modify: `scripts/combat/zombie_target.gd` — 接入游荡、感知接近和近身攻击状态机。
- Modify: `scripts/gameplay/demo_arena.gd` — 把场景难度速度注入每只僵尸。
- Modify: `scenes/gameplay/DemoArena.tscn` — 默认引用普通难度 Resource。
- Modify: `scenes/targets/ZombieTarget.tscn` — 写入固定感知、游荡和攻击基线参数。
- Create: `tests/unit/test_zombie_behavior_math.gd` — 覆盖状态边界、感知滞后、游荡点和到达减速。
- Create: `tests/unit/test_zombie_difficulty_profile.gd` — 验证三个难度只有感知速度不同且顺序正确。
- Create: `tests/unit/test_zombie_behavior.gd` — 验证游荡不攻击、感知接近不攻击、进入近身范围才攻击。
- Modify: `tests/integration/test_demo_scene.gd` — 验证 Demo 默认普通难度并完成速度注入。
- Modify: `tests/test_runner.gd` — 注册新增测试，移除被替代的旧追击数学测试。
- Delete: `scripts/combat/zombie_pursuit_math.gd` — 状态机接入后删除恒速直线追击算法。
- Delete: `tests/unit/test_zombie_pursuit_math.gd` — 由新的行为数学测试替代。
- Modify: `README.md` — 更新僵尸行为与难度说明。

---

### Task 1: 建立可测试的行为状态与移动数学

**Files:**
- Create: `scripts/combat/zombie_behavior_math.gd`
- Create: `tests/unit/test_zombie_behavior_math.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: `Vector3`、固定感知/攻击参数和由调用方提供的随机角度、随机距离比例。
- Produces: `ZombieBehaviorMath.State`、`next_state(...) -> int`、`wander_point(...) -> Vector3`、`arrive_velocity(...) -> Vector3`、`facing_yaw(...) -> float`。

- [ ] **Step 1: 写行为数学失败测试**

创建 `tests/unit/test_zombie_behavior_math.gd`，完整覆盖以下事实：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZombieBehaviorMath = preload("res://scripts/combat/zombie_behavior_math.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var state := ZombieBehaviorMath.State.WANDER
	state = ZombieBehaviorMath.next_state(state, 8.0, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.WANDER,
		"Player outside perception leaves zombie wandering"
	))
	state = ZombieBehaviorMath.next_state(state, 6.5, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.AWARE_APPROACH,
		"Player inside perception starts slow approach"
	))
	state = ZombieBehaviorMath.next_state(state, 7.6, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.AWARE_APPROACH,
		"Perception exit margin prevents boundary flicker"
	))
	state = ZombieBehaviorMath.next_state(state, 8.1, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.WANDER,
		"Zombie forgets player beyond perception exit margin"
	))
	state = ZombieBehaviorMath.next_state(state, 1.40, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.ATTACK,
		"Only attack range enters attack state"
	))
	state = ZombieBehaviorMath.next_state(state, 2.0, true, 7.0, 1.0, 1.45)
	_append(failures, Assertions.expect_equal(
		state,
		ZombieBehaviorMath.State.AWARE_APPROACH,
		"Leaving attack range returns to approach immediately"
	))
	_append(failures, Assertions.expect_equal(
		ZombieBehaviorMath.next_state(state, 1.0, false, 7.0, 1.0, 1.45),
		ZombieBehaviorMath.State.WANDER,
		"Dead or missing player always returns zombie to wander"
	))

	_append(failures, Assertions.expect_vector3_near(
		ZombieBehaviorMath.wander_point(Vector3(2.0, 0.0, 3.0), PI * 0.5, 0.5, 4.0),
		Vector3(2.0, 0.0, 5.0),
		0.0001,
		"Wander target is derived only from home position and random sample"
	))
	_append(failures, Assertions.expect_vector3_near(
		ZombieBehaviorMath.arrive_velocity(Vector3.ZERO, Vector3(4.0, 0.0, 0.0), 1.45, 1.30, 1.5),
		Vector3(1.30, 0.0, 0.0),
		0.0001,
		"Distant aware zombie uses full difficulty speed"
	))
	_append(failures, Assertions.expect_vector3_near(
		ZombieBehaviorMath.arrive_velocity(Vector3.ZERO, Vector3(1.825, 0.0, 0.0), 1.45, 1.30, 1.5),
		Vector3(0.325, 0.0, 0.0),
		0.0001,
		"Aware zombie slows down before attack range"
	))
	_append(failures, Assertions.expect_vector3_near(
		ZombieBehaviorMath.arrive_velocity(Vector3.ZERO, Vector3(1.40, 0.0, 0.0), 1.45, 1.30, 1.5),
		Vector3.ZERO,
		0.0001,
		"Attack range produces zero approach velocity"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

- [ ] **Step 2: 注册测试并验证失败**

在 `tests/test_runner.gd` 的 `TEST_PATHS` 中加入：

```gdscript
"res://tests/unit/test_zombie_behavior_math.gd",
```

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: FAIL，明确提示 `res://scripts/combat/zombie_behavior_math.gd` 尚不存在。

- [ ] **Step 3: 实现最小行为数学**

创建 `scripts/combat/zombie_behavior_math.gd`：

```gdscript
extends RefCounted
class_name ZombieBehaviorMath

enum State {
	WANDER,
	AWARE_APPROACH,
	ATTACK,
}

static func next_state(
	current_state: int,
	distance_to_player: float,
	target_alive: bool,
	perception_range: float,
	perception_exit_margin: float,
	attack_range: float
) -> int:
	if not target_alive:
		return State.WANDER
	var distance := maxf(distance_to_player, 0.0)
	if distance <= maxf(attack_range, 0.0):
		return State.ATTACK
	var exit_range := maxf(perception_range, 0.0) + maxf(perception_exit_margin, 0.0)
	if current_state == State.AWARE_APPROACH or current_state == State.ATTACK:
		return State.AWARE_APPROACH if distance <= exit_range else State.WANDER
	return State.AWARE_APPROACH if distance <= maxf(perception_range, 0.0) else State.WANDER

static func wander_point(
	home_position: Vector3,
	angle_radians: float,
	distance_ratio: float,
	wander_radius: float
) -> Vector3:
	var radius := maxf(wander_radius, 0.0) * clampf(distance_ratio, 0.0, 1.0)
	return home_position + Vector3(cos(angle_radians), 0.0, sin(angle_radians)) * radius

static func arrive_velocity(
	from_position: Vector3,
	target_position: Vector3,
	stop_range: float,
	move_speed: float,
	slow_radius: float
) -> Vector3:
	var offset := target_position - from_position
	offset.y = 0.0
	var distance := offset.length()
	var gap := distance - maxf(stop_range, 0.0)
	if gap <= 0.0 or distance <= 0.0001:
		return Vector3.ZERO
	var speed_factor := clampf(gap / maxf(slow_radius, 0.01), 0.25, 1.0)
	return offset / distance * maxf(move_speed, 0.0) * speed_factor

static func facing_yaw(direction: Vector3, current_yaw: float) -> float:
	var flat_direction := Vector3(direction.x, 0.0, direction.z)
	if flat_direction.length_squared() <= 0.0001:
		return current_yaw
	flat_direction = flat_direction.normalized()
	return atan2(flat_direction.x, flat_direction.z)
```

- [ ] **Step 4: 运行新增测试和全套测试**

运行相同 headless 命令。Expected: 新增测试通过，现有恒速追击测试仍通过；此 Task 暂不切换运行时行为。

---

### Task 2: 建立只控制感知移动速度的难度配置

**Files:**
- Create: `scripts/gameplay/zombie_difficulty_profile.gd`
- Create: `resources/difficulty/zombie_easy.tres`
- Create: `resources/difficulty/zombie_normal.tres`
- Create: `resources/difficulty/zombie_hard.tres`
- Create: `tests/unit/test_zombie_difficulty_profile.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: Godot `Resource` 加载机制。
- Produces: `ZombieDifficultyProfile.perception_move_speed: float`，以及简单、普通、困难三个可替换资源。

- [ ] **Step 1: 写难度配置失败测试**

创建 `tests/unit/test_zombie_difficulty_profile.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var easy := load("res://resources/difficulty/zombie_easy.tres")
	var normal := load("res://resources/difficulty/zombie_normal.tres")
	var hard := load("res://resources/difficulty/zombie_hard.tres")
	_append(failures, Assertions.expect_true(
		easy is ZombieDifficultyProfile and normal is ZombieDifficultyProfile and hard is ZombieDifficultyProfile,
		"All zombie difficulty resources load as ZombieDifficultyProfile"
	))
	if easy is ZombieDifficultyProfile and normal is ZombieDifficultyProfile and hard is ZombieDifficultyProfile:
		_append(failures, Assertions.expect_float_near(easy.perception_move_speed, 0.90, 0.0001, "Easy perception speed"))
		_append(failures, Assertions.expect_float_near(normal.perception_move_speed, 1.30, 0.0001, "Normal perception speed"))
		_append(failures, Assertions.expect_float_near(hard.perception_move_speed, 1.80, 0.0001, "Hard perception speed"))
		_append(failures, Assertions.expect_true(
			easy.perception_move_speed < normal.perception_move_speed and normal.perception_move_speed < hard.perception_move_speed,
			"Difficulty increases only perceived movement pressure"
		))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

将测试路径加入 `tests/test_runner.gd`，运行全套测试。Expected: FAIL，三个 Resource 尚不存在。

- [ ] **Step 2: 创建难度 Resource 类型**

创建 `scripts/gameplay/zombie_difficulty_profile.gd`：

```gdscript
extends Resource
class_name ZombieDifficultyProfile

@export_range(0.0, 5.0, 0.05) var perception_move_speed := 1.30
```

此类型不得增加感知范围、游荡速度、攻击伤害或攻击冷却字段。

- [ ] **Step 3: 创建三个难度资源**

三个 `.tres` 使用同一个脚本，只设置以下值：

```text
zombie_easy.tres   perception_move_speed = 0.90
zombie_normal.tres perception_move_speed = 1.30
zombie_hard.tres   perception_move_speed = 1.80
```

每个资源的结构为：

```ini
[gd_resource type="Resource" script_class="ZombieDifficultyProfile" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/zombie_difficulty_profile.gd" id="1_profile"]

[resource]
script = ExtResource("1_profile")
perception_move_speed = 1.3
```

简单和困难资源分别将最后一行替换为 `0.9` 与 `1.8`。

- [ ] **Step 4: 运行难度测试和全套测试**

运行 headless 测试。Expected: 三个资源均能加载，速度值严格递增，现有测试不受影响。

---

### Task 3: 接入游荡、感知接近、近身攻击状态机并完成场景验收

**Files:**
- Modify: `scripts/combat/zombie_target.gd`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `scenes/targets/ZombieTarget.tscn`
- Create: `tests/unit/test_zombie_behavior.gd`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `tests/test_runner.gd`
- Delete: `scripts/combat/zombie_pursuit_math.gd`
- Delete: `tests/unit/test_zombie_pursuit_math.gd`
- Modify: `README.md`

**Interfaces:**
- Consumes: `ZombieBehaviorMath`、`ZombieDifficultyProfile.perception_move_speed`、现有 `MeleeAttackCycle` 和 `PlayerController.is_alive()`。
- Produces: `ZombieTarget.set_perception_move_speed(speed: float) -> void`、`ZombieTarget.get_behavior_state() -> int`，以及 Demo 场景对普通难度的默认注入。

- [ ] **Step 1: 写运行时行为失败测试**

创建 `tests/unit/test_zombie_behavior.gd`。测试实例化玩家和僵尸，关闭自动物理处理后手动推进僵尸：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ZombieBehaviorMath = preload("res://scripts/combat/zombie_behavior_math.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var player := (load("res://scenes/player/Player.tscn") as PackedScene).instantiate() as PlayerController
	var zombie := (load("res://scenes/targets/ZombieTarget.tscn") as PackedScene).instantiate() as ZombieTarget
	host.add_child(player)
	host.add_child(zombie)
	tree.root.add_child(host)
	player.set_physics_process(false)
	zombie.set_physics_process(false)
	zombie.set_attack_target(player)
	zombie.set_perception_move_speed(1.30)

	player.global_position = zombie.global_position + Vector3(10.0, 0.0, 0.0)
	zombie.call("_physics_process", 0.1)
	_append(failures, Assertions.expect_equal(
		zombie.get_behavior_state(),
		ZombieBehaviorMath.State.WANDER,
		"Zombie wanders outside perception"
	))
	_append(failures, Assertions.expect_true(
		not zombie.attack_cycle.is_winding_up(),
		"Wandering zombie does not prepare an attack"
	))

	player.global_position = zombie.global_position + Vector3(5.0, 0.0, 0.0)
	zombie.call("_physics_process", 0.1)
	_append(failures, Assertions.expect_equal(
		zombie.get_behavior_state(),
		ZombieBehaviorMath.State.AWARE_APPROACH,
		"Zombie approaches inside perception"
	))
	_append(failures, Assertions.expect_true(
		Vector2(zombie.velocity.x, zombie.velocity.z).length() <= 1.3001,
		"Aware movement respects injected difficulty speed"
	))
	_append(failures, Assertions.expect_true(
		not zombie.attack_cycle.is_winding_up(),
		"Aware approach cannot start an attack outside attack range"
	))

	player.global_position = zombie.global_position + Vector3(1.0, 0.0, 0.0)
	zombie.call("_physics_process", 0.0)
	_append(failures, Assertions.expect_equal(
		zombie.get_behavior_state(),
		ZombieBehaviorMath.State.ATTACK,
		"Zombie attacks only after player enters attack range"
	))
	_append(failures, Assertions.expect_true(
		zombie.attack_cycle.is_winding_up(),
		"Entering attack range starts the fixed attack windup"
	))

	host.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

将测试加入 `tests/test_runner.gd`。Expected: FAIL，`ZombieTarget` 尚未暴露新状态和速度注入接口。

- [ ] **Step 2: 为 ZombieTarget 增加环境行为配置和状态**

将旧 `ZombiePursuitMath` preload 替换为：

```gdscript
const ZombieBehaviorMath = preload("res://scripts/combat/zombie_behavior_math.gd")
```

在 `ZombieTarget` 增加固定环境行为参数：

```gdscript
@export_group("Ambient Behavior")
@export var perception_range := 7.0
@export var perception_exit_margin := 1.0
@export var wander_speed := 0.55
@export var wander_radius := 3.5
@export var wander_arrive_range := 0.25
@export var wander_pause_min := 0.4
@export var wander_pause_max := 1.2
@export var perception_slow_radius := 1.5
@export var movement_acceleration := 5.0

var perception_move_speed := 1.30
var behavior_state := ZombieBehaviorMath.State.WANDER
var home_position := Vector3.ZERO
var wander_target := Vector3.ZERO
var wander_pause_remaining := 0.0
var wander_rng := RandomNumberGenerator.new()
```

在 `_ready()` 中记录出生点并用节点路径生成各自稳定但不同的随机序列：

```gdscript
home_position = global_position
wander_rng.seed = hash(str(get_path()))
_select_wander_target()
```

新增公开接口：

```gdscript
func set_perception_move_speed(speed: float) -> void:
	perception_move_speed = maxf(speed, 0.0)

func get_behavior_state() -> int:
	return behavior_state
```

- [ ] **Step 3: 实现状态更新与随机游荡**

每个物理帧先计算玩家水平距离，再调用：

```gdscript
var previous_state := behavior_state
behavior_state = ZombieBehaviorMath.next_state(
	behavior_state,
	distance_to_target,
	target_alive,
	perception_range,
	perception_exit_margin,
	attack_range
)
if previous_state == ZombieBehaviorMath.State.ATTACK and behavior_state != ZombieBehaviorMath.State.ATTACK:
	attack_cycle.cancel_pending()
	attack_animation_remaining = 0.0
```

仅当 `behavior_state == ATTACK` 且玩家实际距离不大于 `attack_range` 时，把 `target_in_range = true` 传给 `MeleeAttackCycle.tick()`。`AWARE_APPROACH` 绝不能通过状态滞后触发攻击。

游荡目标必须围绕 `home_position` 产生，不读取玩家位置：

```gdscript
func _select_wander_target() -> void:
	wander_target = ZombieBehaviorMath.wander_point(
		home_position,
		wander_rng.randf_range(0.0, TAU),
		wander_rng.randf_range(0.35, 1.0),
		wander_radius
	)

func _wander_velocity(delta: float) -> Vector3:
	if wander_pause_remaining > 0.0:
		wander_pause_remaining = maxf(wander_pause_remaining - delta, 0.0)
		if wander_pause_remaining <= 0.0:
			_select_wander_target()
		return Vector3.ZERO
	var offset := ZombieBehaviorMath.arrive_velocity(
		global_position,
		wander_target,
		wander_arrive_range,
		wander_speed,
		0.8
	)
	if offset == Vector3.ZERO:
		wander_pause_remaining = wander_rng.randf_range(wander_pause_min, wander_pause_max)
	return offset
```

三种状态的目标水平速度必须严格如下：

```gdscript
match behavior_state:
	ZombieBehaviorMath.State.WANDER:
		target_planar_velocity = _wander_velocity(delta)
	ZombieBehaviorMath.State.AWARE_APPROACH:
		target_planar_velocity = ZombieBehaviorMath.arrive_velocity(
			global_position,
			attack_target.global_position,
			attack_range,
			perception_move_speed,
			perception_slow_radius
		)
	ZombieBehaviorMath.State.ATTACK:
		target_planar_velocity = Vector3.ZERO
```

游荡时朝 `target_planar_velocity` 转向；感知和攻击时朝玩家转向。所有状态都继续使用 `move_toward` 与 `move_and_slide()`，加速率使用固定 `movement_acceleration`，停止时继续使用现有地面/空中阻力。

- [ ] **Step 4: 固定攻击节奏并移除旧追击实现**

在脚本默认值和 `scenes/targets/ZombieTarget.tscn` 中统一写入：

```text
perception_range = 7.0
perception_exit_margin = 1.0
wander_speed = 0.55
wander_radius = 3.5
movement_acceleration = 5.0
attack_range = 1.45
attack_damage = 10.0
attack_windup = 0.50
attack_cooldown = 1.40
attack_animation_duration = 0.70
```

删除旧的 `chase_speed`、`chase_acceleration` 场景属性和脚本导出字段。删除 `scripts/combat/zombie_pursuit_math.gd` 与 `tests/unit/test_zombie_pursuit_math.gd`，并从 `tests/test_runner.gd` 移除旧测试路径。

- [ ] **Step 5: 将普通难度注入 Demo 中的所有僵尸**

在 `scripts/gameplay/demo_arena.gd` 增加：

```gdscript
@export var zombie_difficulty: ZombieDifficultyProfile
```

在 `_wire_target(target)` 中，绑定玩家后注入速度：

```gdscript
var zombie := target as ZombieTarget
zombie.set_attack_target(player)
if zombie_difficulty != null:
	zombie.set_perception_move_speed(zombie_difficulty.perception_move_speed)
```

在 `scenes/gameplay/DemoArena.tscn` 引用 `resources/difficulty/zombie_normal.tres` 并赋给根节点 `zombie_difficulty`。未来难度选择只需替换该 Resource；不能在 `DemoArena` 里同时改写感知范围或攻击数值。

- [ ] **Step 6: 扩展 Demo 集成测试**

在 `tests/integration/test_demo_scene.gd` 获取根节点的 `zombie_difficulty`，新增断言：

```gdscript
var difficulty := arena.get("zombie_difficulty") as ZombieDifficultyProfile
_append(failures, Assertions.expect_true(
	difficulty != null,
	"Demo has a zombie difficulty profile"
))
if difficulty != null:
	_append(failures, Assertions.expect_float_near(
		difficulty.perception_move_speed,
		1.30,
		0.0001,
		"Demo defaults to normal zombie perception speed"
	))
```

在遍历僵尸时追加：

```gdscript
_append(failures, Assertions.expect_float_near(
	float(target.get("perception_move_speed")),
	1.30,
	0.0001,
	"Every zombie receives the normal perception speed"
))
_append(failures, Assertions.expect_float_near(
	float(target.get("perception_range")),
	7.0,
	0.0001,
	"Difficulty does not alter zombie perception range"
))
```

- [ ] **Step 7: 更新说明并完成自动化与人工验收**

更新 `README.md` 的敌人行为说明为：僵尸默认围绕出生点随机游荡；玩家进入 7 米感知范围后僵尸以难度配置速度缓慢接近；只有进入 1.45 米攻击范围才会经过 0.50 秒前摇攻击；攻击间隔固定 1.40 秒，难度不改变攻击伤害和频率。

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

自动化 Expected: 全部测试通过，不再加载旧 `ZombiePursuitMath`。

人工验收 Expected:

1. 玩家站在所有僵尸 8 米外时，僵尸围绕各自出生点低速随机移动并偶尔停顿，不朝玩家持续修正方向。
2. 玩家进入 7 米范围但保持在 1.45 米外时，僵尸缓慢接近，且没有 Punch 动画、攻击前摇或玩家掉血。
3. 玩家在 7～8 米边界小幅往返时，僵尸不会每帧切换游荡和接近状态；超过 8 米后恢复游荡。
4. 玩家进入 1.45 米后才出现 Punch 动画，约 0.50 秒后命中；离开攻击距离会取消未完成的攻击。
5. 将 Demo Resource 临时切换为 easy、normal、hard 时，仅感知后的接近速度分别变成 `0.90`、`1.30`、`1.80`；游荡速度、感知距离、伤害与攻击间隔不变。
6. 僵尸受击、击退、死亡、血迹和玩家死亡 HUD 行为与改造前一致。

---

## Self-Review

- Spec coverage: 三状态行为覆盖随机游荡、感知后慢速接近、进入攻击范围才攻击；难度配置只包含感知移动速度。
- Placeholder scan: 计划无占位内容、无未定义接口、无“参考其他 Task”式省略步骤。
- Type consistency: `perception_move_speed` 在 Resource、Demo 注入、ZombieTarget 接口和测试中统一为 `float`；行为状态统一使用 `ZombieBehaviorMath.State`。
- Scope control: Task 共 3 个，未引入路径寻找、行为树或多人围攻协调器。
