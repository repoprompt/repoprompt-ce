#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HEADLESS_TOOLS_ROOT="${REPOPROMPT_HEADLESS_TOOLS_ROOT:-$HOME/Library/Application Support/RepoPrompt CE/HeadlessTools}"
SUPPORT_ROOT="$HOME/Library/Application Support/RepoPrompt CE"
BINARY_NAME="repoprompt-headless"

ACTION="status"
CONFIGURATION="all"
CONFIGURATION_EXPLICIT=0
BUILD_FIRST=0

fail() { echo "ERROR: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $0 [status|install|uninstall] [--configuration debug|release] [--build]

Installs or inspects standalone RepoPrompt CE headless MCP commands.

Managed debug link:
  ${REPOPROMPT_HEADLESS_DEBUG_INSTALL_PATH:-/usr/local/bin/rpce-headless-debug}
    -> $SUPPORT_ROOT/repoprompt_headless_debug
    -> $HEADLESS_TOOLS_ROOT/Debug/$BINARY_NAME

Managed release link:
  ${REPOPROMPT_HEADLESS_INSTALL_PATH:-/usr/local/bin/rpce-headless}
    -> $SUPPORT_ROOT/repoprompt_headless
    -> $HEADLESS_TOOLS_ROOT/Release/$BINARY_NAME

Options:
  --configuration debug|release   Select which command to install/uninstall (default: debug)
  --build                         Package the selected headless binary before installing
EOF
}

if (( $# > 0 )) && [[ "${1:-}" != --* ]]; then
	ACTION="$1"
	shift
fi

while (( $# > 0 )); do
	case "$1" in
		--configuration)
			shift
			[[ $# -gt 0 ]] || fail "--configuration requires debug or release"
			case "$1" in
				debug|release) CONFIGURATION="$1"; CONFIGURATION_EXPLICIT=1 ;;
				*) fail "--configuration must be debug or release, got '$1'" ;;
			esac
			;;
		--build) BUILD_FIRST=1 ;;
		--help|-h) usage; exit 0 ;;
		*) fail "Unknown option: $1" ;;
	esac
	shift
done

case "$ACTION" in
	status|install|uninstall) ;;
	*) fail "Unknown action '$ACTION'. Expected status, install, or uninstall." ;;
esac

if [[ "$ACTION" != "status" && "$CONFIGURATION" == "all" ]]; then
	CONFIGURATION="debug"
fi

config_label() {
	case "$1" in
		debug) printf 'Debug' ;;
		release) printf 'Release' ;;
		*) fail "Unknown configuration '$1'" ;;
	esac
}

binary_for() {
	local config="$1"
	printf '%s/%s/%s' "$HEADLESS_TOOLS_ROOT" "$(config_label "$config")" "$BINARY_NAME"
}

user_link_for() {
	case "$1" in
		debug) printf '%s/repoprompt_headless_debug' "$SUPPORT_ROOT" ;;
		release) printf '%s/repoprompt_headless' "$SUPPORT_ROOT" ;;
		*) fail "Unknown configuration '$1'" ;;
	esac
}

path_link_for() {
	case "$1" in
		debug) printf '%s' "${REPOPROMPT_HEADLESS_DEBUG_INSTALL_PATH:-/usr/local/bin/rpce-headless-debug}" ;;
		release) printf '%s' "${REPOPROMPT_HEADLESS_INSTALL_PATH:-/usr/local/bin/rpce-headless}" ;;
		*) fail "Unknown configuration '$1'" ;;
	esac
}

command_name_for() {
	basename "$(path_link_for "$1")"
}

is_managed_path_link() {
	local config="$1" path_link user_link binary target
	path_link="$(path_link_for "$config")"
	user_link="$(user_link_for "$config")"
	binary="$(binary_for "$config")"
	[[ -L "$path_link" ]] || return 1
	target="$(readlink "$path_link" 2>/dev/null || true)"
	[[ "$target" == "$user_link" || "$target" == "$binary" ]]
}

is_current_user_link() {
	local config="$1" user_link binary target
	user_link="$(user_link_for "$config")"
	binary="$(binary_for "$config")"
	[[ -L "$user_link" ]] || return 1
	target="$(readlink "$user_link" 2>/dev/null || true)"
	[[ "$target" == "$binary" && -x "$user_link" ]]
}

is_current_path_link() {
	local config="$1" path_link user_link binary target
	path_link="$(path_link_for "$config")"
	user_link="$(user_link_for "$config")"
	binary="$(binary_for "$config")"
	[[ -L "$path_link" ]] || return 1
	target="$(readlink "$path_link" 2>/dev/null || true)"
	if [[ "$target" == "$binary" && -x "$path_link" ]]; then
		return 0
	fi
	[[ "$target" == "$user_link" && -x "$path_link" ]] || return 1
	is_current_user_link "$config"
}

ensure_binary() {
	local config="$1" binary
	binary="$(binary_for "$config")"
	if (( BUILD_FIRST )); then
		"$ROOT_DIR/Scripts/package_headless.sh" "$config"
	fi
	[[ -x "$binary" ]] || fail "Headless binary not found at '$binary'. Run './Scripts/package_headless.sh $config' first, or use '$0 install --configuration $config --build'."
}

