# 击退血液拖痕最终审查修复实施计划

> **给执行代理：** 必须逐任务执行，先写测试并观察 RED，再写最小实现并观察 GREEN。

**目标：** 关闭最终审查中三个 Important，并收敛可自动验证的血迹行为 Minor。

**架构：** `BloodTrailState` 负责仅在击退会话内、且不跨越 0.75 秒截止的位移取样；`ZombieTarget` 以真实碰撞后的位移驱动该状态，并在低速时无条件终止会话。`GroundBloodManager` 以射击水平方向（或僵尸稳定朝向）计算主血斑方向，并在饱和格内选择尺寸匹配的已有层合并。

**技术栈：** Godot 4.7.1、GDScript、仓库自定义 headless 测试运行器。

## 全局约束

- 正式完整测试命令为 `./tests/run_tests.sh`。
- 仅使用 GL Compatibility；不引入 Decal3D、Forward+ 或血迹清理功能。
- 主血斑的世界落点不因方向或随机性改变；每格最多两层，维持 FIFO 索引。
- 不把自动化测试替代人工阴影、Z-fighting 或碰撞滑动视觉验收。

---

### 任务 1：击退会话在无印记阻挡时结束，并严格裁剪截止帧

**文件：**
- 修改：`scripts/fx/blood_trail_state.gd`
- 修改：`tests/unit/test_blood_trail_state.gd`

**接口：**
- 输入：`advance(current_position, delta, planar_speed, normal_move_speed)`。
- 输出：在会话有效采样时间内的真实位移样本；低速时 `active == false`。

- [ ] 写失败测试：首段不足 `0.36m`、速度低于阈值后会话结束，随后正常移动不再返回样本。
- [ ] 运行 `./tests/run_tests.sh`，确认该断言因会话仍活跃而 RED。
- [ ] 写失败测试：从 `0.70s` 推进 `0.10s` 的跨界段不会生成仅存在于 `0.75s` 后的样本。
- [ ] 运行 `./tests/run_tests.sh`，确认边界样本断言 RED。
- [ ] 最小实现：按剩余持续时间比例裁剪本段终点；处理完裁剪段后，低速即关闭会话（不依赖 `marks_emitted`）。
- [ ] 运行 `./tests/run_tests.sh`，确认 GREEN。

### 任务 2：真实 ZombieTarget 信号携带稳定朝向回退

**文件：**
- 修改：`scripts/combat/zombie_target.gd`
- 修改：`tests/unit/test_blood_trail_state.gd` 或新增聚焦 ZombieTarget 测试

**接口：**
- 维持现有公开信号和管理器方法签名。
- 零水平 `shot_direction` 时，主血斑请求的方向参数是僵尸当前水平朝向。

- [ ] 写失败测试：一个零水平射击方向的命中请求收到僵尸 `-global_transform.basis.z` 的水平回退方向。
- [ ] 运行完整测试，确认请求方向错误或缺少回退而 RED。
- [ ] 最小实现：在产生主血斑请求前标准化水平方向；近零时从当前朝向取得稳定向量。
- [ ] 运行完整测试，确认 GREEN。

### 任务 3：主血斑方向与饱和格合并匹配请求尺寸

**文件：**
- 修改：`scripts/fx/ground_blood_manager.gd`
- 修改：`tests/unit/test_ground_blood_manager.gd`
- 修改：`tests/unit/test_blood_impact.gd`

**接口：**
- 输入：现有 `spawn_hit_splat` 方向及回退参数。
- 输出：固定落点、以水平方向 yaw 为中心的小随机偏差；第三个格内请求合并至尺寸接近层。

- [ ] 写失败测试：相同随机种子下，主血斑 rotation 基于 `Vector3.RIGHT` 的水平 yaw，而非任意全圆随机；零向量使用传入稳定回退。
- [ ] 运行完整测试，确认 RED。
- [ ] 写失败测试：小拖痕和大主血斑占满格子时，新的大主血斑合并到大层，层数仍为二。
- [ ] 运行完整测试，确认 RED。
- [ ] 最小实现：采用 `atan2(horizontal.x, horizontal.z)` 加有限小偏差；用与请求面积/尺寸的差值选择待合并层。
- [ ] 补充材质契约断言：受光、`alpha_scissor_threshold == 0.25`、per-pixel、metallic 为零。
- [ ] 运行完整测试，确认 GREEN。

### 任务 4：严格测试入口、文档与最终验证

**文件：**
- 修改：`tests/run_tests.sh`
- 修改：`AGENTS.md`
- 修改：`README.md`
- 新增：`.superpowers/sdd/2026-08-05-knockback-blood-trails-lighting/final-fix-report.md`

- [ ] 写 shell 故障注入：替换 `tee` 为返回非零的可执行文件，证明 runner 仍保留 Godot 原退出码且 tee 失败会非零。
- [ ] 运行注入命令，确认 RED（现有 runner 忽略 tee 失败）。
- [ ] 最小实现：保存 `${PIPESTATUS[0]}` 与 `${PIPESTATUS[1]}`，任一失败均返回非零，Godot 失败优先返回其原退出码。
- [ ] 运行故障注入，确认 GREEN。
- [ ] 将 AGENTS、README 及实际自动化的正式完整测试入口统一为 `./tests/run_tests.sh`（历史计划不改）。
- [ ] 运行 `./tests/run_tests.sh`、Godot editor import、`git diff --check`；记录自动化结果和人工验收遗留项。
