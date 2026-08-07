# S1 服务端骨架、身份与排行榜 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新建独立服务端仓库 `zombiewar-server`（Node + TypeScript + Fastify 5 + SQLite + Vitest），提供匿名设备身份与队伍波次榜／个人击杀榜的只读接口与内部写入函数，并在 Godot 客户端加入网络配置、身份存储、API 客户端与排行榜面板。

**Architecture:** 服务端是与 `htz-server` 同级同风格的独立仓库，Fastify 监听 `0.0.0.0:8787`，身份与成绩持久化在单文件 SQLite（`better-sqlite3`）。榜单**没有公开写入端点**，`src/lib/leaderboard.ts` 的 `submitMatchResult()` 只供将来的房间服进程内调用，成绩必须先通过客户端多数投票交叉验证与服务端合理性上限。客户端新增 `scripts/net/` 三件套（`net_config.gd` / `identity_store.gd` / `api_client.gd`）与 `LeaderboardPanel`，base URL 从 `user://net.cfg` 读取、可在面板内直接改写，Web 导出下缺省值取浏览器地址栏的主机名，不硬编码任何 IP。协议镜像文件（`lobby_protocol.gd`）由 S2 产出，本计划不重复造。

**Tech Stack:** Node ≥ 20.11、TypeScript 5、Fastify 5、`@fastify/cors`、`@fastify/rate-limit`、`@fastify/websocket`、`better-sqlite3`、Vitest 3、tsx；Godot 4.7.1、GDScript、`HTTPRequest`、`ConfigFile`。

## Global Constraints

- 客户端主仓库为 `/Users/liangpingbo/Desktop/4399/game/zombiewar`，基线提交 `5423871`；执行前若主线继续前进，先确认下列目标文件接口仍与本计划一致。
- 服务端是**独立新仓库** `/Users/liangpingbo/Desktop/4399/game/zombiewar-server`，与 `zombiewar`、`htz-server` 同级。它有自己的 `git init`，不是子模块，不进 `zombiewar` 的版本库。
- 服务端 Node ≥ 20.11、TypeScript、Fastify 5、Vitest；SQLite 单文件持久化用 `better-sqlite3`。
- Fastify 监听 `0.0.0.0:8787`。
- 身份位置固定为 `Authorization: Bearer <token>`；`ENFORCE_AUTH` 默认 `false`。
- `POST /api/auth/anon` 响应必须含 `player_id`、`token`、`authenticated: false`、`auth_mode: "anonymous_device"`。
- 昵称 2–12 字符 + 黑名单过滤，允许重名（以 `player_id` 区分）。
- 设备 ID 由客户端首次运行生成 UUIDv4，存 `user://identity.cfg`。
- 表结构逐字为：`players(player_id TEXT PRIMARY KEY, device_id TEXT UNIQUE, nickname TEXT, created_at INTEGER, last_seen INTEGER)`；`scores(id INTEGER PRIMARY KEY, board TEXT, season INTEGER, player_id TEXT, room_id TEXT, value INTEGER, extra TEXT, created_at INTEGER)`；`CREATE INDEX idx_scores_rank ON scores(board, season, value DESC)`。
- `board` 只有两个取值：`team_waves`（队伍单局最高存活波次）与 `player_kills`（个人单局击杀数）。`season` 本轮固定为 `0`。
- `GET /api/leaderboard/:board?season=0&limit=100` 每个 `player_id` 只取其最佳成绩；`GET /api/leaderboard/:board/me` 需 token，返回本人最佳与名次。
- **不存在公开的成绩提交端点。** 客户端无任何写榜路径；`leaderboard.ts` 暴露的写入函数只供房间服内部调用。
- 交叉验证：多数投票 → 有客户端偏离多数则丢弃其上报**并记录日志**；全场无多数则整局作废**并记录日志**。投票的「多数」是**席位的严格多数**（不是上报条数的多数）：同一 `player_id` 只算一票（首票为准），不在 `slots` 里的上报直接忽略，且至少要有 2 份独立上报才可能通过。
- 合理性上限：单局波次 ≤ 200；击杀数 ≤ 波次 × 每波僵尸上限（该上限**由客户端刷怪配置推导**，见 Task 4 Step 1）；对局时长有下限。
- SQLite 写失败不得让房间服进程崩：`submitMatchResult()` 内部捕获、记日志、返回 `persisted: false`，由 S2 广播「成绩未保存」。
- **1 人房不写入任何榜单**，客户端 UI 必须明示「至少 2 人才能上榜」。
- 客户端 UI 必须依据响应里的 `authenticated` 字段显示「未认证」，不得依据「拿到 token」显示「已认证」。
- 协议：`zombiewar-server/protocol/` 是单一事实源并导出 `PROTOCOL_VERSION`；`protocol/fixtures/*.json` 复制一份到 `zombiewar/tools/validation/fixtures/protocol/`，两端各自跑对拍。opcode `0x00–0x7F` 为大厅与控制消息，`0x80–0xFF` 整段预留给 S3。
- **协议模块的所有权切分（跨计划唯一约定）**：本计划（S1）Task 5 创建 `protocol/PROTOCOL.md` 的「版本号」与「opcode 号段」两节、`src/lib/protocol/version.ts`、`src/lib/protocol/opcodes.ts`；S2 Task 4 **Modify**（不是 Create）同一份 `PROTOCOL.md`，追加大厅消息表、心跳与 HTTP 端点各节，并新建 `src/lib/protocol/lobby.ts`。线格式的唯一权威是 **S2 的扁平帧**（`{ "type": ..., ...字段 }`），本计划不再定义任何消息信封，也不提供 `encodeMessage` / `decodeMessage`。客户端的协议镜像唯一文件是 S2 Task 7 的 `scripts/net/lobby_protocol.gd`（`class_name LobbyProtocol`），本计划**不产出** `scripts/net/protocol_codec.gd`。
- 协议同步的第 3 条机制（握手强制版本校验、不匹配立即 close 并回报双方版本号）属 S2 房间层，本计划只交付它依赖的 `PROTOCOL_VERSION` 常量、`PROTOCOL.md` 的号段划定与该条契约的白纸黑字；S2 的 `room_hub.ts` 必须在首帧校验 `protocol_version`，不匹配时以 `4001` 关闭连接并在关闭原因里带上双方版本号。
- **`@fastify/websocket` 的安装与注册唯一归本计划**：Task 1 的 `package.json` 写入依赖，Task 6 的 `buildApp()` 里 `await app.register(websocket)`。S2 **不得**再 `npm install` 或再次 `app.register(websocket)`——它用 fastify-plugin 封装，同 scope 重复注册会直接抛错让 `buildApp()` 失败。
- **昵称规则的唯一实现在 `src/lib/sessions.ts`**（`NICKNAME_MIN_LENGTH` / `NICKNAME_MAX_LENGTH` / `NICKNAME_BLOCKLIST` / `normalizeNickname`）。S2 的 `src/lib/rooms.ts` 只做 `export { ... } from './sessions.js';` 再导出，不得另写一份；`room_hub` 需要把 `normalizeNickname` 抛出的 `HttpError` 与自己的 `RoomError` 一起识别，取其 `code` 填进 `error` 帧。
- **数据库句柄的类型别名统一为 `Db`**（`src/lib/db.ts` 导出）。任何模块不得直接 `import type { Database } from 'better-sqlite3'`。
- **主菜单按钮顺序与焦点链（跨计划唯一约定）**：`SinglePlayerButton → LocalMultiplayerButton → OnlineMultiplayerButton → LeaderboardButton → QuitButton`。S2 Task 12 先插入 `OnlineMultiplayerButton`，本计划 Task 12 **在其之后执行**，把 `LeaderboardButton` 插在 `OnlineMultiplayerButton` 与 `QuitButton` 之间。涉及跨计划共享文件的 Files 条目一律**不写行号**，只用唯一文本锚点。
- 本地联通以**全 http 局域网直连**为主路径：页面 `http://<开发机 LAN IP>:<port>/index.html`，API 与 WebSocket `http://<开发机 LAN IP>:8787` / `ws://...`。撰写时开发机 LAN IP 为 `10.3.31.37`，但该地址由 DHCP 分配、会变化，**不得硬编码进业务代码**，必须由 `user://net.cfg` 覆盖、缺省值来自 `net_config.gd`。
- nginx 443 + `wss://` 为备选方案，只记录在服务端仓库 README（证书复用 `/opt/homebrew/etc/nginx/ssl2.conf`，WebSocket 代理头参考 `/opt/homebrew/etc/nginx/vhost/bk/bk.conf`）。
- **`zombiewar` 主仓库没有常驻自动化测试套件**（`AGENTS.md`「Testing Guidelines」）。客户端验证一律写成 `tools/validation/validate_*.gd` 一次性脚本；**不得恢复 `tests/` 或 `tests/run_tests.sh`**。
- 服务端仓库使用 Vitest，那里可以有常驻测试。
- 客户端静态检查命令：`/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit`。
- 不使用 CUA 自动化。需要人工核对的项以操作步骤 + 截图清单交给用户。
- 两个仓库都用 Conventional Commits（`feat:` / `fix:` / `docs:` / `test:` / `chore:`）。

---
### Task 1: 创建 zombiewar-server 仓库骨架与配置

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/package.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/tsconfig.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/tsconfig.test.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/vitest.config.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/.gitignore`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/.env.example`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/types.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/http.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/rate-limit.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/config.ts`

**Interfaces:**
- Consumes: 无（本仓库第一个任务）。
- Produces:
  - `types.ts`：`type BoardId = 'team_waves' | 'player_kills'`、`const BOARD_IDS: readonly BoardId[]`、`const CURRENT_SEASON = 0`、`interface PlayerRow`、`interface ScoreRow`、`interface LeaderboardEntry { rank: number; player_id: string; nickname: string; value: number; created_at: number }`。
  - `lib/http.ts`：`class HttpError { statusCode: number; code: string; message: string; details?: unknown }`、`badRequest(code: string, message: string, details?: unknown): HttpError`、`notFound(code: string, message: string): HttpError`、`unauthorized(code: string, message: string): HttpError`、`getInt(query: Record<string, unknown>, key: string, opts?: { min?: number; max?: number; default?: number }): number | undefined`。
  - `lib/rate-limit.ts`：`interface RateLimitConfig { enabled: boolean; windowMs: number; max: number; authMax: number }`、`type RateTier = 'auth' | 'health' | 'default'`、`rateTier(request: FastifyRequest): RateTier`、`maxForTier(config: RateLimitConfig, tier: RateTier): number`、`rateLimitOptions(config: RateLimitConfig)`。
  - `config.ts`：`interface Config { host: string; port: number; dbPath: string; enforceAuth: boolean; corsOrigin: string; logLevel: string; trustProxy: boolean | number | string[]; rateLimit: RateLimitConfig; maxLeaderboardLimit: number; maxSessions: number }`、`loadDotEnv(file?: string): void`、`loadConfig(env?: NodeJS.ProcessEnv): Config`。

- [ ] **Step 1: 建目录并 git init**

Run:

```bash
mkdir -p /Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib \
         /Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/routes \
         /Users/liangpingbo/Desktop/4399/game/zombiewar-server/test \
         /Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server init
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server rev-parse --show-toplevel
```

Expected: `Initialized empty Git repository in /Users/liangpingbo/Desktop/4399/game/zombiewar-server/.git/`；最后一行输出 `/Users/liangpingbo/Desktop/4399/game/zombiewar-server`，确认它是**独立仓库**而不是 `zombiewar` 的子目录。

- [ ] **Step 2: 写 package.json**

`/Users/liangpingbo/Desktop/4399/game/zombiewar-server/package.json`：

```json
{
  "name": "zombiewar-server",
  "version": "0.1.0",
  "private": true,
  "description": "Anonymous identity + leaderboard backend for the zombiewar Godot 4 client",
  "type": "module",
  "engines": {
    "node": ">=20.11"
  },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "start": "node dist/server.js",
    "dev": "tsx watch src/server.ts",
    "serve": "tsx src/server.ts",
    "typecheck": "tsc -p tsconfig.test.json",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "@fastify/cors": "^11.0.1",
    "@fastify/rate-limit": "^11.2.0",
    "@fastify/websocket": "^11.0.2",
    "better-sqlite3": "^11.8.1",
    "fastify": "^5.2.1"
  },
  "devDependencies": {
    "@types/better-sqlite3": "^7.6.12",
    "@types/node": "^22.13.1",
    "tsx": "^4.19.2",
    "typescript": "^5.7.3",
    "vitest": "^3.0.5"
  }
}
```

`@fastify/websocket` 在这里就进 `dependencies`，本轮没有 WebSocket 端点也照装：它是 S2 房间层的唯一 WS 插件，安装与注册的所有权在本计划（Task 6 Step 1 注册），S2 只挂路由、**不得重复 install / register**。

`dev` / `serve` 用 `tsx` 而不是 `htz-server` 的 `bun`：`better-sqlite3` 是原生模块，node + tsx 与 `npm start` 走同一套 ABI，避免运行时和构建时装载两份不同的 native binding。脚本名字（`build`/`start`/`dev`/`serve`/`typecheck`/`test`）与 `htz-server` 保持一致。

- [ ] **Step 3: 写 tsconfig.json 与 tsconfig.test.json**

`tsconfig.json`：

```json
{
  "compilerOptions": {
    "target": "ES2023",
    "lib": ["ES2023"],
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": "src",

    "strict": true,
    "noImplicitOverride": true,
    "noUncheckedIndexedAccess": true,
    "noPropertyAccessFromIndexSignature": true,
    "exactOptionalPropertyTypes": true,
    "noFallthroughCasesInSwitch": true,
    "noImplicitReturns": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "useUnknownInCatchVariables": true,
    "verbatimModuleSyntax": true,

    "declaration": true,
    "sourceMap": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "esModuleInterop": true,
    "resolveJsonModule": true
  },
  "include": ["src/**/*.ts"],
  "exclude": ["dist", "node_modules"]
}
```

`tsconfig.test.json`：

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "noEmit": true,
    "rootDir": ".",
    "types": ["node"]
  },
  "include": ["src/**/*.ts", "test/**/*.ts"]
}
```

- [ ] **Step 4: 写 vitest.config.ts、.gitignore 与 .env.example**

`vitest.config.ts`：

```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    environment: 'node',
    globals: false,
    testTimeout: 15_000,
  },
});
```

`.gitignore`：

```gitignore
node_modules/
dist/
.env
.env.local
*.log
coverage/
.DS_Store

# SQLite lives outside version control: it is player data, not source.
data/
*.db
*.db-wal
*.db-shm
```

`.env.example`：

```dotenv
# Fastify binds 0.0.0.0 so a phone on the same WiFi can reach it by LAN IP.
ZW_HOST=0.0.0.0
ZW_PORT=8787

# Single-file SQLite. Relative paths resolve against the process CWD.
ZW_DB_PATH=./data/zombiewar.db

# Master switch for downstream auth enforcement. Stays false this round:
# an anonymous device token is not worth enforcing yet.
ZW_ENFORCE_AUTH=false

ZW_CORS_ORIGIN=*
ZW_LOG_LEVEL=info

# Only turn this on when nginx (and nothing else) can reach the port.
ZW_TRUST_PROXY=false

ZW_RATE_LIMIT=true
ZW_RATE_LIMIT_WINDOW_MS=60000
ZW_RATE_LIMIT_MAX=240
ZW_RATE_LIMIT_AUTH_MAX=10

ZW_MAX_LEADERBOARD_LIMIT=100
ZW_MAX_SESSIONS=10000
```

- [ ] **Step 5: 写 src/types.ts**

```ts
/**
 * The two boards this round ships. Anything else is rejected at the route,
 * because an unbounded `board` column is an unbounded table scan waiting to
 * happen and a typo that silently creates a third leaderboard.
 */
export type BoardId = 'team_waves' | 'player_kills';

export const BOARD_IDS: readonly BoardId[] = ['team_waves', 'player_kills'];

/** Season is reserved in the schema but frozen at 0 for this round. */
export const CURRENT_SEASON = 0;

export interface PlayerRow {
  player_id: string;
  device_id: string;
  nickname: string;
  created_at: number;
  last_seen: number;
}

export interface ScoreRow {
  id: number;
  board: string;
  season: number;
  player_id: string;
  room_id: string;
  value: number;
  extra: string;
  created_at: number;
}

/** One rendered leaderboard row. `rank` is 1-based and includes the offset. */
export interface LeaderboardEntry {
  rank: number;
  player_id: string;
  nickname: string;
  value: number;
  created_at: number;
}
```

- [ ] **Step 6: 写 src/lib/http.ts**

```ts
/** Uniform error envelope: every non-2xx response is `{ error: {code, message} }`. */
export class HttpError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = 'HttpError';
  }
}

export function badRequest(code: string, message: string, details?: unknown): HttpError {
  return new HttpError(400, code, message, details);
}

export function notFound(code: string, message: string): HttpError {
  return new HttpError(404, code, message);
}

export function unauthorized(code: string, message: string): HttpError {
  return new HttpError(401, code, message);
}

type Query = Record<string, unknown>;

function single(query: Query, key: string): string | undefined {
  const raw = query[key];
  if (raw === undefined || raw === null) return undefined;
  // Fastify gives string[] when a key repeats; take the last occurrence.
  const value = Array.isArray(raw) ? raw[raw.length - 1] : raw;
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  return trimmed === '' ? undefined : trimmed;
}

export function getInt(
  query: Query,
  key: string,
  opts: { min?: number; max?: number; default?: number } = {},
): number | undefined {
  const value = single(query, key);
  if (value === undefined) return opts.default;
  if (!/^-?\d+$/.test(value)) {
    throw badRequest('invalid_query', `${key} must be an integer, got "${value}"`);
  }
  const n = Number.parseInt(value, 10);
  if (opts.min !== undefined && n < opts.min) {
    throw badRequest('invalid_query', `${key} must be >= ${opts.min}, got ${n}`);
  }
  if (opts.max !== undefined && n > opts.max) {
    throw badRequest('invalid_query', `${key} must be <= ${opts.max}, got ${n}`);
  }
  return n;
}
```

- [ ] **Step 7: 写 src/lib/rate-limit.ts**

```ts
import type { FastifyRequest } from 'fastify';

import { HttpError } from './http.js';

/**
 * Per-IP rate limiting.
 *
 * With no real authentication (see sessions.ts) the only expensive endpoint is
 * POST /api/auth/anon: it writes a row to `players` and evicts the OLDEST live
 * session when the in-memory cap is reached, so a few hundred calls sign real
 * players out. It gets its own, much tighter budget. Reads of the leaderboard
 * are cheap and share the default budget.
 *
 * The tier is part of the bucket key, so exhausting the auth budget cannot lock
 * a client out of reading a leaderboard.
 */

export interface RateLimitConfig {
  enabled: boolean;
  windowMs: number;
  /** Budget for any request without a tier of its own. */
  max: number;
  authMax: number;
}

export type RateTier = 'auth' | 'health' | 'default';

/**
 * Keyed off the matched *route pattern*, not the raw URL, so query strings and
 * path parameters cannot be varied to escape a tier. Unmatched routes (404s)
 * fall through to `default`, which is deliberate.
 */
export function rateTier(request: FastifyRequest): RateTier {
  const route = request.routeOptions.url;
  if (route === '/health') return 'health';
  if (route === '/api/auth/anon' && request.method === 'POST') return 'auth';
  return 'default';
}

export function maxForTier(config: RateLimitConfig, tier: RateTier): number {
  switch (tier) {
    case 'auth':
      return config.authMax;
    case 'health':
      return config.max * 4;
    case 'default':
      return config.max;
  }
}

export function rateLimitOptions(config: RateLimitConfig) {
  return {
    global: true,
    timeWindow: config.windowMs,
    max: (request: FastifyRequest): number => maxForTier(config, rateTier(request)),
    keyGenerator: (request: FastifyRequest): string => `${rateTier(request)}:${request.ip}`,
    /**
     * Returns an `HttpError` rather than a body object on purpose: whatever this
     * returns is handed to app.ts's error handler as-is, and a plain object
     * carries no status, so it would be classified as an unknown failure and
     * answered 500. An HttpError lands in the branch that already exists.
     */
    errorResponseBuilder: (request: FastifyRequest, context: { after: string; max: number }) =>
      new HttpError(
        429,
        'rate_limited',
        `too many requests: the ${rateTier(request)} budget is ${context.max} per ` +
          `${Math.round(config.windowMs / 1000)}s. Retry after ${context.after}.`,
      ),
  };
}
```

- [ ] **Step 8: 写 src/config.ts**

```ts
import { existsSync, readFileSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';

import type { RateLimitConfig } from './lib/rate-limit.js';

export interface Config {
  host: string;
  port: number;
  /** Absolute path of the single-file SQLite database, or ':memory:' in tests. */
  dbPath: string;
  /**
   * Master switch for the future. Today every downstream endpoint parses the
   * bearer token but does not require it — a device-id token is not worth
   * enforcing. When real platform accounts arrive, flip this on and the
   * rejection path in app.ts (already written and tested) starts rejecting.
   */
  enforceAuth: boolean;
  corsOrigin: string;
  logLevel: string;
  /**
   * Whether `X-Forwarded-For` may be believed, and from whom. Defaults to
   * `false`: with it on, ANY caller can set that header, and `request.ip` is
   * what the rate limiter buckets by. Turn it on only for the nginx in front.
   */
  trustProxy: boolean | number | string[];
  rateLimit: RateLimitConfig;
  /** Hard cap on `?limit=` for leaderboard reads. */
  maxLeaderboardLimit: number;
  /** Cap on live in-memory sessions; oldest are evicted past this. */
  maxSessions: number;
}

/**
 * Minimal `.env` reader. Deliberately dependency-free: we only need
 * `KEY=value` lines, `#` comments and optional surrounding quotes.
 * Real environment variables always win over the file.
 */
export function loadDotEnv(file: string = resolve(process.cwd(), '.env')): void {
  if (!existsSync(file)) return;
  for (const rawLine of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line === '' || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
      (value.startsWith("'") && value.endsWith("'") && value.length >= 2)
    ) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
}

function intEnv(env: NodeJS.ProcessEnv, key: string, fallback: number): number {
  const raw = env[key];
  if (raw === undefined || raw.trim() === '') return fallback;
  const n = Number.parseInt(raw, 10);
  if (!Number.isFinite(n) || n < 0) {
    throw new Error(`Invalid ${key}=${raw} (expected a non-negative integer)`);
  }
  return n;
}

const WORD_TRUTHY = new Set(['true', 'yes', 'on']);
const WORD_FALSY = new Set(['false', 'no', 'off']);
const TRUTHY = new Set(['1', ...WORD_TRUTHY]);
const FALSY = new Set(['0', ...WORD_FALSY]);

function boolEnv(env: NodeJS.ProcessEnv, key: string, fallback: boolean): boolean {
  const raw = env[key]?.trim().toLowerCase();
  if (raw === undefined || raw === '') return fallback;
  if (TRUTHY.has(raw)) return true;
  if (FALSY.has(raw)) return false;
  throw new Error(`Invalid ${key}=${raw} (expected true/false)`);
}

function trustProxyEnv(env: NodeJS.ProcessEnv): boolean | number | string[] {
  const raw = env['ZW_TRUST_PROXY']?.trim();
  if (raw === undefined || raw === '') return false;
  const lower = raw.toLowerCase();
  if (/^\d+$/.test(raw)) return Number.parseInt(raw, 10);
  if (WORD_TRUTHY.has(lower)) return true;
  if (WORD_FALSY.has(lower)) return false;
  const proxies = raw
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry !== '');
  return proxies.length === 0 ? false : proxies;
}

function rateLimitEnv(env: NodeJS.ProcessEnv): RateLimitConfig {
  return {
    enabled: boolEnv(env, 'ZW_RATE_LIMIT', true),
    windowMs: intEnv(env, 'ZW_RATE_LIMIT_WINDOW_MS', 60_000),
    max: intEnv(env, 'ZW_RATE_LIMIT_MAX', 240),
    // Tight: flooding this endpoint evicts real players' sessions.
    authMax: intEnv(env, 'ZW_RATE_LIMIT_AUTH_MAX', 10),
  };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const rawDbPath = env['ZW_DB_PATH']?.trim();
  const dbPath =
    rawDbPath === undefined || rawDbPath === ''
      ? resolve(process.cwd(), 'data/zombiewar.db')
      : rawDbPath === ':memory:'
        ? ':memory:'
        : isAbsolute(rawDbPath)
          ? rawDbPath
          : resolve(process.cwd(), rawDbPath);

  return {
    // 0.0.0.0 so a phone on the same WiFi reaches this by LAN IP. The IP itself
    // is never written down here — the client configures its own base URL.
    host: env['ZW_HOST']?.trim() || '0.0.0.0',
    port: intEnv(env, 'ZW_PORT', 8787),
    dbPath,
    enforceAuth: boolEnv(env, 'ZW_ENFORCE_AUTH', false),
    corsOrigin: env['ZW_CORS_ORIGIN']?.trim() || '*',
    logLevel: env['ZW_LOG_LEVEL']?.trim() || 'info',
    trustProxy: trustProxyEnv(env),
    rateLimit: rateLimitEnv(env),
    maxLeaderboardLimit: intEnv(env, 'ZW_MAX_LEADERBOARD_LIMIT', 100),
    maxSessions: intEnv(env, 'ZW_MAX_SESSIONS', 10_000),
  };
}
```

- [ ] **Step 9: 安装依赖并确认类型检查通过**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server && npm install
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server && npx tsc -p tsconfig.json --noEmit
```

Expected: `npm install` 成功，`node_modules/better-sqlite3` 存在且原生模块编译完成；`tsc` 无输出、退出码 0（此时 `src/` 只有 `types.ts`、`config.ts`、`lib/http.ts`、`lib/rate-limit.ts`，它们互不缺依赖）。

- [ ] **Step 10: 提交仓库骨架**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server add \
  .gitignore .env.example package.json package-lock.json \
  tsconfig.json tsconfig.test.json vitest.config.ts \
  src/types.ts src/config.ts src/lib/http.ts src/lib/rate-limit.ts
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server commit \
  -m "chore: scaffold zombiewar-server repository"
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server status --short
```

Expected: 提交成功；`status --short` 不列出 `node_modules/`、`dist/`、`data/`。

---

### Task 2: SQLite 打开与迁移

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/db.ts`

**Interfaces:**
- Consumes: 无（只依赖 `better-sqlite3`）。
- Produces：`type Db = import('better-sqlite3').Database`、`const SCHEMA_VERSION = 1`、`migrate(db: Db): void`、`openDatabase(dbPath: string): Db`、`closeDatabase(db: Db): void`。

- [ ] **Step 1: 写 src/lib/db.ts**

```ts
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

import SqliteDatabase from 'better-sqlite3';
import type { Database as SqliteHandle } from 'better-sqlite3';

/**
 * SQLite instead of htz-server's pure in-memory stores.
 *
 * Leaderboards cannot be lost on restart, and they need "sort by value, take
 * each player's best, page through it" — which is one SQL statement and a
 * hand-rolled index otherwise. A single file is still zero operations.
 */
export type Db = SqliteHandle;

export const SCHEMA_VERSION = 1;

/**
 * Idempotent schema creation. There is exactly one version today, so there is
 * no migration ladder yet; `user_version` is stamped so the next schema change
 * has somewhere to branch from.
 */
export function migrate(db: Db): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS players (
      player_id  TEXT PRIMARY KEY,
      device_id  TEXT UNIQUE NOT NULL,
      nickname   TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      last_seen  INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS scores (
      id         INTEGER PRIMARY KEY,
      board      TEXT NOT NULL,
      season     INTEGER NOT NULL,
      player_id  TEXT NOT NULL,
      room_id    TEXT NOT NULL,
      value      INTEGER NOT NULL,
      extra      TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_scores_rank ON scores(board, season, value DESC);
  `);
  db.pragma(`user_version = ${SCHEMA_VERSION}`);
}

/**
 * Opens (creating the parent directory if needed), sets pragmas and migrates.
 * Pass ':memory:' for a throwaway database — that is what the test suite uses,
 * so no suite can leave state behind for the next one.
 */
export function openDatabase(dbPath: string): Db {
  if (dbPath !== ':memory:') mkdirSync(dirname(dbPath), { recursive: true });
  const db = new SqliteDatabase(dbPath);
  // WAL keeps a leaderboard read from blocking the room server's score write.
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  migrate(db);
  return db;
}

export function closeDatabase(db: Db): void {
  db.close();
}
```

- [ ] **Step 2: 用一次性脚本确认迁移产出的表与索引**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server && npx tsx -e "
import { openDatabase } from './src/lib/db.ts';
const db = openDatabase(':memory:');
console.log(JSON.stringify(db.prepare(\"SELECT name, type FROM sqlite_master ORDER BY name\").all()));
console.log(JSON.stringify(db.pragma('user_version')));
db.close();
"
```

Expected: 第一行包含 `{\"name\":\"idx_scores_rank\",\"type\":\"index\"}`、`{\"name\":\"players\",\"type\":\"table\"}`、`{\"name\":\"scores\",\"type\":\"table\"}`；第二行为 `[{"user_version":1}]`。

- [ ] **Step 3: 提交**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server add src/lib/db.ts
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server commit \
  -m "feat: add sqlite storage and schema migration"
```

Expected: 提交成功，只包含 `src/lib/db.ts`。

---
### Task 3: 匿名设备身份与 auth 路由

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/sessions.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/routes/auth.ts`

**Interfaces:**
- Consumes: `Db`（Task 2）、`badRequest(code, message, details?)`（Task 1）。
- Produces:
  - `sessions.ts`：`const AUTH_MODE = 'anonymous_device'`、`const NICKNAME_MIN_LENGTH = 2`、`const NICKNAME_MAX_LENGTH = 12`、`const NICKNAME_BLOCKLIST: readonly string[]`、`normalizeNickname(raw: unknown): string`、`normalizeDeviceId(raw: unknown): string`、`interface PlayerSession { token: string; playerId: string; deviceId: string; nickname: string; createdAt: number; lastSeenAt: number }`、`interface SessionStoreOptions { db: Db; maxSessions: number; now?: () => number }`、`class SessionStore { constructor(options: SessionStoreOptions); get size(): number; authenticateDevice(deviceId: string, nickname: string): PlayerSession; resolve(token: string | undefined): PlayerSession | undefined; revoke(token: string): boolean }`、`extractBearerToken(headers: { authorization?: string | undefined; 'x-player-token'?: string | string[] | undefined }): string | undefined`。
  - `routes/auth.ts`：`interface AuthRoutesOptions extends FastifyPluginOptions { sessions: SessionStore }`、`authRoutes(app: FastifyInstance, options: AuthRoutesOptions): Promise<void>`，挂载 `POST /api/auth/anon`、`GET /api/auth/me`、`DELETE /api/auth/anon`。
