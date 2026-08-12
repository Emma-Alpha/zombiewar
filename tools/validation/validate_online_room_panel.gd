extends SceneTree

## 联机房间面板的校验。
##
## 断言的是这三件事：两个面板互斥、座位表被翻译成四张卡（含空位）、
## 以及开始按钮只有在「本机是房主 且 其他人全准备」时才可用。
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

	var browser = lobby.get_node_or_null("%BrowserPanel")
	var room = lobby.get_node_or_null("%RoomPanel")
	_expect(browser != null and room != null, "大厅必须同时含有两个面板", failures)
	if browser == null or room == null:
		lobby.queue_free()
		await process_frame
		_finish(failures)
		return
	_expect(
		browser.visible != room.visible,
		"两个面板必须互斥：不能同时可见或同时隐藏",
		failures
	)
	_expect(browser.visible, "未入房时必须显示房间浏览面板", failures)

	var characters = ContentCatalogsScript.characters()
	var maps = ContentCatalogsScript.maps()
	var default_map: StringName = maps.default_id()

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

	# 稀疏座位表：中间的人退了，剩下的人不能往前挪位。
	room.apply_roster([roster[1]], 1, "lobby", 1, default_map)
	await process_frame
	_expect(
		cards[0].get_node("%NameLabel").text == SeatCard.EMPTY_TEXT,
		"slot 0 空出来后第一张卡必须回到空位态",
		failures
	)
	_expect(
		cards[1].get_node("%NameLabel").text == "小明",
		"slot 1 的人必须还在第二张卡上，不能被挪到第一张",
		failures
	)

	# 非房主：开始按钮永远禁用，地图卡只读。
	room.apply_roster(roster, 0, "lobby", 1, default_map)
	await process_frame
	_expect(start_button.disabled, "非房主的开始按钮必须始终禁用", failures)
	var map_card = room.get_node("%MapCard")
	_expect(
		not map_card.get_node("%ChangeHint").visible,
		"非房主不能换图",
		failures
	)
	_expect(
		map_card.get_node("%MapNameLabel").text == maps.get_by_id(default_map).display_name,
		"地图卡必须显示房间当前地图",
		failures
	)
	_expect(
		not cards[0].get_node("%PreviousButton").visible,
		"别人的卡不能出现切换箭头",
		failures
	)

	# 卡片的 step 信号必须冒泡成面板的 step 信号。
	# 用字典接住：GDScript 的 lambda 按值捕获局部变量。
	var observed := {"steps": []}
	room.character_step_requested.connect(func(step: int): observed["steps"].append(step))
	roster[1]["ready"] = false
	room.apply_roster(roster, 0, "lobby", 1, default_map)
	await process_frame
	(cards[1].get_node("%NextButton") as Button).pressed.emit()
	_expect(
		observed["steps"] == [1],
		"本机卡片的箭头必须冒泡成面板的 step 信号，实际 %s" % str(observed["steps"]),
		failures
	)

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
