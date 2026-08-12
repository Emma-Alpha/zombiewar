# 大厅重设计（Brotato 布局 × 原创僵尸美术）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `MainMenu` 从「左列排版 + 3D 动态背景」重造为 Brotato 式大厅——静态剪影背景 + 居中聚光主角立绘 + 大字主按钮 + 边缘图标入口，并新增跨局材料货币存档。

**Architecture:** 美术全部由 codex CLI 生成原创僵尸题材 PNG 到 `assets/ui/menu/`；UI 用真实 Control 节点重建 `MainMenu.tscn` 的 UI 层（保留进出场 fade、音效、MenuEntrance 入场动画、MenuFlow/GameSession 导航）；跨局货币用新 autoload `MetaProgression` 存 `user://`，在退出到主菜单时把局内材料累加进存档（不动 `sim_world` 确定性逻辑）。

**Tech Stack:** Godot 4.7 / GDScript / Control UI（anchor 布局）/ codex CLI 文生图 / ConfigFile 存档。

## Global Constraints

- 视口基准 1280×720，`window/stretch/mode="canvas_items"`，`aspect="expand"`——UI 必须用 anchor 布局适配其它宽高比。
- CJK 字体统一用 `res://assets/fonts/NotoSansSC-UI.ttf`。
- 美术**原创**，不临摹 Brotato 版权素材。
- 跨局货币**只在单人局累加**；本地/联机不累加（避免刷币 + 不碰网络同步）。
- **不改动 `scripts/sim/sim_world.gd` 的局内材料逻辑**（`add_player_material`/`get_player_material`/`spend_player_material`，`sim_world.gd:1928-1946` 保持不变）。
- 图鉴/升级/设置系统**不存在**，本次只占位，点击提示「敬请期待」。
- 场景根节点改为 `Control`（原为 `Node3D`），背景改为静态 `TextureRect`。

## 现状关键事实（实施者必读）

- `MainMenu.tscn` 根为 `Node3D`，脚本 `scripts/menu/main_menu.gd`，含 `MenuBackdrop`(3D)、`SelectAudio`/`ConfirmAudio`/`BackAudio`(AudioStreamPlayer)、`MenuLayer`(CanvasLayer)→`MenuRoot`(Control)→`LeftColumn`、`FadeOverlay`(ColorRect)、`ExitDialog`、按钮 `%SinglePlayerButton`/`%LocalMultiplayerButton`/`%OnlineMultiplayerButton`/`%LeaderboardButton`/`%QuitButton`/`%ConfirmExitButton`。
- `main_menu.gd` 已有 `_start_transition(scene_path)`（fade + 切场景）、`_on_action_focused()`（focus 音效）、`_activate_focused_button()`（手柄 A）。
- 导航目标：`map_selection_scene_path="res://scenes/menu/MapSelection.tscn"`、`online_lobby_scene_path="res://scenes/menu/OnlineLobby.tscn"`、`leaderboard_scene_path="res://scenes/menu/LeaderboardPanel.tscn"`。
- 本地多人历史路径：`GameSession.begin_map_selection(GameSessionState.Mode.LOCAL_MULTIPLAYER)` → MapSelection。
- 返回主菜单路径：`gameplay_arena.gd:1352` `_handle_player_spawn_failure()` → `MainMenu.tscn`（单人）。**材料累加钩子就加在切场景之前。**
- `gameplay_arena.gd`：`online_mode`(bool, `:76`)、`_local_slot()`(`:931`)、`sim_world`（含 `get_player_material(slot)`）。
- 测试基建：`tools/validation/*.gd` 为 headless 脚本，用 `godot --headless -s <script>` 运行（参考现有 `validate_*.gd` / `selftest_*.gd`）。
- Godot 可执行：用 `godot`（或项目约定的二进制）；headless 运行 `-s`。

---

### Task 1: 生成全部美术素材（codex）

**Files:**
- Create: `assets/ui/menu/bg.png`, `hero.png`, `icon_coin.png`, `icon_local.png`, `icon_online.png`, `icon_codex.png`, `icon_upgrade.png`, `icon_leaderboard.png`, `icon_settings.png`