- **下游约定（S2 必须遵守）**：`NICKNAME_MIN_LENGTH` / `NICKNAME_MAX_LENGTH` / `NICKNAME_BLOCKLIST` / `normalizeNickname` 在全仓库只有这一份实现。S2 的 `src/lib/rooms.ts` 用 `export { NICKNAME_MIN_LENGTH, NICKNAME_MAX_LENGTH, normalizeNickname } from './sessions.js';` 再导出，让 `room_hub.ts` / `routes/rooms.ts` 的 import 路径不变；`set_nickname` 帧与 `POST /api/auth/anon` 因此永远给出同一个接受/拒绝结论。`normalizeNickname` 抛的是 `HttpError`（`invalid_nickname` / `nickname_blocked`），S2 的 `room_hub` catch 里要与 `RoomError` 一起识别并取 `code`。

- [ ] **Step 1: 写 src/lib/sessions.ts 的头部注释与校验函数**

```ts
import { randomBytes, randomUUID } from 'node:crypto';

import type { Db } from './db.js';
import { badRequest } from './http.js';

/**
 * ============================================================================
 *  THIS IS NOT AUTHENTICATION. READ BEFORE TRUSTING ANYTHING IN HERE.
 * ============================================================================
 *
 * `POST /api/auth/anon` exchanges a *client-generated device id* for a token.
 * There is no password, no registration, no verification. Anyone can send any
 * device id, including someone else's. A token proves exactly one thing: that
 * its holder called /api/auth/anon at some point.
 *
 * So why does it exist at all?
 *
 *   Because the *shape* of the interface is more expensive to change than its
 *   implementation. Every downstream endpoint, the client's request pipeline
 *   and the future game handshake all have to agree on "where does identity
 *   live in a request". Deciding that now — `Authorization: Bearer <token>` —
 *   costs one file. Retrofitting it later costs every endpoint and call site.
 *
 * When platform accounts arrive, the change is confined to this file plus the
 * body validation in routes/auth.ts. The header, the response shape and every
 * downstream endpoint stay byte-for-byte identical.
 *
 * The `authenticated: false` / `auth_mode` fields in the response are the
 * contract by which the Godot client learns this. The leaderboard panel keys
 * its "未认证" badge off `authenticated`, NOT off "I got a token back".
 */

export const AUTH_MODE = 'anonymous_device' as const;

export const NICKNAME_MIN_LENGTH = 2;
export const NICKNAME_MAX_LENGTH = 12;

/**
 * Substring blocklist, matched case-folded. Deliberately short: this is a
 * courtesy filter over a 12-character field, not moderation. Duplicates are
 * allowed — players are distinguished by player_id, never by nickname.
 */
export const NICKNAME_BLOCKLIST: readonly string[] = [
  'admin',
  'administrator',
  'root',
  'system',
  'moderator',
  'official',
  'null',
  'undefined',
  'fuck',
  'shit',
  '管理员',
  '客服',
  '官方',
];

/**
 * 2–12 characters, counted as code points rather than UTF-16 units, so
 * "僵尸猎人" is 4 characters and not 8. The Godot side counts the same way
 * (`String.length()` is code points), which is why both ends agree.
 */
export function normalizeNickname(raw: unknown): string {
  if (typeof raw !== 'string') {
    throw badRequest('invalid_body', 'nickname is required and must be a string');
  }
  const nickname = raw.trim();
  const length = [...nickname].length;
  if (length < NICKNAME_MIN_LENGTH || length > NICKNAME_MAX_LENGTH) {
    throw badRequest(
      'invalid_nickname',
      `nickname must be ${NICKNAME_MIN_LENGTH}-${NICKNAME_MAX_LENGTH} characters, got ${length}`,
    );
  }
  // Control characters would corrupt logs and any UI that renders the roster.
  if (/[\u0000-\u001f\u007f]/.test(nickname)) {
    throw badRequest('invalid_nickname', 'nickname must not contain control characters');
  }
  const folded = nickname.toLowerCase();
  if (NICKNAME_BLOCKLIST.some((word) => folded.includes(word))) {
    throw badRequest('nickname_blocked', 'nickname contains a blocked word');
  }
  return nickname;
}

/**
 * The client generates a UUIDv4 on first run and stores it in
 * `user://identity.cfg`. We only shape-check it: it is a stable handle, not a
 * credential, and pretending otherwise would be the lie this file exists to
 * avoid.
 */
export function normalizeDeviceId(raw: unknown): string {
  if (typeof raw !== 'string') {
    throw badRequest('invalid_body', 'device_id is required and must be a string');
  }
  const deviceId = raw.trim().toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(deviceId)) {
    throw badRequest('invalid_device_id', 'device_id must be a lowercase UUID (36 characters)');
  }
  return deviceId;
}
```

- [ ] **Step 2: 在同一文件追加 SessionStore 与 extractBearerToken**

```ts
export interface PlayerSession {
  /** Opaque bearer token. Not signed, not encrypted, not verifiable offline. */
  token: string;
  /** Durable across reinstalls of the token, keyed by device_id in SQLite. */
  playerId: string;
  deviceId: string;
  nickname: string;
  createdAt: number;
  lastSeenAt: number;
}

export interface SessionStoreOptions {
  db: Db;
  /** Hard cap on live sessions; oldest are evicted past this. */
  maxSessions: number;
  now?: () => number;
}

export class SessionStore {
  private readonly byToken = new Map<string, PlayerSession>();
  private readonly db: Db;
  private readonly now: () => number;
  readonly maxSessions: number;

  constructor(options: SessionStoreOptions) {
    this.db = options.db;
    this.maxSessions = options.maxSessions;
    this.now = options.now ?? Date.now;
  }

  get size(): number {
    return this.byToken.size;
  }

  /**
   * Upserts the player row and mints a fresh token.
   *
   * Same device_id -> same player_id, forever: that is the whole point of
   * persisting `players`, and it is what makes a leaderboard entry survive the
   * app being closed. The token, by contrast, is per-call and lives only in
   * memory — a restart of the server signs everyone out, which is correct for
   * something that is not authentication.
   */
  authenticateDevice(deviceId: string, nickname: string): PlayerSession {
    this.evictIfFull();
    const ts = this.now();
    const existing = this.db
      .prepare('SELECT player_id FROM players WHERE device_id = ?')
      .get(deviceId) as { player_id: string } | undefined;
    const playerId = existing === undefined ? randomUUID() : existing.player_id;
    if (existing === undefined) {
      this.db
        .prepare(
          'INSERT INTO players (player_id, device_id, nickname, created_at, last_seen) ' +
            'VALUES (?, ?, ?, ?, ?)',
        )
        .run(playerId, deviceId, nickname, ts, ts);
    } else {
      this.db
        .prepare('UPDATE players SET nickname = ?, last_seen = ? WHERE player_id = ?')
        .run(nickname, ts, playerId);
    }
    const session: PlayerSession = {
      // Deliberately NOT a JWT: a signed token with no key management, no
      // rotation and no audience checks is not security, it just looks like it.
      token: randomBytes(32).toString('base64url'),
      playerId,
      deviceId,
      nickname,
      createdAt: ts,
      lastSeenAt: ts,
    };
    this.byToken.set(session.token, session);
    return session;
  }

  /** Resolves a bearer token. Returns undefined for unknown/absent tokens. */
  resolve(token: string | undefined): PlayerSession | undefined {
    if (token === undefined || token === '') return undefined;
    const session = this.byToken.get(token);
    if (session === undefined) return undefined;
    session.lastSeenAt = this.now();
    return session;
  }

  revoke(token: string): boolean {
    return this.byToken.delete(token);
  }

  /** Map iteration order is insertion order, so the first key is the oldest. */
  private evictIfFull(): void {
    while (this.byToken.size >= this.maxSessions) {
      const oldest = this.byToken.keys().next();
      if (oldest.done === true) return;
      this.byToken.delete(oldest.value);
    }
  }
}

/**
 * Extracts a bearer token from `Authorization: Bearer <token>`.
 * Also accepts `X-Player-Token` for clients that cannot set Authorization.
 */
export function extractBearerToken(headers: {
  authorization?: string | undefined;
  'x-player-token'?: string | string[] | undefined;
}): string | undefined {
  const auth = headers.authorization;
  if (typeof auth === 'string') {
    const match = /^Bearer\s+(.+)$/i.exec(auth.trim());
    if (match !== null) {
      const token = match[1]!.trim();
      if (token !== '') return token;
    }
  }
  const alt = headers['x-player-token'];
  const altValue = Array.isArray(alt) ? alt[0] : alt;
  if (typeof altValue === 'string' && altValue.trim() !== '') return altValue.trim();
  return undefined;
}
```

- [ ] **Step 3: 写 src/routes/auth.ts**

```ts
import type { FastifyInstance, FastifyPluginOptions, FastifyRequest } from 'fastify';

import { badRequest } from '../lib/http.js';
import {
  AUTH_MODE,
  normalizeDeviceId,
  normalizeNickname,
  type SessionStore,
} from '../lib/sessions.js';

export interface AuthRoutesOptions extends FastifyPluginOptions {
  sessions: SessionStore;
}

function bodyObject(request: FastifyRequest): Record<string, unknown> {
  const raw = request.body;
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw badRequest('invalid_body', 'request body must be a JSON object');
  }
  return raw as Record<string, unknown>;
}

export async function authRoutes(
  app: FastifyInstance,
  options: AuthRoutesOptions,
): Promise<void> {
  const { sessions } = options;

  /**
   * POST /api/auth/anon — exchange a device id + nickname for a bearer token.
   *
   * !! NOT AUTHENTICATION !! See src/lib/sessions.ts. The client MUST render
   * "未认证" based on the `authenticated` field below, never on the presence of
   * a token.
   */
  app.post('/api/auth/anon', async (request, reply) => {
    const body = bodyObject(request);
    const deviceId = normalizeDeviceId(body['device_id']);
    const nickname = normalizeNickname(body['nickname']);
    const session = sessions.authenticateDevice(deviceId, nickname);

    request.log.info(
      { player_id: session.playerId, nickname: session.nickname },
      'issued anonymous device token (not authentication)',
    );

    return reply.code(201).send({
      player_id: session.playerId,
      token: session.token,
      nickname: session.nickname,
      authenticated: false,
      auth_mode: AUTH_MODE,
      usage: 'send as: Authorization: Bearer <token>',
    });
  });

  /**
   * GET /api/auth/me — what the server makes of the caller's token.
   * Never 401s: an absent or unknown token is a legitimate state today.
   */
  app.get('/api/auth/me', async (request) => {
    const session = request.playerSession;
    if (session === null) {
      return { authenticated: false, auth_mode: AUTH_MODE, token_recognised: false, player: null };
    }
    return {
      // Still false: a device-id claim is not proof of identity.
      authenticated: false,
      auth_mode: AUTH_MODE,
      token_recognised: true,
      player: {
        player_id: session.playerId,
        nickname: session.nickname,
        created_at: session.createdAt,
      },
    };
  });

  /** Lets a client drop its token on sign-out. Idempotent. */
  app.delete('/api/auth/anon', async (request, reply) => {
    const session = request.playerSession;
    if (session !== null) sessions.revoke(session.token);
    return reply.code(204).send();
  });
}
```

`request.playerSession` 由 Task 6 的 `app.ts` 通过 `declare module 'fastify'` 声明并在 `onRequest` 钩子里赋值。本任务结束时 `npx tsc` 会因缺少该声明报错，属预期，Task 6 完成后消失。

- [ ] **Step 4: 局部验证身份存储的 upsert 语义**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server && npx tsx -e "
import { openDatabase } from './src/lib/db.ts';
import { SessionStore, normalizeNickname } from './src/lib/sessions.ts';
const db = openDatabase(':memory:');
const store = new SessionStore({ db, maxSessions: 10 });
const a = store.authenticateDevice('11111111-1111-4111-8111-111111111111', normalizeNickname('阿波'));
const b = store.authenticateDevice('11111111-1111-4111-8111-111111111111', normalizeNickname('阿波2'));
console.log('same_player_id', a.playerId === b.playerId);
console.log('different_token', a.token !== b.token);
console.log('rows', db.prepare('SELECT COUNT(*) AS n FROM players').get());
console.log('nickname', db.prepare('SELECT nickname FROM players').get());
db.close();
"
```

Expected:
```
same_player_id true
different_token true
rows { n: 1 }
nickname { nickname: '阿波2' }
```

- [ ] **Step 5: 提交**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server add \
  src/lib/sessions.ts src/routes/auth.ts
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server commit \
  -m "feat: add anonymous device identity and auth routes"
```

Expected: 提交成功，只包含这两个文件。

---

### Task 4: 榜单读取、交叉验证与内部写入

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/leaderboard.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/routes/leaderboard.ts`

**Interfaces:**
- Consumes: `Db`（Task 2）、`BoardId`、`BOARD_IDS`、`CURRENT_SEASON`、`LeaderboardEntry`（Task 1）、`badRequest`、`unauthorized`、`getInt`（Task 1）、`AUTH_MODE`（Task 3）。
- Produces:
  - `leaderboard.ts`：`const MAX_TEAM_WAVE = 200`、`const MAX_ZOMBIES_PER_WAVE = 16`、`const MIN_MATCH_DURATION_MS = 30_000`、`const MIN_PLAYERS_FOR_RANKING = 2`、`maxKillsForWave(teamWave: number): number`、`readLeaderboard(db: Db, board: BoardId, season: number, limit: number, offset: number): LeaderboardEntry[]`、`readTeamLeaderboard(db: Db, season: number, limit: number, offset: number): Array<LeaderboardEntry & { members: string[] }>`、`countLeaderboard(db: Db, board: BoardId, season: number): number`、`readPlayerBest(db: Db, board: BoardId, season: number, playerId: string): LeaderboardEntry | null`、`interface MatchSlot { slot: number; player_id: string }`、`interface MatchReport { player_id: string; team_wave: number; player_kills: Record<string, number> }`、`type VoteStatus = 'accepted' | 'no_majority' | 'too_few_players' | 'too_short' | 'out_of_range'`、`interface VoteResult { status: VoteStatus; team_wave: number; player_kills: Record<string, number>; dissenters: string[]; reason: string }`、`crossValidateReports(reports: MatchReport[], slotPlayerIds: string[], durationMs: number): VoteResult`、`interface MatchLogger { warn(payload: Record<string, unknown>, message: string): void; error(payload: Record<string, unknown>, message: string): void }`、`interface SubmitMatchOptions { roomId: string; season: number; slots: MatchSlot[]; reports: MatchReport[]; durationMs: number; now?: () => number; logger?: MatchLogger }`、`type SubmitMatchResult = VoteResult & { written: number; persisted: boolean }`、`submitMatchResult(db: Db, options: SubmitMatchOptions): SubmitMatchResult`。
  - `routes/leaderboard.ts`：`interface LeaderboardRoutesOptions extends FastifyPluginOptions { db: Db; maxLimit: number }`、`leaderboardRoutes(app: FastifyInstance, options: LeaderboardRoutesOptions): Promise<void>`，挂载 `GET /api/leaderboard/:board`、`GET /api/leaderboard/:board/me`。
- **下游约定（S2 必须逐字对齐）**：写榜的唯一入口是 `submitMatchResult(db: Db, options: SubmitMatchOptions): SubmitMatchResult`，载荷字段一律 snake_case（`player_id` / `team_wave` / `player_kills`），与线上 `match_result` 帧同名。S2 的 `room_hub` 收齐结算时必须按 `room.members` 构造 `slots: [{ slot, player_id }]` 一并传入（没上报的席位也要写 `team_waves` 行），成功判定用 `result.status === 'accepted'`，被丢弃的上报读 `result.dissenters`（`player_id` 列表，需要 slot 时在 hub 内用 `slots` 反查），SQLite 写失败读 `result.persisted === false`，并把自己的 `app.log` 作为 `options.logger` 注入。**不存在** `recordMatchResults` / `MatchResultReport` / `MatchResultOutcome` / `rejectedSlots` 这些名字。

- [ ] **Step 1: 写 src/lib/leaderboard.ts 的常量与读取函数**

```ts
import type { BoardId, LeaderboardEntry } from '../types.js';
import type { Db } from './db.js';

/**
 * ============================================================================
 *  THERE IS NO PUBLIC SCORE SUBMISSION ENDPOINT.
 * ============================================================================
 *
 * `submitMatchResult()` below is the ONLY way a row enters `scores`, and it is
 * called in-process by the room server (S2) after a match ends. No route file
 * may import it. That is the entire anti-cheat foundation: a client that cannot
 * reach a write path cannot forge a score, whatever it does to its own memory.
 *
 * What a client CAN do is lie in its `match_result` report. That is what
 * `crossValidateReports()` is for: every client runs the same deterministic
 * simulation, so in a healthy match the reported numbers are byte-identical.
 * A single deviating client is discarded; a room with no majority is voided.
 *
 * A one-player room has nobody to cross-check against, so it is never written.
 * This is the unavoidable price of majority voting under anonymous identity,
 * and the client UI states it up front ("至少 2 人才能上榜").
 */

/** Nobody survives 200 waves. Anything past this is a forged report. */
export const MAX_TEAM_WAVE = 200;

/**
 * Kill ceiling per wave. Derived from the client's wave spawner, not invented:
 * scripts/gameplay/demo_arena.gd spawns `maximum_zombies_per_corner` (2) at each
 * of 4 corners per wave, so a wave can produce at most 8 zombies. The x2 is
 * headroom for future difficulty tuning; anything above it is a forged report.
 * If demo_arena.gd's spawn config changes, this MUST change with it.
 */
export const MAX_ZOMBIES_PER_WAVE = 16;

/** A "match" shorter than this cannot have produced a real wave count. */
export const MIN_MATCH_DURATION_MS = 30_000;

/** Fewer participants than this and nothing is written. */
export const MIN_PLAYERS_FOR_RANKING = 2;

export function maxKillsForWave(teamWave: number): number {
  return teamWave * MAX_ZOMBIES_PER_WAVE;
}

interface AggregateRow {
  player_id: string;
  nickname: string;
  value: number;
  created_at: number;
}

/**
 * One row per player: their single best score on this board and season.
 *
 * `s.created_at` is a bare column beside `MAX(s.value)`. In SQLite — and only
 * SQLite — that is defined behaviour: with a min/max aggregate, bare columns
 * take their values from the row that produced the extreme. So `created_at` is
 * the timestamp OF the best run, not of an arbitrary one, which is what the
 * tie-break below needs to be stable.
 */
export function readLeaderboard(
  db: Db,
  board: BoardId,
  season: number,
  limit: number,
  offset: number,
): LeaderboardEntry[] {
  const rows = db
    .prepare(
      `SELECT s.player_id              AS player_id,
              COALESCE(p.nickname, '') AS nickname,
              MAX(s.value)             AS value,
              s.created_at             AS created_at
         FROM scores s
         LEFT JOIN players p ON p.player_id = s.player_id
        WHERE s.board = ? AND s.season = ?
        GROUP BY s.player_id
        ORDER BY value DESC, created_at ASC, player_id ASC
        LIMIT ? OFFSET ?`,
    )
    .all(board, season, limit, offset) as AggregateRow[];
  return rows.map((row, index) => ({
    rank: offset + index + 1,
    player_id: row.player_id,
    nickname: row.nickname,
    value: row.value,
    created_at: row.created_at,
  }));
}

/**
 * U+001F. A nickname can never contain it: normalizeNickname() rejects control
 * characters, so it is the one separator GROUP_CONCAT cannot collide with.
 */
const MEMBER_SEPARATOR = String.fromCharCode(31);

/**
 * The `team_waves` board rendered as what it actually is: a TEAM board.
 *
 * `scores` still carries one `team_waves` row per participant — `/me` needs a
 * row keyed by player_id to answer "my rank" — but reading that table with
 * readLeaderboard() would put four identical rows on the public board for a
 * single 4-player run, with no way to tell one team's run from four solo ones.
 * So the public read groups by `room_id`: one row per match, with every
 * member's nickname joined into `nickname` for display and kept verbatim in
 * `members`. `player_id` carries the room id here — it is the identity of the
 * row, and the client only uses it as an opaque key.
 */
export function readTeamLeaderboard(
  db: Db,
  season: number,
  limit: number,
  offset: number,
): Array<LeaderboardEntry & { members: string[] }> {
  const rows = db
    .prepare(
      `SELECT s.room_id    AS room_id,
              MAX(s.value) AS value,
              s.created_at AS created_at,
              GROUP_CONCAT(COALESCE(p.nickname, ''), char(31)) AS members
         FROM scores s
         LEFT JOIN players p ON p.player_id = s.player_id
        WHERE s.board = 'team_waves' AND s.season = ?
        GROUP BY s.room_id
        ORDER BY value DESC, created_at ASC, room_id ASC
        LIMIT ? OFFSET ?`,
    )
    .all(season, limit, offset) as Array<{
    room_id: string;
    value: number;
    created_at: number;
    members: string | null;
  }>;
  return rows.map((row, index) => {
    const members = (row.members ?? '')
      .split(MEMBER_SEPARATOR)
      .filter((name) => name !== '');
    return {
      rank: offset + index + 1,
      player_id: row.room_id,
      nickname: members.join('、'),
      value: row.value,
      created_at: row.created_at,
      members,
    };
  });
}

/**
 * How many rows the board has in total, so the client can tell "this page is
 * full" from "there is a next page". Without it a panel showing exactly
 * PAGE_SIZE entries has to guess, and guessing wrong lands the player on an
 * empty page that looks identical to an empty leaderboard.
 *
 * Counts the same unit each board is rendered in: rooms for the team board,
 * players for the kills board.
 */
export function countLeaderboard(db: Db, board: BoardId, season: number): number {
  const column = board === 'team_waves' ? 'room_id' : 'player_id';
  const row = db
    .prepare(
      `SELECT COUNT(DISTINCT ${column}) AS n FROM scores WHERE board = ? AND season = ?`,
    )
    .get(board, season) as { n: number };
  return row.n;
}

/**
 * This player's best score plus its rank. The "ahead of me" predicate mirrors
 * the ORDER BY in readLeaderboard exactly — value first, then earlier timestamp
 * wins, then player_id — so the rank reported here is the row number the player
 * would occupy in the paged list.
 */
export function readPlayerBest(
  db: Db,
  board: BoardId,
  season: number,
  playerId: string,
): LeaderboardEntry | null {
  const best = db
    .prepare(
      `SELECT MAX(value) AS value, created_at AS created_at
         FROM scores
        WHERE board = ? AND season = ? AND player_id = ?`,
    )
    .get(board, season, playerId) as { value: number | null; created_at: number | null } | undefined;
  if (best === undefined || best.value === null || best.created_at === null) return null;

  const ahead = db
    .prepare(
      `SELECT COUNT(*) AS ahead FROM (
          SELECT player_id AS pid, MAX(value) AS best, created_at AS at
            FROM scores
           WHERE board = ? AND season = ?
           GROUP BY player_id
       )
       WHERE best > ?
          OR (best = ? AND (at < ? OR (at = ? AND pid < ?)))`,
    )
    .get(board, season, best.value, best.value, best.created_at, best.created_at, playerId) as {
    ahead: number;
  };

  const player = db
    .prepare('SELECT nickname FROM players WHERE player_id = ?')
    .get(playerId) as { nickname: string } | undefined;

  return {
    rank: ahead.ahead + 1,
    player_id: playerId,
    nickname: player === undefined ? '' : player.nickname,
    value: best.value,
    created_at: best.created_at,
  };
}
```

- [ ] **Step 2: 在同一文件追加多数投票交叉验证**

```ts
/** One occupied seat in the finished match. `slot` is 0-based, as in-game. */
export interface MatchSlot {
  slot: number;
  player_id: string;
}

/**
 * One client's `match_result` upload. `player_kills` is keyed by slot index
 * rendered as a decimal string, because that is what JSON object keys are.
 */
export interface MatchReport {
  player_id: string;
  team_wave: number;
  player_kills: Record<string, number>;
}

export type VoteStatus =
  | 'accepted'
  | 'no_majority'
  | 'too_few_players'
  | 'too_short'
  | 'out_of_range';

export interface VoteResult {
  status: VoteStatus;
  team_wave: number;
  player_kills: Record<string, number>;
  /** player_ids whose report disagreed with the majority. Sorted, deduped. */
  dissenters: string[];
  reason: string;
}

/** Stable string form of a report's payload, so identical reports hash equal. */
function reportKey(report: MatchReport): string {
  const slots = Object.keys(report.player_kills).sort((a, b) => Number(a) - Number(b));
  const kills = slots.map((slot) => `${slot}:${report.player_kills[slot] ?? 0}`);
  return `w=${report.team_wave}|k=${kills.join(',')}`;
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0;
}

function voided(status: VoteStatus, reason: string, dissenters: string[] = []): VoteResult {
  return { status, team_wave: 0, player_kills: {}, dissenters, reason };
}

/**
 * Majority vote over the clients' reports, then server-side sanity caps.
 *
 * The order matters and is taken from the design: vote FIRST, cap SECOND. A cap
 * applied before the vote would let one liar with an in-range number drag the
 * whole room into an argument the vote is there to settle.
 *
 * The quorum is over SEATS, not over uploads, and that distinction is the whole
 * anti-cheat foundation. Three ways a per-upload tally loses to a single liar,
 * all of them closed here:
 *
 *   1. Only one client uploads in a 2-player room. Per-upload, that one report
 *      is "unanimous" and writes the whole room's scores unverified. Here it is
 *      one ballot, below MIN_PLAYERS_FOR_RANKING, so the match is voided.
 *   2. One client uploads the same forged report three times in a 4-player
 *      room and manufactures a 3-vs-1 majority. Here one seat casts one ballot;
 *      the first upload from a seat wins and the rest are dropped. (The dedupe
 *      has to live here, not in the room server: this function is the only
 *      thing standing between an upload and a row in `scores`.)
 *   3. A `player_id` that never sat in this match uploads a report. Here it is
 *      not in `slots`, so it is not counted at all.
 *
 * "Majority" is strict and measured against the number of seats: a winner needs
 * more than half of the room to agree, and never fewer than two clients. Two
 * clients that disagree therefore produce no majority — with two votes and no
 * tiebreaker there is no evidence.
 */
export function crossValidateReports(
  reports: MatchReport[],
  slotPlayerIds: string[],
  durationMs: number,
): VoteResult {
  const playerCount = slotPlayerIds.length;
  if (playerCount < MIN_PLAYERS_FOR_RANKING) {
    return voided(
      'too_few_players',
      `a ${playerCount}-player room has nothing to cross-check against; ` +
        `${MIN_PLAYERS_FOR_RANKING} players are required to rank`,
    );
  }
  if (durationMs < MIN_MATCH_DURATION_MS) {
    return voided('too_short', `match lasted ${durationMs}ms, below ${MIN_MATCH_DURATION_MS}ms`);
  }
  if (reports.length === 0) {
    return voided('no_majority', 'no client reported a result');
  }

  const seatIds = new Set(slotPlayerIds);
  const byPlayer = new Map<string, MatchReport>();
  for (const report of reports) {
    if (!seatIds.has(report.player_id)) continue; // non-participant
    if (byPlayer.has(report.player_id)) continue; // one vote per seat, first wins
    byPlayer.set(report.player_id, report);
  }
  const ballots = [...byPlayer.values()];
  if (ballots.length < MIN_PLAYERS_FOR_RANKING) {
    return voided(
      'no_majority',
      `only ${ballots.length} of ${playerCount} seats reported; ` +
        `${MIN_PLAYERS_FOR_RANKING} independent reports are required to cross-check`,
    );
  }

  const tally = new Map<string, { count: number; report: MatchReport }>();
  for (const report of ballots) {
    const key = reportKey(report);
    const bucket = tally.get(key);
    if (bucket === undefined) tally.set(key, { count: 1, report });
    else bucket.count += 1;
  }

  let winnerKey = '';
  let winner: MatchReport | null = null;
  let winnerCount = 0;
  for (const [key, bucket] of tally) {
    if (bucket.count > winnerCount) {
      winnerKey = key;
      winner = bucket.report;
      winnerCount = bucket.count;
    }
  }
  if (winner === null || winnerCount * 2 <= playerCount || winnerCount < MIN_PLAYERS_FOR_RANKING) {
    // No dissenters on purpose. The match is voided, so nobody was outvoted —
    // there is no reference to have deviated from. Naming every honest client
    // here would poison the audit trail S2 logs to find tampering.
    return voided(
      'no_majority',
      `no strict majority among ${ballots.length} reports from ${playerCount} seats ` +
        `(best agreement was ${winnerCount}); nobody is singled out because there is ` +
        `no reference to deviate from`,
    );
  }

  const dissenters = [
    ...new Set(
      ballots.filter((report) => reportKey(report) !== winnerKey).map((report) => report.player_id),
    ),
  ].sort();

  const teamWave = winner.team_wave;
  if (!Number.isInteger(teamWave) || teamWave < 1 || teamWave > MAX_TEAM_WAVE) {
    return voided('out_of_range', `team_wave ${teamWave} is outside 1..${MAX_TEAM_WAVE}`, dissenters);
  }
  const killCap = maxKillsForWave(teamWave);
  for (const [slot, kills] of Object.entries(winner.player_kills)) {
    if (!isNonNegativeInteger(kills) || kills > killCap) {
      return voided(
        'out_of_range',
        `slot ${slot} reported ${String(kills)} kills, outside 0..${killCap} for wave ${teamWave}`,
        dissenters,
      );
    }
  }

  return {
    status: 'accepted',
    team_wave: teamWave,
    player_kills: { ...winner.player_kills },
    dissenters,
    reason:
      dissenters.length === 0
        ? 'unanimous'
        : `majority of ${winnerCount}/${ballots.length}; discarded ${dissenters.length} deviating report(s)`,
  };
}
```

- [ ] **Step 3: 在同一文件追加内部写入函数**

