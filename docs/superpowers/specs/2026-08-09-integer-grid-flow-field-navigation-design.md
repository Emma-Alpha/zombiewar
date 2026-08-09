# 整数网格与共享流场导航设计

## 目标

把当前基于 `NavigationMesh`、`NavigationRegion3D`、`NavigationAgent3D` 和运行时异步烘焙的僵尸导航完整替换为场景级整数网格导航系统。

新系统以整数地图格作为权威数据，在运行时用确定性的整数算法构建玩家共享流场，并通过整数 footprint 原子更新静态与动态障碍。僵尸继续使用现有 `CharacterBody3D`、重力、击退、动画和世界物理碰撞完成最终移动，但路径选择不再读取 Godot 导航服务器或运行时碰撞几何。

本次同时建立单一全局 `session_seed` 和可派生的独立确定性随机流，保证相同根 seed、相同输入和相同事件顺序得到相同的波次、掉落、武器散布、僵尸游荡和表现随机结果。

## 已确认范围

- 这是导航架构重组，不保留旧 `NavigationAgent3D` 路径、运行时功能开关或双轨回退。
- 整数地图格是导航权威数据；视觉模型不得反向决定导航阻挡。
- 静态碰撞、拾取箱、爆炸桶和放置物必须声明整数 anchor cell 与导航 footprint。
- 静态地图格和运行时流场都在运行时构建，但构建输入只包含整数配置，不扫描碰撞形状生成导航数据。
- 玩家追击使用共享流场；每位存活玩家最多维护一个流场。
- 僵尸游荡使用有界局部整数 A*，不为每只僵尸建立整张地图流场。
- 导航以固定 10 Hz 更新；物理移动继续使用项目现有 60 Hz 物理帧。
- 动态障碍更新支持生成、移除、移动、启用和禁用，并在导航 Tick 边界原子提交。
- 相同导航输入必须产生完全相同的距离场、下一格和不可达结果。
- 全局随机使用一个根 `session_seed`，各玩法与表现系统从根 seed 派生互不干扰的子流。
- 不新增导航 Autoload；当前 `World3D` 继续拥有场景级导航管理器。
- 不启用僵尸间局部 avoidance，不实现群体拥挤、推挤或队列行为。
- 不把玩家、战斗、物理碰撞或完整玩法模拟迁移为整数 Lockstep。

## 方案选择

### 采用方案：运行时整数地图 + 共享流场

地图首先按整数格 authoring。运行时只读取地图尺寸、整数原点、格子尺寸、静态 footprint 和动态 obstacle 命令，构建紧凑占用数组和流场。

该方案不需要提交离线生成的 NavMesh 或网格缓存，同时避免从任意浮点 `Transform3D`、旋转碰撞体或 GLTF 模型重新栅格化。地图的逻辑布局和动态障碍生命周期全部可以通过整数数据复现。

### 未采用：运行时碰撞体栅格化

该方案可以使用整数输出，但输入仍来自任意浮点位置、旋转和形状边界；需要定义大量边界取整规则，并会让场景碰撞继续成为隐含权威来源。它不符合“地图先格子化”的已确认前提。

### 未采用：离线生成并提交导航格资源

离线资源可以减少启动构建，但需要额外构建步骤、缓存失效协议和场景与资源一致性检查。当前 DemoArena 只有 7,296 个格子，直接从整数场景配置构建占用数组的成本很低，因此不引入这条资源管线。

## 确定性边界

导航核心保证：

- 相同网格配置得到相同静态占用数组。
- 相同动态 obstacle 命令批次得到相同 `grid_revision` 和动态占用结果。
- 相同目标格得到相同距离场与下一格数组。
- 相同不可达、阻挡和 tie-break 条件得到相同决策。
- 相同根 seed、namespace、稳定实体 ID 和调用次数得到相同随机序列。

本次不保证整个游戏逐帧确定，因为以下系统仍使用浮点和 Godot 运行时状态：

