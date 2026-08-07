# S0 确定性模拟地基 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在本仓库内建立与表现层硬分离的确定性模拟层，使 300 只僵尸的寻路、碰撞、伤害结算在同一输入序列下逐位可复现。

**Architecture:** 新增 `scripts/sim/`（纯数据 + 纯函数，零 Node 依赖）与 `scripts/render/`（只读模拟状态并驱动渲染）两个目录。`SimWorld` 用结构化数组保存全部模拟状态，由 `SimClock` 以固定 20Hz 推进；寻路用整数代价多源 BFS 流场替代 `NavigationAgent3D`，移动用圆碰撞空间哈希替代 `move_and_slide()`，随机用自实现分流 PCG32 替代 `RandomNumberGenerator`。僵尸节点退化为纯表现件，由 `ZombieRenderer` 按距离 LOD 混合骨骼动画与 `MultiMeshInstance3D`。

**Tech Stack:** Godot 4.7.1、GDScript、`PackedInt32Array` / `PackedVector2Array` 等 Packed 数组、`MultiMeshInstance3D`、`tools/validation/*.gd` 一次性验证脚本。

## Global Constraints

- 基线提交为当前主线 `5423871`；执行前若主线继续前进，先确认下列目标文件接口仍与本计划一致。
- 全部改动位于 `/Users/liangpingbo/Desktop/4399/game/zombiewar`，**不涉及任何网络代码**，不创建 `zombiewar-server`。
- 模拟节拍固定 20Hz：`TICK_SECONDS = 0.05`、`MAX_CATCHUP_TICKS = 5`。
- **模拟层函数一律不接收 `delta` 参数**，只使用常量 `SimClock.TICK_SECONDS`。
- 模拟层中出现 `delta` 形参、`randf()`、`randi()`、`randomize()`、`move_and_slide()`、`NavigationAgent3D`、`get_tree()`、`Time.*` 均视为缺陷。
- 模拟层允许使用 `Dictionary` 做键值查找（空间哈希桶），但**禁止遍历 `Dictionary` 来驱动模拟决策**；所有实体遍历按数组下标升序，即实体 id 升序。
- 实体 id 由单调递增计数器分配，**永不复用**；删除实体时按顺序压缩数组，保持下标顺序与 id 顺序一致。
- `DeterministicRng` 自实现 PCG32，四条流：`ZOMBIE_WANDER`、`ZOMBIE_SPAWN`、`WEAPON_SPREAD`、`LOOT_DROP`，各自持有 state，从房间种子加流 ID 派生。
- `Stream.LOOT_DROP` 本轮**只占位不使用**：`scripts/gameplay/pickup_spawn_point.gd` 的 `_next_spawn_transform()` 与 `_next_respawn_delay()` 目前返回常量，没有随机源需要迁移。保留该流是为了让流下标在将来加入掉落随机时不移动其他三条流的序列。任何新增掉落随机必须走这条流，不得新建 `RandomNumberGenerator`。
- `scripts/fx/**` 下的全部表现随机保留；`ranged_weapon.gd` 的射击音高 `randf_range(0.97, 1.03)` 保留。
- 流场网格 cell 边长取 **1.0**（spec 允许 0.5–1.0），与 `PlaceItemGrid.cell_size = 1.0` 的网格语义对齐但为独立实例，不复用其占位状态。
- DemoArena 流场网格：原点 `Vector2(-24.5, -19.5)`、cell 1.0、49 × 39 格。该原点使 cell 中心落在整数世界坐标上，与 `PlaceItemGrid` 的 `cell_to_world()` 完全对齐；覆盖 `Ground` 的 48 × 38 与四面边界墙。
- 玩家位置以毫米级整数量化后进入模拟：`roundi(value * 1000.0)`。
- 僵尸血量为整数：`HEALTH_SCALE = 100`，即 1 点血 = 100 内部单位；浮点伤害用 `roundi(damage * HEALTH_SCALE)` 转换。
- 帧哈希为 64 位 FNV-1a，offset basis `0xCBF29CE484222325`、prime `0x100000001B3`，逐字节消费 Packed 数组的 `to_byte_array()`（即浮点的 IEEE 位模式，不做量化）。
- 近景 LOD 至多 48 只且只覆盖锚点 15 m 内（`ZombieRenderer.NEAR_LOD_COUNT = 48`、`BLOCKER_RADIUS = 15.0`），其余走 `MultiMeshInstance3D` 静态姿势；**LOD 归属不进入模拟层**。超出该半径的僵尸不提供玩家阻挡体，这是相对 spec「近景 LOD 的选取半径覆盖整个活动区」的**已知收窄**：15 m 覆盖 `PlayerScreenBounds.ONLINE_BOUNDS_HALF_WIDTH = 11.2` / `ONLINE_BOUNDS_HALF_DEPTH = 9.7` 构成的活动区对角线（≈14.8 m）加一个僵尸半径，锚点附近的玩家一定被挡；但当同一半径内僵尸数超过 48 只时，第 49 只起不再有阻挡体。若人工验收发现穿模，先提高 `NEAR_LOD_COUNT`，不得改动模拟层。
- 同屏僵尸上限 300：`DemoArena.maximum_active_zombies` 的导出范围放宽到 `(4, 400, 1)`、默认值 300，且 `scenes/gameplay/DemoArena.tscn` 的 `DemoArena` 根节点显式写入 `maximum_active_zombies = 300`，使随包发布的场景与默认值一致。
- **基线事实修正**：`scenes/targets/ZombieTarget.tscn` 根节点当前为 `collision_layer = 0`，`scenes/player/Player.tscn` 为 `collision_mask = 1`，因此**现状玩家与僵尸之间本就没有物理阻挡**。spec 写的「保留一个仅用于玩家阻挡的碰撞体」在本仓库等价于**新增**：本计划新建物理层 4 `ZombieBlocker`，近景表现节点置于该层，玩家 mask 加入该层。
- **基线事实修正**：`scenes/targets/ZombieTarget.tscn` 当前只有一个 `Hitboxes/BodyHitbox`（`CylinderShape3D`，radius 1.1、height 2.2、偏移 y = 1.1），命中区只有 `&"body"` 一种、倍率 1.0，不存在头/侧身/腿部分区。模拟层解析几何按**现状**建模为单段竖直圆柱并保留分区表结构，不凭空发明新的分部位倍率。
- 当前仓库没有持久化自动测试套件；**不得恢复 `tests/` 或 `tests/run_tests.sh`**。客户端验证一律写成 `tools/validation/validate_*.gd` 一次性脚本。
- 静态检查命令：`/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`。
- 验证脚本运行方式：`/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/<name>.gd`。
- `validate_sim_determinism.gd` 单次运行在 Apple Silicon 上耗时 **10–40 分钟**（3 趟 × 3000 tick × 300 僵尸，逐字节 FNV 哈希是主要开销）。凡出现该脚本的步骤（Task 6 Step 4、Task 7、Task 8、Task 11）一律后台运行（`run_in_background` 或 `nohup ... &`），不要放进有 120 秒超时的前台 shell，也不要因为长时间无输出就中断。
- 冒烟脚本清理一律用 `rm -f`：`.uid` 边车文件由编辑器导入过程生成，`--headless --script` 不会生成它，用 `rm` 会因文件不存在而以非 0 退出。
- 提交信息使用 Conventional Commits，每个 Task 结束提交一次。

---

### Task 1: 固定节拍时钟与分流确定性随机

**Files:**
- Create: `scripts/sim/sim_clock.gd`
- Create: `scripts/sim/deterministic_rng.gd`
- Test: `tools/validation/validate_deterministic_rng.gd`

**Interfaces:**
- Consumes: 无（本任务不依赖既有源码）。
- Produces:
  - `SimClock.TICK_SECONDS: float = 0.05`、`SimClock.MAX_CATCHUP_TICKS: int = 5`
  - `SimClock.reset() -> void`
  - `SimClock.consume_frame(frame_delta: float) -> int`
  - `SimClock.get_tick_index() -> int`
  - `SimClock.get_interpolation_alpha() -> float`
  - `DeterministicRng.Stream { ZOMBIE_WANDER = 0, ZOMBIE_SPAWN = 1, WEAPON_SPREAD = 2, LOOT_DROP = 3 }`
  - `DeterministicRng.STREAM_COUNT: int = 4`
  - `DeterministicRng.seed_streams(room_seed: int) -> void`
  - `DeterministicRng.next_uint32(stream_index: int) -> int`
  - `DeterministicRng.next_unit_float(stream_index: int) -> float`
  - `DeterministicRng.next_range(stream_index: int, minimum: float, maximum: float) -> float`
  - `DeterministicRng.next_int_range(stream_index: int, minimum: int, maximum: int) -> int`
  - `DeterministicRng.get_state_words() -> PackedInt64Array`

- [ ] **Step 1: 确认目录不存在且没有旧实现**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git status --short
ls scripts/sim 2>&1
rg -n "SimClock|DeterministicRng|TICK_SECONDS" scripts tools || echo "no prior implementation"
```

Expected: 工作树干净；`ls scripts/sim` 报 `No such file or directory`；搜索输出 `no prior implementation`。

- [ ] **Step 2: 创建 `scripts/sim/sim_clock.gd`**

```gdscript
extends RefCounted
class_name SimClock

## 固定 20Hz 模拟节拍，与渲染帧率解耦。
## 模拟层函数一律不接收 delta，只使用 TICK_SECONDS。
const TICK_SECONDS := 0.05
const MAX_CATCHUP_TICKS := 5

var accumulator := 0.0
var tick_index := 0

func reset() -> void:
	accumulator = 0.0
	tick_index = 0

## 消费一个渲染帧的真实 delta，返回本帧应推进的整数 tick 数。
## 单帧最多追赶 MAX_CATCHUP_TICKS 个 tick，超出的欠账直接丢弃以避免卡顿后雪崩。
func consume_frame(frame_delta: float) -> int:
	accumulator += maxf(frame_delta, 0.0)
	var ticks := 0
	while accumulator >= TICK_SECONDS and ticks < MAX_CATCHUP_TICKS:
		accumulator -= TICK_SECONDS
		ticks += 1
	# 丢弃欠账时必须清零而不是钳到 TICK_SECONDS：钳到 TICK_SECONDS 会让
	# 下一帧即使 delta 为 0 也满足 accumulator >= TICK_SECONDS 并再吐一个 tick，
	# 被丢弃的欠账就以「每帧多一个 tick」的形式重新浮现。
	if accumulator >= TICK_SECONDS:
		accumulator = 0.0
	tick_index += ticks
	return ticks

func get_tick_index() -> int:
	return tick_index

## 渲染帧在上一 tick 与当前 tick 之间的插值系数。
func get_interpolation_alpha() -> float:
	return clampf(accumulator / TICK_SECONDS, 0.0, 1.0)
```

- [ ] **Step 3: 创建 `scripts/sim/deterministic_rng.gd`**

64 位 LCG 的乘加用 4 个 16 位 limb 手工完成，任何中间量都不超过 2^35，因此完全避开 GDScript `int` 的 64 位溢出行为；state 常驻为两个 32 位无符号半字，不会触碰符号位。

```gdscript
extends RefCounted
class_name DeterministicRng

## 自实现 PCG32-XSH-RR。不使用 Godot 的 RandomNumberGenerator：
## 其内部实现不保证跨版本稳定，而帧同步要求逐位一致。
enum Stream {
	ZOMBIE_WANDER,
	ZOMBIE_SPAWN,
	WEAPON_SPREAD,
	LOOT_DROP,
}

const STREAM_COUNT := 4
const UINT32_MASK := 0xFFFFFFFF
const INVERSE_UINT32 := 1.0 / 4294967296.0
const STREAM_SALT := 0x9E3779B1

# 0x5851F42D4C957F2D 的 16 位 limb（低位在前）
const MULTIPLIER_LIMB_0 := 0x7F2D
const MULTIPLIER_LIMB_1 := 0x4C95
const MULTIPLIER_LIMB_2 := 0xF42D
const MULTIPLIER_LIMB_3 := 0x5851
# 0x14057B7EF767814F 的 16 位 limb（低位在前）
const INCREMENT_LIMB_0 := 0x814F
const INCREMENT_LIMB_1 := 0xF767
const INCREMENT_LIMB_2 := 0x7B7E
const INCREMENT_LIMB_3 := 0x1405

var state_low := PackedInt64Array()
var state_high := PackedInt64Array()

func _init() -> void:
	state_low.resize(STREAM_COUNT)
	state_high.resize(STREAM_COUNT)
	seed_streams(0)

## 从房间种子加流 ID 派生每条流的初始 state。
## 任一子系统增删随机调用不会移动其他子系统的序列。
func seed_streams(room_seed: int) -> void:
	var seed_low := room_seed & UINT32_MASK
	var seed_high := (room_seed >> 32) & UINT32_MASK
	for stream_index in range(STREAM_COUNT):
		state_low[stream_index] = 0
		state_high[stream_index] = 0
		_advance(stream_index)
		_add(
			stream_index,
			(seed_high + stream_index) & UINT32_MASK,
			(seed_low + stream_index * STREAM_SALT) & UINT32_MASK
		)
		_advance(stream_index)
		_advance(stream_index)

func next_uint32(stream_index: int) -> int:
	var low := state_low[stream_index]
	var high := state_high[stream_index]
	_advance(stream_index)
	var shifted_low := ((low >> 18) | (high << 14)) & UINT32_MASK
	var shifted_high := high >> 18
	var xored_low := shifted_low ^ low
	var xored_high := shifted_high ^ high
	var xorshifted := ((xored_low >> 27) | (xored_high << 5)) & UINT32_MASK
	var rotation := (high >> 27) & 31
	return (
		(xorshifted >> rotation) | (xorshifted << ((32 - rotation) & 31))
	) & UINT32_MASK

## 返回 [0.0, 1.0) 区间的浮点数。
func next_unit_float(stream_index: int) -> float:
	return float(next_uint32(stream_index)) * INVERSE_UINT32

func next_range(stream_index: int, minimum: float, maximum: float) -> float:
	return minimum + (maximum - minimum) * next_unit_float(stream_index)

## 闭区间 [minimum, maximum]。取模偏置是可接受的：它是确定的。
func next_int_range(stream_index: int, minimum: int, maximum: int) -> int:
	var span := maxi(maximum - minimum + 1, 1)
	return minimum + next_uint32(stream_index) % span

## 供 SimHasher 纳入帧哈希：[low0, high0, low1, high1, ...]
func get_state_words() -> PackedInt64Array:
	var words := PackedInt64Array()
	words.resize(STREAM_COUNT * 2)
	for stream_index in range(STREAM_COUNT):
		words[stream_index * 2] = state_low[stream_index]
		words[stream_index * 2 + 1] = state_high[stream_index]
	return words

## state = state * MULTIPLIER + INCREMENT (mod 2^64)，用 16 位 limb 手工完成。
func _advance(stream_index: int) -> void:
	var low := state_low[stream_index]
	var high := state_high[stream_index]
	var limb_0 := low & 0xFFFF
	var limb_1 := (low >> 16) & 0xFFFF
	var limb_2 := high & 0xFFFF
	var limb_3 := (high >> 16) & 0xFFFF
	var column_0 := limb_0 * MULTIPLIER_LIMB_0 + INCREMENT_LIMB_0
	var column_1 := (
		limb_0 * MULTIPLIER_LIMB_1 +
		limb_1 * MULTIPLIER_LIMB_0 +
		INCREMENT_LIMB_1 +
		(column_0 >> 16)
	)
	var column_2 := (
		limb_0 * MULTIPLIER_LIMB_2 +
		limb_1 * MULTIPLIER_LIMB_1 +
		limb_2 * MULTIPLIER_LIMB_0 +
		INCREMENT_LIMB_2 +
		(column_1 >> 16)
	)
	var column_3 := (
		limb_0 * MULTIPLIER_LIMB_3 +
		limb_1 * MULTIPLIER_LIMB_2 +
		limb_2 * MULTIPLIER_LIMB_1 +
		limb_3 * MULTIPLIER_LIMB_0 +
		INCREMENT_LIMB_3 +
		(column_2 >> 16)
	)
	state_low[stream_index] = (column_0 & 0xFFFF) | ((column_1 & 0xFFFF) << 16)
	state_high[stream_index] = (column_2 & 0xFFFF) | ((column_3 & 0xFFFF) << 16)

func _add(stream_index: int, add_high: int, add_low: int) -> void:
	var total := state_low[stream_index] + add_low
	state_low[stream_index] = total & UINT32_MASK
	state_high[stream_index] = (
		state_high[stream_index] + add_high + (total >> 32)
	) & UINT32_MASK
```

- [ ] **Step 4: 创建 `tools/validation/validate_deterministic_rng.gd`**

下列已知向量由与本实现逐位等价的独立参考实现算出，不得改写为「运行一次再抄回来」。

```gdscript
extends SceneTree

const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")

# PCG32-XSH-RR 已知向量（room_seed = 12345）
const SEED_12345_STREAM_0: Array[int] = [3165192603, 3360792183, 2433038347, 628889468]
const SEED_12345_STREAM_1: Array[int] = [3744665246, 682428536, 3931205900, 2624254912]
const SEED_12345_STREAM_2: Array[int] = [119260362, 2490054067]
const SEED_12345_STREAM_3: Array[int] = [318996717, 4017299320]
const SEED_1_STREAM_0: Array[int] = [1791099446, 124312908, 1968572995, 1080415314]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_known_vectors(failures)
	_check_stream_independence(failures)
	_check_reseed_reproducibility(failures)
	_check_value_ranges(failures)
	_check_clock(failures)
	_finish(failures)

func _check_known_vectors(failures: Array[String]) -> void:
	var expected := {
		DeterministicRngScript.Stream.ZOMBIE_WANDER: SEED_12345_STREAM_0,
		DeterministicRngScript.Stream.ZOMBIE_SPAWN: SEED_12345_STREAM_1,
		DeterministicRngScript.Stream.WEAPON_SPREAD: SEED_12345_STREAM_2,
		DeterministicRngScript.Stream.LOOT_DROP: SEED_12345_STREAM_3,
	}
	for stream_index in expected.keys():
		var rng = DeterministicRngScript.new()
		rng.seed_streams(12345)
		var vector: Array = expected[stream_index]
		for draw_index in range(vector.size()):
			var value: int = rng.next_uint32(stream_index)
			_expect(
				value == vector[draw_index],
				"stream %d draw %d must be %d, got %d" % [
					stream_index, draw_index, vector[draw_index], value
				],
				failures
			)
	var seeded_one = DeterministicRngScript.new()
	seeded_one.seed_streams(1)
	for draw_index in range(SEED_1_STREAM_0.size()):
		var value: int = seeded_one.next_uint32(
			DeterministicRngScript.Stream.ZOMBIE_WANDER
		)
		_expect(
			value == SEED_1_STREAM_0[draw_index],
			"seed 1 stream 0 draw %d must be %d, got %d" % [
				draw_index, SEED_1_STREAM_0[draw_index], value
			],
			failures
		)

func _check_stream_independence(failures: Array[String]) -> void:
	var baseline = DeterministicRngScript.new()
	baseline.seed_streams(12345)
	var first := baseline.next_uint32(DeterministicRngScript.Stream.ZOMBIE_WANDER)
	var second := baseline.next_uint32(DeterministicRngScript.Stream.ZOMBIE_WANDER)

	var interleaved = DeterministicRngScript.new()
	interleaved.seed_streams(12345)
	var interleaved_first := interleaved.next_uint32(
		DeterministicRngScript.Stream.ZOMBIE_WANDER
	)
	interleaved.next_uint32(DeterministicRngScript.Stream.ZOMBIE_SPAWN)
	interleaved.next_uint32(DeterministicRngScript.Stream.WEAPON_SPREAD)
	interleaved.next_uint32(DeterministicRngScript.Stream.LOOT_DROP)
	var interleaved_second := interleaved.next_uint32(
		DeterministicRngScript.Stream.ZOMBIE_WANDER
	)
	_expect(
		interleaved_first == first and interleaved_second == second,
		"drawing from other streams must not move ZOMBIE_WANDER",
		failures
	)
	var seeded = DeterministicRngScript.new()
	seeded.seed_streams(12345)
	var distinct: Dictionary = {}
	for stream_index in range(DeterministicRngScript.STREAM_COUNT):
		distinct[seeded.next_uint32(stream_index)] = true
	_expect(
		distinct.size() == DeterministicRngScript.STREAM_COUNT,
		"each stream must start from a distinct derived state",
		failures
	)

func _check_reseed_reproducibility(failures: Array[String]) -> void:
	var first_run: Array[int] = []
	var second_run: Array[int] = []
	var rng = DeterministicRngScript.new()
	rng.seed_streams(987654321)
	for draw_index in range(64):
		first_run.append(
			rng.next_uint32(draw_index % DeterministicRngScript.STREAM_COUNT)
		)
	rng.seed_streams(987654321)
	for draw_index in range(64):
		second_run.append(
			rng.next_uint32(draw_index % DeterministicRngScript.STREAM_COUNT)
		)
	_expect(first_run == second_run, "reseeding must reproduce the same sequence", failures)
	var state_words := rng.get_state_words()
	_expect(
		state_words.size() == DeterministicRngScript.STREAM_COUNT * 2,
		"state words must expose low and high halves for every stream",
		failures
	)

func _check_value_ranges(failures: Array[String]) -> void:
	var rng = DeterministicRngScript.new()
	rng.seed_streams(4242)
	var minimum_float := 2.0
	var maximum_float := -1.0
	for _draw_index in range(4096):
		var unit := rng.next_unit_float(DeterministicRngScript.Stream.WEAPON_SPREAD)
		minimum_float = minf(minimum_float, unit)
		maximum_float = maxf(maximum_float, unit)
		var ranged := rng.next_range(
			DeterministicRngScript.Stream.WEAPON_SPREAD, -1.0, 1.0
		)
		_expect(ranged >= -1.0 and ranged < 1.0, "next_range must stay inside bounds", failures)
		var integer := rng.next_int_range(
			DeterministicRngScript.Stream.ZOMBIE_SPAWN, 3, 7
		)
		_expect(integer >= 3 and integer <= 7, "next_int_range must be inclusive", failures)
	_expect(minimum_float >= 0.0, "next_unit_float must not go below 0.0", failures)
	_expect(maximum_float < 1.0, "next_unit_float must stay below 1.0", failures)

func _check_clock(failures: Array[String]) -> void:
	_expect(
		SimClockScript.TICK_SECONDS == 0.05,
		"SimClock.TICK_SECONDS must be 0.05",
		failures
	)
	_expect(
		SimClockScript.MAX_CATCHUP_TICKS == 5,
		"SimClock.MAX_CATCHUP_TICKS must be 5",
		failures
	)
	var clock = SimClockScript.new()
	var single_total := 0
	for _frame_index in range(600):
		single_total += clock.consume_frame(0.05)
	_expect(single_total == 600, "feeding 0.05 per frame must yield one tick per frame", failures)
	_expect(clock.get_tick_index() == 600, "tick index must equal consumed ticks", failures)

	var batched = SimClockScript.new()
	var batched_total := 0
	for _frame_index in range(120):
		batched_total += batched.consume_frame(0.25)
	_expect(batched_total == 600, "feeding 0.25 per frame must yield five ticks per frame", failures)

	var starved = SimClockScript.new()
	_expect(
		starved.consume_frame(2.0) == SimClockScript.MAX_CATCHUP_TICKS,
		"a long stall must be clamped to MAX_CATCHUP_TICKS",
		failures
	)
	_expect(
		starved.consume_frame(0.0) == 0,
		"the dropped backlog must not resurface on the next frame",
		failures
	)
	starved.reset()
	_expect(
		starved.get_tick_index() == 0 and starved.get_interpolation_alpha() == 0.0,
		"reset must clear both the tick index and the accumulator",
		failures
	)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_deterministic_rng: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 5: 运行验证脚本与静态检查**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_deterministic_rng.gd
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
```

Expected: 第一条命令打印 `validate_deterministic_rng: PASS` 并以退出码 0 结束；第二条命令退出码为 0，输出没有本次改动引入的 `SCRIPT ERROR` 或 `Parse Error`。

- [ ] **Step 6: 审查确定性闸门**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
rg -n "randf|randi|randomize|get_tree|move_and_slide|NavigationAgent3D|Time\." scripts/sim \
  || echo "sim layer has no nondeterministic api"
rg -n "\bdelta\b" scripts/sim | rg -v "^scripts/sim/sim_clock.gd:" \
  || echo "only sim_clock touches real delta"
```

Expected: 分别输出 `sim layer has no nondeterministic api` 与 `only sim_clock touches real delta`。`sim_clock.gd` 的 `consume_frame(frame_delta)` 是表现层与模拟层之间唯一允许接触真实 delta 的边界函数，第二条命令已按文件名把它排除；两条命令中的任何一条有输出（而非上述固定字符串）都视为缺陷。

> 第二条用的是 `\bdelta\b` 而不是裸 `delta`：`sim_world.line_is_clear()` 的 Bresenham 里有 `delta_x` / `delta_y`，`sim_clock.gd` 的形参叫 `frame_delta`，这三个标识符两侧都紧邻下划线，不构成词边界，因此不会被误报；只有独立出现的 `delta` 标识符才会命中。同理，`scripts/sim/**` 的注释里也不要写独立的 `delta` 一词，否则这条闸门会假红。

- [ ] **Step 7: 提交**

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add scripts/sim/sim_clock.gd scripts/sim/deterministic_rng.gd \
  tools/validation/validate_deterministic_rng.gd
git commit -m "feat: add fixed sim clock and deterministic rng"
```

Expected: 提交只包含上述三个脚本及其 `.uid`，不含 `.godot/`。

---

### Task 2: 整数代价多源 BFS 流场

**Files:**
- Create: `scripts/sim/flow_field_grid.gd`
- Create: `scripts/sim/flow_field.gd`
- Test: `tools/validation/validate_flow_field.gd`

**Interfaces:**
- Consumes: 无（`FlowField` 只依赖 `FlowFieldGrid`）。
- Produces:
  - `FlowFieldGrid.DEFAULT_CELL_SIZE: float = 1.0`
  - `FlowFieldGrid.configure(value_origin: Vector2, value_cell_size: float, value_width: int, value_height: int) -> void`
  - `FlowFieldGrid.get_cell_size() -> float`、`get_width() -> int`、`get_height() -> int`、`get_cell_count() -> int`
  - `FlowFieldGrid.get_blocked_bytes() -> PackedByteArray`
  - `FlowFieldGrid.world_to_cell(world_xz: Vector2) -> Vector2i`
  - `FlowFieldGrid.cell_to_world(cell: Vector2i) -> Vector2`
  - `FlowFieldGrid.is_inside(cell: Vector2i) -> bool`
  - `FlowFieldGrid.cell_index(cell: Vector2i) -> int`
  - `FlowFieldGrid.index_to_cell(index: int) -> Vector2i`
  - `FlowFieldGrid.is_blocked(cell: Vector2i) -> bool`
  - `FlowFieldGrid.set_blocked(cell: Vector2i, value: bool) -> bool`
  - `FlowFieldGrid.set_blocked_world_rect(min_xz: Vector2, max_xz: Vector2, value: bool) -> bool`
  - `FlowFieldGrid.mark_dirty() -> void`、`consume_dirty() -> bool`
  - `FlowField.UNREACHABLE: int = 0x7FFFFFFF`
  - `FlowField.setup(value_grid: FlowFieldGrid) -> void`
  - `FlowField.update(source_cell_indices: PackedInt32Array) -> bool`
  - `FlowField.rebuild(source_cell_indices: PackedInt32Array) -> void`
  - `FlowField.get_cost(cell: Vector2i) -> int`
  - `FlowField.is_reachable(cell: Vector2i) -> bool`
  - `FlowField.get_direction(cell: Vector2i) -> Vector2`
  - `FlowField.get_rebuild_count() -> int`

- [ ] **Step 1: 创建 `scripts/sim/flow_field_grid.gd`**

```gdscript
extends RefCounted
class_name FlowFieldGrid

## XZ 平面的整数阻挡网格。与 PlaceItemGrid 的网格语义对齐（同样的 cell 边长），
## 但是独立实例：它保存的是「僵尸能否通过」，不是「放置位是否被占」。
const DEFAULT_CELL_SIZE := 1.0

var origin := Vector2.ZERO
var cell_size := DEFAULT_CELL_SIZE
var width := 0
var height := 0
var blocked := PackedByteArray()
var dirty := true

func configure(
	value_origin: Vector2,
	value_cell_size: float,
	value_width: int,
	value_height: int
) -> void:
	origin = value_origin
	cell_size = maxf(value_cell_size, 0.001)
	width = maxi(value_width, 1)
	height = maxi(value_height, 1)
	blocked = PackedByteArray()
	blocked.resize(width * height)
	blocked.fill(0)
	dirty = true

func get_cell_size() -> float:
	return cell_size

func get_width() -> int:
	return width

func get_height() -> int:
	return height

func get_cell_count() -> int:
	return width * height

func get_blocked_bytes() -> PackedByteArray:
	return blocked

func world_to_cell(world_xz: Vector2) -> Vector2i:
	return Vector2i(
		floori((world_xz.x - origin.x) / cell_size),
		floori((world_xz.y - origin.y) / cell_size)
	)

func cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(
		origin.x + (float(cell.x) + 0.5) * cell_size,
		origin.y + (float(cell.y) + 0.5) * cell_size
	)

func is_inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < height

func cell_index(cell: Vector2i) -> int:
	return cell.y * width + cell.x if is_inside(cell) else -1

func index_to_cell(index: int) -> Vector2i:
	if index < 0 or index >= width * height:
		return Vector2i(-1, -1)
	return Vector2i(index % width, index / width)

## 网格外一律视为阻挡，BFS 与碰撞都靠这条把僵尸关在场内。
func is_blocked(cell: Vector2i) -> bool:
	var index := cell_index(cell)
	return true if index < 0 else blocked[index] == 1

func set_blocked(cell: Vector2i, value: bool) -> bool:
	var index := cell_index(cell)
	if index < 0:
		return false
	var next_value := 1 if value else 0
	if blocked[index] == next_value:
		return false
	blocked[index] = next_value
	dirty = true
	return true

