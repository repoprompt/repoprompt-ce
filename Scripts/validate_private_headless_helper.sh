#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?app bundle required}"
EXPECTED="${2:?architecture policy required}"
SKIP_SIGNATURE="${3:-}"
LIPO="${LIPO:-lipo}"
CODESIGN="${CODESIGN:-codesign}"
HELPER="$APP_BUNDLE/Contents/Helpers/repoprompt-mcp-headless-runtime"

fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ -f "$HELPER" && ! -L "$HELPER" && -x "$HELPER" ]] || fail "missing regular executable private headless helper"
contract="$("$HELPER" --print-launcher-contract-version 2>/dev/null || true)"
[[ "$contract" == "1" ]] || fail "private headless helper contract mismatch: ${contract:-<empty>}"
actual="$("$LIPO" -archs "$HELPER" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -)"
case "$EXPECTED" in
    arm64,x86_64) [[ "$actual" == "arm64,x86_64" ]] || fail "private helper must be universal; got $actual" ;;
    matching)
        machine="$(uname -m)"
        [[ ",$actual," == *",$machine,"* ]] || fail "private helper lacks host architecture $machine: $actual"
        ;;
    *) fail "unknown architecture policy: $EXPECTED" ;;
esac
if [[ "$SKIP_SIGNATURE" != "--skip-signature" ]]; then
    "$CODESIGN" --verify --strict --verbose=2 "$HELPER" >/dev/null
fi
printf 'OK: private headless helper contract, architecture, and signature validated.\n'
