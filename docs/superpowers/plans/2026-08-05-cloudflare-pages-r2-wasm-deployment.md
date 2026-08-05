# Cloudflare Pages + 私有 R2 同域 WASM 部署 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将超过 Cloudflare Pages 25 MiB 限制的 Godot `index.wasm` 保存到私有 R2，并通过同域 Pages Worker 流式返回，同时提供本机和 CI/CD 可重复执行的一键部署脚本。

**Architecture:** Godot 继续导出标准 Web 包。部署脚本把原始 WASM 上传到私有 R2 的版本化 SHA-256 key，Pages 包排除 WASM并生成 `_worker.js`；`_routes.json` 只把 `/index.wasm` 路由给 Worker，其他资源继续由 Pages 静态服务提供。

**Tech Stack:** Godot 4.7.1、GDScript 自定义测试、Node.js 24 内置测试运行器、Bash、Wrangler 4.x、Cloudflare Pages Advanced Mode Worker、Cloudflare R2。

## Global Constraints

- 生产入口保持 `https://zombiewar.pages.dev`，Godot 请求路径保持 `/index.wasm`。
- R2 bucket 保持私有，不启用 `r2.dev`，不新增 DNS 或公开域名。
- Pages 静态包不得包含原始 `index.wasm`，且任何单文件不得超过 25 MiB。
- R2 object key 必须使用完整 WASM SHA-256：`wasm/index-<sha256>.wasm`。
- R2 上传成功后才能部署引用该 key 的 Pages 版本。
- 第一版不删除历史 WASM 对象，避免破坏历史 Pages 部署。
- CI 凭据只从 `CLOUDFLARE_API_TOKEN` 和 `CLOUDFLARE_ACCOUNT_ID` 读取，不写入仓库。
- 默认 Pages 项目和分支分别为 `zombiewar`、`main`，允许环境变量覆盖；R2 bucket 固定为 `wrangler.jsonc` 中的 `zombiewar-assets`。
- 不提交 `build/` 或 `.godot/` 生成内容。
- 不创建 worktree：用户已确认在当前分支直接执行；任何既有未提交修改均视为用户内容并避开。

## 文件结构

- `wrangler.jsonc`：Pages 输出目录、兼容日期和 `GAME_ASSETS` R2 binding 的唯一配置源。
- `tools/cloudflare/pages_worker.template.js`：Advanced Mode Worker 模板，通过 `__WASM_OBJECT_KEY__` 注入版本化 R2 key。
- `tools/cloudflare/_routes.json`：只将 `/index.wasm` 交给 Worker。
- `tools/cloudflare/_headers`：Pages 静态页面的缓存和跨源隔离响应头。
- `tools/cloudflare/deploy_r2_pages.sh`：Godot 导出、R2 上传、Pages 包准备、发布和线上校验的一键入口。
- `tests/integration/cloudflare_r2_worker.test.mjs`：用 Node 内置测试运行器验证 Worker 的 GET、HEAD、错误和静态回退行为。
- `tests/integration/test_cloudflare_r2_deployment.gd`：注册到 Godot 自定义测试套件，执行 Node Worker 测试并验证配置和 `--prepare-only` 产物。
- `tests/test_runner.gd`：注册新的部署集成测试。
- `README.md`：记录本机及 CI/CD 的 R2 部署命令、环境变量和验证方式。

---

### Task 1: R2 Worker、Wrangler 配置与行为测试

**Files:**
- Create: `wrangler.jsonc`
- Create: `tools/cloudflare/pages_worker.template.js`
- Create: `tools/cloudflare/_routes.json`
- Create: `tools/cloudflare/_headers`
- Create: `tests/integration/cloudflare_r2_worker.test.mjs`
- Create: `tests/integration/test_cloudflare_r2_deployment.gd`
- Modify: `tests/test_runner.gd`

