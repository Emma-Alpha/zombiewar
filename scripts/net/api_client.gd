extends Node
class_name ApiClient

## 服务端 HTTP 接口的客户端。每个请求用一个一次性的 HTTPRequest 子节点，
## 用完即焚：HTTPRequest 一次只能跑一个请求，复用一个实例会让
## 「排行榜还没回来玩家就点了建房」表现成一次静默失败。

const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")
const NetConfigScript = preload("res://scripts/net/net_config.gd")

const REQUEST_TIMEOUT_SECONDS := 12.0

signal authenticated(player_id: String, token: String, nickname: String)
signal auth_failed(code: String, message: String)
signal leaderboard_loaded(board: String, entries: Array, total: int)
signal leaderboard_failed(board: String, message: String)
signal room_created(code: String)
signal room_create_failed(message: String)
signal room_list_loaded(rooms: Array)
signal room_list_failed(message: String)

func authenticate(device_id: String, nickname: String) -> void:
	_request(
		NetConfigScript.api_url("/api/auth/anon"),
		HTTPClient.METHOD_POST,
		{"device_id": device_id, "nickname": nickname},
		"",
		func(ok: bool, code: int, body: Dictionary) -> void:
			if ok and code == 200:
				authenticated.emit(
					String(body.get("player_id", "")),
					String(body.get("token", "")),
					String(body.get("nickname", nickname))
				)
				return
			auth_failed.emit(
				String(body.get("error", "network_error")),
				String(body.get("message", "无法连接服务器"))
			)
	)

## board 取 "team" 或 "kills"，对应队伍波次榜与个人击杀榜。
func load_leaderboard(board: String, limit: int = 20, offset: int = 0) -> void:
	var path := "/api/leaderboard/%s?limit=%d&offset=%d" % [board, limit, offset]
	_request(
		NetConfigScript.api_url(path),
		HTTPClient.METHOD_GET,
		{},
		"",
		func(ok: bool, code: int, body: Dictionary) -> void:
			if ok and code == 200:
				var entries = body.get("entries", [])
				leaderboard_loaded.emit(
					board,
					entries if typeof(entries) == TYPE_ARRAY else [],
					int(body.get("total", 0))
				)
				return
			leaderboard_failed.emit(board, String(body.get("message", "排行榜读取失败")))
	)

func create_room(token: String, is_public: bool) -> void:
	_request(
		NetConfigScript.api_url("/api/rooms"),
		HTTPClient.METHOD_POST,
		{"is_public": is_public},
		token,
		func(ok: bool, code: int, body: Dictionary) -> void:
			if ok and code == 200:
				room_created.emit(String(body.get("code", "")))
				return
			room_create_failed.emit(String(body.get("message", "建房失败")))
	)

func list_rooms() -> void:
	_request(
		NetConfigScript.api_url("/api/rooms?limit=20"),
		HTTPClient.METHOD_GET,
		{},
		"",
		func(ok: bool, code: int, body: Dictionary) -> void:
			if ok and code == 200:
				var rooms = body.get("rooms", [])
				room_list_loaded.emit(rooms if typeof(rooms) == TYPE_ARRAY else [])
				return
			room_list_failed.emit(String(body.get("message", "房间列表读取失败")))
	)

func _request(
	url: String,
	method: int,
	payload: Dictionary,
	token: String,
	on_done: Callable
) -> void:
	var request := HTTPRequest.new()
	request.timeout = REQUEST_TIMEOUT_SECONDS
	add_child(request)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if token != "":
		# X-Player-Token 与 Authorization 二选一即可；这里两个都发，
		# 是因为浏览器对 Authorization 会多一次预检，而预检失败的报错
		# 与「服务器不可达」长得一模一样。
		headers.append("Authorization: Bearer %s" % token)
		headers.append("X-Player-Token: %s" % token)
	request.request_completed.connect(
		func(
			result: int,
			response_code: int,
			_response_headers: PackedStringArray,
			body: PackedByteArray
		) -> void:
			var parsed := {}
			var text := body.get_string_from_utf8()
			if text != "":
				var decoded = JSON.parse_string(text)
				if typeof(decoded) == TYPE_DICTIONARY:
					parsed = decoded
			on_done.call(result == HTTPRequest.RESULT_SUCCESS, response_code, parsed)
			request.queue_free()
	)
	var body_text := "" if payload.is_empty() and method == HTTPClient.METHOD_GET else JSON.stringify(payload)
	var error := request.request(url, headers, method, body_text)
	if error != OK:
		on_done.call(false, 0, {"message": "请求发送失败（%d）" % error})
		request.queue_free()
