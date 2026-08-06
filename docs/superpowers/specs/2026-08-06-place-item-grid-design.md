# 放置物网格系统设计

## 目标

删除玩家跳跃功能，并建立可复用于 DemoArena 与未来真实游戏关卡的“放置物（Place Item）”系统。桌面端使用 K 键，移动端使用放置物按钮。DemoArena 作为玩法 playground，首个放置物为爆炸油桶，初始库存 999 个。

放置物不能出现在任意世界坐标。每个可玩场景拥有自己的二维网格占用状态；玩家只能在当前朝向对应的相邻一格放置。地图障碍、已有放置物和临时站在目标格内的角色都会阻止放置。失败不扣库存，成功放置永久消耗 1 个，物品之后销毁也不返还。

## 已确认行为

- 删除 Space 跳跃、移动端跳跃按钮和所有跳跃输入处理。
- 保留重力与离地坠落，角色在未来高低地形上不会悬空。
- 新增输入动作 `place_item`，桌面绑定 K。
- 玩家每次按下 K 或触摸移动端放置按钮只发出一次放置请求。
- DemoArena 的放置物显示名为“油桶”，初始库存为 999。
- 网格单元为 1 米 × 1 米。
- 玩家只能使用面对的相邻一格，不能选择左右其他格。
- 玩家朝向归一为八方向，支持正前、正后、左右和四个对角方向。
- 地图墙体、车辆、集装箱、边界与已有油桶占用其碰撞范围覆盖的网格。
- 玩家或僵尸临时位于目标格时，本次放置失败；角色离开后该格重新可用。
- 目标格被占用、库存为 0 或配置无效时不生成物品，也不扣库存。
- 成功生成后库存减 1；油桶爆炸或因其他原因销毁时释放网格，但不返还库存。
- 移动端用 `PlaceItemButton` 替换跳跃按钮，Demo 中显示“油桶”和当前数量。
- 桌面操作提示显示 K 键、放置物名称和当前数量。

## 场景定位

DemoArena 是玩法 playground，用于验证移动、武器、僵尸、导航、爆炸物和移动端操作。未来真实游戏关卡会建立独立场景，但复用同一套玩家输入、网格占用和放置控制组件。

网格管理器不使用 Autoload。每个可玩场景拥有独立网格、放置物配置、库存、放置容器和导航管理器，符合现有场景级世界状态与导航所有权规则。

## 方案选择

采用“玩家发出通用请求 + 场景级放置控制器 + 场景级网格占用管理器”的拆分方案。

不把油桶场景、999 库存或地图占用逻辑写进 `PlayerController`，否则玩家脚本会依赖 DemoArena。也不只在吸附后的坐标执行一次物理查询，因为这种方式没有稳定的网格所有权，难以处理多格地图障碍、放置物销毁释放和未来其他放置物。

地图制作者不维护独立手绘占用图。静态障碍使用简化碰撞形状自动换算覆盖格，避免碰撞与占用数据产生两套事实来源。

## 组件设计

### `PlayerController`

玩家新增导出输入动作：

```gdscript
@export var place_item_action: StringName = &"place_item"
```

新增信号：

```gdscript
signal place_item_requested(
	requester: CollisionObject3D,
	origin: Vector3,
	direction: Vector3
)
```

存活且物理处理启用时，`Input.is_action_just_pressed(place_item_action)` 只发出一次请求。`origin` 使用玩家 `global_position`，`direction` 使用当前水平 `aim_direction`，因此同一帧改变移动方向并按下 K 时使用玩家新的面对方向。

玩家不知道当前场景放置什么、剩余多少、网格是否可用，也不直接生成节点。

### `PlaceItemGrid`

`PlaceItemGrid` 是场景级 `Node3D`，职责只有网格坐标换算、八方向选择和占用登记，不管理库存或具体 PackedScene。

主要配置：

```gdscript
@export_range(0.25, 4.0, 0.25) var cell_size := 1.0
@export var grid_origin := Vector3.ZERO
@export_flags_3d_physics var dynamic_blocker_mask := 6
@export_range(0.2, 4.0, 0.1) var dynamic_query_height := 1.8
```

主要接口：

```gdscript
func world_to_cell(world_position: Vector3) -> Vector2i
func cell_to_world(cell: Vector2i) -> Vector3
func facing_step(direction: Vector3) -> Vector2i
func target_cell(origin: Vector3, direction: Vector3) -> Vector2i
func reserve_cells(owner: Node, cells: Array[Vector2i]) -> bool
func release_owner(owner: Node) -> bool
func is_cell_reserved(cell: Vector2i) -> bool
func has_dynamic_blocker(
	world: World3D,
	cell: Vector2i,
	excluded: Array[RID]
) -> bool
```

内部使用两个字典：

- `cell_owners: Dictionary`：格坐标到占用节点实例 ID。
- `owner_cells: Dictionary`：节点实例 ID 到其覆盖格数组，便于一次释放多格占用。

### 网格坐标

格子中心与 `grid_origin` 对齐。世界坐标使用最近格中心换算：

