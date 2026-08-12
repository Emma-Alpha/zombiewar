# 波间商店（A+B：成长选择 + 完整经济）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给《僵尸危机》补上 Brotato 式波间商店——每波结束进商店，用打死僵尸掉的材料购买武器/被动/属性升级/回血，形成"杀怪→材料→商店→变强"的成长闭环。单机暂停制、联机各端独立购买（方案二），商店物品由确定性 RNG 生成，购买走确定性命令进模拟层。

**Architecture:** 分三层。①**经济层**：僵尸死亡掉"材料"（货币），逐玩家计数进模拟 + 帧哈希。②**商店层**：波间由 `SimWaveDirector` 触发 `intermission_started` 事件，商店物品表用确定性 RNG 从目录生成，购买命令走 `pending_events`。③**成长层**：新增逐玩家成长表（属性升级）仿 `player_signature_scale` 模式进模拟 + 帧哈希，武器/被动购买复用现有 `grant_item`。

**Tech Stack:** Godot 4.7 GDScript、确定性逐帧模拟、自定义帧哈希、Control 商店 UI。

## Global Constraints

- 一切**玩法推进按模拟 tick**，绝不 `Timer`/墙钟。商店窗口时长 = 波间 tick 数，不能是计时器。
- **商店物品生成用确定性 RNG**（`DeterministicRng`，房间种子派生），各端算出一致。
- **购买动作 = 确定性命令**（走 `pending_events`，像 `queue_fire_event`），禁止表现层直接改属性/金钱。
- **玩家金钱与成长表进帧哈希**（`sim_hasher`），联机不一致立刻暴露。
- 新增模拟可达文件必须加进 `validate_sim_math.gd` 的 `SIM_REACHABLE_FILES`；三角函数禁令同项目规则。
- 改动模拟层后必须跑 `validate_sim_determinism`；改动 `scripts/net/` 或 `server/src/lib/protocol.ts` 需 **bump `PROTOCOL_VERSION`**（客户端 `lobby_protocol.gd` 与服务端 `protocol.ts` **同步改**，4→5）并跑 `validate_online_frame_sync`。
- **联机购买**走现有 `command["e"]` 事件通道：新增 `EVENT_SHOP_PURCHASE`，服务端 `protocol.ts` 白名单 `parseEvent` 必须加一行（否则旧服务端 `return null` 丢事件 → desync），客户端 `lobby_protocol.gd` 同加常量。
- 武器 profile 只增不插序；商店卖武器**不能**新增 profile，走 `grant_item` 复用现有 loadout 武器。
- `RewardMode { EQUIPMENT, AMMO, WEAPON_MOD }` 现有掉落类型保留；材料是新掉落类型。
- 波间窗口现为 60 tick（3 秒），商店需要更长——**延长 `inter_wave_delay_ticks`**（demo_map）并让商店结算不影响僵尸生成。

---

## 现状与设计决策（背景）

**现状**：`sim_wave_director.gd` 只有 `EndMode.COMPLETE/LOOP`，波间只有 `inter_wave_delay_ticks` 干等，无成长/商店/经济。掉落只有 `EQUIPMENT/AMMO/WEAPON_MOD`，无货币。无局内成长数据模型。

**方案二（本计划）**：单机波间暂停进商店；联机各端独立购买，用**同一份确定性商店**（种子一致）保证同步。商店**卖**：武器、被动、属性升级、回血、弹药。材料掉落：普通僵尸小概率、精英必掉、波次越高越多。

**为什么购买必须走模拟命令**：方案二联机下各端独立购买，若直接改表现层属性，各端购买时序不同 → desync。必须让"购买"作为确定性命令进 `pending_events`，模拟层应用，进帧哈希。表现层只负责显示 UI 和发命令。

---

## Task 1: 材料掉落 + 逐玩家金钱（模拟层）

