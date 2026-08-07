# 本地多人大厅与玩家生成 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增单人/多人菜单分流、设备加入大厅、真实 3D 角色预览，以及根据会话生成一至四名拥有独立输入和装备状态的战斗玩家。

**Architecture:** `GameSession` 只保存模式和输入源描述；大厅使用 `LocalPlayerJoinState` 管理首次加入顺序和设备在线状态。`LocalPlayerSpawner` 在 DemoArena 中把描述转换为输入源并实例化 Player，菜单预览使用精简的真实 GLTF 场景而不是完整战斗玩家。

**Tech Stack:** Godot 4.7.1、GDScript、现有 MainMenu/MenuBackdrop/Player/DemoArena、真实角色 GLTF、独立 headless 场景契约验证。

## Global Constraints

- 前置计划：`2026-08-07-local-multiplayer-input-equipment.md` 必须完成。
- 设计规格：`docs/superpowers/specs/2026-08-07-local-multiplayer-input-shared-camera-design.md`。
- 最多四名本地玩家；两套键盘与每个手柄 ID 都是唯一输入源。
- 设备按首次加入顺序占用最前面的空槽。
- 只有 P1 可开始；不支持单独退出槽位；P1 返回会清空全部玩家。
- 战斗开始后不允许热加入。
- 大厅必须使用真实角色 GLTF；空槽位只显示世界站位标记。
- 玩家之间保持碰撞层 2、掩码 1，可以互相穿过。
- 底部桌面操作说明固定为键盘行和手柄行；触屏显示时隐藏。
- 不恢复 `tests/`，只增加稳定会话和场景契约验证脚本。
- 最终 squash 提交：`feat: add local multiplayer lobby and player spawning`。

---

### Task 1: 建立 GameSession、玩家描述与加入状态

**Files:**
- Create: `scripts/gameplay/game_session.gd`
- Create: `scripts/input/local_player_descriptor.gd`
- Create: `scripts/menu/local_player_join_state.gd`
- Modify: `project.godot`
- Create: `tools/validation/validate_local_join_state.gd`

**Interfaces:**
- Consumes: `KeyboardWasdInputSource`、`KeyboardArrowsInputSource`、`GamepadInputSource`。
- Produces: `GameSession.Mode`、`configure_single()`、`configure_local(players)`、`clear()`、`LocalPlayerDescriptor.create_input_source()`、`LocalPlayerJoinState.try_join(...) -> int`、`set_gamepad_online(...)`。

- [ ] **Step 1: 写失败的加入顺序验证**

验证以下顺序：方向键先加入得到 P1、手柄 ID 2 得到 P2、WASD 得到 P3、同一手柄重复加入被拒绝、第五个来源被拒绝、清空后再次从 P1 开始；无效来源种类或负数手柄 ID 的 `create_input_source()` 返回 null。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_join_state.gd
```

Expected: FAIL，原因是会话和加入状态尚不存在。

- [ ] **Step 2: 实现 LocalPlayerDescriptor**

```gdscript
extends RefCounted
class_name LocalPlayerDescriptor

enum SourceKind {
	KEYBOARD_WASD,
	KEYBOARD_ARROWS,
	GAMEPAD,
}

var player_index := 0
var source_kind := SourceKind.KEYBOARD_WASD
var gamepad_device_id := -1
var online := true

func source_key() -> StringName:
	match source_kind:
		SourceKind.KEYBOARD_WASD:
			return &"keyboard_wasd"
		SourceKind.KEYBOARD_ARROWS:
			return &"keyboard_arrows"
		SourceKind.GAMEPAD:
			return StringName("gamepad_%d" % gamepad_device_id)
		_:
			return &"invalid"

func create_input_source() -> PlayerInputSource:
	match source_kind:
		SourceKind.KEYBOARD_WASD:
			return KeyboardWasdInputSource.new()
		SourceKind.KEYBOARD_ARROWS:
			return KeyboardArrowsInputSource.new()
		SourceKind.GAMEPAD:
			if gamepad_device_id < 0:
				push_warning("Invalid gamepad device id")
				return null
			return GamepadInputSource.new(gamepad_device_id)
		_:
			push_warning("Invalid local player source kind")
			return null
