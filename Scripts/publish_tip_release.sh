#!/usr/bin/env bash
set -euo pipefail

# Retry-safe Tip publication. Every remote mutation is reconciled by observing
# exact release state; protected-main ancestry and the public P -> T -> S ladder
# are rechecked immediately before a draft becomes public.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLOUT_TOOL="$SCRIPT_DIR/stable_rollout.py"
APPLE_IDENTITY_POLICY="$SCRIPT_DIR/apple_identity_policy.json"
SOURCE_COMMIT_VERIFIER="$SCRIPT_DIR/verify_tip_source_commit.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_env() { [[ -n "${!1:-}" ]] || fail "Missing required environment variable: $1"; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_file() { [[ -f "$1" && ! -L "$1" ]] || fail "Missing regular non-symlink file: $1"; }

for name in \
    TIP_GH_TOKEN TIP_SOURCE_GH_TOKEN TIP_UPDATE_REPOSITORY TIP_SOURCE_REPOSITORY TIP_SOURCE_BRANCH \
    TIP_COMMIT TIP_TAG TIP_BUILD_NUMBER TIP_PUBLISH_INSTALLATION_TYPE \
    TIP_EXPECTED_ROLLOUT_ROLE TIP_EXPECTED_SIGNING_IDENTITY \
    TIP_EXPECTED_MIGRATION_PHASE TIP_RELEASE_TITLE TIP_RELEASE_NOTES; do
    require_env "$name"
done
for command in curl gh python3 shasum; do require_command "$command"; done
require_file "$ROLLOUT_TOOL"
require_file "$APPLE_IDENTITY_POLICY"
require_file "$SOURCE_COMMIT_VERIFIER"

