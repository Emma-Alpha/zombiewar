# 击退血液拖痕与光照：最终审查修复报告

修复日期：2026-08-05

## 审查发现处理

### Important 1：首个 0.36m 前被阻挡后，正常移动补出拖痕

已修复。`BloodTrailState.advance()` 在处理当前真实位移段后，只要水平速度回到正常移动阈值即关闭会话，不再要求已产生过印记。新增回归覆盖：击退实际移动 `0.20m`、被挡停且零印记、随后恢复正常移动，整个过程均不产生样本。

RED：`./tests/run_tests.sh`

关键失败输出：

```
A knockback stopped before its first mark closes the trail session
Normal movement after a blocked knockback cannot emit a delayed trail mark — expected 0, got 3
```

GREEN：`./tests/run_tests.sh`

关键通过输出：`PASS: 30 test file(s)`。

### Important 2：主血斑没有跟随射击方向旋转，零水平向量没有稳定回退

已修复。`GroundBloodManager.spawn_hit_splat()` 以 `shot_direction` 的水平分量计算 yaw，并只叠加 `[-0.12, 0.12]` 的小随机偏差；落点仍是投影得到的原始水平坐标。`ZombieTarget` 保持现有公开信号签名，在射击方向水平分量近零时，向该信号提供僵尸当前 `-basis.z` 的水平稳定朝向（最终退回 `Vector3.FORWARD`）。

RED：`./tests/run_tests.sh`

关键失败输出：

```
A vertical hit sends the zombie facing direction as the stable splat fallback — expected (-1.0, 0.0, 0.0), got (0.0, 1.0, 0.0)
Main splat rotation follows shot direction with only a small random offset
```

GREEN：`./tests/run_tests.sh`

关键通过输出：`PASS: 30 test file(s)`。

### Important 3：正式完整测试入口仍使用直接 Godot 命令

已修复。`AGENTS.md` 与 `README.md` 的正式完整测试命令统一为 `./tests/run_tests.sh`；直接 Godot test-runner 调用仅被说明为底层调试入口。检索非历史计划、非生成目录后，仓库中没有其他正式完整测试说明需要更新。

### Minor：0.75 秒截止帧仍会采样截止之后的位移

已修复。采样段按本帧剩余可用时间的比例截断；`0.70s` 后再推进 `0.10s` 时，只采样前 `0.05s` 的位移，断言为两点且最远不超过该帧中点 `x=1.5`。

RED：`./tests/run_tests.sh`

关键失败输出：

```
The 0.75-second cutoff excludes sample points after the deadline — expected 2, got 3
The cutoff frame samples only the movement reached by 0.75 seconds
```

GREEN：`./tests/run_tests.sh`，输出 `PASS: 30 test file(s)`。

### Minor：饱和格固定合并第一个实例

已修复。保持每格至多两层与 FIFO 索引不变；饱和后以请求二维尺寸和各层最近 `setup()` 基础尺寸的 L1 差值选择最匹配层。新增“小拖痕 + 大主血斑已满格，再请求大主血斑”测试，确认合并大层且仍为两层。

RED：`./tests/run_tests.sh`

关键失败输出：

```
A large request merges into the large matching layer instead of the small trail
Size-matched merging leaves the unrelated small trail layer intact
```

GREEN：`./tests/run_tests.sh`，输出 `PASS: 30 test file(s)`。

### Deferred triage：精确材质断言

已收敛为自动化契约。`test_ground_blood_manager.gd` 现断言血迹材质为 per-pixel、受光、`alpha_scissor_threshold == 0.25`、`metallic == 0`，并保留现有的 alpha-scissor、双面和不投射自身阴影断言。现有实现无需额外生产代码改动，完整套件 GREEN。

### Deferred triage：严格运行器未处理 tee 写失败

已修复并新增 `tests/test_run_tests_runner.sh` 聚焦故障注入。运行器先快照整条管道的 `PIPESTATUS`；Godot 非零时优先返回 Godot 原退出码，Godot 成功而 `tee` 失败时返回 tee 的非零码。

RED：`./tests/test_run_tests_runner.sh`

关键失败输出：

```
Expected tee failure status 9, got 0
```

GREEN：`./tests/test_run_tests_runner.sh`

关键通过输出：

```
PASS: strict test runner preserves Godot failure and rejects tee failure
```

该测试同时验证 Godot 返回 `23`、tee 返回 `9` 时，运行器仍返回 `23`。

## 最终自动化验证

```
./tests/test_run_tests_runner.sh
PASS: strict test runner preserves Godot failure and rejects tee failure

./tests/run_tests.sh
PASS: 30 test file(s)

/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
退出码 0；未出现源码解析错误。

git diff --check
通过（无输出）。
```

Editor import 如实报告了既有生成物的三条 duplicate UID 警告：`build/web` 与 `build/cloudflare-pages` 中的 `index.apple-touch-icon.png`、`index.icon.png`、`index.png`。这些生成目录未被修改或提交。

## 自审

- 所有 3 个 Important 均有对应实现和可运行测试；公开信号与 manager 方法签名未改变。
- 正常追击/游荡没有活动击退会话时不产生拖痕，且新增零印记阻挡回归防止会话泄漏到恢复移动。
- 主血斑落点未因方向逻辑修改；只改变绕表面法线的旋转。
- 0.75 秒是实际采样上限，截止后的位移不会补点。
- 饱和格仍只有两层，未增加第三层且未更改 FIFO 复用索引。
- 未引入清理功能、Forward+、Decal3D，也未修改生成的 `build/` 内容。

## 未处理及需人工验证项

- 未声称完成动态阴影、Z-fighting、透明排序、碰撞滑动轨迹、重复叠加或长时间渲染伪影的人工视觉验收；这些仍须在 Demo 中实际检查。
- Editor import 的 duplicate UID 警告来自既有 `build/` 生成物，不属于本源码修复；应在后续干净导出/发布流程中单独处理。
