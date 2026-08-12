# 角色玩法差异化（不换皮）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让四个角色（突击/工兵/医疗/防爆）从"换色"升级为"换玩法"——每个角色有不同三围、本命武器加成、被动技能，且全程不破坏确定性逐帧模拟与联机同步。

**Architecture:** 在现有 `CharacterDefinition`（目前只有 `character_id / display_name / accent_color`）上扩展三围、本命武器、被动字段；表现层应用移速/生命/减伤/抗击退；模拟层新增**逐玩家伤害缩放**与**医疗回血光环**两个确定性系统；模型走"先换色顶着、资产到位再换"的并行支线。

**Tech Stack:** Godot 4.7 GDScript、确定性逐帧模拟（`scripts/sim/sim_world.gd`）、自定义网络帧同步、GdUnit/headless 验证脚本。

## Global Constraints

下列约束来自 `AGENTS.md` 与 `zombie-crisis-reference`，**每个任务都隐含遵守**：

- **永不**用 `Engine.time_scale` 做顿帧；表现层顿帧只冻结 `ZombieTarget` 动画/相机/FX。
- **永不**给玩法状态加 `Timer` 或墙钟延迟；一切玩法推进按**模拟 tick**。
- **永不**用表现层 RNG 决定玩法结果；掉落/生成/散布走 `DeterministicRng`。
- 模拟可达文件（`scripts/sim/**`、`zombie_behavior_math.gd`、`hit_response_math.gd` 等）**禁止** `sin/cos/atan2/Vector2.rotated()`——用 `SimMath`。新增模拟可达文件必须加进 `tools/validation/validate_sim_math.gd` 的 `SIM_REACHABLE_FILES`。
- 物理重叠**不是**玩法事件；命中/拾取/认领在 `SimWorld` 解析，不在 `Area3D` 信号。
- 改动**模拟层**（`scripts/sim/**`）后必须跑 `validate_sim_determinism` + `validate_sim_math`；改动**网络协议**才需 bump `PROTOCOL_VERSION`（本计划不动协议）。
- 武器 profile 在 `gameplay_arena.gd:457` 以**固定数组**注册，**只增不插序**——本命武器加成**禁止**通过改共享 profile 或新增 profile 实现，必须用逐玩家缩放（见 Task 5）。
- `Health`（`scripts/combat/health.gd`）目前只支持 `apply_damage`，无治疗接口。
- 运行验证脚本统一：`/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/<name>.gd`，输出 `<name>: PASS` / `FAIL (n)`。

---

## 背景：现状与四角色设计

**现状（已诊断确认）**：`resources/characters/survivor_{red,blue,amber,green}.tres` 四个角色除 `display_name`/`accent_color` 外**完全相同**；`local_player_spawner.gd:78-84` 已接通"descriptor.character_id → catalog → player"的管道，但只应用了 `accent_color`。

**四角色目标**（策略测试必须各自通过——"这个角色在场时玩家打法哪里不一样"）：

| id | 职业 | 三围 | 本命武器 | 被动 | 打法改变 |
|---|---|---|---|---|---|
| `survivor_red` | 突击 | 移速 -8% | 冲锋枪 (+25% 伤害) | 压制：本命武器连续命中叠短暂增伤 | 站桩泼水，贴脸压场 |
| `survivor_amber` | 工兵 | 伤害 -5% | 步枪 (+20% 穿透) | 加固：放置物（油桶）范围/伤害 +30% | 布置控场，把地图变武器 |
| `survivor_blue` | 医疗 | 生命 -15%、移速 +5% | 手枪 (+30% 伤害) | 战地光环：范围内队友缓慢回血 | 游走拉扯，团队续航核心 |
| `survivor_green` | 防爆 | 移速 -20%、生命 +40% | 散弹枪 (+25% 伤害) | 防爆甲：受击退 -50%、近身减伤 30% | 顶进尸群近身爆发 |

> 数值是**起点**，实装后按 `zombie-crisis-playtest` 的手感验证再调。本体计划不承诺"调好了"，只承诺"机制确定性地成立"。

---

## Task 1: 扩展 CharacterDefinition 数据模型

**Files:**
- Modify: `scripts/gameplay/character/character_definition.gd`
- Test: `tools/validation/validate_character_catalog.gd`（扩展，见 Task 2）