[[ "$TIP_SOURCE_BRANCH" == "main" ]] || fail "Tip publication source branch must remain main"
[[ "$TIP_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "TIP_COMMIT must be a full lowercase Git SHA"
[[ "$TIP_TAG" =~ ^tip-[0-9a-f]{12}$ ]] || fail "TIP_TAG must be tip-<12 lowercase hex>"
[[ "${1:-}" == "--rollout-declaration" && "$#" -ge 2 ]] ||
    fail "Usage: $0 --rollout-declaration <checked-in-declaration> <release-asset>..."
ROLLOUT_DECLARATION="$2"
shift 2
require_file "$ROLLOUT_DECLARATION"
[[ "$#" -ge 1 ]] || fail "Usage: $0 --rollout-declaration <checked-in-declaration> <release-asset>..."
case "$TIP_UPDATE_REPOSITORY" in
    "$TIP_SOURCE_REPOSITORY"|repoprompt/repoprompt-ce-updates)
        fail "Tip publication repository must be separate from source and Stable updates"
        ;;
esac

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repoprompt-tip-publish.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

ASSETS=("$@")
EXPECTED_NAMES=()
for path in "${ASSETS[@]}"; do
    [[ -f "$path" && ! -L "$path" ]] || fail "Tip asset must be a regular non-symlink file: $path"
    EXPECTED_NAMES+=("$(basename "$path")")
done

python3 - "${EXPECTED_NAMES[@]}" <<'PY'
import sys
names = sys.argv[1:]
if len(names) != len(set(names)):
    raise SystemExit("ERROR: duplicate Tip asset basename")
PY

sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
asset_path_for_name() {
    local wanted="$1" path
    for path in "${ASSETS[@]}"; do
        [[ "$(basename "$path")" == "$wanted" ]] && { printf '%s\n' "$path"; return 0; }
    done
    return 1
}

CANDIDATE_MANIFEST="$(asset_path_for_name identity-rollout.json)" ||
    fail "Tip publication inventory is missing identity-rollout.json"
CANDIDATE_APPCAST="$(asset_path_for_name appcast.xml)" ||
    fail "Tip publication inventory is missing appcast.xml"

validate_candidate_bindings() {
    python3 - \
        "$CANDIDATE_MANIFEST" \
        "$TIP_UPDATE_REPOSITORY" \
        "$TIP_COMMIT" \
        "$TIP_TAG" \
        "$TIP_BUILD_NUMBER" \
        "$TIP_EXPECTED_ROLLOUT_ROLE" \
        "$TIP_EXPECTED_SIGNING_IDENTITY" \
        "$TIP_EXPECTED_MIGRATION_PHASE" \
        "$TIP_PUBLISH_INSTALLATION_TYPE" \
        "${ASSETS[@]}" <<'PYTHON'
import hashlib
import json
import sys
from pathlib import Path

(
    manifest_path,
    update_repository,
    commit,
    tag,
    build_number,
    role,
    signing_identity,
    migration_phase,
    installation_type,
    *asset_paths,
) = sys.argv[1:]
manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
expected = {
    "updateRepository": update_repository,
    "releaseCommit": commit,
    "sourceTag": tag,
    "buildNumber": build_number,
    "currentRole": role,
    "signingIdentity": signing_identity,
    "migrationPhase": migration_phase,
}
for key, value in expected.items():
    if manifest.get(key) != value:
        raise SystemExit(
            f"ERROR: candidate Tip manifest {key} mismatch: "
            f"expected {value!r}, got {manifest.get(key)!r}"
        )

assets = {}
for raw_path in asset_paths:
    path = Path(raw_path)
    if path.name in assets:
        raise SystemExit(f"ERROR: duplicate candidate Tip asset basename: {path.name}")
    assets[path.name] = path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


artifact = manifest.get("appArtifactManifest")
if not isinstance(artifact, dict) or set(artifact) != {"name", "sha256"}:
    raise SystemExit("ERROR: candidate Tip app artifact binding is malformed")
artifact_path = assets.get(artifact.get("name"))
if artifact_path is None or digest(artifact_path) != artifact.get("sha256"):
    raise SystemExit("ERROR: candidate Tip app artifact manifest bytes do not match their binding")

items = manifest.get("appcastItems")
if not isinstance(items, list) or not items or not isinstance(items[0], dict):
    raise SystemExit("ERROR: candidate Tip manifest has no newest appcast item")
newest = items[0]
for key, value in {
    "role": role,
    "tag": tag,
    "buildNumber": build_number,
    "installationType": installation_type,
}.items():
    if newest.get(key) != value:
        raise SystemExit(
            f"ERROR: candidate newest Tip item {key} mismatch: "
            f"expected {value!r}, got {newest.get(key)!r}"
        )
expected_suffix = ".pkg" if installation_type == "package" else ".zip"
enclosure_name = newest.get("enclosureName")
if not isinstance(enclosure_name, str) or not enclosure_name.endswith(expected_suffix):
    raise SystemExit("ERROR: candidate Tip enclosure type does not match the rollout installation type")
enclosure = assets.get(enclosure_name)
if enclosure is None:
    raise SystemExit("ERROR: candidate Tip enclosure is missing from the publication inventory")
if newest.get("enclosureSize") != enclosure.stat().st_size:
    raise SystemExit("ERROR: candidate Tip enclosure size does not match its manifest binding")
if newest.get("enclosureSha256") != digest(enclosure):
    raise SystemExit("ERROR: candidate Tip enclosure digest does not match its manifest binding")
PYTHON
}

file_size() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }
verify_expected_bytes() {
    local downloaded="$1" name="$2" expected_size="$3" expected_sha="${4:-}"
    [[ -f "$downloaded" && ! -L "$downloaded" ]] ||
        fail "Downloaded Tip asset is not a regular file: $name"
    local actual_size actual_sha
    actual_size="$(file_size "$downloaded")"
    [[ "$actual_size" == "$expected_size" ]] ||
        fail "Remote Tip asset size mismatch for $name: expected=$expected_size actual=$actual_size"
    if [[ -n "$expected_sha" ]]; then
        actual_sha="$(sha256_file "$downloaded")"
        [[ "$actual_sha" == "$expected_sha" ]] ||
            fail "Remote Tip asset SHA-256 mismatch for $name"
    fi
}
verify_downloaded_asset() {
    local expected_path="$1" downloaded="$2" name="$3"
    verify_expected_bytes "$downloaded" "$name" "$(file_size "$expected_path")" "$(sha256_file "$expected_path")"
}

