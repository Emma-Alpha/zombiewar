# 僵尸运行时分区导航 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 DemoArena 中通过运行时异步烘焙的可注册导航区块，让僵尸追击和游荡都能绕过静态障碍，并为未来随机地图、建筑破坏和分块世界保留导航更新入口。

**Architecture:** 当前 `World3D` 拥有场景级 `NavigationWorldManager`，它管理共享同一导航地图的 `NavigationChunk3D` 子节点。每个区块使用独立候选 `NavigationMesh` 完成解析和后台烘焙，成功后才替换 `NavigationRegion3D` 的活动网格；`ZombieTarget` 使用关闭 avoidance 的 `NavigationAgent3D` 提供路径点，但继续自行控制速度、重力、击退、动画和 `move_and_slide()`。

**Tech Stack:** Godot 4.7.1、GDScript、`NavigationServer3D`、`NavigationRegion3D`、`NavigationAgent3D`、现有 RefCounted 自定义测试框架。

## Global Constraints

- 实现必须在独立 Git worktree 和 `codex/runtime-chunked-zombie-navigation` 分支中完成。
- 使用场景级导航管理器，不新增导航 Autoload。
- DemoArena 只创建一个 `demo_arena` 导航区块；不实现无限地图、动态分块加载、随机地图生成器或建筑破坏系统。
- 所有导航区块共享当前 `World3D` 的默认导航地图。
- 运行时只解析简化静态碰撞体，不解析 GLTF 视觉模型。
- 所有区块与共享导航地图统一使用 `cell_size = 0.20`、`cell_height = 0.10`；`agent_radius = 0.60` 和 `border_size = 0.60` 必须与体素精确对齐。
- 区块 `baking_bounds` 使用 `source_root` 本地坐标；位置查询和活动 region 变换必须采用同一坐标空间。
- 默认使用后台异步烘焙；测试允许切换同步烘焙以获得确定结果。
- 初始波次不等待导航就绪；首次导航不可用时允许短暂直线降级。
- 有效导航地图出现后，不可达目标不得永久回退为直线撞墙。
- 重烘焙期间保留旧网格；同一区块不得并发烘焙；重复请求必须合并。
- 追击和游荡都使用导航路径。
- `NavigationAgent3D.avoidance_enabled` 保持 `false`。
- 隔着世界碰撞层障碍物时不得进入或维持攻击。
- 保留现有僵尸感知、难度速度、攻击周期、击退、重力、血迹和动画行为。
- 新增测试必须注册到 `tests/test_runner.gd`；运行完整 headless 测试，不追求低价值覆盖率。
- 每个 Task 完成后保留一个临时 Conventional Commit；最终评审通过后，把设计、计划和 Task 提交全部 squash 为单个 `feat: add runtime chunked zombie navigation` 提交。

---

## 文件结构

- Create: `scripts/navigation/navigation_bake_state.gd` — 纯状态机，管理排队、烘焙、版本失效、stale 和失败状态。
- Create: `scripts/navigation/navigation_chunk_3d.gd` — 收集静态碰撞源，创建候选网格并调用 `NavigationServer3D` 烘焙。
- Create: `scripts/navigation/navigation_world_manager.gd` — 注册、注销、标脏和查询当前世界的导航区块。
- Create: `scenes/navigation/NavigationChunk3D.tscn` — 可复用区块场景，包含活动 `NavigationRegion3D`。
- Create: `tests/unit/test_navigation_bake_state.gd` — 状态机核心生命周期测试。
- Create: `tests/unit/test_navigation_chunk_3d.gd` — 网格配置和同步烘焙测试。
- Create: `tests/unit/test_navigation_world_manager.gd` — 注册、重复 ID、转发和注销测试。
- Create: `tests/integration/test_demo_navigation.gd` — DemoArena 导航节点、来源分组和僵尸 agent 场景契约。
- Modify: `scripts/combat/zombie_behavior_math.gd` — 增加隔障碍攻击门禁和路径方向速度计算。
- Modify: `scripts/combat/zombie_target.gd` — 接入 agent、路径刷新、不可达处理和攻击遮挡射线。
- Modify: `scripts/gameplay/demo_arena.gd` — 监听区块失败并复用 `WaveStatus` 报告。
- Modify: `scenes/targets/ZombieTarget.tscn` — 增加关闭 avoidance 的 `NavigationAgent3D`。
- Modify: `scenes/gameplay/DemoArena.tscn` — 增加管理器、区块并标记导航源静态碰撞体。
- Modify: `tests/unit/test_zombie_behavior_math.gd` — 覆盖路径转向和隔障碍状态。
- Modify: `tests/unit/test_zombie_behavior.gd` — 保留无导航直线降级契约，并验证 agent 配置。
- Modify: `tests/integration/test_demo_scene.gd` — 保留现有 Demo 契约并补充导航失败信号绑定。
- Modify: `tests/test_runner.gd` — 注册四个新增测试文件。

---

### Task 1: 建立可测试的导航烘焙状态机