```ts
/**
 * Just enough of pino's shape for the room server to pass `app.log` straight in
 * without this file importing fastify. Unit tests pass a recording stub.
 */
export interface MatchLogger {
  warn(payload: Record<string, unknown>, message: string): void;
  error(payload: Record<string, unknown>, message: string): void;
}

export interface SubmitMatchOptions {
  roomId: string;
  season: number;
  slots: MatchSlot[];
  reports: MatchReport[];
  durationMs: number;
  now?: () => number;
  /**
   * Injected by the room server (S2). Omitted in unit tests.
   *
   * The seam exists NOW rather than in S2 because the design requires three
   * things to be logged — a discarded deviating report, a voided match, and a
   * failed SQLite write — and all three are decided inside this function. Adding
   * the parameter later would change this signature after S2 has consumed it.
   */
  logger?: MatchLogger;
}

export type SubmitMatchResult = VoteResult & {
  /** Rows inserted into `scores`. Zero whenever nothing was persisted. */
  written: number;
  /**
   * False when the vote failed OR the write threw. The room server broadcasts
   * 「成绩未保存」 off this, and a SQLite failure must never take the process
   * down with it — a lost leaderboard row is not worth ending everyone's match.
   */
  persisted: boolean;
};

/**
 * INTERNAL. Called by the room server after a match ends. No HTTP route may
 * import this — see the header of this file, and test/no-public-submit.test.ts,
 * which fails the build if a route ever does.
 *
 * The team wave is written under EVERY participating player_id — including
 * seats that never uploaded a report. `team_waves` is a team achievement, and
 * `/me` answers "my best run" from these per-player rows; the PUBLIC team board
 * then groups them back by `room_id` (readTeamLeaderboard) so one match shows as
 * one row. Both reads are served by the same rows, which is why they are written
 * per participant rather than once per room.
 *
 * `extra` carries the slot (and, on the kills board, the wave) as JSON so a
 * later audit can reconstruct the match without a second table.
 */
export function submitMatchResult(db: Db, options: SubmitMatchOptions): SubmitMatchResult {
  const now = options.now ?? Date.now;
  const vote = crossValidateReports(
    options.reports,
    options.slots.map((slot) => slot.player_id),
    options.durationMs,
  );
  if (vote.status !== 'accepted') {
    options.logger?.warn(
      { room_id: options.roomId, status: vote.status, dissenters: vote.dissenters },
      `match voided: ${vote.reason}`,
    );
    return { ...vote, written: 0, persisted: false };
  }
  if (vote.dissenters.length > 0) {
    // The design's words: 该客户端可能已不同步或被篡改. Either way it is worth a
    // line in the log — a client that deviates twice is a lead, not noise.
    options.logger?.warn(
      { room_id: options.roomId, dissenters: vote.dissenters },
      'discarded deviating match reports',
    );
  }

  const ts = now();
  try {
    return { ...vote, written: writeScores(db, options, vote, ts), persisted: true };
  } catch (error: unknown) {
    // A full disk or a locked database must not throw out of the room server:
    // the match is over either way, and the players deserve to be told the
    // score was lost rather than to have the process die under them.
    options.logger?.error(
      { room_id: options.roomId, err: error },
      'sqlite write failed; scores not saved',
    );
    return { ...vote, written: 0, persisted: false };
  }
}

/**
 * The transaction itself, extracted so that `db.prepare()` is INSIDE the caller's
 * try/catch. better-sqlite3 prepares eagerly, so a missing or corrupted `scores`
 * table throws at prepare time, not at run time — leaving it outside the try
 * would let exactly the failure we are guarding against escape.
 */
function writeScores(
  db: Db,
  options: SubmitMatchOptions,
  vote: VoteResult,
  ts: number,
): number {
  const insert = db.prepare(
    'INSERT INTO scores (board, season, player_id, room_id, value, extra, created_at) ' +
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
  );
  const writeAll = db.transaction((slots: MatchSlot[]): number => {
    let written = 0;
    for (const slot of slots) {
      insert.run(
        'team_waves',
        options.season,
        slot.player_id,
        options.roomId,
        vote.team_wave,
        JSON.stringify({ slot: slot.slot }),
        ts,
      );
      written += 1;
      const kills = vote.player_kills[String(slot.slot)] ?? 0;
      insert.run(
        'player_kills',
        options.season,
        slot.player_id,
        options.roomId,
        kills,
        JSON.stringify({ slot: slot.slot, team_wave: vote.team_wave }),
        ts,
      );
      written += 1;
    }
    return written;
  });

  return writeAll(options.slots);
}
```

- [ ] **Step 4: 写 src/routes/leaderboard.ts**

```ts
import type { FastifyInstance, FastifyPluginOptions } from 'fastify';

import type { Db } from '../lib/db.js';
import { badRequest, getInt, unauthorized } from '../lib/http.js';
import {
  countLeaderboard,
  MIN_PLAYERS_FOR_RANKING,
  readLeaderboard,
  readPlayerBest,
  readTeamLeaderboard,
} from '../lib/leaderboard.js';
import { AUTH_MODE } from '../lib/sessions.js';
import { BOARD_IDS, CURRENT_SEASON, type BoardId } from '../types.js';

export interface LeaderboardRoutesOptions extends FastifyPluginOptions {
  db: Db;
  maxLimit: number;
}

function boardFrom(params: unknown): BoardId {
  const raw = (params as { board?: unknown }).board;
  if (typeof raw !== 'string' || !(BOARD_IDS as readonly string[]).includes(raw)) {
    throw badRequest('invalid_board', `board must be one of: ${BOARD_IDS.join(', ')}`);
  }
  return raw as BoardId;
}

/**
 * READ-ONLY, on purpose. There is no POST here and there must never be one:
 * scores enter through lib/leaderboard.ts submitMatchResult(), which the room
 * server calls in-process.
 */
export async function leaderboardRoutes(
  app: FastifyInstance,
  options: LeaderboardRoutesOptions,
): Promise<void> {
  const { db, maxLimit } = options;

  app.get('/api/leaderboard/:board', async (request) => {
    const board = boardFrom(request.params);
    const query = request.query as Record<string, unknown>;
    const season = getInt(query, 'season', { min: 0, max: 9999, default: CURRENT_SEASON }) ?? CURRENT_SEASON;
    const limit = getInt(query, 'limit', { min: 1, max: maxLimit, default: maxLimit }) ?? maxLimit;
    const offset = getInt(query, 'offset', { min: 0, max: 100_000, default: 0 }) ?? 0;
    return {
      board,
      season,
      limit,
      offset,
      /**
       * How many rows the board holds in total — rooms for `team_waves`,
       * players for `player_kills`. The client cannot page correctly without
       * it: "this page is exactly full" and "there is another page" are
       * different facts, and guessing lands the player on a blank page that
       * reads identically to an empty leaderboard.
       */
      total: countLeaderboard(db, board, season),
      // The client renders "未认证" off this, never off "I hold a token".
      authenticated: false,
      auth_mode: AUTH_MODE,
      min_players_for_ranking: MIN_PLAYERS_FOR_RANKING,
      /**
       * `team_waves` is a TEAM board, so it is read grouped by room: one row
       * per match with every member's nickname. `player_kills` is per player.
       * Both shapes satisfy `LeaderboardEntry`; the team rows carry an extra
       * `members` array the panel may use later.
       */
      entries:
        board === 'team_waves'
          ? readTeamLeaderboard(db, season, limit, offset)
          : readLeaderboard(db, board, season, limit, offset),
    };
  });

  /**
   * The one endpoint that requires a token today, regardless of ENFORCE_AUTH:
   * "my rank" has no meaning without a caller. It 401s rather than returning an
   * empty result, so the client can tell "not signed in" from "no score yet".
   *
   * Stays per-player for BOTH boards, including `team_waves`: the question is
   * "my best run", and the per-participant rows written by submitMatchResult()
   * are exactly what answers it. The rank here is therefore "among players",
   * while the public team board ranks "among rooms" — deliberately different
   * questions, which is why the panel labels this row 我的最佳 and not 名次.
   */
  app.get('/api/leaderboard/:board/me', async (request) => {
    const board = boardFrom(request.params);
    const session = request.playerSession;
    if (session === null) {
      throw unauthorized('unauthenticated', 'this endpoint requires Authorization: Bearer <token>');
    }
    const query = request.query as Record<string, unknown>;
    const season = getInt(query, 'season', { min: 0, max: 9999, default: CURRENT_SEASON }) ?? CURRENT_SEASON;
    return {
      board,
      season,
      authenticated: false,
      auth_mode: AUTH_MODE,
      min_players_for_ranking: MIN_PLAYERS_FOR_RANKING,
      entry: readPlayerBest(db, board, season, session.playerId),
    };
  });
}
```

- [ ] **Step 5: 局部验证投票三分支与取最佳**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server && npx tsx -e "
import { openDatabase } from './src/lib/db.ts';
import { crossValidateReports, readLeaderboard, readTeamLeaderboard, countLeaderboard, submitMatchResult } from './src/lib/leaderboard.ts';
const r = (id, w, k) => ({ player_id: id, team_wave: w, player_kills: k });
console.log('unanimous', crossValidateReports([r('a',7,{'0':10,'1':12}), r('b',7,{'0':10,'1':12})], ['a','b'], 60000).status);
console.log('one_deviant', JSON.stringify(crossValidateReports([r('a',7,{'0':10}), r('b',7,{'0':10}), r('c',9,{'0':99})], ['a','b','c'], 60000)));
console.log('split', crossValidateReports([r('a',7,{'0':10}), r('b',8,{'0':11})], ['a','b'], 60000).status);
console.log('solo', crossValidateReports([r('a',7,{'0':10})], ['a'], 60000).status);
console.log('one_reporter_of_two', crossValidateReports([r('a',7,{'0':10})], ['a','b'], 60000).status);
console.log('ballot_stuffing', crossValidateReports([r('a',99,{'0':1}), r('a',99,{'0':1}), r('a',99,{'0':1}), r('b',7,{'0':1}), r('c',7,{'0':1})], ['a','b','c'], 60000).team_wave);
console.log('outsider_ignored', JSON.stringify(crossValidateReports([r('a',7,{'0':1}), r('b',7,{'0':1}), r('x',99,{'0':1})], ['a','b'], 60000).dissenters));
console.log('over_wave', crossValidateReports([r('a',201,{'0':1}), r('b',201,{'0':1})], ['a','b'], 60000).status);
console.log('over_kills', crossValidateReports([r('a',2,{'0':33}), r('b',2,{'0':33})], ['a','b'], 60000).status);
console.log('too_short', crossValidateReports([r('a',7,{'0':10}), r('b',7,{'0':10})], ['a','b'], 1000).status);
const db = openDatabase(':memory:');
const slots = [{ slot: 0, player_id: 'a' }, { slot: 1, player_id: 'b' }];
submitMatchResult(db, { roomId: 'R1', season: 0, slots, reports: [r('a',5,{'0':10,'1':4}), r('b',5,{'0':10,'1':4})], durationMs: 60000, now: () => 1000 });
submitMatchResult(db, { roomId: 'R2', season: 0, slots, reports: [r('a',9,{'0':3,'1':40}), r('b',9,{'0':3,'1':40})], durationMs: 60000, now: () => 2000 });
console.log('kills_board', JSON.stringify(readLeaderboard(db, 'player_kills', 0, 10, 0)));
console.log('team_board', JSON.stringify(readTeamLeaderboard(db, 0, 10, 0).map((e) => [e.rank, e.player_id, e.value, e.members.length])));
console.log('totals', countLeaderboard(db, 'team_waves', 0), countLeaderboard(db, 'player_kills', 0));
db.close();
"
```

Expected:
```
unanimous accepted
one_deviant {"status":"accepted","team_wave":7,"player_kills":{"0":10},"dissenters":["c"],"reason":"majority of 2/3; discarded 1 deviating report(s)"}
split no_majority
solo too_few_players
one_reporter_of_two no_majority
ballot_stuffing 7
outsider_ignored []
over_wave out_of_range
over_kills out_of_range
too_short too_short
kills_board [{"rank":1,"player_id":"b","nickname":"","value":40,"created_at":2000},{"rank":2,"player_id":"a","nickname":"","value":10,"created_at":1000}]
team_board [[1,"R2",9,2],[2,"R1",5,2]]
totals 2 2
```

四行关键读法：

- `one_reporter_of_two` —— 2 人房只有 1 个客户端上报时**不写榜**。这是投票按席位计而不是按上报条数计的直接结果：一个人说了不算。
- `ballot_stuffing` —— 同一个 `player_id` 连发 3 份伪造上报，仍然只算 1 票，最终采信另外两人的 `7`。若按上报条数计票，这里会是 `99`。
- `outsider_ignored` —— 不在 `slots` 里的 `x` 连 `dissenters` 都进不去，因为它压根没有投票权。
- `kills_board` / `team_board` —— `b` 有两条击杀成绩（4 与 40）而个人榜上只出现一次且取 40；队伍榜按 `room_id` 分组，两场比赛两行，每行 2 名成员。

- [ ] **Step 6: 提交**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server add \
  src/lib/leaderboard.ts src/routes/leaderboard.ts
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server commit \
  -m "feat: add leaderboard reads, cross-validation and internal score writes"
```

Expected: 提交成功，只包含这两个文件。

---
### Task 5: 协议版本、opcode 号段与跨仓库 fixtures

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/PROTOCOL.md`（**只写「版本号」与「opcode 号段」两节 + fixtures 说明**；大厅消息表、心跳、HTTP 端点各节由 S2 Task 4 以 **Modify** 追加）
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/manifest.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/auth_anon_request.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/auth_anon_response.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/leaderboard_page.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/handshake.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/match_result.json`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/protocol/version.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/lib/protocol/opcodes.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/fixtures/protocol/`（从服务端复制）
- **不产出**：`src/lib/protocol.ts`（单文件版）、任何消息信封编解码。线格式的唯一权威是 S2 的扁平帧，`src/lib/protocol/lobby.ts` 由 S2 Task 4 创建。

**Interfaces:**
- Consumes: 无。
- Produces:
  - `protocol/PROTOCOL.md`：以 `PROTOCOL_VERSION = 1` 单独成行的形式声明版本号（单一事实源），并划定 opcode 号段、写死「握手强制版本校验」这条契约。
  - `src/lib/protocol/version.ts`：`const PROTOCOL_VERSION = 1`、`readProtocolVersionFromMarkdown(markdown: string): number`。
  - `src/lib/protocol/opcodes.ts`：`const OPCODE_LOBBY_MIN = 0x00`、`const OPCODE_LOBBY_MAX = 0x7f`、`const OPCODE_SYNC_MIN = 0x80`、`const OPCODE_SYNC_MAX = 0xff`、`isLobbyOpcode(opcode: number): boolean`、`isSyncOpcode(opcode: number): boolean`。
  - fixture 文件格式分两类，都带 `name`：
    - **HTTP 载荷样本**（`auth_anon_request` / `auth_anon_response` / `leaderboard_page`）：`{ "name": string, "type": string, "payload": object }`，`payload` 是 HTTP 请求体或响应体本身。
    - **WebSocket 帧样本**（`handshake` / `match_result`）：`{ "name": string, ...帧的全部字段 }` —— 逐字就是线上那一帧（扁平，无 `payload` 嵌套），因为 S2 的 `parseClientMessage()` 解析的正是这个形状，样本必须能直接喂给它。
    - `manifest.json` 为 `{ "protocol_version": number, "messages": string[] }`。
- **给 S2 的接力说明**：S2 Task 4 对 `PROTOCOL.md` 用 **Modify**（追加各节），对 `src/lib/protocol/` 用 **Create**（新增 `lobby.ts`）。两个 WebSocket 帧样本的编解码对拍属于 S2（`test/lobby_protocol.test.ts` 与客户端 `LobbyProtocol`），本计划只保证样本存在、版本号一致、清单不漏文件。

- [ ] **Step 1: 写 protocol/PROTOCOL.md**

````markdown
# zombiewar 协议

本目录是**协议的单一事实源**。服务端从 `src/lib/protocol/` 消费它，Godot 客户端从
`res://scripts/net/lobby_protocol.gd` 消费它的副本。两边各自跑对拍，靠共享的
`fixtures/` 保证不漂移。

不使用 git submodule：Godot 对 submodule 不友好，GDScript 也无法消费 TypeScript 类型。

> **本文件的分工**：S1 写下「版本号」「opcode 号段」「fixtures」三节与握手校验契约；
> S2 在此之后**追加**「大厅消息表」「心跳」「HTTP 端点」各节。S2 不重建本文件。

## 版本号

下面这一行是机器可读的。`src/lib/protocol/version.ts` 的 `PROTOCOL_VERSION` 必须与之
相等，`test/protocol.test.ts` 会在不等时让构建失败；客户端 `LobbyProtocol.PROTOCOL_VERSION`
同样必须与之相等，由客户端的一次性验证脚本对着 `fixtures/manifest.json` 校验。

PROTOCOL_VERSION = 1

### 握手强制版本校验（S2 实现，契约在此固定）

客户端连接时的第一帧必须携带 `protocol_version`。服务端 `room_hub.ts` 在处理这一帧的
任何其它字段之前先比对版本：不匹配时**立即 `socket.close(4001, ...)`**，关闭原因里必须
同时写出 `peer=<客户端版本>` 与 `local=<服务端版本>`。

这条规则的价值不在于兼容，恰恰在于**拒绝兼容**：把「两个仓库悄悄漂移」从一个会在半年后
以诡异同步 bug 现身的静默缺陷，变成握手当场、带双方版本号的一次响亮失败。

## 线格式

大厅 WebSocket 帧是**扁平 JSON 对象**，`type` 与业务字段同层，没有信封、没有 `payload`
嵌套：

```json
{ "type": "join", "protocol_version": 1, "token": null, "session_token": null, "nickname": "阿波" }
```

字段清单与白名单由 S2 的 `src/lib/protocol/lobby.ts` 定义并在下面的消息表里逐条写明。

## opcode 号段

S3 同步层用二进制帧，号段现在就划定，避免将来撞号：

| 范围 | 归属 |
| --- | --- |
| `0x00`–`0x7F` | 大厅与控制消息 |
| `0x80`–`0xFF` | 整段预留给 S3 同步层（含 `desync_report`） |

本轮不实现二进制帧，只固定号段与判定函数（`src/lib/protocol/opcodes.ts`）。

## `match_result`

对局结束后房内每个客户端各自上报一次。**它不是公开的成绩提交端点**——它是
WebSocket 帧，由房间服收齐后做多数投票，客户端没有任何直接写榜路径。

```json
{ "type": "match_result", "player_kills": { "0": 41, "1": 33 }, "team_wave": 7 }
```

`player_kills` 的键是 slot 下标的十进制字符串。**帧里没有 `room_id`**：房间由 ticket 与
连接本身确定，客户端说自己在哪个房间是不作数的。

## fixtures

`fixtures/manifest.json` 列出全部样本文件，格式 `{ "protocol_version": N, "messages": [...] }`。
样本分两类，都带一个 `name` 字段：

- **HTTP 载荷样本**（`auth_anon_request` / `auth_anon_response` / `leaderboard_page`）：
  `{ "name": ..., "type": ..., "payload": { ...请求体或响应体... } }`。
- **WebSocket 帧样本**（`handshake` / `match_result`）：`{ "name": ..., ...帧的全部字段 }`，
  逐字就是线上那一帧，可以直接喂给 `parseClientMessage()`。

对拍方式（两端相同）：`decode(encode(frame))` 必须还原出同一个对象，且
`manifest.protocol_version` 必须等于本端的 `PROTOCOL_VERSION`。
不比较序列化后的字节串——JSON 的键序在两种语言里没有共同保证，比较它只会制造假失败。
````

- [ ] **Step 2: 写 protocol/fixtures/ 下的样本**

`manifest.json`：

```json
{
  "protocol_version": 1,
  "messages": [
    "auth_anon_request.json",
    "auth_anon_response.json",
    "leaderboard_page.json",
    "handshake.json",
    "match_result.json"
  ]
}
```

`auth_anon_request.json`：

```json
{
  "name": "auth_anon_request",
  "type": "auth_anon_request",
  "payload": {
    "device_id": "3f2a5c10-9b4d-4e77-8a01-5c6d7e8f9a0b",
    "nickname": "阿波"
  }
}
```

`auth_anon_response.json`：

```json
{
  "name": "auth_anon_response",
  "type": "auth_anon_response",
  "payload": {
    "player_id": "9a1c2d3e-4f50-4617-8829-0a1b2c3d4e5f",
    "token": "V0tzZXhhbXBsZS10b2tlbi1ub3QtcmVhbA",
    "nickname": "阿波",
    "authenticated": false,
    "auth_mode": "anonymous_device"
  }
}
```

`leaderboard_page.json`：

```json
{
  "name": "leaderboard_page",
  "type": "leaderboard_page",
  "payload": {
    "board": "team_waves",
    "season": 0,
    "limit": 20,
    "offset": 0,
    "total": 1,
    "authenticated": false,
    "auth_mode": "anonymous_device",
    "min_players_for_ranking": 2,
    "entries": [
      {
        "rank": 1,
        "player_id": "9a1c2d3e-4f50-4617-8829-0a1b2c3d4e5f",
        "nickname": "阿波",
        "value": 12,
        "created_at": 1770000000000
      }
    ]
  }
}
```

`handshake.json` —— **扁平帧**，逐字就是客户端连上大厅后发的第一帧，可以直接喂给 S2 的
`parseClientMessage()`：

```json
{
  "name": "handshake",
  "type": "join",
  "protocol_version": 1,
  "token": null,
  "session_token": null,
  "nickname": "阿波"
}
```

`match_result.json` —— 同样是扁平帧。**没有 `room_id`**：房间由 ticket 与连接本身确定，
客户端上报自己在哪个房间是不作数的：

```json
{
  "name": "match_result",
  "type": "match_result",
  "player_kills": {
    "0": 41,
    "1": 33
  },
  "team_wave": 7
}
```

这两个样本的编解码对拍在 S2（服务端 `test/lobby_protocol.test.ts`、客户端
`validate_online_lobby_wiring.gd`）。本计划只保证它们存在、清单不漏、版本号一致——
S1 阶段还没有任何一端能解析扁平帧，硬要在这里对拍就得先把 S2 的 `lobby.ts` 抄一份过来，
那正是这次拆分要消灭的第二份事实源。

- [ ] **Step 3: 写 src/lib/protocol/version.ts 与 src/lib/protocol/opcodes.ts**

目录形式（而不是单个 `protocol.ts`）是刻意的：S2 会在同一目录下加 `lobby.ts`，
`import { PROTOCOL_VERSION } from './lib/protocol/version.js'` 这条路径从第一天起就是最终形态，
不需要在 S2 落地时把所有 import 改一遍。

`src/lib/protocol/version.ts`：

```ts
import { readFileSync } from 'node:fs';

/**
 * Mirror of protocol/PROTOCOL.md. That document is the source of truth; this
 * constant exists so TypeScript can use it, and test/protocol.test.ts fails the
 * build if the two ever disagree.
 *
 * This file is the ONLY place in the server that spells the version out. The
 * client's only copy is scripts/net/lobby_protocol.gd. Two copies, both pinned
 * to PROTOCOL.md by a test — a third copy is how a version bump gets half
 * applied.
 */
export const PROTOCOL_VERSION = 1;

/** Reads the machine-readable `PROTOCOL_VERSION = N` line out of PROTOCOL.md. */
export function readProtocolVersionFromMarkdown(markdown: string): number {
  const match = /^\s*PROTOCOL_VERSION\s*=\s*(\d+)\s*$/m.exec(markdown);
  if (match === null) throw new Error('PROTOCOL.md has no "PROTOCOL_VERSION = N" line');
  return Number.parseInt(match[1]!, 10);
}

/** Convenience wrapper for the test suite and any future tooling. */
export function readProtocolVersionFromFile(path: string): number {
  return readProtocolVersionFromMarkdown(readFileSync(path, 'utf8'));
}
```

`src/lib/protocol/opcodes.ts`：

```ts
/** Lobby and control messages. */
export const OPCODE_LOBBY_MIN = 0x00;
export const OPCODE_LOBBY_MAX = 0x7f;

/** Reserved wholesale for the S3 sync layer. Nothing in S1/S2 may allocate here. */
export const OPCODE_SYNC_MIN = 0x80;
export const OPCODE_SYNC_MAX = 0xff;

export function isLobbyOpcode(opcode: number): boolean {
  return Number.isInteger(opcode) && opcode >= OPCODE_LOBBY_MIN && opcode <= OPCODE_LOBBY_MAX;
}

export function isSyncOpcode(opcode: number): boolean {
  return Number.isInteger(opcode) && opcode >= OPCODE_SYNC_MIN && opcode <= OPCODE_SYNC_MAX;
}
```

**没有 `encodeMessage` / `decodeMessage` / `Envelope`。** 大厅帧的解析与序列化由 S2 的
`src/lib/protocol/lobby.ts` 提供（`parseClientMessage()` / `encodeServerMessage()`），
线格式是扁平帧。本计划若再写一份信封编解码，就会出现两种互斥的线格式，
而握手会 100% 失败在其中一种上。

- [ ] **Step 4: 把 fixtures 复制到客户端仓库**

Run:

```bash
mkdir -p /Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/fixtures/protocol
cp /Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures/*.json \
   /Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/fixtures/protocol/
diff -r /Users/liangpingbo/Desktop/4399/game/zombiewar-server/protocol/fixtures \
        /Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/fixtures/protocol
```

Expected: `diff -r` 无输出（两侧逐字节相同）。复制而非 submodule 是设计里明确选定的做法；一致性由「握手强制版本校验」与两端各自的对拍脚本兜底。

- [ ] **Step 5: 提交（两个仓库各一次）**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server add protocol src/lib/protocol
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server commit \
  -m "feat: define protocol version, opcode ranges and shared fixtures"
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar add tools/validation/fixtures/protocol
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar commit \
  -m "chore: vendor protocol fixtures from zombiewar-server"
```

Expected: 两次提交都成功；`zombiewar` 侧只新增 `tools/validation/fixtures/protocol/` 下的 6 个 `.json`。

---

### Task 6: Fastify 装配与进程入口

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/app.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/src/server.ts`

**Interfaces:**
- Consumes: `Config`（Task 1）、`Db`（Task 2）、`HttpError`、`rateLimitOptions`（Task 1）、`SessionStore`、`extractBearerToken`、`PlayerSession`（Task 3）、`authRoutes`（Task 3）、`leaderboardRoutes`、`MIN_PLAYERS_FOR_RANKING`（Task 4）、`PROTOCOL_VERSION`（Task 5）、`BOARD_IDS`、`CURRENT_SEASON`（Task 1）。
- Produces:
  - `app.ts`：`declare module 'fastify' { interface FastifyRequest { playerSession: PlayerSession | null } }`、`interface BuildAppOptions { config: Config; db: Db; sessions?: SessionStore }`、`interface ZombiewarApp { app: FastifyInstance; db: Db; sessions: SessionStore; config: Config }`、`buildApp(options: BuildAppOptions): Promise<ZombiewarApp>`；挂载 `GET /health`、`GET /api/meta`。
  - `server.ts`：进程入口，无导出。

- [ ] **Step 1: 写 src/app.ts**

