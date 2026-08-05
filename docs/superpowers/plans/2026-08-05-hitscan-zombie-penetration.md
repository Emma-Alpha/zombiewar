# Hitscan 枪械僵尸穿透实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 Godot 4.7.1 Hitscan 射击链路中，为每把远程武器增加可配置的僵尸穿透数量和逐目标递减伤害，同时保持建筑阻挡与单次射击反馈契约。

**Architecture:** 保留 `_fire()` 每发只解析一次散布方向的结构，把原单次 `intersect_ray()` 改为同一起点、同一终点、逐步扩大排除集合的有限循环。僵尸通过 `damageable_targets` 组识别并按实体 ID 去重；非僵尸碰撞体最多承受一次既有伤害后立即截断。每个僵尸独立执行 `apply_hit()`，远程武器把有效结果汇总成一个 `HitResult` 并只发送一次 `attack_resolved`。

**Tech Stack:** Godot 4.7.1、GDScript、`PhysicsRayQueryParameters3D`、项目自定义 `RefCounted.run()` 测试框架、Headless Godot。

## Global Constraints

- 首个僵尸承受 `100%` 基础伤害；后续目标伤害按穿透系数递乘。
- `max_penetration_count` 表示首个目标之后的额外僵尸数量。
- 手枪使用穿透系数 `0.5`、最大额外穿透 `1`；步枪使用 `0.75`、最大额外穿透 `3`。
- 建筑、墙体及其他非僵尸场景碰撞立即截断射击。
- 同一僵尸的多个 Hitbox 不得重复伤害或重复计数。
- 穿透过程必须复用本发散布后的同一个方向，不重新采样随机数。
- 枪口火焰、声音、曳光、后坐力、相机冲击和 `attack_resolved` 每发只触发一次。
- 不修改近战武器、僵尸基础属性、第三方 `addons/`，不引入实体子弹。
- 验证只覆盖核心业务路径、Headless 解析和基本 Smoke Test，不追求覆盖率。
- 当前工作区含用户已有且与本功能重叠的暂存/未暂存改动；所有子任务禁止回退、覆盖或自行提交这些改动。最终提交只能由根代理在确认可精确隔离后执行。
- 计划编写时 `./tests/run_tests.sh` 已有 4 个与本功能无关的基线失败：刀动画 1 项、刀攻击周期 3 项。RED/GREEN 判断以穿透测试是否新增/消失为准，最终不得新增失败。

---

## 文件结构

- 修改 `scripts/combat/weapons/ranged_weapon_definition.gd`：声明远程武器穿透配置。
- 修改 `resources/weapons/pistol.tres`：写入手枪 `0.5 / 1` 参数。
- 修改 `resources/weapons/rifle.tres`：写入步枪 `0.75 / 3` 参数。
- 修改 `scripts/combat/weapons/ranged_weapon.gd`：循环射线、目标去重、伤害衰减、结果汇总和终点解析。
- 修改 `tests/unit/test_weapon_configuration.gd`：验证资源参数。
- 新建 `tests/unit/test_weapon_penetration.gd`：覆盖两把枪的核心穿透路径、墙体阻挡与多 Hitbox 去重。
- 新建 `tests/unit/test_weapon_penetration.gd.uid`：由 Godot 导入生成并随脚本保留。
- 修改 `tests/test_runner.gd`：注册新的穿透测试。

### Task 1: 武器穿透配置

**Files:**
- Modify: `tests/unit/test_weapon_configuration.gd:41-99`
- Modify: `scripts/combat/weapons/ranged_weapon_definition.gd:4-11`
- Modify: `resources/weapons/pistol.tres`
- Modify: `resources/weapons/rifle.tres`

**Interfaces:**
- Consumes: 现有 `RangedWeaponDefinition` 资源加载与 `_has_property(value, property_name)` 测试辅助函数。
- Produces: `penetration_damage_coefficient: float` 与 `max_penetration_count: int`，供 Task 2 的射击循环读取。

- [ ] **Step 1: 写入失败的配置测试**

在 `test_weapon_configuration.gd` 的碰撞层断言后加入存在性检查，避免字段缺失时触发无关运行时错误：

