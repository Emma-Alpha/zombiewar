# 退役导航系统硬删除实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完整删除已退役的 Godot 内置导航、运行时异步烘焙及其遗留信号和场景分组，让确定性整数网格流场成为唯一僵尸导航路径。

**Architecture:** 先添加一个只扫描运行时代码、场景和 `AGENTS.md` 的旧符号验证闸门，使当前遗留实现产生稳定失败；再移除失效信号链并把相关验证改为检查真正的 `blocker_changed` 数据流；最后删除导航脚本、场景节点、资源和分组，更新项目约定并运行核心验证。历史设计文档不纳入旧符号扫描，以保留架构演进记录。

**Tech Stack:** Godot 4.7.1、GDScript、Godot `.tscn` 场景、现有 `tools/validation/` 无头验证脚本、Git。

## Global Constraints

- 僵尸导航只使用 `scripts/sim/flow_field_grid.gd` 与 `scripts/sim/flow_field.gd` 的确定性整数网格流场。
- 运行时代码不得调用 Godot 内置导航代理、导航服务器或异步导航烘焙。
- 动态静态障碍必须把世界 AABB 通过 `SimWorld.set_blocker_world_rect()` 写入流场阻挡网格；爆炸桶继续由 `SimWorld` 独占维护阻挡生命周期。
- 不修改 `FlowFieldGrid`、`FlowField` 的算法和参数。
- 不重构放置物、拾取箱或爆炸桶的模拟层协议。
- 不修改 `docs/superpowers/specs/` 和既有历史计划中的旧架构记录。
- 本任务属于低风险可回滚清理，只增加稳定的源码闸门并运行核心 Smoke Test，不编写与实现成本不相称的测试。
- 保留用户现有未跟踪文件，不暂存或提交 `scripts/menu/menu_entrance.gd.uid`。
- 所有实现 Task 和最终评审完成后，把本计划相关提交 squash 为一个 Conventional Commit。

---

## 文件结构与职责

- `tools/validation/validate_retired_navigation_removed.gd`：新增源码级闸门，只检查运行时代码、场景和当前项目约定中是否仍存在退役导航文件或符号。
- `tools/validation/validate_pickup_spawn_point.gd`：把旧导航几何通知断言改为拾取箱阻挡出现、消失及竞技场连接断言。
- `tools/validation/validate_random_pickup_drops.gd`：把一次性掉落的旧导航通知断言改为 `blocker_changed` 生命周期断言。
- `scripts/gameplay/demo_arena.gd`：删除旧管理器绑定和烘焙回调，只保留确定性流场阻挡连接。
- `scripts/gameplay/pickup_spawn_point.gd`：删除旧导航通知，保留 `blocker_changed` 和 `pickup_spawned`。
- `scripts/gameplay/random_pickup_drop_manager.gd`：删除旧导航通知转发。
- `scripts/gameplay/place_item_service.gd`：删除无人消费的 `placement_geometry_changed`，保留 `item_placed` 和 `item_removed`。
- `scripts/props/explosive_barrel.gd`：删除旧导航通知和旧分组操作，阻挡继续由模拟层负责。
- `scenes/gameplay/DemoArena.tscn`：删除 `World/Navigation` 子树及对应资源，清除旧导航源分组。
- `scenes/gameplay/PickupChest.tscn`、`scenes/props/*.tscn`：清除旧导航源分组，保留 `place_item_obstacle`。
- `scripts/navigation/*`、`scenes/navigation/NavigationChunk3D.tscn`：整组删除。
- `AGENTS.md`：把“退役但保留”改为“已经移除且禁止恢复”的当前约定。

---

### Task 1: 添加退役导航源码闸门

**Files:**
- Create: `tools/validation/validate_retired_navigation_removed.gd`
- Create: `tools/validation/validate_retired_navigation_removed.gd.uid`（由 Godot 导入生成；若无头导入未生成则不手工伪造）
- Include: `docs/superpowers/plans/2026-08-11-remove-retired-navigation.md`
- Reference: `docs/superpowers/specs/2026-08-11-remove-retired-navigation-design.md`

**Interfaces:**
- Consumes: `DirAccess.open(path: String)`、`FileAccess.open(path: String, mode_flags: FileAccess.ModeFlags)`、`FileAccess.file_exists(path: String)`。
- Produces: 无参数无头验证入口；成功打印 `validate_retired_navigation_removed: PASS` 并退出 0，失败对每个命中调用 `push_error()` 并退出 1。

- [ ] **Step 1: 创建会在当前代码上失败的源码闸门**

