#!/usr/bin/env bash
set -euo pipefail
[[ "${VERBOSE:-0}" == "1" || "${VERBOSE:-0}" == "true" ]] && set -x
START_TIME="$(date +%s)"
PHASE_START="$START_TIME"
phase(){
    local now elapsed total
    now="$(date +%s)"
    elapsed=$((now - PHASE_START))
    total=$((now - START_TIME))
    printf '\n==> [%s] %s (previous: %ss, total: %ss)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" "$elapsed" "$total"
    PHASE_START="$now"
}
run(){ printf '+ '; printf '%q ' "$@"; printf '\n'; "$@"; }
DELAYED_LAUNCH_GUARD_SECONDS=12
find_debug_app_pids(){ python3 "$PROCESS_HELPER" list --executable "$APP_EXECUTABLE"; }
terminate_debug_app_processes(){ python3 "$PROCESS_HELPER" terminate --executable "$APP_EXECUTABLE"; }
wait_for_no_debug_app_process(){
    local deadline pids
    deadline=$(( $(date +%s) + 5 ))
    while (( $(date +%s) <= deadline )); do
        if ! pids="$(find_debug_app_pids)"; then
            echo "ERROR: could not safely identify the RepoPrompt CE debug app process."
            return 1
        fi
        [[ -z "$pids" ]] && return 0
        sleep 0.2
    done
    return 1
}
wait_for_debug_app_process(){
    local deadline pids
    deadline=$(( $(date +%s) + 10 ))
    while (( $(date +%s) <= deadline )); do
        if ! pids="$(find_debug_app_pids)"; then
            echo "ERROR: could not safely identify the launched RepoPrompt CE debug app process." >&2
            return 1
        fi
        if [[ -n "$pids" ]]; then
            printf '%s\n' "$pids"
            return 0
        fi
        sleep 0.2
    done
    return 1
}
guard_delayed_debug_app_launch(){
    local deadline pids terminated_pids
    deadline=$(( $(date +%s) + DELAYED_LAUNCH_GUARD_SECONDS ))
    while (( $(date +%s) <= deadline )); do
        if ! pids="$(find_debug_app_pids)"; then
            echo "ERROR: could not safely identify a delayed RepoPrompt CE debug app process."
            return 1
        fi
        if [[ -n "$pids" ]]; then
            printf 'Observed delayed RepoPrompt CE debug PID(s): %s\n' "$(printf '%s' "$pids" | paste -sd ', ' -)"
            if ! terminated_pids="$(terminate_debug_app_processes)"; then
                echo "ERROR: refused to signal a delayed process without validated debug app identity."
                return 1
            fi
        fi
        sleep 0.2
    done
    if ! wait_for_no_debug_app_process; then
        echo "ERROR: RepoPrompt CE debug app remained running after delayed-launch guard."
        return 1
    fi
    echo "Delayed launch guard confirmed RepoPrompt CE debug app stopped."
}
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESS_HELPER="$ROOT_DIR/Scripts/debug_app_process.py"
DEBUG_APP_ROOT="${REPOPROMPT_DEBUG_APP_ROOT:-$HOME/Library/Application Support/RepoPrompt CE/DebugApps}"
APP_BUNDLE="${REPOPROMPT_DEBUG_APP_BUNDLE:-$DEBUG_APP_ROOT/RepoPrompt.app}"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/RepoPrompt"
export REPOPROMPT_DEBUG_APP_BUNDLE="$APP_BUNDLE"
phase "Packaging debug app"
run "$ROOT_DIR/Scripts/package_app.sh" debug
phase "Checking packaged app signing"
SIGNING_DETAILS="$(codesign -dv "$APP_BUNDLE" 2>&1 || true)"
TEAM_ID="$(printf '%s\n' "$SIGNING_DETAILS" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
AUTHORITIES="$(printf '%s\n' "$SIGNING_DETAILS" | awk -F= '/^Authority=/{print $2}' | paste -sd ', ' -)"
DEBUG_STORAGE_BACKEND_MARKER="$(plutil -extract RepoPromptDebugSecureStorageBackend raw -o - "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
printf 'Launch app path: %s\n' "$APP_BUNDLE"
printf 'Launch app team: %s\n' "${TEAM_ID:-<missing>}"
printf 'Launch app signing authorities: %s\n' "${AUTHORITIES:-<none/ad-hoc>}"
printf 'Launch app debug secure storage marker: %s\n' "${DEBUG_STORAGE_BACKEND_MARKER:-<missing>}"
if [[ "$DEBUG_STORAGE_BACKEND_MARKER" != "keychain" ]]; then
    echo "WARNING: Debug secure storage is in-memory this run; secrets and permission changes won't persist (set SIGN_IDENTITY=\"Apple Development: ...\" for Keychain)."
elif [[ -z "$TEAM_ID" || "$TEAM_ID" == "not set" ]]; then
    echo "WARNING: Launching a keychain-marked debug app without a team identifier; runtime will fall back to in-memory secure storage."
fi
phase "Stopping existing RepoPrompt CE debug app instance"
if ! TERMINATED_PIDS="$(terminate_debug_app_processes)"; then
    echo "ERROR: refused to stop a process without validated RepoPrompt CE debug app identity."
    exit 1
fi
phase "Waiting for existing RepoPrompt CE debug app process to exit"
if ! wait_for_no_debug_app_process; then
    echo "ERROR: existing RepoPrompt CE debug app process did not exit within 5 seconds; refusing to open another instance."
    exit 1
fi
echo "RepoPrompt CE debug app stop confirmed."
if [[ "${REPOPROMPT_GUARD_DELAYED_LAUNCH:-0}" == "1" ]]; then
    phase "Guarding against a delayed RepoPrompt CE debug app launch from superseded app work"
    guard_delayed_debug_app_launch
fi
phase "Launching $APP_BUNDLE"
if (( $# > 0 )); then run open -n "$APP_BUNDLE" --args "$@"; else run open -n "$APP_BUNDLE"; fi
phase "Confirming launched RepoPrompt CE debug app process"
if ! LAUNCHED_PIDS="$(wait_for_debug_app_process)"; then
    echo "ERROR: launch request returned, but no matching RepoPrompt CE debug app process appeared within 10 seconds."
    phase "Guarding against a delayed RepoPrompt CE debug app launch after launch confirmation failure"
    guard_delayed_debug_app_launch || true
    exit 1
fi
printf 'Observed launched RepoPrompt CE debug PID(s): %s\n' "$(printf '%s' "$LAUNCHED_PIDS" | paste -sd ', ' -)"
