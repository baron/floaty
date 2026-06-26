#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="FloatyApp"
PROJECT="FloatyApp/FloatyApp.xcodeproj"
SCHEME="FloatyApp"
DERIVED_DATA="build/FloatyAppDerivedData"
BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
BINARY="$BUNDLE/Contents/MacOS/$APP_NAME"
BUNDLE_ID="dev.floaty.widget"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

open_app() {
  /usr/bin/open -n "$BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$BINARY"
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
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