```gdscript
cell.x = roundi((world_position.x - grid_origin.x) / cell_size)
cell.y = roundi((world_position.z - grid_origin.z) / cell_size)
```

DemoArena 使用 `grid_origin = Vector3.ZERO`，因此整数 X/Z 坐标是格中心。

面对方向使用八个扇区，每个扇区宽 45 度。水平向量归一化后选择最近的以下一步：

```text
(-1,-1)  (0,-1)  (1,-1)
(-1, 0)  player   (1, 0)
(-1, 1)  (0, 1)   (1, 1)
```

目标格始终为：

```gdscript
world_to_cell(origin) + facing_step(direction)
```

零长度或无效方向拒绝放置，不回退到任意格。

### 地图障碍登记

参与放置占用的静态碰撞根节点加入 `place_item_obstacle` 分组。DemoArena 首版包括：

- 四周边界。
- 车辆碰撞体。
- 两个集装箱碰撞体。
- 场景初始油桶。

地面不加入该分组，因此不会占满整个地图。

`PlaceItemGrid` 在场景 ready 后 deferred 扫描当前场景树中的该分组，确保同场景的 Props 与初始油桶都已进入树。对每个节点的有效 `CollisionShape3D`，读取 Box、Cylinder、Capsule 或 Sphere 简化形状尺寸，将形状局部包围盒转换成世界水平 AABB，并保守登记 AABB 覆盖的全部格子。旋转物体可能多占边角格，但不会允许物品穿入真实碰撞体。

不解析车辆、集装箱或 GLTF 的高精度视觉网格。未知形状记录警告并跳过，由地图作者改用支持的简化碰撞形状。

### 动态阻挡

静态登记通过后，放置前还要在目标格执行一次瞬时 BoxShape3D 查询：

- 水平尺寸略小于 1 格，避免边界接触造成误判。
- 高度为 `dynamic_query_height`，底部略高于地面。
- 默认查询物理层 2 与 3，即玩家和目标。
- 排除发起请求的玩家 RID，避免玩家自身前置武器碰撞体阻止每次放置。
- 其他玩家、僵尸 body 或命中 Area 进入目标格时均阻止放置。

动态角色不写入持久占用字典。

### `PlaceItemController`

`PlaceItemController` 是可复用的场景级 `Node`，负责当前放置物配置、库存、生成和生命周期，不负责具体 HUD 布局。

主要配置：

```gdscript
@export var item_display_name := ""
@export var place_item_scene: PackedScene
@export_range(0, 999999, 1) var initial_item_count := 0
@export_node_path("PlaceItemGrid") var grid_path: NodePath
@export_node_path("Node3D") var placed_items_path: NodePath
```

主要信号：

```gdscript
signal item_count_changed(display_name: String, remaining_count: int)
signal placement_geometry_changed
signal placement_rejected(reason: StringName)
```

主要接口：

```gdscript
func request_place_item(
	requester: CollisionObject3D,
	origin: Vector3,
	direction: Vector3
) -> bool
func get_remaining_count() -> int
```

成功顺序：

1. 验证库存、PackedScene、网格与放置容器。
2. 计算面对的相邻格。
3. 检查持久格占用。
4. 检查动态角色阻挡。
5. 实例化场景，并把节点位置设置为目标格中心。
6. 加入配置的放置容器。
7. 使用真实节点作为 owner 登记目标格。
8. 库存减 1。
9. 连接节点 `tree_exiting`，在销毁时释放 owner 占用。
10. 发出数量变化和导航几何变化信号。

如果实例化或登记失败，立即清理临时节点并保持库存不变。

物品销毁时只释放占用并发出 `placement_geometry_changed`，不增加库存。场景整体退出时释放字典，不向已经退出的关卡发出重烘焙请求。

## DemoArena 接入

DemoArena 增加：

- `World/Placement/PlaceItemGrid`。
- `PlaceItemController`。
- 配置为 `ExplosiveBarrel.tscn`、显示名“油桶”、初始数量 999。
- 放置容器继续使用 `World/Props/ExplosiveBarrels`。

DemoArena 连接：

- `Player.place_item_requested` → `PlaceItemController.request_place_item`。
- `PlaceItemController.item_count_changed` → HUD 与移动端数量同步。
- `PlaceItemController.placement_geometry_changed` → `NavigationWorldManager.mark_chunk_dirty(&"demo_arena")`。

成功添加油桶后标脏导航区块；油桶退出场景并释放格子后再次标脏。已有三个演示油桶继续保留，并在场景初始化时作为地图障碍登记。

## 输入与 UI

### 项目输入

删除 `jump` 动作及 Space 绑定。新增：

```text
place_item = K
```

测试清理、场景启动清理和失焦清理都释放 `place_item`，不再引用 `jump`。

### 移动端

`MobileControls.tscn` 将 `JumpButton` 替换为 `PlaceItemButton`：

