#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-}"
CONFIGURATION="${CONFIGURATION:-Debug}"

fail(){ echo "ERROR: $*" >&2; exit 1; }
usage(){
    cat >&2 <<'EOF'
Usage: Scripts/xcode_developer_workflow.sh {app|mcp|test|prepare-app-run}
This debug-only Xcode convenience delegates to conductor by default.
REPOPROMPT_XCODE_UNCOORDINATED=1 is build/test-only; Xcode Run requires conductor.
EOF
    exit 2
}
interrupted(){
    echo "ERROR: Xcode stopped waiting, but the conductor job may still be active." >&2
    echo "Inspect it with: ./conductor job list" >&2
    exit 130
}
trap interrupted INT TERM

[[ -n "$ACTION" ]] || usage
case "$ACTION" in app|mcp|test|prepare-app-run) ;; *) usage ;; esac
[[ "$CONFIGURATION" == "Debug" ]] || fail "The generated Xcode workflow is Debug-only; use the repository release workflow for '$CONFIGURATION'."

cd "$ROOT_DIR"

case "$ACTION" in
    app)
        if [[ -n "${REPOPROMPT_XCODE_SIGN_IDENTITY:-}" ]]; then
            export SIGN_IDENTITY="$REPOPROMPT_XCODE_SIGN_IDENTITY"
        fi
        export ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-1}"
        if [[ "${REPOPROMPT_XCODE_UNCOORDINATED:-0}" == "1" ]]; then
            ./Scripts/package_app.sh debug
        else
            ./conductor build
        fi
        [[ -x .build/debug/RepoPrompt.app/Contents/MacOS/RepoPrompt ]] || fail "packaged RepoPrompt executable is missing"
        [[ -x .build/debug/RepoPrompt.app/Contents/MacOS/repoprompt-mcp ]] || fail "embedded repoprompt-mcp is missing"
        ;;
    mcp)
        if [[ "${REPOPROMPT_XCODE_UNCOORDINATED:-0}" == "1" ]]; then
            ./Scripts/run_without_github_tokens.sh swift build -c debug --product repoprompt-mcp
        else
            ./conductor swift-build --product repoprompt-mcp
        fi
        [[ -x .build/debug/repoprompt-mcp ]] || fail "debug repoprompt-mcp executable is missing"
        ;;
    test)
        if [[ "${REPOPROMPT_XCODE_UNCOORDINATED:-0}" == "1" ]]; then
            command=(./Scripts/run_without_github_tokens.sh swift test)
            if [[ -n "${REPOPROMPT_XCODE_TEST_FILTER:-}" ]]; then
                command+=(--filter "$REPOPROMPT_XCODE_TEST_FILTER")
            fi
            "${command[@]}"
        else
            command=(./conductor test)
            if [[ -n "${REPOPROMPT_XCODE_TEST_FILTER:-}" ]]; then
                command+=(--filter "$REPOPROMPT_XCODE_TEST_FILTER")
            fi
            "${command[@]}"
        fi
        ;;
    prepare-app-run)
        if [[ "${REPOPROMPT_XCODE_UNCOORDINATED:-0}" == "1" ]]; then
            fail "The uncoordinated fallback is build/test-only; Xcode Run requires conductor for safe exact-executable lifecycle handling."
        fi
        ./conductor app stop
        ;;
esac
