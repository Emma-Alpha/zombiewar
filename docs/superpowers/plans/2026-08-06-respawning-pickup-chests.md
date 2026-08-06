# 可刷新步枪箱与弹药箱 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 使用同一个 `Chest.gltf` 创建可配置的步枪箱和弹药箱，成功领取后关闭内容标记并在 3 秒后原地刷新，同时在 Demo 出生点附近提供固定测试位置。

**Architecture:** `PickupChest` 是带静态碰撞的通用场景，奖励类型由导出枚举决定；它只调用 `PlayerController` 的武器/弹药拾取接口。箱体与导航碰撞始终保留，冷却期间仅关闭 `Area3D` 和蓝/橙视觉标记。

**Tech Stack:** Godot 4.7.1、GDScript、Area3D、Label3D、TorusMesh、现有 `Chest.gltf` 与中文字体、自定义测试框架。

## Global Constraints

- 前置计划：前三份计划必须完成，尤其是 `receive_weapon_pickup()`、`receive_ammo_pickup()` 和 HUD 状态同步。
- 步枪箱：未拥有时授予步枪与 60 发；已拥有时增加 60 发；成功后请求自动装备槽 2。
- 弹药箱：只为已经拥有的步枪增加 90 发，不自动切换武器。
- 两类奖励都受 360 上限约束；没有实际状态变化时箱子保持可用。
- 玩家死亡、尚未拥有步枪却接触弹药箱、或弹药已满时，不能消费箱子。
- 成功领取后箱体与静态碰撞保持，隐藏光圈/图标/标签并禁用领取区域；3 秒后恢复。
- 弹药箱使用蓝色光圈、弹匣标记、`弹药 +90`；步枪箱使用橙色光圈、步枪标记、`步枪 +60`。
- 原补给点四个 `SupplyChest` 保持装饰；只在出生点附近新增两个功能箱。
- 不新增第三方素材；只使用 `Chest.gltf`、Godot 原生几何和现有字体。
- 本计划最终只保留一个提交：`feat: add respawning weapon pickups`。

---

### Task 1: 创建通用 PickupChest 场景与行为

**Files:**
- Create: `scripts/gameplay/pickup_chest.gd`
- Create: `scenes/props/PickupChest.tscn`
- Create: `tests/integration/test_pickup_chest.gd`
- Modify: `tests/test_runner.gd:4-58`

**Interfaces:**
- Consumes: `PlayerController.receive_weapon_pickup(weapon_id, ammo_amount) -> bool`、`receive_ammo_pickup(weapon_id, ammo_amount) -> bool`。
- Produces: `PickupChest.PickupKind`、`pickup_kind`、`weapon_id`、`ammo_amount`、`respawn_seconds`、`is_available() -> bool`、`try_collect(player) -> bool`、`finish_respawn() -> void`。

- [ ] **Step 1: 注册不会解析报错的失败测试**

在 `tests/test_runner.gd` 集成测试段加入：

```gdscript
"res://tests/integration/test_pickup_chest.gd",
```

