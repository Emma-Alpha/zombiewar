#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PAGES_PROJECT="${CLOUDFLARE_PAGES_PROJECT:-zombiewar}"
DEPLOY_BRANCH="${CLOUDFLARE_BRANCH:-main}"
# Exported so the inline node helpers below can read them via process.env.
export PAGES_PROJECT DEPLOY_BRANCH
WEB_DIR="$ROOT_DIR/build/web"
PAGES_DIR="$ROOT_DIR/build/cloudflare-pages"
WRANGLER_CONFIG="$ROOT_DIR/wrangler.jsonc"
PREPARE_ONLY=false
VERIFY_ATTEMPTS=5
VERIFY_RETRY_DELAY_SECONDS="${DEPLOY_VERIFY_RETRY_DELAY_SECONDS:-2}"

if [[ "${1:-}" == "--prepare-only" ]]; then
	PREPARE_ONLY=true
elif [[ $# -gt 0 ]]; then
	echo "Usage: $0 [--prepare-only]" >&2
	exit 2
fi

[[ -x "$GODOT_BIN" ]] || {
	echo "Godot executable not found: $GODOT_BIN" >&2
	exit 1
}
command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 1; }
command -v npx >/dev/null 2>&1 || { echo "npx is required" >&2; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "shasum is required" >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "rsync is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
[[ -f "$WRANGLER_CONFIG" ]] || { echo "Missing Wrangler config: $WRANGLER_CONFIG" >&2; exit 1; }

R2_BUCKET="$(node - "$WRANGLER_CONFIG" <<'NODE'
const fs = require("node:fs");

function stripJsonComments(source) {
	let output = "";
	let inString = false;
	let escaped = false;
	let lineComment = false;
	let blockComment = false;
	for (let index = 0; index < source.length; index += 1) {
		const character = source[index];
		const nextCharacter = source[index + 1];
		if (lineComment) {
			if (character === "\n") {
				lineComment = false;
				output += character;
			}
			continue;
		}
		if (blockComment) {
			if (character === "*" && nextCharacter === "/") {
				blockComment = false;
				index += 1;
			} else if (character === "\n") {
				output += character;
			}
			continue;
		}
		if (inString) {
			output += character;
			if (escaped) {
				escaped = false;
			} else if (character === "\\") {
				escaped = true;
			} else if (character === '"') {
				inString = false;
			}
			continue;
		}
		if (character === '"') {
			inString = true;
			output += character;
		} else if (character === "/" && nextCharacter === "/") {
			lineComment = true;
			index += 1;
		} else if (character === "/" && nextCharacter === "*") {
			blockComment = true;
			index += 1;
		} else {
			output += character;
		}
	}
	return output;
}

const configPath = process.argv[2];
try {
	const source = stripJsonComments(fs.readFileSync(configPath, "utf8"))
		.replace(/,\s*([}\]])/g, "$1");
	const config = JSON.parse(source);
	const bindings = Array.isArray(config.r2_buckets)
		? config.r2_buckets.filter((entry) => entry?.binding === "GAME_ASSETS")
		: [];
	if (bindings.length !== 1) {
		throw new Error(`expected exactly one GAME_ASSETS R2 binding, found ${bindings.length}`);
	}
	const bucketName = bindings[0].bucket_name;
	if (typeof bucketName !== "string" || bucketName.trim() === "") {
		throw new Error("GAME_ASSETS bucket_name must be a non-empty string");
	}
	process.stdout.write(bucketName.trim());
} catch (error) {
	console.error(`Invalid Wrangler GAME_ASSETS configuration in ${configPath}: ${error.message}`);
	process.exit(1);
}
NODE
)"

rm -rf "$WEB_DIR" "$PAGES_DIR"
mkdir -p "$WEB_DIR"
"$GODOT_BIN" --headless --path "$ROOT_DIR" --export-release Web "$WEB_DIR/index.html"

WASM_PATH="$WEB_DIR/index.wasm"
[[ -f "$WASM_PATH" ]] || { echo "Missing exported WASM: $WASM_PATH" >&2; exit 1; }
WASM_HASH="$(shasum -a 256 "$WASM_PATH" | awk '{print $1}')"
WASM_KEY="wasm/index-${WASM_HASH}.wasm"

mkdir -p "$PAGES_DIR"
rsync -a --delete --delete-excluded --exclude index.wasm "$WEB_DIR/" "$PAGES_DIR/"
sed "s|__WASM_OBJECT_KEY__|${WASM_KEY}|g" \
	"$ROOT_DIR/tools/cloudflare/pages_worker.template.js" \
	> "$PAGES_DIR/_worker.js"
cp "$ROOT_DIR/tools/cloudflare/_routes.json" "$PAGES_DIR/_routes.json"
cp "$ROOT_DIR/tools/cloudflare/_headers" "$PAGES_DIR/_headers"

if find "$PAGES_DIR" -type f -size +25M -print -quit | grep -q .; then
	echo "Pages package contains a file larger than 25 MiB" >&2
	exit 1
