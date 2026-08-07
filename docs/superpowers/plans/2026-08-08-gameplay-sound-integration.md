# 游戏音效接入实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `docs/sounds_975 2/` 中用途明确且当前玩法可触发的音效接入游戏，并保证高频播放不发生运行时同步加载或无上限节点分配。

**Architecture:** 长生命周期的枪械、角色、爆炸和菜单复用自身音频播放器；`DemoArena` 提供场景级固定容量 `SpatialSfxPool`，供墙面命中、拾取和放置等短生命周期事件使用。所有 `AudioStream` 通过场景资源或 `preload()` 预引用，运行时热路径只选择共享资源并发起播放。

**Tech Stack:** Godot 4.7.1、GDScript、`AudioStreamPlayer`、`AudioStreamPlayer3D`、MP3 导入资源。

## 全局约束

- 运行时代码和场景不得引用 `res://docs/sounds_975 2/`；选中的素材复制到 `res://assets/sfx/boxhead/` 并语义化命名。
- 射击、受击、拾取、放置和物理回调等热路径中不得调用 `load()`。
- 不新增 Autoload；3D 单次音效池由每个可玩 3D 世界场景拥有。
- 播放器池容量固定，耗尽时复用最早的播放器，不得阻塞或改变玩法结果。
- 音效不得改变伤害、弹药、武器散布、掉落、导航、输入或存档状态。
- `CombatFxPrewarmer` 的预热流程保持静音。
- 本改动属于表现层接线，用户已确认不新增低价值持久自动测试；使用 Godot headless 导入、静态检查和人工听感验收。
- 原始素材目录和主工作区中未跟踪的其他设计/计划文件不纳入本功能提交。

---

### Task 1：整理运行时素材并建立固定容量 3D 音效池

**Files:**
- Create: `assets/sfx/boxhead/*.mp3`
- Create: `scripts/fx/spatial_sfx_pool.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`

**Interfaces:**
- Produces: `SpatialSfxPool.find_for(node: Node) -> SpatialSfxPool`
- Produces: `SpatialSfxPool.play_at(stream: AudioStream, world_position: Vector3, volume_db: float = 0.0, pitch_scale: float = 1.0, max_distance: float = 32.0) -> void`
- Consumes: Godot 场景树组 `spatial_sfx_pool`

- [ ] **Step 1：复制并语义化命名当前会使用的 19 个 MP3**

从主工作区 `/Users/yewei/yyw/project/zombiewar/docs/sounds_975 2/` 复制以下文件到工作树 `assets/sfx/boxhead/`：

```text
sound_539.mp3 -> creature_fall.mp3
sound_540.mp3 -> player_scream_1.mp3
sound_541.mp3 -> player_scream_2.mp3
sound_542.mp3 -> zombie_ambience_1.mp3
sound_543.mp3 -> zombie_ambience_2.mp3
sound_544.mp3 -> zombie_ambience_3.mp3
sound_545.mp3 -> zombie_ambience_4.mp3
sound_546.mp3 -> zombie_attack.mp3
sound_547.mp3 -> zombie_hit.mp3
sound_548.mp3 -> explosion.mp3
sound_549.mp3 -> barrel_place.mp3
sound_551.mp3 -> pickup.mp3
sound_553.mp3 -> bullet_wall_1.mp3
sound_554.mp3 -> bullet_wall_2.mp3
sound_555.mp3 -> bullet_wall_3.mp3
sound_558.mp3 -> pistol_fire.mp3
sound_562.mp3 -> rifle_fire.mp3
sound_563.mp3 -> world_end.mp3
sound_564.mp3 -> ui_click.mp3
```

复制后运行：

```bash
find assets/sfx/boxhead -maxdepth 1 -type f -name '*.mp3' | sort
```

Expected: 精确列出 19 个语义化 MP3，不包含用途不明或当前玩法不可用的素材。

- [ ] **Step 2：实现固定容量播放器池**

创建 `scripts/fx/spatial_sfx_pool.gd`，核心实现为：

