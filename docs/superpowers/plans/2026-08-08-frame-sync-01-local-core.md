# 本地确定性帧同步核心 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不接入现有战斗场景的前提下，交付可录像、可回放、可逐 Tick Hash 比对的本地 30 Hz 确定性模拟核心，并以连续 100,000 Tick 零分歧作为后续迁移的硬门槛。

**Architecture:** 新代码全部位于 `scripts/simulation/`，其中 `LocalInputCollector` 将现有设备输入快照量化为固定四槽位命令，`LocalFrameInputBuffer` 按 Tick 保存完整帧，`LocalFrameSyncDriver` 在 60 Hz Godot 物理回调中严格每两次推进一次 30 Hz `SimulationWorld`。世界只保存整数状态、稳定实体引用和稳定排序后的事件；`InputTape` 与规范状态均走显式 little-endian 字节编码，双世界 harness 分别走直接命令和编解码命令路径后逐 Tick 比较 SHA-256。

**Tech Stack:** Godot 4.7.1、GDScript、`PackedByteArray`、`HashingContext.HASH_SHA256`、现有 `PlayerInputSource` / `PlayerInputState`、headless Godot 验证脚本。

## Global Constraints

- 设计规格：`docs/superpowers/specs/2026-08-08-local-deterministic-frame-sync-design.md`，本计划只实现其中 Plan 1 的本地核心。
- 仅创建 `scripts/simulation/{core,commands,session,input,world,replay,driver,events,testing}/` 下列出的新 GDScript 文件和 `tools/validation/` 下列出的新验证脚本；不修改现有文件。
- 不接入 `DemoArena`、`PlayerController`、摄像机、Godot Physics、Jolt、`NavigationAgent3D`、`NavigationServer3D`、运行时 NavMesh、场景节点玩法判定或网络传输。
- `SimulationWorld` 不继承 `Node`、不引用场景节点、不接收 `delta`、不读取浮点输入、RandomNumberGenerator、全局随机数或 Dictionary 迭代顺序。
- 模拟频率固定为 30 Hz；Godot 物理频率必须为 60 Hz；驱动器每两个物理回调恰好执行一个模拟 Tick，性能不足时累积落后而不跳 Tick。
- 玩家槽位固定为 `0..3`；有效掩码只能是连续低位的 `0b0001`、`0b0011`、`0b0111`、`0b1111`，未启用槽位命令始终为全零。
- `PlayerFrameCommand` 字段固定为 `move_heading: 0..16`、`action_bits: USE_HELD|USE_PRESSED|CONFIRM`、`equipment_delta: -1|0|1`、`placement_heading: 0..16`；不得增添设备、Vector、摄像机或装备索引字段。
- 单帧命令编码固定为 22 bytes：`schema:u8 + tick:u32-le + active_player_mask:u8 + 4 * (move_heading:u8 + action_bits:u8 + equipment_delta:i8 + placement_heading:u8)`。
- 所有多字节整数均使用 little-endian；坐标、Tick、ID、计数、随机状态和 Hash 输入均使用显式字节写入；不使用 Variant、Dictionary 或 JSON 序列化作为确定性数据格式。
- 数值规则使用整数和 `FixedMath`；中间乘法使用 GDScript `int` 的 int64 语义；不依赖溢出、`sin`、`cos`、`atan2`、`sqrt`、浮点归一化或负数 `%` 的实现细节。
- PRNG 固定为 Park–Miller：乘数 `48271`、模数 `2147483647`、状态 `1..2147483646`；范围采样使用 rejection sampling。
- 实体引用为正数 `entity_id` 加正数 `generation`；命令和事件遍历按显式稳定键排序；不使用 NodePath、RID 或 instance ID。
- 正常本地运行可按每 30 Tick 计算诊断 Hash；本计划所有自动确定性验证每 Tick 计算 Hash。
- 验证命令必须先在缺少对应实现时失败，再在最小实现后通过。若连续 100,000 Tick 验证首次分歧或退出码非 0，停止 Plan 2 至 Plan 8 的任何实现工作并保留旧 `DemoArena` 默认路径。
- 可使用每个任务的临时 Conventional Commit 进行审查；本计划及后续评审完成、合并目标分支之前，必须 squash 为一个计划提交：`feat: add local deterministic frame-sync core`。

---

## 文件结构与稳定边界

