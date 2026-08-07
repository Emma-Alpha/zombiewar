# 玩家当前装备标签 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 复用最新 `PlayerEquipmentLabel`，按当前装备显示玩家编号、中文装备名和弹药/库存，并缩小现有过大的头顶文字。

**Architecture:** 每个 `EquipmentItem` 提供自己的稳定计数文本；`EquipmentController` 把当前装备名称和计数文本通过现有 `equipment_changed` 信号发送给 `PlayerController`。标签只负责格式化 `P编号 · 装备名:数量`，不读取武器或库存内部状态。

**Tech Stack:** Godot 4.7.1、GDScript、Label3D、现有 NotoSansSC UI 字体。

## Global Constraints

- 前置计划 `2026-08-07-weapon-ammo-core.md` 和 `2026-08-07-equipment-ownership-inventory.md` 必须完成。
- 只显示当前装备，不再显示旧设计中的“武器 | 特殊道具”双栏。
- 手枪显示 `P1 · 手枪:∞`。
- 步枪显示实际弹药，例如 `P1 · 步枪:30`。
- 匕首显示 `P1 · 匕首:—`。
- 油桶显示当前库存，例如 `P1 · 油桶:30`。
- 玩家倒地继续显示 `P1 · 倒地`，不追加冒号。
- 保留每名本地玩家自己的 `P1` 至 `P4` 编号。
- 标签使用现有 `PlayerEquipmentLabel`，不把文字重新塞入 `HealthBar3D`。
- 字号从 30 调整为 22，描边从 10 调整为 7；后续只允许基于实际截图小幅调整位置或字号。
- 当前仓库没有持久化自动测试套件；视觉结果采用人工验收。
- 本计划最终只保留一个提交：`feat: refine player equipment label`。

---

### Task 1: 建立装备计数文本契约并优化 Label3D

**Files:**
- Modify: `scripts/player/equipment_item.gd:19-39`
- Modify: `scripts/combat/weapons/ranged_weapon.gd`
- Modify: `scripts/player/placeable_equipment.gd:40-53`
- Modify: `scripts/player/equipment_controller.gd:20-190`
- Modify: `scripts/player/player_controller.gd:71-350`
- Modify: `scripts/ui/player_equipment_label.gd:1-7`
- Modify: `scenes/ui/PlayerEquipmentLabel.tscn:6-16`
- Modify: `resources/weapons/pistol.tres:7-9`
- Modify: `resources/weapons/rifle.tres:7-9`
- Modify: `resources/weapons/knife.tres:7-9`

**Interfaces:**
- Consumes: `RangedWeapon.get_ammo_count() -> int`、`RangedWeaponDefinition.uses_ammo`、`PlaceableEquipment.get_remaining_count() -> int`。
- Produces: `EquipmentItem.get_count_text() -> String`、`EquipmentController.equipment_changed(display_name: String, count_text: String)`、`PlayerEquipmentLabel.set_status(player_index: int, display_name: String, count_text: String)`。

- [ ] **Step 1: 为 EquipmentItem 定义默认计数文本**

在 `equipment_item.gd` 增加：

```gdscript
func get_count_text() -> String:
	return "—"
```

该默认值适用于匕首等没有库存概念的装备。

- [ ] **Step 2: 为远程武器和油桶覆盖计数文本**

在 `ranged_weapon.gd` 增加：

```gdscript
func get_count_text() -> String:
	return str(get_ammo_count()) if _uses_ammo() else "∞"
```

在 `placeable_equipment.gd` 增加：

```gdscript
func get_count_text() -> String:
	return str(get_remaining_count())
```

不得通过 `remaining_count == -1` 推断无限弹药；手枪是否无限必须来自 `RangedWeaponDefinition.uses_ammo`。

- [ ] **Step 3: 把 EquipmentController 状态信号改为传递文本**

修改信号：

```gdscript
signal equipment_changed(display_name: String, count_text: String)
```

用以下接口替换 `get_current_count()` 的 HUD 用途：

```gdscript
func get_current_count_text() -> String:
	return current_item.get_count_text() if current_item != null else ""
```

修改空装备与常规同步：

```gdscript
func _clear_current() -> void:
	if current_item != null:
		current_item.cancel_use()
		current_item.set_equipped(false)
	current_item = null
	current_slot = -1
	equipment_changed.emit("无可用装备", "")

func _emit_equipment_changed() -> void:
	equipment_changed.emit(
		get_current_display_name(),
		get_current_count_text()
	)
```

保留现有 `get_current_count() -> int` 作为非 HUD 的兼容查询接口，但本计划完成后标签链路不得再调用它。

- [ ] **Step 4: 更新 PlayerController 的标签桥接**

把 `_ready()` 中初始同步改为：

```gdscript
_on_equipment_changed(
	equipment.get_current_display_name(),
	equipment.get_current_count_text()
)
```

修改处理函数：

```gdscript
func _on_equipment_changed(display_name: String, count_text: String) -> void:
	if equipment_label != null:
		equipment_label.set_status(player_index, display_name, count_text)
```

倒地状态改为：

```gdscript
equipment_label.set_status(player_index, "倒地", "")
```

- [ ] **Step 5: 更新标签格式和视觉尺寸**

把 `player_equipment_label.gd` 改为：

```gdscript
extends Label3D
class_name PlayerEquipmentLabel

func set_status(
	player_index: int,
	display_name: String,
	count_text: String
) -> void:
	text = "P%d · %s" % [player_index + 1, display_name]
	if not count_text.is_empty():
		text += ":%s" % count_text
```

更新 `PlayerEquipmentLabel.tscn`：

```ini
position = Vector3(0, 2.72, 0)
font_size = 22
outline_size = 7
text = "P1 · 手枪:∞"
```

保留 `billboard = 1`、`no_depth_test = true` 和 `fixed_size = true`。

- [ ] **Step 6: 把武器显示名改为中文**

资源值：

```ini
# resources/weapons/pistol.tres
display_name = "手枪"

# resources/weapons/rifle.tres
display_name = "步枪"

# resources/weapons/knife.tres
display_name = "匕首"
```

`weapon_id` 和 `visual_node_name` 保持英文，不得为了显示文案改变运行时身份或模型节点名称。

- [ ] **Step 7: 运行 Godot 检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
git diff --check
rg -n "equipment_changed|set_status\(" scripts scenes
```

Expected: 所有信号连接和 `set_status()` 调用都使用 `String count_text`；Godot 没有脚本解析或场景资源错误。

- [ ] **Step 8: 人工检查单人和四人标签**

1. 单人进入 Demo，确认初始文字为 `P1 · 手枪:∞`。
2. 切换匕首，确认显示 `P1 · 匕首:—`。
3. 本地多人创建 4 名玩家，确认标签分别使用 P1、P2、P3、P4。
4. 确认字号明显小于旧版，不遮住血条，也不在玩家靠近时完全重叠。
5. 玩家倒地后确认显示 `P编号 · 倒地`。

- [ ] **Step 9: 提交本计划**

```bash
git add \
  scripts/player/equipment_item.gd \
  scripts/combat/weapons/ranged_weapon.gd \
  scripts/player/placeable_equipment.gd \
  scripts/player/equipment_controller.gd \
  scripts/player/player_controller.gd \
  scripts/ui/player_equipment_label.gd \
  scenes/ui/PlayerEquipmentLabel.tscn \
  resources/weapons/pistol.tres \
  resources/weapons/rifle.tres \
  resources/weapons/knife.tres
git commit -m "feat: refine player equipment label"
```

Expected: 本计划只有一个提交，不包含拾取箱或 Demo 刷新逻辑。
