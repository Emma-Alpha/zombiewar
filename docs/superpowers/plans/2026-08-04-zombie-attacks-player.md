# 僵尸攻击玩家 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 `DemoArena` 中让四只僵尸主动追击并近战攻击玩家，玩家拥有生命值、受伤反馈和死亡结算，且不破坏当前射击、命中与血迹功能。

**Architecture:** 保留现有 `ZombieTarget` 与 `PlayerController`，不引入导航网格或新敌人基类。近战攻击时序抽成可独立测试的 `MeleeAttackCycle`，僵尸负责距离判断、移动、朝向与动画，玩家继续复用现有 `Health`；`DemoArena` 只负责依赖绑定和 HUD 展示。

**Tech Stack:** Godot 4.7.1、GDScript、现有自定义 headless 测试运行器。

## Global Constraints

- 只修改当前 demo 场景，不加入刷怪波次、经验、升级、掉落或持久化系统。
- 直接在当前工作区增量实现，不创建独立 worktree。
- 保留当前未提交的射击、命中、击退、血迹和主菜单改动。
- 全部新增行为先写失败测试并确认失败，再写最小实现。
- 不自动创建 Git commit；全部计划执行完成后由用户自行提交。
- 本计划共 3 个 task，不再拆分更多独立 task。

---

### Task 1: 可测试的近战攻击时序

**Files:**
- Create: `scripts/combat/melee_attack_cycle.gd`
- Create: `tests/unit/test_melee_attack_cycle.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: `delta: float`、`target_in_range: bool`、`target_alive: bool`。
- Produces: `MeleeAttackCycle.new(cooldown_seconds, windup_seconds)`、`tick(delta, target_in_range, target_alive) -> bool`、`is_winding_up() -> bool`、`cancel_pending() -> void`。

- [ ] **Step 1: 写近战前摇与冷却的失败测试**

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const MeleeAttackCycle = preload("res://scripts/combat/melee_attack_cycle.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var cycle := MeleeAttackCycle.new(0.8, 0.25)
	_append(failures, Assertions.expect_true(
		not cycle.tick(0.0, true, true) and cycle.is_winding_up(),
		"Entering range starts windup without immediate damage"
	))
	_append(failures, Assertions.expect_true(
		not cycle.tick(0.20, true, true),
		"Attack does not land before windup completes"
	))
	_append(failures, Assertions.expect_true(
		cycle.tick(0.05, true, true),
		"Attack lands when windup completes"
	))
	_append(failures, Assertions.expect_true(
		not cycle.tick(0.30, true, true) and not cycle.is_winding_up(),
		"Cooldown prevents an immediate second attack"
	))
	cycle.tick(0.50, true, true)
	_append(failures, Assertions.expect_true(
		cycle.is_winding_up(),
		"A new attack starts after cooldown"
	))
	cycle.cancel_pending()
	_append(failures, Assertions.expect_true(
		not cycle.is_winding_up() and not cycle.tick(0.30, true, true),
		"Cancelling a windup prevents its pending hit"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

- [ ] **Step 2: 把测试加入运行器并确认 RED**

在 `tests/test_runner.gd` 的 `TEST_PATHS` 中加入：

```gdscript
	"res://tests/unit/test_melee_attack_cycle.gd",
```

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: FAIL，原因是 `res://scripts/combat/melee_attack_cycle.gd` 尚不存在。

- [ ] **Step 3: 写最小攻击时序实现**

```gdscript
extends RefCounted
class_name MeleeAttackCycle

var cooldown_duration: float
var windup_duration: float
var cooldown_remaining := 0.0
var windup_remaining := 0.0
var pending := false

func _init(cooldown_seconds: float, windup_seconds: float) -> void:
	cooldown_duration = maxf(cooldown_seconds, 0.01)
	windup_duration = maxf(windup_seconds, 0.0)

func tick(delta: float, target_in_range: bool, target_alive: bool) -> bool:
	var safe_delta := maxf(delta, 0.0)
	cooldown_remaining = maxf(cooldown_remaining - safe_delta, 0.0)
	if pending:
		windup_remaining = maxf(windup_remaining - safe_delta, 0.0)
		if windup_remaining <= 0.0:
			pending = false
			return target_in_range and target_alive
	if not pending and target_in_range and target_alive and cooldown_remaining <= 0.0:
		pending = true
		windup_remaining = windup_duration
		cooldown_remaining = cooldown_duration
	return false

func is_winding_up() -> bool:
	return pending

func cancel_pending() -> void:
	pending = false
	windup_remaining = 0.0
```

- [ ] **Step 4: 运行测试确认 GREEN**

