#!/usr/bin/env bash
set -euo pipefail

TRUSTED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$TRUSTED_ROOT}"
CANDIDATE_FRAMEWORK="${1:-}"
TRUSTED_VENDOR="$TRUSTED_ROOT/Vendor/Sparkle"
SOURCE_VENDOR="$SOURCE_ROOT/Vendor/Sparkle"
TRUSTED_FRAMEWORK="$TRUSTED_VENDOR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
TRUSTED_MANIFEST="$TRUSTED_VENDOR/INSTALLED_MANIFEST.tsv"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -f "$TRUSTED_MANIFEST" ]] ||
    fail "Missing trusted Sparkle installed typed manifest"

verify_manifest() {
    python3 - "$TRUSTED_MANIFEST" "$TRUSTED_VENDOR" <<'PYTHON'
import hashlib
import os
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
vendor = Path(sys.argv[2])
expected = {}
for line in manifest.read_text(encoding="utf-8").splitlines():
    kind, relative, value = line.split("\t")
    if kind not in {"dir", "file", "link"}:
        raise SystemExit(f"Unsupported Sparkle manifest entry type: {kind}")
    if relative in expected:
        raise SystemExit(f"Duplicate Sparkle manifest entry: {relative}")
    expected[relative] = (kind, value)

def snapshot(root: Path):
    values = {}
    for path in [root, *sorted(root.rglob("*"))]:
        relative = str(path.relative_to(vendor))
        if path.is_symlink():
            values[relative] = ("link", os.readlink(path))
        elif path.is_dir():
            values[relative] = ("dir", "-")
        elif path.is_file():
            values[relative] = ("file", hashlib.sha256(path.read_bytes()).hexdigest())
        else:
            values[relative] = ("other", "-")
    return values

actual = {}
for relative in [
    "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework",
    "Sparkle.xcframework/macos-arm64_x86_64/dSYMs",
    "bin",
]:
    actual.update(snapshot(vendor / relative))
if actual != expected:
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    changed = sorted(path for path in set(actual) & set(expected) if actual[path] != expected[path])
    raise SystemExit(
        "Sparkle installed manifest mismatch"
        f"\nmissing={missing}\nextra={extra}\nchanged={changed}"
    )
PYTHON
}

verify_manifest

compare_trees() {
    python3 - "$1" "$2" <<'PYTHON'
import hashlib
import os
import sys
from pathlib import Path

def snapshot(root: Path):
    values = {}
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            values[relative] = ("link", os.readlink(path))
        elif path.is_dir():
            values[relative] = ("dir", "")
        elif path.is_file():
            values[relative] = ("file", hashlib.sha256(path.read_bytes()).hexdigest())
        else:
            values[relative] = ("other", "")
    return values

left = Path(sys.argv[1])
right = Path(sys.argv[2])
if snapshot(left) != snapshot(right):
    raise SystemExit(f"Sparkle tree mismatch: {right} does not match trusted baseline {left}")
PYTHON
}

compare_trees "$TRUSTED_FRAMEWORK" "$SOURCE_VENDOR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
compare_trees "$TRUSTED_VENDOR/Sparkle.xcframework/macos-arm64_x86_64/dSYMs" "$SOURCE_VENDOR/Sparkle.xcframework/macos-arm64_x86_64/dSYMs"
compare_trees "$TRUSTED_VENDOR/bin" "$SOURCE_VENDOR/bin"
if [[ -n "$CANDIDATE_FRAMEWORK" ]]; then
    [[ -d "$CANDIDATE_FRAMEWORK" ]] || fail "Missing built Sparkle framework: $CANDIDATE_FRAMEWORK"
    compare_trees "$TRUSTED_FRAMEWORK" "$CANDIDATE_FRAMEWORK"
fi

printf 'OK: Sparkle vendor payload matches trusted control-plane baseline.\n'
