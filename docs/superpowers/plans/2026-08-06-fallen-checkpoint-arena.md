# 失守的临时检查站 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `DemoArena` 扩展为 `48 × 38` 米，并使用现有 CC0 环境资产制作一处具有封锁线、车辆事故、危险品区、遗弃补给点和撤离痕迹的失守临时检查站。

**Architecture:** 保持单场景、单导航区块和现有正交跟随相机。新增水马、塑料护栏和补给箱各自封装为无脚本的静态物件场景，`DemoArena.tscn` 只负责语义分区、精确摆位和原生网格装饰；所有真实障碍继续通过简化碰撞加入导航与放置网格。现有爆炸桶动态重烘焙流程不改变，只更新语义层级后的节点路径。

**Tech Stack:** Godot 4.7.1、GDScript、`.tscn`/`.gltf` 场景资源、自定义 `RefCounted.run() -> Array[String]` 测试运行器。

## Global Constraints

- 地图固定为 `48 × 38` 米，地面范围 X `-24..24`、Z `-19..19`。
- 四角刷怪点固定为 `(±19, 0, ±14)`；玩家保持在 `(0, 0, 6)`；相机正交尺寸保持 `15.0`。
- 导航烘焙范围固定为 `AABB(-24.25, -0.5, -19.25, 48.5, 4, 38.5)`，继续只使用一个 `demo_arena` 区块和异步烘焙。
- 新增数量固定为 6 个交通水马、8 个塑料护栏、12 个交通锥和 4 个补给箱；补给箱不提供交互。
- 水马、塑料护栏和补给箱使用简化 `BoxShape3D`，加入 `navigation_source` 与 `place_item_obstacle`；交通锥、道路标线、固定血迹、标牌和警示灯不参与导航。
- 北侧封锁线必须保留两个不窄于 `2.4` 米的入口；玩家出生点 8 米内不新增大型障碍。
- 不调整僵尸数量上限、感知距离、移动速度、武器配置、相机参数或现有战斗规则。
- 警示灯不启用阴影，不增加体积雾或高成本后处理，兼顾 Web 和移动端。
- 不修改 `addons/`、导出配置或用户当前未提交的武器资源与武器测试改动。
- 不使用 CUA 或 UI 自动化验证；视觉结果由用户按计划末尾步骤运行游戏并提供截图。
- 每个任务可以产生临时审查提交；全部任务和最终评审完成后，把本计划的实现提交 squash 为一个 `feat: build fallen checkpoint arena` 提交。

---

## File Structure

### 新增正式资产

- `assets/environment/TrafficBarrier_1.gltf` 与 `TrafficBarrier_1_Zombie_Atlas.png`：北侧实体封锁水马。
- `assets/environment/PlasticBarrier.gltf` 与 `PlasticBarrier_Zombie_Atlas.png`：检查通道与补给点边界。
- `assets/environment/TrafficCone_1.gltf` 与 `TrafficCone_1_Zombie_Atlas.png`：无碰撞的小型叙事装饰。
- `assets/environment/Chest.gltf` 与 `Chest_Zombie_Atlas.png`：无交互补给箱视觉。
- 上述八个文件对应的 `.import`：由 Godot 从正式 `res://assets/environment/` 路径重新生成并提交，不能直接复用 `docs/` 下带旧 `source_file` 的 `.import`。

### 新增可复用场景

- `scenes/props/TrafficBarrier.tscn`：水马视觉、简化碰撞和导航/放置组契约。
- `scenes/props/PlasticBarrier.tscn`：塑料护栏视觉、简化碰撞和导航/放置组契约。
- `scenes/props/SupplyChest.tscn`：补给箱视觉、简化碰撞和导航/放置组契约。

### 新增测试

- `tests/integration/test_checkpoint_prop_scenes.gd`：验证三个静态物件场景的资源、碰撞尺寸与组契约。
- `tests/integration/test_demo_arena_extent.gd`：验证地图、边界、导航 AABB、刷怪点、玩家与相机尺寸。
- `tests/integration/test_fallen_checkpoint_scene.gd`：验证语义分区、固定数量、封锁线双入口、故事节点和出生区约束。
- 对应 `.gd.uid`：执行 Godot 导入后生成并提交。

### 修改文件

- `scenes/gameplay/DemoArena.tscn`：扩图、语义层级、资产实例、道路标线、标牌、警示灯和固定血迹。
- `scripts/gameplay/demo_arena.gd`：把初始爆炸桶容器路径改到 `World/Props/HazardZone/ExplosiveBarrels`。
- `tests/integration/test_demo_navigation.gd`：更新语义路径并检查新增静态导航来源。
- `tests/integration/test_demo_place_item.gd`：更新语义路径并检查新增放置障碍。
- `tests/integration/test_explosive_barrel_scene.gd`：更新爆炸桶容器路径。
- `tests/test_runner.gd`：注册三个新增集成测试。
- `docs/superpowers/plans/2026-08-06-fallen-checkpoint-arena.md`：本实施计划，随 Task 1 的临时提交纳入最终 squash。

---

### Task 1: 导入检查站资产并建立静态物件场景

**Files:**
- Create: `assets/environment/TrafficBarrier_1.gltf`
- Create: `assets/environment/TrafficBarrier_1_Zombie_Atlas.png`
- Create: `assets/environment/PlasticBarrier.gltf`
- Create: `assets/environment/PlasticBarrier_Zombie_Atlas.png`
- Create: `assets/environment/TrafficCone_1.gltf`
- Create: `assets/environment/TrafficCone_1_Zombie_Atlas.png`
- Create: `assets/environment/Chest.gltf`
- Create: `assets/environment/Chest_Zombie_Atlas.png`
- Create after import: `assets/environment/TrafficBarrier_1.gltf.import`
- Create after import: `assets/environment/TrafficBarrier_1_Zombie_Atlas.png.import`
- Create after import: `assets/environment/PlasticBarrier.gltf.import`
- Create after import: `assets/environment/PlasticBarrier_Zombie_Atlas.png.import`
- Create after import: `assets/environment/TrafficCone_1.gltf.import`
- Create after import: `assets/environment/TrafficCone_1_Zombie_Atlas.png.import`
- Create after import: `assets/environment/Chest.gltf.import`
- Create after import: `assets/environment/Chest_Zombie_Atlas.png.import`
- Create: `scenes/props/TrafficBarrier.tscn`
- Create: `scenes/props/PlasticBarrier.tscn`
- Create: `scenes/props/SupplyChest.tscn`
- Create: `tests/integration/test_checkpoint_prop_scenes.gd`
- Create after import: `tests/integration/test_checkpoint_prop_scenes.gd.uid`
- Modify: `tests/test_runner.gd:41-48`