| 路径 | 职责 |
| --- | --- |
| `scripts/simulation/core/little_endian.gd` | 有界 little-endian 读写器，集中处理 u8/i8/u16/u32/i32 与固定字节段。 |
| `scripts/simulation/core/fixed_math.gd` | 整数除法、欧几里得取模、16 方向整数表和距离平方。 |
| `scripts/simulation/core/park_miller_rng.gd` | 独立、可快照的 Park–Miller 随机流。 |
| `scripts/simulation/core/entity_id_allocator.gd` | 正 ID、generation 和固定容量复用规则。 |
| `scripts/simulation/commands/player_frame_command.gd` | 单玩家四字节命令与字段验证。 |
| `scripts/simulation/commands/local_frame_command_set.gd` | Tick、连续掩码和四槽位命令集合。 |
| `scripts/simulation/commands/local_frame_command_codec.gd` | 22 bytes 单帧命令的严格编码、解码与拒绝规则。 |
| `scripts/simulation/events/sim_event.gd` | 不引用表现节点的整数事件记录。 |
| `scripts/simulation/events/sim_event_order.gd` | 按阶段、来源、本地序号、目标和类型的稳定比较器。 |
| `scripts/simulation/session/simulation_manifest.gd` | 不可变规则版本、地图 ID、配置 Hash 和清单字节格式。 |
| `scripts/simulation/session/local_simulation_session.gd` | 本局种子、连续玩家掩码、输入延迟 0 和启动前验证。 |
| `scripts/simulation/input/local_input_collector.gd` | 以槽位升序采样既有输入源，并将其量化为命令。 |
| `scripts/simulation/input/local_frame_input_buffer.gd` | 按 Tick 保存、拒绝矛盾提交、只在完整帧存在时放行。 |
| `scripts/simulation/world/simulation_world.gd` | 最小纯数据世界、稳定命令消费、事件排序、规范状态编码。 |
| `scripts/simulation/replay/input_tape.gd` | 带清单和种子的定长帧录像读写。 |
| `scripts/simulation/replay/state_hasher.gd` | 对规范状态计算 SHA-256 并比较 32 bytes Hash。 |
| `scripts/simulation/driver/local_frame_sync_driver.gd` | 60 Hz 到 30 Hz 的整数二分频推进，不传递物理 delta。 |
| `scripts/simulation/testing/first_divergence_harness.gd` | 双世界直接/编解码回放、首分歧导出和立即停止。 |
| `scripts/simulation/testing/determinism_test_runner.gd` | 以 1、2、3、4 人固定输入带执行 100,000 Tick 的 headless 入口。 |
| `tools/validation/validate_simulation_core_primitives.gd` | 定点、PRNG、实体 ID 和事件顺序聚焦验证。 |
| `tools/validation/validate_local_frame_commands.gd` | 命令字段、连续掩码、22 bytes codec 和缓冲聚焦验证。 |
| `tools/validation/validate_local_frame_sync_core.gd` | 会话、采集、驱动、录像、规范状态和首分歧 harness 集成验证。 |

### Task 1: 建立确定性字节基础与失败验证

**Files:**
- Create: `scripts/simulation/core/little_endian.gd`
- Create: `tools/validation/validate_simulation_core_primitives.gd`

**Interfaces:**
- Consumes: `PackedByteArray`。
- Produces: `LittleEndianWriter.write_u8(value: int) -> void`、`write_i8(value: int) -> void`、`write_u16(value: int) -> void`、`write_u32(value: int) -> void`、`write_i32(value: int) -> void`、`write_bytes(value: PackedByteArray) -> void`、`to_bytes() -> PackedByteArray`；`LittleEndianReader.read_u8() -> int`、`read_i8() -> int`、`read_u16() -> int`、`read_u32() -> int`、`read_i32() -> int`、`read_bytes(count: int) -> PackedByteArray`、`is_at_end() -> bool`、`has_error() -> bool`。

- [ ] **Step 1: 写字节编码的失败验证**

在 `validate_simulation_core_primitives.gd` 预加载尚不存在的 `LittleEndianWriter` 和 `LittleEndianReader`，写入 `0x7f`、`-1`、`0x3412`、`0x78563412`、`-2`，断言字节序列和往返值完全相同：

```gdscript
var writer := LittleEndianWriter.new()
writer.write_u8(0x7f)
writer.write_i8(-1)
writer.write_u16(0x3412)
writer.write_u32(0x78563412)
writer.write_i32(-2)
_expect(
	writer.to_bytes() == PackedByteArray([0x7f, 0xff, 0x12, 0x34, 0x12, 0x34, 0x56, 0x78, 0xfe, 0xff, 0xff, 0xff]),
	"little-endian bytes must be canonical",
	failures
)
```

- [ ] **Step 2: 运行验证，确认因缺少类而失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
```

Expected: 非零退出，预加载 `res://scripts/simulation/core/little_endian.gd` 失败；不得把此失败改为跳过测试。

- [ ] **Step 3: 实现有界 little-endian 读写器**

写入器在越界值时设置 `error_message` 且不追加字节；读取器在剩余字节不足时设置同一错误状态并返回 `0` 或空 `PackedByteArray`。核心位移规则固定如下：

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

- [ ] **Step 4: 补全越界读取与 signed byte 的断言并运行通过**

验证 `read_i8()` 将 `0xff` 还原为 `-1`，验证读取第五个字节会设置错误但不改变已读取的值。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
```

Expected: `validate_simulation_core_primitives: PASS`，退出码 0。

- [ ] **Step 5: 提交临时检查点**

```bash
git add scripts/simulation/core/little_endian.gd tools/validation/validate_simulation_core_primitives.gd
git commit -m "feat: add deterministic little-endian codec primitives"
```

### Task 2: 固化整数数学与 Park–Miller 随机流

**Files:**
- Create: `scripts/simulation/core/fixed_math.gd`
- Create: `scripts/simulation/core/park_miller_rng.gd`
- Modify: `tools/validation/validate_simulation_core_primitives.gd`

**Interfaces:**
- Consumes: `LittleEndianWriter`、`LittleEndianReader`。
- Produces: `FixedMath.floor_div(dividend: int, divisor: int) -> int`、`euclidean_mod(dividend: int, divisor: int) -> int`、`heading_x(heading: int) -> int`、`heading_z(heading: int) -> int`、`distance_squared(ax: int, az: int, bx: int, bz: int) -> int`；`ParkMillerRng.new(seed: int)`、`next_u31() -> int`、`next_inclusive(minimum: int, maximum: int) -> int`、`get_state() -> int`、`set_state(state: int) -> bool`、`encode_state(writer: LittleEndianWriter) -> void`。

- [ ] **Step 1: 为负数数学、16 方向表和 PRNG 金样写失败断言**

向同一验证脚本加入如下固定契约；`heading 0` 是静止，`heading 1` 是正 X，`heading 5` 是正 Z，`heading 9` 是负 X，`heading 13` 是负 Z，16 个非零 heading 顺时针等间隔：

```gdscript
_expect(FixedMath.floor_div(-1, 16) == -1, "floor_div must round down", failures)
_expect(FixedMath.euclidean_mod(-1, 16) == 15, "mod must be non-negative", failures)
_expect(FixedMath.heading_x(1) == 1024 and FixedMath.heading_z(1) == 0, "heading 1 must be +X", failures)
var rng := ParkMillerRng.new(1)
_expect(rng.next_u31() == 48271, "Park-Miller first value must be stable", failures)
_expect(rng.next_u31() == 182605794, "Park-Miller second value must be stable", failures)
```

- [ ] **Step 2: 运行验证，确认接口缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
```

