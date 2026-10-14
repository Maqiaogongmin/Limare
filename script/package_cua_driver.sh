#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
CACHE_DIR="${HOME}/.cache/limare-helpers"

# Pinned upstream version & cryptographic hashes
PINNED_VERSION="0.28.2"
PINNED_BIN_SHA256="9a7731f7e961a57963f0deb132878367fdf7354e7327a4d558fe4a68e4686b81"
PINNED_TARBALL_URL="https://github.com/trycua/cua/releases/download/cua-driver-rs-v0.28.2/cua-driver-rs-0.28.2-darwin-universal.tar.gz"
PINNED_TARBALL_SHA256="e273181b26709c88b1d809474deb3c592b4efae3530b11d76318f1887fc3fbb1"
TARBALL_BIN_SUBPATH="cua-driver-rs-0.28.2-darwin-universal/CuaDriver.app/Contents/MacOS/cua-driver"

mkdir -p "${DIST_DIR}" "${CACHE_DIR}"
OUT_BIN="${DIST_DIR}/cua-driver"

# Candidate sources in order of preference
CANDIDATE_PATHS=(
  "${OUT_BIN}"
  "${CACHE_DIR}/cua-driver-${PINNED_VERSION}"
)

# Optional local installed app cache (can be disabled via DISALLOW_LOCAL_APP=1 for clean checkout testing)
if [[ "${DISALLOW_LOCAL_APP:-0}" != "1" ]]; then
  CANDIDATE_PATHS+=("/Applications/CuaDriver.app/Contents/MacOS/cua-driver")
fi

SRC_BIN=""
for path in "${CANDIDATE_PATHS[@]}"; do
  if [[ -f "$path" && -x "$path" ]]; then
    ACTUAL_SHA256=$(shasum -a 256 "$path" | awk '{print $1}')
    if [[ "$ACTUAL_SHA256" == "$PINNED_BIN_SHA256" ]]; then
      SRC_BIN="$path"
      echo "[package_cua_driver] Found valid pinned binary at ${SRC_BIN}"
      break
    fi
  fi
done

# If no candidate matches, acquire from exact pinned upstream release
if [[ -z "$SRC_BIN" ]]; then
  echo "[package_cua_driver] Pinned cua-driver v${PINNED_VERSION} not found locally."
  echo "[package_cua_driver] Acquiring from exact pinned upstream release: ${PINNED_TARBALL_URL}..."
  
  TMP_DIR=$(mktemp -d -t cua_driver_acquire_XXXXXX)
  trap 'rm -rf "${TMP_DIR}"' EXIT
  
  TAR_DEST="${TMP_DIR}/cua-driver-${PINNED_VERSION}.tar.gz"
  curl -sSL --fail "${PINNED_TARBALL_URL}" -o "${TAR_DEST}"
  
  echo "[package_cua_driver] Verifying downloaded tarball SHA256..."
  DOWNLOAD_TAR_SHA256=$(shasum -a 256 "${TAR_DEST}" | awk '{print $1}')
  if [[ "${DOWNLOAD_TAR_SHA256}" != "${PINNED_TARBALL_SHA256}" ]]; then
    echo "[-] FATAL: Upstream tarball SHA256 mismatch!" >&2
    echo "    Expected: ${PINNED_TARBALL_SHA256}" >&2
    echo "    Actual:   ${DOWNLOAD_TAR_SHA256}" >&2
    exit 1
  fi
  echo "[package_cua_driver] Tarball SHA256 verified successfully (${DOWNLOAD_TAR_SHA256})"
  
  echo "[package_cua_driver] Extracting ${TARBALL_BIN_SUBPATH}..."
  tar -xzf "${TAR_DEST}" -C "${TMP_DIR}" "${TARBALL_BIN_SUBPATH}"
  
  EXTRACTED_BIN="${TMP_DIR}/${TARBALL_BIN_SUBPATH}"
  if [[ ! -f "${EXTRACTED_BIN}" ]]; then
    echo "[-] FATAL: Extracted binary not found at ${EXTRACTED_BIN}" >&2
    exit 1
  fi
  
  echo "[package_cua_driver] Verifying extracted binary SHA256..."
  EXTRACTED_SHA256=$(shasum -a 256 "${EXTRACTED_BIN}" | awk '{print $1}')
  if [[ "${EXTRACTED_SHA256}" != "${PINNED_BIN_SHA256}" ]]; then
    echo "[-] FATAL: Extracted binary SHA256 mismatch!" >&2
    echo "    Expected: ${PINNED_BIN_SHA256}" >&2
    echo "    Actual:   ${EXTRACTED_SHA256}" >&2
    exit 1
  fi
  echo "[package_cua_driver] Binary SHA256 verified successfully (${EXTRACTED_SHA256})"
  
  # Cache verified binary for future clean builds
  cp -p "${EXTRACTED_BIN}" "${CACHE_DIR}/cua-driver-${PINNED_VERSION}"
  chmod +x "${CACHE_DIR}/cua-driver-${PINNED_VERSION}"
  SRC_BIN="${CACHE_DIR}/cua-driver-${PINNED_VERSION}"
fi

# Stage to output path
if [[ "$SRC_BIN" != "$OUT_BIN" ]]; then
  echo "[package_cua_driver] Staging pinned cua-driver binary to ${OUT_BIN}..."
  cp -p "$SRC_BIN" "$OUT_BIN"
fi
chmod +x "$OUT_BIN"

# Embed exact upstream MIT license notice
cat > "${DIST_DIR}/CUA_DRIVER_LICENSE.txt" << 'EOF'
MIT License

Copyright (c) 2025 Cua AI, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

# Explicit Debug / Release signing policy shared with the final embed phase.
"${REPO_ROOT}/script/sign_helper.sh" "$OUT_BIN"

# Verify executable version
VERSION_OUTPUT=$("$OUT_BIN" --version 2>&1 || true)
if [[ "$VERSION_OUTPUT" != *"0.28.2"* ]]; then
  echo "[-] ERROR: Output binary version mismatch! Expected 0.28.2, got: ${VERSION_OUTPUT}" >&2
  exit 1
fi

echo "[package_cua_driver] cua-driver helper verified and packaged successfully at ${OUT_BIN} (${VERSION_OUTPUT})"
