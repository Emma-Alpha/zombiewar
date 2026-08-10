extends Node
class_name GameSessionState

enum Mode {
	SINGLE,
	LOCAL_MULTIPLAYER,
	ONLINE_MULTIPLAYER,
}

var mode := Mode.SINGLE
var local_players: Array = []
var last_error := ""

func configure_single() -> void:
	mode = Mode.SINGLE
	local_players.clear()
	last_error = ""

func configure_local(players: Array) -> void:
	mode = Mode.LOCAL_MULTIPLAYER
	local_players = players.duplicate()
	last_error = ""

## 联机与本地多人共用同一份玩家名单：名单里的描述符决定每个座位的输入源，
## 而「输入从哪来」是联机唯一需要分叉的地方。
func configure_online(players: Array) -> void:
	mode = Mode.ONLINE_MULTIPLAYER
	local_players = players.duplicate()
	last_error = ""

func clear() -> void:
	configure_single()