创建 `tests/integration/test_pickup_chest.gd`。RED 阶段使用动态 `load()`，确保场景不存在时得到断言失败而不是 preload 解析错误：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const PICKUP_PATH := "res://scenes/props/PickupChest.tscn"

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load(PICKUP_PATH) as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Pickup chest scene loads"
	))
	if packed == null:
		return failures

	var tree := Engine.get_main_loop() as SceneTree
	var player := PLAYER_SCENE.instantiate() as PlayerController
	tree.root.add_child(player)
	var weapon_chest := packed.instantiate()
	weapon_chest.set("pickup_kind", 0)
	weapon_chest.set("ammo_amount", 60)
	tree.root.add_child(weapon_chest)
	_append(failures, Assertions.expect_true(
		bool(weapon_chest.call("try_collect", player)),
		"Weapon chest grants an unowned rifle"
	))
	_append(failures, Assertions.expect_true(
		player.equipment.owns_weapon(&"rifle") and
			player.equipment.get_ammo_count(&"rifle") == 60 and
			player.equipment.get_current_definition().weapon_id == &"rifle",
		"Weapon chest grants 60 rounds and auto-equips"
	))
	_append(failures, Assertions.expect_true(
		not bool(weapon_chest.call("is_available")) and
			is_equal_approx(float(weapon_chest.get("respawn_seconds")), 3.0) and
			not weapon_chest.get_node("MarkerRoot").visible and
			weapon_chest.get_node("Visual").visible,
		"Collected chest enters three-second cooldown"
	))
	weapon_chest.call("finish_respawn")
	_append(failures, Assertions.expect_true(
		weapon_chest.get_node("MarkerRoot").visible and
			bool(weapon_chest.call("try_collect", player)) and
			player.equipment.get_ammo_count(&"rifle") == 120,
		"Duplicate weapon pickup adds another 60 rounds"
	))

	var ammo_chest := packed.instantiate()
	ammo_chest.set("pickup_kind", 1)
	ammo_chest.set("ammo_amount", 90)
	tree.root.add_child(ammo_chest)
	_append(failures, Assertions.expect_true(
		bool(ammo_chest.call("try_collect", player)) and
			player.equipment.get_ammo_count(&"rifle") == 210,
		"Ammo chest adds 90 rifle rounds"
	))
	player.equipment.add_ammo(&"rifle", 1000)
	ammo_chest.call("finish_respawn")
	weapon_chest.call("finish_respawn")
	_append(failures, Assertions.expect_true(
		not bool(ammo_chest.call("try_collect", player)) and
			bool(ammo_chest.call("is_available")),
		"Full ammo leaves ammo chest available"
	))
	_append(failures, Assertions.expect_true(
		not bool(weapon_chest.call("try_collect", player)) and
			bool(weapon_chest.call("is_available")),
		"Full duplicate weapon leaves weapon chest available"
	))

	var player_without_rifle := PLAYER_SCENE.instantiate() as PlayerController
	tree.root.add_child(player_without_rifle)
	var locked_ammo_chest := packed.instantiate()
	locked_ammo_chest.set("pickup_kind", 1)
	locked_ammo_chest.set("ammo_amount", 90)
	tree.root.add_child(locked_ammo_chest)
	_append(failures, Assertions.expect_true(
		not bool(locked_ammo_chest.call("try_collect", player_without_rifle)) and
			bool(locked_ammo_chest.call("is_available")),
		"Ammo chest cannot pre-store ammo before rifle ownership"
	))

	locked_ammo_chest.free()
	player_without_rifle.free()
	ammo_chest.free()
	weapon_chest.free()
	player.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

运行：

```bash
./tests/run_tests.sh res://tests/integration/test_pickup_chest.gd
```

Expected: FAIL，消息为 `Pickup chest scene loads`，而不是脚本解析错误。

- [ ] **Step 2: 实现 PickupChest 脚本**

创建 `scripts/gameplay/pickup_chest.gd`：

