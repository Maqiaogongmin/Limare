#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/limare-shell-containment.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT
sources=()
while IFS= read -r file; do
  if [[ "$(basename "$file")" != "LimareApp.swift" ]]; then
    sources+=("$file")
  fi
done < <(bash "$ROOT_DIR/script/app_sources.sh" "$ROOT_DIR")
xcrun swiftc -parse-as-library "${sources[@]}" "$ROOT_DIR/script/ShellLifecycleContainmentRegressionTests.swift" -o "$TEST_TMP/shell-containment-tests"
"$TEST_TMP/shell-containment-tests"