**Files:**
- Create: `scripts/navigation/navigation_bake_state.gd`
- Create: `tests/unit/test_navigation_bake_state.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: 无。
- Produces: `NavigationBakeState.Status`、`queue_bake() -> bool`、`begin_bake() -> int`、`is_active_generation(generation: int) -> bool`、`complete_success(generation: int) -> bool`、`complete_failure(generation: int, message: String) -> bool`、`invalidate() -> void`、`snapshot() -> Dictionary`。

- [ ] **Step 1: 写失败测试，固定排队、合并、补烘焙和失败语义**

在 `tests/unit/test_navigation_bake_state.gd` 创建：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const NavigationBakeState = preload("res://scripts/navigation/navigation_bake_state.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var state := NavigationBakeState.new()

	_append(failures, Assertions.expect_true(state.queue_bake(), "First request schedules work"))
	_append(failures, Assertions.expect_true(not state.queue_bake(), "Queued requests merge"))
	_append(failures, Assertions.expect_equal(
		state.status,
		NavigationBakeState.Status.QUEUED,
		"Merged request stays queued"
	))

	var first_generation := state.begin_bake()
	_append(failures, Assertions.expect_true(first_generation > 0, "Queued bake starts"))
	_append(failures, Assertions.expect_true(
		state.is_active_generation(first_generation),
		"Started generation becomes active"
	))
	_append(failures, Assertions.expect_true(
		not state.queue_bake(),
		"Request during bake does not start concurrent work"
	))
	_append(failures, Assertions.expect_true(
		state.complete_success(first_generation),
		"Active generation can complete"
	))
	_append(failures, Assertions.expect_equal(
		state.status,
		NavigationBakeState.Status.QUEUED,
		"Dirty-during-bake schedules one follow-up"
	))
	_append(failures, Assertions.expect_true(state.has_usable_mesh, "Success records usable mesh"))
	_append(failures, Assertions.expect_true(state.is_stale, "Old mesh is stale before follow-up"))

	var second_generation := state.begin_bake()
	_append(failures, Assertions.expect_true(
		state.complete_failure(second_generation, "synthetic failure"),
		"Active failure is accepted"
	))
	_append(failures, Assertions.expect_equal(
		state.status,
		NavigationBakeState.Status.READY,
		"Rebake failure keeps old mesh ready"
	))
	_append(failures, Assertions.expect_true(state.is_stale, "Failed rebake leaves stale mesh"))
	_append(failures, Assertions.expect_equal(
		state.last_error,
		"synthetic failure",
		"Failure reason is retained"
	))

	var stale_generation := second_generation
	state.queue_bake()
	var current_generation := state.begin_bake()
	_append(failures, Assertions.expect_true(
		not state.complete_success(stale_generation),
		"Outdated callback cannot replace current work"
	))
	state.invalidate()
	_append(failures, Assertions.expect_true(
		not state.complete_success(current_generation),
		"Invalidation rejects in-flight callbacks"
	))

	var initial_failure := NavigationBakeState.new()
	initial_failure.queue_bake()
	var initial_generation := initial_failure.begin_bake()
	initial_failure.complete_failure(initial_generation, "no geometry")
	_append(failures, Assertions.expect_equal(
		initial_failure.status,
		NavigationBakeState.Status.FAILED,
		"Initial failure has no ready fallback"
	))
	_append(failures, Assertions.expect_true(
		not initial_failure.has_usable_mesh,
		"Initial failure has no usable mesh"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在 `tests/test_runner.gd` 的导航相关测试位置加入：

```gdscript
	"res://tests/unit/test_navigation_bake_state.gd",
```

- [ ] **Step 2: 运行测试确认因脚本缺失而失败**

Run: `./tests/run_tests.sh`

Expected: FAIL，报告无法加载 `res://scripts/navigation/navigation_bake_state.gd`。

- [ ] **Step 3: 实现最小纯状态机**

创建 `scripts/navigation/navigation_bake_state.gd`：

```gdscript
extends RefCounted
class_name NavigationBakeState

enum Status {
	UNBAKED,
	QUEUED,
	BAKING,
	READY,
	FAILED,
}

var status := Status.UNBAKED
var requested_generation := 0
var active_generation := 0
var has_usable_mesh := false
var is_stale := false
var pending_after_active := false
var last_error := ""

func queue_bake() -> bool:
	requested_generation += 1
	if has_usable_mesh:
		is_stale = true
	match status:
		Status.QUEUED:
			return false
		Status.BAKING:
			pending_after_active = true
			return false
		_:
			status = Status.QUEUED
			return true

func begin_bake() -> int:
	if status != Status.QUEUED:
		return 0
	status = Status.BAKING
	active_generation = requested_generation
	pending_after_active = false
	return active_generation

func is_active_generation(generation: int) -> bool:
	return status == Status.BAKING and generation == active_generation

func complete_success(generation: int) -> bool:
	if not is_active_generation(generation):
		return false
	has_usable_mesh = true
	last_error = ""
	if pending_after_active or requested_generation > generation:
		status = Status.QUEUED
		is_stale = true
		pending_after_active = false
	else:
		status = Status.READY
		is_stale = false
	return true

func complete_failure(generation: int, message: String) -> bool:
	if not is_active_generation(generation):
		return false
	last_error = message
	if pending_after_active or requested_generation > generation:
		status = Status.QUEUED
		pending_after_active = false
		is_stale = has_usable_mesh
	else:
		status = Status.READY if has_usable_mesh else Status.FAILED
		is_stale = has_usable_mesh
	return true

func invalidate() -> void:
	requested_generation += 1
	active_generation = 0
	pending_after_active = false
	status = Status.UNBAKED
	has_usable_mesh = false
	is_stale = false
	last_error = ""

func snapshot() -> Dictionary:
	return {
		"status": status,
		"requested_generation": requested_generation,
		"active_generation": active_generation,
		"has_usable_mesh": has_usable_mesh,
		"is_stale": is_stale,
		"last_error": last_error,
	}
```

- [ ] **Step 4: 运行状态机测试和导入检查**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`

Expected: exit code 0，并生成对应 `.uid`。

Run: `./tests/run_tests.sh`

Expected: PASS。

- [ ] **Step 5: 提交 Task 1**

```bash
git add scripts/navigation/navigation_bake_state.gd scripts/navigation/navigation_bake_state.gd.uid tests/unit/test_navigation_bake_state.gd tests/unit/test_navigation_bake_state.gd.uid tests/test_runner.gd
git commit -m "feat: add navigation bake lifecycle state"
```

---

### Task 2: 实现可复用的运行时导航区块

**Files:**
- Create: `scripts/navigation/navigation_chunk_3d.gd`
- Create: `scenes/navigation/NavigationChunk3D.tscn`
- Create: `tests/unit/test_navigation_chunk_3d.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: `NavigationBakeState` 的全部 Task 1 接口。
- Produces: `NavigationChunk3D.request_rebake() -> void`、`mark_dirty() -> void`、`invalidate_pending_bakes() -> void`、`set_registered(value: bool) -> void`、`contains_global_position(world_position: Vector3) -> bool`、`get_state_snapshot() -> Dictionary`；信号 `bake_started(chunk_id, generation)`、`bake_succeeded(chunk_id, generation)`、`bake_failed(chunk_id, generation, message)`。

- [ ] **Step 1: 写失败测试，固定网格配置和同步烘焙契约**