**Files:**
- Modify: `scripts/sim/sim_world.gd`（新增 `player_material` 数组 + 死亡掉落 + 帧哈希）
- Modify: `scripts/sim/sim_hasher.gd`（混入金钱）
- Test: `tools/validation/validate_shop_economy.gd`（新建）

**Interfaces:**
- Produces:
  - `SimWorld.player_material := PackedInt32Array()`（逐座位材料数）
  - `SimWorld.add_player_material(slot: int, amount: int) -> void`
  - `SimWorld.get_player_material(slot: int) -> int`
  - `SimWorld.spend_player_material(slot: int, amount: int) -> bool`（够才扣，返回是否成功）
  - 死亡规则：`MapZombieDeathRuleDefinition` 增加"材料掉落"字段，`_materialize_death_rule_drops` 处理

- [ ] **Step 1: SimWorld 加金钱数组**

在 `player_signature_scale` 声明附近加：

```gdscript
## 逐玩家材料（货币）。波间商店的购买力。进帧哈希，各端必须一致。
var player_material := PackedInt32Array()
```

`_init`/`reset` 里 `player_material.resize(MAX_PLAYER_SLOTS); player_material.fill(0)`。

方法：

```gdscript
func add_player_material(slot: int, amount: int) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	player_material[slot] = maxi(0, player_material[slot] + amount)

func get_player_material(slot: int) -> int:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return 0
	return player_material[slot]

## 扣费。够才扣并返回 true；不够不动并返回 false。
func spend_player_material(slot: int, amount: int) -> bool:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return false
	if player_material[slot] < amount:
		return false
	player_material[slot] -= amount
	return true
```

- [ ] **Step 2: 死亡掉落材料**

`MapZombieDeathRuleDefinition` 增加 `@export var material_drop_min := 0` / `material_drop_max := 0`。在 `_materialize_death_rule_drops`（处理 `drop_item` 事件处）旁边，新增处理 `material_drop` 事件：`add_player_material(slot, rng.randint(min, max))`（确定性 RNG）。

- [ ] **Step 3: 帧哈希**

`sim_hasher.hash_world` 里 `player_material` 混入：

```gdscript
hasher.mix_bytes(world.player_material.to_byte_array())
```

- [ ] **Step 4: 验证**

新建 `validate_shop_economy.gd`：构造 world，`add_player_material(0, 50)`，断言 `get_player_material(0)==50`；`spend_player_material(0, 30)` 返回 true 且剩 20；`spend_player_material(0, 100)` 返回 false 且仍 20；非法 slot 拒绝。

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_shop_economy.gd`
Expected: `validate_shop_economy: PASS`

Run: `validate_sim_determinism`（后台长跑）→ PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/sim/sim_world.gd scripts/sim/sim_hasher.gd scripts/gameplay/map/map_zombie_death_rule_definition.gd tools/validation/validate_shop_economy.gd
git commit -m "feat(shop): 逐玩家材料货币——僵尸死亡掉落，进帧哈希"
```

---

## Task 2: 波间事件触发商店阶段

**Files:**
- Modify: `scripts/sim/sim_wave_director.gd`（新增 `intermission_started` 事件 + 状态查询）
- Modify: `scripts/sim/sim_world.gd`（透传事件）
- Modify: `scripts/gameplay/gameplay_arena.gd`（消费事件，控制商店 UI 显隐）
- Test: `validate_sim_wave_director.gd`（确认现有通过）

**Interfaces:**
- Produces:
  - `SimWaveDirector` 进入 `INTERMISSION` 时输出 `{"kind": &"intermission_started", "wave_number": N}` 事件。
  - `SimWaveDirector.is_intermission() -> bool` 公开查询。
  - arena 的 `_on_sim_wave_event` 处理 `intermission_started` → 显示商店 UI（Task 3/4 的界面），`wave_started` → 隐藏。

- [ ] **Step 1: wave director 输出 intermission 事件**

