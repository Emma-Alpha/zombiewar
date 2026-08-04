# Demo 随机僵尸波次与死亡重开 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 DemoArena 的 4 只固定僵尸改为四角随机波次，支持玩家存活时按 T 追加一波、死亡后按 R 完整重开 demo。

**Architecture:** 波次生命周期继续由 DemoArena 管理，复用 World/Targets 的动态子节点绑定，不新增通用 WaveManager。DemoArena 使用可固定种子的 RandomNumberGenerator 在四个 Marker3D 周围生成 ZombieTarget，并通过场景重载完成死亡重开，避免扩展 PlayerController 的复活状态机。

**Tech Stack:** Godot 4.7.1、GDScript、Jolt Physics、现有 RefCounted 自定义 headless 测试运行器。

## Global Constraints

- 只修改当前 demo，不加入自动下一波、波次难度成长、经验、掉落、对象池、导航网格或移动端 T/R 按钮。
- 第一波在 DemoArena._ready() 自动生成。
- 四个角落每角随机 1～2 只，正常每波总计 4～8 只。
- 场上最多保留 24 个仍位于 World/Targets 下的 ZombieTarget；死亡动画尚未结束的僵尸仍计入上限。
- 动态僵尸的 perception_range 固定覆盖为 60.0，其他生命、速度、攻击、动画和血迹参数继续使用现有实现。
- spawn_wave 绑定 KEY_T；restart_demo 绑定 KEY_R。
- T 只在玩家存活时追加，不替换已有僵尸；R 只在玩家死亡后重载当前场景。
- 保留当前工作区所有未提交的模块化武器、移动端控制和测试改动，尤其是 project.godot、scripts/gameplay/demo_arena.gd、scenes/gameplay/DemoArena.tscn 与 tests/integration/test_demo_scene.gd 中的现有差异。
- 使用 GDScript tab 缩进，并为新增公开方法和关键集合补充类型。
- 每个行为先写失败测试并确认 RED，再实现最小代码并确认 GREEN。
- 本计划共 3 个 task；单独 task 不创建提交，全部执行完成后由用户自行提交。
- 默认直接在当前工作区执行。当前未提交改动与本功能重叠，不建议使用隔离 worktree。

---

## 文件职责映射

- project.godot：声明 spawn_wave 与 restart_demo 两个输入动作。
- scripts/gameplay/demo_arena.gd：维护随机数、波次编号、数量上限、动态生成、输入状态和 HUD。
- scenes/gameplay/DemoArena.tscn：移除静态僵尸，提供四角 Marker3D、波次提示标签和提示计时器。
- tests/unit/test_project_contract.gd：锁定 T/R 的 InputMap 契约。
- tests/integration/test_demo_wave_spawning.gd：验证初始随机波次、四角覆盖、间距、追击绑定、追加波次与 24 只上限。
- tests/integration/test_demo_wave_controls.gd：验证 T/R 状态门槛、HUD 文案、上限提示和重开请求。
- tests/integration/test_demo_scene.gd：把旧的“固定 4 只、感知范围 7 米”断言更新为动态波次契约，继续覆盖现有玩家、武器、相机、攻击和血迹接线。
- tests/test_runner.gd：注册两个新增集成测试。

---

### Task 1: 建立 T/R 输入契约

**Files:**
- Modify: project.godot
- Modify: tests/unit/test_project_contract.gd

**Interfaces:**
- Consumes: Godot InputMap 与现有 REQUIRED_ACTIONS、REQUIRED_KEY_BINDINGS 测试结构。
- Produces: 输入动作 spawn_wave -> KEY_T，restart_demo -> KEY_R，供 Task 3 的 DemoArena._unhandled_input(event: InputEvent) 使用。

- [ ] **Step 1: 扩展项目契约测试**

在 tests/unit/test_project_contract.gd 的 REQUIRED_ACTIONS 末尾加入：

~~~gdscript
	&"spawn_wave",
	&"restart_demo",
~~~

在 REQUIRED_KEY_BINDINGS 末尾加入：

~~~gdscript
	&"spawn_wave": KEY_T,
	&"restart_demo": KEY_R,
~~~

不要改变现有移动、攻击和武器槽位动作的名称或按键。

- [ ] **Step 2: 运行测试确认输入动作尚不存在**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
~~~

Expected: FAIL，test_project_contract.gd 报告 Missing input action: spawn_wave 和 Missing input action: restart_demo；现有测试不得出现新的解析错误。

