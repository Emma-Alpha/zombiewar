extends SceneTree

const MenuFlowScript = preload("res://scripts/menu/menu_flow.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var single_flow = MenuFlowScript.new()
	_expect(single_flow.has_method("request_single"), "MenuFlow must expose request_single", failures)
	if single_flow.has_method("request_single"):
		_expect(single_flow.request_single(), "ready flow must accept single-player start", failures)
		_expect(not single_flow.request_single(), "starting flow must reject duplicate single-player start", failures)
	var local_flow = MenuFlowScript.new()
	_expect(local_flow.has_method("request_local"), "MenuFlow must expose request_local", failures)
	if local_flow.has_method("request_local"):
		_expect(local_flow.request_local(), "ready flow must accept local multiplayer start", failures)
		_expect(not local_flow.request_local(), "starting flow must reject duplicate local start", failures)

	var main_scene := load("res://scenes/menu/MainMenu.tscn") as PackedScene
	_expect(main_scene != null, "MainMenu scene must load", failures)
	if main_scene != null:
		var main = main_scene.instantiate()
		var single_button := main.get_node_or_null("MenuLayer/MenuRoot/LeftColumn/Actions/SinglePlayerButton") as Button
		var local_button := main.get_node_or_null("MenuLayer/MenuRoot/LeftColumn/Actions/LocalMultiplayerButton") as Button
		var quit_button := main.get_node_or_null("MenuLayer/MenuRoot/LeftColumn/Actions/QuitButton") as Button
		_expect(single_button != null, "MainMenu must contain SinglePlayerButton", failures)
		_expect(local_button != null, "MainMenu must contain LocalMultiplayerButton", failures)
		_expect(quit_button != null, "MainMenu must contain QuitButton", failures)
		if single_button != null and local_button != null and quit_button != null:
			_expect(single_button.focus_neighbor_bottom == single_button.get_path_to(local_button), "single-player focus must move down to local multiplayer", failures)
			_expect(local_button.focus_neighbor_top == local_button.get_path_to(single_button), "local multiplayer focus must move up to single-player", failures)
			_expect(local_button.focus_neighbor_bottom == local_button.get_path_to(quit_button), "local multiplayer focus must move down to quit", failures)
		main.free()

	var lobby_scene := load("res://scenes/menu/LocalMultiplayerLobby.tscn") as PackedScene
	_expect(lobby_scene != null, "LocalMultiplayerLobby scene must load", failures)
	if lobby_scene != null:
		var lobby = lobby_scene.instantiate()
		_expect(lobby.get("join_state") != null, "lobby must own a join state", failures)
		for player_number in range(1, 5):
			_expect(lobby.get_node_or_null("LobbyWorld/Slots/P%d" % player_number) is Marker3D, "lobby must contain world slot P%d" % player_number, failures)
			_expect(lobby.get_node_or_null("MenuLayer/StatusRoot/P%dStatus" % player_number) is Label, "lobby must contain status label P%d" % player_number, failures)
		_expect(lobby.get_node_or_null("MenuLayer/P1Hint") is Label, "lobby must contain fixed P1 operation hint", failures)
		lobby.free()

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_local_multiplayer_menu_scenes: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
