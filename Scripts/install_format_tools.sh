#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="status"

SWIFTFORMAT_REQUIRED_VERSION="0.61.1"
SWIFTFORMAT_ARCHIVE_SHA256="b990400779aceb7d7020796eb9ba814d4480543f671d38fc0ff48cb72f04c584"
SWIFTFORMAT_ARCHIVE_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_REQUIRED_VERSION}/swiftformat.zip"
FORMAT_TOOLS_DIR="${REPOPROMPT_FORMAT_TOOLS_DIR:-$ROOT_DIR/.build/format-tools}"
MANAGED_SWIFTFORMAT_DIR="$FORMAT_TOOLS_DIR/swiftformat/$SWIFTFORMAT_REQUIRED_VERSION"
MANAGED_SWIFTFORMAT_PATH="$MANAGED_SWIFTFORMAT_DIR/swiftformat"
TEMP_DIR=""

cleanup(){
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

if (( $# > 0 )) && [[ "${1:-}" != -* ]]; then
    ACTION="$1"
    shift
fi

while (( $# > 0 )); do
    case "$1" in
        --help|-h)
            cat <<'EOF'
Usage: ./Scripts/install_format_tools.sh [status|check|install|resolve-swiftformat]

Checks or installs the required Swift style tools:
  - SwiftFormat 0.61.1 from the checksum-pinned official release
  - SwiftLint

Subcommands:
  status               Print tool availability and versions. Always exits 0.
  check                Fail unless authoritative SwiftFormat and SwiftLint are available.
  install              Install authoritative SwiftFormat and missing SwiftLint, then verify them.
  resolve-swiftformat  Print the authoritative SwiftFormat executable path.

SwiftFormat is installed into the repository-local .build/format-tools directory
when the system executable is missing or has a different version. SwiftLint
continues to use Homebrew when it is missing.
EOF
            exit 0
            ;;
        *) echo "ERROR: Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

fail(){ echo "ERROR: $*" >&2; exit 1; }
has_tool(){ command -v "$1" >/dev/null 2>&1; }

swiftformat_version_at(){
    local executable="$1"
    "$executable" --version 2>/dev/null || true
}

swiftlint_version(){
    swiftlint version 2>/dev/null || swiftlint --version 2>/dev/null || true
}

system_swiftformat_path(){
    command -v swiftformat 2>/dev/null || true
}

authoritative_swiftformat_path(){
    local system_path

    if [[ -x "$MANAGED_SWIFTFORMAT_PATH" ]] \
        && [[ "$(swiftformat_version_at "$MANAGED_SWIFTFORMAT_PATH")" == "$SWIFTFORMAT_REQUIRED_VERSION" ]]
    then
        printf '%s\n' "$MANAGED_SWIFTFORMAT_PATH"
        return 0
    fi

    system_path="$(system_swiftformat_path)"
    if [[ -n "$system_path" ]] \
        && [[ "$(swiftformat_version_at "$system_path")" == "$SWIFTFORMAT_REQUIRED_VERSION" ]]
    then
        printf '%s\n' "$system_path"
        return 0
    fi

    return 1
}

print_swiftformat_status(){
    local resolved_path system_path version

    if resolved_path="$(authoritative_swiftformat_path)"; then
        echo "  SwiftFormat: OK ($SWIFTFORMAT_REQUIRED_VERSION at $resolved_path)"
        return
    fi

    system_path="$(system_swiftformat_path)"
    if [[ -n "$system_path" ]]; then
        version="$(swiftformat_version_at "$system_path")"
        echo "  SwiftFormat: incompatible (${version:-unknown} at $system_path; requires $SWIFTFORMAT_REQUIRED_VERSION)"
    else
        echo "  SwiftFormat: missing (requires $SWIFTFORMAT_REQUIRED_VERSION)"
    fi
}

print_swiftlint_status(){
    local version

    if has_tool swiftlint; then
        version="$(swiftlint_version)"
        if [[ -n "$version" ]]; then
            echo "  SwiftLint: OK ($version)"
        else
            echo "  SwiftLint: OK ($(command -v swiftlint))"
        fi
    else
        echo "  SwiftLint: missing"
    fi
}

print_status(){
    echo "Swift style tool status"
    print_swiftformat_status
    print_swiftlint_status
}

all_tools_present(){
    authoritative_swiftformat_path >/dev/null && has_tool swiftlint
}

print_remediation(){
    cat >&2 <<'EOF'
Install the repository-authoritative format tools with:
  make install-format-tools

SwiftFormat is downloaded from the checksum-pinned official release when the
system version does not match. SwiftLint is installed with Homebrew when missing.
EOF
}

check_tools(){
    if ! all_tools_present; then
        print_status
        print_remediation
        fail "Missing or incompatible required Swift style tools."
    fi
    print_status
}

require_install_tool(){
    has_tool "$1" || fail "Missing required installer tool: $1."
}

install_authoritative_swiftformat(){
    local archive extracted_path actual_sha installed_version destination_tmp tool

    for tool in curl shasum unzip awk mktemp mkdir cp chmod mv rm; do
        require_install_tool "$tool"
    done

    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repoprompt-swiftformat.XXXXXX")"
    archive="$TEMP_DIR/swiftformat.zip"

    echo "Installing SwiftFormat $SWIFTFORMAT_REQUIRED_VERSION from the verified official release..."
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --silent --show-error \
        "$SWIFTFORMAT_ARCHIVE_URL" \
        --output "$archive"

    actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual_sha" != "$SWIFTFORMAT_ARCHIVE_SHA256" ]]; then
        fail "SwiftFormat archive checksum mismatch (expected $SWIFTFORMAT_ARCHIVE_SHA256, got ${actual_sha:-unavailable})."
    fi

    mkdir -p "$TEMP_DIR/extracted"
    unzip -q "$archive" -d "$TEMP_DIR/extracted"
    extracted_path="$TEMP_DIR/extracted/swiftformat"
    [[ -f "$extracted_path" ]] || fail "Verified SwiftFormat archive did not contain the expected executable."
    chmod 0755 "$extracted_path"

    installed_version="$(swiftformat_version_at "$extracted_path")"
    if [[ "$installed_version" != "$SWIFTFORMAT_REQUIRED_VERSION" ]]; then
        fail "Verified SwiftFormat archive reported version ${installed_version:-unavailable}; expected $SWIFTFORMAT_REQUIRED_VERSION."
    fi

    mkdir -p "$MANAGED_SWIFTFORMAT_DIR"
    destination_tmp="$MANAGED_SWIFTFORMAT_PATH.tmp.$$"
    cp "$extracted_path" "$destination_tmp"
    chmod 0755 "$destination_tmp"
    mv -f "$destination_tmp" "$MANAGED_SWIFTFORMAT_PATH"

    rm -rf "$TEMP_DIR"
    TEMP_DIR=""
    echo "Installed SwiftFormat $SWIFTFORMAT_REQUIRED_VERSION at $MANAGED_SWIFTFORMAT_PATH"
}

install_missing_tools(){
    local resolved_path

    if resolved_path="$(authoritative_swiftformat_path)"; then
        echo "SwiftFormat $SWIFTFORMAT_REQUIRED_VERSION already available at $resolved_path."
    else
        install_authoritative_swiftformat
    fi

    if has_tool swiftlint; then
        echo "SwiftLint already installed."
    else
        has_tool brew || fail "Homebrew is required to install SwiftLint. Install Homebrew, then rerun 'make install-format-tools'."
        echo "Installing SwiftLint with Homebrew..."
        brew install swiftlint
    fi

    check_tools
}

resolve_swiftformat(){
    local resolved_path

    if resolved_path="$(authoritative_swiftformat_path)"; then
        printf '%s\n' "$resolved_path"
        return
    fi

    print_swiftformat_status >&2
    print_remediation
    fail "SwiftFormat $SWIFTFORMAT_REQUIRED_VERSION is required but unavailable."
}

case "$ACTION" in
    status) print_status ;;
    check) check_tools ;;
    install) install_missing_tools ;;
    resolve-swiftformat) resolve_swiftformat ;;
    *)
        echo "ERROR: Unknown subcommand: $ACTION" >&2
        echo "Usage: ./Scripts/install_format_tools.sh [status|check|install|resolve-swiftformat]" >&2
        exit 2
        ;;
esac