## 运行时增删阻挡几何统一走这里：任何改变都会置脏，下一 tick 触发流场重算。
func set_blocked_world_rect(min_xz: Vector2, max_xz: Vector2, value: bool) -> bool:
	var low_cell := world_to_cell(
		Vector2(minf(min_xz.x, max_xz.x), minf(min_xz.y, max_xz.y))
	)
	var high_cell := world_to_cell(
		Vector2(maxf(min_xz.x, max_xz.x), maxf(min_xz.y, max_xz.y))
	)
	var changed := false
	for cell_z in range(low_cell.y, high_cell.y + 1):
		for cell_x in range(low_cell.x, high_cell.x + 1):
			changed = set_blocked(Vector2i(cell_x, cell_z), value) or changed
	return changed

func mark_dirty() -> void:
	dirty = true

func consume_dirty() -> bool:
	if not dirty:
		return false
	dirty = false
	return true
```

- [ ] **Step 2: 创建 `scripts/sim/flow_field.gd`**

代价用 4 邻域单位代价 BFS（整数、逐位确定）；方向在 8 邻域里取代价严格更小者，邻域顺序固定，禁止穿越阻挡拐角。方向按需惰性计算并缓存，避免每次重算都遍历全图。

```gdscript
extends RefCounted
class_name FlowField

## 替代 300 个 NavigationAgent3D：以全部存活玩家为源做多源 BFS，
## 整数代价，生成到最近玩家的方向场。僵尸只查自己所在 cell，寻路成本与僵尸数量无关。
const UNREACHABLE := 0x7FFFFFFF

const ORTHOGONAL_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
]

const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, -1),
	Vector2i(1, 0),
	Vector2i(1, 1),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(-1, -1),
]

var grid: FlowFieldGrid
var cost := PackedInt32Array()
var direction_x := PackedFloat32Array()
var direction_z := PackedFloat32Array()
var direction_ready := PackedByteArray()
var last_sources := PackedInt32Array()
var rebuild_count := 0

func setup(value_grid: FlowFieldGrid) -> void:
	grid = value_grid
	var cell_count := grid.get_cell_count()
	cost = PackedInt32Array()
	cost.resize(cell_count)
	cost.fill(UNREACHABLE)
	direction_x = PackedFloat32Array()
	direction_x.resize(cell_count)
	direction_x.fill(0.0)
	direction_z = PackedFloat32Array()
	direction_z.resize(cell_count)
	direction_z.fill(0.0)
	direction_ready = PackedByteArray()
	direction_ready.resize(cell_count)
	direction_ready.fill(0)
	last_sources = PackedInt32Array()
	rebuild_count = 0

## 重算时机：任一玩家跨越 cell 边界（source 集合变化），或阻挡集合变脏。
## 调用方必须传入升序去重后的 cell index 数组。返回是否真的重算过。
func update(source_cell_indices: PackedInt32Array) -> bool:
	var grid_changed := grid.consume_dirty()
	if not grid_changed and source_cell_indices == last_sources:
		return false
	rebuild(source_cell_indices)
	return true

func rebuild(source_cell_indices: PackedInt32Array) -> void:
	rebuild_count += 1
	last_sources = source_cell_indices.duplicate()
	var cell_count := grid.get_cell_count()
	cost.fill(UNREACHABLE)
	direction_ready.fill(0)
	var queue := PackedInt32Array()
	queue.resize(cell_count)
	var queue_end := 0
	for source_index in source_cell_indices:
		if source_index < 0 or source_index >= cell_count:
			continue
		if cost[source_index] == 0:
			continue
		cost[source_index] = 0
		queue[queue_end] = source_index
		queue_end += 1
	var queue_head := 0
	var grid_width := grid.get_width()
	while queue_head < queue_end:
		var current_index := queue[queue_head]
		queue_head += 1
		var next_cost := cost[current_index] + 1
		var current_cell := Vector2i(
			current_index % grid_width,
			current_index / grid_width
		)
		for offset in ORTHOGONAL_OFFSETS:
			var neighbor := current_cell + offset
			var neighbor_index := grid.cell_index(neighbor)
			if neighbor_index < 0 or grid.is_blocked(neighbor):
				continue
			if cost[neighbor_index] <= next_cost:
				continue
			cost[neighbor_index] = next_cost
			queue[queue_end] = neighbor_index
			queue_end += 1

func get_cost(cell: Vector2i) -> int:
	var index := grid.cell_index(cell)
	return UNREACHABLE if index < 0 else cost[index]

func is_reachable(cell: Vector2i) -> bool:
	return get_cost(cell) != UNREACHABLE

func get_direction(cell: Vector2i) -> Vector2:
	var index := grid.cell_index(cell)
	if index < 0:
		return Vector2.ZERO
	if direction_ready[index] == 0:
		_compute_direction(index, cell)
	return Vector2(direction_x[index], direction_z[index])

func get_rebuild_count() -> int:
	return rebuild_count

func _compute_direction(index: int, cell: Vector2i) -> void:
	direction_ready[index] = 1
	direction_x[index] = 0.0
	direction_z[index] = 0.0
	var current_cost := cost[index]
	if current_cost == UNREACHABLE or current_cost == 0:
		return
	var best_cost := current_cost
	var best_offset := Vector2i.ZERO
	for offset in NEIGHBOR_OFFSETS:
		var neighbor := cell + offset
		var neighbor_index := grid.cell_index(neighbor)
		if neighbor_index < 0 or grid.is_blocked(neighbor):
			continue
		if offset.x != 0 and offset.y != 0:
			if grid.is_blocked(Vector2i(cell.x + offset.x, cell.y)):
				continue
			if grid.is_blocked(Vector2i(cell.x, cell.y + offset.y)):
				continue
		var neighbor_cost := cost[neighbor_index]
		if neighbor_cost < best_cost:
			best_cost = neighbor_cost
			best_offset = offset
	if best_offset == Vector2i.ZERO:
		return
	var direction := Vector2(float(best_offset.x), float(best_offset.y)).normalized()
	direction_x[index] = direction.x
	direction_z[index] = direction.y
```

- [ ] **Step 3: 创建 `tools/validation/validate_flow_field.gd`**

```gdscript
extends SceneTree

