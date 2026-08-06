# 爆炸油桶 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 DemoArena 中加入三枪引爆、二枪破损、可被其他爆炸连锁触发，并能按距离与掩体规则伤害玩家和僵尸的爆炸油桶。

**Architecture:** 使用纯函数 `ExplosionMath` 计算距离衰减，使用无持久状态的 `ExplosionResolver` 统一执行球形查询、目标去重、掩体射线和伤害分发。`ExplosiveBarrel` 只管理三阶段命中状态、一次性引爆和导航几何变化信号；爆炸与破损烟雾作为独立 `scenes/fx/` 场景参与现有渲染预热。

**Tech Stack:** Godot 4.7.1、GDScript、PhysicsDirectSpaceState3D、低数量 CPUParticles3D、自定义 RefCounted 测试框架。

## 实施结果（2026-08-06）

- [x] 已在独立 worktree `/Users/yewei/yyw/project/zombiewar-explosive-barrel`、分支 `codex/explosive-barrel` 中完成实现。
- [x] 已按 RED → GREEN 完成最小测试矩阵：爆炸距离衰减、油桶三阶段状态、爆炸去重/叠加/遮挡/连锁/近战隔离、DemoArena 场景契约和 FX 预热契约。
- [x] 任意枪械正数命中累计一次；第二枪进入持续变形、黑烟和橙色火星状态；第三枪立即引爆。
- [x] `ExplosionResolver` 可供后续手雷、火箭和其他明确爆炸来源复用，并能触发油桶连锁。
- [x] DemoArena 已放置 `ChainA`、`ChainB` 和 `Solo` 三个油桶，并在油桶移除后标脏 `demo_arena` 导航区块。
- [x] 新增两个运行时战斗 FX 场景均实现统一渲染预热生命周期；爆炸预热不播放音频、不结算伤害。为规避 Godot 4.7.1 headless 同时加载多个 GPU 粒子场景时的 Dummy Renderer RID 泄漏，首版采用低数量 CPU 粒子。
- [x] Godot 无头编辑器导入与解析检查退出码为 0；功能脚本与场景无解析错误。fresh import 偶发输出 `addons/phantom_camera` 更新器的已知类型错误，本任务未修改第三方插件。`git diff --check` 通过。
- [x] 爆炸油桶新增测试全部通过。完整测试套件仍有 4 个与本功能无关的隔离基线失败：1 个小刀移动动画期望、3 个玩家近战冷却/缓冲期望；本任务未修改这些范围外问题。

实现中的爆炸 FX 运行时入口命名为 `explode_at(world_position)`，语义对应计划草案中的 `setup(world_position)`。

## Global Constraints

- 实现和验证均在独立 worktree `/Users/yewei/yyw/project/zombiewar-explosive-barrel`、分支 `codex/explosive-barrel` 中进行。
- 油桶仅接受枪械 `apply_hit()` 和明确的爆炸 `apply_explosion_damage()`；近战、僵尸攻击和普通碰撞不能累计命中。
- 任意枪械第三次命中引爆，第二次命中进入明显持续破损状态。
- 不同爆炸伤害可以叠加；单次爆炸对同一目标只结算一次。
- 世界碰撞层 1 完全阻挡爆炸伤害。
- 新运行时战斗 FX 必须位于 `scenes/fx/` 并实现 `warmup_for_render(context)` 与 `finish_render_warmup()`。
- 测试使用最小矩阵：一个爆炸数学单元测试、一个油桶状态单元测试、一个爆炸/场景集成测试；不增加低价值的逐节点视觉断言。
- 先写失败测试并确认 RED，再编写对应生产代码。
- 不修改 `addons/`、不提交 `.godot/` 或 `build/`。

---

## 文件结构

