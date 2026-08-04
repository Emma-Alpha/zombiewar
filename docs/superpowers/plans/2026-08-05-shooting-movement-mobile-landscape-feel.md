# 射击、移动与移动端横屏手感调整 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移除自动瞄准与部位伤害，以统一圆柱命中盒改善全方向射击容错，同时拉近相机、调缓地面移动、放大移动摇杆，并让移动端竖屏状态无法游玩。

**Architecture:** 枪械继续使用单条水平物理射线，但 Zombie 只暴露一个与实体移动碰撞分离的 `CylinderShape3D` 射击命中盒；相机、玩家移动和 `VirtualJoystick` 通过现有场景资源与导出属性调参。新增独立的移动触屏检测工具和可复用横屏守卫场景，主菜单与 Demo 共用守卫，H5 竖屏时用遮罩和暂停实现强制横屏。

**Tech Stack:** Godot 4.7.1、GDScript、Jolt Physics、GL Compatibility、原生 `VirtualJoystick`、Godot Web 导出、现有自定义 headless 测试运行器。

## Global Constraints

- 所有实施步骤在独立 git worktree 中执行；不得直接在 `main` 工作区修改生产代码。
- 本计划共 3 个 task，每个 task 完成测试、评审与修复后单独提交；用户明确要求覆盖仓库默认的整计划一次提交约定。
- 所有生产代码修改严格使用 RED → GREEN → REFACTOR；写测试前遵守 `test-driven-development/writing-good-tests.md`，测试真实行为而不是源码文本。
- 保持 Godot `4.7.1`、GL Compatibility、Jolt Physics、1280×720 基准视口和现有 Web 导出。
- 射击方向必须与输入方向一致；禁止辅助角、自动选目标、粗射线、磁性子弹或隐形弹道修正。
- Zombie 射击命中盒使用 `CylinderShape3D`，半径 `1.1`、高度 `2.2`、中心 Y `1.1`；实体移动仍使用现有 `MotionCollision`。
- Zombie 所有枪械与近战命中统一为 `&"body"`、`critical = false`、伤害倍率 `1.0`、击退倍率 `1.0`、垂直抬升 `0.05`。
- 相机正交尺寸固定从 `18.0` 调整为 `15.0`；位置、俯角、轴对齐、跟随与射击脉冲不得改变。
- 玩家地面参数固定为 `move_speed = 5.0`、`ground_acceleration = 30.0`、`ground_deceleration = 42.0`；空中、重力和跳跃参数不变。
- 移动摇杆固定为 `252×252`、`joystick_size = 204`、`tip_size = 88`、`deadzone_ratio = 0.12`，布局偏移 `left=40`、`top=-292`、`right=292`、`bottom=-40`；开火和跳跃按钮不移动、不缩放。
- 当前只有 Web 导出，因此“强制横屏”定义为触屏竖屏时显示遮罩、释放玩法输入并暂停，恢复横屏后自动恢复；不得新增 Android/iOS 导出预设。
- 横屏守卫不得把桌面鼠标触摸模拟误判为物理触屏，也不得撤销其他系统已经存在的暂停状态。
- 新增 `.gd` 文件必须保留 Godot 生成的对应 `.uid`；不得提交 `.godot/`、`build/` 或 SDD 工作区文件。
- 所有验证命令使用 `/Applications/Godot.app/Contents/MacOS/Godot`。

---

## 文件结构

### 新建文件

- `scripts/ui/mobile_touchscreen.gd`：集中执行物理触屏检测，并完整恢复 ProjectSettings 与运行时鼠标触摸模拟状态。
- `scripts/ui/mobile_orientation_guard.gd`：根据触屏状态和视口宽高管理竖屏遮罩、玩法输入释放与自身暂停状态。
- `scenes/ui/MobileOrientationGuard.tscn`：可复用的最高层级横屏提示遮罩。
- `tests/unit/test_mobile_orientation_guard.gd`：验证横竖屏决策、暂停所有权、输入释放与恢复行为。

### 修改文件

