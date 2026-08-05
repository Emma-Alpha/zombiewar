# 武器转身解耦与胶囊枪口弹道设计

## 背景

现有枪械净空控制器把人物朝向与枪械姿态作为同一个原子提交处理。当目标朝向下的 `NORMAL` 和 `RAISED` 两种枪械胶囊都受阻时，控制器返回人物上一合法 yaw，导致玩家贴墙或处于墙角时无法转身。

现有远程射击还存在三个不同的位置来源：伤害射线从人物功能射线点发出，曳光弹和枪口喷火从每把武器资源配置的 `muzzle_anchor_offset` 发出，真实枪械阻挡则使用玩家直属的 `WeaponCollision`。三者可能在举枪、收枪和同帧转向时失配。

本设计把人物转身与枪械净空解耦，并把真实枪械胶囊的枪口端点统一为喷火、伤害射线、曳光弹和攻击反馈的唯一射击起点。

## 目标

- 人物在贴墙、墙角和低顶组合环境中始终可以采用目标 yaw。
- 所有远程武器继续使用统一步枪包络：长度 `1.55m`、半径 `0.12m`。
- 正常持枪和 `65°` 举枪都不可用时，枪械进入人物自身碰撞体内部的 `TUCKED` 紧急收枪姿态。
- `NORMAL`、`RAISED`、`TUCKED` 均允许按原射速开火。
- 所有远程射击始终沿人物实际身体前方发出。
- 枪口喷火、功能射线、曳光弹和 `attack_resolved.origin` 使用同一个真实枪械胶囊枪口端点。
- 曳光弹在射击帧完整显示，从枪口端低透明度渐变到命中端高透明度，并在现有生命周期内整体淡出。
- 世界第 1 层继续阻挡射线，墙后目标不能受到伤害。

## 非目标

- 不改变武器伤害、射程、射速、触发模式、后坐力、相机冲击或声音。
- 不引入弹丸飞行时间、重力、散布、穿透、跳弹或网络同步。
- 不修改近战武器逻辑。
- 不修改第三方 `addons/`。
- 不通过关闭有效远程武器的 `WeaponCollision` 解决转身问题。
- 不重新引入举枪插值或攻击释放门闩。

## 设计约束

- Godot 版本保持 `4.7.1`。
- 所有远程武器共用：
  - 胶囊总高度 `1.55m`；
  - 胶囊半径 `0.12m`；
  - 正常持枪中心偏移 `Vector3(0.0, 1.12, -0.62)`；
  - 举枪角度 `65°`；
  - 正常姿态恢复延迟 `0.15s`；
  - 正常姿态恢复查询余量 `0.08m`。
- 人物主体胶囊保持总高度 `1.8m`、半径 `0.45m`、中心 `Vector3(0.0, 0.9, 0.0)`。
- 射击方向始终使用应用目标 yaw 后的人物实际前方 `-global_basis.z`。
- `WeaponCollision` 的世界 yaw 只能继承人物父变换一次。

## 状态模型

`WeaponClearanceState.Pose` 扩展为：

```text
DISABLED / NORMAL / RAISED / TUCKED
```

### `DISABLED`

当前装备不是有效远程武器。真实枪械碰撞和两个 probe 均关闭。

### `NORMAL`

使用现有正常步枪胶囊和可见枪械静止姿态。正常姿态安全时保持该状态；正常姿态首次受阻时立即尝试 `RAISED`。

### `RAISED`

真实步枪胶囊和可见枪械绕既有握枪枢轴直接抬高 `65°`，不插值。正常姿态连续安全 `0.15s` 后才恢复 `NORMAL`。

### `TUCKED`

当目标 yaw 下的 `NORMAL` 和 `RAISED` 均不安全时，真实步枪胶囊竖直放置在：

```gdscript
Transform3D(
	Basis(Vector3.RIGHT, PI),
	Vector3(0.0, 0.9, 0.0)
)
```

胶囊仍保持长度 `1.55m`、半径 `0.12m`。绕 X 轴 `180°` 后，胶囊长轴仍保持竖直，同时统一的 `-global_basis.y` 明确指向世界上方的枪口端。它与人物主体胶囊同中心、同竖直长轴，且尺寸严格小于人物主体胶囊，因此完整包含在人物自身碰撞范围内。只要人物主体未与世界重叠，`TUCKED` 胶囊也不会额外碰墙；人物旋转不会改变竖直胶囊的世界占用范围。

