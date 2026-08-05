# GitHub Release 触发 Cloudflare 生产部署设计

## 背景

仓库已有 `tools/cloudflare/deploy_r2_pages.sh`，可将 Godot Web 导出包发布到 Cloudflare Pages，并把超过 Pages 单文件限制的 `index.wasm` 以 SHA-256 版本化对象写入私有 R2。当前缺少 GitHub Actions 自动化入口。

项目要求不因日常开发提交而发布。只有 GitHub Release 被正式发布时，才将该 Release 对应 tag 的代码部署到生产环境。

## 目标

- 仅在 GitHub Release 的 `published` 事件执行生产部署；所有普通 push 均不部署。
- 部署内容严格对应被发布 Release 的 tag 提交。
- 复用仓库现有部署脚本，保持 R2 WASM 的版本化、私有访问和 Pages 原子切换语义。
- 部署前运行完整 Godot 测试套件；测试失败时不调用 Cloudflare。
- Cloudflare 凭据仅通过 GitHub Actions Secrets 提供，不写入仓库或日志。

## 非目标

- 不新增 preview deployment、PR deployment 或 push 自动部署。
- 不修改 `tools/cloudflare/deploy_r2_pages.sh`、Cloudflare Pages 项目、R2 bucket 或游戏导出逻辑。
- 不自动创建 GitHub Release、tag 或管理历史 R2 对象。

## 方案比较

### 方案一：GitHub Release `published` 工作流（采用）

新增单个 GitHub Actions workflow，监听 `release.types: [published]`。工作流检出 Release tag，安装固定版本的 Godot 和 Node，执行 `./tests/run_tests.sh`，成功后以生产分支参数调用既有部署脚本。

优点：发布意图明确，部署提交可追溯到 Release；本地和 CI 共用同一发布逻辑。缺点：每次正式发布都需要等待 Godot 下载、测试和 Web 导出完成。

### 方案二：监听 `push` 到 `main`

实现简单，但每次日常提交都会直接影响生产，与“打 Release 才发布”的要求冲突。

### 方案三：Cloudflare Pages Git 集成

Pages 可自动监听仓库，但不能自然复用项目私有 R2 WASM 上传和每次发布生成 Worker 引用的流程，且以提交而非 GitHub Release 作为发布关口。

## 工作流设计

新增 `.github/workflows/deploy-cloudflare.yml`。

触发器：

```yaml
on:
  release:
    types: [published]
```

该定义没有 `push` 触发器，保证普通推送永不部署。

单个 `deploy` job 使用 Ubuntu runner，并设置：

- `permissions.contents: read`，仅允许读取仓库内容。
- `concurrency.group: cloudflare-production-deploy`，并使用 `cancel-in-progress: false`。多个 Release 依次完成，避免 R2 上传和 Pages 发布交叉执行。
- `actions/checkout` 的 `ref` 设为 `${{ github.event.release.tag_name }}`，确保检出 Release 对应 tag，而非事件发生时的默认分支 HEAD。
- 安装 Godot 4.7.1、Node 24 和 Wrangler。
- 先运行 `./tests/run_tests.sh`。
- 测试成功后执行 `bash tools/cloudflare/deploy_r2_pages.sh`，设置 `CLOUDFLARE_BRANCH=main`，确保部署到 Pages 生产分支。

部署步骤从 GitHub Secrets 注入以下变量：

```text
CLOUDFLARE_API_TOKEN
CLOUDFLARE_ACCOUNT_ID
```

它们不写入 workflow 文件，不通过命令行参数传递，也不打印到日志。

## 数据流

```text
发布 GitHub Release
  -> Actions 检出 release tag
  -> 执行 Godot 测试
  -> 现有部署脚本导出 Web
  -> 上传 hash-addressed WASM 至私有 R2
  -> 发布 Pages production（main）
```

测试、Godot 安装或 Cloudflare 发布任一环节失败时，job 失败并停止；不会执行后续步骤。既有部署脚本在 Pages 发布失败时保留未引用的版本化 R2 对象，不影响当前线上版本。

## 测试策略

扩展现有 `tests/unit/test_project_contract.gd`，验证 workflow：

- 存在且只监听 `release` 的 `published` 事件。
- 不含 `push` 触发器。
- checkout ref 使用 `github.event.release.tag_name`。
- 在部署前执行 `./tests/run_tests.sh`。
- 部署步骤使用 `CLOUDFLARE_API_TOKEN`、`CLOUDFLARE_ACCOUNT_ID` Secrets，并将 `CLOUDFLARE_BRANCH` 固定为 `main`。
- 含只读内容权限和串行生产部署并发控制。

实现后运行完整 `./tests/run_tests.sh`，并以 YAML 解析或文本契约检查确认 workflow 格式正确。实际 Cloudflare 发布需在 GitHub 创建并发布一个 Release 后由 Actions 执行验证。

## 成功标准

- 普通 push 不启动 Cloudflare 发布 workflow。
- 发布 GitHub Release 后，workflow 从该 tag 检出、完成测试并调用部署脚本。
- 发布使用 GitHub Secrets，仓库中不存在 Cloudflare token 或 account ID。
- 并发 Release 部署不会重叠，生产 Pages 分支保持 `main`。
