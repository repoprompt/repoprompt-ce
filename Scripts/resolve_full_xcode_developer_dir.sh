#!/usr/bin/env bash
set -euo pipefail

MINIMUM_MACOS_SDK_MAJOR=26

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

developer_dir_is_usable() {
    local developer_dir="$1"
    local sdk_version

    [[ -d "$developer_dir" ]] || return 1
    [[ -x "$developer_dir/usr/bin/xcodebuild" ]] || return 1
    [[ -d "$developer_dir/Platforms/MacOSX.platform" ]] || return 1
    if ! sdk_version="$(DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-version 2>/dev/null)"; then
        return 1
    fi
    [[ "$sdk_version" =~ ^([0-9]+)(\.|$) ]] || return 1
    (( BASH_REMATCH[1] >= MINIMUM_MACOS_SDK_MAJOR ))
}

append_candidate() {
    local candidate="$1"
    local existing
    for existing in "${CANDIDATES[@]:-}"; do
        [[ "$existing" != "$candidate" ]] || return 0
    done
    CANDIDATES+=("$candidate")
}

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    developer_dir_is_usable "$DEVELOPER_DIR" ||
        fail "DEVELOPER_DIR must point to a full Xcode with the macOS $MINIMUM_MACOS_SDK_MAJOR SDK or newer: $DEVELOPER_DIR"
    printf '%s\n' "$DEVELOPER_DIR"
    exit 0
fi

SELECTED_DEVELOPER_DIR="$(xcode-select --print-path 2>/dev/null || true)"
if [[ -n "$SELECTED_DEVELOPER_DIR" ]] && developer_dir_is_usable "$SELECTED_DEVELOPER_DIR"; then
    printf '%s\n' "$SELECTED_DEVELOPER_DIR"
    exit 0
fi

CANDIDATES=()
if (( $# )); then
    for candidate in "$@"; do
        append_candidate "$candidate"
    done
else
    append_candidate "/Applications/Xcode.app/Contents/Developer"
    append_candidate "/Applications/Xcode-beta.app/Contents/Developer"
    shopt -s nullglob
    for xcode_app in /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app; do
        append_candidate "$xcode_app/Contents/Developer"
    done
    shopt -u nullglob
fi

for candidate in "${CANDIDATES[@]}"; do
    case "$candidate" in
        *[Bb][Ee][Tt][Aa]*) continue ;;
    esac
    if developer_dir_is_usable "$candidate"; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

for candidate in "${CANDIDATES[@]}"; do
    case "$candidate" in
        *[Bb][Ee][Tt][Aa]*) ;;
        *) continue ;;
    esac
    if developer_dir_is_usable "$candidate"; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

selection_note=""
if [[ -n "$SELECTED_DEVELOPER_DIR" ]]; then
    selection_note=" Current xcode-select path: $SELECTED_DEVELOPER_DIR."
fi
fail "RepoPrompt CE requires a full Xcode with the macOS $MINIMUM_MACOS_SDK_MAJOR SDK or newer.$selection_note Install Xcode in /Applications or set DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer and retry."
