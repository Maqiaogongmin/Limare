#!/usr/bin/env bash
# Puts the pinned cloudflared (Cloudflare Tunnel connector) into dist/ for the app bundle:
# dist/cloudflared and dist/CLOUDFLARED_LICENSE.txt. The release tarball is verified against its
# pinned SHA256 (as published by the GitHub release); a cached copy is reused when it verifies.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
CACHE_DIR="${HOME}/.cache/limare-helpers"

PINNED_VERSION="2026.10.0"
PINNED_TARBALL_URL="https://github.com/cloudflare/cloudflared/releases/download/${PINNED_VERSION}/cloudflared-darwin-arm64.tgz"
PINNED_TARBALL_SHA256="a2f79ff7b9420aa537d74af239f376da170bbabeb529aec416002adac6a72e70"
PINNED_LICENSE_URL="https://raw.githubusercontent.com/cloudflare/cloudflared/${PINNED_VERSION}/LICENSE"

mkdir -p "${DIST_DIR}" "${CACHE_DIR}"
TARBALL="${CACHE_DIR}/cloudflared-${PINNED_VERSION}-darwin-arm64.tgz"
LICENSE="${CACHE_DIR}/cloudflared-${PINNED_VERSION}-LICENSE"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ ! -f "${TARBALL}" || "$(sha256 "${TARBALL}")" != "${PINNED_TARBALL_SHA256}" ]]; then
  echo "[package_cloudflared] Downloading cloudflared ${PINNED_VERSION}..."
  TMP="$(mktemp "${CACHE_DIR}/cloudflared.XXXXXX")"
  curl -sSL --fail "${PINNED_TARBALL_URL}" -o "${TMP}"
  ACTUAL="$(sha256 "${TMP}")"
  if [[ "${ACTUAL}" != "${PINNED_TARBALL_SHA256}" ]]; then
    rm -f "${TMP}"
    echo "[-] FATAL: cloudflared tarball SHA256 mismatch (expected ${PINNED_TARBALL_SHA256}, got ${ACTUAL})" >&2
    exit 1
  fi
  mv "${TMP}" "${TARBALL}"
fi
echo "[package_cloudflared] Tarball SHA256 verified (${PINNED_TARBALL_SHA256})"

if [[ ! -s "${LICENSE}" ]]; then
  curl -sSL --fail "${PINNED_LICENSE_URL}" -o "${LICENSE}"
fi

EXTRACT="$(mktemp -d)"
trap 'rm -rf "${EXTRACT}"' EXIT
tar -xzf "${TARBALL}" -C "${EXTRACT}"
[[ -x "${EXTRACT}/cloudflared" ]] || { echo "[-] FATAL: no cloudflared binary in the tarball" >&2; exit 1; }
cp "${EXTRACT}/cloudflared" "${DIST_DIR}/cloudflared"
chmod 755 "${DIST_DIR}/cloudflared"
cp "${LICENSE}" "${DIST_DIR}/CLOUDFLARED_LICENSE.txt"
echo "[package_cloudflared] dist/cloudflared ${PINNED_VERSION} ready ($(sha256 "${DIST_DIR}/cloudflared"))"