fetch_json_status() {
    local url="$1" output="$2" status
    if ! status="$(curl --location --silent --show-error \
        --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        --output "$output" --write-out '%{http_code}' "$url")"; then
        fail "GitHub API request failed: $url"
    fi
    [[ "$status" =~ ^[0-9]{3}$ ]] || fail "GitHub API returned an invalid HTTP status"
    printf '%s\n' "$status"
}

require_main_lineage() {
    "$SOURCE_COMMIT_VERIFIER" --allow-ancestor "$1"
}

LIVE_AUDIT_INDEX=0
STABLE_AUDIT_INDEX=0
LIVE_MANIFEST_PATH=""
LIVE_APPCAST_PATH=""
STABLE_APPCAST_PATH=""
fetch_live_tip_rollout() {
    LIVE_AUDIT_INDEX=$((LIVE_AUDIT_INDEX + 1))
    local release_file="$TMP_DIR/live-release-$LIVE_AUDIT_INDEX.json" status report
    status="$(fetch_json_status \
        "https://api.github.com/repos/$TIP_UPDATE_REPOSITORY/releases/latest" \
        "$release_file")"
    if [[ "$status" == "404" ]]; then
        LIVE_MANIFEST_PATH=""
        LIVE_APPCAST_PATH=""
        return 1
    fi
    [[ "$status" == "200" ]] || fail "Live Tip release lookup failed with HTTP $status"

    report="$TMP_DIR/live-release-$LIVE_AUDIT_INDEX.tsv"
    python3 - "$release_file" "$report" "$TIP_UPDATE_REPOSITORY" <<'PY'
import json
import re
import sys
from pathlib import Path

release_path, report_path, repository = sys.argv[1:]
release = json.loads(Path(release_path).read_text(encoding="utf-8"))
if release.get("draft") is not False or release.get("prerelease") is not False:
    raise SystemExit("ERROR: live Tip release must be public and not a prerelease")
tag = release.get("tag_name")
if not isinstance(tag, str) or not re.fullmatch(r"tip-[0-9a-f]{12}", tag):
    raise SystemExit("ERROR: live Tip release tag is malformed")
assets = release.get("assets")
if not isinstance(assets, list):
    raise SystemExit("ERROR: live Tip release assets must be a list")

def asset(name):
    matches = [value for value in assets if isinstance(value, dict) and value.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"ERROR: live Tip release must contain exactly one {name}")
    value = matches[0]
    if value.get("state") != "uploaded":
        raise SystemExit(f"ERROR: live Tip asset is not fully uploaded: {name}")
    url = value.get("browser_download_url")
    expected = f"https://github.com/{repository}/releases/download/{tag}/{name}"
    if url != expected:
        raise SystemExit(f"ERROR: live Tip asset URL mismatch: {name}")
    size = value.get("size")
    if not isinstance(size, int) or size <= 0:
        raise SystemExit(f"ERROR: live Tip asset size is malformed: {name}")
    digest = value.get("digest")
    if digest is None:
        digest = ""
    elif not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise SystemExit(f"ERROR: live Tip asset digest is malformed: {name}")
    return url, size, digest.removeprefix("sha256:")

manifest = asset("identity-rollout.json")
appcast = asset("appcast.xml")
Path(report_path).write_text(
    "\t".join((tag, str(manifest[0]), str(manifest[1]), str(manifest[2]),
                str(appcast[0]), str(appcast[1]), str(appcast[2]))) + "\n",
    encoding="utf-8",
)
PY

    local live_tag manifest_url manifest_size manifest_sha appcast_url appcast_size appcast_sha
    IFS=$'\t' read -r live_tag manifest_url manifest_size manifest_sha \
        appcast_url appcast_size appcast_sha < "$report"
    LIVE_MANIFEST_PATH="$TMP_DIR/live-identity-rollout-$LIVE_AUDIT_INDEX.json"
    LIVE_APPCAST_PATH="$TMP_DIR/live-appcast-$LIVE_AUDIT_INDEX.xml"
    curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 \
        "$manifest_url" --output "$LIVE_MANIFEST_PATH"
    curl --fail --location --silent --show-error --connect-timeout 10 --max-time 30 \
        "$appcast_url" --output "$LIVE_APPCAST_PATH"
    verify_expected_bytes "$LIVE_MANIFEST_PATH" "live identity-rollout.json" "$manifest_size" "$manifest_sha"
    verify_expected_bytes "$LIVE_APPCAST_PATH" "live appcast.xml" "$appcast_size" "$appcast_sha"
}

