# 本地确定性帧同步核心 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不接入现有战斗场景的前提下，交付可录像、可回放、可逐 Tick Hash 比对的本地 30 Hz 确定性模拟核心，并以连续 100,000 Tick 零分歧作为 Plan 2 至 Plan 8 的硬门槛。

**Architecture:** 新代码全部位于 `scripts/simulation/`，唯一既有运行配置变更是在 `project.godot` 显式固定当前默认的 60 Hz 物理频率。`LocalInputCollector` 把既有设备输入快照量化为固定四槽位命令，`LocalFrameInputBuffer` 按 Tick 保存完整帧，`LocalFrameSyncDriver` 在 60 Hz Godot 物理回调中严格每两次推进一次 30 Hz `SimulationWorld`。世界只保存整数状态、稳定实体引用和显式排序后的事件；`InputTape` 与规范状态均使用显式 little-endian 字节编码，双世界 harness 分别走直接命令路径和编码/解码路径并逐 Tick 比较 SHA-256。

**Tech Stack:** Godot 4.7.1、GDScript、`PackedByteArray`、`PackedInt32Array`、`HashingContext.HASH_SHA256`、现有 `PlayerInputSource` / `PlayerInputState`、headless Godot 验证脚本。

## Global Constraints

- 唯一设计规格为 `docs/superpowers/specs/2026-08-08-local-deterministic-frame-sync-design.md`。本计划只实现该 SPEC 的 Plan 1；若本文与 SPEC 有任何冲突，以 SPEC 为准，并先修订本文再继续实施。
- 除在 `project.godot` 的现有 `[physics]` 段显式增加 `common/physics_ticks_per_second=60` 外，本计划只创建下方“文件结构与稳定边界”列出的 GDScript 与验证脚本；不修改现有 `DemoArena`、`PlayerController`、输入源、场景或资源文件。
- 不接入摄像机、Godot Physics、Jolt、`NavigationAgent3D`、`NavigationServer3D`、运行时 NavMesh、场景节点玩法判定、WS、ENet、WebRTC、RPC 或其他网络传输。
- `SimulationWorld` 不继承 `Node`、不引用场景节点、不接收 `delta`、不读取浮点输入、`RandomNumberGenerator`、全局随机数或 `Dictionary` 迭代顺序。
- 模拟频率固定为 30 Hz；`project.godot` 必须显式声明 Godot 物理频率为 60 Hz，该值与修改前的引擎默认行为相同；驱动器每两个物理回调至多执行一个连续模拟 Tick，性能不足或输入缺失时不得跳 Tick。
- 玩家槽位固定为 `0..3`；有效掩码只能是连续低位的 `0b0001`、`0b0011`、`0b0111`、`0b1111`；未启用槽位命令始终为全零。
- `PlayerFrameCommand` 字段固定为 `move_heading: 0..16`、`action_bits: USE_HELD|USE_PRESSED|CONFIRM`、`equipment_delta: -1|0|1`、`placement_heading: 0..16`；不得增加设备、`Vector2`、摄像机或装备索引字段。
- 同一 Tick 同时检测到“上一件”和“下一件”时，必须规范化为 `equipment_delta = 0`；不得选择上一件优先或下一件优先，装备切换也不得重复写入 `action_bits`。
- 单帧命令编码固定为 22 bytes：`schema:u8 + tick:u32-le + active_player_mask:u8 + 4 * (move_heading:u8 + action_bits:u8 + equipment_delta:i8 + placement_heading:u8)`。
- 所有多字节整数均使用 little-endian；坐标、Tick、ID、计数、随机状态和 Hash 输入均使用显式字节写入；不得使用 Variant、Dictionary 或 JSON 序列化作为确定性数据格式。
- 数值规则只使用整数和 `FixedMath`；中间乘法使用 GDScript `int` 的 int64 语义；不得依赖溢出、`sin`、`cos`、`atan2`、`sqrt`、浮点归一化或负数 `%` 的实现细节。`FixedMath.floor_div()` 是模拟层唯一允许直接使用 GDScript `int / int` 截断语义的底层原语；其他模拟代码进行整数除法时必须调用 `FixedMath.floor_div()`，不得直接写 `/`。
- 1 Godot 世界单位等于 1024 个模拟单位；方向表索引 0 为静止，1～16 为预烘焙十六方向。
- PRNG 固定为 Park–Miller：乘数 `48271`、模数 `2147483647`、状态 `1..2147483646`；范围采样使用 rejection sampling。
- 实体引用为正数 `entity_id` 加正数 `generation`；命令和事件遍历按显式稳定键排序；不得使用 `NodePath`、RID 或 instance ID。
- 战斗中已绑定设备离线时，collector 返回失败，driver 暂停模拟 Tick；不得提交中性输入、推进冷却或允许其他设备接管。相同 source key 恢复后才能采样下一 Tick。
- 正常本地运行可每 30 Tick 计算一次诊断 Hash；本计划的所有自动确定性验证必须每 Tick 计算 Hash。
- 所有行为先写失败验证、运行并确认因缺少对应实现或断言不满足而失败，再写最小实现并运行通过。
- 连续 100,000 Tick 直接命令世界与编码/解码命令世界只要首次分歧或进程退出码非 0，就立即停止 Plan 2 至 Plan 8，保留旧 `DemoArena` 默认路径并输出首分歧诊断。
- 执行前必须询问用户是否使用 worktree，默认不使用；只有用户同意才按 `using-git-worktrees` 建立隔离目录。
- 本计划实施期间 agent 不进行暂存、提交或任何历史改写，也不压缩提交。全部 Task 验收完成后由用户自行提交整个 Plan 的改动。

---

## 文件结构与稳定边界

| 路径 | 职责 |
| --- | --- |
| `project.godot` | 在现有 `[physics]` 段显式声明 `common/physics_ticks_per_second=60`，冻结当前默认频率，不改变 Jolt 或物理插值配置。 |
| `scripts/simulation/core/little_endian.gd` | 有界 little-endian 读写器，集中处理 u8/i8/u16/u32/i32 与固定字节段。 |
| `scripts/simulation/core/fixed_math.gd` | floor 除法、欧几里得取模、十六方向整数表和距离平方。 |
| `scripts/simulation/core/park_miller_rng.gd` | 独立、可快照的 Park–Miller 随机流。 |
| `scripts/simulation/core/entity_id_allocator.gd` | 正 ID、generation 和固定容量复用规则。 |
| `scripts/simulation/events/sim_event.gd` | 不引用表现节点的整数事件记录，并由 Tick、来源和本地序号派生稳定 event_id。 |
| `scripts/simulation/events/sim_event_order.gd` | 按阶段、来源、本地序号、目标和类型的稳定比较器。 |
| `scripts/simulation/commands/player_frame_command.gd` | 单玩家四字节命令、复制、相等比较与字段验证。 |
| `scripts/simulation/commands/local_frame_command_set.gd` | Tick、连续掩码和固定四槽位命令集合。 |
| `scripts/simulation/commands/local_frame_command_codec.gd` | 22 bytes 单帧命令的严格编码、解码与拒绝规则。 |
| `scripts/simulation/session/simulation_manifest.gd` | 规则版本、地图 ID、配置 Hash 和稳定清单字节格式。 |
| `scripts/simulation/session/local_simulation_session.gd` | 本局种子、连续玩家掩码、四槽输入源绑定和固定 input delay 0。 |
| `scripts/simulation/input/local_input_collector.gd` | 以槽位升序采样既有输入源，并量化为帧命令。 |
| `scripts/simulation/input/local_frame_input_buffer.gd` | 按 Tick 保存命令字节副本、拒绝冲突、只放行完整帧。 |
| `scripts/simulation/replay/input_tape.gd` | 带 manifest、种子与 active mask 的定长帧录像读写。 |
| `scripts/simulation/world/simulation_world.gd` | 最小纯数据世界、稳定命令消费、事件排序，以及按 SPEC 固定大类顺序分段写入的规范状态编码。 |
| `scripts/simulation/replay/state_hasher.gd` | 对规范状态计算、比较和格式化 SHA-256。 |
| `scripts/simulation/driver/local_frame_sync_driver.gd` | 60 Hz 到 30 Hz 的整数二分频推进，不向模拟传递 delta。 |
| `scripts/simulation/testing/first_divergence_harness.gd` | 双世界直接/codec 回放、首分歧定位和立即停止。 |
| `scripts/simulation/testing/determinism_test_runner.gd` | 为 1、2、3、4 人固定输入带执行 100,000 Tick 门槛。 |
| `tools/validation/validate_simulation_core_primitives.gd` | 字节、FixedMath、PRNG、实体 ID 和事件顺序聚焦验证。 |
| `tools/validation/validate_local_frame_commands.gd` | 命令、session、22 bytes codec、InputTape、collector 和 buffer 聚焦验证。 |
| `tools/validation/validate_local_frame_sync_core.gd` | 最小世界、规范状态、Hash、driver 和首分歧 harness 集成验证。 |