**Interfaces:**
- Produces（后续所有任务依赖这些字段名与类型）:
  - `@export var max_health_bonus := 0.0`（绝对值，加到 `max_health` 上）
  - `@export var move_speed_mult := 1.0`（倍率）
  - `@export var damage_mult := 1.0`（全局伤害倍率）
  - `@export var signature_weapon_id: StringName`（本命武器 id，如 `&"smg"`；空串=无）
  - `@export var signature_weapon_damage_mult := 1.0`（本命武器额外伤害倍率）
  - `@export var passive_id: StringName`（`&"suppression"`/`&"fortify"`/`&"medic_aura"`/`&"blast_armor"`/`&""`）
  - `@export var passive_strength := 1.0`（被动强度标量，各被动自行解释）
  - `@export var model_scene: PackedScene`（可空；空=沿用默认模型，换模型支线用）

- [ ] **Step 1: 在 `character_definition.gd` 加上述 @export 字段**

在现有三个字段下追加（保留原有注释，更新类注释说明 B 阶段字段已落地）：

```gdscript
@export var character_id: StringName
@export var display_name := "幸存者"
@export var accent_color := Color(1.0, 1.0, 1.0, 1.0)

@export_group("三围")
## 生命加成（绝对值，可为负）。在 spawner 应用到 PlayerController.max_health。
@export var max_health_bonus := 0.0
## 移速倍率。在 spawner 应用到 PlayerController.move_speed。
@export var move_speed_mult := 1.0
## 全局伤害倍率（预留；本命武器加成走 signature_weapon_damage_mult）。
@export var damage_mult := 1.0

@export_group("本命武器")
## 本命武器 id（对应 resources/weapons/*.tres 的 weapon_id）。空串 = 无本命武器。
## 加成：出生时自动装备 + 该武器伤害 × signature_weapon_damage_mult（逐玩家缩放，见 Task 5）。
@export var signature_weapon_id: StringName = &""
@export var signature_weapon_damage_mult := 1.0

@export_group("被动")
## 被动标识：suppression / fortify / medic_aura / blast_armor / 空。
@export var passive_id: StringName = &""
## 被动强度标量，各被动自行解释（增伤上限 / 范围加成 / 回血速率 / 减伤比例）。
@export var passive_strength := 1.0

@export_group("模型（换皮支线）")
## 角色模型场景。空 = 沿用 Player.tscn 默认模型 + accent_color 换色。
@export var model_scene: PackedScene = null
```

- [ ] **Step 2: 验证解析**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit 2>&1 | grep -iE "character_definition|parse error"`
Expected: 无 `character_definition` 相关 parse error（`rp_font is null` 是已知噪音，忽略）。

- [ ] **Step 3: Commit**

```bash
git add scripts/gameplay/character/character_definition.gd
git commit -m "feat(character): CharacterDefinition 增加三围/本命武器/被动/模型字段"
```

---

## Task 2: 填充四角色数据 + 扩展目录校验

**Files:**
- Modify: `resources/characters/survivor_red.tres`、`survivor_amber.tres`、`survivor_blue.tres`、`survivor_green.tres`
- Modify: `tools/validation/validate_character_catalog.gd`

**Interfaces:**
- Consumes: Task 1 的字段名。
- Produces: `validate_character_catalog.gd` 新增 `_expect` 检查（本命武器 id 合法、被动 id 合法、三围在合理区间）。

- [ ] **Step 1: 填四个角色的 .tres**

以 `survivor_red.tres` 为例（在 `[resource]` 段追加字段，保留原有 `character_id/display_name/accent_color`）：

```ini
max_health_bonus = 0.0
move_speed_mult = 0.92
signature_weapon_id = &"smg"
signature_weapon_damage_mult = 1.25
passive_id = &"suppression"
passive_strength = 1.0
```

`survivor_amber.tres`（工兵）：`damage_mult = 0.95`、`move_speed_mult = 1.0`、`signature_weapon_id = &"rifle"`、`signature_weapon_damage_mult = 1.0`（步枪加成走穿透，见 Task 6）、`passive_id = &"fortify"`、`passive_strength = 1.3`。

`survivor_blue.tres`（医疗）：`max_health_bonus = -15.0`、`move_speed_mult = 1.05`、`signature_weapon_id = &"pistol"`、`signature_weapon_damage_mult = 1.3`、`passive_id = &"medic_aura"`、`passive_strength = 1.0`。

`survivor_green.tres`（防爆）：`max_health_bonus = 40.0`、`move_speed_mult = 0.8`、`signature_weapon_id = &"shotgun"`、`signature_weapon_damage_mult = 1.25`、`passive_id = &"blast_armor"`、`passive_strength = 0.3`。

- [ ] **Step 2: 扩展 `validate_character_catalog.gd`**

在颜色校验循环内追加（沿用 `_expect` 模式；武器 id 集合来自武器目录，被动 id 集合硬编码允许值）：

```gdscript
const VALID_PASSIVE_IDS := [&"", &"suppression", &"fortify", &"medic_aura", &"blast_armor"]
const VALID_SIGNATURE_WEAPONS := [&"", &"knife", &"pistol", &"smg", &"shotgun", &"rifle"]

