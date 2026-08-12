extends SceneTree

const MAP_SELECTION_PATH := "res://scenes/menu/MapSelection.tscn"
const DEMO_PATH := "res://scenes/maps/demo/DemoMap.tscn"

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
	_expect(not online_source.contains("selected_game_scene_path"), "online ignores selected map", failures)
	_expect(online_source.contains("game_scene_path := \"%s\"" % DEMO_PATH), "online default remains demo", failures)

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