创建 `tests/unit/test_navigation_chunk_3d.gd`，测试包含以下完整断言：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/navigation/NavigationChunk3D.tscn") as PackedScene
	_append(failures, Assertions.expect_true(packed != null, "Navigation chunk scene loads"))
	if packed == null:
		return failures

	var chunk := packed.instantiate() as NavigationChunk3D
	chunk.chunk_id = &"test_chunk"
	chunk.source_group_name = &"navigation_source"
	chunk.baking_bounds = AABB(Vector3(-5.0, -1.0, -5.0), Vector3(10.0, 3.0, 10.0))
	chunk.threaded_baking = false
	var navigation_mesh := chunk.call("_create_navigation_mesh") as NavigationMesh
	_append(failures, Assertions.expect_true(navigation_mesh != null, "Chunk creates navigation mesh"))
	if navigation_mesh != null:
		_append(failures, Assertions.expect_equal(
			navigation_mesh.geometry_parsed_geometry_type,
			NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS,
			"Chunk parses only static colliders"
		))
		_append(failures, Assertions.expect_equal(
			navigation_mesh.geometry_source_geometry_mode,
			NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN,
			"Chunk parses the configured source group"
		))
		_append(failures, Assertions.expect_equal(
			navigation_mesh.geometry_source_group_name,
			&"navigation_source",
			"Chunk uses the navigation source group"
		))
		_append(failures, Assertions.expect_float_near(
			navigation_mesh.agent_radius, 0.60, 0.0001, "Chunk reserves zombie clearance"
		))
		_append(failures, Assertions.expect_float_near(
			navigation_mesh.agent_height, 1.90, 0.0001, "Chunk matches zombie height"
		))
		_append(failures, Assertions.expect_float_near(
			navigation_mesh.cell_size, 0.20, 0.0001, "Chunk uses voxel-aligned cell size"
		))
		_append(failures, Assertions.expect_float_near(
			navigation_mesh.cell_height, 0.10, 0.0001, "Chunk uses shared map cell height"
		))
		_append(failures, Assertions.expect_true(
			navigation_mesh.filter_baking_aabb == chunk.baking_bounds,
			"Chunk filters baking to its AABB"
		))

	var host := Node3D.new()
	var ground := StaticBody3D.new()
	ground.add_to_group(&"navigation_source")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10.0, 0.2, 10.0)
	shape.position.y = -0.1
	shape.shape = box
	ground.add_child(shape)
	host.add_child(ground)
	chunk.source_root_path = NodePath("..")
	host.add_child(chunk)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(host)
	chunk.request_rebake()
	chunk.call("_start_queued_bake")
	var snapshot := chunk.get_state_snapshot()
	var region := chunk.get_node("NavigationRegion3D") as NavigationRegion3D
	_append(failures, Assertions.expect_true(
		bool(snapshot.get("has_usable_mesh", false)),
		"Synchronous test bake produces usable data"
	))
	_append(failures, Assertions.expect_true(
		region.navigation_mesh != null and region.navigation_mesh.get_polygon_count() > 0,
		"Synchronous test bake commits a non-empty mesh"
	))
	host.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在 `tests/test_runner.gd` 加入：

```gdscript
	"res://tests/unit/test_navigation_chunk_3d.gd",
```

- [ ] **Step 2: 运行测试确认区块场景缺失**

Run: `./tests/run_tests.sh`

Expected: FAIL，无法加载 `NavigationChunk3D.tscn`。

- [ ] **Step 3: 创建可复用区块场景**

创建 `scenes/navigation/NavigationChunk3D.tscn`：

```ini
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/navigation/navigation_chunk_3d.gd" id="1_chunk"]

[node name="NavigationChunk3D" type="Node3D"]
script = ExtResource("1_chunk")

[node name="NavigationRegion3D" type="NavigationRegion3D" parent="."]
enabled = false
top_level = true
use_edge_connections = true
navigation_layers = 1
```

- [ ] **Step 4: 实现候选网格解析、同步/异步烘焙与成功后替换**

创建 `scripts/navigation/navigation_chunk_3d.gd`，使用以下接口和控制流：