- [ ] **Step 3: 在 InputMap 中加入精确按键**

在 project.godot 的 [input] 段、weapon_slot_4 后加入：

~~~ini
spawn_wave={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":84,"physical_keycode":0,"key_label":0,"unicode":116,"location":0,"echo":false,"script":null)
]
}
restart_demo={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":82,"physical_keycode":0,"key_label":0,"unicode":114,"location":0,"echo":false,"script":null)
]
}
~~~

保留当前 primary_attack 和 weapon_pistol、weapon_rifle、weapon_knife、weapon_slot_4 配置。

- [ ] **Step 4: 运行完整测试确认输入契约恢复 GREEN**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
~~~

Expected: test_project_contract.gd 通过；若其他测试仍失败，只允许是当前工作区原本存在且与本 task 无关的失败，必须记录并在继续前定位。

---

### Task 2: 实现四角随机波次与数量上限

**Files:**
- Create: tests/integration/test_demo_wave_spawning.gd
- Modify: tests/test_runner.gd
- Modify: scripts/gameplay/demo_arena.gd
- Modify: scenes/gameplay/DemoArena.tscn
- Modify: tests/integration/test_demo_scene.gd

**Interfaces:**
- Consumes: res://scenes/targets/ZombieTarget.tscn、World/Targets、ZombieTarget.set_attack_target(player)、ZombieDifficultyProfile。
- Produces:
  - DemoArena.spawn_wave() -> int：尝试追加一波并返回实际生成数量。
  - DemoArena.get_active_zombie_count() -> int：只统计 World/Targets 下的 ZombieTarget。
  - 属性 wave_number: int、player_defeated: bool、random_seed: int。
  - 场景路径 World/SpawnPoints/{NorthWest,NorthEast,SouthWest,SouthEast}。

- [ ] **Step 1: 写随机波次集成测试**

创建 tests/integration/test_demo_wave_spawning.gd：

~~~gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const SPAWN_POINT_NAMES: Array[StringName] = [
	&"NorthWest",
	&"NorthEast",
	&"SouthWest",
	&"SouthEast",
]

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Wave test loads DemoArena"
	))
	if packed == null:
		return failures

	var arena := packed.instantiate()
	arena.set("random_seed", 20260805)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)

	var targets := arena.get_node_or_null("World/Targets")
	var spawn_root := arena.get_node_or_null("World/SpawnPoints")
	var player := arena.get_node_or_null("Player")
	var initial_zombies := _get_zombies(targets)

	_append(failures, Assertions.expect_true(
		spawn_root != null,
		"Demo exposes four-corner spawn points"
	))
	_append(failures, Assertions.expect_true(
		initial_zombies.size() >= 4 and initial_zombies.size() <= 8,
		"Initial wave contains four to eight zombies"
	))
	_append(failures, Assertions.expect_equal(
		int(arena.get("wave_number")),
		1,
		"Initial wave increments the wave number"
	))

	var corner_counts: Dictionary = {}
	for point_name in SPAWN_POINT_NAMES:
		corner_counts[point_name] = 0

	for zombie in initial_zombies:
		var nearest_name := _nearest_spawn_name(zombie, spawn_root)
		corner_counts[nearest_name] = int(corner_counts[nearest_name]) + 1
		var marker := spawn_root.get_node(String(nearest_name)) as Marker3D
		_append(failures, Assertions.expect_true(
			_planar_distance(zombie.global_position, marker.global_position) <= 1.751,
			"Zombie stays inside its corner spawn radius"
		))
		_append(failures, Assertions.expect_float_near(
			zombie.perception_range,
			60.0,
			0.0001,
			"Wave zombie detects the player across the arena"
		))
		_append(failures, Assertions.expect_true(
			zombie.attack_target == player,
			"Wave zombie targets the arena player"
		))

	for point_name in SPAWN_POINT_NAMES:
		_append(failures, Assertions.expect_true(
			int(corner_counts[point_name]) >= 1,
			"Every corner contributes at least one zombie: %s" % point_name
		))

	for first_index in range(initial_zombies.size()):
		for second_index in range(first_index + 1, initial_zombies.size()):
			_append(failures, Assertions.expect_true(
				_planar_distance(
					initial_zombies[first_index].global_position,
					initial_zombies[second_index].global_position
				) >= 1.099,
				"Initial wave zombies keep minimum horizontal spacing"
			))

	var initial_count := initial_zombies.size()
	var appended := int(arena.call("spawn_wave"))
	_append(failures, Assertions.expect_true(
		appended > 0,
		"Manual wave request creates zombies while capacity remains"
	))
	_append(failures, Assertions.expect_equal(
		int(arena.call("get_active_zombie_count")),
		initial_count + appended,
		"Active count follows the appended wave"
	))
	_append(failures, Assertions.expect_equal(
		int(arena.get("wave_number")),
		2,
		"Successful manual wave increments the wave number"
	))

	for _index in range(8):
		arena.call("spawn_wave")
	_append(failures, Assertions.expect_equal(
		int(arena.call("get_active_zombie_count")),
		24,
		"Repeated wave requests stop at the active-zombie cap"
	))
	_append(failures, Assertions.expect_equal(
		int(arena.call("spawn_wave")),
		0,
		"A full arena rejects another wave"
	))

	arena.free()
	return failures