```

- [ ] **Step 3: 实现 LocalPlayerJoinState**

保存 `Array[LocalPlayerDescriptor]`，`try_join(source_kind, device_id)` 先检查 `source_key()` 唯一性，再将新描述放入最前空槽。返回玩家索引，拒绝时返回 -1。`set_gamepad_online()` 只更新同 ID 描述，不释放槽位。

- [ ] **Step 4: 实现 GameSession Autoload**

```gdscript
extends Node
class_name GameSession

enum Mode { SINGLE, LOCAL_MULTIPLAYER }

var mode := Mode.SINGLE
var local_players: Array[LocalPlayerDescriptor] = []
var last_error := ""

func configure_single() -> void:
	mode = Mode.SINGLE
	local_players.clear()
	last_error = ""

func configure_local(players: Array[LocalPlayerDescriptor]) -> void:
	mode = Mode.LOCAL_MULTIPLAYER
	local_players = players.duplicate()
	last_error = ""

func clear() -> void:
	configure_single()
```

在 `project.godot` 注册 `GameSession` Autoload。不要把世界导航或实时镜头状态放入该 Autoload。

- [ ] **Step 5: 运行验证与导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_join_state.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 6: 提交检查点**

```bash
git add project.godot scripts/gameplay/game_session.gd scripts/input/local_player_descriptor.gd scripts/menu/local_player_join_state.gd tools/validation/validate_local_join_state.gd
git commit -m "feat: add local player session state"
```

---

### Task 2: 改造主菜单并新增本地多人大厅

**Files:**
- Modify: `scripts/menu/menu_flow.gd`
- Modify: `scripts/menu/main_menu.gd`
- Modify: `scenes/menu/MainMenu.tscn`
- Create: `scripts/menu/local_multiplayer_lobby.gd`
- Create: `scenes/menu/LocalMultiplayerLobby.tscn`
- Create: `tools/validation/validate_local_multiplayer_menu_scenes.gd`

**Interfaces:**
- Consumes: `GameSession`、`LocalPlayerJoinState`。
- Produces: `MenuFlow.request_single()`、`request_local()`、大厅的 `join_state`、P1 开始和返回清空逻辑。

- [ ] **Step 1: 写失败的菜单场景契约验证**

加载 MainMenu，要求存在 `SinglePlayerButton`、`LocalMultiplayerButton`、`QuitButton`。加载 LocalMultiplayerLobby，要求存在四个世界站位、四个状态标签和底部 P1 操作提示。

- [ ] **Step 2: 扩展 MenuFlow**

把 `request_start()` 拆为：

```gdscript
func request_single() -> bool:
	return _request_start()

func request_local() -> bool:
	return _request_start()

func _request_start() -> bool:
	if state != State.READY:
		return false
	state = State.STARTING
	return true
