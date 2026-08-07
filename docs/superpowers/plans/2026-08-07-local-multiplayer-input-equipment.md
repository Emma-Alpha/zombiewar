# 本地多人输入与统一装备 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立设备隔离的玩家输入契约，将武器和油桶统一为循环装备，并保持键盘、手柄和触控单人模式可玩。

**Architecture:** `PlayerController` 消费 `PlayerInputSource` 生成的 `PlayerInputState`，不再直接读取全局 InputMap。`EquipmentController` 管理统一 `EquipmentItem`，玩家自己的放置装备保存库存，场景级 `PlaceItemService` 只处理世界放置。

**Tech Stack:** Godot 4.7.1、GDScript、现有 Player/Weapon/MobileControls 场景、独立 headless 验证脚本。

## Global Constraints

- 设计规格：`docs/superpowers/specs/2026-08-07-local-multiplayer-input-shared-camera-design.md`。
- 本计划是四份计划中的第 1 份；大厅、多人战斗和共享镜头计划依赖本计划。
- 不恢复 `tests/` 框架，不新增全局测试运行器。
- 只为稳定输入、边沿状态、装备循环和库存契约添加 `tools/validation/` 聚焦脚本。
- 键盘 1：WASD、Q/E、Space；键盘 2：方向键、物理逗号/句号、`/`；手柄：左摇杆、LB/RB、RT。
- 单人模式合并两套键盘、全部在线手柄和触控输入。
- 输入源只提供移动、装备切换、使用和确认，不输出瞄准向量；保持现有角色朝向与攻击方向逻辑。
- 油桶库存按玩家独立，Demo 初始数量为 999；放置失败不扣数量，耗尽后自动切换。
- 计划执行期间允许检查点提交；最终评审后 squash 为 `feat: add device-scoped input and equipment cycling`。

---

### Task 1: 建立玩家输入快照与设备输入源

**Files:**
- Create: `scripts/input/player_input_state.gd`
- Create: `scripts/input/player_input_source.gd`
- Create: `scripts/input/keyboard_wasd_input_source.gd`
- Create: `scripts/input/keyboard_arrows_input_source.gd`
- Create: `scripts/input/gamepad_input_source.gd`
- Create: `scripts/input/composite_input_source.gd`
- Create: `scripts/input/single_player_input_source.gd`
- Create: `tools/validation/validate_local_input_contracts.gd`

**Interfaces:**
- Consumes: Godot 原始键盘和手柄读取 API。
- Produces: `PlayerInputState`、`PlayerInputSource.sample() -> PlayerInputState`、`is_online() -> bool`、`get_source_key() -> StringName`、`reset_edges() -> void`。

- [ ] **Step 1: 写失败的输入契约验证**

验证脚本预加载尚不存在的输入类，并检查移动合并、相反方向抵消、动作逻辑或以及单次边沿触发。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_input_contracts.gd
```

Expected: FAIL，原因是输入类尚不存在。

- [ ] **Step 2: 实现 PlayerInputState**

```gdscript
extends RefCounted
class_name PlayerInputState

var move_vector := Vector2.ZERO
var previous_equipment_just_pressed := false
var next_equipment_just_pressed := false
var use_pressed := false
var use_just_pressed := false
var confirm_just_pressed := false

func merge_from(other: PlayerInputState) -> void:
	move_vector = (move_vector + other.move_vector).limit_length(1.0)
	previous_equipment_just_pressed = (
		previous_equipment_just_pressed or
		other.previous_equipment_just_pressed
	)
	next_equipment_just_pressed = (
		next_equipment_just_pressed or other.next_equipment_just_pressed
	)
	use_pressed = use_pressed or other.use_pressed
	use_just_pressed = use_just_pressed or other.use_just_pressed
	confirm_just_pressed = confirm_just_pressed or other.confirm_just_pressed
```

- [ ] **Step 3: 实现 PlayerInputSource 与边沿状态**

```gdscript
extends RefCounted
class_name PlayerInputSource

var previous_previous_pressed := false
var previous_next_pressed := false
var previous_use_pressed := false
var previous_confirm_pressed := false

func sample() -> PlayerInputState:
	return PlayerInputState.new()

func is_online() -> bool:
	return true

func get_source_key() -> StringName:
	return &"unknown"

func reset_edges() -> void:
	previous_previous_pressed = false
	previous_next_pressed = false
	previous_use_pressed = false
	previous_confirm_pressed = false