func _get_zombies(targets: Node) -> Array[ZombieTarget]:
	var zombies: Array[ZombieTarget] = []
	if targets == null:
		return zombies
	for child in targets.get_children():
		if child is ZombieTarget:
			zombies.append(child as ZombieTarget)
	return zombies

func _nearest_spawn_name(zombie: ZombieTarget, spawn_root: Node) -> StringName:
	var nearest_name := StringName()
	var nearest_distance := INF
	for point_name in SPAWN_POINT_NAMES:
		var marker := spawn_root.get_node(String(point_name)) as Marker3D
		var distance := _planar_distance(
			zombie.global_position,
			marker.global_position
		)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_name = point_name
	return nearest_name

func _planar_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.x, first.z).distance_to(Vector2(second.x, second.z))

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
~~~

在 tests/test_runner.gd 的集成测试区域、test_demo_scene.gd 后加入：

~~~gdscript
	"res://tests/integration/test_demo_wave_spawning.gd",
~~~

- [ ] **Step 2: 运行测试确认缺少动态波次接口**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
~~~

Expected: FAIL。新测试应报告缺少 SpawnPoints、wave_number、spawn_wave 或 get_active_zombie_count；旧 test_demo_scene.gd 仍按当前静态四只契约运行。

- [ ] **Step 3: 把场景改为动态目标容器和四角刷新点**

在 scenes/gameplay/DemoArena.tscn 中：

1. 保留 ZombieTarget 的 ext_resource，因为运行时脚本仍预加载同一场景。
2. 删除 World/Targets 下 ZombieTarget1～ZombieTarget4 四个实例。
3. 保留空的 World/Targets 节点。
4. 在 World/Targets 后加入以下节点：

~~~ini
[node name="SpawnPoints" type="Node3D" parent="World"]

[node name="NorthWest" type="Marker3D" parent="World/SpawnPoints"]
position = Vector3(-17, 0, -12)

[node name="NorthEast" type="Marker3D" parent="World/SpawnPoints"]
position = Vector3(17, 0, -12)

[node name="SouthWest" type="Marker3D" parent="World/SpawnPoints"]
position = Vector3(-17, 0, 12)

[node name="SouthEast" type="Marker3D" parent="World/SpawnPoints"]
position = Vector3(17, 0, 12)
~~~

这些坐标与边界至少保留 3 米中心距离，1.75 米随机半径不会穿过场地边界，也不会与现有车辆和集装箱刷新区域重叠。

- [ ] **Step 4: 在 DemoArena 中加入波次配置和初始化**

在 scripts/gameplay/demo_arena.gd 顶部现有 preload 后加入：

~~~gdscript
const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")
const SPAWN_POINT_NAMES: Array[StringName] = [
	&"NorthWest",
	&"NorthEast",
	&"SouthWest",
	&"SouthEast",
]

@export_group("Wave Spawning")
@export_range(1, 8, 1) var minimum_zombies_per_corner := 1
@export_range(1, 8, 1) var maximum_zombies_per_corner := 2
@export_range(4, 128, 1) var maximum_active_zombies := 24
@export_range(0.0, 8.0, 0.05) var spawn_radius := 1.75
@export_range(0.0, 4.0, 0.05) var minimum_spawn_spacing := 1.1
@export_range(1.0, 100.0, 0.5) var wave_perception_range := 60.0
@export var random_seed: int = 0
~~~

在现有 tween 状态后加入：

~~~gdscript
var wave_rng := RandomNumberGenerator.new()
var wave_number := 0
var player_defeated := false
~~~

