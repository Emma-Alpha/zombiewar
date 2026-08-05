#!/usr/bin/env bash

set -euo pipefail

zombiewar_repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
zombiewar_godot_bin="${ZOMBIEWAR_GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
zombiewar_test_output="$(mktemp "${TMPDIR:-/tmp}/zombiewar-tests.XXXXXX")"

cleanup_test_output() {
	rm -f -- "$zombiewar_test_output"
}
trap cleanup_test_output EXIT

cd "$zombiewar_repo_root"
set +e
"$zombiewar_godot_bin" \
	--headless \
	--path . \
	--script tests/test_runner.gd 2>&1 | tee "$zombiewar_test_output"
zombiewar_runner_status=${PIPESTATUS[0]}
set -e

if (( zombiewar_runner_status != 0 )); then
	exit "$zombiewar_runner_status"
fi

if LC_ALL=C grep -Eq \
	'SCRIPT ERROR:|Parse Error:|(^|[[:space:]])ERROR:' \
	"$zombiewar_test_output"; then
	printf '%s\n' "FAIL: Godot emitted a script, parse, or runtime error." >&2
	exit 1
fi