func build_state(
	move: Vector2,
	previous: bool,
	next: bool,
	use: bool,
	confirm: bool
) -> PlayerInputState:
	var state := PlayerInputState.new()
	state.move_vector = move.limit_length(1.0)
	state.previous_equipment_just_pressed = previous and not previous_previous_pressed
	state.next_equipment_just_pressed = next and not previous_next_pressed
	state.use_pressed = use
	state.use_just_pressed = use and not previous_use_pressed
	state.confirm_just_pressed = confirm and not previous_confirm_pressed
	previous_previous_pressed = previous
	previous_next_pressed = next
	previous_use_pressed = use
	previous_confirm_pressed = confirm
	return state
```

- [ ] **Step 4: 实现两套键盘输入源**

每套输入源用 `Input.is_physical_key_pressed(...)` 显式计算 Vector2。键盘 2 使用 `KEY_COMMA`、`KEY_PERIOD` 和 `KEY_SLASH`，不要求 Shift。两套键盘的确认键都是 Enter。`get_source_key()` 分别返回 `&"keyboard_wasd"` 和 `&"keyboard_arrows"`。

- [ ] **Step 5: 实现指定设备 ID 的 GamepadInputSource**

构造函数固定 `device_id`。左摇杆使用 `0.20` 死区，LB/RB 读取肩键，RT 轴大于 `0.50` 视为使用，A 产生确认边沿。`is_online()` 检查 `Input.get_connected_joypads().has(device_id)`，离线采样必须返回零输入。

- [ ] **Step 6: 实现组合输入和动态单人手柄列表**

`CompositeInputSource` 逐个采样并调用 `merge_from()`。`SinglePlayerInputSource` 固定持有两套键盘源，每帧同步 `Input.get_connected_joypads()`，并提供：

```gdscript
func set_touch_source(source: PlayerInputSource) -> void:
	touch_source = source
```

- [ ] **Step 7: 运行聚焦验证与导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_input_contracts.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两条命令退出码均为 0。

- [ ] **Step 8: 提交检查点**

```bash
git add scripts/input tools/validation/validate_local_input_contracts.gd
git commit -m "feat: add device-scoped input sources"
```

---

### Task 2: 将武器和放置物统一为循环装备

**Files:**
- Create: `scripts/player/equipment_item.gd`
- Create: `scripts/player/placeable_equipment.gd`
- Create: `scripts/gameplay/place_item_service.gd`
- Create: `scenes/player/equipment/OilBarrelEquipment.tscn`
- Modify: `scripts/combat/weapons/weapon_base.gd`
- Modify: `scripts/player/equipment_controller.gd`
- Modify: `scenes/player/Player.tscn`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Delete: `scripts/gameplay/place_item_controller.gd`
- Create: `tools/validation/validate_equipment_cycle.gd`

**Interfaces:**
- Consumes: 现有武器攻击接口和 `PlaceItemGrid`。
- Produces: `EquipmentItem`、`equipment_changed(display_name: String, remaining_count: int)`、`equip_previous() -> bool`、`equip_next() -> bool`、`set_use_input(pressed: bool, just_pressed: bool, aim: Vector3) -> void`、`get_current_display_name() -> String`、`get_current_count() -> int`、`set_place_item_service(service: PlaceItemService)`。

- [ ] **Step 1: 写失败的装备循环验证**

创建四个假装备，验证正反循环、跳过零库存、放置失败不扣数量、最后一个油桶成功放置后自动切换。运行脚本并确认因接口缺失而失败。

- [ ] **Step 2: 建立 EquipmentItem 并适配 WeaponBase**

```gdscript
extends Node3D
class_name EquipmentItem

func set_use_input(_pressed: bool, _just_pressed: bool, _aim: Vector3) -> void:
	pass

func cancel_use() -> void:
	pass

func is_available() -> bool:
	return true

func get_display_name() -> String:
	return ""

func get_remaining_count() -> int:
	return -1
```

把 `WeaponBase` 改为继承 `EquipmentItem`，`set_use_input(...)` 代理 `set_attack_input(...)`，`cancel_use()` 代理 `cancel_attack()`。

- [ ] **Step 3: 把 PlaceItemController 拆成无库存 PlaceItemService**

迁移网格、阻挡、生成、占用和导航几何信号，删除数量字段。入口固定为：

```gdscript
extends Node
class_name PlaceItemService

func request_place_item(
	requester: CollisionObject3D,
	origin: Vector3,
	direction: Vector3,
	item_scene: PackedScene
) -> bool:
```

- [ ] **Step 4: 实现独立库存 PlaceableEquipment**

`PlaceableEquipment` 保存 `initial_count = 999`、`remaining_count`、`item_scene` 和服务引用。只响应 `just_pressed`，服务返回 true 后扣 1 并发出 `count_changed`。`is_available()` 返回 `remaining_count > 0`。

- [ ] **Step 5: 实现 EquipmentController 循环和耗尽切换**

```gdscript
func _find_available_slot(start: int, direction: int) -> int:
	if equipment_items.is_empty():
		return -1
	for offset in range(1, equipment_items.size() + 1):
		var index := posmod(start + direction * offset, equipment_items.size())
		if equipment_items[index].is_available():
			return index
	return -1