**Interfaces:**
- Consumes: `__WASM_OBJECT_KEY__` 模板占位符；Pages runtime 的 `env.GAME_ASSETS` R2 binding 与 `env.ASSETS` 静态资源 binding。
- Produces: `export default { fetch(request, env) }`；`GET|HEAD /index.wasm` 返回 R2 对象；其他路径调用 `env.ASSETS.fetch(request)`。

- [ ] **Step 1: 写入 Worker 行为和配置的失败测试**

创建 `tests/integration/cloudflare_r2_worker.test.mjs`，通过读取模板、替换 key 并用 `data:` URL 动态导入真实 Worker：

```javascript
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const template = await readFile(
	new URL("../../tools/cloudflare/pages_worker.template.js", import.meta.url),
	"utf8",
);
const source = template.replaceAll("__WASM_OBJECT_KEY__", "wasm/index-test.wasm");
const moduleUrl = `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`;
const worker = (await import(moduleUrl)).default;

function createObject() {
	return {
		body: new Response(new Uint8Array([0, 97, 115, 109])).body,
		httpEtag: '"test-etag"',
		writeHttpMetadata(headers) {
			headers.set("Content-Type", "application/octet-stream");
		},
	};
}

function createEnv({ missing = false, failure = false } = {}) {
	return {
		GAME_ASSETS: {
			async get(key) {
				assert.equal(key, "wasm/index-test.wasm");
				if (failure) throw new Error("r2 unavailable");
				return missing ? null : createObject();
			},
			async head(key) {
				assert.equal(key, "wasm/index-test.wasm");
				if (failure) throw new Error("r2 unavailable");
				return missing ? null : createObject();
			},
		},
		ASSETS: {
			async fetch() {
				return new Response("static asset", { status: 200 });
			},
		},
	};
}

test("GET /index.wasm streams the versioned R2 object", async () => {
	const response = await worker.fetch(
		new Request("https://zombiewar.pages.dev/index.wasm"),
		createEnv(),
	);
	assert.equal(response.status, 200);
	assert.equal(response.headers.get("content-type"), "application/wasm");
	assert.equal(response.headers.get("etag"), '"test-etag"');
	assert.deepEqual(new Uint8Array(await response.arrayBuffer()), new Uint8Array([0, 97, 115, 109]));
});

test("HEAD /index.wasm returns metadata without a body", async () => {
	const response = await worker.fetch(
		new Request("https://zombiewar.pages.dev/index.wasm", { method: "HEAD" }),
		createEnv(),
	);
	assert.equal(response.status, 200);
	assert.equal(response.headers.get("content-type"), "application/wasm");
	assert.equal(await response.text(), "");
});

test("missing R2 objects return 503", async () => {
	const response = await worker.fetch(
		new Request("https://zombiewar.pages.dev/index.wasm"),
		createEnv({ missing: true }),
	);
	assert.equal(response.status, 503);
});

test("R2 failures return 502", async () => {
	const response = await worker.fetch(
		new Request("https://zombiewar.pages.dev/index.wasm"),
		createEnv({ failure: true }),
	);
	assert.equal(response.status, 502);
});

test("other paths fall back to Pages static assets", async () => {
	const response = await worker.fetch(
		new Request("https://zombiewar.pages.dev/index.html"),
		createEnv(),
	);
	assert.equal(await response.text(), "static asset");
});
```

创建 `tests/integration/test_cloudflare_r2_deployment.gd`，先只执行 Node 测试并检查待创建文件：

```gdscript
extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var output: Array = []
	var node_test := ProjectSettings.globalize_path("res://tests/integration/cloudflare_r2_worker.test.mjs")
	var exit_code := OS.execute("node", ["--test", node_test], output, true)
	_append(failures, Assertions.expect_equal(exit_code, 0, "Cloudflare Worker Node tests: %s" % "\n".join(output)))
	for path in [
		"res://wrangler.jsonc",
		"res://tools/cloudflare/pages_worker.template.js",
		"res://tools/cloudflare/_routes.json",
		"res://tools/cloudflare/_headers",
	]:
		_append(failures, Assertions.expect_true(FileAccess.file_exists(path), "Missing Cloudflare deployment file: %s" % path))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
```

