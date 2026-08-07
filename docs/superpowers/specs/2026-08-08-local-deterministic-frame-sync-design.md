# 本地确定性帧同步与共享屏幕迁移设计

**日期：** 2026-08-08

**状态：** 已确认

**范围：** 无网络服务器、无 WS/ENet、单人模式、本地 2～4 人共享屏幕、本地帧命令、固定 Tick、确定性模拟、输入录像、状态 Hash、100+ 僵尸迁移基础

## 背景

项目当前以 Godot 场景树、Jolt Physics 和 NavigationServer3D 作为实际游戏状态来源。玩家和僵尸分别在各自的物理回调中读取输入、更新浮点速度、执行碰撞和导航；枪械、近战、爆炸、拾取及放置也直接读取 Godot 物理查询结果。

这种结构适合当前单机原型，但不适合后续跨平台帧同步：不同平台的浮点、Jolt 碰撞顺序、运行时导航烘焙、Timer、动画回调和场景生命周期都可能导致状态分歧。同时，每只僵尸独立持有 CharacterBody3D、NavigationAgent3D、命中区域、动画和 3D UI，也不利于把同屏数量提高到 100 只以上。

本阶段不建设中间服务器，不实现 WebSocket、ENet、客户端权限、状态纠正或回滚。目标是先在本地建立唯一的帧同步游戏循环，并保证单人和当前本地 2～4 人共享屏幕模式继续可玩。后续网络只应把远端帧命令送入同一个帧缓冲，不改变模拟接口。

## 已确认决策

- 第一阶段完全本地运行，不启动或依赖任何中间服务器。
- 第一阶段不实现 WS、ENet、WebRTC、RPC 或 MultiplayerSynchronizer。
- 单人和本地 2～4 人使用完全相同的帧命令和模拟流程。
- 单人只启用玩家槽位 0；本地多人按大厅结果启用槽位 0～3。
- 模拟采用固定 30 Hz Tick；显示层独立插值。
- 第一版本地输入延迟为 0 Tick，不人为增加操作延迟。
- 确定性模拟不使用 CharacterBody3D、Godot 物理查询、NavigationAgent3D 或运行时 NavMesh。
- 模拟坐标限制为平坦 XZ 平面，使用整数或定点表示。
- 当前按屏幕边缘限制玩家移动的逻辑改为确定性的世界坐标队伍范围约束。
- 摄像机只消费模拟位置，不再反向改变玩家位置或攻击方向。
- 迁移期间保留当前 DemoArena 玩法路径；新模拟在旁路场景或明确功能开关下建设，达到功能等价后再切换，避免主游戏长期处于半迁移状态。

## 目标

1. 建立唯一的固定 Tick 游戏循环，所有玩法状态只在 SimulationWorld.step() 中推进。
2. 单人和本地 2～4 人都先生成定长帧命令，再由本地帧缓冲提交模拟。
3. 支持输入录像、回放、逐 Tick 状态 Hash 和首个分歧 Tick 定位。
4. 建立稳定玩家槽位和模拟实体 ID，不依赖 NodePath、RID 或 instance_id。
5. 将玩家世界边界和共享屏幕队伍范围改为整数世界规则。
6. 建立独立于 Godot 物理和导航的二维地图格、碰撞、流场和空间索引边界。
7. 为后续迁移僵尸、武器、爆炸、拾取、放置和波次提供统一事件与状态接口。
8. 最终在最低目标 Web 或移动设备上支持至少 100～150 只活跃僵尸的 30 Hz 模拟。
9. 保留当前模型、动画、音频、特效、HUD、输入设备适配和本地多人大厅体验。

## 非目标

- 中间服务器、匹配、房间服务或网络大厅。
- WebSocket、ENet、WebRTC 或自定义网络传输。
- 网络输入延迟、丢包、乱序、重连或中途加入。
- 权威服务器、主机权限、作弊防护或状态裁决。
- 自动快照纠正、客户端预测或完整回滚。
- 继续使用 Jolt、NavigationAgent3D 或运行时 NavMesh 作为模拟判定来源。
- 任意高度 3D 地形、跳跃、楼梯、车辆刚体或复杂动态刚体。
- 第一阶段直接承诺 300～500 只完整骨骼僵尸的渲染性能。
- 在迁移尚未达到功能等价时删除当前可玩的旧实现。