verify_retained_release_asset() {
    local tag="$1" name="$2" expected_url="$3" expected_size="$4" expected_sha="$5"
    local release_file="$TMP_DIR/retained-release-$tag.json" status report
    status="$(fetch_json_status \
        "https://api.github.com/repos/$TIP_UPDATE_REPOSITORY/releases/tags/$tag" \
        "$release_file")"
    [[ "$status" == "200" ]] || fail "Retained Tip release $tag lookup failed with HTTP $status"
    report="$TMP_DIR/retained-release-$tag.tsv"
    python3 - "$release_file" "$report" "$tag" "$name" "$expected_url" \
        "$expected_size" "$expected_sha" <<'PY'
import json
import re
import sys
from pathlib import Path

release_path, report_path, tag, name, expected_url, expected_size, expected_sha = sys.argv[1:]
release = json.loads(Path(release_path).read_text(encoding="utf-8"))
if release.get("tag_name") != tag or release.get("draft") is not False or release.get("prerelease") is not False:
    raise SystemExit(f"ERROR: retained Tip release metadata mismatch for {tag}")
assets = release.get("assets")
if not isinstance(assets, list):
    raise SystemExit(f"ERROR: retained Tip release assets must be a list for {tag}")
matches = [value for value in assets if isinstance(value, dict) and value.get("name") == name]
if len(matches) != 1:
    raise SystemExit(f"ERROR: retained Tip release {tag} must contain exactly one {name}")
asset = matches[0]
if asset.get("state") != "uploaded":
    raise SystemExit(f"ERROR: retained Tip asset is not fully uploaded: {tag}/{name}")
if asset.get("browser_download_url") != expected_url:
    raise SystemExit(f"ERROR: retained Tip asset URL mismatch: {tag}/{name}")
if str(asset.get("size")) != expected_size:
    raise SystemExit(f"ERROR: retained Tip asset size mismatch: {tag}/{name}")
digest = asset.get("digest")
if digest is not None:
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise SystemExit(f"ERROR: retained Tip asset digest is malformed: {tag}/{name}")
    if digest != f"sha256:{expected_sha}":
        raise SystemExit(f"ERROR: retained Tip asset digest mismatch: {tag}/{name}")
Path(report_path).write_text((digest or "") + "\n", encoding="utf-8")
PY
    local api_digest
    api_digest="$(cat "$report")"
    if [[ -z "$api_digest" ]]; then
        local downloaded="$TMP_DIR/retained-$tag-$name"
        curl --fail --location --silent --show-error --connect-timeout 10 --max-time 900 \
            "$expected_url" --output "$downloaded"
        verify_expected_bytes "$downloaded" "$tag/$name" "$expected_size" "$expected_sha"
    fi
}

# Retained enclosures are immutable public dependencies of the candidate feed.
# GitHub's server-side SHA-256 and size are sufficient when present; older API
# responses without a digest fall back to a bounded byte download.
audit_retained_enclosures() {
    local report="$TMP_DIR/retained-enclosures.tsv"
    python3 - "$CANDIDATE_MANIFEST" "$report" "$TIP_UPDATE_REPOSITORY" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest_path, report_path, repository = sys.argv[1:]
manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
rows = []
for position, item in enumerate(manifest.get("appcastItems", [])[1:], start=2):
    tag = item.get("tag")
    name = item.get("enclosureName")
    url = item.get("url")
    size = item.get("enclosureSize")
    digest = item.get("enclosureSha256")
    if not isinstance(tag, str) or not re.fullmatch(r"tip-[0-9a-f]{12}", tag):
        raise SystemExit(f"ERROR: retained Tip item {position} tag is malformed")
    if not isinstance(name, str) or Path(name).name != name:
        raise SystemExit(f"ERROR: retained Tip item {position} enclosure name is malformed")
    expected_url = f"https://github.com/{repository}/releases/download/{tag}/{name}"
    if url != expected_url:
        raise SystemExit(f"ERROR: retained Tip item {position} enclosure URL mismatch")
    if not isinstance(size, int) or size <= 0:
        raise SystemExit(f"ERROR: retained Tip item {position} enclosure size is malformed")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise SystemExit(f"ERROR: retained Tip item {position} enclosure digest is malformed")
    rows.append((tag, name, url, str(size), digest))
Path(report_path).write_text(
    "".join("\t".join(row) + "\n" for row in rows), encoding="utf-8"
)
PY
    local tag name url size digest
    while IFS=$'\t' read -r tag name url size digest; do
        [[ -n "$tag" ]] || continue
        verify_retained_release_asset "$tag" "$name" "$url" "$size" "$digest"
    done < "$report"
}

