# 武器胶囊允许僵尸穿透 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让僵尸穿过远程武器的长胶囊，在玩家主体胶囊前停下并进入现有攻击范围，同时保留枪械墙体净空、姿态和枪口端点行为。

**Architecture:** `WeaponCollision` 继续作为 `Player` 直属的 `CollisionShape3D` 保存胶囊尺寸和当前姿态变换，但永久禁用其物理碰撞；`NormalProbe` 与 `RaisedProbe` 继续只查询世界第 1 层，负责墙体净空。玩家根节点的碰撞遮罩及人物主体胶囊保持不变，因此玩家身体仍与 `ZombieBlocker` 层碰撞。

**Tech Stack:** Godot 4.7.1、GDScript、Godot headless 场景验证。

## Global Constraints

- 在当前分支执行，不创建 worktree。
- 不创建 commit；整个 plan 完成后由用户自行提交。
- 不修改僵尸 `1.45m` 攻击范围、攻击状态机、伤害、追击或确定性模拟。
- 玩家根节点继续保持 `collision_layer = 2`、`collision_mask = 9`。
- `NormalProbe` 与 `RaisedProbe` 继续保持 `collision_mask = 1`。
- 保留 `WeaponCollision` 的胶囊尺寸与局部变换，供枪口端点和视觉姿态读取。
- 避开工作区中已有的无关 `.import` 和其他用户改动。

---

### Task 1: 让武器胶囊退出玩家物理碰撞

**Files:**
- Create: `tools/validation/validate_weapon_collision_zombie_passthrough.gd`
- Modify: `scenes/player/Player.tscn:42-45`
- Modify: `scripts/player/weapon_clearance_controller.gd:28-76,137-145`
- Verify: `tools/validation/validate_local_player_spawning.gd`
- Verify: `tools/validation/validate_muzzle_flash_orientation.gd`

**Interfaces:**
- Consumes: `Player.tscn` 的 `WeaponCollision`、`WeaponClearanceController/NormalProbe`、`RaisedProbe`；`WeaponClearanceController.get_weapon_muzzle_origin(fallback: Vector3) -> Vector3`。
- Produces: 远程武器绑定后仍为 `weapon_collision.disabled == true`；玩家身体继续碰撞世界与僵尸层；净空查询继续只检测世界层。

- [x] **Step 1: 新增场景级失败验证**

创建 `tools/validation/validate_weapon_collision_zombie_passthrough.gd`：

```gdscript
extends SceneTree

const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	_expect(player != null, "Player scene must instantiate", failures)
	if player == null:
		_finish(failures)
		return

	var weapon_collision := player.get_node_or_null(
		"WeaponCollision"
	) as CollisionShape3D
	var clearance := player.get_node_or_null(
		"WeaponClearanceController"
	) as WeaponClearanceController
	var normal_probe := player.get_node_or_null(
		"WeaponClearanceController/NormalProbe"
	) as ShapeCast3D
	var raised_probe := player.get_node_or_null(
		"WeaponClearanceController/RaisedProbe"
	) as ShapeCast3D

	_expect(weapon_collision != null, "Player must retain weapon capsule metadata", failures)
	_expect(clearance != null, "Player must retain weapon clearance controller", failures)
	_expect(normal_probe != null, "Player must retain normal clearance probe", failures)
	_expect(raised_probe != null, "Player must retain raised clearance probe", failures)
	if weapon_collision != null:
		_expect(
			weapon_collision.disabled,
			"weapon capsule must start disabled so zombies can cross its space",
			failures
		)

	root.add_child(player)
	await process_frame
	await physics_frame

	_expect(player.collision_layer == 2, "player must remain on collision layer 2", failures)
	_expect(
		player.collision_mask == 9,
		"player body must keep colliding with world and ZombieBlocker layers",
		failures
	)
	if weapon_collision != null:
		_expect(
			weapon_collision.disabled,
			"binding a ranged weapon must not add its capsule to player collision",
			failures
		)
		_expect(
			weapon_collision.shape is CapsuleShape3D,
			"disabled weapon capsule must retain its shape for muzzle math",
			failures
		)
	if normal_probe != null:
		_expect(normal_probe.collision_mask == 1, "normal probe must only query world layer 1", failures)
	if raised_probe != null:
		_expect(raised_probe.collision_mask == 1, "raised probe must only query world layer 1", failures)
	if clearance != null:
		var fallback := Vector3(99.0, 99.0, 99.0)
		_expect(
			not clearance.get_weapon_muzzle_origin(fallback).is_equal_approx(fallback),
			"disabled weapon capsule must still provide the muzzle endpoint",
			failures
		)

	player.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_weapon_collision_zombie_passthrough: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

该验证捕获的生产缺陷是：场景默认或远程武器绑定流程重新启用 `WeaponCollision`，使枪械空间重新参与玩家与僵尸的物理碰撞。

- [x] **Step 2: 运行验证并确认因现有缺陷失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . \
  --script res://tools/validation/validate_weapon_collision_zombie_passthrough.gd
```