```gdscript
	var pistol_has_penetration := (
		_has_property(pistol, &"penetration_damage_coefficient") and
		_has_property(pistol, &"max_penetration_count")
	)
	var rifle_has_penetration := (
		_has_property(rifle, &"penetration_damage_coefficient") and
		_has_property(rifle, &"max_penetration_count")
	)
	_append(failures, Assertions.expect_true(
		pistol_has_penetration,
		"Pistol exposes penetration configuration"
	))
	_append(failures, Assertions.expect_true(
		rifle_has_penetration,
		"Rifle exposes penetration configuration"
	))
	if pistol_has_penetration:
		_append(failures, Assertions.expect_float_near(
			pistol.penetration_damage_coefficient,
			0.5,
			0.0001,
			"Pistol penetration damage coefficient"
		))
		_append(failures, Assertions.expect_equal(
			pistol.max_penetration_count,
			1,
			"Pistol maximum extra penetration count"
		))
	if rifle_has_penetration:
		_append(failures, Assertions.expect_float_near(
			rifle.penetration_damage_coefficient,
			0.75,
			0.0001,
			"Rifle penetration damage coefficient"
		))
		_append(failures, Assertions.expect_equal(
			rifle.max_penetration_count,
			3,
			"Rifle maximum extra penetration count"
		))
```

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
./tests/run_tests.sh
```

Expected: 除已知 4 个基线失败外，新增 `Pistol exposes penetration configuration` 和 `Rifle exposes penetration configuration` 失败。

- [ ] **Step 3: 增加最小配置实现**

在 `RangedWeaponDefinition` 的 tracer 配置后、Ballistic Spread 分组前加入：

```gdscript
@export_group("Penetration")
@export_range(0.0, 1.0, 0.05) var penetration_damage_coefficient := 0.0
@export_range(0, 16, 1) var max_penetration_count := 0
```

在 `pistol.tres` 的 `tracer_pool_size` 后加入：

```text
penetration_damage_coefficient = 0.5
max_penetration_count = 1
```

在 `rifle.tres` 的 `tracer_pool_size` 后加入：

```text
penetration_damage_coefficient = 0.75
max_penetration_count = 3
```

- [ ] **Step 4: 运行测试并确认配置 GREEN**

Run:

```bash
./tests/run_tests.sh
```

Expected: 两个穿透配置失败消失；输出只保留计划开始前记录的 4 个刀相关基线失败，不新增 Parse Error、SCRIPT ERROR 或配置失败。

- [ ] **Step 5: 检查变更边界**

Run:

```bash
git diff --check -- \
  scripts/combat/weapons/ranged_weapon_definition.gd \
  resources/weapons/pistol.tres \
  resources/weapons/rifle.tres \
  tests/unit/test_weapon_configuration.gd
```

Expected: 无输出。此步骤不提交，由根代理保留现有工作区索引状态。

### Task 2: Hitscan 多僵尸穿透与汇总结果

**Files:**
- Create: `tests/unit/test_weapon_penetration.gd`
- Create: `tests/unit/test_weapon_penetration.gd.uid`
- Modify: `tests/test_runner.gd:10-14`
- Modify: `scripts/combat/weapons/ranged_weapon.gd:85-153`

**Interfaces:**
- Consumes: Task 1 的 `RangedWeaponDefinition.penetration_damage_coefficient` 和 `max_penetration_count`；现有 `HitResult`、`ZombieTarget.apply_hit()`、`ShotTracer.setup()`。
- Produces: `_resolve_shot(from: Vector3, to: Vector3, shot_direction: Vector3) -> Dictionary`，返回 `{"end_position": Vector3, "hit_result": HitResult}`；`_intersect_shot(from, to, excluded)` 支持递增排除 RID。

- [ ] **Step 1: 新建核心穿透测试并注册**

在 `tests/test_runner.gd` 的 `test_weapon_configuration.gd` 后加入：

```gdscript
	"res://tests/unit/test_weapon_penetration.gd",
