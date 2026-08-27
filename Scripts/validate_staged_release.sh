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

TIP_ROLLOUT_DECLARATION_NAME=""
TIP_CONTEXT_MODE=0
case "${REPOPROMPT_TIP_ARCHIVE_CONTRACT:-}" in
    "") ;;
    tip-rollout-v1)
        TIP_CONTEXT_MODE=1
        TIP_ROLLOUT_DECLARATION_NAME="tip-rollout.json"
        ;;
    *) fail "Unsupported REPOPROMPT_TIP_ARCHIVE_CONTRACT: $REPOPROMPT_TIP_ARCHIVE_CONTRACT" ;;
esac

source "$SCRIPT_DIR/load_release_metadata.sh"
if (( TIP_CONTEXT_MODE )); then
    load_verified_tip_release_context \
        "$SCRIPT_DIR" \
        "$APPROVED_SOURCE_ROOT" \
        "validate-staged-release" \
        "$ROOT_DIR" || fail "Unable to verify the staged Tip release context"
    [[ -f "$APPROVED_SOURCE_ROOT/$TIP_ROLLOUT_DECLARATION_NAME" ]] ||
        fail "Missing approved Tip rollout declaration"
    [[ -f "$ROOT_DIR/$TIP_ROLLOUT_DECLARATION_NAME" ]] ||
        fail "missing staged file: $ROOT_DIR/$TIP_ROLLOUT_DECLARATION_NAME"
    RELEASE_COMMIT="$TIP_COMMIT"
    BUILD_NUMBER="$TIP_BUILD_NUMBER"

    python3 - \
        "$ROOT_DIR/version.env" \
        "$APP_NAME" \
        "$DISPLAY_NAME" \
        "$MARKETING_VERSION" \
        "$TIP_BUILD_NUMBER" \
        "$BUNDLE_ID" \
        "$SIGNING_TEAM_ID" <<'PYTHON'
import sys
from pathlib import Path

staged_path, app_name, display_name, marketing, build, bundle_id, team_id = sys.argv[1:]

def parse(path: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"ERROR: invalid staged release metadata line: {raw_line}")
        key, value = line.split("=", 1)
        if key in values:
            raise SystemExit(f"ERROR: duplicate staged release metadata key: {key}")
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        values[key] = value
    return values

staged = parse(staged_path)
expected = {
    "APP_NAME": app_name,
    "DISPLAY_NAME": display_name,
    "MARKETING_VERSION": marketing,
    "BUILD_NUMBER": build,
    "BUNDLE_ID": bundle_id,
    "SIGNING_TEAM_ID": team_id,
}
if staged != expected:
    mismatches = sorted(
        key for key in set(staged) | set(expected) if staged.get(key) != expected.get(key)
    )
    raise SystemExit(
        "ERROR: staged version.env does not match the verified Tip release context: "
        + ", ".join(mismatches)
    )
PYTHON
else
    [[ -n "${RELEASE_COMMIT:-}" ]] ||
        fail "Missing required environment variable: RELEASE_COMMIT"
    if [[ -n "${REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE:-}" ]]; then
        [[ "$REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE" =~ ^[0-9]{1,4}(\.[0-9]{1,2}){0,2}$ ]] ||
            fail "REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE must be a valid numeric build version"
        python3 - \
            "$ROOT_DIR/version.env" \
            "$APPROVED_SOURCE_ROOT/version.env" \
            "$REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE" <<'PYTHON'
import sys
from pathlib import Path

staged_path, approved_path, build_override = sys.argv[1:]

