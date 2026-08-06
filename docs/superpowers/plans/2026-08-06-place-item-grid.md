# 放置物网格系统 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 删除玩家跳跃，新增绑定 K 与移动端按钮的通用放置物输入，并让 DemoArena 使用 1 米八方向网格、999 个库存和占用规则放置爆炸油桶。

**Architecture:** `PlayerController` 只发出通用 `place_item_requested` 信号；场景级 `PlaceItemGrid` 负责坐标、八方向、静态格占用和动态角色查询；场景级 `PlaceItemController` 负责 PackedScene、库存、生成与释放。DemoArena 只配置油桶、连接 HUD 与场景级导航，不把 Demo 规则写回玩家或 Autoload。

**Tech Stack:** Godot 4.7.1、GDScript、PhysicsDirectSpaceState3D、Shape3D 简化碰撞、现有 RefCounted 测试运行器。

## 实施结果

- 2026-08-06 在 worktree `/Users/yewei/yyw/project/zombiewar-place-item`、分支 `codex/place-item` 完成实现。
- 按 TDD 完成 RED→GREEN：输入与重力、玩家放置请求、1 米八方向网格、静态/动态阻挡、控制器库存生命周期、DemoArena 接线、移动端库存同步和测试路径筛选均有对应测试。
- 玩家已删除 Space 跳跃与跳跃参数，保留重力和离地坠落；K 与移动端 `PlaceItemButton` 统一触发 `place_item`，一次按住只发出一次请求。
- DemoArena 使用世界原点的 1 米网格，只允许面对的八方向相邻格；墙体、边界、车辆、集装箱和油桶持久占格，玩家/僵尸只在放置瞬间阻挡。
- DemoArena 配置“油桶”初始库存 999；成功放置扣 1，占用或动态阻挡失败不扣，爆炸销毁释放格子但不退款。
- 新增和移除油桶都会标脏导航区块 `demo_arena`；场景级网格与控制器未使用 Autoload。
- 移动端按钮显示 `油桶\n999` 并随库存同步，保留 120×120 固定尺寸与开火多指操作；字体子集已补齐新增中文字符。
- 测试运行器新增单文件/多文件筛选：`./tests/run_tests.sh tests/unit/test_place_item_grid.gd`；不传路径时仍运行全量，未注册路径会明确失败。
- 相关最小矩阵共 9 个测试文件通过；Godot 导入/解析检查 exit 0；DemoArena 5 秒 headless Smoke Test exit 0；`git diff --check` 通过。
- 完整测试没有新增本功能失败，仍只有 4 个已知范围外基线失败：`test_weapon_loadout.gd` 的 `Run_Slash` 期望，以及 `test_player_melee_weapon.gd` 的 3 个冷却/缓冲期望。

## Global Constraints

- 实现与验证均在 `/Users/yewei/yyw/project/zombiewar-place-item`、分支 `codex/place-item` 中进行。
- 使用 TDD：每个生产行为先写测试，运行并确认预期 RED，再写最小实现并确认 GREEN。
- 使用最小测试矩阵：扩展现有输入、移动与移动端测试；新增一个玩家输入集成测试、一个网格单元测试、一个网格物理集成测试、一个控制器集成测试和一个 Demo 场景集成测试。
- 删除 `jump` 动作、Space 绑定、玩家跳跃参数、跳跃速度分支和移动端跳跃按钮；保留重力与离地坠落。
- 新增 `place_item` 动作并唯一绑定 K；玩家每次按下只发出一次请求。
- 网格为 1 米 × 1 米，Demo 原点为世界原点，玩家只能放置到面对的八方向相邻一格。
- 地图静态障碍使用 `place_item_obstacle` 分组和简化 CollisionShape3D 自动登记；地面不得加入该分组。
- 玩家和僵尸只在放置瞬间阻挡，不进入持久占用字典；放置查询必须排除请求玩家 RID。
- DemoArena 配置爆炸油桶、显示名“油桶”和初始库存 999；失败不扣库存，成功永久扣 1，销毁只释放格子不退款。
- 新增或移除放置物后必须由 DemoArena 标脏 `demo_arena` 导航区块；放置组件不使用 Autoload。
- 移动端 `PlaceItemButton` 替换 `JumpButton`，保留 120×120 固定触摸尺寸，可与开火使用不同触摸 ID。
- 不解析高精度视觉模型；障碍覆盖只使用 Box、Cylinder、Capsule 与 Sphere 简化碰撞。
- 不实现放置预览、格子高亮、远距离选择、多格建筑、库存拾取、退款、存档或跨场景持久化。
- 不修改 `addons/`，不提交 `.godot/` 或 `build/`。
- 当前隔离分支基线的完整测试套件已知有 4 个范围外失败：`test_weapon_loadout.gd` 的小刀移动动画期望，以及 `test_player_melee_weapon.gd` 的 3 个冷却/缓冲期望。每次 GREEN 的标准是没有新增本功能失败。

---

## 文件结构

- Create: `scripts/gameplay/place_item_grid.gd` — 网格换算、八方向、owner 占用、静态碰撞覆盖与动态阻挡查询。
- Create: `scripts/gameplay/place_item_controller.gd` — 放置物配置、库存、生成、占用登记、销毁释放与信号。
- Create: `tests/unit/test_place_item_grid.gd` — 1 米坐标、八方向和 owner 占用矩阵。
- Create: `tests/integration/test_place_item_grid_physics.gd` — 简化碰撞覆盖和玩家/僵尸动态阻挡。
- Create: `tests/integration/test_place_item_controller.gd` — 成功扣库存、占用失败不扣、销毁释放不退款。
- Create: `tests/integration/test_demo_place_item.gd` — Demo 配置、初始障碍、真实油桶放置和导航接线。
- Create: `tests/integration/test_player_place_item_input.gd` — 玩家一次输入发出一次通用放置请求。
- Modify: `project.godot` — 删除 `jump`，增加 K 绑定的 `place_item`。
- Modify: `scripts/player/player_motion.gd` — 垂直速度只处理重力。
- Modify: `scripts/player/player_controller.gd` — 删除跳跃输入与参数，增加放置请求信号。
- Modify: `scripts/gameplay/demo_arena.gd` — 连接玩家、放置控制器、HUD 和导航标脏。
- Modify: `scenes/gameplay/DemoArena.tscn` — 增加网格与控制器，标记地图障碍，更新桌面提示。
- Modify: `scenes/props/ExplosiveBarrel.tscn` — 根节点加入 `place_item_obstacle`。
- Modify: `scripts/ui/mobile_controls.gd` — 用放置按钮替换跳跃按钮并更新名称/数量。
- Modify: `scenes/ui/MobileControls.tscn` — `PlaceItemButton`、`place_item` 动作和两行标签。
- Modify: `tests/unit/test_project_contract.gd` — 输入迁移契约。
- Modify: `tests/unit/test_player_motion.gd` — 删除跳跃期望，保留重力期望。
- Modify: `tests/unit/test_mobile_touch_controls.gd` — 放置按钮布局、多指与取消契约。
- Modify: `tests/integration/test_demo_scene.gd` — 新移动端节点与桌面提示契约。
- Modify: `tests/integration/test_weapon_wall_clearance.gd` — 测试输入清理由 `jump` 改为 `place_item`。
- Modify: `tests/test_runner.gd` — 注册五个新增测试并迁移输入清理。
- Modify: `docs/superpowers/plans/2026-08-06-place-item-grid.md` — 完成后写入实施结果。

