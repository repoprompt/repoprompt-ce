#!/usr/bin/env bash
set -euo pipefail

# Shared read-only history boundary. The publisher sources only this section so
# signing and publication resolve the SAME releases/latest API snapshot, never a
# second releases/latest/download pointer. No credentials are needed for signing.
tip_history_context() {
    HISTORY_SCRIPTS_DIR="$1"
    HISTORY_TOOL="$1/tip_history.py"
    HISTORY_ADMISSION_TOOL="$1/tip_history_admission.py"
    HISTORY_APPLE_POLICY="$1/apple_identity_policy.json"
    HISTORY_POLICY="$1/tip_history_policy.json"
    [[ -f "$HISTORY_POLICY" ]] || HISTORY_POLICY="$1/tip_history_policy.example.json"
    [[ -f "$HISTORY_POLICY" && ! -L "$HISTORY_POLICY" ]] || {
        printf 'ERROR: missing reviewed or explicitly inactive Tip history policy\n' >&2; return 1;
    }
    HISTORY_ACTIVE="$(python3 - "$HISTORY_POLICY" <<'PY'
import json, re, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
if p.get("schemaVersion") != 1 or "historyEnabledSinceTag" not in p:
    raise SystemExit("ERROR: malformed Tip history activation policy")
tag = p["historyEnabledSinceTag"]
if tag is not None and (not isinstance(tag, str) or not re.fullmatch(r"tip-[0-9a-f]{12}", tag)):
    raise SystemExit("ERROR: malformed Tip history activation tag")
print("false" if tag is None else "true")
PY
)" || return 1
}

tip_history_verify_signature() {
    local envelope="$1" work="$2"
    mkdir -p "$work" || return 1
    python3 "$HISTORY_TOOL" extract --envelope "$envelope" \
        --message-output "$work/message" --signature-output "$work/signature" || return 1
    python3 - "$HISTORY_APPLE_POLICY" > "$work/public-key" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["sparkle"]["sparklePublicEdDSAValue"])
PY
    xcrun swift "$HISTORY_SCRIPTS_DIR/verify_sparkle_signature.swift" \
        "$work/public-key" "$(cat "$work/signature")" "$work/message"
}

# Optional second argument is the exact API response already used for rollout
# progression by the publisher. JSON null means a confirmed API 404, not bootstrap
# permission. Write a pinned versioned parent, or leave it absent for admission to
# require the reviewed activation/bootstrap evidence.
tip_history_resolve_parent() {
    local work="$1" snapshot="${2:-}" status report tag url size digest actual
    mkdir -p "$work" || return 1
    rm -f "$work/parent-envelope.json" || return 1
    if [[ -z "$snapshot" ]]; then
        snapshot="$work/release.json"
        status="$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
            -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
            --output "$snapshot" --write-out '%{http_code}' \
            "https://api.github.com/repos/$TIP_UPDATE_REPOSITORY/releases/latest")" || return 1
        case "$status" in
            200) ;;
            404) printf 'null\n' > "$snapshot" ;;
            *) printf 'ERROR: Tip history parent lookup HTTP %s\n' "$status" >&2; return 1 ;;
        esac
    fi
    cp "$snapshot" "$work/resolved-release.json" || return 1
    report="$(python3 - "$snapshot" "$TIP_UPDATE_REPOSITORY" <<'PY'
import json, re, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
if r is None:
    print("none||||")
    raise SystemExit(0)
if not isinstance(r, dict) or r.get("draft") is not False or r.get("prerelease") is not False:
    raise SystemExit("ERROR: history parent must be a public non-prerelease")
tag = r.get("tag_name")
if not isinstance(tag, str) or not re.fullmatch(r"tip-[0-9a-f]{12}", tag):
    raise SystemExit("ERROR: malformed history parent release tag")
assets = r.get("assets")
if not isinstance(assets, list):
    raise SystemExit("ERROR: malformed history parent assets")
a = [a for a in assets if isinstance(a, dict) and a.get("name") == "tip-history.json"]
if len(a) > 1:
    raise SystemExit("ERROR: duplicate live tip-history.json")
if not a:
    print(f"{tag}||||")
    raise SystemExit(0)
a = a[0]
url = f"https://github.com/{sys.argv[2]}/releases/download/{tag}/tip-history.json"
if a.get("state") != "uploaded" or a.get("browser_download_url") != url:
    raise SystemExit("ERROR: invalid versioned history parent asset")
size = a.get("size")
if type(size) is not int or not 0 < size <= 1024 * 1024:
    raise SystemExit("ERROR: history parent exceeds envelope bounds")
digest = a.get("digest")
if digest is not None and (not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
    raise SystemExit("ERROR: malformed history parent asset digest")
print(f"{tag}|{url}|{size}|{(digest or '').removeprefix('sha256:')}|")
PY
)" || return 1
    IFS='|' read -r tag url size digest actual <<< "$report"
    printf '%s\n' "$tag" > "$work/live-tag"
    if [[ -z "$url" ]]; then
        return 0
    fi
    [[ "$HISTORY_ACTIVE" == true ]] || {
        printf 'ERROR: live Tip history exists but activation policy is inactive; never reset history\n' >&2; return 1;
    }
    curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
        "$url" --output "$work/parent-envelope.json" || return 1
    actual="$(wc -c < "$work/parent-envelope.json" | tr -d '[:space:]')"
    [[ "$actual" == "$size" ]] || { printf 'ERROR: history parent size mismatch\n' >&2; return 1; }
    actual="$(shasum -a 256 "$work/parent-envelope.json" | awk '{print $1}')"
    [[ -z "$digest" || "$actual" == "$digest" ]] || {
        printf 'ERROR: history parent digest mismatch\n' >&2; return 1;
    }
    tip_history_verify_signature "$work/parent-envelope.json" "$work/verify-parent" || return 1
    python3 "$HISTORY_ADMISSION_TOOL" verify-parent --envelope "$work/parent-envelope.json" \
        --tag "$tag" --sha256 "$actual"
}

# Resolve only a policy-pinned file inside the approved source. This is an audit
# input, not an API-enumeration shortcut or a fabricated no-history assertion.
tip_history_bootstrap_path() {
    python3 - "$HISTORY_POLICY" "$1" <<'PY'
import json, pathlib, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
root = pathlib.Path(sys.argv[2]).resolve()
name = p.get("bootstrapEvidenceFile")
if not isinstance(name, str) or not name or pathlib.Path(name).is_absolute():
    raise SystemExit("ERROR: reviewed bootstrapEvidenceFile required")
path = (root / name).resolve()
if not path.is_relative_to(root) or not path.is_file():
    raise SystemExit("ERROR: bootstrap evidence must exist inside approved source")
print(path)
PY
}