## 总体架构

~~~mermaid
flowchart LR
    Devices["键盘、手柄、触控"] --> Collector["LocalInputCollector"]
    Session["LocalSimulationSession"] --> Collector
    Collector --> Commands["LocalFrameCommandSet"]
    Commands --> Buffer["LocalFrameInputBuffer"]
    Buffer --> Runner["LocalFrameSyncDriver"]
    Runner --> Sim["SimulationWorld.step"]
    Sim --> State["整数模拟状态"]
    Sim --> Events["确定性表现事件"]
    State --> Bridge["SimulationViewBridge"]
    Events --> Bridge
    Bridge --> Views["Godot 玩家、僵尸、动画、FX、HUD"]
    Sim --> Tape["InputTape 与 StateHash"]
~~~

本地模式不需要 Transport 抽象或本地回环 Socket。LocalInputCollector 直接把完整帧命令提交 LocalFrameInputBuffer，但命令仍使用固定字段和稳定二进制编码，以便后续网络层可以在帧缓冲之前接入。

后续增加网络时，扩展点固定为：远端传输解码出同一种 LocalFrameCommandSet，再调用帧缓冲的提交接口。SimulationWorld、表现桥和本地输入格式不因网络接入而改变。

## 会话和玩家槽位

### LocalSimulationSession

LocalSimulationSession 在进入战斗时从现有 GameSession 读取模式和本地玩家描述，创建不可变的本局配置：

- session_seed
- rules_version
- map_id
- active_player_mask
- player_slot 到输入源的映射
- 模拟 Tick 频率
- 地图与玩法配置 Hash

玩家槽位固定为 0～3。单人模式 active_player_mask 为 0001；本地多人根据大厅加入人数启用连续槽位。战斗开始后不支持热加入、退出槽位或更换设备。

模拟中的玩家实体 ID 直接由固定槽位派生，不使用场景节点实例 ID。表现层可以自由销毁和重建 PlayerView，只要继续绑定相同模拟实体 ID。

### 设备断开

本地多人战斗中，已绑定手柄断开时暂停模拟 Tick，并显示等待设备恢复的界面。暂停期间不生成中性输入、不推进冷却、不让角色继续受到攻击。相同设备 ID 恢复后重新采样并继续下一 Tick。

此规则避免设备状态以未记录的方式改变模拟，同时保持当前本地合作体验。第一阶段不允许其他设备接管断开的槽位。

## 帧命令

每个模拟 Tick 只提交一个定长 LocalFrameCommandSet：

    LocalFrameCommandSet
    - tick: int
    - active_player_mask: int
    - player_commands[4]

    PlayerFrameCommand
    - move_heading: int
    - action_bits: int
    - equipment_delta: int
    - placement_heading: int

move_heading 使用 0 表示静止，1～16 表示预定义的十六方向。模拟层不接收 Vector2、摇杆浮点值或摄像机 Basis。输入采集层使用本局固定的镜头朝向配置把设备方向转换成世界 heading，不读取正在平滑或震动的 Camera3D Basis；输入录像和回放也不会再次读取摄像机。

action_bits 至少包含：

- USE_HELD
- USE_PRESSED
- PREVIOUS_EQUIPMENT
- NEXT_EQUIPMENT
- CONFIRM

玩家静止时，模拟状态保留上一次有效朝向。武器开火、近战和放置读取模拟朝向，不读取模型旋转或武器视觉节点。

命令字段使用明确位宽编码到 PackedByteArray。输入录像不使用 JSON、Dictionary 或 Variant 序列化，避免字段顺序和大整数经过 JavaScript Number 时失真。

## 本地输入采集

现有 KeyboardWasdInputSource、KeyboardArrowsInputSource、GamepadInputSource、TouchInputSource 和 CompositeInputSource 继续负责设备层采样，但不再直接控制 PlayerController。