### Task 1: 里程碑一——确定性字节、整数数学、随机流、实体引用与事件顺序

**Files:**
- Create: `scripts/simulation/core/little_endian.gd`
- Create: `scripts/simulation/core/fixed_math.gd`
- Create: `scripts/simulation/core/park_miller_rng.gd`
- Create: `scripts/simulation/core/entity_id_allocator.gd`
- Create: `scripts/simulation/events/sim_event.gd`
- Create: `scripts/simulation/events/sim_event_order.gd`
- Create: `tools/validation/validate_simulation_core_primitives.gd`

**Interfaces:**
- Consumes: Godot `PackedByteArray`、`PackedInt32Array` 和 GDScript `int`。
- Produces: `LittleEndianWriter.write_u8(value: int) -> void`、`write_i8(value: int) -> void`、`write_u16(value: int) -> void`、`write_u32(value: int) -> void`、`write_i32(value: int) -> void`、`write_bytes(value: PackedByteArray) -> void`、`to_bytes() -> PackedByteArray`、`has_error() -> bool`、`get_error_message() -> String`。
- Produces: `LittleEndianReader.new(bytes: PackedByteArray)`、`read_u8() -> int`、`read_i8() -> int`、`read_u16() -> int`、`read_u32() -> int`、`read_i32() -> int`、`read_bytes(count: int) -> PackedByteArray`、`is_at_end() -> bool`、`has_error() -> bool`、`get_error_message() -> String`。
- Produces: `FixedMath.floor_div(dividend: int, divisor: int) -> int`、`euclidean_mod(dividend: int, divisor: int) -> int`、`heading_x(heading: int) -> int`、`heading_z(heading: int) -> int`、`distance_squared(ax: int, az: int, bx: int, bz: int) -> int`。
- Produces: `ParkMillerRng.new(seed: int)`、`is_valid() -> bool`、`next_u31() -> int`、`next_inclusive(minimum: int, maximum: int) -> int`、`get_state() -> int`、`set_state(state: int) -> bool`、`encode_state(writer: LittleEndianWriter) -> void`。
- Produces: `EntityIdAllocator.new(capacity: int)`、`allocate() -> Dictionary`、`release(entity_id: int, generation: int) -> bool`、`is_alive(entity_id: int, generation: int) -> bool`、`encode_canonical(writer: LittleEndianWriter) -> void`。
- Produces: `SimEvent.new(tick: int, phase: int, source_id: int, local_sequence: int, target_id: int, event_type: int, value: int)`，公开只读整数 `event_id`，其值固定为 `(tick << 24) | (source_id << 8) | local_sequence`；`SimEventOrder.less_than(left: SimEvent, right: SimEvent) -> bool`、`sort(events: Array[SimEvent]) -> void`。

#### 里程碑 1A：先锁定 little-endian 字节契约

- [ ] **Step 1: 写 little-endian 失败验证**

创建 `validate_simulation_core_primitives.gd`，预加载尚不存在的 reader/writer，写入固定值并断言精确字节：

```gdscript
var writer := LittleEndianWriter.new()
writer.write_u8(0x7f)
writer.write_i8(-1)
writer.write_u16(0x3412)
writer.write_u32(0x78563412)
writer.write_i32(-2)
_expect(
	writer.to_bytes() == PackedByteArray([
		0x7f, 0xff, 0x12, 0x34, 0x12, 0x34, 0x56, 0x78,
		0xfe, 0xff, 0xff, 0xff,
	]),
	"little-endian bytes must be canonical",
	failures
)
```

- [ ] **Step 2: 运行失败验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
```

Expected: 非零退出，预加载 `res://scripts/simulation/core/little_endian.gd` 失败；不得跳过断言。

- [ ] **Step 3: 实现有界 reader/writer**

writer 对越界值设置首个 `error_message` 且不追加字节；reader 在剩余长度不足时设置错误并返回 `0` 或空字节段。u32 的规范实现为：

```gdscript
func write_u32(value: int) -> void:
	if value < 0 or value > 0xffffffff:
		_fail("u32 out of range")
		return
	_bytes.append(value & 0xff)
	_bytes.append((value >> 8) & 0xff)
	_bytes.append((value >> 16) & 0xff)
	_bytes.append((value >> 24) & 0xff)

func read_u32() -> int:
	if not _require(4):
		return 0
	var value := _bytes[_offset]
	value |= _bytes[_offset + 1] << 8
	value |= _bytes[_offset + 2] << 16
	value |= _bytes[_offset + 3] << 24
	_offset += 4
	return value
```

- [ ] **Step 4: 补全 signed 与越界验证并运行通过**

补充 `read_i8(0xff) == -1`、`read_i32(0xfffffffe) == -2`、末尾额外读取设置错误、writer 越界不改变既有 bytes 的断言。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
```

Expected: `validate_simulation_core_primitives: PASS`，退出码 0。

#### 里程碑 1B：锁定 FixedMath 与 Park–Miller 金样

- [ ] **Step 5: 写数学、方向表和 PRNG 失败断言**

方向约定固定为：0 静止、1 正 X、5 正 Z、9 负 X、13 负 Z，其余方向由长度 17 的预烘焙对称整数表给出：

```gdscript
var positive_quotient := FixedMath.floor_div(7, 3)
var negative_quotient := FixedMath.floor_div(-7, 3)
_expect(positive_quotient == 2, "positive floor_div must return 2", failures)
_expect(negative_quotient == -3, "negative floor_div must round down to -3", failures)
_expect(FixedMath.floor_div(-6, 3) == -2, "exact negative division must stay exact", failures)
_expect(typeof(positive_quotient) == TYPE_INT, "floor_div return type must be int", failures)
_expect(FixedMath.floor_div(-1, 16) == -1, "floor_div must round down", failures)
_expect(FixedMath.euclidean_mod(-1, 16) == 15, "mod must be non-negative", failures)
_expect(FixedMath.heading_x(1) == 1024 and FixedMath.heading_z(1) == 0, "heading 1 must be +X", failures)
var rng := ParkMillerRng.new(1)
_expect(rng.next_u31() == 48271, "Park-Miller first value must be stable", failures)
_expect(rng.next_u31() == 182605794, "Park-Miller second value must be stable", failures)
```

- [ ] **Step 6: 运行验证，确认接口缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
```

