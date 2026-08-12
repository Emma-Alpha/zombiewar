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