tip_history_require_bootstrap_parent() {
    local bootstrap="$1" snapshot="$2"
    python3 - "$HISTORY_POLICY" "$bootstrap" "$snapshot" "$TIP_TAG" <<'PY'
import hashlib, json, sys
policy, bootstrap, live = (json.load(open(p, encoding="utf-8")) for p in sys.argv[1:4])
if sys.argv[4] != policy.get("historyEnabledSinceTag"):
    raise SystemExit("ERROR: activated Tip history is missing its parent catalog; recovery required, never bootstrap")
canonical = json.dumps(bootstrap, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode() + b"\n"
if hashlib.sha256(canonical).hexdigest() != policy.get("bootstrapEvidenceSha256") or bootstrap.get("historyNeverEnabled") is not True:
    raise SystemExit("ERROR: bootstrap evidence is not the reviewed never-enabled snapshot")
# The mutable API response is NOT hashed (download counts can change). The
# approved immutable release tag must still be the authoritative latest parent.
expected = bootstrap.get("liveParent")
if "liveParent" not in bootstrap or (None if live is None else live.get("tag_name")) != expected:
    raise SystemExit("ERROR: Tip history parent superseded: bootstrap liveParent mismatch")
PY
}

# An already-public exact candidate is a read-only reconciliation, not a new
# child of itself. Recover its original hash-pinned parent for full re-derivation.
tip_history_reaudit_parent() {
    local envelope="$1" source="$2" work="$3" reference tag digest status bootstrap
    [[ "$(cat "$work/live-tag")" == "$TIP_TAG" ]] || return 0
    cmp "$envelope" "$work/parent-envelope.json" || {
        printf 'ERROR: already-public Tip catalog differs from candidate bytes\n' >&2; return 1;
    }
    reference="$(python3 - "$envelope" <<'PY'
import base64, json, sys
p = json.loads(base64.b64decode(json.load(open(sys.argv[1]))["payload"], validate=True))
e = p["entries"][1] if len(p["entries"]) > 1 else None
if e and e.get("historyCatalogSha256"):
    print(e["tag"] + "|" + e["historyCatalogSha256"])
else:
    print("|")
PY
)" || return 1
    IFS='|' read -r tag digest <<< "$reference"
    if [[ -z "$tag" ]]; then
        bootstrap="$(tip_history_bootstrap_path "$source")" || return 1
        tag="$(python3 - "$bootstrap" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
if "liveParent" not in p:
    raise SystemExit("ERROR: bootstrap requires explicit liveParent")
print(p["liveParent"] or "none")
PY
)" || return 1
    fi
    if [[ "$tag" == none ]]; then
        printf 'null\n' > "$work/original-release.json"
    else
        [[ "$tag" =~ ^tip-[0-9a-f]{12}$ && "$tag" != "$TIP_TAG" ]] || return 1
        status="$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
            -H 'Accept: application/vnd.github+json' --output "$work/original-release.json" \
            --write-out '%{http_code}' \
            "https://api.github.com/repos/$TIP_UPDATE_REPOSITORY/releases/tags/$tag")" || return 1
        [[ "$status" == 200 ]] || { printf 'ERROR: original history parent unavailable\n' >&2; return 1; }
        python3 - "$work/original-release.json" "$tag" <<'PY' || return 1
import json, sys
if json.load(open(sys.argv[1])).get("tag_name") != sys.argv[2]:
    raise SystemExit("ERROR: original history parent tag mismatch")
PY
    fi
    tip_history_resolve_parent "$work/original" "$work/original-release.json" || return 1
    if [[ -n "$digest" ]]; then
        [[ -f "$work/original/parent-envelope.json" ]] || return 1
        [[ "$(shasum -a 256 "$work/original/parent-envelope.json" | awk '{print $1}')" == "$digest" ]] || {
            printf 'ERROR: original history parent digest mismatch\n' >&2; return 1;
        }
    else
        [[ ! -f "$work/original/parent-envelope.json" ]] || return 1
    fi
    rm -f "$work/parent-envelope.json" || return 1
    if [[ -f "$work/original/parent-envelope.json" ]]; then
        cp "$work/original/parent-envelope.json" "$work/parent-envelope.json" || return 1
    fi
    cp "$work/original/resolved-release.json" "$work/resolved-release.json"
}

tip_history_archive_expanded_size() {
    python3 - "$1" <<'PY'
import pathlib, sys, zipfile
path = pathlib.Path(sys.argv[1])
if not path.is_file() or path.is_symlink() or not 0 < path.stat().st_size <= 2 * 1024**3:
    raise SystemExit("ERROR: history ZIP archive bounds invalid")
with zipfile.ZipFile(path) as z:
    entries = z.infolist()
    if len(entries) > 100000:
        raise SystemExit("ERROR: history ZIP entry limit exceeded")
    total = 0
    for i in entries:
        name = i.filename
        parts = pathlib.PurePosixPath(name).parts
        if not parts or parts[0] != "RepoPrompt CE.app" or name.startswith("/") or ".." in parts or "\\" in name or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in name):
            raise SystemExit("ERROR: history ZIP layout is not the expected app")
        if not i.is_dir():
            total += i.file_size
    if not 0 < total <= 8 * 1024**3:
        raise SystemExit("ERROR: history ZIP expanded bounds invalid")
    print(total)
PY
}

tip_history_verify_candidate() {
    local envelope="$1" manifest="$2" artifact="$3" metadata="$4" source="$5" work="$6"
    local bootstrap expanded_size enclosure_path
    [[ "$(git -C "$source" rev-parse HEAD)" == "$TIP_COMMIT" ]] || {
        printf 'ERROR: history validation requires approved source HEAD\n' >&2; return 1;
    }
    [[ "$(git -C "$source" rev-parse --is-shallow-repository)" == false ]] || {
        printf 'ERROR: history validation requires full approved source history\n' >&2; return 1;
    }
    local verify_args=(--envelope "$envelope")
    if [[ -f "$work/parent-envelope.json" ]]; then
        verify_args+=(--parent-envelope "$work/parent-envelope.json")
    else
        bootstrap="$(tip_history_bootstrap_path "$source")" || return 1
        tip_history_require_bootstrap_parent "$bootstrap" "$work/resolved-release.json" || return 1
        verify_args+=(--bootstrap "$bootstrap")
    fi
    # Metadata is independently bound; expanded size is re-measured from the
    # actual checksum/manifest-bound ZIP, never trusted from the signed head.
    enclosure_path="$(python3 - "$manifest" "$metadata" <<'PY'
import json, pathlib, sys
m, metadata = (json.load(open(p, encoding="utf-8")) for p in sys.argv[1:])
for key, expected in {"commit": m["releaseCommit"], "short_sha": m["releaseCommit"][:12], "tag": m["sourceTag"], "marketing_version": m["marketingVersion"], "build_number": m["buildNumber"], "rollout_role": m["currentRole"], "signing_identity": m["signingIdentity"], "migration_phase": m["migrationPhase"]}.items():
    if metadata.get(key) != expected:
        raise SystemExit(f"ERROR: history metadata binding mismatch: {key}")
head = m["appcastItems"][0]
name = head["enclosureName"]
if not isinstance(name, str) or pathlib.Path(name).name != name or "/" in name or "\\" in name:
    raise SystemExit("ERROR: invalid history enclosure filename")
print(pathlib.Path(sys.argv[1]).parent / name if head["installationType"] == "application" else "")
PY
)" || return 1
    expanded_size=0
    if [[ -n "$enclosure_path" ]]; then
        expanded_size="$(tip_history_archive_expanded_size "$enclosure_path")" || return 1
    fi
    python3 "$HISTORY_ADMISSION_TOOL" verify-candidate "${verify_args[@]}" \
        --apple-policy "$HISTORY_APPLE_POLICY" --policy "$HISTORY_POLICY" --source "$source" \
        --manifest "$manifest" --app-artifact-manifest "$artifact" --expanded-size "$expanded_size"
}

