# 联机房间界面重做设计（角色/地图选择接缝）

## 背景

现有联机大厅 `scenes/menu/OnlineLobby.tscn` 是一块单屏表单：昵称输入框、服务器地址、
房间码、房间列表 `ItemList`，以及一个把整个座位表渲染成多行文本的 `roster_label`
（`scripts/menu/online_lobby.gd:209`）。它能用，但没有"房间"的实感——玩家看不到自己是谁、
看不到别人选了什么、也无从知道这局要打哪张图。

目标形态是《泡泡堂》那类联机房间：每个座位一张卡片，卡里站着该玩家的 3D 角色，
卡下方一条准备横幅；房主额外拥有一张地图卡，可以换图。玩家在**点准备之前**可以换角色，
准备之后锁定。

这份设计只覆盖其中的第一块。完整需求被拆成三个独立 spec：

| | 内容 | 状态 |
|---|---|---|
| **A** | 房间界面 + 角色/地图选择的协议与数据接缝（本文档） | 本次 |
| B | 角色系统：四个角色的三围与专属被动 | 另开 |
| C | 第二张真实地形 | 另开 |

拆分理由：A 是唯一一个做完就能看见目标界面的切片，而且它建立的接缝决定了 B 和 C 怎么插进来。
反过来先做内容，接缝未定，两次都得返工。

### 现状约束

以下事实约束了设计空间，均已核对代码：

- **座位数硬编码为 4**，出现在 `scripts/sim/sim_world.gd:23`、`scripts/net/lobby_protocol.gd:59`、
  `server/src/types.ts:26`，且 `resources/maps/demo/demo_map.tres:313` 正好只有 4 个
  `player_spawn_positions`。本设计不改这个数字。
- **共享单摄像机**：`scripts/camera/shared_camera_math.gd:44` 取全体玩家重心，
  `scripts/camera/player_screen_bounds.gd:54` 再把每个人夹在屏幕内。座位数是摄像机问题，
  不是数组长度问题，故不在本设计范围内。
- **玩家移动与血量在表现层**，`SimWorld` 只保存量化后的位置快照与 alive/present 位
  （`scripts/sim/sim_world.gd:167`）。因此角色三围差异不破坏锁步——这一点是 B 的前提，
  在此记录。
- **两个玩家描述符鸭子类型同形**（`scripts/net/online_player_descriptor.gd`、
  `scripts/input/local_player_descriptor.gd`），`LocalPlayerSpawner` 两边通吃。
  这是角色系统覆盖三种模式的天然接缝。
- **`GameplayArena` 已完全数据驱动**，`scenes/maps/demo/DemoMap.tscn` 只是 7 行的壳，
  `MapDefinition` 本就带 `map_id` / `display_name` / `content_scene`。
- **`startMatch()` 会压实座位**（`server/src/room_do.ts:431`），slot 号在开局瞬间会变。
- **lobby 态下断线的座位直接移除**（`server/src/room_do.ts:635`），准备状态判定无需特判掉线。
- **协议版本双端硬编码、握手当场比对**，不一致以 4001 关闭。

## 设计

### 1. 数据层：角色目录与地图目录

新增两个 Resource，沿用项目既有的 `.tres` 数据驱动风格：

```
CharacterDefinition                    CharacterCatalog
  character_id: StringName               entries: Array[CharacterDefinition]
  display_name: String                   default_id() -> StringName
  accent_color: Color                    get_by_id(id) -> CharacterDefinition
```

- `scripts/gameplay/character/character_definition.gd`
- `scripts/gameplay/character/character_catalog.gd`
- `resources/characters/character_catalog.tres` + 四个角色 `.tres`

`MapCatalog` 与之同形，装 `Array[MapDefinition]`。`MapDefinition` 补两个字段供地图卡使用：
`thumbnail: Texture2D` 与 `difficulty: int`（1..5）。

**跨线传输的是 id 字符串，不是数组下标。** 往目录中插入一个角色不会给其他角色重新编号，
也就不存在"新旧客户端对同一个下标理解不同"这种静默错位。

**A 阶段即产出 4 个角色 definition**，区分手段是颜色。两条理由：

1. 选择链路必须有多于一个选项才测得了。
2. 它解决一个当下就存在的问题——联机时四人共用同一个 GLTF，场上分不清谁是谁。

B 阶段的三围与被动直接往这四个 definition 上加字段，不重开资源。

**配色的落地方式是脚下光环 + 名牌 + 卡片描边，不是模型整体染色。**
角色使用单张 atlas（`assets/characters/Characters_Lis_SingleWeapon_Zombie_Atlas.png`），
`material_override` 会把脸和武器一并染色。三处配色在俯视视角下反而更易读。