新增 `tools/validation/validate_retired_navigation_removed.gd`：

```gdscript
extends SceneTree

const REMOVED_PATHS: PackedStringArray = [
	"res://scripts/navigation/navigation_world_manager.gd",
	"res://scripts/navigation/navigation_chunk_3d.gd",
	"res://scripts/navigation/navigation_bake_state.gd",
	"res://scenes/navigation/NavigationChunk3D.tscn",
]

const SCAN_ROOTS: PackedStringArray = [
	"res://scripts",
	"res://scenes",
]

const SCAN_EXTENSIONS: PackedStringArray = ["gd", "tscn"]

const REMOVED_TOKENS: PackedStringArray = [
	"NavigationWorldManager",
	"NavigationChunk3D",
	"NavigationBakeState",
	"NavigationAgent3D",
	"NavigationServer3D",
	"NavigationRegion3D",
	"navigation_geometry_changed",
	"placement_geometry_changed",
	"navigation_source",
	"bake_from_source_geometry_data_async",
]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	for path in REMOVED_PATHS:
		if FileAccess.file_exists(path):
			failures.append("retired navigation file must be removed: %s" % path)
	var files: Array[String] = []
	for root_path in SCAN_ROOTS:
		_collect_files(root_path, files)
	files.append("res://AGENTS.md")
	files.sort()
	for path in files:
		_scan_file(path, failures)
	_finish(failures)

func _collect_files(path: String, files: Array[String]) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if not entry.begins_with("."):
			var child_path := path.path_join(entry)
			if directory.current_is_dir():
				_collect_files(child_path, files)
			elif entry.get_extension() in SCAN_EXTENSIONS:
				files.append(child_path)
		entry = directory.get_next()
	directory.list_dir_end()

func _scan_file(path: String, failures: Array[String]) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("unable to read navigation scan target: %s" % path)
		return
	var source := file.get_as_text()
	for token in REMOVED_TOKENS:
		if source.contains(token):
			failures.append("%s still contains retired navigation token %s" % [path, token])

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_retired_navigation_removed: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
```

- [ ] **Step 2: 运行闸门并确认它捕获当前遗留实现**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_retired_navigation_removed.gd
```

Expected: 退出码 1；输出至少包含 `navigation_world_manager.gd`、`DemoArena.tscn`、`navigation_geometry_changed` 和 `navigation_source` 的失败信息。

- [ ] **Step 3: 运行格式检查**

Run:

```bash
git diff --check -- tools/validation/validate_retired_navigation_removed.gd
```

Expected: 无输出，退出码 0。

- [ ] **Step 4: 提交失败闸门**

```bash
git add docs/superpowers/plans/2026-08-11-remove-retired-navigation.md \
  tools/validation/validate_retired_navigation_removed.gd
if test -f tools/validation/validate_retired_navigation_removed.gd.uid; then
  git add tools/validation/validate_retired_navigation_removed.gd.uid
fi
git commit -m "test: guard against retired navigation code"
```

如果 `.uid` 尚未生成，则只暂存 `.gd`；不得创建空 UID 文件。

---

### Task 2: 删除旧通知链并强化有效阻挡验证

**Files:**
- Modify: `scripts/gameplay/demo_arena.gd:570-585, 925-999, 1113-1126`
- Modify: `scripts/gameplay/pickup_spawn_point.gd:4-7, 45-69`
- Modify: `scripts/gameplay/random_pickup_drop_manager.gd:4-27`
- Modify: `scripts/gameplay/place_item_service.gd:4-11, 50-74`
- Modify: `scripts/props/explosive_barrel.gd:4-24, 83-93`
- Modify: `tools/validation/validate_pickup_spawn_point.gd:85-270`
- Modify: `tools/validation/validate_random_pickup_drops.gd:85-120`

**Interfaces:**
- Consumes: `PickupSpawnPoint.blocker_changed(world_aabb: AABB, blocked: bool)`、`PickupSpawnPoint.pickup_spawned(pickup: PickupChest)`、`PlaceItemService.item_placed(item: Node3D)`、`PlaceItemService.item_removed(item: Node3D, world_aabb: AABB)`。
- Produces: `DemoArena._on_pickup_blocker_changed(world_aabb: AABB, blocked: bool)` 继续把拾取箱变化路由到 `SimWorld.set_blocker_world_rect()`；不再产生或消费任何旧导航几何通知。

- [ ] **Step 1: 把拾取箱生命周期测试改为检查实际阻挡事件**

在 `_test_spawn_and_respawn_lifecycle()` 中，用事件数组替换 `geometry_changes`：

```gdscript
	var blocker_events: Array[Dictionary] = []
	spawner.blocker_changed.connect(
		func(world_aabb: AABB, blocked: bool) -> void:
			blocker_events.append({
				"world_aabb": world_aabb,
				"blocked": blocked,
			})
	)
