# 移动与射击方向始终一致 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将当前“按住J后锁定射击方向”的操作改回“WASD输入方向始终同时决定移动、角色朝向和射击方向”，并在松开WASD时保留最后一个非零方向供原地射击。

**Architecture:** 保留`PlayerController`作为唯一输入读取者，也保留`PlayerWeapon.set_combat_input(...)`的注入边界和80毫秒短按缓冲；只把`PlayerMotion.next_aim_direction(...)`简化为与扳机状态无关的移动方向决策。每个物理帧先从WASD得到相机相对的`move_direction`，立即更新`aim_direction`和玩家根节点朝向，再把同一个方向注入武器，因此角色视觉方向、方向指示器和功能射线共享同一事实源。

**Tech Stack:** Godot 4.7.1、GDScript、CharacterBody3D、Jolt Physics、GL Compatibility、原生Godot headless测试。

## Global Constraints

- 所有新增计划与说明使用中文；代码标识符、Godot节点名和测试断言保持英文。
- 以当前主分支工作区代码为事实源；当前工作区已有大量用户未提交修改，执行时不得重置、覆盖、暂存或提交无关内容。
- 本计划覆盖`docs/superpowers/plans/2026-08-04-keyboard-shooting-feel-and-persistent-ground-blood.md`中的“按住J锁向”控制语义；该计划已经实现的辅助命中、结构化命中、击退、血花、枪口反馈、镜头反馈和永久地面血迹不回退。
- 保持Godot `4.7.1.stable.official.a13da4feb`、GL Compatibility、Jolt Physics、1280×720窗口设置、正交2.5D镜头和当前主菜单入口。
- 保持键盘-only：WASD移动、Space跳跃、J射击；不重新引入鼠标瞄准或鼠标射击。
- “移动方向”指当前WASD经过相机基向量转换后的`move_direction`，不指受加减速影响的瞬时`CharacterBody3D.velocity`；改变WASD后，射击方向必须在同一物理帧立即改变。
- WASD非零时，`move_direction`、`aim_direction`、玩家根节点朝向和功能射线方向必须一致；按住J不得阻止方向更新。
- WASD为零时保留最后一个非零`aim_direction`，允许原地沿最后朝向继续射击；无历史方向时降级为`Vector3.FORWARD`。
- `PlayerController`仍是唯一读取`Input`的节点；`PlayerWeapon`不得直接读取全局输入，以保留未来同屏双人的输入注入边界。
- 保留`trigger_pressed`和`trigger_just_pressed`传入`PlayerWeapon.set_combat_input(...)`；它们继续负责持续射击和80毫秒短按缓冲，但不得参与方向锁定。
- 保留5度、18米胸口辅助命中和世界遮挡检测；辅助命中只修正最终射线，不改变角色朝向和WASD方向。
- 保留稳定的`FunctionalRayOrigin`、视觉枪口跟随、角色视觉后坐、受限镜头脉冲、HUD命中确认、死亡动画、地面血迹192上限与FIFO复用。
- 所有Godot命令使用`/Applications/Godot.app/Contents/MacOS/Godot`。
- 按最新项目约定，执行代理不得创建提交；整个计划完成后由用户自行暂存和提交。

---

## 文件结构

### 修改文件

- `scripts/player/player_motion.gd`：删除扳机状态对瞄准方向的影响，只根据当前移动方向或最后方向返回结果。
- `scripts/player/player_controller.gd`：每帧使用简化后的方向函数；扳机状态只继续注入武器。
- `tests/unit/test_player_motion.gd`：把锁向断言改成“按住射击时改变移动方向仍立即改变射击方向”，并覆盖零输入保留方向。
- `README.md`：删除锁向说明，明确WASD在射击期间仍同时控制移动与射击朝向。

### 不修改文件

- `scripts/combat/player_weapon.gd`：保留输入注入、短按缓冲、辅助瞄准、功能射线和反馈链路。
- `scripts/combat/fire_gate.gd`：保留用户已确认的“冷却期间保留短按缓冲”语义。
- `scenes/player/Player.tscn`：保留`AimIndicator`和`FunctionalRayOrigin`；它们随玩家根朝向自然表达当前移动/射击方向。
- `scripts/fx/ground_blood_manager.gd`及其场景：与本次操作变更无关，保持永久血迹和FIFO复用。

---

### Task 1: 恢复移动方向与射击方向实时一致