新增 _ready()：

~~~gdscript
func _ready() -> void:
	if random_seed == 0:
		wave_rng.randomize()
	else:
		wave_rng.seed = random_seed
	spawn_wave()
~~~

在 _wire_dependencies() 取得 targets 后，保留现有 child_entered_tree 连接，并补充退出监听：

~~~gdscript
		if not targets.child_exiting_tree.is_connected(_on_target_exiting_tree):
			targets.child_exiting_tree.connect(_on_target_exiting_tree)
~~~

- [ ] **Step 5: 实现动态生成、间距、计数和 HUD 刷新**

在 scripts/gameplay/demo_arena.gd 加入以下完整方法：

~~~gdscript
func spawn_wave() -> int:
	if player_defeated:
		return 0
	var targets := get_node_or_null("World/Targets") as Node3D
	if targets == null:
		_report_wave_problem("MISSING TARGET CONTAINER")
		return 0
	var spawn_points := _get_spawn_points()
	if spawn_points.size() != SPAWN_POINT_NAMES.size():
		_report_wave_problem("MISSING CORNER SPAWN POINT")
		return 0

	var remaining_capacity := maximum_active_zombies - get_active_zombie_count()
	if remaining_capacity <= 0:
		_show_wave_status("MAX ZOMBIES: %d" % maximum_active_zombies)
		return 0

	var occupied_positions := _collect_zombie_positions()
	var spawned := 0
	var next_wave_number := wave_number + 1
	for marker in spawn_points:
		var requested := wave_rng.randi_range(
			minimum_zombies_per_corner,
			maximum_zombies_per_corner
		)
		for _index in range(requested):
			if spawned >= remaining_capacity:
				break
			var spawn_position := _sample_spawn_position(
				marker.global_position,
				occupied_positions
			)
			var zombie := ZOMBIE_SCENE.instantiate() as ZombieTarget
			if zombie == null:
				_report_wave_problem("FAILED TO CREATE ZOMBIE")
				return spawned
			zombie.name = "Wave%02dZombie%02d" % [
				next_wave_number,
				spawned + 1,
			]
			zombie.perception_range = wave_perception_range
			zombie.position = targets.to_local(spawn_position)
			targets.add_child(zombie)
			occupied_positions.append(spawn_position)
			spawned += 1
		if spawned >= remaining_capacity:
			break

	if spawned > 0:
		wave_number = next_wave_number
	_update_wave_hud()
	return spawned

func get_active_zombie_count() -> int:
	var targets := get_node_or_null("World/Targets")
	if targets == null:
		return 0
	var count := 0
	for child in targets.get_children():
		if child is ZombieTarget:
			count += 1
	return count

func _get_spawn_points() -> Array[Marker3D]:
	var points: Array[Marker3D] = []
	for point_name in SPAWN_POINT_NAMES:
		var marker := get_node_or_null(
			"World/SpawnPoints/%s" % String(point_name)
		) as Marker3D
		if marker == null:
			return []
		points.append(marker)
	return points

func _collect_zombie_positions() -> Array[Vector3]:
	var positions: Array[Vector3] = []
	var targets := get_node_or_null("World/Targets")
	if targets == null:
		return positions
	for child in targets.get_children():
		if child is ZombieTarget:
			positions.append((child as ZombieTarget).global_position)
	return positions

func _sample_spawn_position(
	center: Vector3,
	occupied_positions: Array[Vector3]
) -> Vector3:
	var fallback := center
	for _attempt in range(16):
		var angle := wave_rng.randf_range(0.0, TAU)
		var radius := sqrt(wave_rng.randf()) * spawn_radius
		var candidate := center + Vector3(
			cos(angle) * radius,
			0.0,
			sin(angle) * radius
		)
		fallback = candidate
		if _has_spawn_clearance(candidate, occupied_positions):
			return candidate
	return fallback

func _has_spawn_clearance(
	candidate: Vector3,
	occupied_positions: Array[Vector3]
) -> bool:
	for occupied in occupied_positions:
		if Vector2(candidate.x, candidate.z).distance_to(
			Vector2(occupied.x, occupied.z)
		) < minimum_spawn_spacing:
			return false
	return true

func _on_target_exiting_tree(target: Node) -> void:
	if target is ZombieTarget:
		call_deferred("_update_wave_hud")

