#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-}"

if [[ -z "$ACTION" || "$ACTION" == "--help" || "$ACTION" == "-h" ]]; then
    cat <<'EOF'
Usage: ./Scripts/swift_style.sh <format|format-check|lint> [--changed [RANGE]]

Subcommands:
  format        Format first-party Swift files with SwiftFormat.
  format-check  Check first-party Swift files for formatting drift.
  lint          Run format-check, then SwiftLint in strict mode.

Install missing tools with:
  make install-format-tools
EOF
    [[ -z "$ACTION" ]] && exit 2 || exit 0
fi
shift || true
CHANGED_RANGE=""
if [[ "${1:-}" == "--changed" ]]; then
    CHANGED_RANGE="${2:-default}"
    shift
    (( $# > 0 )) && shift
fi
if (( $# > 0 )); then
    echo "ERROR: Unexpected arguments: $*" >&2
    exit 2
fi

STYLE_PATHS=(
    "Package.swift"
    "Sources/RepoPrompt"
    "Sources/RepoPromptExecutable"
    "Sources/RepoPromptMCP"
    "Sources/RepoPromptShared"
    "Tests/RepoPromptTests"
    "Packages/RepoPromptAgentProviders/Package.swift"
    "Packages/RepoPromptAgentProviders/Sources"
    "Packages/RepoPromptAgentProviders/Tests"
)

EXCLUDED_SWIFT_PREFIXES=(
    "Sources/RepoPrompt/ThirdParty/SwiftPCRE2/"
    "Packages/RepoPromptAgentProviders/.build/"
)

EXCLUDED_SWIFT_FILES=(
    "Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/WorkflowPromptSharedFragments.swift"
    "Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/WorkflowPrompt+Build.swift"
    "Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/WorkflowPrompt+DeepPlan.swift"
    "Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/WorkflowPrompt+Investigate.swift"
    "Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/WorkflowPrompt+Optimize.swift"
    "Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/WorkflowPrompt+OracleExport.swift"
    "Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/WorkflowPrompt+Orchestrate.swift"
    "Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/WorkflowPrompt+Refactor.swift"
    "Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/WorkflowPrompt+Reminder.swift"
    "Sources/RepoPrompt/Infrastructure/AI/Prompts/Workflows/WorkflowPrompt+Review.swift"
)

fail(){ echo "ERROR: $*" >&2; exit 1; }

ensure_tool(){
    command -v "$1" >/dev/null 2>&1 || fail "Missing required tool: $1. Run 'make install-format-tools'."
}

run(){
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    "$@"
}

should_include_swift_file(){
    local file="$1"
    local excluded prefix
    for prefix in "${EXCLUDED_SWIFT_PREFIXES[@]}"; do
        [[ "$file" == "$prefix"* ]] && return 1
    done
    for excluded in "${EXCLUDED_SWIFT_FILES[@]}"; do
        [[ "$file" == "$excluded" ]] && return 1
    done
    return 0
}

SWIFT_FILES=()
SWIFT_FILES_COLLECTED=0
STYLE_FALLBACK_PATHS=(
    ".swiftformat" ".swiftlint.yml" "Package.swift"
    "Packages/RepoPromptAgentProviders/Package.swift"
    "Scripts/swift_style.sh" "Scripts/install_format_tools.sh"
    ".github/workflows/ci.yml" "Makefile"
)

collect_changed_paths(){
    local range="$1"
    if [[ "$range" == "default" ]]; then
        git diff --name-only --diff-filter=ACMRT -z origin/main...HEAD --
        git diff --name-only --diff-filter=ACMRT -z HEAD --
        git ls-files --others --exclude-standard -z
    else
        git diff --name-only --diff-filter=ACMRT -z "$range" --
    fi
}

path_is_style_fallback(){
    local path="$1" fallback
    for fallback in "${STYLE_FALLBACK_PATHS[@]}"; do
        [[ "$path" == "$fallback" ]] && return 0
    done
    return 1
}

path_is_in_style_scope(){
    local file="$1" scope
    for scope in "${STYLE_PATHS[@]}"; do
        if [[ "$file" == "$scope" || "$file" == "$scope/"* ]]; then
            return 0
        fi
    done
    return 1
}

collect_swift_files(){
    local path full file fallback=0 changed_file
    SWIFT_FILES=()

    if [[ -n "$CHANGED_RANGE" ]]; then
        changed_file="$(mktemp "${TMPDIR:-/tmp}/rpce-style-files.XXXXXX")"
        if ! collect_changed_paths "$CHANGED_RANGE" > "$changed_file"; then
            rm -f -- "$changed_file"
            fail "Unable to determine changed files for style range '$CHANGED_RANGE'; run the full style command."
        fi
        while IFS= read -r -d '' file; do
            path_is_style_fallback "$file" && fallback=1
            if [[ "$file" == *.swift && -f "$ROOT_DIR/$file" && ! -L "$ROOT_DIR/$file" ]] \
                && path_is_in_style_scope "$file" && should_include_swift_file "$file"; then
                SWIFT_FILES+=("$file")
            fi
        done < "$changed_file"
        rm -f -- "$changed_file"
        if (( fallback == 0 )); then
            local sorted
            sorted="$(printf '%s\n' "${SWIFT_FILES[@]}" | sed '/^$/d' | LC_ALL=C sort -u)"
            SWIFT_FILES=()
            while IFS= read -r file; do
                [[ -n "$file" ]] && SWIFT_FILES+=("$file")
            done <<< "$sorted"
            SWIFT_FILES_COLLECTED=1
            return
        fi
        printf 'Changed style/tooling boundary requires full Swift style scope.\n'
    fi

    for path in "${STYLE_PATHS[@]}"; do
        full="$ROOT_DIR/$path"
        if [[ -f "$full" ]]; then
            if [[ "$path" == *.swift ]] && should_include_swift_file "$path"; then
                SWIFT_FILES+=("$path")
            fi
        elif [[ -d "$full" ]]; then
            while IFS= read -r file; do
                file="${file#"$ROOT_DIR/"}"
                if should_include_swift_file "$file"; then
                    SWIFT_FILES+=("$file")
                fi
            done < <(find "$full" -type f -name '*.swift' -print | LC_ALL=C sort)
        else
            fail "Configured Swift style path does not exist: $path"
        fi
    done
    SWIFT_FILES_COLLECTED=1
}

ensure_swift_files_collected(){
    if (( SWIFT_FILES_COLLECTED == 0 )); then
        collect_swift_files
    fi
}

run_swiftformat(){
    local mode="$1"
    ensure_tool swiftformat
    ensure_swift_files_collected

    if (( ${#SWIFT_FILES[@]} == 0 )); then
        echo "No changed Swift files in configured style scope."
        return
    fi

    local args=(--config "$ROOT_DIR/.swiftformat")
    if [[ "$mode" == "check" ]]; then
        args+=(--lint)
    fi
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        args+=(--reporter github-actions-log)
    fi

    cd "$ROOT_DIR"
    run swiftformat "${args[@]}" "${SWIFT_FILES[@]}"
}

run_swiftlint(){
    ensure_tool swiftlint
    ensure_swift_files_collected

    if (( ${#SWIFT_FILES[@]} == 0 )); then
        echo "No changed Swift files in configured style scope."
        return
    fi

    # Pass the selected files together so startup and SourceKit setup are paid once.
    local args=(lint --strict --config "$ROOT_DIR/.swiftlint.yml" --quiet --force-exclude)
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        args+=(--reporter github-actions-logging)
    fi

    cd "$ROOT_DIR"
    run swiftlint "${args[@]}" "${SWIFT_FILES[@]}"
}

case "$ACTION" in
    format) run_swiftformat format ;;
    format-check) run_swiftformat check ;;
    lint)
        run_swiftformat check
        run_swiftlint
        ;;
    *)
        echo "ERROR: Unknown subcommand: $ACTION" >&2
        echo "Usage: ./Scripts/swift_style.sh <format|format-check|lint>" >&2
        exit 2
        ;;
esac