Expected: 非零退出，错误指向 `FixedMath` 或 `ParkMillerRng` 尚未定义。

- [ ] **Step 3: 实现无浮点 FixedMath 和固定方向表**

把 17 组整数方向表作为常量，长度为 17，索引 0 为 `(0, 0)`；斜向组使用预烘焙、对称的整数值，禁止运行时三角函数。除法、取模和距离实现固定如下：

```gdscript
static func floor_div(dividend: int, divisor: int) -> int:
	assert(divisor > 0)
	var quotient := dividend / divisor
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

- [ ] **Step 4: 实现 Park–Miller 与无偏范围采样**

拒绝 `0`、负数和大于 `2147483646` 的种子。每次推进使用 int64 乘法且不依赖溢出；范围采样以 `2147483646` 为有效样本数，拒绝落在不完整桶中的值：

```gdscript
func next_u31() -> int:
	_state = (_state * 48271) % 2147483647
	return _state

func next_inclusive(minimum: int, maximum: int) -> int:
	assert(minimum <= maximum)
	var span := maximum - minimum + 1
	var limit := 2147483646 - (2147483646 % span)
	while true:
		var sample := next_u31() - 1
		if sample < limit:
			return minimum + (sample % span)
```

- [ ] **Step 5: 验证方向、随机状态快照和范围边界**

扩展验证：遍历 heading `0..16`，断言 `heading 0` 仅有零向量；`next_inclusive(7, 7)` 恒为 7；将推进三次后的状态编码、再解码到另一流，两个流的下一个值相同。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两条命令均退出 0。

- [ ] **Step 6: 提交临时检查点**

```bash
git add scripts/simulation/core/fixed_math.gd scripts/simulation/core/park_miller_rng.gd tools/validation/validate_simulation_core_primitives.gd
git commit -m "feat: add fixed math and Park-Miller rng"
```

### Task 3: 建立正数实体引用与稳定事件排序

**Files:**
- Create: `scripts/simulation/core/entity_id_allocator.gd`
- Create: `scripts/simulation/events/sim_event.gd`
- Create: `scripts/simulation/events/sim_event_order.gd`
- Modify: `tools/validation/validate_simulation_core_primitives.gd`

**Interfaces:**
- Consumes: `LittleEndianWriter`。
- Produces: `EntityIdAllocator.new(capacity: int)`、`allocate() -> Dictionary`、`release(entity_id: int, generation: int) -> bool`、`is_alive(entity_id: int, generation: int) -> bool`、`encode_canonical(writer: LittleEndianWriter) -> void`；`SimEvent.new(tick: int, phase: int, source_id: int, local_sequence: int, target_id: int, event_type: int, value: int)`；`SimEventOrder.less_than(left: SimEvent, right: SimEvent) -> bool`、`sort(events: Array[SimEvent]) -> void`。

- [ ] **Step 1: 写实体复用和事件 tie-break 的失败验证**

约定分配器第一个引用恒为 `{ "entity_id": 1, "generation": 1 }`；释放后再分配复用 `entity_id: 1` 但 generation 为 2；旧引用无效。构造相同 Tick 的事件，按 phase、source、local_sequence、target、event_type 断言排序：

```gdscript
var allocator := EntityIdAllocator.new(2)
var first := allocator.allocate()
_expect(first.entity_id == 1 and first.generation == 1, "first entity reference must be positive", failures)
_expect(allocator.release(1, 1), "current entity reference must release", failures)
var reused := allocator.allocate()
_expect(reused.entity_id == 1 and reused.generation == 2, "reused ID must advance generation", failures)
_expect(not allocator.is_alive(1, 1), "stale generation must be invalid", failures)
```

- [ ] **Step 2: 运行验证，确认稳定 ID 和事件类尚不存在**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
```

Expected: 非零退出，缺失脚本或类名使验证无法加载。

- [ ] **Step 3: 实现固定容量分配器**

分配器预分配 `alive: PackedByteArray` 和 `generation: PackedInt32Array`，始终从最小空闲 ID 开始扫描；capacity 耗尽返回空 Dictionary；release 只接受匹配且存活的正 ID/generation。generation 增长到 `2147483647` 时拒绝该槽位后续复用而非回绕：

```gdscript
func allocate() -> Dictionary:
	for entity_id in range(1, _capacity + 1):
		if _alive[entity_id] == 0 and _generation[entity_id] < 2147483647:
			_generation[entity_id] += 1
			_alive[entity_id] = 1
			return {"entity_id": entity_id, "generation": _generation[entity_id]}
	return {}
```

- [ ] **Step 4: 实现事件结构和不依赖容器稳定性的比较器**

`SimEvent` 的全部字段为 `int`，事件 ID 在世界内由 `(tick, source_id, local_sequence)` 显式派生和编码；比较器逐字段返回，禁止仅按 source 或使用默认对象排序：

```gdscript
static func less_than(left: SimEvent, right: SimEvent) -> bool:
	if left.phase != right.phase: return left.phase < right.phase
	if left.source_id != right.source_id: return left.source_id < right.source_id
	if left.local_sequence != right.local_sequence: return left.local_sequence < right.local_sequence
	if left.target_id != right.target_id: return left.target_id < right.target_id
	return left.event_type < right.event_type
```

用插入排序实现 `sort()`，每次比较均调用该函数，从而不依赖运行时排序稳定性。

