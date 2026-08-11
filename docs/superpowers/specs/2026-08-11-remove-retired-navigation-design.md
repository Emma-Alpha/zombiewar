# 退役导航系统硬删除设计

## 背景

僵尸寻路已经迁移到 `scripts/sim/` 下的确定性整数网格流场。旧的 NavMesh、导航服务器调用和运行时异步烘焙仍以退役代码、场景节点、信号和分组的形式留在项目中，但玩法不再消费其结果。

这些遗留内容会继续初始化导航服务、响应无效的几何变化信号，并让后续开发者误以为项目仍有两套有效导航系统。本次清理采用硬删除，不保留兼容层或功能开关。

## 目标

- 删除旧导航管理器、分块烘焙器、烘焙状态及其场景资源。
- 删除 `DemoArena` 中的旧导航节点、资源声明、失败回调和动态烘焙唤醒逻辑。
- 删除只服务旧烘焙系统的 `navigation_geometry_changed` 信号链。
- 删除只用于旧几何收集的 `navigation_source` 场景分组。
- 更新项目约定，明确旧导航代码已经移除，僵尸导航只允许使用确定性流场。
- 保持现有流场阻挡更新、拾取箱生命周期、放置物和爆炸桶行为不变。

## 非目标

- 不修改 `FlowFieldGrid`、`FlowField` 的算法或参数。
- 不重构放置物、拾取箱或爆炸桶的模拟层阻挡协议。
- 不删除历史设计文档；它们保留为架构演进记录。
- 不引入新的导航抽象、兼容信号或迁移开关。

## 删除范围

### 旧实现与资源

删除以下文件及对应 UID：

- `scripts/navigation/navigation_world_manager.gd`
- `scripts/navigation/navigation_chunk_3d.gd`
- `scripts/navigation/navigation_bake_state.gd`
- `scenes/navigation/NavigationChunk3D.tscn`

### DemoArena 集成

从 `DemoArena.tscn` 删除旧脚本和 PackedScene 外部资源、`World/Navigation` 节点及分块实例。

从 `demo_arena.gd` 删除：

- 导航管理器依赖绑定。
- 烘焙失败提示回调。
- `_on_runtime_navigation_geometry_changed()`。
- 爆炸桶、拾取生成器、随机掉落管理器和放置服务对旧几何变化信号的连接。

保留真正影响确定性流场的路径：

- 拾取箱通过 `blocker_changed` 更新 `SimWorld` 阻挡矩形。
- 放置物通过 `item_placed`、`item_removed` 更新阻挡矩形。
- 爆炸桶由 `SimWorld.spawn_barrel()` 和模拟 Tick 内的引爆事件维护阻挡。

### 信号和分组

删除以下只服务旧烘焙系统的内容：

- `PickupSpawnPoint.navigation_geometry_changed`
- `RandomPickupDropManager.navigation_geometry_changed`
- `ExplosiveBarrel.navigation_geometry_changed`
- 所有场景节点上的 `navigation_source` 分组

其中 `place_item_obstacle` 分组继续作为启动时静态阻挡收集入口，不做改名。

## 数据流

清理后的阻挡数据流只有一条权威路径：场景或玩法事件先得到世界 AABB，再通过 `SimWorld.set_blocker_world_rect()` 或爆炸桶专用接口写入整数阻挡网格；网格置脏后，在固定模拟 Tick 内同步重建流场。

旧系统的“场景几何变化 → 标记导航分块 → 后台烘焙 NavMesh”数据流被完整删除。

## 风险与处理

- **漏删类型引用导致脚本解析失败**：用源码扫描和 Godot 无头导入检查发现。
- **误删有效阻挡通知导致僵尸穿过动态物体**：保留并运行拾取箱、流场、碰撞和确定性验证。
- **场景资源编号变化**：仅删除对应外部资源和节点，不手工重排其余资源 ID。
- **历史文档仍包含旧 API 名称**：允许存在；验证只约束运行时代码、场景和当前项目约定。

## 验证

1. 扫描运行时代码和场景，确认不再出现旧导航类型、服务器调用、异步烘焙信号和 `navigation_source` 分组。
2. 运行 Godot 无头编辑器导入检查，确认脚本与场景可解析。
3. 运行 `validate_flow_field.gd`。
4. 运行 `validate_sim_collision.gd`。
5. 运行 `validate_sim_determinism.gd`。
6. 运行拾取箱与随机掉落相关验证，确认动态阻挡出现和消失仍会更新流场。

## 完成标准

- 旧导航实现和场景资源已从仓库删除。
- 游戏运行时只剩确定性整数网格流场导航。
- 所有旧名称均从运行时代码、场景和当前项目约定中消失。
- 无头导入及相关验证通过。
