# 冲锋枪迁移与散弹枪 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将现有步枪完整迁移为冲锋枪，并新增通过武器箱获取、每轮发射三条固定夹角弹道的有限弹药散弹枪。

**Architecture:** 继续复用 `RangedWeapon` 的 hitscan、弹药、反馈和墙体净空链路；新增纯计算 `WeaponVolleyMath`，由通用远程武器在一次中央散布解析后生成对称多弹丸方向。冲锋枪与散弹枪都使用数据资源驱动，不创建散弹枪专用攻击脚本。

**Tech Stack:** Godot 4.7.1、GDScript、Godot Resource、PhysicsRayQueryParameters3D、现有独立 headless 验证脚本、Godot headless editor。

## Global Constraints

- 计划与实现说明使用中文。
- 现有步枪完整迁移为 `smg`，不保留旧 `rifle` 运行时入口。
- 冲锋枪保留每秒 `4` 发、单发 `25` 伤害、弹药上限 `360` 及现有散布/反馈数值。
- 散弹枪每轮方向固定为 `-6° / 0° / +6°`，不叠加随机散布。
- 散弹枪按住连续射击，每轮间隔 `0.8s`，每颗 `25` 伤害，射程 `18m`。
- 散弹枪每轮三颗弹丸只消耗 `1` 发，弹药上限 `120`。
- 散弹武器箱授予 `24` 发并自动装备；散弹弹药箱补充 `36` 发。
- 每条弹道独立命中且只伤害第一个目标；同一目标允许吃到同轮多颗伤害。
- 每颗弹丸独立曳光；枪口、音效、后坐、镜头和 `attack_resolved` 每轮只触发一次。
- 新运行时战斗 VFX 若使用网格、Shader、GPU 粒子或首次动画，必须放在 `scenes/fx/` 并实现 render warmup；本计划复用现有 `ShotTracer` 与 `MuzzleFlash`，不新增 VFX 场景。
- 不修改 `addons/`，不提交 `build/` 或 `.godot/`。
- 各 Task 可保留临时 Conventional Commit；全部 Task 与最终评审完成后，合并前 squash 为一个计划 Commit：`feat: add smg and shotgun weapon flow`。

## 文件结构

- `scripts/combat/weapons/weapon_volley_math.gd`：纯函数生成对称的多弹丸方向。
- `scripts/combat/weapons/ranged_weapon_definition.gd`：声明每轮弹丸数和相邻弹道夹角。
- `scripts/combat/weapons/ranged_weapon.gd`：一轮内解析多条射线并汇总反馈。
- `resources/weapons/smg.tres`、`scenes/weapons/Smg.tscn`：迁移后的冲锋枪定义与场景。
- `resources/weapons/shotgun.tres`、`scenes/weapons/Shotgun.tscn`：新散弹枪定义与场景。
- `resources/pickups/smg_*.tres`、`resources/pickups/shotgun_*.tres`：两类武器和弹药拾取定义。
- `scenes/player/Player.tscn`：五项装备顺序与新场景引用。
- `scenes/gameplay/DemoArena.tscn`：五个固定拾取点和五项随机掉落池。
- `tools/validation/validate_ranged_weapon_volley.gd`：多弹丸数学与武器资源契约。
- 现有 `tools/validation/validate_*`：迁移稳定 ID、装备、拾取、Demo 和预览断言。
- `README.md`：操作、武器名称和 Demo 能力说明。

---

### Task 1: 通用多弹丸弹道

**Files:**
- Create: `scripts/combat/weapons/weapon_volley_math.gd`
- Create: `tools/validation/validate_ranged_weapon_volley.gd`
- Modify: `scripts/combat/weapons/ranged_weapon_definition.gd`
- Modify: `scripts/combat/weapons/ranged_weapon.gd`

**Interfaces:**
- Consumes: `WeaponMath.flat_direction(direction: Vector3) -> Vector3`、`WeaponSpreadState.resolve_shot_direction(direction: Vector3, random_sample: float) -> Vector3`、现有 `_resolve_shot(from, to, shot_direction) -> Dictionary`。
- Produces: `WeaponVolleyMath.build_directions(center_direction: Vector3, projectile_count: int, projectile_angle_degrees: float) -> Array[Vector3]`；`RangedWeaponDefinition.projectiles_per_shot: int`；`RangedWeaponDefinition.projectile_angle_degrees: float`。

- [ ] **Step 1: 写多弹丸数学的失败验证**

创建 `tools/validation/validate_ranged_weapon_volley.gd`，先只验证尚不存在的纯计算接口：