- `scenes/targets/ZombieTarget.tscn`：把五个部位命中盒替换为单个 `BodyHitbox/CylinderShape3D`。
- `scripts/combat/zombie_hitbox.gd`：去掉部位倍率配置，只转发统一命中参数。
- `scripts/combat/zombie_target.gd`：统一命中结果、伤害与击退，并让 `get_aim_point()` 指向整体命中盒。
- `scripts/combat/weapons/ranged_weapon.gd`：删除辅助目标选择，只保留直接射线。
- `scripts/combat/weapons/ranged_weapon_definition.gd`：删除辅助角和辅助距离字段。
- `resources/weapons/pistol.tres`、`resources/weapons/rifle.tres`：删除辅助角配置。
- `scripts/gameplay/demo_arena.gd`：HUD 只显示 `HIT` 或 `KILL`。
- `scripts/player/player_controller.gd`：写入新的地面移动默认值。
- `scenes/camera/FollowCamera.tscn`：写入 `size = 15.0`。
- `scenes/ui/MobileControls.tscn`：放大摇杆并写入目标布局与死区。
- `scripts/ui/mobile_controls.gd`：复用物理触屏检测工具，并公开 `cancel_all_input()` 给横屏守卫调用。
- `scenes/gameplay/DemoArena.tscn`：实例化横屏守卫，并把输入取消目标指向 `MobileControls`。
- `scenes/menu/MainMenu.tscn`：实例化相同横屏守卫。
- `tests/unit/test_zombie_hitboxes.gd`：验证单一圆柱命中盒和统一命中结果。
- `tests/unit/test_weapon_feedback.gd`：验证旧辅助角范围内、实际圆柱外的目标不会被自动命中。
- `tests/unit/test_blood_impact.gd`：改用统一 `apply_hit` 签名。
- `tests/unit/test_player_melee_weapon.gd`：把测试约定由 `TorsoHitbox` 改为 `BodyHitbox`。
- `tests/unit/test_player_motion.gd`：按新参数验证起步与停止速度。
- `tests/unit/test_mobile_touch_controls.gd`：验证放大摇杆和公开输入取消入口。
- `tests/integration/test_demo_scene.gd`：验证统一命中 HUD、相机、移动、摇杆与 Demo 横屏守卫契约。
- `tests/integration/test_main_menu_scene.gd`：验证主菜单也包含横屏守卫。
- `tests/test_runner.gd`：移除辅助角测试并注册横屏守卫测试。

### 删除文件

- `scripts/combat/aim_assist_math.gd`
- `scripts/combat/aim_assist_math.gd.uid`
- `tests/unit/test_aim_assist_math.gd`
- `tests/unit/test_aim_assist_math.gd.uid`

---

### Task 1: 统一 Zombie 命中盒并移除瞄准辅助

**Files:**
- Modify: `scenes/targets/ZombieTarget.tscn:1-128`
- Modify: `scripts/combat/zombie_hitbox.gd:1-28`
- Modify: `scripts/combat/zombie_target.gd:106-151`
- Modify: `scripts/combat/weapons/ranged_weapon.gd:1-152`
- Modify: `scripts/combat/weapons/ranged_weapon_definition.gd:1-9`
- Modify: `resources/weapons/pistol.tres:20-24`
- Modify: `resources/weapons/rifle.tres:20-24`
- Modify: `scripts/gameplay/demo_arena.gd:135-150`
- Modify: `tests/unit/test_zombie_hitboxes.gd:1-104`
- Modify: `tests/unit/test_weapon_feedback.gd:1-90`
- Modify: `tests/unit/test_blood_impact.gd:30-55`
- Modify: `tests/unit/test_player_melee_weapon.gd:354-402`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `tests/test_runner.gd:3-32`
- Delete: `scripts/combat/aim_assist_math.gd`
- Delete: `scripts/combat/aim_assist_math.gd.uid`
- Delete: `tests/unit/test_aim_assist_math.gd`
- Delete: `tests/unit/test_aim_assist_math.gd.uid`

**Interfaces:**
- Consumes: `WeaponMath.ray_end_from_direction(origin: Vector3, direction: Vector3, max_range: float) -> Vector3`、`HitResponseMath.knockback_velocity(...)`、`HitResult.resolved(...)`。
- Produces: `ZombieHitbox.apply_hit(amount: float, hit_position: Vector3, shot_direction: Vector3) -> HitResult`，固定转发 `&"body" / 1.0 / 1.0 / 0.05` 语义。
- Produces: `ZombieTarget.apply_hit(amount: float, hit_position: Vector3, shot_direction: Vector3) -> HitResult`，所有成功命中返回 `hit_zone == &"body"` 且 `critical == false`。
- Preserves: `ZombieTarget.get_aim_point() -> Vector3` 供近战命中位置使用，但改为返回 `Hitboxes/BodyHitbox.global_position`。