```gdscript
extends Node3D
class_name NavigationChunk3D

const NavigationBakeState = preload("res://scripts/navigation/navigation_bake_state.gd")

signal bake_started(chunk_id: StringName, generation: int)
signal bake_succeeded(chunk_id: StringName, generation: int)
signal bake_failed(chunk_id: StringName, generation: int, message: String)

@export var chunk_id: StringName
@export var source_root_path: NodePath
@export var source_group_name: StringName = &"navigation_source"
@export var baking_bounds := AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 2.0, 2.0))
@export var threaded_baking := true
@export var agent_radius := 0.60
@export var agent_height := 1.90
@export var cell_size := 0.20
@export var cell_height := 0.10
@export var border_size := 0.60

@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D

var bake_state := NavigationBakeState.new()

func request_rebake() -> void:
	if bake_state.queue_bake():
		call_deferred("_start_queued_bake")

func mark_dirty() -> void:
	request_rebake()

func invalidate_pending_bakes() -> void:
	bake_state.invalidate()

func set_registered(value: bool) -> void:
	if navigation_region != null:
		navigation_region.enabled = value

func contains_global_position(world_position: Vector3) -> bool:
	var source_root := get_node_or_null(source_root_path) as Node3D
	return (
		source_root != null and
		baking_bounds.has_point(source_root.to_local(world_position))
	)

func get_state_snapshot() -> Dictionary:
	return bake_state.snapshot()

func _start_queued_bake() -> void:
	if bake_state.status != NavigationBakeState.Status.QUEUED:
		return
	var validation_error := _validation_error()
	var generation := bake_state.begin_bake()
	if not validation_error.is_empty():
		_finish_failure(generation, validation_error)
		return
	bake_started.emit(chunk_id, generation)
	var candidate := _create_navigation_mesh()
	var source_data := NavigationMeshSourceGeometryData3D.new()
	var source_root := get_node(source_root_path) as Node3D
	navigation_region.global_transform = source_root.global_transform
	NavigationServer3D.parse_source_geometry_data(
		candidate,
		source_data,
		source_root,
		Callable(self, "_on_source_geometry_parsed").bind(
			generation,
			candidate,
			source_data
		)
	)

func _validation_error() -> String:
	if chunk_id.is_empty():
		return "Navigation chunk id is empty"
	if source_root_path.is_empty() or not get_node_or_null(source_root_path) is Node3D:
		return "Navigation source root is missing for %s" % chunk_id
	if baking_bounds.size.x <= 0.0 or baking_bounds.size.y <= 0.0 or baking_bounds.size.z <= 0.0:
		return "Navigation baking bounds are invalid for %s" % chunk_id
	if navigation_region == null:
		return "Navigation region is missing for %s" % chunk_id
	return ""

func _create_navigation_mesh() -> NavigationMesh:
	var navigation_mesh := NavigationMesh.new()
	navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	navigation_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	navigation_mesh.geometry_source_group_name = source_group_name
	navigation_mesh.filter_baking_aabb = baking_bounds
	navigation_mesh.agent_radius = agent_radius
	navigation_mesh.agent_height = agent_height
	navigation_mesh.cell_size = cell_size
	navigation_mesh.cell_height = cell_height
	navigation_mesh.border_size = border_size
	return navigation_mesh

func _on_source_geometry_parsed(
	generation: int,
	candidate: NavigationMesh,
	source_data: NavigationMeshSourceGeometryData3D
) -> void:
	if not bake_state.is_active_generation(generation):
		return
	if not source_data.has_data():
		_finish_failure(generation, "Navigation source geometry is empty for %s" % chunk_id)
		return
	var callback := Callable(self, "_on_navigation_mesh_baked").bind(generation, candidate)
	if threaded_baking:
		NavigationServer3D.bake_from_source_geometry_data_async(candidate, source_data, callback)
	else:
		NavigationServer3D.bake_from_source_geometry_data(candidate, source_data, callback)

func _on_navigation_mesh_baked(generation: int, candidate: NavigationMesh) -> void:
	if not bake_state.is_active_generation(generation):
		return
	if candidate.get_polygon_count() <= 0:
		_finish_failure(generation, "Navigation bake produced no polygons for %s" % chunk_id)
		return
	navigation_region.navigation_mesh = candidate
	if not bake_state.complete_success(generation):
		return
	bake_succeeded.emit(chunk_id, generation)
	_start_follow_up_if_queued()

func _finish_failure(generation: int, message: String) -> void:
	if not bake_state.complete_failure(generation, message):
		return
	push_warning(message)
	bake_failed.emit(chunk_id, generation, message)
	_start_follow_up_if_queued()

func _start_follow_up_if_queued() -> void:
	if bake_state.status == NavigationBakeState.Status.QUEUED:
		call_deferred("_start_queued_bake")
```

候选 `NavigationMesh` 必须在成功前与活动 `NavigationRegion3D.navigation_mesh` 分离，确保重烘焙期间旧网格持续可用。

- [ ] **Step 5: 运行同步烘焙测试、完整测试与导入检查**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`

Expected: exit code 0，无导航属性或回调签名解析错误。

Run: `./tests/run_tests.sh`

Expected: PASS；同步测试网格 polygon count 大于 0。

- [ ] **Step 6: 提交 Task 2**

```bash
git add scripts/navigation/navigation_chunk_3d.gd scripts/navigation/navigation_chunk_3d.gd.uid scenes/navigation/NavigationChunk3D.tscn tests/unit/test_navigation_chunk_3d.gd tests/unit/test_navigation_chunk_3d.gd.uid tests/test_runner.gd
git commit -m "feat: add runtime navigation chunks"
```

---

### Task 3: 添加场景级导航管理器并接入 DemoArena

**Files:**
- Create: `scripts/navigation/navigation_world_manager.gd`
- Create: `tests/unit/test_navigation_world_manager.gd`
- Create: `tests/integration/test_demo_navigation.gd`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `tests/integration/test_demo_scene.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: `NavigationChunk3D` 的 Task 2 接口和三个烘焙信号。
- Produces: `NavigationWorldManager.register_chunk(chunk: NavigationChunk3D) -> bool`、`unregister_chunk(chunk_id: StringName) -> bool`、`mark_chunk_dirty(chunk_id: StringName) -> bool`、`request_rebake(chunk_id: StringName) -> bool`、`get_chunk_state(chunk_id: StringName) -> Dictionary`、`is_navigation_ready_at(world_position: Vector3) -> bool`；信号 `chunk_bake_started`、`chunk_ready`、`chunk_bake_failed`。

- [ ] **Step 1: 写失败测试，固定管理器注册和转发接口**

创建 `tests/unit/test_navigation_world_manager.gd`：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var manager := NavigationWorldManager.new()
	var first := NavigationChunk3D.new()
	first.chunk_id = &"arena"
	var duplicate := NavigationChunk3D.new()
	duplicate.chunk_id = &"arena"

	_append(failures, Assertions.expect_true(manager.register_chunk(first), "Manager registers chunk"))
	_append(failures, Assertions.expect_true(
		not manager.register_chunk(duplicate),
		"Manager rejects duplicate chunk id"
	))
	_append(failures, Assertions.expect_true(
		manager.get_chunk_state(&"arena").has("status"),
		"Manager exposes registered chunk state"
	))
	_append(failures, Assertions.expect_true(
		not manager.is_navigation_ready_at(Vector3.ZERO),
		"Queued chunk is not reported ready"
	))
	_append(failures, Assertions.expect_true(
		manager.mark_chunk_dirty(&"arena"),
		"Manager forwards dirty request"
	))
	_append(failures, Assertions.expect_true(
		not manager.mark_chunk_dirty(&"missing"),
		"Manager rejects unknown dirty request"
	))
	_append(failures, Assertions.expect_true(
		manager.unregister_chunk(&"arena"),
		"Manager unregisters chunk"
	))
	_append(failures, Assertions.expect_true(
		manager.get_chunk_state(&"arena").is_empty(),
		"Unregistered state is removed"
	))
	first.free()
	duplicate.free()
	manager.free()
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

创建 `tests/integration/test_demo_navigation.gd`，实例化 DemoArena 后断言：

