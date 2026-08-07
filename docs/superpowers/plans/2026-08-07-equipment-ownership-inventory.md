# 装备拥有状态与油桶库存 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让统一装备栏中的装备实例自行管理可用状态，使每名玩家默认只有手枪和匕首，步枪与油桶必须由该玩家单独拾取获得。

**Architecture:** `Player.tscn` 继续预实例化手枪、步枪、匕首和油桶，以保留固定槽位与视觉绑定；是否可切换由各 `EquipmentItem.is_available()` 决定。`WeaponBase` 保存该玩家是否拥有武器，`RangedWeapon` 复用前置计划的弹药库存，`PlaceableEquipment` 保存油桶数量；`EquipmentController` 只按 `item_id` 查找和分发奖励。

**Tech Stack:** Godot 4.7.1、GDScript、现有统一装备栏、本地多人独立 Player 实例。

## Global Constraints

- 前置计划 `2026-08-07-weapon-ammo-core.md` 必须完成。
- 每名玩家独立保存装备拥有、步枪弹药和油桶数量；不得放入 `GameSession` 或团队共享状态。
- 默认拥有手枪和匕首，默认装备手枪。
- 步枪默认未拥有且为 0 发；油桶默认数量为 0。
- 步枪箱授予步枪并增加 60 发；油桶箱增加 30 个；具体箱子在后续计划实现。
- 油桶上限固定为 999。
- 未拥有的装备必须被 `equip_previous()`、`equip_next()` 和 `equip_slot()` 跳过或拒绝。
- 自动装备被现有墙体切换守卫拒绝时，已授予的武器和库存仍然保留。
- 玩家死亡后拒绝所有拾取奖励。
- 不动态增删装备槽位，不引入背包或团队共享库存。
- 本计划不改变油桶放置方向；若已执行 `2026-08-07-oil-barrel-rear-placement.md`，必须保留 `placement_direction_scale = -1.0`。
- 当前仓库没有持久化自动测试套件；不得恢复旧 `tests/`。
- 本计划最终只保留一个提交：`feat: add per-player equipment ownership`。

---

### Task 1: 扩展 EquipmentItem 能力并提供玩家拾取入口

**Files:**
- Modify: `scripts/player/equipment_item.gd:1-39`
- Modify: `scripts/combat/weapons/weapon_base.gd:16-86`
- Modify: `scripts/combat/weapons/ranged_weapon.gd`
- Modify: `scripts/player/placeable_equipment.gd:4-53`
- Modify: `scripts/player/equipment_controller.gd:4-214`
- Modify: `scripts/player/player_controller.gd:125-350`
- Modify: `scenes/weapons/Pistol.tscn:8-10`
- Modify: `scenes/weapons/Rifle.tscn:8-10`
- Modify: `scenes/weapons/Knife.tscn:6-8`
- Modify: `scenes/player/equipment/OilBarrelEquipment.tscn:6-10`
- Modify: `scenes/player/Player.tscn:72-75`

**Interfaces:**
- Consumes: `RangedWeapon.add_ammo(amount: int) -> int`、`EquipmentItem.is_available() -> bool`、`EquipmentController` 现有槽位切换守卫。
- Produces: `EquipmentItem.get_item_id() -> StringName`、`EquipmentItem.receive_pickup(amount: int) -> bool`、`WeaponBase.is_owned() -> bool`、`WeaponBase.set_owned(value: bool) -> bool`、`PlaceableEquipment.add_count(amount: int) -> int`、`EquipmentController.get_item_by_id(item_id: StringName) -> EquipmentItem`、`EquipmentController.get_slot_for_item(item_id: StringName) -> int`、`EquipmentController.grant_item(item_id: StringName, amount: int = 0, auto_equip: bool = false) -> bool`、`EquipmentController.add_ammo(item_id: StringName, amount: int) -> int`、`PlayerController.receive_equipment_pickup(item_id: StringName, amount: int, auto_equip: bool = false) -> bool`、`PlayerController.receive_ammo_pickup(item_id: StringName, amount: int) -> bool`。

- [ ] **Step 1: 为统一装备基类增加稳定身份与拾取契约**

在 `equipment_item.gd` 增加：

```gdscript
func get_item_id() -> StringName:
	return &""

func receive_pickup(_amount: int) -> bool:
	return false
```

`receive_pickup()` 返回“本次是否实际改变该装备实例状态”，后续箱子依赖该返回值决定是否被消耗。

- [ ] **Step 2: 让 WeaponBase 管理该玩家是否拥有武器**

在 `weapon_base.gd` 增加属性：

```gdscript
@export var initially_owned := false

var owned := false
```

在 `bind_context()` 开头初始化一次拥有状态：

```gdscript
owned = initially_owned
```

增加接口：

```gdscript
func get_item_id() -> StringName:
	return definition.weapon_id if definition != null else &""

func is_available() -> bool:
	return owned

func is_owned() -> bool:
	return owned

func set_owned(value: bool) -> bool:
	if owned == value:
		return false
	owned = value
	return true

func receive_pickup(_amount: int) -> bool:
	return set_owned(true)
```

不要通过 `visible` 判断拥有状态；可见性仍只代表当前是否装备。

- [ ] **Step 3: 让步枪拾取同时授予拥有状态与弹药**

在 `ranged_weapon.gd` 覆盖：

```gdscript
func receive_pickup(amount: int) -> bool:
	var ownership_changed := set_owned(true)
	var added_ammo := add_ammo(amount)
	return ownership_changed or added_ammo > 0
```

