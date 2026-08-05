# GitHub Release 触发 Cloudflare 生产部署 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 GitHub Release 正式发布时，将该 tag 对应的 Godot Web 构建测试并部署到 Cloudflare Pages 生产环境；普通 push 永不部署。

**Architecture:** 新增一个 Release-only GitHub Actions workflow。工作流检出 Release tag，安装 Node 24 与 Godot 4.7.1，先执行现有完整 Godot 测试，再以 GitHub Secrets 和 CLOUDFLARE_BRANCH=main 调用既有 R2 + Pages 部署脚本；不复制脚本内的导出、R2 上传或线上校验逻辑。

**Tech Stack:** GitHub Actions、YAML、Godot 4.7.1、Node.js 24、Node 内置测试运行器、GDScript 自定义测试、Wrangler 4.x、Cloudflare Pages 与 R2。

## Global Constraints

- 仅响应 GitHub release 的 published 事件；不得添加 push、pull_request 或定时触发器。
- 必须检出 ${{ github.event.release.tag_name }}，绝不能以默认分支 HEAD 替代 Release tag。
- 部署前必须执行 ./tests/run_tests.sh，并使用安装后的 Godot 二进制设置 ZOMBIEWAR_GODOT_BIN。
- 仅部署到 CLOUDFLARE_BRANCH=main 的 Pages 生产分支。
- CLOUDFLARE_API_TOKEN 与 CLOUDFLARE_ACCOUNT_ID 只能从 GitHub Secrets 注入；不得写入仓库、命令行参数或日志。
- workflow 的 GitHub Token 权限仅为 contents: read；生产部署使用同一并发组且不取消已开始的部署。
- 不修改 tools/cloudflare/deploy_r2_pages.sh、wrangler.jsonc、R2 bucket、Pages 项目或游戏运行时资源。
- 不提交 build/、.godot/ 或测试/导出生成的文件；保留用户现有未提交的刀具资源和场景修改。

## 文件结构

- .github/workflows/deploy-cloudflare.yml：Release-only 生产部署工作流，负责检出、安装依赖、测试和调用既有部署脚本。
- tests/integration/cloudflare_release_workflow.test.mjs：用 Node 内置测试验证 workflow 的触发器、安全、tag 检出、测试门槛与部署环境契约。
- tests/integration/test_cloudflare_r2_deployment.gd：把新的 Node workflow 契约测试纳入现有 Cloudflare 部署集成测试入口。
- README.md：说明 GitHub Release 是唯一自动部署入口、所需 Secrets 与正常 push 不发布的规则。

---

### Task 1: 为 Release 部署 workflow 建立失败契约测试

**Files:**

- Create: tests/integration/cloudflare_release_workflow.test.mjs
- Modify: tests/integration/test_cloudflare_r2_deployment.gd:7-12
- Test: tests/integration/cloudflare_release_workflow.test.mjs

**Interfaces:**

- Consumes: .github/workflows/deploy-cloudflare.yml 的 UTF-8 文本。
- Produces: Node 测试 exit 0 表示 workflow 具有唯一的 Release published 触发器、tag checkout、测试门槛、只读权限、串行部署和正确的 Cloudflare 环境变量。

- [ ] **Step 1: 写入失败的 workflow 契约测试**

创建 tests/integration/cloudflare_release_workflow.test.mjs：

~~~~javascript
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const workflowPath = new URL(
	"../../.github/workflows/deploy-cloudflare.yml",
	import.meta.url,
);

async function readWorkflow() {
	return readFile(workflowPath, "utf8");
}

test("Cloudflare deployment runs only for published GitHub Releases", async () => {
	const workflow = await readWorkflow();
	assert.match(workflow, /^on:\s*\n\s*release:\s*\n\s*types:\s*\[published\]\s*$/m);
	assert.doesNotMatch(workflow, /^\s*(push|pull_request|schedule):/m);
});

test("Cloudflare deployment checks out the published Release tag", async () => {
	const workflow = await readWorkflow();
	assert.match(workflow, /ref:\s*\$\{\{\s*github\.event\.release\.tag_name\s*\}\}/);
});

test("Cloudflare deployment tests before publishing and uses only Secrets", async () => {
	const workflow = await readWorkflow();
	const testIndex = workflow.indexOf("./tests/run_tests.sh");
	const deployIndex = workflow.indexOf("bash tools/cloudflare/deploy_r2_pages.sh");
	assert.ok(testIndex >= 0, "workflow must run the full Godot suite");
	assert.ok(deployIndex > testIndex, "workflow must deploy only after tests");
	assert.match(workflow, /CLOUDFLARE_API_TOKEN:\s*\$\{\{\s*secrets\.CLOUDFLARE_API_TOKEN\s*\}\}/);
	assert.match(workflow, /CLOUDFLARE_ACCOUNT_ID:\s*\$\{\{\s*secrets\.CLOUDFLARE_ACCOUNT_ID\s*\}\}/);
	assert.match(workflow, /CLOUDFLARE_BRANCH:\s*main/);
});

