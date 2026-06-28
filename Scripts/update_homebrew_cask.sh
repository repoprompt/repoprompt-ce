#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-update}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$ROOT_DIR/Scripts}"
cd "$ROOT_DIR"

source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"
load_release_metadata "$ROOT_DIR"

RELEASE_TAG="${RELEASE_TAG:-v$MARKETING_VERSION}"
PUBLIC_UPDATE_REPOSITORY="${PUBLIC_UPDATE_REPOSITORY:-repoprompt/repoprompt-ce-updates}"
PUBLIC_UPDATE_GH_TOKEN="${PUBLIC_UPDATE_GH_TOKEN:-}"
HOMEBREW_TAP_REPOSITORY="${HOMEBREW_TAP_REPOSITORY:-z23cc/homebrew-tap}"
HOMEBREW_TAP_BRANCH="${HOMEBREW_TAP_BRANCH:-main}"
HOMEBREW_CASK_PATH="${HOMEBREW_CASK_PATH:-Casks/repoprompt-ce.rb}"
HOMEBREW_CASK_TOKEN="${HOMEBREW_CASK_TOKEN:-repoprompt-ce}"
HOMEBREW_TAP_CHECKOUT="${HOMEBREW_TAP_CHECKOUT:-}"
HOMEBREW_TAP_GH_TOKEN="${HOMEBREW_TAP_GH_TOKEN:-}"
HOMEBREW_TAP_PUSH="${HOMEBREW_TAP_PUSH:-1}"
HOMEBREW_TAP_COMMITTER_NAME="${HOMEBREW_TAP_COMMITTER_NAME:-RepoPrompt Release Bot}"
HOMEBREW_TAP_COMMITTER_EMAIL="${HOMEBREW_TAP_COMMITTER_EMAIL:-release-bot@repoprompt.com}"
HOMEBREW_CASK_SHA256="${HOMEBREW_CASK_SHA256:-}"
ARCHIVE_BASENAME="${APP_NAME}-${MARKETING_VERSION}-${BUILD_NUMBER}"
UPDATE_ZIP_NAME="$ARCHIVE_BASENAME.zip"
UPDATE_ZIP_URL="https://github.com/$PUBLIC_UPDATE_REPOSITORY/releases/download/$RELEASE_TAG/$UPDATE_ZIP_NAME"
CASK_VERIFIED_URL="github.com/$PUBLIC_UPDATE_REPOSITORY/"
CASK_VERSION="$MARKETING_VERSION,$BUILD_NUMBER"
TMP_DIR=""

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_file() {
    [[ -f "$1" ]] || fail "Missing required file: $1"
}

