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
