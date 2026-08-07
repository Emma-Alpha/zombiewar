# 本地多人战斗状态 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让僵尸在多名玩家之间稳定选敌，支持独立死亡和手柄离线状态，并只在全员倒地后由 P1 重新开始。

**Architecture:** 场景级 `PlayerRegistry` 是玩家集合的唯一事实源。纯数学 `ZombieTargetSelector` 从注册表候选中选择最近存活玩家并应用切换迟滞；`LocalTeamState` 聚合倒地状态和 P1 确认输入，DemoArena 只负责 UI 与场景重载。

**Tech Stack:** Godot 4.7.1、GDScript、现有 ZombieTarget/DemoArena/PlayerController、聚焦 headless 契约验证。

## Global Constraints

- 前置计划：`2026-08-07-local-multiplayer-input-equipment.md` 和 `2026-08-07-local-multiplayer-lobby-spawning.md` 必须完成。
- 设计规格：`docs/superpowers/specs/2026-08-07-local-multiplayer-input-shared-camera-design.md`。
- 僵尸选择感知范围内最近的存活玩家；离线但存活玩家仍可成为目标。
- 新目标只有明显更近时才替换仍有效的当前目标。
- 单个玩家倒地不结束游戏；全员倒地才失败。
- 倒地玩家停止输入和攻击，不再被僵尸选中。
- 手柄离线不暂停，不释放槽位，不允许其他手柄接管。
- 多人模式只有 P1 的 Enter 或 A 能重开；单人组合源接受 Enter、任一手柄 A 或触控使用按钮。
- 不恢复 `tests/`；只保留稳定选敌和团队状态验证。
- 最终 squash 提交：`feat: add local multiplayer combat state`。

---

### Task 1: 建立玩家注册表和稳定选敌数学

**Files:**
- Create: `scripts/gameplay/player_registry.gd`
- Create: `scripts/combat/zombie_target_selector.gd`
- Create: `tools/validation/validate_zombie_target_selector.gd`

**Interfaces:**
- Consumes: `PlayerController.is_alive()`、`global_position`。
- Produces: `PlayerRegistry.register_player(player)`、`unregister_player(player)`、`get_players() -> Array[PlayerController]`、`ZombieTargetSelector.select_target(...) -> PlayerController`。

- [ ] **Step 1: 写失败的选敌验证**

验证：范围外玩家被排除；最近存活玩家被选中；倒地玩家被排除；离线但存活玩家仍可选；当前目标有效且新目标只近 0.1 时不切换，新目标近 0.6 时切换。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_zombie_target_selector.gd
```

Expected: FAIL，原因是注册表和选择器不存在。

- [ ] **Step 2: 实现 PlayerRegistry**

```gdscript
extends Node
class_name PlayerRegistry

signal player_registered(player: PlayerController)
signal player_unregistered(player: PlayerController)

var players: Array[PlayerController] = []

func register_player(player: PlayerController) -> void:
	if player == null or players.has(player):
		return
	players.append(player)
	player.tree_exiting.connect(unregister_player.bind(player), CONNECT_ONE_SHOT)
	player_registered.emit(player)

func unregister_player(player: PlayerController) -> void:
	if players.erase(player):
		player_unregistered.emit(player)

func get_players() -> Array[PlayerController]:
	return players.duplicate()
```

- [ ] **Step 3: 实现 ZombieTargetSelector**

```gdscript
extends RefCounted
class_name ZombieTargetSelector

static func select_target(
	origin: Vector3,
	current: PlayerController,
	candidates: Array[PlayerController],
	perception_range: float,
	switch_margin: float
) -> PlayerController:
	var current_distance := INF
	if _is_candidate(current, origin, perception_range):
		current_distance = origin.distance_to(current.global_position)
	var best := current if current_distance < INF else null
	var best_distance := current_distance
	for candidate in candidates:
		if not _is_candidate(candidate, origin, perception_range):
			continue
		var distance := origin.distance_to(candidate.global_position)
		if distance + maxf(switch_margin, 0.0) < best_distance:
			best = candidate
			best_distance = distance
	return best
