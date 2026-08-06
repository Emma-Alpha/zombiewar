# 枪械弹药核心 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为远程武器建立可测试的无限/有限弹药模型，使手枪始终可射击、步枪最多持有 360 发并在每次真实射击时消费 1 发。

**Architecture:** 弹药配置属于 `RangedWeaponDefinition`，运行时弹药保存在各自的 `RangedWeapon` 实例中。射击节流器只在库存可用时消费攻击机会，弹药消费成功后才进入现有 `_fire()` 弹道和反馈链。

**Tech Stack:** Godot 4.7.1、GDScript、`.tres` 武器资源、项目自定义测试运行器。

## Global Constraints

- 本计划是四份计划中的第 1 份；完成后再执行 `2026-08-06-weapon-ownership-demo-loadout.md`。
- 手枪不使用有限弹药；步枪使用有限弹药，最大值固定为 360。
- 每次真正执行的一发步枪射击消费 1 发。
- 步枪为 0 发时，不产生伤害、枪声、枪口火焰、曳光、扩散增长、后坐力或 `attack_resolved`。
- 不实现弹匣、换弹动作或换弹时间。
- `_fire()` 继续表示“已获准执行的一发”，不得在该函数内重复扣弹，以保留现有弹道测试接口。
- 新测试注册到 `tests/test_runner.gd`；必须先看见测试因接口缺失而失败。
- 本计划最终只保留一个提交：`feat: add finite weapon ammo`。

---

### Task 1: 定义并实现枪械弹药状态

**Files:**
- Create: `tests/unit/test_weapon_ammo.gd`
- Modify: `tests/test_runner.gd:4-58`
- Modify: `scripts/combat/weapons/ranged_weapon_definition.gd:1-18`
- Modify: `scripts/combat/weapons/ranged_weapon.gd:12-114`
- Modify: `resources/weapons/pistol.tres`
- Modify: `resources/weapons/rifle.tres`
- Modify: `tests/unit/test_weapon_configuration.gd`
- Modify: `tests/unit/test_weapon_feedback.gd`
- Modify: `tests/integration/test_weapon_wall_clearance.gd`

**Interfaces:**
- Consumes: `WeaponTrigger.try_attack(trigger_pressed: bool, trigger_just_pressed: bool) -> bool`、`RangedWeapon._fire(shot_direction: Vector3) -> void`。
- Produces: `RangedWeaponDefinition.uses_ammo: bool`、`max_ammo: int`、`RangedWeapon.ammo_changed(current: int, maximum: int)`、`set_ammo_count(amount: int) -> void`、`add_ammo(amount: int) -> int`、`get_ammo_count() -> int`、`get_max_ammo() -> int`、`has_ammo_for_shot() -> bool`、`try_consume_ammo() -> bool`。

- [ ] **Step 1: 注册并编写失败测试**

在 `tests/test_runner.gd` 的武器测试段加入：

```gdscript
"res://tests/unit/test_weapon_ammo.gd",
```

创建 `tests/unit/test_weapon_ammo.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const RangedWeapon = preload("res://scripts/combat/weapons/ranged_weapon.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	tree.root.add_child(player)
	var pistol := player.equipment.weapons[0] as RangedWeapon
	var rifle := player.equipment.weapons[1] as RangedWeapon

	_append(failures, Assertions.expect_true(
		not pistol.definition.uses_ammo and pistol.has_ammo_for_shot(),
		"Pistol remains fireable without finite ammo"
	))
	_append(failures, Assertions.expect_true(
		pistol.try_consume_ammo() and pistol.get_ammo_count() == 0,
		"Unlimited pistol consumption leaves inventory unchanged"
	))

	rifle.set_ammo_count(2)
	_append(failures, Assertions.expect_true(
		rifle.try_consume_ammo() and rifle.get_ammo_count() == 1,
		"Rifle consumes one round"
	))
	rifle.set_ammo_count(350)
	_append(failures, Assertions.expect_equal(
		rifle.add_ammo(90), 10,
		"Rifle reports actual capped pickup amount"
	))
	_append(failures, Assertions.expect_equal(
		rifle.get_ammo_count(), 360,
		"Rifle ammo is capped at 360"
	))

	rifle.set_ammo_count(0)
	var resolved_count := 0
	rifle.attack_resolved.connect(func(
		_origin: Vector3,
		_direction: Vector3,
		_result: HitResult,
		_recoil: float,
		_impulse: float
	) -> void:
		resolved_count += 1
	)
	var tracer_cursor_before := rifle.tracer_pool_cursor
	var spread_before := rifle.spread_state.current_spread_degrees
	rifle.set_equipped(true)
	rifle.weapon_trigger.reset()
	rifle.set_attack_input(true, true, Vector3.FORWARD)
	rifle._physics_process(0.0)
	_append(failures, Assertions.expect_true(
		resolved_count == 0 and
			rifle.tracer_pool_cursor == tracer_cursor_before and
			is_equal_approx(rifle.spread_state.current_spread_degrees, spread_before) and
			not rifle.muzzle_flash.visible and
			not rifle.shot_audio.playing,
		"Empty rifle produces no shot side effects"
	))

	player.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在 `tests/unit/test_weapon_configuration.gd` 增加：

```gdscript
_append(failures, Assertions.expect_true(
	not pistol.uses_ammo and pistol.max_ammo == 0,
	"Pistol uses infinite ammo"
))
_append(failures, Assertions.expect_true(
	rifle.uses_ammo and rifle.max_ammo == 360,
	"Rifle uses finite ammo capped at 360"
))
```

- [ ] **Step 2: 运行测试并确认正确失败**

```bash
./tests/run_tests.sh \
  res://tests/unit/test_weapon_ammo.gd \
  res://tests/unit/test_weapon_configuration.gd