- [ ] **Step 5: 验证容量耗尽、规范编码与乱序事件结果**

验证容量为 2 时第三次分配为空；验证同样的 allocate/release 序列得到相同 canonical bytes；以逆序、正序两种数组输入排序，输出逐项的 `phase/source/local_sequence/target/type` 完全相等。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
```

Expected: `validate_simulation_core_primitives: PASS`，退出码 0。

- [ ] **Step 6: 提交临时检查点**

```bash
git add scripts/simulation/core/entity_id_allocator.gd scripts/simulation/events tools/validation/validate_simulation_core_primitives.gd
git commit -m "feat: add stable simulation entity and event ordering"
```

### Task 4: 固定四槽位帧命令与 22 bytes codec

**Files:**
- Create: `scripts/simulation/commands/player_frame_command.gd`
- Create: `scripts/simulation/commands/local_frame_command_set.gd`
- Create: `scripts/simulation/commands/local_frame_command_codec.gd`
- Create: `tools/validation/validate_local_frame_commands.gd`

**Interfaces:**
- Consumes: `LittleEndianWriter`、`LittleEndianReader`。
- Produces: `PlayerFrameCommand.new(move_heading := 0, action_bits := 0, equipment_delta := 0, placement_heading := 0)`、`is_valid() -> bool`、`neutral() -> PlayerFrameCommand`；`LocalFrameCommandSet.new(tick: int, active_player_mask: int, player_commands: Array[PlayerFrameCommand])`、`is_valid() -> bool`、`is_contiguous_active_mask(mask: int) -> bool`；`LocalFrameCommandCodec.encode(frame: LocalFrameCommandSet) -> PackedByteArray`、`decode(bytes: PackedByteArray) -> LocalFrameCommandSet`、`get_error_message() -> String`。

- [ ] **Step 1: 写字段范围、掩码与 22 bytes 的失败验证**

验证脚本建立 mask `0b0011` 的 Tick `0x78563412` 帧，四个命令分别用不同合法值；断言编码长度固定为 22、前六字节为 `PackedByteArray([1, 0x12, 0x34, 0x56, 0x78, 3])`。同时断言 `0b0101`、0、16、`action_bits = 8`、`equipment_delta = 2`、未启用槽位非零都无效：

```gdscript
_expect(LocalFrameCommandSet.is_contiguous_active_mask(0b0001), "1 player mask must be valid", failures)
_expect(LocalFrameCommandSet.is_contiguous_active_mask(0b1111), "4 player mask must be valid", failures)
_expect(not LocalFrameCommandSet.is_contiguous_active_mask(0b0101), "sparse mask must fail", failures)
_expect(encoded.size() == 22, "each frame must be exactly 22 bytes", failures)
```

- [ ] **Step 2: 运行验证，确认命令实现缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
```

Expected: 非零退出，原因是命令脚本尚不存在。

- [ ] **Step 3: 实现严格的 PlayerFrameCommand 与帧集合验证**

动作位只定义下列三个常量，任何未声明 bit 都无效；`LocalFrameCommandSet` 始终保存恰好四个命令：

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

`is_contiguous_active_mask()` 只接受 `1`、`3`、`7`、`15`；对每个未启用槽位验证 `PlayerFrameCommand.neutral()` 的四个字段均为零。

- [ ] **Step 4: 实现唯一的 little-endian 单帧 codec**

编码前先调用 `frame.is_valid()`，失败返回空 `PackedByteArray` 并记录错误；解码要求字节长度恰为 22、schema 恒为 1，所有字段读取后再用同一验证器检查：

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

- [ ] **Step 5: 验证全字段往返和破损拒绝**

将已编码帧 decode 后逐字段比较 Tick、mask 和四个命令；分别截断一字节、附加一字节、修改 schema 为 2、修改未启用槽位为非零，断言 `decode()` 返回 `null` 并有非空错误信息。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两条命令均退出 0。

- [ ] **Step 6: 提交临时检查点**

```bash
git add scripts/simulation/commands tools/validation/validate_local_frame_commands.gd
git commit -m "feat: add fixed local frame commands and codec"
```

### Task 5: 创建不可变会话清单、零延迟会话与输入录像

**Files:**
- Create: `scripts/simulation/session/simulation_manifest.gd`
- Create: `scripts/simulation/session/local_simulation_session.gd`
- Create: `scripts/simulation/replay/input_tape.gd`
- Modify: `tools/validation/validate_local_frame_commands.gd`

**Interfaces:**
- Consumes: `LocalFrameCommandSet`、`LocalFrameCommandCodec`、`LittleEndianWriter`、`LittleEndianReader`。
- Produces: `SimulationManifest.new(schema_version: int, rules_version: int, map_id: StringName, config_hash: PackedByteArray)`、`is_valid() -> bool`、`encode() -> PackedByteArray`；`LocalSimulationSession.new(manifest: SimulationManifest, session_seed: int, active_player_mask: int, slot_source_keys: Array[StringName])`、`is_valid() -> bool`、`get_input_delay_ticks() -> int`、`get_active_player_mask() -> int`；`InputTape.new(session: LocalSimulationSession)`、`append(frame: LocalFrameCommandSet) -> bool`、`encode() -> PackedByteArray`、`decode(bytes: PackedByteArray) -> bool`、`get_frame(tick: int) -> LocalFrameCommandSet`、`get_frame_count() -> int`。

- [ ] **Step 1: 写清单和录像失败验证**

新增验证：32 bytes 配置 Hash、`rules_version = 3`、`map_id = &"core_spike"`、种子 12345、mask `0b0011`，向 InputTape 追加 tick 0、1 的合法帧后编码并恢复。断言更换任一 Hash 字节或删除中间 tick 都会拒绝：