Expected: 非零退出，错误明确指向 `FixedMath` 或 `ParkMillerRng` 尚不存在。

- [ ] **Step 7: 实现 FixedMath**

不得调用浮点三角函数；方向表必须直接写成以下两个长度 17 的常量数组，索引 0 是静止，其余索引从正 X 朝正 Z 每次旋转 22.5 度：

```gdscript
const HEADING_X := PackedInt32Array([
	0,
	1024, 946, 724, 392,
	0, -392, -724, -946,
	-1024, -946, -724, -392,
	0, 392, 724, 946,
])
const HEADING_Z := PackedInt32Array([
	0,
	0, 392, 724, 946,
	1024, 946, 724, 392,
	0, -392, -724, -946,
	-1024, -946, -724, -392,
])
```

除法、取模和距离固定为：

```gdscript
static func floor_div(dividend: int, divisor: int) -> int:
	assert(divisor > 0)
	var quotient: int = dividend / divisor
	var remainder := dividend % divisor
	if remainder != 0 and dividend < 0:
		quotient -= 1
	return quotient

static func euclidean_mod(dividend: int, divisor: int) -> int:
	return dividend - floor_div(dividend, divisor) * divisor

static func distance_squared(ax: int, az: int, bx: int, bz: int) -> int:
	var dx := ax - bx
	var dz := az - bz
	return dx * dx + dz * dz
```

这里明确且仅在这一处依赖 GDScript 的 `int / int` 先向零截断：当负被除数存在非零余数时再减 1，得到数学 floor。验证必须覆盖正数、负数、负数整除和 `TYPE_INT` 返回类型。除本函数外，`scripts/simulation/` 中任何玩法或确定性算法都不得直接用 `/` 做整数除法；后续范围审查必须检查这一约束。

- [ ] **Step 8: 实现 Park–Miller 与 rejection sampling**

无效种子使 `is_valid()` 为 false，`set_state()` 拒绝范围外值；随机推进不得依赖溢出：

```gdscript
func next_u31() -> int:
	assert(is_valid())
	_state = (_state * 48271) % 2147483647
	return _state

func next_inclusive(minimum: int, maximum: int) -> int:
	assert(minimum <= maximum)
	var span := maximum - minimum + 1
	assert(span >= 1 and span <= 2147483646)
	var limit := 2147483646 - (2147483646 % span)
	while true:
		var sample := next_u31() - 1
		if sample < limit:
			return minimum + (sample % span)
```

- [ ] **Step 9: 运行方向、状态快照和范围验证**

遍历 heading `0..16`，断言索引 0 是唯一零向量且方向表对称；验证 `next_inclusive(7, 7) == 7`；把推进三次后的 state 通过 little-endian 编码并恢复到第二个流，断言两个流后续 32 个值一致。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
```

Expected: `validate_simulation_core_primitives: PASS`，退出码 0。

#### 里程碑 1C：锁定实体复用和事件 tie-break

- [ ] **Step 10: 写实体 ID 与事件顺序失败验证**

```gdscript
var allocator := EntityIdAllocator.new(2)
var first := allocator.allocate()
_expect(first.entity_id == 1 and first.generation == 1, "first reference must be positive", failures)
_expect(allocator.release(1, 1), "current reference must release", failures)
var reused := allocator.allocate()
_expect(reused.entity_id == 1 and reused.generation == 2, "reuse must advance generation", failures)
_expect(not allocator.is_alive(1, 1), "stale generation must be invalid", failures)
```

另以逆序事件输入断言排序键依次为 `phase`、`source_id`、`local_sequence`、`target_id`、`event_type`。

- [ ] **Step 11: 运行验证，确认实体和事件类缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
```

Expected: 非零退出，缺失 `EntityIdAllocator`、`SimEvent` 或 `SimEventOrder`。

- [ ] **Step 12: 实现固定容量实体分配器**

预分配 `PackedByteArray` alive 和 `PackedInt32Array` generation，始终扫描并复用最小空闲 ID；容量耗尽返回空 Dictionary；release 只接受当前存活 generation；generation 达到 `2147483647` 后该槽位不得回绕复用：

```gdscript
func allocate() -> Dictionary:
	for entity_id in range(1, _capacity + 1):
		if _alive[entity_id] == 0 and _generation[entity_id] < 2147483647:
			_generation[entity_id] += 1
			_alive[entity_id] = 1
			return {"entity_id": entity_id, "generation": _generation[entity_id]}
	return {}
```

`encode_canonical()` 按 ID 升序写 capacity、alive 和 generation，不序列化 Dictionary。

- [ ] **Step 13: 实现整数事件与显式稳定排序**

```gdscript
static func less_than(left: SimEvent, right: SimEvent) -> bool:
	if left.phase != right.phase: return left.phase < right.phase
	if left.source_id != right.source_id: return left.source_id < right.source_id
	if left.local_sequence != right.local_sequence: return left.local_sequence < right.local_sequence
	if left.target_id != right.target_id: return left.target_id < right.target_id
	return left.event_type < right.event_type
```

`sort()` 使用插入排序并只调用该比较器，不依赖运行时排序稳定性。

构造事件时要求 `tick: 0..0xffffffff`、`source_id: 1..65535`、`local_sequence: 0..255`，从而保证稳定 `event_id` 在 GDScript signed int64 正数范围内。同一 `(tick, source_id)` 的 `local_sequence` 必须跨 phase 单调递增且不得重复；`event_id` 只由这三个字段派生，不使用对象地址、实例 ID 或容器位置。

- [ ] **Step 14: 完成本 Task 验收**

验证 capacity 2 的第三次同时存活分配为空；相同 allocate/release 序列产生完全相同 canonical bytes；正序和逆序事件排序后逐字段相同。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两条命令均退出 0。Task 1 可独立验收；不提交。

### Task 2: 里程碑二——固定帧命令、会话、输入采集、帧缓冲与 InputTape

**Files:**
- Create: `scripts/simulation/commands/player_frame_command.gd`
- Create: `scripts/simulation/commands/local_frame_command_set.gd`
- Create: `scripts/simulation/commands/local_frame_command_codec.gd`
- Create: `scripts/simulation/session/simulation_manifest.gd`
- Create: `scripts/simulation/session/local_simulation_session.gd`
- Create: `scripts/simulation/input/local_input_collector.gd`
- Create: `scripts/simulation/input/local_frame_input_buffer.gd`
- Create: `scripts/simulation/replay/input_tape.gd`
- Create: `tools/validation/validate_local_frame_commands.gd`