在 `tests/test_runner.gd` 的 `TEST_PATHS` 末尾加入：

```gdscript
	"res://tests/integration/test_cloudflare_r2_deployment.gd",
```

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: FAIL；Node 测试报告无法读取 `tools/cloudflare/pages_worker.template.js`，同时 GDScript 报告缺少 Wrangler 和 Cloudflare 配置文件。

- [ ] **Step 3: 实现最小 Worker 模板和配置**

创建 `tools/cloudflare/pages_worker.template.js`：

```javascript
const WASM_OBJECT_KEY = "__WASM_OBJECT_KEY__";
const CACHE_CONTROL = "no-store, no-cache, must-revalidate, max-age=0";

function buildHeaders(object) {
	const headers = new Headers();
	if (typeof object.writeHttpMetadata === "function") {
		object.writeHttpMetadata(headers);
	}
	headers.set("Content-Type", "application/wasm");
	headers.set("Cache-Control", CACHE_CONTROL);
	headers.set("Cross-Origin-Opener-Policy", "same-origin");
	headers.set("Cross-Origin-Embedder-Policy", "require-corp");
	if (object.httpEtag) headers.set("ETag", object.httpEtag);
	return headers;
}

function errorResponse(status, message) {
	return new Response(message, {
		status,
		headers: {
			"Content-Type": "text/plain; charset=utf-8",
			"Cache-Control": CACHE_CONTROL,
		},
	});
}

async function serveWasm(request, env) {
	try {
		const object = request.method === "HEAD"
			? await env.GAME_ASSETS.head(WASM_OBJECT_KEY)
			: await env.GAME_ASSETS.get(WASM_OBJECT_KEY);
		if (object === null) {
			return errorResponse(503, `WASM object is unavailable: ${WASM_OBJECT_KEY}`);
		}
		return new Response(request.method === "HEAD" ? null : object.body, {
			status: 200,
			headers: buildHeaders(object),
		});
	} catch (error) {
		console.error("Unable to read WASM from R2", error);
		return errorResponse(502, "Unable to read WASM from R2");
	}
}

export default {
	async fetch(request, env) {
		const url = new URL(request.url);
		if (url.pathname === "/index.wasm") {
			if (request.method !== "GET" && request.method !== "HEAD") {
				return new Response("Method Not Allowed", {
					status: 405,
					headers: { Allow: "GET, HEAD" },
				});
			}
			return serveWasm(request, env);
		}
		return env.ASSETS.fetch(request);
	},
};
```

创建 `wrangler.jsonc`：

```jsonc
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "zombiewar",
  "pages_build_output_dir": "./build/cloudflare-pages",
  "compatibility_date": "2026-08-05",
  "r2_buckets": [
    {
      "binding": "GAME_ASSETS",
      "bucket_name": "zombiewar-assets"
    }
  ]
}
```

创建 `tools/cloudflare/_routes.json`：

```json
{
  "version": 1,
  "include": ["/index.wasm"],
  "exclude": []
}
```

创建 `tools/cloudflare/_headers`：

```text
/*
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp

/
  Cache-Control: no-store, no-cache, must-revalidate, max-age=0

/index.html
  Cache-Control: no-store, no-cache, must-revalidate, max-age=0
```

- [ ] **Step 4: 运行 Worker 和 Godot 测试并确认 GREEN**

Run:

```bash
node --test tests/integration/cloudflare_r2_worker.test.mjs
node --check tools/cloudflare/pages_worker.template.js
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: Node 的 5 个 Worker 测试 PASS；JavaScript 语法检查 exit `0`；Godot 测试报告全部 PASS。

- [ ] **Step 5: 提交 Task 1**

```bash
git add wrangler.jsonc tools/cloudflare/pages_worker.template.js tools/cloudflare/_routes.json tools/cloudflare/_headers tests/integration/cloudflare_r2_worker.test.mjs tests/integration/test_cloudflare_r2_deployment.gd tests/test_runner.gd
git commit -m "feat: add R2-backed Pages worker"
```

---

### Task 2: 可重复执行的导出、R2 上传和 Pages 包准备脚本

**Files:**
- Create: `tools/cloudflare/deploy_r2_pages.sh`
- Modify: `tests/integration/test_cloudflare_r2_deployment.gd`

**Interfaces:**
- Consumes: `GODOT_BIN`、`CLOUDFLARE_PAGES_PROJECT`、`CLOUDFLARE_BRANCH`；Task 1 的 Worker 模板和配置文件。
- Produces: `bash tools/cloudflare/deploy_r2_pages.sh [--prepare-only]`；生成不含原始 WASM 的 `build/cloudflare-pages`，完整模式上传 R2 并部署 Pages。

- [ ] **Step 1: 扩展集成测试以验证 `--prepare-only`，形成 RED**

在 `tests/integration/test_cloudflare_r2_deployment.gd` 的 `run()` 中追加：

```gdscript
	var deploy_script := ProjectSettings.globalize_path("res://tools/cloudflare/deploy_r2_pages.sh")
	_append(failures, Assertions.expect_true(FileAccess.file_exists(deploy_script), "Missing R2 Pages deployment script"))
	if FileAccess.file_exists(deploy_script):
		var prepare_output: Array = []
		var prepare_exit := OS.execute("bash", [deploy_script, "--prepare-only"], prepare_output, true)
		_append(failures, Assertions.expect_equal(prepare_exit, 0, "R2 Pages prepare-only: %s" % "\n".join(prepare_output)))
		_append(failures, Assertions.expect_true(
			not FileAccess.file_exists("res://build/cloudflare-pages/index.wasm"),
			"Pages package must exclude index.wasm"
		))
		var wasm_path := ProjectSettings.globalize_path("res://build/web/index.wasm")
		var hash_output: Array = []
		var hash_exit := OS.execute("shasum", ["-a", "256", wasm_path], hash_output, true)
		_append(failures, Assertions.expect_equal(hash_exit, 0, "Calculate WASM SHA-256"))
		if hash_exit == 0 and not hash_output.is_empty():
			var wasm_hash := String(hash_output[0]).get_slice(" ", 0)
			var generated_worker := FileAccess.get_file_as_string("res://build/cloudflare-pages/_worker.js")
			_append(failures, Assertions.expect_true(
				generated_worker.contains("wasm/index-%s.wasm" % wasm_hash),
				"Generated Worker references the exported WASM hash"
			))