```

Expected: FAIL，明确指出 `uses_ammo`、`max_ammo`、`set_ammo_count`、`add_ammo` 或 `try_consume_ammo` 缺失。

- [ ] **Step 3: 增加资源配置字段**

在 `ranged_weapon_definition.gd` 增加：

```gdscript
@export_group("Ammo")
@export var uses_ammo := false
@export_range(0, 9999, 1) var max_ammo := 0
```

资源值：

```ini
# resources/weapons/pistol.tres
uses_ammo = false
max_ammo = 0

# resources/weapons/rifle.tres
uses_ammo = true
max_ammo = 360
```

- [ ] **Step 4: 实现弹药 API**

在 `ranged_weapon.gd` 增加：

```gdscript
signal ammo_changed(current: int, maximum: int)

var current_ammo := 0

func set_ammo_count(amount: int) -> void:
	var next_ammo := clampi(amount, 0, get_max_ammo()) if _uses_ammo() else 0
	if next_ammo == current_ammo:
		return
	current_ammo = next_ammo
	ammo_changed.emit(current_ammo, get_max_ammo())

func add_ammo(amount: int) -> int:
	if not _uses_ammo() or amount <= 0:
		return 0
	var before := current_ammo
	set_ammo_count(current_ammo + amount)
	return current_ammo - before

func get_ammo_count() -> int:
	return current_ammo

func get_max_ammo() -> int:
	return maxi((definition as RangedWeaponDefinition).max_ammo, 0)

func has_ammo_for_shot() -> bool:
	return not _uses_ammo() or current_ammo > 0

func try_consume_ammo() -> bool:
	if not _uses_ammo():
		return true
	if current_ammo <= 0:
		return false
	set_ammo_count(current_ammo - 1)
	return true

func _uses_ammo() -> bool:
	return (definition as RangedWeaponDefinition).uses_ammo
```

- [ ] **Step 5: 把射击门控接入弹药消费**

用以下实现替换 `_physics_process()`：

```gdscript
func _physics_process(delta: float) -> void:
	spread_state.tick(delta)
	weapon_trigger.tick(delta)
	if (
		has_ammo_for_shot() and
		weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed) and
		try_consume_ammo()
	):
		_fire(aim_direction)
	trigger_just_pressed = false
```

- [ ] **Step 6: 为依赖旧开局步枪的射击测试显式装填弹药**

在 `tests/unit/test_weapon_feedback.gd` 取得当前 `RangedWeapon` 后加入：

```gdscript
weapon.set_ammo_count(360)
```

在 `tests/integration/test_weapon_wall_clearance.gd` 两处调用 `rifle._physics_process(...)` 的用例中，取得 rifle 后加入：

```gdscript
rifle.set_ammo_count(360)
```

这些是测试夹具配置，不得把生产 `RangedWeapon.current_ammo` 默认值改成 360。

- [ ] **Step 7: 运行聚焦与完整回归测试**

```bash
./tests/run_tests.sh \
  res://tests/unit/test_weapon_ammo.gd \
  res://tests/unit/test_weapon_configuration.gd \
  res://tests/unit/test_weapon_feedback.gd
./tests/run_tests.sh
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
```

Expected: 全部 PASS；Godot 检查退出码 0，输出无 `SCRIPT ERROR`、`Parse Error` 或 `ERROR:`。

- [ ] **Step 8: 提交本计划**

```bash
git add tests/test_runner.gd tests/unit/test_weapon_ammo.gd \
  scripts/combat/weapons/ranged_weapon_definition.gd \
  scripts/combat/weapons/ranged_weapon.gd \
  resources/weapons/pistol.tres resources/weapons/rifle.tres \
  tests/unit/test_weapon_configuration.gd tests/unit/test_weapon_feedback.gd \
  tests/integration/test_weapon_wall_clearance.gd
git commit -m "feat: add finite weapon ammo"
```