```

初始化装备列表时跳过 null 或不继承 `EquipmentItem` 的条目并发出一次警告。切换前调用 `cancel_use()`；当前特殊物品数量变为 0 时调用 `equip_next()`。没有可用装备时保持当前槽为 -1，主操作无效，并发出 `equipment_changed("无可用装备", -1)`。

每次成功切换或当前特殊物品数量变化时发出：

```gdscript
signal equipment_changed(display_name: String, remaining_count: int)
```

- [ ] **Step 6: 配置 Player 和 DemoArena**

`Player.tscn` 装备顺序固定为手枪、步枪、刀、油桶。`OilBarrelEquipment.tscn` 引用 `scenes/props/ExplosiveBarrel.tscn`。`DemoArena.tscn` 将旧节点替换为 `PlaceItemService`，保留网格和已放置物路径。

- [ ] **Step 7: 运行验证与导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: PASS，四个装备场景和 DemoArena 无资源错误。

- [ ] **Step 8: 提交检查点**

```bash
git add scripts/player scripts/combat/weapons/weapon_base.gd scripts/gameplay/place_item_service.gd scenes/player scenes/gameplay/DemoArena.tscn tools/validation/validate_equipment_cycle.gd
git rm scripts/gameplay/place_item_controller.gd
git commit -m "feat: unify weapons and placeables as equipment"
```

---

### Task 3: 让 PlayerController 消费输入源

**Files:**
- Modify: `scripts/player/player_controller.gd`
- Modify: `scripts/player/equipment_controller.gd`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `project.godot`
- Create: `tools/validation/validate_single_player_input_wiring.gd`

**Interfaces:**
- Consumes: `PlayerInputSource.sample()` 和统一装备接口。
- Produces: `set_input_source(source: PlayerInputSource)`、`get_input_source() -> PlayerInputSource`、`set_place_item_service(service: PlaceItemService)`。

- [ ] **Step 1: 写失败的 Player 输入注入验证**

加载 Player，注入固定输入源，验证一次循环边沿只切一格、使用状态传入当前装备，并确认旧数字键和独立放置动作导出已删除。

- [ ] **Step 2: 替换 PlayerController 输入读取**

```gdscript
var input_source: PlayerInputSource

func set_input_source(value: PlayerInputSource) -> void:
	input_source = value
	if input_source != null:
		input_source.reset_edges()
```

每个物理帧只调用一次 `sample()`。移动使用 `state.move_vector`；前后切换调用装备循环；主操作使用 PlayerController 已有的 `aim_direction` 调用 `equipment.set_use_input(state.use_pressed, state.use_just_pressed, aim_direction)`。输入源不得生成或覆盖独立瞄准向量，左摇杆只控制移动；`aim_direction` 继续由现有 PlayerController 朝向逻辑维护。删除数字键切换、独立放置信号和 `place_item_was_pressed`。

- [ ] **Step 3: 在 DemoArena 注入单人组合输入和放置服务**

```gdscript
var single_player_input := SinglePlayerInputSource.new()

func _ready() -> void:
	player.set_input_source(single_player_input)
	player.set_place_item_service(place_item_service)