```

把四次旧计数断言分别替换为：

```gdscript
	var initial_bounds := AABB()
	if not blocker_events.is_empty():
		initial_bounds = blocker_events[0]["world_aabb"]
	_expect(
		blocker_events.size() == 1
		and bool(blocker_events[0]["blocked"])
		and initial_bounds.size != Vector3.ZERO,
		"initial pickup insertion must publish one non-empty blocker rect",
		failures
	)
```

```gdscript
	_expect(
		blocker_events.size() == 1,
		"collection must not clear the blocker before the pickup exits",
		failures
	)
```

```gdscript
	_expect(
		blocker_events.size() == 2 and not bool(blocker_events[1]["blocked"]),
		"pickup tree exit must clear its blocker rect",
		failures
	)
```

```gdscript
	_expect(
		blocker_events.size() == 3 and bool(blocker_events[2]["blocked"]),
		"replacement pickup insertion must publish its blocker rect",
		failures
	)
```

```gdscript
	_expect(
		blocker_events.size() == 4 and not bool(blocker_events[3]["blocked"]),
		"external pickup removal must clear its blocker rect",
		failures
	)
```

在 `_test_demo_pickup_spawner_wiring()` 中删除 `_on_runtime_navigation_geometry_changed` 的 `Callable`，改为：

```gdscript
		var blocker_callback := Callable(arena, "_on_pickup_blocker_changed")
```

并断言：

```gdscript
			_expect(
				spawner.blocker_changed.is_connected(blocker_callback),
				"%s must notify DemoArena flow-field blocker updates" % spawner_name,
				failures
			)
```

- [ ] **Step 2: 把一次性随机掉落测试改为检查阻挡出现和清除**

在 `_test_one_shot_spawn_point_reclaims_after_success()` 中，用以下代码替换旧导航计数：

```gdscript
	var blocker_states: Array[bool] = []
	spawner.blocker_changed.connect(
		func(_world_aabb: AABB, blocked: bool) -> void:
			blocker_states.append(blocked)
	)
```

释放后断言：

```gdscript
	_expect(
		blocker_states == [true, false],
		"one-shot pickup must publish blocker insertion then removal",
		failures
	)
```

- [ ] **Step 3: 删除生产代码中的旧通知声明和发射**

执行以下最小删除：

- `PickupSpawnPoint` 删除 `signal navigation_geometry_changed` 及生成、离场时的两次 `.emit()`；保留 `blocker_changed` 的时序不变。
- `RandomPickupDropManager` 删除同名信号，并删除新生成 spawner 到该信号的转发连接。
- `PlaceItemService` 删除 `signal placement_geometry_changed` 和放置、离场时的两次 `.emit()`；保留 `item_placed`、`item_removed` 的发射顺序不变。
- `ExplosiveBarrel` 删除旧信号、注释中的“离场时广播导航几何变化”、`remove_from_group()` 和旧信号发射；`queue_free()` 保持在爆炸表现结尾。

- [ ] **Step 4: 删除 DemoArena 对旧通知链的消费**

从 `demo_arena.gd` 删除：

```gdscript
func _wire_explosive_barrel(barrel: Node) -> void:
	...
```

从 `_wire_dependencies()` 删除：

- `World/Navigation` 管理器查询和 `chunk_bake_failed` 连接。
- `ExplosiveBarrels` 子树的旧通知连接循环和 `child_entered_tree` 连接。
- 每个 `PickupSpawnPoint.navigation_geometry_changed` 连接。
- `RandomPickupDropManager.navigation_geometry_changed` 连接块。
- `PlaceItemService.placement_geometry_changed` 连接。

保留以下连接：

```gdscript
spawner.blocker_changed.connect(_on_pickup_blocker_changed)
spawner.pickup_spawned.connect(_register_chest)
place_item_service.item_placed.connect(_on_item_placed)
place_item_service.item_removed.connect(_on_item_removed)
```

删除以下函数：

```gdscript
func _on_navigation_chunk_bake_failed(
	chunk_id: StringName,
	_generation: int,
	message: String
) -> void:
	...

func _on_runtime_navigation_geometry_changed() -> void:
	...
