# 枪械弹药核心 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在最新统一装备代码上加入手枪无限弹药与步枪有限弹药，使步枪每次真实开火消费 1 发，并把库存变化接入现有 `EquipmentItem.count_changed` 通道。

**Architecture:** 弹药配置保存在 `RangedWeaponDefinition`，运行时库存由每个玩家各自实例化的 `RangedWeapon` 保存。`RangedWeapon` 在调用现有 `_fire()` 前检查并消费弹药；空弹时不消耗 `WeaponTrigger` 的攻击机会，也不进入任何伤害或反馈逻辑。

**Tech Stack:** Godot 4.7.1、GDScript、`.tres` 武器资源、现有 `EquipmentItem` 信号体系。

## Global Constraints

- 基线提交为当前主线 `0ecfb59`；执行前若主线继续前进，先确认下列目标文件接口仍与本计划一致。
- 手枪无限弹药；步枪最大弹药固定为 360。
- 步枪每次真正执行的一发射击消费 1 发。
- 步枪为 0 发时，不产生伤害、枪声、枪口火焰、曳光、扩散增长、后坐力或 `attack_resolved`。
- `_fire()` 继续表示“已经获准执行的一发”，不得在 `_fire()` 内扣弹。
- 不实现弹匣、换弹动作或换弹时间。
- 当前仓库没有持久化自动测试套件；不得恢复旧 `tests/` 或 `tests/run_tests.sh`。
- 验证使用 Godot headless import、差异检查和后续 Demo 人工核心路径。
- 本计划最终只保留一个提交：`feat: add finite weapon ammo`。

---

### Task 1: 增加弹药配置、库存 API 与射击门控

**Files:**
- Modify: `scripts/combat/weapons/ranged_weapon_definition.gd:4-14`
- Modify: `scripts/combat/weapons/ranged_weapon.gd:16-86`
- Modify: `resources/weapons/pistol.tres:5-27`
- Modify: `resources/weapons/rifle.tres:5-27`

**Interfaces:**
- Consumes: `EquipmentItem.count_changed(remaining_count: int)`、`WeaponTrigger.try_attack(trigger_pressed: bool, trigger_just_pressed: bool) -> bool`、`RangedWeapon._fire(shot_direction: Vector3) -> void`。
- Produces: `RangedWeaponDefinition.uses_ammo: bool`、`max_ammo: int`、`RangedWeapon.set_ammo_count(amount: int) -> void`、`add_ammo(amount: int) -> int`、`get_ammo_count() -> int`、`get_max_ammo() -> int`、`has_ammo_for_shot() -> bool`、`try_consume_ammo() -> bool`。

- [ ] **Step 1: 记录当前基线并确认没有旧弹药实现**

Run:

```bash
git status --short
rg -n "uses_ammo|max_ammo|current_ammo|try_consume_ammo" \
  scripts/combat/weapons resources/weapons
```

Expected: 工作树只包含本任务预期改动；搜索不应在生产武器代码中找到完整弹药实现。

- [ ] **Step 2: 为远程武器定义增加弹药配置**

在 `RangedWeaponDefinition` 的扩散配置之前增加：

```gdscript
@export_group("Ammo")
@export var uses_ammo := false
@export_range(0, 9999, 1) var max_ammo := 0
```

配置资源：

```ini
# resources/weapons/pistol.tres
uses_ammo = false
max_ammo = 0

# resources/weapons/rifle.tres
uses_ammo = true
max_ammo = 360
```

- [ ] **Step 3: 在每个 RangedWeapon 实例内实现弹药状态**

在 `ranged_weapon.gd` 增加：

```gdscript
var current_ammo := 0

func set_ammo_count(amount: int) -> void:
	var next_ammo := clampi(amount, 0, get_max_ammo()) if _uses_ammo() else 0
	if next_ammo == current_ammo:
		return
	current_ammo = next_ammo
	count_changed.emit(current_ammo)

func add_ammo(amount: int) -> int:
	if not _uses_ammo() or amount <= 0:
		return 0
	var before := current_ammo
	set_ammo_count(current_ammo + amount)
	return current_ammo - before

func get_ammo_count() -> int:
	return current_ammo

func get_max_ammo() -> int:
	var ranged_definition := definition as RangedWeaponDefinition
	return maxi(ranged_definition.max_ammo, 0) if ranged_definition != null else 0

func get_remaining_count() -> int:
	return current_ammo if _uses_ammo() else -1

func has_ammo_for_shot() -> bool:
	return not _uses_ammo() or current_ammo > 0

func try_consume_ammo() -> bool:
	if not _uses_ammo():
		return true
	if current_ammo <= 0:
		return false
	set_ammo_count(current_ammo - 1)
	return true

func _uses_ammo() -> bool:
	var ranged_definition := definition as RangedWeaponDefinition
	return ranged_definition != null and ranged_definition.uses_ammo
```

不要为手枪保存一个伪造的巨大库存；无限弹药武器的 `get_ammo_count()` 保持为 0，显示层在后续计划中依据 `uses_ammo` 输出 `∞`。

- [ ] **Step 4: 在触发器消费攻击机会之前拦截空弹**

把 `_physics_process()` 改为：

```gdscript
func _physics_process(delta: float) -> void:
	spread_state.tick(delta)
	weapon_trigger.tick(delta)
	if (
		has_ammo_for_shot() and
		weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed) and
		try_consume_ammo()
	):
		_fire(aim_direction)
	trigger_just_pressed = false
```

保持 `_fire()` 原样。空弹检查必须位于 `WeaponTrigger.try_attack()` 前，避免空枪消耗连射冷却。

- [ ] **Step 5: 运行 Godot 解析与资源导入检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
git diff --check
```

Expected: Godot 退出码为 0；输出没有由本次改动引入的 `SCRIPT ERROR`、`Parse Error` 或资源加载错误；`git diff --check` 无输出。

- [ ] **Step 6: 审查核心分支条件**

Run:

```bash
git diff -- \
  scripts/combat/weapons/ranged_weapon_definition.gd \
  scripts/combat/weapons/ranged_weapon.gd \
  resources/weapons/pistol.tres \
  resources/weapons/rifle.tres
```

确认以下事实：

- 手枪 `uses_ammo = false`。
- 步枪 `uses_ammo = true` 且 `max_ammo = 360`。
- 只有 `try_consume_ammo()` 修改有限弹药库存。
- `_fire()` 没有新增扣弹逻辑。
- 空弹时不会调用 `WeaponTrigger.try_attack()`。

- [ ] **Step 7: 提交本计划**

```bash
git add \
  scripts/combat/weapons/ranged_weapon_definition.gd \
  scripts/combat/weapons/ranged_weapon.gd \
  resources/weapons/pistol.tres \
  resources/weapons/rifle.tres
git commit -m "feat: add finite weapon ammo"
```

Expected: 本计划范围只有一个提交，且不包含 `.godot/`、旧测试套件或其他功能文件。
