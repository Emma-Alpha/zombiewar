# 玩家独立武器系统（手枪、步枪、刀）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将当前写死在玩家节点中的步枪重构为可独立配置、装备和替换的武器系统，并交付手枪单发、步枪连发、刀近战三种可切换武器。

**Architecture:** `PlayerController`继续作为唯一输入读取者，只负责移动、朝向、武器槽切换和把攻击输入交给`EquipmentController`；`EquipmentController`持有独立武器场景并代理当前武器的动画与命中事件。手枪和步枪共享`RangedWeapon`命中扫描实现，通过`RangedWeaponDefinition`和`WeaponTrigger`区分单发/连发；刀使用`MeleeWeapon`，在`Slash`动画的固定命中窗口内查询玩家前方最近的一个目标。第一阶段继续复用角色GLTF内嵌的`Pistol`、`Rifle`、`Knife`视觉节点，但武器逻辑、参数和场景均已独立，未来替换独立模型时无需改玩家或攻击逻辑。

**Tech Stack:** Godot 4.7.1、GDScript、CharacterBody3D、PhysicsRayQueryParameters3D、PhysicsShapeQueryParameters3D、Jolt Physics、GL Compatibility、现有原生Godot headless测试运行器。

## Global Constraints

- 所有计划说明使用中文；代码标识符、Godot节点名、动画名和测试断言保持英文。
- 保持Godot `4.7.1.stable.official.a13da4feb`、Jolt Physics、GL Compatibility、1280×720窗口、正交2.5D镜头和当前主菜单入口不变。
- 当前工作区已有大量用户未提交修改；执行时不得重置、覆盖、暂存或提交无关内容。
- 本计划直接在当前工作区增量实现；改动集中在玩家、战斗和demo接线，默认不创建隔离worktree。
- 本计划共4个task，不再拆分更多独立task；每个task遵循RED→GREEN→回归验证。
- 执行代理不得按task创建独立提交；整个计划完成后由用户自行暂存和提交。
- `PlayerController`仍是唯一读取`Input`的节点；任何武器、`EquipmentController`和触发器辅助类均不得直接读取全局输入。
- 把输入动作`fire`改名为`primary_attack`并继续绑定J；新增`weapon_pistol`=`1`、`weapon_rifle`=`2`、`weapon_knife`=`3`。
- 第一版默认装备步枪；1切手枪、2切步枪、3切刀，切换立即生效并取消上一把武器尚未完成的攻击。
- 手枪初始参数：单发、35伤害、3发/秒、24米射程、6度/15米辅助命中、视觉后坐0.10、镜头脉冲0.08。
- 步枪保持当前核心参数：连发、25伤害、6发/秒、28米射程、5度/18米辅助命中、视觉后坐0.08、镜头脉冲0.06。
- 刀初始参数：单次挥砍、35伤害、1.5次/秒、0.22秒命中时刻、0.55秒攻击锁、前方`Vector3(1.5, 1.4, 1.4)`盒形范围、镜头脉冲0.04。
- 刀每次挥砍只伤害范围内距离玩家最近的一个`damageable_targets`目标，并对该目标只结算一次；首版不实现穿透式多目标横扫。
- 手枪/步枪继续保留射线遮挡、目标辅助命中、结构化`HitResult`、弹道池、枪口火焰、枪声、角色后坐、镜头反馈、HIT/CRITICAL/KILL和血迹链路。
- 刀使用角色资源现有`Knife`视觉、`Idle`待机、`Run_Slash`移动、`Slash`攻击；受伤和死亡可以中断挥砍，且被中断的攻击不得在之后补结算伤害。
- 第一阶段不加入弹药、换弹、背包容量、拾取、掉落、武器升级、独立武器模型导出或移动端武器切换按钮；现有移动端攻击按钮改为触发`primary_attack`，使用当前已装备武器。
- 所有Godot命令使用`/Applications/Godot.app/Contents/MacOS/Godot`。

---

## 文件结构

### 新增核心脚本

- `scripts/combat/weapons/weapon_definition.gd`：所有武器共享的身份、触发方式、伤害、动画和反馈配置。
- `scripts/combat/weapons/ranged_weapon_definition.gd`：命中扫描武器的射程、碰撞层、辅助瞄准、枪口和弹道池配置。
- `scripts/combat/weapons/melee_weapon_definition.gd`：近战武器的盒形范围、命中延迟和碰撞层配置。
- `scripts/combat/weapons/weapon_trigger.gd`：纯逻辑触发器，统一实现单发、连发、冷却和80毫秒短按缓冲。
- `scripts/combat/weapons/weapon_base.gd`：武器运行时公共接口、上下文绑定、视觉显隐、输入注入和通用信号。
- `scripts/combat/weapons/ranged_weapon.gd`：从现有`player_weapon.gd`迁移的命中扫描、辅助命中与枪械反馈。
- `scripts/combat/weapons/melee_weapon.gd`：刀的挥砍时序、盒形查询、最近目标选择和一次性伤害结算。
- `scripts/player/equipment_controller.gd`：创建loadout、切换槽位、代理当前武器输入/动画/结果。

### 新增资源与场景

- `resources/weapons/pistol.tres`：手枪数值和动画配置。
- `resources/weapons/rifle.tres`：步枪数值和动画配置。
- `resources/weapons/knife.tres`：刀的数值、范围和动画配置。
- `scenes/weapons/Pistol.tscn`：独立手枪运行时场景，包含枪口、枪口火焰和3D音效。
- `scenes/weapons/Rifle.tscn`：独立步枪运行时场景，包含枪口、枪口火焰和3D音效。
- `scenes/weapons/Knife.tscn`：独立刀运行时场景，不创建枪口、弹道或射击音效节点。

### 新增测试

- `tests/unit/test_weapon_configuration.gd`：三种配置、单发/连发触发语义和短按缓冲。
- `tests/unit/test_weapon_loadout.gd`：装备初始化、槽位切换、视觉显隐和输入代理。
- `tests/unit/test_player_melee_weapon.gd`：刀的前摇、单目标命中、攻击锁和中断。

### 修改文件

- `scripts/player/player_controller.gd`：删除固定`Rifle`绑定，接入`EquipmentController`、通用攻击信号和武器动画优先级。
- `scenes/player/Player.tscn`：删除固定`Weapon`节点，添加`EquipmentController`并配置三把武器场景。
- `scripts/gameplay/demo_arena.gd`：从`shot_fired`接线改为通用`attack_resolved`接线。
- `scenes/gameplay/DemoArena.tscn`：更新键位提示。
- `project.godot`：将J映射到`primary_attack`，加入数字键1/2/3武器槽动作。
- `scripts/ui/mobile_action_button.gd`：不改实现，只继续消费任意注入的动作名。
- `tests/unit/test_project_contract.gd`：更新输入动作契约。
- `tests/unit/test_mobile_touch_controls.gd`：把移动端测试动作从`fire`改为`primary_attack`。
- `tests/unit/test_weapon_feedback.gd`：通过`EquipmentController.current_weapon`验证当前枪械反馈。
- `tests/unit/test_tracer_pool.gd`：通过loadout中的步枪验证弹道池。
- `tests/integration/test_demo_scene.gd`：验证三武器loadout、默认步枪和HUD控制说明。
- `tests/test_runner.gd`：注册三个新测试文件。
- `README.md`：记录三把武器、切换键、攻击语义和当前范围限制。

### 删除文件

- `scripts/combat/player_weapon.gd`：其职责完整迁移到`weapon_base.gd`和`ranged_weapon.gd`后删除，避免新旧两套武器入口并存。

---

### Task 1: 建立数据驱动武器配置与单发/连发触发器