**Interfaces:**
- Produces: 上述 PNG 文件路径，供 Task 4 的 `.tscn` ext_resource 引用。

- [ ] **Step 1: 生成正式背景（中央留聚光空地，氛围与已验证的 bg_test 一致）**

```bash
mkdir -p assets/ui/menu
codex exec --sandbox workspace-write "Generate a 2D game main-menu background and save as PNG at assets/ui/menu/bg.png. Dark cartoon horror forest silhouette for an ORIGINAL zombie survival menu (NOT copying Brotato art). Deep purple-black night sky, layered black gnarled-tree and zombie silhouettes framing the left/right edges and background, a clear empty spotlight pool in the CENTER-BOTTOM where a character will stand, subtle vignette, flat cartoon vector style, muted dark palette so white UI text stays readable. 16:9, exactly 1920x1080."
```

- [ ] **Step 2: 生成主角立绘（透明背景，独立图层）**

```bash
codex exec --sandbox workspace-write "Generate a single cartoon zombie-hunter hero character sprite and save as PNG at assets/ui/menu/hero.png with a TRANSPARENT background. Full-body, standing idle pose, holding a shotgun, chunky flat cartoon style matching a dark purple horror menu, facing forward, original character design (not Brotato). Roughly 800x800, character centered with padding, alpha channel preserved."
```

- [ ] **Step 3: 生成一套图标（统一风格，透明背景，各 256×256）**

逐个生成（同一风格描述，保证成套）：

```bash
for pair in "icon_coin:a glowing cartoon material/scrap-metal currency crystal icon" \
            "icon_local:a cartoon couch-with-two-people local co-op icon" \
            "icon_online:a cartoon globe-with-signal online multiplayer icon" \
            "icon_codex:a cartoon open bestiary book icon" \
            "icon_upgrade:a cartoon up-arrow-with-gear upgrade icon" \
            "icon_leaderboard:a cartoon trophy leaderboard icon" \
            "icon_settings:a cartoon gear settings icon"; do
  name="${pair%%:*}"; desc="${pair#*:}"
  codex exec --sandbox workspace-write "Generate $desc and save as PNG at assets/ui/menu/${name}.png with a TRANSPARENT background. Flat cartoon style with a bold dark outline and a subtle dark circular backing disc, muted purple/red palette matching a dark horror game menu, centered, 256x256, alpha preserved."
done
```

- [ ] **Step 4: 人工核对产物**

确认 9 个文件存在且非空；用 Read 工具查看 `bg.png` 与 `hero.png` 确认构图（背景中央有空地、主角透明底）。任一不合格就重生成该张。

- [ ] **Step 5: Commit**

```bash
git add assets/ui/menu/
git commit -m "feat(menu): codex 生成大厅原创美术素材（背景/主角/图标）"
```

---

### Task 2: 新增跨局货币存档 autoload `MetaProgression`

**Files:**
- Create: `scripts/meta/meta_progression.gd`
- Modify: `project.godot`（`[autoload]` 块，约 `:24` 附近）
- Test: `tools/validation/selftest_meta_progression.gd`

**Interfaces:**
- Produces: 全局 autoload `MetaProgression`，方法：
  - `get_banked_material() -> int`
  - `add_banked_material(amount: int) -> void`（负值钳到 0，自动存盘）
  - `SAVE_PATH := "user://meta_save.cfg"`（常量）
- Consumes: 无（独立）。

- [ ] **Step 1: 写失败测试**

`tools/validation/selftest_meta_progression.gd`：