**Interfaces:**
- Consumes: `LittleEndianWriter`、`LittleEndianReader`、`FixedMath`、现有 `res://scripts/input/player_input_source.gd` 的 `sample() -> PlayerInputState`、`is_online() -> bool`、`get_source_key() -> StringName`，以及现有 `PlayerInputState` 六个字段。
- Produces: `PlayerFrameCommand.new(move_heading := 0, action_bits := 0, equipment_delta := 0, placement_heading := 0)`、`is_valid() -> bool`、`is_neutral() -> bool`、`copy() -> PlayerFrameCommand`、`equals(other: PlayerFrameCommand) -> bool`、`neutral() -> PlayerFrameCommand`。
- Produces: `LocalFrameCommandSet.new(tick: int, active_player_mask: int, player_commands: Array[PlayerFrameCommand])`、`is_valid() -> bool`、`copy() -> LocalFrameCommandSet`、`equals(other: LocalFrameCommandSet) -> bool`、`is_contiguous_active_mask(mask: int) -> bool`。
- Produces: `LocalFrameCommandCodec.encode(frame: LocalFrameCommandSet) -> PackedByteArray`、严格 `decode(bytes: PackedByteArray) -> LocalFrameCommandSet`、运行时 `decode_runtime(bytes: PackedByteArray) -> LocalFrameCommandSet`、`get_error_message() -> String`、`get_diagnostics() -> PackedStringArray`。
- Produces: `SimulationManifest.new(schema_version: int, rules_version: int, map_id: StringName, config_hash: PackedByteArray)`、`is_valid() -> bool`、`encode() -> PackedByteArray`、静态 `decode(bytes: PackedByteArray) -> SimulationManifest`、`copy() -> SimulationManifest`、`equals(other: SimulationManifest) -> bool`。
- Produces: `LocalSimulationSession.new(manifest: SimulationManifest, session_seed: int, active_player_mask: int, slot_source_keys: Array[StringName], input_heading_offset: int = 0)`、`is_valid() -> bool`、`copy() -> LocalSimulationSession`、`get_manifest() -> SimulationManifest`、`get_session_seed() -> int`、`get_simulation_ticks_per_second() -> int`、`get_input_delay_ticks() -> int`、`get_active_player_mask() -> int`、`get_slot_source_key(slot: int) -> StringName`、`get_input_heading_offset() -> int`、`equals(other: LocalSimulationSession) -> bool`、`is_replay_compatible(other: LocalSimulationSession) -> bool`。
- Produces: `LocalInputCollector.new(session: LocalSimulationSession, sources: Array)`、`collect(tick: int) -> LocalFrameCommandSet`、`quantize_move_heading(move_vector: Vector2) -> int`、`get_error_message() -> String`。
- Produces: `LocalFrameInputBuffer.new(max_pending_frames := 256)`、`submit(frame: LocalFrameCommandSet) -> bool`、`has_complete_frame(tick: int) -> bool`、`take(tick: int) -> LocalFrameCommandSet`、`get_error_message() -> String`。
- Produces: `InputTape.new(session: LocalSimulationSession)`、`append(frame: LocalFrameCommandSet) -> bool`、`encode() -> PackedByteArray`、`decode(bytes: PackedByteArray) -> bool`、`get_session() -> LocalSimulationSession`、`get_frame(tick: int) -> LocalFrameCommandSet`、`get_frame_count() -> int`、`get_error_message() -> String`。

#### 里程碑 2A：固定 22 bytes 帧命令

- [ ] **Step 1: 写命令范围、mask 和字节布局失败验证**

建立 mask `0b0011`、tick `0x78563412` 的合法帧，断言长度和头六字节；同时拒绝 mask 0、`0b0101`、16，越界 heading、未知 action bit、`equipment_delta = 2` 和未启用槽位非零：

```gdscript
_expect(LocalFrameCommandSet.is_contiguous_active_mask(0b0001), "one-player mask must pass", failures)
_expect(LocalFrameCommandSet.is_contiguous_active_mask(0b1111), "four-player mask must pass", failures)
_expect(not LocalFrameCommandSet.is_contiguous_active_mask(0b0101), "sparse mask must fail", failures)
_expect(encoded.size() == 22, "frame size must be exactly 22 bytes", failures)
_expect(encoded.slice(0, 6) == PackedByteArray([1, 0x12, 0x34, 0x56, 0x78, 3]), "header bytes must match", failures)
```

- [ ] **Step 2: 运行失败验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
```

Expected: 非零退出，命令脚本尚不存在。

- [ ] **Step 3: 实现命令对象与固定四槽帧**

```gdscript
const USE_HELD := 1 << 0
const USE_PRESSED := 1 << 1
const CONFIRM := 1 << 2
const ACTION_MASK := USE_HELD | USE_PRESSED | CONFIRM

func is_valid() -> bool:
	return move_heading >= 0 and move_heading <= 16 \
		and placement_heading >= 0 and placement_heading <= 16 \
		and (action_bits & ~ACTION_MASK) == 0 \
		and equipment_delta >= -1 and equipment_delta <= 1
```

`LocalFrameCommandSet` 必须恰有四个非 null 命令；`is_contiguous_active_mask()` 只接受 1、3、7、15；所有未启用槽位必须 `is_neutral()`。

- [ ] **Step 4: 实现唯一 codec**

编码前调用 `frame.is_valid()`；严格解码要求长度恰为 22、schema 恰为 1，读完后再次用同一验证器检查：

```gdscript
writer.write_u8(SCHEMA_VERSION)
writer.write_u32(frame.tick)
writer.write_u8(frame.active_player_mask)
for command in frame.player_commands:
	writer.write_u8(command.move_heading)
	writer.write_u8(command.action_bits)
	writer.write_i8(command.equipment_delta)
	writer.write_u8(command.placement_heading)
return writer.to_bytes()
```

`decode_runtime()` 与严格 decode 共用同一结构读取器：魔数/schema、长度、tick、mask、未启用槽非零等结构错误仍返回 null；仅当启用槽的 command 字段越界时，把该槽替换为 neutral 并追加确定性诊断文本。测试、InputTape 和 determinism harness 一律调用严格 `decode()`；运行时接缝才允许调用 `decode_runtime()`，满足 SPEC 的“运行时中性化、测试环境直接失败”。诊断文本不进入模拟状态或 Hash。

- [ ] **Step 5: 运行往返与破损拒绝验证**

逐字段比较 decode 结果；分别截断一字节、附加一字节、修改 schema、写入稀疏 mask、污染未启用槽位，断言严格 `decode() == null` 且 error 非空。再把一个启用槽 heading 改为 17：严格 decode 必须失败，`decode_runtime()` 必须返回该槽 neutral、其他槽不变且 diagnostics 非空。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
```

Expected: `validate_local_frame_commands: PASS`，退出码 0。

#### 里程碑 2B：固定 manifest、session 与 InputTape

- [ ] **Step 6: 写 manifest/session/tape 失败验证**

使用 32 bytes 配置 Hash、`rules_version = 3`、`map_id = &"core_spike"`、seed 12345、mask `0b0011`、固定输入 heading offset 0。向 tape 追加 tick 0、1，编码并恢复；断言 session 模拟频率为 30、input delay 为 0、frame count 为 2、恢复后字节完全相同。另断言 31 bytes Hash、空 map、无效 seed、启用槽无 source key、未启用槽有 source key、heading offset 不在 `0..15`、从 tick 2 开始或跳过 tick 都失败。

```gdscript
_expect(session.get_input_delay_ticks() == 0, "local input delay must remain zero", failures)
_expect(session.get_simulation_ticks_per_second() == 30, "simulation rate must remain 30 Hz", failures)
_expect(tape.get_frame_count() == 2, "tape must preserve frame count", failures)
_expect(restored.get_frame(1).tick == 1, "tape must restore exact tick", failures)
```

- [ ] **Step 7: 运行验证，确认 session/replay 接口缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
```

Expected: 非零退出，预加载 session 或 replay 脚本失败。

- [ ] **Step 8: 实现 manifest 与不可变 session**

manifest 只接受 schema 1、正数 rules version、UTF-8 长度 1..64 的非空 map ID、恰好 32 bytes config hash。其二进制格式固定为：`"SMAN" + schema:u8 + rules_version:u32-le + map_id_length:u8 + map_id_utf8 + config_hash:32 bytes`。decode 必须消费完整输入，不接受尾随字节。

session 只接受有效 manifest、Park–Miller 有效 seed、连续 active mask、长度恰为 4 的 source key 数组和 `0..15` 的 `input_heading_offset`；启用槽 key 非空、未启用槽 key 为空。`input_heading_offset` 是本局固定镜头朝向配置在十六方向环上的离散偏移，只供 collector 把设备方向转成世界 heading；不得读取正在平滑、震动或随宽高比变化的 Camera3D Basis。构造后复制 manifest bytes、hash 和 key 数组，getter 不暴露可变内部对象。`equals()` 比较包括 source keys 的全部本地会话字段；`is_replay_compatible()` 只比较 manifest、seed、active mask、30 Hz、input delay 0 和 heading offset，不比较只用于现场设备采样的 source keys。

```gdscript
func get_simulation_ticks_per_second() -> int:
	return 30