LocalInputCollector 每个模拟 Tick 按玩家槽位升序执行：

1. 从绑定输入源获取 PlayerInputState。
2. 把移动向量量化为十六方向 heading。
3. 把按下、按住和装备切换编码为 action_bits。
4. 生成四槽位定长命令集合。
5. 对未启用槽位写入全零命令。
6. 提交到 LocalFrameInputBuffer。

单人 CompositeInputSource 仍可合并两套键盘、全部已连接手柄和触控输入。本地多人继续使用大厅中独占的设备映射。

## 固定 Tick 与帧推进

模拟频率固定为 30 Tick/s。Godot 物理频率显式保持 60 Hz，LocalFrameSyncDriver 使用整数二分频每两个 Godot 物理回调执行一个模拟 Tick，不把物理 delta 传入模拟。性能不足时允许模拟落后于真实时间，但不得跳过模拟 Tick。

LocalFrameSyncDriver 只在当前 Tick 的 active_player_mask 对应命令全部存在时调用：

    simulation_world.step(tick, frame_commands)

SimulationWorld.step() 不接收 delta。所有持续时间在进入本局前换算为整数 Tick：

- 0.5 秒攻击前摇为 15 Tick。
- 1.4 秒攻击冷却为 42 Tick。
- 0.12 秒油桶连锁延迟按确定规则换算为 4 Tick。

渲染帧率、掉帧和窗口刷新率只能改变表现插值，不能改变模拟计算结果。调试模式支持暂停、单步 Tick、倍速执行和无渲染快速回放。

第一阶段 input_delay 固定为 0。帧缓冲仍按 Tick 索引保存命令，以验证未来输入延迟和网络接入所需的数据边界。

## 确定性数值规则

- 1 Godot 世界单位等于 1024 个模拟单位。
- 模拟 X/Z 坐标、速度、半径和距离使用整数存储。
- 位置和速度保持在 int32 设计范围内，中间乘法使用 GDScript int64。
- 核心算法不得依赖整数溢出；输入和配置在本局初始化时进行上界校验。
- 除法和负数取模统一通过 FixedMath 的 floor_div 和 euclidean_mod 实现。
- 方向使用预烘焙整数查找表，不在模拟中调用 sin、cos、atan2 或 normalized。
- 距离和范围判断优先使用距离平方，不调用 sqrt。
- 生命、伤害、弹药、冷却、波次和库存全部使用整数。
- Dictionary 可以用于按 ID 查询，但模拟逻辑不得依赖 Dictionary 遍历顺序。

确定性随机数第一版固定使用 Park–Miller 31 位 PRNG，乘数为 48271、模数为 2147483647，种子状态范围为 1～2147483646。世界、波次、掉落和实体随机流相互独立，并全部纳入状态快照和 Hash。随机范围转换使用固定 rejection sampling，不使用浮点数或简单取模偏差。不得使用 RandomNumberGenerator.randomize、全局 randf 或 NodePath hash 作为玩法随机源。

## SimulationWorld 数据结构

SimulationWorld 不继承 Node，不持有场景节点引用。热路径优先使用预分配的 PackedInt32Array、PackedByteArray 或定长类型数组。

僵尸采用 SoA 结构：

    zombie_alive[]
    zombie_generation[]
    zombie_pos_x[]
    zombie_pos_z[]
    zombie_velocity_x[]
    zombie_velocity_z[]
    zombie_heading[]
    zombie_health[]
    zombie_state[]
    zombie_target_id[]
    zombie_cooldown_tick[]
    zombie_rng_state[]

第一版容量目标为至少 256 只僵尸，压测容量为 512。模拟遍历按槽位或稳定实体 ID 升序执行。实体死亡立即从玩法状态中失效；尸体动画播放多久不影响波次、掉落或存活数量。

## 固定系统顺序

每个 Tick 严格执行：

