# 联机房间界面重做实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把联机大厅从单屏表单改成"四张座位卡 + 地图卡"的房间界面，并建立角色选择与地图选择的协议与数据接缝。

**Architecture:** 新增 `CharacterCatalog` / `MapCatalog` 两张按 `StringName` id 索引的资源目录；协议升到 v4，`roster` 与 `start` 消息携带 `character_id` 与 `map_id`；服务端只做 id 形状校验并新增"全员准备"开局闸门；客户端把 `OnlineLobby.tscn` 拆成互斥的 `BrowserPanel` / `RoomPanel` 两棵 Control 子树，每张座位卡用独立 `SubViewport` 渲染 3D 角色。

**Tech Stack:** Godot 4.7.1 / GDScript、Cloudflare Worker + Durable Objects (TypeScript)、vitest、`tools/validation/*.gd`（`extends SceneTree` 的源码级校验脚本）。

**设计文档:** `docs/superpowers/specs/2026-08-12-online-room-seat-cards-design.md`

## Global Constraints

- 座位数固定为 **4**。不得修改 `scripts/sim/sim_world.gd` 的 `MAX_PLAYER_SLOTS`、`scripts/net/lobby_protocol.gd` 的 `MAX_PLAYER_SLOTS`、`server/src/types.ts` 的 `MAX_PLAYERS_PER_ROOM`。
- 本计划**不触碰同步层**：二进制帧、`FrameHistory`、重连补帧、`SimWorld`、流场、tick 推进一律不改。
- 改动 `scripts/net/` 或 `server/src/lib/protocol.ts` 后，必须把 `PROTOCOL_VERSION` 在两端同时抬到 **4**，并运行 `tools/validation/validate_online_frame_sync.gd`（AGENTS.md 硬性要求）。
- 跨线传输的内容标识一律是 **`StringName` id 字符串**，不得使用数组下标。
- 内容 id 形状：`^[a-z0-9_]{1,32}$`。长度上限以常量 `CONTENT_ID_MAX_LENGTH = 32` 在两端各存一份，由双向常量对拍守护。
- GDScript 用 **Tab** 缩进，`snake_case` 文件与函数名，`PascalCase` 的 `class_name`，`UPPER_SNAKE_CASE` 常量。
- 新增用户可见中文文案后必须运行 `tools/validation/validate_ui_font_coverage.gd`。
- 新增 `.gd` / `.tscn` / `.tres` 后必须跑一次 headless editor 导入生成 `.uid`，并把 `.uid` 一起提交。
- 每个任务结束时提交一次，提交信息用 Conventional Commit 前缀。

**常用命令**

```bash
GODOT=/Applications/Godot.app/Contents/MacOS/Godot

# 运行单个校验脚本
$GODOT --headless --path . --script res://tools/validation/<name>.gd

# 导入资源、生成 .uid、捕获场景与脚本解析错误
$GODOT --headless --editor --path . --quit

# 服务端
cd server && npm test
cd server && npm run typecheck
```

---

### Task 1: 角色目录

**Files:**
- Create: `scripts/gameplay/character/character_definition.gd`
- Create: `scripts/gameplay/character/character_catalog.gd`
- Create: `scripts/gameplay/content_catalogs.gd`
- Create: `resources/characters/survivor_red.tres`
- Create: `resources/characters/survivor_blue.tres`
- Create: `resources/characters/survivor_amber.tres`
- Create: `resources/characters/survivor_green.tres`
- Create: `resources/characters/character_catalog.tres`
- Test: `tools/validation/validate_character_catalog.gd`

**Interfaces:**
- Produces:
  - `CharacterDefinition`：`character_id: StringName`、`display_name: String`、`accent_color: Color`
  - `CharacterCatalog`：`entries: Array[CharacterDefinition]`、`default_id() -> StringName`、`has_id(id: StringName) -> bool`、`get_by_id(id: StringName) -> CharacterDefinition`、`ids() -> Array[StringName]`、`next_id(from: StringName, step: int) -> StringName`
  - `ContentCatalogs`：`static characters() -> CharacterCatalog`
- Consumes: 无

- [ ] **Step 1: 写失败的校验脚本**

Create `tools/validation/validate_character_catalog.gd`：

```gdscript
extends SceneTree

## 角色目录的源码级校验。
##
## 目录里的 id 是**跨线传输**的：它会进 join / roster / start 三种消息。
## 一个重复的 id 意味着两台客户端把同一个字符串解析成不同的角色，
## 一个不合法的 id 会被服务端的形状校验静默丢弃——两种都不会当场报错，
## 只会在对局里表现成"别人的颜色和我看到的不一样"。所以在这里挡住。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_character_catalog.gd

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")

const MINIMUM_CHARACTER_COUNT := 4

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var catalog = ContentCatalogsScript.characters()
	_expect(catalog != null, "角色目录必须能加载", failures)
	if catalog == null:
		_finish(failures)
		return

	_expect(
		catalog.entries.size() >= MINIMUM_CHARACTER_COUNT,
		"角色目录至少要有 %d 个角色，实际 %d" % [
			MINIMUM_CHARACTER_COUNT, catalog.entries.size()
		],
		failures
	)

	var seen := {}
	var seen_colors := {}
	for definition in catalog.entries:
		_expect(definition != null, "角色目录里不允许有空条目", failures)
		if definition == null:
			continue
		var id := String(definition.character_id)
		_expect(
			LobbyProtocolScript.is_valid_content_id(id),
			"角色 id %s 不符合 ^[a-z0-9_]{1,%d}$" % [
				id, LobbyProtocolScript.CONTENT_ID_MAX_LENGTH
			],
			failures
		)
		_expect(not seen.has(id), "角色 id %s 重复" % id, failures)
		seen[id] = true
		_expect(
			definition.display_name.strip_edges() != "",
			"角色 %s 缺少显示名" % id,
			failures
		)
		# 配色是四个人在场上唯一的区分手段，撞色等于没做区分。
		var color_key := "%d_%d_%d" % [
			roundi(definition.accent_color.r * 255.0),
			roundi(definition.accent_color.g * 255.0),
			roundi(definition.accent_color.b * 255.0),
		]
		_expect(
			not seen_colors.has(color_key),
			"角色 %s 的配色与 %s 相同" % [id, seen_colors.get(color_key, "")],
			failures
		)
		seen_colors[color_key] = id

	_expect(
		catalog.has_id(catalog.default_id()),
		"默认角色 id %s 必须存在于目录中" % catalog.default_id(),
		failures
	)
	_expect(
		catalog.get_by_id(&"__missing__") == null,
		"未知 id 必须返回 null 而不是回退到默认角色",
		failures
	)

	# 循环切换必须能走遍每一个角色再回到起点，否则卡片上的左右箭头会漏掉角色。
	var walked := {}
	var cursor := catalog.default_id()
	for _index in range(catalog.entries.size()):
		walked[String(cursor)] = true
		cursor = catalog.next_id(cursor, 1)
	_expect(
		walked.size() == catalog.entries.size(),
		"next_id 循环只走到 %d 个角色，目录里有 %d 个" % [
			walked.size(), catalog.entries.size()
		],
		failures
	)
	_expect(
		cursor == catalog.default_id(),
		"next_id 走满一圈后必须回到起点",
		failures
	)
	_expect(
		catalog.next_id(catalog.default_id(), -1) == catalog.entries[catalog.entries.size() - 1].character_id,
		"next_id 向前一步必须从第一个角色绕到最后一个",
		failures
	)

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_character_catalog: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_character_catalog: %s" % failure)
	printerr("validate_character_catalog: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 2: 运行校验脚本确认失败**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_character_catalog.gd
```

预期：失败，报 `res://scripts/gameplay/content_catalogs.gd` 无法 preload（文件不存在）。

- [ ] **Step 3: 在协议里加内容 id 校验常量与函数**

在 `scripts/net/lobby_protocol.gd` 的 `const MAX_PLAYER_SLOTS := 4` 之后插入：

```gdscript
## 跨线内容标识（角色 id、地图 id）的长度上限。
## 服务端存着同一个数字并按同样的形状拒收，双向常量对拍守护两者相等。
## 之所以是"形状校验"而不是"白名单"：服务端不认识游戏内容，
## 维护一份 id 白名单意味着每加一个角色都要发一次 Worker。
const CONTENT_ID_MAX_LENGTH := 32

static func is_valid_content_id(value: String) -> bool:
	if value.length() == 0 or value.length() > CONTENT_ID_MAX_LENGTH:
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		var is_lower := code >= 97 and code <= 122
		var is_digit := code >= 48 and code <= 57
		var is_underscore := code == 95
		if not (is_lower or is_digit or is_underscore):
			return false
	return true
```

- [ ] **Step 4: 写 CharacterDefinition**

Create `scripts/gameplay/character/character_definition.gd`：

```gdscript
extends Resource
class_name CharacterDefinition

## 一个可选角色。
##
## A 阶段四个角色共用同一个 GLTF，只靠 accent_color 区分——它落在脚下光环、
## 名牌描边和座位卡描边三处，而不是给模型整体染色：角色用的是单张 atlas，
## material_override 会把脸和武器一并染了。
##
## B 阶段的三围与被动直接往这个类上加字段，不另起资源。

@export var character_id: StringName
@export var display_name := "幸存者"
@export var accent_color := Color(1.0, 1.0, 1.0, 1.0)
```

- [ ] **Step 5: 写 CharacterCatalog**

Create `scripts/gameplay/character/character_catalog.gd`：

```gdscript
extends Resource
class_name CharacterCatalog

## 按 id 索引的角色目录。
##
## 对外只认 StringName id，不认数组下标：下标会随目录顺序变化，
## 而 id 不会——往目录中间插一个角色不该让别人的编号跟着挪位。

@export var entries: Array[CharacterDefinition] = []

func default_id() -> StringName:
	if entries.is_empty():
		return &""
	return entries[0].character_id

func ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for definition in entries:
		if definition != null:
			result.append(definition.character_id)
	return result

func has_id(id: StringName) -> bool:
	return get_by_id(id) != null

## 未知 id 返回 null，绝不回退到默认角色。
## 回退会把"两端目录不一致"变成一次静默的外观分叉；调用方必须自己决定
## 是显示错误还是拒绝入局。
func get_by_id(id: StringName) -> CharacterDefinition:
	for definition in entries:
		if definition != null and definition.character_id == id:
			return definition
	return null

## 循环切换。step 为 +1/-1，超出两端时绕回。
func next_id(from: StringName, step: int) -> StringName:
	if entries.is_empty():
		return &""
	var index := 0
	for candidate in range(entries.size()):
		if entries[candidate] != null and entries[candidate].character_id == from:
			index = candidate
			break
	var count := entries.size()
	var next_index := ((index + step) % count + count) % count
	return entries[next_index].character_id
```

- [ ] **Step 6: 写 ContentCatalogs 访问器**

Create `scripts/gameplay/content_catalogs.gd`：

```gdscript
extends RefCounted
class_name ContentCatalogs

## 两张内容目录的唯一加载点。
##
## 不做成 autoload，也不在 CharacterCatalog 自己身上 preload 目录 .tres：
## 那个 .tres 的 script 就是 CharacterCatalog，自己 preload 自己是一个循环引用。
## 一个不被任何 .tres 引用的访问器脚本没有这个问题。

const CHARACTER_CATALOG_PATH := "res://resources/characters/character_catalog.tres"
const MAP_CATALOG_PATH := "res://resources/maps/map_catalog.tres"

static var _characters: CharacterCatalog = null
static var _maps: MapCatalog = null

static func characters() -> CharacterCatalog:
	if _characters == null:
		_characters = load(CHARACTER_CATALOG_PATH) as CharacterCatalog
	return _characters

static func maps() -> MapCatalog:
	if _maps == null:
		_maps = load(MAP_CATALOG_PATH) as MapCatalog
	return _maps
```

注意：`maps()` 引用的 `MapCatalog` 在 Task 2 才创建。本任务先把 `maps()` 一起写好，
Task 2 补上 `MapCatalog` 类与 `.tres`；在 Task 2 完成前 `maps()` 会解析失败，
但 `characters()` 不受影响，本任务的校验脚本也不调用它。

- [ ] **Step 7: 写四个角色资源**

Create `resources/characters/survivor_red.tres`：

```
[gd_resource type="Resource" script_class="CharacterDefinition" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/character/character_definition.gd" id="1_definition"]

[resource]
script = ExtResource("1_definition")
character_id = &"survivor_red"
display_name = "红衣"
accent_color = Color(0.906, 0.263, 0.212, 1)
```

Create `resources/characters/survivor_blue.tres`：

```
[gd_resource type="Resource" script_class="CharacterDefinition" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/character/character_definition.gd" id="1_definition"]

[resource]
script = ExtResource("1_definition")
character_id = &"survivor_blue"
display_name = "蓝衣"
accent_color = Color(0.243, 0.553, 0.925, 1)
```

Create `resources/characters/survivor_amber.tres`：

```
[gd_resource type="Resource" script_class="CharacterDefinition" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/character/character_definition.gd" id="1_definition"]

[resource]
script = ExtResource("1_definition")
character_id = &"survivor_amber"
display_name = "琥珀"
accent_color = Color(0.965, 0.678, 0.153, 1)
```

Create `resources/characters/survivor_green.tres`：

```
[gd_resource type="Resource" script_class="CharacterDefinition" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/character/character_definition.gd" id="1_definition"]

[resource]
script = ExtResource("1_definition")
character_id = &"survivor_green"
display_name = "青衣"
accent_color = Color(0.349, 0.769, 0.404, 1)
```

- [ ] **Step 8: 写目录资源**

Create `resources/characters/character_catalog.tres`：

```
[gd_resource type="Resource" script_class="CharacterCatalog" load_steps=6 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/character/character_catalog.gd" id="1_catalog"]
[ext_resource type="Resource" path="res://resources/characters/survivor_red.tres" id="2_red"]
[ext_resource type="Resource" path="res://resources/characters/survivor_blue.tres" id="3_blue"]
[ext_resource type="Resource" path="res://resources/characters/survivor_amber.tres" id="4_amber"]
[ext_resource type="Resource" path="res://resources/characters/survivor_green.tres" id="5_green"]

[resource]
script = ExtResource("1_catalog")
entries = [ExtResource("2_red"), ExtResource("3_blue"), ExtResource("4_amber"), ExtResource("5_green")]
```

- [ ] **Step 9: 导入并运行校验，确认通过**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_character_catalog.gd
```

预期：导入无 `Parse Error` / `Failed to load script`；校验脚本输出 `validate_character_catalog: PASS`，退出码 0。

- [ ] **Step 10: 字体覆盖校验**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_ui_font_coverage.gd
```

预期：PASS。若报缺字（「红」「蓝」「衣」「琥」「珀」「青」），按 AGENTS.md 的要求从完整 Noto Sans SC 重新生成子集，而不是逐字补。

- [ ] **Step 11: 提交**

```bash
git add scripts/gameplay/character scripts/gameplay/content_catalogs.gd \
  scripts/net/lobby_protocol.gd resources/characters \
  tools/validation/validate_character_catalog.gd
git commit -m "feat: 新增角色目录与内容 id 形状校验"
```