```

`MenuFlow` 只负责避免重复转场，不写入 `GameSession`，也不决定目标场景。内部仍维持 READY、STARTING、EXIT_CONFIRM 状态。

- [ ] **Step 3: 改造 MainMenu**

单人按钮调用 `GameSession.configure_single()` 后进入 DemoArena。多人按钮先调用 `GameSession.clear()` 清除旧会话，再进入 `LocalMultiplayerLobby.tscn`；大厅确认开始时才调用 `GameSession.configure_local(join_state.players)`。按钮顺序和焦点邻居必须为单人、多人、退出；初始焦点为单人。

- [ ] **Step 4: 实现大厅设备加入事件**

大厅 `_input(event)` 规则：

- `InputEventKey` 按下且非 echo；WASD 任一键加入键盘 1，方向键任一键加入键盘 2。
- `InputEventJoypadButton` 的 A 键加入该 `device`。
- P1 为键盘来源时，Enter 开始；P1 为当前手柄来源时，该设备的 Menu/Start 开始。
- Escape 或 P1 手柄 B 返回主菜单并 `GameSession.clear()`。

开始前把 `join_state.players` 传给 `GameSession.configure_local(...)`，然后进入 DemoArena。监听 `Input.joy_connection_changed`，只更新同 ID 在线状态。P1 离线时开始提示禁用。

- [ ] **Step 5: 运行菜单契约验证和导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_multiplayer_menu_scenes.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 6: 提交检查点**

```bash
git add scripts/menu scenes/menu tools/validation/validate_local_multiplayer_menu_scenes.gd
git commit -m "feat: add local multiplayer menu flow"
```

---

### Task 3: 用真实角色模型实现大厅站位预览

**Files:**
- Create: `scripts/menu/lobby_player_preview.gd`
- Create: `scenes/menu/LobbyPlayerPreview.tscn`
- Modify: `scripts/menu/local_multiplayer_lobby.gd`
- Modify: `scenes/menu/LocalMultiplayerLobby.tscn`
- Create: `tools/validation/validate_lobby_player_preview.gd`

**Interfaces:**
- Consumes: `assets/characters/Characters_Lis_SingleWeapon.gltf` 和其 AnimationPlayer。
- Produces: `LobbyPlayerPreview.set_player_index(index: int)`、`set_online(value: bool)`、`LocalMultiplayerLobby._sync_slots()`。

- [ ] **Step 1: 写失败的真实模型契约验证**

实例化 `LobbyPlayerPreview.tscn`，断言它包含真实 GLTF 实例和 AnimationPlayer，不包含 PlayerController、碰撞、生命、EquipmentController 或 HealthBar3D。

- [ ] **Step 2: 创建精简预览场景**

预览根节点使用 Node3D，通过导出的 `character_scene: PackedScene` 实例化现有角色 GLTF。资源或实例为空时发出一次警告，保留站位标记和设备状态，不阻止开局；成功时隐藏所有嵌入武器，只显示 Rifle，并播放 `Idle_Gun`。如果动画不存在，发出一次警告并保持静态模型。

- [ ] **Step 3: 构建非卡片式 3D 大厅**

在大厅背景中布置四个 Marker3D、地面站位标记和 Label3D。空槽只显示站位标记与加入方式；加入后在 Marker3D 下实例化真实预览模型。离线时保留模型，降低灯光或材质亮度并显示“设备离线”。

- [ ] **Step 4: 确认大厅预览不运行战斗逻辑**

```bash
rg -n "PlayerController|HealthBar3D|EquipmentController|CollisionShape3D|set_attack_input" scenes/menu/LobbyPlayerPreview.tscn scripts/menu/lobby_player_preview.gd
```

Expected: 无战斗控制或碰撞依赖。

- [ ] **Step 5: 运行验证和导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_lobby_player_preview.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 6: 提交检查点**

```bash
git add scripts/menu/lobby_player_preview.gd scripts/menu/local_multiplayer_lobby.gd scenes/menu tools/validation/validate_lobby_player_preview.gd
git commit -m "feat: render joined players in local lobby"
```

---

### Task 4: 根据会话生成战斗玩家并显示长期装备标记

**Files:**
- Create: `scripts/gameplay/local_player_spawner.gd`
- Create: `scripts/ui/player_equipment_label.gd`
- Create: `scenes/ui/PlayerEquipmentLabel.tscn`
- Modify: `scripts/player/player_controller.gd`
- Modify: `scenes/player/Player.tscn`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Create: `tools/validation/validate_local_player_spawning.gd`

**Interfaces:**
- Consumes: `GameSession`、`LocalPlayerDescriptor.create_input_source()`、`EquipmentController.equipment_changed`、`PlaceItemService`。
- Produces: `LocalPlayerSpawner.spawn_players(...) -> Array[PlayerController]`、`PlayerController.player_index`、每名玩家独立的 `PlayerInputSource` 和装备实例。

- [ ] **Step 1: 写失败的玩家生成契约验证**

分别配置单人、两人和四人会话，实例化 DemoArena 并断言 Players 容器中的玩家数量、索引、输入源唯一性、碰撞层和掩码正确。

- [ ] **Step 2: 新增 Players 容器与出生标记**

从 DemoArena 删除预放 `Player`，新增 `Players` Node3D 和四个 Marker3D。四个标记位于当前出生区域附近，全部在初始镜头安全范围内。

- [ ] **Step 3: 实现 LocalPlayerSpawner**

```gdscript
func spawn_players(
	container: Node3D,
	spawn_points: Array[Marker3D],
	place_item_service: PlaceItemService,
	single_player_input: SinglePlayerInputSource
) -> Array[PlayerController]:
```

单人模式生成一个 P1 并注入 DemoArena 已绑定触控源的 `single_player_input`，不得另建组合输入源。多人模式逐个调用描述的 `create_input_source()`；返回 null 时设置 `GameSession.last_error`，释放本次已经生成的玩家并返回空数组。生成前使用玩家 CapsuleShape3D 对每个标记做空间查询；阻挡时尝试预定义备用偏移。任一会话玩家无法生成时同样清理本次已生成玩家、设置 `GameSession.last_error` 并返回空数组，DemoArena 返回上一界面，场内不得留下部分玩家。

- [ ] **Step 4: 添加长期 P 编号与装备标记**

`PlayerEquipmentLabel` 接收：

```gdscript
func set_status(player_index: int, display_name: String, count: int) -> void:
	text = "P%d · %s" % [player_index + 1, display_name]
	if count >= 0:
		text += " ×%d" % count