1. 验证并应用玩家命令。
2. 处理装备切换和放置请求。
3. 提交本 Tick 生效的动态障碍变化。
4. 更新需要重建的流场。
5. 计算玩家候选移动和地图碰撞。
6. 批量执行队伍范围约束。
7. 更新僵尸目标选择、状态机和移动意图。
8. 执行僵尸空间哈希和局部分离。
9. 结算枪械、近战和僵尸攻击。
10. 结算爆炸及连锁触发。
11. 按稳定排序统一应用伤害。
12. 处理死亡、掉落、拾取和波次状态。
13. 统一生成和销毁模拟实体。
14. 输出带稳定 event_id 的表现事件。
15. 编码规范状态并计算 Hash。

遍历过程中不直接增删实体。伤害、生成、销毁和地图修改先写入命令缓冲，按阶段、来源实体 ID、本地序号和目标实体 ID 排序后提交。

## 玩家移动、地图碰撞和共享屏幕

### 玩家移动

玩家移动只发生在 XZ 平面。加速、减速、击退和受击硬直保留当前玩法语义，但改为每 Tick 的整数参数。地图碰撞使用预烘焙阻挡格和确定性的圆形或胶囊投影，不调用 move_and_slide 或 is_on_floor。

同一 Tick 的玩家候选位置先全部计算，再统一处理玩家之间及队伍范围的约束，避免某个玩家节点先处理而获得隐藏优势。需要稳定 Tie-break 时使用玩家槽位升序，并固定先处理 X 轴、再处理 Z 轴。

### 地图边界

DemoArena 的模拟地图边界转换为整数 Rect2i 或等价结构。单人玩家只受地图碰撞和地图边界限制，不再受屏幕分辨率或安全边距影响。

### 队伍活动范围

本地 2～4 人共享屏幕使用世界坐标队伍范围，而不是摄像机投影约束。初始配置为：

- 最大 X 跨度：24 Godot 单位。
- 最大 Z 跨度：18 Godot 单位。

这两个值在本局开始时换算为整数，并纳入玩法配置 Hash。

TeamBoundsSystem 的处理规则：

1. 只统计仍存活的玩家。
2. 先完成各玩家地图碰撞，得到所有候选位置。
3. 分别计算候选位置的最小和最大 X/Z。
4. 跨度未超过上限时全部接受。
5. 超过上限时，以前一 Tick 存活玩家包围盒中点为约束中心，批量裁剪向外扩张的候选位置。
6. 固定先解析 X，再解析 Z；同值按玩家槽位升序。
7. 约束只改变模拟位置，不读取摄像机或视口。

玩家倒地后不参与队伍跨度约束，避免其他玩家被倒地位置永久锁住。

### 共享摄像机

FollowCamera 改为纯表现组件：

- 读取当前和上一模拟 Tick 的玩家显示位置。
- 根据渲染插值计算可见位置和队伍中心。
- 保留平滑、镜头推动和射击震动等视觉效果。
- 不再向 PlayerController 或模拟核心提供移动边界。
- 不同宽高比可以调整正交 size 或留白，但不得改变模拟位置。

## 地图网格与僵尸导航边界

模拟地图由离线工具从简化碰撞体生成二维网格资源，并作为项目资源提交。运行时只加载和验证该资源，不根据客户端当前场景重新生成。建议初始格子尺寸为 0.5 Godot 单位，即 512 模拟单位。

静态碰撞体和 navigation_source 分组可以继续作为编辑器导图来源，但运行时 SimulationWorld 只读取已经生成的整数阻挡格。动态油桶、拾取箱和放置物在指定 Tick 修改格子占用。

100+ 僵尸采用共享 Flow Field：

- 每个有效玩家目标或目标区域维护反向距离场。
- 邻居访问顺序固定。
- 相同代价按 cell_id 选择。
- 玩家跨格或动态障碍变化时在固定 Tick 标记重建。
- 当前 DemoArena 的流场在指定 Tick 内同步、原子重建；不创建线程或等待异步回调。
- 如果后续大地图需要增量重建，必须按固定 cell_id 顺序和固定每 Tick 单元预算推进，完成前继续使用旧场。