在 `_finish_wave` 里 `state = State.INTERMISSION` 后，`output.append({"kind": &"intermission_started", "wave_number": wave_number})`。确保 `wave_started` 事件仍正常发出。

- [ ] **Step 2: 状态查询**

`func is_intermission() -> bool: return state == State.INTERMISSION`

- [ ] **Step 3: 透传 + arena 消费**

`sim_world.step_tick` 已把 `tick_wave_events` 收集（`wave_director.step_tick` 输出）。arena 的 `_on_sim_wave_event` 加分支：`intermission_started` → 通知商店 UI 打开；`wave_started` → 通知商店 UI 关闭。

- [ ] **Step 4: 验证**

Run: `validate_sim_wave_director.gd` → PASS（确认现有波次逻辑未破）
Run: `validate_sim_determinism`（后台）→ PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/sim/sim_wave_director.gd scripts/sim/sim_world.gd scripts/gameplay/gameplay_arena.gd
git commit -m "feat(shop): 波间触发 intermission_started 事件，arena 感知商店阶段"
```

---

## Task 3: 商店物品生成（确定性 RNG）

**Files:**
- Create: `scripts/shop/shop_catalog.gd`（商店物品目录：物品 = 类型 + 数据 + 价格）
- Create: `resources/shop/shop_catalog.tres`（初始商品：武器/被动/属性/回血/弹药）
- Modify: `scripts/gameplay/content_catalogs.gd`（注册 shop catalog）
- Test: `tools/validation/validate_shop_catalog.gd`

**Interfaces:**
- Produces:
  - `ShopCatalog`（Resource）：`entries: Array[ShopOfferDefinition]`
  - `ShopOfferDefinition`（Resource）：
    - `offer_type: StringName`（`&"weapon"`/`&"passive"`/`&"stat"`/`&"heal"`/`&"ammo"`）
    - `weapon_id: StringName`（offer_type==weapon）
    - `passive_id: StringName`（offer_type==passive）
    - `stat: StringName`（offer_type==stat，`&"damage"`/`&"max_health"`/`&"move_speed"`）
    - `stat_amount: float`
    - `price: int`
    - `display_name: String`
  - 商店刷新逻辑：波间开始时，用确定性 RNG 从目录选 N 个（初始 3 个），各端一致。

- [ ] **Step 1: 定义 ShopOfferDefinition + ShopCatalog**

`ShopOfferDefinition` 用 `class_name` + `@export`，字段如上。

- [ ] **Step 2: 确定性生成**

在 arena（或一个 shop manager）里，波间开始时：

```gdscript
## 从目录确定性选 N 个商品。seed 由房间种子派生，各端一致。
func _generate_shop_offers(catalog: ShopCatalog, seed: int, count: int) -> Array[ShopOfferDefinition]:
	var rng := DeterministicRngScript.new()
	rng.initialize(seed)  # 或项目现有的确定性 RNG 接口
	var pool := catalog.entries.duplicate()
	var offers: Array[ShopOfferDefinition] = []
	for _i in range(mini(count, pool.size())):
		var idx := rng.randi_range(0, pool.size() - 1)
		offers.append(pool[idx])
		pool.remove_at(idx)
	return offers
```

> **必须**：这个生成在**各端同种子**下结果一致。种子用 `sim_world` 现有房间种子派生（查 `deterministic_rng.gd` / `get_rng()` 现有用法，复用它而非新建）。注意现有 `get_rng()` 是逐 tick 推进的共享 RNG——**别用共享 RNG 做商店生成**（会消费掉僵尸 AI 的随机序列导致分叉）。要**独立派生**一个 RNG（种子 = 房间种子 + 波次号），或专门的 store rng。

- [ ] **Step 3: 内容目录注册**

`content_catalogs.gd` 加 `shop()` 访问器，`resources/shop/shop_catalog.tres` 填初始商品（约 10-15 个：3 武器、2-3 被动、属性升级若干、回血、弹药）。

- [ ] **Step 4: 验证**

`validate_shop_catalog.gd`：目录加载、offer 字段合法性（weapon_id 存在、price>0、display_name 非空、类型合法）。

Run → PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/shop/*.gd resources/shop/*.tres scripts/gameplay/content_catalogs.gd tools/validation/validate_shop_catalog.gd
git commit -m "feat(shop): 商店物品目录 + 确定性 RNG 生成"
```

