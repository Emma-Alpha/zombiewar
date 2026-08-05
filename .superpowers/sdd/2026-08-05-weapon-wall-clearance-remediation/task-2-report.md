# Task 2 — 事务切枪与失败关闭报告

## 实现内容

- `WeaponClearanceController.try_bind_weapon()` 现在是同步切枪预检与提交入口：
  - 非远程候选恢复当前视觉并关闭 clearance；
  - 没有 `visual_anchor` 的远程候选发出 warning 并拒绝，且不触碰当前合法状态；
  - 已提交且仍安全的远程姿态会被下一把远程武器继承；
  - 已提交姿态在墙体移动后不再安全时，重新预检 normal/raised 两个姿态；两个都不安全则拒绝；
  - 成功时一次性更新当前武器、定义、视觉 rest transform、三个统一胶囊和碰撞姿态。
- `EquipmentController` 提供 `set_switch_guard()`，并让 `setup()` 接收可选守卫。`equip_slot()` 在隐藏旧武器、更新槽位或发射信号前执行守卫，拒绝时保持旧武器的物理、视觉、槽位和攻击输入。
- `PlayerController` 在 `setup()` 中注入 clearance 守卫，删除 `weapon_changed` 后的重复绑定。
- Clearance 初始化时禁用 `WeaponCollision`；因此首次装备遭双 probe 拒绝时会保持“无当前武器、无武器碰撞”。这覆盖了 progress ledger 中与本任务相关的 deferred Minor。
- `_exit_tree()` 恢复仍有效的当前视觉 local transform，并重置已提交 clearance state。

## TDD 记录

### RED

首次加入集成测试后执行 `./tests/run_tests.sh` 时，测试夹具误将 `StaticBody3D` 传入只接受 `ZombieTarget` 的 `_cleanup()`，产生解析错误。该运行不计作 RED；已将新夹具改为显式释放 player 与两面墙。

修复夹具后执行：

```text
./tests/run_tests.sh
exit 1
ERROR: ...test_weapon_clearance_controller.gd: Clearance exit restores the raised weapon local transform
ERROR: ...test_weapon_loadout.gd: Equipment exposes a switch guard setter
FAIL: 2 failure(s)
```

新增首次双阻挡场景测试后再次执行：

```text
./tests/run_tests.sh
exit 1
ERROR: ...Clearance exit restores the raised weapon local transform
ERROR: ...Equipment exposes a switch guard setter
ERROR: ...Initial double-blocked equip leaves no weapon and no active weapon collision
FAIL: 3 failure(s)
```

这些是预期断言失败：基线缺少新 setter 和退出恢复，且双 probe 拒绝初始装备时真实 `WeaponCollision` 仍启用。

第一轮实现后的 GREEN 运行还暴露了真实回归：当墙在远程武器装备后移动，旧 normal pose 已不安全却被无条件继承。原有集成断言“Wall-side pistol/rifle switch chooses the raised pose immediately”失败。实现改为先验证已提交姿态安全；不安全时重新执行双姿态预检。

### GREEN

执行：

```text
./tests/run_tests.sh
PASS: 33 test file(s)
```

该运行包含两条预期 warning（测试刻意移除 rifle `visual_anchor` 以验证拒绝路径）；没有测试失败或 Godot error。

执行：

```text
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
exit 0
```

执行：

```text
git diff --check
<no output>
```

## 覆盖测试文件

- `tests/unit/test_weapon_loadout.gd`
  - 可调用守卫拒绝切换时的 weapon identity、slot、visibility 和 attack input 不变；
  - 从初始双阻挡场景生成时，无当前武器且 `WeaponCollision` 禁用；
  - 保留并验证 melee/ranged 现有的双阻挡切枪事务。
- `tests/integration/test_weapon_wall_clearance.gd`
  - 已抬枪远程互切继承已提交碰撞姿态；
  - 三个运行时 capsule 保持 `height = 1.55`、`radius = 0.12`；
  - 缺少候选远程 visual anchor 时保留当前远程碰撞；
  - 匕首到前墙和低顶双阻挡的远程切换失败关闭。
- `tests/unit/test_weapon_clearance_controller.gd`
  - raised 状态退出树时恢复保存的视觉 local transform。

## 变更文件

- `scripts/player/weapon_clearance_controller.gd`
- `scripts/player/equipment_controller.gd`
- `scripts/player/player_controller.gd`
- `tests/unit/test_weapon_clearance_controller.gd`
- `tests/unit/test_weapon_loadout.gd`
- `tests/integration/test_weapon_wall_clearance.gd`
- `.superpowers/sdd/2026-08-05-weapon-wall-clearance-remediation/task-2-report.md`

## 自审

- 守卫在任何旧武器可见性、slot、current weapon、信号或 attack state 写入之前执行。
- 所有拒绝分支均在写入 candidate clearance state 前返回；候选无 visual anchor 时尤其不会恢复旧视觉或关闭旧远程碰撞。
- 已提交姿态仅在当前物理世界中 probe 仍安全时继承，避免墙体移动后的 stale pose。
- `WeaponCollision` 在初始状态禁用，成功远程绑定才启用；非远程绑定、死亡和重置仍会关闭它。
- 未修改 `addons/`、`.godot/`、`build/`、计划或 SDD ledger。

## Concerns

无未解决 concern。缺少 `visual_anchor` 时的 warning 是指定失败路径的诊断输出，且由测试有意触发。
