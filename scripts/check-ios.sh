#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData-sim}"
RESULT_BUNDLE="${RESULT_BUNDLE:-$ROOT/build/FuelLockCompanionTests.xcresult}"
SIMULATOR_ID="${SIMULATOR_ID:-}"

cd "$ROOT"

command -v xcodegen >/dev/null || { echo "error: xcodegen isn't installed (brew install xcodegen)" >&2; exit 1; }
bash "$ROOT/scripts/setup-deps.sh"

echo "==> Generating FuelLockCompanion.xcodeproj from project.yml"
xcodegen generate --spec project.yml --quiet

if [ -z "$SIMULATOR_ID" ]; then
  SIMULATOR_ID="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, entries in devices.items():
    m = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    if not m:
        continue
    version = tuple(int(p or 0) for p in m.groups())
    for d in entries:
        if d["name"].startswith("iPhone") and (best is None or version > best[0]):
            best = (version, d["udid"], d["name"])
if best:
    print(best[1])
    print("==> Simulator: %s, iOS %s" % (best[2], ".".join(map(str, best[0]))), file=sys.stderr)
')"
fi
[ -n "$SIMULATOR_ID" ] || { echo "error: no available iPhone simulator found" >&2; exit 1; }

rm -rf "$RESULT_BUNDLE"
mkdir -p "$(dirname "$RESULT_BUNDLE")"

echo "==> Building and running FuelLockCompanionTests"
xcodebuild test \
  -project FuelLockCompanion.xcodeproj \
  -scheme FuelLockCompanion \
  -configuration Debug \
  -destination "id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  CODE_SIGNING_ALLOWED=NO

echo "==> Simulator build and tests passed ($RESULT_BUNDLE)"