---

### Task 2: 地图目录

**Files:**
- Modify: `scripts/gameplay/map/map_definition.gd`
- Create: `scripts/gameplay/map/map_catalog.gd`
- Create: `resources/maps/map_catalog.tres`
- Modify: `resources/maps/demo/demo_map.tres`
- Test: `tools/validation/validate_map_catalog.gd`

**Interfaces:**
- Consumes: `ContentCatalogs.maps()`（Task 1 已写好访问器）、`LobbyProtocol.is_valid_content_id()`
- Produces:
  - `MapDefinition` 新增 `thumbnail: Texture2D`、`difficulty: int`
  - `MapCatalog`：`entries: Array[MapDefinition]`、`default_id() -> StringName`、`has_id(id: StringName) -> bool`、`get_by_id(id: StringName) -> MapDefinition`、`ids() -> Array[StringName]`

- [ ] **Step 1: 写失败的校验脚本**

Create `tools/validation/validate_map_catalog.gd`：

```gdscript
extends SceneTree

## 地图目录的源码级校验。
##
## 地图 id 决定整局跑哪张图，是所有跨线内容标识里后果最重的一个：
## 两端把同一个 id 解析成不同的 MapDefinition，等于两端跑着不同的障碍布局，
## 而流场是从障碍布局算出来的——僵尸会当场走出两条不同的路。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_map_catalog.gd

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var catalog = ContentCatalogsScript.maps()
	_expect(catalog != null, "地图目录必须能加载", failures)
	if catalog == null:
		_finish(failures)
		return

	_expect(not catalog.entries.is_empty(), "地图目录不能为空", failures)

	var seen := {}
	for definition in catalog.entries:
		_expect(definition != null, "地图目录里不允许有空条目", failures)
		if definition == null:
			continue
		var id := String(definition.map_id)
		_expect(
			LobbyProtocolScript.is_valid_content_id(id),
			"地图 id %s 不符合 ^[a-z0-9_]{1,%d}$" % [
				id, LobbyProtocolScript.CONTENT_ID_MAX_LENGTH
			],
			failures
		)
		_expect(not seen.has(id), "地图 id %s 重复" % id, failures)
		seen[id] = true
		_expect(
			definition.display_name.strip_edges() != "",
			"地图 %s 缺少显示名" % id,
			failures
		)
		_expect(
			definition.content_scene != null,
			"地图 %s 缺少 content_scene" % id,
			failures
		)
		_expect(
			definition.difficulty >= 1 and definition.difficulty <= 5,
			"地图 %s 的难度 %d 不在 1..5" % [id, definition.difficulty],
			failures
		)
		# 玩家出生点数量必须够坐满一间房，否则房间能坐 4 个人但地图开不了局。
		_expect(
			definition.player_spawn_positions.size() >= LobbyProtocolScript.MAX_PLAYER_SLOTS,
			"地图 %s 只有 %d 个出生点，房间最多 %d 人" % [
				id,
				definition.player_spawn_positions.size(),
				LobbyProtocolScript.MAX_PLAYER_SLOTS,
			],
			failures
		)

	_expect(
		catalog.has_id(catalog.default_id()),
		"默认地图 id %s 必须存在于目录中" % catalog.default_id(),
		failures
	)
	_expect(
		catalog.get_by_id(&"__missing__") == null,
		"未知地图 id 必须返回 null 而不是回退到默认地图",
		failures
	)

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_catalog: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_map_catalog: %s" % failure)
	printerr("validate_map_catalog: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 2: 运行校验脚本确认失败**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_map_catalog.gd
```

预期：失败，`ContentCatalogs.maps()` 返回 null（`map_catalog.tres` 不存在）。

- [ ] **Step 3: 给 MapDefinition 加两个字段**

在 `scripts/gameplay/map/map_definition.gd` 的 `@export var display_name := "地图"` 之后插入：

```gdscript
## 地图卡上的缩略图。允许为空——空时地图卡画一块用 display_name 打底的占位色块，
## 而不是留一个空洞。真实缩略图需要人进游戏俯视截图，不该阻塞这条链路。
@export var thumbnail: Texture2D
## 地图卡上的难度星级，1..5。
@export_range(1, 5, 1) var difficulty := 3
```

- [ ] **Step 4: 写 MapCatalog**

Create `scripts/gameplay/map/map_catalog.gd`：

```gdscript
extends Resource
class_name MapCatalog

## 按 id 索引的地图目录。语义与 CharacterCatalog 完全一致：
## 只认 StringName id，未知 id 返回 null 而不回退。

@export var entries: Array[MapDefinition] = []

func default_id() -> StringName:
	if entries.is_empty():
		return &""
	return entries[0].map_id

func ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for definition in entries:
		if definition != null:
			result.append(definition.map_id)
	return result

func has_id(id: StringName) -> bool:
	return get_by_id(id) != null

func get_by_id(id: StringName) -> MapDefinition:
	for definition in entries:
		if definition != null and definition.map_id == id:
			return definition
	return null
```

- [ ] **Step 5: 确认 demo 地图的 id 与难度**

打开 `resources/maps/demo/demo_map.tres`，在 `[resource]` 段确认/补上：

```
map_id = &"demo"
difficulty = 3
```

若 `map_id` 已存在且不等于 `demo`，以文件里的实际值为准，并在后续步骤中同步使用该值。
若 `display_name` 为默认的 `"地图"`，改成 `"废弃仓库"`。

- [ ] **Step 6: 写目录资源**

Create `resources/maps/map_catalog.tres`：

```
[gd_resource type="Resource" script_class="MapCatalog" load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/gameplay/map/map_catalog.gd" id="1_catalog"]
[ext_resource type="Resource" path="res://resources/maps/demo/demo_map.tres" id="2_demo"]

[resource]
script = ExtResource("1_catalog")
entries = [ExtResource("2_demo")]
```

- [ ] **Step 7: 导入并运行校验，确认通过**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_map_catalog.gd
```

预期：`validate_map_catalog: PASS`。

- [ ] **Step 8: 跑既有地图校验，确认没改坏**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_map_definitions.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_demo_map_data_driven.gd
```

预期：两者都 PASS。

- [ ] **Step 9: 提交**

```bash
git add scripts/gameplay/map resources/maps tools/validation/validate_map_catalog.gd
git commit -m "feat: 新增地图目录与地图卡展示字段"
```

---

### Task 3: 协议 v4 与双向常量对拍

**Files:**
- Modify: `scripts/net/lobby_protocol.gd`
- Modify: `server/src/lib/protocol.ts`
- Create: `server/src/lib/room_rules.ts`
- Modify: `tools/validation/validate_online_frame_sync.gd`
- Modify: `server/test/protocol.test.ts`
- Create: `server/test/room_rules.test.ts`
- Delete: `tools/validation/fixtures/protocol/`（6 个 JSON）

**Interfaces:**
- Consumes: `LobbyProtocol.CONTENT_ID_MAX_LENGTH`、`LobbyProtocol.is_valid_content_id()`（Task 1）
- Produces:
  - 两端 `PROTOCOL_VERSION = 4`
  - `server/src/lib/protocol.ts` 导出 `CONTENT_ID_MAX_LENGTH = 32`；`RosterEntry` 增加 `character_id: string`
  - `server/src/lib/room_rules.ts` 导出 `isValidContentId(value: unknown): value is string` 与 `allNonHostSeatsReady(seats, hostSlot): boolean`

- [ ] **Step 1: 写失败的服务端规则测试**

Create `server/test/room_rules.test.ts`：

```typescript
import { describe, expect, it } from 'vitest';

import { allNonHostSeatsReady, isValidContentId } from '../src/lib/room_rules.js';

describe('isValidContentId', () => {
  it('accepts lowercase, digits and underscore', () => {
    expect(isValidContentId('survivor_red')).toBe(true);
    expect(isValidContentId('map01')).toBe(true);
    expect(isValidContentId('a')).toBe(true);
  });

  it('rejects anything the client could not have produced', () => {
    expect(isValidContentId('')).toBe(false);
    expect(isValidContentId('Survivor')).toBe(false);
    expect(isValidContentId('survivor-red')).toBe(false);
    expect(isValidContentId('survivor red')).toBe(false);
    expect(isValidContentId('a'.repeat(33))).toBe(false);
    expect(isValidContentId(null)).toBe(false);
    expect(isValidContentId(42)).toBe(false);
    expect(isValidContentId(undefined)).toBe(false);
  });

  it('accepts exactly the length ceiling', () => {
    expect(isValidContentId('a'.repeat(32))).toBe(true);
  });
});

describe('allNonHostSeatsReady', () => {
  const seat = (ready: boolean) => ({ ready });

  it('is true for a lone host', () => {
    expect(allNonHostSeatsReady([seat(false), null, null, null], 0)).toBe(true);
  });

  it('ignores the host own ready flag', () => {
    expect(allNonHostSeatsReady([seat(false), seat(true), null, null], 0)).toBe(true);
  });

  it('is false while any guest is not ready', () => {
    expect(allNonHostSeatsReady([seat(true), seat(true), seat(false), null], 0)).toBe(false);
  });

  it('is true when every guest is ready', () => {
    expect(allNonHostSeatsReady([seat(false), seat(true), seat(true), null], 0)).toBe(true);
  });

  it('honours a host that is not in slot 0', () => {
    // 房主迁移后 hostSlot 可能是任意一个座位，闸门必须跟着走。
    expect(allNonHostSeatsReady([seat(false), seat(true), null, null], 1)).toBe(false);
    expect(allNonHostSeatsReady([seat(true), seat(false), null, null], 1)).toBe(true);
  });

  it('is false when there is no host at all', () => {
    // hostSlot 为 -1 意味着房间是空的，开局没有意义。
    expect(allNonHostSeatsReady([null, null, null, null], -1)).toBe(false);
  });
});
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd server && npm test
```

预期：FAIL，报无法解析 `../src/lib/room_rules.js`。

- [ ] **Step 3: 写 room_rules.ts**

Create `server/src/lib/room_rules.ts`：

```typescript
/**
 * Room decisions that are pure functions of the seat table.
 *
 * They live here rather than inside the Durable Object so they can be tested
 * without standing up a WebSocket and a DurableObjectState: the rules are the
 * part that is worth testing, and the object around them is plumbing.
 */

import { CONTENT_ID_MAX_LENGTH } from './protocol.js';

const CONTENT_ID_PATTERN = new RegExp(`^[a-z0-9_]{1,${CONTENT_ID_MAX_LENGTH}}$`);

/**
 * Shape-only validation for a content identifier (character id, map id).
 *
 * Deliberately not an allowlist: the server does not know the game's content,
 * and keeping one here would mean deploying the Worker every time a character
 * is added. The client refuses to enter a match carrying an id its own catalog
 * does not have, which is where an unknown id actually gets caught.
 */
export function isValidContentId(value: unknown): value is string {
  return typeof value === 'string' && CONTENT_ID_PATTERN.test(value);
}

/**
 * The host may start once every *other* occupied seat is ready. The host's own
 * flag is ignored -- pressing start is the host's readiness.
 */
export function allNonHostSeatsReady(
  seats: ReadonlyArray<{ ready: boolean } | null>,
  hostSlot: number,
): boolean {
  if (hostSlot < 0) return false;
  return seats.every((seat, slot) => seat === null || slot === hostSlot || seat.ready);
}
```

- [ ] **Step 4: 在服务端协议里加常量并抬版本**

在 `server/src/lib/protocol.ts` 中把 `export const PROTOCOL_VERSION = 3;` 改为：

```typescript
export const PROTOCOL_VERSION = 4;
```

在 `export const OPCODE_LOBBY_MIN = 0x00;` 之前插入：

```typescript
/**
 * Length ceiling for a cross-wire content identifier (character id, map id).
 * The Godot client holds the same number; the two are diffed in both
 * directions by `server/test/protocol.test.ts` and
 * `tools/validation/validate_online_frame_sync.gd`.
 */
export const CONTENT_ID_MAX_LENGTH = 32;
```

在 `RosterEntry` 接口中，`ready: boolean;` 之后插入：

```typescript
  /** Opaque to the server; resolved against the client's own catalog. */
  character_id: string;
```

- [ ] **Step 5: 修正 protocol.ts 头注释里的错误路径**

`server/src/lib/protocol.ts` 顶部的文档注释里，把

```
 * `res://scripts/net/lobby_protocol.gd`. Two copies, and a client-side
 * validation script that diffs them against `protocol/fixtures/`.
```

改成

```
 * `res://scripts/net/lobby_protocol.gd`. Two copies, diffed against each other
 * in both directions: `server/test/protocol.test.ts` reads the GDScript file,
 * and `tools/validation/validate_online_frame_sync.gd` reads this one.
```

- [ ] **Step 6: 抬客户端协议版本**

在 `scripts/net/lobby_protocol.gd` 中把 `const PROTOCOL_VERSION := 3` 改为：

```gdscript
const PROTOCOL_VERSION := 4
```

- [ ] **Step 7: 删除无人读取的过期 fixtures**

这 6 个 JSON 没有任何代码读取（`grep -rn "fixtures/protocol" tools scripts server` 无命中），
且 `manifest.json` 与 `handshake.json` 停在 `protocol_version: 1`。留着一份没人校验、
版本停在三代以前的"协议样例"，下一个人会把它当权威。

```bash
git rm -r tools/validation/fixtures/protocol
```

- [ ] **Step 8: 把新常量加进两个方向的对拍**

在 `tools/validation/validate_online_frame_sync.gd` 的 `expected` 字典中，
`"FRAME_HISTORY_LIMIT": LobbyProtocolScript.FRAME_HISTORY_LIMIT,` 之后插入：

```gdscript
		"CONTENT_ID_MAX_LENGTH": LobbyProtocolScript.CONTENT_ID_MAX_LENGTH,
```

在 `server/test/protocol.test.ts` 中，把 `CONTENT_ID_MAX_LENGTH` 加进从
`'../src/lib/protocol.js'` 的 import 列表，并在既有的常量对拍 `describe` 块里增加一条：

```typescript
  it('keeps CONTENT_ID_MAX_LENGTH in step with the client', () => {
    const source = readFileSync(CLIENT_PROTOCOL, 'utf8');
    expect(readGdConstant(source, 'CONTENT_ID_MAX_LENGTH')).toBe(CONTENT_ID_MAX_LENGTH);
  });
```

若既有文件里常量对拍是用表驱动写的（一个名字数组配一个 `it.each`），
把 `CONTENT_ID_MAX_LENGTH` 加进那个数组即可，不要另写一条重复的用例。

- [ ] **Step 9: 运行两端测试确认通过**

```bash
cd server && npm test && npm run typecheck
```

预期：全部 PASS，`room_rules.test.ts` 12 条用例全绿。

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_online_frame_sync.gd
```

预期：`validate_online_frame_sync: PASS`。若报 `协议常量 PROTOCOL_VERSION 不一致`，
说明只抬了一端的版本号。

- [ ] **Step 10: 提交**

```bash
git add scripts/net/lobby_protocol.gd server/src/lib/protocol.ts \
  server/src/lib/room_rules.ts server/test tools/validation/validate_online_frame_sync.gd
# fixtures 的删除已由上面的 `git rm -r` 暂存，无需再 add
git commit -m "feat: 协议升到 v4 并补内容 id 校验规则"
```