SimulationWorld 不读取 NavigationAgent3D、NavigationServer3D iteration ID 或运行时 NavMesh 烘焙结果。

## 战斗与玩法迁移边界

武器、难度和拾取的现有 tres 资源继续作为编辑配置来源。离线构建工具把它们转换成只包含整数的 SimConfig 资源并提交；本局启动时只加载和验证 SimConfig，模拟进行中不读取原始 Resource 浮点属性。SimConfig 与地图资源共同组成玩法 manifest，并纳入配置 Hash。

枪械使用整数线段与目标圆形或胶囊投影相交。近战使用整数扇形、圆形或矩形范围。爆炸使用距离平方和网格遮挡。所有命中候选按距离参数和实体 ID 排序，距离相同时优先较小实体 ID。

Godot 武器节点只负责：

- 模型显示。
- 枪口火焰。
- 音频。
- 曳光弹。
- 后坐力和镜头表现。

模拟层负责：

- 射速和攻击 Tick。
- 弹药与装备。
- 散布随机数。
- 命中、穿透和伤害。
- 爆炸及连锁。
- 死亡、掉落和拾取归属。

表现事件包含 tick、event_id、事件类型、来源实体 ID、目标实体 ID 和必要的量化位置。动画、音频、血迹和 HUD 只能消费事件，不得回写模拟状态。

## 输入录像、状态 Hash 与诊断

InputTape 至少记录：

- 协议与规则版本。
- 地图和配置 Hash。
- session_seed。
- active_player_mask。
- 每 Tick 的四槽位命令。

StateHasher 对规范化整数状态编码结果计算 SHA-256。编码顺序固定为：世界头、玩家槽位、僵尸槽位、其他实体、动态地图、PRNG 状态、波次状态、待执行事件。确定性测试每 Tick 计算；正常本地游玩默认每 30 Tick 计算一次诊断 Hash。

Hash 不包含动画、摄像机、节点 Transform、音频、粒子、HUD、网络状态或对象实例 ID。

调试工具必须能够：

- 同进程运行两个 SimulationWorld。
- 一个实例直接接收命令，另一个经过编码和解码后接收命令。
- 每 Tick 比较 Hash。
- 首次分歧时导出 Tick、输入帧和规范状态差异。
- 无渲染快速执行至少 100,000 Tick。

## 迁移与切换策略

该工作属于核心重建级，不在一个实现任务中一次性替换全部玩法。采用旁路迁移和阶段切换：

### 阶段 A：本地帧同步基础

- LocalSimulationSession。
- LocalInputCollector。
- LocalFrameCommandSet。
- LocalFrameInputBuffer。
- LocalFrameSyncDriver。
- InputTape、StateHasher 和双实例测试工具。
- 空或最小 SimulationWorld。

### 阶段 B：玩家和共享屏幕

- 单人及 2～4 人整数玩家状态。
- 地图整数边界和基础阻挡格。
- 玩家移动、击退和受击硬直。
- TeamBoundsSystem。
- PlayerView 和 FollowCamera 表现桥。

### 阶段 C：僵尸和群体导航

- 僵尸 SoA 状态。
- 空间哈希。
- Flow Field。
- 目标选择、游荡、追击、攻击状态机。
- 100～150 只模拟性能基线。

### 阶段 D：完整战斗与玩法循环

- 手枪、步枪、匕首。
- 穿透、散布、弹药和装备切换。
- 油桶、爆炸和连锁。
- 放置物和动态障碍。
- 拾取、掉落、波次、失败和重新开始。

### 阶段 E：表现和 100+ 优化

- SimulationViewBridge 完整事件接入。
- 僵尸视图池。
- 血条、动画和音频距离分级。
- 血迹及 FX 限流和池化。
- 最低目标设备压测。

当前 DemoArena 在阶段 D 达到功能等价前继续作为默认可玩路径。新模拟使用独立测试入口或功能开关，禁止长期让一部分玩法由 SimulationWorld 决定、另一部分玩法继续由旧场景节点决定。切换默认路径时，旧玩法判定逻辑一次性退为表现层或移除。

