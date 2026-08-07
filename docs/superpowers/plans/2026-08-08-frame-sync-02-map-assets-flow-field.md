# 帧同步 Plan 2：整数地图资源、碰撞与原子流场 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `DemoArena` 建立可重复离线导出并提交到仓库的整数地图资源，以及不依赖 Godot 物理、运行时 NavMesh 或异步回调的地图碰撞、动态占用、空间哈希和四槽位原子 Flow Field。

**Architecture:** 离线工具只在构建阶段实例化 `DemoArena.tscn`，按冻结的地图源契约读取简化 `BoxShape3D` 碰撞，先量化为模拟整数，再生成 row-major 阻挡位图和规范 SHA-256；运行时只加载并校验已提交的 `demo_arena_map.tres`。`SimMapGrid` 组合不可变静态阻挡与按 Tick 排序提交的动态 owner 占用，提供固定先 X 后 Z 的整数圆形投影；`SimFlowFieldSet` 在动态 revision 或目标格变化时同步构建候选场，并在全部候选成功后一次换入；`SimSpatialHash` 用固定容量数组给 Plan 4 提供稳定 ID 升序邻居。

**Tech Stack:** Godot 4.7.1、GDScript、`Resource` / `.tres`、`PackedByteArray`、`PackedInt32Array`、Plan 1 的 `LittleEndianWriter` / `StateHasher` / `SimulationWorld` / `FirstDivergenceHarness`、headless Godot 验证脚本。

## Global Constraints

- 唯一规格来源是 `docs/superpowers/specs/2026-08-08-local-deterministic-frame-sync-design.md`；本计划、Plan 1、Plan 4 或旧代码发生冲突时，以该规格为准。
- 开始本计划前，Plan 1 必须已通过直接命令路径与编解码命令路径连续 100,000 Tick 的逐 Tick Hash 门槛；未通过时停止实施本计划。
- 本计划不增加服务器、WS、ENet、WebRTC、RPC、MultiplayerSynchronizer、Transport 抽象、网络输入延迟、预测或回滚；第一阶段仍是 input delay 0 的纯本地模拟。
- 1 Godot 世界单位固定等于 1024 模拟单位；`DemoArena` 地图格固定为 512 模拟单位，即 0.5 Godot 单位。
- 提交的地图资源固定为 `resources/simulation/maps/demo_arena_map.tres`；运行时不得从场景节点、`navigation_source`、碰撞体、Jolt、`NavigationAgent3D`、`NavigationServer3D` 或运行时 NavMesh 重新生成地图。
- 地图资源的所有玩法字段只能是整数、`StringName`、`PackedByteArray` 或 `PackedInt32Array`；不得把 `Vector2`、`Vector3`、`Transform3D`、浮点形状参数、RID、NodePath 或 instance ID 写入运行时资源。
- `content_hash: PackedByteArray` 是地图 Hash 的唯一字段名；它固定为 32 bytes SHA-256，输入是 `SimMapAssetCodec.encode_hash_payload(asset)` 的规范 little-endian 字节，不使用 `.tres` 文本字节、Variant 或 Dictionary 序列化。
- Plan 1 的 canonical section 顺序是冻结协议；Plan 2 只能替换/实现 `SimulationWorld._encode_dynamic_map_section(writer)`，其位置始终在 player、zombie、other entity section 之后且在 PRNG section 之前。不得在 canonical 末尾追加地图字节、插入新顶层 section 或改写其他 section 金样。
- Plan 2 的测试会话把 `SimulationManifest.map_id` 设为 `demo_arena`、把当前 `config_hash` 设为地图 `content_hash`；后续整数 `SimConfig` 出现后由对应计划显式组合地图与玩法配置 Hash，不改变本计划地图 Hash 字段或编码。
- 地图坐标固定为平坦 XZ：原点 `(-24832, -19712)` 模拟单位、宽 97 格、高 77 格、row-major `cell_id = cell_z * width + cell_x`；范围外视为阻挡。
- 离线源固定为 `res://scenes/gameplay/DemoArena.tscn` 中同时属于 `navigation_source` 与 `place_item_obstacle`、且不属于 `sim_dynamic_obstacle` 的启用 `BoxShape3D`；任何其他静态形状使导出失败，不得静默忽略。
- 离线工具不得读取 MeshInstance3D、GLTF 模型三角面、视觉 AABB 或材质；只允许读取上述简化碰撞盒。
- `ExplosiveBarrel.tscn` 与 `PickupChest.tscn` 只增加 `sim_dynamic_obstacle` 元数据组；旧 `DemoArena`、旧 `PlaceItemGrid`、旧运行时导航和现有主场景默认入口保持可玩且仍为默认路径。
- 动态占用变化只在指定 Tick 的 `SimulationWorld.step()` 阶段 3 提交；同 Tick 按 `(source_entity_id, local_sequence, owner_entity_id)` 升序处理，冲突时排序靠前者获得格子。
- `dynamic_owner_capacity` 只接受 `1..32767`；pending 缓冲固定为其两倍，因此 `pending_change_count:u16` 永远可完整编码。
- 动态地图重置必须携带 `last_completed_tick >= -1`：初局传 `-1`，高 Tick 重开传重开前最后完成的 Tick；重置后下一次合法提交固定为 `last_completed_tick + 1`，并把全部 Flow Field 标 dirty。
- Flow Field 在阶段 4 同步、原子重建，不创建线程、不 `await`、不依赖异步回调；构建失败保留旧完整场，不暴露半构建数组。
- 本计划只实现 DemoArena 全场同步重建；不加入增量场、每 Tick 单元预算或后台构建。未来大地图若需要增量方案，必须另行冻结按 cell_id 顺序和固定预算的协议。
- Flow Field 使用固定 8 邻居、直移成本 10、斜移成本 14；斜移必须同时满足两个相邻正交格可通行；堆键与等价路径 Tie-break 都按 `(cost, cell_id)`。
- 碰撞、流场、空间哈希和规范状态编码不得依赖 Dictionary 遍历顺序、浮点数学、`sin`、`cos`、`atan2`、`sqrt` 或整数溢出。
- Plan 2 自有运行时代码 `scripts/simulation/map/` 中，所有整数商都必须调用 Plan 1 `FixedMath.floor_div(value: int, positive_divisor: int) -> int`；包括 bitset 字节数、cell row、cell center 半格、二分中点、最小堆 parent、桶行列和 Flow Field row。Plan 2 运行时代码不得直接使用 `/`；Plan 1 的 `scripts/simulation/core/fixed_math.gd` 是确定性核心中唯一允许保留原始整数 `/` 的文件，此外只有 `tools/map/` 离线导出中的明确浮点换算和纯表现代码可使用 `/`。
- 每个 Task 先写失败验证、确认失败，再写最小实现并运行通过；本计划所有自动验证与 Headless 导入通过前，不允许 Plan 3/4 把这些接口视为稳定接口。
- Headless 导入为每个新增 `.gd` 生成的同路径 `.gd.uid` 必须保留并纳入最终变更，不手写或复用其他脚本的 UID；`.godot/` 仍不得提交。
- 按项目约定，本计划不包含 `git add` 或 `git commit` 步骤；执行 agent 不运行提交命令，全部计划完成后由用户自行检查并提交。

---

## 文件结构与稳定边界

| 路径 | 职责 |
| --- | --- |
| `scripts/simulation/map/sim_map_asset.gd` | 只含整数的已导出地图资源、尺寸校验、静态 bitset 与唯一 `content_hash`。 |
| `scripts/simulation/map/sim_map_asset_codec.gd` | 地图规范 little-endian Hash payload、Hash 计算和资源自校验。 |
| `scripts/simulation/map/sim_dynamic_occupancy_change.gd` | 指定 Tick 的 CLAIM/RELEASE 变化与稳定排序键。 |
| `scripts/simulation/map/sim_map_grid.gd` | 静态阻挡、动态 owner、变化缓冲、地图查询与固定 X 后 Z 碰撞。 |
| `scripts/simulation/map/sim_flow_field.gd` | 单目标反向距离场、确定性最小堆、下一格与规范编码。 |
| `scripts/simulation/map/sim_flow_field_set.gd` | 四槽位目标、dirty 标记、同步候选构建和原子换入。 |
| `scripts/simulation/map/sim_spatial_hash.gd` | 固定容量桶、实体插入和 3×3 邻桶稳定查询。 |
| `tools/map/demo_arena_map_export_contract.gd` | DemoArena 场景、整数边界、源组和动态排除组的离线契约。 |
| `tools/map/demo_arena_map_exporter.gd` | 可由 CLI 与验证共同调用的场景扫描、整数 SAT 和资源构建库。 |
| `tools/map/export_demo_arena_sim_map.gd` | 扫描简化碰撞、整数 SAT 栅格化、生成 `.tres` 并打印 Hash。 |
| `resources/simulation/maps/demo_arena_map.tres` | 仓库提交的 DemoArena 整数地图位图与 32-byte `content_hash`。 |
| `scenes/props/ExplosiveBarrel.tscn` | 增加 `sim_dynamic_obstacle` 组，避免油桶被烘焙成静态格。 |
| `scenes/gameplay/PickupChest.tscn` | 增加 `sim_dynamic_obstacle` 组，避免拾取箱被烘焙成静态格。 |
| `tools/validation/validate_frame_sync_map_asset.gd` | 导出契约、资源字段、重复导出、Hash 和关键格金样验证。 |
| `tools/validation/validate_frame_sync_map_grid.gd` | 动态占用顺序、冲突、释放、边界和整数碰撞验证。 |
| `tools/validation/validate_frame_sync_flow_field.gd` | Flow Field、原子失败、固定邻居、空间哈希稳定性验证。 |
| `tools/validation/validate_frame_sync_map_integer_division.gd` | 去除字符串与注释后扫描 Plan 2 运行时源码，拒绝裸 `/` 运算符。 |
| `tools/validation/validate_frame_sync_map_replay.gd` | 100,000 Tick 直接/codec 双世界地图回放门槛。 |
| `scripts/simulation/world/simulation_world.gd` | 保持 Plan 1 构造、step 与 canonical 顶层顺序，增加地图配置、阶段 3/4、reset wrapper 和冻结 dynamic-map section 实现。 |
| `scripts/simulation/testing/first_divergence_harness.gd` | 增加地图双实例回放和首个地图状态差异报告。 |

## 对后续计划冻结的公开接口

