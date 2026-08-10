# 补给箱字体与模型缩小实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 统一缩小固定补给与随机掉落使用的箱体模型和悬浮文字，同时保持原有拾取范围与发光标记可见性。

**Architecture:** 修改所有拾取物共同实例化的 `PickupChest.tscn`，并同步修正 `PlayerEquipmentLabel.tscn` 的同类 Label3D 缩放问题。3D 文字使用高字体分辨率和较小 `pixel_size` 控制世界尺寸；`ClaimArea`、发光圆环和信标保持原配置。

**Tech Stack:** Godot 4.7.1、`.tscn` 场景资源、`Label3D`、3D 碰撞形状。

## Global Constraints

- `Chest.gltf` 可视模型缩放为 `Vector3(0.75, 0.75, 0.75)`。
- 箱体实体碰撞从 `Vector3(0.64, 0.41, 0.48)` 缩放为 `Vector3(0.48, 0.3075, 0.36)`，中心高度从 `0.205` 调整为 `0.15375`。
- 补给悬浮文字使用 `font_size = 64`、`pixel_size = 0.005`、`outline_size = 6`、`fixed_size = false`，高度为 `1.25`。
- 玩家装备文字使用 `font_size = 64`、`pixel_size = 0.006`、`outline_size = 6`、`fixed_size = false`。
- 不缩放 `ClaimArea`、`MarkerRing` 或 `MarkerBeacon`。
- 不修改奖励 Definition、三秒刷新、一次性回收、多人归属和导航通知逻辑。
- 当前主工作区含其他未提交改动，只做目标场景的小范围修改，不回退或覆盖其他文件。

---

### Task 1：统一缩小 PickupChest 视觉与文字

**Files:**
- Modify: `scenes/gameplay/PickupChest.tscn`
- Modify: `scenes/ui/PlayerEquipmentLabel.tscn`
- Verify: `tools/validation/validate_pickup_spawn_point.gd`
- Verify: `tools/validation/validate_random_pickup_drops.gd`

**Interfaces:**
- Consumes: `PickupSpawnPoint` 统一实例化的 `res://scenes/gameplay/PickupChest.tscn`。
- Produces: 更紧凑的通用箱体视觉、匹配模型的实体碰撞和较小的奖励悬浮文字。

- [ ] **Step 1：修改基础场景数值**

在 `PickupChest.tscn` 中应用以下精确配置：

```ini
[sub_resource type="BoxShape3D" id="BoxShape3D_chest"]
size = Vector3(0.48, 0.3075, 0.36)

[node name="Visual" parent="." instance=ExtResource("2_chest")]
scale = Vector3(0.75, 0.75, 0.75)

[node name="CollisionShape3D" type="CollisionShape3D" parent="."]
position = Vector3(0, 0.15375, 0)

[node name="RewardLabel" type="Label3D" parent="."]
position = Vector3(0, 1.25, 0)
font_size = 64
outline_size = 6
pixel_size = 0.005
fixed_size = false
```

在 `PlayerEquipmentLabel.tscn` 中使用 `font_size = 64`、`outline_size = 6`、`pixel_size = 0.006`、`fixed_size = false`。

- [ ] **Step 2：检查不应变化的交互配置**

确认 `ClaimArea` 仍使用 `radius = 1.15`、`height = 1.8`，`MarkerRing` 与 `MarkerBeacon` 的网格尺寸和位置未修改。

- [ ] **Step 3：运行生命周期回归验证**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_spawn_point.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_random_pickup_drops.gd
```

预期两个验证均输出 `PASS` 且退出码为 `0`。

- [ ] **Step 4：运行场景导入与 diff 检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
git diff --check
```

预期无新增场景解析错误或空白错误。

- [ ] **Step 5：人工验收要点**

启动 Demo，确认固定补给和僵尸掉落的箱体都缩小约四分之一，悬浮文字更小且未压住箱体；玩家仍可在原拾取距离内领取。