Expected: exit `1`，至少报告：

```text
weapon capsule must start disabled so zombies can cross its space
binding a ranged weapon must not add its capsule to player collision
```

如果出现脚本解析或夹具错误，先只修正验证文件，重复运行，直到它确实因当前 `WeaponCollision` 被启用而失败。

- [x] **Step 3: 最小修改场景默认状态**

在 `scenes/player/Player.tscn` 的 `WeaponCollision` 节点加入：

```gdscript
[node name="WeaponCollision" type="CollisionShape3D" parent="."]
position = Vector3(0, 1.12, -0.62)
rotation_degrees = Vector3(90, 0, 0)
disabled = true
shape = SubResource("CapsuleShape3D_weapon_collision")
```

这保证节点进入场景树之前就不会作为玩家运动形状注册，但仍保留形状资源和变换。

- [x] **Step 4: 阻止远程武器绑定重新启用胶囊**

修改 `scripts/player/weapon_clearance_controller.gd`：

1. 从 `try_bind_weapon()` 的两个远程武器成功分支删除：

```gdscript
weapon_collision.disabled = false
```

2. 在 `_configure_shapes()` 开头明确保持禁用，并用注释记录边界：

```gdscript
func _configure_shapes() -> void:
	# 武器胶囊只保存净空姿态和枪口端点数据。若把它启用为 Player 的运动形状，
	# 它会继承 Player 对 ZombieBlocker 层的遮罩，让长枪从正面提前顶住僵尸。
	weapon_collision.disabled = true
	var capsules: Array[CapsuleShape3D] = [
		weapon_collision.shape as CapsuleShape3D,
		normal_probe.shape as CapsuleShape3D,
		raised_probe.shape as CapsuleShape3D,
	]
```

不要修改 `_commit_pose()` 的变换提交，也不要关闭两个 `ShapeCast3D`；禁用的 `CollisionShape3D` 仍必须随姿态更新并供 `get_weapon_muzzle_origin()` 读取。

- [x] **Step 5: 运行聚焦验证确认通过**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . \
  --script res://tools/validation/validate_weapon_collision_zombie_passthrough.gd
```

Expected:

```text
validate_weapon_collision_zombie_passthrough: PASS
```

- [x] **Step 6: 运行相关回归验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . \
  --script res://tools/validation/validate_local_player_spawning.gd
```

Expected:

```text
validate_local_player_spawning: PASS
```

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . \
  --script res://tools/validation/validate_muzzle_flash_orientation.gd
```

Expected:

```text
validate_muzzle_flash_orientation: PASS
```

- [x] **Step 7: 运行 Godot 导入与解析检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
```

Expected: exit `0`，没有新增场景或脚本解析错误。该命令可能刷新现有 `.import` 文件；不要把无关导入改动纳入本任务。

- [x] **Step 8: 检查最终差异，不提交**

Run:

```bash
git diff --check -- \
  scenes/player/Player.tscn \
  scripts/player/weapon_clearance_controller.gd \
  tools/validation/validate_weapon_collision_zombie_passthrough.gd \
  docs/superpowers/specs/2026-08-12-weapon-collision-zombie-pass-through-design.md \
  docs/superpowers/plans/2026-08-12-weapon-collision-zombie-pass-through.md
```

Expected: exit `0`。只报告变更和验证结果，不执行 `git add` 或 `git commit`。

---

## 人工验收

由于项目约定不使用 UI 自动化，完成后请用户在游戏内执行：

1. 持手枪或冲锋枪，正面对着一只接近中的僵尸并停止移动。
2. 确认僵尸模型可以进入枪械前端占用空间，而不会在枪口处持续推着玩家。
3. 确认僵尸最终停在玩家身体前，播放攻击前摇并造成伤害。
4. 从侧面和背面各接触一次，确认攻击行为保持原样。
5. 面向墙体靠近，确认枪械仍会抬起或收起，且射线不会穿墙。