- 动作设置为 `place_item`。
- 沿用原跳跃按钮的 120×120 固定触摸尺寸和响应式位置，避免与开火、摇杆重叠。
- 标签为两行文本，Demo 初始显示 `油桶\n999`。
- `MobileControls.set_place_item_status(display_name, remaining_count)` 更新文本。
- `cancel_all_input()` 同时取消开火、放置物与移动输入。
- 支持一根手指持续开火、另一根手指点击放置物。

### 桌面 HUD

删除 `SPACE JUMP` 提示。控制说明包含：

```text
K  油桶 999
```

成功放置后同步改为 998、997。库存为 0 时显示 0，按钮仍可点击，但请求会被控制器拒绝且不生成节点。

## 跳跃移除

`PlayerMotion.next_vertical_velocity()` 改为只处理重力：

```gdscript
static func next_vertical_velocity(
	current_y: float,
	grounded: bool,
	delta: float,
	gravity: float
) -> float:
	if not grounded:
		return current_y - maxf(gravity, 0.0) * maxf(delta, 0.0)
	return minf(current_y, 0.0)
```

`PlayerController` 删除 `jump_action` 和 `jump_speed`。空中动画分支可以保留作为离地/坠落姿势，但任何输入都不能赋予正向 Y 速度。

## 导航一致性

放置物属于运行时导航几何变化：

- 油桶加入场景并完成碰撞登记后，DemoArena 标脏 `demo_arena`。
- 油桶爆炸关闭碰撞、退出场景并释放格子后，再次标脏该区块。
- `PlaceItemController` 只发出几何变化信号，不查找 Autoload 或全局导航管理器。
- 未来真实关卡连接自己的场景级 `NavigationWorldManager` 和 chunk ID。

## 错误与边界处理

- 库存为 0：拒绝 `out_of_stock`，不生成、不扣数量。
- 方向为零：拒绝 `invalid_direction`。
- 目标格已登记：拒绝 `reserved_cell`。
- 玩家或僵尸占位：拒绝 `dynamic_blocker`。
- PackedScene、网格或容器缺失：记录一次清晰警告，拒绝 `invalid_configuration`。
- 场景实例根节点不是 Node3D：立即释放，拒绝 `invalid_scene_root`。
- 目标格登记在实例化之后失败：释放实例，不扣库存。
- 同一物品重复退出或释放：`release_owner()` 幂等，不重复发出库存变化。
- 地图障碍使用未知碰撞形状：记录节点路径与形状类型，跳过该形状。
- 放置物销毁不退款。
- 放置失败不播放成功反馈、不标脏导航。

## 测试策略

本功能属于中等风险玩法与输入改动，使用最小 TDD 矩阵覆盖核心规则，不增加像素级 UI 测试。

### 单元测试

- 项目输入不存在 `jump`，`place_item` 唯一绑定为 K。
- 垂直速度在地面不产生向上速度，空中只应用重力。
- 世界坐标与格坐标按 1 米格和世界原点正确换算。
- 八个面对方向映射到八个相邻格；零方向无目标格。
- 同一格不能被两个 owner 登记；释放 owner 后可以再次登记。
- 地图 Box 与旋转 Box 的世界 AABB 覆盖格得到保守登记。

### 集成测试

- 玩家一次 `place_item` 输入只产生一个请求。
- DemoArena 初始放置物为油桶、库存 999，移动端和桌面 HUD显示一致。
- 玩家面对一个空闲相邻格时成功生成油桶，格中心正确，库存变为 998。
- 连续按键但目标格已被新油桶占用时不再生成，库存仍为 998。
- 墙体、车辆、集装箱和初始油桶覆盖格拒绝放置且不扣库存。
- 僵尸临时站在空闲目标格时拒绝，离开后可以放置。
- 放置油桶成功时导航区块标脏。
- 放置的油桶爆炸退出后释放网格但库存不返还，原格可再次放置。
- 移动端 `PlaceItemButton` 使用 `place_item`，显示名称与数量，并可与开火使用不同触摸 ID 同时操作。
- 场景和测试输入清理不再引用 `jump`，会释放 `place_item`。

### 自动验证

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
./tests/run_tests.sh
git diff --check
```

### 人工验收

1. 桌面端确认 Space 不再跳跃，K 在面对的相邻网格放置油桶。
2. 面向八个方向分别放置，确认只使用对应相邻格。
3. 面向墙体、车辆、集装箱、油桶或僵尸按 K，确认不生成且数量不变。
4. 在空格放置后确认数量减 1，油桶爆炸后数量不返还，但该格可再次放置。
5. 移动端确认原跳跃按钮变成“油桶 999”，数量实时更新，可与开火多指同时使用。
6. 连续放置和销毁油桶后，确认僵尸导航能使用最新障碍布局。

## 非目标

- 放置预览、幽灵模型、格子高亮或旋转选择 UI。
- 手动选择左右格或远距离格。
- 拖拽放置、连续按住自动放置。
- 库存拾取、退款、存档或跨场景持久化。
- 多格可放置建筑、升级、拆除或建造时间。
- 坡地、多层网格或三维体素占用。
- 把 DemoArena 改造成正式游戏关卡。