```gdscript
_expect(session.get_input_delay_ticks() == 0, "local input delay must remain zero", failures)
_expect(tape.get_frame_count() == 2, "tape must preserve frame count", failures)
_expect(restored.get_frame(1).tick == 1, "tape must restore exact tick", failures)
```

- [ ] **Step 2: 运行验证，确认会话和录像接口尚不存在**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
```

Expected: 非零退出，预加载 session 或 replay 路径失败。

- [ ] **Step 3: 实现清单与会话启动时的全部拒绝规则**

清单只接受 schema 1、正数 rules version、非空 UTF-8 map ID（编码长度 1..64）和恰好 32 bytes 的 config hash。会话只接受有效清单、Park–Miller 有效种子、连续 mask、槽位数组长度为 4，启用槽位必须有非空 source key、未启用槽位必须是空 key：

```gdscript
func get_input_delay_ticks() -> int:
	return 0

func is_valid() -> bool:
	return manifest.is_valid() and session_seed >= 1 and session_seed <= 2147483646 \
		and LocalFrameCommandSet.is_contiguous_active_mask(active_player_mask) \
		and _has_exact_slot_source_keys()
```

- [ ] **Step 4: 实现定长 InputTape 格式**

二进制格式固定为：`"ITAP"` 四字节、tape schema `u8=1`、manifest 字节长度 `u16-le`、manifest bytes、session seed `u32-le`、active mask `u8`、frame count `u32-le`、连续的 `frame_count * 22` bytes。`append()` 只接受从 0 开始、严格等于前一帧 Tick 加 1 且与会话 mask 一致的帧；decode 在读取前先验证魔数、长度、会话字段和每个 frame codec。

```gdscript
func append(frame: LocalFrameCommandSet) -> bool:
	if not frame.is_valid() or frame.active_player_mask != _session.get_active_player_mask():
		return false
	if frame.tick != _frames.size():
		return false
	_frames.append(frame)
	return true
```

- [ ] **Step 5: 运行录像往返、连续 Tick 与配置不匹配验证**

验证 encode/decode 后字节完全一致；验证试图追加 tick 2 为第一帧、连续帧之后追加 tick 3、输入 31 bytes 配置 Hash 均失败。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
```

Expected: `validate_local_frame_commands: PASS`，退出码 0。

- [ ] **Step 6: 提交临时检查点**

```bash
git add scripts/simulation/session scripts/simulation/replay/input_tape.gd tools/validation/validate_local_frame_commands.gd
git commit -m "feat: add local simulation session and input tape"
```

### Task 6: 将现有输入快照收束到帧缓冲

**Files:**
- Create: `scripts/simulation/input/local_input_collector.gd`
- Create: `scripts/simulation/input/local_frame_input_buffer.gd`
- Create: `tools/validation/validate_local_frame_sync_core.gd`

**Interfaces:**
- Consumes: 既有 `res://scripts/input/player_input_source.gd`、`PlayerInputState`、`LocalSimulationSession`、`LocalFrameCommandSet`。
- Produces: `LocalInputCollector.new(session: LocalSimulationSession, sources: Array)`、`collect(tick: int) -> LocalFrameCommandSet`、`quantize_move_heading(move_vector: Vector2) -> int`；`LocalFrameInputBuffer.submit(frame: LocalFrameCommandSet) -> bool`、`has_complete_frame(tick: int) -> bool`、`take(tick: int) -> LocalFrameCommandSet`、`get_error_message() -> String`。

- [ ] **Step 1: 写采集顺序、量化和缓冲失败验证**

在验证脚本定义不读取全局 Input 的 `FixedInputSource extends PlayerInputSource`。以槽位 0 的 `Vector2(1, 0)`、槽位 1 的 `Vector2(0, -1)` 构造 mask `0b0011` 会话，断言 collect 返回 heading 1 与 5、`use_pressed/use_just_pressed/confirm_just_pressed` 映射为三个唯一 bit、未启用 slot 2/3 为零。验证重复提交不同内容同一 Tick 失败，`take(0)` 后帧不可再取：

```gdscript
_expect(frame.player_commands[0].move_heading == 1, "collector must quantize +X", failures)
_expect(frame.player_commands[1].move_heading == 5, "collector must quantize +Z", failures)
_expect(buffer.submit(frame), "first frame submission must succeed", failures)
_expect(not buffer.submit(conflicting_frame), "same tick conflict must fail", failures)
```

- [ ] **Step 2: 运行验证，确认 collector 和 buffer 缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
```

Expected: 非零退出，原因是 `LocalInputCollector` 或 `LocalFrameInputBuffer` 未定义。

- [ ] **Step 3: 实现固定量化及动作字段映射**

采样严格按 slot `0..3` 升序；输入向量先以 `round(component * 32767.0)` 转为整数，仅在采集层比较 FixedMath 方向表点积，点积相同取较小 heading；零向量为 0。禁止把 `Vector2` 或摄像机信息写入命令：

```gdscript
func _to_command(state: PlayerInputState) -> PlayerFrameCommand:
	var bits := 0
	if state.use_pressed: bits |= PlayerFrameCommand.USE_HELD
	if state.use_just_pressed: bits |= PlayerFrameCommand.USE_PRESSED
	if state.confirm_just_pressed: bits |= PlayerFrameCommand.CONFIRM
	var delta := 0
	if state.previous_equipment_just_pressed: delta = -1
	elif state.next_equipment_just_pressed: delta = 1
	return PlayerFrameCommand.new(quantize_move_heading(state.move_vector), bits, delta, 0)
