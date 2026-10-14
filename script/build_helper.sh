#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[build_helper] Packaging cua-driver helper..."
"${REPO_ROOT}/script/package_cua_driver.sh"

echo "[build_helper] Packaging cloudflared helper..."
"${REPO_ROOT}/script/package_cloudflared.sh"

echo "[build_helper] Helpers packaged at ${REPO_ROOT}/dist"