- `CharacterBody3D.move_and_slide()`。
- Jolt Physics 世界碰撞和射线查询。
- 浮点物理位置、速度和 `delta`。
- 动画、音频、粒子和渲染更新。
- 由玩家实时输入和物理结算决定的事件顺序。

因此，本功能可以称为“确定性导航核心”和“确定性随机基础”，不能称为完整跨平台帧同步模拟。

## 总体架构

```text
GameSession.session_seed
        |
        +--> DeterministicRng 子流

整数地图配置 + obstacle 命令 + 玩家格
        |
        v
IntegerNavigationWorld
        |
        +--> IntegerNavigationGrid
        +--> 玩家共享 IntegerFlowField
        +--> 局部 IntegerGridPathfinder
        |
        v
ZombieTarget 缓存 next_cell
        |
        v
Vector3 移动方向 + CharacterBody3D
```

### `IntegerNavigationGrid`

纯 `RefCounted` 数据核心，不持有 `Node`、`RID`、`World3D` 或物理服务器引用。

职责：

- 保存整数地图原点、格子尺寸、宽高和格子总数。
- 完成 `Vector2i`、稳定 `cell_id` 与世界毫米坐标之间的转换。
- 保存静态阻挡、动态占用引用计数和合并后的可通行状态。
- 验证 footprint、anchor cell 和 obstacle 更新边界。
- 按批次应用动态障碍命令，并只递增一次 `grid_revision`。
- 提供固定顺序的可通行邻居查询。

核心配置：

```gdscript
world_origin_mm: Vector2i
cell_size_mm: int = 500
grid_size: Vector2i = Vector2i(96, 76)
```

DemoArena 的逻辑可行走矩形按边界墙内侧对齐为 48×38 米，并与现有 1 米放置格共享世界零点边界：

```gdscript
world_origin_mm = Vector2i(-24000, -19000)
cell_size_mm = 500
grid_size = Vector2i(96, 76)
```

格子索引固定为：

```text
cell_id = cell.y * grid_width + cell.x
```

地图外部天然不可通行，不需要把四面边界墙加入导航障碍。

### `IntegerFlowField`

纯 `RefCounted` 反向距离场，输入为只读整数网格快照和目标格。

保存：

```gdscript
goal_cell_id: int
grid_revision: int
distance: PackedInt32Array
next_cell: PackedInt32Array
```

约定：

- `INF_COST = 0x3fffffff` 表示不可达。
- `NO_CELL = -1` 表示没有下一格。
- 直线边费用为 `10`。
- 斜线边费用为 `14`。
- 优先级按 `(累计费用, cell_id)` 排序。
- 相同候选费用时，选择较小的下一格 `cell_id`。

### `IntegerGridPathfinder`

纯 `RefCounted` 局部 A*，只用于僵尸游荡。

职责：

- 在 home cell 周围的固定整数半径内搜索。
- 使用和共享流场完全相同的邻居、费用、斜角与 tie-break 规则。
- 返回 `PackedInt32Array` 路径。
- 通过固定最大展开格数限制成本。

当前游荡半径 3.5 米对应 7 格，搜索边界最多为 15×15，即 225 个格子。路径只在选择新目标、路径阻塞或网格版本变化时重新计算。

### `IntegerNavigationWorld`

场景级 `Node3D` 管理器，位于 `DemoArena/World/Navigation`，不作为 Autoload。

职责：

- 从整数场景配置初始化 `IntegerNavigationGrid`。
- 收集并排序静态 `NavigationGridObstacle3D`。
- 批量接收动态障碍更新。
- 维护每位存活玩家的共享流场。
- 每 6 个物理帧执行一次导航 Tick。
- 对场景层提供世界位置、玩家目标和下一格查询接口。
- 把配置错误转发给 DemoArena，并阻止在无权威导航格时开始波次。

### `NavigationGridObstacle3D`