**Files:**
- Modify: `tests/unit/test_player_motion.gd`
- Modify: `scripts/player/player_motion.gd`
- Modify: `scripts/player/player_controller.gd`
- Modify: `README.md`
- Verify: `scripts/combat/player_weapon.gd`
- Verify: `scripts/combat/fire_gate.gd`
- Verify: `tests/unit/test_directional_fire.gd`

**Interfaces:**
- Consumes: `PlayerMotion.world_direction(input_vector: Vector2, camera_basis: Basis) -> Vector3`。
- Produces: `PlayerMotion.next_aim_direction(move_direction: Vector3, current_aim_direction: Vector3) -> Vector3`。
- Preserves: `PlayerWeapon.set_combat_input(trigger_pressed: bool, trigger_just_pressed: bool, aim_direction: Vector3) -> void`。
- Preserves: `PlayerController.aim_direction: Vector3`，作为玩家根朝向、方向指示器和功能射线的共同方向。

- [ ] **Step 1: 先把锁向测试改成移动/射击同向测试**

在`tests/unit/test_player_motion.gd`中，用下面的断言替换现有四个`next_aim_direction(...)`断言：

```gdscript
	var previous_aim := Vector3.FORWARD
	var right_move := Vector3.RIGHT
	var right_aim: Vector3 = player_motion.next_aim_direction(
		right_move,
		previous_aim
	)
	_append(failures, Assertions.expect_vector3_near(
		right_aim,
		Vector3.RIGHT,
		0.0001,
		"Movement direction immediately becomes the shooting direction"
	))

	var reversed_aim: Vector3 = player_motion.next_aim_direction(
		Vector3.BACK,
		right_aim
	)
	_append(failures, Assertions.expect_vector3_near(
		reversed_aim,
		Vector3.BACK,
		0.0001,
		"Changing movement direction immediately redirects shooting"
	))

	_append(failures, Assertions.expect_vector3_near(
		player_motion.next_aim_direction(Vector3.ZERO, reversed_aim),
		Vector3.BACK,
		0.0001,
		"Zero movement retains the last movement-aligned shooting direction"
	))

	_append(failures, Assertions.expect_vector3_near(
		player_motion.next_aim_direction(Vector3.ZERO, Vector3.ZERO),
		Vector3.FORWARD,
		0.0001,
		"Missing movement history falls back to Godot forward"
	))
```

这些测试刻意不接收`trigger_pressed`或`trigger_just_pressed`，使扳机状态无法重新进入方向决策接口。

- [ ] **Step 2: 运行完整测试确认RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1`；`test_player_motion.gd`调用`next_aim_direction(...)`时报告参数数量不匹配，因为当前实现仍要求四个参数。既有其余测试不应出现新的资源缺失或解析错误。

- [ ] **Step 3: 将方向决策简化为只消费移动方向和最后方向**

在`scripts/player/player_motion.gd`中，用下面的实现完整替换当前`next_aim_direction(...)`：

```gdscript
static func next_aim_direction(
	move_direction: Vector3,
	current_aim_direction: Vector3
) -> Vector3:
	var flat_move := Vector3(move_direction.x, 0.0, move_direction.z)
	if flat_move.length_squared() > 0.000001:
		return flat_move.normalized()

	var flat_current := Vector3(
		current_aim_direction.x,
		0.0,
		current_aim_direction.z
	)
	if flat_current.length_squared() <= 0.000001:
		return Vector3.FORWARD
	return flat_current.normalized()
```

实现中不得保留`trigger_pressed`、`trigger_just_pressed`参数，也不得添加射击期间跳过更新的分支。

- [ ] **Step 4: 让PlayerController每帧直接采用移动对齐方向**

在`scripts/player/player_controller.gd`的`_physics_process()`中，保留当前输入读取：

```gdscript
var trigger_pressed := Input.is_action_pressed(fire_action)
var trigger_just_pressed := Input.is_action_just_pressed(fire_action)
```

只把当前四参数方向调用：

```gdscript
aim_direction = PlayerMotion.next_aim_direction(
	move_direction,
	aim_direction,
	trigger_pressed,
	trigger_just_pressed
)
```

替换为：

```gdscript
aim_direction = PlayerMotion.next_aim_direction(
	move_direction,
	aim_direction
)
```

后续两行保持原样：

```gdscript
rotation.y = PlayerMotion.next_facing_yaw(aim_direction, rotation.y)
weapon.set_combat_input(trigger_pressed, trigger_just_pressed, aim_direction)
```

这样`trigger_pressed`和`trigger_just_pressed`仍驱动武器射速与短按缓冲，但不再控制方向。不要把`Input`读取移动到`PlayerWeapon`。

- [ ] **Step 5: 更新README操作说明**

在`README.md`的`## Controls`中保留现有英文基础操作，并在`Hold J`后补充一行：

