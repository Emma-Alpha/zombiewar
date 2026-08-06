# 武器拥有状态与 Demo 出生装备 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让基础玩家默认只有手枪和匕首，并提供按武器 ID 授予步枪、补充弹药和自动装备的接口，同时保留 Demo 出生即持有步枪 30 发的例外。

**Architecture:** `EquipmentController` 继续实例化完整槽位，但把“已实例化”和“已拥有”分离，通过 `owned_weapon_ids` 拦截未拥有槽位。`PlayerController` 暴露拾取奖励入口；Demo 在父节点 `_ready()` 中调用相同授予接口配置出生装备。

**Tech Stack:** Godot 4.7.1、GDScript、Player/Equipment 场景、项目自定义测试框架。

## Global Constraints

- 前置计划：`2026-08-06-weapon-ammo-core.md` 必须完成并通过全量测试。
- 基础玩家拥有手枪和匕首，默认装备手枪；槽 2 步枪默认未拥有。
- 未拥有步枪时选择槽 2 必须失败，并保持当前武器、攻击状态和视觉不变。
- 步枪拾取接口授予武器、增加指定弹药并请求自动装备；墙体切换守卫拒绝时奖励仍保留。
- 弹药补给接口不能为尚未拥有的武器预存弹药。
- Demo 例外：出生时授予步枪 30 发并装备槽 2；配置必须幂等。
- 玩家死亡后拒绝武器和弹药拾取。
- 本计划最终只保留一个提交：`feat: add weapon ownership and demo loadout`。

---

### Task 1: 实现武器拥有状态与拾取入口

**Files:**
- Create: `tests/helpers/player_test_factory.gd`
- Modify: `scripts/player/equipment_controller.gd:10-121`
- Modify: `scripts/player/player_controller.gd:12-288`
- Modify: `scenes/player/Player.tscn:65-71`
- Modify: `tests/unit/test_weapon_loadout.gd`
- Modify: `tests/unit/test_weapon_ammo.gd`
- Modify: `tests/unit/test_weapon_feedback.gd`
- Modify: `tests/unit/test_weapon_penetration.gd`
- Modify: `tests/unit/test_tracer_pool.gd`
- Modify: `tests/unit/test_weapon_clearance_controller.gd`
- Modify: `tests/integration/test_weapon_wall_clearance.gd`

**Interfaces:**
- Consumes: `RangedWeapon.add_ammo(amount: int) -> int`、`get_ammo_count() -> int`、`ammo_changed(current, maximum)`。
- Produces: `equipment_status_changed`、`owns_weapon(weapon_id) -> bool`、`get_weapon_by_id(weapon_id) -> WeaponBase`、`get_slot_for_weapon(weapon_id) -> int`、`grant_weapon(weapon_id, ammo_amount, auto_equip) -> bool`、`add_ammo(weapon_id, amount) -> int`、`get_ammo_count(weapon_id) -> int`、`receive_weapon_pickup(...) -> bool`、`receive_ammo_pickup(...) -> bool`。

- [ ] **Step 1: 改写武器装载测试并确认失败**

在 `test_weapon_loadout.gd` 的默认状态段加入：

```gdscript
_append(failures, Assertions.expect_equal(
	equipment.get_current_definition().weapon_id,
	&"pistol",
	"Base player starts with the pistol"
))
_append(failures, Assertions.expect_true(
	equipment.owns_weapon(&"pistol") and
		not equipment.owns_weapon(&"rifle") and
		equipment.owns_weapon(&"knife"),
	"Base player owns pistol and knife but not rifle"
))
var before_weapon := equipment.get_current_weapon()
_append(failures, Assertions.expect_true(
	not equipment.equip_slot(1) and equipment.get_current_weapon() == before_weapon,
	"Unowned rifle slot is rejected transactionally"
))
_append(failures, Assertions.expect_true(
	equipment.grant_weapon(&"rifle", 60, true),
	"Rifle pickup grants ownership and ammo"
))
_append(failures, Assertions.expect_true(
	equipment.owns_weapon(&"rifle") and
		equipment.get_current_definition().weapon_id == &"rifle" and
		equipment.get_ammo_count(&"rifle") == 60,
	"Granted rifle auto-equips with 60 rounds"
))
equipment.add_ammo(&"rifle", 300)
_append(failures, Assertions.expect_true(
	equipment.get_ammo_count(&"rifle") == 360 and
		not equipment.grant_weapon(&"rifle", 60, true),
	"Full duplicate rifle reports no state change"
))
```

运行：

```bash
./tests/run_tests.sh res://tests/unit/test_weapon_loadout.gd
```

Expected: FAIL，原因是拥有状态接口缺失或基础玩家仍以步枪开局。