场景适配组件，作为影响导航的碰撞对象子节点存在。

权威字段：

```gdscript
obstacle_id: int
anchor_cell: Vector2i
footprint_cells: Array[Vector2i]
enabled: bool
dynamic: bool
```

`anchor_cell` 表示 footprint 的最小逻辑格，不表示父节点必须位于该格中心。组件不读取父碰撞形状生成 footprint。footprint 直接表示“僵尸中心不可进入”的相对格，因此包含所需角色半径和安全间隙。

静态组件在场景加载时使用导出 anchor cell。动态组件必须在父节点进入场景树前通过明确配置接口获得稳定 ID 与 anchor cell。

组件负责设置或校验父碰撞对象的格子对齐。碰撞对象 X/Z 原点必须位于导航格边界或格中心，误差不得超过 1 毫米；水平旋转必须是 90 度整数倍且误差不超过 0.01 度；碰撞 AABB 的 XZ 投影必须完全包含在 footprint 对应的世界矩形内。视觉节点可以通过局部 Transform 自由偏移或旋转，但碰撞对象必须遵守这些逻辑格约束。

## 地图格子化规则

### 世界毫米与格子转换

导航核心使用整数毫米。场景适配层把世界浮点坐标转换为毫米：

```gdscript
world_x_mm = roundi(world_position.x * 1000.0)
world_z_mm = roundi(world_position.z * 1000.0)
```

格坐标使用明确的 floor division，不依赖语言对负数整数除法的隐式行为：

```text
cell_x = floor_div(world_x_mm - origin_x_mm, cell_size_mm)
cell_y = floor_div(world_z_mm - origin_z_mm, cell_size_mm)
```

权威格中心转换回世界位置时使用：

```text
center_mm = origin_mm + cell * cell_size_mm + cell_size_mm / 2
```

`cell_size_mm` 必须为正偶数，确保格中心仍是整数毫米。

### 静态阻挡

所有影响导航的静态对象必须有显式 footprint：

- 地图外部由 grid bounds 阻挡。
- 集装箱、固定车辆、固定箱体和关卡障碍声明矩形或显式格掩码。
- 只影响视觉的交通锥、标牌和血迹不登记导航阻挡。
- 不再使用 `navigation_source` 分组。

静态 obstacle ID 在场景中显式配置，加载时按 ID 升序登记。重复 ID、空 footprint 或越界 footprint 都是关卡配置错误。

### 动态阻挡

动态障碍统一提交：

```gdscript
queue_obstacle_update(
	obstacle_id: int,
	anchor_cell: Vector2i,
	footprint_cells: Array[Vector2i],
	enabled: bool
) -> bool
```

同一个 obstacle ID 的新状态完整替换旧状态，因此可以覆盖：

- 生成：旧状态不存在，新状态启用。
- 移除：新状态禁用。
- 移动：新状态使用不同 anchor cell。
- 启用：保留 footprint 并切换为启用。
- 禁用：从占用引用计数中移除。

命令在下一个导航 Tick 按 obstacle ID 升序提交。移动先计算完整旧、新 cell 集合，再原子修改引用计数，不暴露中间状态。

重叠障碍使用引用计数。只有动态引用计数归零且没有静态阻挡时，格子才重新可通行。

### 放置格映射

现有放置系统继续使用 1 米操作格。地图原点使 1 米放置格边界和 0.5 米导航格边界精确对齐；每个放置格映射为 2×2 个导航格。

```text
placement_center_mm = placement_grid_origin_mm + placement_cell * 1000
placement_min_mm = placement_center_mm - Vector2i(500, 500)
nav_cell_origin = navigation_grid.world_mm_to_cell(placement_min_mm)
```

映射结果必须验证 `nav_cell_origin` 到 `nav_cell_origin + Vector2i(1, 1)` 四格的世界范围与该放置格完全一致；不一致时拒绝初始化放置服务。

