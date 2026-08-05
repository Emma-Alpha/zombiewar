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
	var deploy_script := ProjectSettings.globalize_path("res://tools/cloudflare/deploy_r2_pages.sh")
	_append(failures, Assertions.expect_true(FileAccess.file_exists(deploy_script), "Missing R2 Pages deployment script"))
	if FileAccess.file_exists(deploy_script):
		var prepare_output: Array = []
		var prepare_exit := OS.execute("bash", [deploy_script, "--prepare-only"], prepare_output, true)
		_append(failures, Assertions.expect_equal(prepare_exit, 0, "R2 Pages prepare-only: %s" % "\n".join(prepare_output)))
		_append(failures, Assertions.expect_true(
			not FileAccess.file_exists("res://build/cloudflare-pages/index.wasm"),
			"Pages package must exclude index.wasm"
		))
		var wasm_path := ProjectSettings.globalize_path("res://build/web/index.wasm")
		var hash_output: Array = []
		var hash_exit := OS.execute("shasum", ["-a", "256", wasm_path], hash_output, true)
		_append(failures, Assertions.expect_equal(hash_exit, 0, "Calculate WASM SHA-256"))
		if hash_exit == 0 and not hash_output.is_empty():
			var wasm_hash := String(hash_output[0]).get_slice(" ", 0)
			var generated_worker := FileAccess.get_file_as_string("res://build/cloudflare-pages/_worker.js")
			_append(failures, Assertions.expect_true(
				generated_worker.contains("wasm/index-%s.wasm" % wasm_hash),
				"Generated Worker references the exported WASM hash"
			))
	return failures

func _append(failures: Array[String], failure: String) -> void:
	if not failure.is_empty():
		failures.append(failure)