```ts
import cors from '@fastify/cors';
import rateLimit from '@fastify/rate-limit';
import websocket from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';

import type { Config } from './config.js';
import type { Db } from './lib/db.js';
import { HttpError } from './lib/http.js';
import { MIN_PLAYERS_FOR_RANKING } from './lib/leaderboard.js';
import { PROTOCOL_VERSION } from './lib/protocol/version.js';
import { rateLimitOptions } from './lib/rate-limit.js';
import { extractBearerToken, SessionStore, type PlayerSession } from './lib/sessions.js';
import { authRoutes } from './routes/auth.js';
import { leaderboardRoutes } from './routes/leaderboard.js';
import { BOARD_IDS, CURRENT_SEASON } from './types.js';

declare module 'fastify' {
  interface FastifyRequest {
    /**
     * Resolved from `Authorization: Bearer <token>`, or null.
     *
     * NOT a proof of identity — see src/lib/sessions.ts. Routes may read this
     * (e.g. to answer "my rank") but must not treat it as authentication.
     */
    playerSession: PlayerSession | null;
  }
}

/**
 * Routes that stay reachable even with ENFORCE_AUTH on.
 *
 * Matched against the *route pattern*, never against `request.url`. A prefix
 * test on the raw URL is a substring test: `/api/authorize`, `/api/authfoo` and
 * `/api/auth-anything` would all sail past `startsWith('/api/auth')`, and
 * `/health` — the check that is supposed to tell an operator the service is
 * alive — would start answering 401 exactly when someone tightened security.
 * A health check that fails under its own configuration is worse than none.
 */
const PUBLIC_ROUTES = new Set(['/health', '/api/meta', '/api/auth/anon', '/api/auth/me']);

export interface BuildAppOptions {
  config: Config;
  db: Db;
  /** Injected by tests so they can drive a fake clock. */
  sessions?: SessionStore;
}

export interface ZombiewarApp {
  app: FastifyInstance;
  db: Db;
  sessions: SessionStore;
  config: Config;
}

export async function buildApp(options: BuildAppOptions): Promise<ZombiewarApp> {
  const { config, db } = options;
  const sessions = options.sessions ?? new SessionStore({ db, maxSessions: config.maxSessions });

  const app = Fastify({
    logger: { level: config.logLevel },
    bodyLimit: 64 * 1024,
    // NOT unconditionally true: `request.ip` is what the rate limiter buckets
    // by, so trusting X-Forwarded-For from anyone would let a caller mint a
    // fresh budget per request by varying one header.
    trustProxy: config.trustProxy,
  });

  // Registered before anything else so a caller cannot spend work on the
  // application by being rejected late.
  if (config.rateLimit.enabled) {
    await app.register(rateLimit, rateLimitOptions(config.rateLimit));
  }

  await app.register(cors, {
    origin: config.corsOrigin === '*' ? true : config.corsOrigin.split(',').map((s) => s.trim()),
    methods: ['GET', 'HEAD', 'POST', 'DELETE', 'OPTIONS'],
  });

  // S2 mounts `WS /api/rooms/:room_id/ws` on this. Registering it now means
  // every boot exercises the plugin instead of only the S2 branch discovering
  // a version incompatibility months from now.
  //
  // THIS IS THE ONLY REGISTRATION. @fastify/websocket is wrapped in
  // fastify-plugin, so registering it twice in the same scope throws on the
  // duplicate decorator and takes buildApp() down with it. S2 adds its route
  // plugin (`await app.register(roomRoutes, {...})`) and nothing else.
  await app.register(websocket);

  // Treat an empty body on POST as `{}` rather than a 400.
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (_req, payload, done) => {
    const text = typeof payload === 'string' ? payload.trim() : '';
    if (text === '') return done(null, {});
    try {
      return done(null, JSON.parse(text) as unknown);
    } catch {
      return done(new HttpError(400, 'invalid_json', 'request body is not valid JSON'), undefined);
    }
  });

  /**
   * Identity seam. Runs on every request: resolve the bearer token if there is
   * one, attach it. Rejects only when ENFORCE_AUTH is on — the point today is
   * that the plumbing exists and is exercised, not that it guards anything.
   */
  app.decorateRequest('playerSession', null);
  app.addHook('onRequest', async (request) => {
    const token = extractBearerToken(request.headers);
    const session = sessions.resolve(token);
    request.playerSession = session ?? null;
    // `routeOptions.url` is the matched pattern (e.g. '/api/leaderboard/:board')
    // and is populated by onRequest time; it is undefined for 404s, which then
    // fall through to the rejection — an unknown path is not a public route.
    const route = request.routeOptions.url ?? '';
    if (config.enforceAuth && session === undefined && !PUBLIC_ROUTES.has(route)) {
      throw new HttpError(401, 'unauthenticated', 'a valid bearer token is required');
    }
  });

  app.addHook('onResponse', async (request, reply) => {
    const status = reply.statusCode;
    const line = {
      method: request.method,
      url: request.url,
      status,
      ms: Math.round(reply.elapsedTime * 10) / 10,
      ...(request.playerSession !== null ? { player: request.playerSession.nickname } : {}),
    };
    if (status >= 500) request.log.error(line, 'request');
    else if (status >= 400) request.log.warn(line, 'request');
    else request.log.info(line, 'request');
  });

  /**
   * `global: true` installs the limiter per registered route, so requests that
   * match no route would skip it — leaving the cheapest abuse of all, spraying
   * URLs that do not exist, unmetered. This is the seam for that.
   */
  app.setNotFoundHandler(
    config.rateLimit.enabled ? { preHandler: app.rateLimit(rateLimitOptions(config.rateLimit)) } : {},
    (request, reply) =>
      reply.code(404).send({
        error: { code: 'not_found', message: `no route for ${request.method} ${request.url}` },
      }),
  );

  app.setErrorHandler((error: unknown, request, reply) => {
    if (error instanceof HttpError) {
      return reply.code(error.statusCode).send({
        error: {
          code: error.code,
          message: error.message,
          ...(error.details !== undefined ? { details: error.details } : {}),
        },
      });
    }
    const err = (error ?? {}) as { statusCode?: unknown; code?: unknown; message?: unknown };
    const status = typeof err.statusCode === 'number' ? err.statusCode : 500;
    if (status >= 500) request.log.error({ err: error }, 'unhandled error');
    return reply.code(status).send({
      error: {
        code:
          status >= 500 ? 'internal_error' : typeof err.code === 'string' ? err.code : 'bad_request',
        message:
          status >= 500
            ? 'internal server error'
            : typeof err.message === 'string'
              ? err.message
              : 'bad request',
      },
    });
  });

  /** A health check that can actually fail: it touches SQLite. */
  app.get('/health', async (_request, reply) => {
    const problems: string[] = [];
    try {
      db.prepare('SELECT 1').get();
    } catch (error: unknown) {
      problems.push(`sqlite unreachable: ${error instanceof Error ? error.message : String(error)}`);
    }
    return reply.code(problems.length === 0 ? 200 : 503).send({
      status: problems.length === 0 ? 'ok' : 'unhealthy',
      problems,
      uptime_s: Math.round(process.uptime()),
      sessions: sessions.size,
      protocol_version: PROTOCOL_VERSION,
    });
  });

  app.get('/api/meta', async () => ({
    service: 'zombiewar-server',
    role: 'anonymous identity + leaderboards. Rooms and the sync layer are S2/S3.',
    protocol_version: PROTOCOL_VERSION,
    boards: BOARD_IDS,
    season: CURRENT_SEASON,
    min_players_for_ranking: MIN_PLAYERS_FOR_RANKING,
    auth: {
      mode: 'anonymous_device',
      authenticated: false,
      enforced: config.enforceAuth,
      warning:
        'POST /api/auth/anon trades a client-generated device id for a token WITHOUT ' +
        'verifying anything. It is an interface seam for future real auth, not a ' +
        'security control.',
    },
    score_submission:
      'none. There is no public endpoint. Scores are written in-process by the room ' +
      'server after majority-vote cross-validation; 1-player rooms are never ranked.',
    endpoints: [
      'POST   /api/auth/anon',
      'GET    /api/auth/me',
      'DELETE /api/auth/anon',
      'GET    /api/leaderboard/:board',
      'GET    /api/leaderboard/:board/me',
    ],
  }));

  await app.register(authRoutes, { sessions });
  await app.register(leaderboardRoutes, { db, maxLimit: config.maxLeaderboardLimit });

  return { app, db, sessions, config };
}
```

- [ ] **Step 2: 写 src/server.ts**

```ts
import { buildApp } from './app.js';
import { loadConfig, loadDotEnv } from './config.js';
import { openDatabase } from './lib/db.js';

async function main(): Promise<void> {
  loadDotEnv();
  const config = loadConfig();
  const db = openDatabase(config.dbPath);
  const { app } = await buildApp({ config, db });

  const shutdown = (signal: string): void => {
    app.log.info({ signal }, 'shutting down');
    void app.close().then(() => {
      db.close();
      process.exit(0);
    });
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  // 0.0.0.0 so a phone on the same WiFi can reach this by the dev machine's LAN
  // IP. That IP is DHCP-assigned and changes; it is never written down here or
  // anywhere else in either repository. The client configures its own base URL
  // through user://net.cfg.
  await app.listen({ host: config.host, port: config.port });
  app.log.info(
    { host: config.host, port: config.port, db: config.dbPath, enforce_auth: config.enforceAuth },
    'zombiewar-server listening',
  );
}

main().catch((error: unknown) => {
  console.error('failed to start zombiewar-server:', error);
  process.exit(1);
});
```

- [ ] **Step 3: 类型检查并起服务冒烟**

Run:

进程用 **PID** 起停，不用 job control：`%1` 只在交互式 shell 里有意义，在这里 `kill %1`
会报 "no such job"，把服务端留在 8787 上，之后每一个要绑该端口的步骤都会失败。
就绪判断也用轮询 `/health` 而不是固定 `sleep`。

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server && npm run typecheck
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server && \
  ZW_DB_PATH=./data/smoke.db ZW_LOG_LEVEL=warn npm run serve > /tmp/zw_smoke.log 2>&1 &
ZW_PID=$!
for _ in $(seq 1 40); do curl -sf http://127.0.0.1:8787/health > /dev/null && break; done
curl -s http://127.0.0.1:8787/health; echo
curl -s http://127.0.0.1:8787/api/meta; echo
curl -s -X POST http://127.0.0.1:8787/api/auth/anon \
  -H 'Content-Type: application/json' \
  -d '{"device_id":"3f2a5c10-9b4d-4e77-8a01-5c6d7e8f9a0b","nickname":"阿波"}'; echo
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8787/api/leaderboard/team_waves
kill "$ZW_PID"; wait "$ZW_PID" 2>/dev/null
rm -f /Users/liangpingbo/Desktop/4399/game/zombiewar-server/data/smoke.db*
```

Expected:
- `npm run typecheck` 无输出、退出码 0。
- `/health` 返回 `"status":"ok"` 且带 `"protocol_version":1`。
- `/api/meta` 含 `"enforced":false`、`"boards":["team_waves","player_kills"]`、`score_submission` 说明「none」。
- `POST /api/auth/anon` 返回 201，body 含 `"authenticated":false` 与 `"auth_mode":"anonymous_device"`。
- 最后一行为 `404` —— **确认不存在成绩提交端点**。

- [ ] **Step 4: 提交**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server add src/app.ts src/server.ts
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server commit \
  -m "feat: assemble fastify app and listen on 0.0.0.0:8787"
```

Expected: 提交成功，只包含这两个文件；`data/` 因 `.gitignore` 不会被加入。

---

### Task 7: Vitest 测试套件

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/test/helpers.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/test/auth.api.test.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/test/leaderboard.api.test.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/test/leaderboard.vote.test.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/test/protocol.test.ts`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/test/no-public-submit.test.ts`

**Interfaces:**
- Consumes: `buildApp`、`ZombiewarApp`（Task 6）、`Config`（Task 1）、`openDatabase`、`Db`（Task 2）、`SessionStore`、`extractBearerToken`（Task 3）、`crossValidateReports`、`submitMatchResult`、`readLeaderboard`、`readTeamLeaderboard`、`countLeaderboard`、`readPlayerBest`、`MatchLogger`（Task 4）、`PROTOCOL_VERSION`、`readProtocolVersionFromMarkdown`（`src/lib/protocol/version.ts`）、`isLobbyOpcode`、`isSyncOpcode`、`OPCODE_LOBBY_MAX`、`OPCODE_SYNC_MIN`（`src/lib/protocol/opcodes.ts`）（Task 5）。
  - `test/protocol.test.ts` **不消费任何编解码函数**：本计划不提供信封 codec，大厅帧的编解码对拍在 S2 的 `test/lobby_protocol.test.ts`。这里只钉三件事：PROTOCOL.md 的版本号 == 代码常量 == fixtures 清单的版本号；清单不漏文件；opcode 号段边界。
- Produces: `test/helpers.ts` 的 `makeTestDb(): Db`、`makeConfig(overrides?: Partial<Config>): Config`、`interface TestApp extends ZombiewarApp { advance(ms: number): void }`、`makeTestApp(overrides?: Partial<Config>): Promise<TestApp>`、`interface TestIdentity { token: string; playerId: string }`、`authenticate(ctx: TestApp, deviceId: string, nickname: string): Promise<TestIdentity>`、`deviceId(index: number): string`。

- [ ] **Step 1: 写 test/helpers.ts**

```ts
import { buildApp, type ZombiewarApp } from '../src/app.js';
import type { Config } from '../src/config.js';
import { openDatabase, type Db } from '../src/lib/db.js';
import { SessionStore } from '../src/lib/sessions.js';

/** Every suite gets its own in-memory database; nothing touches the disk. */
export function makeTestDb(): Db {
  return openDatabase(':memory:');
}

export function makeConfig(overrides: Partial<Config> = {}): Config {
  return {
    host: '127.0.0.1',
    port: 0,
    dbPath: ':memory:',
    enforceAuth: false,
    corsOrigin: '*',
    logLevel: 'silent',
    trustProxy: false,
    maxLeaderboardLimit: 100,
    maxSessions: 10_000,
    // Off by default so suites can make as many calls as they need.
    rateLimit: { enabled: false, windowMs: 60_000, max: 240, authMax: 10 },
    ...overrides,
  };
}

export interface TestApp extends ZombiewarApp {
  /** Advances the fake clock the SessionStore reads. */
  advance(ms: number): void;
}

export async function makeTestApp(overrides: Partial<Config> = {}): Promise<TestApp> {
  const config = makeConfig(overrides);
  const db = makeTestDb();
  let clock = 1_700_000_000_000;
  const sessions = new SessionStore({ db, maxSessions: config.maxSessions, now: () => clock });
  const built = await buildApp({ config, db, sessions });
  return {
    ...built,
    advance: (ms: number) => {
      clock += ms;
    },
  };
}

export interface TestIdentity {
  token: string;
  playerId: string;
}

export async function authenticate(
  ctx: TestApp,
  deviceId: string,
  nickname: string,
): Promise<TestIdentity> {
  const res = await ctx.app.inject({
    method: 'POST',
    url: '/api/auth/anon',
    payload: { device_id: deviceId, nickname },
  });
  if (res.statusCode !== 201) throw new Error(`auth failed: ${res.statusCode} ${res.body}`);
  const body = res.json<{ token: string; player_id: string }>();
  return { token: body.token, playerId: body.player_id };
}

/** A UUIDv4-shaped device id derived from an index, so suites read clearly. */
export function deviceId(index: number): string {
  return `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
}
```

- [ ] **Step 2: 写 test/auth.api.test.ts**

```ts
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { extractBearerToken, SessionStore } from '../src/lib/sessions.js';
import { authenticate, deviceId, makeTestApp, makeTestDb, type TestApp } from './helpers.js';

let ctx: TestApp;

beforeEach(async () => {
  ctx = await makeTestApp();
});

afterEach(async () => {
  await ctx.app.close();
  ctx.db.close();
});

describe('POST /api/auth/anon', () => {
  it('exchanges a device id for a bearer token', async () => {
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/api/auth/anon',
      payload: { device_id: deviceId(1), nickname: '阿波' },
    });
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.player_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(body.token).toMatch(/^[\w-]{40,}$/);
    expect(body.nickname).toBe('阿波');
  });

  it('states plainly that this is NOT authentication', async () => {
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/api/auth/anon',
      payload: { device_id: deviceId(2), nickname: '阿波' },
    });
    // The client's leaderboard panel keys its "未认证" badge off these. If they
    // ever flip to true without real credential checking, that is a lie.
    expect(res.json().authenticated).toBe(false);
    expect(res.json().auth_mode).toBe('anonymous_device');
  });

  it('does not issue a JWT', async () => {
    const { token } = await authenticate(ctx, deviceId(3), 'bo');
    expect(token.split('.')).toHaveLength(1);
  });

  it('keeps player_id stable per device and mints a fresh token each call', async () => {
    const first = await authenticate(ctx, deviceId(4), '阿波');
    const second = await authenticate(ctx, deviceId(4), '阿波二号');
    expect(second.playerId).toBe(first.playerId);
    expect(second.token).not.toBe(first.token);
    const rows = ctx.db.prepare('SELECT COUNT(*) AS n FROM players').get() as { n: number };
    expect(rows.n).toBe(1);
  });

  it('gives different devices different player ids and allows duplicate nicknames', async () => {
    const a = await authenticate(ctx, deviceId(5), '同名');
    const b = await authenticate(ctx, deviceId(6), '同名');
    expect(a.playerId).not.toBe(b.playerId);
  });

  it('enforces the 2-12 character nickname window, counting code points', async () => {
    const cases: Array<[string, number]> = [
      ['', 400],
      ['x', 400],
      ['xy', 201],
      ['僵尸', 201],
      ['十二个字符恰好到这里啦', 201],
      ['x'.repeat(12), 201],
      ['x'.repeat(13), 400],
    ];
    let index = 100;
    for (const [nickname, expected] of cases) {
      index += 1;
      const res = await ctx.app.inject({
        method: 'POST',
        url: '/api/auth/anon',
        payload: { device_id: deviceId(index), nickname },
      });
      expect(res.statusCode, `nickname=${JSON.stringify(nickname)}`).toBe(expected);
    }
  });

  it('rejects blocklisted nicknames', async () => {
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/api/auth/anon',
      payload: { device_id: deviceId(7), nickname: '管理员' },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error.code).toBe('nickname_blocked');
  });

  it('rejects a device id that is not a UUID', async () => {
    for (const bad of ['', 'not-a-uuid', '12345678']) {
      const res = await ctx.app.inject({
        method: 'POST',
        url: '/api/auth/anon',
        payload: { device_id: bad, nickname: 'bo' },
      });
      expect(res.statusCode, bad).toBe(400);
    }
  });

  it('400s on invalid JSON', async () => {
    const res = await ctx.app.inject({
      method: 'POST',
      url: '/api/auth/anon',
      headers: { 'content-type': 'application/json' },
      payload: '{ nope',
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error.code).toBe('invalid_json');
  });
});

describe('GET /api/auth/me', () => {
  it('reports the caller when the token is recognised, still unauthenticated', async () => {
    const { token, playerId } = await authenticate(ctx, deviceId(8), 'bo');
    const res = await ctx.app.inject({
      url: '/api/auth/me',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().player).toMatchObject({ player_id: playerId, nickname: 'bo' });
    expect(res.json().token_recognised).toBe(true);
    expect(res.json().authenticated).toBe(false);
  });

  it('does not 401 an anonymous caller — anonymity is legal today', async () => {
    const res = await ctx.app.inject({ url: '/api/auth/me' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ authenticated: false, player: null });
  });
});

describe('DELETE /api/auth/anon', () => {
  it('revokes the token and is idempotent', async () => {
    const { token } = await authenticate(ctx, deviceId(9), 'bo');
    const headers = { authorization: `Bearer ${token}` };
    expect(
      (await ctx.app.inject({ method: 'DELETE', url: '/api/auth/anon', headers })).statusCode,
    ).toBe(204);
    expect((await ctx.app.inject({ url: '/api/auth/me', headers })).json().player).toBeNull();
    expect(
      (await ctx.app.inject({ method: 'DELETE', url: '/api/auth/anon', headers })).statusCode,
    ).toBe(204);
  });
});

describe('ENFORCE_AUTH', () => {
  it('false (the default) lets an anonymous caller read a leaderboard', async () => {
    const res = await ctx.app.inject({ url: '/api/leaderboard/team_waves' });
    expect(res.statusCode).toBe(200);
    expect(ctx.config.enforceAuth).toBe(false);
  });

  it('true rejects anonymous downstream calls but still allows /api/auth', async () => {
    const strict = await makeTestApp({ enforceAuth: true });
    try {
      const anonymous = await strict.app.inject({ url: '/api/leaderboard/team_waves' });
      expect(anonymous.statusCode).toBe(401);
      expect(anonymous.json().error.code).toBe('unauthenticated');

      const issued = await authenticate(strict, deviceId(10), 'bo');
      const withToken = await strict.app.inject({
        url: '/api/leaderboard/team_waves',
        headers: { authorization: `Bearer ${issued.token}` },
      });
      expect(withToken.statusCode).toBe(200);
    } finally {
      await strict.app.close();
      strict.db.close();
    }
  });

  /**
   * The regression this guards: a `request.url.startsWith('/api/auth')` guard
   * locks an operator out of the health check at the exact moment they harden
   * the service, and lets `/api/authorize` through because it happens to share
   * a prefix. The allowlist is keyed off the matched route pattern instead.
   */
  it('never locks out /health or /api/meta', async () => {
    const strict = await makeTestApp({ enforceAuth: true });
    try {
      expect((await strict.app.inject({ url: '/health' })).statusCode).toBe(200);
      expect((await strict.app.inject({ url: '/api/meta' })).statusCode).toBe(200);
      expect((await strict.app.inject({ url: '/api/auth/me' })).statusCode).toBe(200);
    } finally {
      await strict.app.close();
      strict.db.close();
    }
  });

  it('does not let a lookalike path share the /api/auth exemption', async () => {
    const strict = await makeTestApp({ enforceAuth: true });
    try {
      for (const url of ['/api/authorize', '/api/authfoo', '/api/auth-anything']) {
        // 404 (no such route) or 401 (rejected) — never 200. What must NOT
        // happen is the prefix match waving them through.
        expect([401, 404], url).toContain((await strict.app.inject({ url })).statusCode);
      }
    } finally {
      await strict.app.close();
      strict.db.close();
    }
  });
});

describe('SessionStore', () => {
  it('evicts the oldest session past the cap', () => {
    const db = makeTestDb();
    const store = new SessionStore({ db, maxSessions: 3 });
    const first = store.authenticateDevice(deviceId(21), 'a');
    store.authenticateDevice(deviceId(22), 'b');
    store.authenticateDevice(deviceId(23), 'c');
    expect(store.size).toBe(3);
    store.authenticateDevice(deviceId(24), 'd');
    expect(store.size).toBe(3);
    expect(store.resolve(first.token)).toBeUndefined();
    db.close();
  });

  it('tracks last-seen on resolve', () => {
    const db = makeTestDb();
    let clock = 1_000;
    const store = new SessionStore({ db, maxSessions: 10, now: () => clock });
    const session = store.authenticateDevice(deviceId(25), 'a');
    clock = 5_000;
    expect(store.resolve(session.token)?.lastSeenAt).toBe(5_000);
    db.close();
  });

  it('resolves nothing for an absent token', () => {
    const db = makeTestDb();
    const store = new SessionStore({ db, maxSessions: 10 });
    expect(store.resolve(undefined)).toBeUndefined();
    expect(store.resolve('')).toBeUndefined();
    db.close();
  });
});

describe('extractBearerToken', () => {
  it('parses the Authorization header case-insensitively', () => {
    expect(extractBearerToken({ authorization: 'Bearer abc' })).toBe('abc');
    expect(extractBearerToken({ authorization: 'bearer abc' })).toBe('abc');
    expect(extractBearerToken({ authorization: '  Bearer   abc  ' })).toBe('abc');
  });

  it('ignores other schemes and malformed headers', () => {
    expect(extractBearerToken({ authorization: 'Basic abc' })).toBeUndefined();
    expect(extractBearerToken({ authorization: 'Bearer' })).toBeUndefined();
    expect(extractBearerToken({})).toBeUndefined();
  });

  it('falls back to X-Player-Token', () => {
    expect(extractBearerToken({ 'x-player-token': 'xyz' })).toBe('xyz');
    expect(extractBearerToken({ 'x-player-token': ['xyz', 'other'] })).toBe('xyz');
  });
});
```

- [ ] **Step 3: 写 test/leaderboard.vote.test.ts**

```ts
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import {
  countLeaderboard,
  crossValidateReports,
  MAX_TEAM_WAVE,
  MAX_ZOMBIES_PER_WAVE,
  MIN_MATCH_DURATION_MS,
  MIN_PLAYERS_FOR_RANKING,
  maxKillsForWave,
  readLeaderboard,
  readPlayerBest,
  readTeamLeaderboard,
  submitMatchResult,
  type MatchLogger,
  type MatchReport,
  type MatchSlot,
} from '../src/lib/leaderboard.js';
import { makeTestDb } from './helpers.js';
import type { Db } from '../src/lib/db.js';

function report(playerId: string, wave: number, kills: Record<string, number>): MatchReport {
  return { player_id: playerId, team_wave: wave, player_kills: kills };
}

const SLOTS: MatchSlot[] = [
  { slot: 0, player_id: 'p-a' },
  { slot: 1, player_id: 'p-b' },
];

/** The two seats of SLOTS, in the form crossValidateReports() takes. */
const SEATS = SLOTS.map((slot) => slot.player_id);

/** Records what submitMatchResult() logged, so the design's "记录日志" is testable. */
function recordingLogger(): MatchLogger & {
  warns: Array<[Record<string, unknown>, string]>;
  errors: Array<[Record<string, unknown>, string]>;
} {
  const warns: Array<[Record<string, unknown>, string]> = [];
  const errors: Array<[Record<string, unknown>, string]> = [];
  return {
    warns,
    errors,
    warn: (payload, message) => warns.push([payload, message]),
    error: (payload, message) => errors.push([payload, message]),
  };
}

let db: Db;

beforeEach(() => {
  db = makeTestDb();
  db.prepare(
    'INSERT INTO players (player_id, device_id, nickname, created_at, last_seen) ' +
      'VALUES (?, ?, ?, ?, ?)',
  ).run('p-a', 'dev-a', '阿波', 1, 1);
  db.prepare(
    'INSERT INTO players (player_id, device_id, nickname, created_at, last_seen) ' +
      'VALUES (?, ?, ?, ?, ?)',
  ).run('p-b', 'dev-b', '小北', 1, 1);
});

afterEach(() => {
  db.close();
});

describe('crossValidateReports — 一致', () => {
  it('accepts unanimous reports with no dissenters', () => {
    const result = crossValidateReports(
      [report('p-a', 7, { '0': 41, '1': 33 }), report('p-b', 7, { '0': 41, '1': 33 })],
      SEATS,
      60_000,
    );
    expect(result.status).toBe('accepted');
    expect(result.team_wave).toBe(7);
    expect(result.player_kills).toEqual({ '0': 41, '1': 33 });
    expect(result.dissenters).toEqual([]);
    expect(result.reason).toBe('unanimous');
  });

  it('is insensitive to key order within player_kills', () => {
    const a = report('p-a', 5, { '0': 1, '1': 2 });
    const b = report('p-b', 5, { '1': 2, '0': 1 });
    expect(crossValidateReports([a, b], SEATS, 60_000).status).toBe('accepted');
  });
});

describe('crossValidateReports — 单点偏离', () => {
  it('keeps the majority and records the deviating client', () => {
    const result = crossValidateReports(
      [
        report('p-a', 7, { '0': 41 }),
        report('p-b', 7, { '0': 41 }),
        report('p-c', 99, { '0': 999 }),
      ],
      ['p-a', 'p-b', 'p-c'],
      60_000,
    );
    expect(result.status).toBe('accepted');
    expect(result.team_wave).toBe(7);
    expect(result.dissenters).toEqual(['p-c']);
    expect(result.reason).toContain('majority of 2/3');
  });
});

describe('crossValidateReports — 全场分歧', () => {
  it('voids the match when there is no strict majority', () => {
    const result = crossValidateReports(
      [report('p-a', 7, { '0': 1 }), report('p-b', 8, { '0': 2 })],
      SEATS,
      60_000,
    );
    expect(result.status).toBe('no_majority');
    expect(result.team_wave).toBe(0);
    // Nobody is a dissenter when the match is voided: there was no majority to
    // deviate FROM, and labelling honest clients here would poison the log S2
    // uses to spot tampering.
    expect(result.dissenters).toEqual([]);
  });

  it('voids a 2-1-1 plurality too — a plurality is not a majority', () => {
    const result = crossValidateReports(
      [
        report('p-a', 7, { '0': 1 }),
        report('p-b', 7, { '0': 1 }),
        report('p-c', 8, { '0': 1 }),
        report('p-d', 9, { '0': 1 }),
      ],
      ['p-a', 'p-b', 'p-c', 'p-d'],
      60_000,
    );
    expect(result.status).toBe('no_majority');
  });

  it('voids a match nobody reported', () => {
    expect(crossValidateReports([], ['p-a', 'p-b', 'p-c', 'p-d'], 60_000).status).toBe(
      'no_majority',
    );
  });
});

describe('crossValidateReports — 席位法定人数', () => {
  /**
   * The single most dangerous hole a per-upload tally leaves open: one client
   * uploads, it is trivially "unanimous", and it writes the whole room's scores
   * with nothing to check it against.
   */
  it('voids a 2-player match where only one client reported', () => {
    const result = crossValidateReports([report('p-a', 7, { '0': 41 })], SEATS, 60_000);
    expect(result.status).toBe('no_majority');
    expect(result.reason).toContain('1 of 2 seats reported');
  });

  it('ignores duplicate reports from the same player_id', () => {
    const forged = report('p-a', 99, { '0': 1 });
    const result = crossValidateReports(
      [forged, forged, forged, report('p-b', 7, { '0': 1 }), report('p-c', 7, { '0': 1 })],
      ['p-a', 'p-b', 'p-c'],
      60_000,
    );
    // Per-upload this would be 3-vs-2 for the forged wave 99. Per seat it is
    // 1-vs-2, so the honest pair wins and the stuffer is the dissenter.
    expect(result.status).toBe('accepted');
    expect(result.team_wave).toBe(7);
    expect(result.dissenters).toEqual(['p-a']);
  });

  it('ignores reports from a player_id that never sat in this match', () => {
    const result = crossValidateReports(
      [report('p-a', 7, { '0': 1 }), report('p-b', 7, { '0': 1 }), report('p-x', 99, { '0': 1 })],
      SEATS,
      60_000,
    );
    expect(result.status).toBe('accepted');
    expect(result.team_wave).toBe(7);
    // Not even a dissenter: an outsider has no vote to deviate with.
    expect(result.dissenters).toEqual([]);
  });
});

describe('crossValidateReports — 合理性上限', () => {
  it('rejects a wave count over the cap', () => {
    const over = MAX_TEAM_WAVE + 1;
    const result = crossValidateReports(
      [report('p-a', over, { '0': 1 }), report('p-b', over, { '0': 1 })],
      SEATS,
      60_000,
    );
    expect(result.status).toBe('out_of_range');
    expect(result.reason).toContain(`1..${MAX_TEAM_WAVE}`);
  });

  it('accepts exactly the wave cap', () => {
    const result = crossValidateReports(
      [report('p-a', MAX_TEAM_WAVE, { '0': 1 }), report('p-b', MAX_TEAM_WAVE, { '0': 1 })],
      SEATS,
      60_000,
    );
    expect(result.status).toBe('accepted');
  });

  /**
   * Reads MAX_ZOMBIES_PER_WAVE symbolically on purpose: the constant is derived
   * from demo_arena.gd's spawn config (2 zombies x 4 corners, doubled for
   * headroom), and this test must keep passing when that derivation is retuned
   * — while still failing if the cap stops being applied at all.
   */
  it('derives the kill cap from the wave count', () => {
    const wave = 3;
    expect(maxKillsForWave(wave)).toBe(wave * MAX_ZOMBIES_PER_WAVE);
    const atCap = maxKillsForWave(wave);
    expect(
      crossValidateReports(
        [report('p-a', wave, { '0': atCap }), report('p-b', wave, { '0': atCap })],
        SEATS,
        60_000,
      ).status,
    ).toBe('accepted');
    expect(
      crossValidateReports(
        [report('p-a', wave, { '0': atCap + 1 }), report('p-b', wave, { '0': atCap + 1 })],
        SEATS,
        60_000,
      ).status,
    ).toBe('out_of_range');
  });

  it('keeps the cap tight enough to be worth having', () => {
    // A wave-10 run cannot plausibly have produced 200 kills: the arena spawns
    // at most 8 zombies a wave. If this ever passes, the cap has drifted away
    // from the client and stopped being a check.
    expect(
      crossValidateReports(
        [report('p-a', 10, { '0': 200 }), report('p-b', 10, { '0': 200 })],
        SEATS,
        60_000,
      ).status,
    ).toBe('out_of_range');
  });

  it('rejects a match shorter than the duration floor', () => {
    const result = crossValidateReports(
      [report('p-a', 7, { '0': 1 }), report('p-b', 7, { '0': 1 })],
      SEATS,
      MIN_MATCH_DURATION_MS - 1,
    );
    expect(result.status).toBe('too_short');
  });

  it('rejects non-integer and negative kill counts', () => {
    for (const kills of [1.5, -1]) {
      const result = crossValidateReports(
        [report('p-a', 4, { '0': kills }), report('p-b', 4, { '0': kills })],
        SEATS,
        60_000,
      );
      expect(result.status, String(kills)).toBe('out_of_range');
    }
  });
});

describe('submitMatchResult', () => {
  it('writes both boards for every slot when the vote passes', () => {
    const result = submitMatchResult(db, {
      roomId: 'R1',
      season: 0,
      slots: SLOTS,
      reports: [report('p-a', 7, { '0': 41, '1': 33 }), report('p-b', 7, { '0': 41, '1': 33 })],
      durationMs: 60_000,
      now: () => 1_000,
    });
    expect(result.status).toBe('accepted');
    expect(result.written).toBe(4);
    expect(result.persisted).toBe(true);

    // One row on the TEAM board for the one match played — not one row per
    // teammate. The per-participant rows still exist underneath (that is what
    // /me reads), but the public board is grouped by room.
    const waves = readTeamLeaderboard(db, 0, 10, 0);
    expect(waves).toHaveLength(1);
    expect(waves[0]?.value).toBe(7);
    expect(waves[0]?.members.sort()).toEqual(['小北', '阿波']);
    expect(countLeaderboard(db, 'team_waves', 0)).toBe(1);

    const kills = readLeaderboard(db, 'player_kills', 0, 10, 0);
    expect(kills[0]).toMatchObject({ rank: 1, player_id: 'p-a', nickname: '阿波', value: 41 });
    expect(kills[1]).toMatchObject({ rank: 2, player_id: 'p-b', nickname: '小北', value: 33 });
    expect(countLeaderboard(db, 'player_kills', 0)).toBe(2);
  });

  it('keeps only each player best across matches', () => {
    submitMatchResult(db, {
      roomId: 'R1',
      season: 0,
      slots: SLOTS,
      reports: [report('p-a', 5, { '0': 10, '1': 4 }), report('p-b', 5, { '0': 10, '1': 4 })],
      durationMs: 60_000,
      now: () => 1_000,
    });
    submitMatchResult(db, {
      roomId: 'R2',
      season: 0,
      slots: SLOTS,
      reports: [report('p-a', 9, { '0': 3, '1': 40 }), report('p-b', 9, { '0': 3, '1': 40 })],
      durationMs: 60_000,
      now: () => 2_000,
    });
    const kills = readLeaderboard(db, 'player_kills', 0, 10, 0);
    expect(kills).toHaveLength(2);
    expect(kills[0]).toMatchObject({ rank: 1, player_id: 'p-b', value: 40 });
    expect(kills[1]).toMatchObject({ rank: 2, player_id: 'p-a', value: 10 });
    expect(readPlayerBest(db, 'player_kills', 0, 'p-a')).toMatchObject({ rank: 2, value: 10 });
  });

  it('writes nothing for a 1-player room', () => {
    const result = submitMatchResult(db, {
      roomId: 'R-SOLO',
      season: 0,
      slots: [{ slot: 0, player_id: 'p-a' }],
      reports: [report('p-a', 12, { '0': 200 })],
      durationMs: 600_000,
      now: () => 1_000,
    });
    expect(result.status).toBe('too_few_players');
    expect(result.written).toBe(0);
    expect(result.reason).toContain(`${MIN_PLAYERS_FOR_RANKING} players are required`);
    const rows = db.prepare('SELECT COUNT(*) AS n FROM scores').get() as { n: number };
    expect(rows.n).toBe(0);
  });

  it('writes nothing when the vote fails', () => {
    const result = submitMatchResult(db, {
      roomId: 'R3',
      season: 0,
      slots: SLOTS,
      reports: [report('p-a', 7, { '0': 1 }), report('p-b', 8, { '0': 2 })],
      durationMs: 60_000,
      now: () => 1_000,
    });
    expect(result.status).toBe('no_majority');
    expect(result.written).toBe(0);
    expect(result.persisted).toBe(false);
    const rows = db.prepare('SELECT COUNT(*) AS n FROM scores').get() as { n: number };
    expect(rows.n).toBe(0);
  });

  it('logs a voided match and a discarded deviating report', () => {
    const logger = recordingLogger();
    submitMatchResult(db, {
      roomId: 'R-VOID',
      season: 0,
      slots: SLOTS,
      reports: [report('p-a', 7, { '0': 1 }), report('p-b', 8, { '0': 2 })],
      durationMs: 60_000,
      now: () => 1_000,
      logger,
    });
    expect(logger.warns).toHaveLength(1);
    expect(logger.warns[0]?.[1]).toContain('match voided');
    expect(logger.warns[0]?.[0]).toMatchObject({ room_id: 'R-VOID', status: 'no_majority' });

    const second = recordingLogger();
    submitMatchResult(db, {
      roomId: 'R-DEVIANT',
      season: 0,
      slots: [...SLOTS, { slot: 2, player_id: 'p-c' }],
      reports: [
        report('p-a', 7, { '0': 1 }),
        report('p-b', 7, { '0': 1 }),
        report('p-c', 9, { '0': 1 }),
      ],
      durationMs: 60_000,
      now: () => 2_000,
      logger: second,
    });
    expect(second.warns[0]?.[1]).toContain('discarded deviating match reports');
    expect(second.warns[0]?.[0]).toMatchObject({ dissenters: ['p-c'] });
  });

  /**
   * A full disk must not take the room server down with it. The match is over
   * either way; the players get told 「成绩未保存」 and keep their session.
   */
  it('survives a SQLite write failure and reports it instead of throwing', () => {
    const logger = recordingLogger();
    db.exec('DROP TABLE scores');
    const result = submitMatchResult(db, {
      roomId: 'R-BROKEN',
      season: 0,
      slots: SLOTS,
      reports: [report('p-a', 7, { '0': 1 }), report('p-b', 7, { '0': 1 })],
      durationMs: 60_000,
      now: () => 1_000,
      logger,
    });
    expect(result.status).toBe('accepted');
    expect(result.persisted).toBe(false);
    expect(result.written).toBe(0);
    expect(logger.errors).toHaveLength(1);
    expect(logger.errors[0]?.[1]).toContain('sqlite write failed');
  });
});
```

- [ ] **Step 4: 写 test/leaderboard.api.test.ts**

```ts
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { submitMatchResult, type MatchSlot } from '../src/lib/leaderboard.js';
import { authenticate, deviceId, makeTestApp, type TestApp } from './helpers.js';

let ctx: TestApp;
let alice: { token: string; playerId: string };
let bob: { token: string; playerId: string };

beforeEach(async () => {
  ctx = await makeTestApp();
  alice = await authenticate(ctx, deviceId(1), '阿波');
  bob = await authenticate(ctx, deviceId(2), '小北');
  const slots: MatchSlot[] = [
    { slot: 0, player_id: alice.playerId },
    { slot: 1, player_id: bob.playerId },
  ];
  submitMatchResult(ctx.db, {
    roomId: 'R1',
    season: 0,
    slots,
    reports: [
      { player_id: alice.playerId, team_wave: 5, player_kills: { '0': 10, '1': 40 } },
      { player_id: bob.playerId, team_wave: 5, player_kills: { '0': 10, '1': 40 } },
    ],
    durationMs: 60_000,
    now: () => 1_000,
  });
  submitMatchResult(ctx.db, {
    roomId: 'R2',
    season: 0,
    slots,
    reports: [
      { player_id: alice.playerId, team_wave: 9, player_kills: { '0': 22, '1': 3 } },
      { player_id: bob.playerId, team_wave: 9, player_kills: { '0': 22, '1': 3 } },
    ],
    durationMs: 60_000,
    now: () => 2_000,
  });
});

afterEach(async () => {
  await ctx.app.close();
  ctx.db.close();
});

describe('GET /api/leaderboard/:board', () => {
  it('sorts descending and keeps only each player best', async () => {
    const res = await ctx.app.inject({ url: '/api/leaderboard/player_kills?season=0&limit=100' });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.entries).toHaveLength(2);
    expect(body.entries[0]).toMatchObject({ rank: 1, nickname: '小北', value: 40 });
    expect(body.entries[1]).toMatchObject({ rank: 2, nickname: '阿波', value: 22 });
  });

  it('renders the team board one row per match, naming every member', async () => {
    const res = await ctx.app.inject({ url: '/api/leaderboard/team_waves' });
    const entries = res.json().entries as Array<{ value: number; nickname: string; members: string[] }>;
    // Two matches were played, so two rows — NOT four (one per teammate per
    // match), which is what a per-player read of a team board produces.
    expect(entries).toHaveLength(2);
    expect(entries[0]?.value).toBe(9);
    expect(entries[0]?.members.sort()).toEqual(['小北', '阿波']);
    expect(entries[0]?.nickname).toContain('阿波');
    expect(entries[1]?.value).toBe(5);
    expect(res.json().total).toBe(2);
  });

  it('reports a total the client can page against', async () => {
    const res = await ctx.app.inject({ url: '/api/leaderboard/player_kills?limit=1' });
    // One entry on this page, but two on the board: the panel needs the second
    // number to know whether 下一页 leads anywhere.
    expect(res.json().entries).toHaveLength(1);
    expect(res.json().total).toBe(2);
  });

  it('never claims the caller is authenticated', async () => {
    const res = await ctx.app.inject({
      url: '/api/leaderboard/team_waves',
      headers: { authorization: `Bearer ${alice.token}` },
    });
    expect(res.json().authenticated).toBe(false);
    expect(res.json().min_players_for_ranking).toBe(2);
  });

  it('pages with limit and offset, and keeps rank absolute', async () => {
    const page = await ctx.app.inject({ url: '/api/leaderboard/player_kills?limit=1&offset=1' });
    expect(page.json().entries).toHaveLength(1);
    expect(page.json().entries[0]).toMatchObject({ rank: 2, nickname: '阿波' });
  });

  it('400s on an unknown board', async () => {
    const res = await ctx.app.inject({ url: '/api/leaderboard/nope' });
    expect(res.statusCode).toBe(400);
    expect(res.json().error.code).toBe('invalid_board');
  });

  it('400s on a limit above the server cap or a non-integer', async () => {
    expect((await ctx.app.inject({ url: '/api/leaderboard/team_waves?limit=101' })).statusCode).toBe(400);
    expect((await ctx.app.inject({ url: '/api/leaderboard/team_waves?limit=abc' })).statusCode).toBe(400);
    expect((await ctx.app.inject({ url: '/api/leaderboard/team_waves?season=-1' })).statusCode).toBe(400);
  });
});