func _update_wave_hud() -> void:
	var objective := get_node_or_null("HUD/Objective") as Label
	if objective == null:
		return
	var active_count := get_active_zombie_count()
	if player_defeated:
		objective.text = "FINAL WAVE %d    ZOMBIES %d" % [
			wave_number,
			active_count,
		]
	else:
		objective.text = "WAVE %d    ALIVE %d    T: NEW WAVE" % [
			wave_number,
			active_count,
		]

func _show_wave_status(message: String) -> void:
	var label := get_node_or_null("HUD/WaveStatus") as Label
	if label == null:
		return
	label.text = message
	label.visible = true
	var timer := get_node_or_null("WaveStatusTimer") as Timer
	if timer != null:
		timer.start()

func _hide_wave_status() -> void:
	var label := get_node_or_null("HUD/WaveStatus") as Label
	if label != null:
		label.visible = false

func _report_wave_problem(message: String) -> void:
	push_warning(message)
	_show_wave_status(message)
~~~

注意：_sample_spawn_position 的 16 次尝试属于“尽量保持 1.1 米间距”；达到高密度时允许使用最后一次候选位置，不能因为找不到完美间距而阻止场上补足 24 只。

- [ ] **Step 6: 更新旧 Demo 集成测试的静态僵尸假设**

在 tests/integration/test_demo_scene.gd 中，在 arena 加入树前固定随机种子：

~~~gdscript
	var arena := packed.instantiate()
	arena.set("random_seed", 20260805)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)
~~~

取得 targets 后生成只包含 ZombieTarget 的集合：

~~~gdscript
	var zombies: Array[ZombieTarget] = []
	if targets != null:
		for child in targets.get_children():
			if child is ZombieTarget:
				zombies.append(child as ZombieTarget)
~~~

把旧的固定数量断言：

~~~gdscript
targets != null and targets.get_child_count() == 4
~~~

替换为：

~~~gdscript
targets != null and zombies.size() >= 4 and zombies.size() <= 8
~~~

断言消息改为 Demo starts with a four-to-eight zombie wave。

把原有 for target in targets.get_children() 改为：

~~~gdscript
	for target in zombies:
~~~

把感知范围期望从 7.0 改为 60.0，消息改为：

~~~gdscript
"Every wave zombie pursues across the arena"
~~~

保留对 perception_move_speed = 1.30、攻击参数、血迹信号、attack_target 和玩家受伤 HUD 的所有现有断言。

- [ ] **Step 7: 运行新增测试和完整套件**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
~~~

Expected: 新增 test_demo_wave_spawning.gd 通过；test_demo_scene.gd 不再依赖固定 4 只；全部现有测试通过。

---

### Task 3: 接入 T/R、死亡重开与 HUD 提示

**Files:**
- Create: tests/integration/test_demo_wave_controls.gd
- Modify: tests/test_runner.gd
- Modify: scripts/gameplay/demo_arena.gd
- Modify: scenes/gameplay/DemoArena.tscn
- Modify: tests/integration/test_demo_scene.gd

**Interfaces:**
- Consumes: Task 1 的 spawn_wave/restart_demo 动作，Task 2 的 spawn_wave()、get_active_zombie_count()、wave_number 与 player_defeated。
- Produces:
  - signal restart_requested。
  - DemoArena._unhandled_input(event: InputEvent)。
  - DemoArena._reload_current_scene() -> void。
  - HUD/Objective、HUD/WaveStatus、HUD/GameOver 与 WaveStatusTimer 的最终行为。

- [ ] **Step 1: 写 T/R 与 HUD 集成测试**

创建 tests/integration/test_demo_wave_controls.gd：