audit_stable_tip_floor() {
    local phase="$1"
    local stable_feed_url
    STABLE_AUDIT_INDEX=$((STABLE_AUDIT_INDEX + 1))
    STABLE_APPCAST_PATH="$TMP_DIR/stable-floor-$STABLE_AUDIT_INDEX.xml"
    stable_feed_url="$(python3 "$ROLLOUT_TOOL" feed-url \
        --policy "$APPLE_IDENTITY_POLICY" --channel stable)"
    curl --fail --location --silent --show-error \
        --connect-timeout 10 --max-time 30 \
        "$stable_feed_url" --output "$STABLE_APPCAST_PATH"
    python3 "$ROLLOUT_TOOL" validate-stable-tip-floor \
        --policy "$APPLE_IDENTITY_POLICY" \
        --stable-appcast "$STABLE_APPCAST_PATH" \
        --tip-manifest "$CANDIDATE_MANIFEST" \
        --tip-appcast "$CANDIDATE_APPCAST" ||
        fail "$phase rejected an unsafe Stable/Tip build floor"
}

# This is the state-machine fence that keeps P, T, and S in order even if the
# public Tip feed changes while a long signing/notarization job is running.
audit_live_rollout_progression() {
    local phase="$1"
    audit_stable_tip_floor "$phase"
    local arguments=(
        validate-live-tip-progression
        --policy "$APPLE_IDENTITY_POLICY"
        --candidate-manifest "$CANDIDATE_MANIFEST"
        --candidate-appcast "$CANDIDATE_APPCAST"
        --declaration "$ROLLOUT_DECLARATION"
        --stable-appcast "$STABLE_APPCAST_PATH"
    )
    if fetch_live_tip_rollout; then
        arguments+=(
            --live-manifest "$LIVE_MANIFEST_PATH"
            --live-appcast "$LIVE_APPCAST_PATH"
        )
    fi
    python3 "$ROLLOUT_TOOL" "${arguments[@]}" || fail "$phase rejected unsafe Tip rollout progression"
    audit_retained_enclosures
}

# Returns 0 when found, 1 only for a confirmed absence, and 2 on observation error.
lookup_release() {
    local output="$1" pages_file status
    pages_file="$(mktemp "$TMP_DIR/release-pages.XXXXXX")"
    rm -f "$output"
    if ! GH_TOKEN="$TIP_GH_TOKEN" gh api --paginate \
        "/repos/$TIP_UPDATE_REPOSITORY/releases?per_page=100" > "$pages_file"; then
        rm -f "$pages_file"
        return 2
    fi
    if python3 - "$pages_file" "$output" "$TIP_TAG" <<'PY'
import json
import sys
from pathlib import Path

pages_path, output_path, tag = sys.argv[1:]
raw = Path(pages_path).read_text(encoding="utf-8")
decoder = json.JSONDecoder()
offset = 0
page_count = 0
matches = []
while True:
    while offset < len(raw) and raw[offset].isspace():
        offset += 1
    if offset == len(raw):
        break
    try:
        page, offset = decoder.raw_decode(raw, offset)
    except json.JSONDecodeError as error:
        raise SystemExit(f"ERROR: malformed paginated release response: {error}")
    if not isinstance(page, list):
        raise SystemExit("ERROR: paginated release response must contain JSON arrays")
    page_count += 1
    for release in page:
        if not isinstance(release, dict):
            raise SystemExit("ERROR: paginated release response contains a malformed release")
        if release.get("tag_name") == tag:
            matches.append(release)
if page_count == 0:
    raise SystemExit("ERROR: paginated release response contained no JSON pages")
if len(matches) > 1:
    raise SystemExit(f"ERROR: duplicate release tag: {tag}")
if not matches:
    raise SystemExit(3)
Path(output_path).write_text(json.dumps(matches[0], separators=(",", ":")) + "\n", encoding="utf-8")
PY
    then
        rm -f "$pages_file"
        return 0
    else
        status=$?
        rm -f "$pages_file"
        [[ "$status" == 3 ]] && return 1
        return 2
    fi
}