describe('GET /api/leaderboard/:board/me', () => {
  it('401s without a token', async () => {
    const res = await ctx.app.inject({ url: '/api/leaderboard/player_kills/me' });
    expect(res.statusCode).toBe(401);
    expect(res.json().error.code).toBe('unauthenticated');
  });

  it('returns the caller best entry and rank', async () => {
    const res = await ctx.app.inject({
      url: '/api/leaderboard/player_kills/me',
      headers: { authorization: `Bearer ${alice.token}` },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().entry).toMatchObject({ rank: 2, player_id: alice.playerId, value: 22 });
    expect(res.json().authenticated).toBe(false);
  });

  it('returns a null entry for a player with no score', async () => {
    const newcomer = await authenticate(ctx, deviceId(3), '新人');
    const res = await ctx.app.inject({
      url: '/api/leaderboard/player_kills/me',
      headers: { authorization: `Bearer ${newcomer.token}` },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().entry).toBeNull();
  });
});
```

- [ ] **Step 5: 写 test/protocol.test.ts 与 test/no-public-submit.test.ts**

`test/protocol.test.ts`：

```ts
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  isLobbyOpcode,
  isSyncOpcode,
  OPCODE_LOBBY_MAX,
  OPCODE_SYNC_MIN,
} from '../src/lib/protocol/opcodes.js';
import {
  PROTOCOL_VERSION,
  readProtocolVersionFromMarkdown,
} from '../src/lib/protocol/version.js';

const PROTOCOL_DIR = join(process.cwd(), 'protocol');
const FIXTURE_DIR = join(PROTOCOL_DIR, 'fixtures');

/**
 * Every fixture declares a `name` and a `type`. HTTP payload samples wrap their
 * body in `payload`; WebSocket frame samples ARE the frame and are flat. The
 * frame samples' encode/decode round-trip belongs to S2's lobby_protocol tests —
 * this file owns the parts that exist today: version agreement and the manifest.
 */
interface Fixture {
  name: string;
  type: string;
  payload?: Record<string, unknown>;
}

interface Manifest {
  protocol_version: number;
  messages: string[];
}

function readManifest(): Manifest {
  return JSON.parse(readFileSync(join(FIXTURE_DIR, 'manifest.json'), 'utf8')) as Manifest;
}

describe('PROTOCOL.md is the source of truth', () => {
  it('declares the same version the code uses', () => {
    const markdown = readFileSync(join(PROTOCOL_DIR, 'PROTOCOL.md'), 'utf8');
    expect(readProtocolVersionFromMarkdown(markdown)).toBe(PROTOCOL_VERSION);
  });

  it('agrees with the fixture manifest', () => {
    expect(readManifest().protocol_version).toBe(PROTOCOL_VERSION);
  });

  it('lists every fixture on disk', () => {
    const onDisk = readdirSync(FIXTURE_DIR)
      .filter((name) => name.endsWith('.json') && name !== 'manifest.json')
      .sort();
    expect([...readManifest().messages].sort()).toEqual(onDisk);
  });
});

describe('fixtures are well formed', () => {
  it('gives every sample a name and a type', () => {
    for (const file of readManifest().messages) {
      const fixture = JSON.parse(readFileSync(join(FIXTURE_DIR, file), 'utf8')) as Fixture;
      expect(fixture.name, file).toBe(file.replace(/\.json$/, ''));
      expect(typeof fixture.type, file).toBe('string');
      expect(fixture.type, file).not.toBe('');
    }
  });

  it('keeps WebSocket frame samples flat, with no envelope', () => {
    // The wire format is a flat frame: `type` sits beside the business fields.
    // A `payload` key here would mean someone reintroduced the envelope, and the
    // handshake would fail 100% of the time against S2's parseClientMessage().
    for (const file of ['handshake.json', 'match_result.json']) {
      const frame = JSON.parse(readFileSync(join(FIXTURE_DIR, file), 'utf8')) as Record<
        string,
        unknown
      >;
      expect(Object.keys(frame), file).not.toContain('payload');
    }
    const handshake = JSON.parse(readFileSync(join(FIXTURE_DIR, 'handshake.json'), 'utf8')) as {
      protocol_version: number;
    };
    expect(handshake.protocol_version).toBe(PROTOCOL_VERSION);

    const matchResult = JSON.parse(
      readFileSync(join(FIXTURE_DIR, 'match_result.json'), 'utf8'),
    ) as Record<string, unknown>;
    // The server derives the room from the ticket and the connection. A client
    // that gets to name its own room can write into someone else's match.
    expect(Object.keys(matchResult)).not.toContain('room_id');
  });

  it('carries the paging total the client needs', () => {
    const page = JSON.parse(
      readFileSync(join(FIXTURE_DIR, 'leaderboard_page.json'), 'utf8'),
    ) as Fixture;
    expect(page.payload).toHaveProperty('total');
  });
});

describe('opcode ranges', () => {
  it('splits lobby and sync at 0x80', () => {
    expect(OPCODE_LOBBY_MAX).toBe(0x7f);
    expect(OPCODE_SYNC_MIN).toBe(0x80);
    expect(isLobbyOpcode(0x00)).toBe(true);
    expect(isLobbyOpcode(0x7f)).toBe(true);
    expect(isLobbyOpcode(0x80)).toBe(false);
    expect(isSyncOpcode(0x80)).toBe(true);
    expect(isSyncOpcode(0xff)).toBe(true);
    expect(isSyncOpcode(0x7f)).toBe(false);
  });
});

describe('the wire format has exactly one implementation', () => {
  it('does not resurrect the message envelope', () => {
    // Two codecs mean two wire formats, and the loser fails at the handshake
    // with a version-agnostic "invalid_message". The lobby codec lives in
    // src/lib/protocol/lobby.ts (S2) and nowhere else.
    const files = readdirSync(join(process.cwd(), 'src', 'lib', 'protocol'));
    for (const file of files) {
      const source = readFileSync(join(process.cwd(), 'src', 'lib', 'protocol', file), 'utf8');
      if (file === 'lobby.ts') continue;
      expect(source, file).not.toContain('encodeMessage');
      expect(source, file).not.toContain('decodeMessage');
    }
  });
});
```

`test/no-public-submit.test.ts`：

```ts
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import { makeTestApp, type TestApp } from './helpers.js';

const ROUTES_DIR = join(process.cwd(), 'src', 'routes');

let ctx: TestApp;

beforeAll(async () => {
  ctx = await makeTestApp();
});

afterAll(async () => {
  await ctx.app.close();
  ctx.db.close();
});

/**
 * The entire anti-cheat design rests on "a client cannot reach a write path".
 * These assertions are the tripwire: the day someone adds a convenient
 * POST /api/scores, this file fails before the endpoint ships.
 */
describe('there is no public score submission endpoint', () => {
  it('no route file imports the internal write path', () => {
    for (const file of readdirSync(ROUTES_DIR).filter((name) => name.endsWith('.ts'))) {
      const source = readFileSync(join(ROUTES_DIR, file), 'utf8');
      expect(source, file).not.toContain('submitMatchResult');
      // Nor may a route hand-roll the write it was denied.
      expect(source, file).not.toMatch(/INSERT\s+INTO\s+scores/i);
    }
  });

  it('no route file declares a mutating leaderboard handler', () => {
    for (const file of readdirSync(ROUTES_DIR).filter((name) => name.endsWith('.ts'))) {
      const source = readFileSync(join(ROUTES_DIR, file), 'utf8');
      if (!file.startsWith('leaderboard')) continue;
      expect(source, file).not.toContain('app.post(');
      expect(source, file).not.toContain('app.put(');
      expect(source, file).not.toContain('app.patch(');
    }
  });

  it('404s the endpoints a cheating client would try first', async () => {
    for (const url of [
      '/api/scores',
      '/api/leaderboard/submit',
      '/api/leaderboard/team_waves/submit',
    ]) {
      const res = await ctx.app.inject({ method: 'POST', url, payload: { value: 999 } });
      expect(res.statusCode, url).toBe(404);
    }
    const onBoard = await ctx.app.inject({
      method: 'POST',
      url: '/api/leaderboard/team_waves',
      payload: { value: 999 },
    });
    expect(onBoard.statusCode).toBe(404);
  });
});
```

- [ ] **Step 6: 跑测试与类型检查**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server && npm run typecheck
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server && npm test
```

Expected: `typecheck` 无输出、退出码 0；`vitest run` 报告 5 个测试文件全部通过，无 skipped、无 unhandled error。

- [ ] **Step 7: 提交**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server add test
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server commit \
  -m "test: cover identity, leaderboard reads, vote branches and protocol drift"
```

Expected: 提交成功，只包含 `test/` 下 6 个文件。

---
### Task 8: 服务端 README 与本地联通路径

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar-server/README.md`

**Interfaces:**
- Consumes: Task 1–7 的全部脚本名、端点与配置项。
- Produces: 文档，无代码接口。README 是「局域网 http 直连为主路径、nginx 443 + wss 为备选」这一决定的落地位置。

- [ ] **Step 1: 写 README.md**

````markdown
# zombiewar-server

`zombiewar` Godot 4 客户端的身份与排行榜后端。独立仓库，与 `zombiewar`、`htz-server` 同级。

- Node ≥ 20.11、TypeScript、Fastify 5、Vitest
- SQLite 单文件持久化（`better-sqlite3`）
- 监听 `0.0.0.0:8787`

本轮（S1）只有身份与排行榜。房间与大厅（S2）、同步层（S3）另行落地，
`src/lib/rooms.ts` / `src/lib/room_hub.ts` / `src/routes/rooms.ts` 是它们的预留位置。

## 快速开始

```bash
npm install
cp .env.example .env
npm run serve          # tsx，直接跑 src/server.ts
# 或
npm run build && npm start
```

| 脚本 | 作用 |
| --- | --- |
| `npm run build` | `tsc -p tsconfig.json` 输出到 `dist/` |
| `npm start` | 跑 `dist/server.js` |
| `npm run dev` | `tsx watch`，改文件自动重启 |
| `npm run serve` | `tsx` 单次运行 |
| `npm run typecheck` | 含 `test/` 的全量类型检查 |
| `npm test` | `vitest run` |

## 端点

| 方法与路径 | 说明 |
| --- | --- |
| `GET /health` | 会真的失败：它会 `SELECT 1` 摸一次 SQLite |
| `GET /api/meta` | 版本号、榜单列表、鉴权模式 |
| `POST /api/auth/anon` | `{device_id, nickname}` 换 token。**不是鉴权** |
| `GET /api/auth/me` | 解析 token；匿名调用返回 200 而非 401 |
| `DELETE /api/auth/anon` | 注销，幂等 |
| `GET /api/leaderboard/:board?season=0&limit=100&offset=0` | 见下表的两种读法；响应带 `total` 供客户端分页 |
| `GET /api/leaderboard/:board/me?season=0` | 需 token，返回本人最佳与名次 |

`:board` 只有 `team_waves` 与 `player_kills`。`season` 本轮固定 `0`。

两个榜的读法**不同**，因为它们计的不是同一种东西：

| board | 分组 | 一行代表 | `total` 计什么 |
| --- | --- | --- | --- |
| `team_waves` | `room_id` | 一场比赛（`nickname` 是全队成员，`members` 是数组） | 房间数 |
| `player_kills` | `player_id` | 一名玩家的最佳单局击杀 | 玩家数 |

`/me` 两个榜都按 `player_id` 回答「我的最佳」——问题是「我这一局打到多少」，
不是「我的队伍在房间榜上第几」。

### 没有成绩提交端点

这不是遗漏。客户端**没有任何写榜路径**——成绩由房间服在进程内调用
`src/lib/leaderboard.ts` 的 `submitMatchResult()` 写入，写入前必须通过：

1. 多数投票交叉验证（所有客户端跑同一份确定性模拟，正常情况数字必然一致）；
2. 服务端合理性上限（单局波次 ≤ 200、击杀 ≤ 波次 × 每波僵尸上限、对局时长下限）；
3. 至少 2 人（1 人房无交叉验证对象，静默跳过写榜）。

投票按**席位**计，不按上报条数计：同一 `player_id` 只有一票（首票为准），不在座位表里的
上报直接忽略，且至少要有 2 份独立上报。这三条各堵住一个洞——「2 人房只有 1 人上报却算
一致通过」「同一个人连发三份伪造上报制造多数」「局外人投票」。

写失败不抛：`submitMatchResult()` 捕获 SQLite 异常、记 `error` 日志、返回
`persisted: false`，由房间服广播「成绩未保存」。一条榜单行不值得让整个房间的进程陪葬。

`test/no-public-submit.test.ts` 会在有人给路由加写入口时让构建失败。

### 「未认证」是真的未认证

`POST /api/auth/anon` 不校验任何凭据。响应里的 `authenticated: false` 与
`auth_mode: "anonymous_device"` 是客户端判断的唯一依据。客户端 UI 必须依据
`authenticated` 字段显示「未认证」，**不得**依据「拿到 token」显示「已认证」。

## 配置

见 `.env.example`。真实环境变量始终压过 `.env` 文件。

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `ZW_HOST` | `0.0.0.0` | 必须是 `0.0.0.0`，否则手机连不上 |
| `ZW_PORT` | `8787` | |
| `ZW_DB_PATH` | `./data/zombiewar.db` | `:memory:` 用于测试 |
| `ZW_ENFORCE_AUTH` | `false` | 打开后下游端点拒绝匿名调用 |
| `ZW_CORS_ORIGIN` | `*` | 逗号分隔白名单 |
| `ZW_TRUST_PROXY` | `false` | 只有确认端口只能被 nginx 摸到时才打开 |
| `ZW_RATE_LIMIT` | `true` | |
| `ZW_MAX_LEADERBOARD_LIMIT` | `100` | `?limit=` 的硬上限 |

## 本地联通：主路径是全 http 局域网直连

Web 导出 `variant/thread_support=false`，不需要 `SharedArrayBuffer`，
所以 `http://<LAN-IP>` 这一非安全上下文不影响游戏运行。

1. 查开发机的局域网地址：

   ```bash
   ipconfig getifaddr en0
   ```

2. 起服务：

   ```bash
   npm run serve
   ```

3. 手机与 Mac 同一 WiFi，游戏页面开 `http://<开发机 LAN IP>:<页面端口>/index.html`，
   API 与 WebSocket 用 `http://<开发机 LAN IP>:8787` / `ws://<开发机 LAN IP>:8787`。

4. 在客户端设置 base URL。**手机上不要去改 `user://net.cfg`**——Web 导出下 `user://`
   落在 IndexedDB，玩家没有文件系统可写。三条通道按优先级：

   - **面板内输入框**（首选）：排行榜面板顶部的「服务器地址」栏直接填 `http://<LAN IP>:8787`
     并点保存，写的就是 `user://net.cfg`。手机、桌面都可用。
   - **Web 导出下的自动缺省**：游戏页和 API 由同一台开发机提供时，`NetConfig.default_base_url()`
     从 `window.location.hostname` 读出主机名拼成 `http://<该主机>:8787`，多数情况下不用填。
     这不是硬编码 IP——地址在运行时从浏览器地址栏取得。
   - **桌面调试**：直接编辑 `user://net.cfg`：

     ```ini
     [net]
     base_url="http://192.0.2.10:8787"
     ```

**这个地址由 DHCP 分配，会变。** 两个仓库的业务代码里都不允许出现具体 IP：
服务端只 bind `0.0.0.0`，客户端从 `user://net.cfg` 或浏览器地址栏取，
兜底缺省值（回环）在 `scripts/net/net_config.gd`。

## 备选：nginx 443 + wss

`zombiewar` 的 README 现有流程用 `https://zombiewar.devlocal.com` 打开游戏。
**HTTPS 页面连接 `ws://` 会被浏览器按混合内容拒绝**，所以要保留 https 流程就必须
让 WebSocket 也走 443。本轮不以此为主路径，方案记录在这里备用。

在 `/opt/homebrew/etc/nginx/vhost/` 下加一个 vhost：

```nginx
server {
    listen 443 ssl;
    include /opt/homebrew/etc/nginx/ssl2.conf;   # 证书复用现有配置
    server_name zombiewar.devlocal.com;
    charset utf8;

    # 代理头照抄 vhost/bk/bk.conf 的 WebSocket 段
    location /api/ {
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
        proxy_pass http://127.0.0.1:8787;
    }
}
```

配套改动：

- 客户端 `user://net.cfg` 写 `base_url="https://zombiewar.devlocal.com"`，
  `net_config.gd` 的 `get_ws_base_url()` 会自动把 `https://` 映射成 `wss://`。
- 服务端设 `ZW_TRUST_PROXY=127.0.0.1`，否则限流会把所有请求算到 nginx 一个 IP 上。
- `proxy_read_timeout` 必须给足：默认 60 秒会把空闲的大厅连接掐断。

```bash
nginx -t && nginx -s reload
curl -k -I https://zombiewar.devlocal.com/api/meta
```

## 协议

`protocol/` 是协议的单一事实源。版本号写在 `PROTOCOL.md` 的 `PROTOCOL_VERSION = N` 一行，
代码侧唯一副本是 `src/lib/protocol/version.ts`，客户端唯一副本是
`res://scripts/net/lobby_protocol.gd`。`protocol/fixtures/*.json` 复制一份到
`zombiewar/tools/validation/fixtures/protocol/`，两端各自对拍。
改协议时**两侧一起改，并递增 `PROTOCOL_VERSION`**。

大厅帧是**扁平 JSON**（`type` 与业务字段同层，没有信封）。`src/lib/protocol/` 目录里
除 `lobby.ts` 外不得出现任何编解码函数——两份编解码就是两种线格式，握手必然死在其中一种上。

握手强制版本校验：客户端连接的第一帧必须携带 `protocol_version`，不匹配时服务端立即
`close(4001, ...)` 并在原因里写出双方版本号——把「两仓库悄悄漂移」从静默缺陷变成一次
带明确信息的响亮失败。
````

- [ ] **Step 2: 确认 README 里的 nginx 引用路径真实存在**

Run:

```bash
ls -l /opt/homebrew/etc/nginx/ssl2.conf /opt/homebrew/etc/nginx/vhost/bk/bk.conf
grep -c 'proxy_set_header Connection "Upgrade"' /opt/homebrew/etc/nginx/vhost/bk/bk.conf
```

Expected: 两个文件都存在；`grep -c` 输出一个大于 0 的数字，确认 README 引用的 WebSocket 代理头模板确有其文。

- [ ] **Step 3: 提交**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server add README.md
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server commit \
  -m "docs: document endpoints, LAN http path and the nginx wss fallback"
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar-server log --oneline
```

Expected: 提交成功；`git log --oneline` **恰好列出 8 个提交**，自上而下为
`docs: document endpoints…` / `test: cover identity…` / `feat: assemble fastify app…` /
`feat: define protocol version…` / `feat: add leaderboard reads…` /
`feat: add anonymous device identity…` / `feat: add sqlite storage…` /
`chore: scaffold zombiewar-server repository`。（Task 5 在客户端仓库另有一次
`chore: vendor protocol fixtures…`，不计入本仓库。）

---

### Task 9: 客户端网络配置与身份存储

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/net_config.gd`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/identity_store.gd`
- **不产出** `scripts/net/protocol_codec.gd`：客户端的协议镜像唯一文件是 S2 Task 7 的 `scripts/net/lobby_protocol.gd`。两个镜像各自定义 `PROTOCOL_VERSION` 与 opcode 号段，等于把「唯一版本号事实源」在客户端复制成两份，下次递增版本必然漏改一个。

**Interfaces:**
- Consumes: 服务端 `PROTOCOL_VERSION = 1`（Task 5，仅作为常量对齐目标，由 S2 的 `LobbyProtocol` 承载）；服务端昵称规则 2–12 字符 + 黑名单（Task 3）。
- Produces:
  - `NetConfig`（`class_name NetConfig`，`extends RefCounted`）：`const CONFIG_PATH := "user://net.cfg"`、`const SECTION := "net"`、`const DEFAULT_BASE_URL := "http://127.0.0.1:8787"`、`const DEFAULT_PORT := 8787`、`const DEFAULT_TIMEOUT_SECONDS := 8.0`、`const DEFAULT_MAX_RETRIES := 2`、`static func normalize_base_url(raw: String) -> String`、`static func default_base_url() -> String`、`static func get_http_base_url() -> String`、`static func get_ws_base_url() -> String`、`static func set_http_base_url(base_url: String) -> Error`、`static func has_override() -> bool`、`static func get_timeout_seconds() -> float`、`static func get_max_retries() -> int`、`static func build_url(path: String) -> String`、`static func to_ws_scheme(http_url: String) -> String`、`static func build_ws_url(path: String) -> String`。
  - `IdentityStore`（`class_name IdentityStore`，`extends RefCounted`）：`const CONFIG_PATH := "user://identity.cfg"`、`const SECTION := "identity"`、`const NICKNAME_MIN_LENGTH := 2`、`const NICKNAME_MAX_LENGTH := 12`、`const NICKNAME_BLOCKLIST: Array[String]`、`static func generate_uuid_v4() -> String`、`static func is_valid_device_id(device_id: String) -> bool`、`static func get_device_id() -> String`、`static func sanitize_nickname(raw: String) -> String`、`static func is_valid_nickname(nickname: String) -> bool`、`static func get_nickname() -> String`、`static func set_nickname(nickname: String) -> Error`、`static func get_token() -> String`、`static func get_player_id() -> String`、`static func has_token() -> bool`、`static func store_session(player_id: String, token: String, nickname: String) -> Error`、`static func clear_session() -> Error`。
- **下游约定（S2 逐字消费）**：`NetConfig.get_http_base_url()` 与 `NetConfig.get_ws_base_url()` 是 base URL 的唯一读法。S2 的 `RoomClient` 需要 base URL 本体去拼房间服下发的 `ws_path` + `?ticket=`，`build_ws_url(path)` 满足不了；`get_base_url` 这个名字在同时存在 http/ws 两种 scheme 时有歧义，因此不保留。

- [ ] **Step 1: 建目录并确认没有旧的网络层**

Run:

```bash
mkdir -p /Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net
cd /Users/liangpingbo/Desktop/4399/game/zombiewar && rg -n "net_config|identity_store|api_client|10\.3\.31\.37" scripts scenes || echo "NO EXISTING NET LAYER"
cd /Users/liangpingbo/Desktop/4399/game/zombiewar && git rev-parse --short HEAD
```

Expected: 输出 `NO EXISTING NET LAYER`（`scripts/`、`scenes/` 里没有网络层，也没有任何硬编码 IP）；HEAD 为 `5423871` 或其之后包含 Task 5 那次 fixtures 提交的哈希。

- [ ] **Step 2: 写 scripts/net/net_config.gd**

```gdscript
extends RefCounted
class_name NetConfig

## 服务端 base URL 的唯一来源。
##
## 开发机的局域网 IP 由 DHCP 分配、随时会变，因此**业务代码里不允许出现具体 IP**。
## 地址按优先级取三处：
##
##   1. user://net.cfg 的 [net] base_url（由排行榜面板的输入框写入，手机上也能改）；
##   2. Web 导出下浏览器地址栏的主机名——游戏页与 API 由同一台开发机提供，
##      所以页面自己的 host 就是正确答案；
##   3. 回环缺省值，只用来让「什么都没配、又不在浏览器里」时行为可预期。

const CONFIG_PATH := "user://net.cfg"
const SECTION := "net"
const DEFAULT_BASE_URL := "http://127.0.0.1:8787"
const DEFAULT_PORT := 8787
const DEFAULT_TIMEOUT_SECONDS := 8.0
const DEFAULT_MAX_RETRIES := 2

## 去掉尾部斜杠并要求显式协议头。返回空串表示这个值不可用。
static func normalize_base_url(raw: String) -> String:
	var trimmed := raw.strip_edges()
	while trimmed.ends_with("/"):
		trimmed = trimmed.substr(0, trimmed.length() - 1)
	if trimmed.is_empty():
		return ""
	if not (trimmed.begins_with("http://") or trimmed.begins_with("https://")):
		return ""
	return trimmed

static func _load_config() -> ConfigFile:
	var config := ConfigFile.new()
	config.load(CONFIG_PATH)
	return config

## Web 导出下页面自己的主机名就是正确答案：游戏页和 API 由同一台开发机提供。
## 这不是硬编码 IP——地址在运行时从浏览器地址栏读出，开发机换网段也不用改代码。
## 手机上 user:// 落在 IndexedDB、玩家没有文件系统可写，这条路径是它唯一好用的缺省。
static func default_base_url() -> String:
	if OS.has_feature("web"):
		var host: Variant = JavaScriptBridge.eval("window.location.hostname", true)
		if typeof(host) == TYPE_STRING and not String(host).is_empty():
			return "http://%s:%d" % [String(host), DEFAULT_PORT]
	return DEFAULT_BASE_URL

static func get_http_base_url() -> String:
	var stored := String(_load_config().get_value(SECTION, "base_url", ""))
	var normalized := normalize_base_url(stored)
	return normalized if not normalized.is_empty() else default_base_url()

## S2 的 RoomClient 要用它去拼房间服下发的 ws_path + "?ticket=…"，
## 所以这里给的是 base 本体，不是某一条具体路径。
static func get_ws_base_url() -> String:
	return to_ws_scheme(get_http_base_url())

static func set_http_base_url(base_url: String) -> Error:
	var normalized := normalize_base_url(base_url)
	if normalized.is_empty():
		return ERR_INVALID_PARAMETER
	var config := _load_config()
	config.set_value(SECTION, "base_url", normalized)
	return config.save(CONFIG_PATH)

## 是否配过一个可用的覆盖值。UI 用它区分「连不上服务器」与「还没填地址」。
static func has_override() -> bool:
	var stored := String(_load_config().get_value(SECTION, "base_url", ""))
	return not normalize_base_url(stored).is_empty()

static func get_timeout_seconds() -> float:
	var stored := float(_load_config().get_value(SECTION, "timeout_seconds", DEFAULT_TIMEOUT_SECONDS))
	return maxf(stored, 1.0)

static func get_max_retries() -> int:
	var stored := int(_load_config().get_value(SECTION, "max_retries", DEFAULT_MAX_RETRIES))
	return clampi(stored, 0, 5)

static func build_url(path: String) -> String:
	var suffix := path if path.begins_with("/") else "/" + path
	return get_http_base_url() + suffix

## http -> ws、https -> wss。纯函数，方便验证脚本直接喂输入。
static func to_ws_scheme(http_url: String) -> String:
	if http_url.begins_with("https://"):
		return "wss://" + http_url.substr(8)
	if http_url.begins_with("http://"):
		return "ws://" + http_url.substr(7)
	return ""

static func build_ws_url(path: String) -> String:
	return to_ws_scheme(build_url(path))
```

- [ ] **Step 3: 写 scripts/net/identity_store.gd**

```gdscript
extends RefCounted
class_name IdentityStore

## 设备身份与会话 token 的持久化。
##
## 设备 ID 是首次运行生成的 UUIDv4，存 user://identity.cfg。Web 导出下 user://
## 落在 IndexedDB，不需要 JavaScriptBridge。
##
## 昵称规则与服务端 src/lib/sessions.ts 逐条对应（2–12 字符、无控制字符、黑名单）。
## 客户端先做一遍是为了给出即时反馈，**服务端仍然是权威**：这里放行不代表能过。

const CONFIG_PATH := "user://identity.cfg"
const SECTION := "identity"
const NICKNAME_MIN_LENGTH := 2
const NICKNAME_MAX_LENGTH := 12
## 必须是 Array[String] 字面量，不能写成 `PackedStringArray([...])`：
## 后者是一次构造调用，GDScript 不认它是常量表达式，本仓库锁定的 Godot 4.7.1 会直接
## 报 `Parse Error: Assigned value for constant "NICKNAME_BLOCKLIST" isn't a constant
## expression`，整个文件加载失败，连带后续所有验证脚本一起挂掉。
const NICKNAME_BLOCKLIST: Array[String] = [
	"admin",
	"administrator",
	"root",
	"system",
	"moderator",
	"official",
	"null",
	"undefined",
	"fuck",
	"shit",
	"管理员",
	"客服",
	"官方",
]

## 这里的 randomize() 属于网络身份层，与 S0 模拟层禁止随机的规则无关：
## 设备 ID 不进入模拟，也不参与任何需要逐位复现的计算。
static func generate_uuid_v4() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var bytes := PackedByteArray()
	bytes.resize(16)
	for index in range(16):
		bytes[index] = rng.randi() & 0xFF
	bytes[6] = (bytes[6] & 0x0F) | 0x40
	bytes[8] = (bytes[8] & 0x3F) | 0x80
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8),
		hex.substr(8, 4),
		hex.substr(12, 4),
		hex.substr(16, 4),
		hex.substr(20, 12),
	]

