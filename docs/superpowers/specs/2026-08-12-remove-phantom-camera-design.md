# 移除 Phantom Camera 插件设计

## 背景

项目已经安装并启用 Phantom Camera，但项目自身的场景、脚本和资源没有使用该插件。游戏镜头由 `scripts/camera/follow_camera.gd` 和原生 `Camera3D` 实现。继续保留插件只会增加编辑器加载、自动加载节点和第三方代码维护成本。

## 目标

彻底移除未使用的 Phantom Camera 插件，同时保持现有游戏和菜单镜头行为不变。

## 变更范围

- 删除 `addons/phantom_camera/` 整个插件目录。
- 从 `project.godot` 的 `[autoload]` 中删除 `PhantomCameraManager`。
- 从 `project.godot` 的 `[editor_plugins]` 启用列表中删除 Phantom Camera，只保留其他现有插件。
- 不修改 `scripts/camera/`、游戏场景或其他相机逻辑。
- 不处理工作区中与本任务无关的现有改动。

## 验证

- 搜索项目运行时代码和配置，确认不存在 Phantom Camera 残留引用。
- 运行 Godot 无头编辑器导入检查，确认场景和脚本能够正常加载。
- 检查 Git 暂存内容，确保提交仅包含本规格和 Phantom Camera 移除相关变更。

## 提交策略

规格文档按设计流程单独提交。实现完成后使用 `chore: remove unused Phantom Camera plugin` 提交插件删除与配置清理，不提交用户已有的其他工作区改动。