- [ ] **Step 2: 实现 EquipmentController 拥有状态**

增加：

```gdscript
signal equipment_status_changed

@export var starting_owned_weapon_ids: Array[StringName] = [
	&"pistol",
	&"knife",
]

var owned_weapon_ids: Dictionary = {}
var warned_unknown_weapon_ids: Dictionary = {}
```

用以下块替换 `setup()` 末尾原有的单行 `equip_slot(starting_slot)`：

```gdscript
for weapon in weapons:
	if weapon is RangedWeapon:
		(weapon as RangedWeapon).ammo_changed.connect(_on_weapon_ammo_changed)
for weapon_id in starting_owned_weapon_ids:
	if get_weapon_by_id(weapon_id) != null:
		owned_weapon_ids[weapon_id] = true
if not equip_slot(starting_slot):
	equip_slot(_first_owned_slot())
```

在 `equip_slot()` 的索引检查后使用：

```gdscript
var candidate := weapons[slot_index]
if not owns_weapon(candidate.definition.weapon_id):
	return false
if slot_index == current_slot:
	return true
```

实现接口：

```gdscript
func owns_weapon(weapon_id: StringName) -> bool:
	return bool(owned_weapon_ids.get(weapon_id, false))

func get_weapon_by_id(weapon_id: StringName) -> WeaponBase:
	for weapon in weapons:
		if weapon.definition.weapon_id == weapon_id:
			return weapon
	return null

func get_slot_for_weapon(weapon_id: StringName) -> int:
	for slot_index in range(weapons.size()):
		if weapons[slot_index].definition.weapon_id == weapon_id:
			return slot_index
	return -1

func grant_weapon(
	weapon_id: StringName,
	ammo_amount: int = 0,
	auto_equip: bool = false
) -> bool:
	var weapon := get_weapon_by_id(weapon_id)
	if weapon == null:
		if not warned_unknown_weapon_ids.has(weapon_id):
			warned_unknown_weapon_ids[weapon_id] = true
			push_warning("Unknown weapon pickup: %s" % weapon_id)
		return false
	var newly_owned := not owns_weapon(weapon_id)
	if newly_owned:
		owned_weapon_ids[weapon_id] = true
	var added_ammo := add_ammo(weapon_id, ammo_amount)
	var changed := newly_owned or added_ammo > 0
	if newly_owned:
		equipment_status_changed.emit()
	if changed and auto_equip:
		equip_slot(get_slot_for_weapon(weapon_id))
	return changed

func add_ammo(weapon_id: StringName, amount: int) -> int:
	if not owns_weapon(weapon_id) or amount <= 0:
		return 0
	var weapon := get_weapon_by_id(weapon_id) as RangedWeapon
	return weapon.add_ammo(amount) if weapon != null else 0

func get_ammo_count(weapon_id: StringName) -> int:
	var weapon := get_weapon_by_id(weapon_id) as RangedWeapon
	return weapon.get_ammo_count() if weapon != null else 0

func _first_owned_slot() -> int:
	for slot_index in range(weapons.size()):
		if owns_weapon(weapons[slot_index].definition.weapon_id):
			return slot_index
	return -1

func _on_weapon_ammo_changed(_current: int, _maximum: int) -> void:
	equipment_status_changed.emit()
```

成功切换后，在 `weapon_changed.emit(...)` 后追加 `equipment_status_changed.emit()`。

- [ ] **Step 3: 配置基础 Player 并提供拾取入口**

在 `Player.tscn` 设置：

```ini
starting_owned_weapon_ids = Array[StringName]([&"pistol", &"knife"])
starting_slot = 0
```

在 `player_controller.gd` 增加：

```gdscript
func receive_weapon_pickup(
	weapon_id: StringName,
	ammo_amount: int
) -> bool:
	if defeated:
		return false
	return equipment.grant_weapon(weapon_id, ammo_amount, true)

func receive_ammo_pickup(
	weapon_id: StringName,
	ammo_amount: int
) -> bool:
	if defeated:
		return false
	return equipment.add_ammo(weapon_id, ammo_amount) > 0
```

- [ ] **Step 4: 新建显式步枪测试工厂并迁移旧测试**

创建 `tests/helpers/player_test_factory.gd`：

```gdscript
extends RefCounted
class_name PlayerTestFactory

const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")

static func add_player_with_rifle(
	tree: SceneTree,
	rifle_ammo: int = 360
) -> PlayerController:
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var equipment := player.get_node("EquipmentController") as EquipmentController
	equipment.starting_owned_weapon_ids = [&"pistol", &"rifle", &"knife"]
	equipment.starting_slot = 1
	tree.root.add_child(player)
	equipment.add_ammo(&"rifle", rifle_ammo)
	return player
```

