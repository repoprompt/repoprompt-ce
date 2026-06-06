#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBUG_APP_ROOT="${REPOPROMPT_DEBUG_APP_ROOT:-$HOME/Library/Application Support/RepoPrompt CE/DebugApps}"
APP_BUNDLE="${REPOPROMPT_DEBUG_APP_BUNDLE:-$DEBUG_APP_ROOT/RepoPrompt.app}"
BUNDLED_CLI="$APP_BUNDLE/Contents/MacOS/repoprompt-mcp"
USER_LINK="$HOME/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug"
PATH_LINK="${REPOPROMPT_DEBUG_CLI_INSTALL_PATH:-/usr/local/bin/rpce-cli-debug}"
INSTALL_DIR="$(dirname "$PATH_LINK")"
COMMAND_NAME="$(basename "$PATH_LINK")"

ACTION="status"
BUILD_FIRST=0

if (( $# > 0 )) && [[ "${1:-}" != --* ]]; then
	ACTION="$1"
	shift
fi

while (( $# > 0 )); do
	case "$1" in
		--build) BUILD_FIRST=1 ;;
		--help|-h)
			cat <<EOF
Usage: $0 [status|install|uninstall] [--build]

Installs the RepoPrompt CE debug CLI command:
  $PATH_LINK -> $USER_LINK -> $BUNDLED_CLI

Options:
  --build   Package the debug app before installing.
EOF
			exit 0
			;;
		*) echo "ERROR: Unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

fail(){ echo "ERROR: $*" >&2; exit 1; }

is_managed_path_link(){
	local path="${1:-$PATH_LINK}" target
	[[ -L "$path" ]] || return 1
	target="$(readlink "$path" 2>/dev/null || true)"
	[[ "$target" == "$USER_LINK" || "$target" == "$BUNDLED_CLI" ]]
}

is_managed_user_link(){
	local path="${1:-$USER_LINK}" target canonical_debug_cli
	[[ -L "$path" ]] || return 1
	target="$(readlink "$path" 2>/dev/null || true)"
	canonical_debug_cli="$HOME/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/repoprompt-mcp"
	[[ "$target" == "$BUNDLED_CLI" || "$target" == "$canonical_debug_cli" ]]
}

atomic_symlink_replace(){
	local target="$1" path="$2" classifier="$3" tmp backup
	tmp="$(dirname "$path")/.$(basename "$path").$$.$RANDOM.tmp"
	backup="$(dirname "$path")/.$(basename "$path").$$.$RANDOM.backup"
	trap 'rm -f "$tmp"' RETURN
	ln -s "$target" "$tmp"
	if [[ -e "$path" || -L "$path" ]]; then
		mv "$path" "$backup"
		if ! "$classifier" "$backup"; then
			[[ -e "$path" || -L "$path" ]] || mv -n "$backup" "$path"
			fail "CLI ownership changed during replacement: $path"
		fi
	fi
	mv -n "$tmp" "$path"
	if [[ ! -L "$path" || "$(readlink "$path" 2>/dev/null || true)" != "$target" ]]; then
		rm -f "$backup"
		fail "Refusing to overwrite a raced CLI entry at $path"
	fi
	rm -f "$backup"
	trap - RETURN
}

ensure_bundled_cli(){
	if (( BUILD_FIRST )); then
		"$ROOT_DIR/Scripts/package_app.sh" debug
	fi

	if [[ ! -x "$BUNDLED_CLI" ]]; then
		fail "Debug CLI not found at '$BUNDLED_CLI'. Run 'make build' first, or use '$0 install --build'."
	fi
}

ensure_user_link(){
	ensure_bundled_cli

	local link_dir
	link_dir="$(dirname "$USER_LINK")"
	mkdir -p "$link_dir"

	if [[ -e "$USER_LINK" || -L "$USER_LINK" ]]; then
		if [[ ! -L "$USER_LINK" ]]; then
			fail "User-space debug CLI path exists but is not a symlink: $USER_LINK"
		fi
		if ! is_managed_user_link; then
			fail "Refusing to replace unmanaged user-space symlink at $USER_LINK"
		fi
	fi

	if [[ -L "$USER_LINK" && "$(readlink "$USER_LINK")" == "$BUNDLED_CLI" && -x "$USER_LINK" ]]; then
		return
	fi

	# Recheck ownership immediately before atomic rename.
	if [[ -e "$USER_LINK" || -L "$USER_LINK" ]]; then
		is_managed_user_link || fail "User-space CLI ownership changed before replacement: $USER_LINK"
	fi
	atomic_symlink_replace "$BUNDLED_CLI" "$USER_LINK" is_managed_user_link
}

install_path_link(){
	ensure_user_link

	if [[ ! -d "$INSTALL_DIR" ]]; then
		fail "Install directory does not exist: $INSTALL_DIR"
	fi

	if [[ -e "$PATH_LINK" || -L "$PATH_LINK" ]]; then
		if ! is_managed_path_link; then
			fail "Refusing to replace unmanaged file at $PATH_LINK"
		fi
	fi

	if [[ -w "$INSTALL_DIR" ]]; then
		if [[ -e "$PATH_LINK" || -L "$PATH_LINK" ]]; then
			is_managed_path_link || fail "PATH CLI ownership changed before replacement: $PATH_LINK"
		fi
		atomic_symlink_replace "$USER_LINK" "$PATH_LINK" is_managed_path_link
	else
		if [[ ! -t 0 ]]; then
			fail "$INSTALL_DIR is not writable. Re-run from an interactive terminal so sudo can install $COMMAND_NAME, or install it from Settings -> MCP -> CLI Tools."
		fi
		echo "Installing $COMMAND_NAME with administrator privileges..."
		local privileged_tmp="$INSTALL_DIR/.${COMMAND_NAME}.$$.$RANDOM.tmp"
		local privileged_backup="$INSTALL_DIR/.${COMMAND_NAME}.$$.$RANDOM.backup"
		sudo ln -s "$USER_LINK" "$privileged_tmp"
		if [[ -e "$PATH_LINK" || -L "$PATH_LINK" ]]; then
			sudo mv "$PATH_LINK" "$privileged_backup"
			if ! is_managed_path_link "$privileged_backup"; then
				[[ -e "$PATH_LINK" || -L "$PATH_LINK" ]] || sudo mv -n "$privileged_backup" "$PATH_LINK"
				sudo rm -f "$privileged_tmp"
				fail "PATH CLI ownership changed during replacement: $PATH_LINK"
			fi
		fi
		sudo mv -n "$privileged_tmp" "$PATH_LINK"
		if [[ ! -L "$PATH_LINK" || "$(readlink "$PATH_LINK" 2>/dev/null || true)" != "$USER_LINK" ]]; then
			sudo rm -f "$privileged_tmp" "$privileged_backup"
			fail "Refusing to overwrite a raced PATH CLI entry at $PATH_LINK"
		fi
		sudo rm -f "$privileged_backup"
	fi

	echo "Installed: $PATH_LINK -> $USER_LINK"
	"$PATH_LINK" --version
}

uninstall_path_link(){
	if [[ ! -e "$PATH_LINK" && ! -L "$PATH_LINK" ]]; then
		echo "$COMMAND_NAME is not installed at $PATH_LINK"
		return
	fi

	if ! is_managed_path_link; then
		fail "Refusing to remove unmanaged file at $PATH_LINK"
	fi

	local removal_backup="$INSTALL_DIR/.${COMMAND_NAME}.$$.$RANDOM.removing"
	if [[ -w "$INSTALL_DIR" ]]; then
		mv "$PATH_LINK" "$removal_backup"
		if ! is_managed_path_link "$removal_backup"; then
			[[ -e "$PATH_LINK" || -L "$PATH_LINK" ]] || mv -n "$removal_backup" "$PATH_LINK"
			fail "PATH CLI ownership changed during removal: $PATH_LINK"
		fi
		rm -f "$removal_backup"
	else
		if [[ ! -t 0 ]]; then
			fail "$INSTALL_DIR is not writable. Re-run from an interactive terminal so sudo can remove $COMMAND_NAME."
		fi
		echo "Removing $COMMAND_NAME with administrator privileges..."
		sudo mv "$PATH_LINK" "$removal_backup"
		if ! is_managed_path_link "$removal_backup"; then
			[[ -e "$PATH_LINK" || -L "$PATH_LINK" ]] || sudo mv -n "$removal_backup" "$PATH_LINK"
			fail "PATH CLI ownership changed during removal: $PATH_LINK"
		fi
		sudo rm -f "$removal_backup"
	fi

	echo "Removed: $PATH_LINK"
}

print_status(){
	echo "RepoPrompt CE debug CLI status"
	echo "  Debug app bundle: $APP_BUNDLE"
	if [[ -x "$BUNDLED_CLI" ]]; then
		echo "  Bundled CLI: OK ($BUNDLED_CLI)"
	else
		echo "  Bundled CLI: missing ($BUNDLED_CLI)"
	fi

	if [[ -L "$USER_LINK" ]]; then
		local target
		target="$(readlink "$USER_LINK" 2>/dev/null || true)"
		if [[ "$target" == "$BUNDLED_CLI" && -x "$USER_LINK" ]]; then
			echo "  User-space symlink: OK ($USER_LINK -> $target)"
		elif is_managed_user_link; then
			echo "  User-space symlink: stale ($USER_LINK -> $target)"
		else
			echo "  User-space symlink: unmanaged ($USER_LINK -> $target)"
		fi
	elif [[ -e "$USER_LINK" ]]; then
		echo "  User-space symlink: unmanaged file ($USER_LINK)"
	else
		echo "  User-space symlink: missing ($USER_LINK)"
	fi

	if [[ -L "$PATH_LINK" ]]; then
		local target
		target="$(readlink "$PATH_LINK" 2>/dev/null || true)"
		if is_managed_path_link && [[ -x "$PATH_LINK" ]]; then
			echo "  PATH command: OK ($PATH_LINK -> $target)"
		elif is_managed_path_link; then
			echo "  PATH command: stale ($PATH_LINK -> $target)"
		else
			echo "  PATH command: unmanaged symlink ($PATH_LINK -> $target)"
		fi
	elif [[ -e "$PATH_LINK" ]]; then
		echo "  PATH command: unmanaged file ($PATH_LINK)"
	else
		echo "  PATH command: missing ($PATH_LINK)"
	fi

	if command -v "$COMMAND_NAME" >/dev/null 2>&1; then
		echo "  command -v $COMMAND_NAME: $(command -v "$COMMAND_NAME")"
	elif [[ -x "$USER_LINK" ]]; then
		echo "  Direct fallback: \"$USER_LINK\" -e 'windows'"
	fi

	if [[ -x "$PATH_LINK" ]]; then
		echo "  Version: $("$PATH_LINK" --version 2>/dev/null || true)"
	elif [[ -x "$USER_LINK" ]]; then
		echo "  Version: $("$USER_LINK" --version 2>/dev/null || true)"
	fi

	echo "  Install/update: make install-debug-cli"
}

case "$ACTION" in
	status) print_status ;;
	install) install_path_link ;;
	uninstall) uninstall_path_link ;;
	*) fail "Unknown action '$ACTION'. Expected status, install, or uninstall." ;;
esac