validate_release_metadata() {
    local json_file="$1" expected_state="$2"
    python3 - "$json_file" "$TIP_TAG" "$TIP_RELEASE_TITLE" "$TIP_RELEASE_NOTES" \
        "$TIP_SOURCE_BRANCH" "$expected_state" <<'PY'
import json
import sys
from pathlib import Path

path, tag, title, notes, branch, expected_state = sys.argv[1:]
release = json.loads(Path(path).read_text(encoding="utf-8"))
expected_draft = expected_state == "draft"
checks = {
    "tag_name": tag,
    "target_commitish": branch,
    "name": title,
    "body": notes,
    "draft": expected_draft,
    "prerelease": False,
}
for key, expected in checks.items():
    if release.get(key) != expected:
        raise SystemExit(
            f"ERROR: remote Tip release {key} mismatch: expected {expected!r}, got {release.get(key)!r}"
        )
if not isinstance(release.get("id"), int):
    raise SystemExit("ERROR: remote Tip release is missing a numeric id")
PY
}

write_release_json() {
    local output="$1" status release_id="" direct_output
    if [[ -f "$output" ]]; then
        release_id="$(python3 - "$output" <<'PY'
import json
import sys

try:
    release = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)
release_id = release.get("id") if isinstance(release, dict) else None
if isinstance(release_id, int):
    print(release_id)
PY
)"
    fi
    if [[ -n "$release_id" ]]; then
        direct_output="$(mktemp "$TMP_DIR/release-by-id.XXXXXX")"
        if ! GH_TOKEN="$TIP_GH_TOKEN" gh api \
            "/repos/$TIP_UPDATE_REPOSITORY/releases/$release_id" > "$direct_output"; then
            rm -f "$direct_output"
            fail "Authenticated Tip release lookup by id failed"
        fi
        mv "$direct_output" "$output"
        return 0
    fi
    if lookup_release "$output"; then
        return 0
    else
        status=$?
    fi
    case "$status" in
        1) return 1 ;;
        *) fail "Authenticated Tip release lookup failed" ;;
    esac
}

create_draft_if_missing() {
    local release_file="$1"
    if write_release_json "$release_file"; then
        return 0
    fi
    require_main_lineage "pre-draft creation"
    if ! GH_TOKEN="$TIP_GH_TOKEN" gh api --method POST \
        "/repos/$TIP_UPDATE_REPOSITORY/releases" \
        -f tag_name="$TIP_TAG" \
        -f target_commitish="$TIP_SOURCE_BRANCH" \
        -f name="$TIP_RELEASE_TITLE" \
        -f body="$TIP_RELEASE_NOTES" \
        -F draft=true \
        -F prerelease=false > "$release_file"; then
        write_release_json "$release_file" || fail "Unable to create or reconcile Tip release draft"
        return 0
    fi
    validate_release_metadata "$release_file" draft
}

download_authenticated_asset() {
    local api_url="$1" output="$2"
    GH_TOKEN="$TIP_GH_TOKEN" gh api \
        -H 'Accept: application/octet-stream' \
        "$api_url" > "$output"
}

