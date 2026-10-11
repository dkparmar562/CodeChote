#!/usr/bin/env bash
# Builds the app, runs it in the simulator against the local test host (scripts/testhost.sh start), and
# takes a screenshot if you ask for one.
#   ios/scripts/sim.sh [screenshot.png | -] [wait-seconds] [extra launch args...]
# Launch options the app understands in the simulator are listed in Codechote/App/DevLaunch.swift.
# SIM picks the simulator (see simulator.sh). NOBUILD=1 reuses the last build. Build output and the app's
# console log go to .build/sim (console: .build/sim/sim-console.log).
set -euo pipefail
OUT="${1:--}"; WAIT="${2:-12}"; shift 2 || shift $# || true
# A relative screenshot path is relative to where you ran this.
case "$OUT" in -|/*) ;; *) OUT="$PWD/$OUT" ;; esac
cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"
DIR="${SIM_OUT:-$ROOT/.build/sim}"
HOST="$ROOT/.build/testhost"
SIM="$(scripts/simulator.sh)"
mkdir -p "$DIR"

if [ -z "${NOBUILD:-}" ]; then
  # New source files only reach the Xcode project by regenerating it.
  PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" xcodegen generate >/dev/null 2>&1 || echo "Warning: xcodegen failed" >&2
  xcodebuild -project Codechote.xcodeproj -scheme Codechote -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DIR/dd" -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "^\*\* BUILD| error: " | sort -u | cut -c1-300
fi
xcrun simctl boot "$SIM" 2>/dev/null || true
open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null || open -a Simulator 2>/dev/null || true
[ -n "${NOBUILD:-}" ] || xcrun simctl install "$SIM" "$DIR/dd/Build/Products/Debug-iphonesimulator/Codechote.app"
xcrun simctl terminate "$SIM" dev.codechote.app 2>/dev/null || true
: > "$DIR/sim-console.log"
xcrun simctl launch --console --terminate-running-process "$SIM" dev.codechote.app \
  -devSSH "127.0.0.1:2222:$USER:$HOST/client_ed25519" "$@" > "$DIR/sim-console.log" 2>&1 &
if [ "$OUT" != "-" ]; then
  sleep "$WAIT"
  xcrun simctl io "$SIM" screenshot "$OUT" 2>&1 | tail -1
  grep -aE "\[web\] (error|uncaught)|\[app\]" "$DIR/sim-console.log" | grep -v "copilot-chat" | cut -c1-240 | head -6 || true
else
  echo "Running in the simulator. Console: $DIR/sim-console.log"
fi
