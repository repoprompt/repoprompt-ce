#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$PACKAGE_DIR/Artifacts/IrohTransportFFI.xcframework"
BINDINGS="$PACKAGE_DIR/Sources/RepoPromptIrohTransport/IrohTransportBindings.swift"
RUST_SOURCE="$PACKAGE_DIR/rust/src"

fail() {
  echo "XCFramework verification failed: $*" >&2
  exit 1
}

[[ -d "$ARTIFACT" ]] || fail "missing $ARTIFACT"
[[ -f "$ARTIFACT/Info.plist" ]] || fail "missing Info.plist"
[[ -f "$BINDINGS" ]] || fail "missing generated Swift bindings"
grep -q 'public func startEndpoint' "$BINDINGS" || fail "startEndpoint Swift binding is absent"
grep -q 'open class TransportConnection' "$BINDINGS" || fail "connection Swift binding is absent"

libraries=()
while IFS= read -r library; do
  libraries+=("$library")
done < <(find "$ARTIFACT" -name 'librepoprompt_iroh_transport.a' -type f | sort)
[[ "${#libraries[@]}" -eq 3 ]] || fail "expected three static-library slices, found ${#libraries[@]}"

found_macos=false
found_ios=false
found_simulator=false
for library in "${libraries[@]}"; do
  archs="$(xcrun lipo -archs "$library")"
  identifier="$(basename "$(dirname "$library")")"
  header_dir="$(dirname "$library")/Headers"
  [[ -f "$header_dir/IrohTransportFFI.h" ]] || fail "missing header in $identifier"
  [[ -f "$header_dir/module.modulemap" ]] || fail "missing modulemap in $identifier"
  xcrun nm -gU "$library" 2>/dev/null \
    | grep 'uniffi_repoprompt_iroh_transport_fn_func_start_endpoint' >/dev/null \
    || fail "start endpoint symbol absent from $identifier"

  case "$identifier" in
    macos-*)
      [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "macOS slice is not universal: $archs"
      found_macos=true
      ;;
    ios-arm64)
      [[ "$archs" == "arm64" ]] || fail "iOS device slice must be arm64: $archs"
      found_ios=true
      ;;
    ios-*-simulator)
      [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "simulator slice is not universal: $archs"
      found_simulator=true
      ;;
  esac
done

$found_macos || fail "macOS slice not found"
$found_ios || fail "iOS device slice not found"
$found_simulator || fail "iOS simulator slice not found"

if grep -R -n -E 'std::fs|File::create|OpenOptions|write\([^)]*secret|write_all\([^)]*secret' "$RUST_SOURCE"; then
  fail "Rust bridge contains a filesystem/secret-write API"
fi

plist_text="$(plutil -p "$ARTIFACT/Info.plist")"
[[ "$plist_text" == *'SupportedPlatform" => "macos"'* ]] || fail "macOS platform metadata missing"
[[ "$plist_text" == *'SupportedPlatform" => "ios"'* ]] || fail "iOS platform metadata missing"
[[ "$plist_text" == *'SupportedPlatformVariant" => "simulator"'* ]] || fail "simulator metadata missing"

echo "IrohTransportFFI.xcframework verified"