```gdscript
# scripts/simulation/map/sim_map_asset.gd
class_name SimMapAsset
var map_id: StringName
var units_per_world: int
var cell_size_units: int
var origin_x_units: int
var origin_z_units: int
var width: int
var height: int
var static_blocked_bits: PackedByteArray
var content_hash: PackedByteArray
func cell_count() -> int
func is_hash_payload_valid() -> bool
func is_valid() -> bool
func get_content_hash() -> PackedByteArray

# scripts/simulation/map/sim_dynamic_occupancy_change.gd
enum Operation { CLAIM, RELEASE }
func _init(
	tick: int,
	source_entity_id: int,
	local_sequence: int,
	owner_entity_id: int,
	operation: int,
	cell_ids: PackedInt32Array
) -> void
func is_valid(cell_count: int) -> bool

# scripts/simulation/map/sim_map_grid.gd
const NO_BLOCKED_CELL_ID := -1
const OUT_OF_BOUNDS_CELL_ID := -2
func _init(asset: SimMapAsset, dynamic_owner_capacity: int = 256) -> void
func world_to_cell_id(x: int, z: int) -> int
func cell_id_to_center(cell_id: int) -> Vector2i
func is_static_blocked(cell_id: int) -> bool
func is_dynamic_blocked(cell_id: int) -> bool
func is_cell_blocked(cell_id: int) -> bool
func dynamic_owner_at(cell_id: int) -> int
func get_cell_size_units() -> int
func get_width() -> int
func get_height() -> int
func queue_dynamic_change(change: SimDynamicOccupancyChange) -> bool
func commit_dynamic_changes(tick: int) -> int
func get_dynamic_revision() -> int
func get_content_hash() -> PackedByteArray
func reset_dynamic_occupancy(last_completed_tick: int) -> void
func has_clear_line(
	ax: int, az: int, bx: int, bz: int,
	ignore_owner_a: int = 0,
	ignore_owner_b: int = 0
) -> bool
func first_blocked_cell_on_line(
	ax: int, az: int, bx: int, bz: int,
	ignore_owner_a: int = 0,
	ignore_owner_b: int = 0
) -> int
func move_circle_x_then_z(
	x: int, z: int, radius: int, delta_x: int, delta_z: int
) -> Vector2i
func encode_canonical_dynamic(writer: LittleEndianWriter) -> void

# scripts/simulation/map/sim_flow_field.gd
static func build_empty(
	map_grid: SimMapGrid, target_cell: int, generation: int
) -> SimFlowField
static func build_candidate(
	map_grid: SimMapGrid, target_cell: int, generation: int
) -> SimFlowField
func is_reachable(x: int, z: int) -> bool
func next_step(x: int, z: int) -> Vector2i
func target_cell_id() -> int
func generation() -> int
func encode_canonical(writer: LittleEndianWriter) -> void

# scripts/simulation/map/sim_flow_field_set.gd
func _init(map_grid: SimMapGrid, slot_count: int = 4) -> void
func set_target_cell(slot: int, cell_id: int) -> bool
func clear_target(slot: int) -> bool
func mark_all_dirty() -> void
func is_dirty(slot: int) -> bool
func rebuild_dirty_atomic(map_grid: SimMapGrid) -> bool
func field_for_slot(slot: int) -> SimFlowField
func encode_canonical(writer: LittleEndianWriter) -> void
func get_last_error() -> String

# scripts/simulation/map/sim_spatial_hash.gd
func _init(
	map_asset: SimMapAsset,
	bucket_size_units: int,
	max_entities: int
) -> void
func clear() -> void
func insert(entity_id: int, x: int, z: int) -> bool
func query_3x3_sorted(x: int, z: int) -> int
func query_count() -> int
func query_entity_id(index: int) -> int

# scripts/simulation/world/simulation_world.gd
# 保持：SimulationWorld.new(session)
# 保持：step(tick: int, frame: LocalFrameCommandSet) -> bool
func configure_map(
	map_asset: SimMapAsset,
	dynamic_owner_capacity: int = 256
) -> bool
func queue_map_change(change: SimDynamicOccupancyChange) -> bool
func get_map_grid() -> SimMapGrid
func get_flow_fields() -> SimFlowFieldSet
func reset_dynamic_occupancy(last_completed_tick: int) -> void
func mark_all_flow_fields_dirty() -> void
```

`SimFlowField.next_step()` 返回当前格到下一格的 `Vector2i` cell offset，每个分量只能是 `-1`、`0` 或 `1`；不可达、目标格或范围外返回 `Vector2i.ZERO`。Plan 4 必须把该 offset 通过 Plan 1 的整数方向表换算速度，不能把对角两个分量各自当成完整速度。

### Task 1：冻结离线地图契约并生成可重复 Hash 的 DemoArena 资源

**Files:**

- Create: `scripts/simulation/map/sim_map_asset.gd`
- Create: `scripts/simulation/map/sim_map_asset_codec.gd`
- Create: `tools/map/demo_arena_map_export_contract.gd`
- Create: `tools/map/demo_arena_map_exporter.gd`
- Create: `tools/map/export_demo_arena_sim_map.gd`
- Create: `tools/validation/validate_frame_sync_map_asset.gd`
- Create: `tools/validation/validate_frame_sync_map_integer_division.gd`
- Create: `resources/simulation/maps/demo_arena_map.tres`
- Generate on import: `scripts/simulation/map/sim_map_asset.gd.uid`
- Generate on import: `scripts/simulation/map/sim_map_asset_codec.gd.uid`
- Generate on import: `tools/map/demo_arena_map_export_contract.gd.uid`
- Generate on import: `tools/map/demo_arena_map_exporter.gd.uid`
- Generate on import: `tools/map/export_demo_arena_sim_map.gd.uid`
- Generate on import: `tools/validation/validate_frame_sync_map_asset.gd.uid`
- Generate on import: `tools/validation/validate_frame_sync_map_integer_division.gd.uid`
- Modify: `scenes/props/ExplosiveBarrel.tscn`
- Modify: `scenes/gameplay/PickupChest.tscn`

**Interfaces:**

- Consumes: Plan 1 的 `FixedMath.floor_div()`、`LittleEndianWriter`、`StateHasher.hash_canonical(bytes) -> PackedByteArray`，现有 `DemoArena.tscn`、`navigation_source` 与 `place_item_obstacle` 分组。
- Produces: `SimMapAsset` 的冻结字段与方法；`SimMapAssetCodec.encode_hash_payload(asset) -> PackedByteArray`、`compute_content_hash(asset) -> PackedByteArray`、`validate_content_hash(asset) -> bool`；`DemoArenaMapExporter.build_asset(scene_tree: SceneTree) -> SimMapAsset`、`save_asset(scene_tree: SceneTree, output_path: String) -> Error`；`validate_frame_sync_map_integer_division.gd` 的源码扫描入口；已提交的 `res://resources/simulation/maps/demo_arena_map.tres`。

- [ ] **Step 1：写缺少资源类型时必然失败的地图验证**

创建 `validate_frame_sync_map_asset.gd`，预加载尚不存在的类型和资源，固定整数尺寸与关键格语义：

```gdscript
extends SceneTree

const SimMapAsset = preload("res://scripts/simulation/map/sim_map_asset.gd")
const SimMapAssetCodec = preload("res://scripts/simulation/map/sim_map_asset_codec.gd")
const MAP_PATH := "res://resources/simulation/maps/demo_arena_map.tres"

func _init() -> void:
	var failures: Array[String] = []
	var asset := load(MAP_PATH) as SimMapAsset
	_expect(asset != null, "committed DemoArena map must load", failures)
	_expect(asset.map_id == &"demo_arena", "map id must be stable", failures)
	_expect(asset.units_per_world == 1024, "unit scale must be 1024", failures)
	_expect(asset.cell_size_units == 512, "cell size must be 512", failures)
	_expect(asset.origin_x_units == -24832 and asset.origin_z_units == -19712, "origin must match export contract", failures)
	_expect(asset.width == 97 and asset.height == 77, "grid dimensions must be 97x77", failures)
_expect(asset.static_blocked_bits.size() == 934, "7469 cells require 934 bytes", failures)
_expect(asset.content_hash.size() == 32, "content_hash must be SHA-256", failures)
_expect(SimMapAssetCodec.validate_content_hash(asset), "committed map hash must validate", failures)
var invalid_trailing_bits := asset.duplicate(true) as SimMapAsset
var changed_bits := invalid_trailing_bits.static_blocked_bits.duplicate()
changed_bits[changed_bits.size() - 1] = changed_bits[changed_bits.size() - 1] | 0x80
invalid_trailing_bits.static_blocked_bits = changed_bits
_expect(not invalid_trailing_bits.is_hash_payload_valid(), "unused trailing bits must be zero", failures)
_finish(failures)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_frame_sync_map_asset: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
```

- [ ] **Step 2：运行验证，确认因类型或资源缺失而失败**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_asset.gd
```

Expected: 非零退出，错误明确指向 `sim_map_asset.gd`、`sim_map_asset_codec.gd` 或 `demo_arena_map.tres` 不存在；验证不得改成缺失时跳过。

- [ ] **Step 3：实现只含整数的 `SimMapAsset` 与规范 Hash payload**

资源验证必须检查 bit 数、32-byte Hash、正尺寸和 int32 坐标；getter 返回 Hash 副本，避免调用方改写资源：

```gdscript
extends Resource
class_name SimMapAsset

const FixedMath = preload("res://scripts/simulation/core/fixed_math.gd")

@export var map_id: StringName = &""
@export var units_per_world := 0
@export var cell_size_units := 0
@export var origin_x_units := 0
@export var origin_z_units := 0
@export var width := 0
@export var height := 0
@export var static_blocked_bits := PackedByteArray()
@export var content_hash := PackedByteArray()

func cell_count() -> int:
	return width * height

func is_hash_payload_valid() -> bool:
	var map_id_size := String(map_id).to_utf8_buffer().size()
	if map_id_size < 1 or map_id_size > 255 \
	or units_per_world != 1024 \
	or cell_size_units <= 0 or cell_size_units > 65535 \
	or origin_x_units < -2147483648 or origin_x_units > 2147483647 \
	or origin_z_units < -2147483648 or origin_z_units > 2147483647 \
	or width <= 0 or width > 65535 \
	or height <= 0 or height > 65535:
		return false
	var count := cell_count()
	if count > 4294967295 \
	or static_blocked_bits.size() > 65535 \
	or static_blocked_bits.size() != FixedMath.floor_div(count + 7, 8):
		return false
	var used_bits_in_last_byte := count & 7
	if used_bits_in_last_byte == 0:
		return true
	var unused_mask := 0xff ^ ((1 << used_bits_in_last_byte) - 1)
	return (static_blocked_bits[static_blocked_bits.size() - 1] & unused_mask) == 0

func is_valid() -> bool:
	return is_hash_payload_valid() and content_hash.size() == 32

func get_content_hash() -> PackedByteArray:
	return content_hash.duplicate()
```

Hash payload 固定为：ASCII `SMAP`、schema `u16=1`、UTF-8 map ID 长度 `u8` 与 bytes、`units_per_world:u16`、`cell_size_units:u16`、`origin_x:i32`、`origin_z:i32`、`width:u16`、`height:u16`、`cell_count:u32`、bitset 长度 `u16` 与 bitset。`content_hash` 本身不得写入 payload：

```gdscript
static func compute_content_hash(asset: SimMapAsset) -> PackedByteArray:
	assert(asset != null and asset.is_hash_payload_valid())
	return StateHasher.hash_canonical(encode_hash_payload(asset))

static func validate_content_hash(asset: SimMapAsset) -> bool:
	return asset.is_valid() and StateHasher.equal(
		compute_content_hash(asset), asset.content_hash
	)
```

- [ ] **Step 4：实现冻结的 DemoArena 导出契约和整数栅格化**

导出契约不得从 `NavigationChunk3D` 读取运行时状态：

```gdscript
extends RefCounted
class_name DemoArenaMapExportContract