---

## Task 4: 商店 UI（Control 面板）

**Files:**
- Create: `scenes/ui/ShopPanel.tscn` + `scripts/ui/shop_panel.gd`
- Modify: `scenes/gameplay/GameplayArena.tscn`（挂商店面板）
- Modify: `scripts/gameplay/gameplay_arena.gd`（生成商品 → 展示 → 监听购买 → 关闭）

**Interfaces:**
- Consumes: Task 3 的 offers、Task 1 的金钱、Task 5 的购买命令。
- Produces:
  - `ShopPanel`：显示金钱、商品列表（名称/价格/类型图标）、每项一个购买按钮、波间可购买 N 次。
  - arena 在 `intermission_started` → `_open_shop()`（生成 offers + 显示）；`wave_started` → `_close_shop()`。
  - 购买按钮 → `arena._on_shop_buy(offer)` → 发购买命令（Task 5）。

- [ ] **Step 1: 写 ShopPanel 场景 + 脚本**

Control 布局：顶部金钱 Label，下方商品按钮网格（复用现有 Control 风格，查现有 HUD 怎么做）。每个商品按钮显示 `名称 · 价格`，金钱不足时按钮禁用（redraw）。

```gdscript
class_name ShopPanel extends Control
signal buy_requested(offer)

func set_material(amount: int) -> void: ...
func set_offers(offers: Array, prices: Array) -> void: ...  # 生成按钮
func _on_button_pressed(offer_index: int) -> void:
	buy_requested.emit(_offers[offer_index])
```

- [ ] **Step 2: arena 集成**

`_open_shop()`：`_generate_shop_offers(...)` → `shop_panel.set_offers(...)` + `set_material(get_player_material(slot))` → `show()`。`_on_shop_buy` → 构造购买命令（Task 5）。金钱变化时刷新 `set_material`。

- [ ] **Step 3: 验证**

单机跑：`/Applications/Godot.app/Contents/MacOS/Godot --path .`，进单人 Demo，打一波到波间，确认商店弹出、显示金钱和商品。这是**人工验证**（Task 7），机器验证跑 import 不报错。

Run: import/parse check → 干净。

- [ ] **Step 4: Commit**

```bash
git add scenes/ui/ShopPanel.tscn scripts/ui/shop_panel.gd scenes/gameplay/GameplayArena.tscn scripts/gameplay/gameplay_arena.gd
git commit -m "feat(shop): 波间商店面板——显示金钱与商品，购买按钮"
```

---

## Task 5: 购买命令进模拟 + 成长表

**Files:**
- Modify: `scripts/sim/sim_world.gd`（新增 `player_upgrade_scale` 逐玩家成长表 + `queue_shop_purchase` 命令 + 应用）
- Modify: `scripts/sim/sim_hasher.gd`（混入成长表）
- Modify: `scripts/gameplay/gameplay_arena.gd`（发购买命令 + 扣费 + 应用）
- Test: `validate_shop_purchase.gd`

**Interfaces:**
- Consumes: Task 1 金钱、Task 3 offer。
- Produces:
  - `SimWorld.player_upgrade_scale := PackedFloat32Array()`：展平 `[slot * stat_count + stat_index]`，初始 1.0，进帧哈希。
  - 统计种类：`STAT_DAMAGE=0 / STAT_MAX_HEALTH=1 / STAT_MOVE_SPEED=2`（常量）。
  - `SimWorld.queue_shop_purchase(slot: int, offer_type: StringName, stat_index: int, amount: float, weapon_id: StringName, passive_id: StringName, price: int) -> void`：校验金钱→扣费→按类型应用（属性×scale、武器 grant 标记、被动 grant 标记、回血事件、弹药）。
  - `SimWorld.get_upgrade_scale(slot: int, stat_index: int) -> float`