```gdscript
extends Node3D
class_name SpatialSfxPool

const GROUP_NAME := &"spatial_sfx_pool"

@export_range(1, 64, 1) var capacity := 16

var players: Array[AudioStreamPlayer3D] = []
var cursor := 0

func _ready() -> void:
	for index in range(capacity):
		var player := AudioStreamPlayer3D.new()
		player.name = "Voice%02d" % (index + 1)
		add_child(player)
		players.append(player)

static func find_for(node: Node) -> SpatialSfxPool:
	if node == null or node.get_tree() == null:
		return null
	return node.get_tree().get_first_node_in_group(GROUP_NAME) as SpatialSfxPool

func play_at(
	stream: AudioStream,
	world_position: Vector3,
	volume_db := 0.0,
	pitch_scale := 1.0,
	max_distance := 32.0
) -> void:
	if stream == null or players.is_empty():
		return
	var player := players[cursor]
	cursor = (cursor + 1) % players.size()
	player.stop()
	player.stream = stream
	player.global_position = world_position
	player.volume_db = volume_db
	player.pitch_scale = pitch_scale
	player.max_distance = max_distance
	player.play()
```

- [ ] **Step 3：将播放器池挂到 DemoArena**

将 `scenes/gameplay/DemoArena.tscn` 的 `load_steps` 从 55 增加到 56，增加 `id="29_spatial_sfx_pool"` 的脚本外部资源，并在场景根节点下加入：

```text
[node name="SpatialSfxPool" type="Node3D" parent="." groups=["spatial_sfx_pool"]]
script = ExtResource("29_spatial_sfx_pool")
capacity = 16
```

- [ ] **Step 4：运行导入和静态检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
rg -n 'load\(' scripts/fx/spatial_sfx_pool.gd
git diff --check
```

Expected: Godot 退出码 0；`rg` 无输出；`git diff --check` 无输出。

- [ ] **Step 5：提交任务**

```bash
git add assets/sfx/boxhead scripts/fx/spatial_sfx_pool.gd scenes/gameplay/DemoArena.tscn
git commit -m "feat: add pooled spatial sound playback"
```

---

### Task 2：接入枪械、墙面命中、爆炸和菜单音效

**Files:**
- Modify: `scripts/combat/weapons/ranged_weapon.gd`
- Modify: `scenes/weapons/Pistol.tscn`
- Modify: `scenes/weapons/Rifle.tscn`
- Modify: `scenes/fx/BarrelExplosion.tscn`
- Modify: `scenes/menu/MainMenu.tscn`

**Interfaces:**
- Consumes: `SpatialSfxPool.find_for(node)`
- Consumes: `SpatialSfxPool.play_at(stream, world_position, volume_db, pitch_scale, max_distance)`
- Produces: `_resolve_shot()` 字典中的 `hit_world_surface: bool`

- [ ] **Step 1：为射击解析结果增加世界障碍标记**

在 `ranged_weapon.gd` 中加入三个墙面命中共享资源和缓存池引用：

```gdscript
const WALL_IMPACT_SOUNDS := [
	preload("res://assets/sfx/boxhead/bullet_wall_1.mp3"),
	preload("res://assets/sfx/boxhead/bullet_wall_2.mp3"),
	preload("res://assets/sfx/boxhead/bullet_wall_3.mp3"),
]