test("Cloudflare deployment uses least privilege and serial production releases", async () => {
	const workflow = await readWorkflow();
	assert.match(workflow, /permissions:\s*\n\s*contents:\s*read/);
	assert.match(workflow, /concurrency:\s*\n\s*group:\s*cloudflare-production-deploy\s*\n\s*cancel-in-progress:\s*false/);
});
~~~~

在 tests/integration/test_cloudflare_r2_deployment.gd 的 node_tests 数组末尾加入：

~~~~gdscript
		ProjectSettings.globalize_path("res://tests/integration/cloudflare_release_workflow.test.mjs"),
~~~~

- [ ] **Step 2: 验证测试处于 RED 状态**

运行：

~~~~bash
node --test tests/integration/cloudflare_release_workflow.test.mjs
~~~~

预期：失败，错误明确指出无法读取尚未创建的 .github/workflows/deploy-cloudflare.yml；这证明测试针对缺失的自动部署功能而非已有 R2 部署行为。

- [ ] **Step 3: 运行现有 Cloudflare 集成入口确认它也报告缺失 workflow**

运行：

~~~~bash
ZOMBIEWAR_GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot ./tests/run_tests.sh
~~~~

预期：tests/integration/test_cloudflare_r2_deployment.gd 失败，输出含 cloudflare_release_workflow.test.mjs 无法读取 workflow；其余已有 Cloudflare Worker 与部署脚本测试继续可运行。

### Task 2: 实现 GitHub Release-only Cloudflare 部署工作流

**Files:**

- Create: .github/workflows/deploy-cloudflare.yml
- Test: tests/integration/cloudflare_release_workflow.test.mjs

**Interfaces:**

- Consumes: github.event.release.tag_name、仓库的 ./tests/run_tests.sh 与 tools/cloudflare/deploy_r2_pages.sh。
- Consumes: GitHub Secrets CLOUDFLARE_API_TOKEN、CLOUDFLARE_ACCOUNT_ID。
- Produces: 仅由 Release published 事件创建的 deploy job；所有测试成功后向 Cloudflare 发布该 tag 的构建。

- [ ] **Step 1: 创建 workflow 目录与最小工作流实现**

创建 .github/workflows/deploy-cloudflare.yml：

~~~~yaml
name: Deploy Cloudflare on Release

on:
  release:
    types: [published]

permissions:
  contents: read

concurrency:
  group: cloudflare-production-deploy
  cancel-in-progress: false

jobs:
  deploy:
    name: Test and deploy release
    runs-on: ubuntu-latest
    steps:
      - name: Check out the published Release tag
        uses: actions/checkout@v4
        with:
          ref: ${{ github.event.release.tag_name }}

      - name: Set up Node.js 24
        uses: actions/setup-node@v4
        with:
          node-version: 24

      - name: Install Godot 4.7.1
        env:
          GODOT_ARCHIVE: Godot_v4.7.1-stable_linux.x86_64.zip
          GODOT_BINARY: Godot_v4.7.1-stable_linux.x86_64
          GODOT_EXPORT_TEMPLATES: Godot_v4.7.1-stable_export_templates.tpz
        run: |
          curl --fail --location --silent --show-error \
            --output "$RUNNER_TEMP/$GODOT_ARCHIVE" \
            "https://github.com/godotengine/godot/releases/download/4.7.1-stable/$GODOT_ARCHIVE"
          unzip -q "$RUNNER_TEMP/$GODOT_ARCHIVE" -d "$RUNNER_TEMP/godot"
          curl --fail --location --silent --show-error \
            --output "$RUNNER_TEMP/$GODOT_EXPORT_TEMPLATES" \
            "https://github.com/godotengine/godot/releases/download/4.7.1-stable/$GODOT_EXPORT_TEMPLATES"
          mkdir -p "$HOME/.local/share/godot/export_templates/4.7.1.stable"
          unzip -q "$RUNNER_TEMP/$GODOT_EXPORT_TEMPLATES" -d "$RUNNER_TEMP/godot-export-templates"
          mv "$RUNNER_TEMP/godot-export-templates/templates/"* "$HOME/.local/share/godot/export_templates/4.7.1.stable/"
          chmod +x "$RUNNER_TEMP/godot/$GODOT_BINARY"
          echo "ZOMBIEWAR_GODOT_BIN=$RUNNER_TEMP/godot/$GODOT_BINARY" >> "$GITHUB_ENV"
          echo "GODOT_BIN=$RUNNER_TEMP/godot/$GODOT_BINARY" >> "$GITHUB_ENV"

      - name: Run the full Godot test suite
        run: ./tests/run_tests.sh

      - name: Deploy the Release to Cloudflare production
        env:
          GODOT_BIN: ${{ env.ZOMBIEWAR_GODOT_BIN }}
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
          CLOUDFLARE_BRANCH: main
        run: bash tools/cloudflare/deploy_r2_pages.sh
