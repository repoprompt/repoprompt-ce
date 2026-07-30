#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" != 3 ]]; then
    printf '%s\n' \
        'GitHub public tip lookup classification=invalid-input status=000 request_id=unavailable rate_limit_remaining=unavailable rate_limit_reset=unavailable retry_after=unavailable' \
        >&2
    exit 1
fi

REPOSITORY="$1"
TAG="$2"
ARCHIVE_BASENAME="$3"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repoprompt-tip-lookup.XXXXXX")"
RESPONSE_BODY="$TMP_DIR/response.json"
RESPONSE_HEADERS="$TMP_DIR/response.headers"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

header_value() {
    local wanted="$1"
    awk -v wanted="$wanted" '
        {
            line = $0
            sub(/\r$/, "", line)
            if (line ~ /^HTTP\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]([[:space:]]|$)/) {
                result = ""
                next
            }
            separator = index(line, ":")
            if (separator > 0 && tolower(substr(line, 1, separator - 1)) == tolower(wanted)) {
                value = substr(line, separator + 1)
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                result = value
            }
        }
        END { print result }
    ' "$RESPONSE_HEADERS"
}

classify_403_body() {
    python3 - "$RESPONSE_BODY" <<'PYTHON'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        response = json.load(handle)
    message = response.get("message", "") if isinstance(response, dict) else ""
except Exception:
    message = ""

normalized = message.casefold()
if "rate limit" in normalized or "abuse detection" in normalized:
    print("rate-limited")
else:
    print("unexpected-failure")
PYTHON
}

classify_found_body() {
    python3 - "$RESPONSE_BODY" "$ARCHIVE_BASENAME" <<'PYTHON'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        release = json.load(handle)
    if not isinstance(release, dict):
        raise ValueError
    archive_basename = sys.argv[2]
    expected = {
        f"{archive_basename}.zip",
        f"{archive_basename}.dmg",
        "appcast.xml",
        "SHA256SUMS",
        f"{archive_basename}-artifact-manifest.json",
        f"{archive_basename}-metadata.json",
    }
    assets = release.get("assets", [])
    if not isinstance(assets, list) or not all(isinstance(asset, dict) for asset in assets):
        raise ValueError
    actual = {asset.get("name") for asset in assets}
    if release.get("draft") is not False or release.get("prerelease") is not False or actual != expected:
        raise ValueError
except Exception:
    print("malformed")
else:
    print("found")
PYTHON
}

curl_headers=(
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
)
if [[ -n "${TIP_GH_TOKEN:-}" ]]; then
    curl_headers+=(--header "Authorization: Bearer $TIP_GH_TOKEN")
fi

classification=transport-failure
status=000
for attempt in 1 2 3; do
    : > "$RESPONSE_BODY"
    : > "$RESPONSE_HEADERS"
    request_id=unavailable
    rate_limit_remaining=unavailable
    rate_limit_reset=unavailable
    retry_after=unavailable

    if status="$(curl --location --silent \
        --connect-timeout 10 \
        --max-time 30 \
        "${curl_headers[@]}" \
        --dump-header "$RESPONSE_HEADERS" \
        --output "$RESPONSE_BODY" \
        --write-out '%{http_code}' \
        "https://api.github.com/repos/$REPOSITORY/releases/tags/$TAG" \
        2>/dev/null)"; then
        [[ "$status" =~ ^[0-9]{3}$ ]] || status=000
        request_id="$(header_value x-github-request-id)"
        rate_limit_remaining="$(header_value x-ratelimit-remaining)"
        rate_limit_reset="$(header_value x-ratelimit-reset)"
        retry_after="$(header_value retry-after)"
        request_id="${request_id:-unavailable}"
        rate_limit_remaining="${rate_limit_remaining:-unavailable}"
        rate_limit_reset="${rate_limit_reset:-unavailable}"
        retry_after="${retry_after:-unavailable}"

        case "$status" in
            200) classification="$(classify_found_body)" ;;
            404) classification=not-found ;;
            403)
                if [[ "$rate_limit_remaining" == "0" || "$retry_after" != "unavailable" ]]; then
                    classification=rate-limited
                else
                    classification="$(classify_403_body)"
                fi
                ;;
            429) classification=rate-limited ;;
            5??) classification=server-failure ;;
            *) classification=unexpected-failure ;;
        esac
    else
        status=000
        classification=transport-failure
    fi

    printf '%s\n' \
        "GitHub public tip lookup classification=$classification status=$status request_id=$request_id rate_limit_remaining=$rate_limit_remaining rate_limit_reset=$rate_limit_reset retry_after=$retry_after" \
        >&2

    case "$classification" in
        found|not-found|malformed|unexpected-failure)
            break
            ;;
        rate-limited|server-failure|transport-failure)
            if (( attempt == 3 )); then
                break
            fi
            retry_delay="$attempt"
            if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
                retry_delay="$retry_after"
                (( retry_delay <= 10 )) || retry_delay=10
            fi
            sleep "$retry_delay"
            ;;
    esac
done

case "$classification" in
    found|not-found)
        printf '%s\n' "$classification"
        ;;
    *)
        exit 1
        ;;
esac
