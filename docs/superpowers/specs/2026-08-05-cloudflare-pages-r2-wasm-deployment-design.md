# Cloudflare Pages + 私有 R2 同域 WASM 部署设计

## 背景

Godot 4.7.1 Web 导出的 `index.wasm` 当前约为 37.7 MiB，超过 Cloudflare Pages 单个静态资源 25 MiB 的限制。现有部署通过 gzip 压缩和浏览器端显式解压绕过上传限制，但生成文件需要额外修改，且依赖 `DecompressionStream`。

本设计改为由 Cloudflare Pages 承载 HTML、JavaScript、PCK 和图片等小型静态资源，将原始 WASM 保存到私有 R2，并由同一个 Pages 项目的 Advanced Mode Worker 在 `/index.wasm` 路径流式返回。浏览器和 Godot 加载器不感知 R2，也不需要跨域配置。

## 目标

- 保持生产入口为 `https://zombiewar.pages.dev`。
- 浏览器继续请求 Godot 默认路径 `/index.wasm`。
- 原始 WASM 不进入 Pages 静态资源包，因此不受 25 MiB 限制。
- R2 bucket 保持私有，不启用 `r2.dev` 或单独的公开域名。
- 在仓库中提供本机和 CI/CD 均可重复执行的一键部署流程。
- 每个 Pages 部署与其 WASM 版本原子匹配，旧部署不被后续上传破坏。

## 非目标

- 不迁移整个站点到 Workers Static Assets。
- 不为 R2 创建公开域名或调整现有 DNS。
- 不在第一版自动删除历史 WASM 对象。
- 不修改 Godot 游戏逻辑、场景或运行时资源结构。

## 方案比较

### 方案一：Pages Advanced Mode Worker + 私有 R2（采用）

在 Pages 输出目录放置 `_worker.js`，只让 `/index.wasm` 进入 Worker。Worker 使用 R2 binding 获取版本化 WASM 对象，其他资源由 Pages 静态资源系统提供。

优点：同域、私有、路径稳定、控制明确，适合 Direct Upload 和 CI/CD。缺点：每次 WASM 请求会产生一次 Pages Functions 调用。

### 方案二：文件式 Pages Function

通过 `functions/index.wasm.js` 映射路由并读取 R2。文件更小，但 Direct Upload 对 Functions 源目录和构建过程的处理较隐式，部署产物不如 Advanced Mode Worker 直观。

### 方案三：整站迁移到 Worker

使用 Worker Static Assets 承载小文件，并绑定 R2。架构统一，但需要替换现有 Pages 部署模型和生产入口，迁移范围超出本任务。

## 总体架构

```text
浏览器
  ├─ /、/index.html、/index.js、/index.pck、图片和音频
  │    └─ Cloudflare Pages 静态资源
  └─ /index.wasm
       └─ Pages Advanced Mode Worker
            └─ 私有 R2 binding
                 └─ wasm/index-<sha256>.wasm
```

`_routes.json` 只包含 `/index.wasm`，其他静态资源不进入 Worker。Worker 仍保留 `env.ASSETS.fetch(request)` 作为防御性回退。

## 版本与原子性

部署脚本计算原始 `build/web/index.wasm` 的 SHA-256，并使用以下 R2 key：

```text
wasm/index-<完整 sha256>.wasm
```

Pages 包中的 `_worker.js` 由模板生成，内嵌本次部署对应的 R2 key。部署顺序固定为：

1. 完成 Godot Web 导出。
2. 上传版本化 WASM 到 R2。
3. 生成引用该 key 的 Pages Worker。
4. 部署 Pages。

如果 R2 上传失败，不发布 Pages。如果 Pages 发布失败，版本化 R2 对象仅成为未引用对象，不影响当前生产版本。旧 Pages 部署继续引用旧 key，因此后续部署不会改变旧版本行为。

## 仓库文件

```text
wrangler.jsonc
tools/cloudflare/deploy_r2_pages.sh
tools/cloudflare/pages_worker.template.js
tools/cloudflare/_routes.json
tools/cloudflare/_headers
```

生成目录继续位于被 Git 忽略的 `build/`：

```text
build/web/
build/cloudflare-pages/
```

部署脚本不会提交 `build/` 或 `.godot/` 内容。

## Wrangler 配置

`wrangler.jsonc` 声明：

- Pages 项目名 `zombiewar`。
- Pages 输出目录 `build/cloudflare-pages`。
- 当前兼容日期。
- 名为 `GAME_ASSETS` 的 R2 binding。
- 默认 bucket `zombiewar-assets`。