- Create: `scripts/combat/explosion_math.gd` — 纯距离伤害衰减。
- Create: `scripts/combat/explosion_resolver.gd` — 瞬时爆炸物理查询、去重、遮挡和伤害分发。
- Create: `scripts/props/explosive_barrel.gd` — 油桶枪械命中、破损状态、连锁延迟、爆炸与导航信号。
- Create: `scripts/fx/barrel_explosion.gd` — 一次性爆炸视觉、临时音频和预热生命周期。
- Create: `scripts/fx/barrel_damage_smoke.gd` — 第二枪后的持续烟雾/火星和预热生命周期。
- Create: `scenes/props/ExplosiveBarrel.tscn` — 世界碰撞、视觉模型、破损 FX 挂点。
- Create: `scenes/fx/BarrelExplosion.tscn` — 火球、烟雾、火星、闪光、点光和音频。
- Create: `scenes/fx/BarrelDamageSmoke.tscn` — 持续黑烟和橙色火星。
- Copy: `assets/environment/Barrel.gltf` — 从已提交的原型资源目录复制嵌入贴图的油桶模型。
- Create: `tests/unit/test_explosion_math.gd` — 中心、中点、边缘、范围外衰减矩阵。
- Create: `tests/unit/test_explosive_barrel.gd` — 一枪/二枪/三枪与爆炸一次性状态矩阵。
- Create: `tests/integration/test_explosive_barrel_scene.gd` — 去重、叠加、掩体、连锁、近战隔离、导航与 DemoArena 场景契约。
- Modify: `tests/test_runner.gd` — 注册三个测试文件。
- Modify: `tests/integration/test_combat_fx_prewarm.gd` — 将两个新增 FX 场景加入自动发现契约。
- Modify: `scripts/gameplay/demo_arena.gd` — 连接油桶导航几何变化信号并标脏 `demo_arena`。
- Modify: `scenes/gameplay/DemoArena.tscn` — 放置三个油桶实例。
- Modify: `scenes/player/Player.tscn` — 将玩家根节点加入统一爆炸伤害目标分组。

---

### Task 1: 爆炸距离衰减

**Files:**
- Create: `tests/unit/test_explosion_math.gd`
- Create: `scripts/combat/explosion_math.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Produces: `ExplosionMath.damage_at_distance(distance: float, radius: float, center_damage: float, edge_damage: float) -> float`
- Consumes: 无。

- [ ] **Step 1: 写入失败单元测试**

测试同一个接口的最小四点矩阵：半径 4.5、中心伤害 80、边缘伤害 20 时，距离 0 返回 80，距离 2.25 返回 50，距离 4.5 返回 20，距离 4.51 返回 0；无效半径返回 0。将测试路径注册到 `TEST_PATHS`。

```gdscript
const ExplosionMath = preload("res://scripts/combat/explosion_math.gd")

Assertions.expect_float_near(
	ExplosionMath.damage_at_distance(2.25, 4.5, 80.0, 20.0),
	50.0,
	0.0001,
	"Explosion damage falls off linearly at half radius"
)
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，因为 `res://scripts/combat/explosion_math.gd` 不存在或无法加载。

- [ ] **Step 3: 编写最小纯函数实现**

实现规则：负距离按 0；`radius <= 0` 或距离大于半径返回 0；中心与边缘伤害先限制为非负数；使用 `lerpf(center, edge, distance / radius)`。

```gdscript
extends RefCounted
class_name ExplosionMath

static func damage_at_distance(
	distance: float,
	radius: float,
	center_damage: float,
	edge_damage: float
) -> float:
	if radius <= 0.0 or distance > radius:
		return 0.0
	var ratio := clampf(maxf(distance, 0.0) / radius, 0.0, 1.0)
	return lerpf(maxf(center_damage, 0.0), maxf(edge_damage, 0.0), ratio)
```

- [ ] **Step 4: 运行完整测试并确认 GREEN**

Run: `./tests/run_tests.sh`

Expected: PASS，且无新增 Godot 错误或警告。

- [ ] **Step 5: 提交任务**

```bash
git add scripts/combat/explosion_math.gd tests/unit/test_explosion_math.gd tests/test_runner.gd
git commit -m "feat: add explosion damage falloff"
```

---

### Task 2: 油桶三阶段状态

**Files:**
- Copy: `docs/game_resources_zombie_prototype/assets/environment/Barrel.gltf` -> `assets/environment/Barrel.gltf`
- Create: `tests/unit/test_explosive_barrel.gd`
- Create: `scripts/props/explosive_barrel.gd`
- Create: `scenes/props/ExplosiveBarrel.tscn`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: `HitResult.resolved(...)`。
- Produces: `ExplosiveBarrel.apply_hit(amount: float, hit_position: Vector3, shot_direction: Vector3) -> HitResult`
- Produces: `ExplosiveBarrel.apply_explosion_damage(amount: float, origin: Vector3) -> bool`
- Produces: `ExplosiveBarrel.get_state() -> int`
- Produces: `ExplosiveBarrel.get_firearm_hit_count() -> int`
- Produces: `ExplosiveBarrel.explosion_requested(delay_seconds: float)` 信号。
- Produces: `ExplosiveBarrel.navigation_geometry_changed` 信号。

- [ ] **Step 1: 写入失败状态测试**

