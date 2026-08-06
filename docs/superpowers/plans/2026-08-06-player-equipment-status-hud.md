# 人物武器与特殊道具状态条 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有人物头顶血条下方显示当前武器、弹药和特殊道具数量，并在切换、射击、补弹和使用油桶时即时更新。

**Architecture:** `HealthBar3D` 只负责稳定格式和 `Label3D` 渲染，`EquipmentController` 提供当前弹药显示文本，`PlayerController` 汇总装备状态与外部特殊道具状态。Demo 继续监听 `PlaceItemController.item_count_changed`，并把油桶状态传给玩家。

**Tech Stack:** Godot 4.7.1、GDScript、Label3D、现有 NotoSansSC 字体、自定义测试框架。

## Global Constraints

- 前置计划：`2026-08-06-weapon-ammo-core.md` 和 `2026-08-06-weapon-ownership-demo-loadout.md` 必须完成。
- 固定格式：`武器名:弹药显示 | 特殊道具名:数量`。
- 手枪显示 `手枪:∞`；步枪显示实际数量；匕首显示 `匕首:—`。
- 没有特殊道具数据时显示 `特殊道具:—`，不能隐藏整行。
- Demo 初始显示必须为 `步枪:30 | 油桶:999`。
- 使用 `assets/fonts/NotoSansSC-UI.ttf`；状态行跟随现有 HealthBar 根节点摄像机平面，不单独 billboard。
- 不修改血条已有填充、颜色、无深度测试和摄像机对齐契约。
- 本计划最终只保留一个提交：`feat: show equipment status over player`。

---

### Task 1: 为 HealthBar3D 增加状态文字

**Files:**
- Modify: `resources/weapons/pistol.tres`
- Modify: `resources/weapons/rifle.tres`
- Modify: `resources/weapons/knife.tres`
- Modify: `scripts/ui/health_bar_3d.gd:1-79`
- Modify: `scenes/ui/HealthBar3D.tscn:1-64`
- Modify: `tests/unit/test_health_bar_3d.gd`

**Interfaces:**
- Consumes: 现有 `HealthBar3D` 跟随和摄像机对齐逻辑。
- Produces: `HealthBar3D.format_status(weapon_name, ammo_text, item_name, item_count) -> String`、`set_status(...) -> void`、`StatusLabel: Label3D`。

- [ ] **Step 1: 编写状态格式与节点失败测试**

在 `test_health_bar_3d.gd` 中用以下内容替换旧的“没有 Label”断言：

```gdscript
var status_label := health_bar.get_node_or_null("StatusLabel") as Label3D
_append(failures, Assertions.expect_true(
	status_label != null,
	"Health bar owns an equipment status label"
))
_append(failures, Assertions.expect_equal(
	HealthBar3D.format_status("步枪", "30", "油桶", 999),
	"步枪:30 | 油桶:999",
	"Health bar formats finite rifle ammo"
))
_append(failures, Assertions.expect_equal(
	HealthBar3D.format_status("手枪", "∞", "油桶", 999),
	"手枪:∞ | 油桶:999",
	"Health bar formats infinite pistol ammo"
))
_append(failures, Assertions.expect_equal(
	HealthBar3D.format_status("匕首", "—", "特殊道具", -1),
	"匕首:— | 特殊道具:—",
	"Health bar formats melee and missing item placeholders"
))
health_bar.set_status("步枪", "29", "油桶", 998)
_append(failures, Assertions.expect_equal(
	status_label.text,
	"步枪:29 | 油桶:998",
	"Health bar applies live status text"
))
```

运行：

```bash
./tests/run_tests.sh res://tests/unit/test_health_bar_3d.gd
```

Expected: FAIL，原因是 `StatusLabel`、`format_status` 或 `set_status` 缺失。

- [ ] **Step 2: 设置中文武器显示名**

```ini
# resources/weapons/pistol.tres
display_name = "手枪"

# resources/weapons/rifle.tres
display_name = "步枪"

# resources/weapons/knife.tres
display_name = "匕首"
```

- [ ] **Step 3: 在场景增加状态行**

增加字体资源并递增 `load_steps`：

```ini
[ext_resource type="FontFile" path="res://assets/fonts/NotoSansSC-UI.ttf" id="2_cjk_font"]
```

在 `Fill` 后增加：

```ini
[node name="StatusLabel" type="Label3D" parent="."]
position = Vector3(0, -0.16, 0)
font = ExtResource("2_cjk_font")
font_size = 32
outline_size = 8
modulate = Color(1, 0.96, 0.82, 1)
outline_modulate = Color(0.02, 0.025, 0.03, 0.95)
text = "手枪:∞ | 特殊道具:—"
horizontal_alignment = 1
no_depth_test = true
fixed_size = true
pixel_size = 0.0032
```

- [ ] **Step 4: 实现格式与写入接口**

在 `health_bar_3d.gd` 增加：

```gdscript
@onready var status_label: Label3D = $StatusLabel

func set_status(
	weapon_name: String,
	ammo_text: String,
	item_name: String,
	item_count: int
) -> void:
	status_label.text = format_status(
		weapon_name, ammo_text, item_name, item_count
	)

static func format_status(
	weapon_name: String,
	ammo_text: String,
	item_name: String,
	item_count: int
) -> String:
	var safe_weapon := weapon_name if not weapon_name.is_empty() else "武器"
	var safe_ammo := ammo_text if not ammo_text.is_empty() else "—"
	var safe_item := item_name if not item_name.is_empty() else "特殊道具"
	var count_text := str(item_count) if item_count >= 0 else "—"
	return "%s:%s | %s:%s" % [safe_weapon, safe_ammo, safe_item, count_text]
```

