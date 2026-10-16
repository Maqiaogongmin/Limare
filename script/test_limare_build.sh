#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_tmp="$(mktemp -d "${TMPDIR:-/tmp}/limare-build.XXXXXX")"
trap 'rm -rf "$task_tmp"' EXIT
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(bash "$task_root/script/app_sources.sh" "$task_root")
xcrun swiftc -DDEBUG -j8 -parse-as-library "${sources[@]}" "$task_root/script/LimareBuildTests.swift" -o "$task_tmp/build-tests"
"$task_tmp/build-tests"