- [ ] **Step 1: 重写 Zombie 命中测试，先描述单一圆柱与统一伤害行为**

把 `tests/unit/test_zombie_hitboxes.gd` 的五部位约定改成以下核心断言；每个高度使用独立 Zombie，避免累计伤害影响结果：

```gdscript
	var target := ZOMBIE_SCENE.instantiate() as ZombieTarget
	var hitbox_root := target.get_node_or_null("Hitboxes")
	var body_hitbox := target.get_node_or_null("Hitboxes/BodyHitbox") as Area3D
	var collision_shape := target.get_node_or_null(
		"Hitboxes/BodyHitbox/CollisionShape3D"
	) as CollisionShape3D
	var cylinder := collision_shape.shape as CylinderShape3D if collision_shape != null else null

	_append(failures, Assertions.expect_equal(
		hitbox_root.get_child_count() if hitbox_root != null else 0,
		1,
		"Zombie exposes one forgiving shooting hitbox"
	))
	_append(failures, Assertions.expect_true(
		body_hitbox != null and body_hitbox.collision_layer == 4,
		"Body hitbox is visible to weapon rays"
	))
	_append(failures, Assertions.expect_true(
		cylinder != null,
		"Body hitbox uses a direction-independent cylinder"
	))
	if cylinder != null:
		_append(failures, Assertions.expect_float_near(
			cylinder.radius, 1.1, 0.0001, "Body hitbox radius"
		))
		_append(failures, Assertions.expect_float_near(
			cylinder.height, 2.2, 0.0001, "Body hitbox height"
		))

	for hit_height in [0.35, 1.1, 1.85]:
		var height_target := ZOMBIE_SCENE.instantiate() as ZombieTarget
		var height_hitbox := height_target.get_node("Hitboxes/BodyHitbox") as Area3D
		var result := height_hitbox.call(
			"apply_hit",
			10.0,
			Vector3(0.0, hit_height, 0.0),
			Vector3.RIGHT
		) as HitResult
		_append(failures, Assertions.expect_true(
			result.did_hit and not result.critical and result.hit_zone == &"body",
			"Every visible body height resolves as a normal body hit"
		))
		_append(failures, Assertions.expect_float_near(
			result.damage_applied, 10.0, 0.0001,
			"Every visible body height applies base damage"
		))
		height_target.free()
```

同时在 `tests/unit/test_blood_impact.gd` 把 `target.call("apply_hit", ...)` 改成只传三个参数；在 `tests/unit/test_player_melee_weapon.gd` 把保留命中盒名称从 `TorsoHitbox` 改为 `BodyHitbox`。

- [ ] **Step 2: 添加“旧辅助角内但圆柱外仍 miss”的失败测试**

在 `tests/unit/test_weapon_feedback.gd` 加入真实场景射击测试。目标位于旧步枪 `5° / 18m` 辅助范围内，但与直线射线横向相距 `1.4m`，超过新圆柱半径：

```gdscript
	var offset_target := preload("res://scenes/targets/ZombieTarget.tscn").instantiate() as ZombieTarget
	offset_target.position = Vector3(1.4, 0.0, -17.0)
	offset_target.set_physics_process(false)
	tree.root.add_child(offset_target)
	var functional_origin := player.get_node("FunctionalRayOrigin") as Marker3D
	functional_origin.global_position = Vector3(0.0, 1.1, 0.0)
	weapon.call("_fire", Vector3.FORWARD)
	_append(failures, Assertions.expect_float_near(
		offset_target.health.current,
		50.0,
		0.0001,
		"Direct fire does not bend toward a nearby off-axis target"
	))
	offset_target.free()
```

在 `tests/integration/test_demo_scene.gd` 用 `HitResult.resolved(10.0, &"body", true, false, Vector3.ZERO)` 主动调用 `_on_player_attack`，断言即使收到遗留 critical 标志，HUD 文字仍为 `HIT`；这样测试的是用户可见行为，而不是搜索源码中是否存在字符串。