---

### Task 1: 将全部跳跃输入表面迁移为通用放置物输入

**Files:**
- Modify: `tests/unit/test_project_contract.gd:3-31`
- Modify: `tests/unit/test_player_motion.gd:178-198`
- Create: `tests/integration/test_player_place_item_input.gd`
- Modify: `tests/test_runner.gd:3-48,75-88`
- Modify: `tests/integration/test_weapon_wall_clearance.gd:862-874`
- Modify: `tests/unit/test_mobile_touch_controls.gd:138-344`
- Modify: `tests/integration/test_demo_scene.gd:49-65,243-256,304-320`
- Modify: `project.godot:36-102`
- Modify: `scripts/player/player_motion.gd:57-69`
- Modify: `scripts/player/player_controller.gd:12-19,25-44,106-166,246-257`
- Modify: `scripts/gameplay/demo_arena.gd:128-147`
- Modify: `scripts/ui/mobile_controls.gd:7-23,75-92,145-158`
- Modify: `scenes/ui/MobileControls.tscn:84-125`
- Modify: `scenes/gameplay/DemoArena.tscn:320-340`

**Interfaces:**
- Produces: `PlayerController.place_item_requested(requester: CollisionObject3D, origin: Vector3, direction: Vector3)`。
- Produces: `PlayerController.place_item_action: StringName = &"place_item"`。
- Produces: `PlayerMotion.next_vertical_velocity(current_y: float, grounded: bool, delta: float, gravity: float) -> float`。
- Consumes: 现有 `PlayerMotion.next_aim_direction(...)` 作为请求方向。

- [x] **Step 1: 写入失败的输入与重力测试**

在 `test_project_contract.gd` 中从 `REQUIRED_ACTIONS` 和 `REQUIRED_KEY_BINDINGS` 删除 `jump`，加入：

```gdscript
const REQUIRED_ACTIONS: Array[StringName] = [
	&"move_left",
	&"move_right",
	&"move_forward",
	&"move_back",
	&"place_item",
	&"primary_attack",
	&"weapon_pistol",
	&"weapon_rifle",
	&"weapon_knife",
	&"weapon_slot_4",
	&"spawn_wave",
	&"restart_demo",
]

const REQUIRED_KEY_BINDINGS: Dictionary = {
	&"move_left": KEY_A,
	&"move_right": KEY_D,
	&"move_forward": KEY_W,
	&"move_back": KEY_S,
	&"place_item": KEY_K,
	&"primary_attack": KEY_J,
	&"weapon_pistol": KEY_1,
	&"weapon_rifle": KEY_2,
	&"weapon_knife": KEY_3,
	&"weapon_slot_4": KEY_4,
	&"spawn_wave": KEY_T,
	&"restart_demo": KEY_R,
}
```

并在遍历前增加：

```gdscript
_append(failures, Assertions.expect_true(
	not InputMap.has_action(&"jump"),
	"Project removes the jump input action"
))
```

将 `test_player_motion.gd` 的垂直速度矩阵改成新签名：

```gdscript
_append(failures, Assertions.expect_float_near(
	player_motion.next_vertical_velocity(3.0, true, 0.1, 24.0),
	0.0,
	0.0001,
	"Grounded vertical motion cannot retain upward jump speed"
))
_append(failures, Assertions.expect_float_near(
	player_motion.next_vertical_velocity(1.0, false, 0.25, 8.0),
	-1.0,
	0.0001,
	"Airborne vertical motion only applies gravity"
))
```

创建 `test_player_place_item_input.gd`，加载真实玩家场景，按下 `place_item` 后手动执行一次物理处理并捕获真实信号：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var requests: Array[Dictionary] = []
	player.place_item_requested.connect(
		Callable(self, "_capture_request").bind(requests)
	)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)
	player.set_physics_process(false)
	Input.action_press(&"place_item")
	player._physics_process(0.0)
	Input.action_release(&"place_item")
	_append(failures, Assertions.expect_equal(
		requests.size(),
		1,
		"One place-item press emits one player request"
	))
	if requests.size() == 1:
		_append(failures, Assertions.expect_true(
			requests[0]["requester"] == player and
			requests[0]["origin"] == player.global_position and
			(requests[0]["direction"] as Vector3).is_equal_approx(Vector3.FORWARD),
			"Player request carries the player, origin, and current facing"
		))
	player.free()
	return failures

func _capture_request(
	requester: CollisionObject3D,
	origin: Vector3,
	direction: Vector3,
	requests: Array[Dictionary]
) -> void:
	requests.append({
		"requester": requester,
		"origin": origin,
		"direction": direction,
	})

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

注册新测试，并把测试输入清理中的 `&"jump"` 替换为 `&"place_item"`。

同步修改现有移动端和 Demo 场景测试，使旧输入动作删除后本任务即可恢复 GREEN：

```gdscript
var place_item_button := controls.get_node_or_null(
	"Layout/PlaceItemButton"
) as MobileActionButton
_append(failures, Assertions.expect_true(
	place_item_button != null and
	place_item_button.action == &"place_item" and
	place_item_button.size.is_equal_approx(Vector2(120.0, 120.0)),
	"Mobile controls replace jump with a fixed-size place-item button"
))
```

将多指断言中的 `jump_button` / `jump` 改成 `place_item_button` / `place_item`，将 `cancel_all_input()` 和 `_release_test_actions()` 的释放动作同步迁移。`test_demo_scene.gd` 断言不存在 `JumpButton`，存在 `PlaceItemButton`，桌面 Controls 不再包含 `SPACE` 或 `JUMP` 并包含 `K`。

- [x] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: 新失败明确指出 `jump` 仍存在、`place_item` 缺失、垂直速度签名仍包含跳跃参数，或玩家缺少 `place_item_requested`。除此之外仍可能存在 4 个已知基线失败。

- [x] **Step 3: 编写最小输入与玩家实现**

在 `project.godot` 删除完整 `jump={...}` 块，新增：

```text
place_item={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":75,"physical_keycode":0,"key_label":0,"unicode":107,"location":0,"echo":false,"script":null)
]
}
```

将 `PlayerMotion.next_vertical_velocity()` 替换为：