- [ ] **Step 1: SimWorld 加成长表 + 购买命令**

`player_upgrade_scale` 声明 + `_init/reset` 复位（`fill(1.0)`），仿 `player_signature_scale`。

购买命令：

```gdscript
func queue_shop_purchase(
	slot: int, offer_type: StringName, stat_index: int, amount: float,
	weapon_id: StringName, passive_id: StringName, price: int
) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	pending_events.append({
		"kind": &"shop_purchase",
		"slot": slot, "offer_type": offer_type, "stat_index": stat_index,
		"amount": amount, "weapon_id": weapon_id,
		"passive_id": passive_id, "price": price,
	})
```

`_resolve_pending_events` 处理 `shop_purchase`：

```gdscript
elif kind == &"shop_purchase":
	_resolve_shop_purchase(event)

func _resolve_shop_purchase(event: Dictionary) -> void:
	var slot := int(event["slot"])
	if not spend_player_material(slot, int(event["price"])):
		return
	var type: StringName = event["offer_type"]
	if type == &"stat":
		var si := int(event["stat_index"])
		if si >= 0 and si < STAT_COUNT:
			player_upgrade_scale[slot * STAT_COUNT + si] *= maxf(float(event["amount"]), 0.0)
	elif type == &"heal":
		tick_player_heal_events.append({"slot": slot, "amount": float(event["amount"])})
	elif type == &"weapon" or type == &"passive" or type == &"ammo":
		# 武器/被动/弹药：grant 由 arena 表现层处理（不走模拟），
		# 这里只扣费；grant 时机见 Task 6 判定。
		pass
```

> **关键权衡**：武器/被动 grant 走 `EquipmentController`（表现层），若在模拟里扣费但表现层 grant 失败，会扣了钱没货。**决策**：武器/被动/弹药购买**不进模拟**，直接表现层扣费 + grant（单机即时生效）；属性升级/回血**进模拟**（确定性 + 帧哈希）。原因：武器 grant 是表现层系统，强行进模拟要新增"模拟层通知表现层 grant 武器"的协议面，复杂度高且风险大。**属性是数值必须确定性**，所以进模拟。这个分工在 Task 6 明确。

- [ ] **Step 2: 帧哈希混入成长表**

```gdscript
hasher.mix_bytes(world.player_upgrade_scale.to_byte_array())
```

- [ ] **Step 3: 验证**

`validate_shop_purchase.gd`：给 slot0 加 100 材料 → `queue_shop_purchase(stat_damage, 1.1, price 30)` → step 后 `get_upgrade_scale(0, DAMAGE)==1.1` 且材料剩 70；再买 price 100（不够）→ 不扣、scale 不变；回血购买 → `tick_player_heal_events` 出现。

Run → PASS；`validate_sim_determinism` → PASS

- [ ] **Step 4: Commit**

```bash
git add scripts/sim/sim_world.gd scripts/sim/sim_hasher.gd tools/validation/validate_shop_purchase.gd
git commit -m "feat(shop): 属性/回血购买进模拟——逐玩家成长表 + 确定性命令，进帧哈希"
```

---

## Task 6: 商店卖武器/被动/弹药 + 联机（协议扩展）