const SOURCE_SCENE := "res://scenes/gameplay/DemoArena.tscn"
const OUTPUT_RESOURCE := "res://resources/simulation/maps/demo_arena_map.tres"
const MAP_ID := &"demo_arena"
const UNITS_PER_WORLD := 1024
const CELL_SIZE_UNITS := 512
const ORIGIN_X_UNITS := -24832
const ORIGIN_Z_UNITS := -19712
const WIDTH := 97
const HEIGHT := 77
const SOURCE_GROUP := &"navigation_source"
const OBSTACLE_GROUP := &"place_item_obstacle"
const DYNAMIC_GROUP := &"sim_dynamic_obstacle"
```

`demo_arena_map_exporter.gd` 继承 `RefCounted` 并提供可测试的构建库；CLI 脚本继承 `SceneTree`，在 `_init()` 中调用 `call_deferred("_run")`，把自身传给 exporter，保存后按 Error 决定退出码。导出器把场景实例加入 `scene_tree.root`，按绝对 `NodePath` 排序碰撞源；只接受启用 `BoxShape3D`。把盒子四个 XZ 角先经 `global_transform` 变换，再用 `roundi(world * 1024.0)` 量化。每个候选格使用整数 SAT 测试世界 X、世界 Z 与盒子两条边的法线；任一轴投影严格分离才不阻挡，接触视为阻挡。`build_asset()` 在读取完成后同步 `instance.free()`，保证同一验证进程可连续导出两次：

```gdscript
func _overlaps_cell(box: PackedInt32Array, min_x: int, min_z: int, max_x: int, max_z: int) -> bool:
	var cell := PackedInt32Array([min_x, min_z, max_x, min_z, max_x, max_z, min_x, max_z])
	var edge0 := Vector2i(box[2] - box[0], box[3] - box[1])
	var edge1 := Vector2i(box[6] - box[0], box[7] - box[1])
	var axes := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-edge0.y, edge0.x), Vector2i(-edge1.y, edge1.x)]
	for axis in axes:
		var box_projection := _project(box, axis)
		var cell_projection := _project(cell, axis)
		if box_projection.y < cell_projection.x or cell_projection.y < box_projection.x:
			return false
	return true

func _project(points: PackedInt32Array, axis: Vector2i) -> Vector2i:
	var minimum := points[0] * axis.x + points[1] * axis.y
	var maximum := minimum
	for index in range(2, points.size(), 2):
		var value := points[index] * axis.x + points[index + 1] * axis.y
		minimum = mini(minimum, value)
		maximum = maxi(maximum, value)
	return Vector2i(minimum, maximum)
```

遍历格固定先 `cell_z` 后 `cell_x`，bit 固定为 `byte_index = cell_id >> 3`、`bit_index = cell_id & 7`。发现符合源组但形状不是 `BoxShape3D`、形状禁用状态不一致、资源保存失败或 Hash 回读不一致时 `quit(1)`。

创建整数除法源码验证器，Task 1 初始只扫描 `sim_map_asset.gd` 与 `sim_map_asset_codec.gd`。它逐行去掉 `#` 注释和单双引号字符串后，剩余源码出现 `/` 即失败；运行时文件禁止三引号字符串，以免隐藏运算符。核心检查固定如下：

```gdscript
const RUNTIME_PATHS := PackedStringArray([
	"res://scripts/simulation/map/sim_map_asset.gd",
	"res://scripts/simulation/map/sim_map_asset_codec.gd",
])

func _code_without_strings_or_comment(line: String) -> String:
	var result := ""
	var quote := ""
	var escaped := false
	for index in range(line.length()):
		var character := line.substr(index, 1)
		if not quote.is_empty():
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == quote:
				quote = ""
			continue
		if character == "#":
			break
		if character == "\"" or character == "'":
			quote = character
			continue
		result += character
	return result

func _init() -> void:
	var failures := PackedStringArray()
	for path in RUNTIME_PATHS:
		if not FileAccess.file_exists(path):
			failures.append("missing runtime source: %s" % path)
			continue
		var source := FileAccess.get_file_as_string(path)
		if source.contains("\"\"\"") or source.contains("'''"):
			failures.append("triple-quoted string is forbidden in scanned source: %s" % path)
			continue
		var lines := source.split("\n")
		for line_index in range(lines.size()):
			if _code_without_strings_or_comment(lines[line_index]).contains("/"):
				failures.append("raw division operator: %s:%d" % [path, line_index + 1])
	if failures.is_empty():
		print("validate_frame_sync_map_integer_division: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
```

验证器对每个不存在的路径、源码中的三引号字符串、或清理后仍含 `/` 的行追加失败，并打印准确路径与 1-based 行号。

- [ ] **Step 5：标记动态源并首次生成提交资源**

只修改两个根节点的 groups，保留原有组：

```text
ExplosiveBarrel groups=["navigation_source", "place_item_obstacle", "sim_dynamic_obstacle"]
PickupChest groups=["navigation_source", "place_item_obstacle", "sim_dynamic_obstacle"]
```

运行导出：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/map/export_demo_arena_sim_map.gd
```

Expected: 退出码 0，打印 `demo_arena cells=7469 hash=<64 lowercase hex>`，生成的 `.tres` 仅含冻结字段；油桶 `(-14, -3.5)` 与拾取箱源不进入静态位图。

- [ ] **Step 6：补全关键格与重复导出断言**

在验证脚本定义本地 `_is_static_blocked_at(asset, x_units, z_units)`，使用 `FixedMath.floor_div`、row-major cell ID 和 bit 运算直接查询资源；断言边界 `(-24576, 0)` 阻挡、中心 `(0, 0)` 可通行、Flow Field 测试目标 `(8192, 0)` 可通行、集装箱 `(-11264, -11059)` 阻挡、动态油桶中心 `(-14336, -3584)` 静态可通行：

```gdscript
func _is_static_blocked_at(asset: SimMapAsset, x_units: int, z_units: int) -> bool:
	var cell_x := FixedMath.floor_div(x_units - asset.origin_x_units, asset.cell_size_units)
	var cell_z := FixedMath.floor_div(z_units - asset.origin_z_units, asset.cell_size_units)
	if cell_x < 0 or cell_x >= asset.width or cell_z < 0 or cell_z >= asset.height:
		return true
	var cell_id := cell_z * asset.width + cell_x
	return (asset.static_blocked_bits[cell_id >> 3] & (1 << (cell_id & 7))) != 0
```

再调用导出器的 `build_asset() -> SimMapAsset` 两次，断言 payload、bitset、Hash 相同，并与已提交资源相同：

```gdscript
var exporter := DemoArenaMapExporter.new()
var first := exporter.build_asset(self)
var second := exporter.build_asset(self)
_expect(
	SimMapAssetCodec.encode_hash_payload(first) == SimMapAssetCodec.encode_hash_payload(second),
	"two offline exports must produce identical canonical bytes",
	failures
)
_expect(first.content_hash == second.content_hash, "two exports must produce identical hash", failures)
_expect(first.content_hash == committed.content_hash, "committed resource must match exporter", failures)
```

- [ ] **Step 7：运行资源门槛和 Headless 导入检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_asset.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 前两条分别输出 `validate_frame_sync_map_asset: PASS` 与 `validate_frame_sync_map_integer_division: PASS`；导入退出 0；重复导出没有改变 `resources/simulation/maps/demo_arena_map.tres` 的玩法字段或 `content_hash`。

### Task 2：实现动态占用、整数 supercover 与固定 X 后 Z 地图碰撞

**Files:**

- Create: `scripts/simulation/map/sim_dynamic_occupancy_change.gd`
- Create: `scripts/simulation/map/sim_map_grid.gd`
- Create: `tools/validation/validate_frame_sync_map_grid.gd`
- Generate on import: `scripts/simulation/map/sim_dynamic_occupancy_change.gd.uid`
- Generate on import: `scripts/simulation/map/sim_map_grid.gd.uid`
- Generate on import: `tools/validation/validate_frame_sync_map_grid.gd.uid`
- Modify: `tools/validation/validate_frame_sync_map_integer_division.gd`

**Interfaces:**

- Consumes: Task 1 的 `SimMapAsset`、Plan 1 的 `FixedMath.floor_div()` 与 `LittleEndianWriter`。
- Produces: 冻结接口段中的 `SimDynamicOccupancyChange` 与 `SimMapGrid` 全部方法；动态 revision 仅在至少一个 CLAIM/RELEASE 实际改变 owner 数组时递增一次。

- [ ] **Step 1：写动态顺序、冲突和碰撞的失败验证**

创建 5×5 测试资源，中心静态阻挡；将变化以逆序排入同一 Tick，固定较小排序键获胜：

```gdscript
var grid := SimMapGrid.new(_make_test_asset(), 8)
var target := grid.world_to_cell_id(512, 512)
var late := SimDynamicOccupancyChange.new(0, 20, 0, 200, SimDynamicOccupancyChange.Operation.CLAIM, PackedInt32Array([target]))
var early := SimDynamicOccupancyChange.new(0, 10, 0, 100, SimDynamicOccupancyChange.Operation.CLAIM, PackedInt32Array([target]))
_expect(grid.queue_dynamic_change(late), "late change must queue", failures)
_expect(grid.queue_dynamic_change(early), "early change must queue", failures)
_expect(grid.commit_dynamic_changes(0) == 1, "only one conflicting claim may succeed", failures)
_expect(grid.dynamic_owner_at(target) == 100, "stable lower key must win", failures)
var stopped := grid.move_circle_x_then_z(0, 512, 128, 1024, 0)
_expect(stopped.x < 512, "swept collision must prevent tunneling", failures)
var positive_edge_stop := grid.move_circle_x_then_z(-128, 512, 128, 256, 0)
_expect(positive_edge_stop.x == 127, "positive sweep must stop before endpoint contact", failures)
var negative_edge_stop := grid.move_circle_x_then_z(1024, 512, 128, -128, 0)
_expect(negative_edge_stop.x == 897, "negative sweep must stop after endpoint contact", failures)
var depenetrated := grid.move_circle_x_then_z(512, 512, 128, 0, 0)
_expect(depenetrated == Vector2i(127, 512), "initial overlap must depenetrate toward the stable negative side", failures)
var boundary_stop := grid.move_circle_x_then_z(0, -512, 128, -2048, 0)
_expect(boundary_stop.x == -1151, "map boundary must preserve one-unit separation", failures)

func _make_test_asset() -> SimMapAsset:
	var asset := SimMapAsset.new()
	asset.map_id = &"map_grid_test"
	asset.units_per_world = 1024
	asset.cell_size_units = 512
	asset.origin_x_units = -1280
	asset.origin_z_units = -1280
	asset.width = 5
	asset.height = 5
	asset.static_blocked_bits = PackedByteArray([0, 0, 0, 0])
	var center_id := 2 * asset.width + 2
	asset.static_blocked_bits[center_id >> 3] |= 1 << (center_id & 7)
	asset.content_hash = SimMapAssetCodec.compute_content_hash(asset)
	return asset