```gdscript
static func next_vertical_velocity(
	current_y: float,
	grounded: bool,
	delta: float,
	gravity: float
) -> float:
	if not grounded:
		return current_y - maxf(gravity, 0.0) * maxf(delta, 0.0)
	return minf(current_y, 0.0)
```

在 `PlayerController` 增加：

```gdscript
signal place_item_requested(
	requester: CollisionObject3D,
	origin: Vector3,
	direction: Vector3
)

@export var place_item_action: StringName = &"place_item"
```

删除 `jump_action`、`jump_speed`，在更新 `aim_direction` 后增加：

```gdscript
if Input.is_action_just_pressed(place_item_action):
	place_item_requested.emit(self, global_position, aim_direction)
```

两处垂直速度调用统一改成：

```gdscript
velocity.y = PlayerMotion.next_vertical_velocity(
	velocity.y,
	is_on_floor(),
	delta,
	gravity
)
```

将 `MobileControls` 的跳跃变量、常量、布局和取消逻辑机械改名为放置物：

```gdscript
const BASE_PLACE_ITEM_BUTTON_SIZE := 120.0
const BASE_PLACE_ITEM_BUTTON_GAP := 16.0

@onready var place_item_button: MobileActionButton = $Layout/PlaceItemButton
@onready var place_item_label: Label = $Layout/PlaceItemButton/Label
```

使用原跳跃按钮位置的同等布局算法：

```gdscript
var place_item_gap := BASE_PLACE_ITEM_BUTTON_GAP * scale_factor
var place_item_left := fire_left - place_item_gap
var place_item_bottom := fire_top - place_item_gap
_set_anchored_rect(
	place_item_button,
	place_item_left,
	place_item_bottom - BASE_PLACE_ITEM_BUTTON_SIZE,
	place_item_left + BASE_PLACE_ITEM_BUTTON_SIZE,
	place_item_bottom
)
```

`cancel_all_input()` 的末尾改为：

```gdscript
fire_button.cancel()
place_item_button.cancel()
```

场景节点改为：

```text
[node name="PlaceItemButton" type="Control" parent="Layout"]
...
action = &"place_item"

[node name="Label" type="Label" parent="Layout/PlaceItemButton"]
...
text = "放置物\n0"
```

Demo 默认 Controls 文本删除 `SPACE JUMP`，先使用通用占位：

```text
WASD  MOVE + FACE    K  PLACE ITEM    J  FIRE    1-3  WEAPON    T  WAVE    R  RESTART
```

`DemoArena._release_startup_actions()`、`tests/test_runner.gd`、`test_weapon_wall_clearance.gd` 与移动端测试清理全部释放 `place_item`，不再释放不存在的 `jump`。

- [x] **Step 4: 运行完整测试并确认本任务 GREEN**

Run: `./tests/run_tests.sh`

Expected: 输入迁移、重力和玩家请求测试通过；不出现新的跳跃或 `place_item` 失败，只保留已知基线失败。

- [x] **Step 5: 提交任务**

```bash
git add project.godot scripts/player/player_motion.gd scripts/player/player_controller.gd scripts/gameplay/demo_arena.gd scripts/ui/mobile_controls.gd scenes/ui/MobileControls.tscn scenes/gameplay/DemoArena.tscn tests/unit/test_project_contract.gd tests/unit/test_player_motion.gd tests/unit/test_mobile_touch_controls.gd tests/integration/test_player_place_item_input.gd tests/integration/test_weapon_wall_clearance.gd tests/integration/test_demo_scene.gd tests/test_runner.gd
git commit -m "feat: replace jumping with place-item input"
```

---

### Task 2: 实现 1 米网格、八方向与 owner 占用

**Files:**
- Create: `tests/unit/test_place_item_grid.gd`
- Create: `scripts/gameplay/place_item_grid.gd`
- Modify: `tests/test_runner.gd:3-48`

**Interfaces:**
- Produces: `PlaceItemGrid.world_to_cell(world_position: Vector3) -> Vector2i`。
- Produces: `PlaceItemGrid.cell_to_world(cell: Vector2i) -> Vector3`。
- Produces: `PlaceItemGrid.facing_step(direction: Vector3) -> Vector2i`。
- Produces: `PlaceItemGrid.target_cell(origin: Vector3, direction: Vector3) -> Vector2i`。
- Produces: `PlaceItemGrid.reserve_cells(owner: Node, cells: Array[Vector2i]) -> bool`。
- Produces: `PlaceItemGrid.release_owner(owner: Node) -> bool`。
- Produces: `PlaceItemGrid.is_cell_reserved(cell: Vector2i) -> bool`。
- Consumes: 无场景依赖；本任务不做物理查询。

- [x] **Step 1: 写入失败的网格单元测试**

