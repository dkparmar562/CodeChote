#!/usr/bin/env bash
# Builds the app and installs it on the connected iPhone, then launches it.
#   scripts/install.sh            # first connected iPhone
#   DEVICE=<udid> scripts/install.sh
# The phone must be unlocked and trusted. The first run needs a development team set in Xcode (project.yml).
# The full build log is kept at $BUILD/build.log; on failure the relevant lines are printed.
set -uo pipefail
cd "$(dirname "$0")/.."
BUILD="${BUILD_DIR:-$(cd .. && pwd)/.build/device-build}"
mkdir -p "$BUILD"
LOG="$BUILD/build.log"
DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /available|connected/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}"
[ -n "$DEVICE" ] || { echo "No iPhone found. Connect it by cable, unlock it, and trust this Mac." >&2; exit 1; }
echo "Building for ${DEVICE}..."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# New source files only get into the Xcode project by regenerating it.
xcodegen generate >"$BUILD/xcodegen.log" 2>&1 || echo "Warning: xcodegen failed, new files may be missing (see $BUILD/xcodegen.log)" >&2
if ! xcodebuild -project Codechote.xcodeproj -scheme Codechote -destination "id=$DEVICE" -derivedDataPath "$BUILD" \
    -skipPackagePluginValidation -allowProvisioningUpdates build >"$LOG" 2>&1; then
  echo "BUILD FAILED. Relevant lines (full log: $LOG):" >&2
  grep -E "errSec|resource fork|detritus|code object|User interaction|CodeSign failed|: error: |No profiles|Unable to" "$LOG" | cut -c1-300 | sort -u | head -15 >&2
  if grep -q errSecInternalComponent "$LOG"; then
    echo "Signing could not use the key in your login keychain (it is locked, or this is not a logged-in Terminal session)." >&2
    echo "Run this script from Terminal.app on the Mac while it is unlocked; if asked, choose Always Allow for codesign." >&2
  fi
  exit 1
fi
echo "** BUILD SUCCEEDED **"
echo "Installing..."
xcrun devicectl device install app --device "$DEVICE" "$BUILD/Build/Products/Debug-iphoneos/Codechote.app" 2>&1 | grep -iE "installed|error"
xcrun devicectl device process launch --device "$DEVICE" dev.codechote.app 2>&1 | tail -1
