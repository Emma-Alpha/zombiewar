extends SceneTree

const MAP_SELECTION_PATH := "res://scenes/menu/MapSelection.tscn"
const DEMO_PATH := "res://scenes/maps/demo/DemoMap.tscn"
const GENERIC_ARENA_PATH := "res://scenes/gameplay/GameplayArena.tscn"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var main_source := FileAccess.get_file_as_string("res://scripts/menu/main_menu.gd")
	var local_source := FileAccess.get_file_as_string("res://scripts/menu/local_multiplayer_lobby.gd")
	var online_source := FileAccess.get_file_as_string("res://scripts/menu/online_lobby.gd")

	_expect(main_source.contains("map_selection_scene_path"), "main exposes map selection path", failures)
	_expect(main_source.contains("begin_map_selection(GameSessionState.Mode.SINGLE)"), "single begins selection", failures)
	_expect(main_source.contains("begin_map_selection(GameSessionState.Mode.LOCAL_MULTIPLAYER)"), "local begins selection", failures)
	_expect(local_source.contains("selected_game_scene_path(game_scene_path)"), "local launches selected map", failures)
	# 联机必须忽略本地挑的那张图：本地选择只存在于这一端，别人不知道。
	_expect(not online_source.contains("selected_game_scene_path"), "online ignores selected map", failures)
	# 联机入口进的是**通用竞技场**，不是某张具体的地图场景。
	#
	# 这条原先断言的是「联机默认仍是 demo」，那是在联机还没有换图能力时用来防止
	# 本地选图污染联机的。现在房间会下发 map_id、GameplayArena._resolve_map_definition()
	# 按它去目录取图，硬指某张图反而成了缺陷：房主换了图，这一端还在跑原来那张。
	# 上面那条「忽略本地选择」仍然有效，两条合起来表达的是同一个意图——
	# 联机的地图只能由房间决定。
	_expect(
		online_source.contains("game_scene_path := \"%s\"" % GENERIC_ARENA_PATH),
		"online routes through the generic arena so the room's map_id decides the map",
		failures
	)

	var session = root.get_node("GameSession")
	session.begin_map_selection(GameSessionState.Mode.LOCAL_MULTIPLAYER)
	session.select_map_scene(MAP_SELECTION_PATH)
	session.configure_local([])
	_expect(session.selected_game_scene_path(DEMO_PATH) == MAP_SELECTION_PATH, "local selection survives configuration", failures)
	session.clear()

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_game_map_selection_routing: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
