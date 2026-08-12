# VirtualJoystick 原生类名冲突修复设计

## 背景

Godot 4.7.1 已提供原生 `VirtualJoystick` 类。项目脚本
`scripts/ui/virtual_joystick.gd` 再次声明 `class_name VirtualJoystick`，导致解析器报错：

```text
Parser Error: Class "VirtualJoystick" hides a native class.
```

项目的 `MobileControls` 已通过 `preload("res://scripts/ui/virtual_joystick.gd")`
直接引用脚本类型，`MobileControls.tscn` 也通过脚本资源路径绑定节点，因此不需要该全局类名。

## 设计

- 删除 `virtual_joystick.gd` 的 `class_name VirtualJoystick`。
- 保留匿名枚举、导出属性、触摸输入行为和场景脚本绑定，不重命名文件或节点。
- 更新脚本内过时的 `DemoArena` / 全局类名注释，说明它由 `preload` 和场景资源路径使用。
- 扩展移动控制验证：真实加载 `virtual_joystick.gd`，断言脚本可实例化；真实实例化
  `MobileControls.tscn`，断言摇杆节点绑定的是该项目脚本而不是占位节点或原生类。

## 验证

- 修改测试后先运行并确认当前代码因类名冲突失败。
- 修复后运行移动控制、Demo 地图迁移、无头 editor import 和 DemoMap smoke。
- 验证输出不得包含 `Class "VirtualJoystick" hides a native class`、`Parse Error` 或
  `Failed to load script`。

## 范围外

- 不改用 Godot 原生 `VirtualJoystick`。
- 不改变移动手感、摇杆尺寸、触摸动作映射或移动控制布局。
- 不处理既有 `rp_font is null` 诊断。