func get_input_delay_ticks() -> int:
	return 0
```

- [ ] **Step 9: 实现定长 InputTape**

格式固定为：`"ITAP" + tape_schema:u8=1 + manifest_length:u16-le + manifest_bytes + session_seed:u32-le + active_mask:u8 + input_heading_offset:u8 + frame_count:u32-le + frame_count * 22 bytes`。source keys 属于现场设备绑定，不写入录像。`InputTape.new(session)` 保存一份预期 session；`decode()` 必须按 header 字段检查 `is_replay_compatible()`，任何 rules version、map ID、config hash、seed、mask 或 heading offset 不匹配都拒绝回放，且不得用 tape 内容悄悄替换预期 session。`append()` 仅接受从 tick 0 开始连续增长、与 session mask 相同的合法帧：

```gdscript
func append(frame: LocalFrameCommandSet) -> bool:
	if frame == null or not frame.is_valid():
		return _fail("invalid frame")
	if frame.active_player_mask != _session.get_active_player_mask():
		return _fail("active mask mismatch")
	if frame.tick != _frames.size():
		return _fail("non-contiguous tick")
	_frames.append(frame.copy())
	return true
```

decode 必须验证魔数、schema、manifest、session 字段、总长度和每个 22 bytes frame；配置 Hash 的任一字节变化都必须导致预期 session 校验失败。

- [ ] **Step 10: 运行 manifest/session/tape 验收**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
```

Expected: `validate_local_frame_commands: PASS`，退出码 0。

#### 里程碑 2C：采集现有输入并只放行完整帧

- [ ] **Step 11: 写 collector/buffer 失败验证**

在测试脚本内定义不读取全局 `Input` 的 `FixedInputSource extends PlayerInputSource`。以 slot 0 的 `Vector2(1, 0)`、slot 1 的 `Vector2(0, -1)` 构造 mask `0b0011` session，断言 heading 为 1 和 5，三个动作字段只映射到三个声明 bit，slot 2/3 全零。同一 Tick 同时设置 previous/next 时必须断言 `equipment_delta == 0`：

```gdscript
_expect(frame.player_commands[0].move_heading == 1, "collector must quantize +X", failures)
_expect(frame.player_commands[1].move_heading == 5, "collector must quantize +Z", failures)
_expect(frame.player_commands[0].equipment_delta == 0, "opposite equipment edges must cancel", failures)
_expect(buffer.submit(frame), "first submission must pass", failures)
_expect(not buffer.submit(conflicting_frame), "same-tick conflict must fail", failures)
```

- [ ] **Step 12: 运行验证，确认 collector/buffer 缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
```

Expected: 非零退出，`LocalInputCollector` 或 `LocalFrameInputBuffer` 尚不存在。

- [ ] **Step 13: 实现固定采样顺序、量化和装备边沿规范化**

collector 构造时要求 sources 长度为 4。每 Tick 按 slot 0..3 升序；启用槽必须 source 非 null、`is_online()` 为 true 且 `get_source_key()` 等于 session 绑定 key，否则 `collect()` 返回 null 并记录错误；未启用槽不采样并写 neutral。

输入向量仅在 collector 边界转换：固定使用 `input_x = round(move_vector.x * 32767.0)`、`input_z = -round(move_vector.y * 32767.0)`，从而现有输入的“上”映射到正 Z；再与 `FixedMath` 的 `(heading_x, heading_z)` 做整数点积，最大点积相同时取较小本地方向，`input_x == 0 and input_z == 0` 时返回 0。非零本地方向再按 `world_heading = 1 + FixedMath.euclidean_mod((local_heading - 1) + session.get_input_heading_offset(), 16)` 旋转为本局固定世界 heading。`placement_heading` 在 Plan 1 固定为 0。

```gdscript
func _to_command(state: PlayerInputState) -> PlayerFrameCommand:
	var bits := 0
	if state.use_pressed: bits |= PlayerFrameCommand.USE_HELD
	if state.use_just_pressed: bits |= PlayerFrameCommand.USE_PRESSED
	if state.confirm_just_pressed: bits |= PlayerFrameCommand.CONFIRM
	var delta := 0
	if state.previous_equipment_just_pressed != state.next_equipment_just_pressed:
		delta = -1 if state.previous_equipment_just_pressed else 1
	return PlayerFrameCommand.new(quantize_move_heading(state.move_vector), bits, delta, 0)
```

此异或语义保证 previous+next 同 Tick 为 0，并保证装备切换不进入 `action_bits`。

- [ ] **Step 14: 实现按 Tick 的完整帧缓冲**

buffer 只用 Dictionary 做 tick 精确查询，不遍历其顺序。`submit()` 先 codec 编码再保存 bytes 副本；相同 tick 的相同 bytes 可幂等接受，不同 bytes 必须拒绝。拒绝已消费 tick、非法帧和超过 `max_pending_frames` 的窗口。

```gdscript
func take(tick: int) -> LocalFrameCommandSet:
	if not has_complete_frame(tick):
		return null
	var bytes: PackedByteArray = _frame_bytes[tick]
	_frame_bytes.erase(tick)
	_last_consumed_tick = tick
	return LocalFrameCommandCodec.decode(bytes)
```

`take(1)` 不得隐式消费缺失的 tick 0；driver 只请求 world 的 `next_tick`。

- [ ] **Step 15: 完成本 Task 验收**

验证空输入 heading 0；仅 previous 为 -1；仅 next 为 1；previous+next 为 0；source 离线或 key 不匹配使 collect 返回 null；buffer 缺帧、冲突帧、旧 tick、窗口超界均不推进消费位置。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两条命令均退出 0。Task 2 可独立验收；不提交。

### Task 3: 里程碑三——最小纯数据世界、规范状态、SHA-256 与 60/30 Hz 驱动

**Files:**
- Modify: `project.godot:76-80` 的 `[physics]` 段
- Create: `scripts/simulation/world/simulation_world.gd`
- Create: `scripts/simulation/replay/state_hasher.gd`
- Create: `scripts/simulation/driver/local_frame_sync_driver.gd`
- Create: `tools/validation/validate_local_frame_sync_core.gd`

**Interfaces:**
- Consumes: `LocalSimulationSession`、`LocalFrameCommandSet`、`LocalInputCollector`、`LocalFrameInputBuffer`、`EntityIdAllocator`、`ParkMillerRng`、`SimEvent`、`SimEventOrder`、`LittleEndianWriter`。
- Produces: `SimulationWorld.new(session: LocalSimulationSession)`、`step(tick: int, frame: LocalFrameCommandSet) -> bool`、`get_next_tick() -> int`、`encode_canonical_state() -> PackedByteArray`、`get_last_events() -> Array[SimEvent]`、`get_last_error() -> String`。
- Freezes canonical extension points: `_encode_world_header(writer)`、`_encode_player_section(writer)`、`_encode_zombie_section(writer)`、`_encode_other_entity_section(writer)`、`_encode_dynamic_map_section(writer)`、`_encode_prng_section(writer)`、`_encode_wave_section(writer)`、`_encode_pending_event_section(writer)`；Plan 2～6 只能实现对应 section，禁止在编码末尾追加会改变 SPEC 大类顺序的私有段。
- Produces: `StateHasher.hash_canonical(bytes: PackedByteArray) -> PackedByteArray`、`equal(left: PackedByteArray, right: PackedByteArray) -> bool`、`to_hex(value: PackedByteArray) -> String`。
- Produces: `LocalFrameSyncDriver.new(world: SimulationWorld, collector: LocalInputCollector, buffer: LocalFrameInputBuffer)`、`advance_physics_callback() -> bool`、`set_diagnostic_hash_interval(interval_ticks: int) -> bool`、`get_diagnostic_hash_interval() -> int`、`get_physics_callback_count() -> int`、`get_simulation_step_count() -> int`、`get_last_error() -> String`；信号 `simulation_advanced(tick: int, diagnostic_hash: PackedByteArray)`，默认每 30 Tick 才携带 32-byte Hash，其余 Tick 携带空数组，测试/资格模式显式设为 1。

#### 里程碑 3A：最小世界和规范 Hash

- [ ] **Step 1: 写世界顺序、错误原子性和 Hash 失败验证**

创建相同 session 的两个世界，断言只接受 tick 0 开始的连续帧；跳 tick、mask 不符、无效 frame 都返回 false 且 `get_next_tick()` 和 canonical bytes 不变；相同输入得到相同 32 bytes Hash；不同合法命令改变 canonical bytes。

```gdscript
_expect(world.step(0, frame_0), "world must accept first complete frame", failures)
var state_after_tick_0 := world.encode_canonical_state()
_expect(not world.step(2, frame_1), "world must reject skipped tick", failures)
_expect(world.encode_canonical_state() == state_after_tick_0, "rejected step must be atomic", failures)
_expect(StateHasher.hash_canonical(state_after_tick_0).size() == 32, "SHA-256 must be 32 bytes", failures)
```

- [ ] **Step 2: 运行失败验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
```