const FlowFieldGridScript = preload("res://scripts/sim/flow_field_grid.gd")
const FlowFieldScript = preload("res://scripts/sim/flow_field.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_grid_mapping(failures)
	_check_single_source_matches_reference(failures)
	_check_multi_source_is_minimum(failures)
	_check_walls_and_unreachable(failures)
	_check_dirty_triggers_rebuild(failures)
	_check_direction_rules(failures)
	_finish(failures)

func _check_grid_mapping(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	_expect(grid.get_cell_count() == 49 * 39, "grid must allocate width * height cells", failures)
	_expect(
		grid.world_to_cell(Vector2(-24.0, -19.0)) == Vector2i(0, 0),
		"the first cell must contain the arena's minimum corner",
		failures
	)
	_expect(
		grid.cell_to_world(Vector2i(0, 0)).is_equal_approx(Vector2(-24.0, -19.0)),
		"cell centres must land on integer world coordinates",
		failures
	)
	_expect(
		grid.cell_to_world(grid.world_to_cell(Vector2(7.0, -3.0))).is_equal_approx(
			Vector2(7.0, -3.0)
		),
		"world -> cell -> world must round-trip on cell centres",
		failures
	)
	_expect(grid.is_blocked(Vector2i(-1, 0)), "outside cells must read as blocked", failures)
	_expect(grid.cell_index(Vector2i(49, 0)) == -1, "outside cells must have no index", failures)

func _check_single_source_matches_reference(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2.ZERO, 1.0, 12, 9)
	for cell_z in range(1, 7):
		grid.set_blocked(Vector2i(5, cell_z), true)
	var field = FlowFieldScript.new()
	field.setup(grid)
	var sources := PackedInt32Array([grid.cell_index(Vector2i(0, 0))])
	field.rebuild(sources)
	var reference := _reference_costs(grid, sources)
	var mismatches := 0
	for cell_z in range(grid.get_height()):
		for cell_x in range(grid.get_width()):
			var cell := Vector2i(cell_x, cell_z)
			if field.get_cost(cell) != reference[grid.cell_index(cell)]:
				mismatches += 1
	_expect(mismatches == 0, "BFS costs must match the naive reference (%d mismatches)" % mismatches, failures)

func _check_multi_source_is_minimum(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2.ZERO, 1.0, 15, 11)
	var field = FlowFieldScript.new()
	field.setup(grid)
	var first_source := grid.cell_index(Vector2i(0, 0))
	var second_source := grid.cell_index(Vector2i(14, 10))
	var combined := PackedInt32Array([first_source, second_source])
	combined.sort()
	field.rebuild(combined)
	var first_only := _reference_costs(grid, PackedInt32Array([first_source]))
	var second_only := _reference_costs(grid, PackedInt32Array([second_source]))
	var mismatches := 0
	for index in range(grid.get_cell_count()):
		var expected: int = mini(first_only[index], second_only[index])
		if field.get_cost(grid.index_to_cell(index)) != expected:
			mismatches += 1
	_expect(
		mismatches == 0,
		"multi-source BFS must equal the per-source minimum (%d mismatches)" % mismatches,
		failures
	)

func _check_walls_and_unreachable(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2.ZERO, 1.0, 9, 9)
	for cell_z in range(9):
		grid.set_blocked(Vector2i(4, cell_z), true)
	var field = FlowFieldScript.new()
	field.setup(grid)
	field.rebuild(PackedInt32Array([grid.cell_index(Vector2i(0, 0))]))
	_expect(field.is_reachable(Vector2i(3, 8)), "cells on the source side must stay reachable", failures)
	_expect(
		not field.is_reachable(Vector2i(5, 0)),
		"a full wall must leave the far side unreachable",
		failures
	)
	_expect(
		field.get_cost(Vector2i(5, 0)) == FlowFieldScript.UNREACHABLE,
		"unreachable cells must report UNREACHABLE",
		failures
	)
	_expect(
		field.get_direction(Vector2i(5, 0)) == Vector2.ZERO,
		"unreachable cells must produce no direction",
		failures
	)
	_expect(
		not field.is_reachable(Vector2i(4, 4)),
		"blocked cells must never receive a cost",
		failures
	)

func _check_dirty_triggers_rebuild(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2.ZERO, 1.0, 9, 9)
	var field = FlowFieldScript.new()
	field.setup(grid)
	var sources := PackedInt32Array([grid.cell_index(Vector2i(0, 4))])
	_expect(field.update(sources), "the first update must rebuild", failures)
	var after_first := field.get_rebuild_count()
	_expect(not field.update(sources), "an unchanged update must not rebuild", failures)
	_expect(field.get_rebuild_count() == after_first, "rebuild count must stay put", failures)

	for cell_z in range(9):
		grid.set_blocked(Vector2i(4, cell_z), true)
	_expect(field.update(sources), "a dirty blocker set must force a rebuild", failures)
	_expect(
		not field.is_reachable(Vector2i(8, 4)),
		"the rebuilt field must respect the new wall",
		failures
	)
	grid.set_blocked(Vector2i(4, 4), false)
	_expect(field.update(sources), "opening a gap must force a rebuild", failures)
	_expect(
		field.is_reachable(Vector2i(8, 4)),
		"the rebuilt field must route through the reopened gap",
		failures
	)
	var moved := PackedInt32Array([grid.cell_index(Vector2i(1, 4))])
	_expect(field.update(moved), "a source crossing a cell boundary must force a rebuild", failures)

func _check_direction_rules(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2.ZERO, 1.0, 7, 7)
	var field = FlowFieldScript.new()
	field.setup(grid)
	field.rebuild(PackedInt32Array([grid.cell_index(Vector2i(0, 0))]))
	_expect(
		field.get_direction(Vector2i(0, 0)) == Vector2.ZERO,
		"the source cell must produce no direction",
		failures
	)
	var descending := field.get_direction(Vector2i(3, 3))
	_expect(
		field.get_cost(Vector2i(3, 3) + Vector2i(roundi(descending.x), roundi(descending.y)))
			< field.get_cost(Vector2i(3, 3)),
		"the direction must point at a strictly cheaper neighbour",
		failures
	)
	var repeated := field.get_direction(Vector2i(3, 3))
	_expect(repeated == descending, "cached directions must be stable", failures)

	var corner_grid = FlowFieldGridScript.new()
	corner_grid.configure(Vector2.ZERO, 1.0, 5, 5)
	corner_grid.set_blocked(Vector2i(1, 2), true)
	corner_grid.set_blocked(Vector2i(2, 1), true)
	var corner_field = FlowFieldScript.new()
	corner_field.setup(corner_grid)
	corner_field.rebuild(PackedInt32Array([corner_grid.cell_index(Vector2i(1, 1))]))
	_expect(
		corner_field.get_direction(Vector2i(2, 2)) != Vector2(-1.0, -1.0).normalized(),
		"diagonal steps must not cut between two blocked orthogonal neighbours",
		failures
	)

func _reference_costs(grid, sources: PackedInt32Array) -> PackedInt32Array:
	var costs := PackedInt32Array()
	costs.resize(grid.get_cell_count())
	costs.fill(FlowFieldScript.UNREACHABLE)
	var frontier: Array[Vector2i] = []
	for source_index in sources:
		costs[source_index] = 0
		frontier.append(grid.index_to_cell(source_index))
	var distance := 0
	while not frontier.is_empty():
		distance += 1
		var next_frontier: Array[Vector2i] = []
		for cell in frontier:
			for offset in FlowFieldScript.ORTHOGONAL_OFFSETS:
				var neighbor: Vector2i = cell + offset
				var neighbor_index: int = grid.cell_index(neighbor)
				if neighbor_index < 0 or grid.is_blocked(neighbor):
					continue
				if costs[neighbor_index] <= distance:
					continue
				costs[neighbor_index] = distance
				next_frontier.append(neighbor)
		frontier = next_frontier
	return costs

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_flow_field: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 4: 运行验证脚本与静态检查**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_flow_field.gd
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
```

Expected: 打印 `validate_flow_field: PASS`，退出码 0；编辑器导入检查退出码 0 且无新增解析错误。

- [ ] **Step 5: 提交**

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add scripts/sim/flow_field_grid.gd scripts/sim/flow_field.gd \
  tools/validation/validate_flow_field.gd
git commit -m "feat: add integer cost multi-source flow field"
```

Expected: 提交只包含流场两个脚本、验证脚本及其 `.uid`。

---

### Task 3: 圆碰撞与空间哈希

**Files:**
- Create: `scripts/sim/sim_collision.gd`
- Test: `tools/validation/validate_sim_collision.gd`

**Interfaces:**
- Consumes: `FlowFieldGrid.get_cell_size() -> float`、`FlowFieldGrid.world_to_cell(world_xz: Vector2) -> Vector2i`、`FlowFieldGrid.cell_to_world(cell: Vector2i) -> Vector2`、`FlowFieldGrid.is_blocked(cell: Vector2i) -> bool`。
- Produces:
  - `SimCollision.DEFAULT_HASH_CELL_SIZE: float = 1.0`
  - `SimCollision.hash_key(cell_x: int, cell_z: int) -> int`
  - `SimCollision.build_spatial_hash(positions: PackedVector2Array, count: int, hash_cell_size: float) -> Dictionary`
  - `SimCollision.accumulate_separation(positions: PackedVector2Array, radii: PackedFloat32Array, count: int, hash_cell_size: float, separation_ratio: float) -> PackedVector2Array`
  - `SimCollision.resolve_circle_push(position: Vector2, radius: float, other_position: Vector2, other_radius: float) -> Vector2`
  - `SimCollision.resolve_blocker(position: Vector2, radius: float, grid: FlowFieldGrid) -> Vector2`

- [ ] **Step 1: 创建 `scripts/sim/sim_collision.gd`**

```gdscript
extends RefCounted
class_name SimCollision

## 替代僵尸的 CharacterBody3D.move_and_slide()。
## 僵尸建模为 XZ 平面上的圆 + 高度标量；2.5D 平地场景不需要斜坡与台阶解算。
## 空间哈希只做键值查找，绝不遍历 Dictionary：所有配对遍历按实体下标升序，
## 而下标顺序即 id 顺序（SimWorld 保证压缩删除时保持顺序）。
const DEFAULT_HASH_CELL_SIZE := 1.0
const HASH_ORIGIN_BIAS := 32768
const HASH_ROW_STRIDE := 65536

static func hash_key(cell_x: int, cell_z: int) -> int:
	return (cell_z + HASH_ORIGIN_BIAS) * HASH_ROW_STRIDE + (cell_x + HASH_ORIGIN_BIAS)

## 桶内下标天然升序：插入按 index 升序进行。
static func build_spatial_hash(
	positions: PackedVector2Array,
	count: int,
	hash_cell_size: float
) -> Dictionary:
	var buckets: Dictionary = {}
	var size := maxf(hash_cell_size, 0.001)
	for index in range(count):
		var position := positions[index]
		var key := hash_key(floori(position.x / size), floori(position.y / size))
		if not buckets.has(key):
			buckets[key] = PackedInt32Array()
		var bucket: PackedInt32Array = buckets[key]
		bucket.append(index)
	return buckets

## 返回每个实体的互推位移。外层 i 升序、内层只处理 j > i、九宫格顺序固定，
## 因此浮点累加顺序完全确定。
static func accumulate_separation(
	positions: PackedVector2Array,
	radii: PackedFloat32Array,
	count: int,
	hash_cell_size: float,
	separation_ratio: float
) -> PackedVector2Array:
	var displacement := PackedVector2Array()
	displacement.resize(count)
	displacement.fill(Vector2.ZERO)
	if count <= 0:
		return displacement
	var size := maxf(hash_cell_size, 0.001)
	var buckets := build_spatial_hash(positions, count, size)
	var ratio := clampf(separation_ratio, 0.0, 1.0)
	var empty_bucket := PackedInt32Array()
	for index in range(count):
		var radius := radii[index]
		if radius <= 0.0:
			continue
		var position := positions[index]
		var cell_x := floori(position.x / size)
		var cell_z := floori(position.y / size)
		for offset_z in range(-1, 2):
			for offset_x in range(-1, 2):
				var bucket: PackedInt32Array = buckets.get(
					hash_key(cell_x + offset_x, cell_z + offset_z),
					empty_bucket
				)
				for other_index in bucket:
					if other_index <= index:
						continue
					var other_radius := radii[other_index]
					if other_radius <= 0.0:
						continue
					var offset := positions[other_index] - position
					var combined := radius + other_radius
					var distance_squared := offset.length_squared()
					if distance_squared >= combined * combined:
						continue
					var push := Vector2.ZERO
					if distance_squared <= 0.000001:
						push = Vector2(combined * 0.5 * ratio, 0.0)
					else:
						var distance := sqrt(distance_squared)
						push = offset / distance * ((combined - distance) * 0.5 * ratio)
					displacement[index] -= push
					displacement[other_index] += push
	return displacement

## 圆 vs 圆的单向推开：调用方被推开，另一方不动。
## 玩家位置是只读输入，僵尸被玩家推开而玩家不被模拟层反推。
static func resolve_circle_push(
	position: Vector2,
	radius: float,
	other_position: Vector2,
	other_radius: float
) -> Vector2:
	var offset := position - other_position
	var combined := radius + other_radius
	var distance_squared := offset.length_squared()
	if distance_squared >= combined * combined:
		return Vector2.ZERO
	if distance_squared <= 0.000001:
		return Vector2(combined, 0.0)
	var distance := sqrt(distance_squared)
	return offset / distance * (combined - distance)

## 圆 vs 阻挡 cell（轴对齐正方形），不调用 PhysicsDirectSpaceState3D。
## 九宫格顺序固定，逐个 cell 累加修正量。
static func resolve_blocker(
	position: Vector2,
	radius: float,
	grid: FlowFieldGrid
) -> Vector2:
	var correction := Vector2.ZERO
	if radius <= 0.0:
		return correction
	var half := grid.get_cell_size() * 0.5
	var center_cell := grid.world_to_cell(position)
	for offset_z in range(-1, 2):
		for offset_x in range(-1, 2):
			var cell := Vector2i(center_cell.x + offset_x, center_cell.y + offset_z)
			if not grid.is_blocked(cell):
				continue
			var cell_center := grid.cell_to_world(cell)
			var probe := position + correction
			var closest := Vector2(
				clampf(probe.x, cell_center.x - half, cell_center.x + half),
				clampf(probe.y, cell_center.y - half, cell_center.y + half)
			)
			var offset := probe - closest
			var distance_squared := offset.length_squared()
			if distance_squared >= radius * radius:
				continue
			if distance_squared <= 0.000001:
				var to_center := probe - cell_center
				var push_x := (half + radius) - absf(to_center.x)
				var push_z := (half + radius) - absf(to_center.y)
				if push_x <= push_z:
					correction.x += push_x if to_center.x >= 0.0 else -push_x
				else:
					correction.y += push_z if to_center.y >= 0.0 else -push_z
				continue
			var distance := sqrt(distance_squared)
			correction += offset / distance * (radius - distance)
	return correction
```

- [ ] **Step 2: 创建 `tools/validation/validate_sim_collision.gd`**

```gdscript
extends SceneTree

const SimCollisionScript = preload("res://scripts/sim/sim_collision.gd")
const FlowFieldGridScript = preload("res://scripts/sim/flow_field_grid.gd")
const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_pair_separation(failures)
	_check_matches_naive_reference(failures)
	_check_traversal_order_stability(failures)
	_check_degenerate_overlap(failures)
	_check_circle_push(failures)
	_check_blocker_pushout(failures)
	_finish(failures)

func _check_pair_separation(failures: Array[String]) -> void:
	var positions := PackedVector2Array([Vector2(0.0, 0.0), Vector2(0.4, 0.0)])
	var radii := PackedFloat32Array([0.42, 0.42])
	var displacement := SimCollisionScript.accumulate_separation(
		positions, radii, 2, SimCollisionScript.DEFAULT_HASH_CELL_SIZE, 1.0
	)
	_expect(
		is_equal_approx(displacement[0].x, -displacement[1].x),
		"an overlapping pair must separate symmetrically",
		failures
	)
	_expect(displacement[0].x < 0.0, "the lower index must be pushed away from the higher", failures)
	var separated := (positions[1] + displacement[1]) - (positions[0] + displacement[0])
	_expect(
		absf(separated.length() - 0.84) < 0.0001,
		"a fully applied separation must reach the summed radii",
		failures
	)
	var untouched := SimCollisionScript.accumulate_separation(
		PackedVector2Array([Vector2.ZERO, Vector2(3.0, 0.0)]),
		radii,
		2,
		SimCollisionScript.DEFAULT_HASH_CELL_SIZE,
		1.0
	)
	_expect(
		untouched[0] == Vector2.ZERO and untouched[1] == Vector2.ZERO,
		"non-overlapping circles must produce no displacement",
		failures
	)

func _check_matches_naive_reference(failures: Array[String]) -> void:
	var rng = DeterministicRngScript.new()
	rng.seed_streams(20260807)
	var count := 300
	var positions := PackedVector2Array()
	var radii := PackedFloat32Array()
	for _index in range(count):
		positions.append(Vector2(
			rng.next_range(DeterministicRngScript.Stream.ZOMBIE_SPAWN, -8.0, 8.0),
			rng.next_range(DeterministicRngScript.Stream.ZOMBIE_SPAWN, -6.0, 6.0)
		))
		radii.append(0.42)
	var hashed := SimCollisionScript.accumulate_separation(
		positions, radii, count, SimCollisionScript.DEFAULT_HASH_CELL_SIZE, 0.5
	)
	var naive := _naive_separation(positions, radii, count, 0.5)
	var mismatches := 0
	for index in range(count):
		if not hashed[index].is_equal_approx(naive[index]):
			mismatches += 1
	_expect(
		mismatches == 0,
		"spatial hash separation must equal the ascending-order naive reference (%d mismatches)" % mismatches,
		failures
	)

func _check_traversal_order_stability(failures: Array[String]) -> void:
	var rng = DeterministicRngScript.new()
	rng.seed_streams(7)
	var count := 200
	var positions := PackedVector2Array()
	var radii := PackedFloat32Array()
	for _index in range(count):
		positions.append(Vector2(
			rng.next_range(DeterministicRngScript.Stream.ZOMBIE_WANDER, -3.0, 3.0),
			rng.next_range(DeterministicRngScript.Stream.ZOMBIE_WANDER, -3.0, 3.0)
		))
		radii.append(0.42)
	var first := SimCollisionScript.accumulate_separation(
		positions, radii, count, SimCollisionScript.DEFAULT_HASH_CELL_SIZE, 0.5
	)
	for _repeat in range(8):
		var again := SimCollisionScript.accumulate_separation(
			positions, radii, count, SimCollisionScript.DEFAULT_HASH_CELL_SIZE, 0.5
		)
		_expect(again == first, "repeated resolution must be bit-identical", failures)
	var buckets := SimCollisionScript.build_spatial_hash(
		positions, count, SimCollisionScript.DEFAULT_HASH_CELL_SIZE
	)
	var ascending := true
	for key in buckets.keys():
		var bucket: PackedInt32Array = buckets[key]
		for slot in range(1, bucket.size()):
			if bucket[slot] <= bucket[slot - 1]:
				ascending = false
	_expect(ascending, "every hash bucket must hold ascending entity indices", failures)

func _check_degenerate_overlap(failures: Array[String]) -> void:
	var positions := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	var radii := PackedFloat32Array([0.42, 0.42, 0.42])
	var displacement := SimCollisionScript.accumulate_separation(
		positions, radii, 3, SimCollisionScript.DEFAULT_HASH_CELL_SIZE, 1.0
	)
	_expect(
		displacement[0].y == 0.0 and displacement[1].y == 0.0 and displacement[2].y == 0.0,
		"exactly coincident circles must resolve along a fixed axis",
		failures
	)
	_expect(
		displacement[0].x < displacement[2].x,
		"coincident circles must still fan out by ascending index",
		failures
	)

func _check_circle_push(failures: Array[String]) -> void:
	var push := SimCollisionScript.resolve_circle_push(
		Vector2(0.2, 0.0), 0.42, Vector2.ZERO, 0.45
	)
	_expect(push.x > 0.0 and push.y == 0.0, "the zombie must be pushed away from the player", failures)
	_expect(
		absf((Vector2(0.2, 0.0) + push).length() - 0.87) < 0.0001,
		"the push must exactly clear the summed radii",
		failures
	)
	_expect(
		SimCollisionScript.resolve_circle_push(
			Vector2(5.0, 0.0), 0.42, Vector2.ZERO, 0.45
		) == Vector2.ZERO,
		"a distant player must not push the zombie",
		failures
	)

func _check_blocker_pushout(failures: Array[String]) -> void:
	var grid = FlowFieldGridScript.new()
	grid.configure(Vector2(-4.5, -4.5), 1.0, 9, 9)
	grid.set_blocked(grid.world_to_cell(Vector2(0.0, 0.0)), true)
	var outside := SimCollisionScript.resolve_blocker(Vector2(2.5, 2.5), 0.42, grid)
	_expect(outside == Vector2.ZERO, "a circle clear of every blocker must not move", failures)
	var grazing := Vector2(0.8, 0.0)
	var correction := SimCollisionScript.resolve_blocker(grazing, 0.42, grid)
	_expect(correction.x > 0.0, "an overlapping circle must be pushed out of the blocked cell", failures)
	var resolved := grazing + correction
	_expect(
		resolved.x >= 0.5 + 0.42 - 0.0001,
		"the resolved circle must clear the blocked cell face",
		failures
	)
	var inside := SimCollisionScript.resolve_blocker(Vector2(0.1, 0.0), 0.42, grid)
	_expect(
		absf(Vector2(0.1, 0.0).x + inside.x) >= 0.5 + 0.42 - 0.0001 or
		absf(Vector2(0.1, 0.0).y + inside.y) >= 0.5 + 0.42 - 0.0001,
		"a circle centred inside a blocker must be ejected along the shallowest axis",
		failures
	)
	var repeated := SimCollisionScript.resolve_blocker(grazing, 0.42, grid)
	_expect(repeated == correction, "blocker resolution must be bit-identical across calls", failures)

func _naive_separation(
	positions: PackedVector2Array,
	radii: PackedFloat32Array,
	count: int,
	ratio: float
) -> PackedVector2Array:
	var displacement := PackedVector2Array()
	displacement.resize(count)
	displacement.fill(Vector2.ZERO)
	for index in range(count):
		for other_index in range(index + 1, count):
			var offset: Vector2 = positions[other_index] - positions[index]
			var combined: float = radii[index] + radii[other_index]
			var distance_squared := offset.length_squared()
			if distance_squared >= combined * combined:
				continue
			var push := Vector2.ZERO
			if distance_squared <= 0.000001:
				push = Vector2(combined * 0.5 * ratio, 0.0)
			else:
				var distance := sqrt(distance_squared)
				push = offset / distance * ((combined - distance) * 0.5 * ratio)
			displacement[index] -= push
			displacement[other_index] += push
	return displacement

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_sim_collision: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 3: 运行验证脚本与静态检查**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_sim_collision.gd
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
```

Expected: 打印 `validate_sim_collision: PASS`，退出码 0；编辑器导入检查退出码 0。

- [ ] **Step 4: 确认没有引入物理查询**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
rg -n "PhysicsDirectSpaceState3D|PhysicsRayQueryParameters3D|PhysicsShapeQueryParameters3D|intersect_ray|intersect_shape" \
  scripts/sim || echo "sim layer performs no physics queries"
```

Expected: 输出 `sim layer performs no physics queries`。

- [ ] **Step 5: 提交**

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add scripts/sim/sim_collision.gd tools/validation/validate_sim_collision.gd
git commit -m "feat: add deterministic circle collision resolver"
```

Expected: 提交只包含 `sim_collision.gd`、验证脚本及其 `.uid`。

---

### Task 4: SimWorld 结构化状态与僵尸推进

**Files:**
- Create: `scripts/sim/sim_world.gd`
- Modify: `scripts/combat/melee_attack_cycle.gd:1-33`
- Modify: `scripts/combat/zombie_target_selector.gd:1-3`

**Interfaces:**
- Consumes: `SimClock.TICK_SECONDS`、`DeterministicRng.Stream`、`DeterministicRng.next_range()`、`next_int_range()`、`next_unit_float()`、`FlowFieldGrid.configure()` 全套、`FlowField.setup()` / `update()` / `get_direction()`、`SimCollision.accumulate_separation()` / `resolve_circle_push()` / `resolve_blocker()`、`ZombieBehaviorMath.State`、`next_state()`、`wander_point()`、`arrive_velocity()`、`approach_stop_range()`、`facing_yaw()`、`HitResponseMath.knockback_velocity()`。
- Produces:
  - `MeleeAttackCycle.STATE_COOLDOWN: int = 0`、`STATE_WINDUP: int = 1`、`STATE_PENDING: int = 2`、`STATE_SIZE: int = 3`
  - `MeleeAttackCycle.TickOutcome { NONE = 0, WINDUP_STARTED = 1, ATTACK_LANDED = 2 }`
  - `MeleeAttackCycle.ticks_for_seconds(seconds: float, tick_seconds: float) -> int`（静态）
  - `MeleeAttackCycle.tick_state(state: PackedInt32Array, offset: int, cooldown_ticks: int, windup_ticks: int, target_in_range: bool, target_alive: bool) -> int`（静态）
  - `MeleeAttackCycle.cancel_state(state: PackedInt32Array, offset: int) -> void`（静态）
  - `SimWorld.MAX_PLAYER_SLOTS: int = 4`、`NO_TARGET_SLOT: int = 255`、`STATE_DEAD: int = 3`、`HEALTH_SCALE: int = 100`、`POSITION_QUANTIZATION: float = 1000.0`、`ZOMBIE_RADIUS: float = 0.42`、`PLAYER_RADIUS: float = 0.45`
  - `SimWorld.configure(grid_origin_xz: Vector2, grid_cell_size: float, grid_width: int, grid_height: int) -> void`
  - `SimWorld.reset(room_seed: int) -> void`
  - `SimWorld.set_default_move_speed(value: float) -> void`
  - `SimWorld.set_perception_range(value: float) -> void`（僵尸感知半径由装配方注入，不是常量；见 Step 3 的说明）
  - `SimWorld.get_rng() -> DeterministicRng`、`get_grid() -> FlowFieldGrid`、`get_flow_field() -> FlowField`
  - `SimWorld.get_tick() -> int`、`get_zombie_count() -> int`、`get_next_entity_id() -> int`
  - `SimWorld.get_pending_spawn_capacity() -> int`（已排队但尚未在 tick 中兑现的生成名额）
  - `SimWorld.get_zombie_id_array() -> PackedInt32Array`、`index_of_zombie(zombie_id_value: int) -> int`
  - `SimWorld.get_zombie_position(index: int) -> Vector2`、`get_zombie_previous_position(index: int) -> Vector2`
  - `SimWorld.get_zombie_height(index: int) -> float`、`get_zombie_previous_height(index: int) -> float`
  - `SimWorld.get_zombie_facing(index: int) -> float`、`get_zombie_previous_facing(index: int) -> float`
  - `SimWorld.get_zombie_state(index: int) -> int`、`get_zombie_health(index: int) -> int`、`get_zombie_max_health(index: int) -> int`
  - `SimWorld.spawn_zombie(position_xz: Vector2, facing_yaw: float, max_health_points: float) -> int`
  - `SimWorld.queue_spawn_wave(centers: PackedVector2Array, minimum_per_center: int, maximum_per_center: int, capacity: int, radius: float, minimum_spacing: float, max_health_points: float) -> void`
  - `SimWorld.set_player_snapshot(slot: int, position_xz: Vector2, alive: bool, present: bool) -> void`
  - `SimWorld.get_player_position(slot: int) -> Vector2`、`is_player_alive(slot: int) -> bool`、`is_player_present(slot: int) -> bool`
  - `SimWorld.set_blocker_world_rect(min_xz: Vector2, max_xz: Vector2, blocked: bool) -> void`
  - `SimWorld.line_is_clear(from_xz: Vector2, to_xz: Vector2) -> bool`
  - `SimWorld.apply_zombie_damage(index: int, damage_points: int, hit_position: Vector2, hit_height: float, direction: Vector2, zone: StringName) -> bool`
  - `SimWorld.step_tick() -> void`
  - `SimWorld.tick_hit_events: Array`（元素为 `{zombie_id: int, position: Vector2, height: float, direction: Vector2, damage: float, zone: StringName, killed: bool}`）
  - `SimWorld.tick_death_events: PackedInt32Array`、`SimWorld.tick_spawn_events: PackedInt32Array`
  - `SimWorld.tick_player_damage_events: Array`（元素为 `{kind: StringName, zombie_id: int, slot: int, damage: float, origin: Vector2}`，`kind` 取 `&"zombie_windup"` 或 `&"zombie_hit"`）

- [ ] **Step 1: 给 `MeleeAttackCycle` 增加基于 tick 的无分配静态 API**

在 `scripts/combat/melee_attack_cycle.gd` 的 `cancel_pending()` 之后追加。既有实例 API 一行不改，玩家近战与验证脚本继续使用它。

```gdscript

## ---- 模拟层：基于 tick 的无分配变体 ----
## 300 只僵尸各自持有一个 MeleeAttackCycle 实例会带来 300 次分配与
## 不确定的对象顺序，因此模拟层把周期状态放进 SimWorld 的 PackedInt32Array，
## 由下面这组静态函数原地推进。语义与上面的实例版本逐条对应。
const STATE_COOLDOWN := 0
const STATE_WINDUP := 1
const STATE_PENDING := 2
const STATE_SIZE := 3

enum TickOutcome {
	NONE,
	WINDUP_STARTED,
	ATTACK_LANDED,
}

static func ticks_for_seconds(seconds: float, tick_seconds: float) -> int:
	return maxi(int(ceil(maxf(seconds, 0.0) / maxf(tick_seconds, 0.000001))), 0)

static func tick_state(
	state: PackedInt32Array,
	offset: int,
	cooldown_ticks: int,
	windup_ticks: int,
	target_in_range: bool,
	target_alive: bool
) -> int:
	var cooldown_remaining := maxi(state[offset + STATE_COOLDOWN] - 1, 0)
	state[offset + STATE_COOLDOWN] = cooldown_remaining
	if state[offset + STATE_PENDING] == 1:
		var windup_remaining := maxi(state[offset + STATE_WINDUP] - 1, 0)
		state[offset + STATE_WINDUP] = windup_remaining
		if windup_remaining > 0:
			return TickOutcome.NONE
		state[offset + STATE_PENDING] = 0
		if target_in_range and target_alive:
			return TickOutcome.ATTACK_LANDED
		return TickOutcome.NONE
	if target_in_range and target_alive and cooldown_remaining <= 0:
		state[offset + STATE_PENDING] = 1
		state[offset + STATE_WINDUP] = maxi(windup_ticks, 0)
		state[offset + STATE_COOLDOWN] = maxi(cooldown_ticks, 1)
		return TickOutcome.WINDUP_STARTED
	return TickOutcome.NONE

static func cancel_state(state: PackedInt32Array, offset: int) -> void:
	state[offset + STATE_PENDING] = 0
	state[offset + STATE_WINDUP] = 0
```

- [ ] **Step 2: 在 `ZombieTargetSelector` 顶部标注模拟层镜像**

把 `scripts/combat/zombie_target_selector.gd` 的前两行改为：

```gdscript
extends RefCounted
class_name ZombieTargetSelector

## 表现层与工具脚本使用的节点版目标选择。
## 模拟层不使用本文件：SimWorld._select_target_slot() 在量化后的玩家快照上
## 复刻同一语义（最近优先 + switch_margin 迟滞 + 感知半径过滤）。
## 两处语义必须同步修改。
```

- [ ] **Step 3: 创建 `scripts/sim/sim_world.gd`**

```gdscript
extends RefCounted
class_name SimWorld

## 全部模拟状态的唯一持有者。结构化数组（SoA），不持有任何 Node。
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")
const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")
const FlowFieldGridScript = preload("res://scripts/sim/flow_field_grid.gd")
const FlowFieldScript = preload("res://scripts/sim/flow_field.gd")
const SimCollisionScript = preload("res://scripts/sim/sim_collision.gd")
const ZombieBehaviorMathScript = preload("res://scripts/combat/zombie_behavior_math.gd")
const MeleeAttackCycleScript = preload("res://scripts/combat/melee_attack_cycle.gd")
const HitResponseMathScript = preload("res://scripts/combat/hit_response_math.gd")

const MAX_PLAYER_SLOTS := 4
const NO_TARGET_SLOT := 255
const STATE_DEAD := 3
const HEALTH_SCALE := 100
const POSITION_QUANTIZATION := 1000.0

## 与 Godot 的 physics/3d/default_gravity 引擎缺省值一致；project.godot 未覆盖该项
## （基线的 zombie_target.gd 是用 ProjectSettings.get_setting(..., 9.8) 读到同一个缺省值的），
## 模拟层不读 ProjectSettings，因此在此固化。
const SIM_GRAVITY := 9.8

const ZOMBIE_RADIUS := 0.42
const PLAYER_RADIUS := 0.45
const ZOMBIE_SEPARATION_RATIO := 0.5

## 感知半径不是常量：基线 spawn_wave() 会用 DemoArena.wave_perception_range（默认 60.0）
## 覆盖 ZombieTarget.tscn 的导出默认值 7.0，波次僵尸实际用的是 60.0。
## 若在此把 7.0 固化成常量，僵尸只会在 7 m 内才注意到玩家，
## 而生成角在 (±19, ±14)、场地 48 × 38，新生成的僵尸会原地游荡不再汇聚。
## 因此由装配方（DemoArena._setup_simulation()）通过 set_perception_range() 注入。
const DEFAULT_PERCEPTION_RANGE := 60.0
var perception_range := DEFAULT_PERCEPTION_RANGE

# 下列数值逐字取自 scenes/targets/ZombieTarget.tscn 与 zombie_target.gd 的导出默认值。
const ZOMBIE_PERCEPTION_EXIT_MARGIN := 1.0
const ZOMBIE_TARGET_SWITCH_MARGIN := 0.5
const ZOMBIE_ATTACK_RANGE := 1.45
const ZOMBIE_ATTACK_DAMAGE := 10.0
const ZOMBIE_WANDER_SPEED := 0.55
const ZOMBIE_WANDER_RADIUS := 3.5
const ZOMBIE_WANDER_ARRIVE_RANGE := 0.25
const ZOMBIE_WANDER_SLOW_RADIUS := 0.8
const ZOMBIE_PERCEPTION_SLOW_RADIUS := 1.5
const ZOMBIE_MOVE_ACCELERATION := 5.0
const ZOMBIE_GROUND_DRAG := 11.0
const ZOMBIE_KNOCKBACK_IMPULSE := 6.0
const ZOMBIE_KNOCKBACK_VERTICAL_BIAS := 0.05
const DEFAULT_PERCEPTION_MOVE_SPEED := 1.30

# 秒 -> tick（TICK_SECONDS = 0.05）
const ZOMBIE_ATTACK_COOLDOWN_TICKS := 28   # 1.40 s
const ZOMBIE_ATTACK_WINDUP_TICKS := 10     # 0.50 s
const ZOMBIE_WANDER_PAUSE_MIN_TICKS := 8   # 0.40 s
const ZOMBIE_WANDER_PAUSE_MAX_TICKS := 24  # 1.20 s

# 下列常量新增，基线无对应导出项：被击中后的短暂僵直，用于取消攻击蓄力。
# 基线的 ZombieTarget 只有 _play_hit_reaction() 的纯视觉反馈，没有僵直状态。
const ZOMBIE_HIT_STUN_TICKS := 4           # 0.20 s

# ---- spec 指定的 SoA 字段 ----
var zombie_id := PackedInt32Array()
var zombie_position := PackedVector2Array()
var zombie_height := PackedFloat32Array()
var zombie_facing := PackedFloat32Array()
var zombie_health := PackedInt32Array()
var zombie_state := PackedByteArray()
var zombie_target_slot := PackedByteArray()

# ---- 推进与插值所需的内部字段 ----
var zombie_max_health := PackedInt32Array()
var zombie_previous_position := PackedVector2Array()
var zombie_previous_height := PackedFloat32Array()
var zombie_previous_facing := PackedFloat32Array()
var zombie_velocity := PackedVector2Array()
var zombie_vertical_velocity := PackedFloat32Array()
var zombie_radius := PackedFloat32Array()
var zombie_home := PackedVector2Array()
var zombie_wander_target := PackedVector2Array()
var zombie_wander_pause_ticks := PackedInt32Array()
var zombie_hit_stun_ticks := PackedInt32Array()
var zombie_move_speed := PackedFloat32Array()
var zombie_attack_state := PackedInt32Array()

# ---- 玩家量化快照（只读输入） ----
var player_position_quantized := PackedInt32Array()
var player_alive := PackedByteArray()
var player_present := PackedByteArray()

# ---- 子系统 ----
var rng: DeterministicRng
var grid: FlowFieldGrid
var flow_field: FlowField

var tick_index := 0
var next_entity_id := 1
var default_move_speed := DEFAULT_PERCEPTION_MOVE_SPEED
var pending_spawn_waves: Array = []
## 已排队但尚未在 tick 中兑现的生成名额。表现层用它把「排队中」计入活跃数，
## 避免同一物理帧内两次排队各自看到同一个 remaining_capacity 而突破上限。
var pending_spawn_capacity := 0

# ---- 本 tick 产生的表现层事件（每 tick 开头清空） ----
var tick_hit_events: Array = []
var tick_death_events := PackedInt32Array()
var tick_spawn_events := PackedInt32Array()
var tick_player_damage_events: Array = []

func _init() -> void:
	rng = DeterministicRngScript.new()
	grid = FlowFieldGridScript.new()
	flow_field = FlowFieldScript.new()
	player_position_quantized.resize(MAX_PLAYER_SLOTS * 2)
	player_position_quantized.fill(0)
	player_alive.resize(MAX_PLAYER_SLOTS)
	player_alive.fill(0)
	player_present.resize(MAX_PLAYER_SLOTS)
	player_present.fill(0)

func configure(
	grid_origin_xz: Vector2,
	grid_cell_size: float,
	grid_width: int,
	grid_height: int
) -> void:
	grid.configure(grid_origin_xz, grid_cell_size, grid_width, grid_height)
	flow_field.setup(grid)

## 清空全部实体状态并按房间种子重置随机流。阻挡网格保留（静态几何不随开局变化）。
func reset(room_seed: int) -> void:
	rng.seed_streams(room_seed)
	tick_index = 0
	next_entity_id = 1
	zombie_id = PackedInt32Array()
	zombie_position = PackedVector2Array()
	zombie_height = PackedFloat32Array()
	zombie_facing = PackedFloat32Array()
	zombie_health = PackedInt32Array()
	zombie_state = PackedByteArray()
	zombie_target_slot = PackedByteArray()
	zombie_max_health = PackedInt32Array()
	zombie_previous_position = PackedVector2Array()
	zombie_previous_height = PackedFloat32Array()
	zombie_previous_facing = PackedFloat32Array()
	zombie_velocity = PackedVector2Array()
	zombie_vertical_velocity = PackedFloat32Array()
	zombie_radius = PackedFloat32Array()
	zombie_home = PackedVector2Array()
	zombie_wander_target = PackedVector2Array()
	zombie_wander_pause_ticks = PackedInt32Array()
	zombie_hit_stun_ticks = PackedInt32Array()
	zombie_move_speed = PackedFloat32Array()
	zombie_attack_state = PackedInt32Array()
	player_position_quantized.fill(0)
	player_alive.fill(0)
	player_present.fill(0)
	pending_spawn_waves = []
	pending_spawn_capacity = 0
	_clear_tick_events()
	grid.mark_dirty()
	flow_field.setup(grid)

func set_default_move_speed(value: float) -> void:
	default_move_speed = maxf(value, 0.0)

## 感知半径由装配方注入（DemoArena 传入 wave_perception_range，基线默认 60.0）。
func set_perception_range(value: float) -> void:
	perception_range = maxf(value, 0.0)

func get_rng() -> DeterministicRng:
	return rng

func get_grid() -> FlowFieldGrid:
	return grid

func get_flow_field() -> FlowField:
	return flow_field

func get_tick() -> int:
	return tick_index

func get_zombie_count() -> int:
	return zombie_id.size()

func get_next_entity_id() -> int:
	return next_entity_id

func get_pending_spawn_capacity() -> int:
	return pending_spawn_capacity

func get_zombie_id_array() -> PackedInt32Array:
	return zombie_id

## id 单调递增且数组保持顺序，因此可以直接二分。
func index_of_zombie(zombie_id_value: int) -> int:
	var index := zombie_id.bsearch(zombie_id_value, true)
	if index < 0 or index >= zombie_id.size():
		return -1
	return index if zombie_id[index] == zombie_id_value else -1

func get_zombie_position(index: int) -> Vector2:
	return zombie_position[index]

func get_zombie_previous_position(index: int) -> Vector2:
	return zombie_previous_position[index]

func get_zombie_height(index: int) -> float:
	return zombie_height[index]

func get_zombie_previous_height(index: int) -> float:
	return zombie_previous_height[index]

func get_zombie_facing(index: int) -> float:
	return zombie_facing[index]

func get_zombie_previous_facing(index: int) -> float:
	return zombie_previous_facing[index]

func get_zombie_state(index: int) -> int:
	return zombie_state[index]

func get_zombie_health(index: int) -> int:
	return zombie_health[index]

func get_zombie_max_health(index: int) -> int:
	return zombie_max_health[index]

## 实体 id 由单调递增计数器分配，永不复用。
func spawn_zombie(
	position_xz: Vector2,
	facing_yaw: float,
	max_health_points: float
) -> int:
	var new_id := next_entity_id
	next_entity_id += 1
	var health_points := maxi(
		roundi(maxf(max_health_points, 0.0) * float(HEALTH_SCALE)),
		1
	)
	zombie_id.append(new_id)
	zombie_position.append(position_xz)
	zombie_height.append(0.0)
	zombie_facing.append(facing_yaw)
	zombie_health.append(health_points)
	zombie_state.append(ZombieBehaviorMathScript.State.WANDER)
	zombie_target_slot.append(NO_TARGET_SLOT)
	zombie_max_health.append(health_points)
	zombie_previous_position.append(position_xz)
	zombie_previous_height.append(0.0)
	zombie_previous_facing.append(facing_yaw)
	zombie_velocity.append(Vector2.ZERO)
	zombie_vertical_velocity.append(0.0)
	zombie_radius.append(ZOMBIE_RADIUS)
	zombie_home.append(position_xz)
	zombie_wander_target.append(position_xz)
	zombie_wander_pause_ticks.append(0)
	zombie_hit_stun_ticks.append(0)
	zombie_move_speed.append(default_move_speed)
	for _state_slot in range(MeleeAttackCycleScript.STATE_SIZE):
		zombie_attack_state.append(0)
	tick_spawn_events.append(new_id)
	_select_wander_target(zombie_id.size() - 1)
	return new_id

## 波次生成的全部随机取自 Stream.ZOMBIE_SPAWN，并在下一 tick 开头统一执行，
## 使「哪一 tick 生成了哪些僵尸」本身也是确定的。
func queue_spawn_wave(
	centers: PackedVector2Array,
	minimum_per_center: int,
	maximum_per_center: int,
	capacity: int,
	radius: float,
	minimum_spacing: float,
	max_health_points: float
) -> void:
	pending_spawn_waves.append({
		"centers": centers.duplicate(),
		"minimum_per_center": minimum_per_center,
		"maximum_per_center": maximum_per_center,
		"capacity": capacity,
		"radius": radius,
		"minimum_spacing": minimum_spacing,
		"max_health_points": max_health_points,
	})
	pending_spawn_capacity += maxi(capacity, 0)

func set_player_snapshot(
	slot: int,
	position_xz: Vector2,
	alive: bool,
	present: bool
) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	player_position_quantized[slot * 2] = roundi(position_xz.x * POSITION_QUANTIZATION)
	player_position_quantized[slot * 2 + 1] = roundi(position_xz.y * POSITION_QUANTIZATION)
	player_alive[slot] = 1 if alive else 0
	player_present[slot] = 1 if present else 0

func get_player_position(slot: int) -> Vector2:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return Vector2.ZERO
	return Vector2(
		float(player_position_quantized[slot * 2]) / POSITION_QUANTIZATION,
		float(player_position_quantized[slot * 2 + 1]) / POSITION_QUANTIZATION
	)

func is_player_alive(slot: int) -> bool:
	return slot >= 0 and slot < MAX_PLAYER_SLOTS and player_alive[slot] == 1

func is_player_present(slot: int) -> bool:
	return slot >= 0 and slot < MAX_PLAYER_SLOTS and player_present[slot] == 1

## 任何运行时增删阻挡几何的系统都必须调用它，否则流场会停留在过期的通行图上。
func set_blocker_world_rect(min_xz: Vector2, max_xz: Vector2, blocked: bool) -> void:
	grid.set_blocked_world_rect(min_xz, max_xz, blocked)

## 整数 Bresenham 逐 cell 判定视线；终点 cell 自身不算阻挡。
func line_is_clear(from_xz: Vector2, to_xz: Vector2) -> bool:
	var from_cell := grid.world_to_cell(from_xz)
	var to_cell := grid.world_to_cell(to_xz)
	var delta_x := absi(to_cell.x - from_cell.x)
	var delta_y := absi(to_cell.y - from_cell.y)
	var step_x := 1 if to_cell.x >= from_cell.x else -1
	var step_y := 1 if to_cell.y >= from_cell.y else -1
	var error := delta_x - delta_y
	var current := from_cell
	for _step_index in range(delta_x + delta_y + 1):
		if current == to_cell:
			return true
		if current != from_cell and grid.is_blocked(current):
			return false
		var doubled_error := error * 2
		if doubled_error > -delta_y:
			error -= delta_y
			current.x += step_x
		if doubled_error < delta_x:
			error += delta_x
			current.y += step_y
	return true

## 唯一的僵尸掉血入口。damage_points 已是 HEALTH_SCALE 单位的整数。
func apply_zombie_damage(
	index: int,
	damage_points: int,
	hit_position: Vector2,
	hit_height: float,
	direction: Vector2,
	zone: StringName
) -> bool:
	if index < 0 or index >= zombie_id.size():
		return false
	if zombie_state[index] == STATE_DEAD:
		return false
	var applied := mini(maxi(damage_points, 0), zombie_health[index])
	if applied <= 0:
		return false
	zombie_health[index] -= applied
	var impulse := HitResponseMathScript.knockback_velocity(
		Vector3(direction.x, 0.0, direction.y),
		ZOMBIE_KNOCKBACK_IMPULSE,
		1.0,
		ZOMBIE_KNOCKBACK_VERTICAL_BIAS
	)
	zombie_velocity[index] += Vector2(impulse.x, impulse.z)
	zombie_vertical_velocity[index] += impulse.y
	var killed := zombie_health[index] <= 0
	if not killed:
		zombie_hit_stun_ticks[index] = ZOMBIE_HIT_STUN_TICKS
		MeleeAttackCycleScript.cancel_state(
			zombie_attack_state,
			index * MeleeAttackCycleScript.STATE_SIZE
		)
	tick_hit_events.append({
		"zombie_id": zombie_id[index],
		"position": hit_position,
		"height": hit_height,
		"direction": direction,
		"damage": float(applied) / float(HEALTH_SCALE),
		"zone": zone,
		"killed": killed,
	})
	if killed:
		zombie_state[index] = STATE_DEAD
		zombie_radius[index] = 0.0
		zombie_velocity[index] = Vector2.ZERO
		tick_death_events.append(zombie_id[index])
	return true

## 推进一个模拟 tick。不接收任何真实帧时长形参：时间步长恒为 SimClock.TICK_SECONDS。
func step_tick() -> void:
	tick_index += 1
	_clear_tick_events()
	_apply_pending_spawn_waves()
	_update_flow_field()
	_update_zombies()
	_resolve_collisions()
	_resolve_zombie_attacks()
	_compact_dead()

func _clear_tick_events() -> void:
	tick_hit_events = []
	tick_death_events = PackedInt32Array()
	tick_spawn_events = PackedInt32Array()
	tick_player_damage_events = []

func _apply_pending_spawn_waves() -> void:
	pending_spawn_capacity = 0
	if pending_spawn_waves.is_empty():
		return
	var waves := pending_spawn_waves
	pending_spawn_waves = []
	for wave in waves:
		_spawn_wave(wave)

func _spawn_wave(wave: Dictionary) -> int:
	var spawn_stream: int = DeterministicRngScript.Stream.ZOMBIE_SPAWN
	var centers: PackedVector2Array = wave["centers"]
	var capacity: int = maxi(int(wave["capacity"]), 0)
	var radius: float = maxf(float(wave["radius"]), 0.0)
	var minimum_spacing: float = maxf(float(wave["minimum_spacing"]), 0.0)
	var max_health_points: float = float(wave["max_health_points"])
	var occupied := zombie_position.duplicate()
	var spawned := 0
	for center in centers:
		var requested := rng.next_int_range(
			spawn_stream,
			int(wave["minimum_per_center"]),
			int(wave["maximum_per_center"])
		)
		for _spawn_index in range(requested):
			if spawned >= capacity:
				return spawned
			var spawn_position := _sample_spawn_position(
				center, radius, minimum_spacing, occupied
			)
			var facing := rng.next_range(spawn_stream, 0.0, TAU)
			spawn_zombie(spawn_position, facing, max_health_points)
			occupied.append(spawn_position)
			spawned += 1
	return spawned

func _sample_spawn_position(
	center: Vector2,
	radius: float,
	minimum_spacing: float,
	occupied: PackedVector2Array
) -> Vector2:
	var spawn_stream: int = DeterministicRngScript.Stream.ZOMBIE_SPAWN
	var fallback := center
	for _attempt in range(16):
		var angle := rng.next_range(spawn_stream, 0.0, TAU)
		var sample_radius := sqrt(rng.next_unit_float(spawn_stream)) * radius
		var candidate := center + Vector2(
			cos(angle) * sample_radius,
			sin(angle) * sample_radius
		)
		fallback = candidate
		if _has_spawn_clearance(candidate, minimum_spacing, occupied):
			return candidate
	return fallback

func _has_spawn_clearance(
	candidate: Vector2,
	minimum_spacing: float,
	occupied: PackedVector2Array
) -> bool:
	for position in occupied:
		if candidate.distance_to(position) < minimum_spacing:
			return false
	return true

func _update_flow_field() -> void:
	var sources := PackedInt32Array()
	for slot in range(MAX_PLAYER_SLOTS):
		if player_present[slot] == 0 or player_alive[slot] == 0:
			continue
		var cell_index := grid.cell_index(grid.world_to_cell(get_player_position(slot)))
		if cell_index >= 0 and not sources.has(cell_index):
			sources.append(cell_index)
	sources.sort()
	flow_field.update(sources)

func _update_zombies() -> void:
	var count := zombie_id.size()
	var tick_seconds := SimClockScript.TICK_SECONDS
	for index in range(count):
		if zombie_state[index] == STATE_DEAD:
			continue
		zombie_previous_position[index] = zombie_position[index]
		zombie_previous_facing[index] = zombie_facing[index]
		zombie_previous_height[index] = zombie_height[index]
		zombie_hit_stun_ticks[index] = maxi(zombie_hit_stun_ticks[index] - 1, 0)

		var position := zombie_position[index]
		var target_slot := _select_target_slot(position, int(zombie_target_slot[index]))
		zombie_target_slot[index] = target_slot
		var target_alive := target_slot != NO_TARGET_SLOT
		var target_position := Vector2.ZERO
		var direction_to_target := Vector2.ZERO
		var distance_to_target := INF
		if target_alive:
			target_position = get_player_position(target_slot)
			direction_to_target = target_position - position
			distance_to_target = direction_to_target.length()
			if distance_to_target > 0.001:
				direction_to_target /= distance_to_target
		var attack_path_clear := (
			target_alive and
			distance_to_target <= ZOMBIE_ATTACK_RANGE and
			line_is_clear(position, target_position)
		)

		var previous_state := int(zombie_state[index])
		var next_state := ZombieBehaviorMathScript.next_state(
			previous_state,
			distance_to_target,
			target_alive,
			perception_range,
			ZOMBIE_PERCEPTION_EXIT_MARGIN,
			ZOMBIE_ATTACK_RANGE,
			attack_path_clear
		)
		zombie_state[index] = next_state
		if (
			previous_state == ZombieBehaviorMathScript.State.ATTACK and
			next_state != ZombieBehaviorMathScript.State.ATTACK
		):
			MeleeAttackCycleScript.cancel_state(
				zombie_attack_state,
				index * MeleeAttackCycleScript.STATE_SIZE
			)

		var target_velocity := Vector2.ZERO
		if zombie_hit_stun_ticks[index] <= 0:
			if next_state == ZombieBehaviorMathScript.State.WANDER:
				target_velocity = _wander_velocity(index)
			elif next_state == ZombieBehaviorMathScript.State.AWARE_APPROACH:
				target_velocity = _approach_velocity(
					index, distance_to_target, direction_to_target, attack_path_clear
				)

		var facing_direction := direction_to_target
		if (
			next_state == ZombieBehaviorMathScript.State.WANDER or
			(
				next_state == ZombieBehaviorMathScript.State.AWARE_APPROACH and
				target_velocity.length_squared() > 0.0001
			)
		):
			facing_direction = target_velocity
		if facing_direction.length_squared() > 0.0001:
			zombie_facing[index] = ZombieBehaviorMathScript.facing_yaw(
				Vector3(facing_direction.x, 0.0, facing_direction.y),
				zombie_facing[index]
			)

		var moving := target_velocity.length_squared() > 0.0001
		var rate := ZOMBIE_MOVE_ACCELERATION if moving else ZOMBIE_GROUND_DRAG
		var velocity := zombie_velocity[index]
		velocity.x = move_toward(velocity.x, target_velocity.x, rate * tick_seconds)
		velocity.y = move_toward(velocity.y, target_velocity.y, rate * tick_seconds)
		zombie_velocity[index] = velocity
		zombie_position[index] = position + velocity * tick_seconds

		var vertical_velocity := zombie_vertical_velocity[index]
		var height := zombie_height[index]
		if height > 0.0 or vertical_velocity > 0.0:
			vertical_velocity -= SIM_GRAVITY * tick_seconds
			height += vertical_velocity * tick_seconds
			if height <= 0.0:
				height = 0.0
				vertical_velocity = 0.0
		zombie_height[index] = height
		zombie_vertical_velocity[index] = vertical_velocity

## ZombieTargetSelector 语义在玩家槽位快照上的复刻：最近优先，
## 切换必须比当前目标近出 ZOMBIE_TARGET_SWITCH_MARGIN 才生效。
func _select_target_slot(position: Vector2, current_slot: int) -> int:
	var best_slot := NO_TARGET_SLOT
	var best_distance := INF
	if _slot_is_candidate(current_slot, position):
		best_slot = current_slot
		best_distance = position.distance_to(get_player_position(current_slot))
	for slot in range(MAX_PLAYER_SLOTS):
		if not _slot_is_candidate(slot, position):
			continue
		var distance := position.distance_to(get_player_position(slot))
		if distance + ZOMBIE_TARGET_SWITCH_MARGIN < best_distance:
			best_slot = slot
			best_distance = distance
	return best_slot

func _slot_is_candidate(slot: int, position: Vector2) -> bool:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return false
	if player_present[slot] == 0 or player_alive[slot] == 0:
		return false
	return position.distance_to(get_player_position(slot)) <= perception_range

func _select_wander_target(index: int) -> void:
	var wander_stream: int = DeterministicRngScript.Stream.ZOMBIE_WANDER
	var angle := rng.next_range(wander_stream, 0.0, TAU)
	var distance_ratio := rng.next_range(wander_stream, 0.35, 1.0)
	var home := zombie_home[index]
	var point := ZombieBehaviorMathScript.wander_point(
		Vector3(home.x, 0.0, home.y),
		angle,
		distance_ratio,
		ZOMBIE_WANDER_RADIUS
	)
	zombie_wander_target[index] = Vector2(point.x, point.z)

func _wander_velocity(index: int) -> Vector2:
	if zombie_wander_pause_ticks[index] > 0:
		zombie_wander_pause_ticks[index] -= 1
		if zombie_wander_pause_ticks[index] <= 0:
			_select_wander_target(index)
		return Vector2.ZERO
	var position := zombie_position[index]
	var target := zombie_wander_target[index]
	var velocity_3d := ZombieBehaviorMathScript.arrive_velocity(
		Vector3(position.x, 0.0, position.y),
		Vector3(target.x, 0.0, target.y),
		ZOMBIE_WANDER_ARRIVE_RANGE,
		ZOMBIE_WANDER_SPEED,
		ZOMBIE_WANDER_SLOW_RADIUS
	)
	var velocity := Vector2(velocity_3d.x, velocity_3d.z)
	if velocity == Vector2.ZERO:
		zombie_wander_pause_ticks[index] = rng.next_int_range(
			DeterministicRngScript.Stream.ZOMBIE_WANDER,
			ZOMBIE_WANDER_PAUSE_MIN_TICKS,
			ZOMBIE_WANDER_PAUSE_MAX_TICKS
		)
	return velocity

## 追击只查自己所在 cell 的方向向量，成本与僵尸数量无关。
## 流场不可达（例如被临时封死）时退回直线方向，行为与旧的导航不可用回退一致。
func _approach_velocity(
	index: int,
	distance_to_target: float,
	direction_to_target: Vector2,
	attack_path_clear: bool
) -> Vector2:
	var stop_range := ZombieBehaviorMathScript.approach_stop_range(
		distance_to_target, ZOMBIE_ATTACK_RANGE, attack_path_clear
	)
	var gap := distance_to_target - stop_range
	if gap <= 0.0:
		return Vector2.ZERO
	var speed_factor := clampf(gap / ZOMBIE_PERCEPTION_SLOW_RADIUS, 0.25, 1.0)
	var direction := flow_field.get_direction(
		grid.world_to_cell(zombie_position[index])
	)
	if direction.length_squared() <= 0.0001:
		direction = direction_to_target
	if direction.length_squared() <= 0.0001:
		return Vector2.ZERO
	return direction.normalized() * zombie_move_speed[index] * speed_factor

func _resolve_collisions() -> void:
	var count := zombie_id.size()
	if count == 0:
		return
	var displacement := SimCollisionScript.accumulate_separation(
		zombie_position,
		zombie_radius,
		count,
		SimCollisionScript.DEFAULT_HASH_CELL_SIZE,
		ZOMBIE_SEPARATION_RATIO
	)
	for index in range(count):
		if zombie_state[index] == STATE_DEAD:
			continue
		var radius := zombie_radius[index]
		var position := zombie_position[index] + displacement[index]
		for slot in range(MAX_PLAYER_SLOTS):
			if player_present[slot] == 0 or player_alive[slot] == 0:
				continue
			position += SimCollisionScript.resolve_circle_push(
				position, radius, get_player_position(slot), PLAYER_RADIUS
			)
		position += SimCollisionScript.resolve_blocker(position, radius, grid)
		zombie_position[index] = position

func _resolve_zombie_attacks() -> void:
	var count := zombie_id.size()
	for index in range(count):
		if zombie_state[index] == STATE_DEAD:
			continue
		var target_slot := int(zombie_target_slot[index])
		var target_alive := target_slot != NO_TARGET_SLOT and is_player_alive(target_slot)
		var target_in_range := false
		if target_alive:
			target_in_range = (
				zombie_state[index] == ZombieBehaviorMathScript.State.ATTACK and
				zombie_position[index].distance_to(get_player_position(target_slot))
					<= ZOMBIE_ATTACK_RANGE and
				zombie_hit_stun_ticks[index] <= 0
			)
		var outcome := MeleeAttackCycleScript.tick_state(
			zombie_attack_state,
			index * MeleeAttackCycleScript.STATE_SIZE,
			ZOMBIE_ATTACK_COOLDOWN_TICKS,
			ZOMBIE_ATTACK_WINDUP_TICKS,
			target_in_range,
			target_alive
		)
		if outcome == MeleeAttackCycleScript.TickOutcome.WINDUP_STARTED:
			tick_player_damage_events.append({
				"kind": &"zombie_windup",
				"zombie_id": zombie_id[index],
				"slot": target_slot,
				"damage": 0.0,
				"origin": zombie_position[index],
			})
		elif outcome == MeleeAttackCycleScript.TickOutcome.ATTACK_LANDED:
			tick_player_damage_events.append({
				"kind": &"zombie_hit",
				"zombie_id": zombie_id[index],
				"slot": target_slot,
				"damage": ZOMBIE_ATTACK_DAMAGE,
				"origin": zombie_position[index],
			})

## 按顺序压缩删除，保证下标顺序始终等于 id 升序。
func _compact_dead() -> void:
	var count := zombie_id.size()
	var survivor_count := 0
	for index in range(count):
		if zombie_state[index] != STATE_DEAD:
			survivor_count += 1
	if survivor_count == count:
		return
	var new_id := PackedInt32Array()
	var new_position := PackedVector2Array()
	var new_height := PackedFloat32Array()
	var new_facing := PackedFloat32Array()
	var new_health := PackedInt32Array()
	var new_state := PackedByteArray()
	var new_target_slot := PackedByteArray()
	var new_max_health := PackedInt32Array()
	var new_previous_position := PackedVector2Array()
	var new_previous_height := PackedFloat32Array()
	var new_previous_facing := PackedFloat32Array()
	var new_velocity := PackedVector2Array()
	var new_vertical_velocity := PackedFloat32Array()
	var new_radius := PackedFloat32Array()
	var new_home := PackedVector2Array()
	var new_wander_target := PackedVector2Array()
	var new_wander_pause_ticks := PackedInt32Array()
	var new_hit_stun_ticks := PackedInt32Array()
	var new_move_speed := PackedFloat32Array()
	var new_attack_state := PackedInt32Array()
	for index in range(count):
		if zombie_state[index] == STATE_DEAD:
			continue
		new_id.append(zombie_id[index])
		new_position.append(zombie_position[index])
		new_height.append(zombie_height[index])
		new_facing.append(zombie_facing[index])
		new_health.append(zombie_health[index])
		new_state.append(zombie_state[index])
		new_target_slot.append(zombie_target_slot[index])
		new_max_health.append(zombie_max_health[index])
		new_previous_position.append(zombie_previous_position[index])
		new_previous_height.append(zombie_previous_height[index])
		new_previous_facing.append(zombie_previous_facing[index])
		new_velocity.append(zombie_velocity[index])
		new_vertical_velocity.append(zombie_vertical_velocity[index])
		new_radius.append(zombie_radius[index])
		new_home.append(zombie_home[index])
		new_wander_target.append(zombie_wander_target[index])
		new_wander_pause_ticks.append(zombie_wander_pause_ticks[index])
		new_hit_stun_ticks.append(zombie_hit_stun_ticks[index])
		new_move_speed.append(zombie_move_speed[index])
		for state_slot in range(MeleeAttackCycleScript.STATE_SIZE):
			new_attack_state.append(
				zombie_attack_state[index * MeleeAttackCycleScript.STATE_SIZE + state_slot]
			)
	zombie_id = new_id
	zombie_position = new_position
	zombie_height = new_height
	zombie_facing = new_facing
	zombie_health = new_health
	zombie_state = new_state
	zombie_target_slot = new_target_slot
	zombie_max_health = new_max_health
	zombie_previous_position = new_previous_position
	zombie_previous_height = new_previous_height
	zombie_previous_facing = new_previous_facing
	zombie_velocity = new_velocity
	zombie_vertical_velocity = new_vertical_velocity
	zombie_radius = new_radius
	zombie_home = new_home
	zombie_wander_target = new_wander_target
	zombie_wander_pause_ticks = new_wander_pause_ticks
	zombie_hit_stun_ticks = new_hit_stun_ticks
	zombie_move_speed = new_move_speed
	zombie_attack_state = new_attack_state
```

- [ ] **Step 4: 运行静态检查并核对确定性闸门**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
rg -n "randf|randi|randomize|move_and_slide|NavigationAgent3D|get_tree\(|Time\." scripts/sim \
  || echo "sim layer keeps the determinism gate"
rg -n "\bdelta\b" scripts/sim | rg -v "^scripts/sim/sim_clock.gd:" \
  || echo "only sim_clock touches real delta"
rg -n "for .* in .*\.keys\(\)|for .* in buckets" scripts/sim || echo "no dictionary iteration in sim"
```

Expected: 编辑器导入检查退出码 0；三条搜索分别输出 `sim layer keeps the determinism gate`、`only sim_clock touches real delta` 与 `no dictionary iteration in sim`。第二条与 Task 1 Step 6 是同一条闸门（用词边界 `\bdelta\b`，因此不会误报 `line_is_clear()` 里的 `delta_x` / `delta_y`）：`sim_clock.gd` 的 `consume_frame(frame_delta)` 是唯一允许接触真实 delta 的边界函数，已按文件名排除；`sim_world.step_tick()` 等模拟函数都不得出现独立的 `delta` 形参。

- [ ] **Step 5: 冒烟推进 200 tick 并核对 id 与压缩顺序**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
cat > tools/validation/zw_sim_world_smoke.gd <<'EOF'
extends SceneTree

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	var world = SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(12345)
	world.set_perception_range(60.0)
	world.set_player_snapshot(0, Vector2(0.0, 5.0), true, true)
	world.queue_spawn_wave(
		PackedVector2Array([
			Vector2(-19.0, -14.0), Vector2(19.0, -14.0),
			Vector2(-19.0, 14.0), Vector2(19.0, 14.0),
		]),
		2, 3, 300, 1.75, 1.1, 50.0
	)
	for tick in range(200):
		world.set_player_snapshot(0, Vector2(sin(float(tick) * 0.05) * 4.0, 5.0), true, true)
		world.step_tick()
	var ascending := true
	for index in range(1, world.get_zombie_count()):
		if world.get_zombie_id_array()[index] <= world.get_zombie_id_array()[index - 1]:
			ascending = false
	var located := world.get_zombie_count() > 0 and world.index_of_zombie(
		world.get_zombie_id_array()[world.get_zombie_count() - 1]
	) == world.get_zombie_count() - 1
	print("zombies=%d ascending=%s lookup=%s tick=%d next_id=%d pending=%d" % [
		world.get_zombie_count(), ascending, located, world.get_tick(),
		world.get_next_entity_id(), world.get_pending_spawn_capacity()
	])
	quit(0)
EOF
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/zw_sim_world_smoke.gd
rm -f tools/validation/zw_sim_world_smoke.gd tools/validation/zw_sim_world_smoke.gd.uid
```

Expected: 输出形如 `zombies=8 ascending=true lookup=true tick=200 next_id=9 pending=0`；`zombies` 在 8 到 12 之间（每角 2–3 只），`ascending` 与 `lookup` 均为 `true`，`tick` 为 200，`pending` 为 0（排队的名额已在第一个 tick 兑现并清零）。冒烟脚本运行后必须删除，不进入提交；`.uid` 只有在编辑器导入过一次后才存在，因此用 `rm -f` 而不是 `rm`。

- [ ] **Step 6: 提交**

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git status --short
git add scripts/sim/sim_world.gd scripts/combat/melee_attack_cycle.gd \
  scripts/combat/zombie_target_selector.gd
git commit -m "feat: add structure-of-arrays simulation world"
```

Expected: `git status --short` 中不含 `tools/validation/zw_sim_world_smoke.gd`；提交只含 `sim_world.gd` 与两个既有战斗脚本的改动。

---

### Task 5: 伤害结算迁入模拟层

**Files:**
- Create: `scripts/sim/sim_hit_geometry.gd`
- Create: `scripts/sim/sim_combat.gd`
- Modify: `scripts/combat/weapons/weapon_spread_state.gd:33-57`
- Modify: `scripts/sim/sim_world.gd`（Task 4 创建，本任务追加武器档案、散布状态、事件队列，并替换 `step_tick()`）

**Interfaces:**
- Consumes: `SimWorld.apply_zombie_damage()`、`SimWorld.line_is_clear()`、`SimWorld.get_zombie_count()`、`get_zombie_position()`、`get_zombie_height()`、`get_zombie_state()`、`SimWorld.STATE_DEAD`（**仅 `sim_world.gd` 内部使用；`sim_combat.gd` 用自己的 `STATE_DEAD` 副本，不引用 `SimWorld`**）、`SimWorld.HEALTH_SCALE`、`ExplosionMath.damage_at_distance()`、`DeterministicRng.Stream.WEAPON_SPREAD`、`DeterministicRng.next_range()`。
- Produces:
  - `SimHitGeometry.ZONE_BODY: StringName = &"body"`
  - `SimHitGeometry.BODY_CENTER_HEIGHT: float = 1.1`、`BODY_RADIUS: float = 1.1`、`BODY_HALF_HEIGHT: float = 1.1`
  - `SimHitGeometry.aim_point_height(zombie_height: float) -> float`
  - `SimHitGeometry.contains_height(zombie_height: float, probe_height: float) -> bool`
  - `SimHitGeometry.zone_for_height(zombie_height: float, probe_height: float) -> StringName`
  - `SimHitGeometry.damage_multiplier(zone: StringName) -> float`
  - `SimHitGeometry.ray_circle_distance(origin: Vector2, direction: Vector2, center: Vector2, radius: float, max_distance: float) -> float`
  - `SimCombat.STATE_DEAD: int = 3`（`SimWorld.STATE_DEAD` 的本地副本，见下方循环依赖说明）
  - `SimCombat.resolve_ray_hits(world, origin: Vector2, origin_height: float, direction: Vector2, max_distance: float, maximum_targets: int) -> Array`
  - `SimCombat.resolve_melee_target(world, origin: Vector2, origin_height: float, aim_direction: Vector2, reach: float, half_width: float) -> int`
  - `SimCombat.resolve_explosion_targets(world, origin: Vector2, origin_height: float, radius: float, center_damage: float, edge_damage: float) -> Array`
  - **`SimCombat` 的 `world` 形参刻意不加类型标注**：`sim_world.gd` 会 `preload("res://scripts/sim/sim_combat.gd")`，若 `sim_combat.gd` 反过来在签名里标注全局类 `SimWorld` 或读 `SimWorld.STATE_DEAD`，解析器会在 `sim_world.gd` 尚未解析完时被要求解析它，形成 GDScript 循环类引用并在 `--headless --editor` 导入检查中报解析错误。`scripts/sim/` 内其余依赖（`SimCollision` → `FlowFieldGrid`、`SimHasher` → `SimWorld`）都是单向的，只有这一处需要断开。
  - `WeaponSpreadState.recovered_degrees(current_degrees: float, base_degrees: float, recovery_degrees_per_second: float, elapsed_seconds: float) -> float`（静态）
  - `WeaponSpreadState.increased_degrees(current_degrees: float, increase_degrees: float, maximum_degrees: float) -> float`（静态）
  - `WeaponSpreadState.spread_direction(base_direction: Vector2, degrees: float, normalized_offset: float) -> Vector2`（静态）
  - `SimWorld.configure_weapon_profile(profile_index: int, damage: float, attack_range: float, base_spread_degrees: float, max_spread_degrees: float, spread_increase_degrees: float, spread_recovery_degrees_per_second: float, max_penetration_count: int, penetration_damage_coefficient: float) -> void`
  - `SimWorld.queue_fire_event(slot: int, profile_index: int, origin_xz: Vector2, origin_height: float, aim_direction: Vector2) -> void`
  - `SimWorld.queue_melee_event(slot: int, damage: float, reach: float, half_width: float, origin_xz: Vector2, origin_height: float, aim_direction: Vector2) -> void`
  - `SimWorld.queue_explosion_event(origin_xz: Vector2, origin_height: float, radius: float, center_damage: float, edge_damage: float) -> void`
  - `SimWorld.queue_spread_reset(slot: int) -> void`（换下武器时排队清散布；与其他事件同批在 `_resolve_pending_events()` 里按排队顺序执行）
  - `SimWorld.reset_spread(slot: int) -> void`、`SimWorld.get_spread_degrees(slot: int) -> float`
  - `SimWorld.tick_shot_events: Array`（元素为 `{slot: int, origin: Vector2, origin_height: float, direction: Vector2, end: Vector2, end_height: float, did_hit: bool, killed: bool, damage: float, zone: StringName}`）

- [ ] **Step 1: 创建 `scripts/sim/sim_hit_geometry.gd`**

```gdscript
extends RefCounted
class_name SimHitGeometry

## zombie_hitbox.gd 的命中框在模拟层的解析几何表达。
##
## 基线事实：scenes/targets/ZombieTarget.tscn 只有一个 Hitboxes/BodyHitbox
## （CylinderShape3D，radius 1.1、height 2.2，局部偏移 y = 1.1），命中区只有
## &"body" 一种、倍率 1.0。因此这里建模为单段竖直圆柱，并保留分区表结构，
## 将来新增头/侧身/腿部只需扩表，射线求交与伤害应用无需改动。
##
## 射击方向经 WeaponMath.flat_direction() 压平，射线恒为水平，
## 因此圆柱求交退化为「XZ 平面圆求交 + 高度区间判定」。
const ZONE_BODY: StringName = &"body"
const BODY_CENTER_HEIGHT := 1.1
const BODY_RADIUS := 1.1
const BODY_HALF_HEIGHT := 1.1
const ZONE_DAMAGE_MULTIPLIERS := {
	ZONE_BODY: 1.0,
}

## 爆炸与近战使用的瞄准点高度，等价于 ZombieTarget.get_aim_point() 的 BodyHitbox 中心。
static func aim_point_height(zombie_height: float) -> float:
	return zombie_height + BODY_CENTER_HEIGHT

static func contains_height(zombie_height: float, probe_height: float) -> bool:
	var low := zombie_height + BODY_CENTER_HEIGHT - BODY_HALF_HEIGHT
	var high := zombie_height + BODY_CENTER_HEIGHT + BODY_HALF_HEIGHT
	return probe_height >= low and probe_height <= high

static func zone_for_height(zombie_height: float, probe_height: float) -> StringName:
	return ZONE_BODY if contains_height(zombie_height, probe_height) else &""

static func damage_multiplier(zone: StringName) -> float:
	return float(ZONE_DAMAGE_MULTIPLIERS.get(zone, 0.0))

## 返回沿 direction 命中圆的最小非负距离；未命中返回 -1.0。
## direction 必须已归一化。
static func ray_circle_distance(
	origin: Vector2,
	direction: Vector2,
	center: Vector2,
	radius: float,
	max_distance: float
) -> float:
	var to_center := center - origin
	var projection := to_center.dot(direction)
	var closest_squared := to_center.length_squared() - projection * projection
	var radius_squared := radius * radius
	if closest_squared > radius_squared:
		return -1.0
	var half_chord := sqrt(maxf(radius_squared - closest_squared, 0.0))
	var near_distance := projection - half_chord
	var far_distance := projection + half_chord
	var distance := near_distance if near_distance >= 0.0 else far_distance
	if distance < 0.0 or distance > max_distance:
		return -1.0
	return distance
```

- [ ] **Step 2: 给 `WeaponSpreadState` 增加模拟层纯函数**

在 `scripts/combat/weapons/weapon_spread_state.gd` 的 `reset()` 之后追加。既有实例 API 保持不变。

```gdscript

## ---- 模拟层：纯函数变体 ----
## 渐进散布属玩家状态但影响命中结果，必须进入模拟层。SimWorld 按槽位保存
## current_spread_degrees，用下面三个纯函数推进，不再由 RangedWeapon 持有。
static func recovered_degrees(
	current_degrees: float,
	base_degrees: float,
	recovery_degrees_per_second: float,
	elapsed_seconds: float
) -> float:
	return move_toward(
		current_degrees,
		base_degrees,
		maxf(recovery_degrees_per_second, 0.0) * maxf(elapsed_seconds, 0.0)
	)

static func increased_degrees(
	current_degrees: float,
	increase_degrees: float,
	maximum_degrees: float
) -> float:
	return minf(current_degrees + maxf(increase_degrees, 0.0), maximum_degrees)

## XZ 平面上的散布。Vector3.rotated(Vector3.UP, angle) 与 Vector2.rotated(-angle)
## 在 (x, z) -> (x, y) 映射下等价，这里保持与实例版本逐位一致的旋转方向。
static func spread_direction(
	base_direction: Vector2,
	degrees: float,
	normalized_offset: float
) -> Vector2:
	if base_direction.length_squared() <= 0.000001:
		return Vector2(0.0, -1.0)
	var angle := deg_to_rad(degrees * clampf(normalized_offset, -1.0, 1.0))
	return base_direction.normalized().rotated(-angle)
```

- [ ] **Step 3: 创建 `scripts/sim/sim_combat.gd`**

```gdscript
extends RefCounted
class_name SimCombat

## 命中判定在 SimWorld 的僵尸状态上用确定性解算完成，
## 不使用 PhysicsDirectSpaceState3D。各客户端必然得到相同的击杀结果。
const SimHitGeometryScript = preload("res://scripts/sim/sim_hit_geometry.gd")
const ExplosionMathScript = preload("res://scripts/combat/explosion_math.gd")

## 与 sim_world.gd 的 STATE_DEAD 同步；此处不引用全局类 SimWorld 以避免循环依赖：
## sim_world.gd 会 preload 本文件，若本文件再解析全局类 SimWorld
## （无论是签名里的类型标注，还是形如「SimWorld 点 STATE_DEAD」的常量访问），
## 就会形成 GDScript 循环类引用并在编辑器导入检查中报解析错误。
## 注：本文件内不得出现「SimWorld」后紧跟英文句点的写法，Step 8 的闸门按该模式搜索。
const STATE_DEAD := 3

## 返回按距离升序、同距按实体下标升序的命中列表，最多 maximum_targets 条。
## 元素：{index: int, distance: float, point: Vector2, height: float, zone: StringName}
static func resolve_ray_hits(
	world,                    # SimWorld，不加类型标注以避免与 sim_world.gd 的 preload 形成循环
	origin: Vector2,
	origin_height: float,
	direction: Vector2,
	max_distance: float,
	maximum_targets: int
) -> Array:
	var hits: Array = []
	if direction.length_squared() <= 0.000001 or max_distance <= 0.0:
		return hits
	var unit_direction := direction.normalized()
	var count := world.get_zombie_count()
	for index in range(count):
		if world.get_zombie_state(index) == STATE_DEAD:
			continue
		var zombie_height := world.get_zombie_height(index)
		if not SimHitGeometryScript.contains_height(zombie_height, origin_height):
			continue
		var distance := SimHitGeometryScript.ray_circle_distance(
			origin,
			unit_direction,
			world.get_zombie_position(index),
			SimHitGeometryScript.BODY_RADIUS,
			max_distance
		)
		if distance < 0.0:
			continue
		hits.append({
			"index": index,
			"distance": distance,
			"point": origin + unit_direction * distance,
			"height": origin_height,
			"zone": SimHitGeometryScript.zone_for_height(zombie_height, origin_height),
		})
	hits.sort_custom(_compare_hits)
	if hits.size() > maximum_targets:
		hits.resize(maxi(maximum_targets, 0))
	return hits

## 玩家近战：以 wielder 朝向为前向的矩形窗口，取最近的一只。
## 前向门限与 MeleeWeapon._resolve_melee_hit() 的 forward_distance 过滤一致。
static func resolve_melee_target(
	world,                    # SimWorld，同上：不加类型标注
	origin: Vector2,
	origin_height: float,
	aim_direction: Vector2,
	reach: float,
	half_width: float
) -> int:
	if aim_direction.length_squared() <= 0.000001:
		return -1
	var forward := aim_direction.normalized()
	var lateral := Vector2(-forward.y, forward.x)
	var lateral_limit := half_width + SimHitGeometryScript.BODY_RADIUS
	var best_index := -1
	var best_distance_squared := INF
	var count := world.get_zombie_count()
	for index in range(count):
		if world.get_zombie_state(index) == STATE_DEAD:
			continue
		var zombie_height := world.get_zombie_height(index)
		if not SimHitGeometryScript.contains_height(zombie_height, origin_height):
			continue
		var offset := world.get_zombie_position(index) - origin
		var forward_distance := offset.dot(forward)
		if forward_distance <= 0.0 or forward_distance > reach:
			continue
		if absf(offset.dot(lateral)) > lateral_limit:
			continue
		var distance_squared := offset.length_squared()
		if distance_squared < best_distance_squared:
			best_distance_squared = distance_squared
			best_index = index
	return best_index

## 爆炸的波及判定与伤害衰减。视觉与音效留在表现层。
## 元素：{index: int, damage: float, direction: Vector2, point: Vector2, height: float}
static func resolve_explosion_targets(
	world,                    # SimWorld，同上：不加类型标注
	origin: Vector2,
	origin_height: float,
	radius: float,
	center_damage: float,
	edge_damage: float
) -> Array:
	var affected: Array = []
	if radius <= 0.0:
		return affected
	var count := world.get_zombie_count()
	for index in range(count):
		if world.get_zombie_state(index) == STATE_DEAD:
			continue
		var position := world.get_zombie_position(index)
		var aim_height := SimHitGeometryScript.aim_point_height(
			world.get_zombie_height(index)
		)
		var planar_offset := position - origin
		var vertical_offset := aim_height - origin_height
		var distance := sqrt(
			planar_offset.length_squared() + vertical_offset * vertical_offset
		)
		var damage := ExplosionMathScript.damage_at_distance(
			distance, radius, center_damage, edge_damage
		)
		if damage <= 0.0:
			continue
		if not world.line_is_clear(origin, position):
			continue
		var direction := planar_offset
		if direction.length_squared() <= 0.000001:
			direction = Vector2(0.0, -1.0)
		else:
			direction = direction.normalized()
		affected.append({
			"index": index,
			"damage": damage,
			"direction": direction,
			"point": position,
			"height": aim_height,
		})
	return affected

static func _compare_hits(left: Dictionary, right: Dictionary) -> bool:
	var left_distance: float = left["distance"]
	var right_distance: float = right["distance"]
	if left_distance != right_distance:
		return left_distance < right_distance
	return int(left["index"]) < int(right["index"])
```

- [ ] **Step 4: 在 `sim_world.gd` 顶部追加武器档案与散布状态**

在 `const HitResponseMathScript = preload(...)` 之后追加一行 preload：

```gdscript
const WeaponSpreadStateScript = preload(
	"res://scripts/combat/weapons/weapon_spread_state.gd"
)
const SimCombatScript = preload("res://scripts/sim/sim_combat.gd")
const SimHitGeometryScript = preload("res://scripts/sim/sim_hit_geometry.gd")
```

在 `var tick_player_damage_events: Array = []` 之后追加：

```gdscript
var tick_shot_events: Array = []

# ---- 武器档案与逐槽位散布状态 ----
var weapon_profiles: Array = []
var player_spread_degrees := PackedFloat32Array()
var player_spread_profile := PackedInt32Array()
var pending_events: Array = []
```

在 `_init()` 的 `player_present.fill(0)` 之后追加：

```gdscript
	player_spread_degrees.resize(MAX_PLAYER_SLOTS)
	player_spread_degrees.fill(0.0)
	player_spread_profile.resize(MAX_PLAYER_SLOTS)
	player_spread_profile.fill(-1)
```

在 `reset()` 的 `pending_spawn_waves = []` 之后追加：

```gdscript
	pending_events = []
	player_spread_degrees.fill(0.0)
	player_spread_profile.fill(-1)
```

在 `_clear_tick_events()` 的 `tick_player_damage_events = []` 之后追加：

```gdscript
	tick_shot_events = []
```

- [ ] **Step 5: 在 `sim_world.gd` 末尾追加事件队列与结算实现**

```gdscript

## ---- 武器档案 ----
## 由表现层在装配时按 weapon_id 注册；模拟层只认下标，不认资源。
func configure_weapon_profile(
	profile_index: int,
	damage: float,
	attack_range: float,
	base_spread_degrees: float,
	max_spread_degrees: float,
	spread_increase_degrees: float,
	spread_recovery_degrees_per_second: float,
	max_penetration_count: int,
	penetration_damage_coefficient: float
) -> void:
	if profile_index < 0:
		return
	while weapon_profiles.size() <= profile_index:
		weapon_profiles.append({})
	weapon_profiles[profile_index] = {
		"damage": maxf(damage, 0.0),
		"attack_range": maxf(attack_range, 0.0),
		"base_spread_degrees": maxf(base_spread_degrees, 0.0),
		"max_spread_degrees": maxf(max_spread_degrees, maxf(base_spread_degrees, 0.0)),
		"spread_increase_degrees": maxf(spread_increase_degrees, 0.0),
		"spread_recovery_degrees_per_second": maxf(spread_recovery_degrees_per_second, 0.0),
		"max_penetration_count": clampi(max_penetration_count, 0, 16),
		"penetration_damage_coefficient": clampf(penetration_damage_coefficient, 0.0, 1.0),
	}

## 开火事件只携带玩家的瞄准方向，不携带散布后的方向。
## 散布由各客户端在 Stream.WEAPON_SPREAD 上各自确定性地算出。
func queue_fire_event(
	slot: int,
	profile_index: int,
	origin_xz: Vector2,
	origin_height: float,
	aim_direction: Vector2
) -> void:
	pending_events.append({
		"kind": &"shot",
		"slot": slot,
		"profile_index": profile_index,
		"origin": origin_xz,
		"origin_height": origin_height,
		"aim_direction": aim_direction,
	})

func queue_melee_event(
	slot: int,
	damage: float,
	reach: float,
	half_width: float,
	origin_xz: Vector2,
	origin_height: float,
	aim_direction: Vector2
) -> void:
	pending_events.append({
		"kind": &"melee",
		"slot": slot,
		"damage": damage,
		"reach": reach,
		"half_width": half_width,
		"origin": origin_xz,
		"origin_height": origin_height,
		"aim_direction": aim_direction,
	})

func queue_explosion_event(
	origin_xz: Vector2,
	origin_height: float,
	radius: float,
	center_damage: float,
	edge_damage: float
) -> void:
	pending_events.append({
		"kind": &"explosion",
		"origin": origin_xz,
		"origin_height": origin_height,
		"radius": radius,
		"center_damage": center_damage,
		"edge_damage": edge_damage,
	})

func queue_spread_reset(slot: int) -> void:
	pending_events.append({"kind": &"spread_reset", "slot": slot})

func reset_spread(slot: int) -> void:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	var profile := _weapon_profile(player_spread_profile[slot])
	player_spread_degrees[slot] = float(profile.get("base_spread_degrees", 0.0))

func get_spread_degrees(slot: int) -> float:
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return 0.0
	return player_spread_degrees[slot]

func _weapon_profile(profile_index: int) -> Dictionary:
	if profile_index < 0 or profile_index >= weapon_profiles.size():
		return {}
	return weapon_profiles[profile_index]

func _recover_spread() -> void:
	for slot in range(MAX_PLAYER_SLOTS):
		var profile := _weapon_profile(player_spread_profile[slot])
		if profile.is_empty():
			continue
		player_spread_degrees[slot] = WeaponSpreadStateScript.recovered_degrees(
			player_spread_degrees[slot],
			float(profile["base_spread_degrees"]),
			float(profile["spread_recovery_degrees_per_second"]),
			SimClockScript.TICK_SECONDS
		)

func _resolve_pending_events() -> void:
	if pending_events.is_empty():
		return
	var events := pending_events
	pending_events = []
	for event in events:
		var kind: StringName = event["kind"]
		if kind == &"shot":
			_resolve_shot_event(event)
		elif kind == &"melee":
			_resolve_melee_event(event)
		elif kind == &"explosion":
			_resolve_explosion_event(event)
		elif kind == &"spread_reset":
			reset_spread(int(event["slot"]))

func _resolve_shot_event(event: Dictionary) -> void:
	var slot := int(event["slot"])
	if slot < 0 or slot >= MAX_PLAYER_SLOTS:
		return
	var profile_index := int(event["profile_index"])
	var profile := _weapon_profile(profile_index)
	if profile.is_empty():
		return
	player_spread_profile[slot] = profile_index
	var origin: Vector2 = event["origin"]
	var origin_height: float = event["origin_height"]
	var aim: Vector2 = event["aim_direction"]
	if aim.length_squared() <= 0.000001:
		aim = Vector2(0.0, -1.0)
	aim = aim.normalized()

	var spread_degrees := player_spread_degrees[slot]
	var offset := rng.next_range(
		DeterministicRngScript.Stream.WEAPON_SPREAD, -1.0, 1.0
	)
	var direction := WeaponSpreadStateScript.spread_direction(
		aim, spread_degrees, offset
	)
	player_spread_degrees[slot] = WeaponSpreadStateScript.increased_degrees(
		spread_degrees,
		float(profile["spread_increase_degrees"]),
		float(profile["max_spread_degrees"])
	)

	var attack_range := float(profile["attack_range"])
	var maximum_targets := int(profile["max_penetration_count"]) + 1
	var coefficient := float(profile["penetration_damage_coefficient"])
	var hits := SimCombatScript.resolve_ray_hits(
		self, origin, origin_height, direction, attack_range, maximum_targets
	)
	var end_position := origin + direction * attack_range
	var did_hit := false
	var killed := false
	var total_damage := 0.0
	var zone: StringName = &""
	var current_damage := float(profile["damage"])
	for hit in hits:
		var index := int(hit["index"])
		var hit_zone: StringName = hit["zone"]
		var multiplier := SimHitGeometryScript.damage_multiplier(hit_zone)
		var damage_points := roundi(current_damage * multiplier * float(HEALTH_SCALE))
		var before_health := zombie_health[index]
		if apply_zombie_damage(
			index, damage_points, hit["point"], hit["height"], direction, hit_zone
		):
			did_hit = true
			zone = hit_zone
			total_damage += float(before_health - zombie_health[index]) / float(HEALTH_SCALE)
			killed = killed or zombie_state[index] == STATE_DEAD
		# 曳光终点始终落在最后一个被处理的命中点；穿透关闭时即第一个命中点。
		end_position = hit["point"]
		if coefficient <= 0.0:
			break
		current_damage *= coefficient
	tick_shot_events.append({
		"slot": slot,
		"origin": origin,
		"origin_height": origin_height,
		"direction": direction,
		"end": end_position,
		"end_height": origin_height,
		"did_hit": did_hit,
		"killed": killed,
		"damage": total_damage,
		"zone": zone,
	})

func _resolve_melee_event(event: Dictionary) -> void:
	var slot := int(event["slot"])
	var origin: Vector2 = event["origin"]
	var origin_height: float = event["origin_height"]
	var aim: Vector2 = event["aim_direction"]
	if aim.length_squared() <= 0.000001:
		aim = Vector2(0.0, -1.0)
	aim = aim.normalized()
	var index := SimCombatScript.resolve_melee_target(
		self,
		origin,
		origin_height,
		aim,
		float(event["reach"]),
		float(event["half_width"])
	)
	var did_hit := false
	var killed := false
	var damage_dealt := 0.0
	var end_position := origin + aim * float(event["reach"])
	var end_height := origin_height
	if index >= 0:
		var hit_height := SimHitGeometryScript.aim_point_height(
			get_zombie_height(index)
		)
		var before_health := zombie_health[index]
		var damage_points := roundi(float(event["damage"]) * float(HEALTH_SCALE))
		if apply_zombie_damage(
			index,
			damage_points,
			get_zombie_position(index),
			hit_height,
			aim,
			SimHitGeometryScript.ZONE_BODY
		):
			did_hit = true
			killed = zombie_state[index] == STATE_DEAD
			damage_dealt = float(before_health - zombie_health[index]) / float(HEALTH_SCALE)
		end_position = get_zombie_position(index)
		end_height = hit_height
	tick_shot_events.append({
		"slot": slot,
		"origin": origin,
		"origin_height": origin_height,
		"direction": aim,
		"end": end_position,
		"end_height": end_height,
		"did_hit": did_hit,
		"killed": killed,
		"damage": damage_dealt,
		"zone": SimHitGeometryScript.ZONE_BODY if did_hit else &"",
	})

func _resolve_explosion_event(event: Dictionary) -> void:
	var targets := SimCombatScript.resolve_explosion_targets(
		self,
		event["origin"],
		float(event["origin_height"]),
		float(event["radius"]),
		float(event["center_damage"]),
		float(event["edge_damage"])
	)
	for target in targets:
		apply_zombie_damage(
			int(target["index"]),
			roundi(float(target["damage"]) * float(HEALTH_SCALE)),
			target["point"],
			float(target["height"]),
			target["direction"],
			SimHitGeometryScript.ZONE_BODY
		)
```

- [ ] **Step 6: 用完整的新版替换 `sim_world.gd` 的 `step_tick()`**

把 Task 4 写下的 `step_tick()` 整个函数体替换为：

```gdscript
## 推进一个模拟 tick。不接收任何真实帧时长形参：时间步长恒为 SimClock.TICK_SECONDS。
## 顺序固定：生成 -> 散布回复 -> 玩家事件结算 -> 流场 -> 僵尸推进 ->
## 碰撞 -> 僵尸攻击 -> 压缩删除。任何调整都会改变哈希序列，必须同步全端。
func step_tick() -> void:
	tick_index += 1
	_clear_tick_events()
	_apply_pending_spawn_waves()
	_recover_spread()
	_resolve_pending_events()
	_update_flow_field()
	_update_zombies()
	_resolve_collisions()
	_resolve_zombie_attacks()
	_compact_dead()
```

- [ ] **Step 7: 冒烟核对散布确定性与命中结算**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
cat > tools/validation/zw_sim_combat_smoke.gd <<'EOF'
extends SceneTree

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _run_once() -> Array:
	var world = SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(2026)
	# rifle.tres 的数值
	world.configure_weapon_profile(0, 25.0, 28.0, 0.5, 5.0, 0.65, 1.5, 0, 0.0)
	world.set_player_snapshot(0, Vector2(0.0, 6.0), true, true)
	for lane in range(6):
		world.spawn_zombie(Vector2(0.0, float(-lane) - 1.0), 0.0, 50.0)
	var directions: Array = []
	for tick in range(40):
		world.queue_fire_event(0, 0, Vector2(0.0, 6.0), 1.1, Vector2(0.0, -1.0))
		world.step_tick()
		for shot in world.tick_shot_events:
			directions.append([shot["direction"], shot["did_hit"], shot["killed"]])
	directions.append(["spread", world.get_spread_degrees(0)])
	directions.append(["alive", world.get_zombie_count()])
	return directions

func _init() -> void:
	var first := _run_once()
	var second := _run_once()
	print("identical=%s samples=%d tail=%s" % [first == second, first.size(), first[first.size() - 2]])
	quit(0)
EOF
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/zw_sim_combat_smoke.gd
rm -f tools/validation/zw_sim_combat_smoke.gd tools/validation/zw_sim_combat_smoke.gd.uid
```

Expected: 输出 `identical=true`，`samples` 为 42，`tail` 形如 `["spread", 5.0]`（连射 40 发后散布已顶到 `max_spread_degrees = 5.0`）。冒烟脚本运行后必须删除；`.uid` 只有在编辑器导入过一次后才存在，因此用 `rm -f` 而不是 `rm`。

- [ ] **Step 8: 运行静态检查并确认开火事件不携带散布方向**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
rg -n "spread" scripts/sim/sim_world.gd | rg "queue_fire_event" || echo "fire events carry aim only"
rg -n "PhysicsDirectSpaceState3D|intersect_ray|intersect_shape" scripts/sim \
  || echo "sim combat performs no physics queries"
rg -n "world: SimWorld|SimWorld\." scripts/sim/sim_combat.gd || echo "no cyclic type hint"
```

Expected: 导入检查退出码 0；三条搜索分别输出 `fire events carry aim only`、`sim combat performs no physics queries` 与 `no cyclic type hint`。第三条是循环依赖闸门：`sim_combat.gd` 一旦出现 `world: SimWorld` 形参标注或 `SimWorld` 加英文句点的常量访问，上一条的编辑器导入检查就会报 GDScript 循环类引用解析错误。该闸门不区分代码与注释，因此 Step 3 的注释里也刻意没有出现这两种字面写法——改注释时不要把它们写回去。

- [ ] **Step 9: 提交**

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git status --short
git add scripts/sim/sim_hit_geometry.gd scripts/sim/sim_combat.gd \
  scripts/sim/sim_world.gd scripts/combat/weapons/weapon_spread_state.gd
git commit -m "feat: resolve weapon and explosion damage in the simulation layer"
```

Expected: `git status --short` 中不含任何 `zw_*_smoke.gd`；提交只含上述四个脚本及新脚本的 `.uid`。

---

### Task 6: 帧哈希与确定性回归验证

**Files:**
- Create: `scripts/sim/sim_hasher.gd`
- Test: `tools/validation/validate_sim_determinism.gd`

**Interfaces:**
- Consumes: `SimWorld` 全部公开 getter、`SimWorld.zombie_*` SoA 字段、`DeterministicRng.get_state_words()`、`SimClock.consume_frame()`。
- Produces:
  - `SimHasher.OFFSET_BASIS_HIGH: int = 0xCBF29CE4`、`OFFSET_BASIS_LOW: int = 0x84222325`
  - `SimHasher.reset() -> void`
  - `SimHasher.mix_byte(value: int) -> void`
  - `SimHasher.mix_bytes(bytes: PackedByteArray) -> void`
  - `SimHasher.mix_uint32(value: int) -> void`
  - `SimHasher.mix_int64(value: int) -> void`
  - `SimHasher.get_hash_low() -> int`、`get_hash_high() -> int`、`get_hash_hex() -> String`
  - `SimHasher.hash_world(world: SimWorld) -> String`（静态，返回 16 位小写十六进制）

- [ ] **Step 1: 创建 `scripts/sim/sim_hasher.gd`**

下列常量与已知向量来自标准 FNV-1a 64（offset basis `0xCBF29CE484222325`，prime `0x100000001B3`）。乘法用 16 位 limb 展开；prime 的 limb 为 `[0x01B3, 0x0000, 0x0100, 0x0000]`，两个零 limb 直接省去，`0x0100` 的乘法写成左移 8 位。

```gdscript
extends RefCounted
class_name SimHasher

## 对世界状态计算 64 位 FNV-1a 哈希，直接消费浮点的 IEEE 位模式，不做量化：
## 帧同步要求的是逐位一致而非近似一致。
## S0 阶段用于自测；S3 阶段用于周期性不同步检测。
const OFFSET_BASIS_HIGH := 0xCBF29CE4
const OFFSET_BASIS_LOW := 0x84222325
const UINT32_MASK := 0xFFFFFFFF
const PRIME_LOW_LIMB := 0x01B3
const PRIME_HIGH_SHIFT := 8

var hash_low := OFFSET_BASIS_LOW
var hash_high := OFFSET_BASIS_HIGH

func reset() -> void:
	hash_low = OFFSET_BASIS_LOW
	hash_high = OFFSET_BASIS_HIGH

func mix_byte(value: int) -> void:
	hash_low ^= value & 0xFF
	_multiply_prime()

func mix_bytes(bytes: PackedByteArray) -> void:
	for byte_value in bytes:
		hash_low ^= byte_value
		_multiply_prime()

func mix_uint32(value: int) -> void:
	var masked := value & UINT32_MASK
	hash_low ^= masked & 0xFF
	_multiply_prime()
	hash_low ^= (masked >> 8) & 0xFF
	_multiply_prime()
	hash_low ^= (masked >> 16) & 0xFF
	_multiply_prime()
	hash_low ^= (masked >> 24) & 0xFF
	_multiply_prime()

func mix_int64(value: int) -> void:
	mix_uint32(value & UINT32_MASK)
	mix_uint32((value >> 32) & UINT32_MASK)

func get_hash_low() -> int:
	return hash_low

func get_hash_high() -> int:
	return hash_high

func get_hash_hex() -> String:
	return "%08x%08x" % [hash_high, hash_low]

## 纳入哈希的字段：实体 id、位置、高度、朝向、血量、状态、目标槽位、
## 各 RNG 流的 state、当前 tick。Packed 数组的 to_byte_array() 直接给出
## 小端 IEEE 位模式，无需逐元素拆解。
static func hash_world(world: SimWorld) -> String:
	var hasher := new()
	hasher.mix_uint32(world.get_tick())
	hasher.mix_uint32(world.get_zombie_count())
	hasher.mix_uint32(world.get_next_entity_id())
	hasher.mix_bytes(world.zombie_id.to_byte_array())
	hasher.mix_bytes(world.zombie_position.to_byte_array())
	hasher.mix_bytes(world.zombie_height.to_byte_array())
	hasher.mix_bytes(world.zombie_facing.to_byte_array())
	hasher.mix_bytes(world.zombie_health.to_byte_array())
	hasher.mix_bytes(world.zombie_state)
	hasher.mix_bytes(world.zombie_target_slot)
	hasher.mix_bytes(world.player_position_quantized.to_byte_array())
	hasher.mix_bytes(world.player_alive)
	hasher.mix_bytes(world.player_present)
	hasher.mix_bytes(world.player_spread_degrees.to_byte_array())
	for state_word in world.get_rng().get_state_words():
		hasher.mix_int64(state_word)
	return hasher.get_hash_hex()

## hash = hash * 0x100000001B3 (mod 2^64)
func _multiply_prime() -> void:
	var limb_0 := hash_low & 0xFFFF
	var limb_1 := (hash_low >> 16) & 0xFFFF
	var limb_2 := hash_high & 0xFFFF
	var limb_3 := (hash_high >> 16) & 0xFFFF
	var column_0 := limb_0 * PRIME_LOW_LIMB
	var column_1 := limb_1 * PRIME_LOW_LIMB + (column_0 >> 16)
	var column_2 := (
		limb_2 * PRIME_LOW_LIMB + (limb_0 << PRIME_HIGH_SHIFT) + (column_1 >> 16)
	)
	var column_3 := (
		limb_3 * PRIME_LOW_LIMB + (limb_1 << PRIME_HIGH_SHIFT) + (column_2 >> 16)
	)
	hash_low = (column_0 & 0xFFFF) | ((column_1 & 0xFFFF) << 16)
	hash_high = (column_2 & 0xFFFF) | ((column_3 & 0xFFFF) << 16)
```

- [ ] **Step 2: 创建 `tools/validation/validate_sim_determinism.gd`**

```gdscript
extends SceneTree

const SimClockScript = preload("res://scripts/sim/sim_clock.gd")
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const SimHasherScript = preload("res://scripts/sim/sim_hasher.gd")
const DeterministicRngScript = preload("res://scripts/sim/deterministic_rng.gd")

const TICK_COUNT := 3000
const ZOMBIE_COUNT := 300
const ROOM_SEED := 20260807
const INPUT_SEED := 555
const GRID_ORIGIN := Vector2(-24.5, -19.5)
const GRID_CELL_SIZE := 1.0
const GRID_WIDTH := 49
const GRID_HEIGHT := 39
const PLAYER_SLOT_COUNT := 4
const SHOT_INTERVAL_TICKS := 25
const MUZZLE_HEIGHT := 1.1

# 与 DemoArena 一致的静态阻挡近似：四面边界墙 + 两个集装箱 + 一段路障。
const BLOCKER_RECTS: Array[Rect2] = [
	Rect2(Vector2(-24.5, -19.5), Vector2(49.0, 1.0)),
	Rect2(Vector2(-24.5, 18.5), Vector2(49.0, 1.0)),
	Rect2(Vector2(-24.5, -19.5), Vector2(1.0, 39.0)),
	Rect2(Vector2(23.5, -19.5), Vector2(1.0, 39.0)),
	Rect2(Vector2(-14.1, -12.05), Vector2(6.2, 2.5)),
	Rect2(Vector2(7.9, 5.75), Vector2(6.2, 2.5)),
	Rect2(Vector2(-6.0, -2.0), Vector2(12.0, 1.0)),
]

# 与 resources/weapons/rifle.tres 一致
const RIFLE_PROFILE := 0
const RIFLE_DAMAGE := 25.0
const RIFLE_RANGE := 28.0
const RIFLE_BASE_SPREAD := 0.5
const RIFLE_MAX_SPREAD := 5.0
const RIFLE_SPREAD_INCREASE := 0.65
const RIFLE_SPREAD_RECOVERY := 1.5

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var table := _build_input_table(TICK_COUNT)

	var first_pass := _run_scenario(table, 0.05)
	_expect(
		first_pass.size() == TICK_COUNT,
		"a full pass must produce one hash per tick (got %d)" % first_pass.size(),
		failures
	)
	var second_pass := _run_scenario(table, 0.05)
	_compare("second identical run", first_pass, second_pass, failures)

	var batched_pass := _run_scenario(table, 0.25)
	_compare("five ticks per frame", first_pass, batched_pass, failures)

	_expect(
		first_pass[0] != first_pass[TICK_COUNT - 1],
		"the hash must actually change as the world advances",
		failures
	)
	print("validate_sim_determinism: %d ticks, final hash %s" % [
		TICK_COUNT, first_pass[TICK_COUNT - 1]
	])
	_finish(failures)

## 输入表只与 tick 序号有关，用一个独立的 DeterministicRng 实例生成，
## 不触碰 SimWorld 自身的四条流。
func _build_input_table(tick_count: int) -> Array:
	var input_rng = DeterministicRngScript.new()
	input_rng.seed_streams(INPUT_SEED)
	var table: Array = []
	for tick in range(tick_count):
		var players := PackedVector2Array()
		for slot in range(PLAYER_SLOT_COUNT):
			var phase := float(tick) * 0.03 + float(slot) * 1.5707963
			players.append(Vector2(
				cos(phase) * 6.0 + float(slot) - 1.5,
				sin(phase) * 4.0 + 2.0
			))
		table.append({
			"players": players,
			"fire": tick % SHOT_INTERVAL_TICKS == 0,
			"aim": Vector2(
				input_rng.next_range(DeterministicRngScript.Stream.ZOMBIE_WANDER, -1.0, 1.0),
				input_rng.next_range(DeterministicRngScript.Stream.ZOMBIE_WANDER, -1.0, 1.0)
			),
		})
	return table

func _run_scenario(table: Array, frame_delta: float) -> PackedStringArray:
	var clock = SimClockScript.new()
	var world = SimWorldScript.new()
	world.configure(GRID_ORIGIN, GRID_CELL_SIZE, GRID_WIDTH, GRID_HEIGHT)
	for rect in BLOCKER_RECTS:
		world.set_blocker_world_rect(rect.position, rect.end, true)
	world.reset(ROOM_SEED)
	world.set_default_move_speed(1.30)
	world.set_perception_range(60.0)   # 与 DemoArena.wave_perception_range 的默认值一致
	world.configure_weapon_profile(
		RIFLE_PROFILE,
		RIFLE_DAMAGE,
		RIFLE_RANGE,
		RIFLE_BASE_SPREAD,
		RIFLE_MAX_SPREAD,
		RIFLE_SPREAD_INCREASE,
		RIFLE_SPREAD_RECOVERY,
		0,
		0.0
	)
	var per_corner := ZOMBIE_COUNT / 4
	world.queue_spawn_wave(
		PackedVector2Array([
			Vector2(-19.0, -14.0),
			Vector2(19.0, -14.0),
			Vector2(-19.0, 14.0),
			Vector2(19.0, 14.0),
		]),
		per_corner,
		per_corner,
		ZOMBIE_COUNT,
		6.0,
		0.9,
		50.0
	)
	var hashes := PackedStringArray()
	var applied := 0
	while applied < table.size():
		var ticks := clock.consume_frame(frame_delta)
		if ticks <= 0:
			continue
		for _tick_offset in range(ticks):
			if applied >= table.size():
				break
			var entry: Dictionary = table[applied]
			var players: PackedVector2Array = entry["players"]
			for slot in range(PLAYER_SLOT_COUNT):
				world.set_player_snapshot(slot, players[slot], true, true)
			if entry["fire"]:
				world.queue_fire_event(
					0, RIFLE_PROFILE, players[0], MUZZLE_HEIGHT, entry["aim"]
				)
			world.step_tick()
			hashes.append(SimHasherScript.hash_world(world))
			applied += 1
	return hashes

func _compare(
	label: String,
	expected: PackedStringArray,
	actual: PackedStringArray,
	failures: Array[String]
) -> void:
	if expected == actual:
		return
	if expected.size() != actual.size():
		failures.append(
			"%s produced %d hashes, expected %d" % [label, actual.size(), expected.size()]
		)
		return
	for index in range(expected.size()):
		if expected[index] != actual[index]:
			failures.append(
				"%s diverged at tick %d: %s vs %s" % [
					label, index + 1, expected[index], actual[index]
				]
			)
			return

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_sim_determinism: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 3: 核对哈希器与参考实现一致**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
cat > tools/validation/zw_hasher_smoke.gd <<'EOF'
extends SceneTree

const SimHasherScript = preload("res://scripts/sim/sim_hasher.gd")

func _init() -> void:
	var hasher = SimHasherScript.new()
	print("empty=", hasher.get_hash_hex())
	hasher.reset(); hasher.mix_uint32(1)
	print("u32_1=", hasher.get_hash_hex())
	hasher.reset(); hasher.mix_uint32(0)
	print("u32_0=", hasher.get_hash_hex())
	hasher.reset(); hasher.mix_bytes(PackedFloat32Array([1.0]).to_byte_array())
	print("f32_1=", hasher.get_hash_hex())
	hasher.reset(); hasher.mix_bytes(PackedVector2Array([Vector2(1.0, 2.0)]).to_byte_array())
	print("vec2_1_2=", hasher.get_hash_hex())
	hasher.reset(); hasher.mix_bytes(PackedFloat32Array([-0.0]).to_byte_array())
	print("f32_neg0=", hasher.get_hash_hex())
	quit(0)
EOF
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/zw_hasher_smoke.gd
rm -f tools/validation/zw_hasher_smoke.gd tools/validation/zw_hasher_smoke.gd.uid
```

Expected: 逐行完全等于下列参考值（由独立的 FNV-1a 64 参考实现算出）：

```
empty=cbf29ce484222325
u32_1=ad2aca7747985764
u32_0=4d25767f9dce13f5
f32_1=4b72477f9c5c2f98
vec2_1_2=097a69ee2da301d8
f32_neg0=4d24f67f9dcd3a75
```

注意 `f32_neg0` 与 `u32_0` 不同：`-0.0` 与 `0.0` 的 IEEE 位模式不同，这是逐位哈希的应有行为，也是模拟层不得引入 `-0.0` 的原因。冒烟脚本运行后必须删除；`.uid` 只有在编辑器导入过一次后才存在，因此用 `rm -f` 而不是 `rm`。

- [ ] **Step 4: 运行确定性回归**

这一步耗时以十分钟计，**必须放到后台运行**（`run_in_background`，或下面的 `nohup` 写法），不要放在有 120 秒超时的前台 shell 里。

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
nohup /usr/bin/time -p /Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_sim_determinism.gd \
  > /tmp/zw_determinism.log 2>&1 &
echo "started pid $!; tail -f /tmp/zw_determinism.log"
```

Expected: 日志里先打印 `validate_sim_determinism: 3000 ticks, final hash <16 位十六进制>`，再打印 `validate_sim_determinism: PASS`，退出码 0。三趟 3000 tick × 300 僵尸的模拟在 Apple Silicon 上预计耗时 **10–40 分钟**（`SimHasher.hash_world()` 每 tick 逐字节消费约 8 KB Packed 数据，每字节一次 `_multiply_prime()` GDScript 调用，逐字节 FNV 哈希是主要开销），期间无输出属正常，不要中断。若需要更快的迭代循环，可临时把 `TICK_COUNT` 降到 300 定位问题，但**提交前必须以 3000 复跑一次**。任何 `diverged at tick N` 都必须定位到具体子系统后再继续，不得放宽断言。

- [ ] **Step 5: 静态检查**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
git status --short
```

Expected: 导入检查退出码 0；`git status --short` 中不含任何 `zw_*_smoke.gd`。

- [ ] **Step 6: 提交**

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add scripts/sim/sim_hasher.gd tools/validation/validate_sim_determinism.gd
git commit -m "feat: add sim frame hasher and determinism regression"
```

Expected: 提交只含 `sim_hasher.gd`、确定性验证脚本及其 `.uid`。

---

### Task 7: 僵尸表现化、距离 LOD 渲染与竞技场装配

本任务是不可拆分的一次性翻转：`ZombieTarget` 一旦退出模拟，`demo_arena.gd` 对它的属性访问会变成解析错误，因此节点、场景、渲染器与竞技场装配必须落在同一个提交里。

**Files:**
- Modify: `project.godot:70-74`
- Modify: `scenes/player/Player.tscn:30-32`
- Modify: `scripts/combat/zombie_target.gd:1-511`（整文件替换）
- Modify: `scenes/targets/ZombieTarget.tscn:1-63`（整文件替换）
- Create: `scripts/render/zombie_renderer.gd`
- Modify: `scripts/gameplay/demo_arena.gd:5-42,51-78,164-277,375-397,440-559`
- Modify: `scenes/gameplay/DemoArena.tscn`（第 1 行 `load_steps`、第 29 行 `ext_resource` 之后、`DemoArena` 根节点、第 582 行 `Targets` 节点）
- Delete: `scripts/combat/zombie_hitbox.gd`、`scripts/combat/zombie_hitbox.gd.uid`
- Delete: `tools/validation/validate_zombie_multiplayer_wiring.gd`、`tools/validation/validate_zombie_multiplayer_wiring.gd.uid`

**Interfaces:**
- Consumes: `SimClock.consume_frame()`、`get_interpolation_alpha()`、`SimWorld.configure()` / `reset()` / `queue_spawn_wave()` / `get_pending_spawn_capacity()` / `set_player_snapshot()` / `set_default_move_speed()` / `set_perception_range()` / `step_tick()` / `get_zombie_*()` / `tick_hit_events` / `tick_death_events` / `tick_spawn_events` / `tick_player_damage_events`、`FollowCamera.global_position`（作为 LOD 距离锚点）。
- Produces:
  - `ZombieTarget.death_finished(view: ZombieTarget)`（信号）
  - `ZombieTarget.bind_zombie(zombie_id_value: int, world_position: Vector3, facing_yaw: float) -> void`
  - `ZombieTarget.get_bound_zombie_id() -> int`
  - `ZombieTarget.apply_snapshot(world_position: Vector3, facing_yaw: float, planar_speed: float, behavior_state: int) -> void`
  - `ZombieTarget.play_hit_reaction(hit_position: Vector3, impulse: Vector3) -> void`
  - `ZombieTarget.play_attack_windup() -> void`
  - `ZombieTarget.begin_death() -> void`、`is_dying() -> bool`
  - `ZombieTarget.set_blocker_enabled(value: bool) -> void`
  - `ZombieTarget.set_visual_alpha(value: float) -> void`
  - `ZombieTarget.set_health_text(current_points: int, maximum_points: int) -> void`
  - `ZombieRenderer.NEAR_LOD_COUNT: int = 48`、`ZombieRenderer.BLOCKER_RADIUS: float = 15.0`
  - `ZombieRenderer.setup(anchor: Node3D) -> void`
  - `ZombieRenderer.clear() -> void`
  - `ZombieRenderer.sync_lod(world: SimWorld) -> void`
  - `ZombieRenderer.render_frame(world: SimWorld, interpolation_alpha: float, frame_delta: float) -> void`
  - `ZombieRenderer.notify_deaths(world: SimWorld) -> void`
  - `ZombieRenderer.get_near_view(zombie_id_value: int) -> ZombieTarget`
  - `DemoArena.get_sim_world() -> SimWorld`
  - `DemoArena.get_active_zombie_count() -> int`
  - `DemoArena.spawn_wave() -> int`

- [ ] **Step 1: 在 `project.godot` 增加 ZombieBlocker 物理层**

把 `[layer_names]` 一节（第 70–74 行）改为：

```ini
[layer_names]

3d_physics/layer_1="World"
3d_physics/layer_2="Player"
3d_physics/layer_3="Target"
3d_physics/layer_4="ZombieBlocker"
```

- [ ] **Step 2: 让玩家与 ZombieBlocker 层碰撞**

把 `scenes/player/Player.tscn` 第 30–32 行改为：

```ini
[node name="Player" type="CharacterBody3D" groups=["damageable_targets"]]
collision_layer = 2
collision_mask = 9
```

`9 = 1 (World) | 8 (ZombieBlocker)`。基线是 `collision_mask = 1`，即玩家原本不会被僵尸阻挡；本行按 spec 要求新增这条阻挡关系。

- [ ] **Step 3: 用纯表现实现替换 `scripts/combat/zombie_target.gd`**

整文件替换为：

```gdscript
extends CharacterBody3D
class_name ZombieTarget

## 纯表现节点。不持有血量、不 _physics_process、不 move_and_slide、
## 不参与寻路、不参与命中判定。位置与朝向由 ZombieRenderer 每渲染帧
## 从 SimWorld 插值后写入。
##
## 根节点的碰撞体只在物理层 4 (ZombieBlocker)，collision_mask 为 0：
## 它唯一的作用是阻挡玩家的 move_and_slide()，不参与僵尸自身移动、
## 不参与导航、不参与射击判定，因此不引入任何不确定性。
const ZombieBehaviorMathScript = preload("res://scripts/combat/zombie_behavior_math.gd")

signal death_finished(view: ZombieTarget)

const HIT_REACTION_SECONDS := 0.2
const ATTACK_ANIMATION_SECONDS := 0.7
const DEATH_LINGER_SECONDS := 1.2
const RUN_ANIMATION_SPEED := 0.2

@export var reaction_spring: float = 18.0
@export var reaction_damping: float = 8.0
@export var max_visual_tilt_degrees: float = 18.0

@onready var visual_root: Node3D = $VisualRoot
@onready var blocker_collision: CollisionShape3D = $BlockerCollision
@onready var health_label: Label3D = $HealthLabel

var animation_player: AnimationPlayer
var mesh_instances: Array[MeshInstance3D] = []
var initialized := false
var visual_rest_rotation := Vector3.ZERO
var reaction_rotation := Vector3.ZERO
var reaction_angular_velocity := Vector3.ZERO
var bound_zombie_id := 0
var hit_reaction_remaining := 0.0
var attack_animation_remaining := 0.0
var death_remaining := 0.0
var dying := false

func _ready() -> void:
	_ensure_initialized()

func _ensure_initialized() -> void:
	if initialized:
		return
	# project.godot 开着 common/physics_interpolation=true。本节点的 transform 由
	# ZombieRenderer 在 _process() 里每渲染帧写入（已经用 SimWorld 的上一/当前 tick
	# 插值过），若再交给引擎插值，引擎会把每次写入当成新的物理 tick 变换并从上一次
	# 变换插过去，近景模型会整体滞后一帧、与远景 MultiMesh 实例（set_instance_transform()
	# 绕过节点插值，落在精确插值位置）错位，正是 Step 15 人工验收要排除的「衔接处跳变」；
	# ZombieBlocker 碰撞体同样滞后，玩家阻挡感与看到的模型对不上。
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	if visual_root == null:
		visual_root = get_node("VisualRoot") as Node3D
	if blocker_collision == null:
		blocker_collision = get_node("BlockerCollision") as CollisionShape3D
	if health_label == null:
		health_label = get_node("HealthLabel") as Label3D
	animation_player = visual_root.find_child(
		"AnimationPlayer", true, false
	) as AnimationPlayer
	if animation_player != null:
		animation_player.animation_finished.connect(_on_animation_finished)
		animation_player.play(&"Idle")
	for candidate in visual_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := candidate as MeshInstance3D
		if mesh_instance != null:
			mesh_instances.append(mesh_instance)
	visual_rest_rotation = visual_root.rotation
	initialized = true

func bind_zombie(
	zombie_id_value: int,
	world_position: Vector3,
	facing_yaw: float
) -> void:
	_ensure_initialized()
	bound_zombie_id = zombie_id_value
	dying = false
	death_remaining = 0.0
	hit_reaction_remaining = 0.0
	attack_animation_remaining = 0.0
	reaction_rotation = Vector3.ZERO
	reaction_angular_velocity = Vector3.ZERO
	visual_root.rotation = visual_rest_rotation
	visual_root.scale = Vector3.ONE
	global_position = world_position
	rotation.y = facing_yaw
	visible = true
	set_blocker_enabled(true)
	if animation_player != null:
		animation_player.play(&"Idle", 0.05)

func get_bound_zombie_id() -> int:
	return bound_zombie_id

## 每渲染帧由 ZombieRenderer 调用，参数已完成上一 tick 与当前 tick 的插值。
func apply_snapshot(
	world_position: Vector3,
	facing_yaw: float,
	planar_speed: float,
	behavior_state: int
) -> void:
	if dying:
		return
	global_position = world_position
	rotation.y = facing_yaw
	if animation_player == null:
		return
	if hit_reaction_remaining > 0.0 or attack_animation_remaining > 0.0:
		return
	var animation_name := &"Idle"
	if behavior_state != ZombieBehaviorMathScript.State.ATTACK and planar_speed > RUN_ANIMATION_SPEED:
		animation_name = &"Walk"
	if animation_player.current_animation != animation_name:
		animation_player.play(animation_name, 0.12)

func play_hit_reaction(hit_position: Vector3, impulse: Vector3) -> void:
	_ensure_initialized()
	if dying:
		return
	visual_root.scale = Vector3.ONE * 1.08
	var local_hit := hit_position - global_position
	var local_impulse := global_basis.inverse() * impulse
	var torque := local_hit.cross(local_impulse) * 0.075
	reaction_angular_velocity += Vector3(torque.x, 0.0, torque.z)
	if animation_player != null and animation_player.has_animation(&"HitReact"):
		animation_player.play(&"HitReact", 0.05)
		hit_reaction_remaining = HIT_REACTION_SECONDS
		attack_animation_remaining = 0.0

func play_attack_windup() -> void:
	_ensure_initialized()
	if dying:
		return
	if animation_player != null and animation_player.has_animation(&"Punch"):
		animation_player.play(&"Punch", 0.08)
		attack_animation_remaining = ATTACK_ANIMATION_SECONDS

func begin_death() -> void:
	_ensure_initialized()
	if dying:
		return
	dying = true
	death_remaining = DEATH_LINGER_SECONDS
	set_blocker_enabled(false)
	health_label.visible = false
	if animation_player != null and animation_player.has_animation(&"Death"):
		animation_player.play(&"Death", 0.08)
		death_remaining = minf(
			animation_player.get_animation(&"Death").length,
			DEATH_LINGER_SECONDS
		)

func is_dying() -> bool:
	return dying

func set_blocker_enabled(value: bool) -> void:
	_ensure_initialized()
	blocker_collision.disabled = not value

## LOD 切换时的淡入。GeometryInstance3D.transparency 由引擎切到透明管线，
## 不需要复制材质。
func set_visual_alpha(value: float) -> void:
	_ensure_initialized()
	var transparency := clampf(1.0 - value, 0.0, 1.0)
	for mesh_instance in mesh_instances:
		mesh_instance.transparency = transparency

func set_health_text(current_points: int, maximum_points: int) -> void:
	_ensure_initialized()
	if dying:
		return
	health_label.visible = true
	health_label.text = "%d / %d" % [
		ceili(float(current_points) / 100.0),
		ceili(float(maximum_points) / 100.0),
	]

func _process(delta: float) -> void:
	if not initialized:
		return
	hit_reaction_remaining = maxf(hit_reaction_remaining - delta, 0.0)
	attack_animation_remaining = maxf(attack_animation_remaining - delta, 0.0)
	visual_root.scale = visual_root.scale.move_toward(Vector3.ONE, delta * 1.5)
	_update_visual_reaction(delta)
	if not dying:
		return
	death_remaining = maxf(death_remaining - delta, 0.0)
	if death_remaining > 0.0:
		return
	dying = false
	bound_zombie_id = 0
	visible = false
	death_finished.emit(self)

func _update_visual_reaction(delta: float) -> void:
	reaction_angular_velocity -= reaction_rotation * reaction_spring * delta
	reaction_angular_velocity = reaction_angular_velocity.move_toward(
		Vector3.ZERO,
		reaction_damping * delta
	)
	reaction_rotation += reaction_angular_velocity * delta
	var max_tilt := deg_to_rad(max_visual_tilt_degrees)
	if reaction_rotation.length() > max_tilt:
		reaction_rotation = reaction_rotation.normalized() * max_tilt
	visual_root.rotation = visual_rest_rotation + reaction_rotation

func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name == &"HitReact":
		hit_reaction_remaining = 0.0
	elif animation_name == &"Punch":
		attack_animation_remaining = 0.0
```

- [ ] **Step 4: 用表现件版本替换 `scenes/targets/ZombieTarget.tscn`**

整文件替换为：

```ini
[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://scripts/combat/zombie_target.gd" id="1_target"]
[ext_resource type="PackedScene" path="res://assets/enemies/Zombie_Basic.gltf" id="2_model"]

[sub_resource type="CapsuleShape3D" id="CapsuleShape3D_blocker"]
radius = 0.5
height = 1.9

[node name="ZombieTarget" type="CharacterBody3D"]
collision_layer = 8
collision_mask = 0
script = ExtResource("1_target")

[node name="BlockerCollision" type="CollisionShape3D" parent="."]
position = Vector3(0, 0.95, 0)
shape = SubResource("CapsuleShape3D_blocker")

[node name="VisualRoot" type="Node3D" parent="."]

[node name="Zombie_Basic" parent="VisualRoot" instance=ExtResource("2_model")]

[node name="HealthLabel" type="Label3D" parent="."]
position = Vector3(0, 2.35, 0)
text = "50 / 50"
font_size = 32
outline_size = 8
billboard = 1
```

相对基线的删除项：`groups=["damageable_targets"]`（表现件不再是可伤害目标）、`NavigationAgent3D`、`Hitboxes/BodyHitbox`（命中框已改为 `SimHitGeometry` 的解析几何）、全部导出参数（数值已内联到 `SimWorld` 常量）。

- [ ] **Step 5: 删除失效的命中框脚本与失效的验证脚本**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git rm scripts/combat/zombie_hitbox.gd scripts/combat/zombie_hitbox.gd.uid
git rm tools/validation/validate_zombie_multiplayer_wiring.gd \
  tools/validation/validate_zombie_multiplayer_wiring.gd.uid
rg -n "ZombieHitbox|zombie_hitbox" . --glob '!docs/**' || echo "no remaining hitbox references"
```

Expected: 两条 `git rm` 成功；搜索输出 `no remaining hitbox references`。
`validate_zombie_multiplayer_wiring.gd` 断言的是「每只 `ZombieTarget` 节点都拿到了 `player_registry`」，该契约在僵尸退出节点体系后不复存在，其覆盖面由 `validate_sim_determinism.gd` 承接。

- [ ] **Step 6: 把碰撞体世界 AABB 提升为 `PlaceItemGrid` 的公开静态函数**

把 `scripts/gameplay/place_item_grid.gd` 第 161–176 行的 `_shape_local_aabb()` 替换为：

```gdscript
static func shape_local_aabb(shape: Shape3D) -> AABB:
	var half := Vector3.ZERO
	if shape is BoxShape3D:
		half = (shape as BoxShape3D).size * 0.5
	elif shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		half = Vector3(cylinder.radius, cylinder.height * 0.5, cylinder.radius)
	elif shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		half = Vector3(capsule.radius, capsule.height * 0.5, capsule.radius)
	elif shape is SphereShape3D:
		var radius := (shape as SphereShape3D).radius
		half = Vector3.ONE * radius
	else:
		return AABB()
	return AABB(-half, half * 2.0)

## 供流场烘焙与运行时标脏使用：把一个碰撞体的全部可用碰撞形状合并为世界 AABB。
static func collision_object_world_aabb(obstacle: CollisionObject3D) -> AABB:
	if obstacle == null:
		return AABB()
	var combined := AABB()
	var has_bounds := false
	for candidate in obstacle.find_children("*", "CollisionShape3D", true, false):
		var collision_shape := candidate as CollisionShape3D
		if (
			collision_shape == null or collision_shape.disabled or
			collision_shape.shape == null
		):
			continue
		var local_aabb := shape_local_aabb(collision_shape.shape)
		if local_aabb.size == Vector3.ZERO:
			continue
		var world_aabb := collision_shape.global_transform * local_aabb
		combined = world_aabb if not has_bounds else combined.merge(world_aabb)
		has_bounds = true
	return combined if has_bounds else AABB()

func _shape_local_aabb(shape: Shape3D) -> AABB:
	return shape_local_aabb(shape)
```

`cells_for_collision_object()` 与 `has_dynamic_blocker()` 的既有调用点全部保持可用。

- [ ] **Step 7: 创建 `scripts/render/zombie_renderer.gd`**

```gdscript
extends Node3D
class_name ZombieRenderer

## MultiMesh 不支持骨骼动画，而现有僵尸是 GLTF + AnimationPlayer，
## 因此采用距离 LOD 混合：距共享镜头中心最近的 NEAR_LOD_COUNT 只实例化
## 现有 ZombieTarget 场景（仅作表现），其余走 MultiMeshInstance3D 静态姿势。
##
## LOD 归属不进入模拟层：它是纯表现决策，允许各客户端不同。
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")

const NEAR_LOD_COUNT := 48
## 玩家活动区半宽 11.2 / 半深 9.7（PlayerScreenBounds.ONLINE_BOUNDS_*），
## 取对角线（≈14.8）加一个僵尸半径作为「必须提供阻挡体」的半径。
## 近景名额按半径准入而不是无条件取最近 N 只：只按数量取时，
## 波次超过 NEAR_LOD_COUNT 后紧挨玩家的僵尸也可能落选而失去阻挡体，
## 玩家会直接穿过去。半径内僵尸数超过 NEAR_LOD_COUNT 时仍会有漏网的，
## 这是已记录在 Global Constraints 里的已知收窄。
const BLOCKER_RADIUS := 15.0
const FADE_SECONDS := 0.18
const MULTI_MESH_MINIMUM_CAPACITY := 64
const RUN_ANIMATION_SPEED := 0.2

@export var zombie_scene: PackedScene

var camera_anchor: Node3D
var multi_mesh_instance: MultiMeshInstance3D
var multi_mesh: MultiMesh
var far_lod_material: Material
var near_views: Dictionary = {}
var view_alpha: Dictionary = {}
var free_views: Array[ZombieTarget] = []
var lod_scratch: Array = []

func setup(anchor: Node3D) -> void:
	camera_anchor = anchor
	if multi_mesh_instance == null:
		multi_mesh = MultiMesh.new()
		multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
		multi_mesh.mesh = _extract_far_lod_mesh()
		multi_mesh.instance_count = MULTI_MESH_MINIMUM_CAPACITY
		multi_mesh.visible_instance_count = 0
		multi_mesh_instance = MultiMeshInstance3D.new()
		multi_mesh_instance.name = "FarLodMultiMesh"
		multi_mesh_instance.multimesh = multi_mesh
		multi_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if far_lod_material != null:
			multi_mesh_instance.material_override = far_lod_material
		add_child(multi_mesh_instance)
		# project.godot 开着 common/physics_interpolation=true；本渲染器已经在
		# render_frame() 里自己做完了 tick 间插值，必须关掉引擎插值，
		# 否则近景 ZombieTarget 与远景实例会错开一帧。
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	while free_views.size() + near_views.size() < NEAR_LOD_COUNT:
		var view := zombie_scene.instantiate() as ZombieTarget
		view.name = "ZombieView%02d" % (free_views.size() + near_views.size())
		add_child(view)
		view.death_finished.connect(_on_view_death_finished)
		view.visible = false
		view.set_blocker_enabled(false)
		free_views.append(view)

func clear() -> void:
	for zombie_id_value in near_views.keys():
		_release_view(zombie_id_value, near_views[zombie_id_value])
	near_views = {}
	view_alpha = {}
	if multi_mesh != null:
		multi_mesh.visible_instance_count = 0

## 每 tick 重算 LOD 归属。距离取共享镜头锚点到僵尸的 XZ 平面平方距离，
## 同距按实体 id 升序决定，避免抖动。
## 准入条件是「在 BLOCKER_RADIUS 之内」且「名额未超过 NEAR_LOD_COUNT」，
## 二者都不满足的僵尸只出现在远景 MultiMesh 上，没有阻挡体。
func sync_lod(world: SimWorld) -> void:
	var anchor_position := (
		camera_anchor.global_position if camera_anchor != null else Vector3.ZERO
	)
	var anchor_xz := Vector2(anchor_position.x, anchor_position.z)
	var ids := world.get_zombie_id_array()
	lod_scratch.clear()
	for index in range(world.get_zombie_count()):
		lod_scratch.append([
			anchor_xz.distance_squared_to(world.get_zombie_position(index)),
			ids[index],
			index,
		])
	lod_scratch.sort_custom(_compare_lod)
	var wanted: Dictionary = {}
	var blocker_radius_squared := BLOCKER_RADIUS * BLOCKER_RADIUS
	for slot in range(lod_scratch.size()):
		if wanted.size() >= NEAR_LOD_COUNT:
			break
		# lod_scratch 已按距离升序，超出半径后面的只会更远，直接停。
		if float(lod_scratch[slot][0]) > blocker_radius_squared:
			break
		wanted[lod_scratch[slot][1]] = lod_scratch[slot][2]
	for zombie_id_value in near_views.keys():
		if wanted.has(zombie_id_value):
			continue
		var view: ZombieTarget = near_views[zombie_id_value]
		if view.is_dying():
			continue
		_release_view(zombie_id_value, view)
		near_views.erase(zombie_id_value)
		view_alpha.erase(zombie_id_value)
	for zombie_id_value in wanted.keys():
		if near_views.has(zombie_id_value):
			continue
		var view := _acquire_view()
		if view == null:
			break
		var index: int = wanted[zombie_id_value]
		view.bind_zombie(
			zombie_id_value,
			_world_origin(world, index, 1.0),
			world.get_zombie_facing(index)
		)
		view.set_visual_alpha(0.0)
		near_views[zombie_id_value] = view
		view_alpha[zombie_id_value] = 0.0

## 渲染帧之间对 SimWorld 的上一 tick 与当前 tick 做线性插值。
func render_frame(
	world: SimWorld,
	interpolation_alpha: float,
	frame_delta: float
) -> void:
	if multi_mesh == null:
		return
	var count := world.get_zombie_count()
	if multi_mesh.instance_count < count:
		multi_mesh.instance_count = maxi(count, MULTI_MESH_MINIMUM_CAPACITY)
	var ids := world.get_zombie_id_array()
	var far_slot := 0
	for index in range(count):
		var zombie_id_value := ids[index]
		var previous := world.get_zombie_previous_position(index)
		var current := world.get_zombie_position(index)
		var origin := _world_origin(world, index, interpolation_alpha)
		var facing := lerp_angle(
			world.get_zombie_previous_facing(index),
			world.get_zombie_facing(index),
			interpolation_alpha
		)
		if near_views.has(zombie_id_value):
			var view: ZombieTarget = near_views[zombie_id_value]
			var speed := previous.distance_to(current) / SimClockScript.TICK_SECONDS
			view.apply_snapshot(origin, facing, speed, world.get_zombie_state(index))
			view.set_health_text(
				world.get_zombie_health(index),
				world.get_zombie_max_health(index)
			)
			var current_alpha: float = view_alpha.get(zombie_id_value, 1.0)
			if current_alpha < 1.0:
				current_alpha = minf(current_alpha + frame_delta / FADE_SECONDS, 1.0)
				view_alpha[zombie_id_value] = current_alpha
				view.set_visual_alpha(current_alpha)
			continue
		multi_mesh.set_instance_transform(
			far_slot,
			Transform3D(Basis(Vector3.UP, facing), origin)
		)
		far_slot += 1
	multi_mesh.visible_instance_count = far_slot

## 本 tick 死亡的僵尸：近景表现件脱离池子播放死亡动画，播完自行归还。
func notify_deaths(world: SimWorld) -> void:
	for zombie_id_value in world.tick_death_events:
		if not near_views.has(zombie_id_value):
			continue
		var view: ZombieTarget = near_views[zombie_id_value]
		near_views.erase(zombie_id_value)
		view_alpha.erase(zombie_id_value)
		view.begin_death()

func get_near_view(zombie_id_value: int) -> ZombieTarget:
	return near_views.get(zombie_id_value, null) as ZombieTarget

func _world_origin(world: SimWorld, index: int, alpha: float) -> Vector3:
	var blended := world.get_zombie_previous_position(index).lerp(
		world.get_zombie_position(index), alpha
	)
	var height := lerpf(
		world.get_zombie_previous_height(index),
		world.get_zombie_height(index),
		alpha
	)
	return Vector3(blended.x, height, blended.y)

func _acquire_view() -> ZombieTarget:
	if free_views.is_empty():
		return null
	var view: ZombieTarget = free_views.pop_back()
	view.visible = true
	view.set_blocker_enabled(true)
	return view

func _release_view(_zombie_id_value: int, view: ZombieTarget) -> void:
	view.visible = false
	view.set_blocker_enabled(false)
	view.set_visual_alpha(1.0)
	if not free_views.has(view):
		free_views.append(view)

func _on_view_death_finished(view: ZombieTarget) -> void:
	view.set_blocker_enabled(false)
	view.set_visual_alpha(1.0)
	if not free_views.has(view):
		free_views.append(view)

## 远景使用僵尸模型的绑定姿势网格。MultiMesh 不驱动骨骼，
## 因此这里拿到的就是 spec 要求的静态姿势。
func _extract_far_lod_mesh() -> Mesh:
	if zombie_scene == null:
		return null
	var probe := zombie_scene.instantiate()
	var resolved_mesh: Mesh = null
	for candidate in probe.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := candidate as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		resolved_mesh = mesh_instance.mesh
		far_lod_material = mesh_instance.get_active_material(0)
		break
	probe.free()
	return resolved_mesh

static func _compare_lod(left: Array, right: Array) -> bool:
	var left_distance: float = left[0]
	var right_distance: float = right[0]
	if left_distance != right_distance:
		return left_distance < right_distance
	return int(left[1]) < int(right[1])
```

- [ ] **Step 8: 在 `demo_arena.gd` 顶部加入模拟层常量与状态**

在 `scripts/gameplay/demo_arena.gd` 的 `const ARENA_CAMERA_BOUNDS := ...`（第 13 行）之后插入：

```gdscript
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")
const SimWorldScript = preload("res://scripts/sim/sim_world.gd")
const PlaceItemGridScript = preload("res://scripts/gameplay/place_item_grid.gd")
const BLOOD_IMPACT_SCENE := preload("res://scenes/fx/BloodImpact.tscn")
const ARENA_SIM_GRID_ORIGIN := Vector2(-24.5, -19.5)
const ARENA_SIM_CELL_SIZE := 1.0
const ARENA_SIM_GRID_WIDTH := 49
const ARENA_SIM_GRID_HEIGHT := 39
const DEFAULT_SIM_SEED := 20260807
const ZOMBIE_MAX_HEALTH := 50.0
const BLOCKER_GROUP: StringName = &"place_item_obstacle"
```

把第 34 行 `var wave_rng := RandomNumberGenerator.new()` 替换为：

```gdscript
var sim_clock = SimClockScript.new()
var sim_world = SimWorldScript.new()
var zombie_renderer: ZombieRenderer
```

`wave_rng.randomize()` 是本场景里最后一处开局不确定源，随本行一并消失。

同时删除第 7 行的 `const ZOMBIE_SCENE := preload("res://scenes/targets/ZombieTarget.tscn")`：僵尸场景现由 `ZombieRenderer.zombie_scene` 在 `DemoArena.tscn` 中引用（Step 13 的 `zombie_scene = ExtResource("4_target")`），竞技场自身不再实例化僵尸，留着它会让 `DemoArena` 对一个它不再生成的场景保持硬依赖。

第 29 行的 `@export_range(1.0, 100.0, 0.5) var wave_perception_range := 60.0` **保留**，改由 `_setup_simulation()` 传给 `sim_world.set_perception_range()`（见 Step 10）——基线的 `spawn_wave()` 是用它覆盖 `ZombieTarget.tscn` 的导出默认值 7.0 的，删掉会让僵尸只在 7 m 内才注意到玩家。

- [ ] **Step 9: 把同屏僵尸上限从 24 放宽到 300**

spec 的头号目标是「把同屏僵尸上限从个位数提升到 300」，但基线的 `maximum_active_zombies` 导出范围只有 `(4, 128, 1)`、默认 24，且 `spawn_wave()` 按 `maximum_active_zombies - get_active_zombie_count()` 硬钳，`DemoArena.tscn` 也没有覆盖该值。不放宽这三处，Step 15 的「ALIVE 超过 60」与 Task 11 Step 6 的「ALIVE 达到 300」都不可能达成。

把 `scripts/gameplay/demo_arena.gd` 第 24–26 行：

```gdscript
@export_range(1, 8, 1) var minimum_zombies_per_corner := 1
@export_range(1, 8, 1) var maximum_zombies_per_corner := 2
@export_range(4, 128, 1) var maximum_active_zombies := 24
```

替换为：

```gdscript
@export_range(1, 40, 1) var minimum_zombies_per_corner := 12
@export_range(1, 40, 1) var maximum_zombies_per_corner := 18
@export_range(4, 400, 1) var maximum_active_zombies := 300
```

四个角每次 12–18 只，一次 `T` 生成 48–72 只，连按 5 次即可逼近 300 只的上限。

并在 `scenes/gameplay/DemoArena.tscn` 的 `[node name="DemoArena" type="Node3D"]` 块中（`zombie_difficulty = ...` 一行之后）追加：

```ini
maximum_active_zombies = 300
```

使随包发布的场景与脚本默认值一致，而不是依赖「没写就用默认值」——该节点块已经显式写了 `zombie_difficulty`，读者会以为其余导出项也在此声明。

- [ ] **Step 10: 在 `_ready()` 中装配模拟层，并接管每帧推进**

把 `_ready()` 第 60–63 行的种子分支：

```gdscript
	if random_seed == 0:
		wave_rng.randomize()
	else:
		wave_rng.seed = random_seed
```

替换为：

```gdscript
	_setup_simulation()
```

把 `_process()`（第 72–78 行）整体替换为：

```gdscript
func _process(delta: float) -> void:
	if (
		team_defeated and
		not restart_pending and
		local_team_state.sample_restart_requested()
	):
		request_restart()
	if zombie_renderer != null:
		zombie_renderer.render_frame(
			sim_world,
			sim_clock.get_interpolation_alpha(),
			delta
		)

func _physics_process(delta: float) -> void:
	if startup_pending or zombie_renderer == null:
		return
	var ticks := sim_clock.consume_frame(delta)
	for _tick_offset in range(ticks):
		_push_player_snapshot()
		sim_world.step_tick()
		_consume_sim_events()
		zombie_renderer.sync_lod(sim_world)

func get_sim_world() -> SimWorld:
	return sim_world

func _setup_simulation() -> void:
	sim_world.configure(
		ARENA_SIM_GRID_ORIGIN,
		ARENA_SIM_CELL_SIZE,
		ARENA_SIM_GRID_WIDTH,
		ARENA_SIM_GRID_HEIGHT
	)
	_bake_static_blockers()
	sim_world.reset(DEFAULT_SIM_SEED if random_seed == 0 else random_seed)
	if zombie_difficulty != null:
		sim_world.set_default_move_speed(zombie_difficulty.perception_move_speed)
	# 基线的 spawn_wave() 用 wave_perception_range（默认 60.0）覆盖 ZombieTarget 的
	# 导出默认值 7.0；模拟层没有这一步的话，生成角 (±19, ±14) 上的僵尸
	# 在 48 × 38 的场地里永远够不到玩家，会原地游荡而不汇聚。
	sim_world.set_perception_range(wave_perception_range)
	sim_clock.reset()

func _bake_static_blockers() -> void:
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group(BLOCKER_GROUP):
		var obstacle := node as CollisionObject3D
		if obstacle != null:
			mark_blocker(obstacle, true)

## 运行时增删阻挡几何的统一入口。任何调用都会置脏对应 cell，
## 下一 tick 的 FlowField.update() 会同步重算。
func mark_blocker(obstacle: CollisionObject3D, blocked: bool) -> void:
	var bounds := PlaceItemGridScript.collision_object_world_aabb(obstacle)
	if bounds.size == Vector3.ZERO:
		return
	sim_world.set_blocker_world_rect(
		Vector2(bounds.position.x, bounds.position.z),
		Vector2(bounds.end.x, bounds.end.z),
		blocked
	)

func _player_for_slot(slot: int) -> PlayerController:
	if slot < 0 or slot >= players.size():
		return null
	var player := players[slot]
	return player if is_instance_valid(player) else null

## 玩家状态以量化后的快照进入 SimWorld；玩家自身位移仍由玩家层决定。
func _push_player_snapshot() -> void:
	for slot in range(SimWorldScript.MAX_PLAYER_SLOTS):
		var player := _player_for_slot(slot)
		if player == null:
			sim_world.set_player_snapshot(slot, Vector2.ZERO, false, false)
			continue
		sim_world.set_player_snapshot(
			slot,
			Vector2(player.global_position.x, player.global_position.z),
			player.is_alive(),
			true
		)

func _consume_sim_events() -> void:
	for event in sim_world.tick_hit_events:
		_on_sim_hit_event(event)
	for event in sim_world.tick_player_damage_events:
		_on_sim_player_damage_event(event)
	if sim_world.tick_death_events.size() > 0:
		zombie_renderer.notify_deaths(sim_world)
		call_deferred("_refresh_wave_state_after_deaths")

func _on_sim_hit_event(event: Dictionary) -> void:
	var planar: Vector2 = event["position"]
	var hit_position := Vector3(planar.x, float(event["height"]), planar.y)
	var planar_direction: Vector2 = event["direction"]
	var direction := Vector3(planar_direction.x, 0.0, planar_direction.y)
	var view := zombie_renderer.get_near_view(int(event["zombie_id"]))
	if view != null:
		view.play_hit_reaction(
			hit_position,
			direction * SimWorldScript.ZOMBIE_KNOCKBACK_IMPULSE
		)
	_spawn_blood_impact(hit_position, direction)
	var manager := get_node_or_null("GroundBloodManager") as GroundBloodManager
	if manager == null:
		return
	manager.spawn_hit_splat(hit_position, direction, 1.0)
	if bool(event["killed"]):
		manager.spawn_death_pool(Vector3(planar.x, 0.0, planar.y), 1.25)

func _on_sim_player_damage_event(event: Dictionary) -> void:
	var view := zombie_renderer.get_near_view(int(event["zombie_id"]))
	if event["kind"] == &"zombie_windup":
		if view != null:
			view.play_attack_windup()
		return
	var target := _player_for_slot(int(event["slot"]))
	if target == null or not target.is_alive():
		return
	var origin: Vector2 = event["origin"]
	target.apply_damage(float(event["damage"]), Vector3(origin.x, 0.0, origin.y))

func _spawn_blood_impact(hit_position: Vector3, direction: Vector3) -> void:
	var effect := BLOOD_IMPACT_SCENE.instantiate() as BloodImpact
	add_child(effect)
	effect.setup(hit_position, direction, 1.0)

func _refresh_wave_state_after_deaths() -> void:
	_update_wave_hud()
	_schedule_auto_wave_if_empty()
```

- [ ] **Step 11: 在 `_wire_dependencies()` 中接上渲染器，并删除僵尸节点接线**

把 `_wire_dependencies()` 中的 `World/Targets` 区块（第 225–232 行）：

```gdscript
	var targets := get_node_or_null("World/Targets")
	if targets != null:
		for target in targets.get_children():
			_wire_target(target)
		if not targets.child_entered_tree.is_connected(_wire_target):
			targets.child_entered_tree.connect(_wire_target)
		if not targets.child_exiting_tree.is_connected(_on_target_exiting_tree):
			targets.child_exiting_tree.connect(_on_target_exiting_tree)
```

替换为：

```gdscript
	var renderer := get_node_or_null(
		"World/Targets/ZombieRenderer"
	) as ZombieRenderer
	if renderer != null and zombie_renderer != renderer:
		zombie_renderer = renderer
		zombie_renderer.setup(get_node_or_null("FollowCamera") as Node3D)
```

随后整段删除下列已经没有调用点的函数：

- `_wire_target()`（第 263–277 行）
- `_wire_target_blood()`（第 335–344 行）
- `_on_ground_blood_requested()`（第 346–356 行）
- `_on_ground_blood_trail_requested()`（第 358–365 行）
- `_collect_zombie_positions()`（第 514–522 行）
- `_sample_spawn_position()`（第 524–540 行）
- `_has_spawn_clearance()`（第 542–551 行）
- `_on_target_exiting_tree()`（第 553–555 行）
- `_refresh_wave_state_after_target_exit()`（第 557–559 行）

血迹拖尾原本由僵尸节点自己的位移驱动，僵尸退出节点体系后不再产生；命中与死亡血迹改由 `_on_sim_hit_event()` 发出。`GroundBloodManager.spawn_trail_splat()` 保留但暂无调用点。

- [ ] **Step 12: 把波次生成改为向模拟层排队**

把 `spawn_wave()`（第 440–491 行）替换为：

```gdscript
## 把一次波次生成排入模拟层，由下一 tick 在 Stream.ZOMBIE_SPAWN 上确定性执行。
## 返回本次授予的生成上限；实际生成数在下一 tick 后才可由
## get_active_zombie_count() 读到。
##
## 返回值语义相对基线有变：基线返回「本次实际生成数」，这里返回「本次授予的名额」。
## 三个调用点（spawn_wave 输入动作、HUD 生成按钮、_on_auto_wave_timeout）都只判
## `> 0`，语义变化不影响它们；但 request_spawn_wave() -> int 的文档注释必须同步改成
## 「本次授予的生成上限」，不要留着「实际生成数」的旧措辞。
func spawn_wave() -> int:
	if team_defeated:
		return 0
	var spawn_points := _get_spawn_points()
	if spawn_points.size() != SPAWN_POINT_NAMES.size():
		_report_wave_problem("MISSING CORNER SPAWN POINT")
		return 0
	var remaining_capacity := maximum_active_zombies - get_active_zombie_count()
	if remaining_capacity <= 0:
		_show_wave_status("MAX ZOMBIES: %d" % maximum_active_zombies)
		return 0
	var centers := PackedVector2Array()
	for marker in spawn_points:
		centers.append(
			Vector2(marker.global_position.x, marker.global_position.z)
		)
	sim_world.queue_spawn_wave(
		centers,
		minimum_zombies_per_corner,
		maximum_zombies_per_corner,
		remaining_capacity,
		spawn_radius,
		minimum_spawn_spacing,
		ZOMBIE_MAX_HEALTH
	)
	# 与基线一致：只有真的授出了名额才推进波次号，避免 HUD 波次在空转的
	# 波次请求上虚增。上面的 `remaining_capacity <= 0` 分支已经提前 return，
	# 走到这里必然 > 0，这一行是把基线的 `if spawned > 0` 守卫显式保留下来。
	if remaining_capacity > 0:
		wave_number += 1
	_update_wave_hud()
	return remaining_capacity
```

把 `get_active_zombie_count()`（第 493–501 行）替换为：

```gdscript
## 必须把「已排队但尚未兑现」的名额算进来。sim_world.get_zombie_count() 要等
## 下一个 step_tick() 才会变化，若只读它：
##   1. 同一物理帧内连按两次 T，两次都看到同样的 remaining_capacity，
##      _apply_pending_spawn_waves() 会把两批都放出来，突破 maximum_active_zombies；
##   2. 排队后的那一 tick 里计数仍为 0，_schedule_auto_wave_if_empty() 会再排一次。
func get_active_zombie_count() -> int:
	return sim_world.get_zombie_count() + sim_world.get_pending_spawn_capacity()
```

- [ ] **Step 13: 在 `DemoArena.tscn` 里挂上渲染器节点**

在场景头部的 `ext_resource` 列表末尾（第 29 行 `id="27_oil_barrel_pickup"` 之后，该行是 `ext_resource` 列表的最后一行）插入：

```ini
[ext_resource type="Script" path="res://scripts/render/zombie_renderer.gd" id="28_zombie_renderer"]
```

把第 1 行的 `load_steps=54` 改为 `load_steps=55`。

把第 582 行的 `Targets` 节点改为带一个子节点：

```ini
[node name="Targets" type="Node3D" parent="World"]

[node name="ZombieRenderer" type="Node3D" parent="World/Targets"]
script = ExtResource("28_zombie_renderer")
zombie_scene = ExtResource("4_target")
```

- [ ] **Step 14: 静态检查与运行时冒烟**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
rg -n "wave_rng|NavigationAgent3D|ZOMBIE_SCENE" scripts/gameplay/demo_arena.gd \
  || echo "arena no longer instantiates zombies or owns a wave rng"
rg -n "_physics_process|move_and_slide" scripts/combat/zombie_target.gd \
  || echo "zombie view is presentation only"
rg -n "PHYSICS_INTERPOLATION_MODE_OFF" scripts/render/zombie_renderer.gd \
  scripts/combat/zombie_target.gd
rg -n "maximum_active_zombies" scripts/gameplay/demo_arena.gd scenes/gameplay/DemoArena.tscn
for script in validate_mobile_equipment_controls validate_local_player_spawning; do
  /Applications/Godot.app/Contents/MacOS/Godot \
    --headless --path . --script "res://tools/validation/$script.gd" || echo "FAILED: $script"
done
```

随后**后台**运行确定性回归（10–40 分钟，见 Global Constraints）：

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
nohup /Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_sim_determinism.gd \
  > /tmp/zw_determinism_task7.log 2>&1 &
```

Expected: 导入检查退出码 0 且无新增 `SCRIPT ERROR` / `Parse Error`；两条搜索分别输出 `arena no longer instantiates zombies or owns a wave rng`（注意这条已从 `ZOMBIE_SCENE\.instantiate` 收紧为 `ZOMBIE_SCENE`：Step 8 删掉了那个 `const`，留着孤儿常量也算失败）与 `zombie view is presentation only`；第三条搜索在两个文件里各命中一行 `physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF`；第四条搜索显示脚本里是 `@export_range(4, 400, 1) var maximum_active_zombies := 300`、场景里是 `maximum_active_zombies = 300`；`validate_mobile_equipment_controls` 与 `validate_local_player_spawning` 各打印 `: PASS` 且没有 `FAILED:` 行（这两个脚本会实例化 `DemoArena.tscn` 并断言 `_wire_dependencies()` 的注入路径，正是本任务重写的部分）；确定性验证日志最终打印 `validate_sim_determinism: PASS`。

- [ ] **Step 15: 人工确认渲染与阻挡（需要用户执行并截图）**

请用户执行：

1. `/Applications/Godot.app/Contents/MacOS/Godot --path .` 启动主场景，进入单人 Demo。
2. 连按 `T` 直到 HUD 的 `ALIVE` 超过 60（Step 9 已把上限放宽到 300、每角 12–18 只，按两次即可越过 60），观察近景至多 48 只有骨骼动画、远景为静态姿势，两者衔接处无明显跳变。
3. 走向一群僵尸，确认玩家会被僵尸身体挡住而不是穿过去。近景名额按 `BLOCKER_RADIUS = 15.0` 准入，玩家周围的僵尸一定在名额内。
4. 截图 HUD 与僵尸群，交回分析。

Expected: 近景骨骼动画正常播放并有淡入；远景 `MultiMesh` 姿势静止但朝向正确；玩家被近景僵尸阻挡；近远景之间**没有整体错开一帧的拖影**（若有，说明 Step 3 / Step 7 的 `PHYSICS_INTERPOLATION_MODE_OFF` 漏改，引擎插值与渲染器自己的插值叠加了）。

> 本任务结束时枪械仍走旧的物理射线，僵尸已不在物理世界，因此**射击不会造成伤害、HUD 的 HIT/KILL 不再出现**。这是刻意的中间态，由 Task 8 补齐开火事件接线。上面的人工确认只看渲染与阻挡。

- [ ] **Step 16: 提交**

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add project.godot scenes/player/Player.tscn scripts/combat/zombie_target.gd \
  scenes/targets/ZombieTarget.tscn scripts/render/zombie_renderer.gd \
  scripts/gameplay/place_item_grid.gd scripts/gameplay/demo_arena.gd \
  scenes/gameplay/DemoArena.tscn
git commit -m "feat: render zombies from the simulation with distance lod"
```

Expected: 提交同时包含上述修改与 Step 5 的两组删除；不含 `.godot/`。

---

### Task 8: 开火事件接线与移除 `randomize()`

**Files:**
- Modify: `scripts/combat/weapons/weapon_base.gd:20-27`
- Modify: `scripts/combat/weapons/ranged_weapon.gd:1-166,177-302`
- Modify: `scripts/combat/weapons/melee_weapon.gd:1-6,32-47,77-146`
- Modify: `scripts/player/equipment_controller.gd:27-34,44-81`
- Modify: `scripts/player/player_controller.gd:63-70,82-92`
- Modify: `scripts/gameplay/demo_arena.gd`（Task 7 已改造，本任务追加武器档案注册、请求汇聚与射击事件消费）

**Interfaces:**
- Consumes: `SimWorld.configure_weapon_profile()`、`queue_fire_event()`、`queue_melee_event()`、`queue_spread_reset()`、`SimWorld.tick_shot_events`、`DemoArena._player_for_slot()`、`DemoArena._consume_sim_events()`。
- Produces:
  - `WeaponBase.set_sim_request_sink(value: Callable) -> void`
  - `WeaponBase.emit_sim_request(request: Dictionary) -> void`
  - 请求字典形状：
    - `{kind: &"shot", weapon_id: StringName, origin: Vector3, aim_direction: Vector3}`
    - `{kind: &"melee", weapon_id: StringName, damage: float, reach: float, half_width: float, origin: Vector3, aim_direction: Vector3}`
    - `{kind: &"spread_reset"}`
  - `RangedWeapon.show_tracer(from_position: Vector3, to_position: Vector3) -> void`
  - `EquipmentController.set_sim_request_sink(value: Callable) -> void`
  - `PlayerController.set_sim_request_sink(value: Callable) -> void`
  - `DemoArena.register_weapon_profiles() -> void`
  - `DemoArena.get_weapon_profile_index(weapon_id: StringName) -> int`

- [ ] **Step 1: 给 `WeaponBase` 增加模拟层请求出口**

在 `scripts/combat/weapons/weapon_base.gd` 的 `var owned := false`（第 27 行）之后追加：

```gdscript
var sim_request_sink := Callable()

## 武器不认识玩家槽位，也不认识模拟层的武器档案下标：
## 它只把「我要开火 / 我要挥击」的原始意图交给上层，
## 由竞技场翻译成 SimWorld 事件。武器因此不依赖 scripts/sim/。
func set_sim_request_sink(value: Callable) -> void:
	sim_request_sink = value

func emit_sim_request(request: Dictionary) -> void:
	if sim_request_sink.is_valid():
		sim_request_sink.call(request)
```

- [ ] **Step 2: 从 `RangedWeapon` 移除 `randomize()` 与本地散布**

在 `scripts/combat/weapons/ranged_weapon.gd` 中：

删除第 7 行的 `const MAX_PENETRATION_QUERY_COUNT := 64` 与第 8–10 行的 `const WeaponSpreadState = preload(...)`。

把第 16–18 行：

```gdscript
var weapon_trigger: WeaponTrigger
var spread_state: WeaponSpreadState
var spread_rng := RandomNumberGenerator.new()
```

替换为：

```gdscript
var weapon_trigger: WeaponTrigger
```

把 `_ready()`（第 23–36 行）替换为：

```gdscript
func _ready() -> void:
	var ranged_definition := definition as RangedWeaponDefinition
	weapon_trigger = WeaponTrigger.new(
		ranged_definition.trigger_mode,
		ranged_definition.attacks_per_second
	)
	_prewarm_tracers()
```

散布状态与其随机源都已迁入 `SimWorld`（`Stream.WEAPON_SPREAD`），因此 `spread_state`、`spread_rng` 与 `spread_rng.randomize()` 一并消失。

把 `_physics_process()`（第 52–61 行）替换为：

```gdscript
func _physics_process(delta: float) -> void:
	weapon_trigger.tick(delta)
	if (
		has_ammo_for_shot() and
		weapon_trigger.try_attack(trigger_pressed, trigger_just_pressed) and
		try_consume_ammo()
	):
		_fire(aim_direction)
	trigger_just_pressed = false
```

把 `set_equipped()`（第 110–113 行）替换为：

```gdscript
func set_equipped(value: bool) -> void:
	super.set_equipped(value)
	if not value:
		emit_sim_request({"kind": &"spread_reset"})
```

- [ ] **Step 3: 把 `RangedWeapon._fire()` 改为发出开火事件**

把 `_fire()`（第 138–166 行）替换为：

```gdscript
func _fire(shot_direction: Vector3) -> void:
	_sync_to_visual_anchor()
	var ranged_definition := definition as RangedWeaponDefinition
	var ray_origin := _sync_muzzle_to_capsule()
	var aim := WeaponMath.flat_direction(shot_direction)
	# 开火事件只携带玩家的瞄准方向，不携带散布后的方向：
	# 散布由各客户端在 Stream.WEAPON_SPREAD 上各自确定性地算出。
	emit_sim_request({
		"kind": &"shot",
		"weapon_id": ranged_definition.weapon_id,
		"origin": ray_origin,
		"aim_direction": aim,
	})
	# 枪口火焰与射击音高是纯表现，立即播放；曳光的终点要等模拟层解算。
	muzzle_flash.flash()
	shot_audio.pitch_scale = randf_range(0.97, 1.03)
	shot_audio.play()
	attack_resolved.emit(
		ray_origin,
		aim,
		HitResult.miss(ray_origin),
		ranged_definition.visual_recoil_kick,
		ranged_definition.camera_impulse_strength
	)

## 由竞技场在模拟层解算出本次射击的终点后调用。
func show_tracer(from_position: Vector3, to_position: Vector3) -> void:
	var tracer := _acquire_tracer()
	tracer.setup(from_position, to_position)
```

随后整段删除下列只服务于旧物理射线的函数：`_resolve_shot()`（第 177–239 行）、`_find_damage_target()`（第 241–247 行）、`_apply_damage()`（第 249–272 行）、`_merge_hit_result()`（第 274–282 行）、`_intersect_shot()`（第 284–302 行）。

- [ ] **Step 4: 把 `MeleeWeapon` 的命中窗口改为发出近战事件**

在 `scripts/combat/weapons/melee_weapon.gd` 中删除第 5 行的 `const MAX_MELEE_INTERSECTIONS := 64`（`LEGACY_MELEE_HITBOX_HALF_DEPTH` 保留）。

把 `_physics_process()` 中第 **32–47** 行的 `if not impact_resolved ... attack_resolved.emit(...)` 整块替换为下列内容，**保留第 48–49 行的**：

```gdscript
	if attack_elapsed >= melee_definition.attack_lock_duration:
		attack_pending = false
```

（第 26–31 行是 `_start_attack()`、`trigger_just_pressed = false`、`if not attack_pending: return` 与 `attack_elapsed += maxf(delta, 0.0)`，同样保留不动。）

```gdscript
	if not impact_resolved and attack_elapsed >= melee_definition.impact_delay:
		impact_resolved = true
		var impact_origin := (
			wielder.global_transform * Transform3D(
				Basis.IDENTITY,
				melee_definition.hitbox_offset
			)
		).origin
		# 前向可及距离逐字沿用旧的 forward_distance 上限；朝向沿用 wielder 的 -basis.z
		# （基线 _resolve_melee_hit() 就是把目标偏移投影到 wielder_forward 上判定的，
		# 不是投影到 aim_direction 上；两者在身体尚未转到瞄准方向时会分叉）。
		# 横向判定由旧的 BoxShape3D 重叠改为「半宽 + 僵尸圆半径」的解析近似，
		# 在 hitbox_size.x 较小时略宽于旧口径，属已知取舍。
		emit_sim_request({
			"kind": &"melee",
			"weapon_id": melee_definition.weapon_id,
			"damage": melee_definition.damage,
			"reach": (
				-melee_definition.hitbox_offset.z +
				melee_definition.hitbox_size.z * 0.5 +
				LEGACY_MELEE_HITBOX_HALF_DEPTH
			),
			"half_width": melee_definition.hitbox_size.x * 0.5,
			"origin": Vector3(
				wielder.global_position.x,
				impact_origin.y,
				wielder.global_position.z
			),
			"aim_direction": -wielder.global_transform.basis.z,
		})
		attack_resolved.emit(
			impact_origin,
			aim_direction,
			HitResult.miss(impact_origin),
			melee_definition.visual_recoil_kick,
			melee_definition.camera_impulse_strength
		)
```

随后整段删除 `_resolve_melee_hit()`（第 **77–138** 行）与 `_find_damage_target()`（第 **140–146** 行，即文件末尾）。`MeleeWeaponDefinition.hit_collision_mask` 保留不动：`validate_local_disconnect_contract.gd` 仍在断言它不含玩家层。

删除后 `_physics_process()` 里 `attack_resolved.emit()` 传的仍是 `aim_direction`（镜头后坐力方向是表现口径，保持基线不变）；只有递给模拟层的 `aim_direction` 字段改用 `-wielder.global_transform.basis.z`。

- [ ] **Step 5: 让装备控制器与玩家把 sink 透传下去**

在 `scripts/player/equipment_controller.gd` 的 `var place_item_service`（第 32 行）之后追加：

```gdscript
var sim_request_sink := Callable()

func set_sim_request_sink(value: Callable) -> void:
	sim_request_sink = value
	for item in equipment_items:
		if item.has_method("set_sim_request_sink"):
			item.set_sim_request_sink(sim_request_sink)
```

在 `setup()` 的 `item.set_place_item_service(place_item_service)`（第 72 行）之后追加：

```gdscript
			if item.has_method("set_sim_request_sink"):
				item.set_sim_request_sink(sim_request_sink)
```

在 `scripts/player/player_controller.gd` 的 `var place_item_service`（第 69 行）之后追加：

```gdscript
var sim_request_sink := Callable()

func set_sim_request_sink(value: Callable) -> void:
	sim_request_sink = value
	if equipment != null:
		equipment.set_sim_request_sink(sim_request_sink)
```

在 `_ready()` 的 `equipment.set_place_item_service(place_item_service)`（第 88 行）之后追加：

```gdscript
	equipment.set_sim_request_sink(sim_request_sink)
```

- [ ] **Step 6: 在竞技场注册武器档案并汇聚请求**

在 `scripts/gameplay/demo_arena.gd` 的常量区追加：

```gdscript
const PISTOL_DEFINITION := preload("res://resources/weapons/pistol.tres")
const RIFLE_DEFINITION := preload("res://resources/weapons/rifle.tres")
```

在 `var zombie_renderer: ZombieRenderer` 之后追加：

```gdscript
var weapon_profile_indices: Dictionary = {}
```

在 `_setup_simulation()` 的 `sim_clock.reset()` 之前插入 `register_weapon_profiles()`，并在文件中追加：

```gdscript
## 模拟层只认档案下标；这里把 weapon_id 映射到下标，顺序即注册顺序。
func register_weapon_profiles() -> void:
	weapon_profile_indices = {}
	var definitions: Array[RangedWeaponDefinition] = [
		PISTOL_DEFINITION,
		RIFLE_DEFINITION,
	]
	for profile_index in range(definitions.size()):
		var definition := definitions[profile_index]
		weapon_profile_indices[definition.weapon_id] = profile_index
		sim_world.configure_weapon_profile(
			profile_index,
			definition.damage,
			definition.attack_range,
			definition.base_spread_degrees,
			definition.max_spread_degrees,
			definition.spread_increase_per_shot_degrees,
			definition.spread_recovery_degrees_per_second,
			definition.max_penetration_count,
			definition.penetration_damage_coefficient
		)

func get_weapon_profile_index(weapon_id: StringName) -> int:
	return int(weapon_profile_indices.get(weapon_id, -1))

func _on_sim_request(request: Dictionary, slot: int) -> void:
	var kind: StringName = request["kind"]
	if kind == &"shot":
		var profile_index := get_weapon_profile_index(request["weapon_id"])
		if profile_index < 0:
			return
		var shot_origin: Vector3 = request["origin"]
		var shot_aim: Vector3 = request["aim_direction"]
		sim_world.queue_fire_event(
			slot,
			profile_index,
			Vector2(shot_origin.x, shot_origin.z),
			shot_origin.y,
			Vector2(shot_aim.x, shot_aim.z)
		)
		return
	if kind == &"melee":
		var melee_origin: Vector3 = request["origin"]
		var melee_aim: Vector3 = request["aim_direction"]
		sim_world.queue_melee_event(
			slot,
			float(request["damage"]),
			float(request["reach"]),
			float(request["half_width"]),
			Vector2(melee_origin.x, melee_origin.z),
			melee_origin.y,
			Vector2(melee_aim.x, melee_aim.z)
		)
		return
	if kind == &"spread_reset":
		sim_world.queue_spread_reset(slot)

func _on_sim_shot_event(event: Dictionary) -> void:
	var origin: Vector2 = event["origin"]
	var end_point: Vector2 = event["end"]
	var from_position := Vector3(origin.x, float(event["origin_height"]), origin.y)
	var to_position := Vector3(end_point.x, float(event["end_height"]), end_point.y)
	var shooter := _player_for_slot(int(event["slot"]))
	if shooter != null:
		var weapon = shooter.equipment.get_current_weapon()
		if weapon is RangedWeapon:
			(weapon as RangedWeapon).show_tracer(from_position, to_position)
	if not bool(event["did_hit"]):
		return
	var label := get_node_or_null("HUD/HitConfirm") as Label
	if label == null:
		return
	label.text = "KILL" if bool(event["killed"]) else "HIT"
	label.modulate = Color.WHITE
	if hit_confirm_tween != null and hit_confirm_tween.is_valid():
		hit_confirm_tween.kill()
	hit_confirm_tween = create_tween()
	hit_confirm_tween.tween_property(label, "modulate:a", 0.0, 0.18)
```

- [ ] **Step 7: 把请求 sink 绑到每个玩家槽位，并消费射击事件**

在 `_consume_sim_events()` 的 `for event in sim_world.tick_hit_events:` 循环之前插入：

```gdscript
	for event in sim_world.tick_shot_events:
		_on_sim_shot_event(event)
```

把 `_wire_dependencies()` 末尾的玩家循环（Task 7 之后仍为 `for player in current_players:` 一段）替换为：

```gdscript
	for slot_index in range(current_players.size()):
		var player := current_players[slot_index]
		player.set_movement_camera(movement_camera)
		player.set_place_item_service(place_item_service)
		player.set_sim_request_sink(
			Callable(self, "_on_sim_request").bind(slot_index)
		)
		if not player.attack_resolved.is_connected(_on_player_attack):
			player.attack_resolved.connect(_on_player_attack)
		if not player.damaged.is_connected(_on_player_damaged):
			player.damaged.connect(_on_player_damaged)
```

槽位下标即 `current_players` 中的位置，与 `_player_for_slot()` 和 `SimWorld` 的玩家快照槽位一一对应。

把 `_on_player_attack()`（基线第 382–397 行）替换为：

```gdscript
## 镜头后坐力是纯表现，命中确认改由模拟层的射击事件驱动。
func _on_player_attack(
	direction: Vector3,
	_result: HitResult,
	camera_impulse_strength: float
) -> void:
	var follow_camera := get_node("FollowCamera") as FollowCamera
	follow_camera.add_shot_impulse(direction, camera_impulse_strength)
```

- [ ] **Step 8: 静态检查与确定性回归**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
rg -n "randomize\(\)" scripts || echo "no randomize() left in scripts"
rg -n "RandomNumberGenerator" scripts | rg -v "^scripts/fx/" \
  || echo "RandomNumberGenerator only survives in fx"
rg -n "intersect_ray|intersect_shape" scripts/combat/weapons \
  || echo "weapons perform no physics queries"
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_local_disconnect_contract.gd
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_equipment_cycle.gd
# 确定性回归耗时 10–40 分钟，后台跑（见 Global Constraints）
nohup /Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_sim_determinism.gd \
  > /tmp/zw_determinism_task8.log 2>&1 &
```

Expected: 导入检查退出码 0；`no randomize() left in scripts`；`RandomNumberGenerator only survives in fx`（若有命中，必须全部位于 `scripts/fx/`）；`weapons perform no physics queries`；`validate_local_disconnect_contract` 与 `validate_equipment_cycle` 各打印 `: PASS`；`/tmp/zw_determinism_task8.log` 最终打印 `validate_sim_determinism: PASS`。

- [ ] **Step 9: 人工确认射击链路（需要用户执行并截图）**

请用户执行：

1. `/Applications/Godot.app/Contents/MacOS/Godot --path .` 进入单人 Demo。
2. 按 `T` 生成一波僵尸，用手枪与步枪各扫射一段，确认曳光落点、命中掉血、HUD 出现 `HIT` / `KILL`、击杀后出现血泊。
3. 切到匕首近战击杀一只僵尸。
4. 连续长按步枪射击 3 秒，确认弹着点随连射逐渐散开、松开后收拢。
5. 截图 HUD 与命中瞬间，交回分析。

Expected: 曳光终点与僵尸位置一致；命中确认与血迹恢复；渐进散布可见且会恢复。

- [ ] **Step 10: 提交**

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add scripts/combat/weapons/weapon_base.gd scripts/combat/weapons/ranged_weapon.gd \
  scripts/combat/weapons/melee_weapon.gd scripts/player/equipment_controller.gd \
  scripts/player/player_controller.gd scripts/gameplay/demo_arena.gd
git commit -m "feat: route weapon fire through the simulation layer"
```

Expected: 提交只含上述六个脚本。

---

### Task 9: 运行时增删阻挡几何必须标脏 cell

**Files:**
- Modify: `scripts/props/explosive_barrel.gd:8-9,109-136`
- Modify: `scripts/gameplay/place_item_service.gd:4-5,45-63`
- Modify: `scripts/gameplay/pickup_spawn_point.gd:4-14,20-52`
- Modify: `scripts/combat/explosion_resolver.gd:1-17`
- Modify: `scripts/gameplay/demo_arena.gd`（`_wire_dependencies()` 的爆炸桶与拾取点区块，追加标脏处理函数）

**Interfaces:**
- Consumes: `PlaceItemGrid.collision_object_world_aabb()`、`SimWorld.set_blocker_world_rect()`、`SimWorld.queue_explosion_event()`、`DemoArena.mark_blocker()`。
- Produces:
  - `ExplosiveBarrel.blocker_cleared(world_aabb: AABB)`（信号）
  - `ExplosiveBarrel.sim_explosion_requested(origin: Vector3, radius: float, center_damage: float, edge_damage: float)`（信号）
  - `PlaceItemService.item_placed(item: Node3D)`（信号）
  - `PlaceItemService.item_removed(world_aabb: AABB)`（信号）
  - `PickupSpawnPoint.blocker_changed(world_aabb: AABB, blocked: bool)`（信号）
  - `PickupSpawnPoint.get_current_pickup() -> PickupChest`
  - `DemoArena._on_blocker_cleared(world_aabb: AABB) -> void`
  - `DemoArena._on_blocker_added(item: Node3D) -> void`
  - `DemoArena._on_pickup_blocker_changed(world_aabb: AABB, blocked: bool) -> void`
  - `DemoArena._on_barrel_sim_explosion(origin: Vector3, radius: float, center_damage: float, edge_damage: float) -> void`
  - `DemoArena._wire_explosive_barrel(barrel: Node) -> void`

- [ ] **Step 1: 让爆炸桶广播自己的阻挡范围与模拟层爆炸**

在 `scripts/props/explosive_barrel.gd` 的 `signal navigation_geometry_changed`（第 9 行）之后追加：

```gdscript
## 销毁前广播自己占用的世界 AABB，供流场清除对应 cell。
## 必须在禁用碰撞形状之前采集，否则 AABB 会变成空。
signal blocker_cleared(world_aabb: AABB)
## 爆炸的波及判定与伤害衰减在模拟层完成；本信号只负责把参数递出去。
signal sim_explosion_requested(
	origin: Vector3,
	radius: float,
	center_damage: float,
	edge_damage: float
)
```

把 `_execute_explosion()`（第 109–135 行）替换为：

```gdscript
func _execute_explosion() -> void:
	if state != State.EXPLODING:
		return
	var origin := get_explosion_aim_point()
	var blocker_bounds := PlaceItemGrid.collision_object_world_aabb(self)
	if collision_shape != null:
		collision_shape.set_deferred("disabled", true)
	if damage_smoke != null:
		if damage_smoke.has_method("deactivate"):
			damage_smoke.call("deactivate")
		else:
			damage_smoke.visible = false
	_spawn_explosion_fx(origin)
	blocker_cleared.emit(blocker_bounds)
	sim_explosion_requested.emit(
		origin,
		explosion_radius,
		explosion_center_damage,
		explosion_edge_damage
	)
	var world := get_world_3d()
	if world != null:
		ExplosionResolver.resolve(
			world,
			origin,
			explosion_radius,
			explosion_center_damage,
			explosion_edge_damage,
			self,
			true,
			explosion_target_mask,
			explosion_obstacle_mask
		)
	state = State.DESTROYED
	call_deferred("_finish_destroyed")
```

`ExplosionResolver.resolve()` 保留：它仍要处理玩家与连锁引爆的其他爆炸桶，这些都还在物理世界里。僵尸的波及判定改由 `sim_explosion_requested` 走模拟层。

- [ ] **Step 2: 在 `ExplosionResolver` 写明职责边界**

把 `scripts/combat/explosion_resolver.gd` 第 1–6 行替换为：

```gdscript
extends RefCounted
class_name ExplosionResolver

## 物理世界里的爆炸波及判定：玩家、连锁引爆的其他爆炸桶、以及任何仍是
## CollisionObject3D 的可伤害目标。
##
## 僵尸不在此列：S0 之后僵尸已退出 Godot 物理世界，其波及判定与伤害衰减
## 由 SimCombat.resolve_explosion_targets() 在 SimWorld 上完成
## （入口是 ExplosiveBarrel.sim_explosion_requested）。
## 两条路径共用 ExplosionMath.damage_at_distance() 的衰减公式。
const ExplosionMath = preload("res://scripts/combat/explosion_math.gd")
const MAX_INTERSECTIONS := 128
```

- [ ] **Step 3: 让 `PlaceItemService` 广播放置与移除**

在 `scripts/gameplay/place_item_service.gd` 的 `signal placement_rejected(reason: StringName)`（第 5 行）之后追加：

```gdscript
## 运行时放置的油桶是新的阻挡几何，必须标脏对应 cell。
signal item_placed(item: Node3D)
## 移除时广播消失前采集的世界 AABB。
signal item_removed(world_aabb: AABB)
```

把 `request_place_item()` 结尾的两行（第 47–48 行）：

```gdscript
	placement_geometry_changed.emit()
	return true
```

替换为：

```gdscript
	placement_geometry_changed.emit()
	item_placed.emit(item)
	return true
```

把 `_on_item_tree_exiting()`（第 54–62 行）替换为：

```gdscript
func _on_item_tree_exiting(item: Node3D) -> void:
	var item_id := item.get_instance_id()
	if not tracked_items.erase(item_id):
		return
	var bounds := PlaceItemGrid.collision_object_world_aabb(
		item as CollisionObject3D
	)
	var grid := get_node_or_null(grid_path) as PlaceItemGrid
	if grid != null:
		grid.release_owner(item)
	if is_inside_tree():
		placement_geometry_changed.emit()
	item_removed.emit(bounds)
```

- [ ] **Step 4: 让 `PickupSpawnPoint` 广播拾取箱的出现与消失**

在 `scripts/gameplay/pickup_spawn_point.gd` 的 `signal navigation_geometry_changed`（第 4 行）之后追加：

```gdscript
## 拾取箱本身是静态阻挡（place_item_obstacle 组、collision_layer = 1），
## 出现与消失都必须标脏对应 cell。
signal blocker_changed(world_aabb: AABB, blocked: bool)
```

在 `var respawn_requested := false`（第 14 行）之后追加：

```gdscript
var current_pickup_bounds := AABB()
```

在 `_spawn_pickup()` 结尾的 `navigation_geometry_changed.emit()`（第 41 行）之后追加：

```gdscript
	current_pickup_bounds = PlaceItemGrid.collision_object_world_aabb(current_pickup)
	blocker_changed.emit(current_pickup_bounds, true)
```

在 `_on_pickup_tree_exited()` 的 `navigation_geometry_changed.emit()`（第 52 行）之后追加：

```gdscript
	blocker_changed.emit(current_pickup_bounds, false)
	current_pickup_bounds = AABB()
```

并在文件末尾追加：

```gdscript
func get_current_pickup() -> PickupChest:
	return current_pickup
```

- [ ] **Step 5: 在竞技场接上三条标脏通路**

把 `scripts/gameplay/demo_arena.gd` 的 `_wire_dependencies()` 中爆炸桶区块（基线第 177–190 行）替换为：

```gdscript
	var barrels_root := get_node_or_null(
		"World/Props/HazardZone/ExplosiveBarrels"
	)
	if barrels_root != null:
		for barrel in barrels_root.get_children():
			_wire_explosive_barrel(barrel)
		if not barrels_root.child_entered_tree.is_connected(_wire_explosive_barrel):
			barrels_root.child_entered_tree.connect(_wire_explosive_barrel)
```

把拾取点区块（基线第 191–202 行）替换为：

```gdscript
	var pickup_spawners := get_node_or_null("World/Props/PickupSpawners")
	if pickup_spawners != null:
		for child in pickup_spawners.get_children():
			var spawner := child as PickupSpawnPoint
			if spawner == null:
				continue
			if not spawner.navigation_geometry_changed.is_connected(
				_on_runtime_navigation_geometry_changed
			):
				spawner.navigation_geometry_changed.connect(
					_on_runtime_navigation_geometry_changed
				)
			if not spawner.blocker_changed.is_connected(_on_pickup_blocker_changed):
				spawner.blocker_changed.connect(_on_pickup_blocker_changed)
```

把放置服务区块（基线第 213–224 行）替换为：

```gdscript
	var place_item_service = get_node_or_null("PlaceItemService")
	if place_item_service != null:
		if not place_item_service.placement_geometry_changed.is_connected(
			_on_runtime_navigation_geometry_changed
		):
			place_item_service.placement_geometry_changed.connect(
				_on_runtime_navigation_geometry_changed
			)
		if not place_item_service.item_placed.is_connected(_on_blocker_added):
			place_item_service.item_placed.connect(_on_blocker_added)
		if not place_item_service.item_removed.is_connected(_on_blocker_cleared):
			place_item_service.item_removed.connect(_on_blocker_cleared)
```

在文件中追加处理函数：

```gdscript
func _wire_explosive_barrel(barrel: Node) -> void:
	var explosive := barrel as ExplosiveBarrel
	if explosive == null:
		return
	if not explosive.navigation_geometry_changed.is_connected(
		_on_runtime_navigation_geometry_changed
	):
		explosive.navigation_geometry_changed.connect(
			_on_runtime_navigation_geometry_changed
		)
	if not explosive.blocker_cleared.is_connected(_on_blocker_cleared):
		explosive.blocker_cleared.connect(_on_blocker_cleared)
	if not explosive.sim_explosion_requested.is_connected(_on_barrel_sim_explosion):
		explosive.sim_explosion_requested.connect(_on_barrel_sim_explosion)

func _on_blocker_added(item: Node3D) -> void:
	var obstacle := item as CollisionObject3D
	if obstacle != null:
		mark_blocker(obstacle, true)

func _on_blocker_cleared(world_aabb: AABB) -> void:
	_apply_blocker_bounds(world_aabb, false)

func _on_pickup_blocker_changed(world_aabb: AABB, blocked: bool) -> void:
	_apply_blocker_bounds(world_aabb, blocked)

func _apply_blocker_bounds(world_aabb: AABB, blocked: bool) -> void:
	if world_aabb.size == Vector3.ZERO:
		return
	sim_world.set_blocker_world_rect(
		Vector2(world_aabb.position.x, world_aabb.position.z),
		Vector2(world_aabb.end.x, world_aabb.end.z),
		blocked
	)

func _on_barrel_sim_explosion(
	origin: Vector3,
	radius: float,
	center_damage: float,
	edge_damage: float
) -> void:
	sim_world.queue_explosion_event(
		Vector2(origin.x, origin.z),
		origin.y,
		radius,
		center_damage,
		edge_damage
	)
```

- [ ] **Step 6: 冒烟验证三条标脏通路都会触发流场重算**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
cat > tools/validation/zw_blocker_dirty_smoke.gd <<'EOF'
extends SceneTree

const SimWorldScript = preload("res://scripts/sim/sim_world.gd")

func _init() -> void:
	var world = SimWorldScript.new()
	world.configure(Vector2(-24.5, -19.5), 1.0, 49, 39)
	world.reset(1)
	world.set_player_snapshot(0, Vector2(0.0, 0.0), true, true)
	world.step_tick()
	var baseline := world.get_flow_field().get_rebuild_count()
	world.step_tick()
	var idle := world.get_flow_field().get_rebuild_count()
	world.set_blocker_world_rect(Vector2(3.0, -1.0), Vector2(5.0, 1.0), true)
	world.step_tick()
	var after_add := world.get_flow_field().get_rebuild_count()
	world.set_blocker_world_rect(Vector2(3.0, -1.0), Vector2(5.0, 1.0), false)
	world.step_tick()
	var after_remove := world.get_flow_field().get_rebuild_count()
	print("baseline=%d idle=%d after_add=%d after_remove=%d" % [
		baseline, idle, after_add, after_remove
	])
	quit(0)
EOF
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/zw_blocker_dirty_smoke.gd
rm -f tools/validation/zw_blocker_dirty_smoke.gd tools/validation/zw_blocker_dirty_smoke.gd.uid
```

Expected: 输出 `baseline=1 idle=1 after_add=2 after_remove=3` —— 玩家不动且阻挡未变时不重算，增删阻挡各触发一次重算。冒烟脚本运行后必须删除；`.uid` 只有在编辑器导入过一次后才存在，因此用 `rm -f` 而不是 `rm`。

- [ ] **Step 7: 静态检查与确定性回归**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_flow_field.gd
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_pickup_spawn_point.gd
git status --short
```

Expected: 导入检查退出码 0；两个验证脚本各打印 `: PASS`；`git status --short` 中不含 `zw_blocker_dirty_smoke.gd`。

- [ ] **Step 8: 人工确认阻挡随几何变化（需要用户执行并截图）**

请用户执行：

1. 进入单人 Demo，按 `T` 生成僵尸并让它们朝集装箱与油桶方向聚集。
2. 打爆一个爆炸桶，确认原地不再阻挡僵尸，僵尸会走过原来的桶位。
3. 拿到油桶装备后在僵尸来路上放置一个，确认僵尸绕行而不是穿过去。
4. 领走一个拾取箱，确认原位置不再阻挡僵尸。
5. 截图三处对比，交回分析。

Expected: 三种运行时几何变更后，僵尸的通行/绕行行为都在下一秒内跟随变化，没有「绕着已经不存在的障碍走」的残留。

- [ ] **Step 9: 提交**

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add scripts/props/explosive_barrel.gd scripts/gameplay/place_item_service.gd \
  scripts/gameplay/pickup_spawn_point.gd scripts/combat/explosion_resolver.gd \
  scripts/gameplay/demo_arena.gd
git commit -m "feat: mark flow field cells dirty on runtime blocker changes"
```

Expected: 提交只含上述五个脚本。

---

### Task 10: 玩家活动区改为世界坐标固定矩形

`PlayerScreenBounds.limit_motion()` 使用 `camera.get_viewport().get_visible_rect().size`，而 `project.godot` 配置为 `window/stretch/aspect="expand"`，不同宽高比的设备会得到不同的可视区域。本地共屏时无影响；联机时手机 20:9 与桌面 16:9 的玩家会拿到不同的移动边界，这本身即是不同步源。

**Files:**
- Modify: `scripts/camera/player_screen_bounds.gd:16-38`
- Modify: `scripts/gameplay/game_session.gd:4-7`
- Modify: `scripts/player/player_controller.gd:53-56,188-201`
- Modify: `scripts/gameplay/demo_arena.gd`（玩家循环中追加活动区锚点）
- Test: `tools/validation/validate_player_screen_bounds.gd:36-41`

**Interfaces:**
- Consumes: `FollowCamera.global_position`（`PlayerController.world_bounds_anchor` 声明为 `Node3D`，读的是 `global_position`；`FollowCamera.get_anchor_position()` 返回的正是同一个值，两者等价）、`GameSessionState.mode`。
- Produces:
  - `PlayerScreenBounds.ONLINE_BOUNDS_HALF_WIDTH: float = 11.2`
  - `PlayerScreenBounds.ONLINE_BOUNDS_HALF_DEPTH: float = 9.7`
  - `PlayerScreenBounds.limit_motion_in_world_rect(anchor_position: Vector3, world_position: Vector3, desired_motion: Vector3, half_width: float, half_depth: float) -> Vector3`
  - `GameSessionState.Mode.ONLINE_MULTIPLAYER = 2`
  - `PlayerController.set_world_bounds_anchor(anchor: Node3D) -> void`
  - `PlayerController.uses_world_bounds() -> bool`

- [ ] **Step 1: 增加世界坐标固定矩形限位**

在 `scripts/camera/player_screen_bounds.gd` 的 `screen_to_plane()` 之后、`limit_motion()` 之前插入：

```gdscript
## 联机模式的共享活动区：镜头中心 ± 固定半宽半高，不做屏幕反投影。
##
## 数值由现有取景反推，锁死在 16:9：
##   正交 size = 15.0（scenes/camera/FollowCamera.tscn）
##   俯角 40.3°，sin(40.3°) ≈ 0.6468
##   地面纵向可视高度 = 15.0 / 0.6468 ≈ 23.19，半高 ≈ 11.60
##   地面横向可视宽度 = 15.0 * 16 / 9 ≈ 26.67，半宽 ≈ 13.33
##   再乘以 safe_margin_ratio = 0.08 两侧留边后的 0.84
##   => 半宽 11.2、半深 9.7
## 宽高比更大的设备只是看得更多，走不到更远，因此各端边界一致。
const ONLINE_BOUNDS_HALF_WIDTH := 11.2
const ONLINE_BOUNDS_HALF_DEPTH := 9.7

static func limit_motion_in_world_rect(
	anchor_position: Vector3,
	world_position: Vector3,
	desired_motion: Vector3,
	half_width: float,
	half_depth: float
) -> Vector3:
	var desired := world_position + desired_motion
	var clamped := Vector3(
		clampf(
			desired.x,
			anchor_position.x - half_width,
			anchor_position.x + half_width
		),
		desired.y,
		clampf(
			desired.z,
			anchor_position.z - half_depth,
			anchor_position.z + half_depth
		)
	)
	var limited := clamped - world_position
	limited.y = desired_motion.y
	return limited
```

`limit_motion()` 原样保留：单人与本地多人继续使用它。

- [ ] **Step 2: 给 `GameSessionState` 增加联机模式枚举值**

把 `scripts/gameplay/game_session.gd` 第 4–7 行替换为：

```gdscript
enum Mode {
	SINGLE,
	LOCAL_MULTIPLAYER,
	ONLINE_MULTIPLAYER,
}
```

只加枚举值，不加 `configure_online()`：房间与大厅属 S2，本任务只需要一个可分支的模式标识。既有 `demo_arena._handle_player_spawn_failure()` 中的 `session.mode == 1` 判断不受影响。

- [ ] **Step 3: 让 `PlayerController` 按模式分支**

在 `scripts/player/player_controller.gd` 的 `var screen_camera: Camera3D`（第 54 行）之后追加：

```gdscript
var world_bounds_anchor: Node3D
```

在 `set_screen_camera()`（第 108–109 行）之后追加：

```gdscript
func set_world_bounds_anchor(anchor: Node3D) -> void:
	world_bounds_anchor = anchor

## 只有联机模式才用世界坐标矩形；单人与本地多人保持现有屏幕安全区行为。
func uses_world_bounds() -> bool:
	if world_bounds_anchor == null or not is_instance_valid(world_bounds_anchor):
		return false
	var session := get_node_or_null("/root/GameSession")
	return (
		session != null and
		session.mode == GameSessionState.Mode.ONLINE_MULTIPLAYER
	)
```

把 `_physics_process()` 中的限位区块（第 188–201 行）替换为：

```gdscript
	var desired_motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	if _bounds_are_active():
		desired_motion = _limit_desired_motion(desired_motion)
		if delta > 0.000001:
			velocity.x = desired_motion.x / delta
			velocity.z = desired_motion.z / delta
			if knockback_active:
				knockback_velocity.x = velocity.x
				knockback_velocity.z = velocity.z
```

并在 `_actual_ranged_attack_direction()` 之前追加：

```gdscript
func _bounds_are_active() -> bool:
	if uses_world_bounds():
		return true
	return screen_camera != null and is_input_online()

func _limit_desired_motion(desired_motion: Vector3) -> Vector3:
	if uses_world_bounds():
		return PlayerScreenBoundsScript.limit_motion_in_world_rect(
			world_bounds_anchor.global_position,
			global_position,
			desired_motion,
			PlayerScreenBoundsScript.ONLINE_BOUNDS_HALF_WIDTH,
			PlayerScreenBoundsScript.ONLINE_BOUNDS_HALF_DEPTH
		)
	return PlayerScreenBoundsScript.limit_motion(
		screen_camera,
		global_position,
		desired_motion,
		screen_safe_margin_ratio
	)
```

- [ ] **Step 4: 在竞技场传入活动区锚点**

在 `scripts/gameplay/demo_arena.gd` 的玩家循环（Task 8 改造后的 `for slot_index in range(current_players.size()):` 一段）中，`player.set_place_item_service(place_item_service)` 之后追加：

```gdscript
		player.set_world_bounds_anchor(follow_camera)
```

`follow_camera` 在该函数内已经取到（基线第 245 行），且非空才会走到这段循环。

- [ ] **Step 5: 扩充 `validate_player_screen_bounds.gd` 覆盖世界矩形**

在 `tools/validation/validate_player_screen_bounds.gd` 的 `_expect(bounds.limit_motion(camera, right_world, outward_world, 0.10).is_equal_approx(outward_limited), ...)`（第 40 行）之后插入：

```gdscript
	var anchor := Vector3(4.0, 0.0, -2.0)
	var inside := Vector3(4.0, 0.0, -2.0)
	var free_motion := Vector3(1.0, 0.0, 1.0)
	_expect(
		bounds.limit_motion_in_world_rect(
			anchor,
			inside,
			free_motion,
			bounds.ONLINE_BOUNDS_HALF_WIDTH,
			bounds.ONLINE_BOUNDS_HALF_DEPTH
		).is_equal_approx(free_motion),
		"world rect must not clip motion near the anchor",
		failures
	)
	var edge := Vector3(
		anchor.x + bounds.ONLINE_BOUNDS_HALF_WIDTH,
		0.0,
		anchor.z + bounds.ONLINE_BOUNDS_HALF_DEPTH
	)
	var outward := Vector3(3.0, 0.0, 3.0)
	var clipped: Vector3 = bounds.limit_motion_in_world_rect(
		anchor,
		edge,
		outward,
		bounds.ONLINE_BOUNDS_HALF_WIDTH,
		bounds.ONLINE_BOUNDS_HALF_DEPTH
	)
	_expect(
		clipped.is_equal_approx(Vector3.ZERO),
		"world rect must clip motion that leaves the fixed rectangle",
		failures
	)
	var inward := Vector3(-2.0, 0.0, -2.0)
	_expect(
		bounds.limit_motion_in_world_rect(
			anchor,
			edge,
			inward,
			bounds.ONLINE_BOUNDS_HALF_WIDTH,
			bounds.ONLINE_BOUNDS_HALF_DEPTH
		).is_equal_approx(inward),
		"world rect must allow motion back toward the anchor",
		failures
	)
	var shifted_anchor := anchor + Vector3(5.0, 0.0, 0.0)
	_expect(
		bounds.limit_motion_in_world_rect(
			shifted_anchor,
			edge,
			outward,
			bounds.ONLINE_BOUNDS_HALF_WIDTH,
			bounds.ONLINE_BOUNDS_HALF_DEPTH
		).x > 0.0,
		"the world rect must travel with the shared camera anchor",
		failures
	)
	var player_probe = PlayerScene.instantiate()
	root.add_child(player_probe)
	player_probe.set_physics_process(false)
	_expect(
		player_probe.has_method("set_world_bounds_anchor"),
		"PlayerController must accept a world bounds anchor",
		failures
	)
	_expect(
		not player_probe.uses_world_bounds(),
		"single player must keep the screen-space bounds",
		failures
	)
	player_probe.queue_free()
```

- [ ] **Step 6: 运行验证与静态检查**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_player_screen_bounds.gd
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . --script res://tools/validation/validate_shared_camera_scene.gd
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
```

Expected: `validate_player_screen_bounds: PASS` 与 `validate_shared_camera_scene: PASS`；导入检查退出码 0。

- [ ] **Step 7: 提交**

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add scripts/camera/player_screen_bounds.gd scripts/gameplay/game_session.gd \
  scripts/player/player_controller.gd scripts/gameplay/demo_arena.gd \
  tools/validation/validate_player_screen_bounds.gd
git commit -m "feat: add world space player bounds for online mode"
```

Expected: 提交只含上述五个文件。

---

### Task 11: 修订 AGENTS.md 并标记运行时导航退役

`AGENTS.md` 的「3D Runtime Navigation」一节要求场景级导航管理器与运行时异步分块烘焙。S0 后僵尸不再使用该体系，且异步烘焙的完成时机本身不确定，与确定性模拟互斥。spec 明确要求该修订属交付内容，不得静默进行。

**Files:**
- Modify: `AGENTS.md:17-25`
- Modify: `scripts/navigation/navigation_world_manager.gd:1-2`
- Modify: `scripts/navigation/navigation_chunk_3d.gd:1-2`
- Modify: `scripts/navigation/navigation_bake_state.gd:1-2`

**Interfaces:**
- Consumes: 无。
- Produces: 无新的代码接口；本任务只改文档与退役注释。

- [ ] **Step 1: 核对导航体系的剩余消费者**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
rg -n "NavigationWorldManager|NavigationChunk3D|NavigationBakeState|NavigationAgent3D" \
  scripts scenes tools
ls tools/validation | rg -i navigation || echo "no navigation validation script exists"
```

Expected: 命中只应出现在 `scripts/navigation/**`、`scenes/navigation/NavigationChunk3D.tscn`、`scenes/gameplay/DemoArena.tscn` 的 `World/Navigation` 子树，以及 `demo_arena.gd` 的 `_on_navigation_chunk_bake_failed()` / `_on_runtime_navigation_geometry_changed()`；`scripts/combat/zombie_target.gd` 与 `scenes/targets/ZombieTarget.tscn` 不应再出现。第二条命令输出 `no navigation validation script exists`（本仓库从未有过导航验证脚本，spec 中「及其验证脚本」一项因此为空集，如实记录即可）。

- [ ] **Step 2: 重写 `AGENTS.md` 的「3D Runtime Navigation」一节**

把 `AGENTS.md` 第 17–25 行整节替换为：

```markdown
## 3D Runtime Navigation

Zombie pathfinding uses the deterministic flow field in `scripts/sim/`
(`FlowFieldGrid` + `FlowField`): an XZ integer grid with multi-source BFS over
integer costs, rebuilt synchronously whenever a player crosses a cell boundary
or the blocker set is marked dirty. Runtime navigation baking does not
participate in the simulation layer, and no simulation code may call
`NavigationAgent3D`, `NavigationServer3D`, or any asynchronous bake: the
completion time of an async bake is itself nondeterministic and would break
lockstep replay.

Any system that adds, removes, moves, enables, or disables collision geometry
that blocks movement must mark the affected flow field cells dirty after the
geometry change, by routing a world AABB through
`SimWorld.set_blocker_world_rect()`. Explosive barrel destruction,
`PlaceItemService` placement and removal, and pickup chest appearance and
disappearance all go through this path. Missing a dirty mark leaves zombies
walking around obstacles that no longer exist.

`NavigationWorldManager`, `NavigationChunk3D`, and `NavigationBakeState` are
**retired but retained**. They are still instantiated by `DemoArena` and still
respond to geometry-changed signals, but nothing in gameplay consumes their
navigation meshes. Do not build new features on them. They will be deleted once
the S3 synchronisation layer lands and confirms no other consumer exists.

When changing zombie movement behaviour, verify pursuit, wandering, unreachable
targets, blocked attack paths, and runtime blocker changes with
`tools/validation/validate_flow_field.gd`,
`tools/validation/validate_sim_collision.gd`, and
`tools/validation/validate_sim_determinism.gd`.
```

- [ ] **Step 3: 给三个导航脚本加上退役标记**

在 `scripts/navigation/navigation_world_manager.gd` 的 `class_name NavigationWorldManager`（第 2 行）之后插入：

```gdscript

## RETIRED (S0 确定性模拟地基, 2026-08-07)：僵尸寻路已全量迁移到
## scripts/sim/flow_field.gd 的确定性流场。本文件保留是为了让 DemoArena 的
## World/Navigation 子树继续加载，以及给尚未迁移的将来消费者留一个过渡期。
## 不要在其上构建新功能。待 S3 同步层落地并确认无其他消费者后删除。
```

在 `scripts/navigation/navigation_chunk_3d.gd` 的 `class_name NavigationChunk3D`（第 2 行）之后插入：

```gdscript

## RETIRED (S0 确定性模拟地基, 2026-08-07)：运行时异步烘焙的完成时机不确定，
## 与确定性模拟互斥，已不参与僵尸寻路。保留但不得用于新功能。
```

在 `scripts/navigation/navigation_bake_state.gd` 的 `class_name NavigationBakeState`（第 2 行）之后插入：

```gdscript

## RETIRED (S0 确定性模拟地基, 2026-08-07)：随 NavigationChunk3D 一并退役。
## 保留但不得用于新功能。
```

- [ ] **Step 4: 核对文档与实现一致**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
rg -n "RETIRED" scripts/navigation
rg -n "flow field|set_blocker_world_rect|validate_sim_determinism" AGENTS.md
rg -n "Bake navigation meshes asynchronously at runtime" AGENTS.md \
  || echo "the async bake mandate is gone from AGENTS.md"
rg -n "tests/run_tests.sh|^tests/" . --glob '!docs/**' || echo "no test suite resurrected"
rg -n "LOOT_DROP" scripts/sim | rg -v deterministic_rng.gd \
  || echo "LOOT_DROP is reserved and unused"
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path . --quit
```

Expected: 三个导航脚本各命中一处 `RETIRED`；`AGENTS.md` 命中新的流场与标脏要求；输出 `the async bake mandate is gone from AGENTS.md`；输出 `no test suite resurrected`；输出 `LOOT_DROP is reserved and unused`（该流本轮只占位，见 Global Constraints；一旦有实际抽取点，这条断言会转为命中，届时必须同步更新 Global Constraints 的说明）；导入检查退出码 0。

- [ ] **Step 5: 全量复跑 S0 验收**

复跑范围必须是 `tools/validation/` 在 Task 7 删除 `validate_zombie_multiplayer_wiring.gd` 之后**剩下的全部脚本**，而不是只跑本计划新增的那几个。其中 `validate_mobile_equipment_controls.gd` 与 `validate_local_player_spawning.gd` 会实例化 `scenes/gameplay/DemoArena.tscn` 并断言 `_wire_dependencies()` 的注入路径与 `Players` 容器，正是 Task 7 / 8 / 9 重写的代码路径；漏跑它们会让回归静默漏网。

这一步整体耗时以小时计（`validate_sim_determinism` 一项就要 10–40 分钟），**放到后台跑**。

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
for script in validate_deterministic_rng validate_flow_field validate_sim_collision \
  validate_sim_determinism validate_player_screen_bounds validate_shared_camera_math \
  validate_shared_camera_scene validate_equipment_cycle validate_local_disconnect_contract \
  validate_pickup_spawn_point validate_zombie_target_selector validate_local_input_contracts \
  validate_local_join_state validate_local_multiplayer_menu_scenes validate_local_player_spawning \
  validate_local_team_state validate_lobby_player_preview validate_mobile_equipment_controls \
  validate_single_player_input_wiring; do
  /Applications/Godot.app/Contents/MacOS/Godot \
    --headless --path . --script "res://tools/validation/$script.gd" || echo "FAILED: $script"
done
```

Expected: 19 个脚本各打印一行 `<name>: PASS`，没有任何 `FAILED:` 行。若 `ls tools/validation/validate_*.gd` 的实际清单与上面不一致（例如主线又新增了验证脚本），以实际清单为准跑全量，不得只跑列出的这些。

- [ ] **Step 6: 人工验收（需要用户执行并提供截图，不使用 CUA）**

请用户执行并提供截图：

1. 导出 Web 版：`mkdir -p build/web && /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --export-release Web build/web/index.html`，在手机浏览器打开。
2. 连按屏幕上的生成按钮直到 `ALIVE` 达到 300（Task 7 Step 9 已把 `maximum_active_zombies` 放宽到 300、每角 12–18 只，连按 5 次即可打满），持续观察 30 秒。
3. 截图 1：300 僵尸同屏时的画面（含近景骨骼动画与远景 MultiMesh 的衔接）。
4. 截图 2：浏览器帧率显示或录屏，用于确认稳定在 30fps 以上。
5. 截图 3：僵尸绕过集装箱与路障的路径表现。

Expected: 手机 H5 上 300 僵尸稳定 30fps 以上；近景至多 48 只（`NEAR_LOD_COUNT`，且只覆盖锚点 `BLOCKER_RADIUS = 15.0` 米内）有动画、远景静止姿势且朝向正确；僵尸绕行障碍而非穿越。若帧率不达标，先看 `ZombieRenderer.NEAR_LOD_COUNT` 与流场重算频率，不得通过降低 `SimClock` 频率或放宽确定性来换取帧率。

- [ ] **Step 7: 提交**

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add AGENTS.md scripts/navigation/navigation_world_manager.gd \
  scripts/navigation/navigation_chunk_3d.gd scripts/navigation/navigation_bake_state.gd
git commit -m "docs: retire runtime navigation baking for deterministic flow field"
```

Expected: 提交只含 `AGENTS.md` 与三个导航脚本。
