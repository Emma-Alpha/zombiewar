extends SceneTree

const TEST_PATHS: Array[String] = [
	"res://tests/unit/test_project_contract.gd",
	"res://tests/unit/test_player_motion.gd",
	"res://tests/unit/test_follow_camera.gd",
	"res://tests/unit/test_aim_and_fire.gd",
	"res://tests/unit/test_health.gd",
]

func _initialize() -> void:
	var failures: Array[String] = []
	for test_path in TEST_PATHS:
		var test_script := load(test_path) as Script
		if test_script == null:
			failures.append("Unable to load %s" % test_path)
			continue
		var test_case: RefCounted = test_script.new() as RefCounted
		for failure in test_case.run():
			failures.append("%s: %s" % [test_path, failure])

	if failures.is_empty():
		print("PASS: %d test file(s)" % TEST_PATHS.size())
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	print("FAIL: %d failure(s)" % failures.size())
	quit(1)