```

新建 `tests/unit/test_weapon_penetration.gd`，完整内容如下：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const ZombieHitbox = preload("res://scripts/combat/zombie_hitbox.gd")
const EquipmentController = preload("res://scripts/player/equipment_controller.gd")
const RangedWeapon = preload("res://scripts/combat/weapons/ranged_weapon.gd")
const HitResult = preload("res://scripts/combat/hit_result.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_pistol_damage_and_limit(failures)
	_test_rifle_damage_and_summary(failures)
	_test_wall_block_and_hitbox_deduplication(failures)
	return failures

func _test_pistol_damage_and_limit(failures: Array[String]) -> void:
	var fixture := _make_fixture()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	fixture.add_child(player)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(0)
	var weapon := equipment.get_current_weapon() as RangedWeapon
	_disable_spread(weapon)
	var targets: Array[ZombieTarget] = [
		_spawn_target(fixture, Vector3(0.0, 0.0, -4.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -7.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -10.0)),
	]

	weapon._fire(Vector3.FORWARD)

	_append(failures, Assertions.expect_float_near(
		targets[0].health.current,
		15.0,
		0.0001,
		"Pistol first zombie receives full damage"
	))
	_append(failures, Assertions.expect_float_near(
		targets[1].health.current,
		32.5,
		0.0001,
		"Pistol second zombie receives coefficient damage"
	))
	_append(failures, Assertions.expect_float_near(
		targets[2].health.current,
		50.0,
		0.0001,
		"Pistol stops after one extra penetration"
	))
	fixture.free()

func _test_rifle_damage_and_summary(failures: Array[String]) -> void:
	var fixture := _make_fixture()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	fixture.add_child(player)
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.equip_slot(1)
	var weapon := equipment.get_current_weapon() as RangedWeapon
	_disable_spread(weapon)
	var targets: Array[ZombieTarget] = [
		_spawn_target(fixture, Vector3(0.0, 0.0, -4.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -7.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -10.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -13.0)),
		_spawn_target(fixture, Vector3(0.0, 0.0, -16.0)),
	]
	var feedback_results: Array[HitResult] = []
	weapon.attack_resolved.connect(func(
		_origin: Vector3,
		_direction: Vector3,
		result: HitResult,
		_visual_recoil_kick: float,
		_camera_impulse_strength: float
	) -> void:
		feedback_results.append(result)
	)

	weapon._fire(Vector3.FORWARD)

	var expected_health: Array[float] = [
		25.0,
		31.25,
		35.9375,
		39.453125,
		50.0,
	]
	for target_index in range(targets.size()):
		_append(failures, Assertions.expect_float_near(
			targets[target_index].health.current,
			expected_health[target_index],
			0.0001,
			"Rifle penetration health at target %d" % target_index
		))
	_append(failures, Assertions.expect_equal(
		feedback_results.size(),
		1,
		"Penetrating rifle shot emits one attack result"
	))
	if feedback_results.size() == 1:
		_append(failures, Assertions.expect_true(
			feedback_results[0].did_hit,
			"Penetrating rifle summary reports a hit"
		))
		_append(failures, Assertions.expect_float_near(
			feedback_results[0].damage_applied,
			68.359375,
			0.0001,
			"Penetrating rifle summary totals actual damage"
		))
	fixture.free()

func _test_wall_block_and_hitbox_deduplication(
	failures: Array[String]
) -> void:
	var wall_fixture := _make_fixture()
	var wall_player := PLAYER_SCENE.instantiate() as PlayerController
	wall_fixture.add_child(wall_player)
	var wall_equipment := wall_player.get_node(
		"EquipmentController"
	) as EquipmentController
	wall_equipment.equip_slot(0)
	var wall_weapon := wall_equipment.get_current_weapon() as RangedWeapon
	_disable_spread(wall_weapon)
	var front_target := _spawn_target(
		wall_fixture,
		Vector3(0.0, 0.0, -4.0)
	)
	var rear_target := _spawn_target(
		wall_fixture,
		Vector3(0.0, 0.0, -8.0)
	)
	var wall := _make_wall(
		Vector3(0.0, 1.1, -6.0),
		Vector3(2.0, 2.0, 0.2)
	)
	wall_fixture.add_child(wall)
	wall.force_update_transform()
	var tracer_index := wall_weapon.tracer_pool_cursor

	wall_weapon._fire(Vector3.FORWARD)

	var tracer := wall_weapon.tracer_pool[tracer_index] as ShotTracer
	_append(failures, Assertions.expect_float_near(
		front_target.health.current,
		15.0,
		0.0001,
		"Zombie before wall receives pistol damage"
	))
	_append(failures, Assertions.expect_float_near(
		rear_target.health.current,
		50.0,
		0.0001,
		"Wall blocks penetration damage behind it"
	))
	_append(failures, Assertions.expect_float_near(
		_tracer_end(tracer).z,
		-5.9,
		0.05,
		"Wall terminates the penetrating tracer"
	))
	wall_fixture.free()

	var dedupe_fixture := _make_fixture()
	var dedupe_player := PLAYER_SCENE.instantiate() as PlayerController
	dedupe_fixture.add_child(dedupe_player)
	var dedupe_equipment := dedupe_player.get_node(
		"EquipmentController"
	) as EquipmentController
	dedupe_equipment.equip_slot(0)
	var dedupe_weapon := dedupe_equipment.get_current_weapon() as RangedWeapon
	_disable_spread(dedupe_weapon)
	var multi_hitbox_target := _spawn_target(
		dedupe_fixture,
		Vector3(0.0, 0.0, -4.0)
	)
	_add_extra_hitbox(multi_hitbox_target)
	var next_target := _spawn_target(
		dedupe_fixture,
		Vector3(0.0, 0.0, -8.0)
	)

	dedupe_weapon._fire(Vector3.FORWARD)

	_append(failures, Assertions.expect_float_near(
		multi_hitbox_target.health.current,
		15.0,
		0.0001,
		"Multiple hitboxes damage one zombie once"
	))
	_append(failures, Assertions.expect_float_near(
		next_target.health.current,
		32.5,
		0.0001,
		"Duplicate hitbox does not consume penetration count"
	))
	dedupe_fixture.free()

func _make_fixture() -> Node3D:
	var fixture := Node3D.new()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(fixture)
	return fixture

func _spawn_target(parent: Node3D, position: Vector3) -> ZombieTarget:
	var target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	target.position = position
	target.set_physics_process(false)
	target.set_process(false)
	parent.add_child(target)
	target.force_update_transform()
	return target

func _disable_spread(weapon: RangedWeapon) -> void:
	weapon.spread_state.base_spread_degrees = 0.0
	weapon.spread_state.max_spread_degrees = 0.0
	weapon.spread_state.spread_increase_per_shot_degrees = 0.0
	weapon.spread_state.current_spread_degrees = 0.0

func _add_extra_hitbox(target: ZombieTarget) -> void:
	var area := Area3D.new()
	area.position = Vector3(0.0, 1.1, 1.4)
	area.collision_layer = 4
	area.collision_mask = 0
	area.monitoring = false
	area.set_script(ZombieHitbox)
	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.3
	collision.shape = shape
	area.add_child(collision)
	target.get_node("Hitboxes").add_child(area)
	area.force_update_transform()

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

func _tracer_end(tracer: ShotTracer) -> Vector3:
	return tracer.to_global(Vector3(0.0, 0.0, -0.5))

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
./tests/run_tests.sh
```