static func is_valid_device_id(device_id: String) -> bool:
	var regex := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	if regex == null:
		return false
	return regex.search(device_id) != null

static func _load_config() -> ConfigFile:
	var config := ConfigFile.new()
	config.load(CONFIG_PATH)
	return config

## 首次调用生成并落盘；此后每次返回同一个值。
static func get_device_id() -> String:
	var config := _load_config()
	var stored := String(config.get_value(SECTION, "device_id", ""))
	if is_valid_device_id(stored):
		return stored
	var device_id := generate_uuid_v4()
	config.set_value(SECTION, "device_id", device_id)
	config.save(CONFIG_PATH)
	return device_id

## 去掉首尾空白与控制字符，并截到上限。不做黑名单——那是 is_valid_nickname 的事。
static func sanitize_nickname(raw: String) -> String:
	var trimmed := raw.strip_edges()
	var cleaned := ""
	for index in range(trimmed.length()):
		var codepoint := trimmed.unicode_at(index)
		if codepoint >= 32 and codepoint != 127:
			cleaned += trimmed[index]
	if cleaned.length() > NICKNAME_MAX_LENGTH:
		cleaned = cleaned.substr(0, NICKNAME_MAX_LENGTH)
	return cleaned

static func is_valid_nickname(nickname: String) -> bool:
	var length := nickname.length()
	if length < NICKNAME_MIN_LENGTH or length > NICKNAME_MAX_LENGTH:
		return false
	for index in range(length):
		var codepoint := nickname.unicode_at(index)
		if codepoint < 32 or codepoint == 127:
			return false
	var folded := nickname.to_lower()
	for word in NICKNAME_BLOCKLIST:
		if folded.contains(word):
			return false
	return true

static func get_nickname() -> String:
	return String(_load_config().get_value(SECTION, "nickname", ""))

static func set_nickname(nickname: String) -> Error:
	var cleaned := sanitize_nickname(nickname)
	if not is_valid_nickname(cleaned):
		return ERR_INVALID_PARAMETER
	var config := _load_config()
	config.set_value(SECTION, "nickname", cleaned)
	return config.save(CONFIG_PATH)

static func get_token() -> String:
	return String(_load_config().get_value(SECTION, "token", ""))

static func get_player_id() -> String:
	return String(_load_config().get_value(SECTION, "player_id", ""))

static func has_token() -> bool:
	return not get_token().is_empty()

static func store_session(player_id: String, token: String, nickname: String) -> Error:
	var config := _load_config()
	config.set_value(SECTION, "player_id", player_id)
	config.set_value(SECTION, "token", token)
	if not nickname.is_empty():
		config.set_value(SECTION, "nickname", nickname)
	return config.save(CONFIG_PATH)

## 只清会话，不清设备 ID——设备 ID 是这台机器的身份，重新登录仍是同一个玩家。
static func clear_session() -> Error:
	var config := _load_config()
	config.set_value(SECTION, "player_id", "")
	config.set_value(SECTION, "token", "")
	return config.save(CONFIG_PATH)
```

本任务原有的「写 scripts/net/protocol_codec.gd」一步已删除：客户端的协议镜像
唯一文件是 S2 Task 7 的 `scripts/net/lobby_protocol.gd`。在这里再写一个 `ProtocolCodec`，
会让 `PROTOCOL_VERSION`、`OPCODE_*` 与两套语义相反的编解码在客户端各存在两份，
且其中一份没有任何运行时消费者——下一次递增协议版本必然漏改它。

- [ ] **Step 4: 跑 Godot 解析检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
```

Expected: 退出码 0；输出中没有由本次改动引入的 `SCRIPT ERROR`、`Parse Error` 或 `Class name "NetConfig"/"IdentityStore"` 冲突告警。特别确认**没有** `Assigned value for constant "NICKNAME_BLOCKLIST" isn't a constant expression` —— 这条错误意味着黑名单又被写回了 `PackedStringArray([...])` 形式。

- [ ] **Step 5: 提交**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar add \
  scripts/net/net_config.gd scripts/net/net_config.gd.uid \
  scripts/net/identity_store.gd scripts/net/identity_store.gd.uid
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar commit \
  -m "feat: add client net config and identity store"
```

Expected: 提交成功，包含 2 个 `.gd` 与 Godot 生成的 2 个 `.uid`；不含 `.godot/`，不含任何 `protocol_codec.gd`。

---
### Task 10: 客户端 API 客户端

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/net/api_client.gd`

**Interfaces:**
- Consumes: `NetConfig.build_url(path)`、`NetConfig.get_timeout_seconds()`、`NetConfig.get_max_retries()`、`IdentityStore.get_token()`、`IdentityStore.get_device_id()`、`IdentityStore.store_session(player_id, token, nickname)`（Task 9）；服务端 `POST /api/auth/anon`、`GET /api/leaderboard/:board`、`GET /api/leaderboard/:board/me`（Task 3、Task 4）。
- Produces: `ApiClient`（`class_name ApiClient`，`extends Node`）：
  - `signal request_finished(result: Dictionary)`
  - `func _init(host: Node = null) -> void`
  - `static func method_from_name(name: String) -> int`（`"GET"` → `HTTPClient.METHOD_GET`、`"POST"` → `METHOD_POST`、`"DELETE"` → `METHOD_DELETE`，其它返回 `-1`）
  - `static func build_headers(token: String, has_body: bool) -> PackedStringArray`
  - `static func should_retry(godot_result: int, response_code: int) -> bool`
  - `static func parse_response(godot_result: int, response_code: int, body: PackedByteArray) -> Dictionary`
  - `static func retry_delay_seconds(attempt: int) -> float`
  - `func request_json(method: String, path: String, body: Variant = null, on_result: Callable = Callable(), authenticate: bool = true) -> void`
  - `func post_auth_anon(nickname: String, on_result: Callable = Callable()) -> void`
  - `func fetch_leaderboard(board: String, season: int, limit: int, offset: int, on_result: Callable = Callable()) -> void`
  - `func fetch_leaderboard_me(board: String, season: int, on_result: Callable = Callable()) -> void`
  - 统一结果字典：`{"ok": bool, "status_code": int, "payload": Dictionary, "error_code": String, "error_message": String}`
  - 回调签名固定为 `(ok: bool, status_code: int, payload: Dictionary)`；失败时 `payload` 至少含 `{"error": {"code": ..., "message": ...}}`，与服务端错误信封同形。
- **接口形态是回调式而不是 `await` 返回值式**，这一点由 S2 决定并在此对齐：大厅是事件驱动的，`refresh_rooms()` / `create_room()` / `join_by_code()` 都不能阻塞 `_ready()` 与按钮回调；`ApiClientScript.new(self)` 需要 `_init(host)` 把内部 `HTTPRequest` 挂进场景树。方法名 `"GET"` / `"POST"` 传字符串，避免调用点写 `HTTPClient.METHOD_*` 常量。

- [ ] **Step 1: 写 scripts/net/api_client.gd**

```gdscript
extends Node
class_name ApiClient

## HTTPRequest 封装：URL 拼装、token 注入、超时与重试。
##
## 是 Node 而不是 RefCounted，因为每次请求都要挂一个 HTTPRequest 子节点。
## 纯逻辑（构造请求头、判断是否重试、解析响应）拆成 static，好让
## tools/validation/validate_api_client.gd 不起网络就能验。
##
## **接口是回调式的**：request_json() 立刻返回 void，完成时调 on_result。
## 大厅 UI（S2）与本轮的排行榜面板都是事件驱动的，按钮回调与 _ready() 里不能阻塞；
## 一个「等我拿到结果再返回」的 API 会让第一个想在 _ready() 里刷新列表的界面卡住。

const NetConfigScript = preload("res://scripts/net/net_config.gd")
const IdentityStoreScript = preload("res://scripts/net/identity_store.gd")

signal request_finished(result: Dictionary)

## 调用方传进来的场景树宿主。ApiClient 自己是 Node，但调用方常常在 _init 阶段
## 就 new 出来（`ApiClientScript.new(self)`），此时它还不在树里，
## 而 HTTPRequest 必须在树里才会发请求。
var _host: Node = null

func _init(host: Node = null) -> void:
	_host = host

## 字符串方法名换 HTTPClient 常量。未知方法返回 -1，由 request_json 报成一次
## invalid_method 失败——静默降级成 GET 会把一次写操作变成一次读操作。
static func method_from_name(name: String) -> int:
	match name.to_upper():
		"GET":
			return HTTPClient.METHOD_GET
		"POST":
			return HTTPClient.METHOD_POST
		"DELETE":
			return HTTPClient.METHOD_DELETE
		_:
			return -1

## token 只在这里注入，位置固定为 Authorization: Bearer <token>。
## 将来换成平台账号时，这一行是唯一要改的地方。
static func build_headers(token: String, has_body: bool) -> PackedStringArray:
	var headers := PackedStringArray(["Accept: application/json"])
	if has_body:
		headers.append("Content-Type: application/json")
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)
	return headers

## 只重试「再试一次可能会好」的失败。4xx（除 429）是客户端自己的问题，
## 重试只会把一个错误请求打成四个。
static func should_retry(godot_result: int, response_code: int) -> bool:
	if godot_result != HTTPRequest.RESULT_SUCCESS:
		return true
	if response_code == 429:
		return true
	return response_code >= 500 and response_code <= 599

static func retry_delay_seconds(attempt: int) -> float:
	return minf(0.4 * pow(2.0, float(maxi(attempt, 1) - 1)), 3.0)

## 失败时把错误同时塞进 payload，形状与服务端的错误信封一致。
## 回调只收 (ok, status_code, payload) 三个参数，没有这一步，调用方在传输失败时
## 就拿不到 "transport_error" 这个它必须区分的码。
static func _with_error(result: Dictionary, code: String, message: String) -> Dictionary:
	result["error_code"] = code
	result["error_message"] = message
	result["payload"] = {"error": {"code": code, "message": message}}
	return result

## 把 HTTPRequest 的四元组压成一个统一形状，让调用方只看 ok/status_code/payload/error_*。
static func parse_response(godot_result: int, response_code: int, body: PackedByteArray) -> Dictionary:
	var result := {
		"ok": false,
		"status_code": response_code,
		"payload": {},
		"error_code": "",
		"error_message": "",
	}
	if godot_result != HTTPRequest.RESULT_SUCCESS:
		return _with_error(
			result,
			"transport_error",
			"无法连接服务端（HTTPRequest result %d）" % godot_result
		)
	var text := body.get_string_from_utf8()
	if response_code == 204 and text.is_empty():
		result["ok"] = true
		return result
	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if typeof(parsed) != TYPE_DICTIONARY:
		return _with_error(result, "invalid_json", "响应不是 JSON 对象")
	var payload: Dictionary = parsed
	# 非 2xx 也保留 payload：服务端的 {"error":{...}} 正是调用方要读的东西。
	result["payload"] = payload
	if response_code >= 200 and response_code <= 299:
		result["ok"] = true
		return result
	var error_field: Variant = payload.get("error", null)
	if typeof(error_field) == TYPE_DICTIONARY:
		var error_dict: Dictionary = error_field
		result["error_code"] = String(error_dict.get("code", "http_error"))
		result["error_message"] = String(error_dict.get("message", ""))
	else:
		result["error_code"] = "http_error"
		result["error_message"] = "HTTP %d" % response_code
	return result

## 内部含 await，但声明为 -> void 并且不要求调用方 await：
## 调用它会一直执行到第一个 await 然后立刻把控制权还回去，结果通过 on_result 送达。
func request_json(
	method: String,
	path: String,
	body: Variant = null,
	on_result: Callable = Callable(),
	authenticate: bool = true
) -> void:
	var verb := method_from_name(method)
	if verb < 0:
		_deliver(
			_with_error(
				{"ok": false, "status_code": 0, "payload": {}, "error_code": "", "error_message": ""},
				"invalid_method",
				"不支持的 HTTP 方法：%s" % method
			),
			on_result
		)
		return

	_ensure_in_tree()
	var url := NetConfigScript.build_url(path)
	var token := IdentityStoreScript.get_token() if authenticate else ""
	var has_body := body != null
	var headers := build_headers(token, has_body)
	var body_text := JSON.stringify(body) if has_body else ""
	var timeout := NetConfigScript.get_timeout_seconds()
	var max_retries := NetConfigScript.get_max_retries()

	var attempt := 0
	var last := await _perform_once(verb, url, headers, body_text, timeout)
	while should_retry(int(last["godot_result"]), int(last["status"])) and attempt < max_retries:
		attempt += 1
		await get_tree().create_timer(retry_delay_seconds(attempt)).timeout
		last = await _perform_once(verb, url, headers, body_text, timeout)

	_deliver(
		parse_response(
			int(last["godot_result"]),
			int(last["status"]),
			last["body"] as PackedByteArray
		),
		on_result
	)

## 回调先于信号：回调是这次请求的定向答复，信号是给旁观者的广播。
func _deliver(result: Dictionary, on_result: Callable) -> void:
	if on_result.is_valid():
		on_result.call(
			bool(result["ok"]),
			int(result["status_code"]),
			result["payload"] as Dictionary
		)
	request_finished.emit(result)

## HTTPRequest 只有在场景树里才会发请求。调用方通常在自己的 _init/_ready 里
## `ApiClientScript.new(self)`，此时 ApiClient 还没被 add_child，这里补上。
func _ensure_in_tree() -> void:
	if is_inside_tree():
		return
	if _host != null and _host.is_inside_tree():
		_host.add_child(self)

func _perform_once(
	method: int,
	url: String,
	headers: PackedStringArray,
	body_text: String,
	timeout: float
) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout
	add_child(http)
	var error := http.request(url, headers, method, body_text)
	if error != OK:
		http.queue_free()
		return {
			"godot_result": HTTPRequest.RESULT_CANT_CONNECT,
			"status": 0,
			"body": PackedByteArray(),
		}
	var response: Array = await http.request_completed
	http.queue_free()
	return {
		"godot_result": int(response[0]),
		"status": int(response[1]),
		"body": response[3] as PackedByteArray,
	}

## 成功后写入本地会话。注意：拿到 token **不等于**已认证，
## 「已认证 / 未认证」一律由响应里的 authenticated 字段决定。
func post_auth_anon(nickname: String, on_result: Callable = Callable()) -> void:
	var payload := {
		"device_id": IdentityStoreScript.get_device_id(),
		"nickname": nickname,
	}
	request_json(
		"POST",
		"/api/auth/anon",
		payload,
		_on_auth_anon_result.bind(nickname, on_result),
		false
	)

func _on_auth_anon_result(
	ok: bool,
	status_code: int,
	payload: Dictionary,
	nickname: String,
	on_result: Callable
) -> void:
	if ok:
		IdentityStoreScript.store_session(
			String(payload.get("player_id", "")),
			String(payload.get("token", "")),
			String(payload.get("nickname", nickname))
		)
	if on_result.is_valid():
		on_result.call(ok, status_code, payload)

func fetch_leaderboard(
	board: String,
	season: int,
	limit: int,
	offset: int,
	on_result: Callable = Callable()
) -> void:
	var path := "/api/leaderboard/%s?season=%d&limit=%d&offset=%d" % [board, season, limit, offset]
	request_json("GET", path, null, on_result, true)

func fetch_leaderboard_me(board: String, season: int, on_result: Callable = Callable()) -> void:
	var path := "/api/leaderboard/%s/me?season=%d" % [board, season]
	request_json("GET", path, null, on_result, true)
```

- [ ] **Step 2: 跑 Godot 解析检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
```

Expected: 退出码 0；没有 `SCRIPT ERROR` 或 `Parse Error`。

- [ ] **Step 3: 对着真实服务端做一次端到端冒烟**

Run（先在另一个终端起服务端 `npm run serve`）：

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar && cat > /tmp/zw_smoke_api.gd <<'EOF'
extends SceneTree

const ApiClientScript = preload("res://scripts/net/api_client.gd")
const NetConfigScript = preload("res://scripts/net/net_config.gd")

var client = null

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	NetConfigScript.set_http_base_url("http://127.0.0.1:8787")
	client = ApiClientScript.new(root)
	root.add_child(client)
	client.post_auth_anon("冒烟阿波", _on_auth)

func _on_auth(ok: bool, status_code: int, payload: Dictionary) -> void:
	print("auth ok=", ok, " status=", status_code, " authenticated=", payload.get("authenticated", "MISSING"))
	client.fetch_leaderboard("team_waves", 0, 20, 0, _on_board)

func _on_board(ok: bool, status_code: int, payload: Dictionary) -> void:
	print("board ok=", ok, " status=", status_code, " entries=", (payload.get("entries", []) as Array).size(), " total=", payload.get("total", "MISSING"))
	client.fetch_leaderboard_me("team_waves", 0, _on_me)

func _on_me(ok: bool, status_code: int, payload: Dictionary) -> void:
	print("me ok=", ok, " status=", status_code, " entry=", payload.get("entry", "MISSING"))
	quit(0)
EOF
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Users/liangpingbo/Desktop/4399/game/zombiewar --script /tmp/zw_smoke_api.gd
rm -f /tmp/zw_smoke_api.gd
```

Expected:
```
auth ok=true status=201 authenticated=false
board ok=true status=200 entries=0 total=0
me ok=true status=200 entry=<null>
```

`authenticated=false` 是关键：客户端拿到 token 之后服务端仍然明说「未认证」。
这个脚本也顺带验了回调链能一环接一环跑通——三次请求全在回调里发起，没有任何一处 `await`。
它是一次性冒烟，用完即删，不进仓库。

- [ ] **Step 4: 提交**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar add \
  scripts/net/api_client.gd scripts/net/api_client.gd.uid
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar commit \
  -m "feat: add http api client with token injection and retry"
```

Expected: 提交成功，只含 `api_client.gd` 与其 `.uid`；`/tmp/zw_smoke_api.gd` 未被加入。

---

### Task 11: 排行榜面板场景与脚本

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/ui/leaderboard_panel.gd`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scenes/ui/LeaderboardPanel.tscn`

**Interfaces:**
- Consumes: `ApiClient.new(host)`、`ApiClient.post_auth_anon(nickname, on_result)`、`ApiClient.fetch_leaderboard(board, season, limit, offset, on_result)`、`ApiClient.fetch_leaderboard_me(board, season, on_result)`（Task 10）、`IdentityStore.has_token()`、`get_nickname()`、`set_nickname()`、`is_valid_nickname()`、`sanitize_nickname()`、`clear_session()`（Task 9）、`NetConfig.get_http_base_url()`、`NetConfig.set_http_base_url()`、`NetConfig.has_override()`（Task 9）；服务端响应字段 `total`、`authenticated`（Task 4）。
- Produces: `LeaderboardPanel`（`class_name LeaderboardPanel`，`extends CanvasLayer`）：
  - `signal closed`
  - `const BOARD_TEAM_WAVES := "team_waves"`、`const BOARD_PLAYER_KILLS := "player_kills"`、`const PAGE_SIZE := 20`、`const CURRENT_SEASON := 0`、`const MIN_PLAYERS_FOR_RANKING := 2`
  - `const NOTICE_MIN_PLAYERS := "至少 2 人才能上榜（单人房不计分）"`、`const BADGE_UNAUTHENTICATED := "未认证"`、`const BADGE_AUTHENTICATED := "已认证"`、`const DEFAULT_NICKNAME_PREFIX := "玩家"`
  - `static func format_auth_badge(authenticated: bool) -> String`
  - `static func format_board_title(board: String) -> String`
  - `static func format_entry_line(rank: int, nickname: String, value: int, board: String) -> String`
  - `static func format_self_rank(entry: Variant, board: String) -> String`
  - `static func format_page_label(page_index: int, total: int) -> String`
  - `static func has_next(page_index: int, total: int) -> bool`
  - `func open_panel() -> void`、`func close_panel() -> void`、`func select_board(board: String) -> void`、`func refresh() -> void`
- 场景节点契约（唯一名，供验证脚本断言）：`%TeamWavesButton`、`%PlayerKillsButton`、`%EntryList`、`%StatusLabel`、`%AuthLabel`、`%SelfRankLabel`、`%NoticeLabel`、`%PrevPageButton`、`%NextPageButton`、`%PageLabel`、`%CloseButton`、`%BaseUrlEdit`、`%SaveBaseUrlButton`、`%NicknameEdit`、`%SaveNicknameButton`。
- **本任务是全计划唯一调用 `POST /api/auth/anon` 的地方**。没有它，设备 UUID 永远不会生成、`IdentityStore.has_token()` 永远为假、`GET /api/leaderboard/:board/me` 永远打不到，面板会长期显示「我的最佳：本机尚未取得身份」——「匿名设备身份」这条核心需求就没有任何任务实现它。

- [ ] **Step 1: 写 scripts/ui/leaderboard_panel.gd 的常量与纯格式化函数**

```gdscript
extends CanvasLayer
class_name LeaderboardPanel

## 双榜切换 + 分页 + 本人名次 + 匿名身份引导。
##
## 三条硬性 UI 约束来自设计文档，改动前先回去看：
##   1. 「未认证」标记必须依据响应里的 authenticated 字段，不得依据「拿到 token」。
##   2. 必须常驻显示「至少 2 人才能上榜」——1 人房不写榜是已知取舍，
##      玩家有权在打完之前就知道。
##   3. 服务器地址必须能在游戏内改：手机上 user:// 落在 IndexedDB，
##      「请编辑 user://net.cfg」对玩家等于「无法配置」。
##
## 本面板也是全客户端唯一换取匿名 token 的地方（_ensure_identity）。

const ApiClientScript = preload("res://scripts/net/api_client.gd")
const IdentityStoreScript = preload("res://scripts/net/identity_store.gd")
const NetConfigScript = preload("res://scripts/net/net_config.gd")

const BOARD_TEAM_WAVES := "team_waves"
const BOARD_PLAYER_KILLS := "player_kills"
const PAGE_SIZE := 20
const CURRENT_SEASON := 0
const MIN_PLAYERS_FOR_RANKING := 2