Expected: 非零退出，缺少 `SimulationWorld` 或 `StateHasher`。

- [ ] **Step 3: 实现最小纯数据世界推进**

world 构造时复制 session，以一个只在初始化期间使用的 Park–Miller seeder 连续取四个状态，分别创建互不共享状态的 world、wave、drop、entity RNG；再创建固定容量 256 的 allocator、`next_tick = 0`、四份 neutral 命令和空事件数组。四条随机流即使尚未被玩法消费也必须进入 canonical state。`step()` 先完整验证，不得在失败路径修改任何字段；成功后按 slot 升序复制四个命令，为每个非零 action_bits 生成测试事件，显式排序后 `next_tick += 1`。

```gdscript
var seeder := ParkMillerRng.new(_session.get_session_seed())
_world_rng = ParkMillerRng.new(seeder.next_u31())
_wave_rng = ParkMillerRng.new(seeder.next_u31())
_drop_rng = ParkMillerRng.new(seeder.next_u31())
_entity_rng = ParkMillerRng.new(seeder.next_u31())
```

```gdscript
func step(tick: int, frame: LocalFrameCommandSet) -> bool:
	if frame == null or not frame.is_valid():
		return _fail("invalid frame")
	if tick != _next_tick or frame.tick != tick:
		return _fail("unexpected tick")
	if frame.active_player_mask != _session.get_active_player_mask():
		return _fail("active mask mismatch")
	var next_commands: Array[PlayerFrameCommand] = []
	var next_events: Array[SimEvent] = []
	for slot in range(4):
		var command := frame.player_commands[slot].copy()
		next_commands.append(command)
		if command.action_bits != 0:
			next_events.append(SimEvent.new(tick, 0, slot + 1, 0, 0, 1, command.action_bits))
	SimEventOrder.sort(next_events)
	_last_commands = next_commands
	_last_events = next_events
	_next_tick += 1
	return true
```

事件仅验证稳定接口，不播放音频、不产生 FX、不处理伤害、不接触场景树。

- [ ] **Step 4: 实现按固定 section 排序的规范状态和 SHA-256**

`encode_canonical_state()` 无条件按下列大类顺序调用八个 section writer。后续计划只填充预留 section，不得把玩家、僵尸、地图或世界实体追加到末尾，也不得在 Plan 6 再重排此前字节：

1. `_encode_world_header()`：`canonical_schema:u8=1`、`manifest_length:u16 + manifest_bytes`、`session_seed:u32`、`active_mask:u8`、`input_heading_offset:u8`、`next_tick:u32`、`config_bundle_marker:u8=0`；Plan 6 完整世界只把该 marker 改为 1，并在其后写 bundle schema、五段 component Hash 与最终 config Hash。
2. `_encode_player_section()`：`player_slot_count:u8=4`，随后写四个 last command 的原始四字节字段，再预留 `player_sim_marker:u8=0`；Plan 3 只把 marker 改为 1，并在其后按 schema→配置→`SimPlayerState` 的冻结子序写入，不重复编码命令。
3. `_encode_zombie_section()`：Plan 1 固定 `zombie_marker:u8=0`、`zombie_slot_count:u16=0`；Plan 4 只把 marker 改为 1，并在同一位置写 schema/config/`ZombieState`。
4. `_encode_other_entity_section()`：allocator canonical bytes，随后固定预留 `combat_state_marker:u8=0`、`world_entity_marker:u8=0`；Plan 5/6 只把各自 marker 改为 1，并在对应 marker 后按冻结子顺序写装备、油桶、拾取和库存。
5. `_encode_dynamic_map_section()`：Plan 1 固定 `map_marker:u8=0`；Plan 2 只把 marker 改为 1，并在同一位置写 schema、地图 Hash、动态占用和 Flow Field。
6. `_encode_prng_section()`：`rng_stream_count:u8=4`，按固定 tag `1=world, 2=wave, 3=drop, 4=entity` 写 `tag:u8 + state:u32`；后续计划只追加明确命名且稳定排序的独立随机流。
7. `_encode_wave_section()`：Plan 1 固定 `wave_marker:u8=0`；Plan 6 只把 marker 改为 1，并在同一位置写 schema、比赛与波次状态。
8. `_encode_pending_event_section()`：先写 Plan 1 核心待执行队列的 `pending_event_count:u16=0`，再依次预留 `zombie_intent_marker:u8=0`、`combat_pending_marker:u8=0`、`world_command_marker:u8=0`，最后写 Plan 1 的 `last_event_count:u16` 和本 Tick 稳定输出事件；Plan 4～6 只改变各自 marker，并在对应子段中写攻击意图、伤害/表现候选、生灭命令。未配置核心世界的三个 marker 均保持 0。

本 Tick 输出事件逐条编码 `tick:u32 / phase:u16 / source_id:u32 / local_sequence:u16 / target_id:u32 / event_type:u16 / value:i32`。`event_id` 不重复序列化，而是从已编码的 tick/source/local_sequence 重新派生并在验证中断言一致。不得编码节点、Transform、音频、动画、摄像机、HUD、网络状态或对象实例 ID。

```gdscript
static func hash_canonical(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish()
```

- [ ] **Step 5: 锁定 section 顺序金样并运行世界验收**

