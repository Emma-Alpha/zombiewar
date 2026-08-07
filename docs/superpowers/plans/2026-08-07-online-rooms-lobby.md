# S2 房间与大厅 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `zombiewar-server` 落地房间码建房、公开房列表、WebSocket 大厅与心跳重连，并在 `zombiewar` 客户端接出 `RoomClient` / `NetworkInputSource` / `OnlineLobby`，让 4 人联机沿用现有的 descriptor 生成路径。

**Architecture:** 服务端把房间拆成两层——`rooms.ts` 是纯函数式状态机（lobby → starting → playing → ended），只吃注入的时钟与随机源，不引用任何 socket；`room_hub.ts` 是唯一持有 socket 的层，负责握手校验、广播、心跳巡检与结算收集。客户端 `RoomClient` 用 `WebSocketPeer` 收发同一套 JSON 大厅消息，`match_start` 到达后把 `player_slots` 翻译成 `OnlinePlayerDescriptor` 列表交给现有的 `LocalPlayerSpawner`。

**Tech Stack:** Node ≥ 20.11、TypeScript 5、Fastify 5、`@fastify/websocket`、`better-sqlite3`、Vitest；Godot 4.7.1、GDScript、`WebSocketPeer`。

## Global Constraints

- 本仓库基线提交为 `5423871`（`merge: design online multiplayer server`）。执行前若主线继续前进，先确认下列目标文件接口仍与本计划一致。
- 服务端是**独立新仓库** `/Users/liangpingbo/Desktop/4399/game/zombiewar-server`，与 `/Users/liangpingbo/Desktop/4399/game/zombiewar` 同级。本计划的 S1 前置任务已建立其工程骨架、`src/lib/sessions.ts`、`src/lib/db.ts`、`src/lib/leaderboard.ts`、`src/app.ts`、`src/config.ts`。
- 客户端 S1 前置产物为 `scripts/net/net_config.gd`、`scripts/net/identity_store.gd`、`scripts/net/api_client.gd`，本计划直接消费，不重写。
- **主仓库没有常驻自动化测试套件。** 客户端验证一律写成 `tools/validation/validate_*.gd` 一次性脚本。**不得恢复 `tests/` 或 `tests/run_tests.sh`。**
- 服务端仓库使用 Vitest，常驻测试放在 `zombiewar-server/test/`。
- 房间上限 **4 人**；**不支持战斗中热加入**；沿用共享镜头。
- 房间码为 **6 位大写字母数字**，字母表 `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`（剔除易混的 `I` `O` `0` `1`）。
- 建房可选 `public`（进公开列表）或 `code_only`（仅房间码可见）。
- 心跳：客户端每 **5 秒** 发 `ping`；服务端 **15 秒** 未收到判定掉线。
- `lobby` 状态掉线直接移出席位；`playing` 状态**保留席位 30 秒**，客户端用 `session_token` 重连恢复原 slot；超时把该 slot 标记为已断开，对局继续。
- 房主掉线：`lobby` 状态移交给**最早加入的剩余成员**；`playing` 状态**不移交**。
- `match_start` 负载固定为 `{seed, tick_rate: 20, map_id: "demo_arena", player_slots: [{slot, player_id, nickname}]}`。
- 二进制 opcode 号段：`0x00–0x7F` 为大厅与控制消息，`0x80–0xFF` **整段预留给 S3 同步层**。本轮只划定号段并写入 `PROTOCOL.md`，不实现任何 `0x80+` 消息。
- 握手强制版本校验：首帧 `join` 必须携带 `protocol_version` 与 `token`；版本不匹配时服务端先发 `error` 帧（含 `server_protocol_version` 与 `client_protocol_version`），再以 close code `4400` 关闭。
- 成绩只能由房间服写入。`room_hub` 收齐 `match_result` 后按 `room.members` 构造 `slots` 并调用 S1 的 `submitMatchResult(db, { roomId, season, slots, reports, durationMs })`；1 人房不写榜、多数投票、合理性上限全部由 `leaderboard.ts` 内部判定，本计划不重复实现。
- Fastify 监听 `0.0.0.0:8787`；客户端 base URL 由 `net_config.gd` 提供并可被 `user://net.cfg` 覆盖，**不得硬编码 LAN IP**。
- `LocalPlayerSpawner.spawn_players()` 的 descriptor 消费路径不新增任何联机分叉：descriptor 列表消费、`create_input_source()` 调用、出生点解算、共享安全区校验、失败回滚全部逐行保持。本计划对该文件的唯一编辑是第 33 行的模式闸门改为 `session.is_multiplayer()`，让 `Mode.ONLINE_MULTIPLAYER` 落到同一条 descriptor 路径上。**这与 spec 第 485 行「一行不改」的措辞冲突，因此 Task 10 Step 1 会先提交一次 `docs:` 修订把该行改写为「descriptor 消费路径一行不改；唯一允许的编辑是第 33 行的模式闸门」，再动代码。**
- 客户端静态检查命令固定为 `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit`。
- 提交信息使用 Conventional Commits（`feat:` / `fix:` / `docs:` / `test:` / `chore:`）。两个仓库各自提交，互不混合。
- GDScript 一律使用制表符缩进；TypeScript 使用 2 空格缩进、单引号、`.js` 后缀的 ESM 相对导入（`NodeNext`）。

### 跨计划权威约定（S0 / S1 / S2 已对齐，执行期不得再议）

这一节记录三份计划共同裁定的唯一事实源。**任何一条与执行时读到的真实代码不符，都要先停下来核对是不是前置计划没按修订版执行，而不是就地改本计划。**

- **线格式**：大厅帧是**扁平 JSON**（`{"type": ..., ...字段}`），没有 `payload` 嵌套。S1 原先的 `{protocol_version, type, payload}` 信封与 `src/lib/protocol.ts` 已在 S1 修订版里删除；服务端协议目录唯一为 `src/lib/protocol/`。
- **`src/lib/protocol/version.ts` 由 S1 Task 5 创建**（导出 `PROTOCOL_VERSION = 1` 与 `readProtocolVersionFromMarkdown(markdown)`），本计划只消费、不重建。`protocol/PROTOCOL.md` 同样由 S1 Task 5 创建（只含「版本号」与「fixtures」两节），本计划 **Modify** 它、追加其余各节。
- **客户端协议镜像唯一文件为 `scripts/net/lobby_protocol.gd`**（`class_name LobbyProtocol`）。S1 原先的 `scripts/net/protocol_codec.gd` 与 `tools/validation/validate_protocol_codec.gd` 已在 S1 修订版里删除，其 fixtures 对拍职责合并进本计划 Task 14 的 `validate_online_lobby_wiring.gd`。
- **昵称规则唯一实现在 S1 的 `src/lib/sessions.ts`**（`NICKNAME_MIN_LENGTH` / `NICKNAME_MAX_LENGTH` / `NICKNAME_BLOCKLIST` / `normalizeNickname`，按码点计数，失败时抛 `HttpError`）。`src/lib/rooms.ts` 只做**再导出**，不得另写一份。
- **数据库句柄类型唯一为 S1 `src/lib/db.ts` 导出的 `Db`**；本计划不从 `better-sqlite3` 直接 import `Database`。
- **`@fastify/websocket` 的安装与 `app.register(websocket)` 唯一归 S1**（S1 Task 1 已把它写进 `dependencies`，S1 Task 6 的 `buildApp()` 已注册）。本计划只安装 `@types/ws` 并追加 `app.register(roomRoutes, ...)`；重复注册会以 `FST_ERR_DEC_ALREADY_PRESENT` 一类错误让 `buildApp()` 直接失败。
- **写榜入口唯一为 S1 `src/lib/leaderboard.ts` 的 `submitMatchResult(db: Db, options: SubmitMatchOptions): SubmitMatchResult`**，载荷全部是 snake_case：`MatchSlot = { slot: number; player_id: string }`、`MatchReport = { player_id: string; team_wave: number; player_kills: Record<string, number> }`、`SubmitMatchResult = { status: 'accepted' | 'no_majority' | 'too_few_players' | 'too_short' | 'out_of_range'; team_wave: number; player_kills: Record<string, number>; dissenters: string[]; reason: string; written: number }`。不存在 `recordMatchResults` 这个名字。
- **客户端 base URL 取名唯一为 `NetConfig.get_http_base_url()` / `NetConfig.get_ws_base_url()`**（S1 修订版已把 `get_base_url` 改名并新增 ws 变体），`build_url(path)` / `build_ws_url(path)` 保留但本计划不使用——房间服下发的是完整 `ws_path`，需要的是 base URL 本身。
- **`ApiClient` 唯一为回调式**：`ApiClient.new(host: Node)`、`request_json(method: String, path: String, body: Variant = null, on_result: Callable = Callable(), authenticate: bool = true) -> void`，回调签名 `(ok: bool, status_code: int, payload: Dictionary)`，统一结果字典的键为 `{"ok", "status_code", "payload", "error_code", "error_message"}`。大厅是事件驱动的，`refresh_rooms()` / `create_room()` / `join_by_code()` 都不能阻塞 `_ready` 与按钮回调。
- **主菜单按钮顺序与焦点链权威为 `SinglePlayerButton → LocalMultiplayerButton → OnlineMultiplayerButton → LeaderboardButton → QuitButton`**。本计划 Task 12 先插 `OnlineMultiplayerButton`（改 `LocalMultiplayerButton.focus_neighbor_bottom` 与 `QuitButton.focus_neighbor_top`），**S1 Task 12 在本计划之后执行**，把 `LeaderboardButton` 插在 `OnlineMultiplayerButton` 与 `QuitButton` 之间。
- **`GameSessionState.Mode.ONLINE_MULTIPLAYER`（值 `2`）的所有权归 S0 Task 10**，它先执行且只加枚举值。本计划 Task 10 在其基础上**追加** `online_room` / `configure_online()` / `is_multiplayer()` / `attach_online_client()` / `release_online_client()`，**不重写 `enum Mode`、不整体替换该文件**。
- **`match_start.seed` 必须被消费**：spec 第 532 行要求各客户端用同一 seed 初始化 `SimWorld`。本计划 Task 10 在 `demo_arena._setup_simulation()` 里用 `session.online_room["seed"]` 覆盖 `random_seed`，并断言 `online_room["tick_rate"]` 与 `SimClock.TICK_SECONDS` 对得上；Task 14 再把「20Hz」这个数字在客户端两处之间钉死。
- **跨计划共享的文件一律不使用行号锚点**：`scripts/gameplay/demo_arena.gd`、`scripts/gameplay/game_session.gd`、`scenes/menu/MainMenu.tscn`、`scripts/menu/main_menu.gd`、`scripts/menu/menu_flow.gd`、`tools/validation/validate_local_multiplayer_menu_scenes.gd` 在 S0 / S1 / S2 之间被反复改写，任何 `:起-止` 都会在对方改完后失效。这些文件只用唯一的文本锚点定位。
- **spec 偏离登记（ticket 校验时机）**：spec 第 546 行写「ticket 无效或过期 → 拒绝 WebSocket 升级」。因为断线重连路径**不带 ticket**（改用 `session_token`），本计划把 ticket 兑换推迟到首帧 `join`：升级阶段只校验房间是否存在（不存在返回 404），ticket 无效/过期时先发 `error(ticket_invalid | ticket_expired)` 再以 close code `4401` 关闭。Task 6 Step 1 会先提交一次 `docs:` 修订把 spec 该行改成同一措辞。
- **`match_result` 的上报链路在本计划里必须两端都有产生方**：服务端收集与写榜在 Task 5，客户端的 `RoomClient.report_match_result()` 由 Task 13 的 `demo_arena` 结算路径调用。任何一端缺失都会让写榜变成死代码——这正是本计划新增 Task 13 的原因。

---

### Task 1: 服务端房间码分配器

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/room_code.ts`
- Test: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/test/room_code.test.ts`

**Interfaces:**
- Consumes: S1 已建立的 `zombiewar-server` 工程骨架（`package.json` 含 `"test": "vitest run"`、`tsconfig.json` 的 `module: "NodeNext"` 与 `strict: true`、`vitest.config.ts` 的 `include: ['test/**/*.test.ts']`）。
- Produces: `ROOM_CODE_ALPHABET: string`、`ROOM_CODE_LENGTH: number`、`ROOM_CODE_MAX_ATTEMPTS: number`、`type RandomIndex = (maxExclusive: number) => number`、`class RoomCodeExhaustedError extends Error`、`normalizeRoomCode(value: string): string`、`isRoomCode(value: string): boolean`、`generateRoomCode(randomIndex?: RandomIndex): string`、`allocateRoomCode(isTaken: (code: string) => boolean, randomIndex?: RandomIndex): string`。

- [ ] **Step 1: 确认服务端骨架已就位**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
ls package.json tsconfig.json vitest.config.ts src/lib/sessions.ts src/lib/db.ts src/app.ts
git log --oneline -1
```

Expected: 六个文件全部存在；`git log` 输出 S1 的最后一个提交。若任一文件缺失，先完成 S1 计划再回到本计划。

- [ ] **Step 2: 写入房间码分配器**

创建 `src/lib/room_code.ts`：

```ts
import { randomInt } from 'node:crypto';

/**
 * 房间码要被人念出来再手输，所以字母表剔除了 I / O / 0 / 1 这四个易混字符。
 * 剩余 32 个符号 × 6 位 ≈ 1.07e9 种组合，配合 allocateRoomCode 的重试足够。
 */
export const ROOM_CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export const ROOM_CODE_LENGTH = 6;
export const ROOM_CODE_MAX_ATTEMPTS = 64;

export type RandomIndex = (maxExclusive: number) => number;

export class RoomCodeExhaustedError extends Error {
  readonly code = 'code_exhausted';

  constructor(readonly attempts: number) {
    super(`could not allocate a free room code after ${attempts} attempts`);
    this.name = 'RoomCodeExhaustedError';
  }
}

export function normalizeRoomCode(value: string): string {
  return value.trim().toUpperCase();
}

export function isRoomCode(value: string): boolean {
  if (value.length !== ROOM_CODE_LENGTH) return false;
  for (const character of value) {
    if (!ROOM_CODE_ALPHABET.includes(character)) return false;
  }
  return true;
}

export function generateRoomCode(randomIndex: RandomIndex = randomInt): string {
  let code = '';
  for (let position = 0; position < ROOM_CODE_LENGTH; position += 1) {
    const picked = ROOM_CODE_ALPHABET[randomIndex(ROOM_CODE_ALPHABET.length)];
    code += picked ?? 'A';
  }
  return code;
}

export function allocateRoomCode(
  isTaken: (code: string) => boolean,
  randomIndex: RandomIndex = randomInt,
): string {
  for (let attempt = 0; attempt < ROOM_CODE_MAX_ATTEMPTS; attempt += 1) {
    const code = generateRoomCode(randomIndex);
    if (!isTaken(code)) return code;
  }
  throw new RoomCodeExhaustedError(ROOM_CODE_MAX_ATTEMPTS);
}
```

- [ ] **Step 3: 写入房间码测试**

创建 `test/room_code.test.ts`：

```ts
import { describe, expect, it } from 'vitest';

import {
  allocateRoomCode,
  generateRoomCode,
  isRoomCode,
  normalizeRoomCode,
  ROOM_CODE_ALPHABET,
  ROOM_CODE_LENGTH,
  ROOM_CODE_MAX_ATTEMPTS,
  RoomCodeExhaustedError,
  type RandomIndex,
} from '../src/lib/room_code.js';

/** 把一串期望产出的房间码翻译成逐字符的下标序列，让生成过程完全确定。 */
export function scriptedIndex(codes: string[]): RandomIndex {
  const characters = codes.join('').split('');
  let cursor = 0;
  return () => {
    const character = characters[cursor] ?? 'A';
    cursor += 1;
    return ROOM_CODE_ALPHABET.indexOf(character);
  };
}

describe('房间码字母表', () => {
  it('长度为 6 且剔除易混字符', () => {
    expect(ROOM_CODE_LENGTH).toBe(6);
    expect(ROOM_CODE_ALPHABET).toBe('ABCDEFGHJKLMNPQRSTUVWXYZ23456789');
    for (const forbidden of ['I', 'O', '0', '1']) {
      expect(ROOM_CODE_ALPHABET).not.toContain(forbidden);
    }
  });

  it('生成的码总是通过 isRoomCode', () => {
    for (let i = 0; i < 200; i += 1) {
      const code = generateRoomCode();
      expect(code).toHaveLength(6);
      expect(isRoomCode(code)).toBe(true);
    }
  });

  it('拒绝长度错误或含易混字符的码', () => {
    expect(isRoomCode('ABCDE')).toBe(false);
    expect(isRoomCode('ABCDEFG')).toBe(false);
    expect(isRoomCode('ABCDE0')).toBe(false);
    expect(isRoomCode('ABCDEI')).toBe(false);
    expect(isRoomCode('abcdef')).toBe(false);
  });

  it('normalizeRoomCode 去空白并转大写', () => {
    expect(normalizeRoomCode('  ab2de f ')).toBe('AB2DE F');
    expect(normalizeRoomCode(' pq34rs ')).toBe('PQ34RS');
  });
});

describe('allocateRoomCode', () => {
  it('碰撞时继续重试直到拿到未占用的码', () => {
    const taken = new Set(['AAAAAA', 'BBBBBB']);
    const random = scriptedIndex(['AAAAAA', 'BBBBBB', 'CCCCCC']);
    expect(allocateRoomCode((code) => taken.has(code), random)).toBe('CCCCCC');
  });

  it('第一次就不碰撞时只生成一次', () => {
    let calls = 0;
    const random: RandomIndex = (max) => {
      calls += 1;
      return max - 1;
    };
    const code = allocateRoomCode(() => false, random);
    expect(calls).toBe(ROOM_CODE_LENGTH);
    expect(code).toBe('999999');
  });

  it('全部碰撞时抛出 RoomCodeExhaustedError', () => {
    const random = scriptedIndex(Array.from({ length: ROOM_CODE_MAX_ATTEMPTS }, () => 'AAAAAA'));
    expect(() => allocateRoomCode(() => true, random)).toThrow(RoomCodeExhaustedError);
  });
});
```

- [ ] **Step 4: 运行房间码测试与类型检查**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
npx vitest run test/room_code.test.ts
npx tsc -p tsconfig.json --noEmit
```

Expected: Vitest 报告 `Test Files 1 passed`、`Tests 7 passed`；`tsc` 无输出且退出码为 0。

- [ ] **Step 5: 提交房间码分配器**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
git add src/lib/room_code.ts test/room_code.test.ts
git commit -m "feat: add room code allocator"
```

Expected: 提交只包含这两个文件，不含 `node_modules/` 或 `dist/`。

---

### Task 2: 服务端房间状态机（纯逻辑，不引用 socket）

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/rooms.ts`

**Interfaces:**
- Consumes:
  - Task 1 的 `allocateRoomCode(isTaken, randomIndex?)`、`normalizeRoomCode(value)`、`isRoomCode(value)`、`ROOM_CODE_ALPHABET`、`ROOM_CODE_LENGTH`、`type RandomIndex`。
  - **S1 `src/lib/sessions.ts` 的 `NICKNAME_MIN_LENGTH`、`NICKNAME_MAX_LENGTH`、`normalizeNickname(raw: unknown): string`**（唯一实现；按码点计数、带 `NICKNAME_BLOCKLIST`，失败时抛 S1 `src/lib/http.ts` 的 `HttpError`，`code` 为 `invalid_nickname` / `nickname_blocked` / `invalid_body`，`statusCode` 为 `400`）。`rooms.ts` **只做再导出**，让后续 Task 的 import 路径统一走 `./rooms.js`，但事实源仍是 `sessions.ts`。
- Produces:
  - 常量：`MAX_MEMBERS = 4`、`PING_INTERVAL_MS = 5000`、`PING_TIMEOUT_MS = 15000`、`RECONNECT_GRACE_MS = 30000`、`START_COUNTDOWN_MS = 3000`、`TICKET_TTL_MS = 30000`、`EMPTY_ROOM_GRACE_MS = 30000`、`ENDED_ROOM_TTL_MS = 30000`、`SWEEP_INTERVAL_MS = 250`、`MATCH_RESULT_COLLECT_MS = 10000`、`DEFAULT_TICK_RATE = 20`、`DEFAULT_MAP_ID = 'demo_arena'`、`MAX_ROOMS = 500`、`ROOM_LIST_MAX_LIMIT = 50`。
  - 类型：`RoomState = 'lobby' | 'starting' | 'playing' | 'ended'`、`RoomVisibility = 'public' | 'code_only'`、`MatchEndReason = 'wiped' | 'host_ended' | 'abandoned'`、`RoomMember`、`Room`、`Ticket`、`TicketClaim`、`CreateRoomInput`、`LeaveOutcome`、`MemberRef`、`SweepReport`、`PublicRoom`、`RoomMemberPayload`、`RoomStatePayload`、`MatchStartPayload`、`RoomErrorCode`。
  - `class RoomError extends Error { readonly code: RoomErrorCode; readonly statusCode: number }`
  - 再导出（**不是新实现**）：`export { NICKNAME_MIN_LENGTH, NICKNAME_MAX_LENGTH, normalizeNickname } from './sessions.js';`
  - `class RoomStore`，方法签名：
    - `constructor(options?: RoomStoreOptions)`
    - `get size(): number`
    - `createRoom(input: CreateRoomInput): Room`
    - `getRoom(roomId: string): Room | undefined`
    - `requireRoom(roomId: string): Room`
    - `getRoomByCode(code: string): Room | undefined`
    - `requireRoomByCode(code: string): Room`
    - `listPublicRooms(offset: number, limit: number): { total: number; items: Room[] }`
    - `issueTicket(room: Room, playerId: string, nickname: string): Ticket`
    - `peekTicket(ticketId: string, roomId: string): Ticket`
    - `redeemTicket(ticketId: string, roomId: string): TicketClaim`
    - `joinRoom(roomId: string, claim: TicketClaim): { room: Room; member: RoomMember }`
    - `rejoinRoom(roomId: string, sessionToken: string): { room: Room; member: RoomMember }`
    - `setReady(roomId: string, slot: number, ready: boolean): { room: Room; member: RoomMember }`
    - `setNickname(roomId: string, slot: number, nickname: string): { room: Room; member: RoomMember }`
    - `applyPing(roomId: string, slot: number): number`
    - `requestStart(roomId: string, slot: number): Room`
    - `cancelStart(roomId: string): Room`
    - `endMatch(roomId: string, reason: MatchEndReason): Room`
    - `leaveRoom(roomId: string, slot: number): LeaveOutcome`
    - `markDisconnected(roomId: string, slot: number): LeaveOutcome`
    - `sweep(): SweepReport`
    - `hostSlot(room: Room): number`
    - `buildMatchStart(room: Room): MatchStartPayload`
    - `toMemberPayload(room: Room, member: RoomMember): RoomMemberPayload`
    - `toRoomState(room: Room): RoomStatePayload`
    - `toPublic(room: Room): PublicRoom`

- [ ] **Step 1: 写入类型、常量与错误**

创建 `src/lib/rooms.ts`，先写文件头到 `RoomError`：

```ts
import { randomBytes, randomInt, randomUUID } from 'node:crypto';

import {
  allocateRoomCode,
  isRoomCode,
  normalizeRoomCode,
  ROOM_CODE_ALPHABET,
  ROOM_CODE_LENGTH,
  type RandomIndex,
} from './room_code.js';
import { normalizeNickname } from './sessions.js';

/**
 * 昵称规则的事实源是 S1 的 sessions.ts（码点计数 + 屏蔽词表）。这里只把它
 * 再导出一次，让 rooms.ts 的消费者不必知道昵称住在身份模块里——但**绝不能**
 * 在本文件里另写一份实现：同一个昵称在 POST /api/auth/anon 与 set_nickname
 * 帧上必须得到完全相同的接受/拒绝结论与错误码。
 */
export {
  NICKNAME_MIN_LENGTH,
  NICKNAME_MAX_LENGTH,
  normalizeNickname,
} from './sessions.js';

/**
 * 房间状态机 —— 纯逻辑。
 *
 * 这里**不允许出现任何 socket 对象**。所有对外效果都表达为返回值或 SweepReport，
 * 由 room_hub.ts 翻译成广播。时钟与随机源全部注入，因此每一条转移都能在 Vitest
 * 里被直接驱动，不需要起真实 WebSocket。
 */

export type RoomState = 'lobby' | 'starting' | 'playing' | 'ended';
export type RoomVisibility = 'public' | 'code_only';
export type MatchEndReason = 'wiped' | 'host_ended' | 'abandoned';

export const MAX_MEMBERS = 4;
export const PING_INTERVAL_MS = 5_000;
export const PING_TIMEOUT_MS = 15_000;
export const RECONNECT_GRACE_MS = 30_000;
export const START_COUNTDOWN_MS = 3_000;
export const TICKET_TTL_MS = 30_000;
export const EMPTY_ROOM_GRACE_MS = 30_000;
export const ENDED_ROOM_TTL_MS = 30_000;
export const SWEEP_INTERVAL_MS = 250;
/**
 * 结算收集的兜底窗口。第一份 match_result 到达后最多再等这么久，之后无论
 * 还差几席都用已收到的上报调用 submitMatchResult()。没有这个窗口，只要有一人
 * 在结算瞬间掉线，房间就会永远停在 playing 且 bucket 永不释放。
 */
export const MATCH_RESULT_COLLECT_MS = 10_000;
export const DEFAULT_TICK_RATE = 20;
export const DEFAULT_MAP_ID = 'demo_arena';
export const MAX_ROOMS = 500;
export const ROOM_LIST_MAX_LIMIT = 50;

export interface RoomMember {
  slot: number;
  playerId: string;
  nickname: string;
  /** 断线重连凭据；只发给该席位自己。 */
  sessionToken: string;
  ready: boolean;
  connected: boolean;
  /** playing 状态下超过 RECONNECT_GRACE_MS 未回来，席位保留但不再可重连。 */
  abandoned: boolean;
  joinedAt: number;
  lastPingAt: number;
  disconnectedAt: number | null;
}

export interface Room {
  id: string;
  code: string;
  name: string;
  visibility: RoomVisibility;
  state: RoomState;
  mapId: string;
  seed: number;
  tickRate: number;
  hostPlayerId: string | null;
  members: RoomMember[];
  /** 曾经有人坐进来过——用于区分「刚建还没人连」与「人走光了」。 */
  hadMember: boolean;
  createdAt: number;
  updatedAt: number;
  countdownEndsAt: number | null;
  startedAt: number | null;
  endedAt: number | null;
  endReason: MatchEndReason | null;
}

export interface Ticket {
  id: string;
  roomId: string;
  code: string;
  playerId: string;
  nickname: string;
  issuedAt: number;
  expiresAt: number;
}

export interface TicketClaim {
  roomId: string;
  playerId: string;
  nickname: string;
}

export interface CreateRoomInput {
  name: string;
  visibility: RoomVisibility;
  hostPlayerId: string | null;
  mapId?: string;
}

export interface MemberRef {
  roomId: string;
  slot: number;
  playerId: string;
}

export interface LeaveOutcome {
  /** null 表示房间在这次操作里被销毁了。 */
  room: Room | null;
  removed: boolean;
  slot: number;
  hostTransferredTo: { slot: number; playerId: string } | null;
  stateChanged: RoomState | null;
  destroyed: boolean;
}

export interface SweepReport {
  expiredTickets: number;
  /** 心跳超时但席位保留（playing）。 */
  disconnectedMembers: MemberRef[];
  /** 席位已释放（lobby / starting / ended）。 */
  removedMembers: MemberRef[];
  /** 重连宽限超时，slot 标记为已断开，对局继续。 */
  abandonedMembers: MemberRef[];
  hostTransfers: MemberRef[];
  canceledStarts: string[];
  startedRooms: string[];
  endedRooms: string[];
  destroyedRoomIds: string[];
}

export interface PublicRoom {
  room_id: string;
  room_code: string;
  name: string;
  state: RoomState;
  map_id: string;
  member_count: number;
  max_members: number;
  joinable: boolean;
  created_at: string;
}

export interface RoomMemberPayload {
  slot: number;
  player_id: string;
  nickname: string;
  ready: boolean;
  connected: boolean;
  abandoned: boolean;
  is_host: boolean;
}

export interface RoomStatePayload {
  room_id: string;
  room_code: string;
  name: string;
  visibility: RoomVisibility;
  state: RoomState;
  map_id: string;
  tick_rate: number;
  max_members: number;
  host_slot: number;
  countdown_ms: number | null;
  members: RoomMemberPayload[];
}

export interface MatchStartPayload {
  seed: number;
  tick_rate: number;
  map_id: string;
  player_slots: Array<{ slot: number; player_id: string; nickname: string }>;
}

export type RoomErrorCode =
  | 'room_not_found'
  | 'room_full'
  | 'room_in_progress'
  | 'room_ended'
  | 'invalid_room_code'
  | 'invalid_nickname'
  | 'invalid_body'
  | 'invalid_query'
  | 'ticket_invalid'
  | 'ticket_expired'
  | 'not_host'
  | 'not_all_ready'
  | 'invalid_state'
  | 'slot_not_found'
  | 'session_unknown'
  | 'capacity_reached'
  | 'code_exhausted';

export class RoomError extends Error {
  constructor(
    readonly code: RoomErrorCode,
    readonly statusCode: number,
    message: string,
  ) {
    super(message);
    this.name = 'RoomError';
  }
}
```

`RoomErrorCode` 里保留 `'invalid_nickname'` 这一项：`rooms.ts` 自己不再抛它，但
`room_hub.ts` 需要把 `sessions.ts` 抛出的 `HttpError('invalid_nickname')` 翻译成同名
`error` 帧的 `code`，两边用同一个字符串表能少一层映射。

- [ ] **Step 2: 写入 RoomStore 的构造、查询与建房**

在同一文件末尾追加：

```ts
export interface RoomStoreOptions {
  now?: () => number;
  randomIndex?: RandomIndex;
  newRoomId?: () => string;
  newToken?: () => string;
  newSeed?: () => number;
  maxRooms?: number;
}

export class RoomStore {
  private readonly rooms = new Map<string, Room>();
  private readonly byCode = new Map<string, string>();
  private readonly tickets = new Map<string, Ticket>();
  private readonly now: () => number;
  private readonly randomIndex: RandomIndex;
  private readonly newRoomId: () => string;
  private readonly newToken: () => string;
  private readonly newSeed: () => number;
  readonly maxRooms: number;

  constructor(options: RoomStoreOptions = {}) {
    this.now = options.now ?? Date.now;
    this.randomIndex = options.randomIndex ?? randomInt;
    this.newRoomId = options.newRoomId ?? randomUUID;
    this.newToken = options.newToken ?? (() => randomBytes(24).toString('base64url'));
    this.newSeed = options.newSeed ?? (() => randomInt(1, 2_147_483_647));
    this.maxRooms = options.maxRooms ?? MAX_ROOMS;
  }

  get size(): number {
    return this.rooms.size;
  }

  createRoom(input: CreateRoomInput): Room {
    if (this.rooms.size >= this.maxRooms) {
      throw new RoomError('capacity_reached', 503, `room registry is full (${this.maxRooms} rooms)`);
    }
    const ts = this.now();
    const room: Room = {
      id: this.newRoomId(),
      code: allocateRoomCode((code) => this.byCode.has(code), this.randomIndex),
      name: input.name,
      visibility: input.visibility,
      state: 'lobby',
      mapId: input.mapId ?? DEFAULT_MAP_ID,
      // 种子在倒计时结束、真正进入 playing 时才生成，保证每局不同。
      seed: 0,
      tickRate: DEFAULT_TICK_RATE,
      hostPlayerId: input.hostPlayerId,
      members: [],
      hadMember: false,
      createdAt: ts,
      updatedAt: ts,
      countdownEndsAt: null,
      startedAt: null,
      endedAt: null,
      endReason: null,
    };
    this.rooms.set(room.id, room);
    this.byCode.set(room.code, room.id);
    return room;
  }

  getRoom(roomId: string): Room | undefined {
    return this.rooms.get(roomId);
  }

  requireRoom(roomId: string): Room {
    const room = this.rooms.get(roomId);
    if (room === undefined) {
      throw new RoomError('room_not_found', 404, `no room with id ${roomId}`);
    }
    return room;
  }

  getRoomByCode(code: string): Room | undefined {
    const roomId = this.byCode.get(normalizeRoomCode(code));
    return roomId === undefined ? undefined : this.rooms.get(roomId);
  }

  requireRoomByCode(code: string): Room {
    const normalized = normalizeRoomCode(code);
    if (!isRoomCode(normalized)) {
      throw new RoomError(
        'invalid_room_code',
        400,
        `room code must be ${ROOM_CODE_LENGTH} characters from ${ROOM_CODE_ALPHABET}`,
      );
    }
    const room = this.getRoomByCode(normalized);
    if (room === undefined) {
      throw new RoomError('room_not_found', 404, `no room with code ${normalized}`);
    }
    return room;
  }

  listPublicRooms(offset: number, limit: number): { total: number; items: Room[] } {
    const visible = [...this.rooms.values()]
      .filter(
        (room) =>
          room.visibility === 'public' &&
          room.state === 'lobby' &&
          room.members.length < MAX_MEMBERS,
      )
      .sort((a, b) => b.createdAt - a.createdAt || a.id.localeCompare(b.id));
    return { total: visible.length, items: visible.slice(offset, offset + limit) };
  }
```

**注意：本步骤不写类的收尾 `}`，`RoomStore` 保持开放，由 Step 5 末尾统一收尾。**
Step 3、Step 4、Step 5 都是在这个开放类体里继续追加方法；如果这里先补上 `}`，
后面三步就会变成类外的孤立方法加一个多余的 `}`，`tsc` 直接语法错误。

- [ ] **Step 3: 加入 ticket 与入座逻辑**

在 Step 2 留下的开放类体末尾（`listPublicRooms` 之后）继续追加：

```ts
  issueTicket(room: Room, playerId: string, nickname: string): Ticket {
    this.assertTicketable(room);
    const ts = this.now();
    const ticket: Ticket = {
      id: this.newToken(),
      roomId: room.id,
      code: room.code,
      playerId,
      nickname: normalizeNickname(nickname),
      issuedAt: ts,
      expiresAt: ts + TICKET_TTL_MS,
    };
    this.tickets.set(ticket.id, ticket);
    return ticket;
  }

  peekTicket(ticketId: string, roomId: string): Ticket {
    const ticket = this.tickets.get(ticketId);
    if (ticket === undefined || ticket.roomId !== roomId) {
      throw new RoomError('ticket_invalid', 403, 'ticket is unknown or belongs to another room');
    }
    if (ticket.expiresAt <= this.now()) {
      this.tickets.delete(ticketId);
      throw new RoomError('ticket_expired', 403, 'ticket has expired');
    }
    return ticket;
  }

  redeemTicket(ticketId: string, roomId: string): TicketClaim {
    const ticket = this.peekTicket(ticketId, roomId);
    this.tickets.delete(ticketId);
    return { roomId: ticket.roomId, playerId: ticket.playerId, nickname: ticket.nickname };
  }

  joinRoom(roomId: string, claim: TicketClaim): { room: Room; member: RoomMember } {
    const room = this.requireRoom(roomId);
    this.assertOpenForJoin(room);
    const slot = this.firstFreeSlot(room);
    if (slot < 0) {
      throw new RoomError('room_full', 409, `room ${room.code} is full (${MAX_MEMBERS}/${MAX_MEMBERS})`);
    }
    const ts = this.now();
    const member: RoomMember = {
      slot,
      playerId: claim.playerId,
      nickname: claim.nickname,
      sessionToken: this.newToken(),
      ready: false,
      connected: true,
      abandoned: false,
      joinedAt: ts,
      lastPingAt: ts,
      disconnectedAt: null,
    };
    room.members.push(member);
    room.members.sort((a, b) => a.slot - b.slot);
    room.hadMember = true;
    if (room.hostPlayerId === null) room.hostPlayerId = member.playerId;
    room.updatedAt = ts;
    return { room, member };
  }

  rejoinRoom(roomId: string, sessionToken: string): { room: Room; member: RoomMember } {
    const room = this.requireRoom(roomId);
    const member = room.members.find((candidate) => candidate.sessionToken === sessionToken);
    if (member === undefined) {
      throw new RoomError('session_unknown', 403, 'session_token matches no seat in this room');
    }
    if (member.abandoned) {
      throw new RoomError(
        'session_unknown',
        403,
        `slot ${member.slot} was marked disconnected after the ${RECONNECT_GRACE_MS} ms grace window`,
      );
    }
    const ts = this.now();
    member.connected = true;
    member.disconnectedAt = null;
    member.lastPingAt = ts;
    room.updatedAt = ts;
    return { room, member };
  }

  /** 只在发票时用：把尚未兑换的 ticket 也算作已占席位，避免超卖。 */
  private assertTicketable(room: Room): void {
    this.assertLobby(room);
    let pending = 0;
    const ts = this.now();
    for (const ticket of this.tickets.values()) {
      if (ticket.roomId === room.id && ticket.expiresAt > ts) pending += 1;
    }
    if (room.members.length + pending >= MAX_MEMBERS) {
      throw new RoomError('room_full', 409, `room ${room.code} is full (${MAX_MEMBERS}/${MAX_MEMBERS})`);
    }
  }

  /** 兑换后真正入座时用：ticket 已被删除，只看已落座人数。 */
  private assertOpenForJoin(room: Room): void {
    this.assertLobby(room);
    if (room.members.length >= MAX_MEMBERS) {
      throw new RoomError('room_full', 409, `room ${room.code} is full (${MAX_MEMBERS}/${MAX_MEMBERS})`);
    }
  }

  private assertLobby(room: Room): void {
    if (room.state === 'starting' || room.state === 'playing') {
      throw new RoomError(
        'room_in_progress',
        409,
        `room ${room.code} does not accept new players (state=${room.state})`,
      );
    }
    if (room.state === 'ended') {
      throw new RoomError('room_ended', 409, `room ${room.code} has ended`);
    }
  }

  private firstFreeSlot(room: Room): number {
    for (let slot = 0; slot < MAX_MEMBERS; slot += 1) {
      if (!room.members.some((member) => member.slot === slot)) return slot;
    }
    return -1;
  }

  private requireMember(room: Room, slot: number): RoomMember {
    const member = room.members.find((candidate) => candidate.slot === slot);
    if (member === undefined) {
      throw new RoomError('slot_not_found', 404, `room ${room.code} has no slot ${slot}`);
    }
    return member;
  }
```

