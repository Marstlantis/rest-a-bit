#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DIR="$(mktemp -d "$ROOT/.build/ui-probe.XXXXXX")"
mkdir -p "$DIR/Fixture.app/Contents/MacOS" "$DIR/Fixture.app/Contents/Resources" "$ROOT/.build/cache/module"
cp "$ROOT/Support/RestABit.icns" "$DIR/Fixture.app/Contents/Resources/Fixture.icns"
CACHE="$ROOT/.build/cache/module"
CLANG_MODULE_CACHE_PATH="$CACHE" swiftc -parse-as-library -module-cache-path "$CACHE" script/FocusFixture.swift     -o "$DIR/Fixture.app/Contents/MacOS/Fixture"
FIXTURE_ID="local.restabit.fixture.$(uuidgen | tr '[:upper:]' '[:lower:]')"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $FIXTURE_ID"     -c 'Add :CFBundleExecutable string Fixture' -c 'Add :CFBundlePackageType string APPL'     -c 'Add :CFBundleName string Rest a Bit Fixture' -c 'Add :CFBundleIconFile string Fixture' "$DIR/Fixture.app/Contents/Info.plist" >/dev/null
codesign --force --sign - "$DIR/Fixture.app"
cleanup_fixture() {
    local process
    for process in $(pgrep -x Fixture || true); do
        if [[ "$(ps -p "$process" -o comm=)" == "$DIR/Fixture.app/Contents/MacOS/Fixture" ]]; then
            kill "$process" 2>/dev/null || true
        fi
    done
}
trap cleanup_fixture EXIT
open -n "$DIR/Fixture.app" --args "$DIR"
for _ in {1..50}; do
    [[ ! -s "$DIR/fixture-ready.txt" ]] || break
    sleep 0.2
done
if [[ ! -s "$DIR/fixture-ready.txt" ]]; then
    echo "Fixture did not become frontmost. Probe directory: $DIR" >&2
    exit 1
fi
PID="$(cat "$DIR/fixture-ready.txt")"
open -g -n "$ROOT/dist/Rest a Bit.app" --args --ui-probe "$DIR" "$PID" "$@"
for _ in {1..350}; do
    [[ ! -s "$DIR/result.txt" ]] || break
    sleep 0.2
done
echo "Probe directory: $DIR"
if [[ ! -s "$DIR/result.txt" ]]; then
    echo "Rest a Bit UI probe did not finish." >&2
    exit 1
fi
cat "$DIR/result.txt"
rg -q '^Menu and application identity match: true' "$DIR/result.txt"
rg -q '^Settings title matches: true' "$DIR/result.txt"
rg -q '^Synthetic previous settings migrate and persist: true$' "$DIR/result.txt"
rg -q '^Forward direction sprite sets loaded: true$' "$DIR/result.txt"
rg -q '^Live language english updated: true$' "$DIR/result.txt"
rg -q '^Live language chinese updated: true$' "$DIR/result.txt"
[[ "$(rg -c 'captured [0-9]+ stage frames and card=true, kept editor frontmost=true' "$DIR/result.txt")" == 8 ]]
[[ "$(rg -c 'arrived at the center and kept animation click-through: true' "$DIR/result.txt")" == 8 ]]
[[ "$(rg -c 'slows down before stopping: true' "$DIR/result.txt")" == 8 ]]
[[ "$(rg -c 'keeps forward heading: true' "$DIR/result.txt")" == 8 ]]
[[ "$(rg -c 'cue fits its own content: true' "$DIR/result.txt")" == 8 ]]
rg -q '^Combined English cue fits beside the fox: true$' "$DIR/result.txt"
rg -q '^Excluded app appears after sheet closes without reopening settings: true$' "$DIR/result.txt"
rg -q '^Native full-screen pause, toggle, and exit verified: true$' "$DIR/result.txt"
rg -q '^Automatic reminder held for the excluded foreground app: true$' "$DIR/result.txt"
rg -q '^Excluded icon and nested helper matching verified: true$' "$DIR/result.txt"
rg -q '^Scheduled edge reminder skips overlapping blink: true$' "$DIR/result.txt"
rg -q '^Blink stage is centered and click-through: true$' "$DIR/result.txt"
rg -q '^Blink captured 100 frames and kept editor frontmost: true$' "$DIR/result.txt"
rg -q '^Blink closed on its own: true$' "$DIR/result.txt"
rg -q '^Reduced-motion blink rendered: true$' "$DIR/result.txt"
rg -q '^Blink style rise rendered: true$' "$DIR/result.txt"
rg -q '^Blink style sway rendered: true$' "$DIR/result.txt"
rg -q '^Rest illustration hills loaded: true$' "$DIR/result.txt"
rg -q '^Rest illustration shore rendered: true$' "$DIR/result.txt"
rg -q '^Rest illustration grove rendered: true$' "$DIR/result.txt"
rg -q '^Dark illustration and callout rendered: true$' "$DIR/result.txt"
rg -q '^Login item registration states verified without changing login items: true$' "$DIR/result.txt"
rg -q '^Water scene is centered and leaves focus on the editor: true$' "$DIR/result.txt"
rg -q '^Water cue fits its complete localized text: true$' "$DIR/result.txt"
rg -q '^Status icon hover does not show the app name: true$' "$DIR/result.txt"
rg -q '^Native status hover countdown, localization, pause and menu dismissal: true$' "$DIR/result.txt"
rg -q '^Optional menu-bar progress, pause, snooze and static fallback verified: true$' "$DIR/result.txt"
rg -q '^Enabled menu-bar progress settings rendered in dark mode: true$' "$DIR/result.txt"
rg -q '^Closed settings rebuilds at the same position: true$' "$DIR/result.txt"
rg -q '^English standing break rendered: true$' "$DIR/result.txt"
rg -q '^Rest covers the screen above the menu bar: true$' "$DIR/result.txt"
rg -q '^Rest countdown decreased with the running deadline: true' "$DIR/result.txt"
rg -q '^Rest panel became key: true$' "$DIR/result.txt"
rg -q '^Rest rendered: true$' "$DIR/result.txt"
rg -q '^Rest closed on Escape: true$' "$DIR/result.txt"
rg -q '^Synthetic editor frontmost after Escape: true$' "$DIR/result.txt"
rg -q '^Rest closed on its own and returned to editor: true$' "$DIR/result.txt"
rg -q '^Settings rendered: true$' "$DIR/result.txt"
[[ -s "$DIR/editor-return.png" ]]
typed="$(cat "$DIR/fixture-typed.txt")"
echo "Synthetic editor received $typed local key events"
[[ "$typed" -ge 15 ]]