if [[ "${REPOPROMPT_TIP_HISTORY_LIBRARY_ONLY:-0}" == 1 ]]; then
    return 0
fi

MODE="${1:-stage}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONTROL_PLANE_SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$SCRIPT_DIR}"
TRUSTED_ROOT="$(cd "$CONTROL_PLANE_SCRIPTS_DIR/.." && pwd)"
APPROVED_SOURCE_ROOT="${REPOPROMPT_APPROVED_SOURCE_ROOT:-$ROOT_DIR}"
CODEX_MANIFEST="$APPROVED_SOURCE_ROOT/Vendor/Codex/manifest.json"
cd "$ROOT_DIR"

source "$CONTROL_PLANE_SCRIPTS_DIR/load_release_metadata.sh"
source "$CONTROL_PLANE_SCRIPTS_DIR/release_sentry_symbols.sh"
load_release_metadata "$ROOT_DIR"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ROLLOUT_TOOL="$CONTROL_PLANE_SCRIPTS_DIR/stable_rollout.py"
APPLE_IDENTITY_POLICY="$CONTROL_PLANE_SCRIPTS_DIR/apple_identity_policy.json"
ROLLOUT_DECLARATION="$ROOT_DIR/tip-rollout.json"
[[ -f "$ROLLOUT_TOOL" && -f "$APPLE_IDENTITY_POLICY" && -f "$ROLLOUT_DECLARATION" ]] ||
    fail "Tip identity rollout authority is incomplete"
eval "$(python3 "$ROLLOUT_TOOL" packaging-context \
    --declaration "$ROLLOUT_DECLARATION" \
    --policy "$APPLE_IDENTITY_POLICY" \
    --version-env "$ROOT_DIR/version.env")"
[[ "$ROLLOUT_CHANNEL" == "tip" ]] || fail "Tip release requires a Tip rollout declaration"
TIP_PUBLISH_INSTALLATION_TYPE="${TIP_PUBLISH_INSTALLATION_TYPE:-$ROLLOUT_INSTALLATION_TYPE}"

TIP_COMMIT="${TIP_COMMIT:-$(git rev-parse HEAD)}"
TIP_SHORT_SHA="${TIP_SHORT_SHA:-${TIP_COMMIT:0:12}}"
if [[ -z "${TIP_BUILD_NUMBER:-}" ]]; then
    TIP_BUILD_SEQUENCE="${TIP_BUILD_SEQUENCE:-$(git rev-list --count "$TIP_COMMIT")}"
    TIP_BUILD_SEQUENCE="${TIP_BUILD_SEQUENCE//[[:space:]]/}"
    [[ "$TIP_BUILD_SEQUENCE" =~ ^[0-9]+$ ]] || fail "TIP_BUILD_SEQUENCE must be numeric"
    (( TIP_BUILD_SEQUENCE <= 9999 )) || fail "TIP_BUILD_SEQUENCE must not exceed 9999"
    TIP_BUILD_NUMBER="$BUILD_NUMBER.$((TIP_BUILD_SEQUENCE / 100)).$((TIP_BUILD_SEQUENCE % 100))"
fi
TIP_BUILD_NUMBER="${TIP_BUILD_NUMBER//[[:space:]]/}"
TIP_TAG="${TIP_TAG:-tip-$TIP_SHORT_SHA}"
TIP_UPDATE_REPOSITORY="${TIP_UPDATE_REPOSITORY:-repoprompt/repoprompt-ce-tip-updates}"
[[ "$TIP_UPDATE_REPOSITORY" == "$ROLLOUT_UPDATE_REPOSITORY" ]] ||
    fail "TIP_UPDATE_REPOSITORY must match the reviewed identity policy"
TIP_GH_TOKEN="${TIP_GH_TOKEN:-}"

DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$ROOT_DIR/.build/release/$APP_NAME.app"
DISTRIBUTION_APP_BUNDLE_NAME="$DISPLAY_NAME.app"
ARCHIVE_BASENAME="$APP_NAME-tip-$TIP_SHORT_SHA-$TIP_BUILD_NUMBER"
UPDATE_ZIP="$DIST_DIR/$ARCHIVE_BASENAME.zip"
DMG="$DIST_DIR/$ARCHIVE_BASENAME.dmg"
TRANSITION_PKG="$DIST_DIR/$ARCHIVE_BASENAME.pkg"
if [[ "$ROLLOUT_INSTALLATION_TYPE" == "package" ]]; then
    ENCLOSURE="$TRANSITION_PKG"
else
    ENCLOSURE="$UPDATE_ZIP"
fi
APPCAST="$DIST_DIR/appcast.xml"
CHECKSUMS="$DIST_DIR/SHA256SUMS"
BUILD_ARTIFACT_MANIFEST="$ROOT_DIR/.build/release/$APP_NAME-artifact-manifest.json"
SENTRY_SYMBOLS_DIR="$ROOT_DIR/.build/sentry-symbols/release"
FINAL_ARTIFACT_MANIFEST="$DIST_DIR/$ARCHIVE_BASENAME-artifact-manifest.json"
FINAL_METADATA="$DIST_DIR/$ARCHIVE_BASENAME-metadata.json"
ROLLOUT_MANIFEST="$DIST_DIR/identity-rollout.json"
HISTORY_ENVELOPE="$DIST_DIR/tip-history.json"
tip_history_context "$CONTROL_PLANE_SCRIPTS_DIR"
STAGE_ARCHIVE="$DIST_DIR/$ARCHIVE_BASENAME-stage.zip"
STAGE_ARCHIVE_CHECKSUM="$STAGE_ARCHIVE.sha256"
RUN_WITHOUT_GITHUB_TOKENS="$CONTROL_PLANE_SCRIPTS_DIR/run_without_github_tokens.sh"
SIGN_UPDATE="$TRUSTED_ROOT/Vendor/Sparkle/bin/sign_update"
PUBLISH_TIP_RELEASE="$CONTROL_PLANE_SCRIPTS_DIR/publish_tip_release.sh"
TMP_DIR=""
PHASE_LABEL=""
PHASE_START_EPOCH=""