```gdscript
extends SceneTree

## headless 自测：MetaProgression 跨局货币存档。
## 运行: godot --headless -s tools/validation/selftest_meta_progression.gd

func _init() -> void:
	var mp := preload("res://scripts/meta/meta_progression.gd").new()
	# 用独立测试存档路径，避免污染真实存档
	mp.SAVE_PATH = "user://meta_save_test.cfg"
	if FileAccess.file_exists(mp.SAVE_PATH):
		DirAccess.remove_absolute(mp.SAVE_PATH)

	var ok := true
	ok = ok and _check(mp.get_banked_material() == 0, "初始为 0")
	mp.add_banked_material(150)
	ok = ok and _check(mp.get_banked_material() == 150, "累加 150")
	mp.add_banked_material(-50)
	ok = ok and _check(mp.get_banked_material() == 100, "减 50 → 100")
	mp.add_banked_material(-999)
	ok = ok and _check(mp.get_banked_material() == 0, "钳到非负")

	# 重新加载（模拟重启）应从磁盘读回 0… 先存个值再验
	mp.add_banked_material(77)
	var mp2 := preload("res://scripts/meta/meta_progression.gd").new()
	mp2.SAVE_PATH = "user://meta_save_test.cfg"
	mp2.load_save()
	ok = ok and _check(mp2.get_banked_material() == 77, "重启后读回 77")

	DirAccess.remove_absolute(mp.SAVE_PATH)
	print("SELFTEST meta_progression: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)

func _check(cond: bool, label: String) -> bool:
	if not cond:
		printerr("  FAIL: %s" % label)
	return cond
```

- [ ] **Step 2: 运行确认失败**

```bash
godot --headless -s tools/validation/selftest_meta_progression.gd
```
预期：FAIL（`res://scripts/meta/meta_progression.gd` 不存在）。

- [ ] **Step 3: 实现 `MetaProgression`**

`scripts/meta/meta_progression.gd`：

```gdscript
extends Node

## 跨局进度（元层）：目前只有跨局累计材料货币。
## 局内材料在 sim_world（每局清零），这里存的是「累计入银行账户」的材料，
## 主菜单左上角显示用。只读单人局的结算，本地/联机不累加。

var SAVE_PATH := "user://meta_save.cfg"
const SECTION := "meta"
const KEY_BANKED := "banked_material"

var _banked_material := 0

func _ready() -> void:
	load_save()

func get_banked_material() -> int:
	return _banked_material

## amount 可为负；结果钳到非负并立即存盘。
func add_banked_material(amount: int) -> void:
	_banked_material = maxi(0, _banked_material + amount)
	save()

func load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		_banked_material = int(cfg.get_value(SECTION, KEY_BANKED, 0))
	else:
		_banked_material = 0

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, KEY_BANKED, _banked_material)
	cfg.save(SAVE_PATH)
```

- [ ] **Step 4: 注册 autoload**

在 `project.godot` 的 `[autoload]` 块（`GameSession=` 行附近）加一行：

```
MetaProgression="*res://scripts/meta/meta_progression.gd"
```

- [ ] **Step 5: 运行测试确认通过**

```bash
godot --headless -s tools/validation/selftest_meta_progression.gd
```
预期：输出 `SELFTEST meta_progression: PASS`，退出码 0。

- [ ] **Step 6: Commit**

```bash
git add scripts/meta/meta_progression.gd project.godot tools/validation/selftest_meta_progression.gd
git commit -m "feat(meta): 新增 MetaProgression 跨局材料货币存档 autoload"
```

---

### Task 3: 单人局退出时把材料累加进跨局存档

**Files:**
- Modify: `scripts/gameplay/gameplay_arena.gd`（`_handle_player_spawn_failure()`，约 `:1340-1358`）
- Test: `tools/validation/selftest_meta_bank_hook.gd`

**Interfaces:**
- Consumes: `MetaProgression.add_banked_material(int)`（Task 2）；`sim_world.get_player_material(slot)`；`online_mode`、`GameSession.mode`、`_local_slot()`（现有）。
- Produces: 无新公共接口；行为=返回主菜单前把本局材料入银行。

- [ ] **Step 1: 写一个聚焦「累加判定逻辑」的纯函数测试**

把「该不该累加、累加多少」抽成可单测的纯函数，避免拉起整个 arena。新建 `scripts/meta/meta_banker.gd`：

