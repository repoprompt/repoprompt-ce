#!/usr/bin/env bash
set -euo pipefail

APP_PROCESS_NAME="${1:-RepoPrompt}"
WAIT_SECONDS="${REPOPROMPT_EXECUTION_LOCATION_UI_SMOKE_WAIT:-3}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

osascript <<APPLESCRIPT
on labelText(elementRef)
    tell application "System Events"
        set parts to {}
        try
            set elementName to name of elementRef
            if elementName is not missing value and elementName is not "" then set end of parts to elementName as text
        end try
        try
            set elementDescription to description of elementRef
            if elementDescription is not missing value and elementDescription is not "" then set end of parts to elementDescription as text
        end try
        try
            set elementValue to value of elementRef
            if elementValue is not missing value and elementValue is not "" then set end of parts to elementValue as text
        end try
        return parts as text
    end tell
end labelText

on containsAnyNeedle(haystack, needles)
    set lowerHaystack to do shell script "printf %s " & quoted form of haystack & " | tr '[:upper:]' '[:lower:]'"
    repeat with needle in needles
        set lowerNeedle to do shell script "printf %s " & quoted form of (needle as text) & " | tr '[:upper:]' '[:lower:]'"
        if lowerHaystack contains lowerNeedle then return true
    end repeat
    return false
end containsAnyNeedle

on firstButtonContaining(containerRef, needles)
    tell application "System Events"
        try
            repeat with candidate in buttons of containerRef
                if my containsAnyNeedle(my labelText(candidate), needles) then return candidate
            end repeat
        end try
        try
            repeat with child in UI elements of containerRef
                set found to my firstButtonContaining(child, needles)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end firstButtonContaining

on clickButtonContaining(processRef, needles, requiredLabel)
    tell application "System Events"
        set targetButton to my firstButtonContaining(processRef, needles)
        if targetButton is missing value then error "Could not find " & requiredLabel
        click targetButton
    end tell
end clickButtonContaining

tell application "${APP_PROCESS_NAME}" to activate
delay 0.5

tell application "System Events"
    if not (exists process "${APP_PROCESS_NAME}") then error "${APP_PROCESS_NAME} process is not running"
    tell process "${APP_PROCESS_NAME}"
        set frontmost to true
        repeat 30 times
            if exists window 1 then exit repeat
            delay 0.2
        end repeat
        if not (exists window 1) then error "${APP_PROCESS_NAME} has no front window"
    end tell
end tell

-- Open the execution-location popover from the pill. The visible pill label is usually
-- "Work locally" before an Agent session is bound to a worktree.
tell application "System Events"
    tell process "${APP_PROCESS_NAME}"
        my clickButtonContaining(it, {"Work locally", "Workspace checkout", "New worktree"}, "execution-location pill")
    end tell
end tell

delay ${WAIT_SECONDS}

-- Exercise at least one option if it is present, then switch back to local when available.
tell application "System Events"
    tell process "${APP_PROCESS_NAME}"
        set newWorktreeButton to my firstButtonContaining(it, {"New worktree"})
        if newWorktreeButton is not missing value then
            click newWorktreeButton
            delay 0.5
        end if
        set localButton to my firstButtonContaining(it, {"Workspace checkout", "Work locally"})
        if localButton is not missing value then
            click localButton
            delay 0.5
        end if
    end tell
end tell

-- If the app survived the popover open, async load, and option click path, the smoke passes.
tell application "System Events"
    if not (exists process "${APP_PROCESS_NAME}") then error "${APP_PROCESS_NAME} process exited during execution-location UI smoke"
end tell
APPLESCRIPT

printf 'OK: Agent execution-location UI smoke passed for process %s.\n' "$APP_PROCESS_NAME"