```gdscript
var manager := arena.get_node_or_null("World/Navigation") as NavigationWorldManager
var chunk := arena.get_node_or_null("World/Navigation/DemoArenaChunk") as NavigationChunk3D
_append(failures, Assertions.expect_true(manager != null, "Demo owns scene navigation manager"))
_append(failures, Assertions.expect_true(
	chunk != null and chunk.chunk_id == &"demo_arena",
	"Demo registers one named navigation chunk"
))
_append(failures, Assertions.expect_true(
	chunk != null and chunk.threaded_baking,
	"Demo uses threaded runtime baking"
))
var navigation_map := manager.get_world_3d().navigation_map if manager != null else RID()
_append(failures, Assertions.expect_float_near(
	NavigationServer3D.map_get_cell_size(navigation_map) if navigation_map.is_valid() else -1.0,
	0.20,
	0.0001,
	"Demo navigation map shares chunk cell size"
))
_append(failures, Assertions.expect_float_near(
	NavigationServer3D.map_get_cell_height(navigation_map) if navigation_map.is_valid() else -1.0,
	0.10,
	0.0001,
	"Demo navigation map shares chunk cell height"
))
for path in [
	"World/Ground",
	"World/Boundaries/North",
	"World/Boundaries/South",
	"World/Boundaries/West",
	"World/Boundaries/East",
	"World/Props/PickupCollision",
	"World/Props/ContainerACollision",
	"World/Props/ContainerBCollision",
]:
	var source := arena.get_node_or_null(path)
	_append(failures, Assertions.expect_true(
		source != null and source.is_in_group(&"navigation_source"),
		"Demo navigation source is tagged: %s" % path
	))
for path in [
	"World/Props/PickupVisual",
	"World/Props/ContainerAVisual",
	"World/Props/ContainerBVisual",
]:
	var visual := arena.get_node_or_null(path)
	_append(failures, Assertions.expect_true(
		visual != null and not visual.is_in_group(&"navigation_source"),
		"Visual model is excluded from baking: %s" % path
	))
```

将两个测试路径加入 `tests/test_runner.gd`。

- [ ] **Step 2: 运行测试确认管理器和 Demo 节点缺失**

Run: `./tests/run_tests.sh`

Expected: FAIL，缺少 `NavigationWorldManager` 和 Demo 导航节点。

- [ ] **Step 3: 实现场景级管理器**

创建 `scripts/navigation/navigation_world_manager.gd`：

```gdscript
extends Node3D
class_name NavigationWorldManager

signal chunk_bake_started(chunk_id: StringName, generation: int)
signal chunk_ready(chunk_id: StringName, generation: int)
signal chunk_bake_failed(chunk_id: StringName, generation: int, message: String)

@export var map_cell_size := 0.20
@export var map_cell_height := 0.10

var chunks: Dictionary = {}

func _enter_tree() -> void:
	_configure_navigation_map()
	if not child_entered_tree.is_connected(_on_child_entered_tree):
		child_entered_tree.connect(_on_child_entered_tree)
	if not child_exiting_tree.is_connected(_on_child_exiting_tree):
		child_exiting_tree.connect(_on_child_exiting_tree)

func _ready() -> void:
	for child in get_children():
		if child is NavigationChunk3D:
			register_chunk(child as NavigationChunk3D)

func register_chunk(chunk: NavigationChunk3D) -> bool:
	if chunk == null or chunk.chunk_id.is_empty():
		push_warning("Cannot register navigation chunk without an id")
		return false
	if (
		not is_equal_approx(chunk.cell_size, map_cell_size) or
		not is_equal_approx(chunk.cell_height, map_cell_height)
	):
		push_warning("Navigation chunk voxel settings do not match shared map: %s" % chunk.chunk_id)
		return false
	if chunks.has(chunk.chunk_id):
		if chunks[chunk.chunk_id] == chunk:
			return true
		push_warning("Duplicate navigation chunk id: %s" % chunk.chunk_id)
		return false
	chunks[chunk.chunk_id] = chunk
	chunk.set_registered(true)
	chunk.bake_started.connect(_on_chunk_bake_started)
	chunk.bake_succeeded.connect(_on_chunk_bake_succeeded)
	chunk.bake_failed.connect(_on_chunk_bake_failed)
	chunk.request_rebake()
	return true

func unregister_chunk(chunk_id: StringName) -> bool:
	var chunk := chunks.get(chunk_id) as NavigationChunk3D
	if chunk == null:
		return false
	chunk.invalidate_pending_bakes()
	chunk.set_registered(false)
	if chunk.bake_started.is_connected(_on_chunk_bake_started):
		chunk.bake_started.disconnect(_on_chunk_bake_started)
	if chunk.bake_succeeded.is_connected(_on_chunk_bake_succeeded):
		chunk.bake_succeeded.disconnect(_on_chunk_bake_succeeded)
	if chunk.bake_failed.is_connected(_on_chunk_bake_failed):
		chunk.bake_failed.disconnect(_on_chunk_bake_failed)
	chunks.erase(chunk_id)
	return true

func mark_chunk_dirty(chunk_id: StringName) -> bool:
	var chunk := chunks.get(chunk_id) as NavigationChunk3D
	if chunk == null:
		return false
	chunk.mark_dirty()
	return true

func request_rebake(chunk_id: StringName) -> bool:
	var chunk := chunks.get(chunk_id) as NavigationChunk3D
	if chunk == null:
		return false
	chunk.request_rebake()
	return true

func get_chunk_state(chunk_id: StringName) -> Dictionary:
	var chunk := chunks.get(chunk_id) as NavigationChunk3D
	return {} if chunk == null else chunk.get_state_snapshot()

func is_navigation_ready_at(world_position: Vector3) -> bool:
	for chunk_value in chunks.values():
		var chunk := chunk_value as NavigationChunk3D
		if chunk == null or not chunk.contains_global_position(world_position):
			continue
		if bool(chunk.get_state_snapshot().get("has_usable_mesh", false)):
			return true
	return false

func _configure_navigation_map() -> void:
	var world := get_world_3d()
	if world == null or not world.navigation_map.is_valid():
		return
	NavigationServer3D.map_set_cell_size(world.navigation_map, map_cell_size)
	NavigationServer3D.map_set_cell_height(world.navigation_map, map_cell_height)

func _on_child_entered_tree(child: Node) -> void:
	if child is NavigationChunk3D:
		register_chunk(child as NavigationChunk3D)

func _on_child_exiting_tree(child: Node) -> void:
	if child is NavigationChunk3D:
		unregister_chunk((child as NavigationChunk3D).chunk_id)

func _on_chunk_bake_started(chunk_id: StringName, generation: int) -> void:
	chunk_bake_started.emit(chunk_id, generation)

func _on_chunk_bake_succeeded(chunk_id: StringName, generation: int) -> void:
	chunk_ready.emit(chunk_id, generation)

func _on_chunk_bake_failed(chunk_id: StringName, generation: int, message: String) -> void:
	chunk_bake_failed.emit(chunk_id, generation, message)
```

