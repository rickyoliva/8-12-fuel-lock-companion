#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IDEVICE_VERSION="${IDEVICE_VERSION:-v0.1.68}"
ASSET_NAME="idevice-xcframework-${IDEVICE_VERSION}.zip"
DOWNLOAD_URL="https://github.com/jkcoxson/idevice/releases/download/${IDEVICE_VERSION}/${ASSET_NAME}"

if [ -d "$ROOT/IDevice.xcframework/ios-arm64" ] && [ -d "$ROOT/IDevice.xcframework/ios-arm64_x86_64-simulator" ]; then
  echo "==> IDevice.xcframework already present"
  exit 0
fi

echo "==> Downloading ${ASSET_NAME}..."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

curl -fL "$DOWNLOAD_URL" -o "$tmp_dir/$ASSET_NAME"
unzip -q "$tmp_dir/$ASSET_NAME" "swift/IDevice.xcframework/*" -d "$tmp_dir/extract"
rm -rf "$ROOT/IDevice.xcframework"
mv "$tmp_dir/extract/swift/IDevice.xcframework" "$ROOT/IDevice.xcframework"

echo "==> Installed IDevice.xcframework ($IDEVICE_VERSION)"
