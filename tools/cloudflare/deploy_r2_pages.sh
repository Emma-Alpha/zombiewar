#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PAGES_PROJECT="${CLOUDFLARE_PAGES_PROJECT:-zombiewar}"
R2_BUCKET="zombiewar-assets"
DEPLOY_BRANCH="${CLOUDFLARE_BRANCH:-main}"
WEB_DIR="$ROOT_DIR/build/web"
PAGES_DIR="$ROOT_DIR/build/cloudflare-pages"
PREPARE_ONLY=false

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

mkdir -p "$WEB_DIR"
"$GODOT_BIN" --headless --path "$ROOT_DIR" --export-release Web "$WEB_DIR/index.html"

WASM_PATH="$WEB_DIR/index.wasm"
[[ -f "$WASM_PATH" ]] || { echo "Missing exported WASM: $WASM_PATH" >&2; exit 1; }
WASM_HASH="$(shasum -a 256 "$WASM_PATH" | awk '{print $1}')"
WASM_KEY="wasm/index-${WASM_HASH}.wasm"

mkdir -p "$PAGES_DIR"
rsync -a --delete --exclude index.wasm "$WEB_DIR/" "$PAGES_DIR/"
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

npx --yes wrangler r2 object put "$R2_BUCKET/$WASM_KEY" \
	--file "$WASM_PATH" \
	--content-type application/wasm \
	--cache-control "no-store, no-cache, must-revalidate, max-age=0" \
	--remote

npx --yes wrangler pages deploy "$PAGES_DIR" \
	--project-name "$PAGES_PROJECT" \
	--branch "$DEPLOY_BRANCH"

PRODUCTION_URL="https://${PAGES_PROJECT}.pages.dev"
curl --fail --silent --show-error --head "$PRODUCTION_URL/"
curl --fail --silent --show-error --head "$PRODUCTION_URL/index.wasm"
echo "Deployment complete: $PRODUCTION_URL"