fi

node --check "$PAGES_DIR/_worker.js"

if $PREPARE_ONLY; then
	echo "Prepared Pages package for $WASM_KEY"
	exit 0
fi

cd "$ROOT_DIR"
if ! npx --yes wrangler r2 bucket info "$R2_BUCKET" --json >/dev/null 2>&1; then
	npx --yes wrangler r2 bucket create "$R2_BUCKET"
fi

# The engine wasm is ~36 MB. We deliberately serve it UNCOMPRESSED: Cloudflare
# Pages' edge compression (Brotli and gzip alike) corrupts this large R2-backed
# binary response, so the Worker marks it application/octet-stream and the edge
# passes it through untouched. The wire cost is the full ~36 MB, but correctness
# comes first; revisit compression if Cloudflare fixes the edge path.

# `r2 object put` required --remote under wrangler 3 (otherwise it targets a
# local emulated bucket); wrangler 4 removed the flag and always goes remote.
R2_REMOTE_FLAG=()
if npx --yes wrangler r2 object put --help 2>&1 | grep -q -- "--remote"; then
	R2_REMOTE_FLAG=(--remote)
fi

npx --yes wrangler r2 object put "$R2_BUCKET/$WASM_KEY" \
	--file "$WASM_PATH" \
	--content-type application/wasm \
	"${R2_REMOTE_FLAG[@]}"

# The production alias follows the project's actual pages.dev host, which may
# carry a `-<hash>` suffix when the bare subdomain was taken. Resolve it from the
# project rather than assuming `<project>.pages.dev`.
PRODUCTION_URL="$(
	npx --yes wrangler pages project list 2>/dev/null \
		| node -e '
			let out = "";
			process.stdin.setEncoding("utf8");
			process.stdin.on("data", (c) => { out += c; });
			process.stdin.on("end", () => {
				const project = process.env.PAGES_PROJECT.toLowerCase();
				const re = new RegExp(`(${project}(?:-[a-z0-9]+)?\\.pages\\.dev)`, "i");
				const m = out.match(re);
				process.stdout.write(m ? `https://${m[1].toLowerCase()}` : "");
			});
		'
)"
if [[ -z "$PRODUCTION_URL" ]]; then
	PRODUCTION_URL="https://${PAGES_PROJECT}.pages.dev"
fi
DEPLOY_OUTPUT="$(
	npx --yes wrangler pages deploy "$PAGES_DIR" \
		--project-name "$PAGES_PROJECT" \
		--branch "$DEPLOY_BRANCH" 2>&1
)"
printf '%s\n' "$DEPLOY_OUTPUT"

if ! DEPLOYMENT_URL="$(
	printf '%s\n' "$DEPLOY_OUTPUT" | PAGES_PROJECT="$PAGES_PROJECT" DEPLOY_BRANCH="$DEPLOY_BRANCH" node -e '
		let output = "";
		process.stdin.setEncoding("utf8");
		process.stdin.on("data", (chunk) => { output += chunk; });
		process.stdin.on("end", () => {
			const resultPattern = /^\s*(?:✨\s*)?Deployment complete!\s+Take a peek over at\s+(https:\/\/\S+)\s*$/;
			const resultUrls = output
				.split(/\r?\n/)
				.map((line) => line.match(resultPattern)?.[1])
				.filter(Boolean);
			if (resultUrls.length !== 1) {
				console.error("Expected exactly one Pages deployment-complete URL");
				process.exit(1);
			}
			try {
				const deploymentUrl = new URL(resultUrls[0]);
				const project = process.env.PAGES_PROJECT.toLowerCase();
				const branch = process.env.DEPLOY_BRANCH.toLowerCase();
				const hostname = deploymentUrl.hostname;
				// Cloudflare gives a project either `<project>.pages.dev` or, when that
				// subdomain is taken, `<project>-<hash>.pages.dev`. A deployment URL is
				// `<label>.<project-host>.pages.dev`, so accept any host whose pages.dev
				// subdomain starts with the project name.
				const hostPattern = new RegExp(
					`^([a-z0-9-]+)\\.${project.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?:-[a-z0-9]+)?\\.pages\\.dev$`,
				);
				const match = hostname.match(hostPattern);
				const deploymentLabel = match?.[1] ?? "";
				if (
					deploymentUrl.protocol !== "https:"
					|| deploymentUrl.username !== ""
					|| deploymentUrl.password !== ""
					|| deploymentUrl.port !== ""
					|| deploymentUrl.pathname !== "/"
					|| deploymentUrl.search !== ""
					|| deploymentUrl.hash !== ""
					|| deploymentLabel === ""
					|| deploymentLabel === branch
				) {
					throw new Error("deployment URL is not a deployment-specific URL for the current project");
				}
				process.stdout.write(deploymentUrl.origin);
			} catch (error) {
				console.error(`Invalid Pages deployment URL: ${error.message}`);
				process.exit(1);
			}
		});
	'
)"; then
	echo "Unable to determine the deployment-specific Pages URL" >&2
	exit 1