```gdscript
extends SceneTree

const WeaponVolleyMath = preload(
	"res://scripts/combat/weapons/weapon_volley_math.gd"
)
const RangedWeaponDefinition = preload(
	"res://scripts/combat/weapons/ranged_weapon_definition.gd"
)

func _init() -> void:
	var failures: Array[String] = []
	var single := WeaponVolleyMath.build_directions(Vector3.FORWARD, 1, 6.0)
	_expect(single.size() == 1, "single projectile must produce one direction", failures)
	_expect(single[0].is_equal_approx(Vector3.FORWARD), "single projectile must preserve center", failures)

	var volley := WeaponVolleyMath.build_directions(Vector3.FORWARD, 3, 6.0)
	_expect(volley.size() == 3, "shotgun must produce three directions", failures)
	var expected_angles := [-6.0, 0.0, 6.0]
	for index in range(3):
		_expect(is_equal_approx(volley[index].length(), 1.0), "direction must be normalized", failures)
		_expect(is_zero_approx(volley[index].y), "direction must remain horizontal", failures)
		var signed_angle := rad_to_deg(Vector3.FORWARD.signed_angle_to(volley[index], Vector3.UP))
		_expect(is_equal_approx(signed_angle, expected_angles[index]), "direction angle must match contract", failures)

	_finish(failures)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_ranged_weapon_volley: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
```

- [ ] **Step 2: 运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_ranged_weapon_volley.gd
```

Expected: FAIL，报错指出 `res://scripts/combat/weapons/weapon_volley_math.gd` 不存在或无法 preload；失败原因只能是多弹丸接口尚未实现。

- [ ] **Step 3: 实现最小纯计算单元**

创建 `scripts/combat/weapons/weapon_volley_math.gd`：

```gdscript
extends RefCounted
class_name WeaponVolleyMath

const WeaponMath = preload("res://scripts/combat/weapon_math.gd")

static func build_directions(
	center_direction: Vector3,
	projectile_count: int,
	projectile_angle_degrees: float
) -> Array[Vector3]:
	var directions: Array[Vector3] = []
	var safe_count := maxi(projectile_count, 1)
	var center := WeaponMath.flat_direction(center_direction)
	var center_index := float(safe_count - 1) * 0.5
	for projectile_index in range(safe_count):
		var offset_degrees := (
			float(projectile_index) - center_index
		) * maxf(projectile_angle_degrees, 0.0)
		directions.append(
			WeaponMath.flat_direction(
				center.rotated(Vector3.UP, deg_to_rad(offset_degrees))
			)
		)
	return directions
```

- [ ] **Step 4: 运行验证并确认 GREEN**

运行 Step 2 的同一命令。Expected: `validate_ranged_weapon_volley: PASS`。

- [ ] **Step 5: 扩展失败验证以固定资源字段契约**

在验证脚本中 preload `RangedWeaponDefinition`，新增：

```gdscript
var definition := RangedWeaponDefinition.new()
_expect(definition.projectiles_per_shot == 1, "ranged weapon default must remain single projectile", failures)
_expect(is_zero_approx(definition.projectile_angle_degrees), "single projectile default angle must be zero", failures)
```

- [ ] **Step 6: 运行验证并确认第二次 RED**

运行 Step 2 命令。Expected: FAIL，指出 `projectiles_per_shot` 或 `projectile_angle_degrees` 不存在。

- [ ] **Step 7: 添加通用远程武器配置字段**

在 `ranged_weapon_definition.gd` 的弹道配置区新增：

```gdscript
@export_group("Projectile Volley")
@export_range(1, 9, 1) var projectiles_per_shot := 1
@export_range(0.0, 30.0, 0.5) var projectile_angle_degrees := 0.0
```

- [ ] **Step 8: 运行验证并确认字段 GREEN**

运行 Step 2 命令。Expected: PASS。

- [ ] **Step 9: 将 `_fire()` 改为单次反馈、多条独立射线**

在 `ranged_weapon.gd` preload `WeaponVolleyMath`。保留一次中央散布解析，然后循环三类通用弹道：

