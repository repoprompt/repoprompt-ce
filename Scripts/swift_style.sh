#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-}"

if [[ -z "$ACTION" || "$ACTION" == "--help" || "$ACTION" == "-h" ]]; then
    cat <<'EOF'
Usage: ./Scripts/swift_style.sh <format|format-check|lint>

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
collect_swift_files(){
    local path full file
    SWIFT_FILES=()

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
    local swiftformat_bin

    swiftformat_bin="$("$ROOT_DIR/Scripts/install_format_tools.sh" resolve-swiftformat)" || exit
    ensure_swift_files_collected

    if (( ${#SWIFT_FILES[@]} == 0 )); then
        fail "No Swift files found in configured style scope."
    fi

    local args=(--config "$ROOT_DIR/.swiftformat")
    if [[ "$mode" == "check" ]]; then
        args+=(--lint)
    fi
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        args+=(--reporter github-actions-log)
    fi

    cd "$ROOT_DIR"
    run "$swiftformat_bin" "${args[@]}" "${SWIFT_FILES[@]}"
}

run_swiftlint(){
    ensure_tool swiftlint

    # Full-repo lint lets SwiftLint discover files from .swiftlint.yml instead of
    # paying the large environment/script-input overhead for every Swift file.
    local args=(lint --strict --config "$ROOT_DIR/.swiftlint.yml" --quiet --force-exclude)
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        args+=(--reporter github-actions-logging)
    fi

    cd "$ROOT_DIR"
    run swiftlint "${args[@]}"
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