```

- [ ] **Step 5: 运行聚焦验证**

Run:

```bash
for script in validate_pickup_spawn_point validate_random_pickup_drops; do
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script "res://tools/validation/${script}.gd" || exit 1
done
```

Expected: 两个脚本分别打印对应的 `PASS`，退出码均为 0。

- [ ] **Step 6: 确认源码闸门仍因尚未删除的场景和脚本失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_retired_navigation_removed.gd
```

Expected: 仍退出 1，但失败内容只剩导航脚本、导航场景、场景分组或 `AGENTS.md`；不得再报告 `navigation_geometry_changed` 或 `placement_geometry_changed`。

- [ ] **Step 7: 提交通知链清理**

```bash
git add scripts/gameplay/demo_arena.gd \
  scripts/gameplay/pickup_spawn_point.gd \
  scripts/gameplay/random_pickup_drop_manager.gd \
  scripts/gameplay/place_item_service.gd \
  scripts/props/explosive_barrel.gd \
  tools/validation/validate_pickup_spawn_point.gd \
  tools/validation/validate_random_pickup_drops.gd
git commit -m "refactor: remove retired navigation notifications"
```

---

### Task 3: 删除导航实现、场景节点和旧分组

**Files:**
- Delete: `scripts/navigation/navigation_world_manager.gd`
- Delete: `scripts/navigation/navigation_world_manager.gd.uid`
- Delete: `scripts/navigation/navigation_chunk_3d.gd`
- Delete: `scripts/navigation/navigation_chunk_3d.gd.uid`
- Delete: `scripts/navigation/navigation_bake_state.gd`
- Delete: `scripts/navigation/navigation_bake_state.gd.uid`
- Delete: `scenes/navigation/NavigationChunk3D.tscn`
- Modify: `scenes/gameplay/DemoArena.tscn:1-16, 198-209, 223-452`
- Modify: `scenes/gameplay/PickupChest.tscn:32`
- Modify: `scenes/props/ExplosiveBarrel.tscn:11`
- Modify: `scenes/props/PlasticBarrier.tscn:8`
- Modify: `scenes/props/SupplyChest.tscn:8`
- Modify: `scenes/props/TrafficBarrier.tscn:8`
- Modify: `AGENTS.md:19-51`

**Interfaces:**
- Consumes: `place_item_obstacle` 分组、`DemoArena._bake_static_blockers()`、确定性流场阻挡接口。
- Produces: `DemoArena` 不再实例化任何旧导航节点；所有实际阻挡物仍通过 `place_item_obstacle` 或显式运行时事件进入 `SimWorld`。

- [ ] **Step 1: 从 DemoArena 场景删除旧导航资源和节点**

在 `scenes/gameplay/DemoArena.tscn`：

- 将 `load_steps=59` 减为 `57`。
- 删除 `13_navigation_manager` 和 `14_navigation_chunk` 两条 `ext_resource`。
- 删除 `World/Navigation` 与 `World/Navigation/DemoArenaChunk` 节点块。
- 不重排其余资源 ID。

- [ ] **Step 2: 清除所有 `navigation_source` 场景分组**

按以下规则机械修改：

- `groups=["blood_surface", "navigation_source"]` 改为 `groups=["blood_surface"]`。
- `groups=["navigation_source", "place_item_obstacle"]` 改为 `groups=["place_item_obstacle"]`。

覆盖 `DemoArena.tscn` 中 Ground、四面边界、两只集装箱碰撞体和 PickupCollision，以及 `PickupChest.tscn`、`ExplosiveBarrel.tscn`、`PlasticBarrier.tscn`、`SupplyChest.tscn`、`TrafficBarrier.tscn`。

- [ ] **Step 3: 删除退役导航文件**

用 `apply_patch` 删除 Task 文件列表中的 3 个 `.gd`、3 个 `.uid` 和 `NavigationChunk3D.tscn`。删除后 `scripts/navigation/` 与 `scenes/navigation/` 若为空，无需保留目录。

- [ ] **Step 4: 更新当前导航约定**

在 `AGENTS.md` 的 `3D Runtime Navigation` 段落中，把旧 API 点名和“retired but retained”段落替换为：

```markdown
Zombie pathfinding uses the deterministic flow field in `scripts/sim/`
(`FlowFieldGrid` + `FlowField`): an XZ integer grid with multi-source BFS over
integer costs, rebuilt synchronously whenever a player crosses a cell boundary
or the blocker set is marked dirty. Godot's built-in navigation agents,
navigation server, navigation regions, and runtime baking are not part of the
gameplay architecture. Do not restore them or introduce asynchronous navigation
work: completion timing is nondeterministic and would break lockstep replay.
```