```

`placement_heading` 在 Plan 1 固定为 0，留待后续玩法以同一命令字段填充；这不改变 codec。

- [ ] **Step 4: 实现按 Tick 的完整帧缓冲**

缓冲以 Tick 为 key，仅保存 codec 后 bytes 的副本及 decode 后帧，避免外部对象修改；提交 Tick 小于已消费 Tick、无效帧、冲突同 Tick 或超出 `max_pending_frames = 256` 的未消费窗口均失败。只有帧的连续 mask 和四槽位格式完整时 `has_complete_frame()` 返回 true：

```gdscript
func take(tick: int) -> LocalFrameCommandSet:
	if not has_complete_frame(tick):
		return null
	var frame: LocalFrameCommandSet = _frames[tick]
	_frames.erase(tick)
	_last_consumed_tick = tick
	return frame
```

- [ ] **Step 5: 验证无输入、反向装备边沿和缓冲缺帧**

验证空输入得到 heading 0；同一源同时报 previous/next 时 collector 固定选择 previous（`-1`）；空 buffer 的 `has_complete_frame(0)` 为 false，tick 1 在 tick 0 尚未消费时提交有效但取用 tick 1 不会隐式推进 tick 0。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
```

Expected: `validate_local_frame_sync_core: PASS`，退出码 0。

- [ ] **Step 6: 提交临时检查点**

```bash
git add scripts/simulation/input tools/validation/validate_local_frame_sync_core.gd
git commit -m "feat: collect local inputs into frame buffer"
```

### Task 7: 实现最小纯数据世界、规范状态与 SHA-256

**Files:**
- Create: `scripts/simulation/world/simulation_world.gd`
- Create: `scripts/simulation/replay/state_hasher.gd`
- Modify: `tools/validation/validate_local_frame_sync_core.gd`

**Interfaces:**
- Consumes: `LocalSimulationSession`、`LocalFrameCommandSet`、`EntityIdAllocator`、`ParkMillerRng`、`SimEvent`、`SimEventOrder`、`LittleEndianWriter`。
- Produces: `SimulationWorld.new(session: LocalSimulationSession)`、`step(tick: int, frame: LocalFrameCommandSet) -> bool`、`get_next_tick() -> int`、`encode_canonical_state() -> PackedByteArray`、`get_last_events() -> Array[SimEvent]`、`get_last_error() -> String`；`StateHasher.hash_canonical(bytes: PackedByteArray) -> PackedByteArray`、`equal(left: PackedByteArray, right: PackedByteArray) -> bool`、`to_hex(value: PackedByteArray) -> String`。

- [ ] **Step 1: 写世界状态、顺序和 Hash 的失败验证**

创建同一会话的两个最小世界，以两个不同且合法的命令帧 step；断言第一步只接受 tick 0、下一 tick 为 1、历史命令状态改变规范字节、相同输入世界产生同一 32 bytes Hash。另以手工逆序事件放入世界的测试入口，断言 `get_last_events()` 已稳定排序：

```gdscript
_expect(world.step(0, frame_0), "world must accept first complete frame", failures)
_expect(not world.step(2, frame_1), "world must reject skipped tick", failures)
_expect(StateHasher.hash_canonical(world.encode_canonical_state()).size() == 32, "SHA-256 must be 32 bytes", failures)
```

- [ ] **Step 2: 运行验证，确认世界与 Hash 接口缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
```

Expected: 非零退出，缺失 `SimulationWorld` 或 `StateHasher`。

- [ ] **Step 3: 实现不含玩法节点的最小世界推进**

世界构造时保存 session、一个世界随机流、一个固定容量 `EntityIdAllocator`（capacity 256）、`next_tick = 0`、四份上次命令和空事件列表。`step()` 仅接受正确 Tick、匹配 session mask 和合法帧；依 slot 升序复制四份命令、根据非零 action_bits 生成一个测试用 `SimEvent`，排序后存储，最后将 `next_tick += 1`。此事件不播放音频、不产生 FX、不处理伤害也不改变场景：

```gdscript
func step(tick: int, frame: LocalFrameCommandSet) -> bool:
	if tick != _next_tick or frame.tick != tick or frame.active_player_mask != _session.get_active_player_mask():
		return _fail("unexpected frame tick or mask")
	_last_events.clear()
	for slot in range(4):
		_last_commands[slot] = frame.player_commands[slot].duplicate()
		if _last_commands[slot].action_bits != 0:
			_last_events.append(SimEvent.new(tick, 0, slot + 1, 0, 0, 1, _last_commands[slot].action_bits))
	SimEventOrder.sort(_last_events)
	_next_tick += 1
	return true
