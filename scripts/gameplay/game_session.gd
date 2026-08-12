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
var map_selection_mode := Mode.SINGLE
var selected_map_scene_path := ""

func begin_map_selection(target_mode: Mode) -> void:
	map_selection_mode = target_mode
	selected_map_scene_path = ""
	local_players.clear()
	last_error = ""

func select_map_scene(scene_path: String) -> void:
	selected_map_scene_path = scene_path

func selected_game_scene_path(fallback: String) -> String:
	return fallback if selected_map_scene_path.is_empty() else selected_map_scene_path

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
	map_selection_mode = Mode.SINGLE
	selected_map_scene_path = ""