```

同时断言范围外阻挡、静态格不能 CLAIM、错误 owner 不能 RELEASE、非升序或重复 `cell_ids` 无效、重复 `(tick, source, local_sequence, owner)` 排序键无效、无碰撞位移精确等于输入 delta。增加水平、垂直、对角和恰过格角的 supercover 断言：`first_blocked_cell_on_line()` 返回遍历遇到的首个静态或动态阻挡 cell ID，无阻挡返回 `NO_BLOCKED_CELL_ID`；`has_clear_line()` 必须等价于前者返回 `NO_BLOCKED_CELL_ID`。静态墙永远阻断；动态 owner 默认阻断；仅当 owner 等于 `ignore_owner_a` 或 `ignore_owner_b` 时忽略；任一端点范围外返回 `OUT_OF_BOUNDS_CELL_ID`，`has_clear_line()` 返回 false。

最后构造高 Tick reset 场景：先保留一个已占用 owner 和一个未来 pending change，记录 revision，然后调用 `reset_dynamic_occupancy(120)`；断言 owner/pending 清空、`get_dynamic_revision() == revision_before + 1`，随后 Tick 121 的 CLAIM 能 queue 且 `commit_dynamic_changes(121) == 1`。另建初局 grid 调用 `reset_dynamic_occupancy(-1)`，断言 Tick 0 可正常提交。

```gdscript
var future := SimDynamicOccupancyChange.new(
	5, 30, 0, 300,
	SimDynamicOccupancyChange.Operation.CLAIM,
	PackedInt32Array([target + 1])
)
_expect(grid.queue_dynamic_change(future), "future change must exist before reset", failures)
var revision_before_reset := grid.get_dynamic_revision()
grid.reset_dynamic_occupancy(120)
_expect(grid.dynamic_owner_at(target) == 0, "reset must clear current owners", failures)
_expect(grid.get_dynamic_revision() == revision_before_reset + 1, "reset must increment revision exactly once", failures)
var after_reset := SimDynamicOccupancyChange.new(
	121, 40, 0, 400,
	SimDynamicOccupancyChange.Operation.CLAIM,
	PackedInt32Array([target])
)
_expect(grid.queue_dynamic_change(after_reset), "next high tick must queue", failures)
_expect(grid.commit_dynamic_changes(121) == 1, "next high tick must commit", failures)
var initial_grid := SimMapGrid.new(_make_test_asset(), 8)
var initial_revision := initial_grid.get_dynamic_revision()
initial_grid.reset_dynamic_occupancy(-1)
_expect(initial_grid.get_dynamic_revision() == initial_revision + 1, "empty initial reset must still increment once", failures)
var tick_zero := SimDynamicOccupancyChange.new(
	0, 1, 0, 1,
	SimDynamicOccupancyChange.Operation.CLAIM,
	PackedInt32Array([target])
)
_expect(initial_grid.queue_dynamic_change(tick_zero), "initial reset must permit tick 0", failures)
_expect(initial_grid.commit_dynamic_changes(0) == 1, "initial reset must commit tick 0", failures)

var ordered_grid := SimMapGrid.new(_make_test_asset(), 8)
var reversed_grid := SimMapGrid.new(_make_test_asset(), 8)
var ordered_tick_2 := SimDynamicOccupancyChange.new(
	2, 7, 0, 701, SimDynamicOccupancyChange.Operation.CLAIM,
	PackedInt32Array([target + 1])
)
var ordered_tick_5 := SimDynamicOccupancyChange.new(
	5, 8, 0, 801, SimDynamicOccupancyChange.Operation.CLAIM,
	PackedInt32Array([target + 2])
)
var reversed_tick_2 := SimDynamicOccupancyChange.new(
	2, 7, 0, 701, SimDynamicOccupancyChange.Operation.CLAIM,
	PackedInt32Array([target + 1])
)
var reversed_tick_5 := SimDynamicOccupancyChange.new(
	5, 8, 0, 801, SimDynamicOccupancyChange.Operation.CLAIM,
	PackedInt32Array([target + 2])
)
_expect(ordered_grid.queue_dynamic_change(ordered_tick_2), "ordered tick 2 must queue", failures)
_expect(ordered_grid.queue_dynamic_change(ordered_tick_5), "ordered tick 5 must queue", failures)
_expect(reversed_grid.queue_dynamic_change(reversed_tick_5), "reversed tick 5 must queue", failures)
_expect(reversed_grid.queue_dynamic_change(reversed_tick_2), "reversed tick 2 must queue", failures)
var ordered_writer := LittleEndianWriter.new()
var reversed_writer := LittleEndianWriter.new()
ordered_grid.encode_canonical_dynamic(ordered_writer)
reversed_grid.encode_canonical_dynamic(reversed_writer)
_expect(ordered_writer.to_bytes() == reversed_writer.to_bytes(), "pending canonical order must ignore queue order", failures)
```

- [ ] **Step 2：运行验证，确认动态类型和网格缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_grid.gd
```

Expected: 非零退出，错误指向 `SimDynamicOccupancyChange` 或 `SimMapGrid` 尚未定义。

- [ ] **Step 3：实现变化验证与稳定排序**

变化只接受 `0..2147483647` 的 Tick、`1..2147483647` 的 source/owner、`0..2147483647` 的 local sequence、已定义 operation，以及 1～65535 个严格升序且不重复的有效 cell ID：

```gdscript
func is_valid(cell_count: int) -> bool:
	if tick < 0 or tick > 2147483647:
		return false
	if source_entity_id <= 0 or source_entity_id > 2147483647 \
	or owner_entity_id <= 0 or owner_entity_id > 2147483647 \
	or local_sequence < 0 or local_sequence > 2147483647:
		return false
	if operation != Operation.CLAIM and operation != Operation.RELEASE:
		return false
	if cell_ids.is_empty() or cell_ids.size() > 65535:
		return false
	var previous := -1
	for cell_id in cell_ids:
		if cell_id <= previous or cell_id < 0 or cell_id >= cell_count:
			return false
		previous = cell_id
	return true
```

`SimMapGrid._init()` 断言 `dynamic_owner_capacity` 位于 `1..32767`，预分配 `PackedInt32Array` owner 数组和最多 `dynamic_owner_capacity * 2` 个待提交变化；queue 后立即使用插入排序维持完整键 `(tick, source_entity_id, local_sequence, owner_entity_id)` 升序，不调用默认对象排序。`_last_committed_tick` 初值为 `-1`，queue 拒绝 `change.tick <= _last_committed_tick`；同一 Tick 的 `(source_entity_id, local_sequence, owner_entity_id)` 键必须唯一，等价于完整排序键不得重复，重复键无论 payload 是否相同都在 queue 阶段拒绝。这样当前 Tick 的提交顺序固定为规格要求的后三项，跨 Tick pending 的 canonical 顺序也不依赖排队顺序。

- [ ] **Step 4：实现同 Tick 原子 CLAIM/RELEASE 规则**

每条变化先完整验证，再整条应用；CLAIM 的任一格是静态格或被其他 owner 占用时整条拒绝，不能部分占用。RELEASE 的每个格都必须正由该 owner 持有，否则整条拒绝。`commit_dynamic_changes(tick)` 只接受 `tick == _last_committed_tick + 1`，只消费 `change.tick == tick`，未来 Tick 继续保留；完成后无论成功变化数是否为零都把 `_last_committed_tick` 设为当前 Tick：

```gdscript
func _try_apply(change: SimDynamicOccupancyChange) -> bool:
	for cell_id in change.cell_ids:
		if change.operation == SimDynamicOccupancyChange.Operation.CLAIM:
			if is_static_blocked(cell_id) or (_dynamic_owner[cell_id] != 0 and _dynamic_owner[cell_id] != change.owner_entity_id):
				return false
		elif _dynamic_owner[cell_id] != change.owner_entity_id:
			return false
	for cell_id in change.cell_ids:
		_dynamic_owner[cell_id] = change.owner_entity_id if change.operation == SimDynamicOccupancyChange.Operation.CLAIM else 0
	return true
```

同 Tick 至少一次实际 owner 改变时 `_dynamic_revision += 1`，同 owner 重复 CLAIM 不递增；`commit_dynamic_changes()` 返回成功变化数。

- [ ] **Step 5：实现 world/cell 映射和范围外阻挡**

禁止使用普通 `/` 处理负坐标：

```gdscript
func world_to_cell_id(x: int, z: int) -> int:
	var cell_x := FixedMath.floor_div(x - _asset.origin_x_units, _asset.cell_size_units)
	var cell_z := FixedMath.floor_div(z - _asset.origin_z_units, _asset.cell_size_units)
	if cell_x < 0 or cell_x >= _asset.width or cell_z < 0 or cell_z >= _asset.height:
		return -1
	return cell_z * _asset.width + cell_x

func is_cell_blocked(cell_id: int) -> bool:
	return cell_id < 0 or cell_id >= _asset.cell_count() \
		or is_static_blocked(cell_id) or is_dynamic_blocked(cell_id)

func get_content_hash() -> PackedByteArray:
	return _asset.get_content_hash()

func get_cell_size_units() -> int:
	return _asset.cell_size_units

func get_width() -> int:
	return _asset.width

func get_height() -> int:
	return _asset.height
```

`cell_id_to_center()` 先计算 `half_cell = FixedMath.floor_div(cell_size_units, 2)`，再返回 `origin + cell * size + half_cell`；非法 ID 返回 `Vector2i(2147483647, 2147483647)`，调用方不得把它当坐标。`reset_dynamic_occupancy(last_completed_tick)` 断言参数不小于 `-1`，清零完整 owner 数组和 pending change 计数，把 `_last_committed_tick` 设为传入值，并且每次调用都让 `_dynamic_revision += 1` 恰好一次，不因当前是否为空而省略。该方法只负责 grid 数据；调用方必须同步标记 Flow Field dirty。

```gdscript
func reset_dynamic_occupancy(last_completed_tick: int) -> void:
	assert(last_completed_tick >= -1)
	_dynamic_owner.fill(0)
	_pending_change_count = 0
	_last_committed_tick = last_completed_tick
	_dynamic_revision += 1
```

把 `sim_dynamic_occupancy_change.gd` 与 `sim_map_grid.gd` 加入整数除法验证器的 `RUNTIME_PATHS`；聚焦验证额外断言 `world_to_cell_id(origin_x - 1, origin_z) == -1` 和 `cell_id_to_center(0)` 使用 floor 语义得到精确半格中心。

- [ ] **Step 6：实现整数 supercover 线遮挡**

`first_blocked_cell_on_line()` 先把两个端点映射到格；任一端点越界返回 `OUT_OF_BOUNDS_CELL_ID`，无阻挡返回 `NO_BLOCKED_CELL_ID`，其余返回首个阻挡 cell ID。遍历采用整数 DDA，比较到下一条 X/Z 格边界的有理参数时用交叉乘法，不做浮点除法；恰好穿过格角时先按较小 cell ID 检查两个正交邻格，再进入对角格，形成 supercover。`has_clear_line()` 只调用首阻挡方法并比较 `== NO_BLOCKED_CELL_ID`，不得维护第二份 DDA：