```gdscript
var center_direction := spread_state.resolve_shot_direction(
	shot_direction,
	spread_rng.randf_range(-1.0, 1.0)
)
var projectile_directions := WeaponVolleyMath.build_directions(
	center_direction,
	ranged_definition.projectiles_per_shot,
	ranged_definition.projectile_angle_degrees
)
var summary := HitResult.miss(
	WeaponMath.ray_end_from_direction(
		ray_origin,
		center_direction,
		ranged_definition.attack_range
	)
)

for projectile_direction in projectile_directions:
	var ray_end := WeaponMath.ray_end_from_direction(
		ray_origin,
		projectile_direction,
		ranged_definition.attack_range
	)
	var resolution := _resolve_shot(ray_origin, ray_end, projectile_direction)
	var hit_position: Vector3 = resolution["end_position"]
	var hit_result: HitResult = resolution["hit_result"]
	var tracer := _acquire_tracer()
	tracer.setup(ray_origin, hit_position)
	_merge_hit_result(summary, hit_result)

muzzle_flash.flash()
shot_audio.pitch_scale = randf_range(0.97, 1.03)
shot_audio.play()
attack_resolved.emit(
	ray_origin,
	center_direction,
	summary,
	ranged_definition.visual_recoil_kick,
	ranged_definition.camera_impulse_strength
)
```

删除旧 `_fire()` 中只解析一条射线、只申请一条 tracer 的局部变量。不要把弹药扣除移动到循环内；现有 `_physics_process()` 在调用 `_fire()` 前只调用一次 `try_consume_ammo()`。

- [ ] **Step 10: 运行多弹丸验证和导入检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_ranged_weapon_volley.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 验证 PASS，Godot exit `0`，无脚本解析错误。

- [ ] **Step 11: 提交 Task 1**

```bash
git add scripts/combat/weapons/weapon_volley_math.gd scripts/combat/weapons/ranged_weapon_definition.gd scripts/combat/weapons/ranged_weapon.gd tools/validation/validate_ranged_weapon_volley.gd
git commit -m "feat: support ranged weapon projectile volleys"
```

---

### Task 2: 步枪完整迁移为冲锋枪

**Files:**
- Rename: `resources/weapons/rifle.tres` -> `resources/weapons/smg.tres`
- Rename: `scenes/weapons/Rifle.tscn` -> `scenes/weapons/Smg.tscn`
- Rename: `resources/pickups/rifle_pickup.tres` -> `resources/pickups/smg_pickup.tres`
- Rename: `resources/pickups/rifle_ammo_pickup.tres` -> `resources/pickups/smg_ammo_pickup.tres`
- Modify: `scenes/player/Player.tscn`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `scripts/menu/lobby_player_preview.gd`
- Modify: `tools/validation/validate_equipment_cycle.gd`
- Modify: `tools/validation/validate_pickup_spawn_point.gd`
- Modify: `tools/validation/validate_pickup_definitions.gd`
- Modify: `tools/validation/validate_random_pickup_drops.gd`
- Modify: `tools/validation/validate_lobby_player_preview.gd`
- Modify: `tools/validation/validate_local_player_spawning.gd`
- Modify: `tools/validation/validate_single_player_input_wiring.gd`
- Modify: `tools/validation/validate_local_disconnect_contract.gd`

**Interfaces:**
- Consumes: 现有 `EquipmentController.get_item_by_id(item_id)`、`grant_item(item_id, amount, auto_equip)` 和角色模型节点 `SMG`。
- Produces: 稳定 ID `&"smg"`、显示名 `冲锋枪`、场景 `res://scenes/weapons/Smg.tscn`、拾取资源 `smg_pickup.tres` 与 `smg_ammo_pickup.tres`。

- [ ] **Step 1: 先把现有验证期望改为冲锋枪，形成 RED**

在相关验证中执行语义替换，示例核心断言：

```gdscript
var smg = controller.call("get_item_by_id", &"smg")
_expect(smg != null, "smg must retain a stable equipment item id", failures)
_expect(not smg.is_available(), "smg must start unowned", failures)
_expect(int(controller.call("add_ammo", &"smg", 30)) == 0, "unowned smg must reject ammo pickups", failures)
_expect(bool(controller.call("grant_item", &"smg", 400, true)), "smg pickup must grant ownership or ammo", failures)
_expect(smg.get_ammo_count() == 360, "smg ammo must cap at 360", failures)
```

`validate_lobby_player_preview.gd` 改为查找 `SMG`；`validate_local_player_spawning.gd` 和 `validate_single_player_input_wiring.gd` 中过时的 `RIFLE` 初始装备期望改为实际默认的 `手枪`，并保持“下一个可用装备跳过未拥有冲锋枪后到达匕首”的断言；`validate_local_disconnect_contract.gd` 改为 preload `Smg.tscn`。`validate_pickup_definitions.gd` 的通用示例 ID 从 `rifle` 改为 `smg`，并同步期望字典。

