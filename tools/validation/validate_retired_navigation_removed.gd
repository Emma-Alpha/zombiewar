extends SceneTree

const REMOVED_PATHS: PackedStringArray = [
	"res://scripts/navigation/navigation_world_manager.gd",
	"res://scripts/navigation/navigation_chunk_3d.gd",
	"res://scripts/navigation/navigation_bake_state.gd",
	"res://scenes/navigation/NavigationChunk3D.tscn",
]

const SCAN_ROOTS: PackedStringArray = [
	"res://scripts",
	"res://scenes",
]

const SCAN_EXTENSIONS: PackedStringArray = ["gd", "tscn"]

const REQUIRED_SCAN_PREFIXES: PackedStringArray = [
	"res://scripts/gameplay/map",
	"res://scenes/maps",
]

const REMOVED_TOKENS: PackedStringArray = [
	"NavigationWorldManager",
	"NavigationChunk3D",
	"NavigationBakeState",
	"NavigationAgent3D",
	"NavigationServer3D",
	"NavigationRegion3D",
	"navigation_geometry_changed",
	"placement_geometry_changed",
	"navigation_source",
	"bake_from_source_geometry_data_async",
]

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	for path in REMOVED_PATHS:
		if FileAccess.file_exists(path):
			failures.append("retired navigation file must be removed: %s" % path)
	var files: Array[String] = []
	for root_path in SCAN_ROOTS:
		_collect_files(root_path, files)
	_check_required_scan_prefixes(files, failures)
	files.append("res://AGENTS.md")
	files.sort()
	for path in files:
		_scan_file(path, failures)
	_finish(failures)

func _check_required_scan_prefixes(
	files: Array[String], failures: Array[String]
) -> void:
	for prefix in REQUIRED_SCAN_PREFIXES:
		var covered := false
		for path in files:
			if path.begins_with(prefix + "/"):
				covered = true
				break
		if not covered:
			failures.append("navigation scan must cover current runtime path: %s" % prefix)

func _collect_files(path: String, files: Array[String]) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if not entry.begins_with("."):
			var child_path := path.path_join(entry)
			if directory.current_is_dir():
				_collect_files(child_path, files)
			elif entry.get_extension() in SCAN_EXTENSIONS:
				files.append(child_path)
		entry = directory.get_next()
	directory.list_dir_end()

func _scan_file(path: String, failures: Array[String]) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("unable to read navigation scan target: %s" % path)
		return
	var source := file.get_as_text()
	for token in REMOVED_TOKENS:
		if source.contains(token):
			failures.append(
				"%s still contains retired navigation token %s" % [path, token]
			)

func _finish(failures: Array[String]) -> void:
	if failures.is_empty():
		print("validate_retired_navigation_removed: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
