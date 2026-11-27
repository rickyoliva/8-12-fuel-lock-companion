#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-26.4}"

# Rewrite $HOME to /build so local paths aren't embedded in binary strings.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${HOME}=/build"
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=${HOME}=/build"
export TARGET_CFLAGS="${TARGET_CFLAGS:-} -ffile-prefix-map=${HOME}=/build"

if command -v rustup >/dev/null 2>&1; then
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim >/dev/null 2>&1 || true
fi

cd "$ROOT/pairing-host"

echo "==> Building pairing_host_ffi (aarch64-apple-ios)"
cargo build --release --target aarch64-apple-ios

echo "==> Building pairing_host_ffi (aarch64-apple-ios-sim)"
cargo build --release --target aarch64-apple-ios-sim

cd "$ROOT"
echo "==> Packaging PairingHost.xcframework"
rm -rf "$ROOT/PairingHost.xcframework"
xcodebuild -create-xcframework \
  -library pairing-host/target/aarch64-apple-ios/release/libpairing_host_ffi.a \
  -headers pairing-host/include \
  -library pairing-host/target/aarch64-apple-ios-sim/release/libpairing_host_ffi.a \
  -headers pairing-host/include \
  -output "$ROOT/PairingHost.xcframework"

echo "==> Built PairingHost.xcframework"
