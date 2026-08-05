extends RefCounted

const Assertions = preload("res://tests/helpers/assertions.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var output: Array = []
	var node_test := ProjectSettings.globalize_path("res://tests/integration/cloudflare_r2_worker.test.mjs")
	var exit_code := OS.execute("node", ["--test", node_test], output, true)
	_append(failures, Assertions.expect_equal(exit_code, 0, "Cloudflare Worker Node tests: %s" % "\n".join(output)))
	for path in [
		"res://wrangler.jsonc",
		"res://tools/cloudflare/pages_worker.template.js",
		"res://tools/cloudflare/_routes.json",
		"res://tools/cloudflare/_headers",
	]:
		_append(failures, Assertions.expect_true(FileAccess.file_exists(path), "Missing Cloudflare deployment file: %s" % path))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