`register_chunk()` 已明确处理 `_ready()` 与 `child_entered_tree` 的同实例重复注册；只有相同 ID 指向不同实例时才警告失败。显式注销会关闭 region，避免节点仍留在树中时继续贡献导航数据。

- [ ] **Step 4: 把一个运行时区块接入 DemoArena**

在 `scenes/gameplay/DemoArena.tscn`：

1. 增加 manager script 与 chunk scene ext_resource。
2. 在 `World` 下增加：

```ini
[node name="Navigation" type="Node3D" parent="World"]
script = ExtResource("navigation_manager_script")

[node name="DemoArenaChunk" parent="World/Navigation" instance=ExtResource("navigation_chunk_scene")]
chunk_id = &"demo_arena"
source_root_path = NodePath("../..")
baking_bounds = AABB(-22.25, -0.5, -17.25, 44.5, 4, 34.5)
threaded_baking = true
```

3. 给 `World/Ground`、四个 `World/Boundaries/*`、`PickupCollision`、`ContainerACollision`、`ContainerBCollision` 的现有 groups 数组加入 `"navigation_source"`。
4. 不给三个视觉实例加入该 group。

在 `scripts/gameplay/demo_arena.gd` 的 `_wire_dependencies()` 中连接：

```gdscript
var navigation_manager := get_node_or_null("World/Navigation") as NavigationWorldManager
if (
	navigation_manager != null and
	not navigation_manager.chunk_bake_failed.is_connected(_on_navigation_chunk_bake_failed)
):
	navigation_manager.chunk_bake_failed.connect(_on_navigation_chunk_bake_failed)
```

增加：

```gdscript
func _on_navigation_chunk_bake_failed(
	chunk_id: StringName,
	_generation: int,
	message: String
) -> void:
	push_warning("Navigation chunk %s failed: %s" % [chunk_id, message])
	_show_wave_status("NAVIGATION FAILED: %s" % chunk_id)
```

更新 `tests/integration/test_demo_scene.gd`，断言 manager 的失败信号已经连接到 arena。僵尸 manager 注入依赖 Task 4 才产生的 setter，因此放到 Task 4 实现和断言。

- [ ] **Step 5: 运行管理器、Demo 契约和完整测试**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`

Expected: exit code 0，场景资源路径和 AABB 语法有效。

Run: `./tests/run_tests.sh`

Expected: PASS；现有波次仍在场景加入树时立即生成 4–8 只僵尸。

- [ ] **Step 6: 提交 Task 3**

```bash
git add scripts/navigation/navigation_world_manager.gd scripts/navigation/navigation_world_manager.gd.uid scripts/gameplay/demo_arena.gd scenes/gameplay/DemoArena.tscn tests/unit/test_navigation_world_manager.gd tests/unit/test_navigation_world_manager.gd.uid tests/integration/test_demo_navigation.gd tests/integration/test_demo_navigation.gd.uid tests/integration/test_demo_scene.gd tests/test_runner.gd
git commit -m "feat: manage demo navigation chunks"
```

---

### Task 4: 让僵尸追击和游荡使用导航路径

**Files:**
- Modify: `scripts/combat/zombie_behavior_math.gd`
- Modify: `scripts/combat/zombie_target.gd`
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scenes/targets/ZombieTarget.tscn`
- Modify: `tests/unit/test_zombie_behavior_math.gd`
- Modify: `tests/unit/test_zombie_behavior.gd`
- Modify: `tests/integration/test_demo_navigation.gd`

**Interfaces:**
- Consumes: 当前 `ZombieBehaviorMath.State`、`arrive_velocity()`、`NavigationWorldManager.is_navigation_ready_at()`、`NavigationAgent3D.get_navigation_map()`、`NavigationServer3D.map_get_iteration_id()`、`get_next_path_position()` 和 `is_navigation_finished()`。
- Produces: `ZombieBehaviorMath.next_state(..., attack_path_clear: bool = true) -> int`、`path_velocity(...) -> Vector3`、`ZombieTarget.set_navigation_manager(manager: NavigationWorldManager) -> void`；`ZombieTarget` 内部的导航目标刷新、首次降级、不可达停止和世界障碍射线。

- [ ] **Step 1: 写失败测试，固定路径方向和隔障碍攻击规则**

在 `tests/unit/test_zombie_behavior_math.gd` 增加：

```gdscript
_append(failures, Assertions.expect_equal(
	ZombieBehaviorMath.next_state(
		ZombieBehaviorMath.State.AWARE_APPROACH,
		1.0,
		true,
		7.0,
		1.0,
		1.45,
		false
	),
	ZombieBehaviorMath.State.AWARE_APPROACH,
	"Blocked attack range keeps zombie approaching"
))
_append(failures, Assertions.expect_vector3_near(
	ZombieBehaviorMath.path_velocity(
		Vector3.ZERO,
		Vector3(0.0, 0.0, -2.0),
		Vector3(4.0, 0.0, 0.0),
		1.45,
		1.30,
		1.50
	),
	Vector3(0.0, 0.0, -1.30),
	0.0001,
	"Path point controls direction while logical target controls speed"
))
_append(failures, Assertions.expect_vector3_near(
	ZombieBehaviorMath.path_velocity(
		Vector3.ZERO,
		Vector3.ZERO,
		Vector3(4.0, 0.0, 0.0),
		1.45,
		1.30,
		1.50
	),
	Vector3.ZERO,
	0.0001,
	"Missing next path point produces no navigation velocity"
))
```