```gdscript
class_name MetaBanker
extends RefCounted

## 判定一局结束时该把多少材料存入跨局银行。
## 规则：仅单人局累加；本地/联机不累加（避免刷币 + 不碰网络同步）。
static func compute_banked(mode: int, online_mode: bool, material: int) -> int:
	# GameSessionState.Mode.SINGLE == 0（见 game_session.gd Mode 枚举）
	const MODE_SINGLE := 0
	if online_mode:
		return 0
	if mode != MODE_SINGLE:
		return 0
	return maxi(0, material)
```

`tools/validation/selftest_meta_bank_hook.gd`：

```gdscript
extends SceneTree

func _init() -> void:
	var B := preload("res://scripts/meta/meta_banker.gd")
	var ok := true
	ok = ok and _c(B.compute_banked(0, false, 120) == 120, "单人+120")
	ok = ok and _c(B.compute_banked(0, false, 0) == 0, "单人+0")
	ok = ok and _c(B.compute_banked(1, false, 120) == 0, "本地多人不累加")
	ok = ok and _c(B.compute_banked(2, true, 120) == 0, "联机不累加")
	ok = ok and _c(B.compute_banked(0, false, -5) == 0, "负值钳到 0")
	print("SELFTEST meta_bank_hook: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)

func _c(cond: bool, label: String) -> bool:
	if not cond:
		printerr("  FAIL: %s" % label)
	return cond
```

- [ ] **Step 2: 运行确认失败**

```bash
godot --headless -s tools/validation/selftest_meta_bank_hook.gd
```
预期：FAIL（`meta_banker.gd` 不存在）。

- [ ] **Step 3: 在 `_handle_player_spawn_failure()` 里接钩子**

在 `gameplay_arena.gd` 该方法 `change_scene_to_file` **之前**插入（只在回主菜单时累加）：

```gdscript
	# 单局结束回主菜单前：把本局材料累加进跨局银行（仅单人局）。
	_bank_run_material_to_meta(session)
```

并在文件中新增私有方法（顶部加 `const MetaBankerScript = preload("res://scripts/meta/meta_banker.gd")`）：

```gdscript
## 把本局本机座位的材料累加进跨局银行。仅当目的地是主菜单（单人局）时
## 才有意义；本地/联机由 MetaBanker.compute_banked 判 0。
func _bank_run_material_to_meta(session: Node) -> void:
	var meta := get_node_or_null("/root/MetaProgression")
	if meta == null or sim_world == null or session == null:
		return
	var mode: int = session.mode
	var amount: int = MetaBankerScript.compute_banked(
		mode, online_mode, sim_world.get_player_material(_local_slot())
	)
	if amount > 0:
		meta.add_banked_material(amount)
```

> 注：`_handle_player_spawn_failure()` 里已有局部 `session` 变量（`:1348`）。若未来新增其它「回主菜单」路径（如正常通关结算），在同样位置调 `_bank_run_material_to_meta(session)` 即可——本次只接这条已存在的回主菜单路径。

- [ ] **Step 4: 运行两个测试确认通过**

```bash
godot --headless -s tools/validation/selftest_meta_bank_hook.gd
godot --headless -s tools/validation/selftest_meta_progression.gd
```
预期：均 PASS。

- [ ] **Step 5: Commit**

```bash
git add scripts/meta/meta_banker.gd scripts/gameplay/gameplay_arena.gd tools/validation/selftest_meta_bank_hook.gd
git commit -m "feat(meta): 单人局结束回主菜单时把材料累加进跨局银行"
```

---

### Task 4: 重建 `MainMenu.tscn` 为 Brotato 布局

**Files:**
- Modify: `scenes/menu/MainMenu.tscn`（整体重写 UI 层；根 `Node3D`→`Control`）
- Modify: `scripts/menu/main_menu.gd`（重写 onready 引用、入场元素列表、新增占位提示）
- Test: `tools/validation/validate_main_menu_layout.gd`

