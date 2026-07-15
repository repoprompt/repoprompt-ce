#!/usr/bin/env bash
set -euo pipefail

TARGET_PID="${1:-}"
WAIT_SECONDS="${REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_WAIT:-3}"
OPEN_CLOSE_CYCLES="${REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_CYCLES:-3}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ "$TARGET_PID" =~ ^[1-9][0-9]*$ ]] || fail "Target RepoPrompt debug PID must be a positive integer: $TARGET_PID"
[[ "$WAIT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "Wait must be a non-negative number: $WAIT_SECONDS"
[[ "$OPEN_CLOSE_CYCLES" =~ ^[1-9][0-9]*$ ]] || fail "Cycle count must be a positive integer: $OPEN_CLOSE_CYCLES"

exec osascript - "$TARGET_PID" "$WAIT_SECONDS" "$OPEN_CLOSE_CYCLES" <<'APPLESCRIPT'
on accessibilityPermissionPreflight()
    try
        tell application "System Events"
            set permissionEnabled to UI elements enabled
        end tell
    on error
        error "Accessibility permission is required for this UI smoke. Enable RepoPrompt CE in System Settings > Privacy & Security > Accessibility."
    end try
    if not permissionEnabled then
        error "Accessibility permission is required for this UI smoke. Enable RepoPrompt CE in System Settings > Privacy & Security > Accessibility."
    end if
end accessibilityPermissionPreflight

on assertProcessExistsForPID(targetPID)
    tell application "System Events"
        -- System Events incorrectly resolves a variable inside a `whose unix id`
        -- filter to the first matching application process on this host. Enumerate
        -- the process objects and compare their numeric IDs instead; never fall
        -- back to a process name, which could target another RepoPrompt instance.
        repeat with candidateProcess in application processes
            try
                set candidatePID to (unix id of candidateProcess) as integer
                if candidatePID is targetPID then
                    if ((unix id of candidateProcess) as integer) is targetPID then return
                end if
            end try
        end repeat
    end tell
    error "Could not find the RepoPrompt debug process with PID " & targetPID
end assertProcessExistsForPID

on firstElementForPID(targetPID, targetIdentifier)
    tell application "System Events"
        repeat with candidateProcess in application processes
            if ((unix id of candidateProcess) as integer) is targetPID then
                tell candidateProcess
                    -- Focused UI smoke targets the front window only; searching
                    -- background windows can traverse hundreds of stale tabs.
                    repeat with windowIndex from 1 to 1
                        if targetIdentifier is "agent-execution-location-pill" then
                            try
                                set matches to entire contents of window windowIndex whose value of attribute "AXIdentifier" is "agent-execution-location-pill"
                                if (count of matches) > 0 then return item 1 of matches
                            end try
                        else if targetIdentifier is "agent-execution-location-option-local" then
                            try
                                set matches to entire contents of window windowIndex whose value of attribute "AXIdentifier" is "agent-execution-location-option-local"
                                if (count of matches) > 0 then return item 1 of matches
                            end try
                        else if targetIdentifier is "agent-execution-location-option-new-worktree" then
                            try
                                set matches to entire contents of window windowIndex whose value of attribute "AXIdentifier" is "agent-execution-location-option-new-worktree"
                                if (count of matches) > 0 then return item 1 of matches
                            end try
                        else if targetIdentifier is "agent-execution-location-existing-list" then
                            try
                                set matches to entire contents of window windowIndex whose value of attribute "AXIdentifier" is "agent-execution-location-existing-list"
                                if (count of matches) > 0 then return item 1 of matches
                            end try
                        else if targetIdentifier is "agent-execution-location-existing-empty" then
                            try
                                set matches to entire contents of window windowIndex whose value of attribute "AXIdentifier" is "agent-execution-location-existing-empty"
                                if (count of matches) > 0 then return item 1 of matches
                            end try
                        else if targetIdentifier is "agent-execution-location-existing-error" then
                            try
                                set matches to entire contents of window windowIndex whose value of attribute "AXIdentifier" is "agent-execution-location-existing-error"
                                if (count of matches) > 0 then return item 1 of matches
                            end try
                        else
                            error "Unsupported execution-location accessibility identifier " & targetIdentifier
                        end if
                    end repeat
                end tell
                return missing value
            end if
        end repeat
    end tell
    error "Could not find the RepoPrompt debug process with PID " & targetPID
end firstElementForPID

on waitForElement(targetPID, targetIdentifier, shouldExist)
    -- Native AX snapshots can take about a second on a tab-heavy debug app;
    -- keep polling bounded so a missing identifier fails before the conductor
    -- stage timeout rather than multiplying an expensive traversal indefinitely.
    repeat 8 times
        set foundRef to my firstElementForPID(targetPID, targetIdentifier)
        if shouldExist and foundRef is not missing value then return foundRef
        if not shouldExist and foundRef is missing value then return missing value
        delay 0.1
    end repeat
    if shouldExist then error "Could not find accessibility element " & targetIdentifier
    error "Accessibility element remained visible after popover close: " & targetIdentifier
end waitForElement

on clickElementForPID(targetPID, targetIdentifier)
    set elementRef to my firstElementForPID(targetPID, targetIdentifier)
    if elementRef is missing value then error "Could not find accessibility element " & targetIdentifier
    tell application "System Events"
        repeat with candidateProcess in application processes
            if ((unix id of candidateProcess) as integer) is targetPID then
                tell candidateProcess
                    if ((unix id) as integer) is targetPID then
                        click elementRef
                    else
                        error "RepoPrompt debug PID changed before click"
                    end if
                    return
                end tell
            end if
        end repeat
    end tell
    error "Could not find accessibility element " & targetIdentifier
end clickElementForPID

on waitForTerminalState(targetPID)
    set terminalIdentifiers to {"agent-execution-location-existing-list", "agent-execution-location-existing-empty", "agent-execution-location-existing-error"}
    repeat 20 times
        repeat with terminalIdentifier in terminalIdentifiers
            set foundRef to my firstElementForPID(targetPID, terminalIdentifier as text)
            if foundRef is not missing value then return foundRef
        end repeat
        delay 0.1
    end repeat
    error "Existing-worktree picker did not transition from loading to a terminal state"
end waitForTerminalState

on captureWindowIdentity(windowRef)
    tell application "System Events"
        set windowAXIdentifier to ""
        try
            set candidateIdentifier to value of attribute "AXIdentifier" of windowRef
            if candidateIdentifier is not missing value then set windowAXIdentifier to candidateIdentifier as text
        end try
        set windowPosition to position of windowRef
        set windowSize to size of windowRef
    end tell
    return {windowAXIdentifier:windowAXIdentifier, windowPosition:windowPosition, windowSize:windowSize}
end captureWindowIdentity

on windowMatchesIdentity(windowRef, identity)
    tell application "System Events"
        if (identity's windowAXIdentifier) is not "" then
            try
                set candidateIdentifier to value of attribute "AXIdentifier" of windowRef
                return candidateIdentifier as text is identity's windowAXIdentifier
            on error
                return false
            end try
        end if
        try
            return (position of windowRef) is identity's windowPosition and (size of windowRef) is identity's windowSize
        on error
            return false
        end try
    end tell
end windowMatchesIdentity

on captureWindowIdentityForPID(targetPID)
    tell application "System Events"
        repeat with candidateProcess in application processes
            if ((unix id of candidateProcess) as integer) is targetPID then
                tell candidateProcess
                    if not (exists window 1) then error "RepoPrompt debug app has no front window"
                    set windowRef to window 1
                    return my captureWindowIdentity(windowRef)
                end tell
            end if
        end repeat
    end tell
    error "Could not find the RepoPrompt debug process with PID " & targetPID
end captureWindowIdentityForPID

on hasWindowWithIdentity(targetPID, identity)
    set matchingWindowCount to 0
    tell application "System Events"
        repeat with candidateProcess in application processes
            if ((unix id of candidateProcess) as integer) is targetPID then
                tell candidateProcess
                    repeat with candidateWindow in windows
                        if my windowMatchesIdentity(candidateWindow, identity) then set matchingWindowCount to matchingWindowCount + 1
                    end repeat
                    exit repeat
                end tell
            end if
        end repeat
    end tell
    if matchingWindowCount > 1 then error "RepoPrompt debug host window identity is ambiguous during execution-location UI smoke"
    return matchingWindowCount is 1
end hasWindowWithIdentity

on assertHostSurvived(targetPID, originalIdentity)
    if not my hasWindowWithIdentity(targetPID, originalIdentity) then
        error "RepoPrompt debug host lost its original window identity during execution-location UI smoke"
    end if
end assertHostSurvived

on focusProcessForPID(targetPID)
    tell application "System Events"
        repeat with candidateProcess in application processes
            if ((unix id of candidateProcess) as integer) is targetPID then
                tell candidateProcess
                    if ((unix id) as integer) is not targetPID then error "RepoPrompt debug PID changed during focus"
                    set frontmost to true
                    repeat 10 times
                        if frontmost then exit repeat
                        delay 0.1
                    end repeat
                    if not frontmost then error "RepoPrompt debug app did not become frontmost"
                    repeat 30 times
                        if exists window 1 then return
                        delay 0.2
                    end repeat
                    error "RepoPrompt debug app has no front window"
                end tell
            end if
        end repeat
    end tell
    error "Could not find the RepoPrompt debug process with PID " & targetPID
end focusProcessForPID

on escapePopoverForPID(targetPID)
    tell application "System Events"
        repeat with candidateProcess in application processes
            if ((unix id of candidateProcess) as integer) is targetPID then
                tell candidateProcess
                    if ((unix id) as integer) is not targetPID then error "RepoPrompt debug PID changed before Escape"
                    set frontmost to true
                    repeat 10 times
                        if frontmost then exit repeat
                        delay 0.1
                    end repeat
                    if not frontmost then error "RepoPrompt debug app did not become frontmost before Escape"
                    key code 53
                    return
                end tell
            end if
        end repeat
    end tell
    error "Could not find the RepoPrompt debug process with PID " & targetPID
end escapePopoverForPID

on run argv
    set targetPID to item 1 of argv as integer
    set waitSeconds to item 2 of argv as number
    set openCloseCycles to item 3 of argv as integer

    my accessibilityPermissionPreflight()
    my focusProcessForPID(targetPID)
    set originalIdentity to my captureWindowIdentityForPID(targetPID)

    repeat with cycleIndex from 1 to openCloseCycles
        my assertProcessExistsForPID(targetPID)
        my waitForElement(targetPID, "agent-execution-location-pill", true)
        my clickElementForPID(targetPID, "agent-execution-location-pill")
        -- Require both built-in options so a failed pill click cannot pass vacuously.
        my waitForElement(targetPID, "agent-execution-location-option-local", true)
        my waitForElement(targetPID, "agent-execution-location-option-new-worktree", true)

        -- Keep the popover open while the async worktree load reaches a terminal state.
        delay waitSeconds
        my waitForTerminalState(targetPID)
        my assertHostSurvived(targetPID, originalIdentity)

        my focusProcessForPID(targetPID)
        my waitForElement(targetPID, "agent-execution-location-option-local", true)
        my waitForElement(targetPID, "agent-execution-location-option-new-worktree", true)
        my escapePopoverForPID(targetPID)
        my waitForElement(targetPID, "agent-execution-location-option-local", false)
        my waitForElement(targetPID, "agent-execution-location-option-new-worktree", false)

        my assertHostSurvived(targetPID, originalIdentity)
    end repeat
end run
APPLESCRIPT

printf 'OK: Agent execution-location popover survived %s open/close cycles for PID %s.\n' "$OPEN_CLOSE_CYCLES" "$TARGET_PID"