```markdown
- Change `W/A/S/D` while firing: immediately redirect movement, facing, and the next shot together
```

用以下内容替换现有两条中文锁向说明：

```markdown
- WASD始终同时改变移动、角色朝向和射击方向；按住J时改变WASD会立即朝新方向开火。
- 松开WASD后保留最后一个非零方向，原地按住J会沿该方向继续射击。
```

以下内容保持不变：5度/18米辅助命中、世界遮挡、短时空中血花、永久地面血迹和192上限FIFO复用。

- [ ] **Step 6: 运行GREEN与静态检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit-after 3
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
git diff --check
```

Expected:

```text
Godot编辑器导入/解析正常并以0退出
PASS: 17 test file(s)
git diff --check无输出
```

如果执行时测试文件数已因其他用户工作增加，以实际注册数全部PASS为准；不得为满足固定数字删除或跳过测试。

- [ ] **Step 7: 核对输入边界与保留行为**

Run:

```bash
rg -n "Input\." scripts/player scripts/combat
rg -n "next_aim_direction|set_combat_input|request_shot" scripts tests
```

Expected:

```text
PlayerController仍负责WASD、Space和J的全局Input读取
PlayerWeapon没有新增Input调用
next_aim_direction只接受move_direction与current_aim_direction
set_combat_input仍接受trigger_pressed、trigger_just_pressed、aim_direction
FireGate的request_shot(0.08)调用仍存在
```

- [ ] **Step 8: 进行桌面操作验收**

Launch:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

按以下顺序验收：

| 场景 | 操作 | 预期结果 |
| --- | --- | --- |
| 非射击移动 | 分别按W、A、S、D和对角组合 | 玩家移动、角色朝向、方向指示器保持同向，对角速度仍归一化 |
| 持续射击转向 | 按住J，再从W切到D、S、A | 每次WASD改变后角色与下一发射线立即转向，不保留按下J时的旧方向 |
| 反向切换 | 按住J，从W直接切到S | 功能方向同一物理帧反转；视觉后坐不得延迟或改变功能射线 |
| 原地射击 | 先按D移动，再松开WASD并保持J | 玩家停止并保留向右朝向，后续子弹继续向右 |
| 短按缓冲 | 在射击冷却期间快速点按并松开J | 冷却期间保留短按请求，冷却结束后正常发射一次 |
| 辅助命中 | 朝目标附近移动并射击 | 5度、18米内可修正到胸口；障碍物仍阻挡射线 |
| 反馈保留 | 连续命中并击杀目标 | 枪口火焰、枪声、角色后坐、镜头脉冲、HIT/CRITICAL/KILL、死亡动画均正常 |
| 血迹保留 | 普通命中和击杀 | 空中血花短时存在；地面血迹永久保留且不因本次控制改动消失 |

- [ ] **Step 9: 检查本计划增量并交由用户提交**

Run:

```bash
git status --short
git diff --check
git diff -- \
  scripts/player/player_motion.gd \
  scripts/player/player_controller.gd \
  tests/unit/test_player_motion.gd \
  README.md
```

Expected: 只出现本计划的方向语义、测试和说明增量；不得执行`git add`或`git commit`。由用户自行决定如何从当前脏工作区暂存并提交。

---

## Self-Review

- **需求覆盖：** Task 1直接删除J键锁向分支，使WASD非零输入在每帧同时驱动移动、根朝向、方向指示器和武器射线；同时覆盖零输入保留最后方向。
- **范围控制：** 不修改武器射速、80毫秒缓冲、辅助命中、伤害、击退、音画反馈、死亡动画或地面血迹，只调整方向决策与说明。
- **占位符扫描：** 未使用TBD、TODO、“稍后实现”或未定义接口；测试、实现、命令、预期失败和人工验收均给出具体内容。
- **类型一致性：** `PlayerMotion.next_aim_direction(Vector3, Vector3) -> Vector3`与`PlayerController`调用一致；`PlayerWeapon.set_combat_input(bool, bool, Vector3)`保持不变；`aim_direction`始终是扁平归一化向量。
- **提交策略：** 遵循最新项目约定，执行代理不提交，计划完成后由用户自行提交。
