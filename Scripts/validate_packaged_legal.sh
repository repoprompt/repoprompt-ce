#!/usr/bin/env bash
set -euo pipefail

ROOT="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP_BUNDLE="${1:-}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -n "$APP_BUNDLE" ]] || fail "Usage: $0 /path/to/RepoPrompt.app"
[[ -d "$APP_BUNDLE" ]] || fail "Missing app bundle: $APP_BUNDLE"

LEGAL_DIR="$APP_BUNDLE/Contents/Resources/Legal"
[[ -d "$LEGAL_DIR" ]] || fail "Packaged app is missing legal resources: $LEGAL_DIR"

cmp "$ROOT/LICENSE" "$LEGAL_DIR/LICENSE" ||
    fail "Packaged LICENSE does not match the release source"
cmp "$ROOT/THIRD_PARTY_NOTICES.md" "$LEGAL_DIR/THIRD_PARTY_NOTICES.md" ||
    fail "Packaged THIRD_PARTY_NOTICES.md does not match the release source"
diff -qr "$ROOT/ThirdPartyLicenses" "$LEGAL_DIR/ThirdPartyLicenses" ||
    fail "Packaged ThirdPartyLicenses directory does not match the release source"

printf 'OK: packaged legal resources match the release source.\n'
