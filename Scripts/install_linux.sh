#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${HOME:?HOME is required}/.local"
BINARY=""
REPLACE=0

usage() {
    cat <<'EOF'
Usage: Scripts/install_linux.sh [--prefix DIR] [--binary PATH] [--replace]

Install an already-built Linux repoprompt-mcp into DIR/bin (default ~/.local/bin).
Without --binary, use the current checkout's CONFIGURATION build (default release).
No build, downloads, privilege escalation, or shell-profile changes are performed.
An existing different executable is preserved unless --replace is supplied.
Symlinks and non-regular destinations are never replaced.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --prefix|--binary)
            (( $# >= 2 )) || fail "$1 requires a value"
            [[ -n "$2" && "$2" != --* ]] || fail "$1 requires a value"
            if [[ "$1" == --prefix ]]; then
                PREFIX="$2"
            else
                BINARY="$2"
            fi
            shift 2
            ;;
        --replace) REPLACE=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[[ "$(uname -s)" == Linux ]] || fail "This installer requires Linux"

if [[ -z "$BINARY" ]]; then
    command -v swift >/dev/null 2>&1 || fail "Swift is not on PATH; supply --binary or install the Linux toolchain"
    CONFIGURATION="${CONFIGURATION:-release}"
    [[ "$CONFIGURATION" == debug || "$CONFIGURATION" == release ]] || fail "CONFIGURATION must be debug or release"
    BIN_DIR="$(swift build --package-path "$ROOT_DIR" --configuration "$CONFIGURATION" --show-bin-path)"
    BINARY="$BIN_DIR/repoprompt-mcp"
fi

[[ -f "$BINARY" && -x "$BINARY" ]] || fail "Executable not found at '$BINARY'; run Scripts/build_linux.sh first"
INSTALL_DIR="$PREFIX/bin"
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
DESTINATION="$INSTALL_DIR/repoprompt-mcp"

if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    [[ -f "$DESTINATION" && ! -L "$DESTINATION" ]] || fail "Refusing to replace non-regular destination: $DESTINATION"
    if [[ -x "$DESTINATION" ]] && cmp -s "$BINARY" "$DESTINATION"; then
        printf 'Already installed: %s\n' "$DESTINATION"
        exit 0
    fi
    (( REPLACE )) || fail "Destination exists: $DESTINATION (use --replace to update it)"
fi

STAGED="$(mktemp "$INSTALL_DIR/.repoprompt-mcp.XXXXXXXX")"
trap 'rm -f -- "$STAGED"' EXIT
install -m 0755 -- "$BINARY" "$STAGED"

if (( REPLACE )); then
    [[ ! -L "$DESTINATION" && ( ! -e "$DESTINATION" || -f "$DESTINATION" ) ]] || fail "Destination changed to a non-regular file: $DESTINATION"
    mv -T -- "$STAGED" "$DESTINATION"
else
    ln -- "$STAGED" "$DESTINATION" || fail "Destination appeared during installation; preserved: $DESTINATION"
fi

printf 'Installed: %s\n' "$DESTINATION"
case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) printf 'Add this directory to your PATH: %s\n' "$INSTALL_DIR" ;;
esac
