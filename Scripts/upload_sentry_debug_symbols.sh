#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

if [[ $# -lt 1 ]]; then
    fail "usage: upload_sentry_debug_symbols.sh <debug-symbol-path>..."
fi

token_file="${REPOPROMPT_SENTRY_AUTH_TOKEN_FILE:-}"
if [[ -n "$token_file" ]]; then
    [[ -f "$token_file" ]] || fail "Sentry auth token file does not exist: $token_file"
    SENTRY_AUTH_TOKEN="$(tr -d '\r\n' < "$token_file")"
fi

if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
    printf 'Skipping Sentry debug symbol upload: SENTRY_AUTH_TOKEN is not set.\n'
    exit 0
fi

sentry_org="${REPOPROMPT_SENTRY_ORG:-}"
sentry_project="${REPOPROMPT_SENTRY_PROJECT:-}"
[[ -n "$sentry_org" ]] || fail "REPOPROMPT_SENTRY_ORG is required when uploading Sentry debug symbols."
[[ -n "$sentry_project" ]] || fail "REPOPROMPT_SENTRY_PROJECT is required when uploading Sentry debug symbols."
command -v sentry-cli >/dev/null 2>&1 || fail "sentry-cli is required to upload Sentry debug symbols."

paths=()
for candidate in "$@"; do
    if [[ -e "$candidate" ]]; then
        paths+=("$candidate")
    fi
done
(( ${#paths[@]} > 0 )) || fail "No existing Sentry debug symbol paths were provided."

args=(debug-files upload --include-sources --org "$sentry_org" --project "$sentry_project")
if truthy "${REPOPROMPT_SENTRY_UPLOAD_WAIT:-0}"; then
    args+=(--wait)
fi
args+=("${paths[@]}")

export SENTRY_AUTH_TOKEN
printf 'Uploading Sentry debug symbols for org=%s project=%s from %s path(s).\n' \
    "$sentry_org" "$sentry_project" "${#paths[@]}"
sentry-cli "${args[@]}"