```

Player 连接 `equipment_changed(display_name: String, remaining_count: int)` 后，立即使用 `get_current_display_name()` 和 `get_current_count()` 调用一次 `set_status(...)`，确保标签从出生起长期显示。后续装备切换或数量变化实时刷新；倒地时把文案改为 `P# · 倒地`。不修改角色颜色和血条颜色。

- [ ] **Step 5: 固定桌面双行操作说明**

把 ControlsPanel 改为两行：

```text
键盘：WASD 移动 / Q E 切换 / Space 使用 | 方向键移动 / < > 切换 / / 使用
手柄：LS 移动 / LB RB 切换 / RT 使用
```

继续使用 MobileControls 的 `desktop_help_path`，触控显示时隐藏该面板。

- [ ] **Step 6: 运行生成验证与导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_player_spawning.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 7: 提交检查点**

```bash
git add scripts/gameplay scripts/player/player_controller.gd scripts/ui scenes/gameplay/DemoArena.tscn scenes/player/Player.tscn scenes/ui tools/validation/validate_local_player_spawning.gd
git commit -m "feat: spawn local players from session"
```

---

### Task 5: 完成本计划视觉验收与 squash

**Files:**
- Verify: `scenes/menu/MainMenu.tscn`
- Verify: `scenes/menu/LocalMultiplayerLobby.tscn`
- Verify: `scenes/menu/LobbyPlayerPreview.tscn`
- Verify: `scenes/gameplay/DemoArena.tscn`
- Verify: `scenes/player/Player.tscn`

**Interfaces:**
- Consumes: 本计划全部会话、大厅和生成接口。
- Produces: 后续战斗和镜头计划使用的 `Array[PlayerController]` 与玩家在线状态。

- [ ] **Step 1: 运行四个聚焦验证和 headless 导入**

分别运行 `validate_local_join_state.gd`、`validate_local_multiplayer_menu_scenes.gd`、`validate_lobby_player_preview.gd`、`validate_local_player_spawning.gd`，然后运行 headless editor 导入。全部必须退出码 0。

- [ ] **Step 2: 执行大厅人工验收**

1. 主菜单显示单人、多人、退出。
2. 方向键先加入时成为 P1；WASD 和多个手柄按顺序占后续槽位。
3. 空槽只有地面标记；加入后生成真实角色模型并播放 Idle_Gun。
4. 断开手柄后模型保留并显示设备离线；相同 ID 恢复。
5. P1 可开始或返回清空，其他玩家不能开始。

- [ ] **Step 3: 执行战斗玩家 Smoke Test**

检查一至四人生成、独立输入、玩家互相穿过、长期 `P# · 当前装备` 标记和固定双行操作说明。

- [ ] **Step 4: squash 检查点提交**

将本计划检查点提交 squash 为：

```text
feat: add local multiplayer lobby and player spawning
```

确认工作树干净并记录最终提交哈希。
