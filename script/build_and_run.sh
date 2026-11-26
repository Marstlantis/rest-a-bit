#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CONFIGURATION=debug
if [[ "${1:-}" == --release ]]; then
  CONFIGURATION=release
  shift
fi
MODE="${1:-run}"
case "$MODE" in
  run|--build|--verify|--debug|--logs|--telemetry) ;;
  *) echo "Usage: $0 [--release] [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
if [[ $# -gt 0 ]]; then shift; fi

CACHE="$ROOT/.build/cache"
mkdir -p "$CACHE/module" "$CACHE/config" "$CACHE/security" "$ROOT/dist"
export CLANG_MODULE_CACHE_PATH="$CACHE/module"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE/module"
PACKAGE_ARGS=(--configuration "$CONFIGURATION" --cache-path "$CACHE" --config-path "$CACHE/config" --security-path "$CACHE/security" --disable-automatic-resolution)

swift build "${PACKAGE_ARGS[@]}"
BUILD_DIR="$(swift build "${PACKAGE_ARGS[@]}" --show-bin-path)"
PLIST="Support/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")"
BUNDLE="$ROOT/dist/$APP_NAME.app"
BINARY="$BUNDLE/Contents/MacOS/$EXECUTABLE"
STAGING="$(mktemp -d "$ROOT/dist/.restabit-build.XXXXXX")"
trap 'rmdir "$STAGING" 2>/dev/null || true' EXIT
NEW_BUNDLE="$STAGING/$APP_NAME.app"
mkdir -p "$NEW_BUNDLE/Contents/MacOS" "$NEW_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$EXECUTABLE" "$NEW_BUNDLE/Contents/MacOS/$EXECUTABLE"
cp "$PLIST" "$NEW_BUNDLE/Contents/Info.plist"
cp -R Support/zh-Hans.lproj Support/zh-Hant.lproj "$NEW_BUNDLE/Contents/Resources/"
cp -R "$BUILD_DIR/${EXECUTABLE}_${EXECUTABLE}.bundle" "$NEW_BUNDLE/Contents/Resources/"
cp "Support/$EXECUTABLE.icns" "$NEW_BUNDLE/Contents/Resources/"
codesign --force --sign - "$NEW_BUNDLE"
codesign --verify --strict "$NEW_BUNDLE"

if [[ -e "$BUNDLE" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUNDLE/Contents/Info.plist")"
    if [[ -L "$BUNDLE" || "$existing_id" != "$IDENTIFIER" ]]; then
        echo "Unexpected app at $BUNDLE" >&2
        exit 1
    fi
    if [[ "$MODE" != --build ]]; then
        for pid in $(pgrep -x "$EXECUTABLE" || true); do
            if [[ "$(ps -p "$pid" -o comm=)" == "$BINARY" ]]; then
                kill "$pid"
            fi
        done
    fi
    mv "$BUNDLE" "$STAGING/Previous.app"
fi
if ! mv "$NEW_BUNDLE" "$BUNDLE"; then
    if [[ -d "$STAGING/Previous.app" ]]; then mv "$STAGING/Previous.app" "$BUNDLE"; fi
    exit 1
fi
if [[ -d "$STAGING/Previous.app" ]]; then rm -r -- "$STAGING/Previous.app"; fi

case "$MODE" in
  --build) ;;
  --debug) lldb -- "$BINARY" "$@" ;;
  --logs|--telemetry)
    open -g -n "$BUNDLE" --args "$@"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$IDENTIFIER\""
    ;;
  --verify)
    open -g -n "$BUNDLE" --args "$@"
    sleep 1
    for pid in $(pgrep -x "$EXECUTABLE" || true); do
        if [[ "$(ps -p "$pid" -o comm=)" == "$BINARY" ]]; then
            echo "$APP_NAME running (PID $pid)"
            exit 0
        fi
    done
    echo "$APP_NAME did not stay running" >&2
    exit 1
    ;;
  run) open -g -n "$BUNDLE" --args "$@" ;;
esac
