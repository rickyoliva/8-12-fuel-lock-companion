#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${OUTPUT:-$ROOT/build/FuelLockCompanion.ipa}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData-ios}"
BUNDLE_ID="${BUNDLE_ID:-com.rickyoliva.fuellockcompanion}"

cd "$ROOT"

command -v xcodegen >/dev/null || { echo "error: xcodegen isn't installed (brew install xcodegen)" >&2; exit 1; }
bash "$ROOT/scripts/setup-deps.sh"

echo "==> Generating FuelLockCompanion.xcodeproj from project.yml"
xcodegen generate --spec project.yml --quiet

echo "==> Building FuelLockCompanion (Release, unsigned)"
xcodebuild build \
  -project FuelLockCompanion.xcodeproj \
  -scheme FuelLockCompanion \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/FuelLockCompanion.app"
[ -d "$APP_PATH" ] || { echo "error: FuelLockCompanion.app not found at $APP_PATH" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload" "$(dirname "$OUTPUT")"
ditto "$APP_PATH" "$STAGE/Payload/FuelLockCompanion.app"
find "$STAGE" -name .DS_Store -delete
rm -f "$OUTPUT"
(cd "$STAGE" && zip -qryX "$OUTPUT" Payload)

echo "==> Built unsigned sideloadable IPA: $OUTPUT ($(du -h "$OUTPUT" | cut -f1 | tr -d ' '))"
echo "    sha256: $(shasum -a 256 "$OUTPUT" | cut -d' ' -f1)"
