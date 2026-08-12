extends Node
class_name RoomClient

## 房间的 WebSocket 客户端。
##
## 它只做三件事：把大厅消息翻译成信号、把每 tick 的命令发出去、把收到的帧
## 排进队列供模拟层消费。它**不**推进模拟：推进由 GameplayArena 按墙钟节奏从
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
##
## 下限是服务端的帧历史长度：重连时房间会把断线期间的帧一次补齐，
## 上限比它小就会在入队当场丢掉最旧的几帧，把一次本该成功的重连
## 变成一次必然的不同步。
const FRAME_QUEUE_HARD_LIMIT := LobbyProtocolScript.FRAME_HISTORY_LIMIT + 60

const RECONNECT_DELAY_SECONDS := 2.0
const MAX_RECONNECT_ATTEMPTS := 5
## 客户端侧延迟探测的间隔。服务器的心跳 ping 只够保活，测不出 RTT——
## 往返时延必须在同一台机器的 clock 上做差，而那个 ping 的时间戳是服务器的。
const PING_INTERVAL_SECONDS := 2.0

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
## 本机选定的角色。记在这里而不是只记在界面上，是为了重连：
## 握手要把它重新报给房间，否则重连回去的人会变回默认角色。
var character_id: StringName = &""
## 房主选定的地图。由 roster 与 start 两种消息共同维护。
var room_map_id := ""
var roster: Array = []
var seed_value := 0

var _frames: Array = []
## 本机模拟已经走到的 tick。重连时随 join 上报，房间据此决定补哪一段。
## -1 表示这一局还没消费过任何帧。
var _applied_tick := -1
var _connecting := false
var _joined := false
var _reconnect_attempts := 0
var _reconnect_timer := 0.0
var _want_connection := false
var _last_rtt_ms := -1
var _ping_timer := 0.0

func _ready() -> void:
	set_process(true)

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

func leave() -> void:
	_want_connection = false
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send({"type": "leave"})
		socket.close(1000, "left")
	_joined = false
	_frames.clear()
	_applied_tick = -1
	_last_rtt_ms = -1
	_ping_timer = 0.0

func set_ready(is_ready: bool) -> void:
	_send({"type": "ready", "ready": is_ready})

func request_start() -> void:
	_send({"type": "start"})

## 换角色。本机先记下来，再发出去——重连时握手要带的是本机的选择，
## 而不是「上一次服务端确认过的选择」。
func select_character(id: StringName) -> void:
	character_id = id
	_send({"type": "select_character", "character_id": String(id)})

## 换地图。服务端只认房主发的，这里不做本地拦截：拦截会让「我以为我是房主」
## 与「服务端认为谁是房主」两份判断产生分歧，而只有后者算数。
func select_map(id: StringName) -> void:
	_send({"type": "select_map", "map_id": String(id)})

func is_host() -> bool:
	return slot >= 0 and slot == host_slot

func is_connected_to_room() -> bool:
	return socket.get_ready_state() == WebSocketPeer.STATE_OPEN and _joined

## 一个 tick 的命令。GameplayArena 每消费一帧就调一次，频率天然等于服务端泵帧频率。
func send_command(command: Dictionary, hash_tick: int) -> void:
	if not is_connected_to_room():
		return
	var message := {"type": "cmd", "c": command}
	if hash_tick >= 0:
		message["ht"] = hash_tick
	_send(message)

## 最近一次往返时延（毫秒）。-1 表示还没测出来（未连接，或第一个来回还没走完）。
## 值是平滑过的，免得单个尖峰让 HUD 数字乱跳。
func last_rtt_ms() -> int:
	return _last_rtt_ms

func report_result(team_wave: int, player_kills: Dictionary) -> void:
	_send({
		"type": "result",
		"team_wave": team_wave,
		"player_kills": player_kills,
	})

## 取出下一帧；队列空时返回 null，调用方必须原地等待而不是自行推进。
##
## 取走即视为已应用：GameplayArena 拿到帧后同一次调用里就 step 了模拟。
## 记住这个 tick 是为了重连——它就是「本机停在哪」的唯一答案。
func pop_frame():
	if _frames.is_empty():
		return null
	var frame = _frames.pop_front()
	if typeof(frame) == TYPE_DICTIONARY:
		_applied_tick = int(frame.get("t", _applied_tick))
	return frame

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
		_tick_ping(delta)
		return
	if state == WebSocketPeer.STATE_CLOSED:
		_handle_closed()