可见枪械使用现有 `visual_rest_transform` 的位置，并把现有举枪旋转从 `65°` 扩展到 `90°`，在同一物理帧直接竖直收枪。该姿态不插值、不短暂关闭碰撞；真实安全范围仍以完整包含在人物主体内的 `TUCKED` 胶囊为准。

## 状态转换

每个物理帧先使用目标 yaw 和本帧期望位移查询 `NormalProbe` 与 `RaisedProbe`。状态转换按当前已提交姿态解析：

```text
当前 NORMAL：
  normal_clear                       -> 保持 NORMAL
  not normal_clear and raised_clear -> 提交 RAISED
  not normal_clear and not raised_clear -> 提交 TUCKED

当前 RAISED：
  not raised_clear                  -> 提交 TUCKED
  raised_clear and not normal_clear -> 保持 RAISED，并清零恢复计时
  raised_clear and normal_clear     -> 累计 NORMAL 恢复计时

当前 TUCKED：
  not raised_clear                  -> 保持 TUCKED，并清零恢复计时
  raised_clear                      -> 立即提交 RAISED
```

恢复规则：

- `NORMAL → RAISED`：同帧立即提交。
- `NORMAL/RAISED → TUCKED`：同帧立即提交。
- `TUCKED → RAISED`：只要 `RAISED` 安全便同帧立即提交；即使 `NORMAL` 同时安全，也先进入 `RAISED`。
- `RAISED → NORMAL`：`NORMAL` 连续安全 `0.15s` 后提交；等待期间若再次受阻，计时清零。
- `TUCKED` 不需要第三个 probe。其安全性由“完整包含在人物主体胶囊内”的尺寸和变换不变量保证。

## 人物转向流程

枪械控制器不再决定人物是否可以采用 yaw。原 `resolve_facing_yaw()` 的“返回上一合法 yaw”契约删除，改为以下只解析并提交枪械姿态的接口：

```gdscript
func update_clearance(
	delta: float,
	desired_motion: Vector3,
	target_yaw: float
) -> void
```

`PlayerController` 的物理帧顺序为：

1. 根据输入计算 `target_yaw` 和 `desired_motion`。
2. 调用 `weapon_clearance.update_clearance(delta, desired_motion, target_yaw)`，让 probe 在目标朝向下选择并提交 `NORMAL`、`RAISED` 或 `TUCKED`。
3. 无条件执行 `rotation.y = target_yaw`。
4. 从应用后的 `-global_basis.z` 取得远程射击方向。
5. 提交攻击输入并调用 `move_and_slide()`。

枪械净空不能再冻结人物 yaw。人物实际移动仍由人物主体碰撞和保持启用的 `WeaponCollision` 共同约束。

## 装备切换

- 有效远程武器均共享相同包络和四态控制器。
- 远程到远程切换继承当前已提交姿态，包括 `TUCKED`。
- 近战到远程切换依次检查 `NORMAL`、`RAISED`；两者都不安全时以 `TUCKED` 完成装备，不再因空间不足拒绝远程武器。
- 候选武器缺少有效 `visual_anchor` 时仍事务化拒绝，保留当前装备、碰撞和 probe 状态。
- 有效远程武器装备期间不得关闭真实枪械碰撞。

## 胶囊枪口端点

Godot `CapsuleShape3D` 的长轴为形状局部 `Y`。当前胶囊变换约定让 `-global_basis.y` 指向枪口一端，因此控制器提供唯一的世界枪口端点：

```gdscript
func get_weapon_muzzle_origin(fallback: Vector3) -> Vector3:
	var capsule := weapon_collision.shape as CapsuleShape3D
	if capsule == null:
		push_warning("WeaponCollision requires CapsuleShape3D")
		return fallback
	var barrel_direction := -weapon_collision.global_basis.y.normalized()
	return weapon_collision.global_position + barrel_direction * capsule.height * 0.5
```

`CapsuleShape3D.height` 是包含两端半球的总高度，因此使用 `height * 0.5` 可取得胶囊表面端点，而不是圆柱段端点。