audit_authenticated_release_assets() {
    local release_file="$1" allow_missing="$2" report_file="$TMP_DIR/remote-assets.tsv"
    python3 - "$release_file" "$report_file" <<'PY'
import json
import sys
from pathlib import Path

release = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assets = release.get("assets")
if not isinstance(assets, list):
    raise SystemExit("ERROR: remote Tip release assets must be a list")
seen = set()
rows = []
for asset in assets:
    if not isinstance(asset, dict):
        raise SystemExit("ERROR: malformed remote Tip release asset")
    name = asset.get("name")
    if not isinstance(name, str) or not name or name in seen:
        raise SystemExit("ERROR: duplicate or malformed remote Tip release asset name")
    seen.add(name)
    if asset.get("state") != "uploaded":
        raise SystemExit(f"ERROR: remote Tip release asset is not uploaded: {name}")
    url = asset.get("url")
    if not isinstance(url, str) or not url.startswith("https://api.github.com/"):
        raise SystemExit(f"ERROR: remote Tip asset has an invalid API URL: {name}")
    rows.append((name, url))
Path(sys.argv[2]).write_text("".join(f"{name}\t{url}\n" for name, url in rows), encoding="utf-8")
PY

    local name api_url expected_path remote_file
    local remote_names_file="$TMP_DIR/remote-names-audited"
    : > "$remote_names_file"
    while IFS=$'\t' read -r name api_url; do
        [[ -n "$name" ]] || continue
        expected_path="$(asset_path_for_name "$name")" || fail "Unexpected remote Tip asset: $name"
        printf '%s\n' "$name" >> "$remote_names_file"
        remote_file="$TMP_DIR/authenticated-$name"
        download_authenticated_asset "$api_url" "$remote_file"
        verify_downloaded_asset "$expected_path" "$remote_file" "$name"
    done < "$report_file"

    if [[ "$allow_missing" != "true" ]]; then
        for name in "${EXPECTED_NAMES[@]}"; do
            grep -Fx "$name" "$remote_names_file" >/dev/null ||
                fail "Published Tip release is missing asset: $name"
        done
    fi
}

upload_missing_assets() {
    local release_file="$1" names_file="$TMP_DIR/remote-names" release_id
    release_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$release_file")"
    python3 - "$release_file" > "$names_file" <<'PY'
import json
import sys
release = json.load(open(sys.argv[1], encoding="utf-8"))
for asset in release.get("assets", []):
    print(asset.get("name", ""))
PY
    local path name encoded_name upload_response upload_status
    for path in "${ASSETS[@]}"; do
        name="$(basename "$path")"
        if grep -Fx "$name" "$names_file" >/dev/null; then
            continue
        fi
        encoded_name="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$name")"
        upload_response="$(mktemp "$TMP_DIR/upload-response.XXXXXX")"
        upload_status="$(curl --location --silent --show-error \
            --connect-timeout 10 --max-time 1800 \
            --request POST \
            --header 'Accept: application/vnd.github+json' \
            --header 'Content-Type: application/octet-stream' \
            --header 'X-GitHub-Api-Version: 2022-11-28' \
            --header "Authorization: Bearer $TIP_GH_TOKEN" \
            --data-binary "@$path" \
            --output "$upload_response" --write-out '%{http_code}' \
            "https://uploads.github.com/repos/$TIP_UPDATE_REPOSITORY/releases/$release_id/assets?name=$encoded_name")" ||
            upload_status="000"
        rm -f "$upload_response"
        if [[ "$upload_status" != "201" ]]; then
            write_release_json "$release_file" || fail "Unable to reconcile Tip asset upload: $name"
            audit_authenticated_release_assets "$release_file" true
            grep -Fx "$name" <(python3 - "$release_file" <<'PY'
import json,sys
for asset in json.load(open(sys.argv[1], encoding="utf-8")).get("assets", []):
    print(asset.get("name", ""))
PY
) >/dev/null || fail "Tip asset upload failed with HTTP $upload_status: $name"
        fi
        write_release_json "$release_file" || fail "Tip release draft disappeared after uploading $name"
    done
}

publish_draft() {
    local release_file="$1" release_id
    release_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$release_file")"
    require_main_lineage "final pre-publication"
    audit_live_rollout_progression "final pre-publication"
    if ! GH_TOKEN="$TIP_GH_TOKEN" gh api --method PATCH \
        "/repos/$TIP_UPDATE_REPOSITORY/releases/$release_id" \
        -F draft=false -f make_latest=true >/dev/null; then
        write_release_json "$release_file" || fail "Unable to publish or reconcile Tip release"
        python3 - "$release_file" <<'PY'
import json,sys
if json.load(open(sys.argv[1], encoding="utf-8")).get("draft") is not False:
    raise SystemExit("ERROR: Tip release remains a draft after publication failure")
PY
        return 0
    fi
    write_release_json "$release_file" || fail "Published Tip release is not observable"
}

