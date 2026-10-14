#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_CONTENTS="${BUILT_PRODUCTS_DIR:?}/${FULL_PRODUCT_NAME:?}/Contents"

"${REPO_ROOT}/script/build_helper.sh"
mkdir -p "${APP_CONTENTS}/Helpers" "${APP_CONTENTS}/Resources"
for HELPER in cua-driver cloudflared; do
  cp "${REPO_ROOT}/dist/${HELPER}" "${APP_CONTENTS}/Helpers/${HELPER}"
  "${REPO_ROOT}/script/sign_helper.sh" "${APP_CONTENTS}/Helpers/${HELPER}"
done
cp "${REPO_ROOT}/dist/CUA_DRIVER_LICENSE.txt" "${APP_CONTENTS}/Resources/"
cp "${REPO_ROOT}/dist/CLOUDFLARED_LICENSE.txt" "${APP_CONTENTS}/Resources/"
rsync -a --delete "${REPO_ROOT}/src/macos/RemoteWeb/" "${APP_CONTENTS}/Resources/RemoteWeb/"