require_command() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_env() { [[ -n "${!1:-}" ]] || fail "Missing required environment variable: $1"; }
require_file() { [[ -f "$1" ]] || fail "Missing required file: $1"; }
cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"; }
finish() {
    local status="$1"
    trap - EXIT
    cleanup
    if [[ -n "$PHASE_LABEL" ]]; then
        local end_epoch end_utc elapsed outcome
        end_epoch="$(date -u +%s)"
        end_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        elapsed=$((end_epoch - PHASE_START_EPOCH))
        if (( status == 0 )); then outcome="success"; else outcome="failure"; fi
        printf 'PHASE END: %s utc=%s elapsed_seconds=%s status=%s\n' \
            "$PHASE_LABEL" "$end_utc" "$elapsed" "$outcome"
    fi
    exit "$status"
}
start_phase() {
    PHASE_LABEL="$1"
    PHASE_START_EPOCH="$(date -u +%s)"
    printf 'PHASE START: %s utc=%s\n' "$PHASE_LABEL" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
trap 'finish $?' EXIT

prepare_dist() {
    [[ "$DIST_DIR" != "/" ]] || fail "DIST_DIR must not be /"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
}

write_tip_version_env() {
    local output="$1"
    cat > "$output" <<VERSION_ENV
APP_NAME=$APP_NAME
DISPLAY_NAME="$DISPLAY_NAME"
MARKETING_VERSION=$MARKETING_VERSION
BUILD_NUMBER=$TIP_BUILD_NUMBER
BUNDLE_ID=$BUNDLE_ID
SIGNING_TEAM_ID=$SIGNING_TEAM_ID
VERSION_ENV
}

validate_public_app() {
    local app_bundle="$1"
    local manifest="$2"
    local label="$3"
    local signed_team_identifier="${4:-}"
    "$CONTROL_PLANE_SCRIPTS_DIR/validate_embedded_mcp_helper_layout.sh" "$app_bundle" "$label MCP helper layout"
    "$CONTROL_PLANE_SCRIPTS_DIR/validate_app_architectures.sh" "$app_bundle" "arm64,x86_64" "$label architectures"
    local codex_verification_args=(
        --manifest "$CODEX_MANIFEST" verify-bundle
        --arch all
        --bundle "$app_bundle/Contents/Resources/BundledRuntimes/Codex"
    )
    if [[ -n "$signed_team_identifier" ]]; then
        codex_verification_args+=(--signed-team-identifier "$signed_team_identifier")
    fi
    python3 "$CONTROL_PLANE_SCRIPTS_DIR/codex_runtime_artifact.py" "${codex_verification_args[@]}"
    "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py" verify \
        --app "$app_bundle" \
        --manifest "$manifest" \
        --expected-architectures "arm64,x86_64"
}

validate_distribution_zip() {
    local archive="$1"
    local manifest="$2"
    local label="$3"
    local signed_team_identifier="${4:-}"
    local extract_dir="$TMP_DIR/${label//[^A-Za-z0-9]/-}-extract"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    ditto -x -k "$archive" "$extract_dir"
    local extracted_app="$extract_dir/$DISTRIBUTION_APP_BUNDLE_NAME"
    [[ -d "$extracted_app" ]] || fail "$label ZIP must contain $DISTRIBUTION_APP_BUNDLE_NAME at its root"
    validate_public_app "$extracted_app" "$manifest" "$label extracted app" "$signed_team_identifier"
    if [[ "$HISTORY_ACTIVE" == true ]]; then
        local actual_expanded_size expected_expanded_size
        actual_expanded_size="$(python3 - "$extracted_app" <<'PY'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1])
total = 0
for directory, dirs, files in os.walk(root, followlinks=False):
    for name in files:
        total += (pathlib.Path(directory) / name).lstat().st_size
    for name in dirs:
        path = pathlib.Path(directory) / name
        if path.is_symlink():
            total += path.lstat().st_size
print(total)
PY
)"
        expected_expanded_size="$(tip_history_archive_expanded_size "$archive")"
        [[ "$actual_expanded_size" == "$expected_expanded_size" ]] ||
            fail "$label extracted app byte count differs from its final ZIP"
    fi
}

resolve_without_lockfile_drift() {
    require_command cmp
    require_command swift

    local before_lockfile
    before_lockfile="$(mktemp)"
    cp "$ROOT_DIR/Package.resolved" "$before_lockfile"
    "$RUN_WITHOUT_GITHUB_TOKENS" swift package resolve
    cmp "$before_lockfile" "$ROOT_DIR/Package.resolved" ||
        fail "swift package resolve changed Package.resolved; commit the intentional lockfile update before packaging"
    rm -f "$before_lockfile"
}

validate_packaged_legal() {
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/validate_packaged_legal.sh" "$1"
}

write_tip_metadata() {
    cat > "$FINAL_METADATA" <<JSON
{"commit":"$TIP_COMMIT","short_sha":"$TIP_SHORT_SHA","tag":"$TIP_TAG","marketing_version":"$MARKETING_VERSION","build_number":"$TIP_BUILD_NUMBER","rollout_role":"$ROLLOUT_ROLE","signing_identity":"$ROLLOUT_IDENTITY","migration_phase":"$REPOPROMPT_IDENTITY_MIGRATION_PHASE"}
JSON
}

require_tip_sentry_configuration() {
    release_sentry_linking_enabled ||
        fail "Official Tip signing requires REPOPROMPT_ENABLE_SENTRY=1"
    require_env SENTRY_DSN
    require_env REPOPROMPT_SENTRY_AUTH_TOKEN_FILE
    require_file "$REPOPROMPT_SENTRY_AUTH_TOKEN_FILE"
    [[ -s "$REPOPROMPT_SENTRY_AUTH_TOKEN_FILE" ]] || fail "Tip Sentry auth token file must not be empty"
    require_env REPOPROMPT_SENTRY_ORG
    require_env REPOPROMPT_SENTRY_PROJECT
    require_command sentry-cli
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/upload_sentry_debug_symbols.sh"
}

assert_tip_manifest_telemetry_enabled() {
    python3 - "$FINAL_ARTIFACT_MANIFEST" <<'PYTHON'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if manifest.get("bundle", {}).get("telemetry_enabled") is not True:
    raise SystemExit("ERROR: final Tip artifact manifest must record telemetry_enabled=true")
PYTHON
}