audit_public_release() {
    local release_file="$TMP_DIR/public-release.json" status
    status="$(fetch_json_status \
        "https://api.github.com/repos/$TIP_UPDATE_REPOSITORY/releases/tags/$TIP_TAG" \
        "$release_file")"
    [[ "$status" == "200" ]] || fail "Published Tip release lookup failed with HTTP $status"
    validate_release_metadata "$release_file" public

    local report_file="$TMP_DIR/public-assets.tsv"
    python3 - "$release_file" "$report_file" "$TIP_UPDATE_REPOSITORY" "$TIP_TAG" <<'PY'
import json
import sys
from pathlib import Path
release = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
repository, tag = sys.argv[3:]
assets = release.get("assets", [])
seen = set()
rows = []
for asset in assets:
    name = asset.get("name")
    url = asset.get("browser_download_url")
    if not isinstance(name, str) or not name or name in seen:
        raise SystemExit("ERROR: duplicate or malformed public Tip asset")
    expected_url = f"https://github.com/{repository}/releases/download/{tag}/{name}"
    if url != expected_url:
        raise SystemExit(f"ERROR: invalid public Tip asset URL: {name}")
    seen.add(name)
    rows.append((name, url))
Path(sys.argv[2]).write_text("".join(f"{name}\t{url}\n" for name, url in rows), encoding="utf-8")
PY

    local name url expected_path downloaded count=0
    while IFS=$'\t' read -r name url; do
        [[ -n "$name" ]] || continue
        expected_path="$(asset_path_for_name "$name")" || fail "Unexpected public Tip asset: $name"
        downloaded="$TMP_DIR/public-$name"
        curl --fail --location --silent --show-error \
            --connect-timeout 10 --max-time 900 \
            "$url" --output "$downloaded"
        verify_downloaded_asset "$expected_path" "$downloaded" "$name"
        count=$((count + 1))
    done < "$report_file"
    [[ "$count" == "${#EXPECTED_NAMES[@]}" ]] ||
        fail "Public Tip release asset inventory mismatch: expected=${#EXPECTED_NAMES[@]} actual=$count"

    local latest_file="$TMP_DIR/latest-public-release.json" latest_status latest_tag
    latest_status="$(fetch_json_status \
        "https://api.github.com/repos/$TIP_UPDATE_REPOSITORY/releases/latest" \
        "$latest_file")"
    [[ "$latest_status" == "200" ]] || fail "Latest Tip release lookup failed with HTTP $latest_status"
    latest_tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tag_name", ""))' "$latest_file")"
    [[ "$latest_tag" == "$TIP_TAG" ]] || fail "Published Tip release is not the latest release"
}

validate_candidate_bindings
require_main_lineage "publication setup"
audit_live_rollout_progression "publication setup"
release_file="$TMP_DIR/release.json"
create_draft_if_missing "$release_file"

state="$(python3 -c 'import json,sys; print("draft" if json.load(open(sys.argv[1]))["draft"] else "public")' "$release_file")"
validate_release_metadata "$release_file" "$state"
audit_authenticated_release_assets "$release_file" "$([[ "$state" == draft ]] && echo true || echo false)"

if [[ "$state" == "public" ]]; then
    audit_public_release
    printf 'OK: Tip release %s was already public and is byte-exact.\n' "$TIP_TAG"
    exit 0
fi

upload_missing_assets "$release_file"
write_release_json "$release_file" || fail "Tip draft disappeared before final audit"
validate_release_metadata "$release_file" draft
audit_authenticated_release_assets "$release_file" false
publish_draft "$release_file"
validate_release_metadata "$release_file" public
audit_public_release
printf 'OK: published and audited Tip release %s to %s.\n' "$TIP_TAG" "$TIP_UPDATE_REPOSITORY"