const NOTICE_MIN_PLAYERS := "至少 2 人才能上榜（单人房不计分）"
const BADGE_UNAUTHENTICATED := "未认证"
const BADGE_AUTHENTICATED := "已认证"
const DEFAULT_NICKNAME_PREFIX := "玩家"

signal closed

@onready var team_waves_button: Button = %TeamWavesButton
@onready var player_kills_button: Button = %PlayerKillsButton
@onready var entry_list: VBoxContainer = %EntryList
@onready var status_label: Label = %StatusLabel
@onready var auth_label: Label = %AuthLabel
@onready var self_rank_label: Label = %SelfRankLabel
@onready var notice_label: Label = %NoticeLabel
@onready var prev_page_button: Button = %PrevPageButton
@onready var next_page_button: Button = %NextPageButton
@onready var page_label: Label = %PageLabel
@onready var close_button: Button = %CloseButton
@onready var base_url_edit: LineEdit = %BaseUrlEdit
@onready var save_base_url_button: Button = %SaveBaseUrlButton
@onready var nickname_edit: LineEdit = %NicknameEdit
@onready var save_nickname_button: Button = %SaveNicknameButton

var api_client: ApiClient = null
var current_board := BOARD_TEAM_WAVES
var current_page := 0
var is_loading := false
var has_next_page := false
var current_total := 0

## authenticated 为真才显示「已认证」。服务端本轮永远回 false，
## 所以这个分支现在走不到——它存在是为了将来接入平台账号时不用改 UI 代码。
static func format_auth_badge(authenticated: bool) -> String:
	return BADGE_AUTHENTICATED if authenticated else BADGE_UNAUTHENTICATED

static func format_board_title(board: String) -> String:
	return "队伍波次榜" if board == BOARD_TEAM_WAVES else "个人击杀榜"

static func format_entry_line(rank: int, nickname: String, value: int, board: String) -> String:
	var unit := "波" if board == BOARD_TEAM_WAVES else "杀"
	var shown_name := nickname if not nickname.is_empty() else "（无名）"
	return "%2d.  %s  —  %d %s" % [rank, shown_name, value, unit]

static func format_self_rank(entry: Variant, board: String) -> String:
	if typeof(entry) != TYPE_DICTIONARY:
		return "我的最佳：暂无成绩"
	var data: Dictionary = entry
	var unit := "波" if board == BOARD_TEAM_WAVES else "杀"
	return "我的最佳：第 %d 名 · %d %s" % [int(data.get("rank", 0)), int(data.get("value", 0)), unit]

## 分页靠服务端给的 total，而不是「这一页正好装满」。
## 正好 20 条时后者会点亮「下一页」，玩家点过去看到「本榜暂时还没有成绩」——
## 与「榜是空的」长得一模一样。
static func has_next(page_index: int, total: int) -> bool:
	return (page_index + 1) * PAGE_SIZE < total

static func format_page_label(page_index: int, total: int) -> String:
	var pages := maxi(1, ceili(float(total) / float(PAGE_SIZE)))
	return "第 %d / %d 页" % [page_index + 1, pages]
```

- [ ] **Step 2: 在同一文件追加生命周期、匿名身份引导与刷新逻辑**

```gdscript
func _ready() -> void:
	api_client = ApiClientScript.new(self)
	api_client.name = "ApiClient"
	add_child(api_client)
	notice_label.text = NOTICE_MIN_PLAYERS
	auth_label.text = format_auth_badge(false)
	self_rank_label.text = format_self_rank(null, current_board)
	page_label.text = format_page_label(0, 0)
	base_url_edit.text = NetConfigScript.get_http_base_url()
	nickname_edit.text = IdentityStoreScript.get_nickname()
	team_waves_button.button_pressed = true
	player_kills_button.button_pressed = false
	visible = false

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close_panel()
		get_viewport().set_input_as_handled()

func open_panel() -> void:
	visible = true
	current_page = 0
	close_button.grab_focus()
	refresh()

func close_panel() -> void:
	if not visible:
		return
	visible = false
	closed.emit()

func select_board(board: String) -> void:
	if board != BOARD_TEAM_WAVES and board != BOARD_PLAYER_KILLS:
		return
	team_waves_button.button_pressed = board == BOARD_TEAM_WAVES
	player_kills_button.button_pressed = board == BOARD_PLAYER_KILLS
	if board == current_board:
		return
	current_board = board
	current_page = 0
	refresh()

## 刷新是一条回调链：确保身份 → 读当前页 → 读本人名次 → 收尾。
## 每一环都不阻塞，任何一环失败都会走到 _finish_loading()，按钮不会卡在禁用态。
func refresh() -> void:
	if is_loading:
		return
	is_loading = true
	_set_navigation_enabled(false)
	_clear_entries()
	status_label.text = "正在读取 %s…" % NetConfigScript.get_http_base_url()
	_ensure_identity(_load_current_page)

## 首次打开面板时用本机设备 ID 换一次 token。
## 拿到 token **不等于**已认证——「已认证 / 未认证」仍然只看响应里的 authenticated 字段。
##
## 这一步不在别处做是有原因的：排行榜是本轮唯一需要身份的界面，
## 而「打开排行榜」正是玩家第一次表达出「我想被记录」的时刻。
func _ensure_identity(on_done: Callable) -> void:
	if IdentityStoreScript.has_token():
		on_done.call()
		return
	var nickname := IdentityStoreScript.get_nickname()
	if not IdentityStoreScript.is_valid_nickname(nickname):
		# 先给一个能用的名字，玩家随时可以在下面的输入框里改。
		nickname = "%s%04d" % [DEFAULT_NICKNAME_PREFIX, randi() % 10000]
		IdentityStoreScript.set_nickname(nickname)
	api_client.post_auth_anon(nickname, _on_identity_ready.bind(on_done))

func _on_identity_ready(ok: bool, _status_code: int, payload: Dictionary, on_done: Callable) -> void:
	if not ok:
		status_label.text = "匿名身份获取失败：%s" % _error_message_of(payload)
	nickname_edit.text = IdentityStoreScript.get_nickname()
	on_done.call()

func _load_current_page() -> void:
	api_client.fetch_leaderboard(
		current_board,
		CURRENT_SEASON,
		PAGE_SIZE,
		current_page * PAGE_SIZE,
		_on_leaderboard_listed
	)

func _on_leaderboard_listed(ok: bool, _status_code: int, payload: Dictionary) -> void:
	if not ok:
		# 服务端不可达时不假装认证成功，也不假装榜是空的。
		auth_label.text = format_auth_badge(false)
		self_rank_label.text = format_self_rank(null, current_board)
		status_label.text = _describe_failure(payload)
		has_next_page = false
		_finish_loading()
		return

	auth_label.text = format_auth_badge(bool(payload.get("authenticated", false)))
	var entries: Array = payload.get("entries", [])
	for entry_variant in entries:
		if typeof(entry_variant) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entry_variant
		_append_entry(format_entry_line(
			int(entry.get("rank", 0)),
			String(entry.get("nickname", "")),
			int(entry.get("value", 0)),
			current_board
		))
	if entries.is_empty():
		_append_entry("本榜暂时还没有成绩")
	current_total = int(payload.get("total", entries.size()))
	has_next_page = has_next(current_page, current_total)
	page_label.text = format_page_label(current_page, current_total)
	status_label.text = "%s · 共 %d 条" % [format_board_title(current_board), current_total]

	if IdentityStoreScript.has_token():
		api_client.fetch_leaderboard_me(current_board, CURRENT_SEASON, _on_self_rank_read)
		return
	self_rank_label.text = "我的最佳：本机尚未取得身份"
	_finish_loading()

func _on_self_rank_read(ok: bool, _status_code: int, payload: Dictionary) -> void:
	if ok:
		self_rank_label.text = format_self_rank(payload.get("entry", null), current_board)
	else:
		self_rank_label.text = "我的最佳：读取失败（%s）" % _error_code_of(payload)
	_finish_loading()

func _finish_loading() -> void:
	is_loading = false
	_set_navigation_enabled(true)

func _error_field_of(payload: Dictionary) -> Dictionary:
	var error_field: Variant = payload.get("error", null)
	if typeof(error_field) == TYPE_DICTIONARY:
		return error_field as Dictionary
	return {}

func _error_code_of(payload: Dictionary) -> String:
	return String(_error_field_of(payload).get("code", "unknown"))

func _error_message_of(payload: Dictionary) -> String:
	return String(_error_field_of(payload).get("message", ""))

func _describe_failure(payload: Dictionary) -> String:
	var code := _error_code_of(payload)
	if code == "transport_error":
		if NetConfigScript.has_override():
			return "连不上 %s，请确认服务端已启动且在同一局域网" % NetConfigScript.get_http_base_url()
		return "还没配置服务端地址：在上方「服务器地址」里填 http://<开发机 IP>:8787 并保存"
	return "读取失败：%s" % _error_message_of(payload)

func _clear_entries() -> void:
	for child in entry_list.get_children():
		child.queue_free()

func _append_entry(text: String) -> void:
	var label := Label.new()
	label.text = text
	entry_list.add_child(label)

func _set_navigation_enabled(enabled: bool) -> void:
	team_waves_button.disabled = not enabled
	player_kills_button.disabled = not enabled
	prev_page_button.disabled = not enabled or current_page == 0
	next_page_button.disabled = not enabled or not has_next_page
	save_base_url_button.disabled = not enabled
	save_nickname_button.disabled = not enabled

## 换服务器 = 换一整套身份：旧 token 是旧服务端发的，拿到新服务端上没有意义。
func _on_save_base_url_button_pressed() -> void:
	if is_loading:
		return
	if NetConfigScript.set_http_base_url(base_url_edit.text) != OK:
		status_label.text = "地址必须以 http:// 或 https:// 开头，例如 http://192.0.2.10:8787"
		return
	base_url_edit.text = NetConfigScript.get_http_base_url()
	IdentityStoreScript.clear_session()
	current_page = 0
	refresh()

## 改昵称要清掉 token 重新换一次：服务端在 POST /api/auth/anon 时才更新
## players.nickname，只改本地配置的话榜上仍然是旧名字。
## 设备 ID 不受影响，所以还是同一个玩家、同一份历史成绩。
func _on_save_nickname_button_pressed() -> void:
	if is_loading:
		return
	var typed := IdentityStoreScript.sanitize_nickname(nickname_edit.text)
	if not IdentityStoreScript.is_valid_nickname(typed):
		status_label.text = "昵称需要 2–12 个字符，且不能包含屏蔽词"
		return
	IdentityStoreScript.set_nickname(typed)
	IdentityStoreScript.clear_session()
	nickname_edit.text = typed
	refresh()

func _on_team_waves_button_pressed() -> void:
	select_board(BOARD_TEAM_WAVES)

func _on_player_kills_button_pressed() -> void:
	select_board(BOARD_PLAYER_KILLS)

func _on_prev_page_button_pressed() -> void:
	if current_page == 0 or is_loading:
		return
	current_page -= 1
	refresh()

func _on_next_page_button_pressed() -> void:
	if not has_next_page or is_loading:
		return
	current_page += 1
	refresh()

func _on_close_button_pressed() -> void:
	close_panel()