var spatial_sfx_pool: SpatialSfxPool
```

在 `_ready()` 缓存 `SpatialSfxPool.find_for(self)`。修改 `_resolve_shot()`：仅当射线碰到非 `damageable_targets` 且 `_apply_damage()` 未返回有效命中时，将 `hit_world_surface` 设为 `true`；未碰撞和命中僵尸/油桶均为 `false`。返回字典必须包含：

```gdscript
return {
	"end_position": end_position,
	"hit_result": summary,
	"hit_world_surface": hit_world_surface,
}
```

- [ ] **Step 2：在开火后通过池播放随机墙面命中声**

在 `_fire()` 读取 `hit_world_surface`；为真且池存在时执行：

```gdscript
var wall_stream: AudioStream = WALL_IMPACT_SOUNDS.pick_random()
spatial_sfx_pool.play_at(
	wall_stream,
	hit_position,
	-7.0,
	randf_range(0.96, 1.04),
	24.0
)
```

保留枪口声音现有的轻微随机音高。

- [ ] **Step 3：替换枪械与爆炸占位音效**

- `Pistol.tscn` 的 `ShotAudio.stream` 改为 `pistol_fire.mp3`。
- `Rifle.tscn` 的 `ShotAudio.stream` 改为 `rifle_fire.mp3`。
- `BarrelExplosion.tscn` 的播放器改为 `explosion.mp3`，移除为占位声设置的 `pitch_scale = 0.72`，保留合理的 3D 距离和音量。
- 不修改 `barrel_explosion.gd` 的 `warmup_for_render()` 静音分支。

- [ ] **Step 4：统一菜单点击素材**

在 `MainMenu.tscn` 中只声明一次 `ui_click.mp3` 外部资源，让 `SelectAudio`、`ConfirmAudio`、`BackAudio` 共享该资源。保持 `main_menu.gd` 现有确认、返回和焦点防重播逻辑不变。

- [ ] **Step 5：验证并提交**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
rg -n 'impactMetal_heavy_002|docs/game_resources_zombie_prototype/assets/sfx/interface' scenes/weapons scenes/fx/BarrelExplosion.tscn scenes/menu/MainMenu.tscn
rg -n 'load\(' scripts/combat/weapons/ranged_weapon.gd
git diff --check
```

Expected: Godot 退出码 0；两次 `rg` 无输出；diff 检查通过。

```bash
git add scripts/combat/weapons/ranged_weapon.gd scenes/weapons/Pistol.tscn scenes/weapons/Rifle.tscn scenes/fx/BarrelExplosion.tscn scenes/menu/MainMenu.tscn
git commit -m "feat: add weapon and environment sounds"
```

---

### Task 3：接入拾取和成功放置音效

**Files:**
- Modify: `scripts/gameplay/pickup_chest.gd`
- Modify: `scripts/gameplay/place_item_service.gd`
- Modify: `scripts/gameplay/demo_arena.gd`

**Interfaces:**
- Consumes: `SpatialSfxPool.find_for(node)`
- Produces: `PlaceItemService.item_placed(world_position: Vector3)`

- [ ] **Step 1：成功拾取后播放空间音效**

在 `pickup_chest.gd` 预引用 `pickup.mp3`，并在 `_ready()` 缓存池：

```gdscript
const PICKUP_SOUND := preload("res://assets/sfx/boxhead/pickup.mp3")

var spatial_sfx_pool: SpatialSfxPool
```

在奖励成功、锁定拾取且 `queue_free()` 前调用：

```gdscript
if spatial_sfx_pool != null:
	spatial_sfx_pool.play_at(PICKUP_SOUND, global_position, -5.0, 1.0, 24.0)
```

失败领取、死亡玩家或重复进入不得播放。

- [ ] **Step 2：让放置服务报告实际成功位置**

在 `place_item_service.gd` 新增：

```gdscript
signal item_placed(world_position: Vector3)
```

仅在物体已加入容器、设置最终 `global_position`、成功预留格子并登记追踪之后发射 `item_placed.emit(item.global_position)`。所有 `_reject()` 分支不得发射。

- [ ] **Step 3：DemoArena 响应成功放置事件**

在 `demo_arena.gd` 预引用 `barrel_place.mp3`。在 `_wire_dependencies()` 中以防重复方式连接 `PlaceItemService.item_placed`，回调为：

```gdscript
func _on_item_placed(world_position: Vector3) -> void:
	var pool := SpatialSfxPool.find_for(self)
	if pool != null:
		pool.play_at(BARREL_PLACE_SOUND, world_position, -4.0, 1.0, 24.0)
```