在 `tests/unit/test_zombie_behavior.gd` 增加 agent 场景断言：

```gdscript
var navigation_agent := zombie.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
_append(failures, Assertions.expect_true(
	navigation_agent != null and not navigation_agent.avoidance_enabled,
	"Zombie owns navigation agent with avoidance disabled"
))
```

在 `tests/integration/test_demo_navigation.gd` 对初始波次每只僵尸重复相同 agent 断言，并增加：

```gdscript
_append(failures, Assertions.expect_true(
	zombie.navigation_manager == manager,
	"Demo injects scene navigation manager into wave zombie"
))
```

- [ ] **Step 2: 运行测试确认路径 API 和 agent 节点缺失**

Run: `./tests/run_tests.sh`

Expected: FAIL，`path_velocity` 不存在且 Zombie 场景没有 agent。

- [ ] **Step 3: 扩展纯行为数学**

把 `ZombieBehaviorMath.next_state()` 的末尾参数改为：

```gdscript
	attack_range: float,
	attack_path_clear: bool = true
) -> int:
```

把攻击判断改为：

```gdscript
if distance <= maxf(attack_range, 0.0) and attack_path_clear:
	return State.ATTACK
```

在 `zombie_behavior_math.gd` 增加：

```gdscript
static func path_velocity(
	from_position: Vector3,
	next_path_position: Vector3,
	logical_target_position: Vector3,
	stop_range: float,
	move_speed: float,
	slow_radius: float
) -> Vector3:
	var path_offset := next_path_position - from_position
	path_offset.y = 0.0
	if path_offset.length_squared() <= 0.0001:
		return Vector3.ZERO
	var logical_offset := logical_target_position - from_position
	logical_offset.y = 0.0
	var gap := logical_offset.length() - maxf(stop_range, 0.0)
	if gap <= 0.0:
		return Vector3.ZERO
	var speed_factor := clampf(gap / maxf(slow_radius, 0.01), 0.25, 1.0)
	return path_offset.normalized() * maxf(move_speed, 0.0) * speed_factor
```

- [ ] **Step 4: 在 ZombieTarget 场景加入关闭 avoidance 的 agent**

在 `scenes/targets/ZombieTarget.tscn` 增加：

```ini
[node name="NavigationAgent3D" type="NavigationAgent3D" parent="."]
path_desired_distance = 0.35
target_desired_distance = 0.25
avoidance_enabled = false
navigation_layers = 1
```

- [ ] **Step 5: 用 agent 路径点替换追击和游荡直线方向**

在 `scripts/combat/zombie_target.gd` 增加：

```gdscript
@export_group("Navigation")
@export var navigation_target_refresh_distance := 0.35
@export_flags_3d_physics var attack_obstacle_mask := 1

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D

var has_navigation_target := false
var last_navigation_target := Vector3.ZERO
var navigation_manager: NavigationWorldManager
```

增加以下内部方法：

```gdscript
func set_navigation_manager(manager: NavigationWorldManager) -> void:
	navigation_manager = manager

func _navigation_is_ready() -> bool:
	if (
		navigation_agent == null or
		navigation_manager == null or
		not is_instance_valid(navigation_manager) or
		not navigation_manager.is_navigation_ready_at(global_position)
	):
		return false
	var navigation_map := navigation_agent.get_navigation_map()
	return (
		navigation_map.is_valid() and
		NavigationServer3D.map_get_iteration_id(navigation_map) > 0
	)

func _refresh_navigation_target(target_position: Vector3) -> void:
	if (
		not has_navigation_target or
		Vector2(last_navigation_target.x, last_navigation_target.z).distance_to(
			Vector2(target_position.x, target_position.z)
		) >= navigation_target_refresh_distance
	):
		navigation_agent.target_position = target_position
		last_navigation_target = target_position
		has_navigation_target = true

func _navigation_velocity(
	target_position: Vector3,
	stop_range: float,
	move_speed: float,
	slow_radius: float
) -> Vector3:
	if not _navigation_is_ready():
		has_navigation_target = false
		return ZombieBehaviorMath.arrive_velocity(
			global_position,
			target_position,
			stop_range,
			move_speed,
			slow_radius
		)
	_refresh_navigation_target(target_position)
	var next_path_position := navigation_agent.get_next_path_position()
	if navigation_agent.is_navigation_finished():
		return Vector3.ZERO
	return ZombieBehaviorMath.path_velocity(
		global_position,
		next_path_position,
		target_position,
		stop_range,
		move_speed,
		slow_radius
	)

func _attack_path_is_clear() -> bool:
	if not _target_is_alive() or get_world_3d() == null:
		return false
	var origin := global_position + Vector3.UP * 0.90
	var destination := attack_target.global_position + Vector3.UP * 0.90
	var query := PhysicsRayQueryParameters3D.create(
		origin,
		destination,
		attack_obstacle_mask,
		[get_rid()]
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()
```

在 `scripts/gameplay/demo_arena.gd` 的 `_wire_target()` 中注入 Task 3 已存在的场景级 manager：

```gdscript
var navigation_manager := get_node_or_null("World/Navigation") as NavigationWorldManager
if navigation_manager != null:
	zombie.set_navigation_manager(navigation_manager)
```

在 `_physics_process()` 中先计算：

```gdscript
var attack_path_clear := (
	target_alive and
	distance_to_target <= attack_range and
	_attack_path_is_clear()
)
```

然后把 `attack_path_clear` 作为 `ZombieBehaviorMath.next_state()` 的最后参数。

把 `AWARE_APPROACH` 的直线 `arrive_velocity()` 替换为：

```gdscript
target_planar_velocity = _navigation_velocity(
	attack_target.global_position,
	attack_range,
	perception_move_speed,
	perception_slow_radius
)
```

把 `_wander_velocity()` 的目标速度计算替换为：