```

辅助 `_is_candidate` 只检查实例有效、存活和距离，不检查输入在线状态。

- [ ] **Step 4: 运行验证和导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_zombie_target_selector.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 5: 提交检查点**

```bash
git add scripts/gameplay/player_registry.gd scripts/combat/zombie_target_selector.gd tools/validation/validate_zombie_target_selector.gd
git commit -m "feat: add multiplayer zombie target selection"
```

---

### Task 2: 让 ZombieTarget 动态选择玩家

**Files:**
- Modify: `scripts/combat/zombie_target.gd`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Create: `tools/validation/validate_zombie_multiplayer_wiring.gd`

**Interfaces:**
- Consumes: `PlayerRegistry.get_players()`、`ZombieTargetSelector.select_target(...)`。
- Produces: `ZombieTarget.set_player_registry(registry: PlayerRegistry)`、`target_switch_margin` 导出参数。

- [ ] **Step 1: 写失败的场景接线验证**

要求 DemoArena 存在 `PlayerRegistry` 节点，所有新生成 ZombieTarget 都连接同一注册表，旧 `set_attack_target(player)` 单玩家接线不再由 DemoArena 调用。

- [ ] **Step 2: 改造 ZombieTarget**

新增：

```gdscript
@export var target_switch_margin := 0.5
var player_registry: PlayerRegistry

func set_player_registry(value: PlayerRegistry) -> void:
	player_registry = value
```

每个物理帧在行为状态计算前刷新：

```gdscript
if player_registry != null:
	attack_target = ZombieTargetSelector.select_target(
		global_position,
		attack_target,
		player_registry.get_players(),
		perception_range,
		target_switch_margin
	)
```

保留现有导航、障碍检查、攻击周期和 `_target_is_alive()`。

- [ ] **Step 3: 让 DemoArena 注册玩家并给僵尸注入注册表**

玩家生成完成后逐个 `register_player()`。`_wire_target()` 只注入导航管理器、玩家注册表和难度，不再查找固定 `Player` 节点。

- [ ] **Step 4: 运行接线验证和导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_zombie_multiplayer_wiring.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 5: 提交检查点**

```bash
git add scripts/combat/zombie_target.gd scripts/gameplay/demo_arena.gd scenes/gameplay/DemoArena.tscn tools/validation/validate_zombie_multiplayer_wiring.gd
git commit -m "feat: retarget zombies across local players"
```

---

### Task 3: 聚合玩家倒地、失败和 P1 重开

**Files:**
- Create: `scripts/gameplay/local_team_state.gd`
- Modify: `scripts/player/player_controller.gd`
- Modify: `scripts/gameplay/demo_arena.gd`
- Create: `tools/validation/validate_local_team_state.gd`

**Interfaces:**
- Consumes: `PlayerController.died`、`PlayerController.get_last_input_state()`、`PlayerInputState.confirm_just_pressed`。
- Produces: `LocalTeamState.setup(players)`、`all_players_defeated`、`is_all_defeated() -> bool`、`sample_restart_requested() -> bool`。

- [ ] **Step 1: 写失败的团队状态验证**

验证：四人中一人倒地不失败；最后一人倒地发一次全员失败；P2 确认不重开；P1 确认重开；单人组合源确认可重开。

- [ ] **Step 2: 实现 LocalTeamState**

```gdscript
extends Node
class_name LocalTeamState

signal all_players_defeated

var players: Array[PlayerController] = []
var defeat_emitted := false

func setup(value: Array[PlayerController]) -> void:
	players = value.duplicate()
	defeat_emitted = false
	for player in players:
		player.died.connect(_on_player_died)

func is_all_defeated() -> bool:
	return not players.is_empty() and players.all(
		func(player: PlayerController) -> bool: return not player.is_alive()
	)

func sample_restart_requested() -> bool:
	if not is_all_defeated() or players.is_empty():
		return false
	return players[0].get_last_input_state().confirm_just_pressed

func _on_player_died() -> void:
	if defeat_emitted or not is_all_defeated():
		return
	defeat_emitted = true
	all_players_defeated.emit()
```

`LocalTeamState` 只读取 PlayerController 的最近快照，不直接调用输入源。不得让 `LocalTeamState` 和 PlayerController 在同一帧各自调用 `sample()`。

- [ ] **Step 3: 给 PlayerController 暴露在线状态和最后输入快照**

新增：

```gdscript
var last_input_state := PlayerInputState.new()

func is_input_online() -> bool:
	return input_source != null and input_source.is_online()

func get_last_input_state() -> PlayerInputState:
	return last_input_state
