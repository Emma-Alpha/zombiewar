# 大厅重设计：Brotato 布局 × 原创僵尸美术

日期：2026-08-13
状态：已与用户对齐，待实施

## 背景与目标

当前 `MainMenu.tscn` 是「左列排版 + 3D 动态背景（`MenuBackdrop`）」：大标题 `ZOMBIE WAR`、左侧一列按钮（单人/本地/联机/排行/退出）。用户希望改为 **Brotato 式大厅布局**：静态剪影背景 + 居中聚光主角 + 大字主按钮 + 边缘图标入口。

美术**全部用 codex 生成原创僵尸题材素材**——学 Brotato 的构图语言（聚光主角、剪影环绕、深色背景），但不临摹其版权素材，保证可发布。

## 已确认的关键决策

| 决策点 | 结论 |
|---|---|
| 布局 | 照搬 Brotato 视觉语言（居中主角/聚光/边缘图标/大字 CTA） |
| 美术 | codex 生成原创素材，不临摹 |
| 背景 | 废弃 3D 动态背景，换 codex 静态大图铺底 |
| 主角 | codex 生成卡通立绘（透明背景，独立图层） |
| 主按钮 | 「开始游戏」→ 进现有地图/模式选择页（MapSelection） |
| 货币 | 左上角显示材料，**需新增跨局存档** |
| 图鉴/升级/设置 | 这些系统尚不存在 → **占位**，点击提示「敬请期待」 |
| 旧菜单 | **直接替换**（移除左列排版与 3D 背景） |

## 素材清单（codex 生成 → `assets/ui/menu/`）

| 文件 | 说明 | 状态 |
|---|---|---|
| `bg.png` | 1920×1080 黑暗森林剪影背景，中央底部留聚光空地 | ✅ 基线已验证（`bg_test.png`），正式版精修 |
| `hero.png` | 卡通僵尸猎手立绘，持枪，透明背景 | 待生成 |
| `icon_coin.png` | 材料货币图标 | 待生成 |
| `icon_local.png` / `icon_online.png` | 本地 / 联机入口图标 | 待生成 |
| `icon_codex.png` / `icon_upgrade.png` / `icon_settings.png` / `icon_leaderboard.png` | 图鉴/升级/设置/排行 | 待生成 |

图标统一风格：扁平卡通 + 描边 + 深色底衬。

## 场景结构（重建 `MainMenu.tscn` 的 UI 层）

- **背景层** `TextureRect`：全屏 `bg.png`，`keep_aspect_covered`。替换 `MenuBackdrop` 3D 场景。
- **主角层** `TextureRect`：`hero.png`，居中锚定，叠在背景聚光空地上，加轻微呼吸/浮动 tween。
- **UI 层** `Control`（真实可交互节点，anchor 布局适配分辨率）：
  - 顶栏：左 `货币图标 + 数量`（读跨局存档），右 `设置`（占位）
  - 左竖排：`本地`、`联机` 图标按钮
  - 右竖排：`图鉴`、`升级`、`排行` 图标按钮（图鉴/升级占位）
  - 底部中央：`开始游戏` 大按钮（主 CTA）
- 保留现有进出场 fade、按钮音效、`MenuEntrance` 入场动画。

## 导航逻辑（复用 `MenuFlow` + `GameSession`）

- `开始游戏` → `_start_transition(map_selection_scene_path)`
- `本地` → 现有 `local_multiplayer` 流程；`联机` → `online_lobby`
- `排行` → 现有 `leaderboard`
- `图鉴` / `升级` / `设置` → 占位，点击提示「敬请期待」

## 跨局货币存档（新增）

现状：材料是**局内货币**，`sim_world.reset()` 开新局即清零（`scripts/sim/sim_world.gd:405`），无跨局持久化。API：`add_player_material` / `get_player_material` / `spend_player_material`（`sim_world.gd:1928-1946`）。

方案：
- 新增 autoload `MetaProgression`（注册进 `project.godot`），负责跨局货币。
- 存到 `user://meta_save.cfg`（`ConfigFile`），字段如 `banked_material`。
- **累加点**：单人局结束（`GameSession.end_run` / `gameplay_arena` 结算路径）时，把该座位的 `get_player_material` 结算进 `banked_material` 并存盘。**本地/联机局不累加**（避免刷币 + 不碰网络同步确定性）。
- 主菜单左上角读取 `MetaProgression.get_banked_material()` 显示。
- **不改动 `sim_world` 的局内确定性逻辑**——跨局存档在表现/会话层做，与模拟层解耦。

## 明确不做

- 图鉴 / 升级 / 设置的实际系统（仅占位）。
- 不临摹 Brotato 版权素材。
- 本地/联机局的货币跨局累加。

## 自决项（用户可否决）

- 跨局存档用独立 autoload `MetaProgression`，而非改动 `sim_world`。
- 主角立绘加轻微呼吸/浮动 tween，避免静态画面死板。
- 占位入口：图鉴/升级/设置均放但点击提示「敬请期待」。

## 验收

- 主菜单呈现 Brotato 式布局：静态剪影背景 + 居中主角 + 底部「开始游戏」+ 边缘图标。
- 「开始游戏」进地图/模式选择；本地/联机/排行走现有流程。
- 单人局结束后材料累加进跨局存档，主菜单左上角正确显示累计值，重启游戏仍在。
- 1280×720 与其它宽高比下布局不溢出、文字可读。
