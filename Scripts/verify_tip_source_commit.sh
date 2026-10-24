#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_env() { [[ -n "${!1:-}" ]] || fail "Missing required environment variable: $1"; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

for name in TIP_SOURCE_GH_TOKEN TIP_SOURCE_REPOSITORY TIP_SOURCE_BRANCH TIP_COMMIT; do
    require_env "$name"
done
for command in curl python3; do require_command "$command"; done

allow_ancestor=false
if [[ "${1:-}" == "--allow-ancestor" ]]; then
    allow_ancestor=true
    shift
fi
[[ "$#" == 1 && -n "$1" ]] || fail "Usage: $0 [--allow-ancestor] <verification-phase>"
phase="$1"

[[ "$TIP_SOURCE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    fail "TIP_SOURCE_REPOSITORY must be an owner/repository slug"
[[ "$TIP_SOURCE_BRANCH" == "main" ]] || fail "Tip publication source branch must remain main"
[[ "$TIP_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "TIP_COMMIT must be a full lowercase Git SHA"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/repoprompt-tip-source.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

response="$tmp_dir/live-main.json"
status="$(curl --location --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --header "Authorization: Bearer $TIP_SOURCE_GH_TOKEN" \
    --output "$response" --write-out '%{http_code}' \
    "https://api.github.com/repos/$TIP_SOURCE_REPOSITORY/commits/$TIP_SOURCE_BRANCH")" ||
    fail "Protected-main GitHub API request failed"
[[ "$status" =~ ^[0-9]{3}$ ]] || fail "Protected-main lookup returned an invalid HTTP status"

if [[ "$status" != "200" ]]; then
    message="$(python3 - "$response" <<'PY'
import json
import sys

try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    print("GitHub response did not contain a JSON error message")
else:
    value = payload.get("message") if isinstance(payload, dict) else None
    print(value if isinstance(value, str) and value else "GitHub response did not contain an error message")
PY
)"
    fail "Protected-main lookup failed with HTTP $status: $message"
fi

live_main="$(python3 - "$response" <<'PY'
import json
import sys

try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit("ERROR: Protected-main lookup returned invalid JSON")
value = payload.get("sha") if isinstance(payload, dict) else None
print(value if isinstance(value, str) else "")
PY
)"
[[ "$live_main" =~ ^[0-9a-f]{40}$ ]] || fail "$phase did not resolve a full live-main SHA"
if [[ "$live_main" == "$TIP_COMMIT" ]]; then
    printf 'OK: %s confirmed protected main at %s.\n' "$phase" "$live_main"
    exit 0
fi

if [[ "$allow_ancestor" != true ]]; then
    fail "$phase rejected stale Tip candidate: candidate=$TIP_COMMIT live-main=$live_main"
fi

compare_response="$tmp_dir/main-lineage.json"
compare_status="$(curl --location --silent --show-error \
    --connect-timeout 10 --max-time 30 \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --header "Authorization: Bearer $TIP_SOURCE_GH_TOKEN" \
    --output "$compare_response" --write-out '%{http_code}' \
    "https://api.github.com/repos/$TIP_SOURCE_REPOSITORY/compare/$TIP_COMMIT...$TIP_SOURCE_BRANCH")" ||
    fail "Protected-main lineage GitHub API request failed"
[[ "$compare_status" =~ ^[0-9]{3}$ ]] || fail "Protected-main lineage lookup returned an invalid HTTP status"
[[ "$compare_status" == "200" ]] || fail "Protected-main lineage lookup failed with HTTP $compare_status"

lineage="$(python3 - "$compare_response" <<'PY'
import json
import sys

try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit("ERROR: Protected-main lineage lookup returned invalid JSON")
status = payload.get("status") if isinstance(payload, dict) else None
merge_base = payload.get("merge_base_commit") if isinstance(payload, dict) else None
merge_base_sha = merge_base.get("sha") if isinstance(merge_base, dict) else None
print(f"{status or ''}|{merge_base_sha or ''}")
PY
)"
relation="${lineage%%|*}"
merge_base="${lineage#*|}"
[[ "$relation" == "ahead" && "$merge_base" == "$TIP_COMMIT" ]] ||
    fail "$phase rejected Tip candidate outside protected-main ancestry: candidate=$TIP_COMMIT live-main=$live_main relation=${relation:-unknown} merge-base=${merge_base:-unknown}"

printf 'OK: %s confirmed candidate %s remains an ancestor of protected main %s.\n' \
    "$phase" "$TIP_COMMIT" "$live_main"
