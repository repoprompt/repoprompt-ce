#!/usr/bin/env bash
# Shared deterministic Sentry debug-symbol policy for public release lanes.

release_sentry_symbols_fail() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

release_sentry_linking_enabled() {
    [[ "${REPOPROMPT_ENABLE_SENTRY:-}" == "1" ]]
}

require_release_sentry_symbol_mappings() {
    (( $# > 0 && $# % 2 == 0 )) ||
        release_sentry_symbols_fail "Sentry symbol policy requires dSYM/executable name pairs"
}

require_release_sentry_symbols_when_enabled() {
    local symbols_dir="$1"
    shift
    release_sentry_linking_enabled || return 0
    require_release_sentry_symbol_mappings "$@" || return 1
    [[ -d "$symbols_dir" && ! -L "$symbols_dir" ]] ||
        release_sentry_symbols_fail "Sentry-enabled release staging did not produce a real debug-symbol directory at $symbols_dir" ||
        return 1

    local nested_symlink
    nested_symlink="$(find "$symbols_dir" -type l -print -quit)"
    [[ -z "$nested_symlink" ]] ||
        release_sentry_symbols_fail "Sentry debug symbols must not contain symlinks: $nested_symlink" || return 1

    local dsym_name executable_name dsym_dir dwarf_payload
    while (( $# > 0 )); do
        dsym_name="$1"
        executable_name="$2"
        shift 2
        dsym_dir="$symbols_dir/$dsym_name"
        dwarf_payload="$dsym_dir/Contents/Resources/DWARF/$executable_name"
        [[ -d "$dsym_dir" && ! -L "$dsym_dir" ]] ||
            release_sentry_symbols_fail "Sentry-enabled release staging is missing required debug symbols: $dsym_dir" ||
            return 1
        [[ -f "$dwarf_payload" && ! -L "$dwarf_payload" ]] ||
            release_sentry_symbols_fail "Sentry-enabled release staging is missing required dSYM payload: $dwarf_payload" ||
            return 1
    done
}

stage_release_sentry_symbols() {
    local symbols_dir="$1"
    local staged_symbols_dir="$2"
    shift 2
    release_sentry_linking_enabled || return 0
    require_release_sentry_symbols_when_enabled "$symbols_dir" "$@" || return 1
    command -v ditto >/dev/null 2>&1 ||
        release_sentry_symbols_fail "Missing required command: ditto" || return 1
    mkdir -p "$(dirname "$staged_symbols_dir")"
    ditto "$symbols_dir" "$staged_symbols_dir"
}

release_sentry_uuid_set() {
    local dwarfdump_bin="$1"
    local binary_path="$2"
    local label="$3"
    local raw line uuid_lines=""
    local uuid_pattern='^UUID:[[:space:]]+([[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12})[[:space:]]+\([^)]+\)[[:space:]]+.+$'
    raw="$("$dwarfdump_bin" --uuid "$binary_path" 2>/dev/null)" ||
        release_sentry_symbols_fail "Unable to read Mach-O UUIDs for $label" || return 1

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$line" =~ $uuid_pattern ]]; then
            uuid_lines+="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"$'\n'
        else
            release_sentry_symbols_fail "Malformed Mach-O UUID output for $label"
            return 1
        fi
    done <<< "$raw"

    [[ -n "$uuid_lines" ]] ||
        release_sentry_symbols_fail "Mach-O UUID output was empty for $label" || return 1
    printf '%s' "$uuid_lines" | LC_ALL=C sort -u
}

# UUID validation intentionally lives only at the extracted staged-sign boundary.
# Secret-free staging remains portable and performs structural payload checks only.
verify_release_sentry_symbol_uuids_before_signing() {
    local symbols_dir="$1"
    local app_bundle="$2"
    shift 2
    release_sentry_linking_enabled || return 0
    require_release_sentry_symbols_when_enabled "$symbols_dir" "$@" || return 1
    require_release_sentry_symbol_mappings "$@" || return 1

    local dwarfdump_bin="${REPOPROMPT_DWARFDUMP_BIN:-dwarfdump}"
    command -v "$dwarfdump_bin" >/dev/null 2>&1 ||
        release_sentry_symbols_fail "Missing required command: $dwarfdump_bin" || return 1

    local dsym_name executable_name dwarf_payload staged_executable symbol_uuids executable_uuids
    while (( $# > 0 )); do
        dsym_name="$1"
        executable_name="$2"
        shift 2
        dwarf_payload="$symbols_dir/$dsym_name/Contents/Resources/DWARF/$executable_name"
        staged_executable="$app_bundle/Contents/MacOS/$executable_name"
        [[ -f "$staged_executable" && ! -L "$staged_executable" ]] ||
            release_sentry_symbols_fail "Missing staged executable for Sentry UUID validation: $executable_name" ||
            return 1
        symbol_uuids="$(release_sentry_uuid_set "$dwarfdump_bin" "$dwarf_payload" "$dsym_name payload")" ||
            return 1
        executable_uuids="$(release_sentry_uuid_set "$dwarfdump_bin" "$staged_executable" "$executable_name executable")" ||
            return 1
        [[ "$symbol_uuids" == "$executable_uuids" ]] ||
            release_sentry_symbols_fail "Sentry dSYM UUIDs do not match staged executable: $dsym_name -> $executable_name" ||
            return 1
    done
}

upload_release_sentry_symbols() {
    local symbols_dir="$1"
    local upload_helper="$2"
    shift 2
    release_sentry_linking_enabled || return 0
    require_release_sentry_symbols_when_enabled "$symbols_dir" "$@" || return 1
    [[ -f "$upload_helper" ]] ||
        release_sentry_symbols_fail "Missing required Sentry debug-symbol upload helper: $upload_helper" || return 1
    "$upload_helper" "$symbols_dir"
}