- [ ] **Step 2: 运行迁移相关验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_lobby_player_preview.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_single_player_input_wiring.gd
```

Expected: FAIL，因为运行时仍只有 `rifle`、`Rifle` 模型绑定和旧显示名。

- [ ] **Step 3: 重命名四个资源文件**

使用 `apply_patch` 新增四个目标文件并删除四个旧文件；目标内容由 Step 4 与 Step 5 给出的完整字段组成。不要使用 shell 写文件。场景与资源的现有 `.uid` 引用若由 Godot 导入生成，则在 Step 7 的 headless editor 导入后保留对应更新。

- [ ] **Step 4: 更新冲锋枪武器资源与场景**

`resources/weapons/smg.tres` 使用原步枪 UID 和全部原数值，只改身份字段，完整内容为：

```ini
[gd_resource type="Resource" script_class="RangedWeaponDefinition" format=3 uid="uid://bnb1jtawikelh"]

[ext_resource type="Script" uid="uid://brtfga3pmigpt" path="res://scripts/combat/weapons/ranged_weapon_definition.gd" id="1_definition"]

[resource]
script = ExtResource("1_definition")
uses_ammo = true
max_ammo = 360
weapon_id = &"smg"
display_name = "冲锋枪"
visual_node_name = &"SMG"
trigger_mode = 1
attacks_per_second = 4.0
damage = 25.0
idle_animation = &"Idle_Gun"
run_animation = &"Run_Gun"
visual_recoil_kick = 0.08
camera_impulse_strength = 0.06
```

`scenes/weapons/Smg.tscn` 完整内容为：

```ini
[gd_scene load_steps=5 format=3]

[ext_resource type="Script" path="res://scripts/combat/weapons/ranged_weapon.gd" id="1_weapon"]
[ext_resource type="Resource" path="res://resources/weapons/smg.tres" id="2_definition"]
[ext_resource type="PackedScene" path="res://scenes/fx/MuzzleFlash.tscn" id="3_muzzle_flash"]
[ext_resource type="AudioStream" path="res://assets/sfx/weapons/impactMetal_heavy_002.ogg" id="4_shot_audio"]

[node name="Smg" type="Node3D"]
script = ExtResource("1_weapon")
definition = ExtResource("2_definition")
initially_owned = false

[node name="Muzzle" type="Marker3D" parent="."]

[node name="MuzzleFlash" parent="Muzzle" instance=ExtResource("3_muzzle_flash")]