ensure_user_link() {
	local config="$1" binary user_link link_dir
	ensure_binary "$config"
	binary="$(binary_for "$config")"
	user_link="$(user_link_for "$config")"
	link_dir="$(dirname "$user_link")"
	mkdir -p "$link_dir"
	if [[ -e "$user_link" && ! -L "$user_link" ]]; then
		fail "User-space headless path exists but is not a symlink: $user_link"
	fi
	if [[ -L "$user_link" && "$(readlink "$user_link")" == "$binary" && -x "$user_link" ]]; then
		return
	fi
	rm -f "$user_link"
	ln -s "$binary" "$user_link"
}

install_path_link() {
	local config="$1" path_link user_link install_dir command_name
	ensure_user_link "$config"
	path_link="$(path_link_for "$config")"
	user_link="$(user_link_for "$config")"
	install_dir="$(dirname "$path_link")"
	command_name="$(command_name_for "$config")"
	[[ -d "$install_dir" ]] || fail "Install directory does not exist: $install_dir"
	if [[ -e "$path_link" || -L "$path_link" ]]; then
		if ! is_managed_path_link "$config"; then
			fail "Refusing to replace unmanaged file at $path_link"
		fi
	fi
	if [[ -w "$install_dir" ]]; then
		rm -f "$path_link"
		ln -s "$user_link" "$path_link"
	else
		if [[ ! -t 0 ]]; then
			fail "$install_dir is not writable. Re-run from an interactive terminal so sudo can install $command_name."
		fi
		echo "Installing $command_name with administrator privileges..."
		sudo rm -f "$path_link"
		sudo ln -s "$user_link" "$path_link"
	fi
	echo "Installed: $path_link -> $user_link"
	"$path_link" --version
}

uninstall_path_link() {
	local config="$1" path_link install_dir command_name
	path_link="$(path_link_for "$config")"
	install_dir="$(dirname "$path_link")"
	command_name="$(command_name_for "$config")"
	if [[ ! -e "$path_link" && ! -L "$path_link" ]]; then
		echo "$command_name is not installed at $path_link"
		return
	fi
	if ! is_managed_path_link "$config"; then
		fail "Refusing to remove unmanaged file at $path_link"
	fi
	if [[ -w "$install_dir" ]]; then
		rm -f "$path_link"
	else
		if [[ ! -t 0 ]]; then
			fail "$install_dir is not writable. Re-run from an interactive terminal so sudo can remove $command_name."
		fi
		echo "Removing $command_name with administrator privileges..."
		sudo rm -f "$path_link"
	fi
	echo "Removed: $path_link"
}

print_one_status() {
	local config="$1" label binary user_link path_link command_name target
	label="$(config_label "$config")"
	binary="$(binary_for "$config")"
	user_link="$(user_link_for "$config")"
	path_link="$(path_link_for "$config")"
	command_name="$(command_name_for "$config")"
	echo "RepoPrompt CE headless $config status"
	echo "  Staged binary: $binary"
	if [[ -x "$binary" ]]; then
		echo "  Staged binary state: OK"
	else
		echo "  Staged binary state: missing"
	fi
	if [[ -L "$user_link" ]]; then
		target="$(readlink "$user_link" 2>/dev/null || true)"
		if is_current_user_link "$config"; then
			echo "  User-space symlink: OK ($user_link -> $target)"
		else
			echo "  User-space symlink: stale ($user_link -> $target)"
		fi
	else
		echo "  User-space symlink: missing ($user_link)"
	fi
	if [[ -L "$path_link" ]]; then
		target="$(readlink "$path_link" 2>/dev/null || true)"
		if is_current_path_link "$config"; then
			echo "  PATH command: OK ($path_link -> $target)"
		elif is_managed_path_link "$config"; then
			echo "  PATH command: stale ($path_link -> $target)"
		else
			echo "  PATH command: unmanaged symlink ($path_link -> $target)"
		fi
	elif [[ -e "$path_link" ]]; then
		echo "  PATH command: unmanaged file ($path_link)"
	else
		echo "  PATH command: missing ($path_link)"
	fi
	if command -v "$command_name" >/dev/null 2>&1; then
		echo "  command -v $command_name: $(command -v "$command_name")"
	elif [[ -x "$user_link" ]]; then
		echo "  Direct fallback: \"$user_link\" doctor"
	fi
	if [[ -x "$path_link" ]]; then
		echo "  Version: $("$path_link" --version 2>/dev/null || true)"
	elif [[ -x "$user_link" ]]; then
		echo "  Version: $("$user_link" --version 2>/dev/null || true)"
	elif [[ -x "$binary" ]]; then
		echo "  Version: $("$binary" --version 2>/dev/null || true)"
	fi
	if [[ "$label" == "Debug" ]]; then
		echo "  Install/update: make install-debug-headless"
	else
		echo "  Install/update: ./Scripts/install_headless_cli.sh install --configuration release --build"
	fi
}

case "$ACTION" in
	status)
		if [[ "$CONFIGURATION" == "all" && "$CONFIGURATION_EXPLICIT" == "0" ]]; then
			print_one_status debug
			echo
			print_one_status release
		else
			print_one_status "$CONFIGURATION"
		fi
		;;
	install) install_path_link "$CONFIGURATION" ;;
	uninstall) uninstall_path_link "$CONFIGURATION" ;;
esac