```gdscript
extends StaticBody3D
class_name PickupChest

enum PickupKind {
	WEAPON,
	AMMO,
}

const WEAPON_COLOR := Color("ff9f31")
const AMMO_COLOR := Color("41baff")

@export var pickup_kind := PickupKind.AMMO
@export var weapon_id: StringName = &"rifle"
@export_range(1, 9999, 1) var ammo_amount := 90
@export_range(0.1, 60.0, 0.1) var respawn_seconds := 3.0

@onready var pickup_area: Area3D = $PickupArea
@onready var marker_root: Node3D = $MarkerRoot
@onready var ground_ring: MeshInstance3D = $MarkerRoot/GroundRing
@onready var icon_label: Label3D = $MarkerRoot/IconLabel
@onready var pickup_label: Label3D = $MarkerRoot/PickupLabel
@onready var respawn_timer: Timer = $RespawnTimer

var available := true

func _ready() -> void:
	pickup_area.body_entered.connect(_on_body_entered)
	respawn_timer.timeout.connect(finish_respawn)
	respawn_timer.wait_time = respawn_seconds
	_apply_type_visuals()
	_set_available(true)

func is_available() -> bool:
	return available

func try_collect(player: PlayerController) -> bool:
	if not available or player == null or not player.is_alive():
		return false
	var collected := false
	if pickup_kind == PickupKind.WEAPON:
		collected = player.receive_weapon_pickup(weapon_id, ammo_amount)
	else:
		collected = player.receive_ammo_pickup(weapon_id, ammo_amount)
	if not collected:
		return false
	_set_available(false)
	respawn_timer.start(respawn_seconds)
	return true

func finish_respawn() -> void:
	respawn_timer.stop()
	_set_available(true)

func _on_body_entered(body: Node3D) -> void:
	if body is PlayerController:
		try_collect(body as PlayerController)

func _set_available(value: bool) -> void:
	available = value
	pickup_area.set_deferred("monitoring", value)
	marker_root.visible = value

func _apply_type_visuals() -> void:
	var is_weapon := pickup_kind == PickupKind.WEAPON
	var color := WEAPON_COLOR if is_weapon else AMMO_COLOR
	icon_label.text = "步枪" if is_weapon else "▮▮▮"
	pickup_label.text = "%s +%d" % ["步枪" if is_weapon else "弹药", ammo_amount]
	icon_label.modulate = color
	pickup_label.modulate = color
	var material := ground_ring.material_override.duplicate() as StandardMaterial3D
	material.albedo_color = Color(color, 0.32)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.2
	ground_ring.material_override = material
```

- [ ] **Step 3: 创建复用 Chest.gltf 的场景**

节点契约：

```text
PickupChest (StaticBody3D, groups=[navigation_source, place_item_obstacle])
├── Visual (instance=assets/environment/Chest.gltf)
├── CollisionShape3D (BoxShape3D size=0.64,0.41,0.48; y=0.205)
├── PickupArea (Area3D; collision_layer=0; collision_mask=2)
│   └── CollisionShape3D (CylinderShape3D radius=0.95; height=1.6; y=0.8)
├── MarkerRoot
│   ├── GroundRing (TorusMesh; y=0.025)
│   ├── IconLabel (Label3D; y=1.25)
│   └── PickupLabel (Label3D; y=0.92)
└── RespawnTimer (one_shot=true; wait_time=3.0)
```

场景外部资源：

```ini
[ext_resource type="Script" path="res://scripts/gameplay/pickup_chest.gd" id="1_pickup"]
[ext_resource type="PackedScene" path="res://assets/environment/Chest.gltf" id="2_chest"]
[ext_resource type="FontFile" path="res://assets/fonts/NotoSansSC-UI.ttf" id="3_cjk_font"]
```

两个 `Label3D` 设置 `font_size = 32`、`outline_size = 8`、`no_depth_test = true`、`fixed_size = true`。光圈材质开启透明和 emission、关闭阴影，并设置 `resource_local_to_scene = true`。

- [ ] **Step 4: 导入、测试并提交 Task 1**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh res://tests/integration/test_pickup_chest.gd
git status --short
```

Expected: 测试 PASS；若生成 `pickup_chest.gd.uid`，与脚本一并添加。

```bash
git add scripts/gameplay/pickup_chest.gd scenes/props/PickupChest.tscn \
  tests/integration/test_pickup_chest.gd tests/test_runner.gd