~~~gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_append(failures, Assertions.expect_true(
		packed != null,
		"Wave control test loads DemoArena"
	))
	if packed == null:
		return failures

	var arena := packed.instantiate()
	arena.set("random_seed", 20260805)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(arena)

	var player := arena.get_node_or_null("Player") as PlayerController
	var objective := arena.get_node_or_null("HUD/Objective") as Label
	var wave_status := arena.get_node_or_null("HUD/WaveStatus") as Label
	var game_over := arena.get_node_or_null("HUD/GameOver") as Label
	var controls := arena.get_node_or_null("HUD/ControlsPanel/Controls") as Label
	var restart_emissions := [0]
	if arena.has_signal("restart_requested"):
		arena.connect("restart_requested", func() -> void:
			restart_emissions[0] += 1
		)

	_append(failures, Assertions.expect_true(
		objective != null and
		objective.text.contains("WAVE 1") and
		objective.text.contains("T: NEW WAVE"),
		"Live HUD shows wave number and T help"
	))
	_append(failures, Assertions.expect_true(
		controls != null and
		controls.text.contains("T  WAVE") and
		controls.text.contains("R  RESTART"),
		"Desktop help documents wave and restart controls"
	))

	var before_t := int(arena.call("get_active_zombie_count"))
	arena.call("_unhandled_input", _pressed_action(&"spawn_wave"))
	var after_t := int(arena.call("get_active_zombie_count"))
	_append(failures, Assertions.expect_true(
		after_t > before_t,
		"T appends a wave while the player is alive"
	))

	arena.call("_unhandled_input", _pressed_action(&"restart_demo"))
	_append(failures, Assertions.expect_equal(
		restart_emissions[0],
		0,
		"R does nothing while the player is alive"
	))

	for _index in range(8):
		arena.call("spawn_wave")
	arena.call("_unhandled_input", _pressed_action(&"spawn_wave"))
	_append(failures, Assertions.expect_true(
		wave_status != null and
		wave_status.visible and
		wave_status.text == "MAX ZOMBIES: 24",
		"Full arena reports the zombie cap"
	))

	if player != null:
		player.apply_damage(1000.0, Vector3.ZERO)
	_append(failures, Assertions.expect_true(
		bool(arena.get("player_defeated")),
		"Lethal damage marks the arena defeated"
	))
	_append(failures, Assertions.expect_true(
		game_over != null and
		game_over.visible and
		game_over.text == "PLAYER DOWN\nPRESS R TO RESTART",
		"Death HUD explains the R restart"
	))
	_append(failures, Assertions.expect_true(
		objective != null and objective.text.contains("FINAL WAVE"),
		"Death HUD preserves final wave information"
	))

	var defeated_count := int(arena.call("get_active_zombie_count"))
	arena.call("_unhandled_input", _pressed_action(&"spawn_wave"))
	_append(failures, Assertions.expect_equal(
		int(arena.call("get_active_zombie_count")),
		defeated_count,
		"T is ignored after player death"
	))

	arena.call("_unhandled_input", _pressed_action(&"restart_demo"))
	_append(failures, Assertions.expect_equal(
		restart_emissions[0],
		1,
		"Dead-player R requests exactly one scene reload"
	))

	arena.free()
	return failures

func _pressed_action(action: StringName) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	return event

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
~~~

在 tests/test_runner.gd 的 test_demo_wave_spawning.gd 后加入：

~~~gdscript
	"res://tests/integration/test_demo_wave_controls.gd",
~~~

- [ ] **Step 2: 运行测试确认控制与 HUD 尚未完成**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
~~~

Expected: FAIL。缺少 restart_requested、WaveStatus、T/R 输入处理或新 HUD 文案；Task 1 和 Task 2 测试保持通过。

- [ ] **Step 3: 增加重开信号、输入门槛和延迟场景重载**

在 scripts/gameplay/demo_arena.gd 的 extends 后加入：

~~~gdscript
signal restart_requested
~~~

新增以下方法：

~~~gdscript
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).echo:
		return
	if event.is_action_pressed(&"spawn_wave"):
		spawn_wave()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"restart_demo") and player_defeated:
		restart_requested.emit()
		call_deferred("_reload_current_scene")
		get_viewport().set_input_as_handled()

func _reload_current_scene() -> void:
	var scene_tree := get_tree()
	if scene_tree != null:
		scene_tree.reload_current_scene()
~~~

使用 call_deferred() 的原因是避免在输入分发栈中直接销毁当前场景；测试在当前帧释放 arena 后，延迟调用不会重载测试运行器场景。

- [ ] **Step 4: 完成死亡状态和波次提示计时器接线**

在 _wire_dependencies() 中连接提示计时器：

~~~gdscript
	var status_timer := get_node_or_null("WaveStatusTimer") as Timer
	if (
		status_timer != null and
		not status_timer.timeout.is_connected(_hide_wave_status)
	):
		status_timer.timeout.connect(_hide_wave_status)
~~~

把 _on_player_died() 替换为：

~~~gdscript
func _on_player_died() -> void:
	if player_defeated:
		return
	player_defeated = true
	var game_over := get_node_or_null("HUD/GameOver") as Label
	if game_over != null:
		game_over.text = "PLAYER DOWN\nPRESS R TO RESTART"
		game_over.visible = true
	_update_wave_hud()