- [ ] **Step 4: 加入大厅操作与状态转移**

在 Step 2 留下的开放类体末尾继续追加：

```ts
  setReady(roomId: string, slot: number, ready: boolean): { room: Room; member: RoomMember } {
    const room = this.requireRoom(roomId);
    if (room.state !== 'lobby') {
      throw new RoomError('invalid_state', 409, `set_ready is only valid in lobby (state=${room.state})`);
    }
    const member = this.requireMember(room, slot);
    member.ready = ready;
    room.updatedAt = this.now();
    return { room, member };
  }

  setNickname(roomId: string, slot: number, nickname: string): { room: Room; member: RoomMember } {
    const room = this.requireRoom(roomId);
    if (room.state !== 'lobby') {
      throw new RoomError('invalid_state', 409, `set_nickname is only valid in lobby (state=${room.state})`);
    }
    const member = this.requireMember(room, slot);
    member.nickname = normalizeNickname(nickname);
    room.updatedAt = this.now();
    return { room, member };
  }

  applyPing(roomId: string, slot: number): number {
    const room = this.requireRoom(roomId);
    const member = this.requireMember(room, slot);
    const ts = this.now();
    member.lastPingAt = ts;
    return ts;
  }

  requestStart(roomId: string, slot: number): Room {
    const room = this.requireRoom(roomId);
    if (room.state !== 'lobby') {
      throw new RoomError('invalid_state', 409, `start is only valid in lobby (state=${room.state})`);
    }
    const member = this.requireMember(room, slot);
    if (room.hostPlayerId !== member.playerId) {
      throw new RoomError('not_host', 403, `slot ${slot} is not the host of room ${room.code}`);
    }
    const others = room.members.filter((candidate) => candidate.slot !== slot);
    if (others.some((candidate) => !candidate.ready || !candidate.connected)) {
      throw new RoomError('not_all_ready', 409, 'every non-host member must be connected and ready');
    }
    const ts = this.now();
    room.state = 'starting';
    room.countdownEndsAt = ts + START_COUNTDOWN_MS;
    room.updatedAt = ts;
    return room;
  }

  cancelStart(roomId: string): Room {
    const room = this.requireRoom(roomId);
    if (room.state !== 'starting') {
      throw new RoomError('invalid_state', 409, `cancel is only valid while starting (state=${room.state})`);
    }
    room.state = 'lobby';
    room.countdownEndsAt = null;
    room.updatedAt = this.now();
    return room;
  }

  endMatch(roomId: string, reason: MatchEndReason): Room {
    const room = this.requireRoom(roomId);
    if (room.state !== 'playing') {
      throw new RoomError('invalid_state', 409, `end is only valid while playing (state=${room.state})`);
    }
    const ts = this.now();
    room.state = 'ended';
    room.endedAt = ts;
    room.endReason = reason;
    room.updatedAt = ts;
    return room;
  }

  leaveRoom(roomId: string, slot: number): LeaveOutcome {
    const room = this.rooms.get(roomId);
    if (room === undefined) {
      return { room: null, removed: false, slot, hostTransferredTo: null, stateChanged: null, destroyed: true };
    }
    return this.removeMember(room, slot);
  }

  markDisconnected(roomId: string, slot: number): LeaveOutcome {
    const room = this.rooms.get(roomId);
    if (room === undefined) {
      return { room: null, removed: false, slot, hostTransferredTo: null, stateChanged: null, destroyed: true };
    }
    const member = room.members.find((candidate) => candidate.slot === slot);
    if (member === undefined) {
      return { room, removed: false, slot, hostTransferredTo: null, stateChanged: null, destroyed: false };
    }
    if (room.state === 'playing') {
      // 保留席位 RECONNECT_GRACE_MS，房主也不移交。
      const ts = this.now();
      member.connected = false;
      member.disconnectedAt = ts;
      room.updatedAt = ts;
      return { room, removed: false, slot, hostTransferredTo: null, stateChanged: null, destroyed: false };
    }
    return this.removeMember(room, slot);
  }

  private removeMember(room: Room, slot: number): LeaveOutcome {
    const member = room.members.find((candidate) => candidate.slot === slot);
    if (member === undefined) {
      return { room, removed: false, slot, hostTransferredTo: null, stateChanged: null, destroyed: false };
    }
    const ts = this.now();
    room.members = room.members.filter((candidate) => candidate.slot !== slot);
    room.updatedAt = ts;

    let stateChanged: RoomState | null = null;
    if (room.state === 'starting') {
      // 倒计时期间有人离开 → 回退到 lobby。
      room.state = 'lobby';
      room.countdownEndsAt = null;
      stateChanged = 'lobby';
    }

    let hostTransferredTo: { slot: number; playerId: string } | null = null;
    if (room.hostPlayerId === member.playerId && room.state !== 'playing') {
      const heir = [...room.members].sort(
        (a, b) => a.joinedAt - b.joinedAt || a.slot - b.slot,
      )[0];
      if (heir === undefined) {
        room.hostPlayerId = null;
      } else {
        room.hostPlayerId = heir.playerId;
        hostTransferredTo = { slot: heir.slot, playerId: heir.playerId };
      }
    }

    if (room.members.length === 0) {
      this.destroyRoom(room.id);
      return { room: null, removed: true, slot, hostTransferredTo, stateChanged, destroyed: true };
    }
    return { room, removed: true, slot, hostTransferredTo, stateChanged, destroyed: false };
  }

  private destroyRoom(roomId: string): void {
    const room = this.rooms.get(roomId);
    if (room === undefined) return;
    this.rooms.delete(roomId);
    this.byCode.delete(room.code);
    for (const [ticketId, ticket] of this.tickets) {
      if (ticket.roomId === roomId) this.tickets.delete(ticketId);
    }
  }
```

- [ ] **Step 5: 加入 sweep 与负载构造**

在 Step 2 留下的开放类体末尾继续追加，并以 `}` 收尾整个类（**整份文件里 `RoomStore` 只有这一个收尾大括号**）：

```ts
  /**
   * 单一时间驱动入口：过期 ticket、心跳超时、重连宽限超时、倒计时结束、
   * 空置销毁全部在这里发生。room_hub 每 SWEEP_INTERVAL_MS 调一次并广播结果。
   */
  sweep(): SweepReport {
    const ts = this.now();
    const report: SweepReport = {
      expiredTickets: 0,
      disconnectedMembers: [],
      removedMembers: [],
      abandonedMembers: [],
      hostTransfers: [],
      canceledStarts: [],
      startedRooms: [],
      endedRooms: [],
      destroyedRoomIds: [],
    };

    for (const [ticketId, ticket] of this.tickets) {
      if (ticket.expiresAt <= ts) {
        this.tickets.delete(ticketId);
        report.expiredTickets += 1;
      }
    }

    for (const room of [...this.rooms.values()]) {
      for (const member of [...room.members]) {
        if (!member.connected || member.abandoned) continue;
        if (ts - member.lastPingAt < PING_TIMEOUT_MS) continue;
        const ref: MemberRef = { roomId: room.id, slot: member.slot, playerId: member.playerId };
        const outcome = this.markDisconnected(room.id, member.slot);
        if (outcome.removed) report.removedMembers.push(ref);
        else report.disconnectedMembers.push(ref);
        if (outcome.hostTransferredTo !== null) {
          report.hostTransfers.push({
            roomId: room.id,
            slot: outcome.hostTransferredTo.slot,
            playerId: outcome.hostTransferredTo.playerId,
          });
        }
        if (outcome.stateChanged === 'lobby') report.canceledStarts.push(room.id);
        if (outcome.destroyed) {
          report.destroyedRoomIds.push(room.id);
          break;
        }
      }
      if (!this.rooms.has(room.id)) continue;

      if (room.state === 'playing') {
        for (const member of room.members) {
          if (member.connected || member.abandoned || member.disconnectedAt === null) continue;
          if (ts - member.disconnectedAt < RECONNECT_GRACE_MS) continue;
          member.abandoned = true;
          member.ready = false;
          room.updatedAt = ts;
          report.abandonedMembers.push({
            roomId: room.id,
            slot: member.slot,
            playerId: member.playerId,
          });
        }
      }

      if (room.state === 'starting' && room.countdownEndsAt !== null && ts >= room.countdownEndsAt) {
        room.state = 'playing';
        room.seed = this.newSeed();
        room.startedAt = ts;
        room.countdownEndsAt = null;
        room.updatedAt = ts;
        report.startedRooms.push(room.id);
      }

      if (
        room.state === 'playing' &&
        room.members.length > 0 &&
        room.members.every((member) => member.abandoned)
      ) {
        room.state = 'ended';
        room.endedAt = ts;
        room.endReason = 'abandoned';
        room.updatedAt = ts;
        report.endedRooms.push(room.id);
      }

      if (this.shouldDestroy(room, ts)) {
        this.destroyRoom(room.id);
        report.destroyedRoomIds.push(room.id);
      }
    }

    return report;
  }

  private shouldDestroy(room: Room, ts: number): boolean {
    if (room.state === 'ended' && room.endedAt !== null && ts - room.endedAt >= ENDED_ROOM_TTL_MS) {
      return true;
    }
    if (room.members.length > 0) return false;
    if (room.hadMember) return true;
    return ts - room.createdAt >= EMPTY_ROOM_GRACE_MS;
  }

  hostSlot(room: Room): number {
    const host = room.members.find((member) => member.playerId === room.hostPlayerId);
    return host === undefined ? -1 : host.slot;
  }

  buildMatchStart(room: Room): MatchStartPayload {
    return {
      seed: room.seed,
      tick_rate: room.tickRate,
      map_id: room.mapId,
      player_slots: [...room.members]
        .sort((a, b) => a.slot - b.slot)
        .map((member) => ({
          slot: member.slot,
          player_id: member.playerId,
          nickname: member.nickname,
        })),
    };
  }

  toMemberPayload(room: Room, member: RoomMember): RoomMemberPayload {
    return {
      slot: member.slot,
      player_id: member.playerId,
      nickname: member.nickname,
      ready: member.ready,
      connected: member.connected,
      abandoned: member.abandoned,
      is_host: room.hostPlayerId === member.playerId,
    };
  }

  toRoomState(room: Room): RoomStatePayload {
    return {
      room_id: room.id,
      room_code: room.code,
      name: room.name,
      visibility: room.visibility,
      state: room.state,
      map_id: room.mapId,
      tick_rate: room.tickRate,
      max_members: MAX_MEMBERS,
      host_slot: this.hostSlot(room),
      countdown_ms:
        room.countdownEndsAt === null ? null : Math.max(0, room.countdownEndsAt - this.now()),
      members: [...room.members]
        .sort((a, b) => a.slot - b.slot)
        .map((member) => this.toMemberPayload(room, member)),
    };
  }

  toPublic(room: Room): PublicRoom {
    return {
      room_id: room.id,
      room_code: room.code,
      name: room.name,
      state: room.state,
      map_id: room.mapId,
      member_count: room.members.length,
      max_members: MAX_MEMBERS,
      joinable: room.state === 'lobby' && room.members.length < MAX_MEMBERS,
      created_at: new Date(room.createdAt).toISOString(),
    };
  }
}
```

- [ ] **Step 6: 确认状态机没有引用任何 socket**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
npx tsc -p tsconfig.json --noEmit
rg -n "socket|WebSocket|ws\.|fastify|@fastify" src/lib/rooms.ts
rg -c "^}$" src/lib/rooms.ts
rg -n "^export function normalizeNickname" src/lib/rooms.ts
```

Expected: `tsc` 无输出且退出码为 0；第一条 `rg` 无任何匹配（退出码 1）——这是 `rooms.ts` 能被直接单测的前提，出现任何匹配都必须先移除。第二条 `rg -c` 的计数应为 `2`（`RoomError` 类与 `RoomStore` 类各一个顶格 `}`）——若为 `3`，说明 Step 2 误写了类的收尾大括号，回去删掉它。第三条 `rg` 必须 0 命中：昵称规则只能从 `sessions.ts` 再导出，不得在本文件里重新实现。

- [ ] **Step 7: 提交房间状态机**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
git add src/lib/rooms.ts
git commit -m "feat: add room state machine"
```

Expected: 提交只包含 `src/lib/rooms.ts`。

---

### Task 3: 房间状态机 Vitest 全分支覆盖

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/test/rooms.test.ts`

**Interfaces:**
- Consumes: Task 2 的 `RoomStore`、`RoomError`、`MAX_MEMBERS`、`PING_TIMEOUT_MS`、`RECONNECT_GRACE_MS`、`START_COUNTDOWN_MS`、`TICKET_TTL_MS`、`EMPTY_ROOM_GRACE_MS`、`ENDED_ROOM_TTL_MS`、`DEFAULT_TICK_RATE`、`DEFAULT_MAP_ID`、`type Room`、`type RoomStoreOptions`，以及经 `rooms.ts` 再导出的 `normalizeNickname`（**来自 S1 `sessions.ts`**，失败时抛 S1 `src/lib/http.ts` 的 `HttpError` 而不是 `RoomError`）；Task 1 的 `ROOM_CODE_ALPHABET`、`isRoomCode`、`type RandomIndex`。
- Produces: 无生产代码导出。本任务只固化 Task 2 的行为契约。

- [ ] **Step 1: 写入测试夹具与建房/入座辅助**

创建 `test/rooms.test.ts`，先写文件头：

```ts
import { describe, expect, it } from 'vitest';

import { HttpError } from '../src/lib/http.js';
import { isRoomCode, ROOM_CODE_ALPHABET, type RandomIndex } from '../src/lib/room_code.js';
import {
  DEFAULT_MAP_ID,
  DEFAULT_TICK_RATE,
  EMPTY_ROOM_GRACE_MS,
  ENDED_ROOM_TTL_MS,
  MAX_MEMBERS,
  PING_TIMEOUT_MS,
  RECONNECT_GRACE_MS,
  RoomError,
  RoomStore,
  START_COUNTDOWN_MS,
  TICKET_TTL_MS,
  normalizeNickname,
  type Room,
  type RoomStoreOptions,
} from '../src/lib/rooms.js';

function scriptedIndex(codes: string[]): RandomIndex {
  const characters = codes.join('').split('');
  let cursor = 0;
  return () => {
    const character = characters[cursor] ?? 'A';
    cursor += 1;
    return ROOM_CODE_ALPHABET.indexOf(character);
  };
}

interface Harness {
  store: RoomStore;
  advance(ms: number): void;
  now(): number;
}

function makeHarness(overrides: Partial<RoomStoreOptions> = {}): Harness {
  let clock = 1_700_000_000_000;
  let roomSequence = 0;
  let tokenSequence = 0;
  const store = new RoomStore({
    now: () => clock,
    newRoomId: () => `room-${(roomSequence += 1)}`,
    newToken: () => `tok-${(tokenSequence += 1)}`,
    newSeed: () => 1_234_567_890,
    ...overrides,
  });
  return {
    store,
    advance: (ms: number) => {
      clock += ms;
    },
    now: () => clock,
  };
}

function openRoom(store: RoomStore, name = 'test room'): Room {
  return store.createRoom({ name, visibility: 'public', hostPlayerId: null });
}

/** 走完整的 issue → redeem → join 链路，返回落座的成员。 */
function seat(store: RoomStore, room: Room, playerId: string, nickname: string) {
  const ticket = store.issueTicket(room, playerId, nickname);
  const claim = store.redeemTicket(ticket.id, room.id);
  return store.joinRoom(room.id, claim).member;
}

function readyAll(store: RoomStore, room: Room, exceptSlot: number): void {
  for (const member of [...room.members]) {
    if (member.slot === exceptSlot) continue;
    store.setReady(room.id, member.slot, true);
  }
}
```

- [ ] **Step 2: 覆盖房间码、可见性与容量上限**

在同一文件末尾追加：

```ts
describe('建房与房间码', () => {
  it('建房产生 6 位合法房间码且初始状态为 lobby', () => {
    const { store } = makeHarness();
    const room = openRoom(store);
    expect(isRoomCode(room.code)).toBe(true);
    expect(room.state).toBe('lobby');
    expect(room.members).toHaveLength(0);
    expect(room.tickRate).toBe(DEFAULT_TICK_RATE);
    expect(room.mapId).toBe(DEFAULT_MAP_ID);
    expect(room.seed).toBe(0);
  });

  it('房间码碰撞时换一个，绝不重复登记', () => {
    const { store } = makeHarness({ randomIndex: scriptedIndex(['AAAAAA', 'AAAAAA', 'BBBBBB']) });
    const first = openRoom(store, 'first');
    const second = openRoom(store, 'second');
    expect(first.code).toBe('AAAAAA');
    expect(second.code).toBe('BBBBBB');
    expect(store.getRoomByCode('aaaaaa')?.id).toBe(first.id);
    expect(store.getRoomByCode('BBBBBB')?.id).toBe(second.id);
  });

  it('requireRoomByCode 对非法码与未知码给出不同错误', () => {
    const { store } = makeHarness();
    // 房间层的错误一律是 RoomError；昵称那条走的是 sessions.ts 的 HttpError。
    expect(() => store.requireRoomByCode('AB0DEF')).toThrowError(RoomError);
    expect(() => store.requireRoomByCode('AB0DEF')).toThrowError(
      expect.objectContaining({ code: 'invalid_room_code', statusCode: 400 }),
    );
    expect(() => store.requireRoomByCode('ABCDEF')).toThrowError(
      expect.objectContaining({ code: 'room_not_found', statusCode: 404 }),
    );
  });

  it('公开列表只含 public 且未满的 lobby 房，并支持分页', () => {
    const { store, advance } = makeHarness();
    const first = openRoom(store, 'a');
    advance(10);
    const second = openRoom(store, 'b');
    advance(10);
    const hidden = store.createRoom({ name: 'c', visibility: 'code_only', hostPlayerId: null });

    const page = store.listPublicRooms(0, 10);
    expect(page.total).toBe(2);
    expect(page.items.map((room) => room.id)).toEqual([second.id, first.id]);
    expect(page.items.map((room) => room.id)).not.toContain(hidden.id);

    expect(store.listPublicRooms(1, 1).items.map((room) => room.id)).toEqual([first.id]);
  });

  it('容量上限为 4，第 5 张 ticket 直接被拒', () => {
    const { store } = makeHarness();
    const room = openRoom(store);
    for (let index = 0; index < MAX_MEMBERS; index += 1) {
      seat(store, room, `p${index}`, `P${index}`);
    }
    expect(room.members.map((member) => member.slot)).toEqual([0, 1, 2, 3]);
    expect(() => store.issueTicket(room, 'p4', 'P4')).toThrowError(
      expect.objectContaining({ code: 'room_full', statusCode: 409 }),
    );
  });

  it('未兑换的 ticket 也占席位，避免超卖', () => {
    const { store } = makeHarness();
    const room = openRoom(store);
    seat(store, room, 'p0', 'P0');
    store.issueTicket(room, 'p1', 'P1');
    store.issueTicket(room, 'p2', 'P2');
    store.issueTicket(room, 'p3', 'P3');
    expect(() => store.issueTicket(room, 'p4', 'P4')).toThrowError(
      expect.objectContaining({ code: 'room_full' }),
    );
  });

  it('ticket 只能兑换一次，且过期后失效', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const ticket = store.issueTicket(room, 'p0', 'P0');
    store.redeemTicket(ticket.id, room.id);
    expect(() => store.redeemTicket(ticket.id, room.id)).toThrowError(
      expect.objectContaining({ code: 'ticket_invalid', statusCode: 403 }),
    );

    const second = store.issueTicket(room, 'p1', 'P1');
    advance(TICKET_TTL_MS + 1);
    expect(() => store.redeemTicket(second.id, room.id)).toThrowError(
      expect.objectContaining({ code: 'ticket_expired', statusCode: 403 }),
    );
  });

  // rooms.ts 只是把 sessions.ts 的实现再导出一遍，所以这里断言的是 S1 的规则：
  // 按码点计数、只 trim 首尾、失败时抛 HttpError（不是 RoomError）。
  it('昵称规则来自 sessions.ts：2-12 个码点，越界抛 HttpError', () => {
    expect(normalizeNickname('  bo  ')).toBe('bo');
    expect(normalizeNickname('僵尸猎人')).toBe('僵尸猎人');
    expect(() => normalizeNickname('b')).toThrowError(HttpError);
    expect(() => normalizeNickname('b')).toThrowError(
      expect.objectContaining({ code: 'invalid_nickname', statusCode: 400 }),
    );
    expect(() => normalizeNickname('0123456789abc')).toThrowError(
      expect.objectContaining({ code: 'invalid_nickname', statusCode: 400 }),
    );
    expect(() => normalizeNickname('admin')).toThrowError(
      expect.objectContaining({ code: 'nickname_blocked', statusCode: 400 }),
    );
  });
});
```

- [ ] **Step 3: 覆盖 lobby → starting → playing → ended 与 starting → lobby 回退**

在同一文件末尾追加：

```ts
describe('状态转移', () => {
  it('lobby → starting → playing → ended 走通', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    seat(store, room, 'guest', 'Guest');
    readyAll(store, room, host.slot);

    store.requestStart(room.id, host.slot);
    expect(room.state).toBe('starting');
    expect(room.countdownEndsAt).not.toBeNull();

    advance(START_COUNTDOWN_MS - 1);
    expect(store.sweep().startedRooms).toEqual([]);
    expect(room.state).toBe('starting');

    advance(2);
    expect(store.sweep().startedRooms).toEqual([room.id]);
    expect(room.state).toBe('playing');
    expect(room.seed).toBe(1_234_567_890);
    expect(room.startedAt).not.toBeNull();

    const payload = store.buildMatchStart(room);
    expect(payload).toEqual({
      seed: 1_234_567_890,
      tick_rate: 20,
      map_id: 'demo_arena',
      player_slots: [
        { slot: 0, player_id: 'host', nickname: 'Host' },
        { slot: 1, player_id: 'guest', nickname: 'Guest' },
      ],
    });

    store.endMatch(room.id, 'wiped');
    expect(room.state).toBe('ended');
    expect(room.endReason).toBe('wiped');
  });

  it('倒计时期间有人离开时回退到 lobby', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    const guest = seat(store, room, 'guest', 'Guest');
    readyAll(store, room, host.slot);
    store.requestStart(room.id, host.slot);

    const outcome = store.leaveRoom(room.id, guest.slot);
    expect(outcome.stateChanged).toBe('lobby');
    expect(room.state).toBe('lobby');
    expect(room.countdownEndsAt).toBeNull();

    advance(START_COUNTDOWN_MS + 1);
    expect(store.sweep().startedRooms).toEqual([]);
    expect(room.state).toBe('lobby');
  });

  it('cancelStart 显式回退，且只在 starting 有效', () => {
    const { store } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    store.requestStart(room.id, host.slot);
    expect(store.cancelStart(room.id).state).toBe('lobby');
    expect(() => store.cancelStart(room.id)).toThrowError(
      expect.objectContaining({ code: 'invalid_state', statusCode: 409 }),
    );
  });

  it('只有房主能 start，且非房主成员必须全部 ready', () => {
    const { store } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    const guest = seat(store, room, 'guest', 'Guest');

    expect(() => store.requestStart(room.id, guest.slot)).toThrowError(
      expect.objectContaining({ code: 'not_host', statusCode: 403 }),
    );
    expect(() => store.requestStart(room.id, host.slot)).toThrowError(
      expect.objectContaining({ code: 'not_all_ready', statusCode: 409 }),
    );

    store.setReady(room.id, guest.slot, true);
    expect(store.requestStart(room.id, host.slot).state).toBe('starting');
  });

  it('playing 状态拒绝热加入与 set_ready', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    store.requestStart(room.id, host.slot);
    advance(START_COUNTDOWN_MS);
    store.sweep();

    expect(() => store.issueTicket(room, 'late', 'Late')).toThrowError(
      expect.objectContaining({ code: 'room_in_progress', statusCode: 409 }),
    );
    expect(() => store.setReady(room.id, host.slot, true)).toThrowError(
      expect.objectContaining({ code: 'invalid_state' }),
    );
  });

  it('endMatch 只在 playing 有效', () => {
    const { store } = makeHarness();
    const room = openRoom(store);
    seat(store, room, 'host', 'Host');
    expect(() => store.endMatch(room.id, 'host_ended')).toThrowError(
      expect.objectContaining({ code: 'invalid_state' }),
    );
  });

  // spec 的状态机图写着 `playing --> ended: 全灭或房主结束`。'host_ended' 必须
  // 有真实的产生路径，否则它就是一个死枚举值。这条测试固化状态机这一半，
  // Task 4 的 end_match 消息与 Task 5 的 hub 分支固化协议那一半。
  it('房主可以在 playing 中结束对局', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    const guest = seat(store, room, 'guest', 'Guest');
    readyAll(store, room, host.slot);
    store.requestStart(room.id, host.slot);
    advance(START_COUNTDOWN_MS);
    store.sweep();
    expect(room.state).toBe('playing');

    const ended = store.endMatch(room.id, 'host_ended');
    expect(ended.state).toBe('ended');
    expect(ended.endReason).toBe('host_ended');
    expect(ended.endedAt).not.toBeNull();
    // 结束后席位仍在，房间由 sweep 在 ENDED_ROOM_TTL_MS 之后销毁。
    expect(room.members.map((member) => member.slot)).toEqual([host.slot, guest.slot]);
  });
});
```

- [ ] **Step 4: 覆盖房间空置销毁与 ended 清理**

在同一文件末尾追加：

```ts
describe('房间销毁', () => {
  it('最后一名成员离开后房间立即销毁', () => {
    const { store } = makeHarness();
    const room = openRoom(store);
    const only = seat(store, room, 'solo', 'Solo');
    const outcome = store.leaveRoom(room.id, only.slot);
    expect(outcome.destroyed).toBe(true);
    expect(outcome.room).toBeNull();
    expect(store.getRoom(room.id)).toBeUndefined();
    expect(store.getRoomByCode(room.code)).toBeUndefined();
    expect(store.size).toBe(0);
  });

  it('建房后无人连接，超过宽限期被 sweep 掉', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    advance(EMPTY_ROOM_GRACE_MS - 1);
    expect(store.sweep().destroyedRoomIds).toEqual([]);
    expect(store.getRoom(room.id)).toBeDefined();

    advance(2);
    expect(store.sweep().destroyedRoomIds).toEqual([room.id]);
    expect(store.size).toBe(0);
  });

  it('ended 房间在 TTL 之后被 sweep 掉', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    store.requestStart(room.id, host.slot);
    advance(START_COUNTDOWN_MS);
    store.sweep();
    store.endMatch(room.id, 'host_ended');

    advance(ENDED_ROOM_TTL_MS - 1);
    expect(store.sweep().destroyedRoomIds).toEqual([]);
    advance(2);
    expect(store.sweep().destroyedRoomIds).toEqual([room.id]);
  });

  it('销毁房间会连带清掉它未兑换的 ticket', () => {
    const { store } = makeHarness();
    const room = openRoom(store);
    const only = seat(store, room, 'solo', 'Solo');
    const pending = store.issueTicket(room, 'other', 'Other');
    store.leaveRoom(room.id, only.slot);
    expect(() => store.peekTicket(pending.id, room.id)).toThrowError(
      expect.objectContaining({ code: 'ticket_invalid' }),
    );
  });
});
```

- [ ] **Step 5: 覆盖心跳清理、重连恢复 slot 与房主移交**

在同一文件末尾追加：

```ts
describe('心跳与断线', () => {
  it('lobby 心跳超时直接移出席位', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    seat(store, room, 'host', 'Host');
    const guest = seat(store, room, 'guest', 'Guest');

    advance(PING_TIMEOUT_MS - 1);
    store.applyPing(room.id, 0);
    expect(store.sweep().removedMembers).toEqual([]);

    advance(2);
    const report = store.sweep();
    expect(report.removedMembers).toEqual([
      { roomId: room.id, slot: guest.slot, playerId: 'guest' },
    ]);
    expect(room.members.map((member) => member.slot)).toEqual([0]);
  });

  it('playing 心跳超时保留席位，30 秒内可用 session_token 恢复原 slot', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    const guest = seat(store, room, 'guest', 'Guest');
    const guestToken = guest.sessionToken;
    readyAll(store, room, host.slot);
    store.requestStart(room.id, host.slot);
    advance(START_COUNTDOWN_MS);
    store.sweep();

    advance(PING_TIMEOUT_MS + 1);
    store.applyPing(room.id, host.slot);
    const report = store.sweep();
    expect(report.disconnectedMembers).toEqual([
      { roomId: room.id, slot: guest.slot, playerId: 'guest' },
    ]);
    expect(room.members).toHaveLength(2);
    expect(room.members[1]?.connected).toBe(false);

    advance(RECONNECT_GRACE_MS - 1);
    const rejoined = store.rejoinRoom(room.id, guestToken);
    expect(rejoined.member.slot).toBe(guest.slot);
    expect(rejoined.member.connected).toBe(true);
    expect(rejoined.member.abandoned).toBe(false);
  });

  it('超过 30 秒宽限后标记断开，对局继续', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    const guest = seat(store, room, 'guest', 'Guest');
    const guestToken = guest.sessionToken;
    readyAll(store, room, host.slot);
    store.requestStart(room.id, host.slot);
    advance(START_COUNTDOWN_MS);
    store.sweep();

    store.markDisconnected(room.id, guest.slot);
    advance(RECONNECT_GRACE_MS + 1);
    store.applyPing(room.id, host.slot);
    const report = store.sweep();
    expect(report.abandonedMembers).toEqual([
      { roomId: room.id, slot: guest.slot, playerId: 'guest' },
    ]);
    expect(room.state).toBe('playing');
    expect(room.members).toHaveLength(2);
    expect(() => store.rejoinRoom(room.id, guestToken)).toThrowError(
      expect.objectContaining({ code: 'session_unknown', statusCode: 403 }),
    );
  });

  it('全员标记断开后对局结束', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    const guest = seat(store, room, 'guest', 'Guest');
    readyAll(store, room, host.slot);
    store.requestStart(room.id, host.slot);
    advance(START_COUNTDOWN_MS);
    store.sweep();

    store.markDisconnected(room.id, host.slot);
    store.markDisconnected(room.id, guest.slot);
    advance(RECONNECT_GRACE_MS + 1);
    expect(store.sweep().endedRooms).toEqual([room.id]);
    expect(room.state).toBe('ended');
    expect(room.endReason).toBe('abandoned');
  });

  it('未知 session_token 不能顶替任何席位', () => {
    const { store } = makeHarness();
    const room = openRoom(store);
    seat(store, room, 'host', 'Host');
    expect(() => store.rejoinRoom(room.id, 'not-a-token')).toThrowError(
      expect.objectContaining({ code: 'session_unknown' }),
    );
  });
});

describe('房主移交', () => {
  it('lobby 房主离开时移交给最早加入的剩余成员', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    advance(10);
    const second = seat(store, room, 'second', 'Second');
    advance(10);
    seat(store, room, 'third', 'Third');

    const outcome = store.leaveRoom(room.id, host.slot);
    expect(outcome.hostTransferredTo).toEqual({ slot: second.slot, playerId: 'second' });
    expect(room.hostPlayerId).toBe('second');
    expect(store.hostSlot(room)).toBe(second.slot);
  });

  it('lobby 房主心跳超时同样触发移交', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    advance(10);
    const second = seat(store, room, 'second', 'Second');

    advance(PING_TIMEOUT_MS + 1);
    store.applyPing(room.id, second.slot);
    const report = store.sweep();
    expect(report.hostTransfers).toEqual([
      { roomId: room.id, slot: second.slot, playerId: 'second' },
    ]);
    expect(room.hostPlayerId).toBe('second');
    expect(room.members.map((member) => member.playerId)).toEqual(['second']);
    expect(host.playerId).toBe('host');
  });

  it('playing 房主掉线不移交，对局照常进行', () => {
    const { store, advance } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    advance(10);
    const guest = seat(store, room, 'guest', 'Guest');
    readyAll(store, room, host.slot);
    store.requestStart(room.id, host.slot);
    advance(START_COUNTDOWN_MS);
    store.sweep();

    store.markDisconnected(room.id, host.slot);
    expect(room.hostPlayerId).toBe('host');
    expect(store.hostSlot(room)).toBe(host.slot);
    expect(room.state).toBe('playing');
    expect(store.toRoomState(room).members[1]?.slot).toBe(guest.slot);
  });

  it('房主主动 leave 且房内已无人时房间销毁而不是留下空壳', () => {
    const { store } = makeHarness();
    const room = openRoom(store);
    const host = seat(store, room, 'host', 'Host');
    const outcome = store.leaveRoom(room.id, host.slot);
    expect(outcome.hostTransferredTo).toBeNull();
    expect(outcome.destroyed).toBe(true);
    expect(store.size).toBe(0);
  });
});
```

- [ ] **Step 6: 运行状态机测试**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
npx vitest run test/rooms.test.ts
```

Expected: `Test Files 1 passed`；`Tests 28 passed`（建房与房间码 8 + 状态转移 7 + 房间销毁 4 + 心跳与断线 5 + 房主移交 4）；输出中不出现 `RoomCodeExhaustedError` 或未捕获异常。

- [ ] **Step 7: 提交状态机测试**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
git add test/rooms.test.ts
git commit -m "test: cover room state machine transitions"
```

Expected: 提交只包含 `test/rooms.test.ts`。

---

### Task 4: 大厅协议、opcode 号段、PROTOCOL.md 与共享 fixtures

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/protocol/opcodes.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/protocol/lobby.ts`
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/PROTOCOL.md`（S1 Task 5 已创建；本任务只**追加**小节）
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/manifest.json`（追加 8 个大厅样本文件名）
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/lobby_join.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/lobby_set_ready.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/lobby_room_state.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/lobby_member_joined.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/lobby_member_left.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/lobby_member_updated.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/lobby_start_countdown.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/lobby_match_start.json`
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/fixtures/protocol/`（从服务端整目录重新复制）
- Test: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/test/lobby_protocol.test.ts`

**Interfaces:**
- Consumes:
  - **S1 Task 5 的 `src/lib/protocol/version.ts`**：`PROTOCOL_VERSION = 1`、`readProtocolVersionFromMarkdown(markdown: string): number`。本任务**不创建也不覆盖**这个文件——版本号只能有一处定义。
  - **S1 Task 5 的 `protocol/PROTOCOL.md`**（含机器可读的 `PROTOCOL_VERSION = 1` 行与「fixtures」一节）与 `protocol/fixtures/manifest.json`（`{ "protocol_version": number, "messages": string[] }`）。
  - Task 2 的 `MAX_MEMBERS`、`PING_INTERVAL_MS`、`PING_TIMEOUT_MS`、`RECONNECT_GRACE_MS`、`NICKNAME_MIN_LENGTH`、`NICKNAME_MAX_LENGTH`（仅用于写入 `PROTOCOL.md` 的文字说明，代码不导入）。
- Produces:
  - `OPCODE_LOBBY_MIN = 0x00`、`OPCODE_LOBBY_MAX = 0x7f`、`OPCODE_SYNC_MIN = 0x80`、`OPCODE_SYNC_MAX = 0xff`、`OPCODE_LOBBY_JSON = 0x01`、`OPCODE_LOBBY_PING = 0x02`、`OPCODE_LOBBY_PONG = 0x03`
  - `isLobbyOpcode(opcode: number): boolean`、`isSyncOpcode(opcode: number): boolean`
  - `type ClientMessageType`、`type ServerMessageType`、`CLIENT_MESSAGE_TYPES: readonly ClientMessageType[]`、`SERVER_MESSAGE_TYPES: readonly ServerMessageType[]`
  - `interface JoinMessage`、`SetReadyMessage`、`SetNicknameMessage`、`StartMessage`、`EndMatchMessage`、`LeaveMessage`、`PingMessage`、`MatchResultMessage`、`type ClientMessage`、`interface ServerMessage`
  - `class ProtocolError extends Error { readonly code: string }`
  - `parseClientMessage(raw: string): ClientMessage`
  - `encodeServerMessage(message: ServerMessage): string`
  - `frameToText(data: unknown): string`
  - `protocol/fixtures/lobby_*.json` 共 8 个共享样本（**扁平帧**，见 Step 4），并复制到客户端 `tools/validation/fixtures/protocol/`

**线格式一次说清**：大厅帧就是**扁平 JSON 对象**，`type` 与全部字段同级，**没有 `payload` 嵌套**。
S1 修订版已经删掉了原先的 `{protocol_version, type, payload}` 信封与 `src/lib/protocol.ts`，
服务端协议目录唯一为 `src/lib/protocol/`，客户端镜像唯一为 `scripts/net/lobby_protocol.gd`。

- [ ] **Step 1: 确认 S1 的协议底座已就位，再写 opcode 号段**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
ls src/lib/protocol/version.ts protocol/PROTOCOL.md protocol/fixtures/manifest.json
rg -n "export const PROTOCOL_VERSION|export function readProtocolVersionFromMarkdown" src/lib/protocol/version.ts
rg -n "^PROTOCOL_VERSION = " protocol/PROTOCOL.md
test ! -e src/lib/protocol.ts && echo "no legacy src/lib/protocol.ts (expected)"
```

