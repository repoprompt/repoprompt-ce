#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
APPROVED_SOURCE_ROOT="${REPOPROMPT_APPROVED_SOURCE_ROOT:-}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -n "$APPROVED_SOURCE_ROOT" ]] ||
    fail "Missing required environment variable: REPOPROMPT_APPROVED_SOURCE_ROOT"
[[ -n "${RELEASE_COMMIT:-}" ]] ||
    fail "Missing required environment variable: RELEASE_COMMIT"

cmp "$ROOT_DIR/version.env" "$APPROVED_SOURCE_ROOT/version.env" ||
    fail "Staged version.env does not match approved source"
source "$SCRIPT_DIR/load_release_metadata.sh"
load_release_metadata "$APPROVED_SOURCE_ROOT"

APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"

python3 - "$ROOT_DIR" "$APP_BUNDLE" <<'PYTHON'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
app = Path(sys.argv[2])

def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")

def require_real_directory(path: Path) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        fail(f"missing staged directory: {path}")
    if not stat.S_ISDIR(mode):
        fail(f"staged path must be a real directory: {path}")

def require_regular_file(path: Path) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        fail(f"missing staged file: {path}")
    if not stat.S_ISREG(mode):
        fail(f"staged path must be a regular file: {path}")

for path in [
    root,
    root / ".build",
    root / ".build" / "release",
    app,
    app / "Contents",
    app / "Contents" / "Frameworks",
    app / "Contents" / "Frameworks" / "Sparkle.framework",
    app / "Contents" / "MacOS",
    app / "Contents" / "Resources",
    app / "Contents" / "Resources" / "Legal",
]:
    require_real_directory(path)

for path in [
    root / "version.env",
    root / "LICENSE",
    root / "THIRD_PARTY_NOTICES.md",
    root / "RELEASE_COMMIT",
    app / "Contents" / "Info.plist",
    root / ".build" / "release" / "RepoPrompt-artifact-manifest.json",
    app / "Contents" / "MacOS" / "RepoPrompt",
    app / "Contents" / "MacOS" / "repoprompt-mcp",
]:
    require_regular_file(path)

top_level = {path.name for path in root.iterdir()}
expected_top_level = {".build", "LICENSE", "RELEASE_COMMIT", "THIRD_PARTY_NOTICES.md", "ThirdPartyLicenses", "version.env"}
if top_level != expected_top_level:
    fail(f"unexpected staged top-level entries: {sorted(top_level ^ expected_top_level)}")

cli_links = {
    app / "Contents" / "Resources" / "repoprompt-mcp": "../MacOS/repoprompt-mcp",
    app / "Contents" / "Resources" / "bin" / "repoprompt-mcp": "../../MacOS/repoprompt-mcp",
}
sparkle = app / "Contents" / "Frameworks" / "Sparkle.framework"
resolved_sparkle = sparkle.resolve(strict=False)
for path in root.rglob("*"):
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        resolved = path.resolve(strict=False)
        allowed = (
            path in cli_links and os.readlink(path) == cli_links[path]
        ) or (
            sparkle in path.parents and resolved.is_relative_to(resolved_sparkle)
        )
        if not allowed:
            fail(f"unexpected or escaping staged symlink: {path} -> {os.readlink(path)}")
    elif not stat.S_ISDIR(mode) and not stat.S_ISREG(mode):
        fail(f"unsupported staged path type: {path}")
PYTHON

"$SCRIPT_DIR/validate_required_swiftpm_resource_bundles.sh" "$APP_BUNDLE" "Staged app SwiftPM resource bundle layout"
"$SCRIPT_DIR/validate_embedded_mcp_helper_layout.sh" "$APP_BUNDLE" "Staged app MCP helper layout"
"$SCRIPT_DIR/validate_app_architectures.sh" "$APP_BUNDLE" "arm64,x86_64" "Staged public app"
"$SCRIPT_DIR/write_app_artifact_manifest.py" verify \
    --app "$APP_BUNDLE" \
    --manifest "$ROOT_DIR/.build/release/$APP_NAME-artifact-manifest.json" \
    --expected-architectures "arm64,x86_64"

[[ "$(cat "$ROOT_DIR/RELEASE_COMMIT")" == "$RELEASE_COMMIT" ]] ||
    fail "Staged release commit does not match approved commit"
cmp "$ROOT_DIR/LICENSE" "$APPROVED_SOURCE_ROOT/LICENSE" ||
    fail "Staged LICENSE does not match approved source"
cmp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APPROVED_SOURCE_ROOT/THIRD_PARTY_NOTICES.md" ||
    fail "Staged third-party notices do not match approved source"
diff -qr "$ROOT_DIR/ThirdPartyLicenses" "$APPROVED_SOURCE_ROOT/ThirdPartyLicenses" ||
    fail "Staged third-party licenses do not match approved source"
REPOPROMPT_RELEASE_SOURCE_ROOT="$APPROVED_SOURCE_ROOT" \
    "$SCRIPT_DIR/validate_packaged_legal.sh" "$APP_BUNDLE"

python3 - "$APPROVED_SOURCE_ROOT/AppBundle/Info.plist.template" "$APP_BUNDLE/Contents/Info.plist" \
    "$APP_NAME" "$DISPLAY_NAME" "$BUNDLE_ID" "$MARKETING_VERSION" "$BUILD_NUMBER" <<'PYTHON'
import plistlib
import sys
from pathlib import Path

template, actual, app_name, display_name, bundle_id, version, build = sys.argv[1:]
text = Path(template).read_text(encoding="utf-8")
for key, value in {
    "__APP_NAME__": app_name,
    "__DISPLAY_NAME__": display_name,
    "__BUNDLE_ID__": bundle_id,
    "__MARKETING_VERSION__": version,
    "__BUILD_NUMBER__": build,
    "__DEBUG_SECURE_STORAGE_BACKEND__": "alternate-in-memory",
    "__SIGNING_MODE__": "release-candidate-adhoc",
    "__LOCAL_SIGNING_CERTIFICATE_SHA256__": "",
    "__LOCAL_SECURE_STORAGE_GENERATION__": "",
}.items():
    text = text.replace(key, value)
if plistlib.loads(text.encode("utf-8")) != plistlib.loads(Path(actual).read_bytes()):
    raise SystemExit("ERROR: staged Info.plist does not match the approved release candidate")
PYTHON

printf 'OK: staged release payload matches approved source and confined path policy.\n'
