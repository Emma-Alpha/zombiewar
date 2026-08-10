extends Node
class_name RoomClient

## 房间的 WebSocket 客户端。
##
## 它只做三件事：把大厅消息翻译成信号、把每 tick 的命令发出去、把收到的帧
## 排进队列供模拟层消费。它**不**推进模拟：推进由 DemoArena 按墙钟节奏从
## 队列里取帧完成，取不到就停在原地。
##
## 「取不到就停」是这套同步的地基。服务端是唯一的 tick 权威，客户端自行
## 补一个服务端没发过的 tick，就等于凭空发明了一段所有其他客户端都没有的
## 历史——而那正是不同步的定义。

const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")
const NetConfigScript = preload("res://scripts/net/net_config.gd")

## 队列深过这个值说明本机落后了，多吐几帧追上去。
const FRAME_QUEUE_CATCHUP_DEPTH := 6
## 队列再深就说明落后得离谱（切后台、长卡顿），直接丢弃最旧的帧。
## 丢帧当然会不同步，但那时不同步已经发生，早点让哈希对拍报出来更好。
const FRAME_QUEUE_HARD_LIMIT := 240

const RECONNECT_DELAY_SECONDS := 2.0
const MAX_RECONNECT_ATTEMPTS := 5

signal connected(slot: int, player_id: String)
signal connection_failed(reason: String)
signal disconnected(code: int, reason: String)
signal roster_changed(players: Array, host_slot: int, state: String)
signal match_started(seed_value: int, slots: Array)
signal match_ended(result: Dictionary)
signal desync_detected(tick: int, slot: int)

var socket := WebSocketPeer.new()
var room_code := ""
var token := ""
var nickname := ""
var slot := -1
var player_id := ""
var host_slot := -1
var room_state := "lobby"
var roster: Array = []
var seed_value := 0

var _frames: Array = []
var _connecting := false
var _joined := false
var _reconnect_attempts := 0
var _reconnect_timer := 0.0
var _want_connection := false

func _ready() -> void:
	set_process(true)

func connect_to_room(code: String, session_token: String, display_name: String) -> void:
	room_code = code.to_upper()
	token = session_token
	nickname = display_name
	_want_connection = true
	_reconnect_attempts = 0
	_open_socket()

func leave() -> void:
	_want_connection = false
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send({"type": "leave"})
		socket.close(1000, "left")
	_joined = false
	_frames.clear()

func set_ready(is_ready: bool) -> void:
	_send({"type": "ready", "ready": is_ready})

func request_start() -> void:
	_send({"type": "start"})

func is_host() -> bool:
	return slot >= 0 and slot == host_slot

func is_connected_to_room() -> bool:
	return socket.get_ready_state() == WebSocketPeer.STATE_OPEN and _joined

## 一个 tick 的命令。DemoArena 每消费一帧就调一次，频率天然等于服务端泵帧频率。
func send_command(command: Dictionary, hash_tick: int) -> void:
	if not is_connected_to_room():
		return
	var message := {"type": "cmd", "c": command}
	if hash_tick >= 0:
		message["ht"] = hash_tick
	_send(message)

func report_result(team_wave: int, player_kills: Dictionary) -> void:
	_send({
		"type": "result",
		"team_wave": team_wave,
		"player_kills": player_kills,
	})

## 取出下一帧；队列空时返回 null，调用方必须原地等待而不是自行推进。
func pop_frame():
	if _frames.is_empty():
		return null
	return _frames.pop_front()

func queued_frame_count() -> int:
	return _frames.size()

## 落后时应当额外吐出的帧数。
func catchup_frames() -> int:
	if _frames.size() <= FRAME_QUEUE_CATCHUP_DEPTH:
		return 0
	return _frames.size() - FRAME_QUEUE_CATCHUP_DEPTH

func _process(delta: float) -> void:
	if _reconnect_timer > 0.0:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0.0:
			_open_socket()
		return
	socket.poll()
	var state := socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if _connecting:
			_connecting = false
			_send_join()
		while socket.get_available_packet_count() > 0:
			_handle_packet(socket.get_packet())
		return
	if state == WebSocketPeer.STATE_CLOSED:
		_handle_closed()

func _open_socket() -> void:
	socket = WebSocketPeer.new()
	var url := NetConfigScript.websocket_url(room_code)
	var error := socket.connect_to_url(url)
	if error != OK:
		connection_failed.emit("无法连接 %s（错误 %d）" % [url, error])
		_want_connection = false
		return
	_connecting = true
	_joined = false

func _send_join() -> void:
	_send({
		"type": "join",
		"protocol_version": LobbyProtocolScript.PROTOCOL_VERSION,
		"token": token,
		"nickname": nickname,
	})

func _send(payload: Dictionary) -> void:
	if socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	socket.send_text(JSON.stringify(payload))

func _handle_packet(packet: PackedByteArray) -> void:
	var decoded = JSON.parse_string(packet.get_string_from_utf8())
	if typeof(decoded) != TYPE_DICTIONARY:
		return
	var message := decoded as Dictionary
	match String(message.get("type", "")):
		"welcome":
			slot = int(message.get("slot", -1))
			player_id = String(message.get("player_id", ""))
			room_state = String(message.get("state", "lobby"))
			seed_value = int(message.get("seed", 0))
			_joined = true
			_reconnect_attempts = 0
			connected.emit(slot, player_id)
		"roster":
			var players = message.get("players", [])
			roster = players if typeof(players) == TYPE_ARRAY else []
			host_slot = int(message.get("host_slot", -1))
			room_state = String(message.get("state", room_state))
			roster_changed.emit(roster, host_slot, room_state)
		"start":
			seed_value = int(message.get("seed", 0))
			room_state = "playing"
			_frames.clear()
			var slots = message.get("slots", [])
			var slot_list: Array = slots if typeof(slots) == TYPE_ARRAY else []
			# 服务端在开局前会把座位压实到 0..n-1，所以 welcome 时拿到的槽位
			# 可能已经过期。以 start 里的 player_id 为准重新认领自己的槽位，
			# 否则本机会去操作别人的身体。
			for entry in slot_list:
				if typeof(entry) == TYPE_DICTIONARY and String(entry.get("player_id", "")) == player_id:
					slot = int(entry.get("slot", slot))
					break
			match_started.emit(seed_value, slot_list)
		"f":
			_frames.append(message)
			while _frames.size() > FRAME_QUEUE_HARD_LIMIT:
				_frames.pop_front()
		"end":
			room_state = "ended"
			match_ended.emit(message)
		"desync":
			desync_detected.emit(int(message.get("tick", -1)), int(message.get("slot", -1)))
		"ping":
			_send({"type": "pong", "t": message.get("t", 0)})
		_:
			pass

func _handle_closed() -> void:
	var close_code := socket.get_close_code()
	var close_reason := socket.get_close_reason()
	_joined = false
	if not _want_connection:
		return
	# 协议版本不符与房满是终局，重连一百次也还是同一个结果。
	if close_code in [
		LobbyProtocolScript.CLOSE_PROTOCOL_MISMATCH,
		LobbyProtocolScript.CLOSE_ROOM_FULL,
		LobbyProtocolScript.CLOSE_RECONNECTED_ELSEWHERE,
	]:
		_want_connection = false
		disconnected.emit(close_code, close_reason)
		return
	_reconnect_attempts += 1
	if _reconnect_attempts > MAX_RECONNECT_ATTEMPTS:
		_want_connection = false
		disconnected.emit(close_code, close_reason if close_reason != "" else "连接已断开")
		return
	_reconnect_timer = RECONNECT_DELAY_SECONDS
