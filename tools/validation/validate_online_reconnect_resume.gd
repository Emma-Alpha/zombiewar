extends SceneTree

## 重连补帧的客户端侧验证。
##
## 房间为重连保留一段帧历史，客户端在握手时上报「我模拟到哪个 tick 了」，
## 房间据此补齐中间那一段。这条链上任何一处少算一帧，本机就会停在一个
## 别人没走过的 tick 上——而那正是不同步的定义，且事后只能靠哈希对拍
## 才发现。所以这里逐环断言，不靠联调时的肉眼观察。
##
## 运行：
##   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##     --script tools/validation/validate_online_reconnect_resume.gd

const RoomClientScript = preload("res://scripts/net/room_client.gd")
const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	failures.append_array(_check_applied_tick_tracking())
	failures.append_array(_check_backfill_enqueue())
	failures.append_array(_check_queue_holds_a_full_replay())
	failures.append_array(_check_match_start_resets_resume())

	if failures.is_empty():
		print("validate_online_reconnect_resume: PASS")
		quit(0)
		return
	for failure in failures:
		printerr("validate_online_reconnect_resume: %s" % failure)
	printerr("validate_online_reconnect_resume: FAIL (%d)" % failures.size())
	quit(1)

func _make_client() -> RoomClient:
	var client: RoomClient = RoomClientScript.new()
	root.add_child(client)
	return client

func _feed(client: RoomClient, payload: Dictionary) -> void:
	client._handle_packet(JSON.stringify(payload).to_utf8_buffer())

func _frame(tick: int) -> Dictionary:
	return {"type": "f", "t": tick, "s": []}

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)

## 取走一帧即视为已应用，上报的 resume_tick 必须跟着走。
func _check_applied_tick_tracking() -> Array[String]:
	var failures: Array[String] = []
	var client := _make_client()

	_expect(
		int(client.join_payload()["resume_tick"]) == -1,
		"还没消费过帧时 resume_tick 必须是 -1，实际 %d" % int(client.join_payload()["resume_tick"]),
		failures
	)

	for tick in range(5):
		_feed(client, _frame(tick))
	_expect(
		int(client.join_payload()["resume_tick"]) == -1,
		"只入队还没取走时 resume_tick 不能前进：模拟层并没有走过这些 tick",
		failures
	)

	client.pop_frame()
	client.pop_frame()
	_expect(
		int(client.join_payload()["resume_tick"]) == 1,
		"取走 tick 0 与 1 之后 resume_tick 应为 1，实际 %d" % int(client.join_payload()["resume_tick"]),
		failures
	)

	client.queue_free()
	return failures

## 补帧必须原样按序进队列，一帧不少。
func _check_backfill_enqueue() -> Array[String]:
	var failures: Array[String] = []
	var client := _make_client()

	# 断线前走到 tick 2。
	for tick in range(3):
		_feed(client, _frame(tick))
	for _index in range(3):
		client.pop_frame()
	var resume_tick := int(client.join_payload()["resume_tick"])
	_expect(resume_tick == 2, "断线时应停在 tick 2，实际 %d" % resume_tick, failures)

	# 房间补上 tick 3..9，随后直播帧 10 到达。
	var backfilled: Array = []
	for tick in range(resume_tick + 1, 10):
		backfilled.append(_frame(tick))
	_feed(client, {"type": "backfill", "frames": backfilled})
	_feed(client, _frame(10))

	var drained: Array[int] = []
	while true:
		var frame = client.pop_frame()
		if frame == null:
			break
		drained.append(int(frame["t"]))
	var expected_ticks: Array[int] = [3, 4, 5, 6, 7, 8, 9, 10]
	_expect(
		drained == expected_ticks,
		"补帧后应连续消费 tick 3..10，实际 %s" % str(drained),
		failures
	)
	_expect(
		int(client.join_payload()["resume_tick"]) == 10,
		"补完并消费到 tick 10 之后 resume_tick 应为 10",
		failures
	)

	client.queue_free()
	return failures

## 队列上限必须容得下一次完整回放，否则补帧会在入队当场被自己丢掉。
func _check_queue_holds_a_full_replay() -> Array[String]:
	var failures: Array[String] = []
	var client := _make_client()

	var history_limit: int = LobbyProtocolScript.FRAME_HISTORY_LIMIT
	_expect(
		RoomClientScript.FRAME_QUEUE_HARD_LIMIT >= history_limit,
		"帧队列上限 %d 小于房间的帧历史 %d：一次完整补帧会被自己丢掉最旧的几帧" % [
			RoomClientScript.FRAME_QUEUE_HARD_LIMIT, history_limit
		],
		failures
	)

	var backfilled: Array = []
	for tick in range(history_limit):
		backfilled.append(_frame(tick))
	_feed(client, {"type": "backfill", "frames": backfilled})
	_expect(
		client.queued_frame_count() == history_limit,
		"最长的一次补帧应完整入队 %d 帧，实际 %d" % [history_limit, client.queued_frame_count()],
		failures
	)
	var first = client.pop_frame()
	_expect(
		first != null and int(first["t"]) == 0,
		"完整补帧的第一帧必须还是 tick 0",
		failures
	)

	client.queue_free()
	return failures

## 新一局的 tick 从 0 重来，上一局的进度不能带过去。
func _check_match_start_resets_resume() -> Array[String]:
	var failures: Array[String] = []
	var client := _make_client()

	for tick in range(4):
		_feed(client, _frame(tick))
	for _index in range(4):
		client.pop_frame()
	_feed(client, {"type": "start", "seed": 123, "slots": []})
	_expect(
		int(client.join_payload()["resume_tick"]) == -1,
		"开新一局后 resume_tick 必须归零；带着上一局的 tick 去重连会让房间补错一段历史",
		failures
	)
	_expect(
		client.queued_frame_count() == 0,
		"开新一局必须清空上一局残留的帧",
		failures
	)

	client.queue_free()
	return failures