具体道具可以在这 2×2 基础上声明更大的导航 footprint，以包含僵尸半径和设计安全间隙。

放置验证继续检查玩家、僵尸和其他道具。成功放置后，先确定整数 anchor cell，再把动态障碍命令排入导航世界。

## 流场算法

### 固定邻居顺序

邻居顺序固定为顺时针：

```gdscript
[
	Vector2i(0, -1),
	Vector2i(1, -1),
	Vector2i(1, 0),
	Vector2i(1, 1),
	Vector2i(0, 1),
	Vector2i(-1, 1),
	Vector2i(-1, 0),
	Vector2i(-1, -1),
]
```

斜向访问要求目标斜格可通行，并且对应两个正交侧格都可通行，禁止从两个阻挡格之间穿角。

### 反向 Dijkstra

从目标玩家格反向扩展：

1. 所有 `distance` 初始化为 `INF_COST`，所有 `next_cell` 初始化为 `NO_CELL`。
2. 目标格费用设为 0 并压入最小堆。
3. 最小堆比较键固定为 `(cost, cell_id)`。
4. 从当前格扩展到可通行邻格。
5. 候选费用更小时更新距离，并把当前格记录为邻格的下一格。
6. 候选费用相等时，较小的下一格 cell ID 获胜。
7. 队列耗尽后生成完整候选流场。
8. 只有候选流场的目标与网格版本仍匹配时，才原子替换活动流场。

最小堆实现不得使用 Dictionary 或依赖对象比较；使用整数数组保存 cell ID 和 cost。

### 玩家目标投影

玩家通常必须处于可通行格。若动态配置使目标格被阻挡，则从玩家格执行固定邻居顺序的有界 BFS，选择最近的可通行格；同深度存在多个候选时选择较小 cell ID。

如果地图内不存在可用目标格，该玩家流场标为无效，僵尸不得沿直线追击。

### 阻挡格逃离

动态障碍可能在僵尸当前位置出现。若僵尸当前格已被阻挡：

- 允许查询其可通行邻格。
- 选择目标流场费用最低的邻格。
- 费用相同时选择较小 cell ID。
- 其他僵尸不得把该阻挡格作为下一格。

该规则只允许离开阻挡格，不允许穿越连续阻挡区域。

## 导航更新时序

项目物理频率保持 60 Hz，导航 Tick 固定为每 6 个物理帧一次，即 10 Hz。

每个导航 Tick 严格按以下顺序执行：

1. 收集当前存活玩家的稳定 ID 和整数目标格。
2. 将待处理 obstacle 命令按 obstacle ID 排序。
3. 原子应用全部动态占用变化。
4. 如果本批有有效变化，`grid_revision` 只增加一次。
5. 对目标格变化的玩家重建对应流场。
6. 如果 `grid_revision` 变化，为所有活动玩家重建流场。
7. 完整候选流场构建成功后原子替换旧场。
8. 通知僵尸刷新目标选择和下一格缓存。

障碍刚出现但导航 Tick 尚未执行时，旧方向最多继续约 100ms。现有世界物理碰撞负责阻止角色实际穿过新碰撞体。

第一版同步构建当前 7,296 格的流场，不创建线程。只有实际性能采样证明流场重建超过预算时，才另行设计线程快照或增量构建；不得在本次预先增加异步复杂度。

## 僵尸行为接入

### 追击目标选择

每位存活玩家拥有稳定玩家槽位 ID 和一个活动流场。

僵尸对候选玩家进行：

1. 检查玩家存活。
2. 使用整数距离平方检查感知范围。
3. 查询当前格到玩家的流场费用。
4. 排除无效或不可达流场。
5. 选择费用最低的玩家。
6. 保留目标切换滞后；只有新目标费用加固定 margin 小于当前目标费用时才切换。

当前 `target_switch_margin = 0.5` 米对应一个正交格费用，即 `10`。

### 追击移动

