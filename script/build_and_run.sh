#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
SCHEME_NAME="Limare"
APP_NAME="Limare"
BUNDLE_ID="app.limare.Limare"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/src/macos/Limare.xcodeproj"
DERIVED_DATA_PATH="$ROOT_DIR/.build/macos-derived-data"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

BUILD_SIGNING_ARGS=(CODE_SIGNING_ALLOWED=YES)
if [[ "$MODE" == "--unsigned" || "$MODE" == "unsigned" ]]; then
  BUILD_SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -onlyUsePackageVersionsFromResolvedFile \
  "${BUILD_SIGNING_ARGS[@]}" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run|--unsigned|unsigned)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.1
    done
    echo "$APP_NAME did not remain running after launch" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--unsigned|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