Expected: 三个文件都存在；`version.ts` 同时导出 `PROTOCOL_VERSION` 与 `readProtocolVersionFromMarkdown`；`PROTOCOL.md` 里有机器可读的 `PROTOCOL_VERSION = 1` 行；打印 `no legacy src/lib/protocol.ts (expected)`。**任何一条不满足都要先回到 S1 计划的修订版补齐，不得在本任务里新建 `version.ts` 或覆盖 `PROTOCOL.md`。**

创建 `src/lib/protocol/opcodes.ts`：

```ts
/**
 * 二进制帧号段划分。
 *
 * 0x00-0x7F：大厅与控制消息。本轮的大厅消息全部走 JSON 文本帧，
 *            这些号只在将来需要压缩大厅流量时启用。
 * 0x80-0xFF：整段预留给 S3 同步层（tick 定序、玩家状态量化广播、
 *            desync_report）。本轮**只划号段，不实现任何 0x80+ 消息**。
 */
export const OPCODE_LOBBY_MIN = 0x00;
export const OPCODE_LOBBY_MAX = 0x7f;
export const OPCODE_SYNC_MIN = 0x80;
export const OPCODE_SYNC_MAX = 0xff;

export const OPCODE_LOBBY_JSON = 0x01;
export const OPCODE_LOBBY_PING = 0x02;
export const OPCODE_LOBBY_PONG = 0x03;

export function isLobbyOpcode(opcode: number): boolean {
  return Number.isInteger(opcode) && opcode >= OPCODE_LOBBY_MIN && opcode <= OPCODE_LOBBY_MAX;
}

export function isSyncOpcode(opcode: number): boolean {
  return Number.isInteger(opcode) && opcode >= OPCODE_SYNC_MIN && opcode <= OPCODE_SYNC_MAX;
}
```

- [ ] **Step 2: 写入大厅消息类型与解析器**

创建 `src/lib/protocol/lobby.ts`：

```ts
export type ClientMessageType =
  | 'join'
  | 'set_ready'
  | 'set_nickname'
  | 'start'
  | 'end_match'
  | 'leave'
  | 'ping'
  | 'match_result';

export type ServerMessageType =
  | 'room_state'
  | 'member_joined'
  | 'member_left'
  | 'member_updated'
  | 'start_countdown'
  | 'match_start'
  | 'error'
  | 'pong';

/**
 * 这个数组同时是 parseClientMessage 的白名单与 PROTOCOL.md「客户端 → 服务端」
 * 表格的顺序事实源。test/lobby_protocol.test.ts 会从 Markdown 里把该表格解析
 * 回来逐字比对，所以「文档说 7 种、代码收 8 种」这类漂移会变成构建失败。
 */
export const CLIENT_MESSAGE_TYPES: readonly ClientMessageType[] = [
  'join',
  'set_ready',
  'set_nickname',
  'start',
  'end_match',
  'leave',
  'ping',
  'match_result',
];

export const SERVER_MESSAGE_TYPES: readonly ServerMessageType[] = [
  'room_state',
  'member_joined',
  'member_left',
  'member_updated',
  'start_countdown',
  'match_start',
  'error',
  'pong',
];

export interface JoinMessage {
  type: 'join';
  protocol_version: number;
  token: string | null;
  session_token: string | null;
  nickname: string;
}

export interface SetReadyMessage {
  type: 'set_ready';
  ready: boolean;
}

export interface SetNicknameMessage {
  type: 'set_nickname';
  nickname: string;
}

export interface StartMessage {
  type: 'start';
}

/** 房主在 playing 中主动收尾。spec 的状态机图里 `playing --> ended` 的另一半。 */
export interface EndMatchMessage {
  type: 'end_match';
}

export interface LeaveMessage {
  type: 'leave';
}

export interface PingMessage {
  type: 'ping';
  client_time_ms: number;
}

export interface MatchResultMessage {
  type: 'match_result';
  /** key 是 slot 的十进制字符串，值是该 slot 的击杀数。 */
  player_kills: Record<string, number>;
  team_wave: number;
}

export type ClientMessage =
  | JoinMessage
  | SetReadyMessage
  | SetNicknameMessage
  | StartMessage
  | EndMatchMessage
  | LeaveMessage
  | PingMessage
  | MatchResultMessage;

export interface ServerMessage {
  type: ServerMessageType;
  [key: string]: unknown;
}

export class ProtocolError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'ProtocolError';
  }
}

/** ws 的 message 事件可能给出 string / Buffer / ArrayBuffer / Buffer[]。 */
export function frameToText(data: unknown): string {
  if (typeof data === 'string') return data;
  if (Buffer.isBuffer(data)) return data.toString('utf8');
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString('utf8');
  if (Array.isArray(data)) return Buffer.concat(data as Buffer[]).toString('utf8');
  return '';
}

export function encodeServerMessage(message: ServerMessage): string {
  return JSON.stringify(message);
}

export function parseClientMessage(raw: string): ClientMessage {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new ProtocolError('invalid_json', 'frame is not valid JSON');
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new ProtocolError('invalid_message', 'frame must be a JSON object');
  }
  const object = value as Record<string, unknown>;
  const rawType = object['type'];
  if (typeof rawType !== 'string' || !(CLIENT_MESSAGE_TYPES as readonly string[]).includes(rawType)) {
    throw new ProtocolError('unknown_message', `unknown client message type: ${String(rawType)}`);
  }

  switch (rawType as ClientMessageType) {
    case 'join': {
      const version = object['protocol_version'];
      if (typeof version !== 'number' || !Number.isInteger(version)) {
        throw new ProtocolError('invalid_message', 'join.protocol_version must be an integer');
      }
      return {
        type: 'join',
        protocol_version: version,
        token: typeof object['token'] === 'string' ? object['token'] : null,
        session_token: typeof object['session_token'] === 'string' ? object['session_token'] : null,
        nickname: typeof object['nickname'] === 'string' ? object['nickname'] : '',
      };
    }
    case 'set_ready': {
      const ready = object['ready'];
      if (typeof ready !== 'boolean') {
        throw new ProtocolError('invalid_message', 'set_ready.ready must be a boolean');
      }
      return { type: 'set_ready', ready };
    }
    case 'set_nickname': {
      const nickname = object['nickname'];
      if (typeof nickname !== 'string') {
        throw new ProtocolError('invalid_message', 'set_nickname.nickname must be a string');
      }
      return { type: 'set_nickname', nickname };
    }
    case 'start':
      return { type: 'start' };
    case 'end_match':
      return { type: 'end_match' };
    case 'leave':
      return { type: 'leave' };
    case 'ping': {
      const clientTime = object['client_time_ms'];
      return {
        type: 'ping',
        client_time_ms:
          typeof clientTime === 'number' && Number.isFinite(clientTime) ? clientTime : 0,
      };
    }
    case 'match_result': {
      const kills = object['player_kills'];
      if (typeof kills !== 'object' || kills === null || Array.isArray(kills)) {
        throw new ProtocolError('invalid_message', 'match_result.player_kills must be an object');
      }
      const wave = object['team_wave'];
      if (typeof wave !== 'number' || !Number.isInteger(wave) || wave < 0) {
        throw new ProtocolError(
          'invalid_message',
          'match_result.team_wave must be a non-negative integer',
        );
      }
      const normalized: Record<string, number> = {};
      for (const [slot, count] of Object.entries(kills as Record<string, unknown>)) {
        if (!/^[0-3]$/.test(slot)) {
          throw new ProtocolError(
            'invalid_message',
            `match_result.player_kills key must be a slot 0-3, got "${slot}"`,
          );
        }
        if (typeof count !== 'number' || !Number.isInteger(count) || count < 0) {
          throw new ProtocolError(
            'invalid_message',
            `match_result.player_kills["${slot}"] must be a non-negative integer`,
          );
        }
        normalized[slot] = count;
      }
      return { type: 'match_result', player_kills: normalized, team_wave: wave };
    }
  }
}
```

- [ ] **Step 3: 往 PROTOCOL.md 追加大厅小节**

`protocol/PROTOCOL.md` 由 **S1 Task 5 创建**，已经含有「版本号」（机器可读的 `PROTOCOL_VERSION = 1` 行，
`readProtocolVersionFromMarkdown()` 与 S1 的 `test/protocol.test.ts` 靠它工作）与「fixtures」两节。

**在文件末尾追加**下面的小节，**不得改动或删除已有的「版本号」「fixtures」两节**。
唯一允许的就地修改是把 S1 写的客户端镜像路径更新为本计划的唯一镜像文件：
把 `res://scripts/net/protocol_codec.gd` 改成 `res://scripts/net/lobby_protocol.gd`
（S1 修订版已删除 `protocol_codec.gd`，若该字符串已经是 `lobby_protocol.gd` 就什么都不用做）。

追加内容：

````markdown
## 传输

- 大厅与控制消息走 **WebSocket 文本帧，内容为 JSON 对象**。
- 端点：`GET /api/rooms/:room_id/ws?ticket=<ticket>`（`Upgrade: websocket`）。
- 首次进房必须带 `ticket`；断线重连可以不带 `ticket`，改用首帧的 `session_token`。

## 二进制 opcode 号段

| 号段 | 归属 | 状态 |
| --- | --- | --- |
| `0x00`–`0x7F` | 大厅与控制 | 已划定；本轮大厅消息走 JSON 文本帧，`0x01` `0x02` `0x03` 已占名 |
| `0x80`–`0xFF` | S3 同步层（tick 定序、量化状态广播、`desync_report`） | **整段预留，本轮不实现** |

二进制帧的第 0 字节为 opcode。收到 `0x80`–`0xFF` 的实现必须在本轮静默丢弃并记录一次日志，
不得当作错误关闭连接——这样 S3 上线时旧客户端只是收不到同步数据，而不是断线。

## 握手

第一帧必须是 `join`：

```json
{
  "type": "join",
  "protocol_version": 1,
  "token": "<S1 匿名身份 bearer token，可为 null>",
  "session_token": "<断线重连时回填，首次进房为 null>",
  "nickname": "Bo"
}
```

- `protocol_version` 与服务端不一致 → 服务端先发一条 `error` 帧，再以 close code **4400** 关闭：

```json
{
  "type": "error",
  "code": "protocol_version_mismatch",
  "message": "protocol version mismatch: server 1, client 2",
  "server_protocol_version": 1,
  "client_protocol_version": 2
}
```

- `session_token` 非空时走重连路径，恢复原 slot；为空时兑换 URL 上的一次性 `ticket`。
- `token` 非空时按 S1 的 `SessionStore.resolve()` 解析身份；解析出的 `player_id` 必须与 ticket 上的一致，
  否则 `error(code=ticket_invalid)` + close code **4401**。`ZW_ENFORCE_AUTH=true` 时 `token` 为空或解析失败
  一律 `error(code=unauthenticated)` + close code **4401**；默认 `false` 时允许匿名。
- ticket 无效或过期 → `error(code=ticket_invalid | ticket_expired)` + close code **4401**。
  **ticket 的兑换发生在首帧 `join`，不在 HTTP 升级阶段**：断线重连不带 ticket，只带 `session_token`，
  在升级阶段就要求 ticket 会让重连永远失败。升级阶段只校验房间是否存在。
- 房间不存在 → HTTP 升级阶段直接 404；房间在连接期间消失 → close code **4404**。
- 同一 slot 被新连接顶替 → 旧连接 close code **4409**。
- 服务端主动停机 → close code **4500**。
- 客户端 15000 ms 未收到 `pong` → **客户端**主动以 close code **4408** 关闭并进入重连退避。
  服务端不产生该码，`4408` 号位对服务端保留（`WS_CLOSE_PONG_TIMEOUT` 只占名不使用）。

## 客户端 → 服务端

顺序与 `src/lib/protocol/lobby.ts` 的 `CLIENT_MESSAGE_TYPES` 逐字相同，测试会比对。

| type | 字段 | 约束 |
| --- | --- | --- |
| `join` | `protocol_version:int`、`token:string\|null`、`session_token:string\|null`、`nickname:string` | 必须是首帧 |
| `set_ready` | `ready:bool` | 仅 `lobby` |
| `set_nickname` | `nickname:string` | 仅 `lobby`，2–12 字符 |
| `start` | — | 仅房主、仅 `lobby`、非房主成员全部 ready |
| `end_match` | — | 仅房主、仅 `playing` |
| `leave` | — | 任意状态 |
| `ping` | `client_time_ms:number` | 每 5 秒一次 |
| `match_result` | `player_kills:{ "0".."3": int≥0 }`、`team_wave:int≥0` | 仅 `playing` |

## 服务端 → 客户端

顺序与 `src/lib/protocol/lobby.ts` 的 `SERVER_MESSAGE_TYPES` 逐字相同，测试会比对。

| type | 载荷 |
| --- | --- |
| `room_state` | `room`（全量成员与房间状态）、`you`（本席位 `slot` / `player_id` / `session_token` / `is_host`，广播时为 `null`）、`server`（`protocol_version` / `ping_interval_ms` / `reconnect_grace_ms` / `max_members`） |
| `member_joined` | `member` |
| `member_left` | `slot`、`player_id`、`reason`（`leave` \| `timeout`） |
| `member_updated` | `member` |
| `start_countdown` | `countdown_ms:int\|null`、`starts_at_ms:int\|null`、`canceled:bool`。倒计时被取消时三者为 `null` / `null` / `true`，客户端必须据此清掉「x 秒后开始」的过期文案 |
| `match_start` | `match`：`{seed, tick_rate, map_id, player_slots}` |
| `error` | `code`、`message`，版本不匹配时附 `server_protocol_version` / `client_protocol_version` |
| `pong` | `client_time_ms`、`server_time_ms` |

`match_start.match` 的形状是固定的：

```json
{
  "seed": 1234567890,
  "tick_rate": 20,
  "map_id": "demo_arena",
  "player_slots": [{ "slot": 0, "player_id": "...", "nickname": "..." }]
}
```

## 心跳与断线

- 客户端每 **5000 ms** 发 `ping`；服务端 **15000 ms** 未收到判定掉线。
- `lobby` / `starting` / `ended` 掉线 → 直接移出席位并广播 `member_left(reason=timeout)`。
- `playing` 掉线 → 保留席位 **30000 ms**，广播 `member_updated(connected=false)`；
  客户端带 `session_token` 重连即可恢复原 slot；超时后广播 `member_updated(abandoned=true)`，对局继续。
- 房主掉线：`lobby` 移交给最早加入的剩余成员（广播 `member_updated` + `room_state`）；`playing` 不移交。

## 容量

- 每房 **4 人**上限，`slot` 取 `0..3`，永远分配当前最小空位。
- **不支持战斗中热加入**：`starting` / `playing` / `ended` 状态下 `POST /api/rooms/:code/join` 返回 409。

## HTTP 端点

| 方法与路径 | 返回 |
| --- | --- |
| `POST /api/rooms` | `{room_code, room_id, ws_path, ticket, ticket_expires_in_ms, protocol_version, max_members, ping_interval_ms}` |
| `GET /api/rooms?offset=&limit=` | `{total, offset, limit, items:[PublicRoom]}`，仅 `public` 且未满的 `lobby` 房；每次请求先做一次心跳清理 |
| `POST /api/rooms/:code/join` | 与建房同形状，`ticket` 为一次性 |

## 大厅 fixtures

`fixtures/lobby_*.json`（以及 S1 的 `handshake.json` / `match_result.json`）是**扁平帧样本**：
文件内容就是线上那一帧本身，外加一个 `name` 字段作为标识。与 HTTP 样本
（`auth_anon_request.json` 一类，形如 `{name, type, payload}`）的区分规则是纯机械的：

> 一个样本是大厅帧，当且仅当它**没有 `payload` 键**，且它的 `type` 落在
> `CLIENT_MESSAGE_TYPES` 或 `SERVER_MESSAGE_TYPES` 里。

方向也由 `type` 决定——两张表没有任何重叠的 type，因此不需要额外的 `direction` 字段。

对拍方式（两端相同）：去掉 `name` 后，`decode(encode(frame))` 必须还原出同一个对象，
且 `manifest.protocol_version` 必须等于本端的 `PROTOCOL_VERSION`。
**不比较序列化后的字节串**——JSON 的键序在 TypeScript 与 GDScript 里没有共同保证。
````

- [ ] **Step 4: 写入共享 fixtures 并同步到客户端仓库**

spec 的「跨仓库协议同步」要求 `protocol/fixtures/*.json` 复制一份到
`zombiewar/tools/validation/fixtures/protocol/` 供客户端对拍。S1 只覆盖了 auth / leaderboard /
handshake / match_result 四类，本轮新增的 6 类服务端消息与 2 类客户端消息一个样本都没有，
Task 14 的对拍就会形同虚设。这一步补齐它们。

创建 `protocol/fixtures/lobby_join.json`：

```json
{
  "name": "lobby_join",
  "type": "join",
  "protocol_version": 1,
  "token": "bearer-token-sample",
  "session_token": null,
  "nickname": "阿波"
}
```

创建 `protocol/fixtures/lobby_set_ready.json`：

```json
{
  "name": "lobby_set_ready",
  "type": "set_ready",
  "ready": true
}
```

创建 `protocol/fixtures/lobby_room_state.json`：

```json
{
  "name": "lobby_room_state",
  "type": "room_state",
  "room": {
    "room_id": "room-1",
    "room_code": "AB2DEF",
    "name": "阿波 的房间",
    "visibility": "public",
    "state": "lobby",
    "map_id": "demo_arena",
    "tick_rate": 20,
    "max_members": 4,
    "host_slot": 0,
    "countdown_ms": null,
    "members": [
      {
        "slot": 0,
        "player_id": "player-a",
        "nickname": "阿波",
        "ready": false,
        "connected": true,
        "abandoned": false,
        "is_host": true
      }
    ]
  },
  "you": {
    "slot": 0,
    "player_id": "player-a",
    "session_token": "session-token-sample",
    "is_host": true
  },
  "server": {
    "protocol_version": 1,
    "ping_interval_ms": 5000,
    "reconnect_grace_ms": 30000,
    "max_members": 4
  }
}
```

创建 `protocol/fixtures/lobby_member_joined.json`：

```json
{
  "name": "lobby_member_joined",
  "type": "member_joined",
  "member": {
    "slot": 1,
    "player_id": "player-b",
    "nickname": "小北",
    "ready": false,
    "connected": true,
    "abandoned": false,
    "is_host": false
  }
}
```

创建 `protocol/fixtures/lobby_member_left.json`：

```json
{
  "name": "lobby_member_left",
  "type": "member_left",
  "slot": 1,
  "player_id": "player-b",
  "reason": "timeout"
}
```

创建 `protocol/fixtures/lobby_member_updated.json`：

```json
{
  "name": "lobby_member_updated",
  "type": "member_updated",
  "member": {
    "slot": 1,
    "player_id": "player-b",
    "nickname": "小北",
    "ready": true,
    "connected": false,
    "abandoned": false,
    "is_host": false
  }
}
```

创建 `protocol/fixtures/lobby_start_countdown.json`：

```json
{
  "name": "lobby_start_countdown",
  "type": "start_countdown",
  "countdown_ms": 3000,
  "starts_at_ms": 1700000003000,
  "canceled": false
}
```

创建 `protocol/fixtures/lobby_match_start.json`：

```json
{
  "name": "lobby_match_start",
  "type": "match_start",
  "match": {
    "seed": 1234567890,
    "tick_rate": 20,
    "map_id": "demo_arena",
    "player_slots": [
      { "slot": 0, "player_id": "player-a", "nickname": "阿波" },
      { "slot": 1, "player_id": "player-b", "nickname": "小北" }
    ]
  }
}
```

把这 8 个文件名追加进 `protocol/fixtures/manifest.json` 的 `messages` 数组（保留 S1 已有的 5 项，
`protocol_version` 不动）：

```json
{
  "protocol_version": 1,
  "messages": [
    "auth_anon_request.json",
    "auth_anon_response.json",
    "leaderboard_page.json",
    "handshake.json",
    "match_result.json",
    "lobby_join.json",
    "lobby_set_ready.json",
    "lobby_room_state.json",
    "lobby_member_joined.json",
    "lobby_member_left.json",
    "lobby_member_updated.json",
    "lobby_start_countdown.json",
    "lobby_match_start.json"
  ]
}
```

同步到客户端仓库并校验两份完全一致：

```bash
cp /Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/*.json \
   /Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/fixtures/protocol/
diff -r /Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures \
        /Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/fixtures/protocol
ls /Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/fixtures/protocol | wc -l
```

Expected: `diff -r` 无输出且退出码为 0；`ls | wc -l` 输出 `14`（manifest + 13 个样本）。

- [ ] **Step 5: 写入协议测试**

创建 `test/lobby_protocol.test.ts`：

```ts
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  CLIENT_MESSAGE_TYPES,
  SERVER_MESSAGE_TYPES,
  ProtocolError,
  encodeServerMessage,
  frameToText,
  parseClientMessage,
} from '../src/lib/protocol/lobby.js';
import {
  OPCODE_LOBBY_MAX,
  OPCODE_LOBBY_MIN,
  OPCODE_SYNC_MAX,
  OPCODE_SYNC_MIN,
  isLobbyOpcode,
  isSyncOpcode,
} from '../src/lib/protocol/opcodes.js';
import { PROTOCOL_VERSION } from '../src/lib/protocol/version.js';

const PROTOCOL_DIR = new URL('../protocol/', import.meta.url).pathname;
const FIXTURE_DIR = join(PROTOCOL_DIR, 'fixtures');

interface Manifest {
  protocol_version: number;
  messages: string[];
}

function readManifest(): Manifest {
  return JSON.parse(readFileSync(join(FIXTURE_DIR, 'manifest.json'), 'utf8')) as Manifest;
}

function readFixture(name: string): Record<string, unknown> {
  return JSON.parse(readFileSync(join(FIXTURE_DIR, name), 'utf8')) as Record<string, unknown>;
}

/**
 * 从 PROTOCOL.md 的一张消息表里取出第一列的 type 名。表格行形如
 * `| \`join\` | ... | ... |`，所以只要抓第一个反引号对就够，不需要真的解析 Markdown。
 */
function readMessageTable(markdown: string, heading: string): string[] {
  const lines = markdown.split('\n');
  const start = lines.findIndex((line) => line.trim() === heading);
  if (start < 0) throw new Error(`PROTOCOL.md is missing the "${heading}" section`);
  const types: string[] = [];
  for (const line of lines.slice(start + 1)) {
    if (line.startsWith('## ')) break;
    if (!line.startsWith('|')) continue;
    const match = /^\|\s*`([a-z_]+)`\s*\|/.exec(line);
    if (match !== null) types.push(match[1] as string);
  }
  return types;
}

describe('opcode 号段', () => {
  it('大厅段与同步段相接且不重叠', () => {
    expect(OPCODE_LOBBY_MIN).toBe(0x00);
    expect(OPCODE_LOBBY_MAX).toBe(0x7f);
    expect(OPCODE_SYNC_MIN).toBe(0x80);
    expect(OPCODE_SYNC_MAX).toBe(0xff);
    expect(OPCODE_SYNC_MIN - OPCODE_LOBBY_MAX).toBe(1);
    for (let opcode = 0; opcode <= 0xff; opcode += 1) {
      expect(isLobbyOpcode(opcode) !== isSyncOpcode(opcode)).toBe(true);
    }
  });

  it('拒绝非整数与越界 opcode', () => {
    expect(isLobbyOpcode(-1)).toBe(false);
    expect(isSyncOpcode(0x100)).toBe(false);
    expect(isLobbyOpcode(1.5)).toBe(false);
  });
});

describe('消息清单', () => {
  it('协议版本为 1', () => {
    expect(PROTOCOL_VERSION).toBe(1);
  });

  it('客户端与服务端消息集合与设计一致', () => {
    expect([...CLIENT_MESSAGE_TYPES]).toEqual([
      'join',
      'set_ready',
      'set_nickname',
      'start',
      'end_match',
      'leave',
      'ping',
      'match_result',
    ]);
    expect([...SERVER_MESSAGE_TYPES]).toEqual([
      'room_state',
      'member_joined',
      'member_left',
      'member_updated',
      'start_countdown',
      'match_start',
      'error',
      'pong',
    ]);
  });

  it('两张表没有重叠的 type，方向可以只由 type 判定', () => {
    const overlap = CLIENT_MESSAGE_TYPES.filter((type) =>
      (SERVER_MESSAGE_TYPES as readonly string[]).includes(type),
    );
    expect(overlap).toEqual([]);
  });
});

/**
 * 文档漂移在这里变成构建失败。没有这一条，「PROTOCOL.md 说客户端只发 7 种消息、
 * parseClientMessage 收 8 种」这种偏差会一直活到第三方按文档写实现的那天。
 */
describe('PROTOCOL.md 与实现一致', () => {
  const markdown = readFileSync(join(PROTOCOL_DIR, 'PROTOCOL.md'), 'utf8');

  it('版本号一行与 PROTOCOL_VERSION 相等', () => {
    const match = /^PROTOCOL_VERSION = (\d+)$/m.exec(markdown);
    expect(match).not.toBeNull();
    expect(Number((match as RegExpExecArray)[1])).toBe(PROTOCOL_VERSION);
  });

  it('客户端 → 服务端表格与 CLIENT_MESSAGE_TYPES 逐字相同', () => {
    expect(readMessageTable(markdown, '## 客户端 → 服务端')).toEqual([...CLIENT_MESSAGE_TYPES]);
  });

  it('服务端 → 客户端表格与 SERVER_MESSAGE_TYPES 逐字相同', () => {
    expect(readMessageTable(markdown, '## 服务端 → 客户端')).toEqual([...SERVER_MESSAGE_TYPES]);
  });

  it('客户端镜像指向 lobby_protocol.gd 而不是已删除的 protocol_codec.gd', () => {
    expect(markdown).toContain('scripts/net/lobby_protocol.gd');
    expect(markdown).not.toContain('protocol_codec.gd');
  });
});

describe('parseClientMessage', () => {
  it('解析 join 并补齐可选字段', () => {
    expect(parseClientMessage('{"type":"join","protocol_version":1}')).toEqual({
      type: 'join',
      protocol_version: 1,
      token: null,
      session_token: null,
      nickname: '',
    });
  });

  it('保留 join 的 token 与 session_token', () => {
    const parsed = parseClientMessage(
      JSON.stringify({
        type: 'join',
        protocol_version: 1,
        token: 'bearer-1',
        session_token: 'sess-1',
        nickname: 'Bo',
      }),
    );
    expect(parsed).toEqual({
      type: 'join',
      protocol_version: 1,
      token: 'bearer-1',
      session_token: 'sess-1',
      nickname: 'Bo',
    });
  });

  it('解析 set_ready / set_nickname / start / end_match / leave / ping', () => {
    expect(parseClientMessage('{"type":"set_ready","ready":true}')).toEqual({
      type: 'set_ready',
      ready: true,
    });
    expect(parseClientMessage('{"type":"set_nickname","nickname":"Bo"}')).toEqual({
      type: 'set_nickname',
      nickname: 'Bo',
    });
    expect(parseClientMessage('{"type":"start"}')).toEqual({ type: 'start' });
    expect(parseClientMessage('{"type":"end_match"}')).toEqual({ type: 'end_match' });
    expect(parseClientMessage('{"type":"leave"}')).toEqual({ type: 'leave' });
    expect(parseClientMessage('{"type":"ping","client_time_ms":42}')).toEqual({
      type: 'ping',
      client_time_ms: 42,
    });
  });

  it('解析 match_result 并规范化 slot 键', () => {
    expect(
      parseClientMessage('{"type":"match_result","player_kills":{"0":12,"1":7},"team_wave":9}'),
    ).toEqual({ type: 'match_result', player_kills: { '0': 12, '1': 7 }, team_wave: 9 });
  });

  it('拒绝坏 JSON、未知类型与坏字段', () => {
    expect(() => parseClientMessage('{ not json')).toThrowError(
      expect.objectContaining({ code: 'invalid_json' }),
    );
    expect(() => parseClientMessage('[]')).toThrowError(
      expect.objectContaining({ code: 'invalid_message' }),
    );
    expect(() => parseClientMessage('{"type":"desync_report"}')).toThrowError(
      expect.objectContaining({ code: 'unknown_message' }),
    );
    expect(() => parseClientMessage('{"type":"join"}')).toThrowError(ProtocolError);
    expect(() => parseClientMessage('{"type":"set_ready","ready":"yes"}')).toThrowError(
      ProtocolError,
    );
    expect(() =>
      parseClientMessage('{"type":"match_result","player_kills":{"7":1},"team_wave":1}'),
    ).toThrowError(expect.objectContaining({ code: 'invalid_message' }));
    expect(() =>
      parseClientMessage('{"type":"match_result","player_kills":{"0":-1},"team_wave":1}'),
    ).toThrowError(ProtocolError);
  });
});

describe('编码与帧解包', () => {
  it('encodeServerMessage 产出可被 JSON.parse 还原的文本', () => {
    const text = encodeServerMessage({ type: 'pong', client_time_ms: 1, server_time_ms: 2 });
    expect(JSON.parse(text)).toEqual({ type: 'pong', client_time_ms: 1, server_time_ms: 2 });
  });

  it('frameToText 接受 string / Buffer / ArrayBuffer / Buffer[]', () => {
    expect(frameToText('hi')).toBe('hi');
    expect(frameToText(Buffer.from('hi', 'utf8'))).toBe('hi');
    expect(frameToText(new Uint8Array([104, 105]).buffer)).toBe('hi');
    expect(frameToText([Buffer.from('h'), Buffer.from('i')])).toBe('hi');
    expect(frameToText(42)).toBe('');
  });
});

describe('共享 fixtures', () => {
  const manifest = readManifest();

  it('manifest 的版本号与 PROTOCOL_VERSION 相等', () => {
    expect(manifest.protocol_version).toBe(PROTOCOL_VERSION);
  });

  it('本轮新增的 8 个大厅样本全部登记在 manifest 里', () => {
    for (const name of [
      'lobby_join.json',
      'lobby_set_ready.json',
      'lobby_room_state.json',
      'lobby_member_joined.json',
      'lobby_member_left.json',
      'lobby_member_updated.json',
      'lobby_start_countdown.json',
      'lobby_match_start.json',
    ]) {
      expect(manifest.messages).toContain(name);
    }
  });

  it('每个大厅样本都能编解码往返，且方向可由 type 判定', () => {
    const lobbyFixtures = manifest.messages
      .map((name) => ({ name, body: readFixture(name) }))
      .filter(
        (entry) =>
          entry.body['payload'] === undefined &&
          ((CLIENT_MESSAGE_TYPES as readonly string[]).includes(String(entry.body['type'])) ||
            (SERVER_MESSAGE_TYPES as readonly string[]).includes(String(entry.body['type']))),
      );
    // handshake / match_result（S1）+ 本轮 8 个，一个都不能少。
    expect(lobbyFixtures.length).toBeGreaterThanOrEqual(10);

    for (const entry of lobbyFixtures) {
      const { name: _fixtureName, ...frame } = entry.body;
      const type = String(frame['type']);
      if ((CLIENT_MESSAGE_TYPES as readonly string[]).includes(type)) {
        // 客户端帧：解析器必须接受它，且解析结果里的 type 不变。
        const parsed = parseClientMessage(JSON.stringify(frame));
        expect(parsed.type).toBe(type);
      } else {
        // 服务端帧：编码后再 JSON.parse 必须逐字还原。
        expect(JSON.parse(encodeServerMessage(frame as never))).toEqual(frame);
      }
    }
  });
});
```

- [ ] **Step 6: 运行协议测试与类型检查**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
npx vitest run test/lobby_protocol.test.ts
npx tsc -p tsconfig.json --noEmit
```

Expected: `Test Files 1 passed`、`Tests 19 passed`（opcode 号段 2 + 消息清单 3 + PROTOCOL.md 与实现一致 4 + parseClientMessage 5 + 编码与帧解包 2 + 共享 fixtures 3）；`tsc` 无输出且退出码为 0。若实际数目不同，先核对是不是漏写了某个 `it`，不要直接改 Expected。

- [ ] **Step 7: 提交协议定义与 fixtures**

两个仓库各自提交。

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
git add src/lib/protocol protocol/PROTOCOL.md protocol/fixtures test/lobby_protocol.test.ts
git commit -m "feat: define lobby protocol, opcode ranges and shared fixtures"
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar add tools/validation/fixtures/protocol
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar commit \
  -m "chore: vendor lobby protocol fixtures from zombiewar-server"
```

Expected: 服务端提交包含 2 个新的 `src/lib/protocol/*.ts`（`opcodes.ts` / `lobby.ts`，**不含** S1 的 `version.ts`）、`protocol/PROTOCOL.md` 的追加、8 个新 fixture 与 `manifest.json`、1 个测试文件；客户端提交只新增 `tools/validation/fixtures/protocol/lobby_*.json` 与被更新的 `manifest.json`、`handshake.json`、`match_result.json`。

---

### Task 5: WebSocket 房间枢纽 `room_hub.ts`

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/room_hub.ts`
- Test: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/test/room_hub.test.ts`
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/package.json`（**只动 `devDependencies` 一段**；`@fastify/websocket` 由 S1 Task 1 装进 `dependencies`，本任务不重复安装）

**Interfaces:**
- Consumes:
  - Task 2：`RoomStore`、`RoomError`、`normalizeNickname`（经 `rooms.ts` 再导出，事实源是 S1 `sessions.ts`）、`MAX_MEMBERS`、`PING_INTERVAL_MS`、`RECONNECT_GRACE_MS`、`SWEEP_INTERVAL_MS`、`MATCH_RESULT_COLLECT_MS`、`type Room`、`type RoomMember`、`type RoomMemberPayload`、`type SweepReport`。
  - Task 4：`PROTOCOL_VERSION`、`parseClientMessage(raw)`、`encodeServerMessage(message)`、`frameToText(data)`、`ProtocolError`、`type ClientMessage`、`type ServerMessage`、`type MatchResultMessage`。
  - **S1 `src/lib/leaderboard.ts`**：`submitMatchResult(db: Db, options: SubmitMatchOptions): SubmitMatchResult`，其中
    - `SubmitMatchOptions = { roomId: string; season: number; slots: MatchSlot[]; reports: MatchReport[]; durationMs: number; now?: () => number }`
    - `MatchSlot = { slot: number; player_id: string }`
    - `MatchReport = { player_id: string; team_wave: number; player_kills: Record<string, number> }`（**snake_case**，与线上 `match_result` 帧逐字相同）
    - `SubmitMatchResult = { status: 'accepted' | 'no_majority' | 'too_few_players' | 'too_short' | 'out_of_range'; team_wave: number; player_kills: Record<string, number>; dissenters: string[]; reason: string; written: number }`
    - 1 人房不写榜、多数投票、合理性上限全部在该函数内部完成。**`slots` 必须传全**：没上报的玩家也要拿到 `team_waves` 行，函数靠 `slot -> player_id` 映射才知道给谁写。
  - **S1 `src/lib/db.ts`**：`type Db`、`openDatabase(dbPath: string): Db`。本文件用 `Db`，**不从 `better-sqlite3` 直接 import `Database`**。
  - **S1 `src/lib/sessions.ts`**：`class SessionStore` 的 `resolve(token: string | undefined): PlayerSession | undefined`（`PlayerSession.playerId`）。
  - **S1 `src/lib/http.ts`**：`class HttpError { statusCode: number; code: string }`——昵称非法时 `normalizeNickname()` 抛的是它，`room_hub` 的 catch 必须同时认得 `RoomError` 与 `HttpError` 才能把 `code` 原样搬进 `error` 帧。
  - **S1 `src/config.ts`**：`Config.enforceAuth`（`ZW_ENFORCE_AUTH`，默认 `false`）。
- Produces:
  - `WS_CLOSE_PROTOCOL_MISMATCH = 4400`、`WS_CLOSE_TICKET_INVALID = 4401`、`WS_CLOSE_ROOM_GONE = 4404`、`WS_CLOSE_PONG_TIMEOUT = 4408`（**仅占名，服务端不产生**）、`WS_CLOSE_REPLACED = 4409`、`WS_CLOSE_SHUTDOWN = 4500`
  - `interface HubSocket { send(data: string): void; close(code?: number, reason?: string): void; on(event: string, listener: (...args: any[]) => void): void }`
  - `interface HubSessions { resolve(token: string | undefined): { playerId: string } | undefined }`（`SessionStore` 结构上满足它；测试可以传一个两行的替身，不必为了握手用例开一个真实 SQLite）
  - `interface RoomHubOptions { store: RoomStore; log: HubLogger; sessions: HubSessions; enforceAuth: boolean; db: Db | null; season?: number; now?: () => number; sweepIntervalMs?: number }`
  - `interface HubLogger { info(payload: unknown, message: string): void; warn(payload: unknown, message: string): void; error(payload: unknown, message: string): void }`
  - `class RoomHub`：`constructor(options: RoomHubOptions)`、`start(): void`、`stop(): void`、`sweepNow(): SweepReport`、`handleConnection(socket: HubSocket, roomId: string, ticketId: string): void`、`get connectionCount(): number`

- [ ] **Step 1: 只安装 `@types/ws`，并确认 `@fastify/websocket` 已由 S1 装好**

`@fastify/websocket` 用 `fastify-plugin` 封装，同一 scope 重复注册会直接抛错。S1 Task 1 已经把它写进
`dependencies`、S1 Task 6 的 `buildApp()` 已经 `await app.register(websocket)`，所以本计划**只装类型包**。
`@types/ws` 会被 Task 6 的真实 WebSocket 升级用例用到（那条用例要 `import WebSocket from 'ws'`）。

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
npm install -D @types/ws@^8.5.13
node -e "const p=require('./package.json');console.log('dep:', p.dependencies['@fastify/websocket'], 'dev:', p.devDependencies['@types/ws'])"
rg -n "@fastify/websocket" src/app.ts
```

Expected: `node -e` 打印的两个版本号都非空（`dep:` 那个应当已由 S1 装好）；`rg` 在 `src/app.ts` 里命中 S1 已有的 import 与 `await app.register(websocket)`。若 `dep:` 打印 `undefined`，说明 S1 Task 1 没按修订版执行，回去补齐再继续——**不要在这里 `npm install @fastify/websocket`**。

- [ ] **Step 2: 确认 S1 的排行榜、数据库、身份三处签名与本任务一致**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
rg -n "export function submitMatchResult|export interface MatchSlot|export interface MatchReport|export interface SubmitMatchResult|export interface SubmitMatchOptions" src/lib/leaderboard.ts
rg -n "export type Db|export function openDatabase" src/lib/db.ts
rg -n "export class SessionStore|  resolve\(" src/lib/sessions.ts
rg -n "export class HttpError" src/lib/http.ts
rg -n "export function normalizeNickname" src/lib/sessions.ts src/lib/rooms.ts
```

Expected: 五条 `leaderboard.ts` 的导出、两条 `db.ts` 的导出、`SessionStore` 与它的 `resolve`、`HttpError`
全部命中；最后一条只在 `sessions.ts` 命中一次，`rooms.ts` **0 命中**（它只再导出）。
若签名与本任务 Consumes 中记录的不一致，先对齐 S1 计划的修订版再继续——`room_hub.ts` 是唯一的写榜调用点，签名漂移会在这里静默失败。

- [ ] **Step 3: 写入连接管理与握手**

创建 `src/lib/room_hub.ts`，先写到 `handleConnection`：

```ts
import { randomUUID } from 'node:crypto';

import type { Db } from './db.js';
import { HttpError } from './http.js';
import { submitMatchResult, type MatchReport, type MatchSlot } from './leaderboard.js';
import {
  ProtocolError,
  encodeServerMessage,
  frameToText,
  parseClientMessage,
  type ClientMessage,
  type MatchResultMessage,
  type ServerMessage,
} from './protocol/lobby.js';
import { PROTOCOL_VERSION } from './protocol/version.js';
import {
  MATCH_RESULT_COLLECT_MS,
  MAX_MEMBERS,
  PING_INTERVAL_MS,
  RECONNECT_GRACE_MS,
  RoomError,
  RoomStore,
  SWEEP_INTERVAL_MS,
  normalizeNickname,
  type Room,
  type RoomMemberPayload,
  type SweepReport,
} from './rooms.js';

/**
 * 唯一持有 socket 的一层。
 *
 * rooms.ts 决定「发生了什么」，room_hub.ts 决定「谁看得见」。所有房间状态变更
 * 都必须先经过 store，再由这里翻译成广播——反过来在这里直接改 Room 字段会让
 * 状态机的单测失去意义。
 */

