#!/usr/bin/env bash
# Deploys the Godot Web export to Vercel.
#
# The game is a static bundle, so Vercel hosts it as plain files. Two things
# this script exists to get right:
#
#   1. `vercel.json` has to sit *inside* the deployed directory, and that
#      directory is build/ which is gitignored. The source of truth therefore
#      lives at tools/vercel/vercel.json and is copied in at deploy time.
#   2. The default *.vercel.app hostname is DNS-poisoned on mainland Chinese
#      networks -- it resolves into Meta's 31.13.x.x range and times out. The
#      custom domain resolves to Vercel's own 76.76.21.21 and works. Never hand
#      players a *.vercel.app URL.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build/web"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJECT="${VERCEL_PROJECT:-zombiewar}"
DOMAIN="${VERCEL_DOMAIN:-zombiewar.lumentechnologies.stream}"

if [[ "${1:-}" != "--skip-export" ]]; then
  echo "==> exporting Web build"
  rm -rf "${BUILD_DIR}"
  mkdir -p "${BUILD_DIR}"
  "${GODOT_BIN}" --headless --path "${REPO_ROOT}" \
    --export-release Web "${BUILD_DIR}/index.html"
fi

if [[ ! -f "${BUILD_DIR}/index.wasm" ]]; then
  echo "!! ${BUILD_DIR}/index.wasm missing; export failed" >&2
  exit 1
fi

echo "==> staging vercel.json"
python3 - "$REPO_ROOT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
config = json.loads((root / "tools/vercel/vercel.json").read_text(encoding="utf-8"))
# Strip the explanatory `comment` keys; Vercel rejects unknown header fields.
for rule in config["headers"]:
    rule["headers"] = [
        {k: v for k, v in header.items() if k != "comment"} for header in rule["headers"]
    ]
(root / "build/web/vercel.json").write_text(json.dumps(config, indent=2), encoding="utf-8")
PY

echo "==> deploying to Vercel (project ${PROJECT})"
cd "${BUILD_DIR}"
npx vercel deploy --prod --yes --name "${PROJECT}"

echo "==> verifying ${DOMAIN}"
for attempt in 1 2 3 4 5 6; do
  code=$(curl -s -m 30 -o /dev/null -w "%{http_code}" "https://${DOMAIN}/" || true)
  wasm=$(curl -s -m 120 -o /dev/null -w "%{http_code}" "https://${DOMAIN}/index.wasm" || true)
  echo "    attempt ${attempt}: index=${code} wasm=${wasm}"
  if [[ "${code}" == "200" && "${wasm}" == "200" ]]; then
    echo "==> live at https://${DOMAIN}"
    exit 0
  fi
  sleep 15
done

echo "!! ${DOMAIN} did not serve the build" >&2
exit 1