导航 Tick 返回相邻 `next_cell`。`ZombieTarget` 缓存下一格中心世界位置，并在后续物理帧中继续朝该位置移动。

僵尸最大追击速度低于一个导航 Tick 内跨越完整 0.5 米格子的速度，因此不会因为 10 Hz 查询而连续跳过多个未检查格。

最终速度、加速度、减速、重力、击退和 `move_and_slide()` 保持现有实现语义。

### 游荡

游荡目标改为整数格：

- 从 home cell 半径 7 格内的预计算整数偏移列表选择候选。
- 候选偏移列表排序稳定，并通过僵尸独立 wander RNG 子流选择索引。
- 候选必须在地图内且可通行。
- 选择目标时运行一次最多展开 225 格的局部 A*。
- 路径缓存 cell ID；到达、路径格阻塞或 `grid_revision` 改变时失效。
- 不可达时最多继续选择 8 个候选，仍无路径则进入游荡暂停并在下一周期重试。

### 攻击与不可达

进入攻击状态仍要求：

- 目标玩家存活。
- 直线距离在攻击范围内。
- 现有世界障碍射线无遮挡。

流场不可达时，僵尸改选其他可达玩家；没有可达玩家时停止追击或进入游荡。导航核心出现后不得永久使用直线穿墙回退。

## 全局确定性随机

### 根 seed

`GameSession` 新增：

```gdscript
const DEFAULT_SESSION_SEED := 4399
var session_seed: int = DEFAULT_SESSION_SEED
```

单人和本地多人进入战斗前必须确定一次根 seed。本次不增加菜单输入 UI；默认使用固定值，并保留显式设置接口供测试和未来会话配置使用。

### `DeterministicRng`

项目自有纯整数 PRNG 使用 Park–Miller 31 位算法：

```text
modulus = 2147483647
multiplier = 48271
state range = 1..2147483646
```

中间乘法使用 GDScript 64 位整数。随机整数范围使用 rejection sampling，避免简单取模偏差。需要表现浮点值时，只在适配层把整数比例转换为 float。

公开能力：

- `next_u31() -> int`
- `next_range(minimum: int, maximum_exclusive: int) -> int`
- `next_ratio_q16() -> int`
- `next_float_range(minimum: float, maximum: float) -> float`
- `derive(root_seed: int, namespace_id: int, stable_id: int) -> DeterministicRng`

namespace 使用固定整数常量，不使用 String hash。

### 随机子流

至少拆分：

- 波次生成。
- 随机拾取掉落。
- 玩家武器玩法散布。
- 玩家武器表现音高和墙体声音。
- 僵尸游荡。
- 僵尸音频。
- 玩家死亡音频。
- 地面血迹与血液冲击。
- 枪口火焰和其他短时表现。

玩家稳定 ID 使用 `player_index`。僵尸稳定 ID 由波次号与波次内序号组合。武器资源增加显式稳定整数 stream ID，不根据 `weapon_id` 字符串 hash。集中式 FX 管理器使用独立表现子流，其调用不会改变任何玩法 RNG 状态。

删除所有：

- `RandomNumberGenerator.randomize()`。
- 全局 `randf()`、`randf_range()` 和 `randi()`。
- `Array.pick_random()`。
- NodePath 或 instance ID 派生随机种子。

## 场景与生命周期集成

### DemoArena

`World/Navigation` 保留场景级位置，但脚本替换为 `IntegerNavigationWorld`。

DemoArena 启动顺序改为：

1. 初始化玩家和 `session_seed`。
2. 初始化整数地图配置。
3. 登记并验证全部静态障碍。
4. 构建初始网格。
5. 生成玩家目标流场。
6. 导航世界进入 ready。
7. 生成第一波僵尸。

整数地图配置失败时不生成波次，并复用现有 HUD 状态区域显示明确错误。

### 动态对象