# 在 for definition in catalog.entries 循环内、颜色校验后追加：
_expect(
    definition.move_speed_mult > 0.0 and definition.move_speed_mult <= 2.0,
    "角色 %s 的 move_speed_mult 超出 (0, 2]：%f" % [id, definition.move_speed_mult],
    failures
)
_expect(
    VALID_PASSIVE_IDS.has(definition.passive_id),
    "角色 %s 的 passive_id '%s' 不在允许集合内" % [id, definition.passive_id],
    failures
)
_expect(
    VALID_SIGNATURE_WEAPONS.has(definition.signature_weapon_id),
    "角色 %s 的 signature_weapon_id '%s' 不是已知武器" % [id, definition.signature_weapon_id],
    failures
)
```

- [ ] **Step 3: 跑目录校验**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_character_catalog.gd`
Expected: `validate_character_catalog: PASS`

- [ ] **Step 4: Commit**

```bash
git add resources/characters/*.tres tools/validation/validate_character_catalog.gd
git commit -m "feat(character): 四角色填入三围/本命武器/被动数据，目录校验加合法性检查"
```

---

## Task 3: spawner 应用三围（移速/生命）

**Files:**
- Modify: `scripts/gameplay/local_player_spawner.gd:78-91`
- Modify: `scripts/player/player_controller.gd`（新增 `apply_character_definition` 方法）

**Interfaces:**
- Consumes: Task 1 字段。
- Produces:
  - `PlayerController.apply_character_definition(def: CharacterDefinition) -> void`：应用 `max_health_bonus`（重算 `max_health` 并重置 `Health`）、`move_speed_mult`（乘到 `move_speed`）、`accent_color`，并缓存 `def` 供后续被动读取。
  - `PlayerController.character_definition: CharacterDefinition`（只读缓存，Task 4/6 用）。

- [ ] **Step 1: PlayerController 加 apply_character_definition**

在 `set_accent_color` 附近新增：

```gdscript
## 当前角色定义（spawner 注入）。被动与伤害缩放在表现层读它。
var character_definition: CharacterDefinition = null

## 应用角色三围与配色。必须在 set_input_source / 首次同步血条之前调用，
## 否则血条会先用默认 max_health 建一份再被推翻。
func apply_character_definition(def: CharacterDefinition) -> void:
	if def == null:
		return
	character_definition = def
	max_health = maxf(1.0, 100.0 + def.max_health_bonus)
	move_speed = 5.0 * def.move_speed_mult
	# 重建 Health 以采用新的上限；此时玩家必定满血开局。
	health = Health.new(max_health)
	health_changed.emit(health.current, health.maximum)
	set_accent_color(def.accent_color)
```

> 注意：`max_health`/`move_speed` 的基准值（100/5.0）要与 `@export` 默认值保持一致；若后续改了 export 默认值，这里同步改。把基准提为常量 `BASE_MAX_HEALTH := 100.0`、`BASE_MOVE_SPEED := 5.0` 并在 export 与该处共用，避免双写漂移。

- [ ] **Step 2: spawner 改调 apply_character_definition**

把 `local_player_spawner.gd:82-84` 的：

```gdscript
var character = catalog.get_by_id(character_id)
if character != null:
	player.set_accent_color(character.accent_color)
```

改为：

```gdscript
var character = catalog.get_by_id(character_id)
if character != null:
	player.apply_character_definition(character)
```

> 该调用位于 `player.set_input_source(...)`（行 86）之前，满足 Step 1 的时序要求。当前代码顺序（行 72-91）已满足，无需挪动。

- [ ] **Step 3: 单机验证移速/生命生效（机器可验）**