export const WS_CLOSE_PROTOCOL_MISMATCH = 4400;
export const WS_CLOSE_TICKET_INVALID = 4401;
export const WS_CLOSE_ROOM_GONE = 4404;
/**
 * 客户端在 15000 ms 收不到 pong 时自己用这个码关闭。服务端从不发它——
 * 这里只是把号位占住，免得 S3 在服务端侧又给 4408 派别的用途。
 */
export const WS_CLOSE_PONG_TIMEOUT = 4408;
export const WS_CLOSE_REPLACED = 4409;
export const WS_CLOSE_SHUTDOWN = 4500;

/** 只声明 hub 真正用到的三个方法，测试替身与 ws.WebSocket 都能满足。 */
export interface HubSocket {
  send(data: string): void;
  close(code?: number, reason?: string): void;
  // eslint 未启用；此处刻意放宽以同时接受 ws.WebSocket 的重载签名与测试替身。
  on(event: string, listener: (...args: any[]) => void): void;
}

export interface HubLogger {
  info(payload: unknown, message: string): void;
  warn(payload: unknown, message: string): void;
  error(payload: unknown, message: string): void;
}

/**
 * 只声明 hub 真正用到的一个方法，S1 的 SessionStore 结构上满足它。
 * 握手要校验 bearer token，但为此在每条 hub 用例里开一个真实 SQLite 是浪费。
 */
export interface HubSessions {
  resolve(token: string | undefined): { playerId: string } | undefined;
}

export interface RoomHubOptions {
  store: RoomStore;
  log: HubLogger;
  sessions: HubSessions;
  /** 来自 S1 的 config.enforceAuth（ZW_ENFORCE_AUTH），默认关闭时允许匿名入座。 */
  enforceAuth: boolean;
  db: Db | null;
  season?: number;
  now?: () => number;
  sweepIntervalMs?: number;
}

interface Connection {
  id: string;
  socket: HubSocket;
  roomId: string;
  ticketId: string;
  slot: number;
  playerId: string;
  joined: boolean;
  closed: boolean;
}

export class RoomHub {
  private readonly store: RoomStore;
  private readonly log: HubLogger;
  private readonly sessions: HubSessions;
  private readonly enforceAuth: boolean;
  private readonly db: Db | null;
  private readonly season: number;
  private readonly now: () => number;
  private readonly sweepIntervalMs: number;
  private readonly connections = new Map<string, Connection>();
  /** `${roomId}:${slot}` -> connectionId */
  private readonly bySlot = new Map<string, string>();
  /** roomId -> slot -> 上报的结算数据（值是 leaderboard.ts 的 MatchReport，snake_case） */
  private readonly results = new Map<string, Map<number, MatchReport>>();
  /** roomId -> 收齐截止时间戳。第一份 match_result 到达时设置，超时就用已有的结算。 */
  private readonly resultDeadlines = new Map<string, number>();
  private timer: NodeJS.Timeout | null = null;

  constructor(options: RoomHubOptions) {
    this.store = options.store;
    this.log = options.log;
    this.sessions = options.sessions;
    this.enforceAuth = options.enforceAuth;
    this.db = options.db;
    this.season = options.season ?? 0;
    this.now = options.now ?? Date.now;
    this.sweepIntervalMs = options.sweepIntervalMs ?? SWEEP_INTERVAL_MS;
  }

  get connectionCount(): number {
    return this.connections.size;
  }

  start(): void {
    if (this.timer !== null) return;
    this.timer = setInterval(() => this.sweepNow(), this.sweepIntervalMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
    for (const connection of [...this.connections.values()]) {
      this.closeConnection(connection, WS_CLOSE_SHUTDOWN, 'server_shutdown');
    }
  }

  handleConnection(socket: HubSocket, roomId: string, ticketId: string): void {
    const connection: Connection = {
      id: randomUUID(),
      socket,
      roomId,
      ticketId,
      slot: -1,
      playerId: '',
      joined: false,
      closed: false,
    };
    this.connections.set(connection.id, connection);

    socket.on('message', (data: unknown) => {
      this.onFrame(connection, frameToText(data));
    });
    socket.on('close', () => {
      this.onSocketClosed(connection);
    });
    socket.on('error', (error: unknown) => {
      this.log.warn({ err: error, room: connection.roomId }, 'websocket error');
      this.onSocketClosed(connection);
    });
  }

  private onFrame(connection: Connection, raw: string): void {
    if (connection.closed) return;
    let message: ClientMessage;
    try {
      message = parseClientMessage(raw);
    } catch (error) {
      const code = error instanceof ProtocolError ? error.code : 'invalid_message';
      const text = error instanceof Error ? error.message : 'unparsable frame';
      this.send(connection, { type: 'error', code, message: text });
      return;
    }
    if (!connection.joined) {
      if (message.type !== 'join') {
        this.send(connection, {
          type: 'error',
          code: 'handshake_required',
          message: 'the first frame must be a join message',
        });
        this.closeConnection(connection, WS_CLOSE_TICKET_INVALID, 'handshake_required');
        return;
      }
      this.handleJoin(connection, message);
      return;
    }
    this.handleJoined(connection, message);
  }

  private handleJoin(
    connection: Connection,
    message: Extract<ClientMessage, { type: 'join' }>,
  ): void {
    if (message.protocol_version !== PROTOCOL_VERSION) {
      this.send(connection, {
        type: 'error',
        code: 'protocol_version_mismatch',
        message: `protocol version mismatch: server ${PROTOCOL_VERSION}, client ${message.protocol_version}`,
        server_protocol_version: PROTOCOL_VERSION,
        client_protocol_version: message.protocol_version,
      });
      this.closeConnection(connection, WS_CLOSE_PROTOCOL_MISMATCH, 'protocol_version_mismatch');
      return;
    }

    const room = this.store.getRoom(connection.roomId);
    if (room === undefined) {
      this.send(connection, {
        type: 'error',
        code: 'room_not_found',
        message: `no room with id ${connection.roomId}`,
      });
      this.closeConnection(connection, WS_CLOSE_ROOM_GONE, 'room_not_found');
      return;
    }

    /**
     * `join.token` 不是装饰。ENFORCE_AUTH 关闭时它可以为空（匿名局域网联机是
     * 本轮的主路径），但只要带了就必须能解析出身份，且这个身份要与 ticket 上的
     * player_id 一致——否则任何人拿到一张 ticket 就能顶着别人的 player_id 入座，
     * 而 player_id 正是写榜时唯一的归属依据。
     */
    const session =
      message.token === null || message.token === ''
        ? undefined
        : this.sessions.resolve(message.token);
    if (this.enforceAuth && session === undefined) {
      this.send(connection, {
        type: 'error',
        code: 'unauthenticated',
        message: 'a valid bearer token is required when ZW_ENFORCE_AUTH is on',
      });
      this.closeConnection(connection, WS_CLOSE_TICKET_INVALID, 'unauthenticated');
      return;
    }

    let seated: { room: Room; member: { slot: number; playerId: string; sessionToken: string } };
    try {
      if (message.session_token !== null && message.session_token !== '') {
        seated = this.store.rejoinRoom(room.id, message.session_token);
        if (session !== undefined && seated.member.playerId !== session.playerId) {
          throw new RoomError(
            'session_unknown',
            403,
            'session_token belongs to a different player than the bearer token',
          );
        }
      } else {
        const claim = this.store.peekTicket(connection.ticketId, room.id);
        if (session !== undefined && claim.playerId !== session.playerId) {
          throw new RoomError(
            'ticket_invalid',
            403,
            'ticket was issued to a different player than the bearer token',
          );
        }
        const redeemed = this.store.redeemTicket(connection.ticketId, room.id);
        if (message.nickname !== '') {
          redeemed.nickname = normalizeNickname(message.nickname);
        }
        seated = this.store.joinRoom(room.id, redeemed);
      }
    } catch (error) {
      // 昵称非法时抛的是 S1 的 HttpError（code 为 invalid_nickname / nickname_blocked），
      // 房间层的错误是 RoomError。两者都带 code 字段，原样搬进 error 帧即可。
      const code =
        error instanceof RoomError || error instanceof HttpError ? error.code : 'ticket_invalid';
      const text = error instanceof Error ? error.message : 'could not seat this connection';
      this.send(connection, { type: 'error', code, message: text });
      this.closeConnection(connection, WS_CLOSE_TICKET_INVALID, code);
      return;
    }

    const slotKey = `${room.id}:${seated.member.slot}`;
    const previousId = this.bySlot.get(slotKey);
    if (previousId !== undefined && previousId !== connection.id) {
      const previous = this.connections.get(previousId);
      if (previous !== undefined) {
        this.closeConnection(previous, WS_CLOSE_REPLACED, 'replaced_by_new_connection');
      }
    }

    connection.joined = true;
    connection.slot = seated.member.slot;
    connection.playerId = seated.member.playerId;
    this.bySlot.set(slotKey, connection.id);

    this.send(connection, {
      type: 'room_state',
      room: this.store.toRoomState(seated.room),
      you: {
        slot: seated.member.slot,
        player_id: seated.member.playerId,
        session_token: seated.member.sessionToken,
        is_host: seated.room.hostPlayerId === seated.member.playerId,
      },
      server: this.serverInfo(),
    });

    const memberPayload = this.memberPayload(seated.room, seated.member.slot);
    if (memberPayload !== null) {
      this.broadcast(seated.room.id, { type: 'member_joined', member: memberPayload }, connection.id);
    }
    this.log.info(
      { room: seated.room.code, slot: seated.member.slot, player: seated.member.playerId },
      'member seated',
    );
  }
```

- [ ] **Step 4: 写入已入座消息分发与结算收集**

在 `RoomHub` 类体内继续追加：

```ts
  private handleJoined(connection: Connection, message: ClientMessage): void {
    try {
      switch (message.type) {
        case 'join': {
          this.send(connection, {
            type: 'error',
            code: 'already_joined',
            message: 'this connection already holds a seat',
          });
          return;
        }
        case 'set_ready': {
          const result = this.store.setReady(connection.roomId, connection.slot, message.ready);
          this.broadcast(connection.roomId, {
            type: 'member_updated',
            member: this.store.toMemberPayload(result.room, result.member),
          });
          return;
        }
        case 'set_nickname': {
          const result = this.store.setNickname(
            connection.roomId,
            connection.slot,
            message.nickname,
          );
          this.broadcast(connection.roomId, {
            type: 'member_updated',
            member: this.store.toMemberPayload(result.room, result.member),
          });
          return;
        }
        case 'start': {
          const room = this.store.requestStart(connection.roomId, connection.slot);
          this.broadcast(room.id, {
            type: 'start_countdown',
            countdown_ms: room.countdownEndsAt === null ? 0 : room.countdownEndsAt - this.now(),
            starts_at_ms: room.countdownEndsAt ?? this.now(),
            canceled: false,
          });
          this.broadcastRoomState(room);
          return;
        }
        case 'end_match': {
          // spec 的状态机图里 `playing --> ended: 全灭或房主结束` 的后半句。
          // 没有这条分支，MatchEndReason 的 'host_ended' 就是一个永远到不了的值。
          const room = this.store.requireRoom(connection.roomId);
          if (room.hostPlayerId !== connection.playerId) {
            throw new RoomError('not_host', 403, 'only the host can end the match');
          }
          const bucket = this.results.get(room.id);
          if (bucket !== undefined && bucket.size > 0) {
            // 房主收尾前已经有人上报了，先把成绩落地再改状态——
            // finalizeMatch() 内部会调用 endMatch()。
            this.finalizeMatch(room, bucket, 'host_ended');
            return;
          }
          this.store.endMatch(room.id, 'host_ended');
          this.resultDeadlines.delete(room.id);
          this.broadcastRoomState(room);
          return;
        }
        case 'leave': {
          this.applyLeave(connection, 'leave');
          this.closeConnection(connection, 1000, 'left');
          return;
        }
        case 'ping': {
          this.store.applyPing(connection.roomId, connection.slot);
          this.send(connection, {
            type: 'pong',
            client_time_ms: message.client_time_ms,
            server_time_ms: this.now(),
          });
          return;
        }
        case 'match_result': {
          this.collectMatchResult(connection, message);
          return;
        }
      }
    } catch (error) {
      const code =
        error instanceof RoomError || error instanceof HttpError ? error.code : 'internal_error';
      const text = error instanceof Error ? error.message : 'request failed';
      this.send(connection, { type: 'error', code, message: text });
    }
  }

  private collectMatchResult(connection: Connection, message: MatchResultMessage): void {
    const room = this.store.getRoom(connection.roomId);
    if (room === undefined) return;
    if (room.state !== 'playing') {
      this.send(connection, {
        type: 'error',
        code: 'invalid_state',
        message: `match_result is only valid while playing (state=${room.state})`,
      });
      return;
    }
    let bucket = this.results.get(room.id);
    if (bucket === undefined) {
      bucket = new Map<number, MatchReport>();
      this.results.set(room.id, bucket);
    }
    // 值的形状就是 leaderboard.ts 的 MatchReport：snake_case、以 player_id 为主键。
    bucket.set(connection.slot, {
      player_id: connection.playerId,
      team_wave: message.team_wave,
      player_kills: message.player_kills,
    });

    /**
     * 只等**还连着**的席位。把 30 秒重连宽限里的掉线者算进期望数，等于在等
     * 一个永远不会发 match_result 的连接：房间会卡死在 playing，bucket 直到房间
     * 销毁才释放，成绩全丢。只要有一人在结算瞬间掉线就会命中。
     */
    const expected = room.members.filter(
      (member) => member.connected && !member.abandoned,
    ).length;
    if (expected === 0 || bucket.size < expected) {
      // 兜底窗口：第一份上报到达后最多再等 MATCH_RESULT_COLLECT_MS。
      if (bucket.size > 0 && this.resultDeadlines.get(room.id) === undefined) {
        this.resultDeadlines.set(room.id, this.now() + MATCH_RESULT_COLLECT_MS);
      }
      return;
    }
    this.finalizeMatch(room, bucket, 'wiped');
  }

  private finalizeMatch(
    room: Room,
    bucket: Map<number, MatchReport>,
    reason: 'wiped' | 'host_ended',
  ): void {
    this.results.delete(room.id);
    this.resultDeadlines.delete(room.id);
    const reports = [...bucket.values()];
    const durationMs = room.startedAt === null ? 0 : this.now() - room.startedAt;

    if (this.db !== null) {
      try {
        /**
         * slots 必须是房间里的**全部**席位，不是上报者的子集：没上报的玩家
         * 也要拿到 team_waves 行，submitMatchResult() 靠这张 slot -> player_id
         * 表才知道给谁写。只传 reports 会让沉默的队友悄悄丢榜。
         */
        const slots: MatchSlot[] = [...room.members]
          .sort((a, b) => a.slot - b.slot)
          .map((member) => ({ slot: member.slot, player_id: member.playerId }));
        const outcome = submitMatchResult(this.db, {
          roomId: room.id,
          season: this.season,
          slots,
          reports,
          durationMs,
        });
        this.log.info({ room: room.code, outcome }, 'match result processed');
        if (outcome.status !== 'accepted') {
          this.broadcast(room.id, {
            type: 'error',
            code: 'score_not_saved',
            message: `成绩未保存：${outcome.reason}`,
          });
        } else if (outcome.dissenters.length > 0) {
          // dissenters 是 player_id 列表；需要 slot 时在这里用 slots 反查。
          const dissentingSlots = outcome.dissenters
            .map((playerId) => slots.find((slot) => slot.player_id === playerId)?.slot)
            .filter((slot): slot is number => slot !== undefined);
          this.log.warn(
            { room: room.code, dissenters: outcome.dissenters, slots: dissentingSlots },
            'minority reports discarded',
          );
        }
      } catch (error) {
        this.log.error({ err: error, room: room.code }, 'leaderboard write failed');
        this.broadcast(room.id, {
          type: 'error',
          code: 'score_not_saved',
          message: '成绩未保存：存储写入失败',
        });
      }
    }

    if (room.state === 'playing') this.store.endMatch(room.id, reason);
    this.broadcastRoomState(room);
  }
```

- [ ] **Step 5: 写入断线处理、sweep 广播与发送辅助**

在 `RoomHub` 类体内继续追加，并以 `}` 收尾整个类：

```ts
  private applyLeave(connection: Connection, reason: 'leave' | 'timeout'): void {
    if (!connection.joined) return;
    const roomId = connection.roomId;
    const slot = connection.slot;
    const outcome =
      reason === 'leave'
        ? this.store.leaveRoom(roomId, slot)
        : this.store.markDisconnected(roomId, slot);
    this.bySlot.delete(`${roomId}:${slot}`);
    connection.joined = false;

    if (outcome.destroyed) {
      this.closeRoomConnections(roomId, WS_CLOSE_ROOM_GONE, 'room_destroyed');
      this.results.delete(roomId);
      this.resultDeadlines.delete(roomId);
      return;
    }
    const room = outcome.room;
    if (room === null) return;

    if (outcome.removed) {
      this.broadcast(roomId, {
        type: 'member_left',
        slot,
        player_id: connection.playerId,
        reason,
      });
    } else {
      const payload = this.memberPayload(room, slot);
      if (payload !== null) {
        this.broadcast(roomId, { type: 'member_updated', member: payload });
      }
    }
    if (outcome.hostTransferredTo !== null) {
      const payload = this.memberPayload(room, outcome.hostTransferredTo.slot);
      if (payload !== null) {
        this.broadcast(roomId, { type: 'member_updated', member: payload });
      }
    }
    if (outcome.stateChanged !== null || outcome.hostTransferredTo !== null) {
      this.broadcastRoomState(room);
    }
  }

  private onSocketClosed(connection: Connection): void {
    if (connection.closed) return;
    connection.closed = true;
    this.connections.delete(connection.id);
    if (connection.joined) {
      this.applyLeave(connection, 'timeout');
    }
  }

  sweepNow(): SweepReport {
    // 结算兜底先跑：到期的房间用手上已有的上报收尾，之后 store.sweep() 才会
    // 因为 ended 状态把它列进销毁候选。反过来做会让最后一批成绩随房间一起消失。
    const ts = this.now();
    for (const [roomId, deadline] of [...this.resultDeadlines]) {
      if (ts < deadline) continue;
      this.resultDeadlines.delete(roomId);
      const bucket = this.results.get(roomId);
      const room = this.store.getRoom(roomId);
      if (bucket === undefined || room === undefined || room.state !== 'playing') {
        this.results.delete(roomId);
        continue;
      }
      this.log.warn(
        { room: room.code, received: bucket.size },
        'match result collection timed out; finalizing with what arrived',
      );
      this.finalizeMatch(room, bucket, 'wiped');
    }

    const report = this.store.sweep();

    for (const ref of report.disconnectedMembers) {
      const room = this.store.getRoom(ref.roomId);
      const payload = room === undefined ? null : this.memberPayload(room, ref.slot);
      if (payload !== null) {
        this.broadcast(ref.roomId, { type: 'member_updated', member: payload });
      }
      this.dropSlotConnection(ref.roomId, ref.slot, 1001, 'ping_timeout');
    }
    for (const ref of report.removedMembers) {
      this.broadcast(ref.roomId, {
        type: 'member_left',
        slot: ref.slot,
        player_id: ref.playerId,
        reason: 'timeout',
      });
      this.dropSlotConnection(ref.roomId, ref.slot, 1001, 'ping_timeout');
    }
    for (const ref of report.abandonedMembers) {
      const room = this.store.getRoom(ref.roomId);
      const payload = room === undefined ? null : this.memberPayload(room, ref.slot);
      if (payload !== null) {
        this.broadcast(ref.roomId, { type: 'member_updated', member: payload });
      }
    }
    for (const ref of report.hostTransfers) {
      const room = this.store.getRoom(ref.roomId);
      const payload = room === undefined ? null : this.memberPayload(room, ref.slot);
      if (payload !== null) {
        this.broadcast(ref.roomId, { type: 'member_updated', member: payload });
      }
    }
    for (const roomId of report.canceledStarts) {
      // 只广播 room_state 不够：客户端的 ConnectionLabel 上还挂着「对局将在 x 秒后
      // 开始」，而 room_state 的处理路径从不碰那行字。必须显式说一句倒计时没了。
      this.broadcast(roomId, {
        type: 'start_countdown',
        countdown_ms: null,
        starts_at_ms: null,
        canceled: true,
      });
    }
    for (const roomId of [...report.canceledStarts, ...report.endedRooms]) {
      const room = this.store.getRoom(roomId);
      if (room !== undefined) this.broadcastRoomState(room);
    }
    for (const roomId of report.startedRooms) {
      const room = this.store.getRoom(roomId);
      if (room === undefined) continue;
      this.broadcast(roomId, { type: 'match_start', match: this.store.buildMatchStart(room) });
      this.broadcastRoomState(room);
    }
    for (const roomId of report.destroyedRoomIds) {
      this.closeRoomConnections(roomId, WS_CLOSE_ROOM_GONE, 'room_destroyed');
      this.results.delete(roomId);
      this.resultDeadlines.delete(roomId);
    }
    return report;
  }

  private dropSlotConnection(roomId: string, slot: number, code: number, reason: string): void {
    const connectionId = this.bySlot.get(`${roomId}:${slot}`);
    if (connectionId === undefined) return;
    const connection = this.connections.get(connectionId);
    this.bySlot.delete(`${roomId}:${slot}`);
    if (connection === undefined) return;
    connection.joined = false;
    this.closeConnection(connection, code, reason);
  }

  private closeRoomConnections(roomId: string, code: number, reason: string): void {
    for (const connection of [...this.connections.values()]) {
      if (connection.roomId !== roomId) continue;
      this.bySlot.delete(`${roomId}:${connection.slot}`);
      connection.joined = false;
      this.closeConnection(connection, code, reason);
    }
  }

  private closeConnection(connection: Connection, code: number, reason: string): void {
    if (connection.closed) return;
    connection.closed = true;
    this.connections.delete(connection.id);
    if (connection.slot >= 0) this.bySlot.delete(`${connection.roomId}:${connection.slot}`);
    try {
      connection.socket.close(code, reason);
    } catch (error) {
      this.log.warn({ err: error }, 'closing a websocket threw');
    }
  }

  private memberPayload(room: Room, slot: number): RoomMemberPayload | null {
    const member = room.members.find((candidate) => candidate.slot === slot);
    return member === undefined ? null : this.store.toMemberPayload(room, member);
  }

  private broadcastRoomState(room: Room): void {
    this.broadcast(room.id, {
      type: 'room_state',
      room: this.store.toRoomState(room),
      you: null,
      server: this.serverInfo(),
    });
  }

  private broadcast(roomId: string, message: ServerMessage, exceptConnectionId?: string): void {
    const text = encodeServerMessage(message);
    for (const connection of this.connections.values()) {
      if (connection.roomId !== roomId) continue;
      if (!connection.joined) continue;
      if (exceptConnectionId !== undefined && connection.id === exceptConnectionId) continue;
      this.sendText(connection, text);
    }
  }

  private send(connection: Connection, message: ServerMessage): void {
    this.sendText(connection, encodeServerMessage(message));
  }

  private sendText(connection: Connection, text: string): void {
    if (connection.closed) return;
    try {
      connection.socket.send(text);
    } catch (error) {
      this.log.warn({ err: error, room: connection.roomId }, 'sending to a websocket threw');
    }
  }

  private serverInfo(): Record<string, number> {
    return {
      protocol_version: PROTOCOL_VERSION,
      ping_interval_ms: PING_INTERVAL_MS,
      reconnect_grace_ms: RECONNECT_GRACE_MS,
      max_members: MAX_MEMBERS,
    };
  }
}
```

- [ ] **Step 6: 写入 hub 测试**

创建 `test/room_hub.test.ts`：

```ts
import { beforeEach, describe, expect, it } from 'vitest';

import { PROTOCOL_VERSION } from '../src/lib/protocol/version.js';
import {
  RoomHub,
  WS_CLOSE_PROTOCOL_MISMATCH,
  WS_CLOSE_TICKET_INVALID,
  type HubSessions,
  type HubSocket,
  type RoomHubOptions,
} from '../src/lib/room_hub.js';
import {
  MATCH_RESULT_COLLECT_MS,
  PING_TIMEOUT_MS,
  RoomStore,
  START_COUNTDOWN_MS,
  type Room,
} from '../src/lib/rooms.js';

interface FakeSocket extends HubSocket {
  sent: Array<Record<string, unknown>>;
  closes: Array<{ code: number | undefined; reason: string | undefined }>;
  emit(event: 'message' | 'close' | 'error', payload?: unknown): void;
  lastOfType(type: string): Record<string, unknown> | undefined;
}

function makeSocket(): FakeSocket {
  const listeners = new Map<string, Array<(payload?: unknown) => void>>();
  const socket: FakeSocket = {
    sent: [],
    closes: [],
    send(data: string) {
      socket.sent.push(JSON.parse(data) as Record<string, unknown>);
    },
    close(code?: number, reason?: string) {
      socket.closes.push({ code, reason });
    },
    on(event: string, listener: (...args: any[]) => void) {
      const bucket = listeners.get(event) ?? [];
      bucket.push(listener as (payload?: unknown) => void);
      listeners.set(event, bucket);
    },
    emit(event, payload) {
      for (const listener of listeners.get(event) ?? []) listener(payload);
    },
    lastOfType(type: string) {
      return [...socket.sent].reverse().find((message) => message['type'] === type);
    },
  };
  return socket;
}

const silentLog = {
  info: () => undefined,
  warn: () => undefined,
  error: () => undefined,
};

/** SessionStore 的最小替身：这些用例不校验真实 token，只需要一个可注入的解析器。 */
const anonymousSessions: HubSessions = { resolve: () => undefined };

let clock = 1_700_000_000_000;
let store: RoomStore;
let hub: RoomHub;
let tokenSequence = 0;

function advance(ms: number): void {
  clock += ms;
}

function makeHub(overrides: Partial<RoomHubOptions> = {}): RoomHub {
  return new RoomHub({
    store,
    log: silentLog,
    sessions: anonymousSessions,
    enforceAuth: false,
    db: null,
    now: () => clock,
    ...overrides,
  });
}

beforeEach(() => {
  clock = 1_700_000_000_000;
  tokenSequence = 0;
  store = new RoomStore({
    now: () => clock,
    newRoomId: () => 'room-1',
    newToken: () => `tok-${(tokenSequence += 1)}`,
    newSeed: () => 777,
  });
  hub = makeHub();
});

function connect(room: Room, playerId: string, nickname: string): FakeSocket {
  const ticket = store.issueTicket(room, playerId, nickname);
  const socket = makeSocket();
  hub.handleConnection(socket, room.id, ticket.id);
  socket.emit(
    'message',
    JSON.stringify({
      type: 'join',
      protocol_version: PROTOCOL_VERSION,
      token: 'bearer',
      session_token: null,
      nickname,
    }),
  );
  return socket;
}

describe('握手', () => {
  it('版本不匹配时先发 error 再以 4400 关闭，并带上双方版本号', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: null });
    const ticket = store.issueTicket(room, 'p0', 'P0');
    const socket = makeSocket();
    hub.handleConnection(socket, room.id, ticket.id);
    socket.emit(
      'message',
      JSON.stringify({ type: 'join', protocol_version: PROTOCOL_VERSION + 1, token: null }),
    );

    expect(socket.lastOfType('error')).toMatchObject({
      code: 'protocol_version_mismatch',
      server_protocol_version: PROTOCOL_VERSION,
      client_protocol_version: PROTOCOL_VERSION + 1,
    });
    expect(socket.closes[0]?.code).toBe(WS_CLOSE_PROTOCOL_MISMATCH);
    expect(room.members).toHaveLength(0);
  });

  it('无效 ticket 以 4401 关闭', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: null });
    const socket = makeSocket();
    hub.handleConnection(socket, room.id, 'not-a-ticket');
    socket.emit(
      'message',
      JSON.stringify({ type: 'join', protocol_version: PROTOCOL_VERSION, token: null }),
    );
    expect(socket.lastOfType('error')).toMatchObject({ code: 'ticket_invalid' });
    expect(socket.closes[0]?.code).toBe(WS_CLOSE_TICKET_INVALID);
  });

  it('首帧不是 join 时拒绝', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: null });
    const ticket = store.issueTicket(room, 'p0', 'P0');
    const socket = makeSocket();
    hub.handleConnection(socket, room.id, ticket.id);
    socket.emit('message', JSON.stringify({ type: 'set_ready', ready: true }));
    expect(socket.lastOfType('error')).toMatchObject({ code: 'handshake_required' });
  });

  it('入座后返回 room_state 与本席位的 session_token', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const socket = connect(room, 'p0', 'Host');
    const state = socket.lastOfType('room_state');
    expect(state?.['you']).toMatchObject({ slot: 0, player_id: 'p0', is_host: true });
    expect(String((state?.['you'] as Record<string, unknown>)['session_token'])).not.toBe('');
    expect(state?.['server']).toMatchObject({
      protocol_version: PROTOCOL_VERSION,
      ping_interval_ms: 5000,
      reconnect_grace_ms: 30000,
      max_members: 4,
    });
  });

  it('ENFORCE_AUTH 打开时无 token 被拒，有效 token 放行', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const strict = makeHub({
      enforceAuth: true,
      sessions: { resolve: (token) => (token === 'good' ? { playerId: 'p0' } : undefined) },
    });

    const anonymous = makeSocket();
    const firstTicket = store.issueTicket(room, 'p0', 'Host');
    strict.handleConnection(anonymous, room.id, firstTicket.id);
    anonymous.emit(
      'message',
      JSON.stringify({ type: 'join', protocol_version: PROTOCOL_VERSION, token: null }),
    );
    expect(anonymous.lastOfType('error')).toMatchObject({ code: 'unauthenticated' });
    expect(anonymous.closes[0]?.code).toBe(WS_CLOSE_TICKET_INVALID);
    expect(room.members).toHaveLength(0);

    const authorized = makeSocket();
    strict.handleConnection(authorized, room.id, firstTicket.id);
    authorized.emit(
      'message',
      JSON.stringify({
        type: 'join',
        protocol_version: PROTOCOL_VERSION,
        token: 'good',
        nickname: 'Host',
      }),
    );
    expect(authorized.lastOfType('room_state')?.['you']).toMatchObject({ player_id: 'p0' });
    strict.stop();
  });

  it('token 身份与 ticket 上的 player_id 不一致时拒绝入座', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const impostorHub = makeHub({
      sessions: { resolve: () => ({ playerId: 'someone-else' }) },
    });
    const ticket = store.issueTicket(room, 'p0', 'Host');
    const socket = makeSocket();
    impostorHub.handleConnection(socket, room.id, ticket.id);
    socket.emit(
      'message',
      JSON.stringify({
        type: 'join',
        protocol_version: PROTOCOL_VERSION,
        token: 'stolen',
        nickname: 'Host',
      }),
    );
    expect(socket.lastOfType('error')).toMatchObject({ code: 'ticket_invalid' });
    expect(room.members).toHaveLength(0);
    impostorHub.stop();
  });
});

describe('广播', () => {
  it('新成员入座时向其他人广播 member_joined', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const host = connect(room, 'p0', 'Host');
    const guest = connect(room, 'p1', 'Guest');
    expect(host.lastOfType('member_joined')).toMatchObject({
      member: { slot: 1, player_id: 'p1', nickname: 'Guest' },
    });
    expect(guest.lastOfType('member_joined')).toBeUndefined();
  });

  it('set_ready 广播 member_updated 给全房', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const host = connect(room, 'p0', 'Host');
    const guest = connect(room, 'p1', 'Guest');
    guest.emit('message', JSON.stringify({ type: 'set_ready', ready: true }));
    expect(host.lastOfType('member_updated')).toMatchObject({ member: { slot: 1, ready: true } });
    expect(guest.lastOfType('member_updated')).toMatchObject({ member: { slot: 1, ready: true } });
  });

  it('非房主 start 收到 not_host', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    connect(room, 'p0', 'Host');
    const guest = connect(room, 'p1', 'Guest');
    guest.emit('message', JSON.stringify({ type: 'start' }));
    expect(guest.lastOfType('error')).toMatchObject({ code: 'not_host' });
  });

  it('房主 start 后倒计时结束广播 match_start', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const host = connect(room, 'p0', 'Host');
    const guest = connect(room, 'p1', 'Guest');
    guest.emit('message', JSON.stringify({ type: 'set_ready', ready: true }));
    host.emit('message', JSON.stringify({ type: 'start' }));
    expect(host.lastOfType('start_countdown')).toMatchObject({ countdown_ms: START_COUNTDOWN_MS });

    advance(START_COUNTDOWN_MS);
    hub.sweepNow();
    for (const socket of [host, guest]) {
      expect(socket.lastOfType('match_start')).toEqual({
        type: 'match_start',
        match: {
          seed: 777,
          tick_rate: 20,
          map_id: 'demo_arena',
          player_slots: [
            { slot: 0, player_id: 'p0', nickname: 'Host' },
            { slot: 1, player_id: 'p1', nickname: 'Guest' },
          ],
        },
      });
    }
  });

  it('ping 立即回 pong 并刷新心跳', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const host = connect(room, 'p0', 'Host');
    advance(PING_TIMEOUT_MS - 1);
    host.emit('message', JSON.stringify({ type: 'ping', client_time_ms: 99 }));
    expect(host.lastOfType('pong')).toMatchObject({ client_time_ms: 99 });
    advance(2);
    hub.sweepNow();
    expect(store.getRoom(room.id)?.members).toHaveLength(1);
  });

  it('lobby 心跳超时广播 member_left 并关闭该连接', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const host = connect(room, 'p0', 'Host');
    const guest = connect(room, 'p1', 'Guest');
    advance(PING_TIMEOUT_MS + 1);
    host.emit('message', JSON.stringify({ type: 'ping', client_time_ms: 1 }));
    hub.sweepNow();
    expect(host.lastOfType('member_left')).toMatchObject({ slot: 1, reason: 'timeout' });
    expect(guest.closes.length).toBeGreaterThan(0);
  });

  it('socket 关闭后同一 session_token 可重连回原 slot', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const host = connect(room, 'p0', 'Host');
    const guest = connect(room, 'p1', 'Guest');
    const guestToken = String(
      (guest.lastOfType('room_state')?.['you'] as Record<string, unknown>)['session_token'],
    );
    guest.emit('message', JSON.stringify({ type: 'set_ready', ready: true }));
    host.emit('message', JSON.stringify({ type: 'start' }));
    advance(START_COUNTDOWN_MS);
    hub.sweepNow();

    guest.emit('close');
    expect(store.getRoom(room.id)?.members).toHaveLength(2);

    const revived = makeSocket();
    hub.handleConnection(revived, room.id, '');
    revived.emit(
      'message',
      JSON.stringify({
        type: 'join',
        protocol_version: PROTOCOL_VERSION,
        token: 'bearer',
        session_token: guestToken,
        nickname: 'Guest',
      }),
    );
    expect(revived.lastOfType('room_state')?.['you']).toMatchObject({ slot: 1, player_id: 'p1' });
  });

  it('倒计时被打断时广播 canceled 的 start_countdown', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const host = connect(room, 'p0', 'Host');
    const guest = connect(room, 'p1', 'Guest');
    guest.emit('message', JSON.stringify({ type: 'set_ready', ready: true }));
    host.emit('message', JSON.stringify({ type: 'start' }));
    expect(host.lastOfType('start_countdown')).toMatchObject({ canceled: false });

    // 客人心跳超时 → starting 回退到 lobby。
    advance(PING_TIMEOUT_MS + 1);
    host.emit('message', JSON.stringify({ type: 'ping', client_time_ms: 1 }));
    hub.sweepNow();
    expect(host.lastOfType('start_countdown')).toMatchObject({
      countdown_ms: null,
      starts_at_ms: null,
      canceled: true,
    });
    expect(store.getRoom(room.id)?.state).toBe('lobby');
  });
});