- [ ] **Step 3: 运行完整测试确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1`；至少报告缺少 `BodyHitbox`、现有碰撞体不是 `CylinderShape3D`、不同高度仍产生部位结果、偏轴目标被辅助命中、HUD 显示 `CRITICAL`。

- [ ] **Step 4: 将场景改为单一圆柱命中盒**

在 `ZombieTarget.tscn` 删除五个部位 shape 与节点，加入：

```ini
[sub_resource type="CylinderShape3D" id="CylinderShape3D_body"]
radius = 1.1
height = 2.2

[node name="BodyHitbox" type="Area3D" parent="Hitboxes"]
position = Vector3(0, 1.1, 0)
collision_layer = 4
collision_mask = 0
monitoring = false
script = ExtResource("3_hitbox")

[node name="CollisionShape3D" type="CollisionShape3D" parent="Hitboxes/BodyHitbox"]
shape = SubResource("CylinderShape3D_body")
```

保留 `MotionCollision` 的半径 `0.5`、高度 `1.9` 和 World 碰撞层关系不变。

- [ ] **Step 5: 简化 Zombie 命中接口并统一结果**

把 `zombie_hitbox.gd` 改为只负责转发：

```gdscript
extends Area3D
class_name ZombieHitbox

const HitResult = preload("res://scripts/combat/hit_result.gd")

func apply_hit(
	amount: float,
	hit_position: Vector3,
	shot_direction: Vector3
) -> HitResult:
	var target: Node = get_parent().get_parent()
	if target == null or not target.has_method("apply_hit"):
		return HitResult.miss(hit_position)
	var result: Variant = target.call(
		"apply_hit",
		amount,
		hit_position,
		shot_direction
	)
	return result as HitResult if result is HitResult else HitResult.miss(hit_position)
```

把 `ZombieTarget.get_aim_point()` 和 `apply_hit()` 收敛为：

```gdscript
func get_aim_point() -> Vector3:
	var body := get_node_or_null("Hitboxes/BodyHitbox") as Area3D
	return body.global_position if body != null else global_position + Vector3.UP * 1.1

func apply_hit(
	amount: float,
	hit_position: Vector3,
	shot_direction: Vector3
) -> HitResult:
	_ensure_initialized()
	if depleted:
		return HitResult.miss(hit_position)
	attack_cycle.cancel_pending()
	attack_animation_remaining = 0.0
	var applied_damage := health.apply_damage(maxf(amount, 0.0))
	if applied_damage <= 0.0:
		return HitResult.miss(hit_position)

	var impulse := HitResponseMath.knockback_velocity(
		shot_direction,
		knockback_impulse,
		1.0,
		0.05
	)
	velocity += impulse
	_apply_visual_torque(hit_position, impulse)
	_spawn_blood_impact(hit_position, shot_direction, 1.0)
	visual_root.scale = Vector3.ONE * 1.08
	var killed := health.current <= 0.0
	ground_blood_requested.emit(
		global_position if killed else hit_position,
		shot_direction,
		1.25 if killed else 1.0,
		killed
	)
	if not killed:
		_play_hit_reaction()
	return HitResult.resolved(
		applied_damage,
		&"body",
		false,
		killed,
		hit_position
	)
```

`apply_damage(amount, hit_position)` 继续调用三参数 `apply_hit(amount, hit_position, Vector3.ZERO)`。

- [ ] **Step 6: 删除辅助选择路径与资源字段**

在 `ranged_weapon.gd` 删除 `AimAssistMath` preload、`_find_assisted_target()` 和 `_fire()` 内的辅助分支。`_fire()` 的命中解析只保留：

```gdscript
	var ray_end := WeaponMath.ray_end_from_direction(
		ray_origin,
		ray_direction,
		ranged_definition.attack_range
	)
	var result := _intersect_shot(ray_origin, ray_end)
	var collider: Object = result.get("collider", null)
	var hit_position: Vector3 = result.get("position", ray_end)
```

从 `RangedWeaponDefinition` 和 pistol/rifle `.tres` 删除 `aim_assist_angle_degrees` 与 `aim_assist_range`。删除 `aim_assist_math.gd`、其 `.uid`、对应测试与测试 `.uid`，并从 `TEST_PATHS` 移除测试注册。

- [ ] **Step 7: 让 HUD 永远只显示普通命中或击杀**

把 `_on_player_attack()` 的命中文字与颜色改为：

```gdscript
	label.text = "KILL" if result.killed else "HIT"
	label.modulate = Color.WHITE