**Interfaces:**
- Consumes: 候选资源目录 `docs/game_resources_zombie_prototype/assets/environment/` 中四个 `.gltf` 和四个图集文件。
- Produces: `res://scenes/props/TrafficBarrier.tscn`、`res://scenes/props/PlasticBarrier.tscn`、`res://scenes/props/SupplyChest.tscn`；三个根节点均为 `StaticBody3D`，均属于 `navigation_source` 和 `place_item_obstacle`。

- [ ] **Step 1: 先写静态物件场景契约测试并注册**

创建 `tests/integration/test_checkpoint_prop_scenes.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const PROP_CONTRACTS: Array[Dictionary] = [
	{
		"path": "res://scenes/props/TrafficBarrier.tscn",
		"root_name": &"TrafficBarrier",
		"shape_size": Vector3(1.56, 1.12, 0.88),
		"shape_position": Vector3(0.0, 0.56, 0.0),
	},
	{
		"path": "res://scenes/props/PlasticBarrier.tscn",
		"root_name": &"PlasticBarrier",
		"shape_size": Vector3(1.04, 0.60, 0.34),
		"shape_position": Vector3(0.0, 0.30, 0.0),
	},
	{
		"path": "res://scenes/props/SupplyChest.tscn",
		"root_name": &"SupplyChest",
		"shape_size": Vector3(0.64, 0.41, 0.48),
		"shape_position": Vector3(0.0, 0.205, 0.0),
	},
]

func run() -> Array[String]:
	var failures: Array[String] = []
	for contract in PROP_CONTRACTS:
		_test_prop_contract(failures, contract)
	return failures

func _test_prop_contract(
	failures: Array[String],
	contract: Dictionary
) -> void:
	var packed := load(String(contract["path"])) as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Checkpoint prop scene loads: %s" % contract["path"]
	))
	if packed == null:
		return
	var body := packed.instantiate() as StaticBody3D
	_append(failures, Assertions.expect_true(
		body != null and body.name == contract["root_name"],
		"Checkpoint prop owns the planned StaticBody3D root: %s" % contract["path"]
	))
	if body == null:
		return
	var visual := body.get_node_or_null("Visual") as Node3D
	var collision := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	var shape := collision.shape as BoxShape3D if collision != null else null
	_append(failures, Assertions.expect_true(
		body.collision_layer == 1 and body.collision_mask == 0 and
		body.is_in_group(&"navigation_source") and
		body.is_in_group(&"place_item_obstacle"),
		"Checkpoint prop exposes world collision and navigation/place groups: %s" % contract["path"]
	))
	_append(failures, Assertions.expect_true(
		visual != null and not visual.is_in_group(&"navigation_source"),
		"Checkpoint prop keeps its imported visual outside navigation groups: %s" % contract["path"]
	))
	_append(failures, Assertions.expect_true(
		shape != null,
		"Checkpoint prop uses a BoxShape3D: %s" % contract["path"]
	))
	if shape != null and collision != null:
		_append(failures, Assertions.expect_vector3_near(
			shape.size,
			contract["shape_size"],
			0.001,
			"Checkpoint prop collision size matches the low-poly model"
		))
		_append(failures, Assertions.expect_vector3_near(
			collision.position,
			contract["shape_position"],
			0.001,
			"Checkpoint prop collision rests on the ground"
		))
	body.free()

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在 `tests/test_runner.gd` 的集成测试区加入：

```gdscript
	"res://tests/integration/test_checkpoint_prop_scenes.gd",
