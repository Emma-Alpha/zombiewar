# 油桶身后放置 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 仅让油桶装备沿玩家瞄准方向的反方向放置，其他可放置装备继续默认向前放置。

**Architecture:** 在通用 `PlaceableEquipment` 上增加场景可配置的放置方向倍率，默认保持 `1.0`。油桶场景显式配置为 `-1.0`，装备在调用现有 `PlaceItemService` 前转换方向，不改动网格选格、障碍检测、库存和导航更新逻辑。

**Tech Stack:** Godot 4.7.1、GDScript、Godot headless 验证脚本

## Global Constraints

- 仅油桶装备放置在玩家身后，其他可放置装备默认仍放在前方。
- 油桶身后目标格被占用或存在动态障碍时，沿用现有拒绝逻辑，不尝试其他格子。
- 放置失败时不扣减油桶数量。
- 使用现有 `PlaceItemService.request_place_item(requester, origin, direction, item_scene)` 接口，不修改网格和导航行为。
- GDScript 使用 tab 缩进，文件和变量使用 `snake_case`。

---

### Task 1: 为油桶配置反向放置方向

**Files:**
- Modify: `scripts/player/placeable_equipment.gd`
- Modify: `scenes/player/equipment/OilBarrelEquipment.tscn`
- Modify: `tools/validation/support/fake_place_item_service.gd`
- Modify: `tools/validation/validate_equipment_cycle.gd`

**Interfaces:**
- Consumes: `PlaceItemService.request_place_item(requester: CollisionObject3D, origin: Vector3, direction: Vector3, item_scene: PackedScene = null) -> bool`
- Produces: `PlaceableEquipment.placement_direction_scale: float`，默认值为 `1.0`；传给放置服务的方向为 `aim * placement_direction_scale`

- [ ] **Step 1: 扩展测试替身以记录最近一次放置方向**

在 `tools/validation/support/fake_place_item_service.gd` 增加记录字段，并在请求方法中保存实际方向：

```gdscript
var last_direction := Vector3.ZERO

func request_place_item(
	_requester: CollisionObject3D,
	_origin: Vector3,
	direction: Vector3,
	_item_scene: PackedScene = null
) -> bool:
	request_count += 1
	last_direction = direction
	return next_result
```

- [ ] **Step 2: 写入默认向前与油桶反向放置的失败验证**

在 `tools/validation/validate_equipment_cycle.gd` 的 `_init()` 中调用新测试 `_test_placeable_direction_configuration(failures)`，并新增：

```gdscript
func _test_placeable_direction_configuration(failures: Array[String]) -> void:
	var service := FakePlaceItemService.new()
	var placeable := PlaceableEquipment.new()
	placeable.initial_count = 2
	placeable.item_scene = _build_node_scene()
	placeable.set_place_item_service(service)
	placeable.set_use_input(false, true, Vector3(0.6, 0.0, -0.8))
	_expect(
		service.last_direction.is_equal_approx(Vector3(0.6, 0.0, -0.8)),
		"placeable equipment must preserve aim direction by default",
		failures
	)
	placeable.placement_direction_scale = -1.0
	placeable.set_use_input(false, true, Vector3(0.6, 0.0, -0.8))
	_expect(
		service.last_direction.is_equal_approx(Vector3(-0.6, 0.0, 0.8)),
		"rear-placement equipment must reverse aim direction",
		failures
	)
	placeable.free()
	service.free()
```

- [ ] **Step 3: 运行验证并确认因缺少配置属性而失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
```

Expected: FAIL，错误指出 `PlaceableEquipment` 不存在 `placement_direction_scale` 属性；不能因为脚本解析或测试搭建错误而失败。

- [ ] **Step 4: 在通用装备中实现可配置方向倍率**

在 `scripts/player/placeable_equipment.gd` 的导出配置中增加：

```gdscript
@export var placement_direction_scale := 1.0
```

将放置请求中的方向参数由 `aim` 改为：

```gdscript
aim * placement_direction_scale
```

保留现有原点选择、放置成功后扣减数量和失败不扣数量的逻辑。

- [ ] **Step 5: 仅为油桶启用反向放置**

在 `scenes/player/equipment/OilBarrelEquipment.tscn` 的根节点配置中加入：

```ini
placement_direction_scale = -1.0
```

不要修改 `PlaceItemService`、`PlaceItemGrid` 或其他装备场景。

- [ ] **Step 6: 运行聚焦验证并确认通过**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
```

Expected: 输出 `validate_equipment_cycle: PASS`，退出码为 `0`。

- [ ] **Step 7: 运行 Godot headless 导入与解析检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 退出码为 `0`，没有新增的场景或脚本解析错误。

- [ ] **Step 8: 提交实现**

```bash
git add scripts/player/placeable_equipment.gd scenes/player/equipment/OilBarrelEquipment.tscn tools/validation/support/fake_place_item_service.gd tools/validation/validate_equipment_cycle.gd
git commit -m "fix: place oil barrel behind player"
```

- [ ] **Step 9: 记录人工验收步骤**

实现完成报告中列出以下游戏内验收，不需要使用 CUA 自动操作：

1. 启动主场景并装备油桶。
2. 朝任意无遮挡方向瞄准并放置，确认油桶出现在角色身后一格。
3. 让角色身后一格被障碍物占用后再次放置，确认放置被拒绝且油桶数量不减少。