Expected: 新测试已加载，手枪第二目标、步枪第二至第四目标、汇总伤害或 Hitbox 去重断言失败；不得因为测试脚本拼写或类型问题产生 Parse Error。已有 4 个刀相关失败仍可同时存在。

- [ ] **Step 3: 实现有限循环射线解析**

在 `ranged_weapon.gd` 顶部常量区加入：

```gdscript
const MAX_PENETRATION_QUERY_COUNT := 64
```

把 `_fire()` 中单次 `_intersect_shot()` 与单目标伤害分支替换为：

```gdscript
	var resolution := _resolve_shot(ray_origin, ray_end, ray_direction)
	var hit_position: Vector3 = resolution["end_position"]
	var hit_result: HitResult = resolution["hit_result"]
```

新增以下解析骨架；实现时保持 tab 缩进和显式类型：

```gdscript
func _resolve_shot(
	from: Vector3,
	to: Vector3,
	shot_direction: Vector3
) -> Dictionary:
	var ranged_definition := definition as RangedWeaponDefinition
	var excluded: Array[RID] = [wielder.get_rid()]
	var visited_targets: Dictionary = {}
	var maximum_zombie_hits := maxi(
		maxi(ranged_definition.max_penetration_count, 0) + 1,
		1
	)
	var coefficient := clampf(
		ranged_definition.penetration_damage_coefficient,
		0.0,
		1.0
	)
	var zombie_hit_count := 0
	var current_damage := maxf(ranged_definition.damage, 0.0)
	var end_position := to
	var summary := HitResult.miss(to)

	for _query_index in range(MAX_PENETRATION_QUERY_COUNT):
		var collision := _intersect_shot(from, to, excluded)
		var collider: Object = collision.get("collider", null)
		if collider == null:
			break
		end_position = collision.get("position", to)
		var collision_object := collider as CollisionObject3D
		if collision_object != null:
			excluded.append(collision_object.get_rid())

		var target := _find_damage_target(collider)
		if target == null:
			_merge_hit_result(
				summary,
				_apply_damage(collider, ranged_definition.damage, end_position, shot_direction)
			)
			break

		var target_id := target.get_instance_id()
		if visited_targets.has(target_id):
			if collision_object == null:
				break
			continue
		visited_targets[target_id] = true
		zombie_hit_count += 1
		_merge_hit_result(
			summary,
			_apply_damage(collider, current_damage, end_position, shot_direction)
		)
		if zombie_hit_count >= maximum_zombie_hits or coefficient <= 0.0:
			break
		current_damage *= coefficient

	if not summary.did_hit:
		summary.position = end_position
	return {
		"end_position": end_position,
		"hit_result": summary,
	}
```