创建 `test_place_item_grid.gd`，用字面量验证坐标、八方向和占用生命周期：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PlaceItemGridScript = preload("res://scripts/gameplay/place_item_grid.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var grid := PlaceItemGridScript.new() as PlaceItemGrid
	grid.cell_size = 1.0
	grid.grid_origin = Vector3.ZERO
	_append(failures, Assertions.expect_equal(
		grid.world_to_cell(Vector3(1.49, 0.0, -2.49)),
		Vector2i(1, -2),
		"World positions round to the nearest one-meter cell"
	))
	_append(failures, Assertions.expect_equal(
		grid.cell_to_world(Vector2i(-3, 4)),
		Vector3(-3.0, 0.0, 4.0),
		"Cell centers align with the configured world origin"
	))
	var directions := {
		Vector3(0.0, 0.0, -1.0): Vector2i(0, -1),
		Vector3(1.0, 0.0, -1.0): Vector2i(1, -1),
		Vector3(1.0, 0.0, 0.0): Vector2i(1, 0),
		Vector3(1.0, 0.0, 1.0): Vector2i(1, 1),
		Vector3(0.0, 0.0, 1.0): Vector2i(0, 1),
		Vector3(-1.0, 0.0, 1.0): Vector2i(-1, 1),
		Vector3(-1.0, 0.0, 0.0): Vector2i(-1, 0),
		Vector3(-1.0, 0.0, -1.0): Vector2i(-1, -1),
	}
	for direction in directions:
		_append(failures, Assertions.expect_equal(
			grid.facing_step(direction),
			directions[direction],
			"Facing maps to the expected adjacent cell: %s" % direction
		))
	_append(failures, Assertions.expect_equal(
		grid.facing_step(Vector3.ZERO),
		Vector2i.ZERO,
		"Zero facing produces no placement step"
	))
	var first := Node.new()
	var second := Node.new()
	_append(failures, Assertions.expect_true(
		grid.reserve_cells(first, [Vector2i(2, 3)]) and
		grid.is_cell_reserved(Vector2i(2, 3)) and
		not grid.reserve_cells(second, [Vector2i(2, 3)]),
		"A reserved cell rejects a different owner"
	))
	_append(failures, Assertions.expect_true(
		grid.release_owner(first) and
		not grid.is_cell_reserved(Vector2i(2, 3)) and
		grid.reserve_cells(second, [Vector2i(2, 3)]),
		"Releasing an owner makes its cells reusable"
	))
	first.free()
	second.free()
	grid.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

将测试路径加到 `TEST_PATHS` 的玩法单元测试区域。

- [x] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，因为 `place_item_grid.gd` 不存在或缺少上述接口。

- [x] **Step 3: 编写最小网格与占用实现**

创建 `place_item_grid.gd`：

```gdscript
extends Node3D
class_name PlaceItemGrid

const FACING_STEPS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, -1),
	Vector2i(1, 0),
	Vector2i(1, 1),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(-1, -1),
]

@export_range(0.25, 4.0, 0.25) var cell_size := 1.0
@export var grid_origin := Vector3.ZERO
@export_flags_3d_physics var dynamic_blocker_mask := 6
@export_range(0.2, 4.0, 0.1) var dynamic_query_height := 1.8

var cell_owners: Dictionary = {}
var owner_cells: Dictionary = {}

func world_to_cell(world_position: Vector3) -> Vector2i:
	var size := maxf(cell_size, 0.001)
	return Vector2i(
		roundi((world_position.x - grid_origin.x) / size),
		roundi((world_position.z - grid_origin.z) / size)
	)

func cell_to_world(cell: Vector2i) -> Vector3:
	var size := maxf(cell_size, 0.001)
	return grid_origin + Vector3(cell.x * size, 0.0, cell.y * size)

func facing_step(direction: Vector3) -> Vector2i:
	var planar := Vector2(direction.x, direction.z)
	if planar.length_squared() <= 0.000001:
		return Vector2i.ZERO
	planar = planar.normalized()
	var best_step := Vector2i.ZERO
	var best_dot := -INF
	for step in FACING_STEPS:
		var candidate := Vector2(step.x, step.y).normalized()
		var score := planar.dot(candidate)
		if score > best_dot:
			best_dot = score
			best_step = step
	return best_step

func target_cell(origin: Vector3, direction: Vector3) -> Vector2i:
	return world_to_cell(origin) + facing_step(direction)

func reserve_cells(owner: Node, cells: Array[Vector2i]) -> bool:
	if owner == null or cells.is_empty():
		return false
	var owner_id := owner.get_instance_id()
	for cell in cells:
		if cell_owners.has(cell) and cell_owners[cell] != owner_id:
			return false
	for cell in cells:
		cell_owners[cell] = owner_id
	owner_cells[owner_id] = cells.duplicate()
	return true

func release_owner(owner: Node) -> bool:
	if owner == null:
		return false
	var owner_id := owner.get_instance_id()
	if not owner_cells.has(owner_id):
		return false
	for cell in owner_cells[owner_id]:
		if cell_owners.get(cell) == owner_id:
			cell_owners.erase(cell)
	owner_cells.erase(owner_id)
	return true

func is_cell_reserved(cell: Vector2i) -> bool:
	return cell_owners.has(cell)
```

- [x] **Step 4: 运行完整测试并确认本任务 GREEN**

Run: `./tests/run_tests.sh`

Expected: 网格坐标、八方向与 owner 生命周期通过；无新增失败。

- [x] **Step 5: 提交任务**

```bash
git add scripts/gameplay/place_item_grid.gd tests/unit/test_place_item_grid.gd tests/test_runner.gd
git commit -m "feat: add place-item grid occupancy"
```

---

### Task 3: 登记地图简化碰撞并查询动态角色

**Files:**
- Create: `tests/integration/test_place_item_grid_physics.gd`
- Modify: `scripts/gameplay/place_item_grid.gd`
- Modify: `tests/test_runner.gd:3-48`

**Interfaces:**
- Consumes: Task 2 的格坐标与 owner 占用接口。
- Produces: `PlaceItemGrid.cells_for_collision_object(obstacle: CollisionObject3D) -> Array[Vector2i]`。
- Produces: `PlaceItemGrid.register_obstacle(obstacle: CollisionObject3D) -> bool`。
- Produces: `PlaceItemGrid.register_initial_obstacles() -> void`。
- Produces: `PlaceItemGrid.has_dynamic_blocker(world: World3D, cell: Vector2i, excluded: Array[RID]) -> bool`。
- Produces: 已登记障碍退出场景时自动 `release_owner(obstacle)`。

- [x] **Step 1: 写入失败的真实物理测试**

创建 `test_place_item_grid_physics.gd`，使用真实 StaticBody3D、CharacterBody3D、Area3D 和物理空间：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PlaceItemGridScript = preload("res://scripts/gameplay/place_item_grid.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var host := Node3D.new()
	var grid := PlaceItemGridScript.new() as PlaceItemGrid
	host.add_child(grid)
	var obstacle := StaticBody3D.new()
	obstacle.position = Vector3(2.0, 0.5, 0.0)
	obstacle.rotation_degrees.y = 45.0
	var obstacle_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 1.0, 1.0)
	obstacle_shape.shape = box
	obstacle.add_child(obstacle_shape)
	host.add_child(obstacle)
	var requester := CharacterBody3D.new()
	requester.collision_layer = 2
	var requester_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.45
	capsule.height = 1.8
	requester_shape.position.y = 0.9
	requester_shape.shape = capsule
	requester.add_child(requester_shape)
	host.add_child(requester)
	var zombie_area := Area3D.new()
	zombie_area.position = Vector3(0.0, 0.9, -1.0)
	zombie_area.collision_layer = 4
	var zombie_shape := CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = 0.45
	cylinder.height = 1.6
	zombie_shape.shape = cylinder
	zombie_area.add_child(zombie_shape)
	host.add_child(zombie_area)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)
	host.force_update_transform()
	var covered := grid.cells_for_collision_object(obstacle)
	_append(failures, Assertions.expect_true(
		Vector2i(2, 0) in covered and covered.size() > 1,
		"A rotated box conservatively covers multiple world-grid cells"
	))
	_append(failures, Assertions.expect_true(
		grid.register_obstacle(obstacle) and grid.is_cell_reserved(Vector2i(2, 0)),
		"A supported static collision reserves its covered cells"
	))
	_append(failures, Assertions.expect_true(
		grid.has_dynamic_blocker(
			requester.get_world_3d(),
			Vector2i(0, -1),
			[requester.get_rid()]
		),
		"A target-layer area temporarily blocks its grid cell"
	))
	_append(failures, Assertions.expect_true(
		not grid.has_dynamic_blocker(
			requester.get_world_3d(),
			Vector2i(0, 0),
			[requester.get_rid()]
		),
		"The requesting player RID is excluded from dynamic blocking"
	))
	obstacle.free()
	_append(failures, Assertions.expect_true(
		not grid.is_cell_reserved(Vector2i(2, 0)),
		"A registered obstacle releases its grid cells when it exits"
	))
	host.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