**Interfaces:**
- Consumes: Task 1 的 PNG；`MetaProgression.get_banked_material()`（Task 2）；现有 `MapSelection/OnlineLobby/LeaderboardPanel` 路径；现有 `MenuFlow`、`MenuEntrance`、`GameSession`。
- Produces: 主场景 `MainMenu.tscn` 可运行，节点唯一名供脚本用 `%` 引用：
  - `%StartButton`、`%LocalButton`、`%OnlineButton`、`%LeaderboardButton`、`%CodexButton`、`%UpgradeButton`、`%SettingsButton`、`%MaterialValue`(Label)、`%HeroTex`(TextureRect)、`%BgTex`(TextureRect)、`%FadeOverlay`、`%ExitDialog`、`%ConfirmExitButton`、`%ToastLabel`(Label)

**场景树（目标结构）：**

```
MainMenu (Control, anchors_preset=15 full_rect)        script=main_menu.gd
├─ SelectAudio / ConfirmAudio / BackAudio (AudioStreamPlayer)
├─ MobileOrientationGuard (instance)
├─ BgTex (TextureRect, full_rect, texture=bg.png, expand_mode=ignore_size? 用 stretch_mode=KEEP_ASPECT_COVERED)
├─ HeroTex (TextureRect, 居中锚定, texture=hero.png, stretch_mode=KEEP_ASPECT_CENTERED)
├─ UILayer (Control, full_rect)
│  ├─ TopBar (HBoxContainer, anchor 顶部, 左右撑开)
│  │  ├─ MaterialChip (HBoxContainer) ─ CoinIcon(TextureRect) + MaterialValue(Label "0")
│  │  └─ (spring) + SettingsButton(Button 图标)
│  ├─ LeftRail (VBoxContainer, anchor 左中) ─ LocalButton, OnlineButton
│  ├─ RightRail (VBoxContainer, anchor 右中) ─ CodexButton, UpgradeButton, LeaderboardButton
│  └─ StartButton (Button, anchor 底部居中, text="开始游戏", 大字)
├─ ToastLabel (Label, 居中, 初始隐藏, 用于「敬请期待」)
├─ FadeOverlay (ColorRect, full_rect, 黑, alpha=0)
└─ ExitDialog (Panel, 居中, 隐藏) ─ ConfirmExitButton / CancelExitButton
```

- [ ] **Step 1: 写布局结构校验测试（headless 实例化场景断言节点存在）**

`tools/validation/validate_main_menu_layout.gd`：

```gdscript
extends SceneTree

## headless：实例化 MainMenu，断言 Brotato 布局的关键节点与货币显示。
## 运行: godot --headless -s tools/validation/validate_main_menu_layout.gd

func _init() -> void:
	var packed := load("res://scenes/menu/MainMenu.tscn")
	if packed == null:
		printerr("FAIL: 无法加载 MainMenu.tscn")
		quit(1)
		return
	var menu := packed.instantiate()
	root.add_child(menu)
	var ok := true
	for path in ["BgTex", "HeroTex", "UILayer/TopBar", "UILayer/LeftRail",
			"UILayer/RightRail", "UILayer/StartButton", "FadeOverlay", "ToastLabel"]:
		ok = ok and _c(menu.get_node_or_null(path) != null, "缺节点 %s" % path)
	var start := menu.get_node_or_null("UILayer/StartButton") as Button
	ok = ok and _c(start != null and start.text == "开始游戏", "开始游戏按钮文案")
	var mv := menu.get_node_or_null("%MaterialValue") as Label
	ok = ok and _c(mv != null, "货币数值 Label 存在")
	quit(0 if ok else 1)

func _c(cond: bool, label: String) -> bool:
	if not cond:
		printerr("  FAIL: %s" % label)
	return cond
```

- [ ] **Step 2: 运行确认失败**

```bash
godot --headless -s tools/validation/validate_main_menu_layout.gd
```
预期：FAIL（当前 MainMenu 还是旧布局，缺 `BgTex`/`UILayer/StartButton` 等）。

- [ ] **Step 3: 重写 `MainMenu.tscn`**