验证相同 session/frame 0 的 canonical bytes 与 SHA-256 hex 金样；断言八个 section 严格按 world→players→zombies→other entities→dynamic map→PRNG→wave→pending/events 出现，且预留的 `config_bundle/player_sim/zombie/combat_state/world_entity/map/wave/zombie_intent/combat_pending/world_command` marker 全部为 0；四条 RNG tag/state 的顺序与状态金样一致。再验证两个新建 world 对相同 200 帧输入逐 Tick hash 相等；手工构造逆序事件时输出顺序和派生 event_id 一致。后续配置型世界只改变对应 marker/子段内容，未配置的 Plan 1 core world 金样不得变化。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
```

Expected: `validate_local_frame_sync_core: PASS`，退出码 0。

#### 里程碑 3B：先显式冻结 Godot 60 Hz 物理频率

- [ ] **Step 6: 写 project.godot 显式 60 Hz 的失败验证**

先只向 `validate_local_frame_sync_core.gd` 加入配置源文件断言，不预加载尚不存在的 driver。既要验证 Godot 运行时读到 60，也要用 `ConfigFile` 验证该值确实写进 `project.godot`，不能仅依赖引擎默认值：

```gdscript
var project_config := ConfigFile.new()
_expect(project_config.load("res://project.godot") == OK, "project.godot must load", failures)
_expect(
	project_config.has_section_key("physics", "common/physics_ticks_per_second"),
	"project.godot must explicitly declare physics tick rate",
	failures
)
_expect(
	int(project_config.get_value("physics", "common/physics_ticks_per_second", -1)) == 60,
	"project.godot physics tick rate must be exactly 60",
	failures
)
_expect(
	int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -1)) == 60,
	"Godot runtime physics tick rate must be 60",
	failures
)
```

- [ ] **Step 7: 运行验证，确认显式声明缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
```

Expected: 非零退出，失败信息为 `project.godot must explicitly declare physics tick rate`；即使运行时默认值当前也是 60，源文件缺少显式键仍必须失败。

- [ ] **Step 8: 在 project.godot 现有 physics 段显式固定 60 Hz**

保留已有 Jolt 和插值设置，只增加一行：

```ini
[physics]

3d/physics_engine="Jolt Physics"
common/physics_interpolation=true
common/physics_ticks_per_second=60
```

该变更冻结修改前已经生效的 Godot 默认 60 Hz 行为，不改变当前物理引擎或玩法节奏。

- [ ] **Step 9: 运行配置验证并确认通过**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
```

Expected: 配置源文件键存在且等于 60，运行时 setting 也等于 60；验证脚本退出 0。

#### 里程碑 3C：60 Hz 到 30 Hz 的不可跳 Tick 驱动

- [ ] **Step 10: 写二分频、诊断 Hash 间隔、缺帧和设备离线失败验证**

调用无参数 `advance_physics_callback()` 六次，断言仅第 2、4、6 次推进 tick 0、1、2；第一次 callback 不采样。使 active source 离线后再调用两个 callback，断言 world tick 不变、未提交 neutral frame、driver 有错误。

```gdscript
for _index in range(6):
	driver.advance_physics_callback()
_expect(driver.get_physics_callback_count() == 6, "driver must count physics callbacks", failures)
_expect(driver.get_simulation_step_count() == 3, "60 Hz must divide to 30 Hz", failures)
_expect(world.get_next_tick() == 3, "driver must advance sequential ticks", failures)
_expect(driver.get_diagnostic_hash_interval() == 30, "normal local play must hash every 30 ticks", failures)
```

另以默认 interval 推进到完成 Tick 29，断言 Tick 0～28 的 `simulation_advanced` 均携带空 `PackedByteArray`、Tick 29 携带 32-byte Hash；新建测试 driver 后调用 `set_diagnostic_hash_interval(1)`，断言每个成功 Tick 都携带 Hash。`FirstDivergenceHarness` 不依赖 driver interval，而是直接对两个世界逐 Tick 计算 Hash。

- [ ] **Step 11: 运行验证，确认 driver 缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
```

Expected: 非零退出，`LocalFrameSyncDriver` 尚不存在。

- [ ] **Step 12: 实现两相位驱动**

driver 可继承 `Node` 以便未来接入物理回调，但 Plan 1 不把它挂入现有场景。构造时验证 `Engine.physics_ticks_per_second == 60`；`_diagnostic_hash_interval` 默认 30，`set_diagnostic_hash_interval()` 只接受正整数。每 callback 计数，奇数 callback 不采样，偶数 callback 只尝试 world 当前 `next_tick`。collector、buffer 或 world 失败时不得增加 simulation step count。

```gdscript
func advance_physics_callback() -> bool:
	_physics_callback_count += 1
	if Engine.physics_ticks_per_second != 60:
		return _fail("physics tick rate must be 60 Hz")
	if (_physics_callback_count & 1) != 0:
		return false
	var tick := _world.get_next_tick()
	var frame := _collector.collect(tick)
	if frame == null:
		return _fail(_collector.get_error_message())
	if not _buffer.submit(frame) or not _buffer.has_complete_frame(tick):
		return _fail(_buffer.get_error_message())
	var accepted := _world.step(tick, _buffer.take(tick))
	if accepted:
		_simulation_step_count += 1
		var diagnostic_hash := PackedByteArray()
		if FixedMath.euclidean_mod(tick + 1, _diagnostic_hash_interval) == 0:
			diagnostic_hash = StateHasher.hash_canonical(_world.encode_canonical_state())
		simulation_advanced.emit(tick, diagnostic_hash)
	return accepted
```

`_physics_process(_delta)` 的方法体只能调用 `advance_physics_callback()`；不得存储或向 world 传递 `_delta`。

- [ ] **Step 13: 完成本 Task 验收**

验证第八次 callback 后 step count 为 4；物理频率不是 60 时拒绝推进；buffer 冲突、collector 离线、source key 不匹配时 world `next_tick` 不变；恢复相同 source key 后继续原 next tick，不补中性帧、不跳 tick。默认本地 driver 只在完成 Tick 29、59、89… 时计算诊断 Hash；聚焦测试把 interval 设为 1 时逐 Tick Hash，设为 0 或负数必须失败且保留原 interval。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两条命令均退出 0。Task 3 可独立验收；不提交。

### Task 4: 里程碑四——首分歧诊断与连续 100,000 Tick 资格门槛

**Files:**
- Create: `scripts/simulation/testing/first_divergence_harness.gd`
- Create: `scripts/simulation/testing/determinism_test_runner.gd`
- Modify: `tools/validation/validate_local_frame_sync_core.gd`

**Interfaces:**
- Consumes: `LocalSimulationSession`、`SimulationWorld`、`LocalFrameCommandSet`、`LocalFrameCommandCodec`、`InputTape`、`ParkMillerRng`、`StateHasher`。
- Produces: `FirstDivergenceHarness.new(session: LocalSimulationSession)`、`run(tape: InputTape, tick_limit: int) -> Dictionary`、`run_with_codec_frame_mutator(tape: InputTape, tick_limit: int, mutator: Callable) -> Dictionary`。
- Produces: harness 成功结果 `{ "ok": true, "ticks_checked": int }`；失败结果 `{ "ok": false, "tick": int, "reason": String, "frame_hex": String, "direct_hash": String, "codec_hash": String, "state_diff_offset": int, "direct_state_byte": int, "codec_state_byte": int, "direct_state_hex": String, "codec_state_hex": String }`。
- Produces: `determinism_test_runner.gd` 为 active mask 1、3、7、15 各验证连续 100,000 Tick；全部通过才打印 `determinism_test_runner: PASS 100000 ticks per active mask` 并退出 0。

#### 里程碑 4A：先验证首分歧工具会失败并能定位

- [ ] **Step 1: 写正常双路径和故意分歧失败验证**

生成 200 Tick 短 tape。直接路径原样 step；codec 路径必须逐帧 encode/decode。正常运行应 `ok`；测试 mutator 在 codec 路径第 17 帧改变一个仍合法的 command，必须报告第 17 Tick，并给出 frame、双方 hash、canonical state 和第一个不同 byte offset。

```gdscript
var result := harness.run(tape, 200)
_expect(result.ok and result.ticks_checked == 200, "direct and codec paths must agree", failures)
var divergent := harness.run_with_codec_frame_mutator(tape, 200, _change_tick_17)
_expect(not divergent.ok and divergent.tick == 17, "harness must stop at first divergence", failures)
_expect(divergent.state_diff_offset >= 0, "harness must locate first state byte difference", failures)
```