```gdscript
var start_cell_x := FixedMath.floor_div(ax - _asset.origin_x_units, _asset.cell_size_units)
var start_cell_z := FixedMath.floor_div(az - _asset.origin_z_units, _asset.cell_size_units)
var end_cell_x := FixedMath.floor_div(bx - _asset.origin_x_units, _asset.cell_size_units)
var end_cell_z := FixedMath.floor_div(bz - _asset.origin_z_units, _asset.cell_size_units)

func _line_cell_is_open(cell_id: int, ignore_owner_a: int, ignore_owner_b: int) -> bool:
	if cell_id < 0 or is_static_blocked(cell_id):
		return false
	var owner := dynamic_owner_at(cell_id)
	return owner == 0 or (ignore_owner_a > 0 and owner == ignore_owner_a) \
		or (ignore_owner_b > 0 and owner == ignore_owner_b)

func _compare_crossing(
	next_x_distance: int, abs_dz: int,
	next_z_distance: int, abs_dx: int
) -> int:
	var left := next_x_distance * abs_dz
	var right := next_z_distance * abs_dx
	return -1 if left < right else (1 if left > right else 0)

func has_clear_line(
	ax: int, az: int, bx: int, bz: int,
	ignore_owner_a: int = 0, ignore_owner_b: int = 0
) -> bool:
	return first_blocked_cell_on_line(
		ax, az, bx, bz, ignore_owner_a, ignore_owner_b
	) == NO_BLOCKED_CELL_ID
```

`next_x_distance` / `next_z_distance` 是从起点到下一条格边界的非负模拟单位距离；每跨一个格分别增加 `cell_size_units`。水平或垂直线把另一轴视为永不先到达。起点格、终点格、格角两侧正交格都调用 `_line_cell_is_open()`；静态格不可忽略，两个 ignore 参数只匹配正动态 owner。

- [ ] **Step 7：实现固定先 X 后 Z 的扫掠投影**

每个轴先枚举起点圆与终点圆包围盒之间的全部阻挡格，再用圆心到格 AABB 最近点的距离平方判断真实圆形重叠；不把圆替换成方形，也不调用 `sqrt`：

```gdscript
func move_circle_x_then_z(x: int, z: int, radius: int, delta_x: int, delta_z: int) -> Vector2i:
	assert(radius >= 0)
	var resolved_x := _sweep_axis(x, z, radius, delta_x, true)
	var resolved_z := _sweep_axis(z, resolved_x, radius, delta_z, false)
	return Vector2i(resolved_x, resolved_z)

func _circle_overlaps_cell(cx: int, cz: int, radius: int, cell_id: int) -> bool:
	var bounds := _cell_bounds(cell_id)
	var closest_x := clampi(cx, bounds[0], bounds[2])
	var closest_z := clampi(cz, bounds[1], bounds[3])
	var dx := cx - closest_x
	var dz := cz - closest_z
	return dx * dx + dz * dz <= radius * radius

func _cell_bounds(cell_id: int) -> PackedInt32Array:
	var cell_x := cell_id % _asset.width
	var cell_z := FixedMath.floor_div(cell_id, _asset.width)
	var min_x := _asset.origin_x_units + cell_x * _asset.cell_size_units
	var min_z := _asset.origin_z_units + cell_z * _asset.cell_size_units
	return PackedInt32Array([min_x, min_z, min_x + _asset.cell_size_units, min_z + _asset.cell_size_units])
```

地图范围外是实体障碍，不伪造无限个越界 cell。每次移动先计算圆心合法闭区间：X 为 `[origin_x + radius + 1, origin_x + width * cell_size - radius - 1]`，Z 同理，并断言给定 radius 在两个轴上都存在合法位置。初始圆心越界时先 clamp 到该区间，目标轴坐标也先 clamp，再执行格碰撞扫掠；内部格接触与地图边界接触都保留一个模拟单位间隔。

对每个候选格，轴向重叠区间是连续的。先取 `segment_min = mini(start, end)`、`segment_max = maxi(start, end)`，再令 `probe = clampi(cell_axis_center, segment_min, segment_max)`；只要 `_circle_overlaps_cell()` 在 probe 为 true，probe 就位于移动段与该格连续重叠区间的交集，即使移动终点还没越过格中心也不会漏检。随后从 start 到 probe 做有方向的整数二分，找首个重叠坐标 `hit`：正向令 `low=start`、`high=probe`，循环取 `mid = low + FixedMath.floor_div(high - low, 2)`，命中则 `high=mid`，未命中则 `low=mid+1`，最终 `hit=low`；负向令 `low=probe`、`high=start`，循环取 `mid = low + FixedMath.floor_div(high - low + 1, 2)`，命中则 `low=mid`，未命中则 `high=mid-1`，最终 `hit=low`。不得写 `/ 2`。停止坐标固定为 `hit - signi(delta)`，即正向停在 `hit - 1`、负向停在 `hit + 1`。X sweep 使用当前 Z，Z sweep 使用已解析 X；正向选择所有首次碰撞坐标的最小值，负向选择最大值。

初始位置重叠的处理优先于 `delta == 0`：为每个当前重叠格产生当前轴的两个保守脱离候选 `cell_min - radius - 1` 与 `cell_max + radius + 1`，按“绝对位移、负轴侧优先、cell_id”升序测试；每个候选都重新枚举候选圆 AABB 覆盖的全部阻挡格，取第一个完全不重叠的坐标，若没有可用候选才保留原坐标。初始位置不重叠且 `delta == 0` 才原样返回。上述扫描覆盖中间格，并由正负端点接触和静止初始重叠金样固定边界语义，因此终点尚未到格中心或一次跨过多个格时都不会穿透。

- [ ] **Step 8：编码动态状态并运行网格验证**

规范编码固定写入：schema `u8=1`、cell count `u32`、dynamic revision `u32`、`last_committed_tick:i32`，然后按 cell_id 升序写每格 owner `i32`，再写 `pending_change_count:u16`。尚未提交的变化已按 `(tick, source_entity_id, local_sequence, owner_entity_id)` 排序；每条依次写 `tick:i32`、`source_entity_id:i32`、`local_sequence:i32`、`owner_entity_id:i32`、`operation:u8`、`cell_id_count:u16` 和严格升序的 `cell_id:u32`。诊断字符串、数组容量和未使用槽位不得编码。运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_grid.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 两个验证分别输出 `validate_frame_sync_map_grid: PASS` 与 `validate_frame_sync_map_integer_division: PASS`，导入退出 0；逆序排队、冲突 CLAIM、错误 RELEASE、reset、静态格、负坐标、越界、supercover 格角和高速穿越均通过固定断言。

### Task 3：实现确定性空间哈希与同步原子 Flow Field

**Files:**

- Create: `scripts/simulation/map/sim_flow_field.gd`
- Create: `scripts/simulation/map/sim_flow_field_set.gd`
- Create: `scripts/simulation/map/sim_spatial_hash.gd`
- Create: `tools/validation/validate_frame_sync_flow_field.gd`
- Generate on import: `scripts/simulation/map/sim_flow_field.gd.uid`
- Generate on import: `scripts/simulation/map/sim_flow_field_set.gd.uid`
- Generate on import: `scripts/simulation/map/sim_spatial_hash.gd.uid`
- Generate on import: `tools/validation/validate_frame_sync_flow_field.gd.uid`
- Modify: `tools/validation/validate_frame_sync_map_integer_division.gd`

**Interfaces:**

- Consumes: Task 2 的 `SimMapGrid`、Task 1 的 `SimMapAsset`、Plan 1 的 `LittleEndianWriter`。
- Produces: 冻结接口段中的 `SimFlowField`、`SimFlowFieldSet` 和 `SimSpatialHash`；Flow Field 的持久数组长度恒等于地图 cell count，空间哈希实体容量构造后不得增长。

- [ ] **Step 1：写流场路径、原子失败和空间哈希的失败验证**

构造 7×7 地图，中间 `cell_x = 3` 的竖墙只留 `cell_z = 3` 一个缺口；目标在右侧，起点在左侧。测试资源构造固定如下：

```gdscript
func _make_flow_asset() -> SimMapAsset:
	var asset := SimMapAsset.new()
	asset.map_id = &"flow_test"
	asset.units_per_world = 1024
	asset.cell_size_units = 512
	asset.origin_x_units = 0
	asset.origin_z_units = 0
	asset.width = 7
	asset.height = 7
	asset.static_blocked_bits = PackedByteArray()
	asset.static_blocked_bits.resize(7)
	for cell_z in range(7):
		if cell_z == 3:
			continue
		var cell_id := cell_z * 7 + 3
		asset.static_blocked_bits[cell_id >> 3] |= 1 << (cell_id & 7)
	asset.content_hash = SimMapAssetCodec.compute_content_hash(asset)
	return asset
```

目标与原子失败断言：

```gdscript
var fields := SimFlowFieldSet.new(grid, 4)
var target_cells := PackedInt32Array([
	grid.world_to_cell_id(2560, 1536),
	grid.world_to_cell_id(2560, 1024),
	grid.world_to_cell_id(2560, 2048),
	grid.world_to_cell_id(2048, 1536),
])
for slot in range(4):
	_expect(fields.set_target_cell(slot, target_cells[slot]), "each target must become dirty", failures)
_expect(fields.rebuild_dirty_atomic(grid), "reachable field must build", failures)
var field := fields.field_for_slot(0)
_expect(field.is_reachable(512, 1536), "start must reach target through gap", failures)
_expect(field.next_step(512, 1536) != Vector2i.ZERO, "reachable non-target must have next step", failures)
var old_generations := PackedInt32Array()
old_generations.resize(4)
for slot in range(4):
	old_generations[slot] = fields.field_for_slot(slot).generation()
	_expect(old_generations[slot] == 1, "all four fields must swap in together", failures)
var target_cell := target_cells[0]
var block_target := SimDynamicOccupancyChange.new(
	0, 1, 0, 900,
	SimDynamicOccupancyChange.Operation.CLAIM,
	PackedInt32Array([target_cell])
)
_expect(grid.queue_dynamic_change(block_target), "target blocker must queue", failures)
_expect(grid.commit_dynamic_changes(0) == 1, "target blocker must commit", failures)
fields.mark_all_dirty()
_expect(not fields.rebuild_dirty_atomic(grid), "blocked target must reject rebuild", failures)
for slot in range(4):
	_expect(fields.field_for_slot(slot).generation() == old_generations[slot], "failed rebuild must preserve every old field", failures)
	_expect(fields.is_dirty(slot), "failed rebuild must preserve every dirty flag", failures)
```

空间哈希以实体 ID `30, 10, 20` 的插入顺序构造，查询结果必须为 `10, 20, 30`；第 `max_entities + 1` 次插入失败且数组长度不变。