注册测试路径。

- [x] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，因为静态覆盖、障碍登记与动态阻挡接口不存在。

- [x] **Step 3: 扩展网格物理实现**

在 `PlaceItemGrid._ready()` deferred 扫描：

```gdscript
func _ready() -> void:
	call_deferred("register_initial_obstacles")

func register_initial_obstacles() -> void:
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group(&"place_item_obstacle"):
		if node is CollisionObject3D:
			register_obstacle(node as CollisionObject3D)
```

实现支持形状的局部 AABB：

```gdscript
func _shape_local_aabb(shape: Shape3D) -> AABB:
	var half := Vector3.ZERO
	if shape is BoxShape3D:
		half = (shape as BoxShape3D).size * 0.5
	elif shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		half = Vector3(cylinder.radius, cylinder.height * 0.5, cylinder.radius)
	elif shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		half = Vector3(capsule.radius, capsule.height * 0.5, capsule.radius)
	elif shape is SphereShape3D:
		var radius := (shape as SphereShape3D).radius
		half = Vector3.ONE * radius
	else:
		return AABB()
	return AABB(-half, half * 2.0)
```

遍历 obstacle 下所有 `CollisionShape3D`，跳过 disabled 或空 shape，合并世界 AABB：

```gdscript
func cells_for_collision_object(
	obstacle: CollisionObject3D
) -> Array[Vector2i]:
	var combined := AABB()
	var has_bounds := false
	for candidate in obstacle.find_children(
		"*",
		"CollisionShape3D",
		true,
		false
	):
		var collision_shape := candidate as CollisionShape3D
		if (
			collision_shape == null or collision_shape.disabled or
			collision_shape.shape == null
		):
			continue
		var local_aabb := _shape_local_aabb(collision_shape.shape)
		if local_aabb.size == Vector3.ZERO:
			push_warning(
				"Unsupported place-item obstacle shape: %s (%s)" % [
					collision_shape.get_path(),
					collision_shape.shape.get_class(),
				]
			)
			continue
		var world_aabb := collision_shape.global_transform * local_aabb
		combined = world_aabb if not has_bounds else combined.merge(world_aabb)
		has_bounds = true
	return _cells_for_world_aabb(combined) if has_bounds else []
```

合并后将 AABB 转成覆盖格：

```gdscript
func _cells_for_world_aabb(bounds: AABB) -> Array[Vector2i]:
	var size := maxf(cell_size, 0.001)
	var half_cell := size * 0.5
	var min_x := ceili((bounds.position.x - grid_origin.x - half_cell) / size)
	var max_x := floori((bounds.end.x - grid_origin.x + half_cell) / size)
	var min_z := ceili((bounds.position.z - grid_origin.z - half_cell) / size)
	var max_z := floori((bounds.end.z - grid_origin.z + half_cell) / size)
	var cells: Array[Vector2i] = []
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			cells.append(Vector2i(x, z))
	return cells
```

`register_obstacle()` 使用 `reserve_cells(obstacle, cells_for_collision_object(obstacle))`。成功后连接一次性退出回调：

```gdscript
func register_obstacle(obstacle: CollisionObject3D) -> bool:
	if obstacle == null:
		return false
	var cells := cells_for_collision_object(obstacle)
	if cells.is_empty() or not reserve_cells(obstacle, cells):
		return false
	var exit_callback := Callable(
		self,
		"_on_registered_obstacle_exiting"
	).bind(obstacle)
	if not obstacle.tree_exiting.is_connected(exit_callback):
		obstacle.tree_exiting.connect(exit_callback, CONNECT_ONE_SHOT)
	return true

func _on_registered_obstacle_exiting(obstacle: CollisionObject3D) -> void:
	release_owner(obstacle)
```

未知形状使用 `push_warning()` 输出 obstacle 路径与 shape 类名。

动态查询实现：

```gdscript
func has_dynamic_blocker(
	world: World3D,
	cell: Vector2i,
	excluded: Array[RID]
) -> bool:
	if world == null or dynamic_blocker_mask == 0:
		return false
	var query_shape := BoxShape3D.new()
	query_shape.size = Vector3(
		maxf(cell_size * 0.9, 0.1),
		maxf(dynamic_query_height, 0.2),
		maxf(cell_size * 0.9, 0.1)
	)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = query_shape
	query.transform = Transform3D(
		Basis.IDENTITY,
		cell_to_world(cell) + Vector3.UP * (0.1 + query_shape.size.y * 0.5)
	)
	query.collision_mask = dynamic_blocker_mask
	query.collide_with_bodies = true
	query.collide_with_areas = true
	query.exclude = excluded
	return not world.direct_space_state.intersect_shape(query, 32).is_empty()
```

- [x] **Step 4: 运行完整测试并确认本任务 GREEN**

Run: `./tests/run_tests.sh`

Expected: 旋转 Box 覆盖、目标 Area 阻挡和请求玩家排除通过；无新增失败。

- [x] **Step 5: 提交任务**

```bash
git add scripts/gameplay/place_item_grid.gd tests/integration/test_place_item_grid_physics.gd tests/test_runner.gd
git commit -m "feat: detect place-item grid blockers"
```

---

### Task 4: 实现库存、生成和销毁释放控制器

**Files:**
- Create: `tests/integration/test_place_item_controller.gd`
- Create: `scripts/gameplay/place_item_controller.gd`
- Modify: `tests/test_runner.gd:3-48`

**Interfaces:**
- Consumes: `PlaceItemGrid.target_cell(...)`、`is_cell_reserved(...)`、`has_dynamic_blocker(...)`、`reserve_cells(...)` 与 `release_owner(...)`。
- Produces: `PlaceItemController.request_place_item(requester: CollisionObject3D, origin: Vector3, direction: Vector3) -> bool`。
- Produces: `PlaceItemController.get_remaining_count() -> int`。
- Produces: `item_count_changed(display_name: String, remaining_count: int)`。
- Produces: `placement_geometry_changed`。
- Produces: `placement_rejected(reason: StringName)`。

- [x] **Step 1: 写入失败的控制器生命周期测试**