加载真实 `ExplosiveBarrel.tscn`，关闭自动物理处理并连接 `explosion_requested`。验证：

- 第一次 `apply_hit()` 后计数为 1，状态仍为 `INTACT`。
- 第二次后计数为 2，状态为 `DAMAGED`，破损 FX 可见。
- 第三次后状态为 `EXPLODING`，只发出一次零延迟爆炸请求。
- 状态锁定后继续调用 `apply_hit()` 不增加计数、不重复发信号。
- 新实例调用正数 `apply_explosion_damage()` 立即锁定为 `EXPLODING`，发出默认 0.12 秒请求。
- 零或负爆炸伤害返回 `false` 且不改变状态。

- [ ] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，因为油桶脚本和场景不存在。

- [ ] **Step 3: 实现最小油桶状态机与场景骨架**

根节点使用 `StaticBody3D`、碰撞层 1、碰撞掩码 0、`navigation_source` 分组；添加圆柱简化碰撞、`VisualRoot`、油桶 GLTF 实例和默认隐藏的 `DamageSmoke` 挂点。油桶不加入 `damageable_targets`，不增加伤害 `Area3D`。

脚本使用以下状态：

```gdscript
enum State { INTACT, DAMAGED, EXPLODING, DESTROYED }
```

`apply_hit()` 忽略伤害数值对耐久的影响，每次正数伤害调用只加一次枪械命中；第二次调用 `_enter_damaged_state()`，第三次调用 `_request_explosion(0.0)`。`apply_explosion_damage()` 使用导出的 `chain_delay_seconds = 0.12`。`_request_explosion()` 必须先把状态锁定为 `EXPLODING`，再发信号。

- [ ] **Step 4: 运行完整测试并确认 GREEN**

Run: `./tests/run_tests.sh`

Expected: PASS。

- [ ] **Step 5: 提交任务**

```bash
git add assets/environment/Barrel.gltf scripts/props/explosive_barrel.gd scenes/props/ExplosiveBarrel.tscn tests/unit/test_explosive_barrel.gd tests/test_runner.gd
git commit -m "feat: add explosive barrel state machine"
```

---

### Task 3: 统一爆炸解析与连锁伤害

**Files:**
- Create: `scripts/combat/explosion_resolver.gd`
- Create: `tests/integration/test_explosive_barrel_scene.gd`
- Modify: `scripts/props/explosive_barrel.gd`
- Modify: `scenes/player/Player.tscn`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: `ExplosionMath.damage_at_distance(...)`。
- Consumes: `ExplosiveBarrel.apply_explosion_damage(amount, origin)`。
- Produces: `ExplosionResolver.resolve(world: World3D, origin: Vector3, radius: float, center_damage: float, edge_damage: float, source: CollisionObject3D, can_trigger_explosives: bool = true, target_mask: int = 7, obstacle_mask: int = 1) -> Array[Node3D]`
- Produces: `ExplosiveBarrel._execute_explosion() -> void`，由零延迟请求立即调用或由定时器调用。

- [ ] **Step 1: 写入失败集成测试**

使用真实 `Player.tscn`、`ZombieTarget.tscn`、`ExplosiveBarrel.tscn` 和简化世界碰撞，验证最小矩阵：

- 一个爆炸同时查询僵尸命中区域和根节点时，僵尸生命只减少一次。
- 连续调用两次 `ExplosionResolver.resolve()` 时，玩家生命累计减少两次。
- 玩家与爆炸之间放置层 1 的 `StaticBody3D` 后，玩家生命不变。
- 设置油桶 `chain_delay_seconds = 0.0` 后，一个油桶爆炸使范围内第二个油桶进入 `EXPLODING`，范围外第三个油桶保持 `INTACT`。
- 油桶没有 `damageable_targets` 分组且没有层 4 伤害区域，证明现有小刀查询无法选择它。

- [ ] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，因为 `ExplosionResolver` 不存在，油桶也尚未执行真实范围伤害。

- [ ] **Step 3: 实现爆炸解析器**

使用 `SphereShape3D` 与 `PhysicsShapeQueryParameters3D`，同时查询 body 和 area，默认掩码为 `1 | 2 | 4`。候选节点向上遍历：优先记录 `damageable_targets` 根节点；没有该分组时才接受实现 `apply_explosion_damage()` 的爆炸物。按实例 ID 去重。

每个目标使用层 1 射线检查遮挡；第一碰撞属于目标自身时允许伤害，否则阻挡。伤害分发顺序为：