**Files:**
- Create: `scripts/combat/weapons/weapon_definition.gd`
- Create: `scripts/combat/weapons/ranged_weapon_definition.gd`
- Create: `scripts/combat/weapons/melee_weapon_definition.gd`
- Create: `scripts/combat/weapons/weapon_trigger.gd`
- Create: `resources/weapons/pistol.tres`
- Create: `resources/weapons/rifle.tres`
- Create: `resources/weapons/knife.tres`
- Create: `tests/unit/test_weapon_configuration.gd`
- Modify: `tests/test_runner.gd:3-28`

**Interfaces:**
- Consumes: `FireGate.new(seconds_between_shots: float)`、`FireGate.tick(delta: float)`、`FireGate.request_shot(buffer_seconds: float)`、`FireGate.try_consume(trigger_held: bool) -> bool`。
- Produces: `WeaponDefinition.TriggerMode { PRESS, HOLD }`。
- Produces: `WeaponTrigger.new(trigger_mode: int, attacks_per_second: float)`、`tick(delta: float) -> void`、`try_attack(trigger_pressed: bool, trigger_just_pressed: bool) -> bool`、`reset() -> void`。
- Produces: `pistol.tres`、`rifle.tres`、`knife.tres`，供后续独立武器场景直接引用。

- [ ] **Step 1: 写三武器配置与触发语义失败测试**

创建`tests/unit/test_weapon_configuration.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const WeaponDefinition = preload("res://scripts/combat/weapons/weapon_definition.gd")
const RangedWeaponDefinition = preload(
	"res://scripts/combat/weapons/ranged_weapon_definition.gd"
)
const MeleeWeaponDefinition = preload(
	"res://scripts/combat/weapons/melee_weapon_definition.gd"
)
const WeaponTrigger = preload("res://scripts/combat/weapons/weapon_trigger.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var pistol := load("res://resources/weapons/pistol.tres") as RangedWeaponDefinition
	var rifle := load("res://resources/weapons/rifle.tres") as RangedWeaponDefinition
	var knife := load("res://resources/weapons/knife.tres") as MeleeWeaponDefinition
	_append(failures, Assertions.expect_true(pistol != null, "Pistol definition loads"))
	_append(failures, Assertions.expect_true(rifle != null, "Rifle definition loads"))
	_append(failures, Assertions.expect_true(knife != null, "Knife definition loads"))
	if pistol == null or rifle == null or knife == null:
		return failures

	_append(failures, Assertions.expect_equal(
		pistol.trigger_mode,
		WeaponDefinition.TriggerMode.PRESS,
		"Pistol uses press-only trigger mode"
	))
	_append(failures, Assertions.expect_float_near(
		pistol.damage, 35.0, 0.0001, "Pistol base damage"
	))
	_append(failures, Assertions.expect_float_near(
		pistol.attack_range, 24.0, 0.0001, "Pistol range"
	))
	_append(failures, Assertions.expect_equal(
		rifle.trigger_mode,
		WeaponDefinition.TriggerMode.HOLD,
		"Rifle uses held trigger mode"
	))
	_append(failures, Assertions.expect_float_near(
		rifle.attacks_per_second, 6.0, 0.0001, "Rifle cadence"
	))
	_append(failures, Assertions.expect_equal(
		knife.attack_animation, &"Slash", "Knife attack animation"
	))
	_append(failures, Assertions.expect_vector3_near(
		knife.hitbox_size,
		Vector3(1.5, 1.4, 1.4),
		0.0001,
		"Knife hitbox size"
	))

	var pistol_trigger := WeaponTrigger.new(
		pistol.trigger_mode,
		pistol.attacks_per_second
	)
	_append(failures, Assertions.expect_true(
		pistol_trigger.try_attack(true, true),
		"Pistol fires on the initial press"
	))
	pistol_trigger.tick(1.0 / pistol.attacks_per_second)
	_append(failures, Assertions.expect_true(
		not pistol_trigger.try_attack(true, false),
		"Pistol does not repeat while the button remains held"
	))
	_append(failures, Assertions.expect_true(
		pistol_trigger.try_attack(true, true),
		"Pistol fires again on a new press"
	))

	var rifle_trigger := WeaponTrigger.new(
		rifle.trigger_mode,
		rifle.attacks_per_second
	)
	_append(failures, Assertions.expect_true(
		rifle_trigger.try_attack(true, true),
		"Rifle fires immediately when held"
	))
	rifle_trigger.tick(1.0 / rifle.attacks_per_second)
	_append(failures, Assertions.expect_true(
		rifle_trigger.try_attack(true, false),
		"Rifle repeats while the button remains held"
	))

	var buffered_pistol := WeaponTrigger.new(
		pistol.trigger_mode,
		pistol.attacks_per_second
	)
	buffered_pistol.try_attack(true, true)
	buffered_pistol.tick(0.30)
	_append(failures, Assertions.expect_true(
		not buffered_pistol.try_attack(false, true),
		"Pistol press during cooldown waits for the gate"
	))
	buffered_pistol.tick(0.04)
	_append(failures, Assertions.expect_true(
		buffered_pistol.try_attack(false, false),
		"Buffered pistol press fires after cooldown"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

- [ ] **Step 2: 注册测试并确认RED**

在`tests/test_runner.gd`的`TEST_PATHS`中，紧跟`test_directional_fire.gd`加入：

```gdscript
	"res://tests/unit/test_weapon_configuration.gd",
```

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: exit code `1`；运行器报告无法加载`weapon_definition.gd`、`weapon_trigger.gd`或三个`.tres`资源。

- [ ] **Step 3: 创建共享、远程和近战配置类型**

创建`scripts/combat/weapons/weapon_definition.gd`：

```gdscript
extends Resource
class_name WeaponDefinition

enum TriggerMode {
	PRESS,
	HOLD,
}

@export var weapon_id: StringName
@export var display_name: String
@export var visual_node_name: StringName
@export var trigger_mode := TriggerMode.PRESS
@export_range(0.1, 30.0, 0.1) var attacks_per_second := 1.0
@export_range(0.0, 500.0, 1.0) var damage := 1.0
@export var idle_animation: StringName = &"Idle"
@export var run_animation: StringName = &"Run"
@export var attack_animation: StringName
@export_range(0.0, 2.0, 0.01) var attack_lock_duration := 0.0
@export_range(0.0, 0.25, 0.01) var visual_recoil_kick := 0.0
@export_range(0.0, 0.12, 0.01) var camera_impulse_strength := 0.0
```

创建`scripts/combat/weapons/ranged_weapon_definition.gd`：

```gdscript
extends WeaponDefinition
class_name RangedWeaponDefinition

@export_range(1.0, 100.0, 0.5) var attack_range := 28.0
@export_flags_3d_physics var hit_collision_mask: int = 5
@export_range(1, 64, 1) var tracer_pool_size := 8
@export_range(0.0, 12.0, 0.25) var aim_assist_angle_degrees := 5.0
@export_range(0.0, 40.0, 0.5) var aim_assist_range := 18.0
@export var muzzle_anchor_offset := Vector3(0.0, 0.0, -0.55)
```

创建`scripts/combat/weapons/melee_weapon_definition.gd`：

```gdscript
extends WeaponDefinition
class_name MeleeWeaponDefinition

@export_flags_3d_physics var hit_collision_mask: int = 4
@export var hitbox_size := Vector3(1.5, 1.4, 1.4)
@export var hitbox_offset := Vector3(0.0, 1.0, -0.85)
@export_range(0.0, 1.0, 0.01) var impact_delay := 0.22
```

- [ ] **Step 4: 创建统一武器触发器**

创建`scripts/combat/weapons/weapon_trigger.gd`：

```gdscript
extends RefCounted
class_name WeaponTrigger

const FireGate = preload("res://scripts/combat/fire_gate.gd")
const WeaponDefinition = preload("res://scripts/combat/weapons/weapon_definition.gd")

var trigger_mode: int
var fire_gate: FireGate