~~~~

测试步骤使用 ZOMBIEWAR_GODOT_BIN，正好匹配 tests/run_tests.sh；部署步骤使用部署脚本已有的 GODOT_BIN 接口。凭据只作为 deploy step 环境变量出现。

- [ ] **Step 2: 运行新增 Node 契约测试确认 GREEN**

运行：

~~~~bash
node --test tests/integration/cloudflare_release_workflow.test.mjs
~~~~

预期：4 个子测试全部 PASS。

- [ ] **Step 3: 运行 workflow 静态格式检查**

运行：

~~~~bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/deploy-cloudflare.yml"); puts "workflow YAML is valid"'
~~~~

预期：exit 0 且输出 workflow YAML is valid。这一步只解析 YAML，不执行部署。

- [ ] **Step 4: 提交可执行 workflow 与契约测试**

运行：

~~~~bash
git add .github/workflows/deploy-cloudflare.yml tests/integration/cloudflare_release_workflow.test.mjs tests/integration/test_cloudflare_r2_deployment.gd
git commit -m "ci: deploy Cloudflare on release"
~~~~

预期：提交只包含 workflow 和对应测试，不包含 build/、.godot/ 或既有未提交的刀具资源改动。

### Task 3: 更新发布说明并执行完整本地验证

**Files:**

- Modify: README.md:73-96
- Test: ./tests/run_tests.sh、node --test tests/integration/cloudflare_release_workflow.test.mjs

**Interfaces:**

- Consumes: Task 2 的 workflow 名称、两个 GitHub Secrets 和现有 R2 Pages 部署脚本。
- Produces: 面向维护者的明确操作：配置 Secrets、发布 GitHub Release 后自动部署、普通 push 不部署。

- [ ] **Step 1: 先确认 README 尚未说明 Release-only 自动部署**

运行：

~~~~bash
rg -n "GitHub Release|release.*published|Ordinary pushes|CLOUDFLARE_API_TOKEN" README.md
~~~~

预期：仅能找到既有 CLOUDFLARE_API_TOKEN 与 CLOUDFLARE_ACCOUNT_ID 说明，不能找到 GitHub Release 触发规则。

- [ ] **Step 2: 补充 CI/CD 说明**

在现有 Cloudflare 部署章节的 CI/CD must provide: 段落替换为：

~~~~markdown
GitHub Actions only deploys after a GitHub Release is published. Configure the following repository Actions secrets before publishing a release:

~~~text
CLOUDFLARE_API_TOKEN
CLOUDFLARE_ACCOUNT_ID
~~~

The workflow checks out the release tag, runs ./tests/run_tests.sh, then deploys to the Cloudflare Pages main production branch. Ordinary pushes do not deploy.
~~~~

这会保留一份 Secrets 清单，并将“Release 发布才部署”的规则放在同一位置。

- [ ] **Step 3: 运行完整验证**

运行：

~~~~bash
node --test tests/integration/cloudflare_release_workflow.test.mjs
ZOMBIEWAR_GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot ./tests/run_tests.sh
git diff --check
git status --short
~~~~

预期：Node workflow 契约测试和完整 Godot suite 均通过，git diff --check 无输出；状态中不包含 build/、.godot/、resources/weapons/knife.tres 或 scenes/weapons/Knife.tscn。

- [ ] **Step 4: 提交文档**

运行：

~~~~bash
git add README.md
git commit -m "docs: explain release Cloudflare deployment"
~~~~

预期：提交仅包含 README 的 GitHub Release 部署说明。

## 计划自检

- Spec 覆盖：Task 2 实现 Release published、tag checkout、Node/Godot 安装、测试门槛、Secret 注入、main 生产发布、最小权限及串行化；Task 1 以自动化契约约束这些要点；Task 3 向维护者说明触发和配置规则。
- 占位符扫描：未发现未完成占位标记或留待实现的空白步骤；所有代码和命令均已给出。
- 接口一致性：测试使用 .github/workflows/deploy-cloudflare.yml；workflow 的 ZOMBIEWAR_GODOT_BIN 与 tests/run_tests.sh 读取的变量一致，GODOT_BIN 与部署脚本读取的变量一致；两项 Cloudflare 变量都以相同 Secrets 名称注入。

## 复审修正

- GitHub Actions 的 Godot 安装步骤还必须下载同版本的 `Godot_v4.7.1-stable_export_templates.tpz`，将其中 `templates/*` 安装到 `$HOME/.local/share/godot/export_templates/4.7.1.stable/`，否则 Ubuntu runner 无法执行 Web release 导出。
- 同一步同时向 `$GITHUB_ENV` 写入 `ZOMBIEWAR_GODOT_BIN` 和 `GODOT_BIN`。前者供 `tests/run_tests.sh` 使用，后者供集成测试内调用的 `tools/cloudflare/deploy_r2_pages.sh` 使用。