```gdscript
var offset := _navigation_velocity(
	wander_target,
	wander_arrive_range,
	wander_speed,
	0.8
)
if offset == Vector3.ZERO:
	var navigation_done := (
		_navigation_is_ready() and
		has_navigation_target and
		navigation_agent.is_navigation_finished()
	)
	var direct_done := (
		not _navigation_is_ready() and
		global_position.distance_to(wander_target) <= wander_arrive_range
	)
	if navigation_done or direct_done:
		wander_pause_remaining = wander_rng.randf_range(wander_pause_min, wander_pause_max)
		has_navigation_target = false
return offset
```

进入 `ATTACK`、目标死亡或僵尸死亡时把 `has_navigation_target` 设为 `false`。导航已经 ready 后，`is_navigation_finished()` 返回 true 时保持零速度，不调用直线降级。

- [ ] **Step 6: 保留现有行为并运行全部测试**

Run: `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`

Expected: exit code 0，无 `NavigationAgent3D` 类型或物理查询解析错误。

Run: `./tests/run_tests.sh`

Expected: PASS；原有感知、攻击 windup、取消攻击、难度速度、波次和血迹测试继续通过。

- [ ] **Step 7: 提交 Task 4**

```bash
git add scripts/combat/zombie_behavior_math.gd scripts/combat/zombie_target.gd scripts/gameplay/demo_arena.gd scenes/targets/ZombieTarget.tscn tests/unit/test_zombie_behavior_math.gd tests/unit/test_zombie_behavior.gd tests/integration/test_demo_navigation.gd
git commit -m "feat: navigate zombie pursuit and wandering"
```

---

### Task 5: 完成运行时验证、风险评审与单提交整理

**Files:**
- Review: `scripts/navigation/navigation_bake_state.gd`
- Review: `scripts/navigation/navigation_chunk_3d.gd`
- Review: `scripts/navigation/navigation_world_manager.gd`
- Review: `scripts/combat/zombie_behavior_math.gd`
- Review: `scripts/combat/zombie_target.gd`
- Review: `scenes/navigation/NavigationChunk3D.tscn`
- Review: `scenes/gameplay/DemoArena.tscn`
- Review: `scenes/targets/ZombieTarget.tscn`
- Review: `tests/unit/test_navigation_bake_state.gd`
- Review: `tests/unit/test_navigation_chunk_3d.gd`
- Review: `tests/unit/test_navigation_world_manager.gd`
- Review: `tests/integration/test_demo_navigation.gd`
- Review: `docs/superpowers/specs/2026-08-06-runtime-chunked-zombie-navigation-design.md`
- Review: `AGENTS.md`

**Interfaces:**
- Consumes: Task 1–4 的最终导航管理、烘焙和僵尸行为接口。
- Produces: 一个通过自动验证、具备人工验收步骤且已 squash 的计划提交。

- [ ] **Step 1: 执行静态导入和完整测试**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh
git diff --check main...HEAD
```

Expected: 所有命令 exit code 0；Godot 输出不含 `SCRIPT ERROR:`、`Parse Error:` 或运行时 `ERROR:`。

- [ ] **Step 2: 执行 DemoArena 后台烘焙 Smoke Test**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
	--headless \
	--path . \
	scenes/gameplay/DemoArena.tscn \
	--quit-after 180
```

Expected: DemoArena 运行约 180 帧后正常退出；初始波次立即生成；日志不出现空导航源、零 polygon、重复区块 ID、并发烘焙或无效回调错误。

- [ ] **Step 3: 做源码级最终评审**

逐项确认：

- 活动 `NavigationRegion3D.navigation_mesh` 只在候选网格成功后替换。
- `threaded_baking=true` 是 DemoArena 默认值，测试才使用同步模式。
- 同一区块 BAKING 时只记录一次补烘焙，不产生并发任务。
- 注销会使 in-flight generation 失效。
- 所有区块共享默认 `World3D` 导航地图，没有独立 map RID。
- 视觉 GLTF 不在 `navigation_source` group。
- 仅首次 map iteration 为 0 时使用直线降级。
- map iteration 有效后，finished/unreachable 目标返回零速度或重新游荡，不直线撞墙。
- 攻击射线只使用 world mask 1，不把其他僵尸视为遮挡物。
- avoidance 保持关闭。
- 没有实现建筑破坏、动态加载或随机地图生成。

- [ ] **Step 4: 准备人工验收说明**

向用户提供以下精确操作，并要求提供一张能看见玩家、障碍物和绕行僵尸的截图以便分析：

1. 从主菜单进入 DemoArena。
2. 先站到车辆与出生僵尸相反的一侧，观察至少一只僵尸绕过车头或车尾。
3. 分别在两个集装箱背面重复操作。
4. 紧贴集装箱另一侧，确认僵尸不会隔箱挥拳并造成伤害。
5. 不主动接近僵尸，观察游荡僵尸遇到集装箱时是否改道。
6. 连续按 T 或点击刷新按钮直至 24 只，观察是否出现明显停顿或报错。

- [ ] **Step 5: 将临时 Task commits squash 为一个计划提交**

先记录功能分支相对 `main` 的 merge base，确认工作区干净，然后把设计、计划和 Task 1–4 的临时提交全部整理为一个提交。最终提交主题必须是：

```text
feat: add runtime chunked zombie navigation
```

整理后运行：

```bash
git status --short
git log --oneline main..HEAD
```

Expected: 工作区干净；`git log --oneline main..HEAD` 只显示一个 `feat: add runtime chunked zombie navigation` 提交，该提交同时包含已批准的设计文档、中文实现计划和功能实现。

---

## 规格覆盖自检

- 单张 DemoArena 运行时导航：Tasks 2–4。
- 多区块管理入口：Tasks 1–3。
- 异步烘焙、请求合并、旧网格保留、stale 和版本失效：Tasks 1–3。
- 追击与游荡导航：Task 4。
- 初次不等待与短暂直线降级：Task 4。
- 导航 ready 后不可达不撞墙：Task 4。
- 隔障碍不攻击：Task 4。
- avoidance 默认关闭：Tasks 4–5。
- 简化静态碰撞源、不解析视觉模型：Tasks 2–3。
- 未来建筑破坏只通过 `mark_chunk_dirty()` 接入：Task 3。
- 自动测试、headless smoke 和人工验收：Task 5。
- 不实现无限地图、动态分块加载或建筑破坏系统：Global Constraints 与 Task 5 最终评审。