在下列文件中，把依赖“开局步枪”的玩家创建替换为 `PlayerTestFactory.add_player_with_rifle(tree)`：

- `tests/unit/test_weapon_ammo.gd`
- `tests/unit/test_weapon_feedback.gd`
- `tests/unit/test_weapon_penetration.gd`
- `tests/unit/test_tracer_pool.gd`
- `tests/unit/test_weapon_clearance_controller.gd`
- `tests/integration/test_weapon_wall_clearance.gd`

专门验证未拥有步枪的测试继续直接实例化基础 `Player.tscn`。

`test_weapon_loadout.gd` 内部自行创建的 `EquipmentController` 若要验证步枪墙体避让或步枪切换，必须在调用 `setup()` 前显式设置：

```gdscript
equipment.starting_owned_weapon_ids = [&"pistol", &"rifle", &"knife"]
equipment.starting_slot = 1
```

这样内部子用例不会因为新的基础拥有列表而误测成“未拥有武器”。

- [ ] **Step 5: 运行拥有状态与枪械回归测试**

```bash
./tests/run_tests.sh \
  res://tests/unit/test_weapon_loadout.gd \
  res://tests/unit/test_weapon_ammo.gd \
  res://tests/unit/test_weapon_feedback.gd \
  res://tests/unit/test_weapon_penetration.gd \
  res://tests/unit/test_tracer_pool.gd \
  res://tests/unit/test_weapon_clearance_controller.gd \
  res://tests/integration/test_weapon_wall_clearance.gd
```

Expected: PASS；基础玩家为手枪开局，旧测试显式获得步枪。

- [ ] **Step 6: 提交 Task 1**

```bash
git add scripts/player/equipment_controller.gd scripts/player/player_controller.gd \
  scenes/player/Player.tscn tests/helpers/player_test_factory.gd \
  tests/unit/test_weapon_loadout.gd tests/unit/test_weapon_ammo.gd \
  tests/unit/test_weapon_feedback.gd tests/unit/test_weapon_penetration.gd \
  tests/unit/test_tracer_pool.gd tests/unit/test_weapon_clearance_controller.gd \
  tests/integration/test_weapon_wall_clearance.gd
git commit -m "feat: add weapon ownership and demo loadout"
```

---

### Task 2: 配置 Demo 出生步枪 30 发

**Files:**
- Modify: `scripts/gameplay/demo_arena.gd:43-55`
- Modify: `tests/integration/test_demo_scene.gd`

**Interfaces:**
- Consumes: `EquipmentController.grant_weapon(&"rifle", 30, true) -> bool`。
- Produces: Demo 玩家出生时 `owns_weapon(&"rifle") == true`、当前槽为 1、弹药为 30。

- [ ] **Step 1: 写入 Demo 失败测试**

在 `test_demo_scene.gd` 增加：

```gdscript
_append(failures, Assertions.expect_true(
	equipment != null and
		equipment.owns_weapon(&"rifle") and
		equipment.get_current_definition().weapon_id == &"rifle" and
		equipment.get_ammo_count(&"rifle") == 30,
	"Demo starts with an owned rifle and 30 rounds"
))
```

运行：

```bash
./tests/run_tests.sh res://tests/integration/test_demo_scene.gd
```

Expected: FAIL；Demo 随基础玩家改成手枪开局，尚未获得步枪。

- [ ] **Step 2: 实现幂等 Demo 配置**

在 `_ready()` 第一行调用 `_configure_demo_player_loadout()`，并实现：

```gdscript
func _configure_demo_player_loadout() -> void:
	var player := get_node_or_null("Player") as PlayerController
	if player == null or player.equipment == null:
		return
	if player.equipment.owns_weapon(&"rifle"):
		return
	player.equipment.grant_weapon(&"rifle", 30, true)
```

父节点 `_ready()` 在 Player 子节点完成 `equipment.setup()` 后执行，因此无需延迟调用。

- [ ] **Step 3: 运行 Demo 与全量测试**

```bash
./tests/run_tests.sh res://tests/integration/test_demo_scene.gd
./tests/run_tests.sh
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
```

Expected: 全部 PASS，Godot 检查退出码 0。

- [ ] **Step 4: 提交并压缩为单一计划提交**

```bash
git add scripts/gameplay/demo_arena.gd tests/integration/test_demo_scene.gd
git commit -m "fixup! feat: add weapon ownership and demo loadout"
GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash HEAD~2
git log -1 --oneline
```

Expected: 只保留一个 `feat: add weapon ownership and demo loadout` 提交。