三个持枪姿态均使用该公式：

- `NORMAL`：枪口端位于人物前方。
- `RAISED`：枪口端随 `65°` 胶囊抬高。
- `TUCKED`：`-global_basis.y` 指向竖直胶囊上端，射击从该上端开始。

## 射击数据流

远程武器开火时按以下顺序处理：

1. 同步可见武器的已提交姿态。
2. 从 `WeaponClearanceController.get_weapon_muzzle_origin(functional_ray_origin.global_position)` 取得胶囊枪口端点；传入值只用于场景契约损坏时的安全降级。
3. 从人物实际前方取得水平单位射击方向。
4. 以胶囊端点为射线起点，以武器原有射程计算终点。
5. 使用 `hit_collision_mask | 1` 查询首次命中，并排除人物自身 RID。
6. 将查询的 `hit_from_inside` 设为 `true`，确保枪口端贴在或轻微处于墙体边界时仍由世界墙体截断射击。
7. 在胶囊端点显示枪口喷火。
8. 从胶囊端点到首次命中点显示曳光弹。
9. `attack_resolved.origin` 使用同一个胶囊端点，`direction` 使用人物实际前方。

每把远程武器资源中的 `muzzle_anchor_offset` 删除。`Muzzle` Marker 不再保存手工枪管偏移，只作为可复用枪口喷火节点的运行时世界锚点。

## 枪口喷火

每次开火前把 `Muzzle` 的世界位置更新为胶囊枪口端点，再调用现有 `MuzzleFlash.flash()`。枪口喷火继续使用当前随机旋转、随机缩放和约 `0.05s` 生命周期，不修改颜色、尺寸或声音。

枪口喷火位置不再依赖步枪或手枪模型中的局部 Marker 偏移，因此所有远程武器在 `NORMAL`、`RAISED`、`TUCKED` 中均与真实胶囊端点一致。

## 曳光弹

曳光弹仍在射击帧完整显示从枪口端点到首次命中点的整段几何，不引入飞行时间。

`ShotTracer` 的局部 `+Z` 端继续表示枪口端，局部 `-Z` 端表示命中端。材质改为无光照、加法混合的空间 Shader，并使用局部长轴进度计算纵向透明度：

```text
progress = 0.0  位于枪口端
progress = 1.0  位于命中端
longitudinal_alpha = smoothstep(0.0, 1.0, progress)
final_alpha = longitudinal_alpha * lifetime_alpha
```

效果为：

- 枪口端透明度最低；
- 沿弹道向命中端平滑增强；
- 命中端透明度最高；
- 整条弹道的 `lifetime_alpha` 在现有约 `0.08s` 生命周期内从 `1.0` 降到 `0.0`；
- 生命周期结束后继续复用现有 tracer pool，不分配临时节点。

弹道终点始终是功能射线的首次命中点。墙体存在时只绘制到墙面，不能绘制或伤害墙后目标。

## 异常与降级

- `WeaponCollision` 缺少有效 `CapsuleShape3D` 时，控制器不得返回虚构端点；输出 warning，并让远程武器回退到现有功能射线起点以避免运行时崩溃。正式 `Player.tscn` 必须通过场景契约测试保证该降级路径不会发生。
- `visual_anchor` 无效时继续事务化拒绝装备，不提交新姿态。
- 射线没有命中时，枪口端点加人物前方乘原有射程作为弹道终点。
- 枪口端点与命中点距离小于 `0.001m` 时不显示零长度曳光弹，但仍播放枪口喷火和声音。

## 文件职责

- `scripts/player/weapon_clearance_state.gd`
  - 维护 `DISABLED/NORMAL/RAISED/TUCKED` 和正常姿态恢复计时。
- `scripts/player/weapon_clearance_controller.gd`
  - 查询目标 yaw 下的正常、举枪姿态；提交三种有效枪械姿态；提供胶囊枪口世界端点。
- `scripts/player/player_controller.gd`
  - 永远采用目标 yaw；从人物实际前方生成远程射击方向。
- `scripts/player/equipment_controller.gd`
  - 让有效远程武器在双姿态受阻时以 `TUCKED` 完成事务切换。