func _init(value_trigger_mode: int, attacks_per_second: float) -> void:
	trigger_mode = value_trigger_mode
	fire_gate = FireGate.new(1.0 / maxf(attacks_per_second, 0.1))

func tick(delta: float) -> void:
	fire_gate.tick(delta)

func try_attack(trigger_pressed: bool, trigger_just_pressed: bool) -> bool:
	if trigger_just_pressed:
		fire_gate.request_shot(0.08)
	var trigger_active := trigger_just_pressed
	if trigger_mode == WeaponDefinition.TriggerMode.HOLD:
		trigger_active = trigger_pressed
	return fire_gate.try_consume(trigger_active)

func reset() -> void:
	fire_gate.remaining = 0.0
	fire_gate.buffered_trigger_remaining = 0.0
```

- [ ] **Step 5: 创建三把武器的精确配置资源**

创建`resources/weapons/pistol.tres`：

```text
[gd_resource type="Resource" script_class="RangedWeaponDefinition" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/combat/weapons/ranged_weapon_definition.gd" id="1_definition"]

[resource]
script = ExtResource("1_definition")
weapon_id = &"pistol"
display_name = "PISTOL"
visual_node_name = &"Pistol"
trigger_mode = 0
attacks_per_second = 3.0
damage = 35.0
idle_animation = &"Idle_Gun"
run_animation = &"Run_Gun"
attack_animation = &""
attack_lock_duration = 0.0
visual_recoil_kick = 0.10
camera_impulse_strength = 0.08
attack_range = 24.0
hit_collision_mask = 5
tracer_pool_size = 6
aim_assist_angle_degrees = 6.0
aim_assist_range = 15.0
muzzle_anchor_offset = Vector3(0, 0, -0.35)
```

创建`resources/weapons/rifle.tres`：

```text
[gd_resource type="Resource" script_class="RangedWeaponDefinition" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/combat/weapons/ranged_weapon_definition.gd" id="1_definition"]

[resource]
script = ExtResource("1_definition")
weapon_id = &"rifle"
display_name = "RIFLE"
visual_node_name = &"Rifle"
trigger_mode = 1
attacks_per_second = 6.0
damage = 25.0
idle_animation = &"Idle_Gun"
run_animation = &"Run_Gun"
attack_animation = &""
attack_lock_duration = 0.0
visual_recoil_kick = 0.08
camera_impulse_strength = 0.06
attack_range = 28.0
hit_collision_mask = 5
tracer_pool_size = 8
aim_assist_angle_degrees = 5.0
aim_assist_range = 18.0
muzzle_anchor_offset = Vector3(0, 0, -0.55)
```

创建`resources/weapons/knife.tres`：

```text
[gd_resource type="Resource" script_class="MeleeWeaponDefinition" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/combat/weapons/melee_weapon_definition.gd" id="1_definition"]

[resource]
script = ExtResource("1_definition")
weapon_id = &"knife"
display_name = "KNIFE"
visual_node_name = &"Knife"
trigger_mode = 0
attacks_per_second = 1.5
damage = 35.0
idle_animation = &"Idle"
run_animation = &"Run_Slash"
attack_animation = &"Slash"
attack_lock_duration = 0.55
visual_recoil_kick = 0.0
camera_impulse_strength = 0.04
hit_collision_mask = 4
hitbox_size = Vector3(1.5, 1.4, 1.4)
hitbox_offset = Vector3(0, 1, -0.85)
impact_delay = 0.22
```

- [ ] **Step 6: 运行配置测试确认GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit-after 3
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: 新资源完成导入；`test_weapon_configuration.gd`通过，既有测试不因新增未接线资源而回退。

---

### Task 2: 抽离远程武器场景并接入装备控制器

**Files:**
- Create: `scripts/combat/weapons/weapon_base.gd`
- Create: `scripts/combat/weapons/ranged_weapon.gd`
- Create: `scripts/player/equipment_controller.gd`
- Create: `scenes/weapons/Pistol.tscn`
- Create: `scenes/weapons/Rifle.tscn`
- Create: `tests/unit/test_weapon_loadout.gd`
- Modify: `scripts/player/player_controller.gd:1-205`
- Modify: `scenes/player/Player.tscn:1-65`
- Modify: `scripts/gameplay/demo_arena.gd:1-80`
- Modify: `project.godot:27-58`
- Modify: `tests/unit/test_project_contract.gd`
- Modify: `tests/unit/test_mobile_touch_controls.gd`
- Modify: `tests/unit/test_weapon_feedback.gd`
- Modify: `tests/unit/test_tracer_pool.gd`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `tests/test_runner.gd`
- Delete: `scripts/combat/player_weapon.gd`

**Interfaces:**
- Consumes: Task 1的`WeaponDefinition`、`RangedWeaponDefinition`、`WeaponTrigger`和两个远程`.tres`。
- Produces: `WeaponBase.bind_context(wielder: CharacterBody3D, visual_root: Node3D, functional_ray_origin: Marker3D) -> void`。
- Produces: `WeaponBase.set_attack_input(trigger_pressed: bool, trigger_just_pressed: bool, aim_direction: Vector3) -> void`、`set_equipped(value: bool) -> void`、`cancel_attack() -> void`。
- Produces: `EquipmentController.setup(...)`、`equip_slot(slot_index: int) -> bool`、`get_current_weapon() -> WeaponBase`、`get_current_definition() -> WeaponDefinition`、`get_idle_animation() -> StringName`、`get_run_animation() -> StringName`。
- Produces: `PlayerController.attack_resolved(direction: Vector3, result: HitResult, camera_impulse_strength: float)`，替代枪械专用`shot_fired`。

- [ ] **Step 1: 写远程loadout与视觉切换失败测试**

创建`tests/unit/test_weapon_loadout.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const EquipmentController = preload("res://scripts/player/equipment_controller.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(player)
	var equipment := player.get_node_or_null("EquipmentController") as EquipmentController
	_append(failures, Assertions.expect_true(
		equipment != null,
		"Player owns an equipment controller"
	))
	if equipment == null:
		player.free()
		return failures

	_append(failures, Assertions.expect_equal(
		equipment.weapons.size(), 2, "Initial ranged loadout has pistol and rifle"
	))
	_append(failures, Assertions.expect_equal(
		equipment.get_current_definition().weapon_id,
		&"rifle",
		"Player starts with the rifle"
	))
	var rifle_visual := player.visual_root.find_child("Rifle", true, false) as Node3D
	var pistol_visual := player.visual_root.find_child("Pistol", true, false) as Node3D
	_append(failures, Assertions.expect_true(
		rifle_visual != null and rifle_visual.visible,
		"Starting rifle visual is visible"
	))
	_append(failures, Assertions.expect_true(
		pistol_visual != null and not pistol_visual.visible,
		"Unequipped pistol visual is hidden"
	))

	_append(failures, Assertions.expect_true(
		equipment.equip_slot(0), "Pistol slot can be equipped"
	))
	_append(failures, Assertions.expect_equal(
		equipment.get_current_definition().weapon_id,
		&"pistol",
		"Equipping slot zero selects the pistol"
	))
	_append(failures, Assertions.expect_true(
		pistol_visual.visible and not rifle_visual.visible,
		"Equipping pistol swaps embedded weapon visuals"
	))
	_append(failures, Assertions.expect_equal(
		equipment.get_idle_animation(),
		&"Idle_Gun",
		"Pistol exposes gun idle animation"
	))
	_append(failures, Assertions.expect_true(
		not equipment.equip_slot(9),
		"Invalid loadout slot is rejected without changing weapons"
	))
	player.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在`tests/test_runner.gd`中紧跟武器配置测试加入：

```gdscript
	"res://tests/unit/test_weapon_loadout.gd",
```

运行全套测试。Expected: FAIL，因为`EquipmentController`、独立武器场景和新玩家节点尚不存在。

- [ ] **Step 2: 创建武器公共运行时接口**

创建`scripts/combat/weapons/weapon_base.gd`：

```gdscript
extends Node3D
class_name WeaponBase

const HitResult = preload("res://scripts/combat/hit_result.gd")
const WeaponMath = preload("res://scripts/combat/weapon_math.gd")

signal attack_started(animation_name: StringName, lock_duration: float)
signal attack_resolved(
	origin: Vector3,
	direction: Vector3,
	result: HitResult,
	visual_recoil_kick: float,
	camera_impulse_strength: float
)

@export var definition: WeaponDefinition

var wielder: CharacterBody3D
var character_visual_root: Node3D
var functional_ray_origin: Marker3D
var visual_anchor: Node3D
var trigger_pressed := false
var trigger_just_pressed := false
var aim_direction := Vector3.FORWARD

func bind_context(
	value_wielder: CharacterBody3D,
	value_visual_root: Node3D,
	value_functional_ray_origin: Marker3D
) -> void:
	wielder = value_wielder
	character_visual_root = value_visual_root
	functional_ray_origin = value_functional_ray_origin
	visual_anchor = character_visual_root.find_child(
		String(definition.visual_node_name),
		true,
		false
	) as Node3D

func set_attack_input(
	value_trigger_pressed: bool,
	value_trigger_just_pressed: bool,
	value_aim_direction: Vector3
) -> void:
	trigger_pressed = value_trigger_pressed
	trigger_just_pressed = value_trigger_just_pressed
	aim_direction = WeaponMath.flat_direction(value_aim_direction)

func set_equipped(value: bool) -> void:
	visible = value
	set_process(value)
	set_physics_process(value)
	if visual_anchor != null:
		visual_anchor.visible = value
	if not value:
		cancel_attack()

func cancel_attack() -> void:
	trigger_pressed = false
	trigger_just_pressed = false

func get_idle_animation() -> StringName:
	return definition.idle_animation

func get_run_animation() -> StringName:
	return definition.run_animation
```

- [ ] **Step 3: 将现有命中扫描实现迁移为RangedWeapon**

以当前`scripts/combat/player_weapon.gd`为迁移源创建`scripts/combat/weapons/ranged_weapon.gd`，保留以下现有方法的完整算法：`_find_assisted_target`、`_intersect_shot`、`_prewarm_tracers`、`_acquire_tracer`和命中后的`HitResult`/弹道/枪口/音效链路。进行以下精确结构替换：

```gdscript
extends WeaponBase
class_name RangedWeapon

const AimAssistMath = preload("res://scripts/combat/aim_assist_math.gd")
const HitResult = preload("res://scripts/combat/hit_result.gd")
const TRACER_SCENE := preload("res://scenes/fx/ShotTracer.tscn")
const MuzzleFlash = preload("res://scripts/fx/muzzle_flash.gd")
const WeaponTrigger = preload("res://scripts/combat/weapons/weapon_trigger.gd")

@onready var muzzle: Marker3D = $Muzzle
@onready var muzzle_flash: MuzzleFlash = $Muzzle/MuzzleFlash
@onready var shot_audio: AudioStreamPlayer3D = $ShotAudio

var weapon_trigger: WeaponTrigger
var tracer_pool: Array[ShotTracer] = []
var tracer_pool_cursor := 0

func _ready() -> void:
	var ranged_definition := definition as RangedWeaponDefinition
	weapon_trigger = WeaponTrigger.new(
		ranged_definition.trigger_mode,
		ranged_definition.attacks_per_second
	)
	_prewarm_tracers()

func bind_context(
	value_wielder: CharacterBody3D,
	value_visual_root: Node3D,
	value_functional_ray_origin: Marker3D
) -> void:
	super.bind_context(
		value_wielder,
		value_visual_root,
		value_functional_ray_origin
	)
	var ranged_definition := definition as RangedWeaponDefinition
	muzzle.position = ranged_definition.muzzle_anchor_offset
	if visual_anchor != null:
		top_level = true
		global_transform = visual_anchor.global_transform
	if functional_ray_origin != null:
		functional_ray_origin.global_position = muzzle.global_position

func _physics_process(delta: float) -> void:
	weapon_trigger.tick(delta)
	if weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed):
		_fire(aim_direction)
	trigger_just_pressed = false

func _process(_delta: float) -> void:
	if visual_anchor != null and is_instance_valid(visual_anchor):
		global_transform = visual_anchor.global_transform

func set_equipped(value: bool) -> void:
	super.set_equipped(value)
	if value and functional_ray_origin != null:
		functional_ray_origin.global_position = muzzle.global_position

func cancel_attack() -> void:
	super.cancel_attack()
	if weapon_trigger != null:
		weapon_trigger.reset()
```

把原`_fire(player, shot_direction)`改为`_fire(shot_direction)`；查询排除项使用`[wielder.get_rid()]`。所有原导出字段替换为局部定义读取：

```gdscript
var ranged_definition := definition as RangedWeaponDefinition
var direct_end := WeaponMath.ray_end_from_direction(
	ray_origin,
	ray_direction,
	ranged_definition.attack_range
)
```

```gdscript
var selected := AimAssistMath.select_best_index(
	origin,
	direction,
	points,
	ranged_definition.aim_assist_range,
	deg_to_rad(ranged_definition.aim_assist_angle_degrees)
)
```

```gdscript
var query := PhysicsRayQueryParameters3D.create(
	from,
	to,
	ranged_definition.hit_collision_mask,
	[wielder.get_rid()]
)
```

命中结算使用`ranged_definition.damage`，弹道池使用`ranged_definition.tracer_pool_size`。原`shot_fired.emit(...)`替换为：

```gdscript
attack_resolved.emit(
	ray_origin,
	ray_direction,
	hit_result,
	ranged_definition.visual_recoil_kick,
	ranged_definition.camera_impulse_strength
)
```

迁移完成后删除`scripts/combat/player_weapon.gd`，并运行：

```bash
rg -n "PlayerWeapon|player_weapon.gd" scripts scenes tests
```

Expected: 在后续步骤改完调用方后无输出。

- [ ] **Step 4: 创建手枪与步枪独立场景**

创建`scenes/weapons/Pistol.tscn`：

```text
[gd_scene load_steps=5 format=3]

[ext_resource type="Script" path="res://scripts/combat/weapons/ranged_weapon.gd" id="1_weapon"]
[ext_resource type="Resource" path="res://resources/weapons/pistol.tres" id="2_definition"]
[ext_resource type="PackedScene" path="res://scenes/fx/MuzzleFlash.tscn" id="3_muzzle_flash"]
[ext_resource type="AudioStream" path="res://assets/sfx/weapons/impactMetal_heavy_002.ogg" id="4_shot_audio"]

[node name="Pistol" type="Node3D"]
script = ExtResource("1_weapon")
definition = ExtResource("2_definition")

[node name="Muzzle" type="Marker3D" parent="."]

[node name="MuzzleFlash" parent="Muzzle" instance=ExtResource("3_muzzle_flash")]

[node name="ShotAudio" type="AudioStreamPlayer3D" parent="."]
stream = ExtResource("4_shot_audio")
volume_db = -8.0
unit_size = 6.0
max_distance = 32.0
```

创建`scenes/weapons/Rifle.tscn`：

```text
[gd_scene load_steps=5 format=3]

[ext_resource type="Script" path="res://scripts/combat/weapons/ranged_weapon.gd" id="1_weapon"]
[ext_resource type="Resource" path="res://resources/weapons/rifle.tres" id="2_definition"]
[ext_resource type="PackedScene" path="res://scenes/fx/MuzzleFlash.tscn" id="3_muzzle_flash"]
[ext_resource type="AudioStream" path="res://assets/sfx/weapons/impactMetal_heavy_002.ogg" id="4_shot_audio"]

[node name="Rifle" type="Node3D"]
script = ExtResource("1_weapon")
definition = ExtResource("2_definition")

[node name="Muzzle" type="Marker3D" parent="."]

[node name="MuzzleFlash" parent="Muzzle" instance=ExtResource("3_muzzle_flash")]

[node name="ShotAudio" type="AudioStreamPlayer3D" parent="."]
stream = ExtResource("4_shot_audio")
volume_db = -8.0
unit_size = 6.0
max_distance = 32.0
```

- [ ] **Step 5: 创建EquipmentController并代理当前武器**

创建`scripts/player/equipment_controller.gd`：

```gdscript
extends Node
class_name EquipmentController

const HitResult = preload("res://scripts/combat/hit_result.gd")
const EMBEDDED_WEAPON_NAMES: Array[StringName] = [
	&"Axe", &"Guitar", &"Knife", &"Pistol", &"Rifle", &"Shotgun", &"SMG",
	&"Spear", &"WoodenBat_Barbed", &"WoodenBat_Saw",
]

signal attack_started(animation_name: StringName, lock_duration: float)
signal attack_resolved(
	origin: Vector3,
	direction: Vector3,
	result: HitResult,
	visual_recoil_kick: float,
	camera_impulse_strength: float
)
signal weapon_changed(definition: WeaponDefinition)

@export var loadout: Array[PackedScene] = []
@export_range(0, 8, 1) var starting_slot := 0

var weapons: Array[WeaponBase] = []
var current_slot := -1
var current_weapon: WeaponBase
var initialized := false

func setup(
	wielder: CharacterBody3D,
	visual_root: Node3D,
	functional_ray_origin: Marker3D
) -> void:
	if initialized:
		return
	initialized = true
	for weapon_name in EMBEDDED_WEAPON_NAMES:
		var embedded_visual := visual_root.find_child(
			String(weapon_name),
			true,
			false
		) as Node3D
		if embedded_visual != null:
			embedded_visual.visible = false
	for weapon_scene in loadout:
		var weapon := weapon_scene.instantiate() as WeaponBase
		add_child(weapon)
		weapon.bind_context(wielder, visual_root, functional_ray_origin)
		weapon.attack_started.connect(_on_attack_started)
		weapon.attack_resolved.connect(_on_attack_resolved)
		weapon.set_equipped(false)
		weapons.append(weapon)
	equip_slot(starting_slot)

func equip_slot(slot_index: int) -> bool:
	if slot_index < 0 or slot_index >= weapons.size():
		return false
	if current_weapon != null:
		current_weapon.set_equipped(false)
	current_slot = slot_index
	current_weapon = weapons[current_slot]
	current_weapon.set_equipped(true)
	weapon_changed.emit(current_weapon.definition)
	return true

func set_attack_input(
	trigger_pressed: bool,
	trigger_just_pressed: bool,
	aim_direction: Vector3
) -> void:
	if current_weapon != null:
		current_weapon.set_attack_input(
			trigger_pressed,
			trigger_just_pressed,
			aim_direction
		)

func cancel_attack() -> void:
	if current_weapon != null:
		current_weapon.cancel_attack()

func get_current_weapon() -> WeaponBase:
	return current_weapon

func get_current_definition() -> WeaponDefinition:
	return current_weapon.definition if current_weapon != null else null

func get_idle_animation() -> StringName:
	return current_weapon.get_idle_animation() if current_weapon != null else &"Idle"

func get_run_animation() -> StringName:
	return current_weapon.get_run_animation() if current_weapon != null else &"Run"

func _on_attack_started(animation_name: StringName, lock_duration: float) -> void:
	attack_started.emit(animation_name, lock_duration)

func _on_attack_resolved(
	origin: Vector3,
	direction: Vector3,
	result: HitResult,
	visual_recoil_kick: float,
	camera_impulse_strength: float
) -> void:
	attack_resolved.emit(
		origin,
		direction,
		result,
		visual_recoil_kick,
		camera_impulse_strength
	)
```

- [ ] **Step 6: 重接Player场景和玩家控制器**

在`scenes/player/Player.tscn`中删除固定`Weapon`、`Weapon/Muzzle`、`Weapon/Muzzle/MuzzleFlash`和`Weapon/ShotAudio`节点，同时删除旧`player_weapon.gd`、固定枪口火焰和固定枪声音效的外部资源声明，并重算`load_steps`；添加三个新外部资源并先配置手枪、步枪两个场景：

```text
[ext_resource type="Script" path="res://scripts/player/equipment_controller.gd" id="6_equipment"]
[ext_resource type="PackedScene" path="res://scenes/weapons/Pistol.tscn" id="7_pistol"]
[ext_resource type="PackedScene" path="res://scenes/weapons/Rifle.tscn" id="8_rifle"]

[node name="EquipmentController" type="Node" parent="."]
script = ExtResource("6_equipment")
loadout = Array[PackedScene]([ExtResource("7_pistol"), ExtResource("8_rifle")])
starting_slot = 1
```

在`PlayerController`中删除`HIDDEN_WEAPONS`、`signal shot_fired(...)`、固定`weapon: PlayerWeapon`、固定Rifle查找和`_on_weapon_shot_fired(...)`；新增：

```gdscript
signal attack_resolved(
	direction: Vector3,
	result: HitResult,
	camera_impulse_strength: float
)

@export var primary_attack_action: StringName = &"primary_attack"
@export var pistol_action: StringName = &"weapon_pistol"
@export var rifle_action: StringName = &"weapon_rifle"
@export var knife_action: StringName = &"weapon_knife"

@onready var equipment: EquipmentController = $EquipmentController
@onready var functional_ray_origin: Marker3D = $FunctionalRayOrigin

var attack_animation_remaining := 0.0
```

在`_ready()`完成动画查找后，先连接事件，再初始化loadout，确保默认步枪触发的首次`weapon_changed`不会丢失：

```gdscript
equipment.attack_started.connect(_on_weapon_attack_started)
equipment.attack_resolved.connect(_on_weapon_attack_resolved)
equipment.weapon_changed.connect(_on_weapon_changed)
equipment.setup(self, visual_root, functional_ray_origin)
```

删除玩家固定的`visual_recoil_kick`导出字段；保留`visual_recoil_recovery`，每次攻击的kick改为完全使用`_on_weapon_attack_resolved(...)`收到的`recoil_kick`。

在`_physics_process()`中，计算`aim_direction`后、注入攻击输入前加入：

```gdscript
if Input.is_action_just_pressed(pistol_action):
	equipment.equip_slot(0)
elif Input.is_action_just_pressed(rifle_action):
	equipment.equip_slot(1)
elif Input.is_action_just_pressed(knife_action):
	equipment.equip_slot(2)

var trigger_pressed := Input.is_action_pressed(primary_attack_action)
var trigger_just_pressed := Input.is_action_just_pressed(primary_attack_action)
equipment.set_attack_input(trigger_pressed, trigger_just_pressed, aim_direction)
```

删除原`fire_action`和`weapon.set_combat_input(...)`调用。把`_update_animation()`中的固定动画改为：

```gdscript
if animation_player == null or defeated:
	return
if hit_reaction_remaining > 0.0 or attack_animation_remaining > 0.0:
	return
var animation_name := equipment.get_idle_animation()
if not is_on_floor():
	animation_name = &"Jump_Idle"
elif horizontal_speed > 0.2:
	animation_name = equipment.get_run_animation()
if animation_player.current_animation != animation_name:
	animation_player.play(animation_name, 0.15)
```

在`_process(delta)`中同时递减攻击锁：

```gdscript
attack_animation_remaining = maxf(attack_animation_remaining - delta, 0.0)
```

加入通用事件处理：

```gdscript
func _on_weapon_attack_started(
	animation_name: StringName,
	lock_duration: float
) -> void:
	attack_animation_remaining = maxf(lock_duration, 0.0)
	if (
		animation_player != null and
		not animation_name.is_empty() and
		animation_player.has_animation(animation_name)
	):
		animation_player.play(animation_name, 0.05)

func _on_weapon_attack_resolved(
	_origin: Vector3,
	direction: Vector3,
	result: HitResult,
	recoil_kick: float,
	camera_impulse_strength: float
) -> void:
	visual_recoil_offset = minf(
		visual_recoil_offset + maxf(recoil_kick, 0.0),
		0.12
	)
	attack_resolved.emit(direction, result, camera_impulse_strength)

func _on_weapon_changed(_definition: WeaponDefinition) -> void:
	attack_animation_remaining = 0.0
	_update_animation(Vector2(velocity.x, velocity.z).length())
```

在受伤和死亡路径中都先调用：

```gdscript
equipment.cancel_attack()
attack_animation_remaining = 0.0
```

在死亡运动路径中用`equipment.set_attack_input(false, false, aim_direction)`替换固定武器调用；死亡时不再对单个武器调用`set_physics_process(false)`，而是调用`equipment.cancel_attack()`。

- [ ] **Step 7: 更新通用攻击接线、输入契约和现有枪械测试**

在`scripts/gameplay/demo_arena.gd`中把`player.shot_fired`改接`player.attack_resolved`，并把处理器改为：

```gdscript
func _on_player_attack(
	direction: Vector3,
	result: HitResult,
	camera_impulse_strength: float
) -> void:
	var follow_camera := get_node("FollowCamera") as FollowCamera
	follow_camera.add_shot_impulse(direction, camera_impulse_strength)
	if not result.did_hit:
		return
	var label := get_node("HUD/HitConfirm") as Label
	label.text = "KILL" if result.killed else (
		"CRITICAL" if result.critical else "HIT"
	)
	label.modulate = Color(1.0, 0.3, 0.22, 1.0) if result.critical else Color.WHITE
	if hit_confirm_tween != null and hit_confirm_tween.is_valid():
		hit_confirm_tween.kill()
	hit_confirm_tween = create_tween()
	hit_confirm_tween.tween_property(label, "modulate:a", 0.0, 0.18)
```

在`project.godot`中删除`fire`并加入以下动作：

```text
primary_attack={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":74,"physical_keycode":0,"key_label":0,"unicode":106,"location":0,"echo":false,"script":null)
]
}
weapon_pistol={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":49,"physical_keycode":0,"key_label":0,"unicode":49,"location":0,"echo":false,"script":null)
]
}
weapon_rifle={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":50,"physical_keycode":0,"key_label":0,"unicode":50,"location":0,"echo":false,"script":null)
]
}
weapon_knife={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":51,"physical_keycode":0,"key_label":0,"unicode":51,"location":0,"echo":false,"script":null)
]
}
```

在`tests/unit/test_project_contract.gd`中要求`primary_attack`、`weapon_pistol`、`weapon_rifle`、`weapon_knife`，键值分别为`KEY_J`、`KEY_1`、`KEY_2`、`KEY_3`，并移除`fire`契约。在`tests/unit/test_mobile_touch_controls.gd`中把测试按钮动作和释放列表中的`&"fire"`全部替换为`&"primary_attack"`。

把`test_weapon_feedback.gd`和`test_tracer_pool.gd`中的固定节点：

```gdscript
var weapon := player.get_node("Weapon") as PlayerWeapon
```

替换为：

```gdscript
var tree := Engine.get_main_loop() as SceneTree
tree.root.add_child(player)
var equipment := player.get_node("EquipmentController") as EquipmentController
var weapon := equipment.get_current_weapon() as RangedWeapon
```

这两个测试必须先把`player`加入SceneTree，再读取`equipment.get_current_weapon()`；删除原测试中后置的重复`tree.root.add_child(player)`。`test_weapon_feedback.gd`继续验证`Muzzle/MuzzleFlash`、`ShotAudio`、视觉枪口跟随、功能射线稳定和镜头脉冲上限；`test_tracer_pool.gd`继续验证当前默认步枪预热8个弹道并循环复用。`tests/integration/test_demo_scene.gd`暂时把固定`Player/Weapon`断言替换为`Player/EquipmentController`和默认`rifle`断言；Task 3再把loadout数量扩为3。

- [ ] **Step 8: 运行远程武器GREEN与边界检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit-after 3
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
rg -n "PlayerWeapon|player_weapon.gd|Player/Weapon|fire_action|&\"fire\"" scripts scenes tests project.godot
rg -n "Input\." scripts/combat scripts/player/equipment_controller.gd
git diff --check
```

Expected:

```text
Godot资源导入与脚本解析正常
test_weapon_loadout.gd及既有枪械反馈/弹道测试通过
旧PlayerWeapon、固定Player/Weapon和fire动作搜索无输出
武器与装备控制器没有任何Input调用
git diff --check无输出
```

---

### Task 3: 实现刀近战、命中窗口与攻击动画锁

**Files:**
- Create: `scripts/combat/weapons/melee_weapon.gd`
- Create: `scenes/weapons/Knife.tscn`
- Create: `tests/unit/test_player_melee_weapon.gd`
- Modify: `scenes/player/Player.tscn`
- Modify: `scripts/player/player_controller.gd`
- Modify: `tests/unit/test_weapon_loadout.gd`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: `MeleeWeaponDefinition`、`WeaponTrigger`、`WeaponBase.attack_started`、`WeaponBase.attack_resolved`。
- Produces: `MeleeWeapon`，在`impact_delay`到达时调用一次`_resolve_melee_hit() -> HitResult`。
- Preserves: `ZombieTarget.apply_hit(amount, hit_position, direction, ...) -> HitResult`默认参数路径，刀不产生暴击区倍率。
- Preserves: 玩家动画优先级`Death > HitReact > Attack > Jump > Run > Idle`。

- [ ] **Step 1: 写刀的前摇、前方单目标命中和中断失败测试**

创建`tests/unit/test_player_melee_weapon.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const TARGET_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const MeleeWeapon = preload("res://scripts/combat/weapons/melee_weapon.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var host := Node3D.new()
	var player := PLAYER_SCENE.instantiate() as PlayerController
	var front_target := TARGET_SCENE.instantiate() as ZombieTarget
	var rear_target := TARGET_SCENE.instantiate() as ZombieTarget
	tree.root.add_child(host)
	host.add_child(player)
	host.add_child(front_target)
	host.add_child(rear_target)
	player.global_position = Vector3.ZERO
	front_target.global_position = Vector3(0.0, 0.0, -0.9)
	rear_target.global_position = Vector3(0.0, 0.0, 0.9)

	var equipment := player.get_node("EquipmentController") as EquipmentController
	_append(failures, Assertions.expect_true(
		equipment.equip_slot(2), "Knife slot can be equipped"
	))
	var knife := equipment.get_current_weapon() as MeleeWeapon
	_append(failures, Assertions.expect_true(knife != null, "Knife uses melee runtime"))
	if knife == null:
		host.free()
		return failures
	knife.set_physics_process(false)

	equipment.set_attack_input(true, true, Vector3.FORWARD)
	knife._physics_process(0.0)
	_append(failures, Assertions.expect_float_near(
		front_target.health.current,
		50.0,
		0.0001,
		"Knife press starts animation without immediate damage"
	))
	_append(failures, Assertions.expect_true(
		player.attack_animation_remaining > 0.0,
		"Knife attack locks locomotion animation"
	))
	_append(failures, Assertions.expect_equal(
		player.animation_player.current_animation,
		&"Slash",
		"Knife plays Slash animation"
	))

	knife._physics_process(0.21)
	_append(failures, Assertions.expect_float_near(
		front_target.health.current,
		50.0,
		0.0001,
		"Knife does not damage before impact time"
	))
	knife._physics_process(0.01)
	_append(failures, Assertions.expect_float_near(
		front_target.health.current,
		15.0,
		0.0001,
		"Knife damages the closest forward target once"
	))
	_append(failures, Assertions.expect_float_near(
		rear_target.health.current,
		50.0,
		0.0001,
		"Knife does not damage a target behind the player"
	))
	knife._physics_process(0.20)
	_append(failures, Assertions.expect_float_near(
		front_target.health.current,
		15.0,
		0.0001,
		"Knife attack cannot damage the same target twice"
	))

	knife.cancel_attack()
	_append(failures, Assertions.expect_true(
		not knife.attack_pending,
		"Cancelling knife clears pending impact"
	))
	host.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在`tests/test_runner.gd`中加入：

```gdscript
	"res://tests/unit/test_player_melee_weapon.gd",
```

运行全套测试。Expected: FAIL，因为`MeleeWeapon`、`Knife.tscn`和loadout槽位2尚不存在。

- [ ] **Step 2: 创建刀的MeleeWeapon实现**

创建`scripts/combat/weapons/melee_weapon.gd`：

```gdscript
extends WeaponBase
class_name MeleeWeapon

const HitResult = preload("res://scripts/combat/hit_result.gd")
const WeaponTrigger = preload("res://scripts/combat/weapons/weapon_trigger.gd")

var weapon_trigger: WeaponTrigger
var attack_pending := false
var attack_elapsed := 0.0
var impact_resolved := false

func _ready() -> void:
	var melee_definition := definition as MeleeWeaponDefinition
	weapon_trigger = WeaponTrigger.new(
		melee_definition.trigger_mode,
		melee_definition.attacks_per_second
	)

func _physics_process(delta: float) -> void:
	weapon_trigger.tick(delta)
	if (
		not attack_pending and
		weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed)
	):
		_start_attack()
	trigger_just_pressed = false
	if not attack_pending:
		return
	attack_elapsed += maxf(delta, 0.0)
	var melee_definition := definition as MeleeWeaponDefinition
	if not impact_resolved and attack_elapsed >= melee_definition.impact_delay:
		impact_resolved = true
		var result := _resolve_melee_hit()
		var impact_origin := (
			wielder.global_transform * Transform3D(
				Basis.IDENTITY,
				melee_definition.hitbox_offset
			)
		).origin
		attack_resolved.emit(
			impact_origin,
			aim_direction,
			result,
			melee_definition.visual_recoil_kick,
			melee_definition.camera_impulse_strength
		)
	if attack_elapsed >= melee_definition.attack_lock_duration:
		attack_pending = false

func set_equipped(value: bool) -> void:
	super.set_equipped(value)
	if not value:
		cancel_attack()

func cancel_attack() -> void:
	super.cancel_attack()
	attack_pending = false
	attack_elapsed = 0.0
	impact_resolved = false
	if weapon_trigger != null:
		weapon_trigger.reset()

func _start_attack() -> void:
	var melee_definition := definition as MeleeWeaponDefinition
	attack_pending = true
	attack_elapsed = 0.0
	impact_resolved = false
	attack_started.emit(
		melee_definition.attack_animation,
		melee_definition.attack_lock_duration
	)

func _resolve_melee_hit() -> HitResult:
	var melee_definition := definition as MeleeWeaponDefinition
	var shape := BoxShape3D.new()
	shape.size = melee_definition.hitbox_size
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = wielder.global_transform * Transform3D(
		Basis.IDENTITY,
		melee_definition.hitbox_offset
	)
	query.collision_mask = melee_definition.hit_collision_mask
	query.collide_with_areas = true
	query.collide_with_bodies = false
	query.exclude = [wielder.get_rid()]
	var intersections := get_world_3d().direct_space_state.intersect_shape(query, 16)
	var closest_target: Node3D
	var closest_distance := INF
	var visited: Dictionary = {}
	for intersection in intersections:
		var collider: Object = intersection.get("collider")
		var target := _find_damage_target(collider)
		if target == null:
			continue
		var target_id := target.get_instance_id()
		if visited.has(target_id):
			continue
		visited[target_id] = true
		var distance := wielder.global_position.distance_squared_to(
			target.global_position
		)
		if distance < closest_distance:
			closest_distance = distance
			closest_target = target
	var miss_position := query.transform.origin
	if closest_target == null:
		return HitResult.miss(miss_position)
	var hit_position := closest_target.global_position + Vector3.UP
	if closest_target.has_method("get_aim_point"):
		hit_position = closest_target.call("get_aim_point")
	var resolved: Variant = closest_target.call(
		"apply_hit",
		melee_definition.damage,
		hit_position,
		aim_direction
	)
	return resolved as HitResult if resolved is HitResult else HitResult.miss(hit_position)

func _find_damage_target(collider: Object) -> Node3D:
	var current := collider as Node
	while current != null:
		if current is Node3D and current.is_in_group(&"damageable_targets"):
			return current as Node3D
		current = current.get_parent()
	return null
```

- [ ] **Step 3: 创建Knife场景并加入玩家loadout**

创建`scenes/weapons/Knife.tscn`：

```text
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/combat/weapons/melee_weapon.gd" id="1_weapon"]
[ext_resource type="Resource" path="res://resources/weapons/knife.tres" id="2_definition"]

[node name="Knife" type="Node3D"]
script = ExtResource("1_weapon")
definition = ExtResource("2_definition")
```

在`scenes/player/Player.tscn`加入：

```text
[ext_resource type="PackedScene" path="res://scenes/weapons/Knife.tscn" id="9_knife"]
```

把`EquipmentController.loadout`改为：

```text
loadout = Array[PackedScene]([ExtResource("7_pistol"), ExtResource("8_rifle"), ExtResource("9_knife")])
starting_slot = 1
```

Task 2的`EquipmentController.setup()`已经在实例化loadout前隐藏角色GLTF内全部武器视觉；加入Knife后保持该逻辑不变，随后`equip_slot(starting_slot)`仍只显示默认Rifle。

- [ ] **Step 4: 保证攻击动画优先级和受伤/死亡中断**

确认`PlayerController._update_animation()`的早退顺序严格为：

```gdscript
if animation_player == null or defeated:
	return
if hit_reaction_remaining > 0.0:
	return
if attack_animation_remaining > 0.0:
	return
```

在`apply_damage()`成功扣血后、播放`HitReact`前执行：

```gdscript
equipment.cancel_attack()
attack_animation_remaining = 0.0
```

在`_on_depleted()`中同样执行取消，并保留`Death`最高优先级。切换武器时`EquipmentController.equip_slot()`已通过`set_equipped(false)`取消上一把武器的待结算挥砍，因此切走刀后不得产生延迟命中。

在`tests/unit/test_weapon_loadout.gd`把loadout数量从2改为3，并补充：

```gdscript
_append(failures, Assertions.expect_true(
	equipment.equip_slot(2), "Knife slot can be equipped"
))
_append(failures, Assertions.expect_equal(
	equipment.get_current_definition().weapon_id,
	&"knife",
	"Third slot selects the knife"
))
_append(failures, Assertions.expect_equal(
	equipment.get_run_animation(),
	&"Run_Slash",
	"Knife exposes slash locomotion animation"
))
```

- [ ] **Step 5: 运行近战GREEN和物理查询回归**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit-after 3
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
rg -n "Slash|Run_Slash|attack_animation_remaining|cancel_attack" scripts tests resources/weapons
git diff --check
```

Expected:

```text
test_player_melee_weapon.gd通过
前方目标在0.22秒时只受到一次35伤害，后方目标不受伤
刀的Slash动画在0.55秒攻击锁内不被Idle/Run覆盖
受伤、死亡、切武器均会取消尚未命中的挥砍
全部既有射击、僵尸攻击、血迹、菜单和移动端输入测试继续通过
```

---

### Task 4: 完成demo契约、操作说明与全量验收

**Files:**
- Modify: `scenes/gameplay/DemoArena.tscn:235-250`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `tests/unit/test_project_contract.gd`
- Modify: `tests/unit/test_mobile_touch_controls.gd`
- Modify: `README.md:1-45`
- Verify: `scripts/player/player_controller.gd`
- Verify: `scripts/player/equipment_controller.gd`
- Verify: `scripts/combat/weapons/*.gd`
- Verify: `resources/weapons/*.tres`
- Verify: `scenes/weapons/*.tscn`

**Interfaces:**
- Consumes: 完成后的三武器loadout和`PlayerController.attack_resolved(...)`。
- Produces: 最终键位契约、demo HUD说明、README说明和可重复的桌面验收矩阵。
- Preserves: 当前主菜单、四只僵尸、难度配置、玩家生命、命中反馈和游戏结束流程。

- [ ] **Step 1: 收紧demo集成测试到最终三武器契约**

在`tests/integration/test_demo_scene.gd`顶部加入：

```gdscript
const RangedWeapon = preload("res://scripts/combat/weapons/ranged_weapon.gd")
const MeleeWeapon = preload("res://scripts/combat/weapons/melee_weapon.gd")
```

在`run()`中取得：

```gdscript
var equipment := arena.get_node_or_null(
	"Player/EquipmentController"
) as EquipmentController
```

删除旧`Player/Weapon`和固定`weapon.max_range`断言，加入：

```gdscript
_append(failures, Assertions.expect_true(
	equipment != null,
	"Demo player owns the modular equipment controller"
))
if equipment != null:
	_append(failures, Assertions.expect_equal(
		equipment.weapons.size(),
		3,
		"Demo loadout contains pistol rifle and knife"
	))
	_append(failures, Assertions.expect_equal(
		equipment.get_current_definition().weapon_id,
		&"rifle",
		"Demo starts with the rifle equipped"
	))
	_append(failures, Assertions.expect_true(
		equipment.weapons[0] is RangedWeapon and
		equipment.weapons[1] is RangedWeapon and
		equipment.weapons[2] is MeleeWeapon,
		"Demo loadout uses two ranged runtimes and one melee runtime"
	))
```

把控制说明断言改为精确文本：

```gdscript
_append(failures, Assertions.expect_equal(
	controls.text,
	"WASD MOVE + FACE   SPACE JUMP   J ATTACK   1 PISTOL   2 RIFLE   3 KNIFE",
	"HUD documents attack and weapon switching controls"
))
```

运行测试确认当前HUD文本仍导致该断言FAIL。

- [ ] **Step 2: 更新HUD和README**

在`scenes/gameplay/DemoArena.tscn`扩大`ControlsPanel`右边界以容纳文本，并设置：

```text
offset_right = 760.0
text = "WASD MOVE + FACE   SPACE JUMP   J ATTACK   1 PISTOL   2 RIFLE   3 KNIFE"
```

在`README.md`的`## Controls`使用以下内容替换单步枪说明：

```markdown
- `W/A/S/D`: camera-relative movement, facing, and attack direction
- `Space`: grounded jump
- `J`: use the current weapon's primary attack
- `1`: equip the semi-automatic pistol
- `2`: equip the automatic rifle
- `3`: equip the melee knife

- 手枪每次按下J只发射一枪，持续按住不会自动补发。
- 步枪按住J以每秒6发持续射击。
- 刀每次按下J播放一次Slash，在0.22秒命中窗口攻击前方最近的一只僵尸。
- 切换武器会立即更换模型、移动动画和攻击方式，并取消上一把武器未完成的攻击。
```

在`## Demo scope`补充精确范围：首版没有弹药、换弹、背包、拾取、掉落、武器升级和移动端武器切换按钮；移动端攻击按钮使用当前装备武器。

- [ ] **Step 3: 运行全量自动验证与静态边界检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit-after 3
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
rg -n "PlayerWeapon|player_weapon.gd|Player/Weapon|fire_action|&\"fire\"|J  FIRE" . \
  -g '!docs/superpowers/plans/*.md' \
  -g '!docs/superpowers/specs/*.md'
rg -n "Input\." scripts/combat scripts/player/equipment_controller.gd
rg -n "Pistol|Rifle|Knife|primary_attack|weapon_pistol|weapon_rifle|weapon_knife" \
  scripts scenes resources tests project.godot README.md
git diff --check
git status --short
```

Expected:

```text
Godot编辑器导入/解析以0退出
若没有并行新增测试，运行器输出PASS: 27 test file(s)；若实际注册数变化，则所有已注册测试必须PASS
旧PlayerWeapon、固定Player/Weapon、fire动作和旧HUD文本搜索无输出
武器和EquipmentController没有Input调用
三把武器、四个新输入动作在代码、场景、资源、测试和README中均有对应引用
git diff --check无输出
git status只显示本计划文件和用户已有/本计划产生的预期改动，不出现临时导出文件
```

- [ ] **Step 4: 进行桌面操作验收**

Launch:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

按以下矩阵逐项验收：

| 场景 | 操作 | 预期结果 |
| --- | --- | --- |
| 默认装备 | 从主菜单开始游戏，不按数字键 | 玩家持步枪，使用`Idle_Gun/Run_Gun`，HUD显示1/2/3切换说明 |
| 手枪单发 | 按1，按住J至少1秒 | 只在J按下瞬间发射一枪；松开后再次按下才可再开枪 |
| 手枪节奏 | 连续快速点按J | 射速最多3发/秒；冷却末尾80毫秒内的短按会在冷却结束后补发一次 |
| 步枪连发 | 按2并持续按住J | 以6发/秒持续射击，保留枪口火焰、弹道、枪声、后坐和辅助命中 |
| 刀视觉 | 按3 | Rifle隐藏、Knife显示，待机切`Idle`，移动切`Run_Slash` |
| 刀命中窗口 | 靠近僵尸后点按J | 立即播放`Slash`，按键瞬间不掉血，约0.22秒时前方最近目标受到35伤害 |
| 刀范围 | 让一只僵尸在前方、一只在身后并挥砍 | 只命中前方最近的一只；同一次Slash不会重复扣血 |
| 攻击中切换 | 刀刚开始Slash、尚未到0.22秒时按1或2 | 挥砍被取消，不产生延迟伤害，新武器立即显示并可攻击 |
| 受伤中断 | 刀刚开始Slash时让僵尸击中玩家 | `HitReact`覆盖Slash，待结算刀伤被取消 |
| 死亡中断 | 挥刀过程中受到致命伤害 | `Death`最高优先级，玩家不能继续攻击或切出延迟命中 |
| 朝向一致 | 分别装备三把武器并用WASD改变方向 | 移动、角色朝向、枪线或刀的前方盒形范围始终使用同一个`aim_direction` |
| 命中反馈 | 用手枪、步枪、刀分别命中和击杀 | HIT/KILL、镜头脉冲、击退、血花和地面血迹继续工作；刀默认躯干命中不产生CRITICAL |
| 移动端回归 | 使用现有触摸测试或H5触摸攻击按钮 | 按钮驱动`primary_attack`且没有遗留`fire`动作；首版保持当前装备，不提供触摸切换 |

- [ ] **Step 5: 执行完成前核对变更范围**

Run:

```bash
git diff --name-status
git diff --stat
```

Expected: 变更只涉及本计划列出的玩家、武器、输入、demo接线、测试和README文件，以及Godot自动生成的对应`.uid`/`.import`元数据；不得暂存或提交。把最终测试结果、手动验收结果和仍存在的非本计划工作区修改一起报告给用户，由用户决定何时提交。
