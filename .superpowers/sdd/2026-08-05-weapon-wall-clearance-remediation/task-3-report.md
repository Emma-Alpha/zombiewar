# Task 3 — 抬枪射击、实际朝向与墙体伤害截断报告

## 实现内容

- `PlayerController` 在同一物理流程应用 `WeaponClearanceController.resolve_facing_yaw()` 返回值后，以 `WeaponMath.flat_direction(-global_basis.z)` 计算已接受的人物实际前向。
- 远程武器攻击输入改用实际人物前向；近战仍沿用原 `aim_direction`。
- `RangedWeapon._intersect_shot()` 使用 `definition.hit_collision_mask | 1`，保证功能射线始终包含世界第 1 层，并继续启用 `collide_with_areas`。
- 保留 `NORMAL` / `RAISED` 原射速射击路径；没有新增 clearance 攻击门闩、`observe_trigger()`、`can_fire()` 或 clearance `cancel_attack()`。
- 未改变 Task 2 的事务切枪接口或语义。

## RED

命令：

```text
./tests/run_tests.sh
```

最终测试夹具下临时移除两处生产修复后的相关完整失败输出：

```text
Godot Engine v4.7.1.stable.official.a13da4feb - https://godotengine.org

[godot_ai game_helper] registered mcp capture (debugger active=false, logger=true)
WARNING: Weapon rifle has no visual anchor
     at: push_warning (core/variant/variant_utility.cpp:1033)
     GDScript backtrace (most recent call first):
         [0] try_bind_weapon (res://scripts/player/weapon_clearance_controller.gd:41)
         [1] run (res://tests/unit/test_weapon_clearance_controller.gd:145)
         [2] _initialize (res://tests/test_runner.gd:51)
WARNING: Weapon rifle has no visual anchor
     at: push_warning (core/variant/variant_utility.cpp:1033)
     GDScript backtrace (most recent call first):
         [0] try_bind_weapon (res://scripts/player/weapon_clearance_controller.gd:41)
         [1] equip_slot (res://scripts/player/equipment_controller.gd:66)
         [2] _test_switching_contract (res://tests/integration/test_weapon_wall_clearance.gd:238)
         [3] run (res://tests/integration/test_weapon_wall_clearance.gd:145)
         [4] _initialize (res://tests/test_runner.gd:51)
ERROR: res://tests/unit/test_weapon_feedback.gd: Layer-one wall is the first functional ray hit even when the resource mask omits it
ERROR: res://tests/unit/test_weapon_feedback.gd: Layer-one wall prevents damage to the target behind it — expected 50.0000, got 25.0000
ERROR: res://tests/integration/test_weapon_wall_clearance.gd: Rejected turn fires along the player's accepted facing
ERROR: res://tests/integration/test_weapon_wall_clearance.gd: Rejected target yaw cannot damage a target only in that direction — expected 50.0000, got 25.0000
FAIL: 4 failure(s)
```

预期原因：

- 资源 mask 临时清除第 1 层后，旧 `_intersect_shot()` 不会补回世界层，射线穿过墙并对墙后目标造成 `25` 点伤害。
- 双阻挡拒绝目标 yaw 后，旧 `PlayerController` 仍把 `aim_direction = Vector3.RIGHT` 提交给远程武器，因此信号方向不是已接受的人物前向，且仅位于右侧的目标受到 `25` 点伤害。

TDD 夹具说明：第一次运行因 `original_hit_mask` 无显式类型产生解析错误，该运行不计作 RED；修正为 `int` 后得到目标行为失败。后续发现 GDScript 闭包对局部 `Vector3` 的赋值不会写回外层变量，方向捕获改为引用型 `Array[Vector3]`，并再次临时移除生产修复确认以上四个断言均由旧行为触发，而非解析或夹具错误。

## GREEN

命令：

```text
./tests/run_tests.sh
```

关键完整输出：

```text
Godot Engine v4.7.1.stable.official.a13da4feb - https://godotengine.org

[godot_ai game_helper] registered mcp capture (debugger active=false, logger=true)
WARNING: Weapon rifle has no visual anchor
     at: push_warning (core/variant/variant_utility.cpp:1033)
     GDScript backtrace (most recent call first):
         [0] try_bind_weapon (res://scripts/player/weapon_clearance_controller.gd:41)
         [1] run (res://tests/unit/test_weapon_clearance_controller.gd:145)
         [2] _initialize (res://tests/test_runner.gd:51)
WARNING: Weapon rifle has no visual anchor
     at: push_warning (core/variant/variant_utility.cpp:1033)
     GDScript backtrace (most recent call first):
         [0] try_bind_weapon (res://scripts/player/weapon_clearance_controller.gd:41)
         [1] equip_slot (res://scripts/player/equipment_controller.gd:66)
         [2] _test_switching_contract (res://tests/integration/test_weapon_wall_clearance.gd:238)
         [3] run (res://tests/integration/test_weapon_wall_clearance.gd:145)
         [4] _initialize (res://tests/test_runner.gd:51)
PASS: 33 test file(s)
```

附加验证：

```text
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
exit 0
```

Godot 完成项目扫描与资源导入，没有场景或脚本解析错误。

```text
git diff --check
<no output>
```

## 覆盖测试文件

- `tests/unit/test_weapon_feedback.gd`
  - 世界墙位于 `Vector3(0, 1.1, -2)`，尺寸 `Vector3(2, 2, 0.2)`，目标位于 `Vector3(0, 0, -4)`。
  - 临时从定义 mask 清除第 1 层，断言生产射线仍首先命中墙；保留墙时目标不掉血，移除墙后同方向射击会造成伤害；最后恢复资源 mask。
- `tests/integration/test_weapon_wall_clearance.gd`
  - 保留既有 `RAISED` 推进 tracer cursor 的原射速回归。
  - 使用低位侧挡块与低顶造成目标 yaw 双阻挡；断言攻击信号沿已接受人物前向，且仅位于被拒目标 yaw 方向的僵尸不受伤。

## 变更文件

- `scripts/player/player_controller.gd`
- `scripts/combat/weapons/ranged_weapon.gd`
- `tests/unit/test_weapon_feedback.gd`
- `tests/integration/test_weapon_wall_clearance.gd`
- `.superpowers/sdd/2026-08-05-weapon-wall-clearance-remediation/task-3-report.md`

## 自审

- 实际远程方向在 accepted yaw 已写入 `rotation.y` 后读取 `global_basis`，不会使用被拒绝的目标 yaw。
- 仅远程定义走实际人物前向分支；近战输入路径保持原样。
- 射线 mask 只强制补入第 1 层，不改变资源中其他目标层、射程、伤害、射速、tracer、枪口闪光、音频或反馈信号。
- `query.collide_with_areas = true` 保持不变，僵尸 hit area 仍可命中。
- `NORMAL` / `RAISED` 均继续开火，没有重新引入 clearance 禁火或攻击取消。
- 未修改 `addons/`、`.godot/`、`build/`、计划、SDD ledger 或 Task 2 事务切枪代码。

## Concerns

- 无未解决实现 concern。
- 完整测试中的两条 `Weapon rifle has no visual anchor` warning 是既有测试刻意移除视觉锚点以验证事务拒绝路径，不是本任务新增警告。
- 未执行 DemoArena 人工游玩或录制运行时截图/视频；自动化覆盖、Godot headless 导入和差异检查均已完成。