## 错误与边界处理

- active_player_mask 与 GameSession 玩家数量不一致：拒绝创建本局并返回菜单错误。
- 玩家槽位缺少输入源：不开始战斗。
- 战斗中设备断开：暂停模拟并等待相同设备恢复。
- 本地帧缺少任一启用槽位命令：不推进 Tick，并在调试版本报告错误。
- 命令字段越界：转换为中性命令并记录诊断；测试环境直接失败。
- 地图或配置 Hash 与 InputTape 不一致：拒绝回放。
- 实体容量耗尽：按固定规则拒绝本次生成，写入确定性诊断事件，不动态扩容热数组。
- 不支持的地图几何或配置数值超界：本局初始化失败，不在模拟中降级为 Godot 物理。
- 双实例 Hash 分歧：立即停止测试并导出首个分歧 Tick。
- 表现节点丢失：模拟继续运行，表现桥记录警告并在节点恢复后按当前状态重建，不修改模拟。

## 测试策略

确定性模拟属于稳定且高价值的行为契约，允许为其新增持久自动测试。

### 单元测试

- 十六方向输入量化和静止朝向保持。
- 帧命令二进制编码与解码。
- active_player_mask 的 1、2、3、4 人组合。
- 固定整数除法、取模、距离和方向表。
- 玩家地图边界和阻挡格碰撞。
- TeamBoundsSystem 的 X/Z 跨度、同时向外移动、倒地玩家排除和 Tie-break。
- 稳定实体 ID、容量耗尽和 Tick 末命令提交。
- PRNG 金样序列。
- 规范状态编码和 Hash 金样。

### 确定性回放测试

- 同一进程双实例逐 Tick Hash 相同。
- 单人、2 人和 4 人固定输入录像。
- 不同渲染帧率下回放结果相同。
- Headless 和正常启动读取同一录像结果相同。
- 随机输入、攻击、死亡、障碍变化和波次组合至少执行 100,000 Tick。

### 性能测试

- 100、150、256 和 512 个僵尸容量档位。
- 最低目标 Web 或移动设备上，100～150 只、30 Hz 模拟 P95 小于 8 ms。
- P99 不持续超过 16 ms。
- 玩家聚集、群体追击、连续射击、爆炸链、动态障碍和大量死亡同时发生。
- 模拟数组、事件队列、视图池和材质数量不持续增长。

### 自动验证

- /Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
- /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://scripts/simulation/testing/determinism_test_runner.gd

### 人工验收

1. 单人从主菜单进入战斗，键盘、手柄和触控输入正常。
2. 本地多人大厅加入 2～4 名玩家并进入共享屏幕战斗。
3. 玩家能够同时向不同方向移动，达到队伍范围边缘时只阻止继续分散，不阻止队伍整体移动。
4. 玩家倒地后不把其他玩家锁在原位置附近。
5. 摄像机保持所有存活玩家可见，分辨率变化不改变玩家世界位置。
6. 输入录像可以完整重放同一局，结果和 Hash 一致。
7. 100～150 只僵尸下移动、攻击、死亡、拾取、放置和波次循环保持可玩。

## 完成标准

- 单人与本地 2～4 人只通过 LocalFrameCommandSet 驱动模拟。
- 所有玩法时间使用整数 Tick，不依赖 delta、Timer 或动画回调。
- 玩家和僵尸的玩法移动不依赖 Godot Physics 或 NavigationServer3D。
- 当前主要武器、油桶、拾取、放置和波次玩法完成模拟迁移。
- 共享屏幕不再通过摄像机投影限制玩家位置。
- 同一 InputTape 在同平台重复运行至少 100,000 Tick 零 Hash 分歧。
- 最低目标设备达到 100～150 只僵尸性能门槛。
- 当前模型、动画、FX、音频、HUD 和本地多人大厅继续可用。
- 网络传输仍未实现，但未来可以在 LocalFrameInputBuffer 之前提交同格式远端帧命令，无需修改 SimulationWorld。