- [ ] **Step 2: 运行验证，确认 harness/runner 尚不存在**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://scripts/simulation/testing/determinism_test_runner.gd
```

Expected: 两条命令均非零退出；不得用空实现返回成功。

- [ ] **Step 3: 实现双世界逐 Tick harness**

每次 run 新建两个同 session world；验证 tape session 与 harness session `is_replay_compatible()`，`tick_limit >= 1` 且不超过 tape frame count。direct world 接受 `tape.get_frame(tick)`；codec world 只能接受该帧 encode/decode 后的副本。任一 codec/step 失败或 hash 不相等时立即返回，不检查后续 tick。

```gdscript
for tick in range(tick_limit):
	var direct_frame := tape.get_frame(tick)
	var codec_bytes := LocalFrameCommandCodec.encode(direct_frame)
	var codec_frame := LocalFrameCommandCodec.decode(codec_bytes)
	if not direct_world.step(tick, direct_frame) or not codec_world.step(tick, codec_frame):
		return _failure(tick, "world step failed", codec_bytes, direct_world, codec_world)
	var direct_hash := StateHasher.hash_canonical(direct_world.encode_canonical_state())
	var codec_hash := StateHasher.hash_canonical(codec_world.encode_canonical_state())
	if not StateHasher.equal(direct_hash, codec_hash):
		return _failure(tick, "state hash mismatch", codec_bytes, direct_world, codec_world)
return {"ok": true, "ticks_checked": tick_limit}
```

`_failure()` 比较双方 canonical byte arrays，从 offset 0 扫描至首个不同 byte；长度不同时 offset 为较短长度，缺失侧 byte 记录为 -1。mutator 只供聚焦测试注入 codec 路径，不在 runner 正常门槛使用。

- [ ] **Step 4: 运行短路径验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
```

Expected: 正常 200 Tick 零分歧；故意修改在 Tick 17 立即停止并定位首个状态字节差异；退出码 0。

#### 里程碑 4B：执行 Plan 1 的 100,000 Tick 硬门槛

- [ ] **Step 5: 实现固定输入带生成器与 runner**

runner 继承 `SceneTree`，对 active mask 1、3、7、15 分别创建独立 session 和 100,000 帧 tape。每个启用 slot 使用固定且互不相同的 Park–Miller seed，生成合法 `move_heading 0..16`、三个 action bit、`equipment_delta -1..1` 和 `placement_heading 0..16`；未启用槽恒为 neutral。每条 tape 必须先 encode/decode，恢复后的 tape 才交给 harness。

```gdscript
for active_player_mask in [0b0001, 0b0011, 0b0111, 0b1111]:
	var tape := _make_tape(active_player_mask, 100000)
	var encoded := tape.encode()
	var restored := InputTape.new(tape.get_session())
	if not restored.decode(encoded):
		push_error("InputTape decode failed for mask %d" % active_player_mask)
		quit(1)
		return
	var result := FirstDivergenceHarness.new(restored.get_session()).run(restored, 100000)
	if not result.ok:
		push_error("first divergence: %s" % [result])
		quit(1)
		return
print("determinism_test_runner: PASS 100000 ticks per active mask")
quit(0)
```

- [ ] **Step 6: 运行全部聚焦验证、100,000 Tick runner 与导入检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://scripts/simulation/testing/determinism_test_runner.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 五条命令全部退出 0；runner 对每个连续 mask 都逐 Tick 比较完整 100,000 Tick，最终输出 `determinism_test_runner: PASS 100000 ticks per active mask`。

- [ ] **Step 7: 执行范围与禁用依赖审查**

```bash
git diff --name-only
if rg -n "CharacterBody3D|PhysicsServer|NavigationAgent3D|NavigationServer3D|Multiplayer|WebSocket|ENet|WebRTC|DemoArena|RandomNumberGenerator|randf|randi|NodePath|instance_id" scripts/simulation tools/validation; then
	echo "forbidden dependency scan: FAIL" >&2
	exit 1
else
	echo "forbidden dependency scan: PASS"
fi
if rg -n " / " scripts/simulation -g "*.gd" -g "!fixed_math.gd"; then
	echo "direct integer division outside FixedMath: FAIL" >&2
	exit 1
else
	echo "direct integer division outside FixedMath: PASS"
fi
if [ "$(rg -c " / " scripts/simulation/core/fixed_math.gd)" -ne 1 ]; then
	echo "FixedMath must contain exactly one direct division primitive" >&2
	exit 1
fi
if ! rg -n "^[[:space:]]*var quotient: int = dividend / divisor$" scripts/simulation/core/fixed_math.gd; then
	echo "FixedMath floor_div primitive is missing or changed" >&2
	exit 1
fi
```

Expected: diff 只包含 `project.godot` 的显式 60 Hz 设置、本计划允许的新增路径和本计划文档；禁用依赖有任何匹配时命令退出 1，无匹配时打印 `forbidden dependency scan: PASS`；除 `FixedMath.floor_div()` 的精确一行外出现任何直接 `/` 时退出 1。

- [ ] **Step 8: 应用失败门槛或宣布 Plan 1 可交付**

若任一验证失败或出现首分歧：保留 harness 输出的 `tick`、`reason`、`frame_hex`、双方 Hash、`state_diff_offset` 和双方 canonical state hex；停止 Plan 2 至 Plan 8，不修改 `DemoArena` 默认路径，不把本计划标为完成。

只有五条命令全部通过、范围审查通过时，Task 4 和 Plan 1 才可验收。agent 到此停止，不暂存、不提交、不改写历史；由用户自行审查并提交整个 Plan。

## 交付判定

- [ ] `LocalFrameCommandCodec` 对每个合法完整帧产出恰好 22 bytes，并拒绝错误 schema、长度、字段、稀疏掩码和未启用槽位数据。
- [ ] collector 按 slot 升序采样；previous+next 同 Tick 规范化为 `equipment_delta = 0`；设备离线或 source key 不匹配时不提交中性帧、不推进模拟。
- [ ] `project.godot` 在现有 `[physics]` 段显式声明 `common/physics_ticks_per_second=60`，验证同时检查源文件显式键和运行时 setting，且 Jolt/插值配置保持不变。
- [ ] `SimulationManifest`、`LocalSimulationSession` 和 `InputTape` 固定保存规则版本、地图 ID、32 bytes 配置 Hash、session seed、active mask 和连续四槽帧。
- [ ] 连续 mask `0b1/0b3/0b7/0b15`、slot 0..3、正 ID + generation、Park–Miller、FixedMath 和 SimEvent 排序均有聚焦验证。
- [ ] `LocalFrameSyncDriver` 仅在每第二个 60 Hz physics callback 尝试从完整帧推进一个 30 Hz Tick；缺帧或设备离线时暂停，恢复后继续同一 next tick，绝不跳 Tick。
- [ ] `InputTape`、规范状态和 Hash 不包含 Godot 节点、物理、导航、渲染、音频、摄像机、HUD、对象实例 ID 或网络状态。
- [ ] 直接命令世界与编码/解码命令世界对 1、2、3、4 人各连续 100,000 Tick 的每 Tick SHA-256 完全一致；差异发生时 harness 在首个 Tick 停止并输出输入、Hash 与首个 canonical byte 差异。
- [ ] 门槛通过前不开始 Plan 2 至 Plan 8，当前 `DemoArena` 保持未修改的默认可玩路径。
- [ ] agent 未执行任何暂存、提交或历史改写；整个 Plan 的提交由用户完成。
