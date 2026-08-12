extends SceneTree

const SelectionStateScript = preload(
	"res://scripts/menu/map_selection_state.gd"
)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	var demo_scene := load("res://scenes/maps/demo/DemoMap.tscn") as PackedScene
	var catalog := MapCatalog.new()
	var late := MapCatalogEntry.new()
	late.map_id = &"late"
	late.sort_order = 20
	late.entry_scene = null
	var demo := MapCatalogEntry.new()
	demo.map_id = &"demo"
	demo.sort_order = 0
	demo.entry_scene = demo_scene
	var catalog_entries: Array[MapCatalogEntry] = [late, demo]
	catalog.entries = catalog_entries

	var state = SelectionStateScript.new()
	state.set_catalog(catalog)
	_expect(state.selected_entry().map_id == &"demo", "catalog sorted selection", failures)
	_expect(
		state.selected_scene_path() == "res://scenes/maps/demo/DemoMap.tscn",
		"selected scene path",
		failures
	)
	state.move_selection(-1)
	_expect(state.selected_entry().map_id == &"late", "selection wraps backwards", failures)
	_expect(state.selected_scene_path().is_empty(), "missing scene returns empty path", failures)

	var session = root.get_node("GameSession")
	session.begin_map_selection(GameSessionState.Mode.LOCAL_MULTIPLAYER)
	_expect(session.map_selection_mode == GameSessionState.Mode.LOCAL_MULTIPLAYER, "local selection mode", failures)
	_expect(session.selected_map_scene_path.is_empty(), "selection starts empty", failures)
	session.select_map_scene("res://scenes/maps/demo/DemoMap.tscn")
	session.configure_local([])
	_expect(
		session.selected_game_scene_path("fallback") == "res://scenes/maps/demo/DemoMap.tscn",
		"configure local preserves selected map",
		failures
	)
	session.clear()
	_expect(session.selected_map_scene_path.is_empty(), "clear removes selected map", failures)

	_finish(failures)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_map_selection_state: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