- [ ] **Step 2：运行验证，确认三个类型均缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_flow_field.gd
```

Expected: 非零退出，最先缺失的 `SimFlowField`、`SimFlowFieldSet` 或 `SimSpatialHash` 被明确报告。

- [ ] **Step 3：实现单场反向 Dijkstra 与固定最小堆**

`SimFlowField.build_empty(map_grid, target_cell, generation)` 创建数组长度等于地图 cell count、`distance_cost` 全为 `2147483647`、`next_cell` 全为 `-1` 的场；仅接受 `target_cell == -1`，否则返回 `null`。`SimFlowField.build_candidate(map_grid, target_cell, next_generation)` 创建同尺寸新数组，再从合法且未阻挡的目标执行反向 Dijkstra。邻居 offset 固定为下列顺序，实际同成本选择仍比较 cell_id：

```gdscript
const NEIGHBOR_X := PackedInt32Array([-1, 0, 1, -1, 1, -1, 0, 1])
const NEIGHBOR_Z := PackedInt32Array([-1, -1, -1, 0, 0, 1, 1, 1])
const NEIGHBOR_COST := PackedInt32Array([14, 10, 14, 10, 10, 14, 10, 14])
```

最小堆使用两个预分配为 `cell_count * 8 + 1` 的 `PackedInt32Array` 保存 cost/cell：`+ 1` 包含目标首次入堆，最多再为每条有向邻接边接受一次更优松弛。比较函数固定先 cost 再 cell。heap parent 必须写成 `FixedMath.floor_div(index - 1, 2)`；不得直接使用 `/ 2`。弹出旧条目时若 `popped_cost != distance_cost[popped_cell]` 直接丢弃；堆容量耗尽使候选构建失败。索引与松弛规则固定如下：

```gdscript
func _heap_parent(index: int) -> int:
	return FixedMath.floor_div(index - 1, 2)

func _cell_z(cell_id: int) -> int:
	return FixedMath.floor_div(cell_id, _width)

var candidate_cost := popped_cost + NEIGHBOR_COST[index]
if candidate_cost < distance_cost[neighbor_id] \
or (candidate_cost == distance_cost[neighbor_id] and popped_cell < next_cell[neighbor_id]):
	distance_cost[neighbor_id] = candidate_cost
	next_cell[neighbor_id] = popped_cell
	_heap_push(candidate_cost, neighbor_id)
```

对角邻居只有在对应 X 正交格与 Z 正交格都不阻挡时有效，禁止切墙角。目标范围外或被阻挡返回失败；可通行但孤立目标构建成功，其他格保持不可达。

- [ ] **Step 4：实现坐标查询与规范编码**

`is_reachable()` 先 world-to-cell，再检查 cost 不是 INF；`next_step()` 以当前和 next cell 的 `(cell_x, cell_z)` 差返回 offset，目标格、非法格、不可达格返回零。单场规范编码固定写 `flow_field_schema:u8=1`、`target_cell_id:i32`、`generation:u32`、`cell_count:u32`，随后按 cell_id 升序写 `distance_cost:i32` 与 `next_cell_id:i32`；不得编码堆的临时内容、构建错误或对象引用。

```gdscript
func next_step(x: int, z: int) -> Vector2i:
	var current := _map_grid.world_to_cell_id(x, z)
	if current < 0 or _next_cell[current] < 0 or _next_cell[current] == current:
		return Vector2i.ZERO
	var next := _next_cell[current]
	return Vector2i(
		next % _width - current % _width,
		FixedMath.floor_div(next, _width) - FixedMath.floor_div(current, _width)
	)
```

- [ ] **Step 5：实现四槽位 dirty 与全体原子换入**

构造函数接收非 null `map_grid`，并断言 `slot_count == 4`；保存该 grid 后，按其 `get_width() * get_height()` 为四个 slot 调用 `SimFlowField.build_empty(map_grid, -1, 0)`，创建 target `-1`、generation `0`、数组长度等于地图 cell count 的合法空场，所以 `field_for_slot()` 始终返回非 null。`set_target_cell()` 仅在目标变化时标 dirty；`clear_target()` 将目标设为 `-1` 并标 dirty。`rebuild_dirty_atomic(map_grid)` 必须拒绝与构造时不同的 grid 对象；它先为所有 dirty slot 建候选，空目标产生下一 generation 的合法空场。任一非空目标构建失败时设置 `get_last_error()`、丢弃本次全部候选并保留所有旧场、generation 与 dirty 标志；全部成功才一次替换并清 dirty：

```gdscript
func rebuild_dirty_atomic(map_grid: SimMapGrid) -> bool:
	if map_grid != _map_grid:
		_last_error = "flow field set received a different map grid"
		return false
	var candidates: Array[SimFlowField] = []
	candidates.resize(_slot_count)
	for slot in range(_slot_count):
		if not _dirty[slot]:
			candidates[slot] = _fields[slot]
			continue
		var candidate := SimFlowField.build_empty(
			_map_grid, -1, _generations[slot] + 1
		) if _targets[slot] < 0 else SimFlowField.build_candidate(
			_map_grid, _targets[slot], _generations[slot] + 1
		)
		if candidate == null:
			_last_error = "flow field candidate build failed for slot %d" % slot
			return false
		candidates[slot] = candidate
	for slot in range(_slot_count):
		if _dirty[slot]:
			_fields[slot] = candidates[slot]
			_generations[slot] += 1
			_dirty[slot] = 0
	_last_error = ""
	return true
```

`encode_canonical()` 固定写 `flow_set_schema:u8=1`、`slot_count:u8=4`，再按 slot 0～3 写“期望 target `i32`、dirty `u8`、当前完整 `SimFlowField` canonical”。这样 target 已改变但候选尚未换入、或重建失败后仍待重试的状态也进入 Hash；`_last_error` 只用于诊断，不进入 canonical。验证须断言 `set_target_cell()` 在 rebuild 前已经改变 canonical bytes，失败重建后四个 dirty flag 和旧场 bytes 全部保留。

- [ ] **Step 6：实现固定容量空间哈希**

桶尺寸必须是地图 cell size 的正整数倍；调用方必须保证局部分离查询半径不大于 bucket size，Plan 4 初始配置以 1024 模拟单位桶覆盖 820 模拟单位分离半径。构造时以地图 bounds 算 bucket width/height，向上取整固定使用 `FixedMath.floor_div(map_extent + bucket_size_units - 1, bucket_size_units)`；world-to-bucket 也使用 `FixedMath.floor_div(world_coordinate - origin, bucket_size_units)`。`_bucket_for_world()` 对地图 bounds 外的坐标统一返回 `Vector2i(-1, -1)`。预分配 `head[bucket_count]`、`next[max_entities]`、`entity_ids[max_entities]` 与 `query_ids[max_entities]`。`clear()` 只填充值，不 resize。插入范围外或重复 entity ID 失败。查询固定扫描左上到右下九桶，收集后以插入排序按 entity ID 升序；中心越界直接返回 0，边缘九宫格中的越界桶由 `_collect_bucket()` 忽略：

```gdscript
func query_3x3_sorted(x: int, z: int) -> int:
	_query_count = 0
	var center := _bucket_for_world(x, z)
	if center == Vector2i(-1, -1):
		return 0
	for bucket_z in range(center.y - 1, center.y + 2):
		for bucket_x in range(center.x - 1, center.x + 2):
			_collect_bucket(bucket_x, bucket_z)
	_insertion_sort_query_ids()
	return _query_count

func _collect_bucket(bucket_x: int, bucket_z: int) -> void:
	if bucket_x < 0 or bucket_x >= _bucket_width \
	or bucket_z < 0 or bucket_z >= _bucket_height:
		return
	var entry_index := _head[bucket_z * _bucket_width + bucket_x]
	while entry_index >= 0:
		assert(_query_count < _query_ids.size())
		_query_ids[_query_count] = _entity_ids[entry_index]
		_query_count += 1
		entry_index = _next[entry_index]
```

`query_entity_id(index)` 只接受 `[0, query_count)`；越界返回 `-1` 并设置可读错误，不改变查询内容。

把 `sim_flow_field.gd`、`sim_flow_field_set.gd` 与 `sim_spatial_hash.gd` 加入整数除法验证器。聚焦断言至少构建一个需要 heap 上浮到两层以上的场，并查询地图原点左一单位，确认返回值与 `query_count()` 都是 0、没有负索引异常，也没有把负坐标向零截断进第一个桶。

- [ ] **Step 7：运行流场、原子失败与哈希验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_flow_field.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

Expected: 输出 `validate_frame_sync_flow_field: PASS` 与 `validate_frame_sync_map_integer_division: PASS`；覆盖墙缺口、不可达岛、阻挡目标、对角切角、同成本 cell_id Tie-break、四槽位同时换入、失败保留旧场、乱序实体插入和容量耗尽；导入退出 0。

### Task 4：接入 SimulationWorld、规范 Hash 与 100,000 Tick 地图回放门槛

**Files:**

- Modify: `scripts/simulation/world/simulation_world.gd`
- Modify: `scripts/simulation/testing/first_divergence_harness.gd`
- Create: `tools/validation/validate_frame_sync_map_replay.gd`
- Generate on import: `tools/validation/validate_frame_sync_map_replay.gd.uid`

**Interfaces:**

- Consumes: Plan 1 的 `SimulationWorld.new(session)`、`step(tick, frame) -> bool`、`InputTape`、`LocalFrameCommandCodec`、`StateHasher`；Task 1～3 的地图类型。
- Produces: `SimulationWorld.configure_map()`、`queue_map_change()`、`get_map_grid()`、`get_flow_fields()`、`reset_dynamic_occupancy(last_completed_tick)`、`mark_all_flow_fields_dirty()`，私有 `_validate_map_component_hash(actual)` 与 `_encode_dynamic_map_section(writer)`；`FirstDivergenceHarness.run_map_replay(tape: InputTape, map_asset: SimMapAsset, tick_limit: int) -> Dictionary`。

- [ ] **Step 1：写世界阶段顺序与短回放的失败验证**

创建一份 300 Tick 单人 InputTape；固定 flow 目标为 DemoArena 中心右侧可通行格。预排 Tick 10 的 CLAIM，断言变化在 `step()` 前不可见、step 后 revision 变化且 flow generation 同 Tick 更新；CLAIM/RELEASE 交替由后续 harness 场景覆盖：

验证脚本从 `OS.get_cmdline_user_args()` 读取唯一可选参数 `--ticks=<positive int>`；缺省为 100000，格式错误或小于 1 时退出 1。短失败验证命令传入 300，最终门槛传入 100000。

```gdscript
func _read_tick_limit() -> int:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return 100000
	if args.size() != 1 or not args[0].begins_with("--ticks="):
		push_error("usage: --ticks=<positive int>")
		quit(1)
		return -1
	var raw := args[0].trim_prefix("--ticks=")
	if not raw.is_valid_int() or int(raw) < 1:
		push_error("ticks must be a positive integer")
		quit(1)
		return -1
	return int(raw)

func _make_tape(session: LocalSimulationSession, tick_count: int) -> InputTape:
	var result := InputTape.new(session)
	for tick in range(tick_count):
		var commands: Array[PlayerFrameCommand] = [
			PlayerFrameCommand.new(tick % 17, 0, 0, 0),
			PlayerFrameCommand.neutral(),
			PlayerFrameCommand.neutral(),
			PlayerFrameCommand.neutral(),
		]
		assert(result.append(LocalFrameCommandSet.new(tick, 0b0001, commands)))
	return result