stage_tip() {
    require_command ditto
    require_command curl
    require_command git
    require_command shasum
    [[ "$TIP_BUILD_NUMBER" =~ ^[0-9]{1,4}\.[0-9]{1,2}\.[0-9]{1,2}$ ]] ||
        fail "TIP_BUILD_NUMBER must be a three-component numeric build version"
    resolve_without_lockfile_drift
    "$CONTROL_PLANE_SCRIPTS_DIR/release.sh" preflight
    prepare_dist
    "$RUN_WITHOUT_GITHUB_TOKENS" env -u SIGN_IDENTITY \
        REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR="$CONTROL_PLANE_SCRIPTS_DIR" \
        MARKETING_VERSION="$MARKETING_VERSION" \
        BUNDLE_ID="$BUNDLE_ID" \
        SIGNING_TEAM_ID="$SIGNING_TEAM_ID" \
        REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER" \
        REPOPROMPT_TIP_ARCHIVE_CONTRACT=tip-rollout-v1 \
        REPOPROMPT_IDENTITY_MIGRATION_PHASE="$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
        REPOPROMPT_ENABLE_SENTRY=1 \
        RELEASE_ALLOW_ADHOC_SIGNING=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/package_app.sh" release
    "$CONTROL_PLANE_SCRIPTS_DIR/release.sh" preflight
    validate_packaged_legal "$APP_BUNDLE"
    validate_public_app "$APP_BUNDLE" "$BUILD_ARTIFACT_MANIFEST" "Tip staging"
    REPOPROMPT_ENABLE_SENTRY=1 require_release_sentry_symbols_when_enabled \
        "$SENTRY_SYMBOLS_DIR" \
        "$APP_NAME.dSYM" \
        "$APP_NAME" \
        "repoprompt-mcp.dSYM" \
        "repoprompt-mcp"

    TMP_DIR="$(mktemp -d)"
    local stage_root="$TMP_DIR/tip-stage"
    mkdir -p "$stage_root/.build/release"
    ditto "$APP_BUNDLE" "$stage_root/.build/release/$APP_NAME.app"
    cp "$BUILD_ARTIFACT_MANIFEST" "$stage_root/.build/release/$APP_NAME-artifact-manifest.json"
    REPOPROMPT_ENABLE_SENTRY=1 stage_release_sentry_symbols \
        "$SENTRY_SYMBOLS_DIR" \
        "$stage_root/.build/sentry-symbols/release" \
        "$APP_NAME.dSYM" \
        "$APP_NAME" \
        "repoprompt-mcp.dSYM" \
        "repoprompt-mcp"
    cp "$ROLLOUT_DECLARATION" "$stage_root/tip-rollout.json"
    write_tip_version_env "$stage_root/version.env"
    cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$stage_root/"
    cp -R "$ROOT_DIR/ThirdPartyLicenses" "$stage_root/"
    printf '%s\n' "$TIP_COMMIT" > "$stage_root/RELEASE_COMMIT"
    write_tip_metadata
    ditto -c -k --norsrc "$stage_root" "$STAGE_ARCHIVE"
    (cd "$DIST_DIR" && shasum -a 256 "$(basename "$STAGE_ARCHIVE")" > "$(basename "$STAGE_ARCHIVE_CHECKSUM")")
    printf 'OK: staged tip build %s (%s) for %s.\n' "$TIP_TAG" "$TIP_BUILD_NUMBER" "$TIP_COMMIT"
}

fetch_notarization_log() {
    local submission_id="$1"
    printf 'Fetching Apple notarization log for submission %s.\n' "$submission_id" >&2
    if ! xcrun notarytool log "$submission_id" \
        --key "$NOTARYTOOL_PRIVATE_KEY" \
        --key-id "$NOTARYTOOL_KEY_ID" \
        --issuer "$NOTARYTOOL_ISSUER_ID" \
        --output-format json; then
        printf 'WARNING: unable to retrieve Apple notarization log for submission %s.\n' "$submission_id" >&2
    fi
}

submit_notarization() {
    local artifact="$1"
    require_file "$artifact"
    require_env NOTARYTOOL_PRIVATE_KEY
    require_env NOTARYTOOL_KEY_ID
    require_env NOTARYTOOL_ISSUER_ID
    require_file "$NOTARYTOOL_PRIVATE_KEY"
    [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d)"

    local response_file submit_status fields submission_id submission_status
    response_file="$(mktemp "$TMP_DIR/notarytool-submit.XXXXXX")"
    if xcrun notarytool submit "$artifact" \
        --key "$NOTARYTOOL_PRIVATE_KEY" \
        --key-id "$NOTARYTOOL_KEY_ID" \
        --issuer "$NOTARYTOOL_ISSUER_ID" \
        --wait \
        --timeout "${NOTARYTOOL_TIMEOUT:-30m}" \
        --output-format json > "$response_file"; then
        submit_status=0
    else
        submit_status=$?
    fi
    cat "$response_file"

    fields="$(python3 - "$response_file" <<'PYTHON'
import json
import sys
import uuid
from pathlib import Path

try:
    response = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    print("|")
    raise SystemExit(0)
submission_id = response.get("id", "")
status = response.get("status", "")
try:
    submission_id = str(uuid.UUID(str(submission_id))) if submission_id else ""
except (ValueError, AttributeError, TypeError):
    submission_id = ""
print(f"{submission_id}|{status if isinstance(status, str) else ''}")
PYTHON
)"
    submission_id="${fields%%|*}"
    submission_status="${fields#*|}"
    if [[ -n "$submission_id" ]]; then
        printf 'Apple notarization submission ID: %s\n' "$submission_id"
    fi
    if (( submit_status != 0 )) || [[ "$submission_status" != "Accepted" || -z "$submission_id" ]]; then
        if [[ -n "$submission_id" ]]; then
            fetch_notarization_log "$submission_id"
        else
            printf 'Apple notarization did not return a valid submission ID; no notarytool log can be retrieved.\n' >&2
        fi
        fail "Apple notarization failed for $(basename "$artifact") (exit=$submit_status status=${submission_status:-unknown})"
    fi
}

derive_sparkle_public_key() {
    xcrun swift "$CONTROL_PLANE_SCRIPTS_DIR/derive_sparkle_public_key.swift" "$1"
}