Run 同 Step 2。Expected: 所有测试通过且无解析错误或警告。

### Task 2: 玩家受伤、生命与死亡状态

**Files:**
- Create: `tests/unit/test_player_damage.gd`
- Modify: `tests/test_runner.gd`
- Modify: `scripts/player/player_controller.gd`
- Modify: `scenes/player/Player.tscn`

**Interfaces:**
- Consumes: 现有 `Health.new(maximum)` 与 `Health.apply_damage(amount)`。
- Produces: `PlayerController.apply_damage(amount, source_position) -> float`、`is_alive() -> bool`、`health_changed(current, maximum)`、`damaged(amount)`、`died`。

- [ ] **Step 1: 写玩家受伤与死亡的失败测试**

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)
	_append(failures, Assertions.expect_true(player.is_alive(), "Player starts alive"))
	_append(failures, Assertions.expect_float_near(
		player.apply_damage(10.0, Vector3.RIGHT), 10.0, 0.0001,
		"Player accepts zombie damage"
	))
	_append(failures, Assertions.expect_float_near(
		player.health.current, 90.0, 0.0001,
		"Player health decreases after a hit"
	))
	player.apply_damage(1000.0, Vector3.RIGHT)
	_append(failures, Assertions.expect_true(not player.is_alive(), "Lethal damage defeats player"))
	_append(failures, Assertions.expect_float_near(
		player.apply_damage(10.0, Vector3.RIGHT), 0.0, 0.0001,
		"Defeated player ignores further damage"
	))
	player.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

- [ ] **Step 2: 把测试加入运行器并确认 RED**

在 `TEST_PATHS` 中加入 `res://tests/unit/test_player_damage.gd`，运行全套测试。Expected: FAIL，原因是玩家尚无 `is_alive`、`apply_damage` 和 `health`。

- [ ] **Step 3: 为玩家接入现有 Health**

在 `PlayerController` 中加入：

```gdscript
const Health = preload("res://scripts/combat/health.gd")

signal health_changed(current: float, maximum: float)
signal damaged(amount: float)
signal died

@export var max_health := 100.0

var health: Health
var defeated := false
var hit_reaction_remaining := 0.0

func _ensure_health_initialized() -> void:
	if health != null:
		return
	health = Health.new(max_health)
	health.changed.connect(_on_health_changed)
	health.depleted.connect(_on_depleted)
	health_changed.emit(health.current, health.maximum)

func apply_damage(amount: float, _source_position := Vector3.ZERO) -> float:
	_ensure_health_initialized()
	if defeated:
		return 0.0
	var applied := health.apply_damage(amount)
	if applied > 0.0:
		damaged.emit(applied)
		hit_reaction_remaining = 0.24
		if animation_player != null and animation_player.has_animation(&"HitReact"):
			animation_player.play(&"HitReact", 0.05)
	return applied

func is_alive() -> bool:
	return not defeated

func _on_health_changed(current: float, maximum: float) -> void:
	health_changed.emit(current, maximum)

func _on_depleted() -> void:
	defeated = true
	velocity.x = 0.0
	velocity.z = 0.0
	weapon.set_combat_input(false, false, aim_direction)
	if animation_player != null and animation_player.has_animation(&"Death"):
		animation_player.play(&"Death", 0.08)
	died.emit()
```

在 `_ready()` 最前调用 `_ensure_health_initialized()`；在 `_process()` 递减 `hit_reaction_remaining`；在 `_physics_process()` 开头对 `defeated` 早退并只保留重力/落地；在 `_update_animation()` 中让死亡和短暂受击动画优先于移动动画。`Player.tscn` 显式配置 `max_health = 100.0`。

- [ ] **Step 4: 运行测试确认 GREEN**

Run 全套 headless 测试。Expected: 玩家受伤测试及原有 17 个测试文件全部通过。

### Task 3: 僵尸追击攻击、Demo HUD 与场景验收

**Files:**
- Modify: `scripts/combat/zombie_target.gd`
- Modify: `scenes/targets/ZombieTarget.tscn`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `README.md`

**Interfaces:**
- Consumes: `MeleeAttackCycle`、`PlayerController.apply_damage`、`PlayerController.is_alive` 与玩家生命信号。
- Produces: `ZombieTarget.set_attack_target(player)`；demo 中每只僵尸追击同一玩家；HUD 节点 `HUD/PlayerHealth`、`HUD/DamageFlash`、`HUD/GameOver`。

- [ ] **Step 1: 扩展 demo 集成测试并确认 RED**

在 `tests/integration/test_demo_scene.gd` 中断言：

