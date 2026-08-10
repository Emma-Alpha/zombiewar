extends Node3D
class_name OnlineLobby

## 联机大厅：匿名身份 -> 建房 / 加入 -> 准备 -> 房主开局。
##
## 房间连接本身不住在这里，而住在 NetSession（autoload）上。大厅只是它的
## 一个视图：开局时场景会切到竞技场，连接必须活过那次切换。

const ApiClientScript = preload("res://scripts/net/api_client.gd")
const OnlinePlayerDescriptorScript = preload("res://scripts/net/online_player_descriptor.gd")
const RoomClientScript = preload("res://scripts/net/room_client.gd")
const NetConfigScript = preload("res://scripts/net/net_config.gd")
const LobbyProtocolScript = preload("res://scripts/net/lobby_protocol.gd")

@export_file("*.tscn") var game_scene_path := "res://scenes/gameplay/DemoArena.tscn"
@export_file("*.tscn") var main_menu_scene_path := "res://scenes/menu/MainMenu.tscn"

@onready var status_label: Label = %StatusLabel
@onready var nickname_edit: LineEdit = %NicknameEdit
@onready var server_edit: LineEdit = %ServerEdit
@onready var room_code_edit: LineEdit = %RoomCodeEdit
@onready var room_list: ItemList = %RoomList
@onready var roster_label: Label = %RosterLabel
@onready var create_button: Button = %CreateRoomButton
@onready var join_button: Button = %JoinRoomButton
@onready var refresh_button: Button = %RefreshRoomsButton
@onready var ready_button: Button = %ReadyButton
@onready var start_button: Button = %StartButton
@onready var back_button: Button = %BackButton

var is_ready := false
var transition_pending := false

func _ready() -> void:
	nickname_edit.text = NetSession.identity.nickname
	server_edit.text = NetConfigScript.base_url()
	room_list.item_selected.connect(_on_room_selected)

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
		_set_status("已在房间 %s" % room.room_code)
		_on_roster_changed(room.roster, room.host_slot, room.room_state)
	else:
		_set_status("正在获取身份…")
		NetSession.ensure_identity()
	_sync_buttons()

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

func _on_simple_error(message: String) -> void:
	_set_status(message)
	_sync_buttons()

func _on_identity_ready(nickname: String) -> void:
	nickname_edit.text = nickname
	_set_status("身份就绪：%s（匿名）" % nickname)
	NetSession.api.list_rooms()
	_sync_buttons()

func _on_identity_failed(message: String) -> void:
	_set_status("连接服务器失败：%s" % message)
	_sync_buttons()

func _on_save_nickname_button_pressed() -> void:
	_set_status("正在更新昵称…")
	NetSession.ensure_identity(nickname_edit.text)

## 换服务器地址会作废当前令牌与房间：令牌是上一台服务器发的，
## 拿到新服务器上什么都不是。所以这里顺手断开并重新取身份。
func _on_apply_server_button_pressed() -> void:
	NetConfigScript.save_override(server_edit.text)
	NetSession.leave_room()
	server_edit.text = NetConfigScript.base_url()
	_set_status("服务器已切换到 %s，正在重新获取身份…" % server_edit.text)
	NetSession.ensure_identity()
	_sync_buttons()

func _on_create_room_button_pressed() -> void:
	if not NetSession.has_token():
		_set_status("还没拿到身份，请稍候")
		return
	_set_status("正在建房…")
	create_button.disabled = true
	NetSession.api.create_room(NetSession.identity.token, true)

func _on_room_created(code: String) -> void:
	room_code_edit.text = code
	_set_status("房间 %s 已创建，正在连接…" % code)
	_connect_to_room(code)

func _on_join_room_button_pressed() -> void:
	var code := room_code_edit.text.strip_edges().to_upper()
	if code.length() != 6:
		_set_status("房间码是 6 位字符")
		return
	_set_status("正在加入 %s…" % code)
	_connect_to_room(code)

func _connect_to_room(code: String) -> void:
	NetSession.room.connect_to_room(
		code, NetSession.identity.token, NetSession.identity.nickname
	)
	_sync_buttons()