要点（照 `scenes/menu/MainMenu.tscn` 现有写法）：
- 根节点改 `type="Control"`，`anchors_preset=15`、`grow_horizontal=2`、`grow_vertical=2`，挂 `main_menu.gd`。
- ext_resource 增加 `bg.png`、`hero.png`、各图标；保留 `ui_click.mp3`、CJK 字体、`MobileOrientationGuard`。
- `BgTex`：`TextureRect`，`anchors_preset=15`，`stretch_mode=6`(KEEP_ASPECT_COVERED)，`expand_mode=1`(IGNORE_SIZE)。
- `HeroTex`：`TextureRect`，锚定中心（`anchors_preset=8` CENTER 或自定义偏移到底部聚光处），`stretch_mode=5`(KEEP_ASPECT_CENTERED)，`texture_filter` 保持清晰。
- `StartButton`：底部居中，`anchors_preset=7`(CENTER_BOTTOM) 附近偏移，大号字体（CJK，`font_size≈40`），沿用 `StyleBox_button_primary`/`_hover` 配色（红系）。
- 图标按钮（`LocalButton` 等）：`Button`，`icon=<图标>`，`custom_minimum_size≈64×64`，`expand_icon=true`，透明底 + hover 高亮 StyleBox。
- `MaterialChip`：`CoinIcon`(TextureRect 32×32) + `MaterialValue`(Label)。
- 保留 `FadeOverlay`、`ExitDialog`、`ConfirmExitButton`、`CancelExitButton`（沿用旧子树，位置改居中）。
- 所有节点设 `unique_name_in_owner=true` 供 `%` 引用。

- [ ] **Step 4: 重写 `main_menu.gd`**

