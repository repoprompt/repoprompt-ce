#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUST_DIR="$PACKAGE_DIR/rust"
BUILD_DIR="$PACKAGE_DIR/.build/xcframework"
CARGO_TARGET_DIR="$PACKAGE_DIR/.build/rust-target"
ARTIFACT="$PACKAGE_DIR/Artifacts/IrohTransportFFI.xcframework"
GENERATED_SOURCE="$PACKAGE_DIR/Sources/RepoPromptIrohTransport/IrohTransportBindings.swift"
LIB_NAME="librepoprompt_iroh_transport.a"

export CARGO_TARGET_DIR
export MACOSX_DEPLOYMENT_TARGET=14.0
export IPHONEOS_DEPLOYMENT_TARGET=17.0

if [[ "${1:-}" != "" && "${1:-}" != "--locked" ]]; then
  echo "usage: $0 [--locked]" >&2
  exit 64
fi

command -v cargo >/dev/null || { echo "cargo is required" >&2; exit 1; }
command -v rustc >/dev/null || { echo "rustc is required" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode is required" >&2; exit 1; }

actual_rust="$(rustc --version | awk '{print $2}')"
if [[ "$actual_rust" != "1.92.0" ]]; then
  echo "Rust 1.92.0 is required; found $actual_rust" >&2
  exit 1
fi

required_targets=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)
for target in "${required_targets[@]}"; do
  if [[ ! -d "$(rustc --print sysroot)/lib/rustlib/$target" ]]; then
    echo "missing Rust target $target (install the targets listed in rust/rust-toolchain.toml)" >&2
    exit 1
  fi
done

rm -rf "$BUILD_DIR" "$ARTIFACT"
mkdir -p "$BUILD_DIR/generated" "$BUILD_DIR/headers" "$PACKAGE_DIR/Artifacts"

build_target() {
  local target="$1"
  local sdk="$2"
  echo "==> Building $target"
  (
    cd "$RUST_DIR"
    SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
      cargo build --locked --release --target "$target"
  )
}

build_target aarch64-apple-darwin macosx
build_target x86_64-apple-darwin macosx
build_target aarch64-apple-ios iphoneos
build_target aarch64-apple-ios-sim iphonesimulator
build_target x86_64-apple-ios iphonesimulator

# Build a host dylib carrying UniFFI metadata, then generate Swift/header/modulemap from the
# exact locked UniFFI version in this crate.
(
  cd "$RUST_DIR"
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" cargo build --locked --release
  cargo run --locked --release --features bindgen --bin uniffi-bindgen -- \
    generate \
    --library "$CARGO_TARGET_DIR/release/librepoprompt_iroh_transport.dylib" \
    --language swift \
    --out-dir "$BUILD_DIR/generated"
)

cp "$BUILD_DIR/generated/IrohTransportBindings.swift" "$GENERATED_SOURCE"
cp "$BUILD_DIR/generated/IrohTransportFFI.h" "$BUILD_DIR/headers/IrohTransportFFI.h"
cp "$BUILD_DIR/generated/IrohTransportFFI.modulemap" "$BUILD_DIR/headers/module.modulemap"

mkdir -p "$BUILD_DIR/macos" "$BUILD_DIR/ios" "$BUILD_DIR/simulator"
xcrun lipo -create \
  "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/$LIB_NAME" \
  "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/$LIB_NAME" \
  -output "$BUILD_DIR/macos/$LIB_NAME"
cp "$CARGO_TARGET_DIR/aarch64-apple-ios/release/$LIB_NAME" "$BUILD_DIR/ios/$LIB_NAME"
xcrun lipo -create \
  "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/$LIB_NAME" \
  "$CARGO_TARGET_DIR/x86_64-apple-ios/release/$LIB_NAME" \
  -output "$BUILD_DIR/simulator/$LIB_NAME"

xcodebuild -create-xcframework \
  -library "$BUILD_DIR/macos/$LIB_NAME" -headers "$BUILD_DIR/headers" \
  -library "$BUILD_DIR/ios/$LIB_NAME" -headers "$BUILD_DIR/headers" \
  -library "$BUILD_DIR/simulator/$LIB_NAME" -headers "$BUILD_DIR/headers" \
  -output "$ARTIFACT"

"$SCRIPT_DIR/verify-xcframework.sh"
echo "Created $ARTIFACT"