新增三个职责单一的辅助函数：

```gdscript
func _find_damage_target(collider: Object) -> Node3D:
	var current := collider as Node
	while current != null:
		if current is Node3D and current.is_in_group(&"damageable_targets"):
			return current as Node3D
		current = current.get_parent()
	return null

func _apply_damage(
	collider: Object,
	amount: float,
	hit_position: Vector3,
	shot_direction: Vector3
) -> HitResult:
	if collider != null and collider.has_method("apply_hit"):
		var resolved: Variant = collider.call(
			"apply_hit",
			amount,
			hit_position,
			shot_direction
		)
		if resolved is HitResult:
			return resolved as HitResult
	elif collider != null and collider.has_method("apply_damage"):
		var resolved: Variant = collider.call(
			"apply_damage",
			amount,
			hit_position
		)
		if resolved is HitResult:
			return resolved as HitResult
	return HitResult.miss(hit_position)

func _merge_hit_result(summary: HitResult, resolved: HitResult) -> void:
	if resolved == null or not resolved.did_hit:
		return
	summary.did_hit = true
	summary.damage_applied += resolved.damage_applied
	summary.hit_zone = resolved.hit_zone
	summary.critical = summary.critical or resolved.critical
	summary.killed = summary.killed or resolved.killed
	summary.position = resolved.position
```

把 `_intersect_shot` 改为消费调用者维护的排除集合：

```gdscript
func _intersect_shot(
	from: Vector3,
	to: Vector3,
	excluded: Array[RID]
) -> Dictionary:
	var ranged_definition := definition as RangedWeaponDefinition
	var hit_mask := ranged_definition.hit_collision_mask | 1
	var query := PhysicsRayQueryParameters3D.create(
		from,
		to,
		hit_mask,
		excluded
	)
	query.collide_with_areas = true
	query.hit_from_inside = true
	return get_world_3d().direct_space_state.intersect_ray(query)
```

- [ ] **Step 4: 运行测试并确认 GREEN**

Run:

```bash
./tests/run_tests.sh
```

