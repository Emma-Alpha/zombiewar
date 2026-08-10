# 步枪完整迁移为冲锋枪 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移除当前功能线的多弹丸能力，并将现有步枪完整迁移为使用 SMG 模型和 UZI 音效的冲锋枪。

**Architecture:** 先把工作树中已确认的多弹丸撤销正式提交，使分支恢复单弹丸 `RangedWeapon`；再合入 `main` 的场景级音效与 UZI 素材。冲锋枪继续复用通用远程武器、装备和数据驱动拾取架构，只迁移稳定 ID、资源路径、模型节点、显示文本和验证契约。

**Tech Stack:** Godot 4.7.1、GDScript、`.tscn`、`.tres`、MP3 导入资源、现有 `tools/validation` SceneTree 验证脚本。

## Global Constraints

- 在已有链接工作树 `/Users/yewei/yyw/project/zombiewar/.worktrees/smg-shotgun` 和分支 `codex/smg-shotgun` 中执行。
- 先移除 `WeaponVolleyMath`、多弹丸配置和对应验证，不实现散弹枪。
- 完整迁移后不保留 `rifle` 稳定 ID、旧运行时资源路径或“步枪”显示名。
- 冲锋枪稳定 ID 为 `&"smg"`，显示名为 `冲锋枪`，模型节点为 `SMG`。
- 保留每秒 `4` 发、单发 `25`、弹药上限 `360`、武器箱 `60`、弹药箱 `90` 及其余现有远程武器数值。
- 射击音效使用 `sound_562.mp3` 对应的 UZI 素材，运行时文件名为 `smg_fire.mp3`。
- 音效由场景 `ext_resource` 预引用；开火热路径不得增加 `load()` 或节点实例化。
- 数据驱动拾取继续使用通用 `PickupChest`；删除未使用的旧 `RiflePickupChest.tscn`，不创建新的专用 SMG 拾取场景。
- 不修改主工作区未提交的菜单、手柄或原始音效目录。
- 每个任务只暂存计划明确列出的文件，避免带入其他工作树改动。

---

### Task 1：正式移除多弹丸能力

**Files:**
- Modify: `scripts/combat/weapons/ranged_weapon.gd`
- Modify: `scripts/combat/weapons/ranged_weapon_definition.gd`
- Delete: `scripts/combat/weapons/weapon_volley_math.gd`
- Delete: `scripts/combat/weapons/weapon_volley_math.gd.uid`
- Delete: `tools/validation/validate_ranged_weapon_volley.gd`
- Delete: `tools/validation/validate_ranged_weapon_volley.gd.uid`

**Interfaces:**
- Produces: `RangedWeapon` 每轮只解析一条射线并生成一条曳光。
- Removes: `RangedWeaponDefinition.projectiles_per_shot`、`projectile_angle_degrees` 和 `WeaponVolleyMath.build_directions()`。

- [ ] **Step 1：确认工作树撤销内容只覆盖多弹丸能力**

Run:

```bash
git diff -- scripts/combat/weapons/ranged_weapon.gd scripts/combat/weapons/ranged_weapon_definition.gd scripts/combat/weapons/weapon_volley_math.gd tools/validation/validate_ranged_weapon_volley.gd
```

Expected: `ranged_weapon.gd` 恢复单射线 `_fire()`；定义移除两个多弹丸字段；数学脚本和验证脚本被删除。

- [ ] **Step 2：删除多弹丸脚本 UID 和孤立验证 UID**

使用 `apply_patch` 删除 `scripts/combat/weapons/weapon_volley_math.gd.uid` 和当前未跟踪的 `tools/validation/validate_ranged_weapon_volley.gd.uid`。不得删除其他验证文件。