```

保留淡出 Tween、镜头脉冲和 miss 早返回不变。

- [ ] **Step 8: 运行测试确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: `PASS`；无解析错误、无测试失败、无新增警告。

- [ ] **Step 9: 执行导入检查并提交 Task 1**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
git status --short
```

确认没有提交 `.godot/`，然后：

```bash
git add scenes/targets/ZombieTarget.tscn scripts/combat/zombie_hitbox.gd scripts/combat/zombie_target.gd scripts/combat/weapons/ranged_weapon.gd scripts/combat/weapons/ranged_weapon_definition.gd resources/weapons/pistol.tres resources/weapons/rifle.tres scripts/gameplay/demo_arena.gd tests/unit/test_zombie_hitboxes.gd tests/unit/test_weapon_feedback.gd tests/unit/test_blood_impact.gd tests/unit/test_player_melee_weapon.gd tests/integration/test_demo_scene.gd tests/test_runner.gd scripts/combat/aim_assist_math.gd scripts/combat/aim_assist_math.gd.uid tests/unit/test_aim_assist_math.gd tests/unit/test_aim_assist_math.gd.uid
git commit -m "feat: simplify zombie shooting hit detection"
```

---

### Task 2: 拉近相机、调缓地面移动并放大移动摇杆

**Files:**
- Modify: `scripts/player/player_controller.gd:28-43`
- Modify: `scenes/camera/FollowCamera.tscn:12-18`
- Modify: `scenes/ui/MobileControls.tscn:20-41`
- Modify: `tests/unit/test_player_motion.gd:114-143`
- Modify: `tests/unit/test_mobile_touch_controls.gd:138-205`
- Modify: `tests/integration/test_demo_scene.gd:20-190`

**Interfaces:**
- Consumes: `PlayerMotion.next_planar_velocity(current_velocity, move_direction, move_speed, acceleration, deceleration, delta) -> Vector3`。
- Produces: `PlayerController` 默认地面参数 `5.0 / 30.0 / 42.0`。
- Produces: `FollowCamera/Camera3D.size == 15.0`。
- Produces: `MobileControls/Layout/VirtualJoystick` 的目标尺寸、行程、摇杆头、死区与偏移。

- [ ] **Step 1: 先把相机、移动和摇杆契约改成目标值**

在 `tests/unit/test_player_motion.gd` 把地面速度测试改为：

```gdscript
	var accelerated: Vector3 = player_motion.next_planar_velocity(
		Vector3.ZERO,
		Vector3.FORWARD,
		5.0,
		30.0,
		42.0,
		0.1
	)
	_append(failures, Assertions.expect_float_near(
		accelerated.length(),
		3.0,
		0.0001,
		"Tuned ground acceleration reaches three meters per second after 100 ms"
	))
	var stopped: Vector3 = player_motion.next_planar_velocity(
		Vector3.FORWARD * 5.0,
		Vector3.ZERO,
		5.0,
		30.0,
		42.0,
		0.1
	)
	_append(failures, Assertions.expect_vector3_near(
		stopped,
		Vector3.FORWARD * 0.8,
		0.0001,
		"Tuned deceleration leaves a short controllable stopping tail"
	))
```

在 `tests/integration/test_demo_scene.gd` 把相机尺寸期望改为 `15.0`，并加入：

```gdscript
	_append(failures, Assertions.expect_float_near(
		float(player.get("move_speed")), 5.0, 0.0001, "Player tuned move speed"
	))
	_append(failures, Assertions.expect_float_near(
		float(player.get("ground_acceleration")), 30.0, 0.0001,
		"Player tuned ground acceleration"
	))
	_append(failures, Assertions.expect_float_near(
		float(player.get("ground_deceleration")), 42.0, 0.0001,
		"Player tuned ground deceleration"
	))
```

对 `virtual_joystick` 加入 `size == Vector2(252, 252)`、`joystick_size == 204`、`tip_size == 88`、`deadzone_ratio == 0.12` 断言，并验证其 `get_global_rect()` 不与开火、跳跃按钮矩形相交。