### 2. 协议 v4

`scripts/net/lobby_protocol.gd:10` 与 `server/src/lib/protocol.ts:11` 同时抬到 `4`。

新增两条客户端消息：

| 消息 | 发送方 | 服务端前置校验 | 副作用 |
|---|---|---|---|
| `{type:'select_character', character_id}` | 任意座位 | 该座位 `ready === false`；`roomState === 'lobby'` | 广播 roster |
| `{type:'select_map', map_id}` | 仅房主 | `slot === hostSlot`；`roomState === 'lobby'` | **清空所有座位的 ready**，广播 roster |

换图清空准备，是因为大家的准备是对着旧图点的。

消息载荷扩展：

- `join` 增加 `character_id`（客户端在入房时就带上具体 id，不留空串）
- `roster` 每个条目增加 `character_id`；顶层增加 `map_id`
- `start` 的 `slots[]` 每项增加 `character_id`；顶层增加 `map_id`

`start` 必须携带这些值：座位在开局瞬间被压实，slot 号会变，选择只能挂在 seat 上由服务端
按压实后的编号发回，客户端不能靠记忆自己选了什么。

**服务端不维护 id 白名单**，只做形状校验：非空字符串、匹配 `^[a-z0-9_]{1,32}$`。
否则每加一个角色就要发一次 Worker。代价转移到客户端：

> 收到 `start`（或 `roster`）中出现本机目录里不存在的 `map_id` / `character_id` 时，
> **拒绝入局并显示明确错误**，不静默回退到默认值。

锁步游戏里静默回退等于两端跑不同的图，必须是一次响亮的失败。这与项目对协议版本
"拒绝兼容"的既有取向一致。

### 3. 服务端改动（`server/src/room_do.ts`）

- `Seat` 增加 `characterId: string`，取自 `join` 消息。
- 房间增加 `mapId: string`，由房主客户端在成为房主后以具体 id 写入。
- `handleMessage` 的 `switch (type)` 增加 `select_character` / `select_map` 两个 case。
- `case 'start'` 增加全员准备闸门：

```ts
if (slot !== this.hostSlot) return;
if (this.occupiedSeats().some((e) => e.slot !== this.hostSlot && !e.seat.ready)) {
  this.diag('start_rejected', { why: 'not_all_ready' });
  return;
}
this.startMatch();
```

房主自身不需要点准备。单人房主开局天然通过（不存在其他座位）。拒绝是静默的加一行
`diag`，与该 `switch` 中其他分支的处理方式一致；客户端按钮置灰只是提示，规则在服务端。

- `roster()` 与 `startMatch()` 的广播载荷按第 2 节扩展。

前置校验不通过的 `select_character` / `select_map`（座位已准备、非房主、房间不在 lobby 态、
id 形状非法）一律**静默忽略并记一行 `diag`**，不回错误消息也不断开连接。这与 `start` 被拒
时的处理一致：客户端界面本就不该让玩家发出这些消息，收到即意味着客户端有 bug 或有人手搓，
两种情况都不值得为之新增一条错误消息类型。

### 4. 客户端界面结构

`scenes/menu/OnlineLobby.tscn` 内放两棵互斥的 `Control` 子树，由同一个场景托管，
`NetSession` 的信号订阅只写一份：

```
OnlineLobby (Node3D)              状态宿主 + NetSession 信号订阅
├─ BrowserPanel  (Control)        未入房
│    昵称 / 服务器地址 / 房间码 / 房间列表 / 建房 / 加入 / 刷新（现有控件原样迁入）
└─ RoomPanel     (Control)        已入房
     ├─ SeatCard ×4               SubViewportContainer(3D 角色 Idle)
     │                            + 昵称 + 房主徽标 + 准备横幅 + 空位态
     ├─ MapCard                   缩略图 + 名称 + 难度星；房主可点，其余人只读
     └─ ActionRow                 准备 / 开始 / 返回
```

**换角色的交互落在本机那张座位卡上**：卡片左右两侧各一个箭头，在目录内循环切换，
每次切换即刻发一条 `select_character`。不做弹层——只有四个角色时，循环比弹层少一次点击。
本机已准备时箭头隐藏。其他玩家的卡片没有箭头。

**换地图的交互落在地图卡上**：房主点击卡片弹出地图列表（每项为缩略图 + 名称 + 难度星），
选中即发 `select_map` 并关闭。非房主点击无响应，卡片以只读样式呈现。

角色预览沿用 `scenes/menu/LobbyPlayerPreview.tscn` 已有的做法（实例化 GLTF、
隐藏非展示武器、播 `Idle_Gun`），装进每张卡自己的 `SubViewport`：渲染分辨率 256×384，
`render_target_update_mode = UPDATE_WHEN_VISIBLE`。

