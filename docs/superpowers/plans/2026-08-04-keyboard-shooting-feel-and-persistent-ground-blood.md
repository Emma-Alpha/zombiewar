# 键盘锁向射击与持久地面血迹打击手感 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保留当前键盘-only直线射击、命中分区、Jolt碰撞击退和短时血花的基础上，完成可后退走射的锁向操作、适配未来同屏双人的输入边界、稳定的键盘辅助命中、完整的枪口/镜头/音频/击杀反馈，以及本局永久保留并在超限后复用最旧实例的地面血迹。

**Architecture:** `PlayerController` 成为唯一输入读取者，保存独立于移动方向的 `aim_direction`，并把扳机状态传给 `PlayerWeapon`；武器使用显式方向、轻量角度吸附和结构化 `HitResult` 完成命中，再通过信号驱动角色后坐、共享镜头脉冲和HUD命中确认。现有 `BloodImpact` 继续负责0.45秒的空中血花，新建场景级 `GroundBloodManager` 负责向下投射、永久保存和FIFO环形复用地面血迹，普通命中与死亡只发出血迹请求，不直接持有地面效果节点。

**Tech Stack:** Godot 4.7.1、GDScript、CharacterBody3D、Jolt Physics、GL Compatibility、原生Godot headless测试、现有Kenney CC0血迹贴图与临时金属枪声。

## Global Constraints

- 所有计划内容和新增文档使用中文；代码标识符、Godot节点名和测试断言保持英文。
- 以当前工作区代码为事实源：现有命中分区、`CharacterBody3D`击退、`BloodImpact`、弹道池和物理插值均视为已实现基线，不回退、不重复实现。
- 保持Godot `4.7.1.stable.official.a13da4feb`、GL Compatibility渲染器、Jolt Physics、1280×720窗口设置和当前主菜单入口。
- 保持键盘-only：当前单人仍使用WASD移动、Space跳跃、J射击，不重新引入鼠标瞄准。
- 输入读取只能发生在`PlayerController`；`PlayerWeapon`不得直接调用`Input.is_action_pressed()`，以便以后为玩家2注入另一组动作名。
- 功能射击方向立即响应；视觉模型可以平滑转动或后坐，但不得让视觉插值改变实际射线方向。
- 按下射击时先捕获当帧非零移动方向，持续按住射击后锁定该方向；锁向期间WASD只改变移动，不改变射击方向。
- 辅助瞄准只允许在可见路径内修正到目标胸口，不允许穿过世界碰撞层，不增加随机散布。
- 保留现有头、躯干、侧面、腿部命中盒和兼容`apply_damage()`的降级路径；本计划不增加新的武器、敌人AI或尸潮系统。
- 普通射击不使用全局hit stop；镜头脉冲必须限制累计幅度，避免未来双人同时射击时干扰另一名玩家。
- 地面血迹在当前一局内不按时间消失；达到固定上限后按生成顺序复用最旧实例，不执行持续增长、不频繁`queue_free()`。
- 地面血迹使用`Sprite3D`或等价平面节点，禁止为了Decal切换渲染器；当前GL Compatibility配置保持不变。
- 保留`docs/game_resources_zombie_prototype/`作为源资源档案，只复制本计划实际使用的枪声和授权文件到`res://assets/`。
- 当前工作区已有未提交修改；执行期间不得重置、覆盖或提交无关修改。四个任务全部完成、测试与人工验收通过后，只创建一次计划级提交。
- 所有Godot命令使用`/Applications/Godot.app/Contents/MacOS/Godot`，不依赖shell PATH中的`godot`。

---

## 文件结构

### 新建文件

- `scripts/combat/hit_result.gd`：描述一次射击的命中、伤害、区域、暴击、击杀和最终位置。
- `scripts/combat/aim_assist_math.gd`：纯函数筛选键盘方向锥体内的最佳目标。
- `scripts/fx/muzzle_flash.gd`：控制40～60毫秒的枪口火焰显隐。
- `scenes/fx/MuzzleFlash.tscn`：无外部纹理的加色枪口火焰平面。
- `scripts/fx/ground_blood_splat.gd`：一个不计时、不自毁、可被重复摆放的贴地血迹实例。
- `scripts/fx/ground_blood_manager.gd`：向下查找可沾血表面，懒创建血迹并在到达上限后FIFO复用。
- `scenes/fx/GroundBloodSplat.tscn`：复用现有`kenney_splat29.png`的水平`Sprite3D`血迹。
- `tests/unit/test_aim_assist_math.gd`：验证方向锥、距离限制和候选排序。
- `tests/unit/test_hit_result.gd`：验证普通命中、暴击、击杀和miss结果。
- `tests/unit/test_weapon_feedback.gd`：验证枪口火焰、枪声、射击信号、角色后坐和镜头脉冲接口。
- `tests/unit/test_ground_blood_manager.gd`：验证永久保留、固定上限、FIFO复用和表面法线对齐。
- `assets/sfx/weapons/impactMetal_heavy_002.ogg`：从现有CC0资源档案复制的原型期机械枪声。
- `assets/sfx/weapons/License.txt`：与临时枪声一起复制的授权说明。

### 修改文件

- `scripts/player/player_motion.gd`：增加锁向决策和独立起步/停止速度计算。
- `scripts/player/player_controller.gd`：成为唯一输入读取者，保存`aim_direction`，驱动武器输入和视觉后坐。
- `scripts/combat/weapon_math.gd`：从显式方向而不是玩家Basis计算射线终点。
- `scripts/combat/fire_gate.gd`：保留帧超时余量并支持80毫秒扳机缓冲。
- `scripts/combat/player_weapon.gd`：移除直接输入读取，增加目标辅助、结构化命中、枪口绑定、枪口火焰、音频和射击信号。
- `scripts/combat/zombie_hitbox.gd`：将目标返回的`HitResult`继续返回给武器。
- `scripts/combat/zombie_target.gd`：返回结构化命中结果，播放受击/死亡动画并发出地面血迹请求。
- `scripts/camera/follow_camera.gd`：增加有上限、快速衰减的射击镜头位移。
- `scripts/gameplay/demo_arena.gd`：连接玩家射击、镜头、HUD命中确认、僵尸血迹请求和地面血迹管理器。
- `scenes/player/Player.tscn`：增加瞄准方向指示器、枪口火焰和3D枪声节点。
- `scenes/camera/FollowCamera.tscn`：写入镜头脉冲默认参数。
- `scenes/targets/ZombieTarget.tscn`：加入`damageable_targets`组并保留胸口瞄准节点约定。
- `scenes/gameplay/DemoArena.tscn`：加入`GroundBloodManager`、可沾血地面组和HUD命中确认。
- `tests/unit/test_player_motion.gd`：验证锁向、射击首帧捕获和停止减速度。
- `tests/unit/test_directional_fire.gd`：验证显式方向射线、扳机缓冲和时间余量。
- `tests/unit/test_zombie_hitboxes.gd`：验证命中盒返回`HitResult`。
- `tests/integration/test_demo_scene.gd`：验证新节点、信号连接、输入边界和血迹管理器。
- `tests/test_runner.gd`：注册新增测试。
- `README.md`：记录锁向射击、辅助命中、枪口反馈和永久地面血迹行为。
- `docs/assets/shooting-impact-assets.md`：补充临时枪声音频来源和用途。

---

### Task 1: 锁向移动、双人可扩展输入边界与方向提示

**Files:**
- Modify: `scripts/player/player_motion.gd`
- Modify: `scripts/player/player_controller.gd`
- Modify: `scripts/combat/weapon_math.gd`
- Modify: `scripts/combat/player_weapon.gd`
- Modify: `scenes/player/Player.tscn`
- Modify: `tests/unit/test_player_motion.gd`
- Modify: `tests/unit/test_directional_fire.gd`
- Modify: `tests/integration/test_demo_scene.gd`