如果步枪已拥有且弹药已满，返回 `false`；如果首次获得步枪但传入 0 发，仍返回 `true`。

- [ ] **Step 4: 把油桶改为 0 起始、999 上限的可拾取装备**

在 `placeable_equipment.gd` 增加：

```gdscript
@export var item_id: StringName = &"oil_barrel"
@export_range(0, 999999, 1) var max_count := 999
```

保留现有 `initial_count`，并增加：

```gdscript
func get_item_id() -> StringName:
	return item_id

func add_count(amount: int) -> int:
	_ensure_count_initialized()
	if amount <= 0:
		return 0
	var before := remaining_count
	remaining_count = clampi(remaining_count + amount, 0, maxi(max_count, 0))
	if remaining_count != before:
		count_changed.emit(remaining_count)
	return remaining_count - before

func receive_pickup(amount: int) -> bool:
	return add_count(amount) > 0
```

把 `_ensure_count_initialized()` 改为同时遵守上限：

```gdscript
func _ensure_count_initialized() -> void:
	if remaining_count < 0:
		remaining_count = clampi(initial_count, 0, maxi(max_count, 0))
```

更新 `OilBarrelEquipment.tscn`：

```ini
item_id = &"oil_barrel"
initial_count = 0
max_count = 999
```

保留现有 `item_scene = ExtResource("2_barrel")`。若场景已包含后置放置配置，同时保留：

```ini
placement_direction_scale = -1.0
```

- [ ] **Step 5: 在 EquipmentController 中按 item_id 分发奖励**

增加预加载和一次性告警状态：

```gdscript
const RangedWeaponScript = preload("res://scripts/combat/weapons/ranged_weapon.gd")

var warned_unknown_item_ids: Dictionary = {}
```

增加接口：

```gdscript
func get_item_by_id(item_id: StringName) -> EquipmentItem:
	for item in equipment_items:
		if item.get_item_id() == item_id:
			return item as EquipmentItem
	return null

func get_slot_for_item(item_id: StringName) -> int:
	for slot_index in range(equipment_items.size()):
		if equipment_items[slot_index].get_item_id() == item_id:
			return slot_index
	return -1

func grant_item(
	item_id: StringName,
	amount: int = 0,
	auto_equip: bool = false
) -> bool:
	var item = get_item_by_id(item_id)
	if item == null:
		if not warned_unknown_item_ids.has(item_id):
			warned_unknown_item_ids[item_id] = true
			push_warning("Unknown equipment pickup: %s" % item_id)
		return false
	var changed := bool(item.receive_pickup(amount))
	if changed and auto_equip:
		equip_slot(get_slot_for_item(item_id))
	return changed

func add_ammo(item_id: StringName, amount: int) -> int:
	var item = get_item_by_id(item_id)
	if item == null or not item.is_available() or not item is RangedWeaponScript:
		return 0
	return (item as RangedWeapon).add_ammo(amount)
```

保持现有 `_find_available_slot()` 和 `equip_slot()` 结构；它们已经通过 `is_available()` 跳过不可用装备。

- [ ] **Step 6: 配置默认拥有手枪与匕首**

武器场景设置：

```ini
# scenes/weapons/Pistol.tscn
initially_owned = true

# scenes/weapons/Rifle.tscn
initially_owned = false

# scenes/weapons/Knife.tscn
initially_owned = true
```

把 `Player.tscn` 的起始槽改为：

```ini
starting_slot = 0
```

保留四个 `loadout` 场景实例；不得从数组删除步枪或油桶，否则固定切换顺序和后续授予接口会失效。

- [ ] **Step 7: 为玩家实例增加死亡守卫后的拾取入口**

在 `player_controller.gd` 增加：

```gdscript
func receive_equipment_pickup(
	item_id: StringName,
	amount: int,
	auto_equip: bool = false
) -> bool:
	if defeated:
		return false
	return equipment.grant_item(item_id, amount, auto_equip)

func receive_ammo_pickup(item_id: StringName, amount: int) -> bool:
	if defeated:
		return false
	return equipment.add_ammo(item_id, amount) > 0
```

接口只修改当前 `PlayerController` 的 `equipment`，不得遍历 `PlayerRegistry` 或 `DemoArena.players`。

- [ ] **Step 8: 运行解析检查并人工确认默认装备循环**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
git diff --check
```

人工 Smoke Test：

1. 启动单人 Demo。
2. 出生时应装备手枪。
3. 连续切换装备，只能在手枪与匕首之间循环。
4. 步枪和油桶不可被切换到。
5. 启动本地多人，确认每名玩家都独立执行同样的默认循环。

- [ ] **Step 9: 提交本计划**

```bash
git add \
  scripts/player/equipment_item.gd \
  scripts/combat/weapons/weapon_base.gd \
  scripts/combat/weapons/ranged_weapon.gd \
  scripts/player/placeable_equipment.gd \
  scripts/player/equipment_controller.gd \
  scripts/player/player_controller.gd \
  scenes/weapons/Pistol.tscn \
  scenes/weapons/Rifle.tscn \
  scenes/weapons/Knife.tscn \
  scenes/player/equipment/OilBarrelEquipment.tscn \
  scenes/player/Player.tscn
git commit -m "feat: add per-player equipment ownership"
```

Expected: 本计划只有一个提交；不包含 Demo 拾取箱、刷新逻辑或 HUD 样式改动。