describe('结算与收尾', () => {
  it('房主 end_match 把对局标记为 host_ended，非房主被拒', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const host = connect(room, 'p0', 'Host');
    const guest = connect(room, 'p1', 'Guest');
    guest.emit('message', JSON.stringify({ type: 'set_ready', ready: true }));
    host.emit('message', JSON.stringify({ type: 'start' }));
    advance(START_COUNTDOWN_MS);
    hub.sweepNow();

    guest.emit('message', JSON.stringify({ type: 'end_match' }));
    expect(guest.lastOfType('error')).toMatchObject({ code: 'not_host' });
    expect(store.getRoom(room.id)?.state).toBe('playing');

    host.emit('message', JSON.stringify({ type: 'end_match' }));
    expect(store.getRoom(room.id)?.state).toBe('ended');
    expect(store.getRoom(room.id)?.endReason).toBe('host_ended');
  });

  it('有人在结算瞬间掉线时不会卡在 playing，兜底窗口到期后照常收尾', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const host = connect(room, 'p0', 'Host');
    const guest = connect(room, 'p1', 'Guest');
    guest.emit('message', JSON.stringify({ type: 'set_ready', ready: true }));
    host.emit('message', JSON.stringify({ type: 'start' }));
    advance(START_COUNTDOWN_MS);
    hub.sweepNow();

    // 客人掉线但仍在 30 秒重连宽限内：它永远不会发 match_result。
    guest.emit('close');
    host.emit(
      'message',
      JSON.stringify({ type: 'match_result', player_kills: { '0': 12 }, team_wave: 7 }),
    );
    // 期望数只算在线席位，因此这一份就已经收齐，立刻收尾。
    expect(store.getRoom(room.id)?.state).toBe('ended');
  });

  it('两人都在线时只到一份上报会等兜底窗口，到期后仍然收尾', () => {
    const room = store.createRoom({ name: 'r', visibility: 'public', hostPlayerId: 'p0' });
    const host = connect(room, 'p0', 'Host');
    const guest = connect(room, 'p1', 'Guest');
    guest.emit('message', JSON.stringify({ type: 'set_ready', ready: true }));
    host.emit('message', JSON.stringify({ type: 'start' }));
    advance(START_COUNTDOWN_MS);
    hub.sweepNow();

    host.emit(
      'message',
      JSON.stringify({ type: 'match_result', player_kills: { '0': 12, '1': 5 }, team_wave: 7 }),
    );
    expect(store.getRoom(room.id)?.state).toBe('playing');

    advance(MATCH_RESULT_COLLECT_MS + 1);
    hub.sweepNow();
    expect(store.getRoom(room.id)?.state).toBe('ended');
    expect(store.getRoom(room.id)?.endReason).toBe('wiped');
  });
});
```

- [ ] **Step 7: 运行 hub 测试与类型检查**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
npx vitest run test/room_hub.test.ts
npx tsc -p tsconfig.json --noEmit
rg -n "room\.state = |room\.members\.push|member\.ready = " src/lib/room_hub.ts
rg -n "recordMatchResults|from 'better-sqlite3'" src/lib/room_hub.ts
```

Expected: `Test Files 1 passed`、`Tests 17 passed`（握手 6 + 广播 8 + 结算与收尾 3）；`tsc` 无输出；第一条 `rg` 无任何匹配（退出码 1）——hub 不得绕过 `RoomStore` 直接改房间字段；第二条 `rg` 同样 0 命中——写榜函数叫 `submitMatchResult`，句柄类型走 S1 的 `Db`。

- [ ] **Step 8: 提交 room_hub**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
git add src/lib/room_hub.ts test/room_hub.test.ts package.json package-lock.json
git commit -m "feat: add websocket room hub"
```

Expected: 提交包含 hub、其测试与依赖清单变更（`package.json` 的差异只应出现在 `devDependencies` 的 `@types/ws` 一行），不含 `node_modules/`。

---

### Task 6: HTTP 与 WebSocket 路由并装配进 app

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/routes/rooms.ts`
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/app.ts`（S1 产出的 `buildApp()`：import 段、`BuildAppOptions` / `ZombiewarApp`、路由注册段、`onClose` 钩子）
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/docs/superpowers/specs/2026-08-07-online-multiplayer-server-design.md`（ticket 校验时机那一行）
- Test: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/test/rooms.api.test.ts`

**Interfaces:**
- Consumes:
  - Task 2：`RoomStore`、`RoomError`、`normalizeNickname`（经 `rooms.ts` 再导出）、`MAX_MEMBERS`、`PING_INTERVAL_MS`、`ROOM_LIST_MAX_LIMIT`、`NICKNAME_MAX_LENGTH`、`type RoomVisibility`。
  - Task 4：`PROTOCOL_VERSION`。
  - Task 5：`RoomHub`、`type HubSocket`。
  - S1 `src/app.ts`：`interface BuildAppOptions { config: Config; db: Db; sessions?: SessionStore }`（**`db` 是必填入参**，`openDatabase()` 在 `src/server.ts` 里调用，不在 `buildApp()` 里）、`interface ZombiewarApp { app: FastifyInstance; db: Db; sessions: SessionStore; config: Config }`、`buildApp(options: BuildAppOptions): Promise<ZombiewarApp>`、`request.playerSession: PlayerSession | null`（由 S1 的 `onRequest` 钩子挂上）、**S1 已完成的 `await app.register(websocket)`**。
  - S1 `src/config.ts`：`Config`（读 `enforceAuth`），本任务不新增字段。
  - S1 `src/lib/types.ts`：`CURRENT_SEASON = 0`（传给 `RoomHub`，不要就地写字面量 `0`）。
- Produces:
  - `interface RoomRoutesOptions extends FastifyPluginOptions { store: RoomStore; hub: RoomHub }`
  - `roomRoutes(app: FastifyInstance, options: RoomRoutesOptions): Promise<void>`
  - S1 的 `ZombiewarApp` 接口新增两个字段：`rooms: RoomStore`、`roomHub: RoomHub`（**在原接口上追加两行，不新写一个接口**）
  - `BuildAppOptions` 新增两个可选注入字段：`rooms?: RoomStore`、`roomHub?: RoomHub`

- [ ] **Step 1: 登记 spec 偏离并查看 S1 的 app.ts 装配段**

spec 第 546 行写「ticket 无效或过期 → 拒绝 WebSocket 升级」。本计划把 ticket 兑换推迟到首帧 `join`，
因为断线重连路径不带 ticket、只带 `session_token`，在升级阶段就要 ticket 会让重连 100% 失败。
这是对 spec 的行为改写，必须先登记再实现。

把 `docs/superpowers/specs/2026-08-07-online-multiplayer-server-design.md` 第 546 行：

```markdown
| ticket 无效或过期 | 拒绝 WebSocket 升级，客户端退回大厅 |
```

改为：

```markdown
| ticket 无效或过期 | 升级成功后先发 `error(ticket_invalid \| ticket_expired)` 再以 close code 4401 关闭，客户端退回大厅；升级阶段只校验房间是否存在（不存在返回 404）。ticket 校验推迟到首帧 `join`，因为重连路径不带 ticket，只带 `session_token` |
```

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add docs/superpowers/specs/2026-08-07-online-multiplayer-server-design.md
git commit -m "docs: move ticket validation to the first join frame"
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
rg -n "app.register\(|export interface BuildAppOptions|export interface ZombiewarApp|return \{ app" src/app.ts
```

Expected: spec 提交成功；`rg` 打印出 `BuildAppOptions` 与 `ZombiewarApp` 的声明行、若干 `await app.register(...)` 行（**其中必须已经有一行 `await app.register(websocket)`**）与 `return { app, ... }` 行。记下最后一个 `await app.register(` 的行号，Step 4 在它之后插入。

- [ ] **Step 2: 写入路由文件**

创建 `src/routes/rooms.ts`：

```ts
import type { FastifyInstance, FastifyPluginOptions, FastifyRequest } from 'fastify';

import { PROTOCOL_VERSION } from '../lib/protocol/version.js';
import type { HubSocket, RoomHub } from '../lib/room_hub.js';
import {
  MAX_MEMBERS,
  NICKNAME_MAX_LENGTH,
  PING_INTERVAL_MS,
  ROOM_LIST_MAX_LIMIT,
  RoomError,
  RoomStore,
  normalizeNickname,
  type Room,
  type RoomVisibility,
} from '../lib/rooms.js';

export interface RoomRoutesOptions extends FastifyPluginOptions {
  store: RoomStore;
  hub: RoomHub;
}

function readBody(request: FastifyRequest): Record<string, unknown> {
  const raw = request.body;
  if (raw === undefined || raw === null) return {};
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    throw new RoomError('invalid_body', 400, 'request body must be a JSON object');
  }
  return raw as Record<string, unknown>;
}

function optionalString(
  body: Record<string, unknown>,
  key: string,
  maxLength: number,
): string | undefined {
  const value = body[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'string') {
    throw new RoomError('invalid_body', 400, `${key} must be a string`);
  }
  const trimmed = value.trim();
  if (trimmed === '') return undefined;
  if (trimmed.length > maxLength) {
    throw new RoomError('invalid_body', 400, `${key} must be at most ${maxLength} characters`);
  }
  return trimmed;
}

function readVisibility(body: Record<string, unknown>): RoomVisibility {
  const value = body['visibility'];
  if (value === undefined || value === null) return 'public';
  if (value !== 'public' && value !== 'code_only') {
    throw new RoomError('invalid_body', 400, 'visibility must be "public" or "code_only"');
  }
  return value;
}

function readInt(
  query: Record<string, unknown>,
  key: string,
  fallback: number,
  min: number,
  max: number,
): number {
  const raw = query[key];
  if (raw === undefined || raw === null || raw === '') return fallback;
  const text = Array.isArray(raw) ? String(raw[raw.length - 1]) : String(raw);
  if (!/^\d+$/.test(text)) {
    throw new RoomError('invalid_query', 400, `${key} must be a non-negative integer`);
  }
  const value = Number.parseInt(text, 10);
  if (value < min || value > max) {
    throw new RoomError('invalid_query', 400, `${key} must be between ${min} and ${max}`);
  }
  return value;
}

/**
 * ENFORCE_AUTH 默认关闭，所以这里不能要求 bearer token 存在。
 * 有 token 就用 S1 解析出来的身份，没有就退回请求体里的 player_id，
 * 再没有才现场发一个 guest id —— 三条路径都会得到一个稳定的 slot 归属。
 */
function resolvePlayerId(request: FastifyRequest, body: Record<string, unknown>): string {
  const session = request.playerSession;
  if (session !== null && session !== undefined) return session.playerId;
  const fromBody = optionalString(body, 'player_id', 64);
  if (fromBody !== undefined) return fromBody;
  return `guest-${Math.random().toString(36).slice(2, 10)}`;
}

function resolveNickname(request: FastifyRequest, body: Record<string, unknown>): string {
  const explicit = optionalString(body, 'nickname', NICKNAME_MAX_LENGTH);
  if (explicit !== undefined) return normalizeNickname(explicit);
  const session = request.playerSession;
  if (session !== null && session !== undefined) return normalizeNickname(session.nickname);
  return 'Player';
}

function joinEnvelope(room: Room, ticketId: string, ticketTtlMs: number): Record<string, unknown> {
  return {
    room_id: room.id,
    room_code: room.code,
    ws_path: `/api/rooms/${room.id}/ws?ticket=${encodeURIComponent(ticketId)}`,
    ticket: ticketId,
    ticket_expires_in_ms: ticketTtlMs,
    protocol_version: PROTOCOL_VERSION,
    max_members: MAX_MEMBERS,
    ping_interval_ms: PING_INTERVAL_MS,
  };
}

export async function roomRoutes(
  app: FastifyInstance,
  options: RoomRoutesOptions,
): Promise<void> {
  const { store, hub } = options;

  app.post('/api/rooms', async (request, reply) => {
    const body = readBody(request);
    const room = store.createRoom({
      name: optionalString(body, 'name', 32) ?? '房间',
      visibility: readVisibility(body),
      hostPlayerId: resolvePlayerId(request, body),
    });
    const ticket = store.issueTicket(
      room,
      room.hostPlayerId ?? resolvePlayerId(request, body),
      resolveNickname(request, body),
    );
    return reply
      .code(201)
      .send(joinEnvelope(room, ticket.id, ticket.expiresAt - ticket.issuedAt));
  });

  app.get('/api/rooms', async (request) => {
    // 列表请求同时充当心跳清理的驱动：没人开局时也不会留下死房。
    hub.sweepNow();
    const query = request.query as Record<string, unknown>;
    const offset = readInt(query, 'offset', 0, 0, 10_000);
    const limit = readInt(query, 'limit', 20, 1, ROOM_LIST_MAX_LIMIT);
    const page = store.listPublicRooms(offset, limit);
    return {
      total: page.total,
      offset,
      limit,
      items: page.items.map((room) => store.toPublic(room)),
    };
  });

  app.post('/api/rooms/:code/join', async (request) => {
    const { code } = request.params as { code: string };
    const body = readBody(request);
    const room = store.requireRoomByCode(code);
    const ticket = store.issueTicket(
      room,
      resolvePlayerId(request, body),
      resolveNickname(request, body),
    );
    return joinEnvelope(room, ticket.id, ticket.expiresAt - ticket.issuedAt);
  });

  app.get(
    '/api/rooms/:room_id/ws',
    {
      websocket: true,
      // ticket 的兑换推迟到首帧 join：断线重连会走 session_token 而不带 ticket。
      // 房间不存在则连升级都不给，避免客户端拿着死房间 id 反复重连。
      preValidation: async (request) => {
        const { room_id: roomId } = request.params as { room_id: string };
        store.requireRoom(roomId);
      },
    },
    (socket: HubSocket, request: FastifyRequest) => {
      const { room_id: roomId } = request.params as { room_id: string };
      const query = request.query as Record<string, unknown>;
      const rawTicket = query['ticket'];
      const ticketId = typeof rawTicket === 'string' ? rawTicket : '';
      hub.handleConnection(socket, roomId, ticketId);
    },
  );
}
```

- [ ] **Step 3: 把 RoomError 接进 app.ts 的错误处理**

在 `src/app.ts` 的 import 段追加：

```ts
import { RoomHub } from './lib/room_hub.js';
import { RoomError, RoomStore } from './lib/rooms.js';
import { CURRENT_SEASON } from './lib/types.js';
import { roomRoutes } from './routes/rooms.js';
```

若 S1 的 `app.ts` 已经 import 过 `CURRENT_SEASON`，不要重复 import，合并到已有那一行即可。

**不要在这里 import 或注册 `@fastify/websocket`**：S1 的 `buildApp()` 已经 `await app.register(websocket)`，
而该插件用 `fastify-plugin` 封装，同一 scope 重复注册会以 `FST_ERR_DEC_ALREADY_PRESENT` 一类错误
让 `buildApp()` 直接失败，整个服务端与本任务的集成测试都起不来。

在 `app.setErrorHandler(...)` 回调内、`HttpError` 分支之后插入 `RoomError` 分支：

```ts
    if (error instanceof RoomError) {
      return reply
        .code(error.statusCode)
        .send({ error: { code: error.code, message: error.message } });
    }
```

若 S1 的 `setErrorHandler` 里没有 `HttpError` 分支，就把上面这段放在该回调的第一条语句。

- [ ] **Step 4: 在 buildApp 中构造并注册房间层**

在 `BuildAppOptions` 接口中追加两个可选注入字段：

```ts
  rooms?: RoomStore;
  roomHub?: RoomHub;
```

在 `buildApp()` 内、创建 `app` 实例之前构造 store：

```ts
  const rooms = options.rooms ?? new RoomStore();
```

在最后一个 `await app.register(...)`（S1 的 `await app.register(websocket)` 之后的那一个）之后追加：

```ts
  const roomHub =
    options.roomHub ??
    new RoomHub({
      store: rooms,
      log: app.log,
      sessions,
      enforceAuth: config.enforceAuth,
      db: options.db,
      season: CURRENT_SEASON,
    });
  roomHub.start();
  app.addHook('onClose', async () => {
    roomHub.stop();
  });
  await app.register(roomRoutes, { store: rooms, hub: roomHub });
```

`db` 来自 **`options.db`**：S1 的 `BuildAppOptions` 已经把它列为**必填入参**，`openDatabase()` 在
`src/server.ts` 里调用。本任务不新增任何打开数据库的代码，也不要去找一个「`buildApp()` 里已打开的句柄」——
那个句柄不存在。`sessions` 与 `config` 都是 S1 在 `buildApp()` 内已有的局部标识符；
`CURRENT_SEASON` 来自 S1 的 `src/lib/types.js`（值为 `0`），从那里 import 而不是就地写 `0`。

把返回语句改为在 S1 原有字段之上追加房间层：

```ts
  return { app, db: options.db, sessions, config, rooms, roomHub };
```

**`config` 一定要留着**——S1 的 `ZombiewarApp` 接口、`src/server.ts` 与 S1 的 `test/helpers.ts`
都依赖它，漏掉它 `tsc --noEmit`（Step 6）会直接报缺少属性。

并在 **S1 已有的 `ZombiewarApp` 接口里追加两行**（不要新写一个接口）：

```ts
  rooms: RoomStore;
  roomHub: RoomHub;
```

- [ ] **Step 5: 写入路由集成测试**

创建 `test/rooms.api.test.ts`：

```ts
import { once } from 'node:events';
import type { AddressInfo } from 'node:net';

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import websocket from '@fastify/websocket';
import WebSocket from 'ws';

import { encodeServerMessage } from '../src/lib/protocol/lobby.js';
import { PROTOCOL_VERSION } from '../src/lib/protocol/version.js';
import { RoomHub } from '../src/lib/room_hub.js';
import { RoomError, RoomStore } from '../src/lib/rooms.js';
import { roomRoutes } from '../src/routes/rooms.js';

/**
 * 这里刻意只装配房间层，不走 buildApp：路由的成功与失败路径不应该被
 * S1 的 CORS / rate limit / 身份钩子干扰。
 *
 * 但 `@fastify/websocket` **必须注册**：没有它，路由选项里的 `{ websocket: true }`
 * 只是一个无意义的普通属性，Fastify 会把 `(socket, request)` 处理器当成标准的
 * `(request, reply)` 绑定。只测 404 那条路径恰好绕开这个错绑，于是 ws_path 拼接、
 * `?ticket=` 解析、`hub.handleConnection()` 的实际接线就完全没有自动化覆盖了。
 */

let clock = 1_700_000_000_000;
let app: FastifyInstance;
let store: RoomStore;
let hub: RoomHub;

const silentLog = {
  info: () => undefined,
  warn: () => undefined,
  error: () => undefined,
};

beforeEach(async () => {
  clock = 1_700_000_000_000;
  let roomSequence = 0;
  let tokenSequence = 0;
  store = new RoomStore({
    now: () => clock,
    newRoomId: () => `room-${(roomSequence += 1)}`,
    newToken: () => `tok-${(tokenSequence += 1)}`,
    newSeed: () => 777,
  });
  hub = new RoomHub({
    store,
    log: silentLog,
    sessions: { resolve: () => undefined },
    enforceAuth: false,
    db: null,
    now: () => clock,
  });
  app = Fastify({ logger: false });
  app.decorateRequest('playerSession', null);
  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof RoomError) {
      return reply
        .code(error.statusCode)
        .send({ error: { code: error.code, message: error.message } });
    }
    return reply.code(500).send({ error: { code: 'internal_error', message: 'boom' } });
  });
  await app.register(websocket);
  await app.register(roomRoutes, { store, hub });
  await app.ready();
});

afterEach(async () => {
  hub.stop();
  await app.close();
});

function advance(ms: number): void {
  clock += ms;
}

async function createRoom(payload: Record<string, unknown> = {}) {
  const response = await app.inject({ method: 'POST', url: '/api/rooms', payload });
  expect(response.statusCode).toBe(201);
  return response.json<{
    room_id: string;
    room_code: string;
    ws_path: string;
    ticket: string;
    protocol_version: number;
    max_members: number;
    ping_interval_ms: number;
  }>();
}

describe('POST /api/rooms', () => {
  it('返回房间码、房间 id 与带 ticket 的 ws_path', async () => {
    const body = await createRoom({ name: '测试房', nickname: 'Bo' });
    expect(body.room_code).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/);
    expect(body.room_id).toBe('room-1');
    expect(body.ws_path).toBe(`/api/rooms/room-1/ws?ticket=${encodeURIComponent(body.ticket)}`);
    expect(body.protocol_version).toBe(PROTOCOL_VERSION);
    expect(body.max_members).toBe(4);
    expect(body.ping_interval_ms).toBe(5000);
  });

  it('拒绝非法 visibility 与超长昵称', async () => {
    const badVisibility = await app.inject({
      method: 'POST',
      url: '/api/rooms',
      payload: { visibility: 'secret' },
    });
    expect(badVisibility.statusCode).toBe(400);
    expect(badVisibility.json().error.code).toBe('invalid_body');

    const badNickname = await app.inject({
      method: 'POST',
      url: '/api/rooms',
      payload: { nickname: '0123456789abc' },
    });
    expect(badNickname.statusCode).toBe(400);
    expect(badNickname.json().error.code).toBe('invalid_nickname');
  });
});

describe('GET /api/rooms', () => {
  it('只列公开房，按新到旧排序并支持分页', async () => {
    const first = await createRoom({ name: 'a' });
    advance(10);
    const second = await createRoom({ name: 'b' });
    advance(10);
    await createRoom({ name: 'c', visibility: 'code_only' });

    const all = await app.inject({ url: '/api/rooms' });
    expect(all.statusCode).toBe(200);
    expect(all.json().total).toBe(2);
    expect(all.json().items.map((room: { room_id: string }) => room.room_id)).toEqual([
      second.room_id,
      first.room_id,
    ]);

    const paged = await app.inject({ url: '/api/rooms?offset=1&limit=1' });
    expect(paged.json().items.map((room: { room_id: string }) => room.room_id)).toEqual([
      first.room_id,
    ]);
  });

  it('列表请求会清掉从没人连进来的死房', async () => {
    await createRoom({ name: 'ghost' });
    advance(30_001);
    const response = await app.inject({ url: '/api/rooms' });
    expect(response.json().total).toBe(0);
    expect(store.size).toBe(0);
  });

  it('拒绝非法的 offset / limit', async () => {
    expect((await app.inject({ url: '/api/rooms?offset=-1' })).statusCode).toBe(400);
    expect((await app.inject({ url: '/api/rooms?limit=0' })).statusCode).toBe(400);
    expect((await app.inject({ url: '/api/rooms?limit=999' })).statusCode).toBe(400);
  });
});

describe('POST /api/rooms/:code/join', () => {
  it('返回一次性 ticket，且两次请求的 ticket 不同', async () => {
    const created = await createRoom();
    const first = await app.inject({
      method: 'POST',
      url: `/api/rooms/${created.room_code}/join`,
      payload: { nickname: 'P2' },
    });
    expect(first.statusCode).toBe(200);
    expect(first.json().room_id).toBe(created.room_id);
    expect(first.json().ticket).not.toBe(created.ticket);

    const second = await app.inject({
      method: 'POST',
      url: `/api/rooms/${created.room_code}/join`,
      payload: { nickname: 'P3' },
    });
    expect(second.json().ticket).not.toBe(first.json().ticket);
  });

  it('房间码大小写不敏感', async () => {
    const created = await createRoom();
    const response = await app.inject({
      method: 'POST',
      url: `/api/rooms/${created.room_code.toLowerCase()}/join`,
    });
    expect(response.statusCode).toBe(200);
  });

  it('非法房间码 400、未知房间码 404', async () => {
    expect(
      (await app.inject({ method: 'POST', url: '/api/rooms/AB0DEF/join' })).statusCode,
    ).toBe(400);
    const unknown = await app.inject({ method: 'POST', url: '/api/rooms/ABCDEF/join' });
    expect(unknown.statusCode).toBe(404);
    expect(unknown.json().error.code).toBe('room_not_found');
  });

  it('房间满员时 409', async () => {
    const created = await createRoom();
    for (let index = 0; index < 3; index += 1) {
      const response = await app.inject({
        method: 'POST',
        url: `/api/rooms/${created.room_code}/join`,
      });
      expect(response.statusCode).toBe(200);
    }
    const overflow = await app.inject({
      method: 'POST',
      url: `/api/rooms/${created.room_code}/join`,
    });
    expect(overflow.statusCode).toBe(409);
    expect(overflow.json().error.code).toBe('room_full');
  });

  it('已开局的房间拒绝加入（不支持热加入）', async () => {
    const created = await createRoom();
    const room = store.requireRoom(created.room_id);
    const claim = store.redeemTicket(created.ticket, room.id);
    const seated = store.joinRoom(room.id, claim);
    store.requestStart(room.id, seated.member.slot);
    advance(3_000);
    store.sweep();

    const response = await app.inject({
      method: 'POST',
      url: `/api/rooms/${created.room_code}/join`,
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe('room_in_progress');
  });
});

describe('WS /api/rooms/:room_id/ws', () => {
  it('房间不存在时连升级都不给', async () => {
    const response = await app.inject({
      url: '/api/rooms/room-does-not-exist/ws?ticket=x',
      headers: {
        connection: 'upgrade',
        upgrade: 'websocket',
        'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==',
        'sec-websocket-version': '13',
      },
    });
    expect(response.statusCode).toBe(404);
    expect(response.json().error.code).toBe('room_not_found');
  });

  /**
   * 真升级一次。这条用例覆盖的是 app.inject 覆盖不到的三段接线：
   * joinEnvelope 拼出来的 ws_path 能不能直接连、`?ticket=` 能不能被解析出来、
   * `(socket, request)` 处理器有没有被正确绑定到 hub.handleConnection()。
   */
  it('按建房返回的 ws_path 直连后，首帧 join 拿到 slot 0 的 room_state', async () => {
    const created = await createRoom({ name: 'ws 房', nickname: 'Bo' });
    await app.listen({ port: 0, host: '127.0.0.1' });
    const { port } = app.server.address() as AddressInfo;

    const socket = new WebSocket(`ws://127.0.0.1:${port}${created.ws_path}`);
    await once(socket, 'open');
    const firstFrame = once(socket, 'message');
    socket.send(
      encodeServerMessage({
        type: 'join',
        protocol_version: PROTOCOL_VERSION,
        token: null,
        session_token: null,
        nickname: 'Bo',
      } as never),
    );
    const [raw] = await firstFrame;
    const message = JSON.parse(String(raw)) as Record<string, unknown>;

    expect(message['type']).toBe('room_state');
    expect(message['you']).toMatchObject({ slot: 0 });
    expect(message['server']).toMatchObject({ protocol_version: PROTOCOL_VERSION });

    socket.close();
    await once(socket, 'close');
  });
});
```

`encodeServerMessage()` 在这里只是「把扁平帧转成 JSON 文本」的同一个函数，
用它而不是 `JSON.stringify` 是为了让这条用例也跟着协议模块一起漂移或一起失败。

- [ ] **Step 6: 跑全量服务端测试与构建**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
npm test
npx tsc -p tsconfig.json --noEmit
```

Expected: `Test Files 5 passed`（`room_code` / `rooms` / `lobby_protocol` / `room_hub` / `rooms.api`），无 failed；`rooms.api.test.ts` 报 `Tests 12 passed`（建房 2 + 列表 3 + 输码加入 5 + WS 2）；`tsc` 无输出且退出码为 0。若跑到 WS 用例时挂住，先确认 `afterEach` 里的 `await app.close()` 会连带关掉 `app.listen()` 起的服务器——`hub.stop()` 也在同一个钩子里，它会把残留连接以 4500 关掉。

- [ ] **Step 7: 记录局域网联通方式到服务端 README**

在 `README.md` 末尾追加一节（若 S1 已写过同名小节，覆盖其内容）：

```markdown
## 局域网联通

- Fastify 监听 `0.0.0.0:8787`。
- 主路径是**全 http 局域网直连**：页面 `http://<开发机 LAN IP>:<port>/index.html`，
  WebSocket `ws://<开发机 LAN IP>:8787`。开发机 LAN IP 由 DHCP 分配、会变化，
  客户端 base URL 必须走 `user://net.cfg` 覆盖，不得硬编码。
- Web 导出 `variant/thread_support=false`，不需要 `SharedArrayBuffer`，
  因此 `http://<LAN-IP>` 这一非安全上下文不影响游戏运行。
- 备选方案（仅在必须保留 `https://zombiewar.devlocal.com` 流程时启用）：
  新增一个 nginx 443 vhost 反代到 `127.0.0.1:8787` 并改用 `wss://`。
  证书复用 `/opt/homebrew/etc/nginx/ssl2.conf`；WebSocket 代理头参考
  现有 `vhost/bk/bk.conf`（`proxy_http_version 1.1`、`Upgrade`、`Connection "Upgrade"`）。
  HTTPS 页面连接 `ws://` 会被浏览器按混合内容拒绝，两者不能混用。
```

- [ ] **Step 8: 提交路由与装配**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server
git add src/routes/rooms.ts src/app.ts test/rooms.api.test.ts README.md
git commit -m "feat: serve rooms over http and websocket"
```

Expected: 提交包含路由、`app.ts` 装配、集成测试与 README 变更；至此服务端 S2 完成。

---

### Task 7: 客户端协议常量与 JSON 编解码

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/lobby_protocol.gd`

**Interfaces:**
- Consumes: 服务端 Task 4 的 `PROTOCOL_VERSION = 1`、opcode 号段、`CLIENT_MESSAGE_TYPES`、`SERVER_MESSAGE_TYPES` 与消息字段名（本文件是它们在 GDScript 侧的镜像）；S1 的 `scripts/net/net_config.gd`（本任务不导入，仅说明 base URL 来源）。
- Produces:
  - 常量：`PROTOCOL_VERSION := 1`、`OPCODE_LOBBY_MIN/MAX`、`OPCODE_SYNC_MIN/MAX`、`OPCODE_LOBBY_JSON/PING/PONG`、`MAX_MEMBERS := 4`、`PING_INTERVAL_SECONDS := 5.0`、`PING_TIMEOUT_SECONDS := 15.0`、`RECONNECT_GRACE_SECONDS := 30.0`、`DEFAULT_TICK_RATE := 20`、`DEFAULT_MAP_ID`、`ROOM_CODE_ALPHABET`、`ROOM_CODE_LENGTH := 6`、`CLIENT_MESSAGE_TYPES`、`SERVER_MESSAGE_TYPES`、`C2S_*` 与 `S2C_*` 字符串常量、`CLOSE_*`、`FIXTURES_DIR`。
  - 静态函数：`is_lobby_opcode(opcode: int) -> bool`、`is_sync_opcode(opcode: int) -> bool`、`normalize_room_code(value: String) -> String`、`is_room_code(value: String) -> bool`、`encode(message: Dictionary) -> String`、`decode(text: String) -> Dictionary`、`make_join(token: String, session_token: String, nickname: String) -> Dictionary`、`make_set_ready(ready: bool) -> Dictionary`、`make_set_nickname(nickname: String) -> Dictionary`、`make_start() -> Dictionary`、`make_end_match() -> Dictionary`、`make_leave() -> Dictionary`、`make_ping(client_time_ms: int) -> Dictionary`、`make_match_result(player_kills: Dictionary, team_wave: int) -> Dictionary`。

**这是客户端唯一的协议镜像文件。** S1 修订版已删除 `scripts/net/protocol_codec.gd` 与
`tools/validation/validate_protocol_codec.gd`——同一个 `PROTOCOL_VERSION` 与同一套 opcode 判定
在客户端存两份，将来递增版本必然漏改一个。

- [ ] **Step 1: 确认 S1 的客户端网络层已按修订版落地**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
ls scripts/net/net_config.gd scripts/net/identity_store.gd scripts/net/api_client.gd
rg -n "func get_http_base_url|func get_ws_base_url|func request_json|func get_token|func get_player_id|func get_nickname|func get_device_id" scripts/net
rg -n "func request_json\(method: String" scripts/net/api_client.gd
rg -n "func _init\(host" scripts/net/api_client.gd
test ! -e scripts/net/protocol_codec.gd && echo "no legacy protocol_codec.gd (expected)"
ls tools/validation/fixtures/protocol/lobby_room_state.json
git log --oneline -1
```

Expected:
- 三个脚本存在；第一条 `rg` 命中 `get_http_base_url`、`get_ws_base_url`、`request_json`、`get_token`、`get_player_id`、`get_nickname` 六个函数定义。
- 第二条 `rg` 命中 `func request_json(method: String, path: String, body: Variant = null, on_result: Callable = Callable(), authenticate: bool = true) -> void`；第三条命中 `func _init(host: Node = null) -> void`。
- 打印 `no legacy protocol_codec.gd (expected)`；Task 4 复制过来的大厅 fixtures 存在。

**这些是硬门槛，不是「记下真实名字再照着改」。** 这里的每一个名字都在跨计划对齐里被钉死过一次；
对不上就说明 S1 没按修订版执行，回去补齐再回到本任务——把接口决策留给执行期正是对齐要消除的东西。

- [ ] **Step 2: 写入协议镜像**

创建 `scripts/net/lobby_protocol.gd`（缩进使用制表符）：

```gdscript
extends RefCounted
class_name LobbyProtocol

# 与 zombiewar-server/protocol/PROTOCOL.md 及
# zombiewar-server/src/lib/protocol/version.ts 的 PROTOCOL_VERSION 必须逐字相同。
# 任何字段增删都要两边同时递增，否则握手会以 close code 4400 响亮失败。
const PROTOCOL_VERSION := 1

# 二进制号段：0x00-0x7F 大厅与控制，0x80-0xFF 整段预留给 S3 同步层。
# 本轮大厅消息全部走 JSON 文本帧，这些号只是把号段钉死，避免 S3 上线时撞号。
const OPCODE_LOBBY_MIN := 0x00
const OPCODE_LOBBY_MAX := 0x7F
const OPCODE_SYNC_MIN := 0x80
const OPCODE_SYNC_MAX := 0xFF
const OPCODE_LOBBY_JSON := 0x01
const OPCODE_LOBBY_PING := 0x02
const OPCODE_LOBBY_PONG := 0x03

const MAX_MEMBERS := 4
const PING_INTERVAL_SECONDS := 5.0
const PING_TIMEOUT_SECONDS := 15.0
const RECONNECT_GRACE_SECONDS := 30.0
const DEFAULT_TICK_RATE := 20
const DEFAULT_MAP_ID := "demo_arena"
const ROOM_CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const ROOM_CODE_LENGTH := 6

const C2S_JOIN := "join"
const C2S_SET_READY := "set_ready"
const C2S_SET_NICKNAME := "set_nickname"
const C2S_START := "start"
const C2S_END_MATCH := "end_match"
const C2S_LEAVE := "leave"
const C2S_PING := "ping"
const C2S_MATCH_RESULT := "match_result"

const S2C_ROOM_STATE := "room_state"
const S2C_MEMBER_JOINED := "member_joined"
const S2C_MEMBER_LEFT := "member_left"
const S2C_MEMBER_UPDATED := "member_updated"
const S2C_START_COUNTDOWN := "start_countdown"
const S2C_MATCH_START := "match_start"
const S2C_ERROR := "error"
const S2C_PONG := "pong"

# 顺序与服务端 src/lib/protocol/lobby.ts 的 CLIENT_MESSAGE_TYPES 逐字相同。
const CLIENT_MESSAGE_TYPES := [
	C2S_JOIN,
	C2S_SET_READY,
	C2S_SET_NICKNAME,
	C2S_START,
	C2S_END_MATCH,
	C2S_LEAVE,
	C2S_PING,
	C2S_MATCH_RESULT,
]

const SERVER_MESSAGE_TYPES := [
	S2C_ROOM_STATE,
	S2C_MEMBER_JOINED,
	S2C_MEMBER_LEFT,
	S2C_MEMBER_UPDATED,
	S2C_START_COUNTDOWN,
	S2C_MATCH_START,
	S2C_ERROR,
	S2C_PONG,
]

const CLOSE_PROTOCOL_MISMATCH := 4400
const CLOSE_TICKET_INVALID := 4401
const CLOSE_ROOM_GONE := 4404
# 4408 由客户端单方面产生（15 秒收不到 pong 就自己关），服务端只把号位保留下来。
# PROTOCOL.md 的 close code 表里已经登记了这一条，别在 S3 里把它挪作他用。
const CLOSE_PONG_TIMEOUT := 4408
const CLOSE_REPLACED := 4409
const CLOSE_SHUTDOWN := 4500

# Task 4 从服务端复制过来的共享样本目录，Task 14 的对拍从这里读。
const FIXTURES_DIR := "res://tools/validation/fixtures/protocol"

static func is_lobby_opcode(opcode: int) -> bool:
	return opcode >= OPCODE_LOBBY_MIN and opcode <= OPCODE_LOBBY_MAX

static func is_sync_opcode(opcode: int) -> bool:
	return opcode >= OPCODE_SYNC_MIN and opcode <= OPCODE_SYNC_MAX

static func normalize_room_code(value: String) -> String:
	return value.strip_edges().to_upper()

static func is_room_code(value: String) -> bool:
	if value.length() != ROOM_CODE_LENGTH:
		return false
	for index in range(value.length()):
		if not ROOM_CODE_ALPHABET.contains(value[index]):
			return false
	return true

static func encode(message: Dictionary) -> String:
	return JSON.stringify(message)

static func decode(text: String) -> Dictionary:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {
			"type": S2C_ERROR,
			"code": "invalid_json",
			"message": "服务端帧不是 JSON 对象",
		}
	var message: Dictionary = parsed
	var message_type := String(message.get("type", ""))
	if not SERVER_MESSAGE_TYPES.has(message_type):
		return {
			"type": S2C_ERROR,
			"code": "unknown_message",
			"message": "未知的服务端消息：%s" % message_type,
		}
	return message

static func make_join(token: String, session_token: String, nickname: String) -> Dictionary:
	return {
		"type": C2S_JOIN,
		"protocol_version": PROTOCOL_VERSION,
		"token": token if not token.is_empty() else null,
		"session_token": session_token if not session_token.is_empty() else null,
		"nickname": nickname,
	}

static func make_set_ready(ready: bool) -> Dictionary:
	return {"type": C2S_SET_READY, "ready": ready}

static func make_set_nickname(nickname: String) -> Dictionary:
	return {"type": C2S_SET_NICKNAME, "nickname": nickname}

static func make_start() -> Dictionary:
	return {"type": C2S_START}

static func make_end_match() -> Dictionary:
	return {"type": C2S_END_MATCH}

static func make_leave() -> Dictionary:
	return {"type": C2S_LEAVE}

static func make_ping(client_time_ms: int) -> Dictionary:
	return {"type": C2S_PING, "client_time_ms": client_time_ms}

static func make_match_result(player_kills: Dictionary, team_wave: int) -> Dictionary:
	var kills: Dictionary = {}
	for slot in player_kills.keys():
		kills[str(int(slot))] = int(player_kills[slot])
	return {"type": C2S_MATCH_RESULT, "player_kills": kills, "team_wave": team_wave}
```

