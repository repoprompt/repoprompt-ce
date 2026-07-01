#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

INVENTORY="ThirdPartyLicenses/swiftpm/inventory.tsv"
CHECKSUMS="ThirdPartyLicenses/swiftpm/SHA256SUMS"
TREE_SITTER_BUNDLE="ThirdPartyLicenses/tree-sitter/README.md"
TREE_SITTER_CHECKSUMS="ThirdPartyLicenses/tree-sitter/SHA256SUMS"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "Missing required command: jq"
command -v shasum >/dev/null 2>&1 || fail "Missing required command: shasum"
[[ -f "$INVENTORY" ]] || fail "Missing SwiftPM notice inventory: $INVENTORY"
[[ -f "$CHECKSUMS" ]] || fail "Missing SwiftPM notice checksums: $CHECKSUMS"
[[ -f "$TREE_SITTER_BUNDLE" ]] || fail "Missing Tree-sitter notice bundle: $TREE_SITTER_BUNDLE"
[[ -f "$TREE_SITTER_CHECKSUMS" ]] || fail "Missing Tree-sitter notice checksums: $TREE_SITTER_CHECKSUMS"

jq -r '
    .pins[]
    | [.identity, (.state.version // .state.revision // .state.branch), .location]
    | @tsv
' Package.resolved | sort > "$TMP_DIR/resolved.tsv"
cut -f1-3 "$INVENTORY" | sort > "$TMP_DIR/inventory.tsv"

# SwiftPM does not keep the env-gated Sentry package in Package.resolved once
# REPOPROMPT_ENABLE_SENTRY is restored to its default-off state, but official
# release builds still link it via Package.swift's exact dependency. Keep its
# copied notice under guardrail coverage without treating it as lockfile drift.
grep -v $'^sentry-cocoa\t' "$TMP_DIR/inventory.tsv" > "$TMP_DIR/inventory-for-lockfile.tsv"

diff -u "$TMP_DIR/resolved.tsv" "$TMP_DIR/inventory-for-lockfile.tsv" ||
    fail "SwiftPM notice inventory does not match Package.resolved"

while IFS=$'\t' read -r identity _resolved _location bundle; do
    [[ -n "$identity" && -n "$bundle" ]] ||
        fail "Malformed SwiftPM notice inventory row for ${identity:-<missing>}"

    if [[ "$bundle" == "../tree-sitter/README.md" ]]; then
        continue
    fi

    [[ -d "ThirdPartyLicenses/swiftpm/$bundle" ]] ||
        fail "Missing copied SwiftPM notice directory for $identity: $bundle"
    find "ThirdPartyLicenses/swiftpm/$bundle" -type f -print -quit | grep -q . ||
        fail "Empty copied SwiftPM notice directory for $identity: $bundle"
done < "$INVENTORY"

(
    cd ThirdPartyLicenses/swiftpm
    find . -mindepth 2 -type f -print |
        sed 's#^\./##' |
        sort > "$TMP_DIR/copied-files.txt"
    awk '{ print $2 }' SHA256SUMS | sort > "$TMP_DIR/checksummed-files.txt"
    diff -u "$TMP_DIR/copied-files.txt" "$TMP_DIR/checksummed-files.txt" ||
        fail "SwiftPM copied notice checksum inventory is incomplete"
    shasum -a 256 -c SHA256SUMS
)

(
    cd ThirdPartyLicenses/tree-sitter
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print |
        sed 's#^\./##' |
        sort > "$TMP_DIR/tree-sitter-files.txt"
    awk '{ print $2 }' SHA256SUMS | sort > "$TMP_DIR/tree-sitter-checksummed-files.txt"
    diff -u "$TMP_DIR/tree-sitter-files.txt" "$TMP_DIR/tree-sitter-checksummed-files.txt" ||
        fail "Tree-sitter copied notice checksum inventory is incomplete"
    shasum -a 256 -c SHA256SUMS
)

printf 'OK: SwiftPM notice inventory matches Package.resolved (%s packages).\n' \
    "$(wc -l < "$INVENTORY" | tr -d ' ')"