fi

VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT

header_matches() {
	local headers_path="$1"
	local header_name="$2"
	local expected_value="$3"
	tr -d '\r' < "$headers_path" \
		| grep -Eiq "^${header_name}:[[:space:]]*${expected_value}[[:space:]]*$"
}

validate_common_headers() {
	local headers_path="$1"
	local description="$2"
	local expected_cache_control="$3"
	if ! tr -d '\r' < "$headers_path" | grep -Eiq '^HTTP/(1\.[01]|2|3)[[:space:]]+200([[:space:]]|$)'; then
		echo "$description did not return HTTP 200" >&2
		return 1
	fi
	if ! header_matches "$headers_path" "Cache-Control" "$expected_cache_control"; then
		echo "$description has an invalid Cache-Control header" >&2
		return 1
	fi
	if ! header_matches "$headers_path" "Cross-Origin-Opener-Policy" "same-origin"; then
		echo "$description has an invalid Cross-Origin-Opener-Policy header" >&2
		return 1
	fi
	if ! header_matches "$headers_path" "Cross-Origin-Embedder-Policy" "require-corp"; then
		echo "$description has an invalid Cross-Origin-Embedder-Policy header" >&2
		return 1
	fi
}

# The HTML shell stays no-store so players always pick up the newest deploy,
# while the content-hashed wasm is safe to cache immutably.
HTML_CACHE_CONTROL="no-store, no-cache, must-revalidate, max-age=0"
WASM_CACHE_CONTROL="public, max-age=31536000, immutable"

validate_wasm_headers() {
	local headers_path="$1"
	local description="$2"
	validate_common_headers "$headers_path" "$description" "$WASM_CACHE_CONTROL" || return 1
	# octet-stream, not application/wasm: see the Worker for why the payload must
	# stay incompressible at the Pages edge.
	if ! header_matches "$headers_path" "Content-Type" "application/octet-stream"; then
		echo "$description has an invalid Content-Type header" >&2
		return 1
	fi
	# The edge must not compress this response; any Content-Encoding means the
	# corruption we are avoiding has crept back in.
	if tr -d '\r' < "$headers_path" | grep -Eiq '^Content-Encoding:'; then
		echo "$description unexpectedly carried a Content-Encoding (edge compression)" >&2
		return 1
	fi
}

verify_deployment_once() {
	local base_url="$1"
	local root_headers="$VERIFY_DIR/root.headers"
	local wasm_head_headers="$VERIFY_DIR/wasm-head.headers"
	local wasm_get_headers="$VERIFY_DIR/wasm-get.headers"
	local downloaded_wasm="$VERIFY_DIR/index.wasm"

	if ! curl --fail --silent --show-error --head "$base_url/" > "$root_headers"; then
		return 1
	fi
	validate_common_headers "$root_headers" "$base_url/" "$HTML_CACHE_CONTROL" || return 1

	if ! curl --fail --silent --show-error --head "$base_url/index.wasm" > "$wasm_head_headers"; then
		return 1
	fi
	validate_wasm_headers "$wasm_head_headers" "$base_url/index.wasm HEAD" || return 1

	# Offer every encoding; the correct behaviour is that the edge serves the raw,
	# unencoded wasm either way, so a plain GET is enough to validate integrity.
	if ! curl --fail --silent --show-error \
		--dump-header "$wasm_get_headers" \
		--output "$downloaded_wasm" \
		"$base_url/index.wasm"; then
		return 1
	fi
	validate_wasm_headers "$wasm_get_headers" "$base_url/index.wasm GET" || return 1

	local downloaded_hash
	downloaded_hash="$(shasum -a 256 "$downloaded_wasm" | awk '{print $1}')"
	if [[ "$downloaded_hash" != "$WASM_HASH" ]]; then
		echo "$base_url/index.wasm SHA-256 mismatch: expected $WASM_HASH, got $downloaded_hash" >&2
		return 1
	fi
}

verify_deployment() {
	local base_url="$1"
	local description="$2"
	local attempt
	for ((attempt = 1; attempt <= VERIFY_ATTEMPTS; attempt += 1)); do
		if verify_deployment_once "$base_url"; then
			echo "Verified $description: $base_url"
			return 0
		fi
		if ((attempt < VERIFY_ATTEMPTS)); then
			echo "Verification attempt $attempt/$VERIFY_ATTEMPTS failed for $base_url; retrying" >&2
			sleep "$VERIFY_RETRY_DELAY_SECONDS"
		fi
	done
	echo "Verification failed after $VERIFY_ATTEMPTS attempts for $base_url" >&2
	return 1
}

verify_deployment "$DEPLOYMENT_URL" "deployment URL"
if [[ "$DEPLOY_BRANCH" == "main" ]]; then
	verify_deployment "$PRODUCTION_URL" "production alias"
fi

echo "Deployment complete: $DEPLOYMENT_URL"
