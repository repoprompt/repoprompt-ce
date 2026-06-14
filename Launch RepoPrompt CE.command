#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDUCTOR="$ROOT_DIR/conductor"
APP_ARGS=("$@")

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

launch_app() {
    echo
    echo "Building and relaunching RepoPrompt CE..."
    echo "This run becomes the active launch; any older build or launch jobs still in flight are canceled."
    echo
    if (( ${#APP_ARGS[@]} > 0 )); then
        if "$CONDUCTOR" app relaunch -- "${APP_ARGS[@]}"; then
            echo
            echo "RepoPrompt CE has been relaunched."
        else
            echo
            echo "RepoPrompt CE was not relaunched."
            echo "Check the result above to see whether the build failed or this run was canceled/replaced."
            echo "If the build failed, fix the errors (or let in-flight edits settle), then press r to retry."
            echo "Press s to check the current app and job state."
        fi
    elif "$CONDUCTOR" app relaunch; then
        echo
        echo "RepoPrompt CE has been relaunched."
    else
        echo
        echo "RepoPrompt CE was not relaunched."
        echo "Check the result above to see whether the build failed or this run was canceled/replaced."
        echo "If the build failed, fix the errors (or let in-flight edits settle), then press r to retry."
        echo "Press s to check the current app and job state."
    fi
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