创建 `test_place_item_controller.gd`，使用真实 `ExplosiveBarrel.tscn`、真实网格和真实玩家碰撞：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PlaceItemGridScript = preload("res://scripts/gameplay/place_item_grid.gd")
const PlaceItemControllerScript = preload("res://scripts/gameplay/place_item_controller.gd")
const BARREL_SCENE := preload("res://scenes/props/ExplosiveBarrel.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var host := Node3D.new()
	var grid := PlaceItemGridScript.new() as PlaceItemGrid
	grid.name = "Grid"
	var placed := Node3D.new()
	placed.name = "Placed"
	var controller := PlaceItemControllerScript.new() as PlaceItemController
	controller.name = "Controller"
	controller.item_display_name = "油桶"
	controller.place_item_scene = BARREL_SCENE
	controller.initial_item_count = 2
	controller.grid_path = NodePath("../Grid")
	controller.placed_items_path = NodePath("../Placed")
	host.add_child(grid)
	host.add_child(placed)
	host.add_child(controller)
	var requester := CharacterBody3D.new()
	requester.collision_layer = 2
	host.add_child(requester)
	var geometry_changes: Array[int] = []
	controller.placement_geometry_changed.connect(
		func() -> void: geometry_changes.append(1)
	)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)
	var first_success := controller.request_place_item(
		requester,
		Vector3.ZERO,
		Vector3.RIGHT
	)
	_append(failures, Assertions.expect_true(
		first_success and placed.get_child_count() == 1 and
		(placed.get_child(0) as Node3D).global_position == Vector3(1.0, 0.0, 0.0) and
		controller.get_remaining_count() == 1,
		"Successful placement snaps to the adjacent cell and consumes one item"
	))
	var occupied_success := controller.request_place_item(
		requester,
		Vector3.ZERO,
		Vector3.RIGHT
	)
	_append(failures, Assertions.expect_true(
		not occupied_success and placed.get_child_count() == 1 and
		controller.get_remaining_count() == 1,
		"A reserved target cell rejects placement without consuming inventory"
	))
	var first_barrel := placed.get_child(0)
	first_barrel.free()
	_append(failures, Assertions.expect_equal(
		controller.get_remaining_count(),
		1,
		"Destroying a placed item releases its cell without refunding inventory"
	))
	var reuse_success := controller.request_place_item(
		requester,
		Vector3.ZERO,
		Vector3.RIGHT
	)
	_append(failures, Assertions.expect_true(
		reuse_success and controller.get_remaining_count() == 0 and
		geometry_changes.size() == 3,
		"A released cell can be placed again and each geometry change emits once"
	))
	_append(failures, Assertions.expect_true(
		not controller.request_place_item(
			requester,
			Vector3.ZERO,
			Vector3.FORWARD
		) and controller.get_remaining_count() == 0,
		"Out-of-stock placement cannot create an item or make stock negative"
	))
	host.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

注册测试路径。

- [x] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，因为 `place_item_controller.gd` 不存在。

- [x] **Step 3: 编写最小控制器实现**

创建脚本头部与配置：

```gdscript
extends Node
class_name PlaceItemController

signal item_count_changed(display_name: String, remaining_count: int)
signal placement_geometry_changed
signal placement_rejected(reason: StringName)

@export var item_display_name := ""
@export var place_item_scene: PackedScene
@export_range(0, 999999, 1) var initial_item_count := 0
@export_node_path("PlaceItemGrid") var grid_path: NodePath
@export_node_path("Node3D") var placed_items_path: NodePath

var remaining_count := -1
var tracked_items: Dictionary = {}

func _ready() -> void:
	if remaining_count < 0:
		remaining_count = maxi(initial_item_count, 0)
	call_deferred("_emit_current_count")

func get_remaining_count() -> int:
	return maxi(initial_item_count, 0) if remaining_count < 0 else remaining_count
```

实现请求流程：

```gdscript
func request_place_item(
	requester: CollisionObject3D,
	origin: Vector3,
	direction: Vector3
) -> bool:
	if remaining_count <= 0:
		return _reject(&"out_of_stock")
	var grid := get_node_or_null(grid_path) as PlaceItemGrid
	var container := get_node_or_null(placed_items_path) as Node3D
	if grid == null or container == null or place_item_scene == null:
		push_warning("PlaceItemController has invalid scene, grid, or container configuration")
		return _reject(&"invalid_configuration")
	if Vector2(direction.x, direction.z).length_squared() <= 0.000001:
		return _reject(&"invalid_direction")
	var cell := grid.target_cell(origin, direction)
	if grid.is_cell_reserved(cell):
		return _reject(&"reserved_cell")
	var excluded: Array[RID] = []
	if requester != null and is_instance_valid(requester):
		excluded.append(requester.get_rid())
	if grid.has_dynamic_blocker(grid.get_world_3d(), cell, excluded):
		return _reject(&"dynamic_blocker")
	var instance := place_item_scene.instantiate()
	if not instance is Node3D:
		instance.free()
		return _reject(&"invalid_scene_root")
	var item := instance as Node3D
	container.add_child(item)
	item.global_position = grid.cell_to_world(cell)
	if not grid.reserve_cells(item, [cell]):
		item.free()
		return _reject(&"reserved_cell")
	tracked_items[item.get_instance_id()] = item
	item.tree_exiting.connect(_on_item_tree_exiting.bind(item), CONNECT_ONE_SHOT)
	remaining_count -= 1
	item_count_changed.emit(item_display_name, remaining_count)
	placement_geometry_changed.emit()
	return true
```

实现拒绝和退出释放：

```gdscript
func _reject(reason: StringName) -> bool:
	placement_rejected.emit(reason)
	return false

func _emit_current_count() -> void:
	item_count_changed.emit(item_display_name, remaining_count)

func _on_item_tree_exiting(item: Node3D) -> void:
	var item_id := item.get_instance_id()
	if not tracked_items.erase(item_id):
		return
	var grid := get_node_or_null(grid_path) as PlaceItemGrid
	if grid != null:
		grid.release_owner(item)
	if is_inside_tree():
		placement_geometry_changed.emit()
```

- [x] **Step 4: 运行完整测试并确认本任务 GREEN**

Run: `./tests/run_tests.sh`

Expected: 成功放置扣 1、占用失败不扣、销毁释放不退款、原格复用和几何信号次数全部通过。

- [x] **Step 5: 提交任务**

```bash
git add scripts/gameplay/place_item_controller.gd tests/integration/test_place_item_controller.gd tests/test_runner.gd
git commit -m "feat: control place-item inventory and lifecycle"
```

---

### Task 5: 接入 DemoArena 网格、障碍、油桶与导航

**Files:**
- Create: `tests/integration/test_demo_place_item.gd`
- Modify: `scenes/props/ExplosiveBarrel.tscn:11-14`
- Modify: `scenes/gameplay/DemoArena.tscn:1-220,260-340`
- Modify: `scripts/gameplay/demo_arena.gd:1-190,258-280`
- Modify: `tests/test_runner.gd:3-48`

**Interfaces:**
- Consumes: Player 的 `place_item_requested`、Task 3 的 `PlaceItemGrid`、Task 4 的 `PlaceItemController`。
- Consumes: `NavigationWorldManager.mark_chunk_dirty(&"demo_arena") -> bool`。
- Produces: Demo 节点 `World/Placement/PlaceItemGrid` 与根节点 `PlaceItemController`。
- Produces: `DemoArena._on_place_item_count_changed(display_name: String, remaining_count: int) -> void`。
- Produces: 复用 `_on_barrel_navigation_geometry_changed() -> void` 标脏导航。

