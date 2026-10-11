#!/usr/bin/env bash
# Prints the UDID of the simulator to use: $SIM (a UDID or a device name such as "iPhone 18 Pro") if set,
# otherwise a booted iPhone, otherwise the iPhone on the newest iOS runtime.
#   ios/scripts/simulator.sh
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, sys
want = sys.argv[1]
runtimes = json.load(sys.stdin)["devices"]
devices = [d for key in sorted(runtimes) if "iOS" in key for d in runtimes[key]]
iphones = [d for d in devices if d["name"].startswith("iPhone")]
if want:
    match = [d for d in devices if want in (d["udid"], d["name"])][-1:]
else:
    match = [d for d in iphones if d["state"] == "Booted"][:1] or iphones[-1:]
if not match:
    sys.exit("No matching simulator. Install an iOS runtime in Xcode, or set SIM to a device name or UDID.")
print(match[0]["udid"])
' "${SIM:-}"