- `scripts/combat/weapons/ranged_weapon.gd`
  - 使用胶囊端点作为射线、喷火、曳光弹和反馈起点。
- `scripts/combat/weapons/ranged_weapon_definition.gd`
  - 删除 `muzzle_anchor_offset`。
- `resources/weapons/pistol.tres`
  - 删除手枪局部枪口偏移。
- `resources/weapons/rifle.tres`
  - 删除步枪局部枪口偏移。
- `scripts/fx/shot_tracer.gd`
  - 维护整段弹道生命周期和整体淡出参数。
- `scenes/fx/ShotTracer.tscn`
  - 提供枪口端到命中端的纵向透明度 Shader。
- `tests/unit/test_weapon_clearance_state.gd`
  - 覆盖 `TUCKED` 转换和恢复计时。
- `tests/unit/test_weapon_clearance_controller.gd`
  - 覆盖永远接受人物 yaw、收枪包含关系和胶囊端点计算。
- `tests/unit/test_weapon_configuration.gd`
  - 验证远程资源不再定义局部枪口偏移。
- `tests/unit/test_weapon_feedback.gd`
  - 覆盖统一射线/喷火/曳光弹/反馈 origin 和整体淡出。
- `tests/integration/test_weapon_wall_clearance.gd`
  - 覆盖真实 90° 转身、三姿态射击方向、墙体截断和离墙恢复。

## 自动化验收

### 状态与转身

- `NORMAL`、`RAISED` 都被阻挡时提交 `TUCKED`，人物仍采用目标 `90°` yaw。
- `TUCKED` 胶囊保持长度 `1.55m`、半径 `0.12m`，中心为 `Vector3(0.0, 0.9, 0.0)`，长轴竖直。
- 数学断言和真实物理夹具共同证明 `TUCKED` 完整位于人物主体胶囊内部。
- `TUCKED` 中人物可原地转身、后退和侧移，不产生持续重叠或抖动。
- `RAISED` 安全时从 `TUCKED` 同帧恢复；`NORMAL` 连续安全 `0.15s` 后放下枪。

### 射击

- `NORMAL`、`RAISED`、`TUCKED` 的攻击方向都等于人物应用 yaw 后的 `-global_basis.z`。
- 枪口喷火位置、功能射线起点、曳光弹起点和 `attack_resolved.origin` 都等于当前胶囊枪口端点。
- `NORMAL`、`RAISED`、`TUCKED` 分别验证胶囊端点计算，避免只覆盖单一姿态。
- 墙位于胶囊端点与目标之间时，墙是第一次命中、弹道结束在墙面、目标生命不变。
- 移除墙后，相同起点和身体朝向能够命中目标。

### 曳光弹

- `ShotTracer.setup(from, to)` 后，局部 `+Z` 端映射到 `from`，局部 `-Z` 端映射到 `to`。
- 场景材质为支持透明度的无光照加法 Shader，枪口端进度为 `0.0`、命中端进度为 `1.0`。
- 生命周期开始时整体 alpha 为 `1.0`，中途下降，约 `0.08s` 后隐藏并归还对象池。
- 零长度弹道不显示。

### 完整验证命令

```bash
./tests/run_tests.sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
git diff --check
```

## 兼容性与迁移

- 现有远程武器场景继续保留 `Muzzle/MuzzleFlash` 节点结构，不需要为不同武器维护 Marker 偏移。
- 删除 `muzzle_anchor_offset` 后，手枪和步枪共享胶囊端点，但各自伤害、射程、射速和 tracer pool 大小保持不变。
- 原“目标 yaw 被双 probe 拒绝”的测试和规格失效，必须改为“人物永远转向，枪械进入 `TUCKED`”。
- 原“近战切远程双姿态受阻时拒绝切换”的契约失效，必须改为以 `TUCKED` 安全装备。

## 验收结论

完成后，人物朝向不再受枪械空间限制；枪械通过 `NORMAL/RAISED/TUCKED` 保持真实碰撞。所有远程射击从真实胶囊枪口端点沿人物实际前方发出，枪口喷火、伤害射线、曳光弹和反馈 origin 完全一致。曳光弹在射击帧整段出现，从枪口端向命中端增强，并在原生命周期内整体淡出。