- [x] **Step 1: 写入失败的 Demo 场景集成测试**

创建 `test_demo_place_item.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ARENA_SCENE := preload("res://scenes/gameplay/DemoArena.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var arena := ARENA_SCENE.instantiate()
	var grid := arena.get_node_or_null("World/Placement/PlaceItemGrid") as PlaceItemGrid
	var controller := arena.get_node_or_null("PlaceItemController") as PlaceItemController
	var player := arena.get_node_or_null("Player") as PlayerController
	var barrels := arena.get_node_or_null("World/Props/ExplosiveBarrels") as Node3D
	_append(failures, Assertions.expect_true(
		grid != null and is_equal_approx(grid.cell_size, 1.0) and
		grid.grid_origin == Vector3.ZERO,
		"Demo owns a one-meter world-origin placement grid"
	))
	_append(failures, Assertions.expect_true(
		controller != null and controller.item_display_name == "油桶" and
		controller.initial_item_count == 999 and
		controller.place_item_scene.resource_path == "res://scenes/props/ExplosiveBarrel.tscn",
		"Demo configures 999 explosive barrels as its place item"
	))
	var obstacle_paths := [
		"World/Boundaries/North",
		"World/Boundaries/South",
		"World/Boundaries/West",
		"World/Boundaries/East",
		"World/Props/PickupCollision",
		"World/Props/ContainerACollision",
		"World/Props/ContainerBCollision",
	]
	for path in obstacle_paths:
		var obstacle := arena.get_node_or_null(path)
		_append(failures, Assertions.expect_true(
			obstacle != null and obstacle.is_in_group(&"place_item_obstacle"),
			"Demo placement grid registers obstacle %s" % path
		))
	for barrel in barrels.get_children():
		_append(failures, Assertions.expect_true(
			barrel.is_in_group(&"place_item_obstacle"),
			"Every initial demo barrel occupies placement grid cells"
		))
	_append(failures, Assertions.expect_true(
		not arena.get_node("World/Ground").is_in_group(&"place_item_obstacle"),
		"Demo ground does not reserve every placement cell"
	))
	_append(failures, Assertions.expect_true(
		player != null and controller != null and
		player.place_item_requested.is_connected(controller.request_place_item) and
		controller.placement_geometry_changed.is_connected(
			Callable(arena, "_on_barrel_navigation_geometry_changed")
		),
		"Demo wires player placement to inventory and scene navigation"
	))
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)
	player.set_physics_process(false)
	grid.register_initial_obstacles()
	var initial_children := barrels.get_child_count()
	var success := controller.request_place_item(
		player,
		Vector3(0.0, 0.0, 6.0),
		Vector3.FORWARD
	)
	_append(failures, Assertions.expect_true(
		success and barrels.get_child_count() == initial_children + 1 and
		(barrels.get_child(-1) as Node3D).global_position == Vector3(0.0, 0.0, 5.0) and
		controller.get_remaining_count() == 998,
		"Demo places one barrel in the facing adjacent empty cell"
	))
	var count_before_blocked := controller.get_remaining_count()
	var blocked := controller.request_place_item(
		player,
		Vector3(-7.0, 0.0, -3.0),
		Vector3.FORWARD
	)
	_append(failures, Assertions.expect_true(
		not blocked and controller.get_remaining_count() == count_before_blocked,
		"Demo container occupancy rejects placement without consuming stock"
	))
	arena.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

注册测试路径。

- [x] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，因为 Demo 尚无网格、控制器配置、障碍分组或信号接线。

- [x] **Step 3: 修改场景分组与节点配置**

将 `ExplosiveBarrel` 根节点组改为：

```text
groups=["navigation_source", "place_item_obstacle"]
```

为 Demo 四个边界、PickupCollision、ContainerACollision、ContainerBCollision 的 groups 加入 `place_item_obstacle`；Ground 保持只有 `blood_surface` 与 `navigation_source`。

Demo 已有油桶 PackedScene 资源 `15_explosive_barrel`。只增加两个脚本资源，并把 `load_steps` 从 30 调整为 32：

```text
[ext_resource type="Script" path="res://scripts/gameplay/place_item_grid.gd" id="16_place_grid"]
[ext_resource type="Script" path="res://scripts/gameplay/place_item_controller.gd" id="17_place_controller"]
```

增加节点：

```text
[node name="Placement" type="Node3D" parent="World"]

[node name="PlaceItemGrid" type="Node3D" parent="World/Placement"]
script = ExtResource("16_place_grid")
cell_size = 1.0
grid_origin = Vector3(0, 0, 0)
dynamic_blocker_mask = 6

[node name="PlaceItemController" type="Node" parent="."]
script = ExtResource("17_place_controller")
item_display_name = "油桶"
place_item_scene = ExtResource("15_explosive_barrel")
initial_item_count = 999
grid_path = NodePath("../World/Placement/PlaceItemGrid")
placed_items_path = NodePath("../World/Props/ExplosiveBarrels")
```

- [x] **Step 4: 连接玩家、控制器与导航**

在 `_wire_dependencies()` 取得 player 与 controller，并连接：

```gdscript
var place_item_controller := get_node_or_null(
	"PlaceItemController"
) as PlaceItemController
if (
	player != null and place_item_controller != null and
	not player.place_item_requested.is_connected(
		place_item_controller.request_place_item
	)
):
	player.place_item_requested.connect(
		place_item_controller.request_place_item
	)
if (
	place_item_controller != null and
	not place_item_controller.placement_geometry_changed.is_connected(
		_on_barrel_navigation_geometry_changed
	)
):
	place_item_controller.placement_geometry_changed.connect(
		_on_barrel_navigation_geometry_changed
	)
if (
	place_item_controller != null and
	not place_item_controller.item_count_changed.is_connected(
		_on_place_item_count_changed
	)
):
	place_item_controller.item_count_changed.connect(
		_on_place_item_count_changed
	)
	_on_place_item_count_changed(
		place_item_controller.item_display_name,
		place_item_controller.get_remaining_count()
	)
```

保留现有初始油桶 `navigation_geometry_changed` 接线。新增 HUD 同步方法的移动端调用先使用 `has_method()`，Task 6 再提供正式接口：

```gdscript
func _on_place_item_count_changed(
	display_name: String,
	remaining_count: int
) -> void:
	var mobile_controls := get_node_or_null("MobileControls")
	if mobile_controls != null and mobile_controls.has_method("set_place_item_status"):
		mobile_controls.call(
			"set_place_item_status",
			display_name,
			remaining_count
		)
	var controls := get_node_or_null("HUD/ControlsPanel/Controls") as Label
	if controls != null:
		controls.text = (
			"WASD  MOVE + FACE    K  %s %d    J  FIRE    " +
			"1-3  WEAPON    T  WAVE    R  RESTART"
		) % [display_name, remaining_count]
