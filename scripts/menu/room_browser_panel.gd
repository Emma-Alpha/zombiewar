extends VBoxContainer
class_name RoomBrowserPanel

## 未入房时的那一屏：身份、服务器地址、房间列表、建房与加入。
##
## 它不认识 NetSession——所有动作都以信号抛给大厅宿主。这样「连接住在
## autoload 上、界面只是它的一个视图」这条既有设计不会被面板拆分打破。

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
