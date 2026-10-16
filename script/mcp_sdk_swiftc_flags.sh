#!/usr/bin/env bash
# Builds the vendored MCP SDK (deps/swift-sdk) once per source revision and prints the swiftc
# flags, one per line, that let a script test runner import and link it like the app target does.
set -euo pipefail
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
package="$root/deps/swift-sdk"
revision="$(find "$package/Sources" "$package/Package.swift" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)"
cache="${TMPDIR:-/tmp}/limare-mcp-sdk-$revision"
if [[ ! -f "$cache/debug/MCP.o" ]]; then
  swift build --package-path "$package" --scratch-path "$cache" --product MCP >"$cache.log" 2>&1 \
    || { echo "MCP SDK build failed; see $cache.log" >&2; exit 1; }
fi
printf '%s\n' -I "$cache/debug"
for object in MCP Logging EventSource SystemPackage CSystem; do
  printf '%s\n' "$cache/debug/$object.o"
done