- [ ] **Step 3：验证单弹丸基线可解析**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
git diff --check
```

Expected: Godot exit `0`，无脚本解析错误，diff 检查通过。

- [ ] **Step 4：提交多弹丸移除**

```bash
git add scripts/combat/weapons/ranged_weapon.gd scripts/combat/weapons/ranged_weapon_definition.gd scripts/combat/weapons/weapon_volley_math.gd scripts/combat/weapons/weapon_volley_math.gd.uid tools/validation/validate_ranged_weapon_volley.gd
git commit -m "refactor: remove projectile volley support"
```

`tools/validation/validate_ranged_weapon_volley.gd.uid` 是未跟踪孤立文件，删除后不需要加入暂存区。

---

### Task 2：合入最新 main 音效基础

**Files:**
- Merge: `main` 的 `dbf4dc3 feat: integrate gameplay sound effects`
- Verify: `scripts/combat/weapons/ranged_weapon.gd`
- Verify: `assets/sfx/boxhead/rifle_fire.mp3`

**Interfaces:**
- Consumes: `SpatialSfxPool.find_for(node)` 与墙面命中音效逻辑。
- Produces: 可供冲锋枪场景预引用的 UZI 素材 `rifle_fire.mp3`，随后在 Task 4 语义化重命名。

- [ ] **Step 1：确认 Task 1 后工作树干净**

Run:

```bash
git status --short
git log --oneline -4
```

Expected: 状态为空，HEAD 包含 `refactor: remove projectile volley support`。

- [ ] **Step 2：合并最新 main**

Run:

```bash
git merge main
```

Expected: 合入 `dbf4dc3`；若 `ranged_weapon.gd` 出现冲突，保留 Task 1 的单射线结构，同时保留 `main` 的 `WALL_IMPACT_SOUNDS`、`SpatialSfxPool` 缓存、`hit_world_surface` 解析与播放逻辑。

- [ ] **Step 3：验证音效基础与场景运行**

Run:

```bash
test -f assets/sfx/boxhead/rifle_fire.mp3
rg -n 'WALL_IMPACT_SOUNDS|SpatialSfxPool|hit_world_surface' scripts/combat/weapons/ranged_weapon.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --quit-after 5 scenes/gameplay/DemoArena.tscn
```

Expected: 素材存在；三个墙面音效关键符号存在；两个 Godot 命令 exit `0`。

---

### Task 3：先更新冲锋枪验证契约并确认 RED

**Files:**
- Modify: `tools/validation/validate_equipment_cycle.gd`
- Modify: `tools/validation/validate_pickup_spawn_point.gd`
- Modify: `tools/validation/validate_lobby_player_preview.gd`
- Modify: `tools/validation/validate_pickup_definitions.gd`
- Modify: `tools/validation/validate_random_pickup_drops.gd`
- Modify: `tools/validation/validate_local_player_spawning.gd`
- Modify: `tools/validation/validate_single_player_input_wiring.gd`
- Modify: `tools/validation/validate_local_disconnect_contract.gd`

**Interfaces:**
- Produces: `smg` 稳定 ID、中文显示名、SMG 模型和新资源路径的可执行验证契约。
- Consumes: 现有 `EquipmentController.get_item_by_id()`、`grant_item()`、`add_ammo()`。

- [ ] **Step 1：把装备与拾取期望改成 SMG 语义**

在 `validate_equipment_cycle.gd` 中暂时保留 `RifleScene` 的旧 preload 路径，使脚本可以执行，但将测试函数、局部变量、ID 和断言改为：

```gdscript
var smg = controller.call("get_item_by_id", &"smg")
_expect(smg != null, "smg must retain a stable equipment item id", failures)
_expect(not smg.is_available(), "smg must start unowned", failures)
_expect(int(controller.call("add_ammo", &"smg", 30)) == 0, "unowned smg must reject ammo pickups", failures)
_expect(bool(controller.call("grant_item", &"smg", 400, true)), "smg pickup must grant ownership or ammo", failures)
_expect(smg.get_ammo_count() == 360, "smg ammo must cap at 360", failures)
```

`validate_pickup_spawn_point.gd` 暂时保留旧资源路径常量，但把 `item_id` 期望改为 `&"smg"`，显示名改为 `冲锋枪` / `冲锋枪弹药`，Demo 节点期望改为 `Smg` / `SmgAmmo`。删除专用场景列表继续要求 `RiflePickupChest.tscn` 不存在。

`validate_pickup_definitions.gd` 的通用示例 ID 与显示文本改为 `smg` / `冲锋枪`；`validate_random_pickup_drops.gd` 的变量命名和期望语义改为 SMG，但在 RED 阶段仍可引用旧路径。

- [ ] **Step 2：把模型和初始装备期望改正确**

- `validate_lobby_player_preview.gd` 查找可见 `SMG`，隐藏列表包含 `Rifle` 而不包含 `SMG`。
- `validate_local_player_spawning.gd` 初始装备标签改为 `P%d · 手枪`，因为冲锋枪默认未拥有。
- `validate_single_player_input_wiring.gd` 初始装备改为 `手枪`；一次 next 切换应跳过未拥有冲锋枪到达 `匕首`；保留旧输入属性移除检查中的 `rifle_action`，因为该字段是历史 API 名称而非运行时武器入口。
- `validate_local_disconnect_contract.gd` 在 RED 阶段仍 preload 旧场景，但局部变量和断言改为 SMG 语义。

- [ ] **Step 3：运行三项核心验证并确认正确失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_spawn_point.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_lobby_player_preview.gd
```