generate_tip_rollout_appcast() {
    require_env SPARKLE_PRIVATE_KEY
    local predecessor_dir="$TMP_DIR/predecessors"
    mkdir -p "$predecessor_dir"
    # macOS still ships Bash 3.2, where expanding an empty array under
    # `set -u` aborts the script. Keep this argument vector non-empty for the
    # preparer role, whose rollout intentionally has no predecessors.
    local rollout_generate_args=(--declaration "$ROLLOUT_DECLARATION")
    local position=0 role tag digest path actual_digest
    while IFS=$'\t' read -r role tag digest; do
        [[ -n "$role" ]] || continue
        position=$((position + 1))
        path="$predecessor_dir/$position-identity-rollout.json"
        curl --fail --location --silent --show-error \
            --connect-timeout 10 --max-time 30 \
            "https://github.com/$TIP_UPDATE_REPOSITORY/releases/download/$tag/identity-rollout.json" \
            --output "$path"
        actual_digest="$(shasum -a 256 "$path" | awk '{print $1}')"
        [[ "$actual_digest" == "$digest" ]] ||
            fail "Tip predecessor $role manifest digest mismatch for $tag"
        rollout_generate_args+=(--predecessor-manifest "$path")
    done < <(python3 "$ROLLOUT_TOOL" predecessor-values --declaration "$ROLLOUT_DECLARATION")

    local enclosure_signature
    enclosure_signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" |
        "$SIGN_UPDATE" --ed-key-file - -p "$ENCLOSURE" |
        tr -d '\r\n')"
    [[ -n "$enclosure_signature" ]] || fail "Unable to sign Tip rollout enclosure"

    python3 "$ROLLOUT_TOOL" generate \
        "${rollout_generate_args[@]}" \
        --policy "$APPLE_IDENTITY_POLICY" \
        --version-env "$ROOT_DIR/version.env" \
        --release-tag "$TIP_TAG" \
        --release-commit "$TIP_COMMIT" \
        --migration-phase "$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
        --allowed-roles legacy,preparer,transition,successor \
        --enclosure "$ENCLOSURE" \
        --enclosure-basename "$ARCHIVE_BASENAME" \
        --enclosure-signature "$enclosure_signature" \
        --app-artifact-manifest "$FINAL_ARTIFACT_MANIFEST" \
        --appcast-output "$APPCAST" \
        --manifest-output "$ROLLOUT_MANIFEST"
    python3 "$ROLLOUT_TOOL" validate \
        "${rollout_generate_args[@]}" \
        --policy "$APPLE_IDENTITY_POLICY" \
        --version-env "$ROOT_DIR/version.env" \
        --release-tag "$TIP_TAG" \
        --release-commit "$TIP_COMMIT" \
        --migration-phase "$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
        --allowed-roles legacy,preparer,transition,successor \
        --enclosure "$ENCLOSURE" \
        --enclosure-basename "$ARCHIVE_BASENAME" \
        --enclosure-signature "$enclosure_signature" \
        --app-artifact-manifest "$FINAL_ARTIFACT_MANIFEST" \
        --appcast "$APPCAST" \
        --manifest "$ROLLOUT_MANIFEST"

    local private_key_file="$TMP_DIR/tip-sparkle-private-key"
    local public_key_file="$TMP_DIR/tip-sparkle-public-key"
    umask 077
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$private_key_file"

    local derived_public_key committed_public_key reproduced_signature
    derived_public_key="$(derive_sparkle_public_key "$private_key_file")"
    committed_public_key="$(plutil -extract SUPublicEDKey raw "$APP_BUNDLE/Contents/Info.plist")"
    [[ "$derived_public_key" == "$committed_public_key" ]] ||
        fail "Tip Sparkle private key does not match the app bundle SUPublicEDKey"
    reproduced_signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" |
        "$SIGN_UPDATE" --ed-key-file - -p "$ENCLOSURE" |
        tr -d '\r\n')"
    [[ "$reproduced_signature" == "$enclosure_signature" ]] ||
        fail "Tip Sparkle private key does not reproduce the generated appcast signature"

    printf '%s' "$committed_public_key" > "$public_key_file"
    xcrun swift "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_signature.swift" \
        "$public_key_file" "$enclosure_signature" "$ENCLOSURE"
}

generate_tip_history_catalog() {
    if [[ "$HISTORY_ACTIVE" != true ]]; then
        printf 'OK: Tip history explicitly inactive; existing release inventory unchanged.\n'
        return
    fi
    require_env REPOPROMPT_APPROVED_SOURCE_ROOT
    require_env SPARKLE_PRIVATE_KEY
    [[ "$(git -C "$APPROVED_SOURCE_ROOT" rev-parse HEAD)" == "$TIP_COMMIT" ]] ||
        fail "Tip history source must be the approved candidate commit"
    [[ "$(git -C "$APPROVED_SOURCE_ROOT" rev-parse --is-shallow-repository)" == false ]] ||
        fail "Tip history requires full approved-source history"
    local work="$TMP_DIR/history" bootstrap from_commit expanded_size signature
    tip_history_resolve_parent "$work" || fail "Unable to resolve verified Tip history parent"
    local parent_args=(--policy "$HISTORY_POLICY")
    if [[ -f "$work/parent-envelope.json" ]]; then
        parent_args+=(--parent-envelope "$work/parent-envelope.json")
        from_commit="$(python3 - "$work/parent-envelope.json" <<'PY'
import base64, json, sys
p = json.loads(base64.b64decode(json.load(open(sys.argv[1]))["payload"], validate=True))
print(p["entries"][0]["releaseCommit"])
PY
)"
    else
        bootstrap="$(tip_history_bootstrap_path "$APPROVED_SOURCE_ROOT")"
        tip_history_require_bootstrap_parent "$bootstrap" "$work/resolved-release.json"
        parent_args+=(--bootstrap "$bootstrap")
        from_commit="$(python3 - "$bootstrap" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["entries"][0]["releaseCommit"])
PY
)"
    fi
    python3 "$HISTORY_TOOL" collect-notes --repo "$APPROVED_SOURCE_ROOT" \
        --from "$from_commit" --to "$TIP_COMMIT" --output "$work/notes.json"
    # The ZIP has already been extracted and its final app validated by the
    # application phase. Bind the catalog to that archive's bounded byte count.
    expanded_size=0
    if [[ "$ROLLOUT_INSTALLATION_TYPE" == application ]]; then
        expanded_size="$(tip_history_archive_expanded_size "$UPDATE_ZIP")"
    fi
    python3 "$HISTORY_ADMISSION_TOOL" build-payload "${parent_args[@]}" \
        --apple-policy "$APPLE_IDENTITY_POLICY" --source "$APPROVED_SOURCE_ROOT" \
        --manifest "$ROLLOUT_MANIFEST" --app-artifact-manifest "$FINAL_ARTIFACT_MANIFEST" \
        --notes "$work/notes.json" --expanded-size "$expanded_size" --output "$work/payload.json"
    python3 "$HISTORY_TOOL" signed-message --payload "$work/payload.json" --output "$work/message"
    signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | \
        "$RUN_WITHOUT_GITHUB_TOKENS" "$SIGN_UPDATE" --ed-key-file - -p "$work/message" | tr -d '\r\n')"
    [[ -n "$signature" ]] || fail "Unable to sign Tip history catalog"
    python3 "$HISTORY_TOOL" wrap --payload "$work/payload.json" --signature "$signature" \
        --output "$HISTORY_ENVELOPE"
    tip_history_verify_signature "$HISTORY_ENVELOPE" "$work/verify-candidate"
    tip_history_verify_candidate "$HISTORY_ENVELOPE" "$ROLLOUT_MANIFEST" \
        "$FINAL_ARTIFACT_MANIFEST" "$FINAL_METADATA" "$APPROVED_SOURCE_ROOT" "$work"
}

require_application_rollout() {
    [[ "$ROLLOUT_INSTALLATION_TYPE" == "application" ]] ||
        fail "Application notarization requires a policy-derived application rollout"
}

require_package_rollout() {
    [[ "$ROLLOUT_INSTALLATION_TYPE" == "package" && "$ROLLOUT_ROLE" == "transition" ]] ||
        fail "Package phase requires the policy-derived transition package rollout"
    require_env EXPECTED_INSTALLER_IDENTITY
}

notarize_application_bundle() {
    require_application_rollout
    local notary_zip="$TMP_DIR/$ARCHIVE_BASENAME-notarization.zip"
    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$notary_zip"
    submit_notarization "$notary_zip"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
}