- [ ] **Step 3: 静态检查并核对与服务端的常量一致**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
rg -n "PROTOCOL_VERSION" \
  /Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/lobby_protocol.gd \
  /Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/protocol/version.ts \
  /Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/fixtures/protocol/manifest.json
rg -o -N '"(join|set_ready|set_nickname|start|end_match|leave|ping|match_result)"' \
  /Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/protocol/lobby.ts \
  | head -16
rg -o -N '"(join|set_ready|set_nickname|start|end_match|leave|ping|match_result)"' \
  /Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/lobby_protocol.gd \
  | head -16
```

Expected: Godot 退出码为 0，输出不含由本次改动引入的 `SCRIPT ERROR` 或 `Parse Error`；三处 `PROTOCOL_VERSION` 都是 `1`（客户端镜像、服务端 `version.ts`、共享 fixtures 的 manifest）；两条 `rg -o` 打印出的 8 个客户端消息名集合完全相同（含 `end_match`）。**客户端只有 `lobby_protocol.gd` 这一处协议镜像**，若 `scripts/net/` 下还能搜到第二个 `PROTOCOL_VERSION`，先把它删掉再继续。

- [ ] **Step 4: 提交协议镜像**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add scripts/net/lobby_protocol.gd scripts/net/lobby_protocol.gd.uid
git commit -m "feat: add lobby protocol constants"
```

Expected: 提交包含脚本与 Godot 生成的 `.uid`，不含 `.godot/`。

---

### Task 8: 客户端 `RoomClient`（WebSocketPeer + 心跳 + 重连）

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/room_client.gd`

**Interfaces:**
- Consumes: Task 7 的 `LobbyProtocol` 全部常量与静态函数；S1 的 `scripts/net/net_config.gd`（`ws_url` 由调用方拼好后传入，`RoomClient` 自身不读配置）。
- Produces:
  - `enum LinkState { IDLE, CONNECTING, HANDSHAKING, READY, RECONNECTING, CLOSED }`
  - 信号：`link_state_changed(state: int)`、`room_state_received(room: Dictionary, you: Dictionary)`、`member_joined(member: Dictionary)`、`member_left(payload: Dictionary)`、`member_updated(member: Dictionary)`、`start_countdown(payload: Dictionary)`、`match_start(payload: Dictionary)`、`server_error(code: String, message: String, payload: Dictionary)`
  - 方法：`configure(url: String, token: String, player_nickname: String) -> void`、`open_link() -> int`、`close_link(code: int = 1000, reason: String = "") -> void`、`set_ready(ready: bool) -> void`、`set_nickname(new_nickname: String) -> void`、`request_start() -> void`、`end_match() -> void`、`leave() -> void`、`report_match_result(player_kills: Dictionary, team_wave: int) -> void`、`get_link_state() -> int`、`get_local_slot() -> int`、`get_session_token() -> String`、`get_room_state() -> Dictionary`、`get_members() -> Array`、`get_room_status() -> String`、`is_host() -> bool`、`get_last_error_code() -> String`

`report_match_result()` 与 `end_match()` 的调用方是 Task 13 的 `demo_arena` 结算路径，
不是本任务。**两者都必须有真实调用方**——只有服务端半边的写榜链路是死代码。

- [ ] **Step 1: 写入连接生命周期**

创建 `scripts/net/room_client.gd`，先写到 `_process`：

```gdscript
extends Node
class_name RoomClient

const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")

# 重连退避。总时长 1+2+4+8+8+8 = 31 秒，刚好覆盖服务端 30 秒的重连宽限窗口，
# 超出后再重连也只会拿到 session_unknown，所以到此为止不再重试。
const RECONNECT_DELAYS := [1.0, 2.0, 4.0, 8.0, 8.0, 8.0]

signal link_state_changed(state: int)
signal room_state_received(room: Dictionary, you: Dictionary)
signal member_joined(member: Dictionary)
signal member_left(payload: Dictionary)
signal member_updated(member: Dictionary)
signal start_countdown(payload: Dictionary)
signal match_start(payload: Dictionary)
signal server_error(code: String, message: String, payload: Dictionary)

enum LinkState {
	IDLE,
	CONNECTING,
	HANDSHAKING,
	READY,
	RECONNECTING,
	CLOSED,
}

var link_state: int = LinkState.IDLE
var ws_url := ""
var auth_token := ""
var nickname := ""
var session_token := ""
var local_slot := -1
var room_state: Dictionary = {}
var last_error_code := ""

var _peer: WebSocketPeer = null
var _handshake_sent := false
var _pending_close := false
var _ping_timer := 0.0
var _pong_timer := 0.0
var _reconnect_timer := 0.0
var _reconnect_attempt := 0

func configure(url: String, token: String, player_nickname: String) -> void:
	ws_url = url
	auth_token = token
	nickname = player_nickname

func open_link() -> int:
	_reconnect_attempt = 0
	_pending_close = false
	return _open_socket()

# 关闭要走两段。WebSocketPeer.close() 只是把关闭帧排进队列，真正发出去要等下一次
# poll()；如果这里立刻把 _peer 置空，_process 会在开头 return，队列里的帧——包括
# leave() 刚排进去的那一帧——就再也不会被冲出去。服务端只会看到一个裸的 socket 关闭，
# 于是走 timeout 语义：lobby 下广播的 reason 从 leave 变成 timeout，playing 下席位被
# 白白保留 30 秒。所以这里只发起关闭并置 _pending_close，由 _process 在对端确认
# STATE_CLOSED 之后才真正释放 _peer。
func close_link(code: int = 1000, reason: String = "") -> void:
	# 把重连次数顶满，确保 _handle_socket_closed 不会又把连接拉起来。
	_reconnect_attempt = RECONNECT_DELAYS.size()
	if _peer != null:
		_peer.close(code, reason)
		_peer.poll()
		_pending_close = true
	else:
		_pending_close = false
	_handshake_sent = false
	_set_link_state(LinkState.CLOSED)

func _open_socket() -> int:
	_peer = WebSocketPeer.new()
	_handshake_sent = false
	_pending_close = false
	_ping_timer = 0.0
	_pong_timer = 0.0
	var error := _peer.connect_to_url(ws_url)
	if error != OK:
		_peer = null
		last_error_code = "connect_failed"
		_set_link_state(LinkState.CLOSED)
		server_error.emit(
			last_error_code,
			"无法连接 %s（错误码 %d）" % [ws_url, error],
			{}
		)
		return error
	_set_link_state(LinkState.CONNECTING)
	return OK

func _process(delta: float) -> void:
	if _peer == null:
		if link_state == LinkState.RECONNECTING:
			_reconnect_timer -= delta
			if _reconnect_timer <= 0.0:
				_open_socket()
		return
	_peer.poll()
	var ready_state := _peer.get_ready_state()
	if _pending_close:
		# 主动关闭中：继续 poll 直到关闭帧真的发出去、对端确认，然后才释放 _peer。
		if ready_state == WebSocketPeer.STATE_CLOSED:
			_peer = null
			_pending_close = false
		return
	if ready_state == WebSocketPeer.STATE_OPEN:
		if not _handshake_sent:
			_send_handshake()
		_drain_packets()
		_tick_heartbeat(delta)
	elif ready_state == WebSocketPeer.STATE_CLOSED:
		_drain_packets()
		_handle_socket_closed()

func _drain_packets() -> void:
	if _peer == null:
		return
	while _peer.get_available_packet_count() > 0:
		_handle_packet(_peer.get_packet())
```

- [ ] **Step 2: 写入握手、心跳与断线**

在同一文件末尾追加：

```gdscript
func _send_handshake() -> void:
	_handshake_sent = true
	_set_link_state(LinkState.HANDSHAKING)
	_send(LobbyProtocolScript.make_join(auth_token, session_token, nickname))

func _tick_heartbeat(delta: float) -> void:
	if link_state != LinkState.READY:
		return
	_ping_timer += delta
	_pong_timer += delta
	if _ping_timer >= LobbyProtocolScript.PING_INTERVAL_SECONDS:
		_ping_timer = 0.0
		_send(LobbyProtocolScript.make_ping(Time.get_ticks_msec()))
	if _pong_timer >= LobbyProtocolScript.PING_TIMEOUT_SECONDS:
		_pong_timer = 0.0
		if _peer != null:
			_peer.close(LobbyProtocolScript.CLOSE_PONG_TIMEOUT, "pong_timeout")

func _handle_socket_closed() -> void:
	var code := -1
	var reason := ""
	if _peer != null:
		code = _peer.get_close_code()
		reason = _peer.get_close_reason()
	_peer = null
	_handshake_sent = false
	_pending_close = false

	if code == LobbyProtocolScript.CLOSE_PROTOCOL_MISMATCH:
		last_error_code = "protocol_version_mismatch"
		_set_link_state(LinkState.CLOSED)
		server_error.emit(last_error_code, "协议版本不匹配，请更新客户端", {})
		return
	if (
		code == LobbyProtocolScript.CLOSE_TICKET_INVALID or
		code == LobbyProtocolScript.CLOSE_ROOM_GONE or
		code == LobbyProtocolScript.CLOSE_REPLACED or
		code == 1000
	):
		_set_link_state(LinkState.CLOSED)
		return
	# 没有 session_token 意味着服务端从没给过我们席位，重连也只会再被拒一次。
	if session_token.is_empty() or _reconnect_attempt >= RECONNECT_DELAYS.size():
		_set_link_state(LinkState.CLOSED)
		server_error.emit(
			"connection_lost",
			"与房间的连接已断开（%d %s）" % [code, reason],
			{}
		)
		return
	_reconnect_timer = float(RECONNECT_DELAYS[_reconnect_attempt])
	_reconnect_attempt += 1
	_set_link_state(LinkState.RECONNECTING)

func _set_link_state(next_state: int) -> void:
	if link_state == next_state:
		return
	link_state = next_state
	link_state_changed.emit(link_state)
```

- [ ] **Step 3: 写入消息分发**

在同一文件末尾追加：

```gdscript
func _handle_packet(packet: PackedByteArray) -> void:
	if packet.is_empty():
		return
	# S3 的二进制同步帧首字节落在 0x80-0xFF，JSON 文本帧首字节永远是 '{'（0x7B）。
	# 本轮静默丢弃同步帧而不是报错，这样 S3 上线后旧客户端只是收不到同步数据，
	# 不会因为一条读不懂的帧被踢下线。
	if LobbyProtocolScript.is_sync_opcode(packet[0]):
		return
	var message := LobbyProtocolScript.decode(packet.get_string_from_utf8())
	var message_type := String(message.get("type", ""))
	match message_type:
		LobbyProtocolScript.S2C_ROOM_STATE:
			_apply_room_state(message)
		LobbyProtocolScript.S2C_MEMBER_JOINED:
			member_joined.emit(_dictionary_of(message, "member"))
		LobbyProtocolScript.S2C_MEMBER_LEFT:
			member_left.emit(message)
		LobbyProtocolScript.S2C_MEMBER_UPDATED:
			member_updated.emit(_dictionary_of(message, "member"))
		LobbyProtocolScript.S2C_START_COUNTDOWN:
			start_countdown.emit(message)
		LobbyProtocolScript.S2C_MATCH_START:
			match_start.emit(_dictionary_of(message, "match"))
		LobbyProtocolScript.S2C_PONG:
			_pong_timer = 0.0
		LobbyProtocolScript.S2C_ERROR:
			last_error_code = String(message.get("code", ""))
			server_error.emit(
				last_error_code,
				String(message.get("message", "")),
				message
			)

func _apply_room_state(message: Dictionary) -> void:
	room_state = _dictionary_of(message, "room")
	var you := _dictionary_of(message, "you")
	if not you.is_empty():
		local_slot = int(you.get("slot", local_slot))
		var token := String(you.get("session_token", ""))
		if not token.is_empty():
			session_token = token
	if link_state != LinkState.READY:
		_reconnect_attempt = 0
		_pong_timer = 0.0
		_set_link_state(LinkState.READY)
	room_state_received.emit(room_state, you)

func _dictionary_of(message: Dictionary, key: String) -> Dictionary:
	var value = message.get(key, null)
	return value if typeof(value) == TYPE_DICTIONARY else {}

func _send(message: Dictionary) -> void:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_peer.send_text(LobbyProtocolScript.encode(message))
```

- [ ] **Step 4: 写入对外操作与读取器**

在同一文件末尾追加：

```gdscript
func set_ready(ready: bool) -> void:
	_send(LobbyProtocolScript.make_set_ready(ready))

func set_nickname(new_nickname: String) -> void:
	nickname = new_nickname
	_send(LobbyProtocolScript.make_set_nickname(new_nickname))

func request_start() -> void:
	_send(LobbyProtocolScript.make_start())

# 仅房主、仅 playing。服务端会校验，客户端不重复判断，免得两处规则各自漂移。
func end_match() -> void:
	_send(LobbyProtocolScript.make_end_match())

func leave() -> void:
	_send(LobbyProtocolScript.make_leave())
	# send_text() 只是入队。先 poll 一次把 leave 帧真正冲出去，再发起关闭；
	# close_link() 内部还会再 poll 一次并等对端确认（见 _pending_close）。
	# 少了这一次 poll，服务端只会看到 socket 断开并按 timeout 处理：
	# lobby 下 member_left 的 reason 变成 timeout，playing 下席位白留 30 秒。
	if _peer != null:
		_peer.poll()
	close_link(1000, "leave")

func report_match_result(player_kills: Dictionary, team_wave: int) -> void:
	_send(LobbyProtocolScript.make_match_result(player_kills, team_wave))
	if _peer != null:
		_peer.poll()

func get_link_state() -> int:
	return link_state

func get_local_slot() -> int:
	return local_slot

func get_session_token() -> String:
	return session_token

func get_room_state() -> Dictionary:
	return room_state

func get_members() -> Array:
	var members = room_state.get("members", [])
	return members if typeof(members) == TYPE_ARRAY else []

func get_room_status() -> String:
	return String(room_state.get("state", ""))

func get_last_error_code() -> String:
	return last_error_code

func is_host() -> bool:
	return local_slot >= 0 and int(room_state.get("host_slot", -1)) == local_slot
```

- [ ] **Step 5: 静态检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
rg -n "func (configure|open_link|close_link|set_ready|set_nickname|request_start|end_match|leave|report_match_result|get_link_state|get_local_slot|get_session_token|get_room_state|get_members|get_room_status|is_host|get_last_error_code)\b" \
  /Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/room_client.gd
rg -n "_peer.poll\(\)" /Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/room_client.gd
```

Expected: Godot 退出码为 0，输出不含由本次改动引入的 `SCRIPT ERROR` 或 `Parse Error`；第一条 `rg` 命中 17 个函数定义；第二条 `rg` 至少命中 4 处（`_process` 主循环、`close_link`、`leave`、`report_match_result`）——出站帧在关闭前必须被冲出去。

- [ ] **Step 6: 提交 RoomClient**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add scripts/net/room_client.gd scripts/net/room_client.gd.uid
git commit -m "feat: add websocket room client"
```

Expected: 提交只包含 `room_client.gd` 与其 `.uid`。

---

### Task 9: 网络输入源与联机玩家 descriptor

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/network_input_source.gd`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/online_player_descriptor.gd`

**Interfaces:**
- Consumes: `PlayerInputSource.build_state(move: Vector2, previous: bool, next: bool, use: bool, confirm: bool)`、`PlayerInputSource.reset_edges() -> void`、`PlayerInputSource.PlayerInputStateScript`、`PlayerInputSource.is_online() -> bool`、`PlayerInputSource.get_source_key() -> StringName`（`scripts/input/player_input_source.gd:11-44`）；`PlayerInputState` 的六个字段（`scripts/input/player_input_state.gd:4-9`）；`LocalPlayerDescriptor.SourceKind`、`LocalPlayerDescriptor.create_input_source()`（`scripts/input/local_player_descriptor.gd:14-47`）；服务端 `match_start.player_slots` 的 `{slot, player_id, nickname}` 形状。
- Produces:
  - `NetworkInputSource extends PlayerInputSource`：`BUTTON_PREVIOUS_EQUIPMENT := 1`、`BUTTON_NEXT_EQUIPMENT := 2`、`BUTTON_USE := 4`、`BUTTON_CONFIRM := 8`；`_init(player_slot: int = 0, owned_local_source = null)`；`is_local() -> bool`；`is_online() -> bool`；`get_source_key() -> StringName`；`set_connected(value: bool) -> void`；`apply_remote_frame(move: Vector2, buttons: int) -> void`；`get_last_local_frame() -> Dictionary`（`{"move": Vector2, "buttons": int}`）；`sample()`；`static pack_buttons(state) -> int`。
  - `OnlinePlayerDescriptor extends RefCounted`：字段 `player_index: int`、`slot: int`、`player_id: String`、`nickname: String`、`is_local: bool`、`online: bool`、`local_source_kind: int`、`local_gamepad_device_id: int`；方法 `source_key() -> StringName`、`create_input_source()`；`static from_match_start(match_payload: Dictionary, local_player_id: String, local_source_kind: int, local_gamepad_device_id: int) -> Array`。

- [ ] **Step 1: 写入网络输入源**

创建 `scripts/net/network_input_source.gd`：

```gdscript
extends PlayerInputSource
class_name NetworkInputSource

# 联机接入的唯一接缝。玩家控制器、武器、拾取全都只认 PlayerInputSource，
# 因此本地多人与联机在这一层之下完全同构。
#
# 本地槽位：把 sample() 直接委托给真实设备输入源，同时留一份打包后的帧
#           供 S3 上行，本轮不发送。
# 远端槽位：由 S3 调用 apply_remote_frame() 灌入；本轮没有灌入方，
#           因此远端槽位输出静止状态——这是 S2 的预期行为，不是缺陷。

const BUTTON_PREVIOUS_EQUIPMENT := 1
const BUTTON_NEXT_EQUIPMENT := 2
const BUTTON_USE := 4
const BUTTON_CONFIRM := 8

var slot := 0
var local_source = null
var connected := true
var remote_move := Vector2.ZERO
var remote_buttons := 0
var last_local_frame := {"move": Vector2.ZERO, "buttons": 0}

func _init(player_slot: int = 0, owned_local_source = null) -> void:
	slot = maxi(player_slot, 0)
	local_source = owned_local_source

func is_local() -> bool:
	return local_source != null

func is_online() -> bool:
	return connected

func get_source_key() -> StringName:
	return StringName("net_slot_%d" % slot)

func set_connected(value: bool) -> void:
	connected = value
	if not connected:
		remote_move = Vector2.ZERO
		remote_buttons = 0
		reset_edges()

func apply_remote_frame(move: Vector2, buttons: int) -> void:
	remote_move = move.limit_length(1.0)
	remote_buttons = buttons

func get_last_local_frame() -> Dictionary:
	return last_local_frame.duplicate()

func sample():
	if local_source != null:
		var state = local_source.sample()
		last_local_frame = {
			"move": state.move_vector,
			"buttons": pack_buttons(state),
		}
		return state
	if not connected:
		reset_edges()
		return PlayerInputStateScript.new()
	return build_state(
		remote_move,
		(remote_buttons & BUTTON_PREVIOUS_EQUIPMENT) != 0,
		(remote_buttons & BUTTON_NEXT_EQUIPMENT) != 0,
		(remote_buttons & BUTTON_USE) != 0,
		(remote_buttons & BUTTON_CONFIRM) != 0
	)

static func pack_buttons(state) -> int:
	var buttons := 0
	if state.previous_equipment_just_pressed:
		buttons |= BUTTON_PREVIOUS_EQUIPMENT
	if state.next_equipment_just_pressed:
		buttons |= BUTTON_NEXT_EQUIPMENT
	if state.use_pressed:
		buttons |= BUTTON_USE
	if state.confirm_just_pressed:
		buttons |= BUTTON_CONFIRM
	return buttons
```

`build_state()` 会自己维护 `previous_*_pressed` 边沿，因此 `apply_remote_frame()` 只需要送电平，不需要送边沿。

- [ ] **Step 2: 写入联机玩家 descriptor**

创建 `scripts/net/online_player_descriptor.gd`：

```gdscript
extends RefCounted
class_name OnlinePlayerDescriptor

# 与 LocalPlayerDescriptor 形状对等：只要有 create_input_source()，
# LocalPlayerSpawner.spawn_players() 就能原样消费这份列表。

const NetworkInputSourceScript = preload("res://scripts/net/network_input_source.gd")
const LocalPlayerDescriptorScript = preload(
	"res://scripts/input/local_player_descriptor.gd"
)

var player_index := 0
var slot := 0
var player_id := ""
var nickname := ""
var is_local := false
var online := true
var local_source_kind := -1
var local_gamepad_device_id := -1

func source_key() -> StringName:
	return StringName("net_slot_%d" % slot)

func create_input_source():
	var owned_local_source = null
	if is_local:
		var local_descriptor = LocalPlayerDescriptorScript.new()
		local_descriptor.player_index = player_index
		local_descriptor.source_kind = (
			local_source_kind if local_source_kind >= 0
			else LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD
		)
		local_descriptor.gamepad_device_id = local_gamepad_device_id
		owned_local_source = local_descriptor.create_input_source()
		if owned_local_source == null:
			return null
	var source = NetworkInputSourceScript.new(slot, owned_local_source)
	source.set_connected(online)
	return source

static func from_match_start(
	match_payload: Dictionary,
	local_player_id: String,
	local_source_kind: int,
	local_gamepad_device_id: int
) -> Array:
	var descriptors: Array = []
	var raw_slots = match_payload.get("player_slots", [])
	if typeof(raw_slots) != TYPE_ARRAY:
		return descriptors
	var ordered: Array = []
	for entry in raw_slots:
		if typeof(entry) == TYPE_DICTIONARY:
			ordered.append(entry)
	ordered.sort_custom(
		func(left, right): return int(left.get("slot", 0)) < int(right.get("slot", 0))
	)
	for index in range(ordered.size()):
		var entry: Dictionary = ordered[index]
		var descriptor = OnlinePlayerDescriptor.new()
		descriptor.player_index = index
		descriptor.slot = int(entry.get("slot", index))
		descriptor.player_id = String(entry.get("player_id", ""))
		descriptor.nickname = String(entry.get("nickname", ""))
		descriptor.is_local = (
			not local_player_id.is_empty() and descriptor.player_id == local_player_id
		)
		descriptor.online = true
		if descriptor.is_local:
			descriptor.local_source_kind = local_source_kind
			descriptor.local_gamepad_device_id = local_gamepad_device_id
		descriptors.append(descriptor)
	return descriptors
```

- [ ] **Step 3: 静态检查并确认继承关系**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
rg -n "^extends PlayerInputSource" \
  /Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/network_input_source.gd
rg -n "func create_input_source" \
  /Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/online_player_descriptor.gd \
  /Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/input/local_player_descriptor.gd
```

Expected: Godot 退出码为 0，输出不含由本次改动引入的 `SCRIPT ERROR` 或 `Parse Error`；第一条 `rg` 命中 1 行；第二条 `rg` 在两个文件里各命中 1 行——两种 descriptor 提供同名同参的工厂方法是 spawner 不分叉的前提。

- [ ] **Step 4: 提交输入接缝**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add \
  scripts/net/network_input_source.gd scripts/net/network_input_source.gd.uid \
  scripts/net/online_player_descriptor.gd scripts/net/online_player_descriptor.gd.uid
git commit -m "feat: add network input source and online player descriptor"
```

Expected: 提交包含两个脚本与各自的 `.uid`。

---

### Task 10: 会话联机字段、spawner 闸门与 seed 通道

`Mode.ONLINE_MULTIPLAYER` 这个枚举值由 **S0 Task 10** 加入，本任务在它之上追加联机所需的
字段与方法，并把服务端下发的 seed 真正接到 `SimWorld` 上。

**Files:**
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/docs/superpowers/specs/2026-08-07-online-multiplayer-server-design.md`（第 485 行的「一行不改」措辞）
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/gameplay/game_session.gd`（**无行号**：S0 Task 10 已经改过它）
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/gameplay/local_player_spawner.gd:33`
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/gameplay/demo_arena.gd`（**无行号**：S0 Task 7/8/9/10 已经四次大改它）

**Interfaces:**
- Consumes:
  - Task 9 的 `OnlinePlayerDescriptor`（作为 `local_players` 的元素类型）；现有 `LocalPlayerSpawner.spawn_players(container, spawn_points, place_item_service, single_player_input) -> Array[PlayerController]`。
  - **S0 Task 10 已加好的 `GameSessionState.Mode.ONLINE_MULTIPLAYER`（枚举值 `2`）**。枚举的所有权归 S0，本任务只在它之上追加字段与方法。
  - S0 的 `SimClock.TICK_SECONDS = 0.05`（`scripts/sim/sim_clock.gd`）与 `demo_arena._setup_simulation()` 里的 `sim_world.reset(...)`。
- Produces:
  - `GameSessionState.online_room: Dictionary`
  - `GameSessionState.online_client: Node`
  - `GameSessionState.configure_online(players: Array, room_info: Dictionary) -> void`
  - `GameSessionState.is_multiplayer() -> bool`
  - `GameSessionState.attach_online_client(client: Node) -> void`
  - `GameSessionState.release_online_client() -> void`
  - `demo_arena` 在联机模式下用 `online_room["seed"]` 覆盖 `random_seed`

- [ ] **Step 1: 修订 spec 的「一行不改」措辞并记录改前状态**

spec 第 485 行写着 `LocalPlayerSpawner.spawn_players()` **一行不改**，但本任务确实要改它的第 33 行
（把模式闸门从 `Mode.LOCAL_MULTIPLAYER` 放宽到 `is_multiplayer()`）。计划不能单方面重写规格，
所以先提交一次 `docs:` 修订。

把 spec 第 485 行：

```markdown
`LocalPlayerSpawner.spawn_players()` **一行不改**：它按 descriptor 列表生成玩家，联机只需提供一份 `OnlinePlayerDescriptor` 列表。
```

改为：

```markdown
`LocalPlayerSpawner.spawn_players()` 的 **descriptor 消费路径一行不改**：它按 descriptor 列表生成玩家，联机只需提供一份 `OnlinePlayerDescriptor` 列表。唯一允许的编辑是第 33 行的模式闸门改为 `session.is_multiplayer()`，让 `Mode.ONLINE_MULTIPLAYER` 落到同一条路径上。
```

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add docs/superpowers/specs/2026-08-07-online-multiplayer-server-design.md
git commit -m "docs: allow spawner mode gate to cover online"
git status --short
sed -n '30,36p' scripts/gameplay/local_player_spawner.gd
rg -n "enum Mode" -A 4 scripts/gameplay/game_session.gd
rg -n "func _setup_simulation|sim_world.reset|func _handle_player_spawn_failure|session.mode == 1" scripts/gameplay/demo_arena.gd
```

Expected:
- spec 提交成功；工作树随后干净或只含本计划前序任务的产物。
- `local_player_spawner.gd` 第 33 行为 `	if session.mode == GameSessionScript.Mode.LOCAL_MULTIPLAYER:`。
- `game_session.gd` 的 `enum Mode` **已经包含 `ONLINE_MULTIPLAYER,`**（S0 Task 10 的产出）。若没有，先去执行 S0 Task 10——本任务不新增枚举值。
- 最后一条 `rg` 命中 `_setup_simulation()` 定义、它内部的 `sim_world.reset(...)`、`_handle_player_spawn_failure()` 定义与其中的 `session.mode == 1` 判断。**行号不作要求**：S0 已经四次改写这个文件，任何固定行号都失效了。

- [ ] **Step 2: 在 S0 的基础上追加 GameSessionState 的联机字段**

`enum Mode` **一行不动**（S0 Task 10 已把 `ONLINE_MULTIPLAYER` 加进去）。在 `scripts/gameplay/game_session.gd` 里：

把变量声明段：

```gdscript
var mode := Mode.SINGLE
var local_players: Array = []
var last_error := ""
```

改为：

```gdscript
var mode := Mode.SINGLE
var local_players: Array = []
var online_room: Dictionary = {}
# 对局期间仍然活着的 RoomClient。OnlineLobby 在切场景前把它移交到这里，
# demo_arena 结算时才有对象可以上报 match_result。
var online_client: Node = null
var last_error := ""
```

在 `configure_single()` 与 `configure_local()` 里各补一行 `online_room.clear()`：

```gdscript
func configure_single() -> void:
	mode = Mode.SINGLE
	local_players.clear()
	online_room.clear()
	last_error = ""

func configure_local(players: Array) -> void:
	mode = Mode.LOCAL_MULTIPLAYER
	local_players = players.duplicate()
	online_room.clear()
	last_error = ""
```

在 `configure_local()` 之后、`clear()` 之前追加：

```gdscript
# 联机与本地多人共用 local_players：两种 descriptor 都提供 create_input_source()，
# 生成路径因此完全一致。
#
# online_room 承载房间元信息（room_id / room_code / local_slot / session_token …），
# 其中 online_room["seed"] 是**模拟种子，DemoArena 必须消费它**：spec 要求各客户端
# 用同一 seed 初始化 SimWorld，不接这条通道的话四个客户端会各自用 DEFAULT_SIM_SEED
# 跑出「一致地错误」的波次，一路瞒到 S3 才炸。online_room["tick_rate"] 同理要与
# SimClock.TICK_SECONDS 对得上。
func configure_online(players: Array, room_info: Dictionary) -> void:
	mode = Mode.ONLINE_MULTIPLAYER
	local_players = players.duplicate()
	online_room = room_info.duplicate(true)
	last_error = ""

func is_multiplayer() -> bool:
	return mode == Mode.LOCAL_MULTIPLAYER or mode == Mode.ONLINE_MULTIPLAYER

# OnlineLobby 在 change_scene_to_file() 之前调用：把 RoomClient 从即将被释放的
# 大厅场景挂到 /root 下，让它跨场景存活到结算上报为止。
func attach_online_client(client: Node) -> void:
	release_online_client()
	online_client = client

func release_online_client() -> void:
	if online_client != null and is_instance_valid(online_client):
		online_client.leave()
		online_client.queue_free()
	online_client = null
```

把 `clear()` 改为同时释放联机连接：

```gdscript
func clear() -> void:
	release_online_client()
	configure_single()
```

- [ ] **Step 3: 让 spawner 的模式闸门覆盖联机**

把 `scripts/gameplay/local_player_spawner.gd` 第 33 行：

```gdscript
	if session.mode == GameSessionScript.Mode.LOCAL_MULTIPLAYER:
```

改为：

```gdscript
	if session.is_multiplayer():
```

**这是本计划对该文件的唯一编辑。** `spawn_players()` 的其余部分——descriptor 数量校验、`create_input_source()` 调用、`PlayerScreenBoundsScript.limit_motion()` 安全区校验、`_find_open_spawn_position()`、`_fail_spawn()` 回滚——一行不动。

- [ ] **Step 4: 让开局失败回到正确的大厅**

在 `scripts/gameplay/demo_arena.gd` 的常量区（`const HitResult = ...` 上方）加入：

```gdscript
const GameSessionScript = preload("res://scripts/gameplay/game_session.gd")
```

把 `_handle_player_spawn_failure()` 中的这两行：

```gdscript
	if session != null and session.mode == 1:
		destination = "res://scenes/menu/LocalMultiplayerLobby.tscn"
```

替换为：

```gdscript
	if session != null and session.mode == GameSessionScript.Mode.LOCAL_MULTIPLAYER:
		destination = "res://scenes/menu/LocalMultiplayerLobby.tscn"
	elif session != null and session.mode == GameSessionScript.Mode.ONLINE_MULTIPLAYER:
		destination = "res://scenes/ui/OnlineLobby.tscn"
```

`res://scenes/ui/OnlineLobby.tscn` 在 Task 11 创建；本步骤只写路径字符串，不需要该文件已存在。

- [ ] **Step 5: 让联机模式真正消费服务端下发的 seed 与 tick_rate**

spec 第 532 行要求「各客户端用同一 seed 初始化 SimWorld」。`match_start.seed` 一路传到
`GameSession.online_room["seed"]` 之后如果没人读它，四个客户端会各自用 `DEFAULT_SIM_SEED` 起模拟——
波次与散布逐位一致（因为都是同一个默认种子），`match_result` 的多数投票于是「一致地正确」，
把「seed 通道从未接通」这件事一直瞒到 S3。这一步把通道接上。

在 `scripts/gameplay/demo_arena.gd` 的 `_setup_simulation()` 里，`sim_world.reset(...)` **之前**插入：

```gdscript
	# 联机局的种子由房间服下发，必须覆盖本地的 @export random_seed，
	# 否则各客户端跑的是各自的世界。
	var session := get_node_or_null("/root/GameSession")
	if session != null and session.mode == GameSessionScript.Mode.ONLINE_MULTIPLAYER:
		random_seed = int(session.online_room.get("seed", random_seed))
		wave_rng.seed = random_seed
		var server_tick_rate := int(session.online_room.get("tick_rate", 0))
		var local_tick_rate := roundi(1.0 / SimClockScript.TICK_SECONDS)
		if server_tick_rate != local_tick_rate:
			push_error(
				"online tick_rate mismatch: server %d, client %d — refusing to start"
				% [server_tick_rate, local_tick_rate]
			)
			session.last_error = "tick_rate mismatch"
			_handle_player_spawn_failure()
			return
```

若 `demo_arena.gd` 的常量区还没有 `SimClockScript`（S0 Task 7 应已加入 `const SimClockScript = preload("res://scripts/sim/sim_clock.gd")`），在 Step 4 加的 `GameSessionScript` 旁边补上它。

**为什么是拒绝开局而不是自动适配**：tick 率是确定性模拟的地基，两端不一致时任何「先跑起来再说」
都会变成一局注定要 desync 的对局。响亮失败比静默漂移便宜得多。

- [ ] **Step 6: 静态检查与差异复核**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git diff --stat -- scripts/gameplay/local_player_spawner.gd
git diff -- scripts/gameplay/local_player_spawner.gd
```

Expected: Godot 退出码为 0，输出不含由本次改动引入的 `SCRIPT ERROR` 或 `Parse Error`；`git diff --stat` 显示 `1 file changed, 1 insertion(+), 1 deletion(-)`；`git diff` 的正文只有第 33 行的模式闸门。

- [ ] **Step 7: 跑既有本地多人生成验证，确认没有回归**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Users/liangpingbo/Desktop/4399/game/zombiewar \
  --script tools/validation/validate_local_player_spawning.gd
```

Expected: 输出 `validate_local_player_spawning: PASS`，退出码为 0。单人、双人、四人与失败回滚四条路径都必须仍然通过。

- [ ] **Step 8: 提交会话模式**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add \
  scripts/gameplay/game_session.gd \
  scripts/gameplay/local_player_spawner.gd \
  scripts/gameplay/demo_arena.gd