Expected: 三项均以断言失败而非解析错误退出；失败原因分别包含缺少 `smg` ID、Demo 缺少 `Smg` 节点或拾取语义仍为步枪、预览未显示 `SMG`。

---

### Task 4：完整迁移运行时资源、模型与 UZI 音效

**Files:**
- Create: `resources/weapons/smg.tres`
- Delete: `resources/weapons/rifle.tres`
- Create: `scenes/weapons/Smg.tscn`
- Delete: `scenes/weapons/Rifle.tscn`
- Create: `resources/pickups/smg_pickup.tres`
- Delete: `resources/pickups/rifle_pickup.tres`
- Create: `resources/pickups/smg_ammo_pickup.tres`
- Delete: `resources/pickups/rifle_ammo_pickup.tres`
- Delete: `scenes/gameplay/RiflePickupChest.tscn`
- Rename binary: `assets/sfx/boxhead/rifle_fire.mp3` -> `assets/sfx/boxhead/smg_fire.mp3`
- Regenerate: `assets/sfx/boxhead/smg_fire.mp3.import`
- Delete: `assets/sfx/boxhead/rifle_fire.mp3.import`
- Modify: `scenes/player/Player.tscn`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `scripts/menu/lobby_player_preview.gd`
- Modify: Task 3 的八个验证脚本路径常量与 preload

**Interfaces:**
- Produces: `weapon_id = &"smg"`、`display_name = "冲锋枪"`、`visual_node_name = &"SMG"`。
- Produces: `Smg.tscn` 的 `ShotAudio.stream = res://assets/sfx/boxhead/smg_fire.mp3`。

- [ ] **Step 1：创建冲锋枪武器资源和场景，删除旧入口**

`resources/weapons/smg.tres` 保留原 UID `uid://bnb1jtawikelh` 和全部数值，只将身份字段设为：

```ini
weapon_id = &"smg"
display_name = "冲锋枪"
visual_node_name = &"SMG"
```

`scenes/weapons/Smg.tscn` 使用 `smg.tres` 与 `smg_fire.mp3`，根节点名为 `Smg`，`initially_owned = false`。保留 `ShotAudio` 的 `volume_db = -8.0`、`unit_size = 6.0`、`max_distance = 32.0`。

通过 `apply_patch` 新增目标文本文件并删除旧文本文件；不得保留旧 `rifle.tres` 或 `Rifle.tscn`。

- [ ] **Step 2：迁移拾取定义并删除旧专用场景**

`smg_pickup.tres` 配置：

```ini
reward_mode = 0
item_id = &"smg"
amount = 60
auto_equip = true
display_name = "冲锋枪"
marker_color = Color(1, 0.45, 0.08, 1)
```

`smg_ammo_pickup.tres` 配置：

```ini
reward_mode = 1
item_id = &"smg"
amount = 90
auto_equip = false
display_name = "冲锋枪弹药"
marker_color = Color(0.2, 0.55, 1, 1)
```

删除旧两个 `.tres` 和未使用的 `RiflePickupChest.tscn`。

