# 步枪射速平衡 Implementation Plan

**目标：** 将步枪射速从每秒 `6` 发调整为每秒 `4` 发，伤害保持 `25`，并同步配置契约与玩家说明。

**实现方式：** 这是低风险、可快速回滚的数据调整，不使用 SDD，也不新增架构或测试框架。直接修改现有武器资源，并利用已有配置测试覆盖核心契约。

**技术栈：** Godot 4.7.1、GDScript、`.tres` 资源、自定义无头测试运行器。

## 约束

- 步枪保持按住连发。
- 步枪伤害保持 `25.0`。
- 不修改射程、散布、后坐、镜头冲击、声音、弹道池或碰撞判定。
- 保留工作区中已有且未提交的其他改动。

### Task 1：调整步枪射速并验证

**文件：**

- 修改：`resources/weapons/rifle.tres`
- 修改：`tests/unit/test_weapon_configuration.gd`
- 修改：`README.md`

- [x] 将 `resources/weapons/rifle.tres` 的 `attacks_per_second` 从 `6.0` 改为 `4.0`，保持 `damage = 25.0`。
- [x] 将 `tests/unit/test_weapon_configuration.gd` 的步枪射速期望改为 `4.0`，增加 `damage = 25.0` 的明确契约。
- [x] 将 `README.md` 的步枪操作说明更新为每秒 `4` 发。
- [x] 运行 `./tests/run_tests.sh`：步枪相关契约通过；完整套件被工作区已有的 4 个匕首测试失败阻断。
- [x] 运行 `/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit`，资源与脚本解析通过。