var manifest := SimulationManifest.new(
	1, 1, &"demo_arena", map_asset.get_content_hash()
)
var source_keys: Array[StringName] = [&"keyboard", &"", &"", &""]
var session := LocalSimulationSession.new(
	manifest, 12345, 0b0001, source_keys, 0
)
var tick_limit := _read_tick_limit()
var phase_tape := _make_tape(session, 12)
var tape := _make_tape(session, tick_limit)
var world := SimulationWorld.new(session)
_expect(world.configure_map(map_asset), "world must accept matching map", failures)
var target_cell := world.get_map_grid().world_to_cell_id(8192, 0)
_expect(world.get_flow_fields().set_target_cell(0, target_cell), "initial target must become dirty", failures)
var dynamic_cell := world.get_map_grid().world_to_cell_id(-14336, -3584)
var change := SimDynamicOccupancyChange.new(10, 1, 0, 1001, SimDynamicOccupancyChange.Operation.CLAIM, PackedInt32Array([dynamic_cell]))
_expect(world.queue_map_change(change), "map change must queue", failures)
_expect(world.get_map_grid().dynamic_owner_at(dynamic_cell) == 0, "queued change must not apply outside step", failures)
for tick in range(11):
	_expect(world.step(tick, phase_tape.get_frame(tick)), "world must step through tick 10", failures)
_expect(world.get_map_grid().dynamic_owner_at(dynamic_cell) == 1001, "phase 3 must commit current tick", failures)
_expect(world.get_flow_fields().field_for_slot(0).generation() == 2, "phase 4 must rebuild after revision", failures)
var revision_before_reset := world.get_map_grid().get_dynamic_revision()
world.reset_dynamic_occupancy(10)
_expect(world.get_map_grid().get_dynamic_revision() == revision_before_reset + 1, "reset must advance revision exactly once", failures)
_expect(world.get_map_grid().dynamic_owner_at(dynamic_cell) == 0, "reset must clear owners", failures)
_expect(world.get_flow_fields().is_dirty(0), "reset must dirty every flow field", failures)
var tick_11_change := SimDynamicOccupancyChange.new(11, 1, 0, 1002, SimDynamicOccupancyChange.Operation.CLAIM, PackedInt32Array([dynamic_cell]))
_expect(world.queue_map_change(tick_11_change), "tick after high reset must queue", failures)
_expect(world.step(11, phase_tape.get_frame(11)), "tick after reset must commit without rewinding to zero", failures)
_expect(world.get_map_grid().dynamic_owner_at(dynamic_cell) == 1002, "post-reset tick must commit new owner", failures)
_expect(world.get_flow_fields().field_for_slot(0).generation() == 3, "post-reset tick must rebuild dirty flow", failures)

var initial_reset_world := SimulationWorld.new(session)
_expect(initial_reset_world.configure_map(map_asset), "initial reset world must configure", failures)
var initial_world_revision := initial_reset_world.get_map_grid().get_dynamic_revision()
initial_reset_world.reset_dynamic_occupancy(-1)
_expect(initial_reset_world.get_map_grid().get_dynamic_revision() == initial_world_revision + 1, "initial world reset must increment revision once", failures)
for slot in range(4):
	_expect(initial_reset_world.get_flow_fields().is_dirty(slot), "initial world reset must dirty every slot", failures)
_expect(initial_reset_world.step(0, phase_tape.get_frame(0)), "initial reset must preserve tick zero", failures)
for slot in range(4):
	_expect(initial_reset_world.get_flow_fields().field_for_slot(slot).generation() == 1, "tick zero must rebuild every empty field", failures)
```

该 helper 从 Tick 0 连续追加 `tick_limit` 个合法单人帧，不得跳 Tick 或改变 active mask。另复制地图 Hash、翻转第一个 byte，构造 map ID 相同但 `config_hash` 错误的会话；`configure_map()` 必须拒绝且不能安装部分地图状态：

```gdscript
var wrong_hash := map_asset.get_content_hash()
wrong_hash[0] = wrong_hash[0] ^ 1
var wrong_manifest := SimulationManifest.new(
	1, 1, &"demo_arena", wrong_hash
)
var wrong_session := LocalSimulationSession.new(
	wrong_manifest, 12345, 0b0001, source_keys, 0
)
var wrong_world := SimulationWorld.new(wrong_session)
var state_before_reject := wrong_world.encode_canonical_state()
_expect(not wrong_world.configure_map(map_asset), "config hash mismatch must reject map", failures)
_expect(wrong_world.get_map_grid() == null, "rejected map must not install a grid", failures)
_expect(wrong_world.get_flow_fields() == null, "rejected map must not install flow fields", failures)
_expect(wrong_world.encode_canonical_state() == state_before_reject, "rejected map must preserve canonical state", failures)

for invalid_capacity in PackedInt32Array([0, 32768]):
	var invalid_capacity_world := SimulationWorld.new(session)
	var capacity_state_before := invalid_capacity_world.encode_canonical_state()
	_expect(not invalid_capacity_world.configure_map(map_asset, invalid_capacity), "capacity outside 1..32767 must reject", failures)
	_expect(invalid_capacity_world.get_map_grid() == null, "invalid capacity must not install a grid", failures)
	_expect(invalid_capacity_world.encode_canonical_state() == capacity_state_before, "invalid capacity must preserve canonical state", failures)
```

然后执行短双世界回放并断言结果：

```gdscript
var replay := FirstDivergenceHarness.new(session).run_map_replay(
	tape, map_asset, tick_limit
)
_expect(replay.ok and replay.ticks_checked == tick_limit, "requested Tick count must agree", failures)
```

- [ ] **Step 2：运行短验证，确认世界扩展与 harness API 缺失**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_replay.gd -- --ticks=300
```

Expected: 非零退出，错误指向 `configure_map()`、`queue_map_change()` 或 `run_map_replay()` 尚未定义。

- [ ] **Step 3：以附加配置保持 Plan 1 构造和 step 签名**

不得把构造改成 `initialize()`，也不得把 `step()` 改成返回 `Error`：

```gdscript
func _validate_map_component_hash(actual: PackedByteArray) -> bool:
	var manifest := _session.get_manifest()
	return StateHasher.equal(manifest.config_hash, actual)

func configure_map(map_asset: SimMapAsset, dynamic_owner_capacity: int = 256) -> bool:
	if _next_tick != 0 or _map_grid != null:
		return _fail("map must be configured exactly once before tick 0")
	if dynamic_owner_capacity < 1 or dynamic_owner_capacity > 32767:
		return _fail("dynamic_owner_capacity must be in 1..32767")
	if map_asset == null or not SimMapAssetCodec.validate_content_hash(map_asset):
		return _fail("map asset hash is invalid")
	var manifest := _session.get_manifest()
	if map_asset.map_id != manifest.map_id:
		return _fail("session map_id does not match map asset")
	if not _validate_map_component_hash(map_asset.get_content_hash()):
		return _fail("session config_hash does not match map content_hash")
	_map_grid = SimMapGrid.new(map_asset, dynamic_owner_capacity)
	_flow_fields = SimFlowFieldSet.new(_map_grid, 4)
	_last_map_warning = ""
	return true

func queue_map_change(change: SimDynamicOccupancyChange) -> bool:
	return _map_grid != null and _map_grid.queue_dynamic_change(change)

func mark_all_flow_fields_dirty() -> void:
	if _flow_fields != null:
		_flow_fields.mark_all_dirty()

func reset_dynamic_occupancy(last_completed_tick: int) -> void:
	assert(_map_grid != null)
	assert(last_completed_tick == _next_tick - 1)
	_map_grid.reset_dynamic_occupancy(last_completed_tick)
	mark_all_flow_fields_dirty()
```

`_validate_map_component_hash(actual)` 是给 Plan 6 保留的唯一扩展缝：Plan 2 尚未配置 bundle 时，legacy 分支把 manifest `config_hash` 直接视为地图 `content_hash`；Plan 6 配置完整 bundle 后，只把 helper 扩展为比较 bundle 的 MAP component Hash，同时 manifest `config_hash` 改为最终 bundle Hash。不得因为引入最终 Hash 而移除地图 component 校验。

`SimulationWorld` wrapper 只接受当前世界实际最后完成的 Tick；初局 `_next_tick == 0` 时传 `-1`，高 Tick 重开在 Tick `T` 完成后传 `T`。这样下一次阶段 3 提交恰好是 `T + 1`，不会错误要求回到 Tick 0。

`get_map_grid()` 与 `get_flow_fields()` 返回现有对象或 `null`；旧 Plan 1 `core_spike` 世界不调用 `configure_map()` 时继续按原最小逻辑运行，确保 Plan 1 金样不被地图空状态改变。

Task 4 不再扩展整数除法验证器；该验证器只扫描 Plan 2 自有的 `scripts/simulation/map/` 运行时代码。完成 Task 3 后的最终扫描清单必须保持精确为：

```gdscript
const RUNTIME_PATHS := PackedStringArray([
	"res://scripts/simulation/map/sim_map_asset.gd",
	"res://scripts/simulation/map/sim_map_asset_codec.gd",
	"res://scripts/simulation/map/sim_dynamic_occupancy_change.gd",
	"res://scripts/simulation/map/sim_map_grid.gd",
	"res://scripts/simulation/map/sim_flow_field.gd",
	"res://scripts/simulation/map/sim_flow_field_set.gd",
	"res://scripts/simulation/map/sim_spatial_hash.gd",
])
```

`SimulationWorld` 属于 Plan 1 冻结核心，`FirstDivergenceHarness` 属于 Plan 1 测试编排，两者都不纳入 Plan 2 自有运行时扫描；本计划新增示例本身仍不得写直接整数除法。

- [ ] **Step 4：在固定阶段 3/4 提交并同步重建**

`step()` 先完成 Plan 1 的 Tick/frame/mask 验证和命令复制，再执行地图阶段，最后执行后续世界逻辑与 Hash 状态更新：

```gdscript
func _step_map_phases(tick: int) -> void:
	if _map_grid == null:
		return
	var revision_before := _map_grid.get_dynamic_revision()
	_map_grid.commit_dynamic_changes(tick)
	if _map_grid.get_dynamic_revision() != revision_before:
		mark_all_flow_fields_dirty()
	if not _flow_fields.rebuild_dirty_atomic(_map_grid):
		_last_map_warning = _flow_fields.get_last_error()
```

调用位置必须对应规格顺序：应用玩家命令之后；未来放置请求之后；玩家候选移动、僵尸和战斗之前。重建失败时本 Tick 继续使用旧完整 flow、继续推进 `_next_tick`，dirty 标志保留供下一 Tick 重试；警告进入地图诊断但不让模拟永久卡死。

- [ ] **Step 5：只实现 Plan 1 冻结位置的动态地图 section**

不得在 `encode_canonical_state()` 末尾追加地图段。保持 Plan 1 已冻结的顶层调用顺序不变：world header → player → zombie → other entity → `_encode_dynamic_map_section(writer)` → PRNG → wave → pending events。Plan 1 在该 helper 预留 `map_marker:u8=0`；Plan 2 未配置地图时继续写 marker 0，已配置地图时写 `map_marker:u8=1`，随后写 `map_section_schema:u8=1`、32-byte `content_hash`、动态占用 canonical 和四槽位 flow canonical：

```gdscript
func _encode_dynamic_map_section(writer: LittleEndianWriter) -> void:
	if _map_grid == null:
		writer.write_u8(0)
		return
	writer.write_u8(1)
	writer.write_u8(1)
	writer.write_bytes(_map_grid.get_content_hash())
	_map_grid.encode_canonical_dynamic(writer)
	_flow_fields.encode_canonical(writer)
```