- [ ] **Step 2: 运行完整测试确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1`；报告相机仍为 `18.0`、玩家仍为 `6.0 / 42.0 / 60.0`、摇杆仍为旧尺寸和死区。

- [ ] **Step 3: 写入新的相机与移动默认值**

在 `player_controller.gd` 写入：

```gdscript
@export var move_speed: float = 5.0
@export var ground_acceleration: float = 30.0
@export var ground_deceleration: float = 42.0
```

在 `FollowCamera.tscn` 只把 `Camera3D.size` 改为：

```ini
size = 15.0
```

不得改动相机位置 `Vector3(0, 12, 14.142136)`、旋转 `Vector3(-40.3, 0, 0)` 或脚本参数。

- [ ] **Step 4: 放大移动摇杆并保持右侧按钮不变**

把 `MobileControls.tscn` 的摇杆节点改为：

```ini
custom_minimum_size = Vector2(252, 252)
offset_left = 40.0
offset_top = -292.0
offset_right = 292.0
offset_bottom = -40.0
joystick_size = 204.0
tip_size = 88.0
deadzone_ratio = 0.12
```

不要改动 `FireButton` 和 `JumpButton` 的尺寸与偏移。

- [ ] **Step 5: 运行测试确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: `PASS`；移动、相机、摇杆与现有触控测试全部通过。

- [ ] **Step 6: 执行导入检查并提交 Task 2**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Then:

```bash
git add scripts/player/player_controller.gd scenes/camera/FollowCamera.tscn scenes/ui/MobileControls.tscn tests/unit/test_player_motion.gd tests/unit/test_mobile_touch_controls.gd tests/integration/test_demo_scene.gd
git commit -m "feat: tune camera movement and mobile joystick"
```

---

### Task 3: 添加移动端横屏守卫并完成全量验证

**Files:**
- Create: `scripts/ui/mobile_touchscreen.gd`
- Create: `scripts/ui/mobile_touchscreen.gd.uid`
- Create: `scripts/ui/mobile_orientation_guard.gd`
- Create: `scripts/ui/mobile_orientation_guard.gd.uid`
- Create: `scenes/ui/MobileOrientationGuard.tscn`
- Create: `tests/unit/test_mobile_orientation_guard.gd`
- Create: `tests/unit/test_mobile_orientation_guard.gd.uid`
- Modify: `scripts/ui/mobile_controls.gd:1-60`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `scenes/menu/MainMenu.tscn`
- Modify: `tests/unit/test_mobile_touch_controls.gd`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `tests/integration/test_main_menu_scene.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Produces: `MobileTouchscreen.is_physical_touchscreen_available() -> bool`。
- Produces: `MobileOrientationGuard.should_block(touchscreen_available: bool, viewport_size: Vector2) -> bool`。
- Produces: `MobileControls.cancel_all_input() -> void`，释放四个移动动作、开火和跳跃。
- Consumes: Demo 中 `MobileOrientationGuard.input_cancel_target_path = NodePath("../MobileControls")`。
- Preserves: `MobileControls.should_show_controls(...)` 与现有桌面隐藏、物理触屏显示行为。

- [ ] **Step 1: 为横竖屏决策和暂停所有权写失败测试**