[node name="ShotAudio" type="AudioStreamPlayer3D" parent="."]
stream = ExtResource("4_shot_audio")
volume_db = -8.0
unit_size = 6.0
max_distance = 32.0
```

- [ ] **Step 5: 更新冲锋枪拾取定义**

`smg_pickup.tres` 完整内容：

```ini
[gd_resource type="Resource" script_class="PickupDefinition" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/pickup_definition.gd" id="1_pickup_definition"]

[resource]
script = ExtResource("1_pickup_definition")
reward_mode = 0
item_id = &"smg"
amount = 60
auto_equip = true
display_name = "冲锋枪"
marker_color = Color(1, 0.45, 0.08, 1)
```

`smg_ammo_pickup.tres` 完整内容：

```ini
[gd_resource type="Resource" script_class="PickupDefinition" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/pickup_definition.gd" id="1_pickup_definition"]

[resource]
script = ExtResource("1_pickup_definition")
reward_mode = 1
item_id = &"smg"
amount = 90
auto_equip = false
display_name = "冲锋枪弹药"
marker_color = Color(0.2, 0.55, 1, 1)
```

- [ ] **Step 6: 更新玩家、Demo、预览与全部运行时引用**

将 Player 的 ext_resource 改为 `Smg.tscn`，将 Demo 的两个旧拾取资源和节点名改为 `Smg` / `SmgAmmo`。`scripts/menu/lobby_player_preview.gd` 默认显示节点改为 `SMG`。执行只读残留检查：

```bash
rg -n 'rifle|Rifle|步枪' scripts scenes resources tools README.md project.godot
```

Expected: 此时允许 README 尚未修改；`scripts/`、`scenes/`、`resources/`、`tools/` 与 `project.godot` 不应再出现旧步枪运行时引用。

- [ ] **Step 7: 运行迁移验证并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_lobby_player_preview.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_player_spawning.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_single_player_input_wiring.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_disconnect_contract.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 全部 PASS，导入 exit `0`。

- [ ] **Step 8: 提交 Task 2**

```bash
git add resources/weapons resources/pickups scenes/weapons scenes/player/Player.tscn scenes/gameplay/DemoArena.tscn scripts/menu/lobby_player_preview.gd tools/validation
git commit -m "refactor: migrate rifle to smg"
```

---

### Task 3: 新增散弹枪装备与数值契约

**Files:**
- Create: `resources/weapons/shotgun.tres`
- Create: `scenes/weapons/Shotgun.tscn`
- Modify: `scenes/player/Player.tscn`
- Modify: `tools/validation/validate_ranged_weapon_volley.gd`
- Modify: `tools/validation/validate_equipment_cycle.gd`
- Modify: `tools/validation/validate_single_player_input_wiring.gd`
- Modify: `tools/validation/validate_local_disconnect_contract.gd`

**Interfaces:**
- Consumes: Task 1 的 `projectiles_per_shot` / `projectile_angle_degrees`，Task 2 完成后的手枪、冲锋枪、匕首、油桶四项装备基础。
- Produces: `weapon_id = &"shotgun"`、`res://scenes/weapons/Shotgun.tscn`，玩家 loadout 顺序 `[pistol, smg, shotgun, knife, oil_barrel]`。

- [ ] **Step 1: 在验证中先声明散弹枪资源契约**

扩展 `validate_ranged_weapon_volley.gd`：

```gdscript
const SHOTGUN_DEFINITION_PATH := "res://resources/weapons/shotgun.tres"
const WeaponDefinition = preload(
	"res://scripts/combat/weapons/weapon_definition.gd"
)
const RangedWeapon = preload(
	"res://scripts/combat/weapons/ranged_weapon.gd"
)

var shotgun := load(SHOTGUN_DEFINITION_PATH) as RangedWeaponDefinition
_expect(shotgun != null, "shotgun definition must load", failures)
if shotgun != null:
	_expect(shotgun.weapon_id == &"shotgun", "shotgun id must be stable", failures)
	_expect(shotgun.display_name == "散弹枪", "shotgun display name must be Chinese", failures)
	_expect(shotgun.visual_node_name == &"Shotgun", "shotgun must bind model node", failures)
	_expect(shotgun.trigger_mode == WeaponDefinition.TriggerMode.HOLD, "shotgun must support hold fire", failures)
	_expect(is_equal_approx(shotgun.attacks_per_second, 1.25), "shotgun interval must be 0.8 seconds", failures)
	_expect(is_equal_approx(shotgun.attack_range, 18.0), "shotgun range must be 18m", failures)
	_expect(is_equal_approx(shotgun.damage, 25.0), "each pellet must deal 25", failures)
	_expect(shotgun.uses_ammo and shotgun.max_ammo == 120, "shotgun ammo cap must be 120", failures)
	_expect(shotgun.projectiles_per_shot == 3, "shotgun must fire three pellets", failures)
	_expect(is_equal_approx(shotgun.projectile_angle_degrees, 6.0), "pellet spacing must be six degrees", failures)
	_expect(is_zero_approx(shotgun.base_spread_degrees), "shotgun random spread must be zero", failures)
	_expect(is_zero_approx(shotgun.max_spread_degrees), "shotgun random spread cap must be zero", failures)

var shotgun_scene := load("res://scenes/weapons/Shotgun.tscn") as PackedScene
_expect(shotgun_scene != null, "shotgun scene must load", failures)
if shotgun_scene != null:
	var shotgun_weapon := shotgun_scene.instantiate() as RangedWeapon
	shotgun_weapon.set_ammo_count(2)
	_expect(shotgun_weapon.try_consume_ammo(), "shotgun round must consume ammo", failures)
	_expect(shotgun_weapon.get_ammo_count() == 1, "one three-pellet round must consume exactly one shell", failures)
	shotgun_weapon.free()
```

扩展 `validate_equipment_cycle.gd`，实例化正式 `Player.tscn` 后断言 `shotgun` 存在、默认未拥有、弹药上限 `120`，且未拥有时 `add_ammo(&"shotgun", 36) == 0`。

- [ ] **Step 2: 运行验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_ranged_weapon_volley.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
```

Expected: FAIL，因为 `shotgun.tres` 与玩家散弹枪 loadout 尚不存在。

- [ ] **Step 3: 创建散弹枪资源**

创建 `resources/weapons/shotgun.tres`：

```ini
[gd_resource type="Resource" script_class="RangedWeaponDefinition" format=3]

[ext_resource type="Script" path="res://scripts/combat/weapons/ranged_weapon_definition.gd" id="1_definition"]

[resource]
script = ExtResource("1_definition")
attack_range = 18.0
tracer_pool_size = 12
uses_ammo = true
max_ammo = 120
max_penetration_count = 0
base_spread_degrees = 0.0
max_spread_degrees = 0.0
spread_increase_per_shot_degrees = 0.0
spread_recovery_degrees_per_second = 0.0
projectiles_per_shot = 3
projectile_angle_degrees = 6.0
weapon_id = &"shotgun"
display_name = "散弹枪"
visual_node_name = &"Shotgun"
trigger_mode = 1
attacks_per_second = 1.25
damage = 25.0
idle_animation = &"Idle_Gun"
run_animation = &"Run_Gun"
visual_recoil_kick = 0.14
camera_impulse_strength = 0.1
```

- [ ] **Step 4: 创建散弹枪场景**

创建 `scenes/weapons/Shotgun.tscn`，结构与 `Smg.tscn` 一致，只替换资源与根名：

```ini
[gd_scene load_steps=5 format=3]

[ext_resource type="Script" path="res://scripts/combat/weapons/ranged_weapon.gd" id="1_weapon"]
[ext_resource type="Resource" path="res://resources/weapons/shotgun.tres" id="2_definition"]
[ext_resource type="PackedScene" path="res://scenes/fx/MuzzleFlash.tscn" id="3_muzzle_flash"]
[ext_resource type="AudioStream" path="res://assets/sfx/weapons/impactMetal_heavy_002.ogg" id="4_shot_audio"]

[node name="Shotgun" type="Node3D"]
script = ExtResource("1_weapon")
definition = ExtResource("2_definition")
initially_owned = false

[node name="Muzzle" type="Marker3D" parent="."]

[node name="MuzzleFlash" parent="Muzzle" instance=ExtResource("3_muzzle_flash")]

[node name="ShotAudio" type="AudioStreamPlayer3D" parent="."]
stream = ExtResource("4_shot_audio")
volume_db = -8.0
unit_size = 6.0
max_distance = 32.0
```

- [ ] **Step 5: 将散弹枪插入玩家装备顺序**

在 `Player.tscn` 增加 `Shotgun.tscn` ext_resource，并把 loadout 改为：

```ini
loadout = Array[PackedScene]([
	ExtResource("7_pistol"),
	ExtResource("8_smg"),
	ExtResource("14_shotgun"),
	ExtResource("9_knife"),
	ExtResource("12_oil_barrel")
])
```

保持 `starting_slot = 0`；基础玩家仍从手枪开始，冲锋枪与散弹枪均未拥有。

- [ ] **Step 6: 更新槽位相关验证**

`validate_single_player_input_wiring.gd` 不再直接装备默认不可用的油桶；先调用 `grant_item(&"oil_barrel", 1, false)`，再装备槽位 `4` 并验证 `place_item_service`。匕首槽位改为 `3`；通过 `get_slot_for_item(&"shotgun") == 2` 验证新槽位。初始显示断言保持 `手枪`，一次 next 输入必须跳过未拥有的冲锋枪和散弹枪并到达 `匕首`。`validate_local_disconnect_contract.gd` 同时实例化 `Smg.tscn` 与 `Shotgun.tscn`，断言两者 `hit_collision_mask` 都排除玩家碰撞层 `2`。

- [ ] **Step 7: 运行散弹枪验证并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_ranged_weapon_volley.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_single_player_input_wiring.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_disconnect_contract.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 全部 PASS，导入 exit `0`。

- [ ] **Step 8: 提交 Task 3**

```bash
git add resources/weapons/shotgun.tres scenes/weapons/Shotgun.tscn scenes/player/Player.tscn tools/validation
git commit -m "feat: add shotgun equipment"
```

---

### Task 4: 散弹拾取、Demo 地图与随机掉落

**Files:**
- Create: `resources/pickups/shotgun_pickup.tres`
- Create: `resources/pickups/shotgun_ammo_pickup.tres`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `tools/validation/validate_equipment_cycle.gd`
- Modify: `tools/validation/validate_pickup_spawn_point.gd`
- Modify: `tools/validation/validate_random_pickup_drops.gd`

**Interfaces:**
- Consumes: Task 3 的 `shotgun` 装备 ID、`PickupDefinition.RewardMode.EQUIPMENT/AMMO`、现有共享 `PickupSpawnPoint.tscn`。
- Produces: 散弹武器箱 `+24` 自动装备、散弹弹药箱 `+36`、Demo 五个固定拾取点与五项随机掉落池。

- [ ] **Step 1: 先扩展拾取与 Demo 失败验证**

在 `validate_pickup_spawn_point.gd` 增加：

```gdscript
const SHOTGUN_PICKUP_DEFINITION_PATH := "res://resources/pickups/shotgun_pickup.tres"
const SHOTGUN_AMMO_PICKUP_DEFINITION_PATH := "res://resources/pickups/shotgun_ammo_pickup.tres"

"Shotgun": SHOTGUN_PICKUP_DEFINITION_PATH,
"ShotgunAmmo": SHOTGUN_AMMO_PICKUP_DEFINITION_PATH,
```

资源期望：

```gdscript
SHOTGUN_PICKUP_DEFINITION_PATH: {
	"reward_mode": PickupDefinition.RewardMode.EQUIPMENT,
	"item_id": &"shotgun",
	"amount": 24,
	"auto_equip": true,
	"display_name": "散弹枪",
	"marker_color": Color(0.85, 0.25, 0.95, 1.0),
},
SHOTGUN_AMMO_PICKUP_DEFINITION_PATH: {
	"reward_mode": PickupDefinition.RewardMode.AMMO,
	"item_id": &"shotgun",
	"amount": 36,
	"auto_equip": false,
	"display_name": "散弹枪弹药",
	"marker_color": Color(1.0, 0.75, 0.20, 1.0),
},
```

固定位置期望增加：

```gdscript
"Shotgun": Vector3(-4.5, 0.0, -6.0),
"ShotgunAmmo": Vector3(4.5, 0.0, -6.0),
```

并把 child count 从 `3` 改为 `5`。`validate_random_pickup_drops.gd` preload 两个新定义，把随机池和 Demo manager size 从 `3` 改为 `5`。

- [ ] **Step 2: 运行拾取验证并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_spawn_point.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_random_pickup_drops.gd
```

Expected: FAIL，因为散弹拾取资源、两个固定拾取点和五项随机池尚不存在。

- [ ] **Step 3: 创建散弹武器与弹药拾取资源**

创建 `shotgun_pickup.tres`：

```ini
[gd_resource type="Resource" script_class="PickupDefinition" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/pickup_definition.gd" id="1_pickup_definition"]

[resource]
script = ExtResource("1_pickup_definition")
reward_mode = 0
item_id = &"shotgun"
amount = 24
auto_equip = true
display_name = "散弹枪"
marker_color = Color(0.85, 0.25, 0.95, 1)
```

创建 `shotgun_ammo_pickup.tres`：

```ini
[gd_resource type="Resource" script_class="PickupDefinition" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/pickup_definition.gd" id="1_pickup_definition"]

[resource]
script = ExtResource("1_pickup_definition")
reward_mode = 1
item_id = &"shotgun"
amount = 36
auto_equip = false
display_name = "散弹枪弹药"
marker_color = Color(1, 0.75, 0.2, 1)
```

- [ ] **Step 4: 验证武器箱和弹药箱业务路径**

在 `validate_equipment_cycle.gd` 增加正式 Player 测试：

```gdscript
var shotgun = controller.get_item_by_id(&"shotgun")
_expect(shotgun != null and not shotgun.is_available(), "shotgun must start unowned", failures)
_expect(controller.add_ammo(&"shotgun", 36) == 0, "unowned shotgun must reject ammo", failures)
_expect(controller.grant_item(&"shotgun", 24, true), "shotgun chest must grant weapon and ammo", failures)
_expect(shotgun.is_available(), "shotgun chest must grant ownership", failures)
_expect(controller.get_current_item() == shotgun, "shotgun chest must auto equip", failures)
_expect(shotgun.get_ammo_count() == 24, "shotgun chest must grant 24 shells", failures)
_expect(controller.add_ammo(&"shotgun", 36) == 36, "shotgun ammo chest must grant 36 shells", failures)
shotgun.set_ammo_count(119)
_expect(controller.add_ammo(&"shotgun", 36) == 1, "shotgun ammo must cap at 120", failures)
```

- [ ] **Step 5: 在 DemoArena 增加两个资源与固定拾取点**

添加两个 ext_resource，将随机掉落池改为五项，并在 `World/Props/PickupSpawners` 下添加：

```ini
[node name="Shotgun" parent="World/Props/PickupSpawners" instance=ExtResource("24_pickup_spawn_point")]
position = Vector3(-4.5, 0, -6)
pickup_definition = ExtResource("29_shotgun_pickup")
respawn_enabled = true
respawn_delay_seconds = 3.0

[node name="ShotgunAmmo" parent="World/Props/PickupSpawners" instance=ExtResource("24_pickup_spawn_point")]
position = Vector3(4.5, 0, -6)
pickup_definition = ExtResource("30_shotgun_ammo_pickup")
respawn_enabled = true
respawn_delay_seconds = 3.0
```

随机池精确配置为：

```ini
pickup_definitions = [
	ExtResource("25_smg_pickup"),
	ExtResource("26_smg_ammo_pickup"),
	ExtResource("29_shotgun_pickup"),
	ExtResource("30_shotgun_ammo_pickup"),
	ExtResource("27_oil_barrel_pickup")
]
```

- [ ] **Step 6: 运行拾取、装备和 Demo 验证并确认 GREEN**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_spawn_point.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_random_pickup_drops.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 全部 PASS，导入 exit `0`。

- [ ] **Step 7: 提交 Task 4**

```bash
git add resources/pickups/shotgun_pickup.tres resources/pickups/shotgun_ammo_pickup.tres scenes/gameplay/DemoArena.tscn tools/validation
git commit -m "feat: add shotgun pickups to demo"
```

---

### Task 5: 文档、完整回归与人工验收

**Files:**
- Modify: `README.md`
- Verify: `scripts/`, `scenes/`, `resources/`, `tools/validation/`, `project.godot`

**Interfaces:**
- Consumes: Task 1–4 的最终武器、装备和拾取行为。
- Produces: 无旧步枪运行时引用、最新操作说明、完整验证记录和最终 squash commit。

- [ ] **Step 1: 更新 README 武器说明**

将控制与 Demo 描述更新为当前循环切换模型，避免继续描述不存在的数字直选槽位。至少写明：

```markdown
- 冲锋枪按住攻击键以每秒 4 发持续射击，每发造成 25 点伤害。
- 散弹枪按住攻击键每 0.8 秒发射一轮；每轮三颗弹丸、消耗 1 发散弹。
- 散弹枪三条弹道固定为 -6° / 0° / +6°，近距离全中伤害高，远距离部分命中时效率明显下降。
- 冲锋枪和散弹枪都通过武器箱解锁，并分别使用自己的有限弹药。
```

同步删除“第一版没有弹药、拾取、掉落”等已经失效的旧说明。

- [ ] **Step 2: 检查旧步枪运行时引用**

Run:

```bash
rg -n 'rifle|Rifle|步枪' scripts scenes resources tools README.md project.godot
```

Expected: 无输出。历史设计文档允许保留原始上下文，因此不扫描 `docs/`。

- [ ] **Step 3: 运行核心验证矩阵**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_ranged_weapon_volley.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_pickup_spawn_point.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_random_pickup_drops.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_lobby_player_preview.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_player_spawning.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_single_player_input_wiring.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_disconnect_contract.gd
```

Expected: 每个脚本打印自己的 `PASS` 并 exit `0`。

- [ ] **Step 4: 运行导入、Demo Smoke Test 与 diff 检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --quit-after 5 res://scenes/gameplay/DemoArena.tscn
git diff --check
```

Expected: 两个 Godot 命令 exit `0`，无解析/场景加载错误；`git diff --check` 无输出。

- [ ] **Step 5: 执行人工验收**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

依次检查：

1. 拾取紫色散弹武器箱，自动装备 `Shotgun` 模型，状态显示 `散弹枪:24`。
2. 按住攻击键，确认约每 `0.8s` 一轮，每轮弹药只减少 `1`，每轮只有一次音效/枪口/镜头冲击。
3. 贴近 `50 HP` 普通僵尸对准射击，确认三条曳光共同命中并一轮击杀。
4. 拉到中远距离，确认三条稳定扇形弹道明显分离，单个目标只中部分弹丸时不能稳定一轮击杀。
5. 将多个僵尸引入窄道或并排区域，确认同轮不同弹道可分别命中不同目标。
6. 隔墙射击，确认每条曳光在自己的墙体命中点结束，墙后目标不受伤。
7. 拾取冲锋枪箱，确认显示 `冲锋枪`、使用 `SMG` 模型、每秒 `4` 发、每发 `25` 伤害、拾取数量与原步枪一致。
8. 拾取散弹弹药箱，确认未拥有时不消耗，拥有后增加 `36` 且不超过 `120`。

若视觉结果存在疑问，按仓库约定由用户截取近距离三弹全中、远距离部分命中和墙体截断三张截图，再基于截图评审；不要用 CUA 做全自动视觉验收。

- [ ] **Step 6: 提交文档更新**

```bash
git add README.md
git commit -m "docs: document smg and shotgun behavior"
```

- [ ] **Step 7: 最终评审后 squash 为计划 Commit**

确认所有 Task 与最终评审完成后，将本功能的临时提交 squash 为一个 Conventional Commit：

```text
feat: add smg and shotgun weapon flow
```

不要改写不属于本功能的用户提交；执行 squash 前先用 `git log --oneline --decorate` 精确确认本功能提交边界。