彻底删除原先说明三个退役类仍被实例化、以后再删除的段落。

- [ ] **Step 5: 运行旧符号闸门并确认转绿**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_retired_navigation_removed.gd
```

Expected: 打印 `validate_retired_navigation_removed: PASS`，退出码 0。

- [ ] **Step 6: 运行无头导入检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 退出码 0，无新增脚本解析、缺失资源或场景加载错误；允许 Godot 对新验证脚本生成 `.uid`。

- [ ] **Step 7: 提交导航实现删除**

```bash
git add AGENTS.md \
  scenes/gameplay/DemoArena.tscn \
  scenes/gameplay/PickupChest.tscn \
  scenes/props/ExplosiveBarrel.tscn \
  scenes/props/PlasticBarrier.tscn \
  scenes/props/SupplyChest.tscn \
  scenes/props/TrafficBarrier.tscn
git add -A scripts/navigation scenes/navigation
if test -f tools/validation/validate_retired_navigation_removed.gd.uid; then
  git add tools/validation/validate_retired_navigation_removed.gd.uid
fi
git commit -m "chore: remove retired navigation system"
```

提交前用 `git status --short` 确认未暂存 `scripts/menu/menu_entrance.gd.uid`。

---

### Task 4: 完整验证、最终评审与单提交整理

**Files:**
- Verify: `scripts/sim/flow_field.gd`
- Verify: `scripts/sim/flow_field_grid.gd`
- Verify: `scripts/sim/sim_collision.gd`
- Verify: `scripts/sim/sim_world.gd`
- Verify: all files changed by Tasks 1-3
- Include: `docs/superpowers/specs/2026-08-11-remove-retired-navigation-design.md`
- Include: `docs/superpowers/plans/2026-08-11-remove-retired-navigation.md`

**Interfaces:**
- Consumes: Tasks 1-3 的完整工作树和提交历史。
- Produces: 一个计划 Commit：`chore: remove retired navigation system`。

- [ ] **Step 1: 运行核心导航与动态阻挡验证**

Run:

```bash
for script in \
  validate_retired_navigation_removed \
  validate_flow_field \
  validate_sim_collision \
  validate_sim_determinism \
  validate_sim_barrel \
  validate_pickup_spawn_point \
  validate_random_pickup_drops; do
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script "res://tools/validation/${script}.gd" || exit 1
done
```

Expected: 七个验证脚本都打印各自的 `PASS`，整体退出码 0。

- [ ] **Step 2: 运行最终无头导入检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 退出码 0，无新增解析或资源错误。

- [ ] **Step 3: 检查删除范围与非目标**

Run:

```bash
git diff 6dff50f^ --stat
git diff 6dff50f^ -- scripts/sim/flow_field.gd scripts/sim/flow_field_grid.gd
git status --short
```

Expected:

- 变更只覆盖设计、计划、验证、旧导航集成、旧导航文件和项目约定。
- 两个流场算法文件无差异。
- `scripts/menu/menu_entrance.gd.uid` 仍保持未跟踪且未暂存。

- [ ] **Step 4: 检查格式和遗留引用**

Run:

```bash
git diff 6dff50f^ --check
rg -n \
  "NavigationWorldManager|NavigationChunk3D|NavigationBakeState|NavigationAgent3D|NavigationServer3D|NavigationRegion3D|navigation_geometry_changed|placement_geometry_changed|navigation_source|bake_from_source_geometry_data_async" \
  scripts scenes tools/validation AGENTS.md \
  --glob '!tools/validation/validate_retired_navigation_removed.gd'
```

Expected: `git diff --check` 无输出；`rg` 无输出并以 1 表示零命中。闸门脚本自身包含被禁止字符串，因此显式排除。

- [ ] **Step 5: squash 为一个计划 Commit**

先确认设计提交 `6dff50f` 的父提交仍是本任务开始前基线：

```bash
git show --no-patch --oneline 6dff50f
git log --oneline --decorate 6dff50f^..HEAD
```

Expected: 范围内只包含本计划产生的设计、计划和实现提交。

然后整理为单提交：

```bash
git reset --soft 6dff50f^
git commit -m "chore: remove retired navigation system"
```

最后确认：

```bash
git show --stat --oneline HEAD
git status --short
```

Expected: `HEAD` 是单个 `chore: remove retired navigation system` 提交，包含设计、计划和全部实现；工作树只剩用户原有未跟踪文件。
