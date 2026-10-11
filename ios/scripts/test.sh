#!/usr/bin/env bash
# Runs the unit tests in the simulator (SIM picks which; see simulator.sh).
#   ios/scripts/test.sh                                   # all tests
#   ios/scripts/test.sh -only-testing:CodechoteTests/ChatItemTests
#   INTEGRATION=1 ios/scripts/test.sh                     # also the tests against the local test host
#   SCHEME=CodechoteUI INTEGRATION=1 ios/scripts/test.sh  # the end-to-end UI tests
# The full log is kept at .build/test/test.log.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"
DIR="$ROOT/.build/test"; mkdir -p "$DIR"
SIM="$(scripts/simulator.sh)" || exit 1
# xcodebuild hands TEST_RUNNER_-prefixed variables to the tests (without the prefix).
if [ -n "${INTEGRATION:-}" ]; then
  export TEST_RUNNER_CODECHOTE_TESTHOST="$ROOT/.build/testhost" TEST_RUNNER_CODECHOTE_TESTHOST_USER="$USER"
fi
# A copy of the app left running (with its console attached, by sim.sh) can stop the test runner from starting.
xcrun simctl terminate "$SIM" dev.codechote.app 2>/dev/null || true
pkill -f "simctl launch --console.*dev.codechote.app" 2>/dev/null || true
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" xcodegen generate >/dev/null 2>&1 || echo "Warning: xcodegen failed" >&2
if xcodebuild test -project Codechote.xcodeproj -scheme "${SCHEME:-Codechote}" -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath "$DIR/dd" -skipPackagePluginValidation -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO "$@" > "$DIR/test.log" 2>&1; then
  grep -E "Executed [0-9]+ tests" "$DIR/test.log" | tail -1
  skipped=$(grep -c "' skipped (" "$DIR/test.log" || true)
  [ "$skipped" -gt 0 ] && echo "$skipped skipped (integration tests need INTEGRATION=1 and the test host)."
  echo "Tests passed."
else
  grep -E "error: |failed \(|: error|XCTAssert" "$DIR/test.log" | sort -u | head -30
  echo "Tests failed. Full log: $DIR/test.log"; exit 1
fi