扩展 `validate_frame_sync_map_replay.gd` 的 canonical section probe：按 Plan 1 固定 schema 解析 world header，并明确断言 `next_tick:u32` 后的 `config_bundle_marker:u8` 仍为 0。玩家段必须先读取并断言 `player_slot_count:u8=4`，消费四个命令各自的 `move_heading:u8 + action_bits:u8 + equipment_delta:i8 + placement_heading:u8`，再读取并断言 `player_sim_marker:u8=0`；之后才消费 `zombie_marker:u8=0 + zombie_slot_count:u16=0` 和 allocator canonical bytes，并逐字节断言 other entity 段尾随的 `combat_state_marker:u8=0`、`world_entity_marker:u8=0`。下一字节必须是 `map_marker`，配置地图时为 1，随后 schema 必须为 1 且 Hash 必须等于资源 `content_hash`。读完 grid/flow 后，下一个字节必须是 Plan 1 `rng_stream_count:u8=4`，四个 tag 必须仍为 `1,2,3,4`。另重跑 Plan 1 `validate_local_frame_sync_core.gd`，其未配置地图 marker 0、config bundle marker 0 与完整金样必须逐 byte 不变。

地图 section 不得包含 Node、RID、物理或导航状态；配置与未配置世界只允许在冻结 dynamic-map section 内产生差异。

- [ ] **Step 6：扩展双世界 harness 的地图场景**

两个世界加载同一提交资源并设置同一初始 flow 目标。每 Tick 左世界读取原帧，右世界读取 `decode(encode(frame))`；测试变化只能从各自实际收到的帧确定性派生，不能共享可变 change 对象：

```gdscript
func _select_scripted_cells(grid: SimMapGrid, flow_target: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for cell_id in range(grid.get_width() * grid.get_height()):
		if cell_id == flow_target or grid.is_static_blocked(cell_id):
			continue
		result.append(cell_id)
		if result.size() == 4:
			break
	assert(result.size() == 4)
	return result

func _queue_scripted_map_change(
	world: SimulationWorld,
	frame: LocalFrameCommandSet,
	candidate_cells: PackedInt32Array,
	previous_cell: int
) -> int:
	if frame.tick % 97 != 0:
		return previous_cell
	var claim := previous_cell < 0
	var cell_id := candidate_cells[
		frame.player_commands[0].move_heading % candidate_cells.size()
	] if claim else previous_cell
	var change := SimDynamicOccupancyChange.new(
		frame.tick, 1, 0, 1001,
		SimDynamicOccupancyChange.Operation.CLAIM if claim else SimDynamicOccupancyChange.Operation.RELEASE,
		PackedInt32Array([cell_id])
	)
	if not world.queue_map_change(change):
		return previous_cell
	return cell_id if claim else -1
```

两个分支分别对自己的 grid 调用 `_select_scripted_cells()`，断言得到相同值，但各自保留独立的 `PackedInt32Array` 与上一次 cell ID。候选固定为 row-major 最前四个静态可通行且不是 flow target 的格，因此 CLAIM 不会因静态阻挡或目标格被占而静默失败。每次调用 helper 前保存旧 cell；step 后若新值非负，断言该格 owner 为 1001；若新值为 `-1`，断言旧格 owner 已变为 0。这样 RELEASE 总是对应已成功的前一次 CLAIM。每 Tick 再比较 32-byte Hash；首次分歧返回：`ok=false`、`tick`、`frame_hex`、双方 Hash、双方 canonical state hex、dynamic revision、四个 flow generation。成功返回 `{ "ok": true, "ticks_checked": tick_limit }`。

- [ ] **Step 7：运行完整 Plan 2 门槛与旧路径保护检查**

Run:

```bash
set -euo pipefail
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_local_frame_sync_core.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_asset.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_grid.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_flow_field.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_integer_division.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_frame_sync_map_replay.gd -- --ticks=100000
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
for source in \
	scripts/simulation/map/sim_map_asset.gd \
	scripts/simulation/map/sim_map_asset_codec.gd \
	scripts/simulation/map/sim_dynamic_occupancy_change.gd \
	scripts/simulation/map/sim_map_grid.gd \
	scripts/simulation/map/sim_flow_field.gd \
	scripts/simulation/map/sim_flow_field_set.gd \
	scripts/simulation/map/sim_spatial_hash.gd \
	tools/map/demo_arena_map_export_contract.gd \
	tools/map/demo_arena_map_exporter.gd \
	tools/map/export_demo_arena_sim_map.gd \
	tools/validation/validate_frame_sync_map_asset.gd \
	tools/validation/validate_frame_sync_map_grid.gd \
	tools/validation/validate_frame_sync_flow_field.gd \
	tools/validation/validate_frame_sync_map_integer_division.gd \
	tools/validation/validate_frame_sync_map_replay.gd
do
	test -f "$source.uid"
done
assert_no_match() {
	if rg "$@"; then
		return 1
	else
		status=$?
	fi
	case "$status" in
		1) return 0 ;;
		*) return "$status" ;;
	esac
}
division_output="$(rg -n ' / ' scripts/simulation/core/fixed_math.gd scripts/simulation/map)"
printf '%s\n' "$division_output" | awk -F: 'BEGIN { count = 0; bad = 0 } { count += 1; if ($1 != "scripts/simulation/core/fixed_math.gd") bad = 1 } END { exit (bad || count != 1) }'
assert_no_match -n 'NavigationAgent3D|NavigationServer3D|NavigationMesh|PhysicsDirectSpaceState3D|intersect_' scripts/simulation/map
git diff --check
protected_diff="$(git diff -- scripts/gameplay/demo_arena.gd scripts/gameplay/place_item_grid.gd scripts/gameplay/place_item_service.gd scripts/navigation/navigation_world_manager.gd scripts/navigation/navigation_chunk_3d.gd scenes/gameplay/DemoArena.tscn)"
test -z "$protected_diff"
```

Expected: 六个验证与导入全部退出 0；Plan 1 核心金样不变，回放输出 `validate_frame_sync_map_replay: PASS 100000 ticks`，15 个新增脚本的 `.gd.uid` 全部存在。整数除法 `rg` 必须恰好返回一行且路径只能是 `scripts/simulation/core/fixed_math.gd`；Plan 2 自有 runtime 由聚焦验证器确认零裸 `/`。API `assert_no_match` 以“rg 无匹配”的原始状态 1 转换为成功，匹配或 rg 自身错误都会使门槛失败；protected diff 必须为空。场景 diff 只允许 `ExplosiveBarrel.tscn` 与 `PickupChest.tscn` 的新增动态组，不允许更改旧 DemoArena 默认路径、旧 `PlaceItemGrid` 或运行时导航行为。

- [ ] **Step 8：记录人工验收结果，不运行提交命令**

用现有默认启动命令打开旧 `DemoArena`，只人工确认：旧玩家可移动、僵尸仍使用旧导航追击、油桶仍可放置、拾取箱仍可领取。关闭运行后记录结果；执行 agent 不执行 `git add`、`git commit`、分支合并或默认场景切换。

## 交付门槛

- [ ] `resources/simulation/maps/demo_arena_map.tres` 可由冻结工具重复生成相同 canonical bytes 与同一个 32-byte `content_hash`，关键静态格与动态排除格验证通过。
- [ ] 运行时只加载并校验提交资源；模拟代码搜索不到 `NavigationAgent3D`、`NavigationServer3D`、NavMesh 烘焙、Physics 查询、场景碰撞扫描或异步 Flow Field。
- [ ] 动态 CLAIM/RELEASE 在指定 Tick、稳定排序和整条原子规则下提交，dynamic revision 与规范状态一致，冲突不会因排队顺序改变结果。
- [ ] `reset_dynamic_occupancy(last_completed_tick)` 清空 owner/pending、设置最后完成 Tick、revision 恰加 1，并经 `SimulationWorld.mark_all_flow_fields_dirty()` 使下一 Tick 重建；初局 `-1` 与高 Tick 重开都通过。
- [ ] `move_circle_x_then_z()` 在负坐标、地图边界、静态格、动态格、高速跨格和初始重叠条件下结果固定，且只使用整数。
- [ ] Plan 2 运行时源码所有整数商都调用 `FixedMath.floor_div()`；源码扫描器与反向 `rg` 均确认没有裸 `/` 运算符。
- [ ] 四槽位 Flow Field 使用固定邻居、成本、cell_id Tie-break 与同步全体换入；重建失败保留旧场，不暴露部分候选。
- [ ] `SimSpatialHash` 固定容量、无热路径扩容，任意插入顺序的 3×3 查询都返回实体 ID 升序结果。
- [ ] 地图 Hash、动态 owner、pending changes 和 Flow Field 只编码在 Plan 1 固定位置的 `_encode_dynamic_map_section()`；其前是 other entity、其后立即是 PRNG，Plan 1 未配置地图金样逐 byte 不变。
- [ ] 直接帧与 codec 帧的地图场景连续 100,000 Tick 每 Tick Hash 完全一致。
- [ ] 旧 `DemoArena` 仍是默认可玩路径；本计划未改旧地图脚本、放置脚本、导航脚本或 `DemoArena.tscn`，也未运行任何提交命令。

## 自检结果

- 规格覆盖：Task 1 覆盖离线整数地图资源与可重复 Hash；Task 2 覆盖地图边界、整数圆形碰撞、带 last-completed Tick 的动态占用重置和首阻挡 supercover；Task 3 覆盖空间哈希与同步原子 Flow Field；Task 4 覆盖固定阶段、Plan 1 冻结 dynamic-map section、双实例 100,000 Tick 和旧路径保护，未发现缺失的 Plan 2 要求。
- 未定义实现项扫描：所有新增文件、类型、字段、方法、排序键、资源路径、验证命令和失败结果都已在产生它们的 Task 中定义；所有“预期无匹配”的 `rg` 都经 `assert_no_match` 反转并保留错误状态。
- 类型一致性：全文 Hash 字段统一为 `content_hash: PackedByteArray`；地图运行时统一为 `SimMapGrid`；reset 统一为 `reset_dynamic_occupancy(last_completed_tick: int)`；线查询 sentinel 统一为 `NO_BLOCKED_CELL_ID=-1` 与 `OUT_OF_BOUNDS_CELL_ID=-2`；Plan 2 自有 runtime 的整数商统一为 `FixedMath.floor_div()`；Flow Field 集合统一为 `SimFlowFieldSet`；空间哈希统一为 `SimSpatialHash`；canonical 统一由 `_encode_dynamic_map_section(writer)` 占据 Plan 1 冻结位置；`SimulationWorld.new(session)` 与 `step(tick, frame) -> bool` 保持 Plan 1 签名不变。

## 执行交接

Plan 完成后，执行时有两种方式：

1. Subagent-Driven（推荐）：使用 `subagent-driven-development`，每个 Task 完成后做规格与质量双阶段审查；按项目约定不为单个 Task 提交，最终也由用户自行提交。
2. Inline Execution：使用 `executing-plans`，在当前会话按 Task 批量执行并设置检查点；同样不运行提交命令。

实施前先询问用户是否使用隔离 worktree；本计划会修改资源与两个场景元数据，建议在当前工作区干净且没有并行编辑时默认不创建 worktree，若同时执行 Plan 3/4 或存在重叠改动则使用隔离 worktree。