**Files:**
- Modify: `scripts/gameplay/gameplay_arena.gd`（`_on_shop_buy` 分派：属性/回血走模拟，武器/被动/弹药走表现层 grant）
- Modify: `scripts/player/equipment_controller.gd`（确认 `grant_item` 已支持武器 + 弹药）
- Modify: `scripts/gameplay/character/character_definition.gd`（若被动购买需扩展运行时被动，见下）
- **联机协议**：
  - Modify: `scripts/net/lobby_protocol.gd`（`EVENT_SHOP_PURCHASE := 3` + `pack_shop_purchase()`）
  - Modify: `server/src/lib/protocol.ts`（`EVENT_SHOP_PURCHASE` 常量 + `parseEvent` 白名单加行 + `PROTOCOL_VERSION` 4→5）
  - Modify: `scripts/net/lobby_protocol.gd` 的 `PROTOCOL_VERSION` 4→5

**Interfaces:**
- Consumes: Task 1/3/5。
- Produces:
  - `arena._on_shop_buy(offer)`：
    - `stat`/`heal` → 发 `queue_shop_purchase`（模拟，扣费+生效）
    - `weapon`/`passive`/`ammo` → 联机走 `pack_shop_purchase` 事件上行；单机直接表现层处理
  - 联机：购买事件经 `command["e"]` 通道 → 服务端 `parseEvent` 白名单放行 → 透传到各端 → `queue_shop_purchase` 进模拟（扣费+生效）。

- [ ] **Step 0: 协议扩展（联机装备购买前置）**

`lobby_protocol.gd`：
```gdscript
const EVENT_SHOP_PURCHASE := 3
const PROTOCOL_VERSION := 5

static func pack_shop_purchase(
	offer_type: StringName, price: int, stat_index: int, amount: float
) -> Dictionary:
	return {"k": EVENT_SHOP_PURCHASE, "t": String(offer_type), "p": price, "si": stat_index, "a": quantize(amount)}
```

`protocol.ts`：
```ts
export const EVENT_SHOP_PURCHASE = 3;
export const PROTOCOL_VERSION = 5;
// parseEvent 白名单：
if (kind !== EVENT_SHOT && kind !== EVENT_MELEE && kind !== EVENT_SPREAD_RESET && kind !== EVENT_SHOP_PURCHASE) return null;
// parseEvent 的数值字段循环加 'p'/'si'/'a'/'t'
```

> **事件类型用 int 而非 StringName**：`parseEvent` 已用 `EVENT_*` int 常量，`offer_type` 这个 String 得**量化成 int 枚举**（如 0=weapon/1=passive/2=ammo）塞进 `t`，或用 `t` 存 int。收端 `queue_shop_purchase` 恢复。

- [ ] **Step 1: arena 分派购买**

`_on_shop_buy(offer)` 按 `offer.offer_type` 分派：`stat`/`heal` → `queue_shop_purchase`（模拟）；`weapon`/`passive`/`ammo` → 联机发 `pack_shop_purchase` 事件上行，单机直接 `_buy_weapon`/`_buy_passive`/`_buy_ammo`（表现层）。

- [ ] **Step 2: 武器 grant + 退款**（同原计划）

```gdscript
func _buy_weapon(slot: int, offer: ShopOfferDefinition) -> void:
	var player := _player_for_slot(slot)
	if player == null:
		return
	if not sim_world.spend_player_material(slot, offer.price):
		return
	var granted := player.equipment.grant_item(offer.weapon_id, 1, true)
	if not granted:
		sim_world.add_player_material(slot, offer.price)  # 退款
```

- [ ] **Step 3: 被动购买（运行时附加）**

`PlayerController` 加 `runtime_passive_id: StringName`，购买被动时设置它，被动逻辑读取时优先 runtime。**不能直接改共享 `character_definition`**（会改所有引用同一 .tres 的玩家）。

- [ ] **Step 4: 弹药购买**：`equipment.add_ammo(weapon_id, amount)`，扣费同武器。

- [ ] **Step 5: 服务端透传购买**