```gdscript
extends Control

const MenuFlow = preload("res://scripts/menu/menu_flow.gd")

@export_file("*.tscn") var map_selection_scene_path := \
	"res://scenes/menu/MapSelection.tscn"
@export_file("*.tscn") var online_lobby_scene_path := "res://scenes/menu/OnlineLobby.tscn"
@export_file("*.tscn") var leaderboard_scene_path := "res://scenes/menu/LeaderboardPanel.tscn"
@export_file("*.tscn") var local_lobby_scene_path := \
	"res://scenes/menu/LocalMultiplayerLobby.tscn"

@onready var start_button: Button = %StartButton
@onready var local_button: Button = %LocalButton
@onready var online_button: Button = %OnlineButton
@onready var leaderboard_button: Button = %LeaderboardButton
@onready var codex_button: Button = %CodexButton
@onready var upgrade_button: Button = %UpgradeButton
@onready var settings_button: Button = %SettingsButton
@onready var material_value: Label = %MaterialValue
@onready var hero_tex: TextureRect = %HeroTex
@onready var toast_label: Label = %ToastLabel
@onready var exit_dialog: Control = %ExitDialog
@onready var confirm_exit_button: Button = %ConfirmExitButton
@onready var fade_overlay: ColorRect = %FadeOverlay
@onready var select_audio: AudioStreamPlayer = $SelectAudio
@onready var confirm_audio: AudioStreamPlayer = $ConfirmAudio
@onready var back_audio: AudioStreamPlayer = $BackAudio

var flow := MenuFlow.new()
var _toast_tween: Tween = null

func _ready() -> void:
	_refresh_material()
	start_button.grab_focus()
	MenuEntrance.play(self, _entrance_elements(), 1)
	_breathe_hero()

func _entrance_elements() -> Array:
	return [
		material_value, codex_button, upgrade_button, settings_button,
		local_button, online_button, leaderboard_button,
		hero_tex, start_button,
	]

func _refresh_material() -> void:
	var meta := get_node_or_null("/root/MetaProgression")
	material_value.text = str(meta.get_banked_material() if meta != null else 0)

## 主角轻微上下浮动，让静态画面不至于死板。
func _breathe_hero() -> void:
	var base := hero_tex.position.y
	var t := create_tween().set_loops()
	t.tween_property(hero_tex, "position:y", base - 8.0, 1.8) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(hero_tex, "position:y", base, 1.8) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

## 占位入口：图鉴/升级/设置尚未实现，点击提示「敬请期待」。
func _show_toast(message: String) -> void:
	toast_label.text = message
	toast_label.modulate.a = 0.0
	toast_label.show()
	if _toast_tween != null:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_property(toast_label, "modulate:a", 1.0, 0.15)
	_toast_tween.tween_interval(1.2)
	_toast_tween.tween_property(toast_label, "modulate:a", 0.0, 0.4)

# ---- 导航 ----

func _on_start_button_pressed() -> void:
	if not flow.request_single():
		return
	GameSession.begin_map_selection(GameSessionState.Mode.SINGLE)
	_start_transition(map_selection_scene_path)

func _on_local_button_pressed() -> void:
	if not flow.request_local():
		return
	GameSession.begin_map_selection(GameSessionState.Mode.LOCAL_MULTIPLAYER)
	_start_transition(map_selection_scene_path)

func _on_online_button_pressed() -> void:
	if not flow.request_local():
		return
	GameSession.clear()
	_start_transition(online_lobby_scene_path)

func _on_leaderboard_button_pressed() -> void:
	if flow.state != MenuFlow.State.READY:
		return
	confirm_audio.play()
	get_tree().change_scene_to_file(leaderboard_scene_path)

func _on_codex_button_pressed() -> void:
	confirm_audio.play()
	_show_toast("图鉴 · 敬请期待")

func _on_upgrade_button_pressed() -> void:
	confirm_audio.play()
	_show_toast("升级 · 敬请期待")

func _on_settings_button_pressed() -> void:
	confirm_audio.play()
	_show_toast("设置 · 敬请期待")

func _start_transition(scene_path: String) -> void:
	confirm_audio.play()
	start_button.disabled = true
	local_button.disabled = true
	online_button.disabled = true
	leaderboard_button.disabled = true
	var tween := create_tween()
	tween.tween_property(fade_overlay, "color:a", 1.0, 0.32)
	await tween.finished
	get_tree().change_scene_to_file(scene_path)

# ---- 退出 ----

func _on_quit_requested() -> void:
	if not flow.request_exit():
		return
	confirm_audio.play()
	exit_dialog.show()
	confirm_exit_button.grab_focus()

func _on_confirm_exit_button_pressed() -> void:
	if flow.confirm_exit():
		get_tree().quit()

func _on_cancel_exit_button_pressed() -> void:
	if not flow.cancel_exit():
		return
	back_audio.play()
	exit_dialog.hide()

func _unhandled_input(event: InputEvent) -> void:
	var joy_button := event as InputEventJoypadButton
	var joy_a := joy_button != null and joy_button.pressed and \
		joy_button.button_index == JOY_BUTTON_A
	var joy_b := joy_button != null and joy_button.pressed and \
		joy_button.button_index == JOY_BUTTON_B
	if (event.is_action_pressed("ui_cancel") or joy_b) and \
			flow.state == MenuFlow.State.EXIT_CONFIRM:
		_on_cancel_exit_button_pressed()
		get_viewport().set_input_as_handled()
	elif joy_a and _activate_focused_button():
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel") and flow.state == MenuFlow.State.READY:
		_on_quit_requested()
		get_viewport().set_input_as_handled()

func _activate_focused_button() -> bool:
	var focused_button := get_viewport().gui_get_focus_owner() as Button
	if focused_button == null or focused_button.disabled:
		return false
	focused_button.pressed.emit()
	return true

func _on_action_focused() -> void:
	if not select_audio.playing:
		select_audio.play()
```

> 注：`GameSessionState` 是 `game_session.gd:2` 的 `class_name`，`Mode.SINGLE`/`LOCAL_MULTIPLAYER`/`ONLINE_MULTIPLAYER` 均已确认存在。`MenuEntrance`、`MenuFlow` 沿用现有实现，不改。

- [ ] **Step 5: 在 `.tscn` 里把按钮 `pressed`/`focus_entered` 信号接到脚本对应方法**

