#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDUCTOR="$ROOT_DIR/conductor"
APP_ARGS=("$@")
LAUNCHER_ADHOC_SIGNING=0

if ! command -v python3 >/dev/null 2>&1; then
    echo "RepoPrompt CE's safe coordinated launcher requires Python 3."
    echo "No uncoordinated fallback is provided because app lifecycle actions must validate the exact debug executable path."
    echo
    echo "Install Python 3, then reopen this launcher."
    read -r -p "Press Return to close this window..." || true
    exit 1
elif [[ ! -x "$CONDUCTOR" ]]; then
    echo "Couldn't find the coordinated launcher:"
    echo "$CONDUCTOR"
    echo
    echo "Make sure this file is still in the repoprompt-ce folder and that conductor is executable."
    read -r -p "Press Return to close this window..." || true
    exit 1
fi

configure_debug_signing() {
    if [[ -n "${SIGN_IDENTITY:-}" || "${ALLOW_ADHOC_SIGNING:-0}" == "1" || "${ALLOW_ADHOC_SIGNING:-0}" == "true" ]]; then
        return 0
    fi

    local apple_development_identity
    apple_development_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Apple Development: / { print $2; exit }' || true)"
    if [[ -n "$apple_development_identity" ]]; then
        return 0
    fi

    export ALLOW_ADHOC_SIGNING=1
    LAUNCHER_ADHOC_SIGNING=1
}

launch_app() {
    echo
    echo "Building and relaunching RepoPrompt CE..."
    echo "This run becomes the active launch; any older build or launch jobs still in flight are canceled."
    if (( LAUNCHER_ADHOC_SIGNING )); then
        echo "No Apple Development signing identity was found, so this launcher is using explicit ad-hoc debug signing."
        echo "Debug secure storage will be in-memory; saved API keys and secure permission changes will not persist across app launches."
    fi
    echo
    local launch_log
    launch_log="$(mktemp -t repoprompt-ce-launch)"
    local relaunch_rc=0
    if (( ${#APP_ARGS[@]} > 0 )); then
        "$CONDUCTOR" app relaunch -- "${APP_ARGS[@]}" 2>&1 | tee "$launch_log" || relaunch_rc=${PIPESTATUS[0]}
    else
        "$CONDUCTOR" app relaunch 2>&1 | tee "$launch_log" || relaunch_rc=${PIPESTATUS[0]}
    fi
    if (( relaunch_rc == 0 )); then
        echo
        echo "RepoPrompt CE has been relaunched."
    else
        echo
        echo "RepoPrompt CE was not relaunched."
        echo "Check the result above to see whether the build failed or this run was canceled/replaced."
        echo "If the build failed, fix the errors (or let in-flight edits settle), then press r to retry."
        echo "Press s to check the current app and job state."
        if grep -q "Debug ad-hoc signing is disabled by default" "$launch_log"; then
            echo
            echo "Debug signing was refused even though this launcher tried to configure it automatically."
            echo "Run the same debug app from Terminal with explicit ad-hoc signing:"
            echo
            echo "  ALLOW_ADHOC_SIGNING=1 ./conductor app relaunch"
            echo
            echo "Ad-hoc debug builds use in-memory secure storage, so saved API keys and secure"
            echo "permission changes do not persist across launches. For persistent debug"
            echo "Keychain storage, pass a stable Apple Development identity explicitly:"
            echo
            echo "  SIGN_IDENTITY=\"Apple Development: Your Name (TEAMID)\" ./conductor app relaunch"
        fi
    fi
    rm -f "$launch_log"
}

show_status() {
    echo
    echo "Current RepoPrompt CE app status:"
    echo
    if ! "$CONDUCTOR" app status --full-log; then
        echo
        echo "Couldn't read app status. Review the daemon output above and try again."
    fi
    echo
    echo "Pending daemon jobs that may change the app next:"
    echo "Only daemon-managed jobs show up here; direct commands and source edits aren't tracked."
    echo
    if ! "$CONDUCTOR" status; then
        echo
        echo "Couldn't read daemon activity. Review the daemon output above and try again."
    fi
}

stop_app() {
    echo
    echo "Stopping RepoPrompt CE..."
    echo "Older build or launch jobs that could reopen it are canceled too."
    echo
    if ! "$CONDUCTOR" app stop --full-log; then
        echo
        echo "Couldn't stop RepoPrompt. Review the daemon output above, or press s to check status."
    fi
}

close_launcher_terminal() {
    local launcher_tty
    launcher_tty="$(tty 2>/dev/null || true)"
    if [[ "$launcher_tty" != /dev/* || ! -x /usr/bin/osascript ]]; then
        return 0
    fi

    (
        sleep 0.2
        /usr/bin/osascript - "$launcher_tty" <<'APPLESCRIPT'
on run argv
    set launcherTTY to item 1 of argv
    tell application "Terminal"
        repeat with terminalWindow in windows
            repeat with terminalTab in tabs of terminalWindow
                if tty of terminalTab is launcherTTY then
                    close terminalTab
                    return
                end if
            end repeat
        end repeat
    end tell
end run
APPLESCRIPT
    ) </dev/null >/dev/null 2>&1 &
}

clear 2>/dev/null || true
echo "RepoPrompt CE — local debug launcher"
echo
echo "Project: $ROOT_DIR"
echo "Mode:    coordinated (builds and launches run through the dev daemon)"

cd "$ROOT_DIR" || exit 1
configure_debug_signing
launch_app

while true; do
    echo
    echo "Choose an action:"
    echo "  r  Rebuild and relaunch RepoPrompt CE"
    echo "  s  Show app status and pending daemon jobs"
    echo "  x  Stop the app (also cancels older build/launch jobs)"
    echo "  q  Close this launcher tab only (leaves the app running)"
    echo

    if ! IFS= read -r -n 1 -p "Action [r/s/x/q]: " choice; then
        echo
        echo "Closing this launcher. The app keeps running and no jobs are canceled."
        exit 0
    fi
    echo

    case "$choice" in
        r | R)
            launch_app
            ;;
        s | S)
            show_status
            ;;
        x | X)
            stop_app
            ;;
        q | Q)
            echo
            echo "Closing this launcher tab. The app keeps running and no jobs are canceled."
            close_launcher_terminal
            exit 0
            ;;
        *)
            echo
            echo "Please choose r, s, x, or q."
            ;;
    esac
done
