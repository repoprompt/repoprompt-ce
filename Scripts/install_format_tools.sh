#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="status"
REQUIRED_SWIFTFORMAT_VERSION="0.61.1"

if (( $# > 0 )) && [[ "${1:-}" != -* ]]; then
    ACTION="$1"
    shift
fi

while (( $# > 0 )); do
    case "$1" in
        --help|-h)
            cat <<'EOF'
Usage: ./Scripts/install_format_tools.sh [status|check|install]

Checks or installs the required Swift style tools:
  - SwiftFormat (Nick Lockwood)
  - SwiftLint

Subcommands:
  status   Print tool availability and versions. Always exits 0.
  check    Fail if either tool is missing and print remediation.
  install  Install missing tools with Homebrew, then verify them.

Homebrew must already be installed; this script does not install Homebrew.
EOF
            exit 0
            ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

fail(){ echo "ERROR: $*" >&2; exit 1; }
has_tool(){ command -v "$1" >/dev/null 2>&1; }

swiftformat_version(){
    swiftformat --version 2>/dev/null || true
}

swiftlint_version(){
    swiftlint version 2>/dev/null || swiftlint --version 2>/dev/null || true
}

print_tool_status(){
    local name="$1"
    local command_name="$2"
    local version

    if has_tool "$command_name"; then
        case "$command_name" in
            swiftformat) version="$(swiftformat_version)" ;;
            swiftlint) version="$(swiftlint_version)" ;;
            *) version="" ;;
        esac
        if [[ -n "$version" ]]; then
            echo "  $name: OK ($version)"
        else
            echo "  $name: OK ($(command -v "$command_name"))"
        fi
    else
        echo "  $name: missing"
    fi
}

print_status(){
    echo "Swift style tool status"
    print_tool_status "SwiftFormat" swiftformat
    print_tool_status "SwiftLint" swiftlint
}

all_tools_present(){
    has_tool swiftformat && has_tool swiftlint
}

print_remediation(){
    cat >&2 <<'EOF'
Install missing format tools with:
  make install-format-tools

Or directly with Homebrew:
  brew install swiftformat swiftlint
EOF
}

check_tools(){
    if ! all_tools_present; then
        print_status
        print_remediation
        fail "Missing required Swift style tools."
    fi
    local installed_swiftformat_version
    installed_swiftformat_version="$(swiftformat_version)"
    if [[ "$installed_swiftformat_version" != "$REQUIRED_SWIFTFORMAT_VERSION" ]]; then
        fail "SwiftFormat $REQUIRED_SWIFTFORMAT_VERSION is required; found ${installed_swiftformat_version:-unknown}. Update the repository baseline deliberately before using a different formatter version."
    fi
    print_status
}

install_missing_tools(){
    if ! has_tool brew; then
        fail "Homebrew is required to install SwiftFormat and SwiftLint. Install Homebrew first, then rerun 'make install-format-tools'."
    fi

    echo "Installing SwiftFormat $REQUIRED_SWIFTFORMAT_VERSION baseline with Homebrew..."
    brew install swiftformat

    echo "Installing SwiftLint with Homebrew..."
    brew install swiftlint

    check_tools
}

case "$ACTION" in
    status) print_status ;;
    check) check_tools ;;
    install) install_missing_tools ;;
    *)
        echo "ERROR: Unknown subcommand: $ACTION" >&2
        echo "Usage: ./Scripts/install_format_tools.sh [status|check|install]" >&2
        exit 2
        ;;
esac