## 周期性发一个带本机 monotonic 时间戳的 ping。服务器的 pong 把这个戳原样
## 带回，做差的 clock 从头到尾都是本机这一个——这正是 RTT 测得准的前提。
## get_ticks_usec 在 Web 端也单调且不受系统校时影响，比墙钟可靠。
func _tick_ping(delta: float) -> void:
	if not is_connected_to_room():
		return
	_ping_timer -= delta
	if _ping_timer > 0.0:
		return
	_ping_timer = PING_INTERVAL_SECONDS
	_send({"type": "ping", "ct": Time.get_ticks_usec()})

func _on_pong_echo(client_time_usec: int) -> void:
	var rtt_usec := Time.get_ticks_usec() - client_time_usec
	if rtt_usec < 0:
		return
	var rtt_ms := rtt_usec / 1000
	if _last_rtt_ms < 0:
		_last_rtt_ms = rtt_ms
	else:
		# 指数平滑（约 1/3 新样本），压住偶发抖动。
		_last_rtt_ms = int(round(lerpf(float(_last_rtt_ms), float(rtt_ms), 0.35)))

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
	_last_rtt_ms = -1
	_ping_timer = 0.0

## 握手负载。单独抽出来是为了能在不开 socket 的情况下断言 resume_tick——
## 少报一个 tick 就是让房间补少一帧，而少一帧就是整局不同步。
func join_payload() -> Dictionary:
	return {
		"type": "join",
		"protocol_version": LobbyProtocolScript.PROTOCOL_VERSION,
		"token": token,
		"nickname": nickname,
		"resume_tick": _applied_tick,
		"character_id": String(character_id),
	}

func _send_join() -> void:
	_send(join_payload())

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
			# 必须在 emit 之前落好：房间面板是在这个信号里读 room_map_id 的。
			room_map_id = String(message.get("map_id", room_map_id))
			roster_changed.emit(roster, host_slot, room_state)
		"start":
			seed_value = int(message.get("seed", 0))
			room_map_id = String(message.get("map_id", room_map_id))
			room_state = "playing"
			_frames.clear()
			# 新一局的 tick 从 0 重新开始，上一局走到哪与这一局无关。
			_applied_tick = -1
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
		"backfill":
			# 重连补帧。它们和直播帧走同一条队列、同一套消费逻辑——
			# 补帧本来就是「服务端已经发过、本机没收到」的那批帧本身，
			# 给它们另开一条路径就等于给同一段历史准备了两种走法。
			var frames = message.get("frames", [])
			if typeof(frames) == TYPE_ARRAY:
				for frame in frames:
					if typeof(frame) == TYPE_DICTIONARY:
						_frames.append(frame)
				while _frames.size() > FRAME_QUEUE_HARD_LIMIT:
					_frames.pop_front()
		"end":
			room_state = "ended"
			match_ended.emit(message)
		"desync":
			desync_detected.emit(int(message.get("tick", -1)), int(message.get("slot", -1)))
		"ping":
			# 服务器的心跳 ping，照旧回 pong 保活。它带的是服务器时钟，不能用来测延迟。
			_send({"type": "pong", "t": message.get("t", 0)})
		"pong":
			# 我们自己 ping 的回声：ct 是本机 monotonic 戳，可直接做差。
			var ct = message.get("ct", -1)
			if typeof(ct) == TYPE_INT or typeof(ct) == TYPE_FLOAT:
				_on_pong_echo(int(ct))
		_:
			pass

func _handle_closed() -> void:
	var close_code := socket.get_close_code()
	var close_reason := socket.get_close_reason()
	_joined = false
	if not _want_connection:
		return
	# 协议版本不符与房满是终局，重连一百次也还是同一个结果。
	# 补不回帧同理：再连一次只会离房间的帧历史更远。
	if close_code in [
		LobbyProtocolScript.CLOSE_PROTOCOL_MISMATCH,
		LobbyProtocolScript.CLOSE_ROOM_FULL,
		LobbyProtocolScript.CLOSE_RECONNECTED_ELSEWHERE,
		LobbyProtocolScript.CLOSE_CANNOT_RESUME,
	]:
		_want_connection = false
		if close_code == LobbyProtocolScript.CLOSE_CANNOT_RESUME:
			# 服务端的原因写的是缺哪一段 tick，那是给日志看的。
			disconnected.emit(close_code, "掉线太久，无法回到这一局")
		else:
			disconnected.emit(close_code, close_reason)
		return
	_reconnect_attempts += 1
	if _reconnect_attempts > MAX_RECONNECT_ATTEMPTS:
		_want_connection = false
		disconnected.emit(close_code, close_reason if close_reason != "" else "连接已断开")
		return
	_reconnect_timer = RECONNECT_DELAY_SECONDS