```gdscript
if target.has_method("apply_explosion_damage") and can_trigger_explosives:
	target.call("apply_explosion_damage", damage, origin)
elif target.has_method("apply_hit"):
	target.call("apply_hit", damage, aim_point, direction)
elif target.has_method("apply_damage"):
	target.call("apply_damage", damage, origin)
```

将玩家根节点加入 `damageable_targets`。这不会让现有小刀或枪械命中玩家，因为玩家没有层 4 伤害区域，枪械掩码也不查询玩家层 2。

- [ ] **Step 4: 让油桶执行一次性爆炸**

`ExplosiveBarrel` 收到 `explosion_requested` 后：零延迟直接执行，正延迟创建一次性 Timer。执行时先把碰撞形状设为 deferred disabled，再调用 `ExplosionResolver.resolve()`，发出 `navigation_geometry_changed`，最后把状态设为 `DESTROYED` 并 `queue_free()`。定时器回调先检查实例仍有效且状态仍为 `EXPLODING`。

- [ ] **Step 5: 运行完整测试并确认 GREEN**

Run: `./tests/run_tests.sh`

Expected: PASS，单次去重、跨爆炸叠加、掩体阻挡和零延迟连锁全部通过。

- [ ] **Step 6: 提交任务**

```bash
git add scripts/combat/explosion_resolver.gd scripts/props/explosive_barrel.gd scenes/player/Player.tscn tests/integration/test_explosive_barrel_scene.gd tests/test_runner.gd
git commit -m "feat: resolve explosive barrel blast damage"
```

---

### Task 4: 破损与爆炸视觉预热

**Files:**
- Create: `scripts/fx/barrel_damage_smoke.gd`
- Create: `scripts/fx/barrel_explosion.gd`
- Create: `scenes/fx/BarrelDamageSmoke.tscn`
- Create: `scenes/fx/BarrelExplosion.tscn`
- Modify: `scenes/props/ExplosiveBarrel.tscn`
- Modify: `scripts/props/explosive_barrel.gd`
- Modify: `tests/integration/test_combat_fx_prewarm.gd`

**Interfaces:**
- Produces: `BarrelDamageSmoke.activate() -> void`
- Produces: `BarrelDamageSmoke.deactivate() -> void`
- Produces: `BarrelExplosion.setup(world_position: Vector3) -> void`
- Produces: 两个 FX 根脚本的 `warmup_for_render(context)` 与 `finish_render_warmup()`。

- [ ] **Step 1: 扩展失败的 FX 预热契约测试**

在 `EXPECTED_FX_PATHS` 中加入：

```gdscript
"res://scenes/fx/BarrelDamageSmoke.tscn",
"res://scenes/fx/BarrelExplosion.tscn",
```

并在油桶状态测试中保留“第二枪后 DamageSmoke 激活”的断言。

- [ ] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，因为两个 FX 场景不存在。

- [ ] **Step 3: 实现破损烟雾场景**

使用低数量 `GPUParticles3D` 黑灰烟雾和橙色火星。默认 `emitting = false`；`activate()` 开启，`deactivate()` 关闭。预热时放到相机安全位置、短暂启用粒子；结束时关闭并恢复默认隐藏状态。油桶第二枪后持续压扁 `VisualRoot.scale.y` 到约 0.88、倾斜约 7 度并激活烟雾。

- [ ] **Step 4: 实现爆炸场景**

使用一次性火焰、烟雾与火星 `GPUParticles3D`、短暂 `OmniLight3D` 和现有 `impactMetal_heavy_002.ogg` 的低音调 `AudioStreamPlayer3D`。`setup()` 只负责真实播放；预热方法不得播放音频。效果生命周期约 1.4 秒并自动释放。

- [ ] **Step 5: 从油桶生成独立爆炸 FX**

在 `_execute_explosion()` 中将 `BarrelExplosion` 实例加入油桶父节点，使油桶本体释放后 FX 仍能播放。先设置全局位置，再调用 `setup()`。

- [ ] **Step 6: 运行完整测试并确认 GREEN**

Run: `./tests/run_tests.sh`

Expected: PASS，预热器自动发现两个场景，结束后效果恢复非活动状态。

- [ ] **Step 7: 提交任务**

```bash
git add scripts/fx/barrel_damage_smoke.gd scripts/fx/barrel_explosion.gd scenes/fx/BarrelDamageSmoke.tscn scenes/fx/BarrelExplosion.tscn scenes/props/ExplosiveBarrel.tscn scripts/props/explosive_barrel.gd tests/integration/test_combat_fx_prewarm.gd
git commit -m "feat: add explosive barrel visual feedback"
```