```

- [ ] **Step 2: 运行测试确认缺少三个场景时失败**

Run:

```bash
./tests/run_tests.sh res://tests/integration/test_checkpoint_prop_scenes.gd
```

Expected: FAIL；输出包含 `Checkpoint prop scene loads`，并指出 `TrafficBarrier.tscn`、`PlasticBarrier.tscn`、`SupplyChest.tscn` 尚不存在。

- [ ] **Step 3: 复制四组正式资产，不复制旧路径的 `.import`**

Run:

```bash
cp docs/game_resources_zombie_prototype/assets/environment/TrafficBarrier_1.gltf assets/environment/TrafficBarrier_1.gltf
cp docs/game_resources_zombie_prototype/assets/environment/TrafficBarrier_1_Zombie_Atlas.png assets/environment/TrafficBarrier_1_Zombie_Atlas.png
cp docs/game_resources_zombie_prototype/assets/environment/PlasticBarrier.gltf assets/environment/PlasticBarrier.gltf
cp docs/game_resources_zombie_prototype/assets/environment/PlasticBarrier_Zombie_Atlas.png assets/environment/PlasticBarrier_Zombie_Atlas.png
cp docs/game_resources_zombie_prototype/assets/environment/TrafficCone_1.gltf assets/environment/TrafficCone_1.gltf
cp docs/game_resources_zombie_prototype/assets/environment/TrafficCone_1_Zombie_Atlas.png assets/environment/TrafficCone_1_Zombie_Atlas.png
cp docs/game_resources_zombie_prototype/assets/environment/Chest.gltf assets/environment/Chest.gltf
cp docs/game_resources_zombie_prototype/assets/environment/Chest_Zombie_Atlas.png assets/environment/Chest_Zombie_Atlas.png
```

不要复制 `docs/.../*.import`；那些文件的 `source_file` 指向 `res://docs/...`，正式资产必须由 Godot 重新生成 `res://assets/environment/...` 的导入元数据。

- [ ] **Step 4: 创建三个无脚本静态物件场景**

`scenes/props/TrafficBarrier.tscn`：

```tscn
[gd_scene load_steps=3 format=3]

[ext_resource type="PackedScene" path="res://assets/environment/TrafficBarrier_1.gltf" id="1_visual"]

[sub_resource type="BoxShape3D" id="BoxShape3D_traffic_barrier"]
size = Vector3(1.56, 1.12, 0.88)

[node name="TrafficBarrier" type="StaticBody3D" groups=["navigation_source", "place_item_obstacle"]]
collision_layer = 1
collision_mask = 0

[node name="Visual" parent="." instance=ExtResource("1_visual")]

[node name="CollisionShape3D" type="CollisionShape3D" parent="."]
position = Vector3(0, 0.56, 0)
shape = SubResource("BoxShape3D_traffic_barrier")
```

`scenes/props/PlasticBarrier.tscn`：

```tscn
[gd_scene load_steps=3 format=3]

[ext_resource type="PackedScene" path="res://assets/environment/PlasticBarrier.gltf" id="1_visual"]

[sub_resource type="BoxShape3D" id="BoxShape3D_plastic_barrier"]
size = Vector3(1.04, 0.6, 0.34)

[node name="PlasticBarrier" type="StaticBody3D" groups=["navigation_source", "place_item_obstacle"]]
collision_layer = 1
collision_mask = 0

[node name="Visual" parent="." instance=ExtResource("1_visual")]

[node name="CollisionShape3D" type="CollisionShape3D" parent="."]
position = Vector3(0, 0.3, 0)
shape = SubResource("BoxShape3D_plastic_barrier")
```

`scenes/props/SupplyChest.tscn`：

```tscn
[gd_scene load_steps=3 format=3]

[ext_resource type="PackedScene" path="res://assets/environment/Chest.gltf" id="1_visual"]

[sub_resource type="BoxShape3D" id="BoxShape3D_supply_chest"]
size = Vector3(0.64, 0.41, 0.48)

[node name="SupplyChest" type="StaticBody3D" groups=["navigation_source", "place_item_obstacle"]]
collision_layer = 1
collision_mask = 0

[node name="Visual" parent="." instance=ExtResource("1_visual")]

[node name="CollisionShape3D" type="CollisionShape3D" parent="."]
position = Vector3(0, 0.205, 0)
shape = SubResource("BoxShape3D_supply_chest")
```

- [ ] **Step 5: 让 Godot 生成正式导入元数据并运行契约测试**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh res://tests/integration/test_checkpoint_prop_scenes.gd
```

Expected: Godot import命令退出码为 0；测试输出 `PASS: 1 test file(s)`；新生成的 `.import` 中 `source_file` 均以 `res://assets/environment/` 开头。

- [ ] **Step 6: 创建 Task 1 临时审查提交**

```bash
git add docs/superpowers/plans/2026-08-06-fallen-checkpoint-arena.md assets/environment/TrafficBarrier_1.gltf assets/environment/TrafficBarrier_1.gltf.import assets/environment/TrafficBarrier_1_Zombie_Atlas.png assets/environment/TrafficBarrier_1_Zombie_Atlas.png.import assets/environment/PlasticBarrier.gltf assets/environment/PlasticBarrier.gltf.import assets/environment/PlasticBarrier_Zombie_Atlas.png assets/environment/PlasticBarrier_Zombie_Atlas.png.import assets/environment/TrafficCone_1.gltf assets/environment/TrafficCone_1.gltf.import assets/environment/TrafficCone_1_Zombie_Atlas.png assets/environment/TrafficCone_1_Zombie_Atlas.png.import assets/environment/Chest.gltf assets/environment/Chest.gltf.import assets/environment/Chest_Zombie_Atlas.png assets/environment/Chest_Zombie_Atlas.png.import scenes/props/TrafficBarrier.tscn scenes/props/PlasticBarrier.tscn scenes/props/SupplyChest.tscn tests/integration/test_checkpoint_prop_scenes.gd tests/integration/test_checkpoint_prop_scenes.gd.uid tests/test_runner.gd
git commit -m "feat: add checkpoint environment props"
```

---

### Task 2: 扩大竞技场、边界、导航范围与刷怪点

**Files:**
- Create: `tests/integration/test_demo_arena_extent.gd`
- Create after import: `tests/integration/test_demo_arena_extent.gd.uid`
- Modify: `tests/test_runner.gd:41-50`
- Modify: `scenes/gameplay/DemoArena.tscn:31-53,129-191,245-257`

**Interfaces:**
- Consumes: 现有 `DemoArenaChunk.baking_bounds`、四个边界节点、四个刷怪点、玩家和 `FollowCamera/Camera3D`。
- Produces: `48 × 38` 地面与碰撞、X `±24`/Z `±19` 边界、固定导航 AABB、`(±19, 0, ±14)` 刷怪点；节点名称保持不变供现有波次与导航代码使用。

- [ ] **Step 1: 写地图尺度契约测试并注册**

创建 `tests/integration/test_demo_arena_extent.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ARENA_SCENE := preload("res://scenes/gameplay/DemoArena.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var arena := ARENA_SCENE.instantiate()
	var ground_mesh_node := arena.get_node_or_null(
		"World/Ground/MeshInstance3D"
	) as MeshInstance3D
	var ground_shape_node := arena.get_node_or_null(
		"World/Ground/CollisionShape3D"
	) as CollisionShape3D
	var ground_mesh := ground_mesh_node.mesh as BoxMesh if ground_mesh_node != null else null
	var ground_shape := ground_shape_node.shape as BoxShape3D if ground_shape_node != null else null
	_append(failures, Assertions.expect_true(
		ground_mesh != null and ground_shape != null,
		"Expanded demo owns box ground mesh and collision"
	))
	if ground_mesh != null:
		_append(failures, Assertions.expect_vector3_near(
			ground_mesh.size,
			Vector3(48.0, 0.3, 38.0),
			0.001,
			"Demo visual ground expands to 48 by 38 meters"
		))
	if ground_shape != null:
		_append(failures, Assertions.expect_vector3_near(
			ground_shape.size,
			Vector3(48.0, 0.3, 38.0),
			0.001,
			"Demo collision ground expands to 48 by 38 meters"
		))

	var chunk := arena.get_node_or_null(
		"World/Navigation/DemoArenaChunk"
	) as NavigationChunk3D
	_append(failures, Assertions.expect_true(
		chunk != null,
		"Expanded demo keeps one navigation chunk"
	))
	if chunk != null:
		_append(failures, Assertions.expect_vector3_near(
			chunk.baking_bounds.position,
			Vector3(-24.25, -0.5, -19.25),
			0.001,
			"Navigation baking origin covers expanded borders"
		))
		_append(failures, Assertions.expect_vector3_near(
			chunk.baking_bounds.size,
			Vector3(48.5, 4.0, 38.5),
			0.001,
			"Navigation baking size covers expanded arena"
		))

	var boundary_positions := {
		"North": Vector3(0.0, 1.0, -19.0),
		"South": Vector3(0.0, 1.0, 19.0),
		"West": Vector3(-24.0, 1.0, 0.0),
		"East": Vector3(24.0, 1.0, 0.0),
	}
	for boundary_name in boundary_positions:
		var boundary := arena.get_node_or_null(
			"World/Boundaries/%s" % boundary_name
		) as StaticBody3D
		_append(failures, Assertions.expect_true(
			boundary != null,
			"Expanded demo keeps boundary %s" % boundary_name
		))
		if boundary != null:
			_append(failures, Assertions.expect_vector3_near(
				boundary.position,
				boundary_positions[boundary_name],
				0.001,
				"Expanded boundary moves to its planned edge: %s" % boundary_name
			))

	var spawn_positions := {
		"NorthWest": Vector3(-19.0, 0.0, -14.0),
		"NorthEast": Vector3(19.0, 0.0, -14.0),
		"SouthWest": Vector3(-19.0, 0.0, 14.0),
		"SouthEast": Vector3(19.0, 0.0, 14.0),
	}
	for spawn_name in spawn_positions:
		var marker := arena.get_node_or_null(
			"World/SpawnPoints/%s" % spawn_name
		) as Marker3D
		_append(failures, Assertions.expect_true(
			marker != null,
			"Expanded demo keeps spawn marker %s" % spawn_name
		))
		if marker != null:
			_append(failures, Assertions.expect_vector3_near(
				marker.position,
				spawn_positions[spawn_name],
				0.001,
				"Spawn marker moves with expanded edge: %s" % spawn_name
			))

	var player := arena.get_node_or_null("Player") as Node3D
	var camera := arena.get_node_or_null("FollowCamera/Camera3D") as Camera3D
	_append(failures, Assertions.expect_true(
		player != null and player.position == Vector3(0.0, 0.0, 6.0),
		"Expansion preserves the player spawn"
	))
	_append(failures, Assertions.expect_true(
		camera != null and camera.projection == Camera3D.PROJECTION_ORTHOGONAL and
		is_equal_approx(camera.size, 15.0),
		"Expansion preserves the orthographic camera framing"
	))
	arena.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在 `tests/test_runner.gd` 加入：

```gdscript
	"res://tests/integration/test_demo_arena_extent.gd",
```

- [ ] **Step 2: 运行测试确认仍为旧尺寸时失败**

Run:

```bash
./tests/run_tests.sh res://tests/integration/test_demo_arena_extent.gd
```

Expected: FAIL；至少报告地面仍为 `44 × 34`、导航 AABB 仍为 `44.5 × 34.5` 或边界仍位于 `±22/±17`。

- [ ] **Step 3: 精确修改地面、边界、导航 AABB 与刷怪点**

在 `scenes/gameplay/DemoArena.tscn` 使用以下值：

```tscn
[sub_resource type="BoxMesh" id="BoxMesh_ground"]
material = SubResource("StandardMaterial3D_ground")
size = Vector3(48, 0.3, 38)

[sub_resource type="BoxShape3D" id="BoxShape3D_ground"]
size = Vector3(48, 0.3, 38)

[sub_resource type="BoxMesh" id="BoxMesh_north_south"]
material = SubResource("StandardMaterial3D_boundary")
size = Vector3(48, 2, 0.5)

[sub_resource type="BoxShape3D" id="BoxShape3D_north_south"]
size = Vector3(48, 2, 0.5)

[sub_resource type="BoxMesh" id="BoxMesh_east_west"]
material = SubResource("StandardMaterial3D_boundary")
size = Vector3(0.5, 2, 38)

[sub_resource type="BoxShape3D" id="BoxShape3D_east_west"]
size = Vector3(0.5, 2, 38)
```

更新实例属性：

```tscn
[node name="DemoArenaChunk" parent="World/Navigation" instance=ExtResource("14_navigation_chunk")]
chunk_id = &"demo_arena"
source_root_path = NodePath("../..")
baking_bounds = AABB(-24.25, -0.5, -19.25, 48.5, 4, 38.5)
threaded_baking = true

[node name="North" type="StaticBody3D" parent="World/Boundaries" groups=["navigation_source", "place_item_obstacle"]]
position = Vector3(0, 1, -19)

[node name="South" type="StaticBody3D" parent="World/Boundaries" groups=["navigation_source", "place_item_obstacle"]]
position = Vector3(0, 1, 19)

[node name="West" type="StaticBody3D" parent="World/Boundaries" groups=["navigation_source", "place_item_obstacle"]]
position = Vector3(-24, 1, 0)

[node name="East" type="StaticBody3D" parent="World/Boundaries" groups=["navigation_source", "place_item_obstacle"]]
position = Vector3(24, 1, 0)

[node name="NorthWest" type="Marker3D" parent="World/SpawnPoints"]
position = Vector3(-19, 0, -14)

[node name="NorthEast" type="Marker3D" parent="World/SpawnPoints"]
position = Vector3(19, 0, -14)

[node name="SouthWest" type="Marker3D" parent="World/SpawnPoints"]
position = Vector3(-19, 0, 14)

[node name="SouthEast" type="Marker3D" parent="World/SpawnPoints"]
position = Vector3(19, 0, 14)
```

不要修改 `Player.position`、`FollowCamera.position` 或 `FollowCamera/Camera3D.size`。

- [ ] **Step 4: 运行地图尺度测试与现有波次测试**

Run:

```bash
./tests/run_tests.sh res://tests/integration/test_demo_arena_extent.gd res://tests/integration/test_demo_wave_spawning.gd
```

Expected: `PASS: 2 test file(s)`；四角仍各自产生至少一只初始僵尸。

- [ ] **Step 5: 创建 Task 2 临时审查提交**

```bash
git add scenes/gameplay/DemoArena.tscn tests/integration/test_demo_arena_extent.gd tests/integration/test_demo_arena_extent.gd.uid tests/test_runner.gd
git commit -m "feat: expand demo arena footprint"
```

---

### Task 3: 构建失守检查站语义布局与视觉叙事

**Files:**
- Create: `tests/integration/test_fallen_checkpoint_scene.gd`
- Create after import: `tests/integration/test_fallen_checkpoint_scene.gd.uid`
- Modify: `tests/test_runner.gd:41-52`
- Modify: `scenes/gameplay/DemoArena.tscn:1-270`
- Modify: `scripts/gameplay/demo_arena.gd:148-172`
- Modify: `tests/integration/test_demo_navigation.gd:59-83`
- Modify: `tests/integration/test_demo_place_item.gd:15-92`
- Modify: `tests/integration/test_explosive_barrel_scene.gd:163-203`

**Interfaces:**
- Consumes: Task 1 的三个静态物件场景、`TrafficCone_1.gltf`、现有皮卡/集装箱/爆炸桶、`GroundBloodSplat.tscn` 与 CJK 字体。
- Produces: `World/Props/Checkpoint`、`Incident`、`HazardZone`、`SupplyPoint`、`RoadDetails` 五个语义分区；动态爆炸桶固定路径为 `World/Props/HazardZone/ExplosiveBarrels`。

- [ ] **Step 1: 写失守检查站场景契约测试并注册**

创建 `tests/integration/test_fallen_checkpoint_scene.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const ARENA_SCENE := preload("res://scenes/gameplay/DemoArena.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	var arena := ARENA_SCENE.instantiate()
	for path in [
		"World/Props/Checkpoint",
		"World/Props/Incident",
		"World/Props/HazardZone",
		"World/Props/SupplyPoint",
		"World/Props/RoadDetails",
	]:
		_append(failures, Assertions.expect_true(
			arena.get_node_or_null(path) is Node3D,
			"Fallen checkpoint exposes semantic scene group: %s" % path
		))

	var traffic_barriers := arena.get_node_or_null(
		"World/Props/Checkpoint/TrafficBarriers"
	) as Node3D
	var checkpoint_plastics := arena.get_node_or_null(
		"World/Props/Checkpoint/PlasticBarriers"
	) as Node3D
	var checkpoint_cones := arena.get_node_or_null(
		"World/Props/Checkpoint/TrafficCones"
	) as Node3D
	var incident_cones := arena.get_node_or_null(
		"World/Props/Incident/TrafficCones"
	) as Node3D
	var south_cones := arena.get_node_or_null(
		"World/Props/RoadDetails/SouthCones"
	) as Node3D
	var supply_perimeter := arena.get_node_or_null(
		"World/Props/SupplyPoint/PerimeterProps"
	) as Node3D
	var chests := arena.get_node_or_null(
		"World/Props/SupplyPoint/Chests"
	) as Node3D
	_append(failures, Assertions.expect_equal(
		_child_count(traffic_barriers), 6,
		"Checkpoint uses six traffic barriers"
	))
	_append(failures, Assertions.expect_equal(
		_child_count(checkpoint_plastics) + _child_count(supply_perimeter), 8,
		"Checkpoint and supply point use eight plastic barriers"
	))
	_append(failures, Assertions.expect_equal(
		_child_count(checkpoint_cones) + _child_count(incident_cones) +
		_child_count(south_cones),
		12,
		"Checkpoint story uses twelve collision-free traffic cones"
	))
	_append(failures, Assertions.expect_equal(
		_child_count(chests), 4,
		"Supply point uses four non-interactive chests"
	))

	for root in [traffic_barriers, checkpoint_plastics, supply_perimeter, chests]:
		if root == null:
			continue
		for child in root.get_children():
			_append(failures, Assertions.expect_true(
				child is StaticBody3D and
				child.is_in_group(&"navigation_source") and
				child.is_in_group(&"place_item_obstacle"),
				"Every substantial checkpoint prop blocks navigation and placement"
			))
	for root in [checkpoint_cones, incident_cones, south_cones]:
		if root == null:
			continue
		for child in root.get_children():
			_append(failures, Assertions.expect_true(
				not child.is_in_group(&"navigation_source") and
				not child.is_in_group(&"place_item_obstacle"),
				"Traffic cones remain visual-only story props"
			))

	if traffic_barriers != null and traffic_barriers.get_child_count() == 6:
		var barrier_shape_node := traffic_barriers.get_child(0).get_node_or_null(
			"CollisionShape3D"
		) as CollisionShape3D
		var barrier_shape := barrier_shape_node.shape as BoxShape3D if barrier_shape_node != null else null
		if barrier_shape != null:
			var west_inner := traffic_barriers.get_node("WestInner") as Node3D
			var center_left := traffic_barriers.get_node("CenterLeft") as Node3D
			var center_right := traffic_barriers.get_node("CenterRight") as Node3D
			var east_inner := traffic_barriers.get_node("EastInner") as Node3D
			var west_gap := absf(center_left.position.x - west_inner.position.x) - barrier_shape.size.x
			var east_gap := absf(east_inner.position.x - center_right.position.x) - barrier_shape.size.x
			_append(failures, Assertions.expect_true(
				west_gap >= 2.4 and east_gap >= 2.4,
				"North checkpoint preserves two 2.4-meter entrance gaps"
			))

	var story_blood := arena.get_node_or_null(
		"World/Props/Incident/StoryBlood"
	) as Node3D
	var warning_label := arena.get_node_or_null(
		"World/Props/Checkpoint/WarningSign/Label3D"
	) as Label3D
	var warning_light := arena.get_node_or_null(
		"World/Props/Checkpoint/WarningSign/WarningLight"
	) as OmniLight3D
	_append(failures, Assertions.expect_equal(
		_child_count(story_blood), 6,
		"Incident path uses six fixed blood marks"
	))
	_append(failures, Assertions.expect_true(
		warning_label != null and warning_label.text.contains("检疫封锁区"),
		"Checkpoint sign names the quarantine area"
	))
	_append(failures, Assertions.expect_true(
		warning_light != null and not warning_light.shadow_enabled and
		warning_light.omni_range <= 6.0,
		"Checkpoint warning light is local and shadow-free"
	))
	_append(failures, Assertions.expect_true(
		arena.get_node_or_null("World/Props/RoadDetails/RoadSurface") is MeshInstance3D and
		arena.get_node_or_null("World/Props/RoadDetails/LaneMarkings") is Node3D and
		arena.get_node_or_null("World/Props/RoadDetails/HazardMarkings") is Node3D,
		"Checkpoint owns road, lane, and hazard markings"
	))

	var player := arena.get_node_or_null("Player") as Node3D
	for path in [
		"World/Props/Incident/PickupCollision",
		"World/Props/HazardZone/ContainerACollision",
		"World/Props/Checkpoint/ContainerBCollision",
	]:
		var obstacle := arena.get_node_or_null(path) as Node3D
		_append(failures, Assertions.expect_true(
			player != null and obstacle != null and
			_planar_distance(player.position, obstacle.position) >= 8.0,
			"Large checkpoint obstacle stays outside the player spawn buffer: %s" % path
		))
	arena.free()
	return failures

func _child_count(node: Node) -> int:
	return 0 if node == null else node.get_child_count()

func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在 `tests/test_runner.gd` 加入：

```gdscript
	"res://tests/integration/test_fallen_checkpoint_scene.gd",
```

- [ ] **Step 2: 运行测试确认旧场景缺少语义分区**

Run:

```bash
./tests/run_tests.sh res://tests/integration/test_fallen_checkpoint_scene.gd
```

Expected: FAIL；输出包含 `Fallen checkpoint exposes semantic scene group`，并指出 `Checkpoint`、`Incident`、`HazardZone`、`SupplyPoint`、`RoadDetails` 尚不存在。

- [ ] **Step 3: 增加场景资源、道路材质、标牌与警示灯子资源**

在 `DemoArena.tscn` 顶部加入以下资源与子资源，并把 `load_steps` 从当前值增加 17（当前场景对应从 `32` 调整为 `49`）：

```tscn
[ext_resource type="PackedScene" path="res://scenes/props/TrafficBarrier.tscn" id="18_traffic_barrier"]
[ext_resource type="PackedScene" path="res://scenes/props/PlasticBarrier.tscn" id="19_plastic_barrier"]
[ext_resource type="PackedScene" path="res://assets/environment/TrafficCone_1.gltf" id="20_traffic_cone"]
[ext_resource type="PackedScene" path="res://scenes/props/SupplyChest.tscn" id="21_supply_chest"]
[ext_resource type="PackedScene" path="res://scenes/fx/GroundBloodSplat.tscn" id="22_story_blood"]

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_road"]
albedo_color = Color(0.13, 0.16, 0.18, 1)
roughness = 1.0

[sub_resource type="BoxMesh" id="BoxMesh_road"]
material = SubResource("StandardMaterial3D_road")
size = Vector3(12, 0.02, 38)

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_marking_white"]
albedo_color = Color(0.72, 0.7, 0.58, 1)
roughness = 0.95

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_marking_yellow"]
albedo_color = Color(0.78, 0.55, 0.12, 1)
roughness = 0.95

[sub_resource type="BoxMesh" id="BoxMesh_lane_dash"]
material = SubResource("StandardMaterial3D_marking_white")
size = Vector3(0.18, 0.025, 3)

[sub_resource type="BoxMesh" id="BoxMesh_stop_line"]
material = SubResource("StandardMaterial3D_marking_white")
size = Vector3(10, 0.025, 0.25)

[sub_resource type="BoxMesh" id="BoxMesh_hazard_line"]
material = SubResource("StandardMaterial3D_marking_yellow")
size = Vector3(4, 0.025, 0.18)

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_sign"]
albedo_color = Color(0.38, 0.08, 0.07, 1)
roughness = 0.72

[sub_resource type="BoxMesh" id="BoxMesh_sign_board"]
material = SubResource("StandardMaterial3D_sign")
size = Vector3(5, 1.1, 0.15)

[sub_resource type="BoxMesh" id="BoxMesh_sign_post"]
material = SubResource("StandardMaterial3D_sign")
size = Vector3(0.14, 2.4, 0.14)

[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_beacon"]
albedo_color = Color(1, 0.04, 0.02, 1)
emission_enabled = true
emission = Color(1, 0.01, 0, 1)
emission_energy_multiplier = 3.0

[sub_resource type="SphereMesh" id="SphereMesh_beacon"]
material = SubResource("StandardMaterial3D_beacon")
radius = 0.18
height = 0.36
```

把现有边界材质从红色改为低饱和蓝灰色：

```tscn
[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_boundary"]
albedo_color = Color(0.20, 0.24, 0.27, 1)
roughness = 0.9
```

- [ ] **Step 4: 按语义重组现有大型物件和爆炸桶**

删除 `World/Props` 下旧的平铺大型物件节点，按以下固定层级与变换重建；碰撞体继续复用现有 `BoxShape3D_pickup` 和 `BoxShape3D_container`：

```text
World/Props/Incident/PickupVisual             position=(5, 0, -1.5)   rotation_y=25
World/Props/Incident/PickupCollision          position=(5, 0.9, -1.5) rotation_y=25
World/Props/HazardZone/ContainerAVisual       position=(-9, 0, -2.5)  rotation_y=90
World/Props/HazardZone/ContainerACollision    position=(-9, 1.4, -2.5) rotation_y=90
World/Props/Checkpoint/ContainerBVisual       position=(-11, 0, -10.8) rotation_y=0
World/Props/Checkpoint/ContainerBCollision    position=(-11, 1.4, -10.8) rotation_y=0
World/Props/HazardZone/ExplosiveBarrels/ChainA position=(-14, 0, -3.5)
World/Props/HazardZone/ExplosiveBarrels/ChainB position=(-11, 0, -3.5)
World/Props/HazardZone/ExplosiveBarrels/Solo   position=(-15, 0, 4)
```

三个碰撞节点继续设置：

```tscn
groups=["navigation_source", "place_item_obstacle"]
collision_layer = 1
collision_mask = 0
```

`ChainA` 与 `ChainB` 平面距离为 3 米，保留连锁爆炸；`Solo` 与两者距离均大于 4.5 米。

- [ ] **Step 5: 摆放 6 个水马并形成两个 2.44 米入口**

在 `World/Props/Checkpoint/TrafficBarriers` 下实例化 Task 1 的场景：

```text
FarWest     position=(-6.4, 0, -10.5) rotation_y=0
WestInner   position=(-4.8, 0, -10.5) rotation_y=0
CenterLeft  position=(-0.8, 0, -10.5) rotation_y=0
CenterRight position=(0.8, 0, -10.5)  rotation_y=0
EastInner   position=(4.8, 0, -10.5)  rotation_y=0
FarEast     position=(6.4, 0, -10.5)  rotation_y=0
```

水马碰撞宽度为 1.56 米，`WestInner -> CenterLeft` 与 `CenterRight -> EastInner` 的净空均为 `4.0 - 1.56 = 2.44` 米。不要在这两个净空中心 X `-2.8` 和 `2.8` 附近增加带碰撞物件。

- [ ] **Step 6: 摆放 8 个塑料护栏、4 个补给箱和 12 个交通锥**

在 `World/Props/Checkpoint/PlasticBarriers` 下摆放四个纵向引导护栏：

```text
WestLaneOuter position=(-3.9, 0, -7.8) rotation_y=90
WestLaneInner position=(-1.7, 0, -7.8) rotation_y=90
EastLaneInner position=(1.7, 0, -7.8)  rotation_y=90
EastLaneOuter position=(3.9, 0, -7.8)  rotation_y=90
```

在 `World/Props/SupplyPoint/PerimeterProps` 下摆放四个补给区护栏：

```text
North position=(11.5, 0, -2.5)  rotation_y=0
South position=(11.5, 0, 2.0)   rotation_y=0
West  position=(9.5, 0, -0.25) rotation_y=90
East  position=(13.5, 0, -0.25) rotation_y=90
```

在 `World/Props/SupplyPoint/Chests` 下摆放四个补给箱：

```text
ChestA position=(10.6, 0, -1.5) rotation_y=-8
ChestB position=(12.0, 0, -1.5) rotation_y=6
ChestC position=(10.6, 0, 0.0)  rotation_y=4
ChestD position=(12.0, 0, 0.0)  rotation_y=-5
```

交通锥直接实例化 `ExtResource("20_traffic_cone")`，不添加组和碰撞：

```text
Checkpoint/TrafficCones/WestOuter  position=(-7.6, 0, -9.6)  rotation=(0, 18, 0)
Checkpoint/TrafficCones/EastOuter  position=(7.7, 0, -9.7)   rotation=(0, -12, 0)
Checkpoint/TrafficCones/WestBreach position=(-2.9, 0, -11.9) rotation=(0, 34, 8)
Checkpoint/TrafficCones/EastBreach position=(2.9, 0, -11.8)  rotation=(0, -26, -10)
Checkpoint/TrafficCones/CenterFall position=(-0.1, 0, -8.8)  rotation=(72, 8, 14)
Checkpoint/TrafficCones/FarWest    position=(-8.7, 0, -12.2) rotation=(0, -20, 0)
Incident/TrafficCones/CrashA       position=(2.8, 0, -3.0)   rotation=(0, 12, 0)
Incident/TrafficCones/CrashB       position=(6.7, 0, -3.0)   rotation=(0, -18, 0)
Incident/TrafficCones/CrashC       position=(2.5, 0, 0.0)    rotation=(68, 25, -12)
Incident/TrafficCones/CrashD       position=(7.0, 0, 0.3)    rotation=(0, 32, 0)
RoadDetails/SouthCones/West        position=(-5, 0, 10)      rotation=(0, -9, 0)
RoadDetails/SouthCones/East        position=(5, 0, 10)       rotation=(0, 11, 0)
```

- [ ] **Step 7: 添加道路、警戒区、标牌、警示灯和固定血迹**

创建 `World/Props/RoadDetails/RoadSurface`，位置 `Vector3(0, 0.01, 0)`，使用 `BoxMesh_road`。在 `LaneMarkings` 下创建五个 `MeshInstance3D`，使用 `BoxMesh_lane_dash`，位置分别为：

```text
(0, 0.025, -15)
(0, 0.025, -8)
(0, 0.025, -1)
(0, 0.025, 6)
(0, 0.025, 13)
```

增加 `StopLine`，位置 `Vector3(0, 0.025, -8.9)`，使用 `BoxMesh_stop_line`。在 `HazardMarkings` 下使用 `BoxMesh_hazard_line` 建立西侧四边框：

```text
North position=(-12.5, 0.025, -6.0) scale=(2.0, 1.0, 1.0)
South position=(-12.5, 0.025, 6.0)  scale=(2.0, 1.0, 1.0)
West  position=(-16.5, 0.025, 0.0)  rotation_y=90 scale=(3.0, 1.0, 1.0)
East  position=(-8.5, 0.025, 0.0)   rotation_y=90 scale=(3.0, 1.0, 1.0)
```

在 `World/Props/Checkpoint/WarningSign` 下建立：

```tscn
[node name="WarningSign" type="Node3D" parent="World/Props/Checkpoint"]
position = Vector3(0, 0, -12.2)

[node name="PostLeft" type="MeshInstance3D" parent="World/Props/Checkpoint/WarningSign"]
position = Vector3(-2, 1.2, 0)
mesh = SubResource("BoxMesh_sign_post")

[node name="PostRight" type="MeshInstance3D" parent="World/Props/Checkpoint/WarningSign"]
position = Vector3(2, 1.2, 0)
mesh = SubResource("BoxMesh_sign_post")

[node name="Board" type="MeshInstance3D" parent="World/Props/Checkpoint/WarningSign"]
position = Vector3(0, 2.4, 0)
mesh = SubResource("BoxMesh_sign_board")

[node name="Label3D" type="Label3D" parent="World/Props/Checkpoint/WarningSign"]
position = Vector3(0, 2.4, 0.09)
texture_filter = 1
font = ExtResource("10_cjk_font")
font_size = 44
text = "检疫封锁区\nQUARANTINE"
modulate = Color(1, 0.88, 0.68, 1)
outline_size = 8

[node name="Beacon" type="MeshInstance3D" parent="World/Props/Checkpoint/WarningSign"]
position = Vector3(0, 3.15, 0)
mesh = SubResource("SphereMesh_beacon")

[node name="WarningLight" type="OmniLight3D" parent="World/Props/Checkpoint/WarningSign"]
position = Vector3(0, 3.15, 0)
light_color = Color(1, 0.08, 0.03, 1)
light_energy = 1.35
omni_range = 5.5
shadow_enabled = false
```

在 `World/Props/Incident/StoryBlood` 下实例化六个 `GroundBloodSplat.tscn`，统一 `rotation_degrees.x = -90`，使用下列位置、Y 旋转和缩放：

```text
BreachA position=(-2.8, 0.035, -11.4) rotation_y=18  scale=(0.8, 0.8, 0.8)
BreachB position=(-1.7, 0.035, -9.6)  rotation_y=-24 scale=(0.65, 0.9, 0.65)
TrailA  position=(-0.4, 0.035, -7.8)  rotation_y=12  scale=(0.7, 1.0, 0.7)
TrailB  position=(1.0, 0.035, -6.0)   rotation_y=-15 scale=(0.6, 0.85, 0.6)
TrailC  position=(2.8, 0.035, -4.1)   rotation_y=22  scale=(0.75, 0.75, 0.75)
Crash   position=(4.3, 0.035, -2.5)   rotation_y=-8  scale=(1.15, 1.15, 1.15)
```

固定血迹节点不加入 `navigation_source` 或 `place_item_obstacle`，运行时战斗血迹仍由 `GroundBloodManager` 独立管理。

- [ ] **Step 8: 更新爆炸桶运行时路径和放置目标路径**

在 `scripts/gameplay/demo_arena.gd` 的 `_wire_dependencies()` 中替换：

```gdscript
	var barrels_root := get_node_or_null(
		"World/Props/HazardZone/ExplosiveBarrels"
	)
```

在 `DemoArena.tscn` 的 `PlaceItemController` 中替换：

```tscn
placed_items_path = NodePath("../World/Props/HazardZone/ExplosiveBarrels")
```

不要修改 `_on_barrel_navigation_geometry_changed()` 或动态重烘焙行为。

- [ ] **Step 9: 更新现有导航、放置和爆炸桶测试的节点路径**

在 `test_demo_navigation.gd` 中把大型物件路径改为：

```gdscript
	for path in [
		"World/Ground",
		"World/Boundaries/North",
		"World/Boundaries/South",
		"World/Boundaries/West",
		"World/Boundaries/East",
		"World/Props/Incident/PickupCollision",
		"World/Props/HazardZone/ContainerACollision",
		"World/Props/Checkpoint/ContainerBCollision",
	]:
```

并额外遍历以下根节点，断言每个子节点属于 `navigation_source`：

```gdscript
	for root_path in [
		"World/Props/Checkpoint/TrafficBarriers",
		"World/Props/Checkpoint/PlasticBarriers",
		"World/Props/SupplyPoint/PerimeterProps",
		"World/Props/SupplyPoint/Chests",
	]:
		var root := arena.get_node_or_null(root_path)
		if root == null:
			failures.append("Demo navigation prop root exists: %s" % root_path)
			continue
		for child in root.get_children():
			_append(failures, Assertions.expect_true(
				child.is_in_group(&"navigation_source"),
				"Checkpoint static prop is a navigation source: %s/%s" % [root_path, child.name]
			))
```

视觉路径改为：

```gdscript
	for path in [
		"World/Props/Incident/PickupVisual",
		"World/Props/HazardZone/ContainerAVisual",
		"World/Props/Checkpoint/ContainerBVisual",
	]:
```

在 `test_demo_place_item.gd` 中把爆炸桶路径改为：

```gdscript
	var barrels := arena.get_node_or_null(
		"World/Props/HazardZone/ExplosiveBarrels"
	) as Node3D
```

把三个大型障碍路径改为新的语义路径，并用与导航测试相同的四个根节点遍历所有新增静态物件，断言 `place_item_obstacle`。把容器阻挡请求改为命中新的 ContainerA 中心格：

```gdscript
	var blocked := controller.request_place_item(
		player,
		Vector3(-9.0, 0.0, -1.5),
		Vector3.FORWARD
	)
```

该请求目标为 `(-9, 0, -2.5)`，落在 ContainerA 的占用区域内。

在 `test_explosive_barrel_scene.gd` 中把容器路径改为：

```gdscript
	var barrels_root := arena.get_node_or_null(
		"World/Props/HazardZone/ExplosiveBarrels"
	)
```

保留三个爆炸桶、连锁半径和导航信号连接断言。

- [ ] **Step 10: 运行检查站与受影响集成测试**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh res://tests/integration/test_checkpoint_prop_scenes.gd res://tests/integration/test_demo_arena_extent.gd res://tests/integration/test_fallen_checkpoint_scene.gd res://tests/integration/test_demo_navigation.gd res://tests/integration/test_demo_place_item.gd res://tests/integration/test_explosive_barrel_scene.gd res://tests/integration/test_demo_wave_spawning.gd
```

Expected: `PASS: 7 test file(s)`；Godot 不输出 `SCRIPT ERROR`、`Parse Error` 或运行时 `ERROR`。

- [ ] **Step 11: 创建 Task 3 临时审查提交**

```bash
git add scenes/gameplay/DemoArena.tscn scripts/gameplay/demo_arena.gd tests/integration/test_fallen_checkpoint_scene.gd tests/integration/test_fallen_checkpoint_scene.gd.uid tests/integration/test_demo_navigation.gd tests/integration/test_demo_place_item.gd tests/integration/test_explosive_barrel_scene.gd tests/test_runner.gd
git commit -m "feat: build fallen checkpoint arena"
```

---

### Task 4: 完整验证、用户视觉验收与最终 squash

**Files:**
- Verify: `scenes/gameplay/DemoArena.tscn`
- Verify: `scripts/gameplay/demo_arena.gd`
- Verify: `tests/integration/test_checkpoint_prop_scenes.gd`
- Verify: `tests/integration/test_demo_arena_extent.gd`
- Verify: `tests/integration/test_fallen_checkpoint_scene.gd`
- Verify: `tests/integration/test_demo_navigation.gd`
- Verify: `tests/integration/test_demo_place_item.gd`
- Verify: `tests/integration/test_explosive_barrel_scene.gd`
- Verify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: Task 1–3 的完整检查站场景、静态物件与测试。
- Produces: 通过完整无界面测试、通过用户视觉验收、且实现历史压缩为一个计划提交的可交付结果。

- [ ] **Step 1: 检查文本、导入和场景解析**

Run:

```bash
git diff --check e13d76a..HEAD
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: `git diff --check` 无输出；Godot 退出码为 0，且不出现资源缺失、循环依赖或场景解析错误。

- [ ] **Step 2: 运行完整自定义测试套件**

Run:

```bash
./tests/run_tests.sh
```

Expected: 输出 `PASS: 53 test file(s)`，并且严格错误捕获没有发现 `SCRIPT ERROR`、`Parse Error` 或运行时 `ERROR`。

- [ ] **Step 3: 向用户发出精确的游戏内视觉验收步骤并等待截图**

请用户运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

验收操作：

1. 进入 Demo 后不要移动，截一张南侧出生视角，画面应能读到中央皮卡、北侧红色警示点和左右分区。
2. 移动到 `(0, 0, -6)` 附近再截一张图，两条水马入口应清楚分开，标牌不应被皮卡遮挡。
3. 沿左右两个入口各穿过一次；任何入口都不能卡住玩家。
4. 按 `T` 连续触发两轮尸潮，观察四角僵尸能否进入检查站并追到中央。
5. 前往西侧引爆 `ChainA/ChainB`，确认连锁爆炸发生，`Solo` 不被首轮连锁引爆。
6. 按 `K` 分别尝试在开放道路、补给箱上、塑料护栏上和地图边界旁放置油桶；只有开放道路允许放置。

请用户提供步骤 1 与步骤 2 的截图。验收标准：模型不悬空、不明显互穿；两个入口净空可辨；补给点不是封闭安全角；红灯不覆盖整张画面；玩家和僵尸轮廓不被道路标线或固定血迹干扰。

- [ ] **Step 4: 根据截图只进行允许范围内的视觉校正并复测**

截图若未通过上述标准，只允许修改以下 `DemoArena.tscn` 属性：环境物件的 `position`/`rotation_degrees`、道路/标线颜色、警示灯 `light_energy`（范围 `0.8..1.35`）和 `omni_range`（范围 `4.0..5.5`）、固定血迹缩放（每轴 `0.5..1.15`）。不得改变地图尺寸、入口水马 X 坐标、碰撞尺寸、资产数量、刷怪点、相机或战斗平衡。

每轮校正后运行：

```bash
./tests/run_tests.sh res://tests/integration/test_fallen_checkpoint_scene.gd res://tests/integration/test_demo_navigation.gd res://tests/integration/test_demo_place_item.gd
```

Expected: `PASS: 3 test file(s)`。如果有视觉校正，创建一个临时提交：

```bash
git add scenes/gameplay/DemoArena.tscn
git commit -m "fix: polish fallen checkpoint layout"
```

- [ ] **Step 5: 最终评审提交范围，保护用户原有未提交修改**

Run:

```bash
git status --short
git log --oneline --decorate e13d76a..HEAD
git diff --name-only e13d76a..HEAD
```

Expected: 提交范围只包含本计划 File Structure 列出的资产、场景、计划、脚本和测试；以下用户原有未提交文件仍保持未提交且不进入任何临时提交：

```text
assets/environment/Barrel_Zombie_Atlas.png.import
resources/weapons/pistol.tres
resources/weapons/rifle.tres
tests/integration/test_weapon_wall_clearance.gd
tests/unit/test_weapon_configuration.gd
tests/unit/test_weapon_penetration.gd
```

如果 `e13d76a..HEAD` 出现与本计划无关的提交，停止 squash 并向用户报告提交哈希与主题；不要重写无关历史。

- [ ] **Step 6: 将本计划临时提交 squash 为一个计划提交**

仅在 Step 5 确认 `e13d76a..HEAD` 全部属于本计划后执行：

```bash
git reset --soft e13d76a
git diff --cached --name-only
git commit -m "feat: build fallen checkpoint arena"
```

Expected: `git diff --cached --name-only` 只包含本计划文件；最终 `git log -2 --oneline` 显示设计提交 `e13d76a docs: design fallen checkpoint arena` 之后只有一个 `feat: build fallen checkpoint arena` 实现提交。用户原有未提交修改仍留在工作区。

- [ ] **Step 7: squash 后再次运行最终验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh
git status --short
```

Expected: Godot 导入成功、完整测试通过；`git status --short` 只显示用户原有未提交修改，不显示本计划遗漏的未跟踪文件。