- [ ] **Step 5: 运行测试并提交 Task 1**

```bash
./tests/run_tests.sh res://tests/unit/test_health_bar_3d.gd
git add resources/weapons/pistol.tres resources/weapons/rifle.tres \
  resources/weapons/knife.tres scripts/ui/health_bar_3d.gd \
  scenes/ui/HealthBar3D.tscn tests/unit/test_health_bar_3d.gd
git commit -m "feat: show equipment status over player"
```

Expected: 测试 PASS；提交不改变现有血条几何和 shader。

---

### Task 2: 同步装备弹药与油桶状态

**Files:**
- Modify: `scripts/player/equipment_controller.gd`
- Modify: `scripts/player/player_controller.gd`
- Modify: `scripts/gameplay/demo_arena.gd:316-337`
- Modify: `tests/unit/test_weapon_loadout.gd`
- Modify: `tests/integration/test_demo_scene.gd`

**Interfaces:**
- Consumes: `equipment_status_changed`、`RangedWeapon.get_ammo_count()`、`PlaceItemController.item_count_changed(display_name, remaining_count)`。
- Produces: `EquipmentController.get_current_ammo_display() -> String`、`PlayerController.set_special_item_status(display_name, remaining_count) -> void`。

- [ ] **Step 1: 编写装备显示与 Demo 失败测试**

在 `test_weapon_loadout.gd` 增加：

```gdscript
_append(failures, Assertions.expect_equal(
	equipment.get_current_ammo_display(), "∞",
	"Pistol exposes infinite ammo display"
))
equipment.grant_weapon(&"rifle", 60, true)
_append(failures, Assertions.expect_equal(
	equipment.get_current_ammo_display(), "60",
	"Rifle exposes finite ammo display"
))
equipment.equip_slot(2)
_append(failures, Assertions.expect_equal(
	equipment.get_current_ammo_display(), "—",
	"Knife exposes a non-ammo placeholder"
))
```

在 `test_demo_scene.gd` 取得 `Player/HealthBar3D/StatusLabel` 并断言：

```gdscript
_append(failures, Assertions.expect_equal(
	status_label.text if status_label != null else "",
	"步枪:30 | 油桶:999",
	"Demo status combines initial rifle ammo and barrel inventory"
))
```

运行：

```bash
./tests/run_tests.sh \
  res://tests/unit/test_weapon_loadout.gd \
  res://tests/integration/test_demo_scene.gd
```

Expected: FAIL，原因是弹药显示接口或油桶桥接缺失。

- [ ] **Step 2: 实现当前弹药显示**

在 `equipment_controller.gd` 增加：

```gdscript
func get_current_ammo_display() -> String:
	if current_weapon == null or not current_weapon is RangedWeapon:
		return "—"
	var ranged_weapon := current_weapon as RangedWeapon
	var ranged_definition := ranged_weapon.definition as RangedWeaponDefinition
	return str(ranged_weapon.get_ammo_count()) if ranged_definition.uses_ammo else "∞"
```

- [ ] **Step 3: 在 PlayerController 汇总状态**

增加：

```gdscript
var special_item_name := "特殊道具"
var special_item_count := -1
```

在 `_ready()` 中连接 `equipment.equipment_status_changed`，在 `equipment.setup(...)` 后调用 `_sync_equipment_status()`：

```gdscript
equipment.equipment_status_changed.connect(_on_equipment_status_changed)
```

实现：

```gdscript
func set_special_item_status(
	display_name: String,
	remaining_count: int
) -> void:
	special_item_name = display_name if not display_name.is_empty() else "特殊道具"
	special_item_count = remaining_count
	_sync_equipment_status()

func _on_equipment_status_changed() -> void:
	_sync_equipment_status()

func _sync_equipment_status() -> void:
	if health_bar == null or equipment == null:
		return
	var definition := equipment.get_current_definition()
	var weapon_name := definition.display_name if definition != null else "武器"
	health_bar.set_status(
		weapon_name,
		equipment.get_current_ammo_display(),
		special_item_name,
		special_item_count
	)
```

在 `_on_weapon_changed()` 末尾也调用 `_sync_equipment_status()`。

- [ ] **Step 4: 桥接 Demo 油桶数量**

在 `demo_arena.gd::_on_place_item_count_changed()` 开头增加：

```gdscript
var player := get_node_or_null("Player") as PlayerController
if player != null:
	player.set_special_item_status(display_name, remaining_count)
```

保留原移动端和桌面帮助文本更新逻辑。

- [ ] **Step 5: 运行全量测试、人工检查并压缩提交**

```bash
./tests/run_tests.sh
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

人工确认步枪、手枪、匕首和放置一个油桶后的文字分别正确且不与血条重叠。若需视觉微调，只改变 `StatusLabel.position` 或 `pixel_size`，再重跑 `test_health_bar_3d.gd` 和 `test_demo_scene.gd`。

提交并压缩：

```bash
git add scripts/player/equipment_controller.gd scripts/player/player_controller.gd \
  scripts/gameplay/demo_arena.gd tests/unit/test_weapon_loadout.gd \
  tests/integration/test_demo_scene.gd
git commit -m "fixup! feat: show equipment status over player"
GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash HEAD~2
git log -1 --oneline
```

Expected: 全量测试 PASS、Godot 检查退出码 0，只保留一个 `feat: show equipment status over player` 提交。
