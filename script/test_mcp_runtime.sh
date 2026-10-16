#!/usr/bin/env bash
# Real child processes and sockets against the vendored SDK runtime (synthetic fixtures only).
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_tmp="$(mktemp -d "${TMPDIR:-/tmp}/limare-mcp-runtime.XXXXXX")"
trap 'rm -rf "$task_tmp"' EXIT
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(bash "$task_root/script/app_sources.sh" "$task_root")
sdk_flags=()
while IFS= read -r flag; do sdk_flags+=("$flag"); done < <(bash "$task_root/script/mcp_sdk_swiftc_flags.sh" "$task_root")
xcrun swiftc -DDEBUG -j8 -parse-as-library "${sdk_flags[@]}" "${sources[@]}" \
  "$task_root/script/MCPRuntimeTests.swift" -o "$task_tmp/runtime-tests"
"$task_tmp/runtime-tests" "$task_tmp/run" "$task_root/script/mcp_runtime_fixture.py"