```

`single_player_input` 必须是 DemoArena 的字段而不是 `_ready()` 局部变量，供触控接线和下一份计划的 `LocalPlayerSpawner` 复用。本计划仍保留场景中的单个 Player，多人生成由下一份计划处理。

- [ ] **Step 4: 清理旧 gameplay InputMap 动作**

删除 `weapon_pistol`、`weapon_rifle`、`weapon_knife`、`weapon_slot_4`、`place_item` 和重复 `fire`。保留菜单 UI 动作以及 Task 4 尚需迁移的虚拟摇杆动作。

- [ ] **Step 5: 运行验证与导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_single_player_input_wiring.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 6: 提交检查点**

```bash
git add project.godot scripts/player scripts/gameplay/demo_arena.gd tools/validation/validate_single_player_input_wiring.gd
git commit -m "refactor: inject player input state"
```

---

### Task 4: 将触控改为循环装备输入

**Files:**
- Create: `scripts/input/touch_input_source.gd`
- Modify: `scripts/ui/mobile_action_button.gd`
- Modify: `scripts/ui/mobile_controls.gd`
- Modify: `scenes/ui/MobileControls.tscn`
- Modify: `scripts/gameplay/demo_arena.gd`
- Create: `tools/validation/validate_mobile_equipment_controls.gd`

**Interfaces:**
- Consumes: `SinglePlayerInputSource.set_touch_source(source: PlayerInputSource) -> void`。
- Produces: `TouchInputSource.set_game_over_active(value: bool) -> void`、`MobileControls.get_input_source() -> TouchInputSource`。

- [ ] **Step 1: 写失败的移动端场景契约验证**

要求场景包含 `PreviousButton`、`NextButton`、`UseButton`，且不再包含 `FireButton`、`PlaceItemButton` 或按钮 InputMap action。验证正常游戏时 Use 只产生使用状态；`set_game_over_active(true)` 后，同一个 Use 按钮的按下边沿还必须产生 `confirm_just_pressed`，以支持触控单人失败后重开。

- [ ] **Step 2: 让 MobileActionButton 只发出 pressed_changed**

删除 `action` 导出及 `Input.action_press/release`。新增：

```gdscript
signal pressed_changed(value: bool)
```

状态变化后发信号，`cancel()` 仍释放触摸 ID。

- [ ] **Step 3: 实现 TouchInputSource 与 MobileControls 绑定**

`TouchInputSource` 继承 `PlayerInputSource`，由虚拟摇杆和三个按钮更新当前状态。新增 `game_over_active` 和 `set_game_over_active(value: bool)`；采样时正常传递 Use 的 `use_pressed/use_just_pressed`，仅当 `game_over_active` 为 true 时再把 Use 的按下边沿映射到 `confirm_just_pressed`：

```gdscript
var move_vector := Vector2.ZERO
var previous_pressed := false
var next_pressed := false
var use_pressed := false
var game_over_active := false

func set_game_over_active(value: bool) -> void:
	game_over_active = value
	previous_confirm_pressed = use_pressed if value else false

func sample() -> PlayerInputState:
	return build_state(
		move_vector,
		previous_pressed,
		next_pressed,
		use_pressed,
		game_over_active and use_pressed
	)
```

`MobileControls.get_input_source()` 返回该对象。应用失焦、暂停、隐藏时全部归零。

- [ ] **Step 4: 重排三个触控按钮**

右下主按钮为“使用”，其左上和正上方为“上一件”“下一件”。沿用现有视口高度缩放逻辑，三个触控矩形不得重叠。

- [ ] **Step 5: 注入触控源并删除旧库存按钮文案接口**

`DemoArena` 将触控源注入 `SinglePlayerInputSource` 并保留该引用；本计划中 `game_over_active` 保持 false，后续战斗状态计划在全员倒地时负责切换。删除 `set_place_item_status(...)` 和场景级库存同步。

- [ ] **Step 6: 运行验证与导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_mobile_equipment_controls.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 7: 提交检查点**

```bash
git add scripts/input/touch_input_source.gd scripts/ui scripts/gameplay/demo_arena.gd scenes/ui/MobileControls.tscn tools/validation/validate_mobile_equipment_controls.gd
git commit -m "feat: adapt touch controls to equipment cycling"
```

---

### Task 5: 完成本计划验证与 squash

**Files:**
- Verify: `scripts/input/`
- Verify: `scripts/player/player_controller.gd`
- Verify: `scripts/player/equipment_controller.gd`
- Verify: `scripts/gameplay/place_item_service.gd`
- Verify: `scripts/ui/mobile_controls.gd`
- Verify: `project.godot`

**Interfaces:**
- Consumes: 本计划全部最终接口。
- Produces: 后续计划可依赖的设备输入、统一装备和触控单人基础。

- [ ] **Step 1: 分别运行四个聚焦验证脚本**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_input_contracts.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_single_player_input_wiring.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_mobile_equipment_controls.gd
```

- [ ] **Step 2: 运行 headless 导入**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 3: 执行单人 Smoke Test**

验证两套键盘和任一手柄可共同控制 P1；三套按键可循环并使用当前装备；油桶失败不扣数量；触控可移动、切换和使用。

- [ ] **Step 4: 检查旧全局玩家输入读取**

```bash
rg -n "Input\.|is_action_|weapon_pistol|weapon_rifle|weapon_knife|place_item_action" scripts/player scripts/combat scripts/gameplay
```

Expected: 玩家、装备和武器不直接读取全局玩家输入；允许设备输入源和菜单读取 `Input`。

- [ ] **Step 5: squash 检查点提交**

将本计划检查点提交 squash 为一个提交：

```text
feat: add device-scoped input and equipment cycling
```

确认 `git status --short` 为空并记录最终提交哈希。