```

- [ ] **Step 2: 运行部署集成测试并确认 RED**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: FAIL with `Missing R2 Pages deployment script`。

- [ ] **Step 3: 实现最小可重复执行部署脚本**

创建 `tools/cloudflare/deploy_r2_pages.sh`，具体行为如下：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PAGES_PROJECT="${CLOUDFLARE_PAGES_PROJECT:-zombiewar}"
R2_BUCKET="zombiewar-assets"
DEPLOY_BRANCH="${CLOUDFLARE_BRANCH:-main}"
WEB_DIR="$ROOT_DIR/build/web"
PAGES_DIR="$ROOT_DIR/build/cloudflare-pages"
PREPARE_ONLY=false

if [[ "${1:-}" == "--prepare-only" ]]; then
	PREPARE_ONLY=true
elif [[ $# -gt 0 ]]; then
	echo "Usage: $0 [--prepare-only]" >&2
	exit 2
fi

command -v "$GODOT_BIN" >/dev/null 2>&1 || {
	echo "Godot executable not found: $GODOT_BIN" >&2
	exit 1
}
command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 1; }
command -v npx >/dev/null 2>&1 || { echo "npx is required" >&2; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "shasum is required" >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "rsync is required" >&2; exit 1; }

mkdir -p "$WEB_DIR"
"$GODOT_BIN" --headless --path "$ROOT_DIR" --export-release Web "$WEB_DIR/index.html"

WASM_PATH="$WEB_DIR/index.wasm"
[[ -f "$WASM_PATH" ]] || { echo "Missing exported WASM: $WASM_PATH" >&2; exit 1; }
WASM_HASH="$(shasum -a 256 "$WASM_PATH" | awk '{print $1}')"
WASM_KEY="wasm/index-${WASM_HASH}.wasm"

mkdir -p "$PAGES_DIR"
rsync -a --delete --exclude index.wasm "$WEB_DIR/" "$PAGES_DIR/"
sed "s/__WASM_OBJECT_KEY__/${WASM_KEY}/g" \
	"$ROOT_DIR/tools/cloudflare/pages_worker.template.js" \
	> "$PAGES_DIR/_worker.js"
cp "$ROOT_DIR/tools/cloudflare/_routes.json" "$PAGES_DIR/_routes.json"
cp "$ROOT_DIR/tools/cloudflare/_headers" "$PAGES_DIR/_headers"

if find "$PAGES_DIR" -type f -size +25M -print -quit | grep -q .; then
	echo "Pages package contains a file larger than 25 MiB" >&2
	exit 1
fi

node --check "$PAGES_DIR/_worker.js"

if $PREPARE_ONLY; then
	echo "Prepared Pages package for $WASM_KEY"
	exit 0
fi

cd "$ROOT_DIR"
if ! npx --yes wrangler r2 bucket info "$R2_BUCKET" --json >/dev/null 2>&1; then
	npx --yes wrangler r2 bucket create "$R2_BUCKET"
fi

npx --yes wrangler r2 object put "$R2_BUCKET/$WASM_KEY" \
	--file "$WASM_PATH" \
	--content-type application/wasm \
	--cache-control "no-store, no-cache, must-revalidate, max-age=0" \
	--remote

npx --yes wrangler pages deploy "$PAGES_DIR" \
	--project-name "$PAGES_PROJECT" \
	--branch "$DEPLOY_BRANCH"

PRODUCTION_URL="https://${PAGES_PROJECT}.pages.dev"
curl --fail --silent --show-error --head "$PRODUCTION_URL/"
curl --fail --silent --show-error --head "$PRODUCTION_URL/index.wasm"
echo "Deployment complete: $PRODUCTION_URL"
```

实现时将 `command -v "$GODOT_BIN"` 改为 `[[ -x "$GODOT_BIN" ]]`，因为 `GODOT_BIN` 是绝对路径；同时在写入脚本后执行 `chmod +x tools/cloudflare/deploy_r2_pages.sh`。

- [ ] **Step 4: 运行静态检查、prepare-only 和完整测试并确认 GREEN**

Run:

```bash
bash -n tools/cloudflare/deploy_r2_pages.sh
bash tools/cloudflare/deploy_r2_pages.sh --prepare-only
test ! -e build/cloudflare-pages/index.wasm
test -e build/cloudflare-pages/_worker.js
find build/cloudflare-pages -type f -size +25M -print
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
```

Expected: Bash 语法检查 exit `0`；prepare-only 成功；Pages 包没有 `index.wasm` 和超过 25 MiB 的文件；Godot 全量测试 PASS。

- [ ] **Step 5: 提交 Task 2**

```bash
git add tools/cloudflare/deploy_r2_pages.sh tests/integration/test_cloudflare_r2_deployment.gd
git commit -m "feat: automate R2-backed Pages deployment"
```

---

### Task 3: 文档、首次 R2 正式部署与线上验证

**Files:**
- Modify: `README.md`
- Output only: `build/web/*`
- Output only: `build/cloudflare-pages/*`
- Remote: Cloudflare R2 bucket `zombiewar-assets`
- Remote: Cloudflare Pages project `zombiewar`

**Interfaces:**
- Consumes: Task 2 的 `bash tools/cloudflare/deploy_r2_pages.sh` 和现有 Wrangler OAuth；CI 使用 `CLOUDFLARE_API_TOKEN`、`CLOUDFLARE_ACCOUNT_ID`。
- Produces: R2 版本化 WASM 对象、引用该对象的生产 Pages deployment、README 部署说明。

- [ ] **Step 1: 写入 README 部署契约并形成 RED 检查**

先运行：