git add scripts/gameplay/pickup_chest.gd.uid
git commit -m "feat: add respawning weapon pickups"
```

若 `.uid` 不存在，省略对应 `git add`，不得创建空文件。

---

### Task 2: 在 Demo 放置固定测试箱

**Files:**
- Modify: `scenes/gameplay/DemoArena.tscn:1-24,455-595`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `tests/integration/test_checkpoint_prop_scenes.gd`

**Interfaces:**
- Consumes: `PickupChest.PickupKind.WEAPON`、`AMMO` 和场景导出配置。
- Produces: `World/Props/SpawnPickups/WeaponPickupChest`、`AmmoPickupChest` 两个固定节点。

- [ ] **Step 1: 编写 Demo 布局失败测试**

在 `test_demo_scene.gd` 顶部预加载 `pickup_chest.gd`，取得两个节点并断言：

```gdscript
_append(failures, Assertions.expect_true(
	weapon_pickup != null and
		weapon_pickup.pickup_kind == PickupChest.PickupKind.WEAPON and
		weapon_pickup.ammo_amount == 60 and
		is_equal_approx(weapon_pickup.respawn_seconds, 3.0),
	"Demo exposes a respawning rifle chest near spawn"
))
_append(failures, Assertions.expect_true(
	ammo_pickup != null and
		ammo_pickup.pickup_kind == PickupChest.PickupKind.AMMO and
		ammo_pickup.ammo_amount == 90 and
		is_equal_approx(ammo_pickup.respawn_seconds, 3.0),
	"Demo exposes a respawning ammo chest near spawn"
))
_append(failures, Assertions.expect_true(
	weapon_pickup.global_position.distance_to(player.global_position) < 4.0 and
		ammo_pickup.global_position.distance_to(player.global_position) < 4.0 and
		weapon_pickup.global_position.distance_to(ammo_pickup.global_position) > 2.0,
	"Demo pickup chests are nearby but cannot trigger together"
))
```

在 `test_checkpoint_prop_scenes.gd` 断言原 `ChestA`–`ChestD` 均没有 `PickupArea`。

运行：

```bash
./tests/run_tests.sh \
  res://tests/integration/test_demo_scene.gd \
  res://tests/integration/test_checkpoint_prop_scenes.gd
```

Expected: FAIL，两个 `SpawnPickups` 节点不存在。

- [ ] **Step 2: 在 DemoArena.tscn 放置两个箱子**

增加外部资源并递增 `load_steps`：

```ini
[ext_resource type="PackedScene" path="res://scenes/props/PickupChest.tscn" id="23_pickup_chest"]
```

加入：

```ini
[node name="SpawnPickups" type="Node3D" parent="World/Props"]

[node name="WeaponPickupChest" parent="World/Props/SpawnPickups" instance=ExtResource("23_pickup_chest")]
position = Vector3(-1.8, 0, 4.8)
pickup_kind = 0
weapon_id = &"rifle"
ammo_amount = 60
respawn_seconds = 3.0

[node name="AmmoPickupChest" parent="World/Props/SpawnPickups" instance=ExtResource("23_pickup_chest")]
position = Vector3(1.8, 0, 4.8)
pickup_kind = 1
weapon_id = &"rifle"
ammo_amount = 90
respawn_seconds = 3.0
```

不要修改原 `World/Props/SupplyPoint/Chests` 四个装饰箱。

- [ ] **Step 3: 运行全量测试和人工验收**

```bash
./tests/run_tests.sh
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

人工验证：蓝/橙视觉可区分；蓝箱加 90；橙箱加 60 并自动切步枪；箱体冷却期间保留；3 秒原地恢复；360 满弹时两箱不消失；两个箱子不能同时触发。

- [ ] **Step 4: 提交并压缩为单一计划提交**

```bash
git add scenes/gameplay/DemoArena.tscn tests/integration/test_demo_scene.gd \
  tests/integration/test_checkpoint_prop_scenes.gd
git commit -m "fixup! feat: add respawning weapon pickups"
GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash HEAD~2
git log -1 --oneline
```

Expected: 只保留一个 `feat: add respawning weapon pickups` 提交；用户现有 `.gitignore` 修改保持未提交。