---

### Task 4: 服务端房间逻辑

**Files:**
- Modify: `server/src/room_do.ts`

**Interfaces:**
- Consumes: `isValidContentId()`、`allNonHostSeatsReady()`（Task 3）、`RosterEntry.character_id`（Task 3）
- Produces（线上载荷，Task 5 的客户端据此解析）：
  - `roster` 消息顶层新增 `map_id: string`；`players[]` 每项新增 `character_id: string`
  - `start` 消息顶层新增 `map_id: string`；`slots[]` 每项新增 `character_id: string`
  - 接受 `{type:'select_character', character_id}` 与 `{type:'select_map', map_id}`

- [ ] **Step 1: 引入新依赖并给 Seat 加字段**

在 `server/src/room_do.ts` 的 import 区，`import { FrameHistory } from './lib/frame_history.js';` 之前插入：

```typescript
import { allNonHostSeatsReady, isValidContentId } from './lib/room_rules.js';
```

把 `Seat` 接口改成：

```typescript
interface Seat {
  playerId: string;
  nickname: string;
  ready: boolean;
  /**
   * Opaque to the server. It rides on the seat rather than being remembered by
   * the client because `startMatch` compacts the seat table: slot numbers move,
   * and a client acting on the number it held at join time would apply someone
   * else's choice.
   */
  characterId: string;
  socket: WebSocket | null;
  lastSeenAt: number;
}
```

- [ ] **Step 2: 给房间加 mapId 字段**

在 `private hostSlot = -1;` 之后插入：

```typescript
  /**
   * The map every client will load when the match starts. Opaque to the server;
   * the host writes it with a concrete id and clients resolve it against their
   * own catalog, refusing to enter if they do not have it.
   */
  private mapId = '';
```

- [ ] **Step 3: 在 join 中读取 character_id 并写进座位**

在 `onJoin` 中，`nickname` 解析之后、座位分配之前，加入：

```typescript
    const requestedCharacter = message['character_id'];
    const characterId = isValidContentId(requestedCharacter) ? requestedCharacter : '';
```

把 `this.seats[slot] = { playerId, nickname, ready: false, socket, lastSeenAt: Date.now() };` 改为：

```typescript
      this.seats[slot] = {
        playerId,
        nickname,
        ready: false,
        characterId,
        socket,
        lastSeenAt: Date.now(),
      };
```

在重连认领已有座位的分支中（`seat.nickname = nickname;` 附近），加入：

```typescript
      if (characterId !== '') seat.characterId = characterId;
```

- [ ] **Step 4: 新增两个消息分支**

在 `switch (type)` 中，`case 'ready':` 分支之后插入：

```typescript
      case 'select_character': {
        // 已准备的座位不能改选择：别人是对着当前这套阵容点的准备。
        if (this.roomState !== 'lobby' || seat.ready) return;
        const requested = message['character_id'];
        if (!isValidContentId(requested)) return;
        seat.characterId = requested;
        this.broadcastRoster();
        return;
      }
      case 'select_map': {
        if (this.roomState !== 'lobby' || slot !== this.hostSlot) return;
        const requested = message['map_id'];
        if (!isValidContentId(requested)) return;
        this.mapId = requested;
        // 换图作废所有准备：大家是对着旧图点的。
        for (const entry of this.seats) if (entry !== null) entry.ready = false;
        this.broadcastRoster();
        return;
      }
```

三种拒绝（非 lobby 态、非房主、id 形状非法）一律静默返回：客户端界面本就不该发出
这些消息，收到即意味着对端有 bug 或有人手搓，两种都不值得新增一条错误消息类型。

- [ ] **Step 5: 给开局加全员准备闸门**

把 `case 'start':` 分支改为：

```typescript
      case 'start':
        if (slot !== this.hostSlot) return;
        if (!allNonHostSeatsReady(this.seats, this.hostSlot)) {
          this.diag('start_rejected', { why: 'not_all_ready', seats: this.diagSeats() });
          return;
        }
        this.startMatch();
        return;
```

- [ ] **Step 6: 扩展 roster 与 start 载荷**

把 `roster()` 改为：

```typescript
  private roster(): RosterEntry[] {
    return this.occupiedSeats().map(({ slot, seat }) => ({
      slot,
      player_id: seat.playerId,
      nickname: seat.nickname,
      ready: seat.ready,
      connected: seat.socket !== null,
      character_id: seat.characterId,
    }));
  }
```

把 `broadcastRoster()` 改为：

```typescript
  private broadcastRoster(): void {
    this.broadcast({
      type: 'roster',
      state: this.roomState,
      host_slot: this.hostSlot,
      map_id: this.mapId,
      players: this.roster(),
    });
  }
```

在 `startMatch()` 的 `this.broadcast({ type: 'start', ... })` 中，把 `slots` 与顶层字段改为：

```typescript
    this.broadcast({
      type: 'start',
      seed: this.seed,
      tick: 0,
      map_id: this.mapId,
      // player_id is here so a client can re-derive its own slot after the
      // compaction above without trusting the one it got at welcome time.
      slots: occupied.map((entry) => ({
        slot: entry.slot,
        nickname: entry.seat.nickname,
        player_id: entry.seat.playerId,
        character_id: entry.seat.characterId,
      })),
    });
```

- [ ] **Step 7: 确认一局结束后 mapId 与准备状态的处置**

`finishMatch` 里已有 `for (const seat of this.seats) if (seat !== null) seat.ready = false;`（约 `room_do.ts:612`）。
`mapId` 与 `characterId` **保持不变**：一局打完回到房间，大家上一局选的图和角色还在，
再点一次准备就能重开，这是玩家预期的行为。不需要改动。

- [ ] **Step 8: 类型检查与测试**

```bash
cd server && npm run typecheck && npm test
```

预期：全部 PASS。若 `typecheck` 报 `Property 'characterId' is missing`，说明还有一处
构造 `Seat` 的地方没补字段——搜索 `lastSeenAt: Date.now()` 找齐。

- [ ] **Step 9: 提交**

```bash
git add server/src/room_do.ts
git commit -m "feat: 房间支持角色与地图选择并要求全员准备开局"
```

---

### Task 5: RoomClient 客户端协议

**Files:**
- Modify: `scripts/net/room_client.gd`
- Modify: `scripts/net/net_session.gd`
- Test: `tools/validation/validate_room_client_lobby_messages.gd`

**Interfaces:**
- Consumes: Task 4 的线上载荷
- Produces:
  - `RoomClient.character_id: StringName`、`RoomClient.room_map_id: String`
  - `RoomClient.connect_to_room(code, session_token, display_name, character_id)`（新增第 4 个参数）
  - `RoomClient.select_character(id: StringName)`、`RoomClient.select_map(id: StringName)`
  - `RoomClient.join_payload()` 增加 `character_id`
  - `NetSession.leave_room()` 行为不变

- [ ] **Step 1: 写失败的校验脚本**

Create `tools/validation/validate_room_client_lobby_messages.gd`：

```gdscript
extends SceneTree

## RoomClient 的大厅消息校验。不开 socket——这些断言问的是"消息长什么样"
## 和"收到消息后本机状态变成什么"，两者都不需要一台真服务器。
##
## join_payload 单独可断言这一点是既有设计（见 room_client.gd 里的注释）：
## 握手里少报一个字段，服务端就少知道一件事，而这类错误不会当场炸。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_room_client_lobby_messages.gd

const RoomClientScript = preload("res://scripts/net/room_client.gd")
const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var client = RoomClientScript.new()
	root.add_child(client)
	await process_frame

	client.connect_to_room("ABCDEF", "token-1", "阿波", &"survivor_blue")
	var payload := client.join_payload()
	_expect(
		int(payload.get("protocol_version", -1)) == LobbyProtocolScript.PROTOCOL_VERSION,
		"握手必须带当前协议版本",
		failures
	)
	_expect(
		String(payload.get("character_id", "")) == "survivor_blue",
		"握手必须带入房时选定的角色 id，实际 %s" % String(payload.get("character_id", "")),
		failures
	)
	_expect(
		int(payload.get("resume_tick", 0)) == -1,
		"未消费过帧时 resume_tick 必须是 -1",
		failures
	)

	# roster 携带的 map_id 必须落到本机状态上，而且要在 roster_changed 发出**之前**
	# 落好：面板是在那个信号里读 room_map_id 的，晚一步就会画上一次的地图。
	var seen_map_id := ""
	client.roster_changed.connect(
		func(_players, _host_slot, _state): seen_map_id = client.room_map_id
	)
	client._handle_packet(JSON.stringify({
		"type": "roster",
		"state": "lobby",
		"host_slot": 0,
		"map_id": "demo",
		"players": [
			{
				"slot": 0,
				"player_id": "p0",
				"nickname": "阿波",
				"ready": false,
				"connected": true,
				"character_id": "survivor_red",
			},
		],
	}).to_utf8_buffer())
	_expect(client.room_map_id == "demo", "roster 的 map_id 必须落到 room_map_id", failures)
	_expect(
		seen_map_id == "demo",
		"room_map_id 必须在 roster_changed 发出前就更新，实际 %s" % seen_map_id,
		failures
	)
	_expect(client.roster.size() == 1, "roster 必须存下座位表", failures)
	_expect(
		String(client.roster[0].get("character_id", "")) == "survivor_red",
		"roster 条目必须保留 character_id",
		failures
	)

	# start 同样携带 map_id，并且要在 match_started 发出前落好。
	var started_map_id := ""
	var started_slots: Array = []
	client.match_started.connect(
		func(_seed, slots):
			started_map_id = client.room_map_id
			started_slots = slots
	)
	client._handle_packet(JSON.stringify({
		"type": "start",
		"seed": 123,
		"tick": 0,
		"map_id": "demo",
		"slots": [
			{"slot": 0, "nickname": "阿波", "player_id": "p0", "character_id": "survivor_red"},
		],
	}).to_utf8_buffer())
	_expect(started_map_id == "demo", "start 的 map_id 必须在 match_started 前落好", failures)
	_expect(
		started_slots.size() == 1 and String(started_slots[0].get("character_id", "")) == "survivor_red",
		"match_started 必须透出每个座位的 character_id",
		failures
	)

	# 未连接时发选择请求必须是空操作，而不是崩溃。
	client.select_character(&"survivor_green")
	client.select_map(&"demo")
	_expect(
		client.character_id == &"survivor_green",
		"select_character 必须记住本机选择，便于重连时随握手重发",
		failures
	)

	client.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_room_client_lobby_messages: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_room_client_lobby_messages: %s" % failure)
	printerr("validate_room_client_lobby_messages: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 2: 运行校验脚本确认失败**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_room_client_lobby_messages.gd
```

预期：失败，`connect_to_room` 接收 3 个参数但传了 4 个。

- [ ] **Step 3: 给 RoomClient 加状态字段**

在 `scripts/net/room_client.gd` 中，`var room_state := "lobby"` 之后插入：

```gdscript
## 本机选定的角色。记在这里而不是只记在界面上，是为了重连：
## 握手要把它重新报给房间，否则重连回去的人会变回默认角色。
var character_id: StringName = &""
## 房主选定的地图。由 roster / start 两种消息共同维护。
var room_map_id := ""
```

- [ ] **Step 4: 让 connect_to_room 接收角色 id**

把 `connect_to_room` 改为：

```gdscript
func connect_to_room(
	code: String,
	session_token: String,
	display_name: String,
	selected_character: StringName
) -> void:
	room_code = code.to_upper()
	token = session_token
	nickname = display_name
	character_id = selected_character
	_want_connection = true
	_reconnect_attempts = 0
	_open_socket()
```

- [ ] **Step 5: 让握手带上角色 id**

把 `join_payload()` 改为：

```gdscript
func join_payload() -> Dictionary:
	return {
		"type": "join",
		"protocol_version": LobbyProtocolScript.PROTOCOL_VERSION,
		"token": token,
		"nickname": nickname,
		"resume_tick": _applied_tick,
		"character_id": String(character_id),
	}
```

- [ ] **Step 6: 加两个发送函数**

在 `func request_start() -> void:` 之后插入：

```gdscript
## 换角色。本机先记下来，再发出去——重连时握手要带的是本机的选择，
## 而不是"上一次服务端确认过的选择"。
func select_character(id: StringName) -> void:
	character_id = id
	_send({"type": "select_character", "character_id": String(id)})

## 换地图。服务端只认房主发的，这里不做本地拦截：拦截会让"我以为我是房主"
## 与"服务端认为谁是房主"两份判断产生分歧，而只有后者算数。
func select_map(id: StringName) -> void:
	_send({"type": "select_map", "map_id": String(id)})
```

- [ ] **Step 7: 解析新载荷**

在 `_handle_packet` 的 `"roster"` 分支中，把

```gdscript
			"roster":
				var players = message.get("players", [])
				roster = players if typeof(players) == TYPE_ARRAY else []
				host_slot = int(message.get("host_slot", -1))
				room_state = String(message.get("state", room_state))
				roster_changed.emit(roster, host_slot, room_state)
```

改为

```gdscript
			"roster":
				var players = message.get("players", [])
				roster = players if typeof(players) == TYPE_ARRAY else []
				host_slot = int(message.get("host_slot", -1))
				room_state = String(message.get("state", room_state))
				# 必须在 emit 之前落好：房间面板是在这个信号里读 room_map_id 的。
				room_map_id = String(message.get("map_id", room_map_id))
				roster_changed.emit(roster, host_slot, room_state)
```

在 `"start"` 分支中，把 `seed_value = int(message.get("seed", 0))` 之后紧接着插入：

```gdscript
				room_map_id = String(message.get("map_id", room_map_id))
```

- [ ] **Step 8: 更新 NetSession 与既有调用点**

`scripts/menu/online_lobby.gd:163` 现在这样调用：

```gdscript
	NetSession.room.connect_to_room(
		code, NetSession.identity.token, NetSession.identity.nickname
	)
```

改为（本任务先用默认角色占位，Task 9 会换成界面上的实际选择）：

```gdscript
	NetSession.room.connect_to_room(
		code,
		NetSession.identity.token,
		NetSession.identity.nickname,
		ContentCatalogsScript.characters().default_id()
	)
```

并在该文件的 preload 区加上：

```gdscript
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
```

用 `grep -rn "connect_to_room" scripts tools` 确认没有其它调用点被漏掉。

- [ ] **Step 9: 运行校验确认通过**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_room_client_lobby_messages.gd
```

预期：`validate_room_client_lobby_messages: PASS`。

- [ ] **Step 10: 跑重连回归，确认握手没改坏**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_online_reconnect_resume.gd
```

预期：PASS。这条是必跑的——`join_payload()` 同时承载 `resume_tick`，改它就是在改重连。

- [ ] **Step 11: 提交**

```bash
git add scripts/net/room_client.gd scripts/menu/online_lobby.gd \
  tools/validation/validate_room_client_lobby_messages.gd
git commit -m "feat: RoomClient 支持角色与地图选择消息"
```

---

### Task 6: 描述符、会话与地图路由