```

- [ ] **Step 4: 实现规范状态顺序与 SHA-256**

规范状态必须依次写入：canonical schema `u8=1`、manifest bytes 长度 `u16` 与 bytes、session seed `u32`、active mask `u8`、next tick `u32`、四个上次命令的原始四字节字段、allocator canonical bytes、world RNG state `u32`、last event count `u16` 及已排序事件字段。Hash 仅接受规范 bytes：

```gdscript
static func hash_canonical(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish()
```

禁止 Hash 节点 Transform、音频、动画、摄像机、HUD、对象实例 ID 或渲染状态。

- [ ] **Step 5: 验证错误不推进、Hash 金样与独立实例一致**

测试无效帧和跳 tick 后 `get_next_tick()` 不变；将固定会话和 frame 0 的 SHA-256 hex 固定为验证中的金样；同样 sequence 在新建的两个 world 中每一步 Hash 相等。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两条命令均退出 0。

- [ ] **Step 6: 提交临时检查点**

```bash
git add scripts/simulation/world scripts/simulation/replay/state_hasher.gd tools/validation/validate_local_frame_sync_core.gd
git commit -m "feat: add canonical simulation world state hashing"
```

### Task 8: 添加 60 Hz/30 Hz 整数二分频驱动

**Files:**
- Create: `scripts/simulation/driver/local_frame_sync_driver.gd`
- Modify: `tools/validation/validate_local_frame_sync_core.gd`

**Interfaces:**
- Consumes: `LocalInputCollector`、`LocalFrameInputBuffer`、`SimulationWorld`。
- Produces: `LocalFrameSyncDriver.new(world: SimulationWorld, collector: LocalInputCollector, buffer: LocalFrameInputBuffer)`、`advance_physics_callback() -> bool`、`get_physics_callback_count() -> int`、`get_simulation_step_count() -> int`、`get_last_error() -> String`；信号 `simulation_advanced(tick: int, state_hash: PackedByteArray)`。

- [ ] **Step 1: 写二分频、缺帧不推进和不使用 delta 的失败验证**

测试调用 `advance_physics_callback()` 六次，使用可用 collector 后只在第 2、4、6 次推进 world 的 tick 0、1、2；用一个无命令 buffer 替换后，再两个回调不推进。验证脚本只调用无参数方法，以此禁止 driver 接收或传递物理 delta：

```gdscript
for _index in range(6):
	driver.advance_physics_callback()
_expect(driver.get_physics_callback_count() == 6, "driver must count physics callbacks", failures)
_expect(driver.get_simulation_step_count() == 3, "60 Hz must divide to exactly 30 Hz", failures)
_expect(world.get_next_tick() == 3, "driver must advance sequential simulation ticks", failures)
```

- [ ] **Step 2: 运行验证，确认 driver 缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
```

Expected: 非零退出，`LocalFrameSyncDriver` 预加载失败。

- [ ] **Step 3: 实现不可跳 Tick 的两相位驱动**

构造时断言 `Engine.physics_ticks_per_second == 60`，否则记录可读错误并拒绝推进。每个物理 callback 增加计数；奇数 callback 只返回 false；偶数 callback 从 collector 收集 `world.get_next_tick()`、提交 buffer，再 `take()` 并 step。Collector 或 buffer 拒绝时不调用 world：

```gdscript
func advance_physics_callback() -> bool:
	_physics_callback_count += 1
	if (_physics_callback_count & 1) != 0:
		return false
	var tick := _world.get_next_tick()
	var frame := _collector.collect(tick)
	if not _buffer.submit(frame) or not _buffer.has_complete_frame(tick):
		return _fail("complete local frame unavailable")
	var accepted := _world.step(tick, _buffer.take(tick))
	if accepted:
		_simulation_step_count += 1
		simulation_advanced.emit(tick, StateHasher.hash_canonical(_world.encode_canonical_state()))
	return accepted
```

`_physics_process(_delta)` 只能调用 `advance_physics_callback()`；不得把 `_delta` 存入或传给模拟。

- [ ] **Step 4: 验证相位边界、命令提交失败和 headless 导入**

验证第一次 callback 不采样输入；验证第八次 callback 后 step 数为 4；令一个 active slot 源为 null 使 collect 失败，断言 world tick 不变且 driver 有错误。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两条命令均退出 0。

- [ ] **Step 5: 提交临时检查点**

```bash
git add scripts/simulation/driver/local_frame_sync_driver.gd tools/validation/validate_local_frame_sync_core.gd
git commit -m "feat: add local 30hz frame-sync driver"
```

### Task 9: 建立首分歧工具并执行 Plan 1 的 100,000 Tick 门槛

**Files:**
- Create: `scripts/simulation/testing/first_divergence_harness.gd`
- Create: `scripts/simulation/testing/determinism_test_runner.gd`
- Modify: `tools/validation/validate_local_frame_sync_core.gd`

**Interfaces:**
- Consumes: `LocalSimulationSession`、`SimulationWorld`、`LocalFrameCommandSet`、`LocalFrameCommandCodec`、`InputTape`、`StateHasher`。
- Produces: `FirstDivergenceHarness.new(session: LocalSimulationSession)`、`run(tape: InputTape, tick_limit: int) -> Dictionary`，结果成功时为 `{ "ok": true, "ticks_checked": int }`，失败时为 `{ "ok": false, "tick": int, "frame_hex": String, "direct_hash": String, "codec_hash": String, "direct_state_hex": String, "codec_state_hex": String }`；`determinism_test_runner.gd` 在通过时打印 `determinism_test_runner: PASS 100000 ticks` 并 `quit(0)`。

- [ ] **Step 1: 写直接路径/codec 路径与故意分歧的失败验证**

生成覆盖 1、2、3、4 人连续掩码的短 InputTape：命令使用固定 Park–Miller 流选择 heading、三个 action bit、`-1/0/1` equipment delta 和 placement heading。首先调用尚不存在的 harness，断言 200 Tick 正常结果 `ok`；然后给第二世界的第 17 帧替换一个合法命令，断言它报告 `tick == 17` 且六个诊断字符串均非空：

```gdscript
var result := harness.run(tape, 200)
_expect(result.ok and result.ticks_checked == 200, "direct and codec paths must agree", failures)
var divergent := harness.run_with_frame_mutator(tape, 200, _change_tick_17)
_expect(not divergent.ok and divergent.tick == 17, "harness must stop at first divergence", failures)
```

- [ ] **Step 2: 运行验证，确认 harness 与 runner 缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://scripts/simulation/testing/determinism_test_runner.gd
```

Expected: 两条命令均非零退出；第二条因为 runner 文件不存在而失败。

- [ ] **Step 3: 实现双世界逐 Tick 首分歧 harness**

每个 run 新建两个相同 session/world。直接世界接收 `tape.get_frame(tick)`；codec 世界每 Tick 必须经过 `encode()` 与 `decode()` 后才 step。两边 world.step 失败也立即返回失败；Hash 不等时采集双方同一 tick 的 22 bytes frame hex、Hash hex 和 canonical state hex，绝不继续检查后续 tick：

```gdscript
for tick in range(tick_limit):
	var direct_frame := tape.get_frame(tick)
	var codec_bytes := LocalFrameCommandCodec.encode(direct_frame)
	var codec_frame := LocalFrameCommandCodec.decode(codec_bytes)
	if not direct_world.step(tick, direct_frame) or not codec_world.step(tick, codec_frame):
		return _failure(tick, codec_bytes, direct_world, codec_world)
	var direct_hash := StateHasher.hash_canonical(direct_world.encode_canonical_state())
	var codec_hash := StateHasher.hash_canonical(codec_world.encode_canonical_state())
	if not StateHasher.equal(direct_hash, codec_hash):
		return _failure(tick, codec_bytes, direct_world, codec_world)
return {"ok": true, "ticks_checked": tick_limit}
```

- [ ] **Step 4: 实现固定输入带生成和 100,000 Tick runner**

runner 为每个 mask `1`、`3`、`7`、`15` 各生成 100,000 Tick；每个 slot 从独立、预先指定 seed 的 Park–Miller 流生成合法命令，未启用 slot 固定 `neutral()`。每一带先 `InputTape.encode()`、`decode()` 并用恢复带送入 harness。任一带失败打印字典并 `quit(1)`；所有带通过才 `quit(0)`：

```gdscript
for active_player_mask in [0b0001, 0b0011, 0b0111, 0b1111]:
	var tape := _make_tape(active_player_mask, 100000)
	var result := FirstDivergenceHarness.new(tape.get_session()).run(tape, 100000)
	if not result.ok:
		push_error("first divergence: %s" % [result])
		quit(1)
		return
print("determinism_test_runner: PASS 100000 ticks")
quit(0)
```

- [ ] **Step 5: 运行短路径和完整 100,000 Tick 验证**

先运行聚焦脚本，再运行完整 runner 和导入检查：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_simulation_core_primitives.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_commands.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://scripts/simulation/testing/determinism_test_runner.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 五条命令全部退出 0；runner 输出四个连续 mask 的逐 Tick 比对均无首次分歧，并最终输出 `determinism_test_runner: PASS 100000 ticks`。

- [ ] **Step 6: 在门槛失败时停止，门槛通过后提交临时检查点**

若任一命令失败，保存 harness 打印的首分歧字典，停止 Plan 2 至 Plan 8，不将本计划标为完成，也不修改 `DemoArena`。只有五条命令均通过时执行：

```bash
git add scripts/simulation/testing tools/validation/validate_local_frame_sync_core.gd
git commit -m "test: qualify local deterministic frame-sync core"
```

### Task 10: 最终评审、导入检查与单一 squash 提交

**Files:**
- Create: 无。
- Modify: 无。
- Test: `tools/validation/validate_simulation_core_primitives.gd`、`tools/validation/validate_local_frame_commands.gd`、`tools/validation/validate_local_frame_sync_core.gd`、`scripts/simulation/testing/determinism_test_runner.gd`。

**Interfaces:**
- Consumes: 前九个任务的所有公开接口与固定文件边界。
- Produces: 通过 Plan 1 门槛的、可供 Plan 2 仅以 `SimulationManifest`、`LocalFrameCommandSet`、`LocalFrameInputBuffer`、`SimulationWorld.step()`、`InputTape` 和 `StateHasher` 消费的稳定基础。

- [ ] **Step 1: 进行范围审查**

用以下命令确认仅包含计划允许的新路径，确认不存在 `DemoArena`、Physics、Navigation、网络 API 或场景文件变动：

```bash
git diff --name-only HEAD
rg -n "CharacterBody3D|PhysicsServer|NavigationAgent3D|NavigationServer3D|Multiplayer|WebSocket|ENet|DemoArena|_process\(|_physics_process\(" scripts/simulation tools/validation
```

Expected: diff 仅列出本计划文件；搜索结果中仅允许 `LocalFrameSyncDriver._physics_process(_delta)`，其方法体只能调用无参数 `advance_physics_callback()`。

- [ ] **Step 2: 重跑最终失败门槛验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://scripts/simulation/testing/determinism_test_runner.gd
```

Expected: 单人、两人、三人和四人连续掩码各 100,000 Tick 均逐 Tick Hash 相同；退出码 0。若失败，停止后续计划并依据 harness 的 `tick`、`frame_hex`、双方 Hash 与 canonical state hex 修复本计划，再从本步骤重跑。

- [ ] **Step 3: Squash 临时提交为计划提交**

仅在所有验证成功后，将本计划产生的临时提交 squash 为单一 Conventional Commit，提交信息固定为：

```bash
git reset --soft "$(git merge-base HEAD <target-branch>)"
git commit -m "feat: add local deterministic frame-sync core"
```

Expected: 分支历史中的本计划只保留一个 `feat: add local deterministic frame-sync core`；任何未相关的用户改动不纳入暂存区或提交。

## 交付判定

- [ ] `LocalFrameCommandCodec` 对每个合法完整帧产出恰好 22 bytes，并拒绝错误 schema、长度、字段、稀疏掩码和未启用槽位数据。
- [ ] 连续 mask `0b1/0b3/0b7/0b15`、slot 0 至 3、正 ID + generation、Park–Miller、FixedMath 和 SimEvent 排序都由聚焦验证覆盖。
- [ ] `LocalFrameSyncDriver` 仅在每第二个 60 Hz physics callback 从完整帧推进一个 30 Hz Tick，且不会跳 Tick。
- [ ] `InputTape`、规范状态和 Hash 不含 Godot 节点、物理、导航、渲染、音频、摄像机、HUD、对象实例 ID 或网络状态。
- [ ] 直接命令世界与编解码命令世界对 1、2、3、4 人各连续 100,000 Tick 的每 Tick SHA-256 完全一致；一旦发生差异，harness 输出首分歧诊断并停止。
- [ ] 通过门槛前不开始 Plan 2 至 Plan 8，且当前 `DemoArena` 保持未修改的默认可玩路径。