```

- [x] **Step 5: 运行完整测试并确认本任务 GREEN**

Run: `./tests/run_tests.sh`

Expected: Demo 配置、障碍分组、信号接线、空格放置、容器阻挡和库存不扣全部通过。

- [x] **Step 6: 提交任务**

```bash
git add scenes/props/ExplosiveBarrel.tscn scenes/gameplay/DemoArena.tscn scripts/gameplay/demo_arena.gd tests/integration/test_demo_place_item.gd tests/test_runner.gd
git commit -m "feat: place barrels on the demo grid"
```

---

### Task 6: 同步移动端放置物名称与库存数量

**Files:**
- Modify: `tests/unit/test_mobile_touch_controls.gd:138-344`
- Modify: `tests/integration/test_demo_scene.gd:49-65,243-320`
- Modify: `scripts/ui/mobile_controls.gd:20-30,145-165`

**Interfaces:**
- Consumes: `place_item` InputMap 与 Demo `_on_place_item_count_changed(...)`。
- Produces: `MobileControls.set_place_item_status(display_name: String, remaining_count: int) -> void`。
- Consumes: Task 1 已存在的 `MobileControls/Layout/PlaceItemButton` 与标签。
- Produces: Demo 初始化显示 `油桶\n999`，成功后同步为 `油桶\n998`。

- [x] **Step 1: 写入失败的名称与数量同步测试**

Task 1 已完成节点和动作迁移。本任务只增加运行时状态断言：

```gdscript
controls.set_place_item_status("油桶", 998)
_append(failures, Assertions.expect_equal(
	place_item_label.text,
	"油桶\n998",
	"Mobile place-item label shows the current item and count"
))
```

在 `test_demo_scene.gd` 断言真实 Demo 实例的标签初始为 `油桶\n999`，桌面 Controls 同时包含 `K`、`油桶`、`999`。保留 Task 1 已通过的多指、布局和取消契约，不重复增加测试。

- [x] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，因为 `MobileControls` 尚无 `set_place_item_status()`，Demo 标签仍为通用占位。

- [x] **Step 3: 增加移动端状态更新接口**

在 `MobileControls` 增加：

```gdscript
func set_place_item_status(display_name: String, remaining_count: int) -> void:
	place_item_label.text = "%s\n%d" % [display_name, maxi(remaining_count, 0)]
```

Task 5 已使用 `has_method("set_place_item_status")` 调用该接口；接口存在后，Demo 的场景实例化接线会把配置中的“油桶”和 999 同步到共享移动端场景。`MobileControls.tscn` 继续保留通用默认文本 `放置物\n0`，避免共享组件依赖 Demo。

- [x] **Step 4: 运行完整测试并确认本任务 GREEN**

Run: `./tests/run_tests.sh`

Expected: 移动端布局、数量文本、多指、取消、字体和 Demo 桌面提示全部通过；无 `jump` 残留失败。

- [x] **Step 5: 提交任务**

```bash
git add scripts/ui/mobile_controls.gd tests/unit/test_mobile_touch_controls.gd tests/integration/test_demo_scene.gd
git commit -m "feat: sync place-item inventory UI"
```

---

### Task 7: 完整验证、计划回写与单提交整理

**Files:**
- Modify: `docs/superpowers/plans/2026-08-06-place-item-grid.md`

**Interfaces:**
- Consumes: 前六个任务的全部接口与场景契约。
- Produces: 一个验证完成的计划提交，保留设计提交 `ce6d5aa`。

- [x] **Step 1: 搜索删除跳跃后的残留**

Run:

```bash
rg -n "jump_action|jump_speed|&\"jump\"|SPACE  JUMP|JumpButton" project.godot scripts scenes tests -g '*.gd' -g '*.tscn' -g '*.godot'
```

Expected: 没有运行时或测试输入残留；允许角色模型动画资源内部仍存在 `Jump_Idle` 动画名，因为它只作为离地坠落姿势，不提供跳跃能力。

- [x] **Step 2: 执行 Godot 导入与解析检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: exit 0；新脚本与场景无解析或加载错误。`addons/phantom_camera` fresh import 偶发 updater 类型错误应单独记录，不修改第三方插件。

- [x] **Step 3: 执行完整测试套件**

Run: `./tests/run_tests.sh`

Expected: 所有放置物、输入、移动、Demo、导航和移动端测试通过；没有新增失败。若仍存在已记录的 4 个范围外近战/小刀基线失败，在实施结果中逐项说明。

- [x] **Step 4: 执行相关场景 Smoke Test**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --quit-after 5 res://scenes/gameplay/DemoArena.tscn
```

Expected: DemoArena 载入和退出无脚本错误、场景加载错误或 RID 泄漏。

- [x] **Step 5: 检查变更质量**

Run:

```bash
git diff --check
git status --short
git log --oneline --decorate -10
```

源码评审逐项确认：

- 玩家不依赖油桶或 DemoArena。
- 网格使用世界原点、1 米格和八方向最近向量。
- Ground 未加入 `place_item_obstacle`。
- 障碍只解析简化碰撞，不解析视觉模型。
- 动态查询排除请求玩家 RID，但能命中僵尸 layer 3 Area。
- 所有失败分支都在扣库存前返回。
- 成功放置后登记 owner、扣 1、标脏导航。
- 物品退出后释放 owner、标脏导航、不退款。
- 移动端取消会释放 `place_item`。

- [x] **Step 6: 将实施结果写回本计划**

在计划头部 Global Constraints 前增加中文“实施结果”段，记录：

- worktree 与分支。
- RED→GREEN 的测试文件。
- K、八方向相邻格、999 库存、占用失败不扣、销毁不退款。
- 移动端按钮与数量同步。
- 导航添加/移除标脏。
- 导入、Smoke Test、`git diff --check` 与完整测试结果。
- 已知范围外失败（如果仍存在）。

- [x] **Step 7: squash 为一个计划提交**

先确认分支为 `codex/place-item`，工作区只包含本计划文件。以设计提交为基准整理：

```bash
git reset --soft ce6d5aa
git commit -m "feat: add grid-based place items"
```

Expected history:

```text
<new commit> feat: add grid-based place items
ce6d5aa docs: design grid-based place items
d92f7bc feat: add explosive barrels
```

- [x] **Step 8: 提供人工验收步骤**

告知用户：

1. Space 不再跳跃。
2. 面向八个方向按 K，只在面对的相邻格生成油桶。
3. 面向墙体、车辆、集装箱、已有油桶或僵尸时不生成且数量不变。
4. 成功放置从 999 减到 998；油桶爆炸后不退款，但原格可再次放置。
5. 移动端原跳跃按钮显示“油桶 999”，可与开火多指同时操作。
6. 连续添加与销毁油桶后，僵尸导航正确绕行或使用释放的格子。