---

### Task 5: DemoArena 与导航接入

**Files:**
- Modify: `scripts/gameplay/demo_arena.gd`
- Modify: `scenes/gameplay/DemoArena.tscn`
- Modify: `tests/integration/test_explosive_barrel_scene.gd`

**Interfaces:**
- Consumes: `ExplosiveBarrel.navigation_geometry_changed`。
- Consumes: `NavigationWorldManager.mark_chunk_dirty(&"demo_arena")`。
- Produces: `DemoArena._wire_explosive_barrel(node: Node) -> void`
- Produces: `DemoArena._on_barrel_navigation_geometry_changed() -> void`

- [ ] **Step 1: 增加失败的场景契约断言**

加载真实 DemoArena，断言 `World/Props/ExplosiveBarrels` 下恰好有三个 `ExplosiveBarrel`：

- `ChainA` 与 `ChainB` 的水平距离小于 4.5 米。
- `Solo` 与另外两个的水平距离都大于 4.5 米。
- 每个油桶都连接到 DemoArena 的导航变化处理方法。
- 油桶根节点属于 `navigation_source`，视觉 GLTF 子节点不属于该分组。

- [ ] **Step 2: 运行测试并确认 RED**

Run: `./tests/run_tests.sh`

Expected: FAIL，因为 DemoArena 尚未放置油桶或连接导航信号。

- [ ] **Step 3: 放置三个油桶并连接导航**

在 `World/Props` 下增加 `ExplosiveBarrels` 容器。建议位置：

- `ChainA`: `Vector3(-13.0, 0.0, -3.0)`
- `ChainB`: `Vector3(-10.0, 0.0, -3.0)`
- `Solo`: `Vector3(-15.0, 0.0, 6.0)`

在 `_wire_dependencies()` 中扫描并连接现有油桶，同时监听容器的 `child_entered_tree` 以支持未来运行时生成。回调只调用：

```gdscript
navigation_manager.mark_chunk_dirty(&"demo_arena")
```

导航管理器不存在或区块不存在时 `push_warning()`，不阻止油桶清理。

- [ ] **Step 4: 运行完整测试并确认 GREEN**

Run: `./tests/run_tests.sh`

Expected: PASS。

- [ ] **Step 5: 提交任务**

```bash
git add scripts/gameplay/demo_arena.gd scenes/gameplay/DemoArena.tscn tests/integration/test_explosive_barrel_scene.gd
git commit -m "feat: place explosive barrels in demo arena"
```

---

### Task 6: 完整验证、人工验收说明与单提交整理

**Files:**
- Modify if required: 仅限本计划已列出的文件。

**Interfaces:**
- Consumes: 前五个任务的全部接口。
- Produces: 一个通过验证的计划提交。

- [ ] **Step 1: 执行 Godot 解析检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: exit 0，无新增脚本解析错误、无场景加载错误。

- [ ] **Step 2: 执行完整测试套件**

Run: `./tests/run_tests.sh`

Expected: PASS，测试文件数量包含新增的三个最小矩阵测试。

- [ ] **Step 3: 检查变更质量**

Run:

```bash
git diff --check
git status --short
git log --oneline --decorate -8
```

确认没有 `.godot/`、`build/`、临时截图或未说明的文件进入提交。

- [ ] **Step 4: 执行源码层最终评审**

逐项确认：枪械三次规则不依赖武器伤害；近战查询无法选中油桶；爆炸单次去重但跨爆炸可叠加；遮挡只查询世界层；油桶进入 `EXPLODING` 后立即幂等锁定；导航标脏发生在碰撞关闭之后；FX 预热不播放音频或伤害。

- [ ] **Step 5: 将任务提交 squash 为一个计划提交**

以计划起点 `99db698` 为基准，把实现提交整理成一个提交，保留已经单独存在的设计提交：

```bash
git reset --soft 99db698
git commit -m "feat: add explosive barrels"
```

执行前再次确认当前分支为 `codex/explosive-barrel` 且工作区没有未提交的用户变更。

- [ ] **Step 6: 提供人工验收步骤**

告知用户从主菜单进入 DemoArena 后依次验证：手枪与步枪均第三枪爆炸、第二枪持续冒烟变形、小刀无效、相邻油桶连锁、多个爆炸伤害叠加、车辆/集装箱阻挡伤害，以及油桶消失后僵尸可使用释放空间。视觉结果由用户截图后再进行分析，不使用 CUA 自动化。
