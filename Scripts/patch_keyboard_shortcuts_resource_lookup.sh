#!/usr/bin/env bash
set -euo pipefail

# Temporary release workaround for KeyboardShortcuts 2.3.0 resource lookup in
# RepoPrompt's packaged app layout. Prefer an upstream fix, pinned fork, or
# vendored package over long-term mutation of SwiftPM's .build/checkouts state.

ROOT_DIR="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_WITHOUT_GITHUB_TOKENS="${REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS:-$SCRIPT_DIR/run_without_github_tokens.sh}"
SWIFTPM_SCRATCH_PATH="${REPOPROMPT_SWIFTPM_SCRATCH_PATH:-$ROOT_DIR/.build}"
CHECKOUT_DIR="$SWIFTPM_SCRATCH_PATH/checkouts/KeyboardShortcuts"
UTILITIES_FILE="$CHECKOUT_DIR/Sources/KeyboardShortcuts/Utilities.swift"
RECORDER_FILE="$CHECKOUT_DIR/Sources/KeyboardShortcuts/Recorder.swift"
RESOURCE_PATCH_FILE="$SCRIPT_DIR/patches/keyboardshortcuts-2.3.0-resource-lookup.patch"
PREVIEW_PATCH_FILE="$SCRIPT_DIR/patches/keyboardshortcuts-2.3.0-remove-previews.patch"
EXPECTED_VERSION="2.3.0"
EXPECTED_REVISION="045cf174010beb335fa1d2567d18c057b8787165"
PATCH_MARKER="RepoPromptKeyboardShortcutsResourceLookupV1"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

run() {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    "$@"
}

[[ -n "$ROOT_DIR" ]] || fail "Usage: $0 <repo-root>"
[[ -f "$RESOURCE_PATCH_FILE" ]] || fail "Missing KeyboardShortcuts resource lookup patch: $RESOURCE_PATCH_FILE"
[[ -f "$PREVIEW_PATCH_FILE" ]] || fail "Missing KeyboardShortcuts preview patch: $PREVIEW_PATCH_FILE"

if [[ ! -f "$UTILITIES_FILE" ]]; then
    run "$RUN_WITHOUT_GITHUB_TOKENS" swift package \
        --package-path "$ROOT_DIR" \
        --scratch-path "$SWIFTPM_SCRATCH_PATH" \
        resolve
fi
[[ -f "$UTILITIES_FILE" ]] || fail "Could not locate KeyboardShortcuts Utilities.swift after package resolution: $UTILITIES_FILE"
[[ -f "$RECORDER_FILE" ]] || fail "Could not locate KeyboardShortcuts Recorder.swift after package resolution: $RECORDER_FILE"

python3 - "$ROOT_DIR/Package.resolved" "$EXPECTED_VERSION" "$EXPECTED_REVISION" <<'PY'
import json
import sys
from pathlib import Path

resolved_path = Path(sys.argv[1])
expected_version = sys.argv[2]
expected_revision = sys.argv[3]
try:
    pins = json.loads(resolved_path.read_text(encoding="utf-8")).get("pins", [])
except FileNotFoundError:
    raise SystemExit(f"ERROR: Missing Package.resolved at {resolved_path}")
for pin in pins:
    if pin.get("identity") == "keyboardshortcuts":
        state = pin.get("state", {})
        actual_version = state.get("version")
        actual_revision = state.get("revision")
        if actual_version != expected_version or actual_revision != expected_revision:
            raise SystemExit(
                "ERROR: KeyboardShortcuts dependency version or revision changed; "
                f"expected {expected_version} @ {expected_revision}, "
                f"got {actual_version or '<missing>'} @ {actual_revision or '<missing>'}. "
                "Review Scripts/patches/keyboardshortcuts-2.3.0-resource-lookup.patch before packaging."
            )
        break
else:
    raise SystemExit("ERROR: KeyboardShortcuts dependency pin is missing from Package.resolved")
PY

RESOURCE_PATCH_NEEDED=1
if grep -Fq "$PATCH_MARKER" "$UTILITIES_FILE"; then
    RESOURCE_PATCH_NEEDED=0
fi

PREVIEW_PATCH_NEEDED=1
if ! grep -Fq "#Preview {" "$RECORDER_FILE"; then
    PREVIEW_PATCH_NEEDED=0
fi

if (( ! RESOURCE_PATCH_NEEDED )) && (( ! PREVIEW_PATCH_NEEDED )); then
    printf 'KeyboardShortcuts patches already applied: %s, %s\n' "$UTILITIES_FILE" "$RECORDER_FILE"
    exit 0
fi

if (( RESOURCE_PATCH_NEEDED )); then
    run chmod u+w "$UTILITIES_FILE"
    if ! (cd "$CHECKOUT_DIR" && git apply --unidiff-zero --check "$RESOURCE_PATCH_FILE"); then
        fail "KeyboardShortcuts resource lookup patch no longer applies cleanly. Review $RESOURCE_PATCH_FILE against $UTILITIES_FILE."
    fi
    run bash -c 'cd "$1" && git apply --unidiff-zero "$2"' bash "$CHECKOUT_DIR" "$RESOURCE_PATCH_FILE"
    printf 'Applied KeyboardShortcuts resource lookup patch: %s\n' "$RESOURCE_PATCH_FILE"
fi

if (( PREVIEW_PATCH_NEEDED )); then
    run chmod u+w "$RECORDER_FILE"
    if ! (cd "$CHECKOUT_DIR" && git apply --unidiff-zero --check "$PREVIEW_PATCH_FILE"); then
        fail "KeyboardShortcuts preview patch no longer applies cleanly. Review $PREVIEW_PATCH_FILE against $RECORDER_FILE."
    fi
    run bash -c 'cd "$1" && git apply --unidiff-zero "$2"' bash "$CHECKOUT_DIR" "$PREVIEW_PATCH_FILE"
    printf 'Applied KeyboardShortcuts preview patch: %s\n' "$PREVIEW_PATCH_FILE"
fi