- `PlaceItemService`：成功放置后提交稳定 obstacle ID、anchor cell 和 footprint；对象退出时提交禁用命令。
- `ExplosiveBarrel`：爆炸完成并禁用碰撞后提交 obstacle 禁用命令，不再发出整图导航标脏信号。
- `PickupSpawnPoint` / `PickupChest`：生成前确定稳定 obstacle ID 和 anchor cell；拾取退出时提交禁用命令。
- `RandomPickupDropManager`：使用根 seed 派生掉落子流，并为生成物分配稳定递增 ID。

所有系统必须先改变实际碰撞状态，再提交对应导航更新，使物理世界与下一个导航 Tick 的逻辑阻挡方向一致。

## 删除与迁移

直接删除旧路径：

- `scripts/navigation/navigation_bake_state.gd`
- `scripts/navigation/navigation_chunk_3d.gd`
- `scripts/navigation/navigation_world_manager.gd`
- `scenes/navigation/NavigationChunk3D.tscn`
- `ZombieTarget.tscn` 中的 `NavigationAgent3D`
- DemoArena 中的 `NavigationRegion3D` / chunk 实例
- `navigation_source` 分组
- 导航烘焙开始、完成、失败和标脏信号
- `NavigationServer3D` iteration ID 查询

新核心可以在实现过程前半段与旧文件同时存在以便独立验证，但正式场景切换任务完成后不得保留运行时双轨选择。

## 错误与边界处理

### 启动失败

以下错误使导航世界初始化失败并阻止波次生成：

- `cell_size_mm <= 0` 或不是偶数。
- `grid_size` 任一维不为正。
- 格子总数超过 `262144`。
- 静态 obstacle ID 重复。
- 静态 footprint 为空或越界。
- 静态碰撞对象没有匹配的整数导航组件。
- 权威 anchor 与碰撞对象位置不符合格子对齐规则。
- 静态碰撞对象水平旋转不是 90 度整数倍。
- 静态碰撞 AABB 的 XZ 投影超出声明 footprint 的世界矩形。

### 动态更新拒绝

以下动态命令被拒绝，旧状态保持不变：

- obstacle ID 无效。
- footprint 为空但命令要求启用。
- 任一目标格越界。
- 同一批次包含同 ID 的多个互相冲突状态。

拒绝必须包含 obstacle ID 和原因，不能部分应用 footprint。

### 流场失败

流场构建使用候选对象。目标、网格版本或数组长度不一致时不提交候选结果，并保留上一份完整流场。

若上一份流场版本已经过期，查询返回明确不可用状态；不得把旧方向当成永久导航结果。

### 实体越界

- 玩家越界：该玩家流场无效，并报告一次警告。
- 僵尸越界：停止导航移动并报告一次警告，不把世界位置强制夹回地图。
- 动态障碍越界：拒绝整条命令。

## 测试策略

该功能属于导航核心与跨系统随机架构重组，行为契约稳定且价值高，允许增加持久化 headless 验证脚本。测试沿用当前 `tools/validation/*.gd` 风格，不恢复已移除的完整通用测试框架。

### 整数网格验证

- 世界毫米、格坐标和 cell ID 往返。
- 负坐标 floor division。
- 地图边界。
- 静态阻挡。
- 动态引用计数。
- 重叠障碍移除。
- obstacle 原子移动。
- 非法动态更新不改变旧状态。
- 每批更新只递增一次 revision。

### 流场验证

- 直线费用 10、斜线费用 14。
- 禁止斜穿墙角。
- 固定 `(cost, cell_id)` 堆顺序。
- 相同费用时较小 next cell ID 获胜。
- 可达与不可达。
- 被阻挡目标的确定性投影。
- 从新阻挡的当前格逃离。
- 相同输入重复构建得到完全相同的 `distance` 与 `next_cell` 数组。
- 网格版本变化后旧候选不得覆盖新结果。

### 游荡路径验证

