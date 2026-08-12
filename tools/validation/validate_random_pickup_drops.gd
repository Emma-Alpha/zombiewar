extends SceneTree

const REMOVED_PATHS := [
	"res://scripts/gameplay/random_pickup_drop_manager.gd",
	"res://scripts/gameplay/random_pickup_drop_manager.gd.uid",
	"res://scenes/gameplay/RandomPickup" + "DropManager.tscn",
]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	for path in REMOVED_PATHS:
		_expect(not FileAccess.file_exists(path), "legacy random drop manager must be removed: %s" % path, failures)
	var manager_token := "RandomPickup" + "DropManager"
	var rng_token := "RandomNumber" + "Generator"
	for path in _runtime_source_paths():
		var source := FileAccess.get_file_as_string(path)
		_expect(
			not source.contains(manager_token),
			"runtime source must not retain %s: %s" % [manager_token, path],
			failures
		)
		var drives_pickup_drop := (
			source.contains("try_spawn_drop") or
			source.contains("drop_chance") or
			source.contains("pickup_definitions")
		)
		_expect(
			not (source.contains(rng_token) and drives_pickup_drop),
			"pickup drops must not be driven by presentation RNG: %s" % path,
			failures
		)
	_finish(failures)

func _runtime_source_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	_collect_runtime_sources("res://scripts", paths)
	_collect_runtime_sources("res://scenes", paths)
	return paths

func _collect_runtime_sources(directory_path: String, paths: PackedStringArray) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return
	for file_name in directory.get_files():
		if file_name.ends_with(".gd") or file_name.ends_with(".tscn"):
			paths.append(directory_path.path_join(file_name))
	for child_name in directory.get_directories():
		_collect_runtime_sources(directory_path.path_join(child_name), paths)

func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_random_pickup_drops: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