**Interfaces:**
- Consumes: 当前动作`move_left`、`move_right`、`move_forward`、`move_back`、`jump`、`fire`和`PlayerMotion.world_direction(...)`。
- Produces: `PlayerMotion.next_aim_direction(move_direction: Vector3, current_aim_direction: Vector3, trigger_pressed: bool, trigger_just_pressed: bool) -> Vector3`。
- Produces: `PlayerMotion.next_planar_velocity(current_velocity: Vector3, move_direction: Vector3, move_speed: float, acceleration: float, deceleration: float, delta: float) -> Vector3`。
- Produces: `WeaponMath.flat_direction(direction: Vector3) -> Vector3`和`WeaponMath.ray_end_from_direction(origin: Vector3, direction: Vector3, max_range: float) -> Vector3`。
- Produces: `PlayerWeapon.set_combat_input(trigger_pressed: bool, trigger_just_pressed: bool, aim_direction: Vector3) -> void`。
- Produces: `PlayerController.aim_direction: Vector3`，供功能朝向、射线和未来双人输入配置共同使用。

- [ ] **Step 1: 为锁向决策和独立停止速度写失败测试**

在`tests/unit/test_player_motion.gd`现有朝向断言之后加入：

```gdscript
	var previous_aim := Vector3.FORWARD
	var right_move := Vector3.RIGHT
	_append(failures, Assertions.expect_vector3_near(
		player_motion.next_aim_direction(right_move, previous_aim, false, false),
		Vector3.RIGHT,
		0.0001,
		"Movement updates aim while trigger is released"
	))
	_append(failures, Assertions.expect_vector3_near(
		player_motion.next_aim_direction(right_move, previous_aim, true, false),
		Vector3.FORWARD,
		0.0001,
		"Held trigger locks the previous aim direction"
	))
	_append(failures, Assertions.expect_vector3_near(
		player_motion.next_aim_direction(right_move, previous_aim, true, true),
		Vector3.RIGHT,
		0.0001,
		"Trigger press captures movement direction on the first frame"
	))
	_append(failures, Assertions.expect_vector3_near(
		player_motion.next_aim_direction(Vector3.ZERO, Vector3.RIGHT, false, false),
		Vector3.RIGHT,
		0.0001,
		"Zero movement retains the last aim direction"
	))

	var accelerated := player_motion.next_planar_velocity(
		Vector3.ZERO,
		Vector3.FORWARD,
		6.0,
		42.0,
		60.0,
		0.1
	)
	_append(failures, Assertions.expect_float_near(
		accelerated.length(),
		4.2,
		0.0001,
		"Ground acceleration reaches the expected speed after 100 ms"
	))
	var stopped := player_motion.next_planar_velocity(
		Vector3.FORWARD * 6.0,
		Vector3.ZERO,
		6.0,
		42.0,
		60.0,
		0.1
	)
	_append(failures, Assertions.expect_vector3_near(
		stopped,
		Vector3.ZERO,
		0.0001,
		"Dedicated deceleration stops the player within 100 ms"
	))
```

在`tests/unit/test_directional_fire.gd`把Basis方向断言改为显式方向断言：

```gdscript
	_append(failures, Assertions.expect_vector3_near(
		weapon_math.ray_end_from_direction(
			Vector3(1.0, 1.2, 1.0),
			Vector3.RIGHT * 3.0,
			28.0
		),
		Vector3(29.0, 1.2, 1.0),
		0.0001,
		"Directional ray normalizes aim and uses the visible-arena range"
	))
```

- [ ] **Step 2: 运行测试确认RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1`；报告缺少`next_aim_direction`、`next_planar_velocity`和`ray_end_from_direction`。

- [ ] **Step 3: 实现纯锁向与平面速度函数**

在`scripts/player/player_motion.gd`加入：

```gdscript
static func next_aim_direction(
	move_direction: Vector3,
	current_aim_direction: Vector3,
	trigger_pressed: bool,
	trigger_just_pressed: bool
) -> Vector3:
	var flat_move := Vector3(move_direction.x, 0.0, move_direction.z)
	var flat_current := Vector3(
		current_aim_direction.x,
		0.0,
		current_aim_direction.z
	)
	if flat_current.length_squared() <= 0.000001:
		flat_current = Vector3.FORWARD
	else:
		flat_current = flat_current.normalized()

	if trigger_pressed and not trigger_just_pressed:
		return flat_current
	if flat_move.length_squared() > 0.000001:
		return flat_move.normalized()
	return flat_current

static func next_planar_velocity(
	current_velocity: Vector3,
	move_direction: Vector3,
	move_speed: float,
	acceleration: float,
	deceleration: float,
	delta: float
) -> Vector3:
	var current_planar := Vector3(current_velocity.x, 0.0, current_velocity.z)
	var flat_direction := Vector3(move_direction.x, 0.0, move_direction.z)
	var target := Vector3.ZERO
	var rate := maxf(deceleration, 0.0)
	if flat_direction.length_squared() > 0.000001:
		target = flat_direction.normalized() * maxf(move_speed, 0.0)
		rate = maxf(acceleration, 0.0)
	return current_planar.move_toward(target, rate * maxf(delta, 0.0))
```

- [ ] **Step 4: 把输入所有权集中到PlayerController**

在`scripts/player/player_controller.gd`增加可配置动作名和锁向状态；保留现有`move_speed`、`air_acceleration`、`gravity`和`jump_speed`，把原来的`ground_acceleration = 30.0`替换为下面的`42.0`，并新增独立`ground_deceleration`，不得保留两个同名导出属性：

```gdscript
@export_group("Input Actions")
@export var move_left_action: StringName = &"move_left"
@export var move_right_action: StringName = &"move_right"
@export var move_forward_action: StringName = &"move_forward"
@export var move_back_action: StringName = &"move_back"
@export var jump_action: StringName = &"jump"
@export var fire_action: StringName = &"fire"

@export_group("Movement Feel")
@export var ground_acceleration: float = 42.0
@export var ground_deceleration: float = 60.0

@onready var weapon: PlayerWeapon = $Weapon

var aim_direction := Vector3.FORWARD
```

用以下逻辑替换`_physics_process()`里直接从移动方向设置旋转和分别`move_toward()`的部分：

```gdscript
var input_vector := Input.get_vector(
	move_left_action,
	move_right_action,
	move_forward_action,
	move_back_action
)
var camera_basis := movement_camera.global_basis if movement_camera != null else Basis.IDENTITY
var move_direction := PlayerMotion.world_direction(input_vector, camera_basis)
var trigger_pressed := Input.is_action_pressed(fire_action)
var trigger_just_pressed := Input.is_action_just_pressed(fire_action)

aim_direction = PlayerMotion.next_aim_direction(
	move_direction,
	aim_direction,
	trigger_pressed,
	trigger_just_pressed
)
rotation.y = PlayerMotion.next_facing_yaw(aim_direction, rotation.y)
weapon.set_combat_input(trigger_pressed, trigger_just_pressed, aim_direction)

var acceleration := ground_acceleration if is_on_floor() else air_acceleration
var deceleration := ground_deceleration if is_on_floor() else air_acceleration
var planar_velocity := PlayerMotion.next_planar_velocity(
	velocity,
	move_direction,
	move_speed,
	acceleration,
	deceleration,
	delta
)
velocity.x = planar_velocity.x
velocity.z = planar_velocity.z
```

把跳跃读取改为：

```gdscript
Input.is_action_just_pressed(jump_action)
```

- [ ] **Step 5: 让武器只消费控制器注入的输入**

在`scripts/combat/player_weapon.gd`加入缓存字段和入口：

```gdscript
var trigger_pressed := false
var trigger_just_pressed := false
var aim_direction := Vector3.FORWARD

func set_combat_input(
	value_trigger_pressed: bool,
	value_trigger_just_pressed: bool,
	value_aim_direction: Vector3
) -> void:
	trigger_pressed = value_trigger_pressed
	trigger_just_pressed = value_trigger_just_pressed
	aim_direction = WeaponMath.flat_direction(value_aim_direction)
```

把武器`_physics_process()`中的全局`Input`读取替换为：

```gdscript
fire_gate.tick(delta)
var player := get_parent() as PlayerController
if player == null:
	return
if trigger_pressed and fire_gate.try_consume():
	_fire(player, aim_direction)
trigger_just_pressed = false
```

将`_fire()`签名改为：

```gdscript
func _fire(player: PlayerController, shot_direction: Vector3) -> void:
```

并使用显式方向：

```gdscript
var ray_direction := WeaponMath.flat_direction(shot_direction)
var ray_end := WeaponMath.ray_end_from_direction(ray_origin, ray_direction, max_range)
```

在`scripts/combat/weapon_math.gd`实现：

```gdscript
static func flat_direction(direction: Vector3) -> Vector3:
	var flat := Vector3(direction.x, 0.0, direction.z)
	return flat.normalized() if flat.length_squared() > 0.000001 else Vector3.FORWARD