```bash
rg -n "deploy_r2_pages|CLOUDFLARE_API_TOKEN|zombiewar-assets|--prepare-only" README.md
```

Expected: 无匹配，证明 R2 部署文档尚未落地。

- [ ] **Step 2: 更新 README 的 Cloudflare R2 部署说明**

在现有 Export 章节之后加入：

````markdown
### Cloudflare Pages + private R2 deployment

The production deployment keeps HTML, JavaScript, PCK, images, and audio on Pages. The exported `index.wasm` is uploaded to the private `zombiewar-assets` R2 bucket and streamed from the same `/index.wasm` URL by the Pages Worker.

Prepare and validate the upload package without contacting Cloudflare:

```bash
bash tools/cloudflare/deploy_r2_pages.sh --prepare-only
```

Export, upload the versioned WASM to R2, and deploy Pages:

```bash
bash tools/cloudflare/deploy_r2_pages.sh
```

CI/CD must provide:

```text
CLOUDFLARE_API_TOKEN
CLOUDFLARE_ACCOUNT_ID
```

Optional overrides are `GODOT_BIN`, `CLOUDFLARE_PAGES_PROJECT`, and `CLOUDFLARE_BRANCH`. The Pages project and branch defaults are `zombiewar` and `main`. The R2 bucket is fixed as `zombiewar-assets` by `wrangler.jsonc`, remains private, and old hash-addressed WASM objects are intentionally retained for historical Pages deployments.
````

- [ ] **Step 3: 验证认证并执行首次完整部署**

Run:

```bash
npx --yes wrangler whoami
bash tools/cloudflare/deploy_r2_pages.sh
```

Expected: Wrangler 显示已登录账户；不存在时创建私有 `zombiewar-assets` bucket；上传 `wasm/index-<sha256>.wasm`；Pages deployment 成功并返回新的生产版本 URL。

- [ ] **Step 4: 验证线上响应和 WASM 完整性**

Run:

```bash
curl -sS -I https://zombiewar.pages.dev/
curl -sS -I https://zombiewar.pages.dev/index.wasm
verify_dir="$(mktemp -d)"
curl -sS https://zombiewar.pages.dev/index.wasm -o "$verify_dir/index.wasm"
shasum -a 256 build/web/index.wasm "$verify_dir/index.wasm"
npx --yes wrangler pages deployment list --project-name zombiewar
```

Expected: `/` 和 `/index.wasm` 均为 `200`；WASM 为 `Content-Type: application/wasm`；两个 SHA-256 完全相同；最新部署为 Production/main。

- [ ] **Step 5: 浏览器验证主菜单和游戏场景**

打开 `https://zombiewar.pages.dev`，等待 WASM 和 PCK 加载完成，确认主菜单可见；选择“开始游戏”，确认 Demo Arena、玩家、Zombie 和 HUD 正常显示。检查控制台不存在 WASM 解压、MIME 或 R2 读取错误。

- [ ] **Step 6: 运行最终回归和格式检查**

Run:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/test_runner.gd
bash -n tools/cloudflare/deploy_r2_pages.sh
node --test tests/integration/cloudflare_r2_worker.test.mjs
git diff --check
git status --short
```

Expected: 编辑器导入、完整 Godot 测试、Bash 检查和 Node 测试全部成功；`git diff --check` 无输出；`build/` 与 `.godot/` 不出现在待提交文件中。

- [ ] **Step 7: 提交 Task 3**

```bash
git add README.md
git commit -m "docs: document R2-backed Pages deployment"
```

## 最终验收

- [ ] `https://zombiewar.pages.dev/index.wasm` 由 Pages Worker 从私有 R2 返回。
- [ ] Pages deployment 不再上传原始 WASM，且无单文件超过 25 MiB。
- [ ] 线上和本地 WASM SHA-256 相同。
- [ ] R2 bucket 未开启公开访问。
- [ ] 主菜单和 Demo Arena 在浏览器中正常运行。
- [ ] 本机一条命令和 CI/CD 环境变量流程均已记录。