func _on_refresh_rooms_button_pressed() -> void:
	_set_status("正在刷新房间列表…")
	NetSession.api.list_rooms()

func _on_room_list_loaded(rooms: Array) -> void:
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
	_set_status("公开房间 %d 个" % room_list.item_count if room_list.item_count > 0 else "暂无公开房间，可直接建房")

func _on_room_selected(index: int) -> void:
	var code = room_list.get_item_metadata(index)
	if typeof(code) == TYPE_STRING:
		room_code_edit.text = code

func _on_room_connected(slot: int, _player_id: String) -> void:
	_set_status("已加入房间 %s，座位 P%d" % [NetSession.room.room_code, slot + 1])
	_sync_buttons()

func _on_room_disconnected(code: int, reason: String) -> void:
	is_ready = false
	if code == LobbyProtocolScript.CLOSE_PROTOCOL_MISMATCH:
		# 服务端在关闭原因里写了双方版本号，原样透出去：
		# 这条消息就是为了让「客户端和服务端不是一批」当场看得见。
		_set_status("协议版本不一致，请更新客户端（%s）" % reason)
	elif code == LobbyProtocolScript.CLOSE_ROOM_FULL:
		_set_status("房间已满或对局已开始")
	else:
		_set_status("连接断开：%s" % reason)
	roster_label.text = ""
	_sync_buttons()

func _on_roster_changed(players: Array, host_slot: int, state: String) -> void:
	var lines: Array[String] = []
	for entry in players:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var slot := int(entry.get("slot", 0))
		var marks: Array[String] = []
		if slot == host_slot:
			marks.append("房主")
		if bool(entry.get("ready", false)):
			marks.append("已准备")
		if not bool(entry.get("connected", true)):
			marks.append("掉线")
		var suffix := "（%s）" % "·".join(marks) if not marks.is_empty() else ""
		lines.append("P%d  %s%s" % [slot + 1, String(entry.get("nickname", "")), suffix])
	if lines.is_empty():
		lines.append("房间里还没有人")
	lines.append("")
	lines.append("对局状态：%s" % state)
	lines.append("提示：至少 2 人完成对局才会计入排行榜")
	roster_label.text = "\n".join(lines)
	_sync_buttons()

func _on_ready_button_pressed() -> void:
	is_ready = not is_ready
	NetSession.room.set_ready(is_ready)
	_sync_buttons()

func _on_start_button_pressed() -> void:
	NetSession.room.request_start()

## 开局：把服务端压实后的座位表翻译成玩家描述符，本机那一个标成 is_local。
func _on_match_started(seed_value: int, slots: Array) -> void:
	if transition_pending:
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
		descriptors.append(descriptor)
	descriptors.sort_custom(func(a, b): return a.player_index < b.player_index)
	GameSession.configure_online(descriptors)
	get_tree().change_scene_to_file(game_scene_path)

func _on_match_ended(result: Dictionary) -> void:
	var status := String(result.get("status", ""))
	if status == "accepted" and bool(result.get("persisted", false)):
		_set_status("对局结束：第 %d 波，成绩已记录" % int(result.get("team_wave", 0)))
	else:
		_set_status("对局结束：成绩未保存（%s）" % String(result.get("reason", status)))
	is_ready = false
	_sync_buttons()

func _on_back_button_pressed() -> void:
	transition_pending = true
	NetSession.leave_room()
	GameSession.clear()
	get_tree().change_scene_to_file(main_menu_scene_path)

func _sync_buttons() -> void:
	var room: RoomClient = NetSession.room
	var in_room := room.is_connected_to_room()
	create_button.disabled = in_room or not NetSession.has_token()
	join_button.disabled = in_room
	refresh_button.disabled = in_room
	ready_button.disabled = not in_room
	ready_button.text = "取消准备" if is_ready else "准备"
	start_button.disabled = not (in_room and room.is_host())
	start_button.text = "开始对局" if room.is_host() else "等待房主开局"