```

Player 每个物理帧采样一次并保存快照；即使玩家已经倒地也继续采样，但倒地状态只允许失败界面的确认输入，必须忽略移动、切换装备和使用装备。`LocalTeamState.sample_restart_requested()` 读取 P1 的 `get_last_input_state()`。

- [ ] **Step 4: 改造 DemoArena 失败 UI**

移除单一 `player_defeated`。连接 `all_players_defeated` 后显示 GameOver 和 RestartButton，并对单人触控源调用 `set_game_over_active(true)`；离开失败状态或重载前恢复为 false。每个玩家死亡只更新团队状态；其余玩家继续。P1 确认或 RestartButton 请求调用现有场景重载保护。

- [ ] **Step 5: 运行团队状态验证与导入检查**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_team_state.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 6: 提交检查点**

```bash
git add scripts/gameplay/local_team_state.gd scripts/gameplay/demo_arena.gd scripts/player/player_controller.gd tools/validation/validate_local_team_state.gd
git commit -m "feat: end local runs when all players fall"
```

---

### Task 4: 验证手柄离线、伤害与直接友伤边界

**Files:**
- Modify: `scripts/input/gamepad_input_source.gd`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scripts/combat/weapons/ranged_weapon.gd`
- Modify: `scripts/combat/weapons/melee_weapon.gd`
- Create: `tools/validation/validate_local_disconnect_contract.gd`

**Interfaces:**
- Consumes: `GamepadInputSource.is_online()`、玩家注册表和现有武器查询。
- Produces: 离线零输入、槽位保留、武器不直接命中 Player 的稳定契约。

- [ ] **Step 1: 写失败的断线契约验证**

构造离线 GamepadInputSource，验证 source key 和设备 ID 保留、采样归零、`is_online()` 为 false。验证玩家仍在 PlayerRegistry 中且 `is_alive()` 为 true 时可被 ZombieTargetSelector 选中。

- [ ] **Step 2: 确认武器查询不会直接选择 Player 层**

检查 ranged ray 和 melee target query 的碰撞掩码或目标分组，只包含世界和僵尸目标，不因多人改造加入 Player 层。环境爆炸继续使用现有 damageable_targets 范围规则。

- [ ] **Step 3: 保持同 ID 恢复语义**

不得替换描述的 `gamepad_device_id`。当 `Input.get_connected_joypads()` 再次包含该 ID 时，原 `GamepadInputSource` 自动恢复，不新建玩家、不转移槽位。

- [ ] **Step 4: 运行验证与 headless 导入**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_disconnect_contract.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

- [ ] **Step 5: 提交检查点**

```bash
git add scripts/input/gamepad_input_source.gd scripts/gameplay/demo_arena.gd scripts/combat/weapons tools/validation/validate_local_disconnect_contract.gd
git commit -m "fix: preserve disconnected local players"
```

---

### Task 5: 完成本计划 Smoke Test 与 squash

**Files:**
- Verify: `scripts/gameplay/player_registry.gd`
- Verify: `scripts/combat/zombie_target_selector.gd`
- Verify: `scripts/combat/zombie_target.gd`
- Verify: `scripts/gameplay/local_team_state.gd`
- Verify: `scripts/gameplay/demo_arena.gd`

**Interfaces:**
- Consumes: 本计划所有多人战斗接口。
- Produces: 共享镜头计划可读取的玩家存活与在线状态。

- [ ] **Step 1: 运行四个聚焦验证和 headless 导入**

分别运行选敌、接线、团队状态和断线验证脚本，再运行 headless editor 导入；全部必须退出码 0。

- [ ] **Step 2: 执行多人战斗人工验收**

1. 僵尸追逐最近存活玩家。
2. 两名玩家距离接近时目标不频繁来回切换。
3. 手柄断线玩家停止输入但仍会被攻击。
4. 单人倒地后其他玩家继续。
5. 全员倒地后才显示失败。
6. 多人只有 P1 的 Enter 或 A 能重开；单人还可用触控“使用”按钮重开。

- [ ] **Step 3: 检查固定单玩家依赖已移除**

```bash
rg -n "get_node_or_null\(\"Player\"\)|set_attack_target\(player\)|player_defeated" scripts/gameplay scripts/combat
```

Expected: DemoArena 和 ZombieTarget 不依赖固定唯一 Player。

- [ ] **Step 4: squash 检查点提交**

将本计划检查点提交 squash 为：

```text
feat: add local multiplayer combat state
```

确认工作树干净并记录最终提交哈希。