服务端 `parseCommand`/帧同步已把 `command["e"]` 事件透传（现有 `EVENT_SHOT` 同路径）。`EVENT_SHOP_PURCHASE` 加白名单后自动透传。**事件进模拟**：各端 `_on_sim_*` 收到 `shop_purchase` 事件 → `queue_shop_purchase`（已实现于 Task 5）。

> **单机 vs 联机分派**：单机购买**不走**网络事件（直接表现层处理，无延迟）；联机购买**走**事件通道上行（服务端广播回来，各端确定性应用）。`_on_shop_buy` 里 `if online_mode: pack+上行 else: 直接处理`。

- [ ] **Step 6: 验证**

单机：波间买武器/被动/属性/回血各一次，确认金钱扣对、属性生效、武器装备上。

协议门禁：
```
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_online_frame_sync.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_sim_determinism.gd
```
Expected: 全 PASS（`validate_online_frame_sync` 会读服务端 `protocol.ts` 的 `PROTOCOL_VERSION`，确认客户端服务端一致）。

- [ ] **Step 7: Commit**

```bash
git add scripts/net/lobby_protocol.gd server/src/lib/protocol.ts scripts/gameplay/gameplay_arena.gd scripts/player/player_controller.gd
git commit -m "feat(shop): 联机购买走命令事件通道——EVENT_SHOP_PURCHASE + 协议 v5，武器/被动/弹药表现层grant"
```

---

## Task 7: 手感验证清单（交回用户）

**Files:** 无代码改动。

- [ ] **Step 1: 单机完整循环**

`/Applications/Godot.app/Contents/MacOS/Godot --path .` → 单人 → Demo 检查站。打第 1 波 → 波间应弹出商店，显示金钱和 3 个商品 → 买一个 → 打第 2 波 → 感受：升级后伤害/血量是否变强。

- [ ] **Step 2: 逐项购买验证**

| 商品 | 该看到 |
|---|---|
| 武器 | 买到后自动装备，切枪可见 |
| 被动 | 角色获得对应被动（防爆甲/医疗光环等） |
| 属性（伤害） | 打僵尸明显更疼 |
| 属性（生命） | 血条变厚 |
| 回血 | 当前血量补满 |
| 弹药 | 对应枪弹药增加 |

- [ ] **Step 3: 联机**

方案二联机：一名玩家买属性升级 → 两端都看到效果一致（无 desync）。武器/被动/弹药购买**若单机可用**，联机下观察是否生效（若标记为"联机待协议扩展"，则只测属性/回血）。

- [ ] **Step 4: 反馈回传**

记录：商店手感、成长曲线是否明显、购买是否顺畅、联机是否 desync。交回后按 `zombie-crisis-playtest` 重排。

---

## Self-Review 记录

- **Spec 覆盖**：材料掉落(T1)、波间事件(T2)、商店物品+UI(T3/T4)、购买生效(T5)、卖武器/被动/弹药+联机(T6)、手感验证(T7)——全覆盖。
- **确定性**：材料/成长表进帧哈希；商店物品确定性 RNG；属性/回血购买走模拟命令；武器/被动/弹药走表现层（已在 T5/T6 显式说明为什么不进模拟：grant 是表现层系统，强行进模拟需新增协议面）。**已知取舍**：武器/被动/弹药购买的联机同步留待协议扩展，写进 T6 判定。
- **Placeholder 扫描**：`DeterministicRng` 初始化方式标注"查现有用法复用"（`get_rng()` 是共享推进的，**不能用**，需独立派生）；`STAT_COUNT`/`STAT_*` 常量需在实现时定义。非空泛 TODO。
- **类型一致性**：`queue_shop_purchase`/`spend_player_material`/`add_player_material`/`get_upgrade_scale` 签名在任务间一致。
- **已知待确认项**：`DeterministicRng` 是否有独立派生接口（Task 3 Step 2）；`LobbyProtocol` 是否有通用命令通道（Task 6 Step 5）；`MapZombieDeathRuleDefinition` 现状字段（Task 1 Step 2）。
