# zombiewar-server

zombiewar 的联机后端：Cloudflare Worker + D1 + Durable Objects。

三件事：

| 能力 | 实现 | 落点 |
| --- | --- | --- |
| 匿名设备身份 | `POST /api/auth/anon` | D1 `players` / `sessions` |
| 队伍波次榜 / 个人击杀榜 | `GET /api/leaderboard/*` | D1 `scores` |
| 房间大厅 + 20Hz 帧中继 | `RoomDurableObject` | Durable Object（内存）+ D1 `rooms` 目录 |

## 为什么房间必须是 Durable Object

Worker 是无状态的，D1 存不下一条长连接。一局 4 人对战需要一个**唯一**的东西
同时持有四条 WebSocket、一个权威 tick 计数器和一个 50ms 的定时器——这正是
Durable Object 的定义。房间用 `idFromName(房间码)` 寻址，所以同一个房间码在全球
永远只解析到同一个对象实例。

注意这里用的是普通 `webSocket.accept()` 而**不是** WebSocket Hibernation：
会休眠的对象持不住那个 50ms 的定时器，而那个定时器就是这局对战的时钟本身。

## 帧同步模型

服务端是唯一的 tick 权威，但它**不跑模拟**：

```
客户端 --cmd(输入 + 量化位置 + 开火事件)--> 房间 DO
房间 DO --f(tick, 四个座位这一 tick 的命令)--> 全部客户端
```

每个客户端收到一帧就把模拟推进**恰好一个 tick**，队列空就原地等。
关键取舍是**玩家位置也是输入**：`SimWorld.set_player_snapshot()` 本来就把玩家
坐标当外部输入吃进来，所以只要各端喂进去的是同一份量化坐标，僵尸、伤害、
爆炸桶就逐位一致——不需要让 `move_and_slide()` 跨端逐位一致，那是这套方案
比全量帧同步省下的绝大部分工作量。

本机玩家的身体仍然由本地输入即时驱动（手感），只是它上报的位置要经过一个
RTT 才进入所有人的模拟。

不同步检测靠客户端每 20 tick 附一次 `SimHasher` 帧哈希；房间发现两个座位对同一
tick 报出不同哈希就广播 `desync`。房间**不尝试修复**——它没有自己的模拟可用来
仲裁。把这件事说响，好过让它半年后以「僵尸咬到我却没咬到你」的形式出现。

## 首次部署

```bash
cd server
npm install

# 1. 建 D1，把打印出来的 database_id 填进 wrangler.jsonc
npx wrangler d1 create zombiewar

# 2. 建表
npm run db:remote

# 3. 部署 Worker（会一并创建 RoomDurableObject 命名空间）
npm run deploy
```

部署完拿到形如 `https://zombiewar-server.<账号>.workers.dev` 的地址，
把它填进 `scripts/net/net_config.gd` 的 `DEFAULT_BASE_URL`，或者在游戏的
联机大厅里直接改「服务器」输入框（写入 `user://net.cfg`，不进版本库）。

## 本地联调

```bash
npm run db:local     # 只需一次
npm run dev          # http://localhost:8787
```

游戏侧指过去的三种办法，任选：

- 联机大厅的「服务器」输入框填 `http://localhost:8787` 再点「切换」。
- 写 `user://net.cfg`：`[net]` 段下 `base_url="http://localhost:8787"`。
- Web 导出加查询参数：`index.html?server=http://localhost:8787`。

> `https://` 会自动映射到 `wss://`，`http://` 映射到 `ws://`。浏览器不允许
> https 页面连 ws://，所以线上环境两边都必须是 TLS——Workers 默认就是。

## 反作弊边界

**没有公开的成绩提交接口。** `scores` 表的唯一写入路径是
`submitMatchResult()`，只有房间 DO 在对局结束后调用它。客户端够不到写路径，
就伪造不了成绩，无论它对自己的内存做什么。

客户端能做的是在 `result` 上报里撒谎，这由 `crossValidateReports()` 处理：
所有人跑的是同一份确定性模拟，健康的一局里各端报出的数字应当逐字节相同。

- 票数按**座位**算，不按上报次数算：一个座位一票，先到的那次算数。
- 需要**严格多数**且至少两票：2 人房里两份报告不一致就是无证据，作废。
- 先投票，后封顶。反过来会让一个报了「合理数值」的骗子把全房拖进
  投票本该终结的争论里。
- 单人房永远不写榜——没有交叉验证的对象。UI 上直接写明「至少 2 人才能上榜」。

`MAX_ZOMBIES_PER_WAVE` 是从客户端刷怪配置反推的（`demo_arena.gd` 每波每角最多
18 只 × 4 角 = 72，取 96 留余量）。**改了客户端刷怪上限就必须同步改它**，
否则要么放过伪造，要么把正常成绩判成伪造。

## 身份不是认证

`POST /api/auth/anon` 拿一个**客户端自己生成的** device_id 换令牌。没有密码、
没有注册、没有校验。任何人都能声称任何 device_id。令牌只能证明一件事：
持有者调用过一次这个接口。

它存在的理由是**接口形状比实现更贵**：现在定下「身份放在
`Authorization: Bearer` 里」只花一个文件，将来接平台账号时改动也只落在
`src/lib/sessions.ts` 加 `routes` 的入参校验上，所有下游端点一个字节都不用动。

响应里的 `authenticated: false` / `auth_mode` 就是把这件事告诉客户端的契约。
排行榜面板的「未认证」角标读的是这个字段，**不是**「我拿到令牌了」。

## 协议漂移

协议常量在两个地方各存一份：`src/lib/protocol.ts` 与
`res://scripts/net/lobby_protocol.gd`。它们靠两道闸门保持一致：

1. 握手时服务端比对 `protocol_version`，不符立刻以 **4001** 关闭，
   关闭原因里同时写出 `peer=` 与 `local=` 两个版本号。
2. `tools/validation/validate_online_frame_sync.gd` 直接读
   `src/lib/protocol.ts` 的源码，逐个常量与 GDScript 侧对拍。

改协议的任何一边，都要把版本号加一，并且跑一次那个验证脚本。

## 端点

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/health` | 协议版本、tick 频率、房间人数上限 |
| POST | `/api/auth/anon` | `{device_id, nickname}` -> 令牌 |
| GET | `/api/leaderboard/team` | 队伍波次榜，按 room_id 归组 |
| GET | `/api/leaderboard/kills` | 个人击杀榜 |
| GET | `/api/leaderboard/me?board=` | 本人最好成绩与名次（需令牌） |
| POST | `/api/rooms` | 建房，返回房间码 |
| GET | `/api/rooms` | 公开房列表（仅大厅中、未满、2 分钟内活跃） |
| GET | `/api/rooms/:code` | 房间是否存在与当前状态 |
| GET | `/ws/rooms/:code` | 升级为 WebSocket，转交房间 DO |