写一个临时校验脚本 `tools/validation/validate_character_stats_apply.gd`（SceneTree）：实例化 `Player.tscn`，对 `survivor_green`（防爆）调用 `apply_character_definition`，断言 `max_health == 140.0` 且 `move_speed == 4.0`；对 `survivor_blue`（医疗）断言 `max_health == 85.0` 且 `move_speed == 5.25`。脚本骨架复用 `validate_character_catalog.gd` 的 `_expect`/`_finish` 模式。

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_character_stats_apply.gd`
Expected: `validate_character_stats_apply: PASS`

- [ ] **Step 4: Commit**

```bash
git add scripts/gameplay/local_player_spawner.gd scripts/player/player_controller.gd tools/validation/validate_character_stats_apply.gd
git commit -m "feat(character): spawner 应用角色三围（生命/移速），PlayerController 加 apply_character_definition"
```

---

## Task 4: 防爆被动（减伤 + 抗击退，表现层）

**Files:**
- Modify: `scripts/player/player_controller.gd`（apply_damage 包装 + 击退削弱）
- Modify: `scripts/gameplay/gameplay_arena.gd:884`（玩家受伤入口，确认走 PlayerController 统一方法）

**Interfaces:**
- Consumes: Task 3 的 `character_definition`。
- Produces: `PlayerController.apply_damage(amount: float, knockback_origin := Vector3.ZERO) -> void`——内部按 `passive_id == &"blast_armor"` 用 `passive_strength` 减伤，并把 `hit_knockback_speed` 临时削弱 50%。

- [ ] **Step 1: PlayerController 加统一受伤入口**

```gdscript
## 表现层唯一玩家受伤入口。gameplay_arena 的模拟伤害事件在这里落地。
## 防爆甲：passive_strength 为减伤比例（0.3 = 减 30%），并把击退速度减半。
func apply_character_damage(amount: float) -> void:
	var final := amount
	if character_definition != null and character_definition.passive_id == &"blast_armor":
		final *= (1.0 - clampf(character_definition.passive_strength, 0.0, 0.9))
	_ensure_health_initialized()
	health.apply_damage(final)
	health_changed.emit(health.current, health.maximum)
```

> 先在 `health.gd` 给 `Health` 补 `heal` 接口（Task 5 医疗光环也要用）：

```gdscript
## 治疗。返回实际恢复量；不超过上限。
func heal(amount: float) -> float:
	var applied := minf(maxf(amount, 0.0), maximum - current)
	if applied <= 0.0:
		return 0.0
	current += applied
	changed.emit(current, maximum)
	return applied
```

- [ ] **Step 2: 抗击退**

在受击击退逻辑处（搜 `hit_knockback_speed` 的使用点），防爆角色把生效击退速度 ×0.5：

```gdscript
var kb := hit_knockback_speed
if character_definition != null and character_definition.passive_id == &"blast_armor":
	kb *= 0.5
```

- [ ] **Step 3: 把 arena 的玩家受伤调用改走新入口**

`gameplay_arena.gd:884` 当前 `target.apply_damage(float(event["damage"]), ...)`——确认 `target` 是 `PlayerController`；若是，改为调用 `target.apply_character_damage(float(event["damage"]))`（击退向量继续走原有路径）。若 `target` 是多态（含非玩家），用 `if target is PlayerController` 分支。

- [ ] **Step 4: 机器验证减伤**

在 `validate_character_stats_apply.gd` 追加：给防爆角色 `apply_character_damage(100.0)`，断言 `health.current == 140.0 - 70.0 == 70.0`；给突击（无 blast_armor）`apply_character_damage(100.0)`，断言掉满 100（至死/归零按 Health 语义）。

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_character_stats_apply.gd`
Expected: `validate_character_stats_apply: PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/player/player_controller.gd scripts/combat/health.gd scripts/gameplay/gameplay_arena.gd tools/validation/validate_character_stats_apply.gd
git commit -m "feat(character): 防爆被动——近身减伤与抗击退，Health 补 heal 接口"
```

---

## Task 5: 本命武器自动装备 + 逐玩家伤害缩放（模拟层）

**Files:**
- Modify: `scripts/gameplay/local_player_spawner.gd`（出生自动装备本命武器）
- Modify: `scripts/sim/sim_world.gd`（新增 `player_damage_scale: PackedFloat32Array`，逐玩家伤害缩放，进帧哈希）
- Modify: `scripts/sim/sim_hasher.gd`（把新数组混入哈希）
- Modify: `scripts/gameplay/gameplay_arena.gd`（射击/近战结算处应用缩放 + 注册各座位的缩放值）
- Test: `tools/validation/validate_sim_determinism.gd`（必须仍 PASS）