- home 半径限制。
- 固定最大展开格数。
- 动态阻挡后路径失效。
- 相同 wander 子流选择相同目标与路径。
- 无候选时进入暂停而不是直线穿墙。

### 随机验证

- Park–Miller 金样序列。
- 同根 seed 同 namespace 同稳定 ID 得到同序列。
- 不同 namespace 子流互不影响。
- 一个表现流多消费随机数不会改变玩法流。
- `next_range()` 边界和拒绝采样。
- 同 seed 重建波次、掉落、散布和游荡选择得到相同结果。

### 场景契约验证

- DemoArena 存在 `IntegerNavigationWorld`。
- DemoArena 不包含 `NavigationRegion3D` 或旧 chunk。
- `ZombieTarget` 不包含 `NavigationAgent3D`。
- 项目运行脚本不再引用 `NavigationServer3D`。
- 所有实际导航障碍拥有合法整数组件。
- 放置格按 2×2 导航格映射。
- 爆炸桶、拾取箱和放置物生命周期产生正确动态命令。
- 导航初始化失败时不生成波次。

### 性能结构验证

- 玩家追击流场数量不超过存活玩家数量。
- 24 只僵尸查询共享数组，不创建 24 份整图追击路径。
- 无 obstacle 或目标变化时，不重复构建流场。
- 网格变化时每位玩家最多重建一次活动流场。
- 验证脚本输出 1、2、4 个玩家流场构建耗时作为观察数据，但不设置跨设备脆弱的毫秒断言。

### 自动验证命令

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_integer_navigation.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_deterministic_random.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/validation/validate_integer_navigation_scene.gd
```

### 人工验收

1. 使用同一个 session seed 连续进入两局，记录第一波数量、生成位置、首次掉落、武器散布和僵尸首次游荡目标，确认一致。
2. 玩家移动到集装箱、车辆和固定障碍背面，确认僵尸沿格子路径绕行。
3. 玩家贴近障碍另一侧，确认僵尸不会隔障碍攻击。
4. 放置油桶，确认下一个导航 Tick 后僵尸改道。
5. 引爆或拾取动态障碍，确认格子重新开放且僵尸可以通过。
6. 让动态障碍出现在僵尸当前位置附近，确认僵尸只能向外离开，其他僵尸不会进入阻挡格。
7. 构造不可达玩家，确认僵尸改选可达玩家或停止，不永久直线撞墙。
8. 连续追加波次至 24 只，观察导航更新没有明显 10 Hz 周期性卡顿。

## 完成标准

- 正式 DemoArena 运行时不再创建或查询 Godot 3D 导航对象。
- 所有导航阻挡由整数地图格和整数 obstacle footprint 决定。
- 追击使用每位玩家共享流场，僵尸查询为 O(1)。
- 游荡使用有界局部整数 A*，不会建立逐僵尸整图流场。
- 动态障碍在导航 Tick 原子更新，无整图碰撞解析或 NavMesh 烘焙。
- 相同导航输入产生字节级相同的距离与下一格数组。
- 全项目不再调用 `randomize()`、全局随机函数或 `pick_random()`。
- 相同根 seed 与相同事件顺序产生相同的玩法和表现随机结果。
- 导航不可用或不可达时不存在永久直线穿墙回退。
- Headless 导入检查和三个聚焦验证脚本全部通过。
- 24 只僵尸场景人工验收通过，且没有明显周期性导航尖峰。

## 非目标

- 完整整数物理或 Lockstep 模拟。
- 跨平台逐 Tick 状态 Hash 资格验证。
- 玩家移动、枪械命中、爆炸或伤害系统整数化。
- 僵尸间 avoidance、空间分离或拥挤疏散。
- 多层地图、楼梯、跳跃链接或立体网格。
- 无限地图、流式区块或后台增量流场。
- 导航线程化或 GDExtension 原生实现。
- 菜单中的 seed 输入 UI。
- 自动修改任意浮点碰撞几何来适配网格。