- [ ] **Step 4：验证并提交**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
rg -n 'load\(' scripts/gameplay/pickup_chest.gd scripts/gameplay/place_item_service.gd scripts/gameplay/demo_arena.gd
git diff --check
```

Expected: Godot 退出码 0；`rg` 无输出；diff 检查通过。

```bash
git add scripts/gameplay/pickup_chest.gd scripts/gameplay/place_item_service.gd scripts/gameplay/demo_arena.gd
git commit -m "feat: add pickup and placement sounds"
```

---

### Task 4：接入僵尸、玩家死亡和对局结束音效

**Files:**
- Modify: `scripts/combat/zombie_target.gd`
- Modify: `scenes/targets/ZombieTarget.tscn`
- Modify: `scripts/player/player_controller.gd`
- Modify: `scenes/player/Player.tscn`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`

**Interfaces:**
- Produces: 僵尸语音调度状态 `ambient_audio_remaining` 与 `hit_audio_cooldown`
- Consumes: `LocalTeamState.all_players_defeated`

- [ ] **Step 1：为僵尸场景配置复用播放器**

在 `ZombieTarget.tscn` 增加三个 `AudioStreamPlayer3D`：

```text
VoiceAudio   # 动态选择呻吟或受击资源
AttackAudio  # 固定 zombie_attack.mp3
DeathAudio   # 固定 creature_fall.mp3
```

统一设置有限 `max_distance`，声音音量以近距离清晰、远距离不淹没战斗为准。

- [ ] **Step 2：实现僵尸受击、攻击、呻吟和死亡调度**

在 `zombie_target.gd` 预引用四个呻吟变体和 `zombie_hit.mp3`，声明：

```gdscript
const AMBIENT_SOUNDS := [
	preload("res://assets/sfx/boxhead/zombie_ambience_1.mp3"),
	preload("res://assets/sfx/boxhead/zombie_ambience_2.mp3"),
	preload("res://assets/sfx/boxhead/zombie_ambience_3.mp3"),
	preload("res://assets/sfx/boxhead/zombie_ambience_4.mp3"),
]
const HIT_SOUND := preload("res://assets/sfx/boxhead/zombie_hit.mp3")

var audio_rng := RandomNumberGenerator.new()
var ambient_audio_remaining := 0.0
var hit_audio_cooldown := 0.0
```

要求：

- `_ready()` 使用实例路径哈希初始化 `audio_rng`，初始呻吟延迟随机为 2—8 秒。
- `_process(delta)` 递减两个计时值；呻吟到期时，若未死亡且 `VoiceAudio` 未播放，则随机选择共享资源、设置轻微音高后播放，并把下次间隔设为 8—18 秒。
- 有效受击且冷却为 0 时，以 `zombie_hit.mp3` 中断当前呻吟并播放，冷却设为约 0.12 秒。
- `_play_attack_animation()` 同步播放 `AttackAudio`。
- `_on_depleted()` 停止语音和攻击播放器、播放 `DeathAudio`；最终释放等待时间取死亡动画等待与死亡音频长度的最大值。

- [ ] **Step 3：为玩家配置死亡声音**

在 `Player.tscn` 增加 `DeathVoiceAudio` 与 `FallAudio` 两个 `AudioStreamPlayer3D`，`FallAudio` 固定使用 `creature_fall.mp3`。在 `player_controller.gd` 预引用两种惨叫，在 `_on_depleted()` 中随机设置并播放 `DeathVoiceAudio`，同时播放 `FallAudio`。玩家仍保持原有倒地状态，不新增释放或等待逻辑。

- [ ] **Step 4：全队首次倒地时播放一次结束声**

在 `DemoArena.tscn` 增加根节点下的 `AudioStreamPlayer`：

```text
[node name="GameOverAudio" type="AudioStreamPlayer" parent="."]
stream = world_end.mp3
```

在 `_on_all_players_defeated()` 通过现有 `team_defeated` 守卫后播放一次；重复死亡信号和等待重启期间不得重复播放。

