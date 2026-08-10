# 步枪完整迁移为冲锋枪设计

## 目标

将当前运行时的步枪完整迁移为冲锋枪。迁移覆盖稳定 ID、资源和场景文件、角色模型绑定、拾取物、Demo 配置、大厅预览、说明文字、验证脚本与射击音效命名，不保留旧 `rifle` 运行时入口。

本次只迁移现有武器，不改变其战斗数值，也不实现散弹枪或多弹丸逻辑。迁移在现有 `codex/smg-shotgun` 功能线上完成，并保留该工作树已有的弹道开发改动。

该功能线当前落后 `main` 的音效接入提交。实施前必须先保存工作树未提交改动，将最新 `main` 合入并恢复这些改动；只有确认弹道文件没有丢失或冲突后，才开始冲锋枪迁移。

## 运行时契约

- 稳定装备 ID：`&"smg"`。
- 显示名：`冲锋枪`。
- 模型节点：`SMG`。
- 场景：`res://scenes/weapons/Smg.tscn`。
- 武器资源：`res://resources/weapons/smg.tres`。
- 武器拾取：`res://resources/pickups/smg_pickup.tres`。
- 弹药拾取：`res://resources/pickups/smg_ammo_pickup.tres`。
- 射击音效：`res://assets/sfx/boxhead/smg_fire.mp3`，素材内容继续使用已导入的 UZI 射击声。

旧 `rifle` ID、旧文件路径和旧显示名不提供兼容别名。所有运行时消费者必须在同一迁移中更新，避免出现拾取物与装备 ID 不一致的半迁移状态。

## 保留数值

冲锋枪完全继承当前步枪数值：

| 配置 | 数值 |
| --- | ---: |
| 触发方式 | 按住连续射击 |
| 每秒射击次数 | `4` |
| 单发伤害 | `25` |
| 弹药上限 | `360` |
| 武器箱授予 | `60` |
| 弹药箱补充 | `90` |

射程、散布、散布恢复、后坐、镜头反馈、曳光池和碰撞掩码保持当前资源中的既有数值。

## 文件与引用迁移

以下资源使用 Git 感知的重命名，保留文件历史：

- `resources/weapons/rifle.tres` → `resources/weapons/smg.tres`
- `scenes/weapons/Rifle.tscn` → `scenes/weapons/Smg.tscn`
- `resources/pickups/rifle_pickup.tres` → `resources/pickups/smg_pickup.tres`
- `resources/pickups/rifle_ammo_pickup.tres` → `resources/pickups/smg_ammo_pickup.tres`
- 删除未被运行时使用的 `scenes/gameplay/RiflePickupChest.tscn`；数据驱动拾取继续使用通用 `PickupChest`，不创建专用 SMG 拾取场景。
- `assets/sfx/boxhead/rifle_fire.mp3` 及其导入描述 → `smg_fire.mp3` 对应文件。

`Player.tscn` 的装备场景引用改为 `Smg.tscn`，装备顺序保持原位置不变。`DemoArena.tscn` 的固定拾取点和随机掉落项同步改为 `Smg`、`SmgAmmo` 及对应资源。大厅角色预览从 `Rifle` 切换到 `SMG`。

`EquipmentController` 继续保留对模型中 `Rifle` 节点的隐藏能力，因为同一个角色模型可能同时包含多个嵌入式武器节点；当前显示和装备绑定只使用 `SMG`。

## 音效与加载性能

`smg_fire.mp3` 继续使用 `sound_562.mp3` 对应的 UZI 射击素材，只修改运行时语义化文件名和场景引用，不重新编码音频。

音效仍由 `Smg.tscn` 的 `AudioStreamPlayer3D` 通过场景 `ext_resource` 预引用。开火热路径只执行既有的音高微调和 `play()`，不增加 `load()`、节点实例化或额外播放器，因此不会改变当前加载和连射性能特征。

## 验证与兼容

先更新稳定的验证契约，使旧实现产生预期失败，再执行资源迁移。验证覆盖：

- `smg` ID、显示名、模型节点和场景路径正确。
- 冲锋枪默认未拥有，武器箱授予 `60` 发并自动装备，弹药上限为 `360`，弹药箱补充 `90`。
- 玩家装备顺序不变，未拥有冲锋枪时装备切换仍会跳过它。
- 大厅预览显示 `SMG`，隐藏其余嵌入式武器。
- Demo 固定拾取点和随机掉落池使用冲锋枪定义。
- UZI 音效由 `smg_fire.mp3` 预引用，射击热路径没有同步加载。
- `scripts/`、`scenes/`、`resources/`、`tools/`、`README.md` 和 `project.godot` 中不再残留 `rifle`、`Rifle` 或“步枪”。历史设计文档不纳入残留扫描。
- Godot headless editor 导入、相关验证脚本与 DemoArena headless Smoke Test 均通过。

人工验收时拾取冲锋枪箱，确认显示“冲锋枪”、角色手持 `SMG` 模型、使用 UZI 射击音色，并保持每秒 `4` 发、单发 `25` 伤害和原有弹药行为。