**Files:**
- Modify: `scripts/net/online_player_descriptor.gd`
- Modify: `scripts/input/local_player_descriptor.gd`
- Modify: `scripts/gameplay/game_session.gd`
- Modify: `scripts/gameplay/gameplay_arena.gd`
- Modify: `scripts/menu/main_menu.gd`
- Modify: `scripts/menu/local_multiplayer_lobby.gd`
- Test: `tools/validation/validate_content_session_routing.gd`

**Interfaces:**
- Consumes: `ContentCatalogs.characters()` / `ContentCatalogs.maps()`（Task 1、2）
- Produces:
  - 两个描述符各有 `character_id: StringName`
  - `GameSessionState.map_id: StringName`
  - `GameSessionState.configure_single()` / `configure_local(players)` 填默认 map_id
  - `GameSessionState.configure_online(players, map_id)`（新增第 2 个参数）
  - `GameplayArena` 在 `map_definition == null` 时按 `GameSession.map_id` 解析

- [ ] **Step 1: 写失败的校验脚本**

Create `tools/validation/validate_content_session_routing.gd`：

```gdscript
extends SceneTree

## 会话 -> 地图 -> 竞技场这条路由的校验。
##
## 它守的是一件事：竞技场拿到哪张图，只能由 GameSession 里的 map_id 决定，
## 而 map_id 在联机下来自服务端的 start 消息。任何"竞技场自己挑一张图"的回退
## 都是一次静默的分叉——各端会各挑各的。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_content_session_routing.gd

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const GameSessionScript = preload("res://scripts/gameplay/game_session.gd")
const OnlinePlayerDescriptorScript = preload("res://scripts/net/online_player_descriptor.gd")
const LocalPlayerDescriptorScript = preload("res://scripts/input/local_player_descriptor.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var maps = ContentCatalogsScript.maps()
	var characters = ContentCatalogsScript.characters()

	var session = GameSessionScript.new()
	root.add_child(session)
	await process_frame

	session.configure_single()
	_expect(
		session.map_id == maps.default_id(),
		"单机会话必须落在默认地图，实际 %s" % session.map_id,
		failures
	)

	var local_descriptor = LocalPlayerDescriptorScript.new()
	_expect(
		local_descriptor.character_id == &"",
		"本地描述符的角色 id 默认为空，由大厅填",
		failures
	)
	local_descriptor.character_id = characters.default_id()
	session.configure_local([local_descriptor])
	_expect(
		session.map_id == maps.default_id(),
		"本地多人会话必须落在默认地图",
		failures
	)

	var online_descriptor = OnlinePlayerDescriptorScript.new()
	online_descriptor.player_index = 0
	online_descriptor.character_id = &"survivor_blue"
	session.configure_online([online_descriptor], &"demo")
	_expect(session.map_id == &"demo", "联机会话的地图必须来自 start 消息", failures)
	_expect(
		session.local_players[0].character_id == &"survivor_blue",
		"联机描述符必须带上角色 id",
		failures
	)

	# 两个描述符必须保持同形：LocalPlayerSpawner 靠鸭子类型同时消费它们，
	# 一边有 character_id 另一边没有，联机和本地就会走出两条路。
	_expect(
		"character_id" in online_descriptor and "character_id" in local_descriptor,
		"两个玩家描述符都必须有 character_id 字段",
		failures
	)

	session.clear()
	_expect(
		session.map_id == maps.default_id(),
		"clear() 之后必须回到默认地图而不是空 id",
		failures
	)

	session.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_content_session_routing: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_content_session_routing: %s" % failure)
	printerr("validate_content_session_routing: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 2: 运行校验脚本确认失败**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_content_session_routing.gd
```

预期：失败，`GameSessionState` 没有 `map_id`。

- [ ] **Step 3: 给两个描述符加字段**

在 `scripts/net/online_player_descriptor.gd` 的 `var nickname := ""` 之后插入：

```gdscript
## 该座位选定的角色。来自服务端 start 消息里的座位表，不是本机记忆——
## 开局瞬间座位会被压实，本机记住的编号可能已经指向别人。
var character_id: StringName = &""
```

在 `scripts/input/local_player_descriptor.gd` 的 `var gamepad_device_id := -1` 之后插入：

```gdscript
## 该座位选定的角色。与 OnlinePlayerDescriptor 同名同义，
## LocalPlayerSpawner 靠鸭子类型同时消费两者。
var character_id: StringName = &""
```

- [ ] **Step 4: 给 GameSessionState 加 map_id**

把 `scripts/gameplay/game_session.gd` 改为：

```gdscript
extends Node
class_name GameSessionState

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

enum Mode {
	SINGLE,
	LOCAL_MULTIPLAYER,
	ONLINE_MULTIPLAYER,
}

var mode := Mode.SINGLE
var local_players: Array = []
var last_error := ""
## 本局要加载的地图。联机下由服务端的 start 消息决定；单机与本地多人取目录默认值。
## 竞技场只读这个值，绝不自己挑图——各端各挑一张就是一次静默的分叉。
var map_id: StringName = &""

func configure_single() -> void:
	mode = Mode.SINGLE
	local_players.clear()
	map_id = ContentCatalogsScript.maps().default_id()
	last_error = ""

func configure_local(players: Array) -> void:
	mode = Mode.LOCAL_MULTIPLAYER
	local_players = players.duplicate()
	map_id = ContentCatalogsScript.maps().default_id()
	last_error = ""

## 联机与本地多人共用同一份玩家名单：名单里的描述符决定每个座位的输入源，
## 而「输入从哪来」是联机唯一需要分叉的地方。
##
## 地图是第二个必须由外部传入的东西：它来自房间，不来自本机。
func configure_online(players: Array, selected_map_id: StringName) -> void:
	mode = Mode.ONLINE_MULTIPLAYER
	local_players = players.duplicate()
	map_id = selected_map_id
	last_error = ""

func clear() -> void:
	configure_single()
```

- [ ] **Step 5: 让竞技场按 map_id 解析地图**

在 `scripts/gameplay/gameplay_arena.gd` 的 preload 区加上：

```gdscript
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
```

在 `_setup_simulation()` 的开头（`var resolved_seed := ...` 之前）插入：

```gdscript
	var map_errors := _resolve_map_definition()
	if not map_errors.is_empty():
		return map_errors
```

并新增：

```gdscript
## 地图来源有两条：场景里直接绑好的（DemoMap.tscn 这样的调试壳），
## 和会话里带来的 map_id（菜单与联机走这条）。
##
## 解析不到时**失败**，不回退到目录里的第一张图：联机下回退意味着
## 缺这张图的那一端悄悄跑了另一张，而其他人不会知道。
func _resolve_map_definition() -> PackedStringArray:
	if map_definition != null:
		return PackedStringArray()
	var session := get_node_or_null("/root/GameSession")
	if session == null:
		return PackedStringArray(["GameplayArena 找不到 GameSession，无法确定地图"])
	var requested: StringName = session.map_id
	if String(requested) == "":
		return PackedStringArray(["会话里没有地图 id"])
	var resolved := ContentCatalogsScript.maps().get_by_id(requested)
	if resolved == null:
		return PackedStringArray(["地图目录里没有 %s" % requested])
	map_definition = resolved
	return PackedStringArray()
```

- [ ] **Step 6: 更新 configure_online 的调用点**

`scripts/menu/online_lobby.gd:256` 现在是 `GameSession.configure_online(descriptors)`，改为：

```gdscript
	GameSession.configure_online(descriptors, StringName(NetSession.room.room_map_id))
```

并在同一函数中，把每个描述符的 `character_id` 从服务端座位表里填上，
即在 `descriptor.nickname = String(entry.get("nickname", ""))` 之后加：

```gdscript
		descriptor.character_id = StringName(entry.get("character_id", ""))
```

- [ ] **Step 7: 更新本地多人大厅与主菜单**

`scripts/menu/local_multiplayer_lobby.gd` 的 `_start_local_game()` 中，
在 `GameSession.configure_local(join_state.players)` 之前插入（A 阶段所有本地座位用默认角色，
选角 UI 随 B 进入这个界面）：

```gdscript
	var default_character := ContentCatalogsScript.characters().default_id()
	for descriptor in join_state.players:
		if String(descriptor.character_id) == "":
			descriptor.character_id = default_character
```

并在该文件的 preload 区加上：

```gdscript
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
```

`scripts/menu/main_menu.gd` 的 `_on_single_player_button_pressed()` 已经调用了
`GameSession.configure_single()`，它现在会自动填默认 map_id，**无需改动**。

- [ ] **Step 8: 运行校验确认通过**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_content_session_routing.gd
```

预期：`validate_content_session_routing: PASS`。

- [ ] **Step 9: 跑玩家生成与地图回归**

```bash
for name in validate_local_player_spawning validate_demo_map_data_driven \
  validate_map_definitions validate_map_catalog; do
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script res://tools/validation/$name.gd || echo "FAILED: $name"
done
```

预期：四个全 PASS，没有 `FAILED:` 输出。

- [ ] **Step 10: 提交**

```bash
git add scripts/net/online_player_descriptor.gd scripts/input/local_player_descriptor.gd \
  scripts/gameplay/game_session.gd scripts/gameplay/gameplay_arena.gd \
  scripts/menu/online_lobby.gd scripts/menu/local_multiplayer_lobby.gd \
  tools/validation/validate_content_session_routing.gd
git commit -m "feat: 会话携带地图 id，竞技场按 id 解析地图"
```

---

### Task 7: 角色预览配色与座位卡

**Files:**
- Modify: `scripts/menu/lobby_player_preview.gd`
- Create: `scenes/menu/SeatCard.tscn`
- Create: `scripts/menu/seat_card.gd`
- Modify: `tools/validation/validate_lobby_player_preview.gd`
- Test: `tools/validation/validate_seat_card.gd`

**Interfaces:**
- Consumes: `CharacterDefinition`（Task 1）
- Produces:
  - `LobbyPlayerPreview.set_accent_color(color: Color)`、`LobbyPlayerPreview.set_label_visible(value: bool)`
  - `SeatCard.set_empty()`、`SeatCard.set_occupied(nickname, character, is_ready, is_host, is_local)`
  - `SeatCard` 信号 `character_step_requested(step: int)`

- [ ] **Step 1: 给预览加配色断言（失败）**

在 `tools/validation/validate_lobby_player_preview.gd` 中，把

```gdscript
	var light := preview.get_node("PlayerLight") as OmniLight3D
	var online_energy := light.light_energy
	preview.set_online(false)
	_expect(light.light_energy < online_energy, "offline preview must be visibly dimmer", failures)
```

替换为

```gdscript
	var light := preview.get_node("PlayerLight") as OmniLight3D
	var label := preview.get_node("PlayerLabel") as Label3D
	# 配色是四个人唯一的区分手段，它必须真的落到灯光和名牌上。
	var accent := Color(0.243, 0.553, 0.925, 1.0)
	preview.set_accent_color(accent)
	_expect(light.light_color.is_equal_approx(accent), "accent color must reach the preview light", failures)
	_expect(
		label.outline_modulate.is_equal_approx(accent),
		"accent color must reach the label outline",
		failures
	)
	var online_energy := light.light_energy
	preview.set_online(false)
	_expect(light.light_energy < online_energy, "offline preview must be visibly dimmer", failures)
	# 变暗走的是 energy 与 modulate，不能把配色一起洗掉。
	_expect(
		light.light_color.is_equal_approx(accent),
		"going offline must not discard the accent color",
		failures
	)
	preview.set_label_visible(false)
	_expect(not label.visible, "preview label must be hideable for card layouts", failures)
	preview.set_label_visible(true)
```

- [ ] **Step 2: 运行确认失败**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_lobby_player_preview.gd
```

预期：失败，`set_accent_color` 不存在（Invalid call）。

- [ ] **Step 3: 给预览加两个方法**

在 `scripts/menu/lobby_player_preview.gd` 中，`var online := true` 之后插入：

```gdscript
var accent_color := Color(1.0, 0.43, 0.24, 1.0)
```

在 `func set_online(value: bool) -> void:` 之后插入：

```gdscript
## 角色配色。落在灯光颜色与名牌描边上，不碰模型材质——
## 角色用的是单张 atlas，整体染色会把脸和武器一并染了。
func set_accent_color(value: Color) -> void:
	accent_color = value
	_apply_status()

## 座位卡里名字由卡片自己的 2D 标签画，Label3D 要能关掉，
## 否则同一个名字会在卡里出现两次。
func set_label_visible(value: bool) -> void:
	var label := get_node_or_null("PlayerLabel") as Label3D
	if label != null:
		label.visible = value
```

把 `_apply_status()` 改为：

```gdscript
func _apply_status() -> void:
	var label := get_node_or_null("PlayerLabel") as Label3D
	if label != null:
		label.text = "P%d" % (player_index + 1)
		# modulate 表达在线/离线，outline_modulate 表达角色配色。
		# 两者分开，才能让"离线变暗"不把配色一起洗掉。
		label.modulate = Color.WHITE if online else Color(0.5, 0.53, 0.55, 1.0)
		label.outline_modulate = accent_color
	var light := get_node_or_null("PlayerLight") as OmniLight3D
	if light != null:
		light.light_color = accent_color
		light.light_energy = 1.25 if online else 0.28
```

- [ ] **Step 4: 运行确认通过**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_lobby_player_preview.gd
```

预期：`validate_lobby_player_preview: PASS`。

- [ ] **Step 5: 写座位卡的失败校验**

Create `tools/validation/validate_seat_card.gd`：

```gdscript
extends SceneTree

## 座位卡组件的校验。
##
## 卡片是纯展示件：它不知道网络存在，只接受一份已经解析好的座位数据。
## 这里断言的就是这条边界——以及每张卡必须有自己独立的 SubViewport，
## 四张卡共用一个 viewport 会让四个座位显示同一个角色。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_seat_card.gd