def parse(path: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        values[key] = value
    return values

staged = parse(staged_path)
expected = parse(approved_path)
expected["BUILD_NUMBER"] = build_override
if staged != expected:
    mismatches = sorted(
        key for key in set(staged) | set(expected) if staged.get(key) != expected.get(key)
    )
    raise SystemExit(
        "ERROR: staged version.env does not match approved source plus reviewed release projections: "
        + ", ".join(mismatches)
    )
PYTHON
    else
        cmp "$ROOT_DIR/version.env" "$APPROVED_SOURCE_ROOT/version.env" ||
            fail "Staged version.env does not match approved source"
    fi
    load_release_metadata "$APPROVED_SOURCE_ROOT"
    if [[ -n "${REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE:-}" ]]; then
        BUILD_NUMBER="$REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE"
    fi
fi

APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"

python3 - "$ROOT_DIR" "$APP_BUNDLE" "$TIP_ROLLOUT_DECLARATION_NAME" <<'PYTHON'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
app = Path(sys.argv[2])
tip_rollout_declaration_name = sys.argv[3]

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
if tip_rollout_declaration_name:
    require_regular_file(root / tip_rollout_declaration_name)
    require_regular_file(root / "tip-release-context.json")
    require_regular_file(root / "tip-release-context.json.sha256")

top_level = {path.name for path in root.iterdir()}
expected_top_level = {".build", "LICENSE", "RELEASE_COMMIT", "THIRD_PARTY_NOTICES.md", "ThirdPartyLicenses", "version.env"}
if tip_rollout_declaration_name:
    expected_top_level.update(
        {
            tip_rollout_declaration_name,
            "tip-release-context.json",
            "tip-release-context.json.sha256",
        }
    )
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

if [[ -n "$TIP_ROLLOUT_DECLARATION_NAME" ]]; then
    [[ -f "$APPROVED_SOURCE_ROOT/$TIP_ROLLOUT_DECLARATION_NAME" ]] ||
        fail "Missing approved Tip rollout declaration"
    cmp "$ROOT_DIR/$TIP_ROLLOUT_DECLARATION_NAME" "$APPROVED_SOURCE_ROOT/$TIP_ROLLOUT_DECLARATION_NAME" ||
        fail "Staged Tip rollout declaration does not match approved source"
fi

"$SCRIPT_DIR/validate_required_swiftpm_resource_bundles.sh" "$APP_BUNDLE" "Staged app SwiftPM resource bundle layout"
"$SCRIPT_DIR/validate_embedded_mcp_helper_layout.sh" "$APP_BUNDLE" "Staged app MCP helper layout"
"$SCRIPT_DIR/validate_app_architectures.sh" "$APP_BUNDLE" "arm64,x86_64" "Staged public app"
python3 "$SCRIPT_DIR/codex_runtime_artifact.py" \
    --manifest "$APPROVED_SOURCE_ROOT/Vendor/Codex/manifest.json" verify-bundle \
    --arch all \
    --bundle "$APP_BUNDLE/Contents/Resources/BundledRuntimes/Codex"
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
    "$APP_NAME" "$DISPLAY_NAME" "$BUNDLE_ID" "$MARKETING_VERSION" "$BUILD_NUMBER" \
    "${REPOPROMPT_IDENTITY_MIGRATION_PHASE:-disabled}" <<'PYTHON'
import plistlib
import sys
from pathlib import Path

template, actual, app_name, display_name, bundle_id, version, build, identity_migration_phase = sys.argv[1:]
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
    "__IDENTITY_MIGRATION_PHASE__": identity_migration_phase,
}.items():
    text = text.replace(key, value)
expected_plist = plistlib.loads(text.encode("utf-8"))
actual_plist = plistlib.loads(Path(actual).read_bytes())
if expected_plist != actual_plist:
    raise SystemExit("ERROR: staged Info.plist does not match the approved release candidate")
actual_identity_migration_phase = actual_plist.get("RepoPromptIdentityMigrationPhase", "disabled")
if actual_identity_migration_phase != identity_migration_phase:
    raise SystemExit(
        "ERROR: staged identity migration phase mismatch: "
        f"expected {identity_migration_phase}, got {actual_identity_migration_phase}"
    )
PYTHON

printf 'OK: staged release payload matches approved source and confined path policy.\n'
