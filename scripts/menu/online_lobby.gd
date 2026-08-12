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
	_publish_default_map_if_host()
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

## 新房间的 map_id 是空串——服务端不认识内容，给不出默认值。
## 由房主把目录默认值写成一个**具体的 id** 发上去，而不是让各端各自把空串
## 解析成"自己目录里的第一张图"：后者在两端目录不一致时会静默跑成两张图，
## 而这正是 _missing_content() 想当场拦下的那种分叉。
##
## 顺带这也是开局的前提：空 map_id 过不了 _missing_content()，房主不发这一条，
## 谁都开不了局。
## 返回实际发出去的 id；没发则返回空串（便于校验断言）。
func _publish_default_map_if_host() -> StringName:
	if not NetSession.room.is_host():
		return &""
	if NetSession.room.room_map_id != "":
		return &""
	var default_map: StringName = ContentCatalogsScript.maps().default_id()
	NetSession.room.select_map(default_map)
	return default_map

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