~~~

不要在死亡时清除已有僵尸、血迹或武器状态；这些状态由 R 重载场景时统一恢复。

- [ ] **Step 5: 更新 DemoArena HUD 节点和桌面帮助**

在 scenes/gameplay/DemoArena.tscn 中把 ControlsPanel 的 offset_right 扩展为：

~~~ini
offset_right = 920.0
~~~

把 HUD/Controls.text 改为：

~~~ini
text = "WASD  MOVE + FACE    SPACE  JUMP    J  FIRE    1-3  WEAPON    T  WAVE    R  RESTART"
~~~

把 HUD/GameOver.text 改为：

~~~ini
text = "PLAYER DOWN\nPRESS R TO RESTART"
~~~

并把 GameOver 的垂直范围扩大：

~~~ini
offset_top = -64.0
offset_bottom = 64.0
~~~

在 HUD/Objective 后加入：

~~~ini
[node name="WaveStatus" type="Label" parent="HUD"]
visible = false
anchors_preset = 1
anchor_left = 1.0
anchor_right = 1.0
offset_left = -448.0
offset_top = 54.0
offset_right = -24.0
offset_bottom = 82.0
grow_horizontal = 0
theme_override_colors/font_color = Color(1, 0.78, 0.26, 1)
theme_override_font_sizes/font_size = 18
text = ""
horizontal_alignment = 2
~~~

在场景根节点下加入：

~~~ini
[node name="WaveStatusTimer" type="Timer" parent="."]
wait_time = 1.2
one_shot = true
~~~

Objective 的场景默认文字改为：

~~~ini
text = "WAVE 0    ALIVE 0    T: NEW WAVE"
~~~

运行时 _ready() 生成第一波后会立即更新为实际波次和数量。

- [ ] **Step 6: 更新旧 Demo 场景测试的 HUD 文案**

在 tests/integration/test_demo_scene.gd 中，把桌面帮助的精确期望改为：

~~~gdscript
"WASD  MOVE + FACE    SPACE  JUMP    J  FIRE    1-3  WEAPON    T  WAVE    R  RESTART"
~~~

取得并断言新增节点：

~~~gdscript
	var wave_status := arena.get_node_or_null("HUD/WaveStatus") as Label
	var wave_status_timer := arena.get_node_or_null("WaveStatusTimer") as Timer
~~~

加入：

~~~gdscript
	_append(failures, Assertions.expect_true(
		wave_status != null and not wave_status.visible,
		"Wave status starts hidden"
	))
	_append(failures, Assertions.expect_true(
		wave_status_timer != null and
		wave_status_timer.one_shot and
		absf(wave_status_timer.wait_time - 1.2) <= 0.0001,
		"Wave status uses a short one-shot timer"
	))
~~~

把致死伤害后的 game-over 断言扩展为同时验证：

~~~gdscript
game_over.visible and game_over.text == "PLAYER DOWN\nPRESS R TO RESTART"
~~~

- [ ] **Step 7: 运行解析检查和完整自动测试**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
~~~

Expected: exit code 0；DemoArena.tscn、demo_arena.gd 和新增测试无解析、类型或资源导入错误。

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
~~~

Expected: 全部测试通过，输出 PASS，测试文件数比执行前增加 2。

- [ ] **Step 8: 进行一次可视化手动验收**

Run:

~~~bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
~~~

从主菜单进入 DemoArena，逐项确认：

1. 初始僵尸从四个角落内侧出现，每角至少一只，并主动向玩家靠近。
2. 连续按 T 会追加波次，右上角 WAVE 与 ALIVE 同步更新。
3. 连续按 T 直到 24 只后不再增加，并短暂显示 MAX ZOMBIES: 24。
4. 玩家死亡后 T 不再生成僵尸，中央显示 PLAYER DOWN / PRESS R TO RESTART。
5. 玩家存活时按 R 无效果；死亡后按 R 重载 demo，玩家满血、血迹清空、波次从 1 重新开始。
6. WASD、Space、J、1～3 武器切换和移动端按钮仍正常。

- [ ] **Step 9: 检查最终差异但不提交**

Run:

~~~bash
git diff --check
git status --short
~~~

Expected: git diff --check 无输出；状态只包含用户原有未提交改动和本计划涉及的输入、DemoArena、测试文件。不要执行 git add 或 git commit，由用户检查后自行提交。