选 SubViewport 而不是"单个 3D 场景 + Control 叠加"，是因为卡片是 2D 网格布局，
把 `Marker3D` 世界坐标对齐到 Control 网格需要 unproject 手调，而本项目要在手机上跑
（存在 `MobileOrientationGuard`），宽高比变化时极易错位。

**`SeatCard` 是纯展示组件**，对外只有 `set_seat(entry, is_host, is_local)` 一个入口，
不知道网络存在。同理 `MapCard` 只接受一个 `MapDefinition` 和一个"是否可编辑"标志。

`scripts/menu/online_lobby.gd` 现有 283 行，承担了身份、服务器配置、房间浏览、座位渲染、
延迟显示、场景切换六件事。本次拆为：

- `online_lobby.gd` — 状态宿主：订阅 `NetSession` 信号，在两个面板间切换，处理开局跳转
- `scripts/menu/room_browser_panel.gd` — 身份、服务器、房间列表、建房/加入
- `scripts/menu/room_panel.gd` — 座位卡与地图卡的编排，准备/开始按钮状态
- `scripts/menu/seat_card.gd`、`scripts/menu/map_card.gd` — 两个展示组件

**对参考截图的一处有意偏离**：截图左上角有一个放大的本机角色预览与独立準備按钮。
4 卡布局下不做——本机那张卡改为高亮描边，准备按钮统一置于底部动作条。
放大预览是 8 卡两列布局挤压出来的需求，4 卡不需要。

### 5. 三种模式共用同一套接缝

- `OnlinePlayerDescriptor` 与 `LocalPlayerDescriptor` 各增加 `character_id: StringName`。
- `GameSessionState` 增加 `map_id: StringName`。
- `LocalPlayerSpawner` 解析 `character_id` 取得 `CharacterDefinition`，
  把 `accent_color` 落到脚下光环、名牌与血条上。
- `GameplayArena` 在 `map_definition` 未设置时，改为从 `GameSession.map_id` 查 `MapCatalog`。
  `DemoMap.tscn` 保留并继续硬绑 definition，以便编辑器内 F5 直接调试单图。

**A 阶段单机与本地多人不新增选角交互**：只有一个可选项时那个界面没有意义。
两处只填入默认 `character_id` / `map_id`，把接缝打通。选角 UI 随 B 一并进入
`LocalMultiplayerLobby` 与主菜单。

### 6. 验证

- `tools/validation/validate_lobby_player_preview.gd:22` 当前断言"预览必须是那个 GLTF"，
  改为"必须来自 `CharacterCatalog` 中某个 definition"。
- 新增 `tools/validation/validate_character_catalog.gd`、`validate_map_catalog.gd`：
  id 唯一、非空、匹配 `^[a-z0-9_]{1,32}$`、引用字段非空、`default_id()` 命中目录内条目。
- 新增 `tools/validation/validate_online_room_panel.gd`：实例化 `OnlineLobby.tscn`，
  断言两个面板互斥、四张 `SeatCard` 各自持有独立 `SubViewport`、空位态与占位态渲染无报错。
- 协议一致性：`server/src/lib/protocol.ts` 的注释提到一个 `protocol/fixtures/` 目录用于
  双端常量比对，**该目录实际不存在**，注释是过期的。本次**只把注释改对**，不搭建
  fixture 比对设施——那是独立议题，塞进本次会把范围撑开，而握手时的版本号比对已经
  覆盖了它真正要防的那类漂移。
- 手动验收：两台客户端各自建房/加入，验证换角色广播、准备锁定选择、房主换图清空准备、
  未全员准备时开始按钮不可用且服务端也拒绝、开局后双端角色配色一致。

## 已知风险（本次不修）

**内容漂移不受协议版本保护。** 两个客户端持有不同版本的 `demo_map.tres` 今天就会不同步，
协议版本号只覆盖协议本身。加入选图功能会显著提高撞上这个问题的概率
（房主选了新客户端才有的图）。第 2 节的"未知 id 拒绝入局"能挡住"图不存在"这一种，
挡不住"同名不同内容"。彻底的解法是在握手时比对内容摘要，属于独立议题。

## 范围外

- 不改动座位数（保持 4）、不改共享摄像机取景。
- 不实现角色三围与被动（B）。
- 不搭建第二张地形（C）。
- 不在单机/本地多人加入选角交互（随 B）。
- 不改动房间列表的 D1 表结构，房间列表不显示地图名。
- 不改动同步层二进制帧、帧历史、重连逻辑。
- 不做角色模型替换（`Player.tscn` 将 GLTF 作为子节点烘进场景，武器挂点与动画均绑定该子树，
  换模型是独立改动）。