notarize_application_dmg() {
    require_application_rollout
    submit_notarization "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
}

notarize_signed_app_for_rollout() {
    case "$ROLLOUT_INSTALLATION_TYPE" in
        application) notarize_application_bundle ;;
        package)
            require_package_rollout
            printf 'OK: package rollout skips standalone application notarization.\n'
            ;;
        *) fail "Unsupported policy-derived installation type: $ROLLOUT_INSTALLATION_TYPE" ;;
    esac
}

sign_tip_application_phase() {
    require_command curl
    require_command ditto
    require_command hdiutil
    require_command plutil
    require_command python3
    require_command shasum
    require_command stat
    require_command xcrun
    require_file "$SIGN_UPDATE"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/derive_sparkle_public_key.swift"
    require_file "$CONTROL_PLANE_SCRIPTS_DIR/verify_sparkle_signature.swift"
    require_env SIGN_IDENTITY
    require_env REPOPROMPT_PROVISIONING_PROFILE
    require_env RELEASE_COMMIT
    require_env REPOPROMPT_APPROVED_SOURCE_ROOT
    require_tip_sentry_configuration
    [[ "$SIGN_IDENTITY" == "$EXPECTED_SIGN_IDENTITY" ]] ||
        fail "SIGN_IDENTITY does not match the reviewed $ROLLOUT_IDENTITY identity"
    [[ "$RELEASE_COMMIT" == "$TIP_COMMIT" ]] || fail "RELEASE_COMMIT must match TIP_COMMIT"
    [[ -d "$APP_BUNDLE" ]] || fail "Missing staged tip app bundle: $APP_BUNDLE"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER" \
        REPOPROMPT_TIP_ARCHIVE_CONTRACT=tip-rollout-v1 \
        REPOPROMPT_IDENTITY_MIGRATION_PHASE="$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
        "$CONTROL_PLANE_SCRIPTS_DIR/validate_staged_release.sh"
    verify_release_sentry_symbol_uuids_before_signing \
        "$SENTRY_SYMBOLS_DIR" \
        "$APP_BUNDLE" \
        "$APP_NAME.dSYM" \
        "$APP_NAME" \
        "repoprompt-mcp.dSYM" \
        "repoprompt-mcp"
    REPOPROMPT_RELEASE_SOURCE_ROOT="$ROOT_DIR" \
        REPOPROMPT_RELEASE_BUILD_NUMBER_OVERRIDE="$TIP_BUILD_NUMBER" \
        REPOPROMPT_TIP_ARCHIVE_CONTRACT=tip-rollout-v1 \
        REPOPROMPT_IDENTITY_MIGRATION_PHASE="$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
        "$CONTROL_PLANE_SCRIPTS_DIR/sign_staged_release.sh"
    prepare_dist
    TMP_DIR="$(mktemp -d)"

    notarize_signed_app_for_rollout

    "$CONTROL_PLANE_SCRIPTS_DIR/write_app_artifact_manifest.py" write \
        --app "$APP_BUNDLE" \
        --output "$FINAL_ARTIFACT_MANIFEST" \
        --expected-architectures "arm64,x86_64"
    assert_tip_manifest_telemetry_enabled
    write_tip_metadata
    validate_public_app "$APP_BUNDLE" "$FINAL_ARTIFACT_MANIFEST" "Final tip Developer ID app" "$SIGNING_TEAM_ID"
    upload_release_sentry_symbols \
        "$SENTRY_SYMBOLS_DIR" \
        "$CONTROL_PLANE_SCRIPTS_DIR/upload_sentry_debug_symbols.sh" \
        "$APP_NAME.dSYM" \
        "$APP_NAME" \
        "repoprompt-mcp.dSYM" \
        "repoprompt-mcp"

    if [[ "$ROLLOUT_INSTALLATION_TYPE" == "package" ]]; then
        printf 'OK: signed and validated Tip application for package rollout %s.\n' "$TIP_TAG"
        return
    fi

    local distribution_dir="$TMP_DIR/distribution"
    mkdir -p "$distribution_dir"
    ditto "$APP_BUNDLE" "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME"
    ditto -c -k --norsrc --keepParent "$distribution_dir/$DISTRIBUTION_APP_BUNDLE_NAME" "$UPDATE_ZIP"
    validate_distribution_zip "$UPDATE_ZIP" "$FINAL_ARTIFACT_MANIFEST" "Final tip distribution" "$SIGNING_TEAM_ID"
    hdiutil create -volname "$DISPLAY_NAME Tip" -srcfolder "$distribution_dir" -ov -format UDZO "$DMG"
    notarize_application_dmg
    generate_tip_rollout_appcast
    generate_tip_history_catalog
    local checksum_assets=(
        "$(basename "$UPDATE_ZIP")"
        "$(basename "$DMG")"
        "$(basename "$APPCAST")"
        "$(basename "$FINAL_ARTIFACT_MANIFEST")"
        "$(basename "$FINAL_METADATA")"
        "$(basename "$ROLLOUT_MANIFEST")"
    )
    if [[ "$HISTORY_ACTIVE" == true ]]; then checksum_assets+=("$(basename "$HISTORY_ENVELOPE")"); fi
    (cd "$DIST_DIR" && shasum -a 256 "${checksum_assets[@]}" > "$(basename "$CHECKSUMS")")
    printf 'OK: signed and notarized Tip %s application artifact %s.\n' "$ROLLOUT_ROLE" "$TIP_TAG"
}

build_tip_package_phase() {
    require_package_rollout
    REPOPROMPT_ENABLE_IDENTITY_TRANSITION_PKG=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/build_identity_transition_pkg.sh" build \
        --app "$APP_BUNDLE" \
        --output "$TRANSITION_PKG" \
        --installer-identity "$EXPECTED_INSTALLER_IDENTITY"
}

submit_tip_package_notarization_phase() {
    require_package_rollout
    require_command xcrun
    TMP_DIR="$(mktemp -d)"
    submit_notarization "$TRANSITION_PKG"
}

staple_tip_package_phase() {
    require_package_rollout
    REPOPROMPT_ENABLE_IDENTITY_TRANSITION_PKG=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/build_identity_transition_pkg.sh" staple "$TRANSITION_PKG"
}

validate_tip_package_phase() {
    require_package_rollout
    require_command curl
    require_command shasum
    require_command xcrun
    require_file "$SIGN_UPDATE"
    require_file "$FINAL_ARTIFACT_MANIFEST"
    require_file "$FINAL_METADATA"
    TMP_DIR="$(mktemp -d)"
    REPOPROMPT_ENABLE_IDENTITY_TRANSITION_PKG=1 \
        "$CONTROL_PLANE_SCRIPTS_DIR/build_identity_transition_pkg.sh" validate \
        "$TRANSITION_PKG" --expected-app "$APP_BUNDLE"
    generate_tip_rollout_appcast
    generate_tip_history_catalog
    local checksum_assets=(
        "$(basename "$TRANSITION_PKG")"
        "$(basename "$APPCAST")"
        "$(basename "$FINAL_ARTIFACT_MANIFEST")"
        "$(basename "$FINAL_METADATA")"
        "$(basename "$ROLLOUT_MANIFEST")"
    )
    if [[ "$HISTORY_ACTIVE" == true ]]; then checksum_assets+=("$(basename "$HISTORY_ENVELOPE")"); fi
    (cd "$DIST_DIR" && shasum -a 256 "${checksum_assets[@]}" > "$(basename "$CHECKSUMS")")
    printf 'OK: signed, notarized, stapled, and validated Tip package artifact %s.\n' "$TIP_TAG"
}