const SEAT_CARD_SCENE_PATH := "res://scenes/menu/SeatCard.tscn"
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(SEAT_CARD_SCENE_PATH), "SeatCard 场景必须存在", failures)
	if not failures.is_empty():
		_finish(failures)
		return

	var scene := load(SEAT_CARD_SCENE_PATH) as PackedScene
	var catalog = ContentCatalogsScript.characters()
	var red = catalog.get_by_id(&"survivor_red")
	var blue = catalog.get_by_id(&"survivor_blue")

	var card_a = scene.instantiate()
	var card_b = scene.instantiate()
	root.add_child(card_a)
	root.add_child(card_b)
	await process_frame

	# 空位态：不显示角色，显示等待文案。
	card_a.set_empty()
	await process_frame
	_expect(not card_a.get_node("%CharacterViewportContainer").visible, "空位卡不显示角色", failures)
	_expect(card_a.get_node("%NameLabel").text.strip_edges() != "", "空位卡要有等待文案", failures)
	_expect(not card_a.get_node("%ReadyBanner").visible, "空位卡不显示准备横幅", failures)
	_expect(not card_a.get_node("%PreviousButton").visible, "空位卡不显示切换箭头", failures)

	# 占位态。
	card_a.set_occupied("阿波", red, false, true, true)
	card_b.set_occupied("小明", blue, true, false, false)
	await process_frame
	_expect(card_a.get_node("%CharacterViewportContainer").visible, "占位卡要显示角色", failures)
	_expect(card_a.get_node("%NameLabel").text == "阿波", "占位卡要显示昵称", failures)
	_expect(card_a.get_node("%HostBadge").visible, "房主卡要显示房主徽标", failures)
	_expect(not card_b.get_node("%HostBadge").visible, "非房主卡不显示房主徽标", failures)
	_expect(not card_a.get_node("%ReadyBanner").visible, "未准备时不显示准备横幅", failures)
	_expect(card_b.get_node("%ReadyBanner").visible, "已准备时显示准备横幅", failures)

	# 箭头只在"本机 且 未准备"时出现。
	_expect(card_a.get_node("%PreviousButton").visible, "本机未准备时要能换角色", failures)
	_expect(not card_b.get_node("%PreviousButton").visible, "别人的卡不能有切换箭头", failures)
	card_a.set_occupied("阿波", red, true, true, true)
	await process_frame
	_expect(not card_a.get_node("%PreviousButton").visible, "本机已准备后必须锁定角色选择", failures)

	# 每张卡必须有自己的 SubViewport 与自己的角色实例。
	var viewport_a := card_a.get_node("%CharacterViewport") as SubViewport
	var viewport_b := card_b.get_node("%CharacterViewport") as SubViewport
	_expect(viewport_a != viewport_b, "每张卡必须有独立的 SubViewport", failures)
	_expect(
		viewport_a.find_child("LobbyPlayerPreview", true, false) != null,
		"卡片的 SubViewport 里必须有角色预览",
		failures
	)
	_expect(
		viewport_a.find_children("*", "Camera3D", true, false).size() == 1,
		"卡片的 SubViewport 里必须正好有一个相机",
		failures
	)

	# 箭头点击必须翻译成 step 信号，而不是自己去改选择——卡片不知道目录存在。
	var steps: Array[int] = []
	card_a.character_step_requested.connect(func(step: int): steps.append(step))
	card_a.set_occupied("阿波", red, false, true, true)
	await process_frame
	(card_a.get_node("%PreviousButton") as Button).pressed.emit()
	(card_a.get_node("%NextButton") as Button).pressed.emit()
	_expect(steps == [-1, 1], "箭头必须发出 -1 / +1 的 step 信号，实际 %s" % str(steps), failures)

	card_a.queue_free()
	card_b.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_seat_card: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_seat_card: %s" % failure)
	printerr("validate_seat_card: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 6: 运行确认失败**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_seat_card.gd
```

预期：失败，`SeatCard 场景必须存在`。

- [ ] **Step 7: 写 SeatCard 脚本**

Create `scripts/menu/seat_card.gd`：

```gdscript
extends PanelContainer
class_name SeatCard

## 一张座位卡。纯展示件——它不知道网络存在，只接受一份解析好的座位数据。
##
## 角色切换在这里只表达为"往前一个/往后一个"，由房间面板去查目录、发消息。
## 卡片自己去查目录的话，四张卡就有四份对"下一个角色是谁"的判断。

signal character_step_requested(step: int)

const EMPTY_TEXT := "等待玩家加入"

@onready var viewport_container: SubViewportContainer = %CharacterViewportContainer
@onready var preview = %CharacterViewport/LobbyPlayerPreview
@onready var name_label: Label = %NameLabel
@onready var host_badge: Label = %HostBadge
@onready var ready_banner: Label = %ReadyBanner
@onready var previous_button: Button = %PreviousButton
@onready var next_button: Button = %NextButton
@onready var accent_rule: ColorRect = %AccentRule

func _ready() -> void:
	previous_button.pressed.connect(func(): character_step_requested.emit(-1))
	next_button.pressed.connect(func(): character_step_requested.emit(1))
	preview.set_label_visible(false)
	set_empty()

func set_empty() -> void:
	viewport_container.visible = false
	name_label.text = EMPTY_TEXT
	name_label.modulate = Color(0.62, 0.65, 0.68, 1.0)
	host_badge.visible = false
	ready_banner.visible = false
	previous_button.visible = false
	next_button.visible = false
	accent_rule.color = Color(0.28, 0.30, 0.32, 1.0)

func set_occupied(
	nickname: String,
	character: CharacterDefinition,
	is_ready: bool,
	is_host: bool,
	is_local: bool
) -> void:
	viewport_container.visible = true
	name_label.text = nickname
	name_label.modulate = Color.WHITE
	host_badge.visible = is_host
	ready_banner.visible = is_ready
	# 准备之后锁定选择：别人是对着当前这套阵容点的准备。
	var can_switch := is_local and not is_ready
	previous_button.visible = can_switch
	next_button.visible = can_switch
	var accent := character.accent_color if character != null else Color.WHITE
	accent_rule.color = accent
	preview.set_accent_color(accent)
	preview.set_online(true)
	# 本机那张卡靠更亮的描边区分，不做单独的放大预览。
	self_modulate = Color(1.15, 1.15, 1.15, 1.0) if is_local else Color.WHITE
```

- [ ] **Step 8: 写 SeatCard 场景**

Create `scenes/menu/SeatCard.tscn`：

```
[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://scripts/menu/seat_card.gd" id="1_seat_card"]
[ext_resource type="PackedScene" path="res://scenes/menu/LobbyPlayerPreview.tscn" id="2_preview"]

[sub_resource type="Environment" id="Environment_card"]
background_mode = 3
ambient_light_source = 2
ambient_light_color = Color(0.55, 0.57, 0.62, 1)
ambient_light_energy = 1.4
tonemap_mode = 2

[node name="SeatCard" type="PanelContainer"]
custom_minimum_size = Vector2(196, 268)
size_flags_horizontal = 3
script = ExtResource("1_seat_card")

[node name="Body" type="VBoxContainer" parent="."]
layout_mode = 2
theme_override_constants/separation = 4

[node name="Header" type="HBoxContainer" parent="Body"]
layout_mode = 2

[node name="HostBadge" type="Label" parent="Body/Header"]
unique_name_in_owner = true
layout_mode = 2
text = "房主"
theme_override_font_sizes/font_size = 15

[node name="Spacer" type="Control" parent="Body/Header"]
layout_mode = 2
size_flags_horizontal = 3

[node name="AccentRule" type="ColorRect" parent="Body"]
unique_name_in_owner = true
custom_minimum_size = Vector2(0, 3)
layout_mode = 2
color = Color(0.28, 0.3, 0.32, 1)

[node name="Stage" type="HBoxContainer" parent="Body"]
layout_mode = 2
size_flags_vertical = 3

[node name="PreviousButton" type="Button" parent="Body/Stage"]
unique_name_in_owner = true
layout_mode = 2
size_flags_vertical = 4
text = "<"

[node name="CharacterViewportContainer" type="SubViewportContainer" parent="Body/Stage"]
unique_name_in_owner = true
layout_mode = 2
size_flags_horizontal = 3
size_flags_vertical = 3
stretch = true

[node name="CharacterViewport" type="SubViewport" parent="Body/Stage/CharacterViewportContainer"]
unique_name_in_owner = true
own_world_3d = true
transparent_bg = true
handle_input_locally = false
size = Vector2i(256, 384)
render_target_update_mode = 3

[node name="WorldEnvironment" type="WorldEnvironment" parent="Body/Stage/CharacterViewportContainer/CharacterViewport"]
environment = SubResource("Environment_card")

[node name="Camera3D" type="Camera3D" parent="Body/Stage/CharacterViewportContainer/CharacterViewport"]
transform = Transform3D(1, 0, 0, 0, 0.985, 0.174, 0, -0.174, 0.985, 0, 1.55, 3.1)
fov = 38.0

[node name="KeyLight" type="DirectionalLight3D" parent="Body/Stage/CharacterViewportContainer/CharacterViewport"]
transform = Transform3D(0.866, -0.25, 0.433, 0, 0.866, 0.5, -0.5, -0.433, 0.75, 0, 3, 2)
light_energy = 1.1

[node name="LobbyPlayerPreview" parent="Body/Stage/CharacterViewportContainer/CharacterViewport" instance=ExtResource("2_preview")]

[node name="NextButton" type="Button" parent="Body/Stage"]
unique_name_in_owner = true
layout_mode = 2
size_flags_vertical = 4
text = ">"

[node name="NameLabel" type="Label" parent="Body"]
unique_name_in_owner = true
layout_mode = 2
text = "等待玩家加入"
horizontal_alignment = 1
theme_override_font_sizes/font_size = 18

[node name="ReadyBanner" type="Label" parent="Body"]
unique_name_in_owner = true
layout_mode = 2
text = "准 备"
horizontal_alignment = 1
theme_override_colors/font_color = Color(1, 0.84, 0.25, 1)
theme_override_font_sizes/font_size = 20
```

注意 `render_target_update_mode = 3` 即 `UPDATE_WHEN_VISIBLE`，`own_world_3d = true`
让每张卡的角色不会互相照亮。若 `%CharacterViewport` 的 `unique_name_in_owner`
在编辑器里没生效，用 `$Body/Stage/CharacterViewportContainer/CharacterViewport` 的
完整路径替代校验脚本里的 `%` 写法，两边保持一致。

- [ ] **Step 9: 导入并运行两个校验**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_seat_card.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_lobby_player_preview.gd
```

预期：两者都 PASS。

- [ ] **Step 10: 字体覆盖校验**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_ui_font_coverage.gd
```

预期：PASS（新文案「等待玩家加入」「房主」「准 备」）。

- [ ] **Step 11: 提交**

```bash
git add scripts/menu/lobby_player_preview.gd scripts/menu/seat_card.gd \
  scenes/menu/SeatCard.tscn tools/validation/validate_seat_card.gd \
  tools/validation/validate_lobby_player_preview.gd
git commit -m "feat: 座位卡组件与角色预览配色"
```

---

### Task 8: 地图卡

**Files:**
- Create: `scenes/menu/MapCard.tscn`
- Create: `scripts/menu/map_card.gd`
- Test: `tools/validation/validate_map_card.gd`

**Interfaces:**
- Consumes: `MapDefinition.thumbnail` / `.difficulty` / `.display_name`（Task 2）
- Produces:
  - `MapCard.set_map(definition: MapDefinition, editable: bool)`
  - `MapCard` 信号 `map_change_requested`

- [ ] **Step 1: 写失败的校验脚本**

Create `tools/validation/validate_map_card.gd`：

```gdscript
extends SceneTree

## 地图卡组件的校验。
##
## 两件事：难度星必须真的按 difficulty 点亮，缺缩略图时必须画占位而不是留空洞；
## 以及只有可编辑（房主）时点击才发出换图请求——把"谁能换图"的判断交给一处。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_map_card.gd

const MAP_CARD_SCENE_PATH := "res://scenes/menu/MapCard.tscn"
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	_expect(ResourceLoader.exists(MAP_CARD_SCENE_PATH), "MapCard 场景必须存在", failures)
	if not failures.is_empty():
		_finish(failures)
		return

	var scene := load(MAP_CARD_SCENE_PATH) as PackedScene
	var card = scene.instantiate()
	root.add_child(card)
	await process_frame

	var catalog = ContentCatalogsScript.maps()
	var demo = catalog.get_by_id(catalog.default_id())

	card.set_map(demo, false)
	await process_frame
	_expect(
		(card.get_node("%MapNameLabel") as Label).text == demo.display_name,
		"地图卡要显示地图名",
		failures
	)
	var stars := card.get_node("%DifficultyRow") as HBoxContainer
	var lit := 0
	for star in stars.get_children():
		if (star as Label).modulate.a > 0.9:
			lit += 1
	_expect(
		lit == demo.difficulty,
		"点亮的难度星必须等于 difficulty：期望 %d，实际 %d" % [demo.difficulty, lit],
		failures
	)
	_expect(stars.get_child_count() == 5, "难度星总数固定为 5", failures)

	# 缺缩略图时画占位色块，不留空洞。
	if demo.thumbnail == null:
		_expect(
			card.get_node("%ThumbnailPlaceholder").visible,
			"缺缩略图时必须显示占位块",
			failures
		)
		_expect(
			not (card.get_node("%Thumbnail") as TextureRect).visible,
			"缺缩略图时不显示空 TextureRect",
			failures
		)

	# 只读时点击不发请求。
	var requests := 0
	card.map_change_requested.connect(func(): requests += 1)
	card._on_pressed()
	_expect(requests == 0, "非房主点击地图卡不得发出换图请求", failures)
	_expect(not card.get_node("%ChangeHint").visible, "非房主不显示换图提示", failures)

	card.set_map(demo, true)
	await process_frame
	_expect(card.get_node("%ChangeHint").visible, "房主要看到换图提示", failures)
	card._on_pressed()
	_expect(requests == 1, "房主点击地图卡必须发出换图请求", failures)

	card.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_card: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_map_card: %s" % failure)
	printerr("validate_map_card: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 2: 运行确认失败**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_map_card.gd
```

预期：失败，`MapCard 场景必须存在`。

- [ ] **Step 3: 写 MapCard 脚本**

Create `scripts/menu/map_card.gd`：

```gdscript
extends PanelContainer
class_name MapCard

## 房间左下角的地图卡。展示件加一个"我想换图"的意图信号——
## 到底能不能换由房间面板决定，卡片不自己判断谁是房主。

signal map_change_requested

const STAR_COUNT := 5
const STAR_LIT := Color(0.94, 0.32, 0.28, 1.0)
const STAR_DIM := Color(0.35, 0.37, 0.40, 0.35)

@onready var thumbnail: TextureRect = %Thumbnail
@onready var thumbnail_placeholder: ColorRect = %ThumbnailPlaceholder
@onready var map_name_label: Label = %MapNameLabel
@onready var difficulty_row: HBoxContainer = %DifficultyRow
@onready var change_hint: Label = %ChangeHint
@onready var button: Button = %ClickArea

var editable := false

func _ready() -> void:
	button.pressed.connect(_on_pressed)

func set_map(definition: MapDefinition, is_editable: bool) -> void:
	editable = is_editable
	change_hint.visible = is_editable
	button.disabled = not is_editable
	if definition == null:
		map_name_label.text = "未选择地图"
		thumbnail.visible = false
		thumbnail_placeholder.visible = true
		_apply_difficulty(0)
		return
	map_name_label.text = definition.display_name
	# 真实缩略图要人进游戏俯视截图，缺它时画占位色块——
	# 一个空洞会被当成"这里坏了"，一块写着地图名的色块不会。
	var has_thumbnail := definition.thumbnail != null
	thumbnail.texture = definition.thumbnail
	thumbnail.visible = has_thumbnail
	thumbnail_placeholder.visible = not has_thumbnail
	_apply_difficulty(definition.difficulty)

func _apply_difficulty(level: int) -> void:
	for index in range(difficulty_row.get_child_count()):
		var star := difficulty_row.get_child(index) as Label
		if star == null:
			continue
		star.modulate = STAR_LIT if index < level else STAR_DIM

func _on_pressed() -> void:
	if not editable:
		return
	map_change_requested.emit()
```

- [ ] **Step 4: 写 MapCard 场景**

Create `scenes/menu/MapCard.tscn`：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/menu/map_card.gd" id="1_map_card"]

[node name="MapCard" type="PanelContainer"]
custom_minimum_size = Vector2(280, 200)
script = ExtResource("1_map_card")

[node name="Body" type="VBoxContainer" parent="."]
layout_mode = 2
theme_override_constants/separation = 4

[node name="MapNameLabel" type="Label" parent="Body"]
unique_name_in_owner = true
layout_mode = 2
text = "未选择地图"
horizontal_alignment = 1
theme_override_font_sizes/font_size = 18

[node name="DifficultyRow" type="HBoxContainer" parent="Body"]
unique_name_in_owner = true
layout_mode = 2
alignment = 1

[node name="Star1" type="Label" parent="Body/DifficultyRow"]
layout_mode = 2
text = "●"

[node name="Star2" type="Label" parent="Body/DifficultyRow"]
layout_mode = 2
text = "●"

[node name="Star3" type="Label" parent="Body/DifficultyRow"]
layout_mode = 2
text = "●"

[node name="Star4" type="Label" parent="Body/DifficultyRow"]
layout_mode = 2
text = "●"

[node name="Star5" type="Label" parent="Body/DifficultyRow"]
layout_mode = 2
text = "●"

[node name="Stage" type="Control" parent="Body"]
layout_mode = 2
size_flags_vertical = 3

[node name="ThumbnailPlaceholder" type="ColorRect" parent="Body/Stage"]
unique_name_in_owner = true
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
color = Color(0.16, 0.18, 0.2, 1)

[node name="Thumbnail" type="TextureRect" parent="Body/Stage"]
unique_name_in_owner = true
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
expand_mode = 1
stretch_mode = 5

[node name="ClickArea" type="Button" parent="Body/Stage"]
unique_name_in_owner = true
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
flat = true

[node name="ChangeHint" type="Label" parent="Body"]
unique_name_in_owner = true
layout_mode = 2
text = "点击更换地图"
horizontal_alignment = 1
theme_override_font_sizes/font_size = 14
```

- [ ] **Step 5: 导入并运行校验**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_map_card.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_ui_font_coverage.gd
```

预期：两者都 PASS。

- [ ] **Step 6: 提交**

```bash
git add scripts/menu/map_card.gd scenes/menu/MapCard.tscn \
  tools/validation/validate_map_card.gd
git commit -m "feat: 地图卡组件"
```

---

### Task 9: OnlineLobby 场景重构

**Files:**
- Modify: `scenes/menu/OnlineLobby.tscn`
- Modify: `scripts/menu/online_lobby.gd`
- Create: `scripts/menu/room_browser_panel.gd`
- Create: `scripts/menu/room_panel.gd`
- Test: `tools/validation/validate_online_room_panel.gd`

**Interfaces:**
- Consumes: `SeatCard`（Task 7）、`MapCard`（Task 8）、`RoomClient.select_character/select_map/room_map_id`（Task 5）、`ContentCatalogs`（Task 1、2）
- Produces:
  - `RoomBrowserPanel` 信号：`create_requested`、`join_requested(code: String)`、`refresh_requested`、`nickname_save_requested(text: String)`、`server_apply_requested(url: String)`
  - `RoomBrowserPanel` 方法：`set_nickname(text)`、`set_server(url)`、`set_room_code(code)`、`set_rooms(rooms: Array)`、`set_busy(in_room: bool, has_token: bool)`
  - `RoomPanel` 信号：`ready_toggled(is_ready: bool)`、`start_requested`、`character_step_requested(step: int)`、`map_selected(map_id: StringName)`
  - `RoomPanel` 方法：`apply_roster(players: Array, host_slot: int, state: String, local_slot: int, map_id: StringName)`

- [ ] **Step 1: 写失败的校验脚本**

Create `tools/validation/validate_online_room_panel.gd`：

```gdscript
extends SceneTree

## 联机房间面板的校验。
##
## 断言的是这三件事：两个面板互斥、座位表被翻译成四张卡（含空位）、
## 以及开始按钮只有在"本机是房主 且 其他人全准备"时才可用。
##
## 最后一条在客户端只是提示——真正的闸门在服务端 room_rules.allNonHostSeatsReady。
## 两边都要有：少了客户端这半，玩家会一直点一个什么都不会发生的按钮。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_online_room_panel.gd

const LOBBY_SCENE_PATH := "res://scenes/menu/OnlineLobby.tscn"
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var scene := load(LOBBY_SCENE_PATH) as PackedScene
	var lobby = scene.instantiate()
	root.add_child(lobby)
	await process_frame

	var browser = lobby.get_node("%BrowserPanel")
	var room = lobby.get_node("%RoomPanel")
	_expect(browser != null and room != null, "大厅必须同时含有两个面板", failures)
	_expect(
		browser.visible != room.visible,
		"两个面板必须互斥：不能同时可见或同时隐藏",
		failures
	)
	_expect(browser.visible, "未入房时必须显示房间浏览面板", failures)

	var characters = ContentCatalogsScript.characters()
	var maps = ContentCatalogsScript.maps()
	var default_map := maps.default_id()

	# 两人房：本机是房主（slot 0），另一人未准备。
	var roster := [
		{
			"slot": 0, "player_id": "p0", "nickname": "阿波",
			"ready": false, "connected": true, "character_id": "survivor_red",
		},
		{
			"slot": 1, "player_id": "p1", "nickname": "小明",
			"ready": false, "connected": true, "character_id": "survivor_blue",
		},
	]
	room.apply_roster(roster, 0, "lobby", 0, default_map)
	await process_frame

	var cards := [
		room.get_node("%SeatCard0"), room.get_node("%SeatCard1"),
		room.get_node("%SeatCard2"), room.get_node("%SeatCard3"),
	]
	_expect(cards[0].get_node("%NameLabel").text == "阿波", "第一张卡显示 P1", failures)
	_expect(cards[1].get_node("%NameLabel").text == "小明", "第二张卡显示 P2", failures)
	_expect(
		cards[2].get_node("%NameLabel").text == SeatCard.EMPTY_TEXT,
		"没人坐的位置必须是空位态",
		failures
	)
	_expect(cards[0].get_node("%HostBadge").visible, "房主卡要有徽标", failures)
	_expect(
		cards[0].get_node("%PreviousButton").visible,
		"本机未准备时要能换角色",
		failures
	)

	var start_button := room.get_node("%StartButton") as Button
	_expect(start_button.disabled, "有人没准备时开始按钮必须禁用", failures)

	roster[1]["ready"] = true
	room.apply_roster(roster, 0, "lobby", 0, default_map)
	await process_frame
	_expect(not start_button.disabled, "其他人全准备后房主才能开局", failures)
	_expect(cards[1].get_node("%ReadyBanner").visible, "已准备的座位要显示横幅", failures)

	# 非房主：开始按钮永远禁用，地图卡只读。
	room.apply_roster(roster, 0, "lobby", 1, default_map)
	await process_frame
	_expect(start_button.disabled, "非房主的开始按钮必须始终禁用", failures)
	_expect(
		not room.get_node("%MapCard").get_node("%ChangeHint").visible,
		"非房主不能换图",
		failures
	)
	_expect(
		room.get_node("%MapCard").get_node("%MapNameLabel").text
			== maps.get_by_id(default_map).display_name,
		"地图卡必须显示房间当前地图",
		failures
	)
	# 本机换成 slot 1 后，箭头必须跟着换到第二张卡上。
	_expect(
		not cards[0].get_node("%PreviousButton").visible,
		"别人的卡不能出现切换箭头",
		failures
	)

	# 卡片的 step 信号必须被面板转成对目录的一次查询后再抛出去。
	var steps: Array[int] = []
	room.character_step_requested.connect(func(step: int): steps.append(step))
	roster[1]["ready"] = false
	room.apply_roster(roster, 0, "lobby", 1, default_map)
	await process_frame
	(cards[1].get_node("%NextButton") as Button).pressed.emit()
	_expect(steps == [1], "本机卡片的箭头必须冒泡成面板的 step 信号", failures)

	_expect(
		characters.get_by_id(&"survivor_red") != null,
		"校验依赖的角色 id 必须存在于目录",
		failures
	)

	lobby.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_online_room_panel: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_online_room_panel: %s" % failure)
	printerr("validate_online_room_panel: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 2: 运行确认失败**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_online_room_panel.gd
```

预期：失败，`%BrowserPanel` 不存在。

- [ ] **Step 3: 写 RoomBrowserPanel**

Create `scripts/menu/room_browser_panel.gd`：

```gdscript
extends VBoxContainer
class_name RoomBrowserPanel

## 未入房时的那一屏：身份、服务器地址、房间列表、建房与加入。
##
## 它不认识 NetSession——所有动作都以信号抛给大厅宿主。这样"连接住在
## autoload 上、界面只是它的一个视图"这条既有设计不会被面板拆分打破。

signal create_requested
signal join_requested(code: String)
signal refresh_requested
signal nickname_save_requested(text: String)
signal server_apply_requested(url: String)

@onready var nickname_edit: LineEdit = %NicknameEdit
@onready var server_edit: LineEdit = %ServerEdit
@onready var room_code_edit: LineEdit = %RoomCodeEdit
@onready var room_list: ItemList = %RoomList
@onready var create_button: Button = %CreateRoomButton
@onready var join_button: Button = %JoinRoomButton
@onready var refresh_button: Button = %RefreshRoomsButton
@onready var save_nickname_button: Button = %SaveNicknameButton
@onready var apply_server_button: Button = %ApplyServerButton

func _ready() -> void:
	room_list.item_selected.connect(_on_room_selected)
	create_button.pressed.connect(func(): create_requested.emit())
	join_button.pressed.connect(
		func(): join_requested.emit(room_code_edit.text.strip_edges().to_upper())
	)
	refresh_button.pressed.connect(func(): refresh_requested.emit())
	save_nickname_button.pressed.connect(
		func(): nickname_save_requested.emit(nickname_edit.text)
	)
	apply_server_button.pressed.connect(
		func(): server_apply_requested.emit(server_edit.text)
	)

func set_nickname(text: String) -> void:
	nickname_edit.text = text

func set_server(url: String) -> void:
	server_edit.text = url

func set_room_code(code: String) -> void:
	room_code_edit.text = code

func set_rooms(rooms: Array) -> void:
	room_list.clear()
	for entry in rooms:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var code := String(entry.get("code", ""))
		room_list.add_item("%s · %s · %d/%d 人" % [
			code,
			String(entry.get("host_nickname", "")),
			int(entry.get("player_count", 0)),
			int(entry.get("max_players", 4)),
		])
		room_list.set_item_metadata(room_list.item_count - 1, code)

func room_count() -> int:
	return room_list.item_count

func set_busy(in_room: bool, has_token: bool) -> void:
	create_button.disabled = in_room or not has_token
	join_button.disabled = in_room
	refresh_button.disabled = in_room

func _on_room_selected(index: int) -> void:
	var code = room_list.get_item_metadata(index)
	if typeof(code) == TYPE_STRING:
		room_code_edit.text = code
```

- [ ] **Step 4: 写 RoomPanel**

Create `scripts/menu/room_panel.gd`：

```gdscript
extends VBoxContainer
class_name RoomPanel

## 已入房时的那一屏：四张座位卡 + 地图卡 + 动作条。
##
## 它把服务端的座位表翻译成四张卡的状态，并把"我想换角色/换地图/准备/开局"
## 四种意图抛给大厅宿主。它不发网络消息，也不判断自己是不是房主——
## 房主是谁由传进来的 host_slot 决定，那是服务端的答案。

signal ready_toggled(is_ready: bool)
signal start_requested
signal character_step_requested(step: int)
signal map_selected(map_id: StringName)
signal back_requested

const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
const SEAT_COUNT := 4

@onready var map_card: MapCard = %MapCard
@onready var ready_button: Button = %ReadyButton
@onready var start_button: Button = %StartButton
@onready var back_button: Button = %BackButton
@onready var map_popup: PopupPanel = %MapPopup
@onready var map_popup_list: VBoxContainer = %MapPopupList

var _cards: Array[SeatCard] = []
var _is_ready := false

func _ready() -> void:
	for index in range(SEAT_COUNT):
		var card := get_node("%%SeatCard%d" % index) as SeatCard
		_cards.append(card)
		card.character_step_requested.connect(_on_card_step)
	map_card.map_change_requested.connect(_on_map_change_requested)
	ready_button.pressed.connect(_on_ready_pressed)
	start_button.pressed.connect(func(): start_requested.emit())
	back_button.pressed.connect(func(): back_requested.emit())

## 把一份服务端座位表铺到四张卡上。
##
## players 是**稀疏**的——中间的人退了会留洞，服务端只在开局那一刻压实。
## 所以这里按 slot 索引铺，而不是按数组顺序铺：按顺序铺会让 P3 退房后
## P4 跳到 P3 的位置上，看起来像换了个人。
func apply_roster(
	players: Array,
	host_slot: int,
	state: String,
	local_slot: int,
	map_id: StringName
) -> void:
	var by_slot := {}
	for entry in players:
		if typeof(entry) == TYPE_DICTIONARY:
			by_slot[int(entry.get("slot", -1))] = entry
	var catalog = ContentCatalogsScript.characters()

	for index in range(SEAT_COUNT):
		var card := _cards[index]
		if not by_slot.has(index):
			card.set_empty()
			continue
		var entry: Dictionary = by_slot[index]
		var character = catalog.get_by_id(StringName(entry.get("character_id", "")))
		var is_local := index == local_slot
		var is_ready := bool(entry.get("ready", false))
		if is_local:
			_is_ready = is_ready
		var nickname := String(entry.get("nickname", ""))
		if not bool(entry.get("connected", true)):
			nickname += "（掉线）"
		card.set_occupied(nickname, character, is_ready, index == host_slot, is_local)

	var is_host := local_slot >= 0 and local_slot == host_slot
	map_card.set_map(ContentCatalogsScript.maps().get_by_id(map_id), is_host)

	ready_button.disabled = is_host
	ready_button.text = "取消准备" if _is_ready else "准备"
	# 客户端这半只是提示，真正的闸门在服务端；两边都要有，
	# 否则玩家会一直点一个什么都不会发生的按钮。
	var everyone_else_ready := _all_guests_ready(by_slot, host_slot)
	start_button.disabled = not (is_host and state == "lobby" and everyone_else_ready)
	start_button.text = "开始对局" if is_host else "等待房主开局"

func _all_guests_ready(by_slot: Dictionary, host_slot: int) -> bool:
	if host_slot < 0:
		return false
	for slot in by_slot.keys():
		if int(slot) == host_slot:
			continue
		if not bool((by_slot[slot] as Dictionary).get("ready", false)):
			return false
	return true

func _on_ready_pressed() -> void:
	_is_ready = not _is_ready
	ready_button.text = "取消准备" if _is_ready else "准备"
	ready_toggled.emit(_is_ready)

func _on_card_step(step: int) -> void:
	character_step_requested.emit(step)

func _on_map_change_requested() -> void:
	for child in map_popup_list.get_children():
		child.queue_free()
	var maps = ContentCatalogsScript.maps()
	for definition in maps.entries:
		if definition == null:
			continue
		var button := Button.new()
		button.text = "%s · 难度 %d" % [definition.display_name, definition.difficulty]
		var chosen: StringName = definition.map_id
		button.pressed.connect(func():
			map_popup.hide()
			map_selected.emit(chosen)
		)
		map_popup_list.add_child(button)
	map_popup.popup_centered()
```

- [ ] **Step 5: 重构 OnlineLobby.tscn**

把 `scenes/menu/OnlineLobby.tscn` 的 `MenuLayer/Root/Panel/Content` 子树改成两棵互斥的
面板。保留现有的 `Title`、`RedRule`、`StatusLabel` 三个节点不动，把
`IdentityRow` / `ServerRow` / `RoomRow` / `Split` 整体移进新的 `BrowserPanel`，
把 `ActionRow` 移进新的 `RoomPanel`。目标结构：

```
MenuLayer/Root/Panel/Content (VBoxContainer)
├─ Title           (保留)
├─ RedRule         (保留)
├─ StatusLabel     (保留, unique_name_in_owner)
├─ BrowserPanel    (VBoxContainer, unique_name_in_owner, script = room_browser_panel.gd)
│   ├─ IdentityRow   (原节点，含 NicknameEdit / SaveNicknameButton)
│   ├─ ServerRow     (原节点，含 ServerEdit / ApplyServerButton)
│   ├─ RoomRow       (原节点，含 RoomCodeEdit / JoinRoomButton / CreateRoomButton / RefreshRoomsButton)
│   └─ RoomList      (原 Split 里的 ItemList)
└─ RoomPanel       (VBoxContainer, unique_name_in_owner, script = room_panel.gd)
    ├─ Seats        (GridContainer, columns = 4)
    │   ├─ SeatCard0  (instance SeatCard.tscn, unique_name_in_owner)
    │   ├─ SeatCard1
    │   ├─ SeatCard2
    │   └─ SeatCard3
    ├─ Lower        (HBoxContainer)
    │   ├─ MapCard    (instance MapCard.tscn, unique_name_in_owner)
    │   └─ ActionRow  (原节点，含 ReadyButton / StartButton / BackButton)
    └─ MapPopup     (PopupPanel, unique_name_in_owner)
        └─ MapPopupList (VBoxContainer, unique_name_in_owner)
```

要求：

- `BrowserPanel` 与 `RoomPanel` 内所有被脚本用 `%` 访问的节点，都要勾上
  `unique_name_in_owner`（`.tscn` 里写 `unique_name_in_owner = true`）。
- 原 `RosterLabel` 节点**删除**——它的职责已由四张座位卡承担。
- 原 `Split` 容器若只剩 `RoomList` 一个子节点，一并删除，把 `RoomList` 直接挂在
  `BrowserPanel` 下。
- 场景初始状态：`BrowserPanel.visible = true`，`RoomPanel.visible = false`。
- 三个按钮的 `pressed` 信号在 `.tscn` 里若连着 `online_lobby.gd` 的旧回调
  （`_on_create_room_button_pressed` 等），一律断开——新的连接由面板脚本
  在 `_ready()` 里用代码建立。

- [ ] **Step 6: 把 online_lobby.gd 改成状态宿主**

把 `scripts/menu/online_lobby.gd` 整个替换为：

```gdscript
extends Node3D
class_name OnlineLobby

## 联机大厅：匿名身份 -> 建房 / 加入 -> 选角色与地图 -> 准备 -> 房主开局。
##
## 房间连接本身不住在这里，而住在 NetSession（autoload）上。大厅只是它的
## 一个视图：开局时场景会切到竞技场，连接必须活过那次切换。
##
## 这个脚本只做三件事：订阅 NetSession 的信号、在两个面板之间切换、
## 把面板抛上来的意图翻译成一次网络调用。座位怎么画、地图卡长什么样，
## 都不是它的事。

const ApiClientScript = preload("res://scripts/net/api_client.gd")
const OnlinePlayerDescriptorScript = preload("res://scripts/net/online_player_descriptor.gd")
const RoomClientScript = preload("res://scripts/net/room_client.gd")
const NetConfigScript = preload("res://scripts/net/net_config.gd")
const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")

@export_file("*.tscn") var game_scene_path := "res://scenes/gameplay/GameplayArena.tscn"
@export_file("*.tscn") var main_menu_scene_path := "res://scenes/menu/MainMenu.tscn"

@onready var status_label: Label = %StatusLabel
@onready var ping_label: Label = %Ping
@onready var browser_panel: RoomBrowserPanel = %BrowserPanel
@onready var room_panel: RoomPanel = %RoomPanel
@onready var content: VBoxContainer = $MenuLayer/Root/Panel/Content

var transition_pending := false
var _ping_refresh_timer := 0.0
## 本机当前选定的角色。它是本机的意图，服务端确认后会随 roster 回来；
## 两者短暂不一致是正常的，界面以 roster 为准。
var _selected_character: StringName = &""

## 大厅延迟显示的刷新节流（秒）。RTT 本身每 2s 才更新，更频繁地读没有信息量。
const PING_REFRESH_INTERVAL_SECONDS := 0.5

func _ready() -> void:
	MenuEntrance.play(self, content.get_children(), 0)
	_selected_character = ContentCatalogsScript.characters().default_id()
	browser_panel.set_nickname(NetSession.identity.nickname)
	browser_panel.set_server(NetConfigScript.base_url())

	browser_panel.create_requested.connect(_on_create_requested)
	browser_panel.join_requested.connect(_on_join_requested)
	browser_panel.refresh_requested.connect(_on_refresh_requested)
	browser_panel.nickname_save_requested.connect(_on_nickname_save_requested)
	browser_panel.server_apply_requested.connect(_on_server_apply_requested)

	room_panel.ready_toggled.connect(_on_ready_toggled)
	room_panel.start_requested.connect(_on_start_requested)
	room_panel.character_step_requested.connect(_on_character_step_requested)
	room_panel.map_selected.connect(_on_map_selected)
	room_panel.back_requested.connect(_on_back_requested)

	NetSession.identity_ready.connect(_on_identity_ready)
	NetSession.identity_failed.connect(_on_identity_failed)
	NetSession.api.room_created.connect(_on_room_created)
	NetSession.api.room_create_failed.connect(_on_simple_error)
	NetSession.api.room_list_loaded.connect(_on_room_list_loaded)
	NetSession.api.room_list_failed.connect(_on_simple_error)

	var room: RoomClient = NetSession.room
	room.connected.connect(_on_room_connected)
	room.connection_failed.connect(_on_simple_error)
	room.disconnected.connect(_on_room_disconnected)
	room.roster_changed.connect(_on_roster_changed)
	room.match_started.connect(_on_match_started)
	room.match_ended.connect(_on_match_ended)

	# 从竞技场返回时连接还在，直接把界面恢复成房内状态，不必重连。
	if room.is_connected_to_room():
		_selected_character = room.character_id
		_set_status("已在房间 %s" % room.room_code)
		_on_roster_changed(room.roster, room.host_slot, room.room_state)
	else:
		_set_status("正在获取身份…")
		NetSession.ensure_identity()
	_sync_panels()

func _exit_tree() -> void:
	for connection in [
		[NetSession.identity_ready, _on_identity_ready],
		[NetSession.identity_failed, _on_identity_failed],
		[NetSession.api.room_created, _on_room_created],
		[NetSession.api.room_create_failed, _on_simple_error],
		[NetSession.api.room_list_loaded, _on_room_list_loaded],
		[NetSession.api.room_list_failed, _on_simple_error],
		[NetSession.room.connected, _on_room_connected],
		[NetSession.room.connection_failed, _on_simple_error],
		[NetSession.room.disconnected, _on_room_disconnected],
		[NetSession.room.roster_changed, _on_roster_changed],
		[NetSession.room.match_started, _on_match_started],
		[NetSession.room.match_ended, _on_match_ended],
	]:
		var signal_ref: Signal = connection[0]
		var callable_ref: Callable = connection[1]
		if signal_ref.is_connected(callable_ref):
			signal_ref.disconnect(callable_ref)

func _set_status(message: String) -> void:
	status_label.text = message

func _process(delta: float) -> void:
	_update_ping(delta)

## 大厅右上角的延迟显示：只在已连进房间、且测出 RTT 后显示。
## 阈值与封顶直接复用 NetSession 上那份，与对局内 HUD 保持一致。
func _update_ping(delta: float) -> void:
	_ping_refresh_timer -= delta
	if _ping_refresh_timer > 0.0:
		return
	_ping_refresh_timer = PING_REFRESH_INTERVAL_SECONDS
	if ping_label == null:
		return
	var rtt := NetSession.latency_display_ms()
	if not NetSession.room.is_connected_to_room() or rtt < 0:
		ping_label.visible = false
		return
	ping_label.visible = true
	ping_label.text = "%dms" % rtt
	ping_label.add_theme_color_override("font_color", NetSession.latency_color(rtt))

func _sync_panels() -> void:
	var in_room := NetSession.room.is_connected_to_room()
	browser_panel.visible = not in_room
	room_panel.visible = in_room
	browser_panel.set_busy(in_room, NetSession.has_token())

func _on_simple_error(message: String) -> void:
	_set_status(message)
	_sync_panels()

func _on_identity_ready(nickname: String) -> void:
	browser_panel.set_nickname(nickname)
	_set_status("身份就绪：%s（匿名）" % nickname)
	NetSession.api.list_rooms()
	_sync_panels()

func _on_identity_failed(message: String) -> void:
	_set_status("连接服务器失败：%s" % message)
	_sync_panels()

func _on_nickname_save_requested(text: String) -> void:
	_set_status("正在更新昵称…")
	NetSession.ensure_identity(text)

## 换服务器地址会作废当前令牌与房间：令牌是上一台服务器发的，
## 拿到新服务器上什么都不是。所以这里顺手断开并重新取身份。
func _on_server_apply_requested(url: String) -> void:
	NetConfigScript.save_override(url)
	NetSession.leave_room()
	browser_panel.set_server(NetConfigScript.base_url())
	_set_status("服务器已切换到 %s，正在重新获取身份…" % NetConfigScript.base_url())
	NetSession.ensure_identity()
	_sync_panels()

func _on_create_requested() -> void:
	if not NetSession.has_token():
		_set_status("还没拿到身份，请稍候")
		return
	_set_status("正在建房…")
	browser_panel.set_busy(true, true)
	NetSession.api.create_room(NetSession.identity.token, true)

func _on_room_created(code: String) -> void:
	browser_panel.set_room_code(code)
	_set_status("房间 %s 已创建，正在连接…" % code)
	_connect_to_room(code)

func _on_join_requested(code: String) -> void:
	if code.length() != 6:
		_set_status("房间码是 6 位字符")
		return
	_set_status("正在加入 %s…" % code)
	_connect_to_room(code)

func _connect_to_room(code: String) -> void:
	NetSession.room.connect_to_room(
		code,
		NetSession.identity.token,
		NetSession.identity.nickname,
		_selected_character
	)
	_sync_panels()

func _on_refresh_requested() -> void:
	_set_status("正在刷新房间列表…")
	NetSession.api.list_rooms()

func _on_room_list_loaded(rooms: Array) -> void:
	browser_panel.set_rooms(rooms)
	_set_status(
		"公开房间 %d 个" % browser_panel.room_count()
		if browser_panel.room_count() > 0
		else "暂无公开房间，可直接建房"
	)

func _on_room_connected(slot: int, _player_id: String) -> void:
	_set_status("已加入房间 %s，座位 P%d" % [NetSession.room.room_code, slot + 1])
	_sync_panels()

func _on_room_disconnected(code: int, reason: String) -> void:
	if code == LobbyProtocolScript.CLOSE_PROTOCOL_MISMATCH:
		# 服务端在关闭原因里写了双方版本号，原样透出去：
		# 这条消息就是为了让「客户端和服务端不是一批」当场看得见。
		_set_status("协议版本不一致，请更新客户端（%s）" % reason)
	elif code == LobbyProtocolScript.CLOSE_ROOM_FULL:
		_set_status("房间已满或对局已开始")
	else:
		_set_status("连接断开：%s" % reason)
	_sync_panels()

func _on_roster_changed(players: Array, host_slot: int, state: String) -> void:
	room_panel.apply_roster(
		players,
		host_slot,
		state,
		NetSession.room.slot,
		StringName(NetSession.room.room_map_id)
	)
	_sync_panels()

func _on_ready_toggled(is_ready: bool) -> void:
	NetSession.room.set_ready(is_ready)

func _on_start_requested() -> void:
	NetSession.room.request_start()

## 卡片只说「往前一个/往后一个」，查目录这一步在这里做：
## 四张卡各自查目录的话，就有四份对「下一个角色是谁」的判断。
func _on_character_step_requested(step: int) -> void:
	var catalog = ContentCatalogsScript.characters()
	_selected_character = catalog.next_id(_selected_character, step)
	NetSession.room.select_character(_selected_character)

func _on_map_selected(map_id: StringName) -> void:
	NetSession.room.select_map(map_id)

## 开局：把服务端压实后的座位表翻译成玩家描述符，本机那一个标成 is_local。
##
## 在切场景之前先把地图与每个角色的 id 对着本机目录核一遍。核不过就**拒绝入局**，
## 不静默回退到默认值：回退意味着缺内容的这一端悄悄跑了另一套配置，
## 而其他人不会知道——那正是这道检查要防的不同步本身。
func _on_match_started(seed_value: int, slots: Array) -> void:
	if transition_pending:
		return
	var map_id := StringName(NetSession.room.room_map_id)
	var missing := _missing_content(map_id, slots)
	if missing != "":
		_set_status("无法进入对局：本机缺少内容 %s，请更新客户端" % missing)
		NetSession.leave_room()
		_sync_panels()
		return
	transition_pending = true
	NetSession.begin_match(seed_value, slots)
	var descriptors: Array = []
	for entry in slots:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var descriptor = OnlinePlayerDescriptorScript.new()
		descriptor.player_index = int(entry.get("slot", 0))
		descriptor.is_local = descriptor.player_index == NetSession.local_slot
		descriptor.nickname = String(entry.get("nickname", ""))
		descriptor.character_id = StringName(entry.get("character_id", ""))
		descriptors.append(descriptor)
	descriptors.sort_custom(func(a, b): return a.player_index < b.player_index)
	GameSession.configure_online(descriptors, map_id)
	get_tree().change_scene_to_file(game_scene_path)

## 返回第一个本机目录里没有的内容 id；全都有则返回空串。
func _missing_content(map_id: StringName, slots: Array) -> String:
	if not ContentCatalogsScript.maps().has_id(map_id):
		return "地图 %s" % map_id
	var characters = ContentCatalogsScript.characters()
	for entry in slots:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var character_id := StringName(entry.get("character_id", ""))
		if not characters.has_id(character_id):
			return "角色 %s" % character_id
	return ""

func _on_match_ended(result: Dictionary) -> void:
	var status := String(result.get("status", ""))
	if status == "accepted" and bool(result.get("persisted", false)):
		_set_status("对局结束：第 %d 波，成绩已记录" % int(result.get("team_wave", 0)))
	else:
		_set_status("对局结束：成绩未保存（%s）" % String(result.get("reason", status)))
	_sync_panels()

func _on_back_requested() -> void:
	transition_pending = true
	NetSession.leave_room()
	GameSession.clear()
	get_tree().change_scene_to_file(main_menu_scene_path)
```

注意 `game_scene_path` 的默认值从 `DemoMap.tscn` 改成了 `GameplayArena.tscn`：
地图现在由 `GameSession.map_id` 决定，竞技场自己去目录里取（Task 6 的
`_resolve_map_definition()`）。若 `OnlineLobby.tscn` 里存过这个导出属性的旧值，
一并改掉。

- [ ] **Step 7: 导入并运行校验**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_online_room_panel.gd
```

预期：`validate_online_room_panel: PASS`。

- [ ] **Step 8: 字体覆盖校验**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_ui_font_coverage.gd
```

预期：PASS（新文案含「无法进入对局：本机缺少内容」「请更新客户端」「点击更换地图」「难度」）。

- [ ] **Step 9: 提交**

```bash
git add scenes/menu/OnlineLobby.tscn scripts/menu/online_lobby.gd \
  scripts/menu/room_browser_panel.gd scripts/menu/room_panel.gd \
  tools/validation/validate_online_room_panel.gd
git commit -m "feat: 联机大厅拆成房间浏览与房间内两个面板"
```

---

### Task 10: 场上角色配色

**Files:**
- Modify: `scenes/player/Player.tscn`
- Modify: `scripts/player/player_controller.gd`
- Modify: `scripts/gameplay/local_player_spawner.gd`
- Test: `tools/validation/validate_player_accent_color.gd`

**Interfaces:**
- Consumes: 描述符的 `character_id`（Task 6）、`ContentCatalogs.characters()`（Task 1）
- Produces: `PlayerController.set_accent_color(color: Color)`

- [ ] **Step 1: 写失败的校验脚本**

Create `tools/validation/validate_player_accent_color.gd`：

```gdscript
extends SceneTree

## 场上角色配色的校验。
##
## 四个人共用同一个模型，脚下光环是场上唯一分得清谁是谁的东西。
## 它必须是纯展示件：不带碰撞、不进物理层——多一个碰撞体就会被
## 玩家生成时的空位探测撞上，四个人会挤不进出生点。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script res://tools/validation/validate_player_accent_color.gd

const PLAYER_SCENE_PATH := "res://scenes/player/Player.tscn"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var scene := load(PLAYER_SCENE_PATH) as PackedScene
	var player = scene.instantiate()
	root.add_child(player)
	await process_frame

	var ring := player.get_node_or_null("AccentRing") as MeshInstance3D
	_expect(ring != null, "Player 必须有 AccentRing 节点", failures)
	if ring == null:
		player.queue_free()
		await process_frame
		_finish(failures)
		return

	_expect(
		ring.find_children("*", "CollisionShape3D", true, false).is_empty(),
		"光环不能带碰撞体——出生点空位探测会撞上它",
		failures
	)
	_expect(
		ring.material_override is StandardMaterial3D,
		"光环必须有自己的材质，否则四个玩家会共用同一份颜色",
		failures
	)

	var accent := Color(0.243, 0.553, 0.925, 1.0)
	player.set_accent_color(accent)
	var material := ring.material_override as StandardMaterial3D
	_expect(
		material.albedo_color.is_equal_approx(accent),
		"配色必须落到光环材质上",
		failures
	)
	_expect(
		material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
		"光环必须是 unshaded，否则夜间场景里看不出颜色",
		failures
	)

	# 第二个玩家换色不能把第一个的颜色一起改掉——材质必须是每实例一份。
	var other = scene.instantiate()
	root.add_child(other)
	await process_frame
	other.set_accent_color(Color(0.906, 0.263, 0.212, 1.0))
	_expect(
		material.albedo_color.is_equal_approx(accent),
		"两个玩家必须各有一份光环材质",
		failures
	)

	player.queue_free()
	other.queue_free()
	await process_frame
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_player_accent_color: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_player_accent_color: %s" % failure)
	printerr("validate_player_accent_color: FAIL (%d)" % failures.size())
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
```

- [ ] **Step 2: 运行确认失败**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_player_accent_color.gd
```

预期：失败，`Player 必须有 AccentRing 节点`。

- [ ] **Step 3: 给 Player.tscn 加光环节点**

在 `scenes/player/Player.tscn` 中新增一个 `TorusMesh` 子资源与一个 `MeshInstance3D` 节点。
在 `[sub_resource]` 区加：

```
[sub_resource type="TorusMesh" id="TorusMesh_accent"]
inner_radius = 0.46
outer_radius = 0.58
rings = 24
ring_segments = 8
```

在 `[node name="Player" ...]` 的子节点区（与 `VisualRoot` 同级）加：

```
[node name="AccentRing" type="MeshInstance3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.03, 0)
cast_shadow = 0
mesh = SubResource("TorusMesh_accent")
```

材质在脚本里创建而不是写进场景：写进场景意味着四个玩家实例共用同一份
`StandardMaterial3D`，改一个人的颜色会把四个人一起改掉。

- [ ] **Step 4: 给 PlayerController 加方法**

在 `scripts/player/player_controller.gd` 的 `@onready var visual_root: Node3D = $VisualRoot`
附近加上：

```gdscript
@onready var accent_ring: MeshInstance3D = $AccentRing
```

并新增：

```gdscript
## 角色配色。四个人共用同一个模型，脚下这圈光环是场上唯一分得清谁是谁的东西。
##
## 材质在这里 new 出来而不是写进 Player.tscn：写进场景的话四个玩家实例
## 共用同一份 StandardMaterial3D，给第四个人上色会把前三个一起改掉。
func set_accent_color(color: Color) -> void:
	if accent_ring == null:
		return
	var material := accent_ring.material_override as StandardMaterial3D
	if material == null:
		material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		accent_ring.material_override = material
	material.albedo_color = color
	if equipment_label != null and equipment_label.has_method("set_accent_color"):
		equipment_label.set_accent_color(color)
```

注意：校验脚本在 `set_accent_color()` **之后**才读 `material_override`，
所以首次调用时创建材质是可以的；但校验里也断言了"必须有自己的材质"，
因此 `_ready()` 里要先建一次。在 `_ready()` 末尾加上：

```gdscript
	set_accent_color(Color(1.0, 1.0, 1.0, 1.0))
```

- [ ] **Step 5: 让 spawner 把配色落下去**

在 `scripts/gameplay/local_player_spawner.gd` 的 preload 区加上：

```gdscript
const ContentCatalogsScript = preload("res://scripts/gameplay/content_catalogs.gd")
```

在 `spawn_players()` 的循环里，`player.player_index = index` 之后插入：

```gdscript
		# 两个描述符同形，都带 character_id；单机的 descriptor 为 null，走默认色。
		var catalog = ContentCatalogsScript.characters()
		var character_id: StringName = catalog.default_id()
		if descriptor != null and "character_id" in descriptor and String(descriptor.character_id) != "":
			character_id = descriptor.character_id
		var character = catalog.get_by_id(character_id)
		if character != null:
			player.set_accent_color(character.accent_color)
```

- [ ] **Step 6: 运行校验确认通过**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/validation/validate_player_accent_color.gd
```

预期：`validate_player_accent_color: PASS`。

- [ ] **Step 7: 跑玩家生成与武器装配回归**

光环挂在 `Player` 根下，与武器挂点和空位探测都在同一棵树上，必须确认没撞上。

```bash
for name in validate_local_player_spawning validate_weapon_assembly \
  validate_player_screen_bounds validate_equipment_cycle; do
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script res://tools/validation/$name.gd || echo "FAILED: $name"
done
```

预期：四个全 PASS。

- [ ] **Step 8: 提交**

```bash
git add scenes/player/Player.tscn scripts/player/player_controller.gd \
  scripts/gameplay/local_player_spawner.gd \
  tools/validation/validate_player_accent_color.gd
git commit -m "feat: 场上玩家按所选角色显示配色光环"
```

---

### Task 11: 全量回归与人工验收

**Files:**
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: 前十个任务的全部产出
- Produces: 无新接口

- [ ] **Step 1: 跑全部校验脚本**

```bash
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
FAILED=""
for script in tools/validation/validate_*.gd; do
  name=$(basename "$script" .gd)
  $GODOT --headless --path . --script "res://$script" > /dev/null 2>&1 \
    || FAILED="$FAILED $name"
done
echo "FAILED:$FAILED"
```

预期：输出 `FAILED:`（后面为空）。任何一个失败都要在本任务内修掉，不得带进下一步。

- [ ] **Step 2: 跑服务端测试与类型检查**

```bash
cd server && npm run typecheck && npm test
```

预期：全绿。

- [ ] **Step 3: 跑 headless 导入，确认零解析错误**

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --path . --quit 2>&1 \
  | grep -E "Parse Error|Failed to load script|SCRIPT ERROR" || echo "clean"
```

预期：输出 `clean`。

- [ ] **Step 4: 确认 .uid 文件已全部生成并纳入版本控制**

```bash
git status --short | grep -E "\.uid$"
```

预期：本次新增的每个 `.gd` 都有对应 `.uid` 出现在待提交列表里（若已提交则无输出）。
把遗漏的补上：`git add $(git status --short | grep "\.uid$" | awk '{print $2}')`

- [ ] **Step 5: 在 AGENTS.md 记下新的内容目录约定**

在 `AGENTS.md` 的「Online Multiplayer」一节末尾追加：

```markdown
角色与地图都由 `resources/characters/character_catalog.tres` 与
`resources/maps/map_catalog.tres` 两张目录按 `StringName` id 索引，统一经
`ContentCatalogs` 加载。跨线传输的永远是 id 字符串而不是数组下标：下标会随目录
顺序变化，id 不会。服务端**不认识**这些 id，只按 `^[a-z0-9_]{1,32}$` 校验形状——
维护白名单意味着每加一个角色都要发一次 Worker。

代价落在客户端：收到 `start` 时若其中的 `map_id` 或任一 `character_id` 不在本机目录
里，必须**拒绝入局并报错**，绝不回退到默认值。回退会让缺内容的那一端悄悄跑另一套
配置，而其他人不会知道。这条检查在 `OnlineLobby._missing_content()`。

注意它挡不住「同名不同内容」：两个客户端各有一份 id 相同但数值不同的
`demo_map.tres` 仍会不同步，协议版本号覆盖不到内容漂移。彻底的解法是在握手时比对
内容摘要，尚未实现。
```

- [ ] **Step 6: 提交**

```bash
git add AGENTS.md
git commit -m "docs: 记录内容目录与未知 id 拒绝入局的约定"
```

- [ ] **Step 7: 人工验收（必须由人执行）**

以下这些从源码验证不了，按 AGENTS.md 的要求交给人在游戏里做。
需要两个客户端：本机跑一个，另一台机器或另一个浏览器标签跑第二个。

1. **建房与入房**：A 建房，B 用房间码加入。两端都应看到两张占位卡 + 两张空位卡，
   A 的卡带「房主」徽标。
2. **换角色**：A 点自己卡片上的 `>` 四次，角色配色应在四种颜色间循环，
   **且 B 的屏幕上 A 那张卡同步变色**。B 的卡上不应出现箭头。
3. **准备锁定**：B 点准备，B 自己卡上的箭头应消失，准备横幅出现；
   此时 B 再无法换角色。B 取消准备后箭头回来。
4. **开局闸门**：B 未准备时，A 的「开始对局」应是灰的；B 准备后变亮。
5. **房主换图清准备**：B 准备后，A 点地图卡换图（当前只有一张，
   列表里应出现「废弃仓库 · 难度 3」一项），选中后 **B 的准备状态应被清空**，
   A 的开始按钮重新变灰。
6. **开局配色一致**：全员准备后 A 开局，进场后两个玩家脚下的光环颜色，
   应与各自在房间里选的颜色一致，**且两端看到的颜色相同**。
7. **手机竖屏**：在手机或把窗口拉成竖长条，确认四张座位卡不重叠、
   地图卡与按钮不出界。

请把第 2、5、6 步的截图发回来。第 6 步要**两端各截一张**——
"两端看到的颜色相同"是这次改动唯一无法从源码证明的断言。

---

## Self-Review

**Spec coverage**

| Spec 小节 | 覆盖任务 |
|---|---|
| 1 角色目录与地图目录 | Task 1、Task 2 |
| 1 四个配色角色 / 不整体染色 | Task 1（definition）、Task 7（预览）、Task 10（场上光环） |
| 2 协议 v4 与两条新消息 | Task 3（常量）、Task 4（服务端）、Task 5（客户端） |
| 2 服务端只校验形状 | Task 3 `isValidContentId` |
| 2 未知 id 拒绝入局 | Task 9 `_missing_content()` |
| 3 Seat.characterId / mapId / 全员准备闸门 | Task 4 |
| 3 非法请求静默忽略 + diag | Task 4 Step 4、Step 5 |
| 4 两棵互斥面板 / SeatCard / MapCard / 箭头换角色 / 弹层换图 | Task 7、Task 8、Task 9 |
| 4 online_lobby.gd 拆分 | Task 9 |
| 5 描述符 + GameSession.map_id + 竞技场路由 | Task 6 |
| 5 单机与本地多人只填默认值 | Task 6 Step 7 |
| 6 预览配色断言 | Task 7 Step 1 |
| 6 两张目录校验脚本 | Task 1、Task 2 |
| 6 房间面板校验 | Task 9 |
| 6 新常量进双向对拍 | Task 3 Step 8 |
| 6 删除过期 fixtures + 修注释 | Task 3 Step 5、Step 7 |
| 6 人工验收 | Task 11 Step 7 |
| 已知风险（内容漂移） | Task 11 Step 5 写进 AGENTS.md |

无遗漏项。

**类型与命名一致性**

- `character_id` / `map_id`：GDScript 侧一律 `StringName`，跨线一律 `String`，
  边界转换点是 `String(id)`（发送）与 `StringName(...)`（接收）。
- `CharacterCatalog.next_id(from, step)` 在 Task 1 定义，Task 9 `_on_character_step_requested` 使用，签名一致。
- `SeatCard.set_occupied(nickname, character, is_ready, is_host, is_local)` 在 Task 7 定义，
  Task 9 `RoomPanel.apply_roster` 按同序调用。
- `MapCard.set_map(definition, is_editable)` 在 Task 8 定义，Task 9 按同序调用。
- `allNonHostSeatsReady(seats, hostSlot)` 在 Task 3 定义并测试，Task 4 使用。
- `RoomPanel._all_guests_ready()` 是它的客户端镜像，语义相同（房主自身不计、无房主为 false）。
- `configure_online(players, map_id)` 在 Task 6 定义，Task 9 调用。
- `ContentCatalogs.characters()` / `maps()` 在 Task 1 定义，Task 2、6、7、8、9、10 使用。

**已知的跨任务依赖**

Task 1 Step 6 写的 `ContentCatalogs.maps()` 在 Task 2 完成前会解析失败。这是有意的：
把两张目录的唯一加载点放在同一个文件里，比为了任务边界拆成两个访问器更值得。
Task 1 的校验脚本不触碰 `maps()`，因此不受影响。