static func ray_end_from_direction(
	origin: Vector3,
	direction: Vector3,
	max_range: float
) -> Vector3:
	return origin + flat_direction(direction) * maxf(max_range, 0.0)
```

保留旧的Basis帮助函数作为兼容包装：

```gdscript
static func forward_direction(player_basis: Basis) -> Vector3:
	return flat_direction(-player_basis.z)

static func ray_end(origin: Vector3, player_basis: Basis, max_range: float) -> Vector3:
	return ray_end_from_direction(origin, -player_basis.z, max_range)
```

- [ ] **Step 6: 增加可读的地面方向指示器并缩短有效射程**

在`scenes/player/Player.tscn`增加发光细线，作为玩家根节点子节点，使其自动跟随功能朝向：

```gdscript
[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_aim_indicator"]
shading_mode = 0
albedo_color = Color(1, 0.72, 0.12, 0.78)
emission_enabled = true
emission = Color(1, 0.38, 0.04, 1)
emission_energy_multiplier = 1.6
transparency = 1

[sub_resource type="BoxMesh" id="BoxMesh_aim_indicator"]
material = SubResource("StandardMaterial3D_aim_indicator")
size = Vector3(0.055, 0.018, 2.4)

[node name="AimIndicator" type="MeshInstance3D" parent="."]
position = Vector3(0, 0.035, -1.65)
cast_shadow = 0
mesh = SubResource("BoxMesh_aim_indicator")
```

将`Weapon`的`max_range`从`80.0`改为`28.0`。方向线只表达朝向，不表达最终吸附目标。

- [ ] **Step 7: 扩展集成测试并运行GREEN**

在`tests/integration/test_demo_scene.gd`加入：

```gdscript
var weapon := arena.get_node_or_null("Player/Weapon") as PlayerWeapon
var aim_indicator := arena.get_node_or_null("Player/AimIndicator") as MeshInstance3D
_append(failures, Assertions.expect_true(
	weapon != null and weapon.has_method("set_combat_input"),
	"Weapon consumes injected combat input"
))
_append(failures, Assertions.expect_true(
	aim_indicator != null and aim_indicator.mesh != null,
	"Player has a visible keyboard aim indicator"
))
_append(failures, Assertions.expect_float_near(
	weapon.max_range,
	28.0,
	0.0001,
	"Weapon range matches the visible arena scale"
))
```

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `0`，全部既有测试和Task 1新增断言通过。

---

### Task 2: 键盘辅助命中、稳定射击节奏与结构化命中结果

**Files:**
- Create: `scripts/combat/hit_result.gd`
- Create: `scripts/combat/aim_assist_math.gd`
- Create: `tests/unit/test_hit_result.gd`
- Create: `tests/unit/test_aim_assist_math.gd`
- Modify: `scripts/combat/fire_gate.gd`
- Modify: `scripts/combat/player_weapon.gd`
- Modify: `scripts/combat/zombie_hitbox.gd`
- Modify: `scripts/combat/zombie_target.gd`
- Modify: `scenes/targets/ZombieTarget.tscn`
- Modify: `tests/unit/test_directional_fire.gd`
- Modify: `tests/unit/test_zombie_hitboxes.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: Task 1的`aim_direction`、`WeaponMath.flat_direction(...)`和`PlayerWeapon.set_combat_input(...)`。
- Produces: `HitResult.miss(end_position: Vector3) -> HitResult`。
- Produces: `HitResult.resolved(damage_applied: float, hit_zone: StringName, critical: bool, killed: bool, position: Vector3) -> HitResult`。
- Produces: `AimAssistMath.select_best_index(origin: Vector3, aim_direction: Vector3, candidate_points: Array[Vector3], max_distance: float, max_angle_radians: float) -> int`。
- Produces: `ZombieTarget.get_aim_point() -> Vector3`。
- Produces: `ZombieHitbox.apply_hit(...) -> HitResult`和`ZombieTarget.apply_hit(...) -> HitResult`。
- Produces: `FireGate.request_shot(buffer_seconds: float) -> void`和`FireGate.try_consume(trigger_held: bool = true) -> bool`。
- Produces: `PlayerWeapon.shot_fired(origin: Vector3, direction: Vector3, result: HitResult)`信号。

- [ ] **Step 1: 写HitResult、辅助瞄准和射速余量的失败测试**

创建`tests/unit/test_hit_result.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const HitResult = preload("res://scripts/combat/hit_result.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var miss := HitResult.miss(Vector3(0, 1.2, -28))
	_append(failures, Assertions.expect_true(not miss.did_hit, "Miss result is not a hit"))
	var critical := HitResult.resolved(37.5, &"head", true, true, Vector3.UP)
	_append(failures, Assertions.expect_true(critical.did_hit, "Resolved result is a hit"))
	_append(failures, Assertions.expect_true(critical.critical, "Head result is critical"))
	_append(failures, Assertions.expect_true(critical.killed, "Kill result preserves killed state"))
	_append(failures, Assertions.expect_float_near(
		critical.damage_applied,
		37.5,
		0.0001,
		"Hit result preserves applied damage"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

创建`tests/unit/test_aim_assist_math.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const AimAssistMath = preload("res://scripts/combat/aim_assist_math.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var origin := Vector3(0, 1.2, 0)
	var candidates: Array[Vector3] = [
		Vector3(0.6, 1.1, -12.0),
		Vector3(2.5, 1.1, -10.0),
		Vector3(0.1, 1.1, -22.0),
	]
	_append(failures, Assertions.expect_equal(
		AimAssistMath.select_best_index(
			origin,
			Vector3.FORWARD,
			candidates,
			18.0,
			deg_to_rad(5.0)
		),
		0,
		"Aim assist prefers the on-angle target inside range"
	))
	_append(failures, Assertions.expect_equal(
		AimAssistMath.select_best_index(
			origin,
			Vector3.RIGHT,
			candidates,
			18.0,
			deg_to_rad(5.0)
		),
		-1,
		"Aim assist rejects candidates outside the cone"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在`tests/unit/test_directional_fire.gd`的FireGate断言中加入：

```gdscript
	var carry_gate := fire_gate_script.new(1.0 / 6.0)
	_append(failures, Assertions.expect_true(
		carry_gate.try_consume(true),
		"Held trigger fires immediately"
	))
	carry_gate.tick(0.2)
	_append(failures, Assertions.expect_true(
		carry_gate.try_consume(true),
		"Overshoot frame still allows the next shot"
	))
	_append(failures, Assertions.expect_float_near(
		carry_gate.remaining,
		(1.0 / 6.0) - (0.2 - 1.0 / 6.0),
		0.0001,
		"Fire cadence carries frame overshoot into the next interval"
	))

	var buffered_gate := fire_gate_script.new(1.0 / 6.0)
	buffered_gate.try_consume(true)
	buffered_gate.request_shot(0.08)
	buffered_gate.tick(1.0 / 6.0)
	_append(failures, Assertions.expect_true(
		buffered_gate.try_consume(false),
		"Released tap fires when the buffered cooldown expires"
	))
```

将`test_hit_result.gd`和`test_aim_assist_math.gd`两个新增测试路径加入`tests/test_runner.gd`中的相应位置；`test_directional_fire.gd`沿用现有注册项。

- [ ] **Step 2: 运行测试确认RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1`；缺少`hit_result.gd`、`aim_assist_math.gd`、FireGate缓冲接口和命中返回类型。

- [ ] **Step 3: 实现HitResult值对象**

创建`scripts/combat/hit_result.gd`：

```gdscript
extends RefCounted
class_name HitResult

var did_hit := false
var damage_applied := 0.0
var hit_zone: StringName = &""
var critical := false
var killed := false
var position := Vector3.ZERO

static func miss(end_position: Vector3) -> HitResult:
	var result := HitResult.new()
	result.position = end_position
	return result

static func resolved(
	value_damage_applied: float,
	value_hit_zone: StringName,
	value_critical: bool,
	value_killed: bool,
	value_position: Vector3
) -> HitResult:
	var result := HitResult.new()
	result.did_hit = true
	result.damage_applied = maxf(value_damage_applied, 0.0)
	result.hit_zone = value_hit_zone
	result.critical = value_critical
	result.killed = value_killed
	result.position = value_position
	return result
```

- [ ] **Step 4: 实现纯辅助瞄准筛选**

创建`scripts/combat/aim_assist_math.gd`：

```gdscript
extends RefCounted
class_name AimAssistMath

static func select_best_index(
	origin: Vector3,
	aim_direction: Vector3,
	candidate_points: Array[Vector3],
	max_distance: float,
	max_angle_radians: float
) -> int:
	var flat_aim := Vector3(aim_direction.x, 0.0, aim_direction.z)
	if flat_aim.length_squared() <= 0.000001:
		return -1
	flat_aim = flat_aim.normalized()
	var resolved_distance := maxf(max_distance, 0.001)
	var resolved_angle := maxf(max_angle_radians, 0.0001)
	var best_index := -1
	var best_score := INF

	for index in range(candidate_points.size()):
		var offset := candidate_points[index] - origin
		var planar := Vector3(offset.x, 0.0, offset.z)
		var distance := planar.length()
		if distance <= 0.0001 or distance > resolved_distance:
			continue
		var direction := planar / distance
		var angle := acos(clampf(flat_aim.dot(direction), -1.0, 1.0))
		if angle > resolved_angle:
			continue
		var score := angle / resolved_angle * 0.8 + distance / resolved_distance * 0.2
		if score < best_score:
			best_score = score
			best_index = index
	return best_index
```

- [ ] **Step 5: 让FireGate保存帧超时余量并消费短按缓冲**

将`scripts/combat/fire_gate.gd`改为：

```gdscript
extends RefCounted
class_name FireGate

var interval: float
var remaining := 0.0
var buffered_trigger_remaining := 0.0

func _init(seconds_between_shots: float) -> void:
	interval = maxf(seconds_between_shots, 0.001)

func request_shot(buffer_seconds: float) -> void:
	buffered_trigger_remaining = maxf(
		buffered_trigger_remaining,
		maxf(buffer_seconds, 0.0)
	)

func tick(delta: float) -> void:
	var safe_delta := maxf(delta, 0.0)
	remaining -= safe_delta
	buffered_trigger_remaining = maxf(
		buffered_trigger_remaining - safe_delta,
		0.0
	)

func try_consume(trigger_held: bool = true) -> bool:
	if not trigger_held and buffered_trigger_remaining <= 0.0:
		return false
	if remaining > 0.0:
		return false
	remaining += interval
	buffered_trigger_remaining = 0.0
	return true
```

在`PlayerWeapon._physics_process()`中，在消费前加入：

```gdscript
if trigger_just_pressed:
	fire_gate.request_shot(0.08)
if fire_gate.try_consume(trigger_pressed):
	_fire(player, aim_direction)
trigger_just_pressed = false
```

- [ ] **Step 6: 让僵尸暴露胸口瞄准点并返回HitResult**

在`scenes/targets/ZombieTarget.tscn`根节点加入组：

```gdscript
[node name="ZombieTarget" type="CharacterBody3D" groups=["damageable_targets"]]
```

在`scripts/combat/zombie_target.gd`预加载`HitResult`并增加：

```gdscript
const HitResult = preload("res://scripts/combat/hit_result.gd")

func get_aim_point() -> Vector3:
	var torso := get_node_or_null("Hitboxes/TorsoHitbox") as Area3D
	return torso.global_position if torso != null else global_position + Vector3.UP * 1.1
```

将`apply_hit()`返回类型改为`HitResult`，并在伤害生效后返回：

```gdscript
if depleted:
	return HitResult.miss(hit_position)
var applied_damage := health.apply_damage(amount * maxf(damage_multiplier, 0.0))
if applied_damage <= 0.0:
	return HitResult.miss(hit_position)

# 保留现有击退、视觉扭矩、BloodImpact和缩放反馈。
var killed := health.current <= 0.0
return HitResult.resolved(
	applied_damage,
	_hit_zone,
	_hit_zone == &"head",
	killed,
	hit_position
)
```

将`apply_damage()`改为：

```gdscript
func apply_damage(amount: float, hit_position: Vector3) -> HitResult:
	return apply_hit(amount, hit_position, Vector3.ZERO)
```

在`scripts/combat/zombie_hitbox.gd`预加载`HitResult`并将转发改为有返回值：

```gdscript
const HitResult = preload("res://scripts/combat/hit_result.gd")

func apply_hit(
	amount: float,
	hit_position: Vector3,
	shot_direction: Vector3
) -> HitResult:
	var target := get_parent().get_parent()
	if target == null or not target.has_method("apply_hit"):
		return HitResult.miss(hit_position)
	var result := target.call(
		"apply_hit",
		amount,
		hit_position,
		shot_direction,
		hit_zone,
		damage_multiplier,
		knockback_multiplier,
		vertical_bias
	)
	return result as HitResult if result is HitResult else HitResult.miss(hit_position)
```

- [ ] **Step 7: 在武器中实现可遮挡的5度胸口辅助命中**

在`scripts/combat/player_weapon.gd`增加：

```gdscript
const AimAssistMath = preload("res://scripts/combat/aim_assist_math.gd")
const HitResult = preload("res://scripts/combat/hit_result.gd")

signal shot_fired(origin: Vector3, direction: Vector3, result: HitResult)

@export_range(0.0, 12.0, 0.25) var aim_assist_angle_degrees := 5.0
@export_range(0.0, 40.0, 0.5) var aim_assist_range := 18.0
```

增加候选目标收集：

```gdscript
func _find_assisted_target(origin: Vector3, direction: Vector3) -> Node3D:
	var targets: Array[Node3D] = []
	var points: Array[Vector3] = []
	for node in get_tree().get_nodes_in_group(&"damageable_targets"):
		if node is Node3D and node.has_method("get_aim_point"):
			targets.append(node as Node3D)
			var aim_point: Vector3 = node.call("get_aim_point")
			points.append(aim_point)
	var selected := AimAssistMath.select_best_index(
		origin,
		direction,
		points,
		aim_assist_range,
		deg_to_rad(aim_assist_angle_degrees)
	)
	return targets[selected] if selected >= 0 else null
```

把射线查询拆为：

```gdscript
func _intersect_shot(
	player: PlayerController,
	from: Vector3,
	to: Vector3
) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		from,
		to,
		hit_collision_mask,
		[player.get_rid()]
	)
	query.collide_with_areas = true
	return get_world_3d().direct_space_state.intersect_ray(query)
```

在`_fire()`中先执行直线射线；直线没有命中伤害目标时，再选择锥体目标并重新对其胸口执行射线。第二次射线仍使用`World + Target`掩码，因此集装箱或车辆会先挡住子弹：

```gdscript
var direct_end := WeaponMath.ray_end_from_direction(ray_origin, ray_direction, max_range)
var resolved_end := direct_end
var result := _intersect_shot(player, ray_origin, direct_end)
var collider: Object = result.get("collider", null)

if collider == null or (
	not collider.has_method("apply_hit") and
	not collider.has_method("apply_damage")
):
	var assisted_target := _find_assisted_target(ray_origin, ray_direction)
	if assisted_target != null:
		var assisted_end: Vector3 = assisted_target.call("get_aim_point")
		resolved_end = assisted_end
		result = _intersect_shot(player, ray_origin, resolved_end)
		collider = result.get("collider", null)

var hit_position: Vector3 = result.get("position", resolved_end)
var hit_result := HitResult.miss(hit_position)
if collider != null and collider.has_method("apply_hit"):
	var resolved := collider.call("apply_hit", damage, hit_position, ray_direction)
	if resolved is HitResult:
		hit_result = resolved as HitResult
elif collider != null and collider.has_method("apply_damage"):
	var resolved := collider.call("apply_damage", damage, hit_position)
	if resolved is HitResult:
		hit_result = resolved as HitResult

var tracer := _acquire_tracer()
tracer.setup(ray_origin, hit_position)
shot_fired.emit(ray_origin, ray_direction, hit_result)
```

辅助命中只改变最终胸口终点；射击方向指示器和角色功能朝向保持原始八方向，不向目标视觉旋转。

- [ ] **Step 8: 验证命中返回契约并运行GREEN**

在`tests/unit/test_zombie_hitboxes.gd`的头部与躯干调用中接收返回值：

```gdscript
var head_result := head_hitbox.call(
	"apply_hit",
	10.0,
	head_target.position + Vector3.UP * 1.7,
	Vector3.RIGHT
) as HitResult
var torso_result := torso_hitbox.call(
	"apply_hit",
	10.0,
	torso_target.position + Vector3.UP,
	Vector3.RIGHT
) as HitResult
_append(failures, Assertions.expect_true(
	head_result != null and head_result.critical,
	"Head hit returns a critical HitResult"
))
_append(failures, Assertions.expect_true(
	torso_result != null and not torso_result.critical,
	"Torso hit returns a non-critical HitResult"
))
```

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `0`；新增HitResult、AimAssist、FireGate和命中盒契约全部通过。

---

### Task 3: 枪口、音频、角色后坐、镜头脉冲与击杀确认

**Files:**
- Copy: `docs/game_resources_zombie_prototype/assets/sfx/impact/Audio/impactMetal_heavy_002.ogg` -> `assets/sfx/weapons/impactMetal_heavy_002.ogg`
- Copy: `docs/game_resources_zombie_prototype/assets/sfx/impact/License.txt` -> `assets/sfx/weapons/License.txt`
- Create: `scripts/fx/muzzle_flash.gd`
- Create: `scenes/fx/MuzzleFlash.tscn`
- Create: `tests/unit/test_weapon_feedback.gd`
- Modify: `scripts/combat/player_weapon.gd`
- Modify: `scripts/player/player_controller.gd`
- Modify: `scripts/camera/follow_camera.gd`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scripts/combat/zombie_target.gd`
- Modify: `scenes/player/Player.tscn`
- Modify: `scenes/camera/FollowCamera.tscn`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `tests/test_runner.gd`
- Modify: `docs/assets/shooting-impact-assets.md`

**Interfaces:**
- Consumes: Task 2的`PlayerWeapon.shot_fired(origin, direction, result)`和`HitResult`。
- Produces: `MuzzleFlash.flash() -> void`。
- Produces: `PlayerWeapon.bind_visual_anchor(anchor: Node3D) -> void`。
- Produces: `PlayerController.shot_fired(direction: Vector3, result: HitResult)`中继信号。
- Produces: `FollowCamera.add_shot_impulse(shot_direction: Vector3, strength: float = -1.0) -> void`；负值表示使用场景配置的`shot_impulse_strength = 0.06`。
- Produces: `DemoArena`对普通命中、暴击和击杀的HUD确认。

- [ ] **Step 1: 复制临时枪声音频和授权文件**

执行：

```bash
mkdir -p assets/sfx/weapons
cp docs/game_resources_zombie_prototype/assets/sfx/impact/Audio/impactMetal_heavy_002.ogg assets/sfx/weapons/impactMetal_heavy_002.ogg
cp docs/game_resources_zombie_prototype/assets/sfx/impact/License.txt assets/sfx/weapons/License.txt
```

首次由Godot打开项目时应生成对应`.import`文件。该音频仅作为原型期机械枪声，不改变源档案内容。

- [ ] **Step 2: 为枪口、音频、信号和镜头脉冲写失败测试**

创建`tests/unit/test_weapon_feedback.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const CAMERA_SCENE := preload("res://scenes/camera/FollowCamera.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var weapon := player.get_node("Weapon") as PlayerWeapon
	var muzzle_flash := weapon.get_node_or_null("Muzzle/MuzzleFlash")
	var shot_audio := weapon.get_node_or_null("ShotAudio") as AudioStreamPlayer3D
	_append(failures, Assertions.expect_true(
		muzzle_flash != null and muzzle_flash.has_method("flash"),
		"Weapon has a reusable muzzle flash"
	))
	_append(failures, Assertions.expect_true(
		shot_audio != null and shot_audio.stream != null,
		"Weapon has a loaded 3D shot sound"
	))
	_append(failures, Assertions.expect_true(
		weapon.has_method("bind_visual_anchor"),
		"Weapon can bind its muzzle to the animated rifle"
	))

	var follow_camera := CAMERA_SCENE.instantiate() as FollowCamera
	_append(failures, Assertions.expect_true(
		follow_camera.has_method("add_shot_impulse"),
		"Follow camera accepts bounded shot impulse"
	))
	follow_camera.add_shot_impulse(Vector3.FORWARD, 1.0)
	var impulse: Vector3 = follow_camera.get("shot_impulse_offset")
	_append(failures, Assertions.expect_true(
		impulse.length() <= 0.1201,
		"Shot impulse is capped for sustained and two-player fire"
	))

	player.free()
	follow_camera.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

将测试路径加入`tests/test_runner.gd`。

- [ ] **Step 3: 运行测试确认RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1`；缺少`MuzzleFlash`场景、`ShotAudio`和镜头脉冲接口。

- [ ] **Step 4: 创建短时枪口火焰**

创建`scripts/fx/muzzle_flash.gd`：

```gdscript
extends Node3D
class_name MuzzleFlash

@export_range(0.02, 0.12, 0.005) var lifetime := 0.05

var remaining := 0.0

func _ready() -> void:
	visible = false
	set_process(false)

func flash() -> void:
	remaining = lifetime
	rotation.z = randf_range(-PI, PI)
	scale = Vector3.ONE * randf_range(0.85, 1.15)
	visible = true
	set_process(true)

func _process(delta: float) -> void:
	remaining -= delta
	if remaining <= 0.0:
		visible = false
		set_process(false)
```

创建`scenes/fx/MuzzleFlash.tscn`，节点结构固定为：

```gdscript
MuzzleFlash (Node3D, script=muzzle_flash.gd)
└── Flash (MeshInstance3D, QuadMesh 0.42m × 0.42m)
```

`Flash`使用以下无纹理ShaderMaterial，保证中心亮黄、边缘橙红并始终面向镜头：

```glsl
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
	);
}

void fragment() {
	vec2 centered = UV * 2.0 - 1.0;
	float radial = 1.0 - smoothstep(0.15, 1.0, length(centered));
	float streak = 1.0 - smoothstep(0.05, 0.42, abs(centered.y));
	float alpha = clamp(radial + streak * 0.35, 0.0, 1.0);
	ALBEDO = mix(vec3(1.0, 0.18, 0.015), vec3(1.0, 0.9, 0.38), radial);
	EMISSION = ALBEDO * 3.0;
	ALPHA = alpha;
}
```

不添加`OmniLight3D`，避免每秒六次动态灯光带来的兼容渲染成本。

- [ ] **Step 5: 将功能枪口绑定到动画中的Rifle节点并触发枪口/音频**

在`scripts/combat/player_weapon.gd`增加：

```gdscript
@export var muzzle_anchor_offset := Vector3(0.0, 0.0, -0.55)

@onready var muzzle_flash: MuzzleFlash = $Muzzle/MuzzleFlash
@onready var shot_audio: AudioStreamPlayer3D = $ShotAudio

var visual_anchor: Node3D

func bind_visual_anchor(anchor: Node3D) -> void:
	visual_anchor = anchor
	top_level = visual_anchor != null
	muzzle.position = muzzle_anchor_offset
	if visual_anchor != null:
		global_transform = visual_anchor.global_transform

func _process(_delta: float) -> void:
	if visual_anchor != null and is_instance_valid(visual_anchor):
		global_transform = visual_anchor.global_transform
```

在每次真正执行`_fire()`后、发出`shot_fired`前执行：

```gdscript
muzzle_flash.flash()
shot_audio.pitch_scale = randf_range(0.97, 1.03)
shot_audio.play()
```

在`scenes/player/Player.tscn`：

```gdscript
[ext_resource type="PackedScene" path="res://scenes/fx/MuzzleFlash.tscn" id="4_muzzle_flash"]
[ext_resource type="AudioStream" path="res://assets/sfx/weapons/impactMetal_heavy_002.ogg" id="5_shot_audio"]

[node name="MuzzleFlash" parent="Weapon/Muzzle" instance=ExtResource("4_muzzle_flash")]

[node name="ShotAudio" type="AudioStreamPlayer3D" parent="Weapon"]
stream = ExtResource("5_shot_audio")
volume_db = -8.0
unit_size = 6.0
max_distance = 32.0
```

在`PlayerController._ready()`中查找动画模型内的`Rifle`并绑定：

```gdscript
var rifle_visual := visual_root.find_child("Rifle", true, false) as Node3D
if rifle_visual != null:
	weapon.bind_visual_anchor(rifle_visual)
```

`muzzle_anchor_offset`初值固定为`Vector3(0, 0, -0.55)`。人工验收时只允许调整这个导出值，使弹道起点与枪管末端的世界空间误差小于`0.12m`；射线方向仍使用Task 1的`aim_direction`。

- [ ] **Step 6: 增加角色视觉后坐与中继射击信号**

在`scripts/player/player_controller.gd`增加：

```gdscript
signal shot_fired(direction: Vector3, result: HitResult)

@export_group("Weapon Feel")
@export var visual_recoil_kick := 0.08
@export var visual_recoil_recovery := 1.2

var visual_rest_position := Vector3.ZERO
var visual_recoil_offset := 0.0
```

在`_ready()`记录位置并连接武器：

```gdscript
visual_rest_position = visual_root.position
if not weapon.shot_fired.is_connected(_on_weapon_shot_fired):
	weapon.shot_fired.connect(_on_weapon_shot_fired)
```

增加：

```gdscript
func _process(delta: float) -> void:
	visual_recoil_offset = move_toward(
		visual_recoil_offset,
		0.0,
		visual_recoil_recovery * delta
	)
	visual_root.position = visual_rest_position + Vector3(0.0, 0.0, visual_recoil_offset)

func _on_weapon_shot_fired(
	_origin: Vector3,
	direction: Vector3,
	result: HitResult
) -> void:
	visual_recoil_offset = minf(visual_recoil_offset + visual_recoil_kick, 0.12)
	shot_fired.emit(direction, result)
```

这段后坐只移动可视模型，不改变`CharacterBody3D`、功能朝向、射线原点绑定或碰撞体。

- [ ] **Step 7: 增加共享镜头的有限脉冲**

在`scripts/camera/follow_camera.gd`增加：

```gdscript
@export var shot_impulse_strength := 0.06
@export var shot_impulse_maximum := 0.12
@export var shot_impulse_recovery := 1.5

var shot_impulse_offset := Vector3.ZERO

func add_shot_impulse(
	shot_direction: Vector3,
	strength: float = -1.0
) -> void:
	var planar := Vector3(shot_direction.x, 0.0, shot_direction.z)
	if planar.length_squared() <= 0.000001:
		return
	var resolved_strength := shot_impulse_strength if strength < 0.0 else strength
	shot_impulse_offset -= planar.normalized() * maxf(resolved_strength, 0.0)
	if shot_impulse_offset.length() > shot_impulse_maximum:
		shot_impulse_offset = shot_impulse_offset.normalized() * shot_impulse_maximum
```

在`_physics_process()`计算desired前衰减：

```gdscript
shot_impulse_offset = shot_impulse_offset.move_toward(
	Vector3.ZERO,
	shot_impulse_recovery * delta
)
var desired := Vector3(
	target.global_position.x,
	global_position.y,
	target.global_position.z
) + shot_impulse_offset
```

在`scenes/camera/FollowCamera.tscn`明确写入`0.06 / 0.12 / 1.5`三个默认值。

- [ ] **Step 8: 增加命中HUD和死亡动画确认**

在`scenes/gameplay/DemoArena.tscn`的HUD中加入：

```gdscript
[node name="HitConfirm" type="Label" parent="HUD"]
anchors_preset = 10
anchor_right = 1.0
offset_top = 82.0
offset_bottom = 112.0
theme_override_font_sizes/font_size = 20
text = ""
horizontal_alignment = 1
modulate = Color(1, 1, 1, 0)
```

在`scripts/gameplay/demo_arena.gd`增加`var hit_confirm_tween: Tween`，连接`player.shot_fired`并处理；连续命中时先停止旧Tween，避免多个淡出动画互相覆盖：

```gdscript
func _on_player_shot(direction: Vector3, result: HitResult) -> void:
	var follow_camera := get_node("FollowCamera") as FollowCamera
	follow_camera.add_shot_impulse(direction)
	if not result.did_hit:
		return
	var label := get_node("HUD/HitConfirm") as Label
	label.text = "KILL" if result.killed else (
		"CRITICAL" if result.critical else "HIT"
	)
	label.modulate = Color(1.0, 0.3, 0.22, 1.0) if result.critical else Color.WHITE
	if hit_confirm_tween != null and hit_confirm_tween.is_valid():
		hit_confirm_tween.kill()
	hit_confirm_tween = create_tween()
	hit_confirm_tween.tween_property(label, "modulate:a", 0.0, 0.18)
```

在`scripts/combat/zombie_target.gd`连接`animation_finished`，普通非致死命中只在`0.2s`冷却允许时播放`HitReact`，致死时播放`Death`并保持模型可见：

```gdscript
var hit_animation_cooldown := 0.0

func _process(delta: float) -> void:
	hit_animation_cooldown = maxf(hit_animation_cooldown - delta, 0.0)
	visual_root.scale = visual_root.scale.move_toward(Vector3.ONE, delta * 1.5)

func _play_hit_reaction() -> void:
	if animation_player == null or hit_animation_cooldown > 0.0:
		return
	if animation_player.has_animation(&"HitReact"):
		animation_player.play(&"HitReact", 0.05)
		hit_animation_cooldown = 0.2

func _on_depleted() -> void:
	depleted = true
	# 保留现有碰撞体和命中盒禁用逻辑。
	health_label.visible = false
	var death_duration := 0.65
	if animation_player != null and animation_player.has_animation(&"Death"):
		animation_player.play(&"Death", 0.08)
		death_duration = minf(
			animation_player.get_animation(&"Death").length,
			1.2
		)
	await get_tree().create_timer(death_duration).timeout
	queue_free()
```

在`apply_hit()`中，当`killed == false`时调用`_play_hit_reaction()`；删除`visual_root.visible = false`。

- [ ] **Step 9: 更新资产说明并运行GREEN**

在`docs/assets/shooting-impact-assets.md`补充：

```markdown
## 原型枪声

- 文件：`assets/sfx/weapons/impactMetal_heavy_002.ogg`
- 来源：现有Kenney impact音效档案
- 授权：CC0，授权副本位于`assets/sfx/weapons/License.txt`
- 用途：作为原型阶段每发步枪的机械瞬态；正式音频可以替换该流，但不得改变`ShotAudio`节点和触发接口。
```

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `0`；所有反馈结构、节点、信号和既有命中测试通过。

---

### Task 4: 本局永久地面血迹、FIFO复用、集成验收与单次提交

**Files:**
- Create: `scripts/fx/ground_blood_splat.gd`
- Create: `scripts/fx/ground_blood_manager.gd`
- Create: `scenes/fx/GroundBloodSplat.tscn`
- Create: `tests/unit/test_ground_blood_manager.gd`
- Modify: `scripts/combat/zombie_target.gd`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `tests/test_runner.gd`
- Modify: `README.md`
- Verify: all files modified by Tasks 1-4

**Interfaces:**
- Consumes: 现有`assets/fx/blood/kenney_splat29.png`、Task 2的命中结果和Task 3保留的`BloodImpact`空中效果。
- Produces: `GroundBloodSplat.surface_basis(surface_normal: Vector3, random_rotation: float) -> Basis`。
- Produces: `GroundBloodSplat.setup(surface_position: Vector3, surface_normal: Vector3, diameter: float, random_rotation: float, tint: Color) -> void`。
- Produces: `GroundBloodManager.place_splat(surface_position: Vector3, surface_normal: Vector3, diameter: float, rotation_radians: float, tint: Color) -> GroundBloodSplat`。
- Produces: `GroundBloodManager.spawn_hit_splat(hit_position: Vector3, shot_direction: Vector3, intensity: float = 1.0) -> GroundBloodSplat`。
- Produces: `GroundBloodManager.spawn_death_pool(world_position: Vector3, intensity: float = 1.0) -> GroundBloodSplat`。
- Produces: `ZombieTarget.ground_blood_requested(origin: Vector3, direction: Vector3, intensity: float, death_pool: bool)`信号。

- [ ] **Step 1: 为永久保存和FIFO复用写失败测试**

创建`tests/unit/test_ground_blood_manager.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const MANAGER_SCRIPT := preload("res://scripts/fx/ground_blood_manager.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var manager := MANAGER_SCRIPT.new()
	manager.max_splats = 3

	var first := manager.place_splat(
		Vector3(0, 0, 0),
		Vector3.UP,
		0.4,
		0.0,
		Color(0.45, 0.01, 0.02, 0.92)
	)
	var second := manager.place_splat(
		Vector3(1, 0, 0),
		Vector3.UP,
		0.5,
		0.4,
		Color(0.48, 0.01, 0.02, 0.9)
	)
	var third := manager.place_splat(
		Vector3(2, 0, 0),
		Vector3.UP,
		0.6,
		0.8,
		Color(0.42, 0.01, 0.02, 0.94)
	)
	var reused := manager.place_splat(
		Vector3(9, 0, 0),
		Vector3.UP,
		1.1,
		1.2,
		Color(0.5, 0.01, 0.02, 0.95)
	)

	_append(failures, Assertions.expect_equal(
		manager.get_child_count(),
		3,
		"Ground blood never grows beyond the configured cap"
	))
	_append(failures, Assertions.expect_equal(
		reused.get_instance_id(),
		first.get_instance_id(),
		"The fourth splat reuses the oldest instance"
	))
	_append(failures, Assertions.expect_true(
		second.get_instance_id() != reused.get_instance_id() and
		third.get_instance_id() != reused.get_instance_id(),
		"Newer splats remain untouched during FIFO reuse"
	))
	_append(failures, Assertions.expect_true(
		not reused.is_processing(),
		"Persistent ground blood does not run a lifetime process"
	))
	_append(failures, Assertions.expect_vector3_near(
		reused.basis.z.normalized(),
		Vector3.UP,
		0.0001,
		"Ground blood plane aligns its normal to the hit surface"
	))

	manager.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

将测试路径加入`tests/test_runner.gd`。

- [ ] **Step 2: 运行测试确认RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1`；缺少地面血迹场景和管理器。

- [ ] **Step 3: 创建不计时、不自毁的GroundBloodSplat**

创建`scripts/fx/ground_blood_splat.gd`：

```gdscript
extends Sprite3D
class_name GroundBloodSplat

@export var base_diameter := 0.82
@export var surface_offset := 0.012

static func surface_basis(
	surface_normal: Vector3,
	random_rotation: float
) -> Basis:
	var normal := surface_normal.normalized()
	if normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	var reference := Vector3.RIGHT
	if absf(reference.dot(normal)) > 0.95:
		reference = Vector3.FORWARD
	var local_y := normal.cross(reference).normalized()
	var local_x := local_y.cross(normal).normalized()
	return Basis(local_x, local_y, normal).rotated(normal, random_rotation)

func _ready() -> void:
	set_process(false)

func setup(
	surface_position: Vector3,
	surface_normal: Vector3,
	diameter: float,
	random_rotation: float,
	tint: Color
) -> void:
	var normal := surface_normal.normalized()
	if normal.length_squared() <= 0.000001:
		normal = Vector3.UP
	var resolved_position := surface_position + normal * surface_offset
	if is_inside_tree():
		global_position = resolved_position
		global_basis = surface_basis(normal, random_rotation)
	else:
		position = resolved_position
		basis = surface_basis(normal, random_rotation)
	var resolved_scale := maxf(diameter, 0.05) / maxf(base_diameter, 0.05)
	scale = Vector3.ONE * resolved_scale
	modulate = tint
	visible = true
```

创建`scenes/fx/GroundBloodSplat.tscn`：

```gdscript
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/fx/ground_blood_splat.gd" id="1_script"]
[ext_resource type="Texture2D" path="res://assets/fx/blood/kenney_splat29.png" id="2_texture"]

[node name="GroundBloodSplat" type="Sprite3D"]
texture = ExtResource("2_texture")
pixel_size = 0.0032
billboard = 0
alpha_cut = 1
cast_shadow = 0
script = ExtResource("1_script")
```

该节点没有`lifetime`、`remaining`、`_process()`淡出或`queue_free()`路径。

- [ ] **Step 4: 实现懒创建和FIFO环形复用管理器**

创建`scripts/fx/ground_blood_manager.gd`：

```gdscript
extends Node3D
class_name GroundBloodManager

const SPLAT_SCENE := preload("res://scenes/fx/GroundBloodSplat.tscn")

@export_range(1, 512, 1) var max_splats := 192
@export_flags_3d_physics var surface_collision_mask := 1
@export_range(0.0, 1.0, 0.05) var hit_splat_probability := 0.55

var splats: Array[GroundBloodSplat] = []
var reuse_cursor := 0

func place_splat(
	surface_position: Vector3,
	surface_normal: Vector3,
	diameter: float,
	rotation_radians: float,
	tint: Color
) -> GroundBloodSplat:
	var splat := _acquire_splat()
	splat.setup(
		surface_position,
		surface_normal,
		diameter,
		rotation_radians,
		tint
	)
	return splat

func spawn_hit_splat(
	hit_position: Vector3,
	shot_direction: Vector3,
	intensity: float = 1.0
) -> GroundBloodSplat:
	if randf() > hit_splat_probability:
		return null
	var planar := Vector3(shot_direction.x, 0.0, shot_direction.z)
	if planar.length_squared() <= 0.000001:
		planar = Vector3.FORWARD
	else:
		planar = planar.normalized()
	var projected := hit_position + planar * randf_range(0.35, 0.9)
	var surface := _find_blood_surface(projected)
	if surface.is_empty():
		return null
	return place_splat(
		surface["position"],
		surface["normal"],
		randf_range(0.22, 0.45) * clampf(intensity, 0.75, 1.35),
		randf_range(-PI, PI),
		Color(0.42, 0.008, 0.015, randf_range(0.86, 0.96))
	)

func spawn_death_pool(
	world_position: Vector3,
	intensity: float = 1.0
) -> GroundBloodSplat:
	var surface := _find_blood_surface(world_position)
	if surface.is_empty():
		return null
	return place_splat(
		surface["position"],
		surface["normal"],
		randf_range(0.9, 1.4) * clampf(intensity, 0.8, 1.35),
		randf_range(-PI, PI),
		Color(0.36, 0.004, 0.01, 0.95)
	)

func _acquire_splat() -> GroundBloodSplat:
	if splats.size() < maxi(max_splats, 1):
		var created := SPLAT_SCENE.instantiate() as GroundBloodSplat
		add_child(created)
		splats.append(created)
		return created
	var reused := splats[reuse_cursor]
	reuse_cursor = (reuse_cursor + 1) % splats.size()
	return reused

func _find_blood_surface(world_position: Vector3) -> Dictionary:
	if not is_inside_tree():
		return {}
	var from := world_position + Vector3.UP * 2.0
	var to := world_position + Vector3.DOWN * 4.0
	var excluded: Array[RID] = []
	for _attempt in range(4):
		var query := PhysicsRayQueryParameters3D.create(
			from,
			to,
			surface_collision_mask,
			excluded
		)
		var result := get_world_3d().direct_space_state.intersect_ray(query)
		if result.is_empty():
			return {}
		var collider := result.get("collider") as CollisionObject3D
		if collider != null and collider.is_in_group(&"blood_surface"):
			return result
		if collider == null:
			return {}
		excluded.append(collider.get_rid())
	return {}
```

管理器只在未达到上限时实例化；达到`192`后，第`193`次开始按`0,1,2...`顺序复用。复用不会淡出旧血迹，也不会增加节点数。

- [ ] **Step 5: 用信号把僵尸命中和死亡接入管理器**

在`scripts/combat/zombie_target.gd`增加：

```gdscript
signal ground_blood_requested(
	origin: Vector3,
	direction: Vector3,
	intensity: float,
	death_pool: bool
)
```

在`apply_hit()`计算`killed`后，只发出一次地面请求：

```gdscript
ground_blood_requested.emit(
	global_position if killed else hit_position,
	shot_direction,
	1.25 if killed else knockback_multiplier,
	killed
)
```

空中`BloodImpact`仍对每个成功命中生成；致死命中不额外生成小地面血点，只生成死亡血泊。

在`scripts/gameplay/demo_arena.gd`增加目标接线：

```gdscript
func _wire_target_blood(target: Node) -> void:
	if not target is ZombieTarget:
		return
	var zombie := target as ZombieTarget
	if not zombie.ground_blood_requested.is_connected(_on_ground_blood_requested):
		zombie.ground_blood_requested.connect(_on_ground_blood_requested)

func _on_ground_blood_requested(
	origin: Vector3,
	direction: Vector3,
	intensity: float,
	death_pool: bool
) -> void:
	var manager := get_node("GroundBloodManager") as GroundBloodManager
	if death_pool:
		manager.spawn_death_pool(origin, intensity)
	else:
		manager.spawn_hit_splat(origin, direction, intensity)
```

在现有`_wire_dependencies()`中遍历`World/Targets`所有子节点调用`_wire_target_blood()`，并连接`World/Targets.child_entered_tree`，保证以后动态生成的僵尸也使用同一入口。

- [ ] **Step 6: 将管理器和可沾血地面加入场景**

在`scenes/gameplay/DemoArena.tscn`增加脚本资源和节点：

```gdscript
[ext_resource type="Script" path="res://scripts/fx/ground_blood_manager.gd" id="7_ground_blood"]

[node name="GroundBloodManager" type="Node3D" parent="."]
script = ExtResource("7_ground_blood")
max_splats = 192
surface_collision_mask = 1
hit_splat_probability = 0.55
```

将地面根碰撞体加入组：

```gdscript
[node name="Ground" type="StaticBody3D" parent="World" groups=["blood_surface"]]
```

皮卡、集装箱和边界不加入`blood_surface`。管理器向下射线先碰到这些物体时会将其RID排除并继续向下寻找地面，最多尝试四次。

- [ ] **Step 7: 扩展集成测试并运行完整自动验证**

在`tests/integration/test_demo_scene.gd`加入：

```gdscript
var ground := arena.get_node_or_null("World/Ground") as StaticBody3D
var ground_blood := arena.get_node_or_null("GroundBloodManager") as GroundBloodManager
var hit_confirm := arena.get_node_or_null("HUD/HitConfirm") as Label
_append(failures, Assertions.expect_true(
	ground != null and ground.is_in_group(&"blood_surface"),
	"Arena ground is the only persistent blood projection surface"
))
_append(failures, Assertions.expect_true(
	ground_blood != null and ground_blood.max_splats == 192,
	"Arena owns a capped persistent ground blood manager"
))
_append(failures, Assertions.expect_true(
	hit_confirm != null,
	"Arena has shot result confirmation UI"
))
for target in targets.get_children():
	_append(failures, Assertions.expect_true(
		target is ZombieTarget and
		(target as ZombieTarget).ground_blood_requested.is_connected(
			Callable(arena, "_on_ground_blood_requested")
		),
		"Every arena target forwards blood requests to the scene manager"
	))
```

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `0`并输出所有测试文件`PASS`。

再运行静态检查：

```bash
git diff --check
```

Expected: 无尾随空格、冲突标记或空白错误。

- [ ] **Step 8: 更新README并进行人工打击手感验收**

在`README.md`的Controls与Demo scope中明确写入：

```markdown
- 未射击时，WASD同时改变移动和朝向。
- 按下J会先捕获当前方向；持续按住J时锁定射击方向，WASD仍可自由移动。
- 步枪使用5度、18米内的轻微胸口辅助命中，但不会穿过车辆、集装箱或墙体。
- 命中产生短时空中血花；地面血迹在本局内永久保留，达到192个后复用最旧血迹。
```

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

依次验收：

1. 面向目标按住J后向反方向移动，角色保持原射击方向并能后退开火。
2. 松开J后按新方向移动，功能方向立即更新；再次按J捕获新方向。
3. 目标偏离方向线不超过约5度时可吸附到胸口；集装箱位于中间时子弹先命中集装箱。
4. 跳跃中朝前射击时，前方18米内目标仍可通过胸口辅助命中，不从头顶水平穿过。
5. 每发枪都有枪口火焰、枪声、轻微角色后坐和受限镜头脉冲，连续射击不产生持续漂移。
6. 普通、暴击和击杀分别显示`HIT`、`CRITICAL`、`KILL`；死亡僵尸播放`Death`后再删除。
7. 普通命中间歇生成小地面血点，致死命中生成较大血泊；僵尸删除后血迹仍在。
8. 将`GroundBloodManager.max_splats`临时设为`8`，生成第9个血迹时节点数保持8且最旧血迹被复用；验收后恢复`192`。
9. 弹道从可视步枪枪口出现；若存在偏差，只调整`muzzle_anchor_offset`，直到世界空间误差小于`0.12m`。

- [ ] **Step 9: 整个计划完成后创建唯一提交**

先检查：

```bash
git status --short
git diff --stat
```

只暂存本计划相关文件和相关hunk；不得把菜单、导出配置或其他用户修改混入提交。新增文件先显式加入：

```bash
git add \
  docs/superpowers/plans/2026-08-04-keyboard-shooting-feel-and-persistent-ground-blood.md \
  scripts/combat/hit_result.gd \
  scripts/combat/aim_assist_math.gd \
  scripts/fx/muzzle_flash.gd \
  scripts/fx/ground_blood_splat.gd \
  scripts/fx/ground_blood_manager.gd \
  scenes/fx/MuzzleFlash.tscn \
  scenes/fx/GroundBloodSplat.tscn \
  tests/unit/test_hit_result.gd \
  tests/unit/test_aim_assist_math.gd \
  tests/unit/test_weapon_feedback.gd \
  tests/unit/test_ground_blood_manager.gd \
  assets/sfx/weapons/impactMetal_heavy_002.ogg \
  assets/sfx/weapons/License.txt
```

对执行前已经包含未提交内容的修改文件使用交互式hunk暂存，只选择本计划实现：

```bash
git add -p \
  README.md \
  docs/assets/shooting-impact-assets.md \
  scripts/player/player_motion.gd \
  scripts/player/player_controller.gd \
  scripts/combat/weapon_math.gd \
  scripts/combat/fire_gate.gd \
  scripts/combat/player_weapon.gd \
  scripts/combat/zombie_hitbox.gd \
  scripts/combat/zombie_target.gd \
  scripts/camera/follow_camera.gd \
  scripts/gameplay/demo_arena.gd \
  scenes/player/Player.tscn \
  scenes/camera/FollowCamera.tscn \
  scenes/targets/ZombieTarget.tscn \
  scenes/gameplay/DemoArena.tscn \
  tests/unit/test_player_motion.gd \
  tests/unit/test_directional_fire.gd \
  tests/unit/test_zombie_hitboxes.gd \
  tests/integration/test_demo_scene.gd \
  tests/test_runner.gd
```

检查暂存内容：

```bash
git diff --cached --check
git diff --cached --stat
```

确认只包含本计划内容后提交一次：

```bash
git commit -m "feat: improve keyboard shooting feel and persistent blood"
```

---

## Self-Review

- **需求覆盖：** Task 1覆盖锁向走射、双人可扩展输入、方向提示和移动启停；Task 2覆盖辅助命中、跳跃射击高度修正、射速余量、短按缓冲和结构化命中；Task 3覆盖枪口绑定、火焰、音频、视觉后坐、共享镜头脉冲、HUD反馈和死亡动画；Task 4覆盖永久地面血迹、向下投射、固定上限、FIFO复用、自动/人工验收和单次提交。
- **范围控制：** 没有新增敌人AI、波次、武器、联网、刚体布偶、地面液体模拟、墙面血迹或渲染器切换；四个任务均可独立得到测试结果。
- **占位符扫描：** 未发现占位标记、模糊实现指令或未定义接口；所有新增函数、信号、节点、默认值、测试命令和验收阈值均已明确。
- **类型一致性：** `HitResult`在武器、命中盒、僵尸、玩家中继、镜头/HUD链路使用同一类型；`aim_direction`始终为扁平归一化`Vector3`；地面血迹入口统一使用`GroundBloodManager`并返回`GroundBloodSplat`或`null`。
- **提交策略：** 遵循项目约定，不在单独Task后提交；四个Task全部完成后仅创建一次计划级提交，并通过hunk暂存保护当前脏工作区中的无关修改。