git commit -m "feat: add online multiplayer session mode"
```

Expected: 提交只含这三个脚本（spec 的 `docs:` 修订已在 Step 1 单独提交）。

---

### Task 11: 联机大厅场景与脚本

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/menu/online_lobby.gd`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scenes/ui/OnlineLobby.tscn`

**Interfaces:**
- Consumes:
  - Task 7 的 `LobbyProtocol.is_room_code(value)`、`normalize_room_code(value)`、`MAX_MEMBERS`。
  - Task 8 的 `RoomClient` 全部信号与方法。
  - Task 9 的 `OnlinePlayerDescriptor.from_match_start(match_payload, local_player_id, local_source_kind, local_gamepad_device_id) -> Array`。
  - Task 10 的 `GameSession.configure_online(players, room_info)`、`GameSession.attach_online_client(client)`、`GameSession.clear()`。
  - S1 客户端（**跨计划权威签名，见 Global Constraints**）：`NetConfig.get_http_base_url() -> String`、`NetConfig.get_ws_base_url() -> String`、`IdentityStore.get_player_id() -> String`、`IdentityStore.get_token() -> String`、`IdentityStore.get_nickname() -> String`、`ApiClient.new(host: Node)`、`ApiClient.request_json(method: String, path: String, body: Variant = null, on_result: Callable = Callable(), authenticate: bool = true) -> void`（回调签名 `(ok: bool, status_code: int, payload: Dictionary)`，`payload` 是解析后的响应体）。
  - `LobbyPlayerPreview.set_player_index(index: int) -> void`、`set_online(value: bool) -> void`（`scripts/menu/lobby_player_preview.gd:30-36`）。
- Produces:
  - `OnlineLobby extends Node3D`（`scripts/menu/online_lobby.gd`）：导出 `game_scene_path`、`main_menu_scene_path`；方法 `refresh_rooms() -> void`、`create_room() -> void`、`join_by_code(code: String) -> void`、`get_room_client() -> RoomClient`、`_hand_off_room_client() -> void`（开局前把 `RoomClient` 移交给 `GameSession`，让它跨场景活到 Task 13 的结算上报）。
  - `res://scenes/ui/OnlineLobby.tscn`，固定节点路径：`LobbyWorld/Slots/P1..P4`（`Marker3D`）、`MenuLayer/StatusRoot/P1Status..P4Status`（`Label`）、`MenuLayer/P1Hint`（`Label`）、`MenuLayer/ConnectionLabel`（`Label`）、`MenuLayer/RoomCodeLabel`（`Label`）、`MenuLayer/RoomList`（`ItemList`）、`MenuLayer/ActionRoot/CreateButton`、`VisibilityCheck`、`CodeInput`、`JoinButton`、`RefreshButton`、`ReadyButton`、`StartButton`、`BackButton`。

- [ ] **Step 1: 核对 S1 客户端网络层的真实签名**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
rg -n "^(static )?func |^extends |^class_name " scripts/net/net_config.gd scripts/net/identity_store.gd scripts/net/api_client.gd
rg -n "\"ok\"|\"status_code\"|\"payload\"|\"error_code\"|\"error_message\"" scripts/net/api_client.gd
```

Expected: 打印三个脚本的 `extends` / `class_name` 与全部函数签名，且与本任务 Consumes 逐字一致：
`NetConfig` 有 `get_http_base_url` / `get_ws_base_url`，`ApiClient` 有 `_init(host: Node = null)` 与
回调式 `request_json(method: String, ...)`；第二条 `rg` 命中统一结果字典的五个键
（`status_code` / `payload`，**不是** `status` / `data`）。

**对不上就停下来回 S1，不要在这里就地适配。** 这些名字在跨计划对齐里已经裁定过一次；
留一句「按真实名字改」等于把接口决策推回执行期，而那正是对齐要消除的东西。
唯一允许的形态差异：若 S1 把 `NetConfig` / `IdentityStore` 做成了 Autoload，
把 Step 2 的 `NetConfigScript.` / `IdentityStoreScript.` 前缀换成 Autoload 名，其余逻辑不变。

- [ ] **Step 2: 写入大厅脚本的状态与生命周期**

创建 `scripts/menu/online_lobby.gd`，先写到 `_input`：

```gdscript
extends Node3D
class_name OnlineLobby

const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")
const RoomClientScript = preload("res://scripts/net/room_client.gd")
const OnlinePlayerDescriptorScript = preload(
	"res://scripts/net/online_player_descriptor.gd"
)
const LocalPlayerDescriptorScript = preload(
	"res://scripts/input/local_player_descriptor.gd"
)
const NetConfigScript = preload("res://scripts/net/net_config.gd")
const IdentityStoreScript = preload("res://scripts/net/identity_store.gd")
const ApiClientScript = preload("res://scripts/net/api_client.gd")
const LOBBY_PLAYER_PREVIEW_SCENE := preload(
	"res://scenes/menu/LobbyPlayerPreview.tscn"
)

const LINK_STATE_TEXT := {
	RoomClientScript.LinkState.IDLE: "未连接",
	RoomClientScript.LinkState.CONNECTING: "连接中…",
	RoomClientScript.LinkState.HANDSHAKING: "握手中…",
	RoomClientScript.LinkState.READY: "已连接",
	RoomClientScript.LinkState.RECONNECTING: "断线重连中…",
	RoomClientScript.LinkState.CLOSED: "已断开",
}

@export_file("*.tscn") var game_scene_path := "res://scenes/gameplay/DemoArena.tscn"
@export_file("*.tscn") var main_menu_scene_path := "res://scenes/menu/MainMenu.tscn"

var api_client: Node = null
var room_client: RoomClient = null
var transition_pending := false
# 开局时 RoomClient 会被移交给 GameSession 跨场景存活，此时本场景不能再关它。
var client_handed_off := false
var listed_room_codes: Array[String] = []
var slot_previews: Dictionary = {}
var local_ready := false

func _ready() -> void:
	api_client = ApiClientScript.new(self)
	if api_client is Node and api_client.get_parent() == null:
		add_child(api_client)
	room_client = RoomClientScript.new()
	room_client.name = "RoomClient"
	add_child(room_client)
	room_client.link_state_changed.connect(_on_link_state_changed)
	room_client.room_state_received.connect(_on_room_state_received)
	room_client.member_joined.connect(_on_member_changed)
	room_client.member_updated.connect(_on_member_changed)
	room_client.member_left.connect(_on_member_left)
	room_client.start_countdown.connect(_on_start_countdown)
	room_client.match_start.connect(_on_match_start)
	room_client.server_error.connect(_on_server_error)
	%CreateButton.pressed.connect(create_room)
	%JoinButton.pressed.connect(_on_join_button_pressed)
	%RefreshButton.pressed.connect(refresh_rooms)
	%ReadyButton.pressed.connect(_on_ready_button_pressed)
	%StartButton.pressed.connect(_on_start_button_pressed)
	%BackButton.pressed.connect(_return_to_menu)
	%RoomList.item_activated.connect(_on_room_list_item_activated)
	%CodeInput.max_length = LobbyProtocolScript.ROOM_CODE_LENGTH
	_apply_hint()
	_sync_slots()
	_on_link_state_changed(room_client.get_link_state())
	refresh_rooms()

func _exit_tree() -> void:
	if client_handed_off:
		return
	if room_client != null and is_instance_valid(room_client):
		room_client.close_link(1000, "scene_exit")

func _input(event: InputEvent) -> void:
	if transition_pending:
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_ESCAPE:
			_return_to_menu()

func get_room_client() -> RoomClient:
	return room_client
```

- [ ] **Step 3: 写入建房、加入与列表刷新**

在同一文件末尾追加：

```gdscript
func refresh_rooms() -> void:
	api_client.request_json(
		"GET",
		"/api/rooms?offset=0&limit=20",
		null,
		_on_rooms_listed
	)

func _on_rooms_listed(ok: bool, status_code: int, payload: Dictionary) -> void:
	%RoomList.clear()
	listed_room_codes.clear()
	if not ok:
		%RoomList.add_item("房间列表获取失败（HTTP %d）" % status_code)
		return
	var items = payload.get("items", [])
	if typeof(items) != TYPE_ARRAY or items.is_empty():
		%RoomList.add_item("暂无公开房间")
		return
	for entry in items:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var room: Dictionary = entry
		var code := String(room.get("room_code", ""))
		listed_room_codes.append(code)
		%RoomList.add_item(
			"%s · %s · %d/%d" % [
				code,
				String(room.get("name", "房间")),
				int(room.get("member_count", 0)),
				int(room.get("max_members", LobbyProtocolScript.MAX_MEMBERS)),
			]
		)

func _on_room_list_item_activated(index: int) -> void:
	if index < 0 or index >= listed_room_codes.size():
		return
	join_by_code(listed_room_codes[index])

func create_room() -> void:
	var visibility := "public" if (%VisibilityCheck as CheckButton).button_pressed else "code_only"
	api_client.request_json(
		"POST",
		"/api/rooms",
		{
			"name": "%s 的房间" % IdentityStoreScript.get_nickname(),
			"visibility": visibility,
			"player_id": IdentityStoreScript.get_player_id(),
			"nickname": IdentityStoreScript.get_nickname(),
		},
		_on_room_opened
	)

func _on_join_button_pressed() -> void:
	join_by_code((%CodeInput as LineEdit).text)

func join_by_code(code: String) -> void:
	var normalized := LobbyProtocolScript.normalize_room_code(code)
	if not LobbyProtocolScript.is_room_code(normalized):
		_set_connection_text("房间码必须是 6 位大写字母数字（不含 I O 0 1）")
		return
	(%CodeInput as LineEdit).text = normalized
	api_client.request_json(
		"POST",
		"/api/rooms/%s/join" % normalized,
		{
			"player_id": IdentityStoreScript.get_player_id(),
			"nickname": IdentityStoreScript.get_nickname(),
		},
		_on_room_opened
	)

func _on_room_opened(ok: bool, status_code: int, payload: Dictionary) -> void:
	if not ok:
		var error: Dictionary = payload.get("error", {}) if typeof(payload.get("error", {})) == TYPE_DICTIONARY else {}
		_set_connection_text(
			"进房失败（HTTP %d）：%s" % [status_code, String(error.get("message", "未知错误"))]
		)
		return
	var ws_path := String(payload.get("ws_path", ""))
	if ws_path.is_empty():
		_set_connection_text("服务端未返回 ws_path")
		return
	(%RoomCodeLabel as Label).text = "房间码 %s" % String(payload.get("room_code", ""))
	local_ready = false
	room_client.configure(
		"%s%s" % [NetConfigScript.get_ws_base_url(), ws_path],
		IdentityStoreScript.get_token(),
		IdentityStoreScript.get_nickname()
	)
	room_client.open_link()
```

- [ ] **Step 4: 写入房间状态同步与开局**

在同一文件末尾追加：

```gdscript
func _on_link_state_changed(state: int) -> void:
	_set_connection_text(String(LINK_STATE_TEXT.get(state, "未知状态")))
	var connected := state == RoomClientScript.LinkState.READY
	(%ReadyButton as Button).disabled = not connected
	(%StartButton as Button).disabled = not connected or not room_client.is_host()
	(%CreateButton as Button).disabled = connected
	(%JoinButton as Button).disabled = connected

func _on_room_state_received(_room: Dictionary, _you: Dictionary) -> void:
	_sync_slots()
	(%StartButton as Button).disabled = not room_client.is_host()
	(%RoomCodeLabel as Label).text = "房间码 %s" % String(
		room_client.get_room_state().get("room_code", "")
	)

func _on_member_changed(_member: Dictionary) -> void:
	_sync_slots()

func _on_member_left(_payload: Dictionary) -> void:
	_sync_slots()

func _on_start_countdown(payload: Dictionary) -> void:
	# countdown_ms 为 null 表示倒计时被取消（有人在 starting 期间离开）。
	# 不处理这一支的话，「对局将在 3.0 秒后开始」会一直挂在屏幕上，
	# 玩家完全看不出开局已经黄了——room_state 的处理路径不碰这行字。
	if payload.get("countdown_ms", null) == null:
		_set_connection_text("开局已取消，等待房主重新开始")
		return
	var seconds := float(int(payload.get("countdown_ms", 0))) / 1000.0
	_set_connection_text("对局将在 %.1f 秒后开始" % seconds)

func _on_ready_button_pressed() -> void:
	local_ready = not local_ready
	(%ReadyButton as Button).text = "取消准备" if local_ready else "准备"
	room_client.set_ready(local_ready)

func _on_start_button_pressed() -> void:
	room_client.request_start()

func _on_server_error(code: String, message: String, _payload: Dictionary) -> void:
	_set_connection_text("错误 %s：%s" % [code, message])

func _on_match_start(payload: Dictionary) -> void:
	if transition_pending:
		return
	var descriptors := OnlinePlayerDescriptorScript.from_match_start(
		payload,
		IdentityStoreScript.get_player_id(),
		LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD,
		-1
	)
	if descriptors.is_empty():
		_set_connection_text("match_start 未包含任何席位，无法开局")
		return
	transition_pending = true
	GameSession.configure_online(
		descriptors,
		{
			"room_id": String(room_client.get_room_state().get("room_id", "")),
			"room_code": String(room_client.get_room_state().get("room_code", "")),
			"seed": int(payload.get("seed", 0)),
			"tick_rate": int(payload.get("tick_rate", LobbyProtocolScript.DEFAULT_TICK_RATE)),
			"map_id": String(payload.get("map_id", LobbyProtocolScript.DEFAULT_MAP_ID)),
			"local_slot": room_client.get_local_slot(),
			"session_token": room_client.get_session_token(),
		}
	)
	# 把 RoomClient 从这个即将被释放的场景里摘出来挂到 /root 下，
	# 让它活到 demo_arena 结算上报 match_result 为止。不做这一步，
	# RoomClient.report_match_result() 就永远没有活着的对象可以调用。
	_hand_off_room_client()
	get_tree().change_scene_to_file(game_scene_path)

func _hand_off_room_client() -> void:
	if room_client == null or not is_instance_valid(room_client):
		return
	if room_client.get_parent() == self:
		remove_child(room_client)
	get_tree().root.add_child(room_client)
	GameSession.attach_online_client(room_client)
	client_handed_off = true

func _return_to_menu() -> void:
	if transition_pending:
		return
	transition_pending = true
	if not client_handed_off and room_client != null and is_instance_valid(room_client):
		room_client.leave()
	# clear() 内部会 release_online_client()，把可能已移交的连接也一并收掉。
	GameSession.clear()
	get_tree().change_scene_to_file(main_menu_scene_path)
```

- [ ] **Step 5: 写入席位同步与提示**

在同一文件末尾追加：

```gdscript
func _sync_slots() -> void:
	var members := room_client.get_members() if room_client != null else []
	var by_slot: Dictionary = {}
	for entry in members:
		if typeof(entry) == TYPE_DICTIONARY:
			by_slot[int(entry.get("slot", -1))] = entry
	for index in range(LobbyProtocolScript.MAX_MEMBERS):
		var label := get_node_or_null(
			"MenuLayer/StatusRoot/P%dStatus" % (index + 1)
		) as Label
		var member = by_slot.get(index, null)
		if label != null:
			label.text = _slot_text(index, member)
		_sync_slot_preview(index, member)
	_apply_hint()

func _slot_text(index: int, member) -> String:
	if member == null:
		return "P%d · 等待加入" % (index + 1)
	var text := "P%d · %s" % [index + 1, String(member.get("nickname", "玩家"))]
	if bool(member.get("is_host", false)):
		text += " · 房主"
	if bool(member.get("abandoned", false)):
		text += " · 已断开"
	elif not bool(member.get("connected", true)):
		text += " · 掉线重连中"
	elif bool(member.get("ready", false)):
		text += " · 已准备"
	return text

func _sync_slot_preview(index: int, member) -> void:
	var marker := get_node_or_null(
		"LobbyWorld/Slots/P%d" % (index + 1)
	) as Marker3D
	if marker == null:
		return
	if member == null:
		if slot_previews.has(index):
			var old_preview = slot_previews[index]
			slot_previews.erase(index)
			if is_instance_valid(old_preview):
				marker.remove_child(old_preview)
				old_preview.queue_free()
		return
	var preview = slot_previews.get(index)
	if not is_instance_valid(preview):
		preview = LOBBY_PLAYER_PREVIEW_SCENE.instantiate()
		preview.name = "LobbyPlayerPreview"
		marker.add_child(preview)
		slot_previews[index] = preview
	preview.set_player_index(index)
	preview.set_online(
		bool(member.get("connected", true)) and not bool(member.get("abandoned", false))
	)

func _apply_hint() -> void:
	var hint := get_node_or_null("MenuLayer/P1Hint") as Label
	if hint == null:
		return
	# 单人房无交叉验证对象，服务端不会写榜。这条提示必须常驻，
	# 不能等玩家打完一局才发现成绩没上榜。
	hint.text = (
		"房主按「开始」开局 · ESC 返回 · 至少 2 人才能上榜 · 最多 %d 人 · 不支持战斗中加入"
		% LobbyProtocolScript.MAX_MEMBERS
	)

func _set_connection_text(text: String) -> void:
	var label := get_node_or_null("MenuLayer/ConnectionLabel") as Label
	if label != null:
		label.text = text
```

- [ ] **Step 6: 写入大厅场景**

创建 `scenes/ui/OnlineLobby.tscn`：

```ini
[gd_scene load_steps=10 format=3]

[ext_resource type="Script" path="res://scripts/menu/online_lobby.gd" id="1_online_lobby"]
[ext_resource type="FontFile" path="res://assets/fonts/NotoSansSC-UI.ttf" id="2_font"]
[ext_resource type="PackedScene" path="res://scenes/ui/MobileOrientationGuard.tscn" id="3_guard"]

[sub_resource type="Environment" id="Environment_lobby"]
background_mode = 1
background_color = Color(0.008, 0.012, 0.014, 1)
ambient_light_source = 2
ambient_light_color = Color(0.24, 0.31, 0.34, 1)
ambient_light_energy = 0.52
fog_enabled = true
fog_light_color = Color(0.1, 0.04, 0.035, 1)
fog_density = 0.014

[sub_resource type="StandardMaterial3D" id="Material_ground"]
albedo_color = Color(0.045, 0.052, 0.054, 1)
roughness = 0.94

[sub_resource type="PlaneMesh" id="Mesh_ground"]
material = SubResource("Material_ground")
size = Vector2(24, 16)

[sub_resource type="StandardMaterial3D" id="Material_slot"]
transparency = 1
albedo_color = Color(0.19, 0.42, 0.82, 0.42)
emission_enabled = true
emission = Color(0.08, 0.28, 0.62, 1)
emission_energy_multiplier = 1.8

[sub_resource type="CylinderMesh" id="Mesh_slot"]
material = SubResource("Material_slot")
top_radius = 0.82
bottom_radius = 0.82
height = 0.035

[sub_resource type="StyleBoxFlat" id="StyleBox_button_normal"]
bg_color = Color(0.075, 0.09, 0.095, 0.94)
border_width_left = 2
border_width_top = 2
border_width_right = 2
border_width_bottom = 2
border_color = Color(0.72, 0.2, 0.14, 1)
corner_radius_top_left = 4
corner_radius_top_right = 4
corner_radius_bottom_right = 4
corner_radius_bottom_left = 4

[sub_resource type="StyleBoxFlat" id="StyleBox_button_hover"]
bg_color = Color(0.55, 0.09, 0.07, 1)
border_width_left = 2
border_width_top = 2
border_width_right = 2
border_width_bottom = 2
border_color = Color(0.72, 0.2, 0.14, 1)
corner_radius_top_left = 4
corner_radius_top_right = 4
corner_radius_bottom_right = 4
corner_radius_bottom_left = 4

[node name="OnlineLobby" type="Node3D"]
script = ExtResource("1_online_lobby")

[node name="WorldEnvironment" type="WorldEnvironment" parent="."]
environment = SubResource("Environment_lobby")

[node name="KeyLight" type="DirectionalLight3D" parent="."]
rotation_degrees = Vector3(-52, -28, 0)
light_color = Color(0.62, 0.75, 0.8, 1)
light_energy = 1.35
shadow_enabled = true

[node name="WarningLight" type="OmniLight3D" parent="."]
position = Vector3(0, 4.5, 1.2)
light_color = Color(0.24, 0.55, 1, 1)
light_energy = 4.0
omni_range = 12.0

[node name="Camera3D" type="Camera3D" parent="."]
position = Vector3(0, 5.6, 10.8)
rotation_degrees = Vector3(-17, 0, 0)
current = true
fov = 44.0

[node name="LobbyWorld" type="Node3D" parent="."]

[node name="Ground" type="MeshInstance3D" parent="LobbyWorld"]
mesh = SubResource("Mesh_ground")

[node name="Slots" type="Node3D" parent="LobbyWorld"]

[node name="P1" type="Marker3D" parent="LobbyWorld/Slots"]
position = Vector3(-3.45, 0.03, -1.1)

[node name="Pad" type="MeshInstance3D" parent="LobbyWorld/Slots/P1"]
mesh = SubResource("Mesh_slot")

[node name="WorldLabel" type="Label3D" parent="LobbyWorld/Slots/P1"]
position = Vector3(0, 0.08, 0)
text = "P1"
font_size = 42
outline_size = 10
billboard = 1

[node name="P2" type="Marker3D" parent="LobbyWorld/Slots"]
position = Vector3(-1.15, 0.03, -1.1)

[node name="Pad" type="MeshInstance3D" parent="LobbyWorld/Slots/P2"]
mesh = SubResource("Mesh_slot")

[node name="WorldLabel" type="Label3D" parent="LobbyWorld/Slots/P2"]
position = Vector3(0, 0.08, 0)
text = "P2"
font_size = 42
outline_size = 10
billboard = 1

[node name="P3" type="Marker3D" parent="LobbyWorld/Slots"]
position = Vector3(1.15, 0.03, -1.1)

[node name="Pad" type="MeshInstance3D" parent="LobbyWorld/Slots/P3"]
mesh = SubResource("Mesh_slot")

[node name="WorldLabel" type="Label3D" parent="LobbyWorld/Slots/P3"]
position = Vector3(0, 0.08, 0)
text = "P3"
font_size = 42
outline_size = 10
billboard = 1

[node name="P4" type="Marker3D" parent="LobbyWorld/Slots"]
position = Vector3(3.45, 0.03, -1.1)

[node name="Pad" type="MeshInstance3D" parent="LobbyWorld/Slots/P4"]
mesh = SubResource("Mesh_slot")

[node name="WorldLabel" type="Label3D" parent="LobbyWorld/Slots/P4"]
position = Vector3(0, 0.08, 0)
text = "P4"
font_size = 42
outline_size = 10
billboard = 1

[node name="MobileOrientationGuard" parent="." instance=ExtResource("3_guard")]

[node name="MenuLayer" type="CanvasLayer" parent="."]

[node name="Shade" type="ColorRect" parent="MenuLayer"]
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
mouse_filter = 2
color = Color(0.005, 0.008, 0.009, 0.26)

