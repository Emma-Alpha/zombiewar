extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")
const TestPathSelection = preload("res://tests/helpers/test_path_selection.gd")

const REGISTERED_PATHS: Array[String] = [
	"res://tests/unit/test_alpha.gd",
	"res://tests/integration/test_beta.gd",
]

func run() -> Array[String]:
	var failures: Array[String] = []
	var all_result: Dictionary = TestPathSelection.select_paths(REGISTERED_PATHS, [])
	_append(failures, Assertions.expect_equal(
		all_result["paths"],
		REGISTERED_PATHS,
		"No requested path keeps the full registered test list"
	))
	var one_result: Dictionary = TestPathSelection.select_paths(
		REGISTERED_PATHS,
		["tests/integration/test_beta.gd"]
	)
	_append(failures, Assertions.expect_true(
		one_result["errors"].is_empty() and
		one_result["paths"] == ["res://tests/integration/test_beta.gd"],
		"A repository-relative path selects exactly one registered test"
	))
	var unknown_result: Dictionary = TestPathSelection.select_paths(
		REGISTERED_PATHS,
		["tests/unit/test_missing.gd"]
	)
	_append(failures, Assertions.expect_true(
		unknown_result["paths"].is_empty() and
		unknown_result["errors"] == [
			"Test path is not registered: res://tests/unit/test_missing.gd"
		],
		"An unknown test path is rejected with a precise error"
	))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