sign_tip() {
    sign_tip_application_phase
    if [[ "$ROLLOUT_INSTALLATION_TYPE" == "package" ]]; then
        build_tip_package_phase
        submit_tip_package_notarization_phase
        staple_tip_package_phase
        validate_tip_package_phase
    fi
}

tip_publish_assets() {
    TIP_PUBLISH_ASSETS=("$APPCAST" "$CHECKSUMS" "$FINAL_ARTIFACT_MANIFEST" "$FINAL_METADATA" "$ROLLOUT_MANIFEST")
    if [[ "$HISTORY_ACTIVE" == true ]]; then TIP_PUBLISH_ASSETS+=("$HISTORY_ENVELOPE"); fi
    case "$TIP_PUBLISH_INSTALLATION_TYPE" in
        package) TIP_PUBLISH_ASSETS+=("$TRANSITION_PKG") ;;
        application) TIP_PUBLISH_ASSETS+=("$UPDATE_ZIP" "$DMG") ;;
        *) fail "TIP_PUBLISH_INSTALLATION_TYPE must be application or package" ;;
    esac
}

validate_tip_publish_assets() {
    require_command python3
    tip_publish_assets
    local expected_basenames=()
    local path
    for path in "${TIP_PUBLISH_ASSETS[@]}"; do
        expected_basenames+=("$(basename "$path")")
    done
    python3 - "$DIST_DIR" "${expected_basenames[@]}" <<'PYTHON'
import sys
from pathlib import Path

dist = Path(sys.argv[1])
expected = set(sys.argv[2:])
if not dist.is_dir():
    raise SystemExit(f"ERROR: Missing Tip publish directory: {dist}")
actual = {entry.name for entry in dist.iterdir()}
missing = sorted(expected - actual)
extra = sorted(actual - expected)
if missing or extra:
    raise SystemExit(
        "ERROR: Tip publish asset inventory mismatch: "
        f"missing={missing or 'none'} extra={extra or 'none'}"
    )
for name in sorted(expected):
    path = dist / name
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"ERROR: Tip publish asset must be a regular non-symlink file: {path}")
print(f"OK: Tip publish asset inventory contains exactly {len(expected)} files.")
PYTHON
    (cd "$DIST_DIR" && shasum -a 256 -c "$(basename "$CHECKSUMS")")
    python3 - "$CHECKSUMS" "${expected_basenames[@]}" <<'PYTHON'
import re
import sys
from pathlib import Path

checksum_path = Path(sys.argv[1])
expected = set(sys.argv[2:]) - {checksum_path.name}
actual = set()
for line in checksum_path.read_text(encoding="utf-8").splitlines():
    match = re.fullmatch(r"([0-9a-f]{64})  ([^/]+)", line)
    if not match:
        raise SystemExit(f"ERROR: malformed SHA256SUMS line: {line!r}")
    name = match.group(2)
    if name in actual:
        raise SystemExit(f"ERROR: duplicate SHA256SUMS entry: {name}")
    actual.add(name)
if actual != expected:
    raise SystemExit(
        "ERROR: SHA256SUMS entry set mismatch: "
        f"missing={sorted(expected - actual)} extra={sorted(actual - expected)}"
    )
PYTHON
}

publish_tip() {
    require_env TIP_GH_TOKEN
    require_env TIP_SOURCE_GH_TOKEN
    require_env TIP_SOURCE_REPOSITORY
    require_env TIP_SOURCE_BRANCH
    require_file "$PUBLISH_TIP_RELEASE"
    case "$TIP_UPDATE_REPOSITORY" in
        repoprompt/repoprompt-ce|repoprompt/repoprompt-ce-updates)
            fail "TIP_UPDATE_REPOSITORY must not target the source or stable update repository"
            ;;
    esac
    validate_tip_publish_assets
    TIP_GH_TOKEN="$TIP_GH_TOKEN" \
    TIP_SOURCE_GH_TOKEN="$TIP_SOURCE_GH_TOKEN" \
    TIP_UPDATE_REPOSITORY="$TIP_UPDATE_REPOSITORY" \
    TIP_SOURCE_REPOSITORY="$TIP_SOURCE_REPOSITORY" \
    TIP_SOURCE_BRANCH="$TIP_SOURCE_BRANCH" \
    TIP_COMMIT="$TIP_COMMIT" \
    TIP_TAG="$TIP_TAG" \
    TIP_BUILD_NUMBER="$TIP_BUILD_NUMBER" \
    TIP_PUBLISH_INSTALLATION_TYPE="$TIP_PUBLISH_INSTALLATION_TYPE" \
    TIP_RELEASE_TITLE="$DISPLAY_NAME Tip $ROLLOUT_ROLE $TIP_SHORT_SHA" \
    TIP_RELEASE_NOTES="Tip identity rollout role \`$ROLLOUT_ROLE\` from main commit \`$TIP_COMMIT\` with build number \`$TIP_BUILD_NUMBER\`." \
    TIP_EXPECTED_ROLLOUT_ROLE="$ROLLOUT_ROLE" \
    TIP_EXPECTED_SIGNING_IDENTITY="$ROLLOUT_IDENTITY" \
    TIP_EXPECTED_MIGRATION_PHASE="$REPOPROMPT_IDENTITY_MIGRATION_PHASE" \
        exec "$PUBLISH_TIP_RELEASE" \
            --rollout-declaration "$ROLLOUT_DECLARATION" "${TIP_PUBLISH_ASSETS[@]}"
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "$MODE" in
        stage)
            start_phase "Stage Tip application"
            stage_tip
            ;;
        sign)
            start_phase "Sign and notarize Tip"
            sign_tip
            ;;
        sign-application)
            start_phase "Sign application"
            sign_tip_application_phase
            ;;
        build-package)
            start_phase "Build package"
            build_tip_package_phase
            ;;
        submit-package-notarization)
            start_phase "Submit package notarization"
            submit_tip_package_notarization_phase
            ;;
        staple-package)
            start_phase "Staple package"
            staple_tip_package_phase
            ;;
        validate-package)
            start_phase "Validate package"
            validate_tip_package_phase
            ;;
        validate-assets) validate_tip_publish_assets ;;
        publish-tip) publish_tip ;;
        *)
            fail "Usage: $0 stage|sign|sign-application|build-package|submit-package-notarization|staple-package|validate-package|validate-assets|publish-tip"
            ;;
    esac
fi