[node name="Title" type="Label" parent="MenuLayer"]
anchor_left = 0.05
anchor_top = 0.04
anchor_right = 0.6
anchor_bottom = 0.12
theme_override_colors/font_color = Color(0.97, 0.95, 0.9, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 40
text = "联机 · 房间与大厅"

[node name="RoomCodeLabel" type="Label" parent="MenuLayer"]
unique_name_in_owner = true
anchor_left = 0.6
anchor_top = 0.04
anchor_right = 0.95
anchor_bottom = 0.12
theme_override_colors/font_color = Color(1, 0.54, 0.35, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 32
text = "房间码 ------"
horizontal_alignment = 2

[node name="ConnectionLabel" type="Label" parent="MenuLayer"]
anchor_left = 0.05
anchor_top = 0.12
anchor_right = 0.95
anchor_bottom = 0.18
theme_override_colors/font_color = Color(0.76, 0.78, 0.74, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 18
text = "未连接"

[node name="RoomList" type="ItemList" parent="MenuLayer"]
unique_name_in_owner = true
anchor_left = 0.05
anchor_top = 0.19
anchor_right = 0.36
anchor_bottom = 0.66
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 17

[node name="StatusRoot" type="HBoxContainer" parent="MenuLayer"]
anchor_left = 0.05
anchor_top = 0.7
anchor_right = 0.95
anchor_bottom = 0.78
theme_override_constants/separation = 26
alignment = 1

[node name="P1Status" type="Label" parent="MenuLayer/StatusRoot"]
custom_minimum_size = Vector2(250, 56)
layout_mode = 2
theme_override_colors/font_color = Color(1, 0.54, 0.35, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 18
text = "P1 · 等待加入"
horizontal_alignment = 1

[node name="P2Status" type="Label" parent="MenuLayer/StatusRoot"]
custom_minimum_size = Vector2(250, 56)
layout_mode = 2
theme_override_colors/font_color = Color(0.86, 0.88, 0.84, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 18
text = "P2 · 等待加入"
horizontal_alignment = 1

[node name="P3Status" type="Label" parent="MenuLayer/StatusRoot"]
custom_minimum_size = Vector2(250, 56)
layout_mode = 2
theme_override_colors/font_color = Color(0.86, 0.88, 0.84, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 18
text = "P3 · 等待加入"
horizontal_alignment = 1

[node name="P4Status" type="Label" parent="MenuLayer/StatusRoot"]
custom_minimum_size = Vector2(250, 56)
layout_mode = 2
theme_override_colors/font_color = Color(0.86, 0.88, 0.84, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 18
text = "P4 · 等待加入"
horizontal_alignment = 1

[node name="ActionRoot" type="HBoxContainer" parent="MenuLayer"]
anchor_left = 0.05
anchor_top = 0.8
anchor_right = 0.95
anchor_bottom = 0.87
theme_override_constants/separation = 12
alignment = 1

[node name="CreateButton" type="Button" parent="MenuLayer/ActionRoot"]
unique_name_in_owner = true
custom_minimum_size = Vector2(150, 52)
layout_mode = 2
theme_override_colors/font_color = Color(0.97, 0.95, 0.9, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 20
theme_override_styles/normal = SubResource("StyleBox_button_normal")
theme_override_styles/hover = SubResource("StyleBox_button_hover")
theme_override_styles/pressed = SubResource("StyleBox_button_hover")
theme_override_styles/focus = SubResource("StyleBox_button_hover")
text = "建房"

[node name="VisibilityCheck" type="CheckButton" parent="MenuLayer/ActionRoot"]
unique_name_in_owner = true
custom_minimum_size = Vector2(150, 52)
layout_mode = 2
theme_override_colors/font_color = Color(0.86, 0.88, 0.84, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 18
button_pressed = true
text = "公开房间"

[node name="CodeInput" type="LineEdit" parent="MenuLayer/ActionRoot"]
unique_name_in_owner = true
custom_minimum_size = Vector2(170, 52)
layout_mode = 2
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 20
placeholder_text = "房间码"
alignment = 1

[node name="JoinButton" type="Button" parent="MenuLayer/ActionRoot"]
unique_name_in_owner = true
custom_minimum_size = Vector2(130, 52)
layout_mode = 2
theme_override_colors/font_color = Color(0.97, 0.95, 0.9, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 20
theme_override_styles/normal = SubResource("StyleBox_button_normal")
theme_override_styles/hover = SubResource("StyleBox_button_hover")
theme_override_styles/pressed = SubResource("StyleBox_button_hover")
theme_override_styles/focus = SubResource("StyleBox_button_hover")
text = "输码加入"

[node name="RefreshButton" type="Button" parent="MenuLayer/ActionRoot"]
unique_name_in_owner = true
custom_minimum_size = Vector2(130, 52)
layout_mode = 2
theme_override_colors/font_color = Color(0.97, 0.95, 0.9, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 20
theme_override_styles/normal = SubResource("StyleBox_button_normal")
theme_override_styles/hover = SubResource("StyleBox_button_hover")
theme_override_styles/pressed = SubResource("StyleBox_button_hover")
theme_override_styles/focus = SubResource("StyleBox_button_hover")
text = "刷新列表"

[node name="ReadyButton" type="Button" parent="MenuLayer/ActionRoot"]
unique_name_in_owner = true
custom_minimum_size = Vector2(130, 52)
layout_mode = 2
disabled = true
theme_override_colors/font_color = Color(0.97, 0.95, 0.9, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 20
theme_override_styles/normal = SubResource("StyleBox_button_normal")
theme_override_styles/hover = SubResource("StyleBox_button_hover")
theme_override_styles/pressed = SubResource("StyleBox_button_hover")
theme_override_styles/focus = SubResource("StyleBox_button_hover")
text = "准备"

[node name="StartButton" type="Button" parent="MenuLayer/ActionRoot"]
unique_name_in_owner = true
custom_minimum_size = Vector2(130, 52)
layout_mode = 2
disabled = true
theme_override_colors/font_color = Color(0.97, 0.95, 0.9, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 20
theme_override_styles/normal = SubResource("StyleBox_button_normal")
theme_override_styles/hover = SubResource("StyleBox_button_hover")
theme_override_styles/pressed = SubResource("StyleBox_button_hover")
theme_override_styles/focus = SubResource("StyleBox_button_hover")
text = "开始"

[node name="BackButton" type="Button" parent="MenuLayer/ActionRoot"]
unique_name_in_owner = true
custom_minimum_size = Vector2(130, 52)
layout_mode = 2
theme_override_colors/font_color = Color(0.97, 0.95, 0.9, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 20
theme_override_styles/normal = SubResource("StyleBox_button_normal")
theme_override_styles/hover = SubResource("StyleBox_button_hover")
theme_override_styles/pressed = SubResource("StyleBox_button_hover")
theme_override_styles/focus = SubResource("StyleBox_button_hover")
text = "返回"

[node name="P1Hint" type="Label" parent="MenuLayer"]
anchor_left = 0.05
anchor_top = 0.9
anchor_right = 0.95
anchor_bottom = 0.97
theme_override_colors/font_color = Color(0.72, 0.75, 0.72, 1)
theme_override_fonts/font = ExtResource("2_font")
theme_override_font_sizes/font_size = 17
text = "房主按「开始」开局 · ESC 返回 · 至少 2 人才能上榜 · 最多 4 人 · 不支持战斗中加入"
horizontal_alignment = 1
```

- [ ] **Step 7: 静态检查并加载场景**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
rg -n "unique_name_in_owner = true" \
  /Users/liangpingbo/Desktop/4399/game/zombiewar/scenes/ui/OnlineLobby.tscn | wc -l
rg -n "^\[node name=\"RoomCodeLabel\"" -A 1 \
  /Users/liangpingbo/Desktop/4399/game/zombiewar/scenes/ui/OnlineLobby.tscn
```

Expected: Godot 退出码为 0，输出不含由本次改动引入的 `SCRIPT ERROR`、`Parse Error` 或 `Failed loading resource`；`rg | wc -l` 输出 `10`（`RoomList` + 8 个操作控件 + `RoomCodeLabel`）；第二条 `rg` 显示 `RoomCodeLabel` 紧跟着 `unique_name_in_owner = true`。

`online_lobby.gd` 有两处用 `%RoomCodeLabel` 取这个节点（`_on_room_opened` 与 `_on_room_state_received`）。
少了这一行，一进房就会抛 `Node not found: %RoomCodeLabel` 直接崩——`ConnectionLabel` 之所以没事，
是因为脚本对它用的是 `get_node_or_null("MenuLayer/ConnectionLabel")`。两种写法混用正是这个 bug 的来源。

- [ ] **Step 8: 提交联机大厅**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add \
  scripts/menu/online_lobby.gd scripts/menu/online_lobby.gd.uid \
  scenes/ui/OnlineLobby.tscn
git commit -m "feat: add online lobby scene"
```

Expected: 提交包含脚本、`.uid` 与场景。

---

### Task 12: 主菜单「联机」入口

**Files（全部不带行号：这四个文件在 S0 / S1 / S2 之间被反复改写，任何固定行号都会失效）：**
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/menu/menu_flow.gd`
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/menu/main_menu.gd`
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scenes/menu/MainMenu.tscn`
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/validate_local_multiplayer_menu_scenes.gd`

**Interfaces:**
- Consumes: Task 11 的 `res://scenes/ui/OnlineLobby.tscn`；现有 `MenuFlow.State`、`MenuFlow._request_start() -> bool`；现有 `GameSession.clear()`；S1 的 `ApiClient`（用来探活 `GET /health`，该端点由 S1 Task 6 的 `buildApp()` 挂载）。
- Produces: `MenuFlow.request_online() -> bool`；`MainMenu` 的 `online_lobby_scene_path` 导出、`_on_online_multiplayer_button_pressed() -> void` 与 `_probe_online() -> void`；`MainMenu.tscn` 的 `MenuLayer/MenuRoot/LeftColumn/Actions/OnlineMultiplayerButton` 节点（`unique_name_in_owner = true`）。

**按钮顺序在这里定型**：本任务把 `OnlineMultiplayerButton` 插在 `LocalMultiplayerButton` 与 `QuitButton`
之间。**S1 Task 12 在本计划之后执行**，把 `LeaderboardButton` 插在 `OnlineMultiplayerButton` 与
`QuitButton` 之间，并把本任务写下的两条 focus_neighbor 改到它身上。最终链是
`Single → LocalMultiplayer → OnlineMultiplayer → Leaderboard → Quit`。
Step 4 把验证脚本的焦点链断言改成按序遍历的数组，S1 只需往那个数组里插一项。

- [ ] **Step 1: 给 MenuFlow 加联机入口**

在 `scripts/menu/menu_flow.gd` 的 `request_local()` 之后插入：

```gdscript
func request_online() -> bool:
	return _request_start()
```

- [ ] **Step 2: 在场景里插入联机按钮**

在 `scenes/menu/MainMenu.tscn` 中，把 `LocalMultiplayerButton` 的这一行：

```ini
focus_neighbor_bottom = NodePath("../QuitButton")
```

改为：

```ini
focus_neighbor_bottom = NodePath("../OnlineMultiplayerButton")
```

在 `LocalMultiplayerButton` 节点块之后、`QuitButton` 节点块之前，插入：

```ini
[node name="OnlineMultiplayerButton" type="Button" parent="MenuLayer/MenuRoot/LeftColumn/Actions"]
unique_name_in_owner = true
custom_minimum_size = Vector2(390, 66)
layout_mode = 2
focus_neighbor_top = NodePath("../LocalMultiplayerButton")
focus_neighbor_bottom = NodePath("../QuitButton")
theme_override_colors/font_color = Color(0.97, 0.95, 0.9, 1)
theme_override_colors/font_hover_color = Color(1, 1, 1, 1)
theme_override_colors/font_focus_color = Color(1, 1, 1, 1)
theme_override_fonts/font = ExtResource("6_cjk_font")
theme_override_font_sizes/font_size = 26
theme_override_styles/normal = SubResource("StyleBox_button_normal")
theme_override_styles/hover = SubResource("StyleBox_button_hover")
theme_override_styles/pressed = SubResource("StyleBox_button_hover")
theme_override_styles/focus = SubResource("StyleBox_button_hover")
theme_override_styles/disabled = SubResource("StyleBox_button_disabled")
text = "联机"
alignment = 0
```

把 `QuitButton` 的这一行：

```ini
focus_neighbor_top = NodePath("../LocalMultiplayerButton")
```

改为：

```ini
focus_neighbor_top = NodePath("../OnlineMultiplayerButton")
```

在文件末尾的 `[connection]` 段里，`LocalMultiplayerButton` 的三条连接之后插入：

```ini
[connection signal="focus_entered" from="MenuLayer/MenuRoot/LeftColumn/Actions/OnlineMultiplayerButton" to="." method="_on_action_focused"]
[connection signal="mouse_entered" from="MenuLayer/MenuRoot/LeftColumn/Actions/OnlineMultiplayerButton" to="." method="_on_action_focused"]
[connection signal="pressed" from="MenuLayer/MenuRoot/LeftColumn/Actions/OnlineMultiplayerButton" to="." method="_on_online_multiplayer_button_pressed"]
```

- [ ] **Step 3: 接上主菜单脚本并加服务端探活**

在 `scripts/menu/main_menu.gd` 的常量区追加：

```gdscript
const ApiClientScript = preload("res://scripts/net/api_client.gd")
```

在导出段追加：

```gdscript
@export_file("*.tscn") var online_lobby_scene_path := "res://scenes/ui/OnlineLobby.tscn"
```

在 `@onready var local_multiplayer_button` 之后追加：

```gdscript
@onready var online_multiplayer_button: Button = %OnlineMultiplayerButton
```

在 `_on_local_multiplayer_button_pressed()` 之后追加：

```gdscript
func _on_online_multiplayer_button_pressed() -> void:
	if not flow.request_online():
		return
	GameSession.clear()
	_start_transition(online_lobby_scene_path)

# spec 的异常处理表要求「服务端不可达 → 主菜单联机入口显示离线状态」。
# 没有这一步，服务端没起时玩家点进去只会在 OnlineLobby 里看到
# 「房间列表获取失败（HTTP 0）」——那是把诊断留给玩家做。
func _probe_online() -> void:
	var probe = ApiClientScript.new(self)
	if probe is Node and probe.get_parent() == null:
		add_child(probe)
	probe.request_json("GET", "/health", null, _on_online_probed, false)

func _on_online_probed(ok: bool, _status_code: int, _payload: Dictionary) -> void:
	# 过场动画已经开始时不要抢文案：_start_transition() 已经把按钮全禁掉了。
	if flow.state != MenuFlowScript.State.READY:
		return
	online_multiplayer_button.disabled = not ok
	online_multiplayer_button.text = "联机" if ok else "联机（服务器离线）"
```

若 `main_menu.gd` 里 `MenuFlow` 的 preload 常量叫别的名字，把 `MenuFlowScript.State.READY`
换成该文件里已有的写法；这一步只需要「过场中不改文案」这个判断成立。

在 `_ready()` 末尾追加一行：

```gdscript
	_probe_online()
```

把 `_start_transition()` 中的三行禁用改成四行：

```gdscript
	single_player_button.disabled = true
	local_multiplayer_button.disabled = true
	online_multiplayer_button.disabled = true
	quit_button.disabled = true
```

- [ ] **Step 4: 同步既有菜单验证脚本的焦点链断言**

`tools/validation/validate_local_multiplayer_menu_scenes.gd` 第 34 行现在断言
「本地多人的下一个焦点必须是退出」（`local_button.focus_neighbor_bottom == local_button.get_path_to(quit_button)`）。
Step 2 往两者之间插了 `OnlineMultiplayerButton`，这条既有断言立刻变红——所以它必须跟着本任务一起改，
不能留给后面的人去发现。

**改成按序遍历的数组**，而不是逐对手写：S1 Task 12 之后还要往同一条链里插 `LeaderboardButton`，
数组形式让它只需插入一个名字，不必第二次重写整块断言。

把该文件里 `local_flow` 段与 `MainMenu` 段替换为：

```gdscript
	var local_flow = MenuFlowScript.new()
	_expect(local_flow.has_method("request_local"), "MenuFlow must expose request_local", failures)
	if local_flow.has_method("request_local"):
		_expect(local_flow.request_local(), "ready flow must accept local multiplayer start", failures)
		_expect(not local_flow.request_local(), "starting flow must reject duplicate local start", failures)
	var online_flow = MenuFlowScript.new()
	_expect(online_flow.has_method("request_online"), "MenuFlow must expose request_online", failures)
	if online_flow.has_method("request_online"):
		_expect(online_flow.request_online(), "ready flow must accept online multiplayer start", failures)
		_expect(not online_flow.request_online(), "starting flow must reject duplicate online start", failures)

	# 主菜单按钮的权威顺序。往里加新入口时**只改这个数组**：
	# 上下焦点邻居由下面的循环成对推导，不会再出现「某个按钮被踢出焦点链」这种
	# 只有用手柄或 Tab 才会发现的伤。S1 Task 12 会在 OnlineMultiplayerButton 与
	# QuitButton 之间插入 "LeaderboardButton"。
	const ACTION_FOCUS_CHAIN := [
		"SinglePlayerButton",
		"LocalMultiplayerButton",
		"OnlineMultiplayerButton",
		"QuitButton",
	]

	var main_scene := load("res://scenes/menu/MainMenu.tscn") as PackedScene
	_expect(main_scene != null, "MainMenu scene must load", failures)
	if main_scene != null:
		var main = main_scene.instantiate()
		var chain: Array[Button] = []
		var chain_complete := true
		for button_name in ACTION_FOCUS_CHAIN:
			var button := main.get_node_or_null(
				"MenuLayer/MenuRoot/LeftColumn/Actions/%s" % button_name
			) as Button
			_expect(button != null, "MainMenu must contain %s" % button_name, failures)
			if button == null:
				chain_complete = false
			else:
				chain.append(button)
		if chain_complete:
			for index in range(chain.size() - 1):
				var upper := chain[index]
				var lower := chain[index + 1]
				_expect(
					upper.focus_neighbor_bottom == upper.get_path_to(lower),
					"%s focus must move down to %s" % [
						ACTION_FOCUS_CHAIN[index], ACTION_FOCUS_CHAIN[index + 1]
					],
					failures
				)
				_expect(
					lower.focus_neighbor_top == lower.get_path_to(upper),
					"%s focus must move up to %s" % [
						ACTION_FOCUS_CHAIN[index + 1], ACTION_FOCUS_CHAIN[index]
					],
					failures
				)
		main.free()
```

若 Godot 对函数体内的 `const` 报错，把 `ACTION_FOCUS_CHAIN` 移到文件顶部
（`const MenuFlowScript = ...` 旁边）声明，循环里照常引用，其余不变。

- [ ] **Step 5: 静态检查并跑既有菜单验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Users/liangpingbo/Desktop/4399/game/zombiewar \
  --script tools/validation/validate_local_multiplayer_menu_scenes.gd
```

Expected: Godot 导入退出码为 0，无由本次改动引入的 `SCRIPT ERROR` 或 `Parse Error`；验证脚本输出 `validate_local_multiplayer_menu_scenes: PASS`，退出码为 0。

- [ ] **Step 6: 提交主菜单入口**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add \
  scripts/menu/menu_flow.gd \
  scripts/menu/main_menu.gd \
  scenes/menu/MainMenu.tscn \
  tools/validation/validate_local_multiplayer_menu_scenes.gd
git commit -m "feat: add online entry to the main menu"
```

Expected: 提交含四个文件；不含 `.godot/`。

---

### Task 13: 联机结算上报接线（`match_result` 的客户端产生方）

服务端在 Task 5 已经能收集 `match_result`、做多数投票、写榜；客户端在 Task 8 也已经有
`RoomClient.report_match_result()` 与 `end_match()`。但到这里为止**没有任何一处调用它们**——
整条写榜链路是死代码，`submitMatchResult()` 永远等不到第一份上报。这个任务把缺的那一半补上。

**Files:**
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/gameplay/demo_arena.gd`（无行号）

**Interfaces:**
- Consumes:
  - Task 8 的 `RoomClient.report_match_result(player_kills: Dictionary, team_wave: int) -> void`、`RoomClient.end_match() -> void`、`RoomClient.is_host() -> bool`。
  - Task 10 的 `GameSessionState.online_client`、`online_room["local_slot"]`、`Mode.ONLINE_MULTIPLAYER`。
  - Task 11 的 `_hand_off_room_client()`（保证切场景后 `GameSession.online_client` 仍然活着）。
  - 现有 `PlayerController.attack_resolved(direction: Vector3, result: HitResult, camera_impulse_strength: float)`、`PlayerController.player_index`、`HitResult.killed`、`demo_arena.wave_number`、`demo_arena._on_all_players_defeated()`、`demo_arena.request_restart()`。
- Produces:
  - `demo_arena.online_kills_by_slot: Dictionary`（key 是 slot 的十进制字符串，与 `match_result.player_kills` 的线上形状逐字相同）
  - `demo_arena._track_online_kill(direction, result, camera_impulse_strength, player) -> void`
  - `demo_arena._report_online_match_result() -> void`

- [ ] **Step 1: 确认结算所需的三个接缝都在**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
rg -n "signal attack_resolved|var player_index" scripts/player/player_controller.gd
rg -n "var killed" scripts/combat/hit_result.gd
rg -n "func _on_all_players_defeated|func request_restart|var wave_number|attack_resolved.connect" scripts/gameplay/demo_arena.gd
rg -n "func report_match_result|func end_match|func is_host" scripts/net/room_client.gd
```

Expected: `attack_resolved` 信号与 `player_index` 都在；`HitResult.killed` 在；`demo_arena` 里
`_on_all_players_defeated()` / `request_restart()` / `wave_number` / 既有的
`player.attack_resolved.connect(_on_player_attack)` 都命中；`RoomClient` 的三个方法都在。

- [ ] **Step 2: 按 slot 累计击杀**

在 `scripts/gameplay/demo_arena.gd` 的变量区（`var wave_number := 0` 附近）追加：

```gdscript
# 联机局的逐槽击杀数。key 是 slot 的十进制字符串，与 match_result.player_kills
# 的线上形状逐字相同，避免上报前再做一次翻译。
var online_kills_by_slot: Dictionary = {}
var online_result_reported := false
```

在已有的 `player.attack_resolved.connect(_on_player_attack)` 那一行**之后**追加一条独立连接
（不要改 `_on_player_attack` 的签名，它还有别的用途）：

```gdscript
		if not player.attack_resolved.is_connected(_track_online_kill):
			player.attack_resolved.connect(_track_online_kill.bind(player))
```

并在文件中追加：

```gdscript
func _track_online_kill(
	_direction: Vector3,
	result,
	_camera_impulse_strength: float,
	player
) -> void:
	if result == null or not result.killed:
		return
	var session := get_node_or_null("/root/GameSession")
	if session == null or session.mode != GameSessionScript.Mode.ONLINE_MULTIPLAYER:
		return
	# 本地生成的玩家按 player_index 密集排布，slot 是服务端的席位号；
	# descriptor 列表二者同序，所以 player_index 就是 local_players 的下标。
	var descriptor_index := player.player_index
	if descriptor_index < 0 or descriptor_index >= session.local_players.size():
		return
	var slot := int(session.local_players[descriptor_index].slot)
	var key := str(slot)
	online_kills_by_slot[key] = int(online_kills_by_slot.get(key, 0)) + 1
```

- [ ] **Step 3: 全灭时上报，房主离开对局时收尾**

把 `_on_all_players_defeated()` 末尾（`_update_wave_hud()` 之后）追加一行：

```gdscript
	_report_online_match_result()
```

在 `request_restart()` 里，`restart_requested.emit()` **之前**追加一行——重开一局等于离开这一局，
房主要让服务端把房间从 `playing` 收到 `ended`，否则房间会一直挂着直到全员心跳超时：

```gdscript
	_report_online_match_result()
```

并追加：

```gdscript
func _report_online_match_result() -> void:
	if online_result_reported:
		return
	var session := get_node_or_null("/root/GameSession")
	if session == null or session.mode != GameSessionScript.Mode.ONLINE_MULTIPLAYER:
		return
	var client = session.online_client
	if client == null or not is_instance_valid(client):
		return
	online_result_reported = true
	# 本客户端看到的这一局：全队存活波次 + 逐槽击杀。服务端会把各客户端的
	# 这两项拿去做多数投票，分歧的少数派被丢弃，全场分歧则整局作废。
	# 本地没记到的席位补 0，让每一份上报的键集合一致——键集合不同会被当成分歧。
	var kills: Dictionary = {}
	for descriptor in session.local_players:
		kills[str(int(descriptor.slot))] = 0
	for key in online_kills_by_slot.keys():
		kills[key] = int(online_kills_by_slot[key])
	client.report_match_result(kills, wave_number)
	if client.is_host():
		client.end_match()
```

**为什么补 0**：`crossValidateReports()` 是按整份 `player_kills` 的键值对做多数投票的。
如果 A 上报 `{"0":12,"1":0}` 而 B 上报 `{"0":12}`，两份不相等，两人局立刻变成「全场分歧、整局作废」。
把席位表补齐是让投票有意义的前提。

- [ ] **Step 4: 静态检查与既有回归**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
rg -n "report_match_result|end_match\(\)" scripts/gameplay/demo_arena.gd scripts/net/room_client.gd
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Users/liangpingbo/Desktop/4399/game/zombiewar \
  --script tools/validation/validate_local_player_spawning.gd
```

Expected: Godot 退出码为 0，无由本次改动引入的 `SCRIPT ERROR` 或 `Parse Error`；
`rg` 在 `demo_arena.gd` 与 `room_client.gd` 里**都**命中 `report_match_result`
（定义方与调用方各一处，链路两端齐全）；`validate_local_player_spawning: PASS`——
单人与本地多人不进这两个分支，行为必须一字不变。

- [ ] **Step 5: 提交结算接线**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add scripts/gameplay/demo_arena.gd
git commit -m "feat: report online match results from the arena"
```

Expected: 提交只含 `demo_arena.gd`。

---

### Task 14: `validate_online_lobby_wiring.gd` 契约验证

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/validate_online_lobby_wiring.gd`

**Interfaces:**
- Consumes: Task 4 复制到 `tools/validation/fixtures/protocol/` 的共享 fixtures 与 `manifest.json`；Task 7 的 `LobbyProtocol`；Task 8 的 `RoomClient`；Task 9 的 `NetworkInputSource`、`OnlinePlayerDescriptor`；Task 10 的 `GameSessionState.Mode.ONLINE_MULTIPLAYER`、`configure_online()`、`is_multiplayer()`、`attach_online_client()`；Task 11 的 `res://scenes/ui/OnlineLobby.tscn`；Task 12 的 `MainMenu.tscn` 焦点链与 `_probe_online()`；S0 的 `SimClock.TICK_SECONDS`；现有 `LocalPlayerSpawner.spawn_players()`、`PlayerInputSource`、`PlayerInputState`；**既有 `tools/validation/validate_local_disconnect_contract.gd` 对断线状态的约定**（离线输入源 `is_online() == false`、`sample()` 返回全零状态、注册表席位不释放）。
- Produces: 无生产代码导出。本脚本是 S2 客户端侧的验收入口，同时承接原 `validate_protocol_codec.gd` 的 fixtures 对拍职责（该脚本已在 S1 修订版里删除）。

- [ ] **Step 1: 写入验证脚本**

创建 `tools/validation/validate_online_lobby_wiring.gd`：

```gdscript
extends SceneTree

const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")
const RoomClientScript = preload("res://scripts/net/room_client.gd")
const NetworkInputSourceScript = preload("res://scripts/net/network_input_source.gd")
const OnlinePlayerDescriptorScript = preload(
	"res://scripts/net/online_player_descriptor.gd"
)
const LocalPlayerDescriptorScript = preload(
	"res://scripts/input/local_player_descriptor.gd"
)
const GameSessionScript = preload("res://scripts/gameplay/game_session.gd")
const LocalPlayerSpawnerScript = preload(
	"res://scripts/gameplay/local_player_spawner.gd"
)
const SimClockScript = preload("res://scripts/sim/sim_clock.gd")

const MATCH_START_SAMPLE := {
	"seed": 1234567890,
	"tick_rate": 20,
	"map_id": "demo_arena",
	"player_slots": [
		{"slot": 2, "player_id": "remote-b", "nickname": "Bee"},
		{"slot": 0, "player_id": "local-a", "nickname": "Ace"},
	],
}

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_validate_protocol(failures)
	_validate_fixtures(failures)
	_validate_input_source(failures)
	_validate_descriptor(failures)
	_validate_room_client(failures)
	_validate_session(failures)
	_validate_scenes(failures)
	await _validate_spawning(failures)
	_finish(failures)

func _validate_protocol(failures: Array[String]) -> void:
	_expect(LobbyProtocolScript.PROTOCOL_VERSION == 1, "protocol version must be 1", failures)
	_expect(LobbyProtocolScript.MAX_MEMBERS == 4, "online room capacity must be 4", failures)
	_expect(is_equal_approx(LobbyProtocolScript.PING_INTERVAL_SECONDS, 5.0), "ping interval must be 5s", failures)
	_expect(is_equal_approx(LobbyProtocolScript.PING_TIMEOUT_SECONDS, 15.0), "ping timeout must be 15s", failures)
	_expect(is_equal_approx(LobbyProtocolScript.RECONNECT_GRACE_SECONDS, 30.0), "reconnect grace must be 30s", failures)
	_expect(LobbyProtocolScript.DEFAULT_TICK_RATE == 20, "tick rate must be 20", failures)
	# 「20Hz」这个数字在两处独立存在：协议里的 DEFAULT_TICK_RATE 与模拟层的
	# SimClock.TICK_SECONDS。把它们钉在一起，免得将来改了一处、另一处静默漂移，
	# 到 S3 才以 desync 的形式暴露出来。
	_expect(
		LobbyProtocolScript.DEFAULT_TICK_RATE == roundi(1.0 / SimClockScript.TICK_SECONDS),
		"lobby DEFAULT_TICK_RATE must equal the simulation rate implied by SimClock.TICK_SECONDS",
		failures
	)
	_expect(LobbyProtocolScript.DEFAULT_MAP_ID == "demo_arena", "default map must be demo_arena", failures)
	_expect(LobbyProtocolScript.OPCODE_LOBBY_MAX == 0x7F, "lobby opcode range must end at 0x7F", failures)
	_expect(LobbyProtocolScript.OPCODE_SYNC_MIN == 0x80, "sync opcode range must start at 0x80", failures)
	for opcode in [0x00, 0x01, 0x7F]:
		_expect(LobbyProtocolScript.is_lobby_opcode(opcode), "0x%02X must be a lobby opcode" % opcode, failures)
		_expect(not LobbyProtocolScript.is_sync_opcode(opcode), "0x%02X must not be a sync opcode" % opcode, failures)
	for opcode in [0x80, 0xC0, 0xFF]:
		_expect(LobbyProtocolScript.is_sync_opcode(opcode), "0x%02X must be reserved for S3" % opcode, failures)
		_expect(not LobbyProtocolScript.is_lobby_opcode(opcode), "0x%02X must not be a lobby opcode" % opcode, failures)

	_expect(LobbyProtocolScript.is_room_code("AB2DEF"), "valid room code must be accepted", failures)
	for rejected in ["ABCDE", "ABCDEFG", "ABCDE0", "ABCDEI", "abcdef"]:
		_expect(not LobbyProtocolScript.is_room_code(rejected), "%s must be rejected as a room code" % rejected, failures)
	_expect(LobbyProtocolScript.normalize_room_code("  ab2def  ") == "AB2DEF", "room code must be trimmed and upper-cased", failures)

	var join := LobbyProtocolScript.make_join("bearer", "", "Ace")
	_expect(join.get("type") == "join", "join message type must be join", failures)
	_expect(int(join.get("protocol_version", 0)) == 1, "join must carry protocol_version", failures)
	_expect(join.get("token") == "bearer", "join must carry the bearer token", failures)
	_expect(join.get("session_token") == null, "empty session token must serialise as null", failures)

	var decoded := LobbyProtocolScript.decode('{"type":"room_state","room":{}}')
	_expect(String(decoded.get("type", "")) == "room_state", "known server message must pass through decode", failures)
	_expect(String(LobbyProtocolScript.decode("not json").get("code", "")) == "invalid_json", "bad JSON must decode to invalid_json", failures)
	_expect(String(LobbyProtocolScript.decode('{"type":"desync_report"}').get("code", "")) == "unknown_message", "unknown server message must decode to unknown_message", failures)

	_expect(
		LobbyProtocolScript.CLIENT_MESSAGE_TYPES.has("end_match"),
		"end_match must be part of the client message set (host ends the match)",
		failures
	)
	_expect(
		String(LobbyProtocolScript.make_end_match().get("type", "")) == "end_match",
		"make_end_match must produce an end_match frame",
		failures
	)

## 与服务端共享的 fixtures 对拍。原 validate_protocol_codec.gd 的职责合并到这里：
## 客户端只有 lobby_protocol.gd 一处协议镜像，对拍也就只该有一处。
func _validate_fixtures(failures: Array[String]) -> void:
	var manifest := _read_json(
		"%s/manifest.json" % LobbyProtocolScript.FIXTURES_DIR, failures
	)
	if manifest.is_empty():
		return
	_expect(
		int(manifest.get("protocol_version", -1)) == LobbyProtocolScript.PROTOCOL_VERSION,
		"fixtures manifest.protocol_version must equal LobbyProtocol.PROTOCOL_VERSION",
		failures
	)
	var messages = manifest.get("messages", [])
	_expect(typeof(messages) == TYPE_ARRAY, "manifest.messages must be an array", failures)
	if typeof(messages) != TYPE_ARRAY:
		return

	var lobby_fixture_count := 0
	for file_name in messages:
		var path := "%s/%s" % [LobbyProtocolScript.FIXTURES_DIR, String(file_name)]
		var body := _read_json(path, failures)
		if body.is_empty():
			continue
		# 大厅帧的判定是纯机械的：没有 payload 键，且 type 落在两张消息表之一。
		# 带 payload 的是 HTTP 样本（auth / leaderboard），不归本脚本管。
		if body.has("payload"):
			continue
		var message_type := String(body.get("type", ""))
		var is_client := LobbyProtocolScript.CLIENT_MESSAGE_TYPES.has(message_type)
		var is_server := LobbyProtocolScript.SERVER_MESSAGE_TYPES.has(message_type)
		if not is_client and not is_server:
			continue
		lobby_fixture_count += 1
		var frame: Dictionary = body.duplicate(true)
		frame.erase("name")
		var round_tripped = JSON.parse_string(LobbyProtocolScript.encode(frame))
		_expect(
			typeof(round_tripped) == TYPE_DICTIONARY and round_tripped == frame,
			"fixture %s must survive encode/decode unchanged" % file_name,
			failures
		)
		if is_server:
			var decoded_frame := LobbyProtocolScript.decode(
				LobbyProtocolScript.encode(frame)
			)
			_expect(
				String(decoded_frame.get("type", "")) == message_type,
				"server fixture %s must decode back to its own type" % file_name,
				failures
			)
	# handshake + match_result（S1）+ 本轮 8 个大厅样本。
	_expect(
		lobby_fixture_count >= 10,
		"expected at least 10 lobby fixtures, found %d — did Task 4 copy them over?" % lobby_fixture_count,
		failures
	)

func _read_json(path: String, failures: Array[String]) -> Dictionary:
	if not FileAccess.file_exists(path):
		failures.append(
			"missing fixture: %s (copy it from zombiewar-server/protocol/fixtures/)" % path
		)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		failures.append("fixture is not a JSON object: %s" % path)
		return {}
	return parsed

func _validate_input_source(failures: Array[String]) -> void:
	var remote = NetworkInputSourceScript.new(2)
	_expect(remote is PlayerInputSource, "NetworkInputSource must extend PlayerInputSource", failures)
	_expect(not remote.is_local(), "a slot without a local device must not report local", failures)
	_expect(remote.get_source_key() == StringName("net_slot_2"), "source key must encode the slot", failures)

	var idle = remote.sample()
	_expect(idle is PlayerInputState, "sample must return a PlayerInputState", failures)
	_expect(idle.move_vector == Vector2.ZERO, "an unfed remote slot must stand still", failures)

	remote.apply_remote_frame(Vector2(3.0, 0.0), NetworkInputSourceScript.BUTTON_USE)
	var first = remote.sample()
	_expect(first.move_vector.length() <= 1.0001, "remote movement must be clamped to unit length", failures)
	_expect(first.use_pressed and first.use_just_pressed, "first frame of a held button must report the edge", failures)
	var second = remote.sample()
	_expect(second.use_pressed and not second.use_just_pressed, "a held button must not repeat its edge", failures)

	remote.set_connected(false)
	_expect(not remote.is_online(), "a disconnected slot must report offline", failures)
	var offline = remote.sample()
	_expect(offline.move_vector == Vector2.ZERO, "a disconnected slot must stand still", failures)
	_expect(not offline.use_pressed, "a disconnected slot must not hold any button", failures)

	var local_descriptor = LocalPlayerDescriptorScript.new()
	local_descriptor.source_kind = LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD
	var wrapped = NetworkInputSourceScript.new(0, local_descriptor.create_input_source())
	_expect(wrapped.is_local(), "a slot holding a device source must report local", failures)
	var sampled = wrapped.sample()
	_expect(sampled is PlayerInputState, "the local slot must still return a PlayerInputState", failures)
	var frame := wrapped.get_last_local_frame()
	_expect(frame.has("move") and frame.has("buttons"), "the local slot must retain an uplink frame for S3", failures)

	# 与既有的 tools/validation/validate_local_disconnect_contract.gd 对齐：
	# 本地手柄拔掉时，GamepadInputSource 报 is_online() == false 且 sample() 全零，
	# 但注册表席位不释放、玩家仍可被僵尸选中。联机席位掉线必须给出**同一套**行为，
	# 否则「掉线」在两条路径上意味着两件事，S3 只会把这个歧义放大。
	var contract_source = NetworkInputSourceScript.new(1)
	contract_source.set_connected(false)
	_expect(
		not contract_source.is_online(),
		"disconnected online slot must mirror local gamepad disconnect: is_online() == false",
		failures
	)
	var contract_state = contract_source.sample()
	_expect(
		(
			contract_state.move_vector == Vector2.ZERO
			and not contract_state.use_pressed
			and not contract_state.use_just_pressed
			and not contract_state.confirm_just_pressed
			and not contract_state.previous_equipment_just_pressed
			and not contract_state.next_equipment_just_pressed
		),
		"disconnected online slot must emit the same neutral state as a disconnected local gamepad",
		failures
	)
	contract_source.set_connected(true)
	_expect(
		contract_source.is_online(),
		"reconnected online slot must report online again",
		failures
	)

func _validate_descriptor(failures: Array[String]) -> void:
	var descriptors = OnlinePlayerDescriptorScript.from_match_start(
		MATCH_START_SAMPLE,
		"local-a",
		LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD,
		-1
	)
	_expect(descriptors.size() == 2, "match_start must produce one descriptor per slot", failures)
	if descriptors.size() == 2:
		_expect(descriptors[0].slot == 0 and descriptors[1].slot == 2, "descriptors must be ordered by slot", failures)
		_expect(descriptors[0].player_index == 0 and descriptors[1].player_index == 1, "player_index must be dense from 0", failures)
		_expect(descriptors[0].is_local, "the descriptor matching the local player_id must be local", failures)
		_expect(not descriptors[1].is_local, "a remote player_id must not be marked local", failures)
		_expect(descriptors[1].nickname == "Bee", "nicknames must survive the translation", failures)
		for descriptor in descriptors:
			_expect(descriptor.has_method("create_input_source"), "OnlinePlayerDescriptor must expose create_input_source", failures)
			var source = descriptor.create_input_source()
			_expect(source != null, "every online descriptor must produce an input source", failures)
			_expect(source is PlayerInputSource, "online input sources must be PlayerInputSource subclasses", failures)

func _validate_room_client(failures: Array[String]) -> void:
	var client = RoomClientScript.new()
	for method_name in [
		"configure",
		"open_link",
		"close_link",
		"set_ready",
		"set_nickname",
		"request_start",
		"end_match",
		"leave",
		"report_match_result",
		"get_link_state",
		"get_local_slot",
		"get_session_token",
		"get_room_state",
		"get_members",
		"get_room_status",
		"is_host",
	]:
		_expect(client.has_method(method_name), "RoomClient must expose %s" % method_name, failures)
	for signal_name in [
		"link_state_changed",
		"room_state_received",
		"member_joined",
		"member_left",
		"member_updated",
		"start_countdown",
		"match_start",
		"server_error",
	]:
		_expect(client.has_signal(signal_name), "RoomClient must expose the %s signal" % signal_name, failures)
	_expect(client.get_link_state() == RoomClientScript.LinkState.IDLE, "a fresh RoomClient must be idle", failures)
	_expect(client.get_local_slot() == -1, "a fresh RoomClient must not claim a slot", failures)
	client.free()

func _validate_session(failures: Array[String]) -> void:
	var session = root.get_node_or_null("GameSession")
	_expect(session != null, "GameSession autoload must exist", failures)
	if session == null:
		return
	_expect(session.has_method("configure_online"), "GameSessionState must expose configure_online", failures)
	_expect(session.has_method("is_multiplayer"), "GameSessionState must expose is_multiplayer", failures)
	_expect(session.has_method("attach_online_client"), "GameSessionState must expose attach_online_client", failures)
	_expect(session.has_method("release_online_client"), "GameSessionState must expose release_online_client", failures)
	var descriptors = OnlinePlayerDescriptorScript.from_match_start(
		MATCH_START_SAMPLE,
		"local-a",
		LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD,
		-1
	)
	session.configure_online(
		descriptors,
		{"room_id": "room-1", "seed": 1234567890, "tick_rate": 20, "local_slot": 0}
	)
	_expect(session.mode == GameSessionScript.Mode.ONLINE_MULTIPLAYER, "configure_online must select ONLINE_MULTIPLAYER", failures)
	_expect(session.is_multiplayer(), "online sessions must report as multiplayer", failures)
	_expect(session.local_players.size() == 2, "configure_online must publish the descriptor list", failures)
	_expect(int(session.online_room.get("seed", 0)) == 1234567890, "configure_online must retain the room seed", failures)
	# seed 与 tick_rate 是 demo_arena 必须消费的两项，不是纯展示信息。
	_expect(
		int(session.online_room.get("tick_rate", 0)) == roundi(1.0 / SimClockScript.TICK_SECONDS),
		"online_room.tick_rate must agree with SimClock.TICK_SECONDS",
		failures
	)
	session.configure_local([])
	_expect(session.is_multiplayer(), "local multiplayer must still report as multiplayer", failures)
	session.configure_single()
	_expect(not session.is_multiplayer(), "single player must not report as multiplayer", failures)
	_expect(session.online_room.is_empty(), "clearing the session must drop the room info", failures)

func _validate_scenes(failures: Array[String]) -> void:
	var lobby_scene := load("res://scenes/ui/OnlineLobby.tscn") as PackedScene
	_expect(lobby_scene != null, "OnlineLobby scene must load", failures)
	if lobby_scene != null:
		var lobby = lobby_scene.instantiate()
		for player_number in range(1, 5):
			_expect(lobby.get_node_or_null("LobbyWorld/Slots/P%d" % player_number) is Marker3D, "online lobby must contain world slot P%d" % player_number, failures)
			_expect(lobby.get_node_or_null("MenuLayer/StatusRoot/P%dStatus" % player_number) is Label, "online lobby must contain status label P%d" % player_number, failures)
		_expect(lobby.get_node_or_null("MenuLayer/P1Hint") is Label, "online lobby must contain the fixed hint label", failures)
		_expect(lobby.get_node_or_null("MenuLayer/ConnectionLabel") is Label, "online lobby must contain a connection label", failures)
		_expect(lobby.get_node_or_null("MenuLayer/RoomCodeLabel") is Label, "online lobby must contain a room code label", failures)
		_expect(lobby.get_node_or_null("MenuLayer/RoomList") is ItemList, "online lobby must contain the public room list", failures)
		for control_name in [
			"CreateButton",
			"VisibilityCheck",
			"CodeInput",
			"JoinButton",
			"RefreshButton",
			"ReadyButton",
			"StartButton",
			"BackButton",
		]:
			_expect(lobby.get_node_or_null("MenuLayer/ActionRoot/%s" % control_name) != null, "online lobby must contain %s" % control_name, failures)
		var hint := lobby.get_node_or_null("MenuLayer/P1Hint") as Label
		if hint != null:
			_expect(hint.text.contains("至少 2 人才能上榜"), "online lobby must state the 2-player leaderboard rule", failures)
		lobby.free()

	var main_scene := load("res://scenes/menu/MainMenu.tscn") as PackedScene
	_expect(main_scene != null, "MainMenu scene must load", failures)
	if main_scene != null:
		var main = main_scene.instantiate()
		var online_button := main.get_node_or_null("MenuLayer/MenuRoot/LeftColumn/Actions/OnlineMultiplayerButton") as Button
		var local_button := main.get_node_or_null("MenuLayer/MenuRoot/LeftColumn/Actions/LocalMultiplayerButton") as Button
		_expect(online_button != null, "MainMenu must contain OnlineMultiplayerButton", failures)
		if online_button != null and local_button != null:
			_expect(online_button.focus_neighbor_top == online_button.get_path_to(local_button), "online focus must move up to local multiplayer", failures)
			# 向下的邻居故意不写死成 QuitButton：S1 Task 12 会在联机与退出之间
			# 插入 LeaderboardButton。整条焦点链由
			# validate_local_multiplayer_menu_scenes.gd 的 ACTION_FOCUS_CHAIN 数组
			# 按序断言，这里只确认联机按钮没有被孤立出焦点链。
			_expect(
				String(online_button.focus_neighbor_bottom) != "",
				"online button must keep a downward focus neighbour",
				failures
			)
			_expect(main.has_method("_on_online_multiplayer_button_pressed"), "MainMenu must handle the online button", failures)
			# spec 的异常处理表要求服务端不可达时主菜单显示离线状态。
			_expect(main.has_method("_probe_online"), "MainMenu must probe the server before offering the online entry", failures)
		main.free()

func _validate_spawning(failures: Array[String]) -> void:
	var session = root.get_node_or_null("GameSession")
	if session == null:
		return
	var descriptors = OnlinePlayerDescriptorScript.from_match_start(
		{
			"seed": 1,
			"tick_rate": 20,
			"map_id": "demo_arena",
			"player_slots": [
				{"slot": 0, "player_id": "local-a", "nickname": "Ace"},
				{"slot": 1, "player_id": "remote-b", "nickname": "Bee"},
			],
		},
		"local-a",
		LocalPlayerDescriptorScript.SourceKind.KEYBOARD_WASD,
		-1
	)
	# tick_rate 必须给对：demo_arena 在联机模式下会拿它和 SimClock.TICK_SECONDS
	# 对账，不等就 push_error 并拒绝开局。seed 用一个不等于 DEFAULT_SIM_SEED 的
	# 值，好让下面能验出「种子确实被服务端的值覆盖了」。
	const ONLINE_SEED_SAMPLE := 424242
	session.configure_online(
		descriptors,
		{
			"room_id": "room-1",
			"seed": ONLINE_SEED_SAMPLE,
			"tick_rate": roundi(1.0 / SimClockScript.TICK_SECONDS),
			"local_slot": 0,
		}
	)

	var arena_scene := load("res://scenes/gameplay/DemoArena.tscn") as PackedScene
	_expect(arena_scene != null, "DemoArena scene must load", failures)
	if arena_scene == null:
		session.configure_single()
		return
	var arena = arena_scene.instantiate()
	root.add_child(arena)
	await process_frame
	await process_frame
	var container := arena.get_node_or_null("Players") as Node3D
	_expect(container != null, "DemoArena must own a Players container", failures)
	if container != null:
		_expect(
			container.get_child_count() == 2,
			"online session must spawn exactly one player per descriptor, got %d" % container.get_child_count(),
			failures
		)
		var seen_keys: Dictionary = {}
		for player in container.get_children():
			var source = player.get_input_source()
			_expect(source is NetworkInputSourceScript, "every online player must use a NetworkInputSource", failures)
			seen_keys[String(source.get_source_key())] = true
		_expect(seen_keys.size() == container.get_child_count(), "each online player must own a distinct input source", failures)
	# spec 要求各客户端用同一 seed 初始化 SimWorld。这一条是那条通道唯一的自动化守卫：
	# 少了它，四个客户端各自用 DEFAULT_SIM_SEED 跑出「一致地正确」的波次，
	# 一路瞒到 S3 才炸。
	_expect(
		arena.random_seed == ONLINE_SEED_SAMPLE,
		"online arena must adopt the room seed, got %d" % arena.random_seed,
		failures
	)
	_expect(session.last_error.is_empty(), "online spawning must not report a session error: %s" % session.last_error, failures)
	arena.queue_free()
	await process_frame
	session.configure_single()

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_online_lobby_wiring: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 2: 运行联机契约验证**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path /Users/liangpingbo/Desktop/4399/game/zombiewar \
  --script tools/validation/validate_online_lobby_wiring.gd
```

Expected: 导入检查退出码为 0；验证脚本输出 `validate_online_lobby_wiring: PASS`，退出码为 0。任何 `push_error` 行都指明了具体违约的契约，必须回到对应 Task 修复而不是放宽断言。

- [ ] **Step 3: 回归既有验证脚本**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
for script in \
  validate_local_input_contracts \
  validate_local_join_state \
  validate_local_disconnect_contract \
  validate_local_player_spawning \
  validate_local_multiplayer_menu_scenes \
  validate_lobby_player_preview
do
  /Applications/Godot.app/Contents/MacOS/Godot \
    --headless --path /Users/liangpingbo/Desktop/4399/game/zombiewar \
    --script tools/validation/$script.gd || echo "FAILED: $script"
done
```

Expected: 六个脚本各自打印 `<name>: PASS`，且没有任何 `FAILED:` 行。联机改动不得让本地多人回归。
特别注意 `validate_local_multiplayer_menu_scenes`：Task 12 Step 4 已经把它的焦点链断言换成
`ACTION_FOCUS_CHAIN` 数组，若它在这里报「focus must move down to」，说明 `MainMenu.tscn` 的
按钮顺序与那个数组不一致——修场景，不要放宽断言。

- [ ] **Step 4: 确认没有恢复常驻测试套件**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
ls tests 2>/dev/null || echo "no tests directory (expected)"
git status --short
```

Expected: 打印 `no tests directory (expected)`；`git status --short` 只列出本任务的验证脚本与其 `.uid`。

- [ ] **Step 5: 提交验证脚本**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar
git add \
  tools/validation/validate_online_lobby_wiring.gd \
  tools/validation/validate_online_lobby_wiring.gd.uid
git commit -m "test: add online lobby wiring validation"
```

Expected: 提交只含验证脚本与其 `.uid`；至此 S2 的两仓库交付完成。

- [ ] **Step 6: 交给用户的人工验收清单**

不使用 CUA 自动化。把下面这份清单交给用户执行并回传截图：

1. 开发机跑 `cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server && npm run build && npm start`，确认日志出现监听 `0.0.0.0:8787`。
2. 用 `ipconfig getifaddr en0` 取当前 LAN IP，在 Mac 与手机两端把该地址写进 `user://net.cfg`（S1 已提供覆盖机制）。
3. Mac 端进主菜单 →「联机」→「建房」，截图房间码。
4. 手机端进「联机」→ 输入该房间码 →「输码加入」，截图双方都能看到彼此昵称与准备状态。
5. 手机端点「准备」，Mac 端点「开始」，截图两端 HUD，确认进入同一张 `demo_arena`。
6. 关掉「公开房间」开关重建一间房，手机端点「刷新列表」，截图确认该房**不出现**在列表里，但输码仍能进。
7. 对局中把手机切飞行模式 10 秒再恢复，截图确认手机端回到原 P 位（同一 slot 号）。
8. 对局中把手机切飞行模式超过 35 秒，截图 Mac 端该席位显示「已断开」且对局继续。
9. 两端都进对局后被僵尸全灭，截图服务端日志里出现一条 `match result processed`
   且 `outcome.status` 为 `accepted`（这条日志证明 Task 13 的客户端上报真的到了服务端；
   若 `status` 是 `too_short`，说明这局不到 30 秒，属于预期内的不写榜）。
10. 把服务端进程停掉，回主菜单重进一次，截图确认联机按钮变灰且文案为「联机（服务器离线）」。