新增 `tests/unit/test_mobile_orientation_guard.gd`，核心行为如下：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const GUARD_SCENE := preload("res://scenes/ui/MobileOrientationGuard.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var guard_script := load("res://scripts/ui/mobile_orientation_guard.gd") as Script
	_append(failures, Assertions.expect_true(
		guard_script != null, "Mobile orientation guard script loads"
	))
	if guard_script == null:
		return failures

	_append(failures, Assertions.expect_true(
		not guard_script.should_block(false, Vector2(720, 1280)),
		"Desktop portrait viewport is not blocked"
	))
	_append(failures, Assertions.expect_true(
		not guard_script.should_block(true, Vector2(1280, 720)),
		"Touch landscape viewport remains playable"
	))
	_append(failures, Assertions.expect_true(
		guard_script.should_block(true, Vector2(720, 1280)),
		"Touch portrait viewport is blocked"
	))

	var tree := Engine.get_main_loop() as SceneTree
	var paused_before := tree.paused
	var viewport := SubViewport.new()
	viewport.size = Vector2i(720, 1280)
	tree.root.add_child(viewport)
	var guard := GUARD_SCENE.instantiate() as MobileOrientationGuard
	guard.force_touchscreen = true
	viewport.add_child(guard)
	_append(failures, Assertions.expect_true(
		guard.get_node("Overlay").visible and tree.paused and guard.paused_by_guard,
		"Portrait guard shows overlay and owns the pause it creates"
	))
	viewport.size = Vector2i(1280, 720)
	guard.refresh_orientation()
	_append(failures, Assertions.expect_true(
		not guard.get_node("Overlay").visible and not tree.paused and not guard.paused_by_guard,
		"Returning to landscape removes only the guard-owned pause"
	))
	viewport.free()
	tree.paused = paused_before
	return failures
```

再加入第二个场景实例：先设置 `tree.paused = true`，再进入触屏竖屏；断言 `paused_by_guard == false`，恢复横屏后 `tree.paused` 仍为 `true`。测试末尾必须恢复原暂停状态。

- [ ] **Step 2: 为输入释放和两个入口场景写失败测试**

在 `test_mobile_touch_controls.gd` 把失焦释放测试提取为对公开 `controls.cancel_all_input()` 的直接行为断言：按下移动、开火和跳跃后调用该方法，六个动作和两个按钮状态全部清空。

在 `test_demo_scene.gd` 断言：

```gdscript
	var orientation_guard := arena.get_node_or_null("MobileOrientationGuard") as MobileOrientationGuard
	_append(failures, Assertions.expect_true(
		orientation_guard != null and
		orientation_guard.input_cancel_target_path == NodePath("../MobileControls"),
		"Demo blocks portrait play and releases mobile controls"
	))
```

在 `test_main_menu_scene.gd` 断言主菜单根节点下存在 `MobileOrientationGuard`，且其输入取消路径为空。

- [ ] **Step 3: 注册新测试并运行确认 RED**

把 `res://tests/unit/test_mobile_orientation_guard.gd` 加入 `TEST_PATHS`，放在 `test_mobile_touch_controls.gd` 之后。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1`；报告缺少 guard 脚本/场景、公开输入取消入口以及两个场景实例。

- [ ] **Step 4: 提取共享的物理触屏检测**

新增 `scripts/ui/mobile_touchscreen.gd`：

```gdscript
extends RefCounted
class_name MobileTouchscreen

const EMULATE_TOUCH_SETTING := "input_devices/pointing/emulate_touch_from_mouse"

static func is_physical_touchscreen_available() -> bool:
	var project_emulation := bool(ProjectSettings.get_setting(
		EMULATE_TOUCH_SETTING,
		false
	))
	var runtime_emulation := Input.is_emulating_touch_from_mouse()
	ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, false)
	Input.set_emulate_touch_from_mouse(false)
	var available := DisplayServer.is_touchscreen_available()
	Input.set_emulate_touch_from_mouse(runtime_emulation)
	ProjectSettings.set_setting(EMULATE_TOUCH_SETTING, project_emulation)
	return available
```

`MobileControls._is_physical_touchscreen_available()` 改为返回 `MobileTouchscreen.is_physical_touchscreen_available()`，保留该方法作为现有测试与调用边界。把 `_cancel_all_input()` 重命名为公开 `cancel_all_input()`，并同步 `_notification()`、`set_touch_mode()` 调用点。

- [ ] **Step 5: 实现横屏守卫脚本**

新增 `scripts/ui/mobile_orientation_guard.gd`：

```gdscript
extends CanvasLayer
class_name MobileOrientationGuard

const MobileTouchscreen = preload("res://scripts/ui/mobile_touchscreen.gd")

@export var force_touchscreen := false
@export_node_path("Node") var input_cancel_target_path: NodePath

@onready var overlay: Control = $Overlay

var paused_by_guard := false

static func should_block(
	touchscreen_available: bool,
	viewport_size: Vector2
) -> bool:
	return touchscreen_available and viewport_size.y > viewport_size.x

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not get_viewport().size_changed.is_connected(refresh_orientation):
		get_viewport().size_changed.connect(refresh_orientation)
	refresh_orientation()

func _exit_tree() -> void:
	if paused_by_guard and get_tree() != null:
		get_tree().paused = false
	paused_by_guard = false

func refresh_orientation() -> void:
	var touchscreen_available := force_touchscreen or (
		MobileTouchscreen.is_physical_touchscreen_available()
	)
	var blocked := should_block(
		touchscreen_available,
		get_viewport().get_visible_rect().size
	)
	overlay.visible = blocked
	if blocked:
		_cancel_gameplay_input()
		if not get_tree().paused:
			get_tree().paused = true
			paused_by_guard = true
	elif paused_by_guard:
		get_tree().paused = false
		paused_by_guard = false

func _cancel_gameplay_input() -> void:
	if input_cancel_target_path.is_empty():
		return
	var target := get_node_or_null(input_cancel_target_path)
	if target != null and target.has_method("cancel_all_input"):
		target.call("cancel_all_input")
```

守卫不自行复制动作名；只有 Demo 通过 `input_cancel_target_path` 调用 `MobileControls`。主菜单依靠最高层遮罩和场景暂停阻止按钮操作。

- [ ] **Step 6: 创建遮罩场景并接入主菜单与 Demo**

新增 `MobileOrientationGuard.tscn`，根节点为 layer `100`、`process_mode = 3` 的 `MobileOrientationGuard`。`Overlay` 使用 full-rect `Control`、`mouse_filter = 0`，内部包含深色 `ColorRect` 与居中的中文 Label：

```text
请旋转设备
横屏游玩
```

Label 使用 `res://assets/fonts/NotoSansSC-UI.ttf`，默认 `Overlay.visible = false`。

在 `MainMenu.tscn` 把 `load_steps` 从 `13` 调整为 `14`，并加入明确资源 ID：

```ini
[ext_resource type="PackedScene" path="res://scenes/ui/MobileOrientationGuard.tscn" id="7_orientation_guard"]

[node name="MobileOrientationGuard" parent="." instance=ExtResource("7_orientation_guard")]
```

在 `DemoArena.tscn` 把 `load_steps` 从 `21` 调整为 `22`，并加入明确资源 ID 后实例化：

```ini
[ext_resource type="PackedScene" path="res://scenes/ui/MobileOrientationGuard.tscn" id="10_orientation_guard"]

[node name="MobileOrientationGuard" parent="." instance=ExtResource("10_orientation_guard")]
input_cancel_target_path = NodePath("../MobileControls")
```

- [ ] **Step 7: 运行测试确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: `PASS`；测试结束时 `SceneTree.paused` 恢复原值，桌面场景不显示横屏遮罩。

- [ ] **Step 8: 生成 UID、执行最终导入与 Web 导出验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
mkdir -p build/web
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release Web build/web/index.html
```

Expected: 编辑器导入 exit `0`；完整测试 `PASS`；Web 导出 exit `0`。确认新脚本与新测试的 `.uid` 已生成，`build/` 和 `.godot/` 不进入提交。

- [ ] **Step 9: 提交 Task 3**

```bash
git add scripts/ui/mobile_touchscreen.gd scripts/ui/mobile_touchscreen.gd.uid scripts/ui/mobile_orientation_guard.gd scripts/ui/mobile_orientation_guard.gd.uid scenes/ui/MobileOrientationGuard.tscn scripts/ui/mobile_controls.gd scenes/gameplay/DemoArena.tscn scenes/menu/MainMenu.tscn tests/unit/test_mobile_orientation_guard.gd tests/unit/test_mobile_orientation_guard.gd.uid tests/unit/test_mobile_touch_controls.gd tests/integration/test_demo_scene.gd tests/integration/test_main_menu_scene.gd tests/test_runner.gd
git commit -m "feat: enforce landscape play on mobile"
```

---

## 计划完成后的整体人工验收

在桌面键盘和移动端触屏各执行一次：

1. 用正向、侧向和四个斜向接近 Zombie 边缘射击，确认弹道不自动拐弯，圆柱范围内稳定命中，范围外明确 miss。
2. 命中 Zombie 上、中、下部位，确认伤害一致且 HUD 只显示 `HIT` 或 `KILL`。
3. 确认相机明显拉近，玩家与 Zombie 同时变大，镜头跟随和射击脉冲仍正常。
4. 确认玩家起步、变向、松开后的停止比当前版本柔和，斜向速度不快于直线。
5. 确认移动摇杆更大、轻推可控，并且不与跳跃、开火按钮重叠。
6. 移动端竖屏进入主菜单和 Demo 时均只显示旋转提示，无法操作；恢复横屏后自动继续且不会残留移动或持续开火。