```

- [ ] **Step 3: 写 scenes/ui/LeaderboardPanel.tscn**

```ini
[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://scripts/ui/leaderboard_panel.gd" id="1_panel"]
[ext_resource type="FontFile" path="res://assets/fonts/NotoSansSC-UI.ttf" id="2_cjk_font"]

[sub_resource type="StyleBoxFlat" id="StyleBox_leaderboard_panel"]
bg_color = Color(0.035, 0.043, 0.045, 0.98)
border_width_left = 2
border_width_top = 2
border_width_right = 2
border_width_bottom = 2
border_color = Color(0.72, 0.2, 0.14, 1)
corner_radius_top_left = 5
corner_radius_top_right = 5
corner_radius_bottom_right = 5
corner_radius_bottom_left = 5
shadow_color = Color(0, 0, 0, 0.6)
shadow_size = 18

[node name="LeaderboardPanel" type="CanvasLayer"]
layer = 5
visible = false
script = ExtResource("1_panel")

[node name="Root" type="Control" parent="."]
layout_mode = 3
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2

[node name="Dim" type="ColorRect" parent="Root"]
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
color = Color(0, 0, 0, 0.62)

[node name="Panel" type="PanelContainer" parent="Root"]
custom_minimum_size = Vector2(720, 560)
layout_mode = 1
anchors_preset = 8
anchor_left = 0.5
anchor_top = 0.5
anchor_right = 0.5
anchor_bottom = 0.5
offset_left = -360.0
offset_top = -280.0
offset_right = 360.0
offset_bottom = 280.0
grow_horizontal = 2
grow_vertical = 2
theme_override_styles/panel = SubResource("StyleBox_leaderboard_panel")

[node name="Margin" type="MarginContainer" parent="Root/Panel"]
layout_mode = 2
theme_override_constants/margin_left = 26
theme_override_constants/margin_top = 22
theme_override_constants/margin_right = 26
theme_override_constants/margin_bottom = 22

[node name="Content" type="VBoxContainer" parent="Root/Panel/Margin"]
layout_mode = 2
theme_override_constants/separation = 12

[node name="TitleRow" type="HBoxContainer" parent="Root/Panel/Margin/Content"]
layout_mode = 2
theme_override_constants/separation = 12

[node name="TitleLabel" type="Label" parent="Root/Panel/Margin/Content/TitleRow"]
layout_mode = 2
size_flags_horizontal = 3
theme_override_colors/font_color = Color(0.97, 0.95, 0.9, 1)
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 30
text = "排行榜"

[node name="AuthLabel" type="Label" parent="Root/Panel/Margin/Content/TitleRow"]
unique_name_in_owner = true
layout_mode = 2
theme_override_colors/font_color = Color(0.92, 0.62, 0.24, 1)
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 18
text = "未认证"

[node name="BoardTabs" type="HBoxContainer" parent="Root/Panel/Margin/Content"]
layout_mode = 2
theme_override_constants/separation = 10

[node name="TeamWavesButton" type="Button" parent="Root/Panel/Margin/Content/BoardTabs"]
unique_name_in_owner = true
custom_minimum_size = Vector2(180, 46)
layout_mode = 2
toggle_mode = true
button_pressed = true
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 20
text = "队伍波次榜"

[node name="PlayerKillsButton" type="Button" parent="Root/Panel/Margin/Content/BoardTabs"]
unique_name_in_owner = true
custom_minimum_size = Vector2(180, 46)
layout_mode = 2
toggle_mode = true
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 20
text = "个人击杀榜"

[node name="ServerRow" type="HBoxContainer" parent="Root/Panel/Margin/Content"]
layout_mode = 2
theme_override_constants/separation = 8

[node name="ServerLabel" type="Label" parent="Root/Panel/Margin/Content/ServerRow"]
layout_mode = 2
theme_override_colors/font_color = Color(0.72, 0.75, 0.76, 1)
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 16
text = "服务器地址"

[node name="BaseUrlEdit" type="LineEdit" parent="Root/Panel/Margin/Content/ServerRow"]
unique_name_in_owner = true
custom_minimum_size = Vector2(0, 40)
layout_mode = 2
size_flags_horizontal = 3
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 16
placeholder_text = "http://192.0.2.10:8787"

[node name="SaveBaseUrlButton" type="Button" parent="Root/Panel/Margin/Content/ServerRow"]
unique_name_in_owner = true
custom_minimum_size = Vector2(96, 40)
layout_mode = 2
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 16
text = "保存"

[node name="IdentityRow" type="HBoxContainer" parent="Root/Panel/Margin/Content"]
layout_mode = 2
theme_override_constants/separation = 8

[node name="NicknameLabel" type="Label" parent="Root/Panel/Margin/Content/IdentityRow"]
layout_mode = 2
theme_override_colors/font_color = Color(0.72, 0.75, 0.76, 1)
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 16
text = "我的昵称"

[node name="NicknameEdit" type="LineEdit" parent="Root/Panel/Margin/Content/IdentityRow"]
unique_name_in_owner = true
custom_minimum_size = Vector2(0, 40)
layout_mode = 2
size_flags_horizontal = 3
max_length = 12
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 16
placeholder_text = "2–12 个字符"

[node name="SaveNicknameButton" type="Button" parent="Root/Panel/Margin/Content/IdentityRow"]
unique_name_in_owner = true
custom_minimum_size = Vector2(96, 40)
layout_mode = 2
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 16
text = "保存"

[node name="StatusLabel" type="Label" parent="Root/Panel/Margin/Content"]
unique_name_in_owner = true
layout_mode = 2
theme_override_colors/font_color = Color(0.72, 0.75, 0.76, 1)
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 16
text = "正在读取…"

[node name="EntryScroll" type="ScrollContainer" parent="Root/Panel/Margin/Content"]
layout_mode = 2
size_flags_vertical = 3

[node name="EntryList" type="VBoxContainer" parent="Root/Panel/Margin/Content/EntryScroll"]
unique_name_in_owner = true
layout_mode = 2
size_flags_horizontal = 3
theme_override_constants/separation = 6

[node name="SelfRankLabel" type="Label" parent="Root/Panel/Margin/Content"]
unique_name_in_owner = true
layout_mode = 2
theme_override_colors/font_color = Color(0.97, 0.95, 0.9, 1)
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 20
text = "我的最佳：暂无成绩"

[node name="NoticeLabel" type="Label" parent="Root/Panel/Margin/Content"]
unique_name_in_owner = true
layout_mode = 2
theme_override_colors/font_color = Color(0.92, 0.62, 0.24, 1)
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 16
text = "至少 2 人才能上榜（单人房不计分）"

[node name="PageRow" type="HBoxContainer" parent="Root/Panel/Margin/Content"]
layout_mode = 2
theme_override_constants/separation = 12
alignment = 1

[node name="PrevPageButton" type="Button" parent="Root/Panel/Margin/Content/PageRow"]
unique_name_in_owner = true
custom_minimum_size = Vector2(120, 44)
layout_mode = 2
disabled = true
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 18
text = "上一页"

[node name="PageLabel" type="Label" parent="Root/Panel/Margin/Content/PageRow"]
unique_name_in_owner = true
custom_minimum_size = Vector2(120, 0)
layout_mode = 2
horizontal_alignment = 1
vertical_alignment = 1
theme_override_colors/font_color = Color(0.97, 0.95, 0.9, 1)
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 18
text = "第 1 页"

[node name="NextPageButton" type="Button" parent="Root/Panel/Margin/Content/PageRow"]
unique_name_in_owner = true
custom_minimum_size = Vector2(120, 44)
layout_mode = 2
disabled = true
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 18
text = "下一页"

[node name="CloseButton" type="Button" parent="Root/Panel/Margin/Content"]
unique_name_in_owner = true
custom_minimum_size = Vector2(0, 50)
layout_mode = 2
theme_override_fonts/font = ExtResource("2_cjk_font")
theme_override_font_sizes/font_size = 20
text = "返回"

[connection signal="pressed" from="Root/Panel/Margin/Content/BoardTabs/TeamWavesButton" to="." method="_on_team_waves_button_pressed"]
[connection signal="pressed" from="Root/Panel/Margin/Content/BoardTabs/PlayerKillsButton" to="." method="_on_player_kills_button_pressed"]
[connection signal="pressed" from="Root/Panel/Margin/Content/ServerRow/SaveBaseUrlButton" to="." method="_on_save_base_url_button_pressed"]
[connection signal="pressed" from="Root/Panel/Margin/Content/IdentityRow/SaveNicknameButton" to="." method="_on_save_nickname_button_pressed"]
[connection signal="pressed" from="Root/Panel/Margin/Content/PageRow/PrevPageButton" to="." method="_on_prev_page_button_pressed"]
[connection signal="pressed" from="Root/Panel/Margin/Content/PageRow/NextPageButton" to="." method="_on_next_page_button_pressed"]
[connection signal="pressed" from="Root/Panel/Margin/Content/CloseButton" to="." method="_on_close_button_pressed"]
```

- [ ] **Step 4: 跑 Godot 导入与解析检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar diff --check
```

Expected: 退出码 0；没有 `SCRIPT ERROR`、`Parse Error` 或 `Cannot open file 'res://scenes/ui/LeaderboardPanel.tscn'`；`git diff --check` 无输出。

- [ ] **Step 5: 提交**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar add \
  scripts/ui/leaderboard_panel.gd scripts/ui/leaderboard_panel.gd.uid \
  scenes/ui/LeaderboardPanel.tscn
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar commit \
  -m "feat: add leaderboard panel with dual boards and paging"
```

Expected: 提交成功，含 `.gd`、`.gd.uid` 与 `.tscn`。

---
### Task 12: 主菜单「排行榜」入口

> **执行顺序：本任务必须在 S2 Task 12（插入 `OnlineMultiplayerButton`）之后执行。**
> 两个计划都往 `MenuLayer/MenuRoot/LeftColumn/Actions` 的同一个位置插按钮、都要改
> `LocalMultiplayerButton.focus_neighbor_bottom` 与 `QuitButton.focus_neighbor_top`。
> 钉死的唯一顺序是
> `SinglePlayerButton → LocalMultiplayerButton → OnlineMultiplayerButton → LeaderboardButton → QuitButton`：
> 联机在排行榜之上，与交付顺序一致。S2 先把在线按钮插在 `LocalMultiplayerButton` 与
> `QuitButton` 之间，本任务再把排行榜按钮插在 `OnlineMultiplayerButton` 与 `QuitButton` 之间。

**Files:**（跨计划共享文件一律不写行号——S2 改完后任何行号都是错的，用文本锚点）
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/menu/menu_flow.gd`（`enum State` 末尾追加一项；`confirm_exit()` 之后追加两个函数）
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scripts/menu/main_menu.gd`（**增量追加，不整体替换**——S2 已在同一文件里加过在线联机的处理函数）
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/scenes/menu/MainMenu.tscn`（改两处 `focus_neighbor`；在 `QuitButton` 节点块之前插入新节点；在 `OnlineMultiplayerButton` 的三条 connection 之后插入三行）
- Modify: `/Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/validate_local_multiplayer_menu_scenes.gd`（既有脚本断言「本地多人的下一个焦点是退出」，插入两个按钮后必然失败，本任务负责改）

**Interfaces:**
- Consumes: `LeaderboardPanel.open_panel()`、`LeaderboardPanel.close_panel()`、`LeaderboardPanel.closed` 信号（Task 11）；现有 `MenuFlow.State`、`MenuFlow.request_single()`、`request_local()`、`request_exit()`、`cancel_exit()`、`confirm_exit()`；S2 Task 12 已加的 `%OnlineMultiplayerButton` 与 `MainMenu._on_online_multiplayer_button_pressed()`。
- Produces:
  - `MenuFlow.State.LEADERBOARD`（枚举新增项，加在**当前末尾**——若 S2 已追加过条目，仍加在它之后，以免改动既有序号）
  - `MenuFlow.request_leaderboard() -> bool`
  - `MenuFlow.close_leaderboard() -> bool`
  - `MainMenu._on_leaderboard_button_pressed() -> void`
  - `MainMenu._on_leaderboard_panel_closed() -> void`
  - 场景节点 `%LeaderboardButton`（路径 `MenuLayer/MenuRoot/LeftColumn/Actions/LeaderboardButton`）

- [ ] **Step 1: 给 MenuFlow 增加排行榜状态**

把 `scripts/menu/menu_flow.gd` 的枚举改为（**新项加在末尾**，不要插在中间：既有序号被 `.tscn` 之外的代码按名字引用，但保持稳定序号仍是廉价的谨慎）：

```gdscript
enum State {
	READY,
	STARTING,
	EXIT_CONFIRM,
	LEADERBOARD,
}
```

若 S2 已在此枚举里追加过条目，把 `LEADERBOARD` 放在它之后，仍然是最后一项。

并在 `confirm_exit()` 之后追加：

```gdscript
func request_leaderboard() -> bool:
	if state != State.READY:
		return false
	state = State.LEADERBOARD
	return true

func close_leaderboard() -> bool:
	if state != State.LEADERBOARD:
		return false
	state = State.READY
	return true
```

排行榜与「正在进入游戏」「退出确认」互斥，走的是与它们同一套门控：面板开着时再点开始会被 `_request_start()` 挡掉，因为 `state` 不是 `READY`。

- [ ] **Step 2: 改 scripts/menu/main_menu.gd**

**不要整体替换这个文件。** S2 Task 12 已经在其中加过 `%OnlineMultiplayerButton` 与
`_on_online_multiplayer_button_pressed()`，整体替换会把它们静默删掉。按下面五处文本锚点做增量修改：

**(1)** 在 `const MenuFlow = preload("res://scripts/menu/menu_flow.gd")` 之后追加一行：

```gdscript
const LeaderboardPanelScene = preload("res://scenes/ui/LeaderboardPanel.tscn")
```

**(2)** 在 `@onready var quit_button: Button = %QuitButton` 之**前**插入一行：

```gdscript
@onready var leaderboard_button: Button = %LeaderboardButton
```

**(3)** 在 `var flow := MenuFlow.new()` 之后追加一行：

```gdscript
var leaderboard_panel: LeaderboardPanel = null
```

**(4)** 把 `_ready()` 改成（原来只有 `single_player_button.grab_focus()` 一行；
若 S2 已往里加过东西，保留它们，只补前四行）：

```gdscript
func _ready() -> void:
	# 面板从代码挂载而不是摆进 MainMenu.tscn：主菜单只需要知道「有个排行榜」，
	# 不需要把面板的十几个节点复制进自己的场景树里。
	leaderboard_panel = LeaderboardPanelScene.instantiate()
	leaderboard_panel.name = "LeaderboardPanel"
	add_child(leaderboard_panel)
	leaderboard_panel.closed.connect(_on_leaderboard_panel_closed)
	single_player_button.grab_focus()
```

**(5)** 在 `func _start_transition(scene_path: String) -> void:` 这一行之**前**插入两个函数，
并在 `_start_transition()` 的 `quit_button.disabled = true` 之**前**插入一行
`leaderboard_button.disabled = true`：

```gdscript
func _on_leaderboard_button_pressed() -> void:
	if not flow.request_leaderboard():
		return
	confirm_audio.play()
	leaderboard_panel.open_panel()

## 面板自己处理 ui_cancel 与「返回」按钮，两条路径都收敛到 closed 信号，
## 所以这里是唯一需要把 flow 拨回 READY 的地方。
func _on_leaderboard_panel_closed() -> void:
	if not flow.close_leaderboard():
		return
	back_audio.play()
	leaderboard_button.grab_focus()
```

改完后 `_start_transition()` 的禁用段应当是：

```gdscript
	single_player_button.disabled = true
	local_multiplayer_button.disabled = true
	online_multiplayer_button.disabled = true   # S2 加的，保留
	leaderboard_button.disabled = true
	quit_button.disabled = true
```

- [ ] **Step 3: 在 MainMenu.tscn 插入排行榜按钮**

`scenes/menu/MainMenu.tscn` 不新增 `ext_resource`（S2 Task 12 同样不新增），因此
**`load_steps=14` 保持不变**。

**锚点已被 S2 改过**：`LocalMultiplayerButton.focus_neighbor_bottom` 此时指向的是
`../OnlineMultiplayerButton` 而不是 `../QuitButton`，本任务**不动它**。要改的是在线按钮
与退出按钮各一行。

把 `OnlineMultiplayerButton` 的这一行（S2 刚写下的）：

```ini
focus_neighbor_bottom = NodePath("../QuitButton")
```

改成：

```ini
focus_neighbor_bottom = NodePath("../LeaderboardButton")
```

把 `QuitButton` 的这一行（同样是 S2 刚写下的）：

```ini
focus_neighbor_top = NodePath("../OnlineMultiplayerButton")
```

改成：

```ini
focus_neighbor_top = NodePath("../LeaderboardButton")
```

并在 `[node name="QuitButton" ...]` 这一行**之前**（即 `OnlineMultiplayerButton` 节点块之后）
插入整块新节点（样式逐项照抄同级按钮，保证外观一致）：

```ini
[node name="LeaderboardButton" type="Button" parent="MenuLayer/MenuRoot/LeftColumn/Actions"]
unique_name_in_owner = true
custom_minimum_size = Vector2(390, 66)
layout_mode = 2
focus_neighbor_top = NodePath("../OnlineMultiplayerButton")
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
text = "排行榜"
alignment = 0
```

- [ ] **Step 4: 在 MainMenu.tscn 追加信号连接**

在 `OnlineMultiplayerButton` 的三条连接之后、`QuitButton` 的连接之前，插入三行
（连接段的顺序不影响运行，但与节点顺序保持一致能让下一个读这个文件的人少查一次）：

```ini
[connection signal="focus_entered" from="MenuLayer/MenuRoot/LeftColumn/Actions/LeaderboardButton" to="." method="_on_action_focused"]
[connection signal="mouse_entered" from="MenuLayer/MenuRoot/LeftColumn/Actions/LeaderboardButton" to="." method="_on_action_focused"]
[connection signal="pressed" from="MenuLayer/MenuRoot/LeftColumn/Actions/LeaderboardButton" to="." method="_on_leaderboard_button_pressed"]
```

- [ ] **Step 5: 更新既有的 validate_local_multiplayer_menu_scenes.gd**

`tools/validation/validate_local_multiplayer_menu_scenes.gd` 里有一条既有断言
「本地多人的下一个焦点必须是退出」（`local_button.focus_neighbor_bottom ==
local_button.get_path_to(quit_button)`）。中间插进两个按钮后它必然变红，而这个脚本
不属于任何一份新计划的产出——不在这里修，它就会以「谁先跑谁弄红」的方式留给下一个人。

把该脚本里取三个按钮、逐条比对 focus 的那一段，替换为按序遍历整条链：

```gdscript
		var actions_path := "MenuLayer/MenuRoot/LeftColumn/Actions"
		# 唯一的按钮顺序，两份计划共用。改顺序就要改这里，改这里就会立刻发现改错了顺序。
		var chain_names := [
			"SinglePlayerButton",
			"LocalMultiplayerButton",
			"OnlineMultiplayerButton",
			"LeaderboardButton",
			"QuitButton",
		]
		var chain: Array[Button] = []
		for button_name in chain_names:
			var button := main.get_node_or_null("%s/%s" % [actions_path, button_name]) as Button
			_expect(button != null, "MainMenu must contain %s" % button_name, failures)
			if button != null:
				chain.append(button)
		if chain.size() == chain_names.size():
			for index in range(chain.size() - 1):
				var upper: Button = chain[index]
				var lower: Button = chain[index + 1]
				_expect(
					upper.focus_neighbor_bottom == upper.get_path_to(lower),
					"%s must move focus down to %s" % [chain_names[index], chain_names[index + 1]],
					failures
				)
				_expect(
					lower.focus_neighbor_top == lower.get_path_to(upper),
					"%s must move focus up to %s" % [chain_names[index + 1], chain_names[index]],
					failures
				)
		main.free()
```

S2 Task 12 对同一脚本的改动只是把 `OnlineMultiplayerButton` 加进 `chain_names`；
本任务加 `LeaderboardButton`。两次都在同一个数组里加一行，不重写断言块。

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Users/liangpingbo/Desktop/4399/game/zombiewar \
  --script res://tools/validation/validate_local_multiplayer_menu_scenes.gd
```

Expected: 打印 `validate_local_multiplayer_menu_scenes: PASS`，退出码 0。

- [ ] **Step 6: 跑 Godot 导入与解析检查，并核对场景结构**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
cd /Users/liangpingbo/Desktop/4399/game/zombiewar && head -1 scenes/menu/MainMenu.tscn
cd /Users/liangpingbo/Desktop/4399/game/zombiewar && grep -c "LeaderboardButton" scenes/menu/MainMenu.tscn
```

Expected: Godot 退出码 0，无 `SCRIPT ERROR` / `Parse Error`；`head -1` 仍为
`[gd_scene load_steps=14 format=3]`；`grep -c "LeaderboardButton" scenes/menu/MainMenu.tscn`
输出 **`6`**（节点声明 1 + `OnlineMultiplayerButton` 的 `focus_neighbor_bottom` 1 +
`QuitButton` 的 `focus_neighbor_top` 1 + 3 条 connection；本按钮自己的两个
`focus_neighbor` 写的是 `../OnlineMultiplayerButton` 与 `../QuitButton`，不含本名）。

- [ ] **Step 7: 提交**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar add \
  scripts/menu/menu_flow.gd scripts/menu/main_menu.gd scenes/menu/MainMenu.tscn \
  tools/validation/validate_local_multiplayer_menu_scenes.gd
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar commit \
  -m "feat: add leaderboard entry to the main menu"
```

Expected: 提交成功，只含这四个文件。

---

### Task 13: 客户端一次性验证脚本

**Files:**
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/validate_api_client.gd`
- Create: `/Users/liangpingbo/Desktop/4399/game/zombiewar/tools/validation/validate_leaderboard_panel.gd`
- **不产出** `tools/validation/validate_protocol_codec.gd`：它对拍的 `ProtocolCodec` 已不存在。fixtures 与协议版本的对拍职责合并进 S2 Task 13 的 `validate_online_lobby_wiring.gd`，断言为 `LobbyProtocol.PROTOCOL_VERSION == manifest.protocol_version` 且 `LobbyProtocol.decode(LobbyProtocol.encode(msg))` 还原同一 Dictionary。

**Interfaces:**
- Consumes: `NetConfig.normalize_base_url`、`to_ws_scheme`、`build_url`、`get_http_base_url`、`get_ws_base_url`、`default_base_url`、`DEFAULT_BASE_URL`（Task 9）；`IdentityStore.generate_uuid_v4`、`is_valid_device_id`、`sanitize_nickname`、`is_valid_nickname`、`NICKNAME_MIN_LENGTH`、`NICKNAME_MAX_LENGTH`、`NICKNAME_BLOCKLIST`（Task 9）；`ApiClient.method_from_name`、`build_headers`、`should_retry`、`parse_response`、`retry_delay_seconds`（Task 10）；`LeaderboardPanel.format_auth_badge`、`format_entry_line`、`format_self_rank`、`format_board_title`、`format_page_label`、`has_next`、`NOTICE_MIN_PLAYERS`、`BADGE_UNAUTHENTICATED`、`MIN_PLAYERS_FOR_RANKING`、`PAGE_SIZE`（Task 11）；`MenuFlow.request_leaderboard`、`close_leaderboard`（Task 12）。
- Produces: 两个 `SceneTree` 脚本，成功打印 `validate_xxx: PASS` 并 `quit(0)`，失败逐条 `push_error` 并 `quit(1)`。写法与目录内既有脚本一致（`extends SceneTree` + `_init()` 里 `call_deferred("_run")` + `_expect()` 收集失败）。

- [ ] **Step 1: 写 tools/validation/validate_api_client.gd**

```gdscript
extends SceneTree

const NetConfigScript = preload("res://scripts/net/net_config.gd")
const IdentityStoreScript = preload("res://scripts/net/identity_store.gd")
const ApiClientScript = preload("res://scripts/net/api_client.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_base_url(failures)
	_check_identity(failures)
	_check_headers(failures)
	_check_retry(failures)
	_check_parse(failures)
	_finish(failures)

func _check_base_url(failures: Array[String]) -> void:
	_expect(NetConfigScript.normalize_base_url("http://10.0.0.5:8787/") == "http://10.0.0.5:8787", "normalize must strip a trailing slash", failures)
	_expect(NetConfigScript.normalize_base_url("  https://a.b/  ") == "https://a.b", "normalize must trim whitespace", failures)
	_expect(NetConfigScript.normalize_base_url("10.0.0.5:8787").is_empty(), "normalize must reject a missing scheme", failures)
	_expect(NetConfigScript.normalize_base_url("").is_empty(), "normalize must reject an empty value", failures)
	_expect(NetConfigScript.to_ws_scheme("http://a.b:8787/api/x") == "ws://a.b:8787/api/x", "http must map to ws", failures)
	_expect(NetConfigScript.to_ws_scheme("https://a.b/api/x") == "wss://a.b/api/x", "https must map to wss", failures)
	_expect(NetConfigScript.to_ws_scheme("ftp://a.b").is_empty(), "unknown schemes must map to an empty ws url", failures)
	var base := NetConfigScript.get_http_base_url()
	_expect(base.begins_with("http://") or base.begins_with("https://"), "base url must always carry a scheme", failures)
	_expect(NetConfigScript.build_url("/api/meta") == base + "/api/meta", "build_url must append the path to the base", failures)
	_expect(NetConfigScript.build_url("api/meta") == base + "/api/meta", "build_url must insert the missing leading slash", failures)
	# S2 的 RoomClient 逐字消费这两个名字去拼 ws_path + "?ticket="。
	var ws_base := NetConfigScript.get_ws_base_url()
	_expect(ws_base.begins_with("ws://") or ws_base.begins_with("wss://"), "the ws base url must carry a ws scheme", failures)
	_expect(ws_base == NetConfigScript.to_ws_scheme(base), "the ws base must be the http base with its scheme swapped", failures)
	# 硬编码 IP 是本设计明确禁止的：地址只能来自 user://net.cfg 或浏览器地址栏，
	# 兜底缺省值是回环。桌面上 default_base_url() 必须就是那个回环值。
	_expect(NetConfigScript.DEFAULT_BASE_URL == "http://127.0.0.1:8787", "the fallback base url must be loopback, never a LAN address", failures)
	if not OS.has_feature("web"):
		_expect(NetConfigScript.default_base_url() == NetConfigScript.DEFAULT_BASE_URL, "on desktop the default must stay loopback — no LAN address may be baked in", failures)

func _check_identity(failures: Array[String]) -> void:
	var first := IdentityStoreScript.generate_uuid_v4()
	var second := IdentityStoreScript.generate_uuid_v4()
	_expect(IdentityStoreScript.is_valid_device_id(first), "generated device id must be a valid UUIDv4", failures)
	_expect(first != second, "two generated device ids must differ", failures)
	_expect(first.length() == 36, "device id must be 36 characters", failures)
	_expect(not IdentityStoreScript.is_valid_device_id("not-a-uuid"), "malformed device ids must be rejected", failures)
	_expect(IdentityStoreScript.NICKNAME_MIN_LENGTH == 2, "nickname floor must match the server", failures)
	_expect(IdentityStoreScript.NICKNAME_MAX_LENGTH == 12, "nickname ceiling must match the server", failures)
	_expect(not IdentityStoreScript.is_valid_nickname("a"), "1-character nicknames must be rejected", failures)
	_expect(IdentityStoreScript.is_valid_nickname("阿波"), "2-character CJK nicknames must be accepted", failures)
	_expect(IdentityStoreScript.is_valid_nickname("十二个字符恰好到这里啦"), "an 11-character nickname must be accepted", failures)
	_expect(not IdentityStoreScript.is_valid_nickname("x".repeat(13)), "13-character nicknames must be rejected", failures)
	_expect(not IdentityStoreScript.is_valid_nickname("管理员"), "blocklisted nicknames must be rejected", failures)
	_expect(not IdentityStoreScript.is_valid_nickname("ADMIN"), "the blocklist must be case-insensitive", failures)
	_expect(IdentityStoreScript.sanitize_nickname("  阿波  ") == "阿波", "sanitize must trim", failures)
	_expect(IdentityStoreScript.sanitize_nickname("x".repeat(20)).length() == 12, "sanitize must clamp to the ceiling", failures)

func _check_headers(failures: Array[String]) -> void:
	# S2 传的是字符串方法名，不是 HTTPClient 常量。未知方法必须报错而不是悄悄当 GET。
	_expect(ApiClientScript.method_from_name("GET") == HTTPClient.METHOD_GET, "\"GET\" must map to METHOD_GET", failures)
	_expect(ApiClientScript.method_from_name("post") == HTTPClient.METHOD_POST, "method names must be case-insensitive", failures)
	_expect(ApiClientScript.method_from_name("DELETE") == HTTPClient.METHOD_DELETE, "\"DELETE\" must map to METHOD_DELETE", failures)
	_expect(ApiClientScript.method_from_name("TELEPORT") < 0, "an unknown method must be rejected, not silently downgraded to GET", failures)

	var anonymous := ApiClientScript.build_headers("", false)
	_expect(not _has_prefix(anonymous, "Authorization:"), "no token must mean no Authorization header", failures)
	_expect(_has_prefix(anonymous, "Accept: application/json"), "every request must accept JSON", failures)
	_expect(not _has_prefix(anonymous, "Content-Type:"), "a bodyless request must not declare a content type", failures)
	var authorized := ApiClientScript.build_headers("tok123", true)
	_expect(authorized.has("Authorization: Bearer tok123"), "the token must be injected as a bearer header", failures)
	_expect(authorized.has("Content-Type: application/json"), "a request with a body must declare JSON", failures)

func _check_retry(failures: Array[String]) -> void:
	_expect(ApiClientScript.should_retry(HTTPRequest.RESULT_CANT_CONNECT, 0), "a transport failure must be retried", failures)
	_expect(ApiClientScript.should_retry(HTTPRequest.RESULT_SUCCESS, 503), "a 503 must be retried", failures)
	_expect(ApiClientScript.should_retry(HTTPRequest.RESULT_SUCCESS, 429), "a 429 must be retried", failures)
	_expect(not ApiClientScript.should_retry(HTTPRequest.RESULT_SUCCESS, 200), "a 200 must not be retried", failures)
	_expect(not ApiClientScript.should_retry(HTTPRequest.RESULT_SUCCESS, 400), "a 400 must not be retried", failures)
	_expect(not ApiClientScript.should_retry(HTTPRequest.RESULT_SUCCESS, 401), "a 401 must not be retried", failures)
	_expect(ApiClientScript.retry_delay_seconds(1) < ApiClientScript.retry_delay_seconds(2), "retry backoff must grow", failures)
	_expect(ApiClientScript.retry_delay_seconds(10) <= 3.0, "retry backoff must stay capped", failures)

func _check_parse(failures: Array[String]) -> void:
	var ok := ApiClientScript.parse_response(
		HTTPRequest.RESULT_SUCCESS,
		200,
		JSON.stringify({"authenticated": false, "entries": []}).to_utf8_buffer()
	)
	_expect(bool(ok["ok"]), "a 200 with a JSON object must be ok", failures)
	_expect(bool((ok["payload"] as Dictionary)["authenticated"]) == false, "the authenticated field must survive parsing", failures)
	_expect(int(ok["status_code"]) == 200, "the result dictionary must key the code as status_code", failures)

	var created := ApiClientScript.parse_response(
		HTTPRequest.RESULT_SUCCESS,
		201,
		JSON.stringify({"player_id": "p", "token": "t"}).to_utf8_buffer()
	)
	_expect(bool(created["ok"]), "a 201 must be ok", failures)

	var no_content := ApiClientScript.parse_response(HTTPRequest.RESULT_SUCCESS, 204, PackedByteArray())
	_expect(bool(no_content["ok"]), "a 204 with an empty body must be ok", failures)

	var unauthorized := ApiClientScript.parse_response(
		HTTPRequest.RESULT_SUCCESS,
		401,
		JSON.stringify({"error": {"code": "unauthenticated", "message": "需要 token"}}).to_utf8_buffer()
	)
	_expect(not bool(unauthorized["ok"]), "a 401 must not be ok", failures)
	_expect(String(unauthorized["error_code"]) == "unauthenticated", "the server error code must be surfaced", failures)
	_expect(String(unauthorized["error_message"]) == "需要 token", "the server error message must be surfaced", failures)
	_expect(int(unauthorized["status_code"]) == 401, "the status code must be surfaced", failures)
	# 回调只收 (ok, status_code, payload)，所以 payload 里也必须带得上错误码，
	# 否则面板分不出「连不上」和「服务端说不行」。
	_expect(
		_payload_error_code(unauthorized) == "unauthenticated",
		"the error must also reach the callback through payload.error.code",
		failures
	)

	var offline := ApiClientScript.parse_response(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray())
	_expect(not bool(offline["ok"]), "a transport failure must not be ok", failures)
	_expect(String(offline["error_code"]) == "transport_error", "a transport failure must be labelled", failures)
	_expect(
		_payload_error_code(offline) == "transport_error",
		"a synthesised transport error must look like a server error envelope",
		failures
	)

	var garbage := ApiClientScript.parse_response(HTTPRequest.RESULT_SUCCESS, 200, "<html>".to_utf8_buffer())
	_expect(not bool(garbage["ok"]), "a non-JSON 200 must not be ok", failures)
	_expect(String(garbage["error_code"]) == "invalid_json", "a non-JSON body must be labelled", failures)

func _has_prefix(headers: PackedStringArray, prefix: String) -> bool:
	for header in headers:
		if header.begins_with(prefix):
			return true
	return false

## 从统一结果字典里挖出 payload.error.code。回调只收三个参数，
## 面板只能从 payload 里读错误码，所以这条路径必须是通的。
func _payload_error_code(result: Dictionary) -> String:
	var payload_variant: Variant = result.get("payload", null)
	if typeof(payload_variant) != TYPE_DICTIONARY:
		return ""
	var error_variant: Variant = (payload_variant as Dictionary).get("error", null)
	if typeof(error_variant) != TYPE_DICTIONARY:
		return ""
	return String((error_variant as Dictionary).get("code", ""))

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_api_client: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

本任务原有的 `validate_protocol_codec.gd` 一步已删除：它要对拍的 `ProtocolCodec` 已不在计划里
（客户端协议镜像唯一文件是 S2 的 `scripts/net/lobby_protocol.gd`）。fixtures 与协议版本号的
对拍职责整体移交给 S2 Task 13 的 `validate_online_lobby_wiring.gd`，那里断言：

- `LobbyProtocol.PROTOCOL_VERSION == manifest.protocol_version`；
- `LobbyProtocol.decode(LobbyProtocol.encode(msg))` 还原出同一个 Dictionary；
- `LobbyProtocol.DEFAULT_TICK_RATE == roundi(1.0 / SimClock.TICK_SECONDS)`。

本计划这一侧只保留 fixtures 文件本身（Task 5 Step 4 复制过来），它们在 S2 落地前是
静态资产：客户端此时还没有能解析扁平帧的代码，硬要在这里对拍就得先把 S2 的编解码抄一份，
而那正是这次拆分要消灭的第二份事实源。

- [ ] **Step 2: 写 tools/validation/validate_leaderboard_panel.gd**

```gdscript
extends SceneTree

const MenuFlowScript = preload("res://scripts/menu/menu_flow.gd")
const LeaderboardPanelScript = preload("res://scripts/ui/leaderboard_panel.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_check_formatting(failures)
	_check_panel_scene(failures)
	_check_menu_entry(failures)
	_finish(failures)

func _check_formatting(failures: Array[String]) -> void:
	# 设计文档的硬约束：未认证标记依据 authenticated 字段，不依据「拿到 token」。
	_expect(LeaderboardPanelScript.format_auth_badge(false) == "未认证", "a false authenticated flag must render 未认证", failures)
	_expect(LeaderboardPanelScript.format_auth_badge(true) == "已认证", "a true authenticated flag must render 已认证", failures)
	_expect(LeaderboardPanelScript.NOTICE_MIN_PLAYERS.contains("2 人"), "the panel must state the 2-player floor", failures)
	_expect(LeaderboardPanelScript.MIN_PLAYERS_FOR_RANKING == 2, "the client-side floor must match the server", failures)
	_expect(LeaderboardPanelScript.PAGE_SIZE > 0, "page size must be positive", failures)
	_expect(LeaderboardPanelScript.CURRENT_SEASON == 0, "this round is frozen at season 0", failures)
	_expect(LeaderboardPanelScript.BOARD_TEAM_WAVES == "team_waves", "board id must match the server", failures)
	_expect(LeaderboardPanelScript.BOARD_PLAYER_KILLS == "player_kills", "board id must match the server", failures)
	_expect(LeaderboardPanelScript.format_board_title("team_waves") == "队伍波次榜", "team board title", failures)
	_expect(LeaderboardPanelScript.format_board_title("player_kills") == "个人击杀榜", "kills board title", failures)

	var wave_line := LeaderboardPanelScript.format_entry_line(1, "阿波", 12, "team_waves")
	_expect(wave_line.contains("阿波") and wave_line.contains("12") and wave_line.contains("波"), "a wave row must show rank, name, value and unit", failures)
	var kill_line := LeaderboardPanelScript.format_entry_line(3, "", 40, "player_kills")
	_expect(kill_line.contains("（无名）"), "an empty nickname must render a placeholder", failures)
	_expect(kill_line.contains("杀"), "a kills row must use the kills unit", failures)

	_expect(LeaderboardPanelScript.format_self_rank(null, "team_waves").contains("暂无成绩"), "no personal score must say so", failures)
	var self_line := LeaderboardPanelScript.format_self_rank({"rank": 7, "value": 9}, "team_waves")
	_expect(self_line.contains("7") and self_line.contains("9"), "a personal rank must show both rank and value", failures)

	# 分页依据服务端的 total，不是「这一页正好装满」。
	# 恰好 20 条时点亮「下一页」会把玩家送到一个与「空榜」长得一样的空页。
	var size: int = LeaderboardPanelScript.PAGE_SIZE
	_expect(not LeaderboardPanelScript.has_next(0, size), "a board with exactly one full page must not offer a next page", failures)
	_expect(LeaderboardPanelScript.has_next(0, size + 1), "one more row than a page must offer a next page", failures)
	_expect(not LeaderboardPanelScript.has_next(1, size + 1), "the last page must not offer a next page", failures)
	_expect(LeaderboardPanelScript.format_page_label(0, 0).contains("1 / 1"), "an empty board must still read as page 1 of 1", failures)
	_expect(LeaderboardPanelScript.format_page_label(1, size * 3).contains("2 / 3"), "the page label must show position and count", failures)

func _check_panel_scene(failures: Array[String]) -> void:
	var scene := load("res://scenes/ui/LeaderboardPanel.tscn") as PackedScene
	_expect(scene != null, "LeaderboardPanel scene must load", failures)
	if scene == null:
		return
	var panel = scene.instantiate()
	_expect(panel is CanvasLayer, "the panel root must be a CanvasLayer so it can overlay the 3D menu", failures)
	_expect(panel.has_signal("closed"), "the panel must expose a closed signal", failures)
	for method_name in [
		"open_panel",
		"close_panel",
		"select_board",
		"refresh",
		# 全客户端唯一换取匿名 token 的地方。少了它，设备 UUID 永远不会生成、
		# /me 永远打不到，「匿名设备身份」这条需求就没有任何代码实现它。
		"_ensure_identity",
		"_on_save_base_url_button_pressed",
		"_on_save_nickname_button_pressed",
	]:
		_expect(panel.has_method(method_name), "the panel must expose %s()" % method_name, failures)
	var required := {
		"Root/Panel/Margin/Content/TitleRow/AuthLabel": "Label",
		"Root/Panel/Margin/Content/BoardTabs/TeamWavesButton": "Button",
		"Root/Panel/Margin/Content/BoardTabs/PlayerKillsButton": "Button",
		# 服务器地址必须能在游戏内改：手机上 user:// 落在 IndexedDB，
		# 「请编辑 user://net.cfg」对玩家等于「无法配置」。
		"Root/Panel/Margin/Content/ServerRow/BaseUrlEdit": "LineEdit",
		"Root/Panel/Margin/Content/ServerRow/SaveBaseUrlButton": "Button",
		# 昵称输入是匿名身份唯一的可见入口——没有它，玩家在榜上永远叫「玩家1234」。
		"Root/Panel/Margin/Content/IdentityRow/NicknameEdit": "LineEdit",
		"Root/Panel/Margin/Content/IdentityRow/SaveNicknameButton": "Button",
		"Root/Panel/Margin/Content/StatusLabel": "Label",
		"Root/Panel/Margin/Content/EntryScroll/EntryList": "VBoxContainer",
		"Root/Panel/Margin/Content/SelfRankLabel": "Label",
		"Root/Panel/Margin/Content/NoticeLabel": "Label",
		"Root/Panel/Margin/Content/PageRow/PrevPageButton": "Button",
		"Root/Panel/Margin/Content/PageRow/PageLabel": "Label",
		"Root/Panel/Margin/Content/PageRow/NextPageButton": "Button",
		"Root/Panel/Margin/Content/CloseButton": "Button",
	}
	for node_path in required:
		var node := panel.get_node_or_null(node_path)
		_expect(node != null, "panel must contain %s" % node_path, failures)
		if node != null:
			_expect(node.is_class(required[node_path]), "%s must be a %s" % [node_path, required[node_path]], failures)
			_expect(node.unique_name_in_owner, "%s must be marked unique_name_in_owner" % node_path, failures)
	var notice := panel.get_node_or_null("Root/Panel/Margin/Content/NoticeLabel") as Label
	if notice != null:
		_expect(notice.text.contains("2 人"), "the 2-player notice must be visible before any request completes", failures)
	panel.free()

func _check_menu_entry(failures: Array[String]) -> void:
	var flow = MenuFlowScript.new()
	_expect(flow.has_method("request_leaderboard"), "MenuFlow must expose request_leaderboard", failures)
	_expect(flow.has_method("close_leaderboard"), "MenuFlow must expose close_leaderboard", failures)
	if flow.has_method("request_leaderboard") and flow.has_method("close_leaderboard"):
		_expect(flow.request_leaderboard(), "a ready flow must accept opening the leaderboard", failures)
		_expect(not flow.request_leaderboard(), "an open leaderboard must reject a second open", failures)
		_expect(not flow.request_single(), "the leaderboard must block starting a game", failures)
		_expect(flow.close_leaderboard(), "an open leaderboard must accept closing", failures)
		_expect(not flow.close_leaderboard(), "a closed leaderboard must reject a second close", failures)
		_expect(flow.request_single(), "closing the leaderboard must return the flow to ready", failures)

	var main_scene := load("res://scenes/menu/MainMenu.tscn") as PackedScene
	_expect(main_scene != null, "MainMenu scene must load", failures)
	if main_scene == null:
		return
	var main = main_scene.instantiate()
	var actions_path := "MenuLayer/MenuRoot/LeftColumn/Actions"
	# 唯一的按钮顺序，与 S2 共用：联机在排行榜之上，与交付顺序一致。
	var online_button := main.get_node_or_null("%s/OnlineMultiplayerButton" % actions_path) as Button
	var leaderboard_button := main.get_node_or_null("%s/LeaderboardButton" % actions_path) as Button
	var quit_button := main.get_node_or_null("%s/QuitButton" % actions_path) as Button
	_expect(leaderboard_button != null, "MainMenu must contain LeaderboardButton", failures)
	_expect(online_button != null, "MainMenu must still contain OnlineMultiplayerButton (S2)", failures)
	if leaderboard_button != null and online_button != null and quit_button != null:
		_expect(leaderboard_button.text == "排行榜", "the leaderboard entry must be labelled 排行榜", failures)
		_expect(leaderboard_button.unique_name_in_owner, "LeaderboardButton must be unique_name_in_owner", failures)
		# 插入排行榜按钮不得把在线按钮挤出焦点链——键盘/手柄用户会再也 Tab 不到它。
		_expect(online_button.focus_neighbor_bottom == online_button.get_path_to(leaderboard_button), "online multiplayer focus must move down to the leaderboard", failures)
		_expect(leaderboard_button.focus_neighbor_top == leaderboard_button.get_path_to(online_button), "leaderboard focus must move up to online multiplayer", failures)
		_expect(leaderboard_button.focus_neighbor_bottom == leaderboard_button.get_path_to(quit_button), "leaderboard focus must move down to quit", failures)
		_expect(quit_button.focus_neighbor_top == quit_button.get_path_to(leaderboard_button), "quit focus must move up to the leaderboard", failures)
	main.free()

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_leaderboard_panel: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 3: 跑三个验证脚本**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Users/liangpingbo/Desktop/4399/game/zombiewar \
  --script res://tools/validation/validate_api_client.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Users/liangpingbo/Desktop/4399/game/zombiewar \
  --script res://tools/validation/validate_leaderboard_panel.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Users/liangpingbo/Desktop/4399/game/zombiewar \
  --script res://tools/validation/validate_local_multiplayer_menu_scenes.gd
```

Expected: 三条命令分别打印 `validate_api_client: PASS`、`validate_leaderboard_panel: PASS`、`validate_local_multiplayer_menu_scenes: PASS`，退出码均为 0。第三条是既有脚本（Task 12 已更新它的焦点链断言），在这里再跑一次，确认插入排行榜按钮没有把在线按钮挤出焦点链。

- [ ] **Step 4: 确认没有恢复常驻测试套件，且没有硬编码 IP**

Run:

```bash
cd /Users/liangpingbo/Desktop/4399/game/zombiewar && ls tests 2>&1 | head -1
cd /Users/liangpingbo/Desktop/4399/game/zombiewar && rg -n "10\.3\.31\.37|192\.168\.|devlocal\.com" scripts scenes tools || echo "NO HARDCODED HOSTS"
cd /Users/liangpingbo/Desktop/4399/game/zombiewar && git status --short
```

Expected:
- 第一条输出 `ls: tests: No such file or directory` —— `tests/` 仍不存在，未被恢复。
- 第二条输出 `NO HARDCODED HOSTS`。（`net_config.gd` 里只有回环缺省值与运行时从
  `window.location.hostname` 读出的主机名，不含任何 LAN 地址字面量。）
- `git status --short` 只列出本任务新增的两个验证脚本及其 `.uid`。

- [ ] **Step 5: 跑一次全量静态检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --editor --path /Users/liangpingbo/Desktop/4399/game/zombiewar --quit
cd /Users/liangpingbo/Desktop/4399/game/zombiewar-server && npm run typecheck && npm test
```

Expected: Godot 退出码 0 且无 `SCRIPT ERROR` / `Parse Error`；服务端 `typecheck` 无输出、`vitest run` 全绿。

- [ ] **Step 6: 提交**

```bash
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar add \
  tools/validation/validate_api_client.gd tools/validation/validate_api_client.gd.uid \
  tools/validation/validate_leaderboard_panel.gd tools/validation/validate_leaderboard_panel.gd.uid
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar commit \
  -m "test: add one-off validation for the api client and leaderboard panel"
git -C /Users/liangpingbo/Desktop/4399/game/zombiewar log --oneline -6
```

Expected: 提交成功；`git log --oneline -6` **恰好列出本计划在 `zombiewar` 留下的 6 个提交**，
自上而下为 `test: add one-off validation…` / `feat: add leaderboard entry to the main menu` /
`feat: add leaderboard panel…` / `feat: add http api client…` /
`feat: add client net config and identity store` / `chore: vendor protocol fixtures from zombiewar-server`；
其中没有任何 `tests/` 路径下的文件。（若 S2 的提交夹在中间，按名字认这 6 条，不按位置。）

---

## 人工验收清单

以下项无法从源码层可靠验证，不使用 CUA 自动化。请用户执行并提供截图：

1. **服务端起在局域网**：在开发机跑 `ipconfig getifaddr en0` 取得 LAN IP，`npm run serve` 起服务，用手机浏览器打开 `http://<LAN IP>:8787/api/meta`。截图应显示 `"enforced": false`、`"score_submission": "none..."`。
2. **在游戏内配置服务器地址**：在客户端主菜单点「排行榜」，在面板顶部「服务器地址」栏填 `http://<LAN IP>:8787` 并点保存。截图应显示状态行变成「队伍波次榜 · 共 0 条」之类的成功文案，而不是连接失败。（Web 导出且页面与 API 同机时，这一栏应该已经预填好了正确地址——那说明 `default_base_url()` 从浏览器地址栏读到了主机名。）
3. **匿名登录与「未认证」**：接上一步，面板首次打开时会自动用本机设备 ID 换一次匿名 token。截图应同时出现：橙色「未认证」标记、「至少 2 人才能上榜（单人房不计分）」提示、「我的昵称」栏里自动生成的 `玩家NNNN`、以及「我的最佳：暂无成绩」（**不是**「本机尚未取得身份」——后者意味着换 token 失败了）。
4. **改昵称后榜上跟着变**：把昵称改成两个汉字并保存，面板会重新换一次 token 并刷新。再用 `curl http://<LAN IP>:8787/api/auth/me -H "Authorization: Bearer <token>"` 或直接看下一次上榜结果确认服务端记的是新名字。
5. **双榜切换与空榜文案**：在面板内切换「队伍波次榜」与「个人击杀榜」。首次运行两榜都应显示「本榜暂时还没有成绩」，页码显示「第 1 / 1 页」，且「下一页」保持禁用。
6. **离线降级**：把服务端停掉再点开排行榜。截图应显示「连不上 …，请确认服务端已启动且在同一局域网」，而不是空白面板或崩溃。
7. **不存在可用的成绩提交端点**：`curl -i -X POST http://<LAN IP>:8787/api/leaderboard/team_waves -d '{"value":999}' -H 'Content-Type: application/json'`。截图应为 `404`。