本机使用现有 Wrangler OAuth 登录态。CI/CD 使用：

```text
CLOUDFLARE_API_TOKEN
CLOUDFLARE_ACCOUNT_ID
```

部署参数允许通过环境变量覆盖：

```text
CLOUDFLARE_PAGES_PROJECT
CLOUDFLARE_R2_BUCKET
CLOUDFLARE_BRANCH
```

默认值分别为 `zombiewar`、`zombiewar-assets` 和 `main`。

## 部署脚本

`tools/cloudflare/deploy_r2_pages.sh` 使用 `set -euo pipefail`，依次执行：

1. 检查 Godot、Node/npm、Wrangler 和基础文件。
2. 运行 Godot headless Web release 导出。
3. 计算 WASM SHA-256 和版本化 R2 key。
4. 检查 R2 bucket；不存在时创建。
5. 上传原始 WASM，设置 `Content-Type: application/wasm`。
6. 重建 `build/cloudflare-pages`，复制 Web 产物但排除 `index.wasm`。
7. 从模板生成包含 R2 key 的 `_worker.js`。
8. 复制 `_routes.json` 和 `_headers`。
9. 验证 Pages 包没有超过 25 MiB 的文件。
10. 使用 Wrangler 发布 Pages。
11. 对生产地址执行响应头和 WASM 内容校验。

脚本提供 `--prepare-only`：完成导出和 Pages 包生成，但不创建 bucket、不上传 R2、不部署 Pages，供测试和 CI 预检查使用。

## Worker 行为

### `GET /index.wasm`

- 使用内嵌版本化 key 调用 `env.GAME_ASSETS.get()`。
- 对象存在时直接流式返回 `object.body`。
- 强制设置 `Content-Type: application/wasm`。
- 返回对象 ETag，并使用项目当前要求的 no-cache 响应头。

### `HEAD /index.wasm`

- 使用 `env.GAME_ASSETS.head()` 查询元数据。
- 返回与 GET 一致的状态和响应头，但不返回 body。

### 其他路径

- 调用 `env.ASSETS.fetch(request)`，作为路由配置失效时的安全回退。

### 错误

- R2 对象不存在：返回 `503` 和明确的纯文本诊断。
- R2 访问异常：返回 `502`，不回退到 HTML 或压缩的旧 WASM。
- 不在响应或日志中泄露凭据。

## 缓存与安全响应头

HTML 和 WASM 沿用项目现有验证要求：

```text
Cache-Control: no-store, no-cache, must-revalidate, max-age=0
```

静态页面通过 `_headers` 获得：

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

由于 `_headers` 不作用于 Functions 响应，Worker 会自行设置 WASM 的 MIME、缓存和必要隔离响应头。

## 测试策略

### 自动化契约测试

扩展 `tests/unit/test_project_contract.gd`，验证：

- `wrangler.jsonc` 包含 Pages 输出目录和 `GAME_ASSETS` R2 binding。
- `_routes.json` 只将 `/index.wasm` 路由给 Worker。
- Worker 模板包含 GET、HEAD、R2 读取、`application/wasm` 和静态资源回退。
- 部署脚本使用版本化 SHA-256 key、排除 Pages 中的原始 WASM，并支持 `--prepare-only`。

### 静态检查

```bash
bash -n tools/cloudflare/deploy_r2_pages.sh
node --check tools/cloudflare/pages_worker.template.js
```

### 本地产物检查

运行 `--prepare-only` 后验证：

- `build/cloudflare-pages/index.wasm` 不存在。
- `_worker.js` 引用的 R2 key 与本地 WASM SHA-256 一致。
- Pages 包中不存在超过 25 MiB 的文件。

### 正式部署验证

- `/` 返回 `200` 和预期缓存、隔离响应头。
- `/index.wasm` 的 GET 与 HEAD 返回 `200` 和 `application/wasm`。
- 线上 WASM SHA-256 与本地原始 WASM 相同。
- 浏览器能进入主菜单并开始游戏场景。

## 历史对象管理

第一版保留所有版本化 WASM，避免删除仍被历史 Pages 部署引用的对象。后续如需控制存储量，应基于 Pages 部署保留策略或 R2 生命周期规则单独设计，不能简单只保留最新对象。

## 成功标准

- 一条命令可在本机或 CI/CD 完成完整部署。
- Pages 上传目录中没有超过 25 MiB 的文件。
- R2 bucket 不公开。
- 生产 URL 和 Godot 请求路径保持不变。
- 线上 WASM 与本地导出文件哈希一致。
- 完整 Godot 测试套件通过，浏览器主菜单和游戏场景正常运行。