```gdscript
var health_label := arena.get_node_or_null("HUD/PlayerHealth") as Label
var game_over := arena.get_node_or_null("HUD/GameOver") as Label

_append(failures, Assertions.expect_true(
	health_label != null and health_label.text == "HP 100 / 100",
	"Demo HUD starts with full player health"
))
_append(failures, Assertions.expect_true(
	game_over != null and not game_over.visible,
	"Game-over message starts hidden"
))
for target in targets.get_children():
	_append(failures, Assertions.expect_true(
		target.get("attack_target") == player,
		"Every zombie targets the arena player"
	))
	_append(failures, Assertions.expect_true(
		target.get("attack_range") > 0.0 and target.get("attack_damage") > 0.0,
		"Every zombie has an enabled melee attack"
	))

player.apply_damage(10.0, Vector3.ZERO)
_append(failures, Assertions.expect_equal(
	health_label.text, "HP 90 / 100",
	"HUD follows player damage"
))
player.apply_damage(1000.0, Vector3.ZERO)
_append(failures, Assertions.expect_true(
	game_over.visible,
	"Lethal damage reveals game-over feedback"
))
```

Run 全套测试。Expected: FAIL，原因是 HUD 节点、目标绑定和僵尸攻击属性尚不存在。

- [ ] **Step 2: 让 ZombieTarget 追击、朝向并攻击玩家**

新增导出参数：

```gdscript
@export_group("Attack Behavior")
@export var chase_speed := 2.6
@export var chase_acceleration := 10.0
@export var attack_range := 1.55
@export var attack_damage := 10.0
@export var attack_cooldown := 0.85
@export var attack_windup := 0.28
```

新增目标和攻击周期：

```gdscript
const MeleeAttackCycle = preload("res://scripts/combat/melee_attack_cycle.gd")

var attack_target: PlayerController
var attack_cycle: MeleeAttackCycle
var attack_animation_remaining := 0.0

func set_attack_target(target: PlayerController) -> void:
	attack_target = target

func _target_is_alive() -> bool:
	return attack_target != null and is_instance_valid(attack_target) and attack_target.is_alive()
```

在初始化阶段创建 `MeleeAttackCycle.new(attack_cooldown, attack_windup)`。在 `_physics_process(delta)` 中计算到玩家的水平向量：目标存活且距离大于 `attack_range` 时用 `move_toward` 追击并播放 `Walk`；进入距离后停止、播放 `Punch`，前摇完成且玩家仍在范围内时调用 `attack_target.apply_damage(attack_damage, global_position)`。受击时调用 `attack_cycle.cancel_pending()`，死亡后不再移动或攻击。

- [ ] **Step 3: 绑定目标并加入 HUD 反馈**

在 `DemoArena._wire_dependencies()` 中为 `World/Targets` 下每个 `ZombieTarget` 同时调用 `_wire_target_blood(zombie)` 和 `zombie.set_attack_target(player)`。连接玩家信号：

```gdscript
player.health_changed.connect(_on_player_health_changed)
player.damaged.connect(_on_player_damaged)
player.died.connect(_on_player_died)
```

实现 HUD 回调：

```gdscript
func _on_player_health_changed(current: float, maximum: float) -> void:
	var label := get_node("HUD/PlayerHealth") as Label
	label.text = "HP %d / %d" % [ceili(current), ceili(maximum)]

func _on_player_damaged(_amount: float) -> void:
	var flash := get_node("HUD/DamageFlash") as ColorRect
	flash.color.a = 0.30
	var tween := create_tween()
	tween.tween_property(flash, "color:a", 0.0, 0.20)

func _on_player_died() -> void:
	(get_node("HUD/GameOver") as Label).visible = true
	(get_node("HUD/Objective") as Label).text = "OBJECTIVE FAILED — PLAYER DOWN"
```

在 `DemoArena.tscn` 新增左上生命标签、全屏红色受伤闪烁层与默认隐藏的居中 `PLAYER DOWN` 文本；把目标说明从练习靶改为存活并清除僵尸。

- [ ] **Step 4: 更新文档并完成自动化与手动验收**

更新 `README.md`：说明四只僵尸会以 2.6 速度追击，1.55 米内经过 0.28 秒前摇造成 10 点伤害，攻击间隔 0.85 秒，玩家初始生命 100；从“后续里程碑”移除 enemy attacks，但继续保留刷怪波次、升级和持久化。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

Expected: headless 测试全部通过；进入 demo 后僵尸主动接近玩家、进入距离播放攻击动画并扣血，玩家可边撤退边射击，玩家死亡后停止输入和开火、僵尸不再继续攻击，HUD 显示 `PLAYER DOWN`；无新增解析错误或运行时错误。
