# 删除未使用 Phantom Camera 插件实现计划

> **面向执行代理：** 必须逐项执行并验证；本计划为配置与删除任务，不创建持久测试文件。

**目标：** 从 Godot 项目移除未使用的 Phantom Camera 插件及其全部项目配置引用。

**架构：** 删除 `addons/phantom_camera/` 插件目录，并从 `project.godot` 的自动加载与编辑器插件列表移除对应条目。其他插件、场景、脚本和相机实现均不改动。

**技术栈：** Godot 4.7.1、GDScript 项目配置、Git。

## 全局约束

- 编辑器插件列表必须精确为 `enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")`。
- 不得修改 `addons/godot_ai/`、运行时相机实现或用户已有的未提交改动。
- 使用 Godot 无头导入检查验证配置可解析。

---

### 任务 1：删除插件与配置引用

**文件：**

- 删除：`addons/phantom_camera/`
- 修改：`project.godot:18-36`
- 创建：`docs/superpowers/plans/2026-08-12-remove-phantom-camera.md`

**接口：**

- 移除输入：`PhantomCameraManager="*res://addons/phantom_camera/scripts/managers/phantom_camera_manager.gd"` 自动加载项。
- 移除输入：`res://addons/phantom_camera/plugin.cfg` 编辑器插件项。
- 产出：Godot 不再加载 Phantom Camera；`godot_ai` 编辑器插件保持启用。

- [ ] **步骤 1：确认 RED 状态**

运行：

```bash
test ! -d addons/phantom_camera
! rg -n -i "phantom[_ -]?camera|phantomcamera" project.godot scenes scripts resources addons --glob '!addons/phantom_camera/**'
```

预期：两个断言均失败，因为插件目录和配置引用仍存在。

- [ ] **步骤 2：实施最小变更**

删除 `addons/phantom_camera/`，删除 `PhantomCameraManager` 自动加载项，并将编辑器插件列表设为：

```ini
enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")
```

- [ ] **步骤 3：确认 GREEN 状态并检查差异**

运行：

```bash
test ! -d addons/phantom_camera
! rg -n -i "phantom[_ -]?camera|phantomcamera" project.godot scenes scripts resources addons --glob '!addons/phantom_camera/**'
git diff --check -- project.godot addons/phantom_camera docs/superpowers/plans/2026-08-12-remove-phantom-camera.md
```

预期：所有命令成功，且没有空白错误或运行时残留引用。

- [ ] **步骤 4：执行 Godot 无头导入检查**

运行：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
```

预期：退出码为 0，输出无 Phantom Camera 缺失引用和脚本、场景解析错误。

- [ ] **步骤 5：精确暂存并提交**

运行：

```bash
git add -- project.godot addons/phantom_camera docs/superpowers/plans/2026-08-12-remove-phantom-camera.md
git diff --cached --name-status
git commit -m "chore: remove unused Phantom Camera plugin"
```

预期：暂存区和提交只包含本任务指定范围，其他用户改动仍未暂存。