每个按钮 `pressed` → 对应 `_on_*_pressed`；所有可聚焦控件 `focus_entered` → `_on_action_focused`；`ConfirmExitButton.pressed`→`_on_confirm_exit_button_pressed`，`CancelExitButton.pressed`→`_on_cancel_exit_button_pressed`。

- [ ] **Step 6: 运行布局测试确认通过**

```bash
godot --headless -s tools/validation/validate_main_menu_layout.gd
```
预期：`PASS`，退出码 0。

- [ ] **Step 7: 视觉验证（截图）**

```bash
godot --headless --quit-after 5 res://scenes/menu/MainMenu.tscn  # 或用 godot-ai 的 editor_screenshot / project_run + screenshot
```
确认：背景铺满、主角居中、开始游戏按钮在底部、货币在左上、图标在两列。用 Read 看截图核对构图，不对就调 anchor/偏移。

- [ ] **Step 8: Commit**

```bash
git add scenes/menu/MainMenu.tscn scripts/menu/main_menu.gd tools/validation/validate_main_menu_layout.gd
git commit -m "feat(menu): 重建 MainMenu 为 Brotato 式大厅（静态背景+居中主角+边缘图标）"
```

---

### Task 5: 端到端联调 + 旧资源清理

**Files:**
- Modify: `scripts/menu/menu_backdrop.gd`、`scenes/menu/MenuBackdrop.tscn`（删除——确认无其它引用后）
- Test: 手动 / headless 截图

**Interfaces:**
- Consumes: 前面所有 Task 的产物。

- [ ] **Step 1: 确认 `MenuBackdrop` 无其它引用**

```bash
grep -rn "MenuBackdrop" scenes/ scripts/ --include="*.tscn" --include="*.gd"
```
预期：仅 `MainMenu.tscn`（已在新版移除）。若还有其它引用，先解除。

- [ ] **Step 2: 删除 3D 背景资源**

```bash
git rm scenes/menu/MenuBackdrop.tscn scripts/menu/menu_backdrop.gd
```
（连同对应 `.uid` 若存在。）

- [ ] **Step 3: 全量跑相关自测**

```bash
godot --headless -s tools/validation/selftest_meta_progression.gd
godot --headless -s tools/validation/selftest_meta_bank_hook.gd
godot --headless -s tools/validation/validate_main_menu_layout.gd
```
预期：全部 PASS。

- [ ] **Step 4: 多分辨率视觉核对**

分别以 1280×720、1920×1080、一个窄屏（如 900×720）跑主菜单截图，确认背景 `KEEP_ASPECT_COVERED` 不留黑边、UI 不溢出、文字可读。

- [ ] **Step 5: 手动跑通一局（单人）验证货币累加**

运行游戏 → 单人进图 → 杀几个僵尸得材料 → 触发回主菜单路径 → 主菜单左上角材料增加；退出游戏重开 → 数值仍在（读 `user://meta_save.cfg`）。

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore(menu): 移除 3D MenuBackdrop，完成大厅重设计联调"
```

---

## Self-Review 记录

- **Spec 覆盖**：美术(✅T1)、跨局存档(✅T2)、货币累加(✅T3)、场景重建+导航+占位(✅T4)、清理+验收(✅T5)。Spec 中「图鉴/升级/设置占位」「直接替换旧菜单」「不动 sim_world」均已落实。
- **类型一致**：`MetaProgression.get_banked_material()/add_banked_material(int)` 在 T2 定义、T3/T4 使用一致；`MetaBanker.compute_banked(mode:int, online:bool, material:int)->int` T3 定义并自测。`%MaterialValue`/`%HeroTex`/`%StartButton` 等节点名在 T4 接口块与场景树一致。
- **风险点（实施时注意）**：
  1. ~~`GameSessionState` 类名~~ 已确认：`game_session.gd:2` 定义 `class_name GameSessionState`，枚举值存在。
  2. `MenuEntrance.play()` 的签名（元素数组 + 方向）沿用现有调用，不改。
  3. 根节点 `Node3D`→`Control` 后，`MobileOrientationGuard`、`AudioStreamPlayer` 作为子节点仍有效。