- [ ] **Step 3：重命名 UZI 素材并重新导入**

将二进制 `rifle_fire.mp3` 移动为 `smg_fire.mp3`。使用 `apply_patch` 删除旧 `.import`，随后运行 Godot headless editor 生成新的 `smg_fire.mp3.import`；确认其 `source_file` 为 `res://assets/sfx/boxhead/smg_fire.mp3`。

- [ ] **Step 4：更新玩家、Demo、大厅预览和验证路径**

- `Player.tscn` 的外部资源改为 `Smg.tscn`，ID 改为 `8_smg`，装备数组保持手枪、冲锋枪、匕首、油桶顺序。
- `DemoArena.tscn` 的拾取资源改为 `smg_pickup.tres` / `smg_ammo_pickup.tres`，节点名改为 `Smg` / `SmgAmmo`，随机池使用两项 SMG 定义。
- `lobby_player_preview.gd` 的 `DISPLAY_WEAPON` 改为 `SMG`。
- Task 3 验证脚本中的旧资源路径、preload、常量名和变量名全部改为 `Smg` / `smg`，但保留历史输入字段字符串 `rifle_action` 的移除断言。

- [ ] **Step 5：运行 GREEN 验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_spawn_point.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_definitions.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_random_pickup_drops.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_lobby_player_preview.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_player_spawning.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_single_player_input_wiring.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_disconnect_contract.gd
```

Expected: 八项均打印 `PASS` 并 exit `0`。

- [ ] **Step 6：提交完整迁移**

```bash
git add assets/sfx/boxhead resources/weapons resources/pickups scenes/weapons scenes/player/Player.tscn scenes/gameplay/DemoArena.tscn scenes/gameplay/RiflePickupChest.tscn scripts/menu/lobby_player_preview.gd tools/validation
git commit -m "refactor: migrate rifle to smg"
```

---

### Task 5：更新说明并执行最终残留与运行验证

**Files:**
- Modify: `README.md`
- Verify: `scripts/`、`scenes/`、`resources/`、`tools/`、`project.godot`

**Interfaces:**
- Consumes: Task 4 的 `smg` 运行时契约。
- Produces: 不含旧步枪运行时语义的说明和可合并分支。

- [ ] **Step 1：更新 README**

将装备键 `2`、中文玩法说明和英文 Demo 描述中的 rifle/步枪改为 SMG/冲锋枪；明确冲锋枪每秒 `4` 发、单发 `25`，不保留旧的每秒 `6` 发描述。

- [ ] **Step 2：执行旧引用残留扫描**

Run:

```bash
rg -n -i 'rifle|步枪' scripts scenes resources tools README.md project.godot --glob '!*.uid'
```

Expected: 只允许 `validate_single_player_input_wiring.gd` 中历史输入字段字符串 `rifle_action`；其他输出必须清零。设计和实施计划文档不纳入扫描。

- [ ] **Step 3：执行音效和数值静态检查**

Run:

```bash
rg -n 'weapon_id = &"smg"|display_name = "冲锋枪"|visual_node_name = &"SMG"|attacks_per_second = 4.0|damage = 25.0|max_ammo = 360' resources/weapons/smg.tres
rg -n 'smg_fire.mp3' scenes/weapons/Smg.tscn assets/sfx/boxhead/smg_fire.mp3.import
rg -n '(^|[^[:alnum:]_])load\(' scripts/combat/weapons/ranged_weapon.gd
```

Expected: 资源字段和音效路径全部命中；最后一个 `rg` 无输出。

- [ ] **Step 4：执行最终 Godot 验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --quit-after 5 scenes/gameplay/DemoArena.tscn
git diff --check
git status --short
```

Expected: 两个 Godot 命令 exit `0`；diff 检查通过；状态只包含 README 的预期修改。

- [ ] **Step 5：提交 README**

```bash
git add README.md
git commit -m "docs: describe smg loadout"
```

完成后使用 `finishing-a-development-branch`。合并目标分支前，按仓库约定将本次任务的提交 squash 为一个计划提交，同时保留功能线中此前经确认需要保留的历史提交。