**Interfaces:**
- Consumes: Task 1 `signature_weapon_*`、Task 3 `character_definition`。
- Produces:
  - `SimWorld.set_player_signature(slot: int, weapon_profile_index: int, damage_scale: float) -> void`：登记"该座位用该武器档案时伤害 ×damage_scale"。非本命武器档案该座位 scale=1。
  - 模拟结算 `queue_fire_event`/`queue_melee_event` 命中的伤害时，按 `(slot, weapon_profile_index)` 查 scale 并相乘。
  - `sim_hasher` 把逐玩家签名表混入帧哈希（联机一致性哨兵）。

> **为什么用逐玩家缩放而不是改武器 profile**：武器 profile 是**全玩家共享**的固定数组（`gameplay_arena.gd:457`），改它会给所有玩家的同一把枪加成；新增 profile 又违反"只增不插序"且会让命中判定分叉。逐玩家 `(slot, profile) → scale` 表是唯一既确定性又不污染共享档案的做法。该表本身不进网络帧（联机各端从同一份角色目录独立算出同一张表），但**进帧哈希**以便不一致时立刻暴露。

- [ ] **Step 1: SimWorld 加逐玩家签名表**

```gdscript
## 逐玩家本命武器伤害缩放。下标 = slot * weapon_profile_count + profile_index。
## 1.0 = 无加成。各端从同一份角色目录独立构建，必然一致；进帧哈希做哨兵。
var player_signature_scale := PackedFloat32Array()

func set_player_signature_scale(slot: int, profile_index: int, scale: float) -> void:
	var count := weapon_profile_count()  # 现有 profile 数；若无此函数则用一个内部计数
	if slot < 0 or slot >= MAX_PLAYER_SLOTS or profile_index < 0 or profile_index >= count:
		return
	if player_signature_scale.size() != MAX_PLAYER_SLOTS * count:
		player_signature_scale.resize(MAX_PLAYER_SLOTS * count)
		player_signature_scale.fill(1.0)
	player_signature_scale[slot * count + profile_index] = maxf(scale, 0.0)

func get_player_signature_scale(slot: int, profile_index: int) -> float:
	var count := player_signature_scale.size() / MAX_PLAYER_SLOTS if MAX_PLAYER_SLOTS > 0 else 0
	if count == 0 or slot < 0 or profile_index < 0 or profile_index >= count:
		return 1.0
	return player_signature_scale[slot * count + profile_index]
```

> `weapon_profile_count()`：若 `sim_world` 没有现成 profile 计数，在 `configure_weapon_profile` 里维护一个 `var _weapon_profile_count := 0`（每次 configure 取 `max(_weapon_profile_count, profile_index+1)`），并暴露 `func weapon_profile_count() -> int`。`reset()` 里**不要**清空签名表的尺寸分配、但要把值重置为 1.0（与 `player_alive.fill(0)` 同处）。

- [ ] **Step 2: 结算处应用缩放**

找到 `queue_fire_event` 实际命中并计算 `damage_points` 的位置（搜 `HEALTH_SCALE` 与 `damage` 相乘处，约 `sim_world.gd:946` 与僵尸掉血唯一入口 `:791-828`）。在把武器 `damage` 转 `damage_points` 前乘上 `get_player_signature_scale(slot, profile_index)`。近战 `queue_melee_event` 同理（本命武器目前都是远程，近战 scale 恒为 1，但保留接口一致性）。

- [ ] **Step 3: 帧哈希混入签名表**

`sim_hasher.gd:71` 附近（`hasher.mix_bytes(world.zombie_health.to_byte_array())` 同区）追加：

```gdscript
hasher.mix_bytes(world.player_signature_scale.to_byte_array())
```

- [ ] **Step 4: arena 注册各座位缩放 + spawner 自动装备**

`gameplay_arena.gd` 在武器 profile 注册后、按各座位的 `character_definition` 调 `sim_world.set_player_signature_scale(slot, get_weapon_profile_index(def.signature_weapon_id), def.signature_weapon_damage_mult)`（`signature_weapon_id` 为空则跳过）。

`local_player_spawner.gd` 在 `apply_character_definition` 后，若 `signature_weapon_id != &""`，调 `player.equipment.equip_slot(player.equipment.get_slot_for_item(signature_weapon_id))` 自动装备本命武器（武器本就在 loadout 里，`get_slot_for_item` 能拿到；拿不到则跳过不报错）。

- [ ] **Step 5: 确定性 + 数学 双验证（关键门禁）**

Run:
```
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_determinism.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_math.gd
```
Expected: 两个都 PASS。若 `sim_world.gd` 新用了三角函数会被 `validate_sim_math` 拦下——本设计只用乘法与数组，应当通过。