- [ ] **Step 5：验证并提交**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
rg -n 'load\(' scripts/combat/zombie_target.gd scripts/player/player_controller.gd scripts/gameplay/demo_arena.gd
git diff --check
```

Expected: Godot 退出码 0；`rg` 无输出；diff 检查通过。

```bash
git add scripts/combat/zombie_target.gd scenes/targets/ZombieTarget.tscn scripts/player/player_controller.gd scenes/player/Player.tscn scripts/gameplay/demo_arena.gd scenes/gameplay/DemoArena.tscn
git commit -m "feat: add creature and game state sounds"
```

---

### Task 5：完成静态、导入与人工性能验收准备

**Files:**
- Modify if needed: 本计划涉及的脚本、场景和音频资源
- Verify: `docs/superpowers/specs/2026-08-08-gameplay-sound-integration-design.md`

**Interfaces:**
- Consumes: 前四个任务的全部音效触发点
- Produces: 可供用户执行的游戏内听感与性能验收清单

- [ ] **Step 1：检查资源范围和运行时路径**

Run:

```bash
test "$(find assets/sfx/boxhead -maxdepth 1 -type f -name '*.mp3' | wc -l | tr -d ' ')" = 19
rg -n 'res://docs/sounds_975 2|sound_(174|175|184|192|193|550|552|556|557|559|560|561)\.mp3' scripts scenes resources assets
rg -n '(load|ResourceLoader\.load)\(' scripts/combat/weapons/ranged_weapon.gd scripts/combat/zombie_target.gd scripts/player/player_controller.gd scripts/gameplay/pickup_chest.gd scripts/gameplay/place_item_service.gd scripts/gameplay/demo_arena.gd scripts/fx/spatial_sfx_pool.gd
```

Expected: 文件数量断言成功；两个 `rg` 均无输出。

- [ ] **Step 2：检查播放器池容量与节点增长约束**

确认 `SpatialSfxPool` 只在 `_ready()` 创建 `capacity` 个播放器，`play_at()` 不调用 `new()`、`add_child()` 或 `load()`；检查僵尸呻吟随机选择只发生在计时到期时。

Run:

```bash
rg -n 'AudioStreamPlayer3D\.new|add_child|load\(' scripts/fx/spatial_sfx_pool.gd
rg -n 'ambient_audio_remaining|randf_range\(8\.0, 18\.0\)' scripts/combat/zombie_target.gd
```

Expected: `new` 与 `add_child` 只位于 `_ready()`；呻吟调度存在明确计时逻辑。

- [ ] **Step 3：执行最终 Godot 导入检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
git diff --check
git status --short
```

Expected: Godot 退出码 0，无脚本/场景/导入错误；diff 检查通过；仅出现本功能预期文件。

- [ ] **Step 4：准备人工验收步骤**

向用户提供以下精确操作：

1. 主菜单移动焦点、确认进入游戏、返回退出确认，检查短点击声不会密集重叠。
2. 分别用手枪和自动步枪开火，确认音色不同且连射无首次明显卡顿。
3. 射击墙面、僵尸和油桶，确认墙面声不与僵尸受击声错误叠加，爆炸使用新声音。
4. 观察 20—24 只僵尸的呻吟、攻击、受击和死亡，确认呻吟稀疏且不会形成持续噪声。
5. 成功与失败地拾取/放置油桶，确认只在成功时播放。
6. 让玩家及全队倒地，确认惨叫、倒地声和结束声各按预期触发，结束声只播放一次。
7. 连续使用自动步枪射墙并观察运行表现，确认无持续卡顿或声音节点数量增长。

- [ ] **Step 5：提交最终修正（仅在前述检查产生修正时）**

```bash
git add assets/sfx/boxhead scripts/fx/spatial_sfx_pool.gd scripts/combat/weapons/ranged_weapon.gd scripts/combat/zombie_target.gd scripts/player/player_controller.gd scripts/gameplay/pickup_chest.gd scripts/gameplay/place_item_service.gd scripts/gameplay/demo_arena.gd scenes/gameplay/DemoArena.tscn scenes/weapons/Pistol.tscn scenes/weapons/Rifle.tscn scenes/fx/BarrelExplosion.tscn scenes/menu/MainMenu.tscn scenes/targets/ZombieTarget.tscn scenes/player/Player.tscn
git commit -m "fix: polish gameplay sound integration"
```

若没有修正，不创建空提交。完成后进入 `finishing-a-development-branch`；在合并目标分支前按仓库约定将本功能分支提交 squash 为一个计划提交。