cleanup() {
    [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require_release_tag_matches_metadata() {
    [[ "$RELEASE_TAG" == "v$MARKETING_VERSION" ]] ||
        fail "Release tag must match release metadata: expected v$MARKETING_VERSION, got ${RELEASE_TAG:-<missing>}"
}

derive_zip_sha256() {
    if [[ -n "$HOMEBREW_CASK_SHA256" ]]; then
        [[ "$HOMEBREW_CASK_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
            fail "Invalid HOMEBREW_CASK_SHA256: expected 64 lowercase hex characters"
        printf '%s\n' "$HOMEBREW_CASK_SHA256"
        return
    fi

    require_command awk
    require_command curl
    TMP_DIR="${TMP_DIR:-$(mktemp -d)}"
    local checksums_dir="$TMP_DIR/homebrew-checksums"
    mkdir -p "$checksums_dir"

    local curl_args=(
        --fail
        --location
        --retry 8
        --retry-delay 3
        --retry-all-errors
        --output "$checksums_dir/SHA256SUMS"
    )
    if [[ -n "$PUBLIC_UPDATE_GH_TOKEN" ]]; then
        curl_args+=(--header "Authorization: Bearer $PUBLIC_UPDATE_GH_TOKEN")
    fi
    curl "${curl_args[@]}" \
        "https://github.com/$PUBLIC_UPDATE_REPOSITORY/releases/download/$RELEASE_TAG/SHA256SUMS"

    local checksums="$checksums_dir/SHA256SUMS"
    require_file "$checksums"
    local entry
    entry="$(awk -v name="$UPDATE_ZIP_NAME" '$2 == name { print $1 }' "$checksums")"
    [[ -n "$entry" ]] || fail "SHA256SUMS is missing $UPDATE_ZIP_NAME"
    [[ "$(printf '%s\n' "$entry" | wc -l | tr -d ' ')" == "1" ]] ||
        fail "SHA256SUMS has multiple entries for $UPDATE_ZIP_NAME"
    [[ "$entry" =~ ^[0-9a-f]{64}$ ]] || fail "Invalid SHA-256 for $UPDATE_ZIP_NAME: $entry"
    printf '%s\n' "$entry"
}

rewrite_cask_file() {
    local cask_file="$1"
    local sha256="$2"
    python3 - "$cask_file" "$CASK_VERSION" "$sha256" "$UPDATE_ZIP_URL" "$CASK_VERIFIED_URL" <<'PYTHON'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
version = sys.argv[2]
sha256 = sys.argv[3]
url = sys.argv[4]
verified = sys.argv[5]
text = path.read_text(encoding="utf-8")
if "latest/download" in text:
    raise SystemExit("refusing to update cask that uses a latest/download URL")

def replace_one(label: str, pattern: str, replacement: str, source: str) -> str:
    matches = list(re.finditer(pattern, source, flags=re.MULTILINE))
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one {label} stanza")
    updated, count = re.subn(pattern, replacement, source, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"failed to rewrite {label} stanza")
    return updated

text = replace_one(
    "version",
    r'^(\s*version\s+")[^"]+(".*)$',
    rf'\g<1>{version}\2',
    text,
)
text = replace_one(
    "sha256",
    r'^(\s*sha256\s+")[^"]+(".*)$',
    rf'\g<1>{sha256}\2',
    text,
)
text = replace_one(
    "url",
    r'^(\s*url\s+")[^"]+(".*)$',
    rf'\g<1>{url}\2',
    text,
)
verified_pattern = r'(verified:\s*")[^"]+(")'
verified_matches = list(re.finditer(verified_pattern, text))
if len(verified_matches) > 1:
    raise SystemExit("expected at most one verified stanza")
if verified_matches:
    text = replace_one("verified", verified_pattern, rf'\g<1>{verified}\2', text)
path.write_text(text, encoding="utf-8")
PYTHON
}

verify_cask_file() {
    local cask_file="$1"
    local sha256="$2"
    python3 - "$cask_file" "$CASK_VERSION" "$sha256" "$UPDATE_ZIP_URL" "$CASK_VERIFIED_URL" <<'PYTHON'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected_version = sys.argv[2]
expected_sha256 = sys.argv[3]
expected_url = sys.argv[4]
expected_verified = sys.argv[5]
text = path.read_text(encoding="utf-8")

def require_single_expected(label: str, stanza_pattern: str, expected_pattern: str) -> None:
    stanzas = list(re.finditer(stanza_pattern, text, flags=re.MULTILINE))
    if len(stanzas) != 1:
        raise SystemExit(f"expected exactly one cask {label} stanza")
    if not re.match(expected_pattern, stanzas[0].group(0)):
        raise SystemExit(f"cask {label} does not match expected release")

require_single_expected(
    "version",
    r'^\s*version\s+"[^"]+".*$',
    rf'^\s*version\s+"{re.escape(expected_version)}"\s*(?:#.*)?$',
)
require_single_expected(
    "sha256",
    r'^\s*sha256\s+"[^"]+".*$',
    rf'^\s*sha256\s+"{re.escape(expected_sha256)}"\s*(?:#.*)?$',
)
require_single_expected(
    "url",
    r'^\s*url\s+"[^"]+".*$',
    rf'^\s*url\s+"{re.escape(expected_url)}"(?:\s*,|\s*$)',
)
verified_values = re.findall(r'verified:\s*"([^"]+)"', text)
if len(verified_values) > 1:
    raise SystemExit("expected at most one cask verified stanza")
if verified_values and verified_values[0] != expected_verified:
    raise SystemExit(f"cask verified URL does not match expected updater repository: {expected_verified}")
if "latest/download" in text:
    raise SystemExit("cask must not use latest/download URLs")
PYTHON
}

resolve_cask_file() {
    local tap_checkout="$1"
    python3 - "$tap_checkout" "$HOMEBREW_CASK_PATH" <<'PYTHON'
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
relative = Path(sys.argv[2])
if relative.is_absolute():
    raise SystemExit("HOMEBREW_CASK_PATH must be relative to the tap checkout")
if not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
    raise SystemExit("HOMEBREW_CASK_PATH must not contain empty, '.', or '..' components")
target = (root / relative).resolve(strict=False)
try:
    target.relative_to(root)
except ValueError as exc:
    raise SystemExit("HOMEBREW_CASK_PATH escapes the tap checkout") from exc
print(target)
PYTHON
}

prepare_tap_checkout() {
    if [[ -n "$HOMEBREW_TAP_CHECKOUT" ]]; then
        [[ -d "$HOMEBREW_TAP_CHECKOUT/.git" ]] || fail "HOMEBREW_TAP_CHECKOUT is not a git checkout: $HOMEBREW_TAP_CHECKOUT"
        printf '%s\n' "$HOMEBREW_TAP_CHECKOUT"
        return
    fi

    require_command gh
    TMP_DIR="${TMP_DIR:-$(mktemp -d)}"
    local tap_checkout="$TMP_DIR/homebrew-tap"
    GH_TOKEN="$HOMEBREW_TAP_GH_TOKEN" gh repo clone "$HOMEBREW_TAP_REPOSITORY" "$tap_checkout"
    git -C "$tap_checkout" checkout "$HOMEBREW_TAP_BRANCH"
    printf '%s\n' "$tap_checkout"
}

commit_and_push_tap() {
    local tap_checkout="$1"
    local cask_file="$2"
    git -C "$tap_checkout" config user.name "$HOMEBREW_TAP_COMMITTER_NAME"
    git -C "$tap_checkout" config user.email "$HOMEBREW_TAP_COMMITTER_EMAIL"
    git -C "$tap_checkout" add -- "$cask_file"
    if git -C "$tap_checkout" diff --cached --quiet; then
        printf 'OK: Homebrew cask already current for %s (%s).\n' "$MARKETING_VERSION" "$BUILD_NUMBER"
        return
    fi

    git -C "$tap_checkout" commit -m "Update $HOMEBREW_CASK_TOKEN to $MARKETING_VERSION ($BUILD_NUMBER)"
    if [[ "$HOMEBREW_TAP_PUSH" == "0" ]]; then
        printf 'OK: Homebrew cask updated locally for %s (%s); push disabled.\n' "$MARKETING_VERSION" "$BUILD_NUMBER"
        return
    fi

    [[ -n "$HOMEBREW_TAP_GH_TOKEN" ]] || fail "HOMEBREW_TAP_GH_TOKEN is required to push $HOMEBREW_TAP_REPOSITORY"
    GH_TOKEN="$HOMEBREW_TAP_GH_TOKEN" gh auth setup-git >/dev/null
    git -C "$tap_checkout" push origin "HEAD:$HOMEBREW_TAP_BRANCH"
    printf 'OK: pushed Homebrew cask update to %s@%s for %s (%s).\n' \
        "$HOMEBREW_TAP_REPOSITORY" "$HOMEBREW_TAP_BRANCH" "$MARKETING_VERSION" "$BUILD_NUMBER"
}

update_tap() {
    require_release_tag_matches_metadata
    [[ -n "$HOMEBREW_TAP_REPOSITORY" || -n "$HOMEBREW_TAP_CHECKOUT" ]] ||
        fail "HOMEBREW_TAP_REPOSITORY is required unless HOMEBREW_TAP_CHECKOUT is provided"
    require_command git
    require_command python3
    local sha256 tap_checkout cask_file
    sha256="$(derive_zip_sha256)"
    tap_checkout="$(prepare_tap_checkout)"
    cask_file="$(resolve_cask_file "$tap_checkout")"
    require_file "$cask_file"
    rewrite_cask_file "$cask_file" "$sha256"
    verify_cask_file "$cask_file" "$sha256"
    commit_and_push_tap "$tap_checkout" "$HOMEBREW_CASK_PATH"
}

verify_tap() {
    require_release_tag_matches_metadata
    [[ -n "$HOMEBREW_TAP_REPOSITORY" || -n "$HOMEBREW_TAP_CHECKOUT" ]] ||
        fail "HOMEBREW_TAP_REPOSITORY is required unless HOMEBREW_TAP_CHECKOUT is provided"
    require_command python3
    local sha256 tap_checkout cask_file
    sha256="$(derive_zip_sha256)"
    tap_checkout="$(prepare_tap_checkout)"
    cask_file="$(resolve_cask_file "$tap_checkout")"
    require_file "$cask_file"
    verify_cask_file "$cask_file" "$sha256"
    printf 'OK: Homebrew cask matches %s (%s).\n' "$MARKETING_VERSION" "$BUILD_NUMBER"
}

case "$MODE" in
    update)
        update_tap
        ;;
    verify)
        verify_tap
        ;;
    *)
        fail "Usage: $0 update|verify"
        ;;
esac