Expected: `test_weapon_penetration.gd` 不出现在失败列表中；手枪、步枪、墙体、Hitbox 去重和汇总断言全部通过。整体进程仍可能因计划开始前的 4 个刀相关基线失败返回 1，但不得出现新的穿透、射击反馈、墙体或 Parse Error。

- [ ] **Step 5: 进行最小重构并保持 GREEN**

检查 `_resolve_shot()`：

- 每个碰撞体在继续循环前已加入 `excluded`。
- 只有首次遇到的僵尸实体才增加 `zombie_hit_count`。
- 非僵尸碰撞体必定 `break`。
- `current_damage` 只在继续穿透前乘一次系数。
- `_fire()` 仍只调用一次 `_acquire_tracer()`、`muzzle_flash.flash()`、`shot_audio.play()` 和 `attack_resolved.emit()`。

Run:

```bash
git diff --check -- \
  scripts/combat/weapons/ranged_weapon.gd \
  tests/unit/test_weapon_penetration.gd \
  tests/test_runner.gd
```

Expected: 无输出。

### Task 3: Headless Smoke Test 与最终 Review

**Files:**
- Review: `scripts/combat/weapons/ranged_weapon.gd`
- Review: `scripts/combat/weapons/ranged_weapon_definition.gd`
- Review: `resources/weapons/pistol.tres`
- Review: `resources/weapons/rifle.tres`
- Review: `tests/unit/test_weapon_configuration.gd`
- Review: `tests/unit/test_weapon_penetration.gd`
- Review: `tests/test_runner.gd`

**Interfaces:**
- Consumes: Task 1 和 Task 2 的完整实现。
- Produces: 可由根代理交付的已评审工作树；若能隔离既有改动，则最终 squash 为一个 Conventional Commit。

- [ ] **Step 1: 运行 Godot Headless 解析检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: exit `0`，无 Parse Error 或资源加载错误，并生成/确认 `tests/unit/test_weapon_penetration.gd.uid`。

- [ ] **Step 2: 运行完整 Smoke Test**

Run:

```bash
./tests/run_tests.sh
```

Expected: 不出现 `test_weapon_penetration.gd`、`test_weapon_configuration.gd`、`test_weapon_feedback.gd` 或墙体净空测试的新失败。若仍失败，只允许保留计划开始前记录的 4 个刀相关基线失败。

- [ ] **Step 3: 进行需求符合性 Review**

逐项核对：

```text
手枪：35.0 → 17.5，第三只不受伤
步枪：25.0 → 18.75 → 14.0625 → 10.546875，第五只不受伤
墙体截断
同一僵尸多 Hitbox 去重
单条散布后方向
一次 attack_resolved / tracer / muzzle / audio
汇总 damage_applied 与任意 killed
```

Expected: 无遗漏、无超出设计范围的重构。

- [ ] **Step 4: 进行代码质量 Review**

重点检查：

- 循环有 `MAX_PENETRATION_QUERY_COUNT` 上限。
- RID 排除集合不会重复命中相同碰撞体。
- 目标去重使用实体 ID，不使用 Hitbox ID。
- 运行时 clamp 与 Inspector 范围一致。
- 没有修改 `addons/`、近战或僵尸基础参数。
- 没有覆盖工作区中已有的散布、移动端、刀或其他用户改动。

Expected: Review 无阻断项；普通风格建议仅在成本很低时修正。

- [ ] **Step 5: 最终提交安全检查**

Run:

```bash
git status --short
git diff --check
git diff -- \
  scripts/combat/weapons/ranged_weapon.gd \
  scripts/combat/weapons/ranged_weapon_definition.gd \
  resources/weapons/pistol.tres \
  resources/weapons/rifle.tres \
  tests/unit/test_weapon_configuration.gd \
  tests/unit/test_weapon_penetration.gd \
  tests/test_runner.gd
```

Expected: 根代理能明确区分本功能与进入任务前已有改动。只有在不会带入无关改动时，才将设计、计划和实现 squash 为一个提交：

```bash
git commit -m "feat: add hitscan zombie penetration"
```

若同文件中的既有改动无法安全隔离，则不执行提交，保留工作树并在交付说明中列明原因；禁止通过 reset、checkout 或覆盖文件来制造干净索引。
