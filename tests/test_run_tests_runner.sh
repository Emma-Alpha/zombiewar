#!/usr/bin/env bash

set -euo pipefail

zombiewar_runner_test_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
zombiewar_runner_test_temp="$(mktemp -d "${TMPDIR:-/tmp}/zombiewar-runner-test.XXXXXX")"

cleanup_runner_test_temp() {
	rm -rf -- "$zombiewar_runner_test_temp"
}
trap cleanup_runner_test_temp EXIT

mkdir -p "$zombiewar_runner_test_temp/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit "${FAKE_GODOT_STATUS}"' \
	> "$zombiewar_runner_test_temp/fake_godot"
printf '%s\n' '#!/usr/bin/env bash' 'while IFS= read -r _line; do :; done' \
	'exit "${FAKE_TEE_STATUS}"' > "$zombiewar_runner_test_temp/bin/tee"
chmod +x "$zombiewar_runner_test_temp/fake_godot" "$zombiewar_runner_test_temp/bin/tee"

run_runner() {
	set +e
	PATH="$zombiewar_runner_test_temp/bin:$PATH" \
		ZOMBIEWAR_GODOT_BIN="$zombiewar_runner_test_temp/fake_godot" \
		FAKE_GODOT_STATUS="$1" \
		FAKE_TEE_STATUS="$2" \
		"$zombiewar_runner_test_root/tests/run_tests.sh" >/dev/null 2>&1
	local status=$?
	set -e
	printf '%s\n' "$status"
}

tee_failure_status="$(run_runner 0 9)"
if [[ "$tee_failure_status" != "9" ]]; then
	printf 'Expected tee failure status 9, got %s\n' "$tee_failure_status" >&2
	exit 1
fi

godot_failure_status="$(run_runner 23 9)"
if [[ "$godot_failure_status" != "23" ]]; then
	printf 'Expected Godot failure status 23, got %s\n' "$godot_failure_status" >&2
	exit 1
fi

printf '%s\n' 'PASS: strict test runner preserves Godot failure and rejects tee failure'