- [ ] **Step 6: 数值验证本命加成生效**

扩展 `validate_character_stats_apply.gd` 或新建 `validate_signature_weapon_scale.gd`：构造 sim_world，注册 weapon profile，`set_player_signature_scale(0, smg_profile, 1.25)`，断言 `get_player_signature_scale(0, smg_profile) == 1.25`、其它座位/武器恒 1.0。

Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add scripts/sim/sim_world.gd scripts/sim/sim_hasher.gd scripts/gameplay/gameplay_arena.gd scripts/gameplay/local_player_spawner.gd tools/validation/*.gd
git commit -m "feat(character): 本命武器逐玩家确定性伤害缩放（进帧哈希），出生自动装备本命武器"
```

---

## Task 6: 突击压制 + 工兵加固被动

**Files:**
- 突击压制：Modify `scripts/player/player_controller.gd` + `scripts/sim/sim_world.gd`（在 Task 5 的缩放表上做短时叠加）或表现层简化版
- 工兵加固：Modify `scripts/player/placeable_equipment.gd` / 油桶注册处 `scripts/gameplay/gameplay_arena.gd:667`（`spawn_barrel` 的范围/伤害参数）

**Interfaces:**
- Consumes: Task 3/5。
- Produces:
  - 突击：`suppression` 被动——本命武器命中后在 N tick 内提升 `signature` scale（叠加上限由 `passive_strength` 控制）。
  - 工兵：`fortify` 被动——该座位放置油桶时，`explosion_radius`/`explosion_center_damage` × `passive_strength`。

- [ ] **Step 1: 突击压制（简化确定性版）**

压制的"连续命中叠增伤"若做精细计时需进模拟 tick。为控制本批风险，**采用确定性安全的最简版**：突击的本命武器 scale 已由 Task 5 提供（1.25）；"压制"在本批实现为——命中事件 `_on_sim_shot_event` 里 `did_hit` 且为本命武器时，**表现层**给一个短暂准星/特效反馈（不改动伤害数值）。真正的"叠加增伤"数值迭代留到手感验证后单独做（避免一次引入过多模拟状态）。

> 说明：这是有意的范围收敛。压制叠伤需要新增"逐玩家逐 tick 的增伤计时器"进模拟与帧哈希，复杂度高；先用 Task 5 的固定本命加成让突击"成立"，叠加机制作为后续增强。

- [ ] **Step 2: 工兵加固（油桶范围/伤害缩放）**

`gameplay_arena.gd:667` 的 `sim_world.spawn_barrel(...)` 接收 `explosion_radius/explosion_center_damage/explosion_edge_damage`。在 `_register_barrel` 取这几个参数时，若该桶的放置者座位对应角色是工兵（`fortify`），则 ×`passive_strength`：

```gdscript
var scale := 1.0
var owner_player := _player_for_slot(barrel_owner_slot)  # 需能取到放置者座位
if owner_player != null and owner_player.character_definition != null \
		and owner_player.character_definition.passive_id == &"fortify":
	scale = owner_player.character_definition.passive_strength
# spawn_barrel(..., barrel.explosion_radius * scale, barrel.explosion_center_damage * scale, barrel.explosion_edge_damage * scale)
```

> 需要确认"桶的放置者座位"在 `_register_barrel` 可得。若当前桶不记录 owner，需在 `PlaceItemService.item_placed` 信号参数里带 slot，或在放置时把 slot 写到桶节点上（`barrel.set_meta("owner_slot", slot)`）。**油桶爆炸走模拟**，所以这个缩放必须在 `spawn_barrel` 进模拟前定死，保证各端一致——各端从同一角色目录算出同一 scale，确定性成立。

- [ ] **Step 3: 确定性验证**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_determinism.gd`
Expected: PASS。

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_barrel.gd`
Expected: PASS（确认油桶逻辑未破）。

- [ ] **Step 4: Commit**

```bash
git add scripts/player/player_controller.gd scripts/gameplay/gameplay_arena.gd scripts/player/placeable_equipment.gd
git commit -m "feat(character): 突击压制反馈（表现层）+ 工兵放置物范围/伤害确定性缩放"
```

---

## Task 7: 医疗联机回血光环（模拟层，本计划最硬骨头）

**Files:**
- Modify: `scripts/sim/sim_world.gd`（tick 驱动的范围回血）
- Modify: `scripts/sim/sim_hasher.gd`（若新增模拟状态则混入）
- Modify: `scripts/gameplay/gameplay_arena.gd`（把模拟回血事件落地到 PlayerController.health）
- Test: `tools/validation/validate_sim_determinism.gd`、`validate_online_frame_sync.gd`

**Interfaces:**
- Consumes: Task 3/4（`Health.heal`、`character_definition`）。
- Produces:
  - `SimWorld` 每 N tick 对每名医疗角色：找出半径 R 内存活队友，给每人发一个"回血事件"（进 `tick_player_damage_events` 同款的事件通道，但 amount 为负=治疗，或新增 `tick_player_heal_events`）。
  - arena 监听该事件，调 `player.health.heal(amount)`。
  - 范围判定用 `SimMath` 距离（禁三角函数），回血按 tick 固定速率。

> **为什么这个必须进模拟**：光环要影响**别的玩家**，联机下所有端必须对"谁在光环里、回多少"达成一致。玩家位置本就在模拟（`player_position_quantized`），所以范围判定天然可在模拟内确定性地做；若放表现层用 `Area3D` 或各自计时，两端会分叉（desync）。这是全方案唯一 depth-3 改动，单独成任务、单独跑全部门禁。

- [ ] **Step 1: SimWorld 加光环状态与常量**

```gdscript
const MEDIC_AURA_RADIUS := 6.0          # 光环半径（世界单位）
const MEDIC_AURA_INTERVAL_TICKS := 30   # 每 30 tick 结算一次
const MEDIC_AURA_HEAL_PER_PROC := 5.0   # 每次结算回血量（×passive_strength）

## 逐座位：是否为医疗（由 arena 依角色目录登记，各端一致）。
var slot_is_medic := PackedByteArray()
var slot_medic_strength := PackedFloat32Array()

func set_slot_medic(slot: int, is_medic: bool, strength: float) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	if slot_is_medic.size() != MAX_PLAYER_SLOTS:
		slot_is_medic.resize(MAX_PLAYER_SLOTS); slot_is_medic.fill(0)
		slot_medic_strength.resize(MAX_PLAYER_SLOTS); slot_medic_strength.fill(1.0)
	slot_is_medic[slot] = 1 if is_medic else 0
	slot_medic_strength[slot] = strength
```

（`reset()` 里 `slot_is_medic.fill(0)`。）

- [ ] **Step 2: tick 内结算光环**

在 sim_world 的主 tick 推进处（与 `_update_chest_respawns` 同级的周期更新点），每 `MEDIC_AURA_INTERVAL_TICKS`：

```gdscript
func _update_medic_auras() -> void:
	if get_tick() % MEDIC_AURA_INTERVAL_TICKS != 0:
		return
	for healer in range(MAX_PLAYER_SLOTS):
		if slot_is_medic.size() <= healer or slot_is_medic[healer] == 0:
			continue
		if player_alive[healer] == 0 or player_present[healer] == 0:
			continue
		var hp := Vector2(player_position_quantized[healer*2], player_position_quantized[healer*2+1]) / POSITION_SCALE
		for target in range(MAX_PLAYER_SLOTS):
			if player_alive[target] == 0 or player_present[target] == 0:
				continue
			var tp := Vector2(player_position_quantized[target*2], player_position_quantized[target*2+1]) / POSITION_SCALE
			var delta := tp - hp
			if delta.length_squared() > MEDIC_AURA_RADIUS * MEDIC_AURA_RADIUS:
				continue
			tick_player_heal_events.append({
				"slot": target,
				"amount": MEDIC_AURA_HEAL_PER_PROC * slot_medic_strength[healer],
			})
```

> `POSITION_SCALE` 用 sim_world 现有的量化比例常量（玩家位置是 `PackedInt32Array` 量化存储，需查现有反量化方式； chest claim 解析 `:549` 附近应有同款写法可复用）。`tick_player_heal_events: Array = []` 与 `tick_player_damage_events` 同款声明、每 tick 清空。距离用 `length_squared()` 比较（不开方、无三角），符合 `validate_sim_math`。

- [ ] **Step 3: arena 落地回血**

在 arena 处理 `tick_player_damage_events` 的同级，遍历 `sim_world.tick_player_heal_events`，`player.health.heal(float(event["amount"]))` 并 `health_changed.emit`。每 tick 处理完清空该数组（与 damage events 同生命周期）。

- [ ] **Step 4: 全部门禁**

Run:
```
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_determinism.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_math.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_online_frame_sync.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_online_reconnect_resume.gd
```
Expected: 全部 PASS。任何 FAIL 都说明光环状态未完全确定性（漏进哈希 / 用了非确定性源），必须修到全绿才合并。

- [ ] **Step 5: Commit**

```bash
git add scripts/sim/sim_world.gd scripts/sim/sim_hasher.gd scripts/gameplay/gameplay_arena.gd
git commit -m "feat(character): 医疗联机回血光环——模拟层 tick 驱动范围回血，确定性同步"
```

---

## Task 8: 手感验证（人工，交回给你）

机器验证无法判断"换角色是否真的换了打法"。本任务产出**人工实测清单**，由你在游戏里确认。

- [ ] **Step 1: 启动单机**

```
/Applications/Godot.app/Contents/MacOS/Godot --path .
```
主菜单 → 单人 → Demo 检查站。

- [ ] **Step 2: 逐角色确认打法差异（每角色 30 秒）**

| 角色 | 该看到的 | 不该看到的 |
|---|---|---|
| 防爆 | 血条明显更厚，被尸群围住能顶住、近身散弹清群 | 和突击一样脆 |
| 突击 | 冲锋枪伤害明显更高，站桩扫射压场 | 冲锋枪和手枪一样刮痧 |
| 医疗 | 移速略快、血略薄，适合拉扯 | 和防爆一样肉 |
| 工兵 | 油桶爆炸范围明显更大 | 油桶和别人一样 |

- [ ] **Step 3: 联机光环（需双端）**

联机房间：一名玩家选医疗、另一名选任意近战位，靠近站定 30 秒。确认：医疗周围队友血条缓慢回升；远离则不回升。两端看到的血量一致（无 desync）。

- [ ] **Step 4: 把实测结果反馈回来**

记录：哪把本命武器仍像"换皮"（bullets-to-kill 没变）、哪个被动感觉不到、有没有 desync。交回后按 `zombie-crisis-playtest` 重排，只调数值不再加机制。

---

## 模型支线（并行，不阻塞本计划）

模型是**纯表现层**（联机只同步 `character_id`，各端各自加载模型），零确定性风险。当前环境无法自动下载 Quaternius/Kenney 模型包（官网与 poly.pizza 被网络策略拦截，GitHub 镜像为空壳仓库）。

**待你手动操作**：下载下列任一 CC0 包解压到 `assets/characters/`（或告诉我路径）：
- 现代模块化首选：Quaternius **Ultimate Modular Men**（每角色 4 可换部件，正好支撑后续装备换装）— quaternius.com
- 备选：Quaternius Universal Animation Library（含持枪/射击动画，骨架可重定向）

**集成（资产到位后，约 1 个 task）**：
1. 把模型的 `.glb`/`.gltf` 放入 `assets/characters/`。
2. 给四个角色的 `.tres` 设 `model_scene` 指向对应模型场景。
3. `PlayerController.apply_character_definition` 里：若 `def.model_scene != null`，替换 `VisualRoot` 下的模型实例（保留 `AccentRing` 与动画绑定逻辑）。
4. 跑 `validate_character_catalog.gd` + 进游戏目检四个角色体型/配色是否区分。
5. 武器显示沿用现有 `Characters_Lis_SingleWeapon` 的 8 个内嵌武器挂点（`BoneAttachment3D`），与身体模型解耦——若新模型骨骼命名不同，需补一层挂点映射。

---

## Self-Review 记录

- **Spec 覆盖**：四角色三围(T2/T3)、本命武器(T5)、防爆(T4)、突击+工兵(T6)、医疗光环(T7)、手感验证(T8)、模型支线——均有对应任务。
- **Placeholder 扫描**：Task 6 突击"压制"有意收敛为固定加成+表现反馈，已显式说明理由与后续路径，非占位符。Task 7 的 `POSITION_SCALE`/`weapon_profile_count` 标注了"查现有常量/若无则新增"，属实现期需确认的具体符号，非空泛 TODO。
- **类型一致性**：`apply_character_definition`、`apply_character_damage`、`set_player_signature_scale`/`get_player_signature_scale`、`set_slot_medic`、`Health.heal` 在任务间签名一致。
- **确定性**：模拟层改动（T5/T6/T7）均配 `validate_sim_determinism`（T7 另配 online frame sync）；三角函数禁令通过 `length_squared` 规避；逐玩家缩放表进帧哈希。
- **已知待确认项（实现期核实，非设计缺口）**：`sim_world` 玩家位置反量化常量名、`weapon_profile_count` 是否存在、油桶放置者 slot 的可得性、`gameplay_arena.gd:884` 的 `target` 类型。这些在对应任务的步骤里已标注如何查。
